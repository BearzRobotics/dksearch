//! Runs imports on behalf of a long-lived process (the administration
//! interface), one at a time, in the background.
//!
//! It does what `dksearch import` does for one source, with the same rules:
//! it takes the data directory's writer lock first (so it cannot run
//! alongside a command-line import, a rebuild or a removal), opens its own
//! connections to the stores and the index, drives the connector through the
//! shared runner, and releases everything when done. Nothing here knows about
//! HTTP. See docs/decisions/0014-admin-actions.md.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const connector = @import("connector.zig");
const connectors = @import("connectors.zig");
const document = @import("document.zig");
const index_sqlite = @import("index_sqlite.zig");
const content_sqlite = @import("content_sqlite.zig");
const state_sqlite = @import("state_sqlite.zig");
const pipeline = @import("pipeline.zig");
const runner = @import("runner.zig");
const maintenance = @import("maintenance.zig");

/// The runner wants a clock without a context argument; one process runs one
/// manager, so the clock's `Io` is kept here.
var clock_io: ?Io = null;

fn now() document.Timestamp {
    const io = clock_io orelse return 0;
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

pub const Options = struct {
    data_dir: []const u8,
    index_path: [:0]const u8,
    state_path: [:0]const u8,
    content_path: [:0]const u8,
    tokenizer: index_sqlite.Tokenizer = .unicode61,
    /// The configured sources; must outlive the manager.
    sources: []const config.Source,
    /// Tests only: skip syncing, which is very slow on some disks.
    sync_off: bool = false,
};

pub const StartError = error{
    UnknownSource,
    SourceDisabled,
    AlreadyRunning,
    /// The data directory or its lock file cannot be used (permissions,
    /// missing directory, disk error): not the same as another process
    /// holding the lock.
    DataDirUnavailable,
    /// The writer lock is held by another process (an import or rebuild on
    /// the command line, for instance).
    LockHeld,
    OutOfMemory,
    NoConcurrency,
};

/// How the most recent run ended; kept in memory for display.
pub const Finished = struct {
    source: []const u8,
    state: state_sqlite.JobState,
    submitted: u64,
    rejected: u64,
    failure: ?[]const u8,
    finished_at: document.Timestamp,
};

pub const Active = struct {
    source: []const u8,
    started_at: document.Timestamp,
    /// Documents submitted so far (live).
    submitted: u64,
};

pub const Manager = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    mutex: Io.Mutex = .init,
    group: Io.Group = .init,
    running: ?Running = null,
    last: ?OwnedFinished = null,

    const Running = struct {
        source: []const u8, // owned
        started_at: document.Timestamp,
        control: *connector.Control,
    };

    const OwnedFinished = struct {
        source: []const u8,
        state: state_sqlite.JobState,
        submitted: u64,
        rejected: u64,
        failure: ?[]const u8,
        finished_at: document.Timestamp,
    };

    pub fn init(gpa: Allocator, io: Io, opts: Options) Manager {
        clock_io = io;
        return .{ .gpa = gpa, .io = io, .opts = opts };
    }

    /// Cancels a running import and waits for it to stop.
    pub fn deinit(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        if (self.running) |r| r.control.cancel();
        self.mutex.unlock(self.io);
        self.group.await(self.io) catch {};
        if (self.last) |l| self.freeFinished(l);
        self.* = undefined;
    }

    fn freeFinished(self: *Manager, l: OwnedFinished) void {
        self.gpa.free(l.source);
        if (l.failure) |f| self.gpa.free(f);
    }

    /// Starts importing `name` in the background and returns at once.
    pub fn start(self: *Manager, name: []const u8) StartError!void {
        const source = for (self.opts.sources) |s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else return error.UnknownSource;
        if (!source.enabled) return error.SourceDisabled;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.running != null) return error.AlreadyRunning;

        // The lock is taken here, so a conflict is reported to the caller,
        // and handed to the task, which releases it when the run ends.
        var dir = Io.Dir.cwd().openDir(self.io, self.opts.data_dir, .{}) catch return error.DataDirUnavailable;
        defer dir.close(self.io);
        const lock = maintenance.WriterLock.acquire(self.io, dir, "write.lock") catch |e| return switch (e) {
            error.Busy => error.LockHeld,
            error.Io => error.DataDirUnavailable,
        };
        errdefer lock.release(self.io);

        const control = self.gpa.create(connector.Control) catch return error.OutOfMemory;
        errdefer self.gpa.destroy(control);
        control.* = .{};
        const owned_name = self.gpa.dupe(u8, source.name) catch return error.OutOfMemory;
        errdefer self.gpa.free(owned_name);

        self.running = .{ .source = owned_name, .started_at = now(), .control = control };
        self.group.concurrent(self.io, task, .{ self, source, control, lock }) catch {
            self.running = null;
            return error.NoConcurrency;
        };
    }

    /// Asks the running import to stop at its next safe point. Returns false
    /// if none is running.
    pub fn cancel(self: *Manager) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const r = self.running orelse return false;
        r.control.cancel();
        return true;
    }

    /// The running import, if any. The source name is allocated from `arena`.
    pub fn current(self: *Manager, arena: Allocator) Allocator.Error!?Active {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const r = self.running orelse return null;
        return .{
            .source = try arena.dupe(u8, r.source),
            .started_at = r.started_at,
            .submitted = r.control.submitted.load(.monotonic),
        };
    }

    /// How the last run ended, if any ran since the process started.
    pub fn lastResult(self: *Manager, arena: Allocator) Allocator.Error!?Finished {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const l = self.last orelse return null;
        return .{
            .source = try arena.dupe(u8, l.source),
            .state = l.state,
            .submitted = l.submitted,
            .rejected = l.rejected,
            .failure = if (l.failure) |f| try arena.dupe(u8, f) else null,
            .finished_at = l.finished_at,
        };
    }

    // ------------------------------------------------------------ the task

    /// How a run ended. `failure`, when set, is allocated from the manager's
    /// allocator and ownership passes to `last` in `record`.
    const Outcome = struct {
        state: state_sqlite.JobState,
        submitted: u64 = 0,
        rejected: u64 = 0,
        failure: ?[]const u8 = null,
    };

    fn fail(self: *Manager, out: *Outcome, text: []const u8) void {
        out.state = .failed;
        out.failure = self.gpa.dupe(u8, text) catch null;
    }

    fn runOne(self: *Manager, source: config.Source, control: *connector.Control, out: *Outcome) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var state = state_sqlite.SqliteStateStore.open(self.gpa, self.opts.state_path, self.opts.sync_off) catch {
            self.fail(out, "cannot open state.db");
            return;
        };
        defer state.close();
        var content = content_sqlite.SqliteContentStore.open(self.gpa, self.opts.content_path, self.opts.sync_off) catch {
            self.fail(out, "cannot open content.db");
            return;
        };
        defer content.close();
        var index = index_sqlite.SqliteIndex.open(self.opts.index_path, .{
            .tokenizer = self.opts.tokenizer,
            .sync = if (self.opts.sync_off) .off else .normal,
        }) catch |e| {
            self.fail(out, if (e == error.TokenizerMismatch)
                "the index was built with a different tokenizer; run `dksearch rebuild`"
            else
                "cannot open index.db");
            return;
        };
        defer index.close();

        var inst = connectors.create(self.gpa, self.io, source) catch {
            self.fail(out, "out of memory");
            return;
        };
        defer inst.deinit();
        var pipe = pipeline.Pipeline.init(content.store(), state.documents(), index.indexer(), .{
            .retain_text = source.retain_text,
            .now = now,
        });
        const r = runner.runImport(arena, &state, &pipe, inst.connector(), source.name, control, now) catch {
            self.fail(out, "the run could not be recorded (storage problem)");
            return;
        };
        out.state = r.state;
        out.submitted = r.submitted;
        out.rejected = r.rejected;
        if (r.failure) |f| out.failure = self.gpa.dupe(u8, f) catch null; // `f` lives in the arena
    }

    fn task(self: *Manager, source: config.Source, control: *connector.Control, lock: maintenance.WriterLock) Io.Cancelable!void {
        // `runOne` sets the state on every path; `failed` is the safe default.
        var outcome: Outcome = .{ .state = .failed };
        runOne(self, source, control, &outcome);
        lock.release(self.io);
        self.record(source.name, outcome);
    }

    fn record(self: *Manager, name: []const u8, o: Outcome) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.last) |old| self.freeFinished(old);
        const owned_name = self.gpa.dupe(u8, name) catch null;
        if (owned_name == null) {
            // Out of memory: nothing can be remembered; do not leak the text.
            if (o.failure) |f| self.gpa.free(f);
        }
        self.last = if (owned_name == null) null else .{
            .source = owned_name.?,
            .state = o.state,
            .submitted = o.submitted,
            .rejected = o.rejected,
            .failure = o.failure, // ownership moves here
            .finished_at = now(),
        };
        if (self.running) |r| {
            self.gpa.free(r.source);
            self.gpa.destroy(r.control);
        }
        self.running = null;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Env = struct {
    tmp: testing.TmpDir,
    notes: testing.TmpDir,
    paths: [3][160:0]u8 = undefined,
    data_dir: [160]u8 = undefined,
    data_len: usize = 0,
    notes_path: [160]u8 = undefined,
    opts_sources: [2]config.Source = undefined,
    note_opts: [1]config.Option = undefined,

    fn init(e: *Env) !void {
        e.tmp = testing.tmpDir(.{});
        e.notes = testing.tmpDir(.{ .iterate = true });
        const dd = try std.fmt.bufPrint(&e.data_dir, ".zig-cache/tmp/{s}", .{e.tmp.sub_path});
        e.data_len = dd.len;
        _ = try std.fmt.bufPrintSentinel(&e.paths[0], "{s}/index.db", .{dd}, 0);
        _ = try std.fmt.bufPrintSentinel(&e.paths[1], "{s}/state.db", .{dd}, 0);
        _ = try std.fmt.bufPrintSentinel(&e.paths[2], "{s}/content.db", .{dd}, 0);
        const np = try std.fmt.bufPrint(&e.notes_path, ".zig-cache/tmp/{s}", .{e.notes.sub_path});
        e.note_opts = .{.{ .key = "path", .value = .{ .string = np } }};
        e.opts_sources = .{
            .{ .name = "notes", .kind = "files", .options = &e.note_opts },
            .{ .name = "off", .kind = "files", .enabled = false, .options = &e.note_opts },
        };
        try e.notes.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "the keeper trims the lamp" });
        try e.notes.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "gulls over the rocks" });
    }
    fn deinit(e: *Env) void {
        e.notes.cleanup();
        e.tmp.cleanup();
    }
    fn options(e: *Env) Options {
        return .{
            .data_dir = e.data_dir[0..e.data_len],
            .index_path = std.mem.sliceTo(&e.paths[0], 0),
            .state_path = std.mem.sliceTo(&e.paths[1], 0),
            .content_path = std.mem.sliceTo(&e.paths[2], 0),
            .sources = &e.opts_sources,
            .sync_off = true,
        };
    }
};

