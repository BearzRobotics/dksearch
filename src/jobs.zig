//! Runs imports and maintenance operations (check, backup, remove a source) on
//! behalf of a long-lived process (the administration interface), one at a
//! time, in the background.
//!
//! An import does what `dksearch import` does for one source, with the same rules:
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
const sourcestore = @import("sourcestore.zig");
const kiwix = @import("kiwix.zig");
const sourceedit = @import("sourceedit.zig");

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
    /// When set, the sources are read from here instead (so they can be
    /// replaced while the server runs); `sources` is then only the initial list.
    store: ?*sourcestore.Store = null,
    /// Where backups made from the interface go (a new subdirectory per
    /// backup). Null turns the backup operation off.
    backup_dir: ?[]const u8 = null,
    /// Where ZIM files downloaded from the Kiwix library go. Null turns downloads off.
    zim_dir: ?[]const u8 = null,
    /// The configuration file, so that a downloaded ZIM file can be added as a source (null: it is not).
    config_path: ?[]const u8 = null,
    /// How downloads behave (tests allow plain http to a local server).
    kiwix_options: kiwix.Options = .{},
    /// Documents of at least this many bytes also get their passages indexed (see `index_sqlite.OpenOptions`).
    chunk_min_bytes: u32 = 64 * 1024,
    /// Tests only: skip syncing, which is very slow on some disks.
    sync_off: bool = false,
};

/// What the manager can run.
pub const Op = enum {
    import,
    /// Verify the stored data (read-only).
    check,
    /// Copy state.db and content.db into a new directory under `backup_dir`.
    backup,
    /// Delete every document of a source.
    remove,
    /// Download a ZIM file from the Kiwix library into `zim_dir`.
    download,
};

/// What a download needs, copied by the manager.
pub const Download = struct {
    meta4_url: []const u8,
    file_name: []const u8,
    size: u64 = 0,
};

pub const StartError = error{
    UnknownSource,
    SourceDisabled,
    /// The operation needs a setting that is not configured (`backup_dir`).
    NotConfigured,
    /// A missing or unusable argument (the source name to remove).
    BadArgument,
    AlreadyRunning,
    /// The folder for downloads has less room than the file needs.
    NoSpace,
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
    op: Op = .import,
    /// The source name for an import or removal; empty otherwise.
    source: []const u8,
    /// A short result for display (a check report, the backup's location).
    summary: ?[]const u8 = null,
    state: state_sqlite.JobState,
    submitted: u64,
    rejected: u64,
    reasons: connector.ReasonCounts,
    failure: ?[]const u8,
    finished_at: document.Timestamp,
};

pub const Active = struct {
    op: Op = .import,
    source: []const u8,
    started_at: document.Timestamp,
    /// Documents submitted so far (live).
    submitted: u64,
    /// The connector's own measure of progress (see `Control.setProgress`);
    /// `progress_total` is 0 when it cannot tell how much there is.
    progress_done: u64 = 0,
    progress_total: u64 = 0,
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
        op: Op,
        source: []const u8, // owned
        started_at: document.Timestamp,
        control: *connector.Control,
    };

    const OwnedFinished = struct {
        op: Op,
        summary: ?[]const u8,
        source: []const u8,
        state: state_sqlite.JobState,
        submitted: u64,
        rejected: u64,
        reasons: connector.ReasonCounts,
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
        if (l.summary) |t| self.gpa.free(t);
    }

    /// The current sources.
    pub fn sources(self: *Manager) []const config.Source {
        return if (self.opts.store) |st| st.snapshot() else self.opts.sources;
    }

    /// Starts importing `name` in the background and returns at once.
    pub fn start(self: *Manager, name: []const u8) StartError!void {
        return self.startOp(.import, name);
    }

    /// Starts `op` in the background and returns at once. `arg` is the source
    /// name for `.import` and `.remove`, and unused otherwise.
    pub fn startOp(self: *Manager, op: Op, arg: ?[]const u8) StartError!void {
        return self.begin(op, arg, null);
    }

    /// Starts downloading a ZIM file in the background. It does not touch the data files, so it takes
    /// no writer lock, but only one background task runs at a time.
    pub fn startDownload(self: *Manager, d: Download) StartError!void {
        if (self.opts.zim_dir == null) return error.NotConfigured;
        if (!kiwix.validFileName(d.file_name) or d.meta4_url.len == 0 or d.meta4_url.len > 2048) return error.BadArgument;
        if (d.size > 0) if (self.spaceShort(d)) |_| return error.NoSpace;
        return self.begin(.download, d.file_name, d);
    }

    /// How much room the download folder lacks for `d` (what is already fetched of it counts), or null if there is
    /// enough or it cannot be told.
    pub fn spaceShort(self: *Manager, d: Download) ?u64 {
        const dir = self.opts.zim_dir orelse return null;
        const free = kiwix.freeBytes(dir) orelse return null;
        var have: u64 = 0;
        var pb: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&pb, "{s}/{s}.part", .{ dir, d.file_name })) |part| {
            if (Io.Dir.cwd().statFile(self.io, part, .{})) |st| have = st.size else |_| {}
        } else |_| {}
        const need = (if (d.size > have) d.size - have else 0) + kiwix.free_margin;
        return if (free >= need) null else need - free;
    }

    fn begin(self: *Manager, op: Op, arg: ?[]const u8, dl: ?Download) StartError!void {
        var source: config.Source = .{ .name = "", .kind = "" };
        switch (op) {
            .import => {
                const name = arg orelse return error.BadArgument;
                source = for (self.sources()) |s| {
                    if (std.mem.eql(u8, s.name, name)) break s;
                } else return error.UnknownSource;
                if (!source.enabled) return error.SourceDisabled;
            },
            .remove => {
                const name = arg orelse return error.BadArgument;
                if (name.len == 0 or name.len > 64) return error.BadArgument;
                source.name = name;
            },
            .backup => if (self.opts.backup_dir == null) return error.NotConfigured,
            .check => {},
            .download => source.name = arg orelse return error.BadArgument,
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.running != null) return error.AlreadyRunning;

        // The lock is taken here, so a conflict is reported to the caller,
        // and handed to the task, which releases it when the run ends.
        var lock: ?maintenance.WriterLock = null;
        if (op != .download) {
            var dir = Io.Dir.cwd().openDir(self.io, self.opts.data_dir, .{}) catch return error.DataDirUnavailable;
            defer dir.close(self.io);
            lock = maintenance.WriterLock.acquire(self.io, dir, "write.lock") catch |e| return switch (e) {
                error.Busy => error.LockHeld,
                error.Io => error.DataDirUnavailable,
            };
        }
        errdefer if (lock) |l| l.release(self.io);
        const owned_dl: ?*OwnedDownload = if (dl) |d| try OwnedDownload.create(self.gpa, d) else null;
        errdefer if (owned_dl) |o| o.destroy(self.gpa);

        const control = self.gpa.create(connector.Control) catch return error.OutOfMemory;
        errdefer self.gpa.destroy(control);
        control.* = .{};
        const owned_name = self.gpa.dupe(u8, source.name) catch return error.OutOfMemory;
        errdefer self.gpa.free(owned_name);

        self.running = .{ .op = op, .source = owned_name, .started_at = now(), .control = control };
        self.group.concurrent(self.io, task, .{ self, op, source, control, lock, owned_dl }) catch {
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
            .op = r.op,
            .source = try arena.dupe(u8, r.source),
            .started_at = r.started_at,
            .submitted = r.control.submitted.load(.monotonic),
            .progress_done = r.control.progress_done.load(.monotonic),
            .progress_total = r.control.progress_total.load(.monotonic),
        };
    }

    /// How the last run ended, if any ran since the process started.
    pub fn lastResult(self: *Manager, arena: Allocator) Allocator.Error!?Finished {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const l = self.last orelse return null;
        return .{
            .op = l.op,
            .summary = if (l.summary) |t| try arena.dupe(u8, t) else null,
            .source = try arena.dupe(u8, l.source),
            .state = l.state,
            .submitted = l.submitted,
            .rejected = l.rejected,
            .reasons = l.reasons,
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
        reasons: connector.ReasonCounts = @splat(0),
        failure: ?[]const u8 = null,
        summary: ?[]const u8 = null,
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
            .chunk_min_bytes = self.opts.chunk_min_bytes,
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
            .rights_override = source.rights,
            .now = now,
        });
        const r = runner.runImport(arena, &state, &pipe, inst.connector(), source.name, control, now) catch {
            self.fail(out, "the run could not be recorded (storage problem)");
            return;
        };
        out.state = r.state;
        out.submitted = r.submitted;
        out.rejected = r.rejected;
        out.reasons = r.reasons;
        if (r.failure) |f| out.failure = self.gpa.dupe(u8, f) catch null; // `f` lives in the arena
    }

    const OwnedDownload = struct {
        meta4_url: []u8,
        file_name: []u8,
        size: u64,

        fn create(gpa: Allocator, d: Download) error{OutOfMemory}!*OwnedDownload {
            const o = try gpa.create(OwnedDownload);
            errdefer gpa.destroy(o);
            const u = try gpa.dupe(u8, d.meta4_url);
            errdefer gpa.free(u);
            o.* = .{ .meta4_url = u, .file_name = try gpa.dupe(u8, d.file_name), .size = d.size };
            return o;
        }

        fn destroy(o: *OwnedDownload, gpa: Allocator) void {
            gpa.free(o.meta4_url);
            gpa.free(o.file_name);
            gpa.destroy(o);
        }
    };

    fn runDownload(self: *Manager, d: *OwnedDownload, control: *connector.Control, out: *Outcome) void {
        const dir = self.opts.zim_dir orelse return self.fail(out, "no ZIM folder is configured ([admin] zim_dir)");
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const path = kiwix.download(self.gpa, self.io, arena_state.allocator(), .{
            .meta4_url = d.meta4_url,
            .dest_dir = dir,
            .file_name = d.file_name,
            .size = d.size,
        }, control, self.opts.kiwix_options) catch |e| {
            switch (e) {
                error.Cancelled => {
                    out.state = .cancelled;
                    self.summaryPrint(out, "Stopped. The part already fetched stays as {s}.part and the next download of the same file continues from it.", .{d.file_name});
                },
                error.Stalled => self.fail(out, "nothing arrived for a minute, so the download stopped; starting it again continues where it left off"),
                error.Exists => self.fail(out, "that file is already in the ZIM folder"),
                error.Checksum => self.fail(out, "the downloaded file does not match the checksum the library published, so it was discarded"),
                error.Refused => self.fail(out, "the library or its mirror refused the request"),
                error.Tls => self.fail(out, "the secure connection failed (certificate or handshake)"),
                error.Io => self.fail(out, "cannot write in the ZIM folder (does it exist, is there room, may the server write there?)"),
                error.BadCatalog, error.BadName => self.fail(out, "the library's answer for this file cannot be trusted (no checksum, or the name or size differs)"),
                error.NotAvailable => self.fail(out, "this build has no network support (-Dcrawler)"),
                error.OutOfMemory => self.fail(out, "out of memory"),
                else => self.fail(out, "the download failed (network problem); starting it again continues where it left off"),
            }
            return;
        };
        out.state = .completed;
        if (self.addDownloadedSource(arena_state.allocator(), path, d.file_name)) |name| {
            self.summaryPrint(out, "Saved and verified: {s}. Added it as the source \"{s}\"; import it to search it (it is a large file: the first import takes a while).", .{ path, name });
        } else {
            self.summaryPrint(out, "Saved and verified: {s}. Add it as a source of kind zim (Sources, then Add a source) to search it.", .{path});
        }
    }

    /// Adds `path` to the configuration as a `zim` source (best effort: null when this server has no configuration
    /// file to edit, or the edit is refused). The name comes from the file name, made unique if need be.
    fn addDownloadedSource(self: *Manager, arena: Allocator, path: []const u8, file_name: []const u8) ?[]const u8 {
        const cfg_path = self.opts.config_path orelse return null;
        const store = self.opts.store orelse return null;
        const text = Io.Dir.cwd().readFileAlloc(self.io, cfg_path, arena, .limited(16 * 1024 * 1024)) catch return null;
        var nbuf: [80]u8 = undefined;
        const base = kiwix.sourceNameFor(&nbuf, file_name);
        var name: []const u8 = arena.dupe(u8, base) catch return null;
        var n: u32 = 1;
        while (n < 100) : (n += 1) {
            var taken = false;
            for (store.snapshot()) |s| if (std.mem.eql(u8, s.name, name)) {
                taken = true;
            };
            if (!taken) break;
            name = std.fmt.allocPrint(arena, "{s}-{d}", .{ base, n + 1 }) catch return null;
        }
        const options = std.fmt.allocPrint(arena, "path = \"{s}\"\n", .{path}) catch return null;
        var problem: sourceedit.Problem = .{};
        const new_text = sourceedit.apply(arena, text, .{ .save = .{ .original = null, .spec = .{ .name = name, .kind = "zim", .options = options } } }, &problem) catch return null;
        sourceedit.writeFile(self.io, arena, cfg_path, new_text) catch return null;
        var diag: config.Diagnostic = .{};
        const cfg = config.loadFromSlice(self.gpa, cfg_path, new_text, &diag) catch return null;
        store.replace(cfg) catch return null;
        return name;
    }

    fn task(self: *Manager, op: Op, source: config.Source, control: *connector.Control, lock: ?maintenance.WriterLock, dl: ?*OwnedDownload) Io.Cancelable!void {
        // Each runner sets the state on every path; `failed` is the safe default.
        var outcome: Outcome = .{ .state = .failed };
        switch (op) {
            .import => runOne(self, source, control, &outcome),
            .check => runCheck(self, control, &outcome),
            .backup => runBackup(self, control, &outcome),
            .remove => runRemove(self, source.name, control, &outcome),
            .download => runDownload(self, dl.?, control, &outcome),
        }
        if (dl) |d| d.destroy(self.gpa);
        if (lock) |l| l.release(self.io);
        self.record(op, source.name, outcome);
    }

    fn summaryPrint(self: *Manager, out: *Outcome, comptime fmt: []const u8, args: anytype) void {
        out.summary = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
    }

    /// Verifies the stored data, like `dksearch check`.
    fn runCheck(self: *Manager, control: *connector.Control, out: *Outcome) void {
        const r = maintenance.checkWith(self.gpa, self.io, .{ .index = self.opts.index_path, .state = self.opts.state_path, .content = self.opts.content_path }, control) catch {
            self.fail(out, "out of memory");
            return;
        };
        if (r.cancelled) {
            out.state = .cancelled;
            self.summaryPrint(out, "Stopped before it finished; {d} of {d} documents checked.", .{ control.progress_done.load(.monotonic), r.documents });
            return;
        }
        out.submitted = r.documents;
        var index_note: [96]u8 = undefined;
        const index_text = if (r.indexed) |n|
            (if (r.cross_checked and n != r.documents)
                std.fmt.bufPrint(&index_note, "{s}: {d} documents, which does not match the records (run `dksearch rebuild`)", .{ fileWord(r.index), n }) catch fileWord(r.index)
            else
                std.fmt.bufPrint(&index_note, "{s}: {d} documents", .{ fileWord(r.index), n }) catch fileWord(r.index))
        else
            fileWord(r.index);
        self.summaryPrint(out, "state.db {s}: {d} documents. content.db {s}: {d} stored texts. index.db {s}. Texts checked against their records: {d} damaged, {d} records without text, {d} texts no record refers to.", .{
            fileWord(r.state),
            r.documents,
            fileWord(r.content),
            r.texts,
            index_text,
            r.corrupt_texts,
            r.without_text,
            r.orphan_texts,
        });
        if (r.healthy()) {
            out.state = .completed;
        } else {
            out.state = .failed;
            out.failure = self.gpa.dupe(u8, "the check found damage; see the summary. Restore from a backup with `dksearch restore`") catch null;
        }
    }

    fn fileWord(f: maintenance.FileState) []const u8 {
        return switch (f) {
            .absent => "absent",
            .ok => "ok",
            .damaged => "DAMAGED",
            .newer_version => "written by a newer version",
            .needs_upgrade => "needs an upgrade",
            .unreadable => "UNREADABLE",
        };
    }

    /// Writes verified copies of state.db and content.db into a new
    /// directory under `backup_dir`, like `dksearch backup`.
    fn runBackup(self: *Manager, control: *connector.Control, out: *Outcome) void {
        const base = self.opts.backup_dir orelse {
            self.fail(out, "no backup directory is configured ([admin] backup_dir)");
            return;
        };
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const t = now();
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(t, 0)) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        const dir_path = std.fmt.allocPrint(a, "{s}/dksearch-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{ base, yd.year, @backingInt(md.month), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch {
            self.fail(out, "out of memory");
            return;
        };
        const dest_state = std.fmt.allocPrintSentinel(a, "{s}/state.db", .{dir_path}, 0) catch return self.fail(out, "out of memory");
        const dest_content = std.fmt.allocPrintSentinel(a, "{s}/content.db", .{dir_path}, 0) catch return self.fail(out, "out of memory");
        for ([_][:0]const u8{ dest_state, dest_content }) |p| {
            if (Io.Dir.cwd().access(self.io, p, .{})) |_| {
                self.fail(out, "this backup directory already exists (two backups in the same second?)");
                return;
            } else |_| {}
        }
        Io.Dir.cwd().createDirPath(self.io, dir_path) catch {
            self.fail(out, "cannot create the backup directory (check backup_dir and its permissions)");
            return;
        };
        // state.db first, then content.db: see docs/decisions/0009.
        control.setProgress(0, 2);
        maintenance.backupFile(self.opts.state_path, dest_state, !self.opts.sync_off) catch {
            self.fail(out, "backing up state.db failed; remove the partial directory before retrying");
            return;
        };
        control.setProgress(1, 2);
        if (control.isCancelled()) {
            out.state = .cancelled;
            self.summaryPrint(out, "Stopped after state.db; {s} holds an incomplete backup: delete it.", .{dir_path});
            return;
        }
        maintenance.backupFile(self.opts.content_path, dest_content, !self.opts.sync_off) catch {
            self.fail(out, "backing up content.db failed; remove the partial directory before retrying");
            return;
        };
        control.setProgress(2, 2);
        out.state = .completed;
        self.summaryPrint(out, "Verified copies of state.db and content.db are in {s}. The index is not copied; `dksearch restore` recreates it.", .{dir_path});
    }

    /// Deletes every document of `name`, like `dksearch remove --yes`.
    fn runRemove(self: *Manager, name: []const u8, control: *connector.Control, out: *Outcome) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var state = state_sqlite.SqliteStateStore.open(self.gpa, self.opts.state_path, self.opts.sync_off) catch return self.fail(out, "cannot open state.db");
        defer state.close();
        var content = content_sqlite.SqliteContentStore.open(self.gpa, self.opts.content_path, self.opts.sync_off) catch return self.fail(out, "cannot open content.db");
        defer content.close();
        var index = index_sqlite.SqliteIndex.open(self.opts.index_path, .{
            .tokenizer = self.opts.tokenizer,
            .sync = if (self.opts.sync_off) .off else .normal,
            .chunk_min_bytes = self.opts.chunk_min_bytes,
        }) catch return self.fail(out, "cannot open index.db (if the tokenizer changed, run `dksearch rebuild`)");
        defer index.close();
        var pipe = pipeline.Pipeline.init(content.store(), state.documents(), index.indexer(), .{ .now = now });
        const r = runner.removeSource(arena, &state, &pipe, name, control) catch {
            self.fail(out, "the removal could not be completed (storage problem)");
            return;
        };
        out.submitted = r.removed;
        if (r.complete) {
            out.state = .completed;
            self.summaryPrint(out, "Removed {d} documents of {s} and forgot its import history.", .{ r.removed, name });
        } else {
            out.state = if (control.isCancelled()) .cancelled else .failed;
            self.summaryPrint(out, "Removed {d} documents of {s} before it stopped; run it again to finish.", .{ r.removed, name });
        }
    }

    fn record(self: *Manager, op: Op, name: []const u8, o: Outcome) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.last) |old| self.freeFinished(old);
        const owned_name = self.gpa.dupe(u8, name) catch null;
        if (owned_name == null) {
            // Out of memory: nothing can be remembered; do not leak the text.
            if (o.failure) |f| self.gpa.free(f);
            if (o.summary) |t| self.gpa.free(t);
        }
        self.last = if (owned_name == null) null else .{
            .op = op,
            .summary = o.summary, // ownership moves here
            .source = owned_name.?,
            .state = o.state,
            .submitted = o.submitted,
            .rejected = o.rejected,
            .reasons = o.reasons,
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

test "check, backup and remove run as operations and report what they did" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    var backups = testing.tmpDir(.{});
    defer backups.cleanup();
    var bpath: [160]u8 = undefined;
    const bdir = try std.fmt.bufPrint(&bpath, ".zig-cache/tmp/{s}", .{backups.sub_path});
    var opts = env.options();
    opts.backup_dir = bdir;
    var m = Manager.init(testing.allocator, testing.io, opts);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try m.start("notes");
    try waitIdle(&m);

    // Check: healthy data completes, with a readable summary.
    try m.startOp(.check, null);
    try waitIdle(&m);
    var last = (try m.lastResult(a)).?;
    try testing.expectEqual(Op.check, last.op);
    try testing.expectEqual(state_sqlite.JobState.completed, last.state);
    try testing.expect(std.mem.indexOf(u8, last.summary.?, "2 documents") != null);

    // Backup: a new folder under backup_dir holds two verified databases.
    try m.startOp(.backup, null);
    try waitIdle(&m);
    last = (try m.lastResult(a)).?;
    try testing.expectEqual(Op.backup, last.op);
    try testing.expectEqual(state_sqlite.JobState.completed, last.state);
    var it_dir = try backups.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer it_dir.close(testing.io);
    var found: u32 = 0;
    var it = it_dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .directory) continue;
        found += 1;
        try testing.expect(std.mem.startsWith(u8, entry.name, "dksearch-"));
        var sub = try it_dir.openDir(testing.io, entry.name, .{});
        defer sub.close(testing.io);
        _ = try sub.statFile(testing.io, "state.db", .{});
        _ = try sub.statFile(testing.io, "content.db", .{});
    }
    try testing.expectEqual(@as(u32, 1), found);

    // Remove: needs the name; documents and history go.
    try testing.expectError(error.BadArgument, m.startOp(.remove, null));
    try m.startOp(.remove, "notes");
    try waitIdle(&m);
    last = (try m.lastResult(a)).?;
    try testing.expectEqual(Op.remove, last.op);
    try testing.expectEqual(state_sqlite.JobState.completed, last.state);
    try testing.expectEqual(@as(u64, 2), last.submitted);
    var index = try index_sqlite.SqliteIndex.open(opts.index_path, .{ .sync = .off });
    defer index.close();
    try testing.expectEqual(@as(u64, 0), try index.count());
}