fn waitIdle(m: *Manager) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 1) {
        if ((try m.current(arena.allocator())) == null) return;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.TestTimedOut;
}

test "an import runs in the background, finishes, and is remembered" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    var m = Manager.init(testing.allocator, testing.io, env.options());
    defer m.deinit();

    try testing.expect((try m.lastResult(testing.allocator)) == null);
    try m.start("notes");
    try waitIdle(&m);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const last = (try m.lastResult(arena.allocator())).?;
    try testing.expectEqualStrings("notes", last.source);
    try testing.expectEqual(state_sqlite.JobState.completed, last.state);
    try testing.expectEqual(@as(u64, 2), last.submitted);
    try testing.expect(last.failure == null);

    // The data is really there, and the lock was released.
    var index = try index_sqlite.SqliteIndex.open(env.options().index_path, .{ .sync = .off });
    defer index.close();
    try testing.expectEqual(@as(u64, 2), try index.count());
    const lock = try maintenance.WriterLock.acquire(testing.io, env.tmp.dir, "write.lock");
    lock.release(testing.io);

    // Running again is fine and skips what is unchanged.
    try m.start("notes");
    try waitIdle(&m);
    try testing.expectEqual(@as(u64, 2), (try m.lastResult(arena.allocator())).?.submitted);
}

test "unknown and disabled sources, a second start, and a held lock are refused" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    var m = Manager.init(testing.allocator, testing.io, env.options());
    defer m.deinit();

    try testing.expectError(error.UnknownSource, m.start("nope"));
    try testing.expectError(error.SourceDisabled, m.start("off"));
    try testing.expect(!m.cancel()); // nothing to cancel

    // Another process (here, another holder) has the writer lock.
    const held = try maintenance.WriterLock.acquire(testing.io, env.tmp.dir, "write.lock");
    try testing.expectError(error.LockHeld, m.start("notes"));
    held.release(testing.io);

    try m.start("notes");
    // While it runs (or right after), a second start must not run in parallel.
    if (m.start("notes")) |_| {} else |e| try testing.expect(e == error.AlreadyRunning or e == error.LockHeld);
    try waitIdle(&m);
}

test "a run that cannot open its connector's source fails cleanly" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    env.note_opts[0] = .{ .key = "path", .value = .{ .string = ".zig-cache/tmp/definitely-missing-dir" } };
    var m = Manager.init(testing.allocator, testing.io, env.options());
    defer m.deinit();
    try m.start("notes");
    try waitIdle(&m);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const last = (try m.lastResult(arena.allocator())).?;
    try testing.expectEqual(state_sqlite.JobState.failed, last.state);
    try testing.expectEqualStrings("InvalidSource", last.failure.?);
}

test "cancelling stops a run, and deinit waits for it" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    // Enough files that the run is still going when cancel arrives.
    for (0..300) |i| {
        var nb: [32]u8 = undefined;
        try env.notes.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&nb, "f{d:0>4}.txt", .{i}), .data = "some text for the file" });
    }
    var m = Manager.init(testing.allocator, testing.io, env.options());
    try m.start("notes");
    _ = m.cancel(); // honoured at the connector's next check, or the run had finished already
    m.deinit();
}