test "backup without a backup directory is refused, and a check can be cancelled" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    var m = Manager.init(testing.allocator, testing.io, env.options());
    defer m.deinit();
    try testing.expectError(error.NotConfigured, m.startOp(.backup, null));
    try testing.expectError(error.BadArgument, m.startOp(.import, null));
    try testing.expectError(error.UnknownSource, m.startOp(.import, "nope"));
}

test "a downloaded ZIM file is added to the configuration as a source with a unique name, and a download without room is refused" {
    var env: Env = undefined;
    try env.init();
    defer env.deinit();
    const cfg_text = "# mine\n";
    try env.tmp.dir.writeFile(testing.io, .{ .sub_path = "cfg.toml", .data = cfg_text });
    var cp: [220]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&cp, "{s}/cfg.toml", .{env.data_dir[0..env.data_len]});
    var d: config.Diagnostic = .{};
    const cfg0 = try config.loadFromSlice(testing.allocator, cfg_path, cfg_text, &d);
    var store = sourcestore.Store.init(testing.allocator, testing.io, cfg0.sources);
    defer store.deinit();
    var cfg_mut = cfg0;
    defer cfg_mut.deinit();
    var opts = env.options();
    opts.store = &store;
    opts.config_path = cfg_path;
    opts.zim_dir = env.data_dir[0..env.data_len];
    var m = Manager.init(testing.allocator, testing.io, opts);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = m.addDownloadedSource(a, "/data/zim/wikipedia_en_all_maxi_2026-01.zim", "wikipedia_en_all_maxi_2026-01.zim").?;
    try testing.expectEqualStrings("wikipedia-en-all-maxi", first);
    const second = m.addDownloadedSource(a, "/data/zim/wikipedia_en_all_maxi_2026-02.zim", "wikipedia_en_all_maxi_2026-02.zim").?;
    try testing.expectEqualStrings("wikipedia-en-all-maxi-2", second);
    const file = try env.tmp.dir.readFileAlloc(testing.io, "cfg.toml", a, .limited(8192));
    try testing.expect(std.mem.indexOf(u8, file, "# mine") != null);
    try testing.expect(std.mem.indexOf(u8, file, "kind = \"zim\"") != null and std.mem.indexOf(u8, file, "wikipedia_en_all_maxi_2026-02.zim") != null);
    try testing.expectEqual(@as(usize, 2), store.snapshot().len); // and it is current at once
    // Without a configuration file nothing is added.
    var plain = Manager.init(testing.allocator, testing.io, env.options());
    defer plain.deinit();
    try testing.expect(plain.addDownloadedSource(a, "/x.zim", "x.zim") == null);

    // A download that cannot fit is refused before anything starts; one of unknown size is not.
    if (kiwix.freeBytes(env.data_dir[0..env.data_len]) != null) {
        try testing.expectError(error.NoSpace, m.startDownload(.{ .meta4_url = "https://download.kiwix.org/zim/a.zim.meta4", .file_name = "a_2026-01.zim", .size = 1 << 60 }));
        try testing.expect(m.spaceShort(.{ .meta4_url = "x", .file_name = "a.zim", .size = 1 << 60 }).? > 0);
        try testing.expect(m.spaceShort(.{ .meta4_url = "x", .file_name = "a.zim", .size = 1000 }) == null);
    }
}
