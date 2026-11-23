//! Runs one import: drives a connector into the ingestion pipeline and keeps
//! a durable record of the run.
//!
//! The runner owns what is common to every connector and none of what is
//! specific to one: it finds the resume point, starts a job record, gives the
//! connector a `Sink` that feeds the pipeline and saves checkpoints, and
//! records how the run ended. Connectors stay unaware of stores and jobs.
//!
//! Resuming follows `SqliteStateStore.resumePoint`: after a run that did not
//! complete and saved a checkpoint, the next run of the same source continues
//! from it; after a completed run (or one that never saved a checkpoint) it
//! starts over, and the pipeline's duplicate detection skips what has not
//! changed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const doc = @import("document.zig");
const connector_mod = @import("connector.zig");
const pipeline = @import("pipeline.zig");
const state_sqlite = @import("state_sqlite.zig");
const storage = @import("storage.zig");
const domainlist = @import("domainlist.zig");

pub const Result = struct {
    job_id: i64,
    state: state_sqlite.JobState,
    /// Documents the pipeline accepted (added, updated or unchanged).
    submitted: u64,
    /// Items not imported: documents the pipeline refused plus items the
    /// connector itself refused (too large, malformed, unreadable).
    rejected: u64,
    /// How many of `rejected` had which reason, for connectors that say.
    reasons: connector_mod.ReasonCounts,
    /// Where the next run would resume, if the run did not complete.
    checkpoint: ?[]const u8,
    /// Why a failed run failed (an error name or reason; not for end users to parse).
    failure: ?[]const u8,
};

pub const Error = error{
    OutOfMemory,
    /// The job record could not be written or updated. The import may have
    /// partly run; check the state store.
    StateUnavailable,
};

/// Largest number of documents written between commits when a connector does
/// not checkpoint often. Bounds how much a crash can lose and how big a
/// transaction grows.
const max_batch = 1000;

/// Feeds the pipeline and records progress for one job.
///
/// Documents are written in batches: one sync per store per batch instead of
/// one per document. A batch is committed (content, then index, then
/// records; see `Pipeline.commitBatch`) and only after that is the
/// connector's position saved, so a saved position never points past
/// durable work.
const JobSink = struct {
    pipe: *pipeline.Pipeline,
    state: *state_sqlite.SqliteStateStore,
    job: i64,
    control: *connector_mod.Control,
    submitted: u64 = 0,
    /// Rejected by the pipeline. The connector's own refusals are in `control`.
    rejected: u64 = 0,
    /// Documents written since the last commit.
    pending: u32 = 0,
    /// A commit failed during the run. After that the connector's own idea of
    /// its position covers documents that were lost, so it must not be used.
    commit_failed: bool = false,
    /// Counters as of the last successful commit.
    committed_submitted: u64 = 0,
    committed_rejected: u64 = 0,
    /// How many of the control's skip examples are already stored.
    samples_saved: usize = 0,
    /// Latest position the connector reported; borrowed copy in `arena`.
    last_checkpoint: ?[]const u8 = null,
    arena: Allocator,

    fn sink(self: *JobSink) connector_mod.Sink {
        return .{ .ptr = self, .vtable = &.{ .submit = submit, .checkpoint = checkpoint } };
    }

    fn submit(ptr: *anyopaque, d: doc.Document) connector_mod.Sink.Error!void {
        const self: *JobSink = @ptrCast(@alignCast(ptr));
        // If a batch cannot even be opened, nothing can be made durable: stop.
        self.pipe.beginBatch() catch return error.Stopped;
        self.pipe.submit(d) catch |e| {
            if (e == error.Rejected) self.rejected += 1;
            return e;
        };
        self.submitted += 1;
        self.pending += 1;
        if (self.pending >= max_batch) try self.flush(null);
    }

    /// Commits the open batch, then records progress (and `position`, if given).
    fn flush(self: *JobSink, position: ?[]const u8) connector_mod.Sink.Error!void {
        self.pipe.commitBatch() catch {
            self.pipe.abortBatch();
            self.commit_failed = true;
            return error.Stopped;
        };
        self.pending = 0;
        self.committed_submitted = self.submitted;
        self.committed_rejected = self.totalRejected();
        // Not being able to record progress means a crash would lose work we
        // think is safe, so treat it like a full disk: stop.
        var rb: [reasons_text_max]u8 = undefined;
        self.state.saveCheckpoint(self.job, position, self.submitted, self.totalRejected(), reasonsText(&rb, self.control.reasonCounts())) catch return error.Stopped;
        if (position) |p| self.last_checkpoint = self.arena.dupe(u8, p) catch return error.OutOfMemory;
        self.saveSamples();
    }

    /// Stores the skip examples collected since the last call. Examples are a convenience: failing to store
    /// them never stops a run.
    fn saveSamples(self: *JobSink) void {
        const total = self.control.sampleTotal();
        if (total <= self.samples_saved) return;
        const fresh = self.control.samplesFrom(self.arena, self.samples_saved) catch return;
        self.state.addSkips(self.job, fresh) catch return;
        self.samples_saved = total;
    }

    fn totalRejected(self: *const JobSink) u64 {
        return self.rejected + self.control.rejected.load(.monotonic);
    }

    fn checkpoint(ptr: *anyopaque, position: []const u8) connector_mod.Sink.Error!void {
        const self: *JobSink = @ptrCast(@alignCast(ptr));
        try self.flush(position);
    }
};

const reasons_text_max = 256;

/// The reasons as stored text, or null if there are none.
fn reasonsText(buf: *[reasons_text_max]u8, counts: connector_mod.ReasonCounts) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    connector_mod.formatReasons(counts, &w) catch return null;
    return if (w.end == 0) null else buf[0..w.end];
}

/// Runs `connector` for `source` (the configured source name, which is what
/// jobs and resume points are keyed by) until it finishes, is cancelled
/// through `control`, or fails. Strings in the result are allocated from `arena`.
pub fn runImport(
    arena: Allocator,
    state: *state_sqlite.SqliteStateStore,
    pipe: *pipeline.Pipeline,
    conn: connector_mod.Connector,
    source: []const u8,
    control: *connector_mod.Control,
    now: *const fn () doc.Timestamp,
) Error!Result {
    const kind = conn.info().kind;
    const resume_from = state.resumePoint(arena, source) catch |e| return stateError(e);
    const job = state.startJob(source, kind, now()) catch return error.StateUnavailable;

    var js: JobSink = .{ .pipe = pipe, .state = state, .job = job, .control = control, .arena = arena };

    var final: state_sqlite.JobState = .completed;
    var failure: ?[]const u8 = null;
    var checkpoint: ?[]const u8 = null;

    const ran = conn.run(js.sink(), control, resume_from);

    // Whatever happened, make the last batch durable before looking at the
    // outcome, so a position the connector reports is never ahead of the data.
    if (!js.commit_failed) {
        pipe.commitBatch() catch {
            pipe.abortBatch();
            js.commit_failed = true;
        };
    }

    if (js.commit_failed) {
        // The last batch is lost. Report only what is durable.
        final = .failed;
        failure = "the final batch could not be committed (storage unavailable or full)";
        checkpoint = js.last_checkpoint;
        js.submitted = js.committed_submitted;
        js.rejected = js.committed_rejected -| control.rejected.load(.monotonic);
    } else if (ran) |outcome| {
        checkpoint = outcome.checkpoint orelse js.last_checkpoint;
        if (outcome.interrupted) {
            if (control.isCancelled()) {
                // Stopped by the server shutting down: it is to be resumed (the scheduler does so); stopped by a person: not.
                final = if (control.stopping.load(.acquire)) .interrupted else .cancelled;
            } else {
                final = .failed;
                failure = "stopped by the ingestion pipeline (storage full or shutting down)";
            }
        }
    } else |e| switch (e) {
        error.OutOfMemory => {
            pipe.abortBatch();
            state.finishJob(job, .failed, now(), "out of memory") catch {};
            return error.OutOfMemory;
        },
        else => {
            final = .failed;
            failure = @errorName(e);
            checkpoint = js.last_checkpoint;
        },
    }

    // Final counters, plus the last position when the connector handed one back.
    var rb: [reasons_text_max]u8 = undefined;
    const reasons = control.reasonCounts();
    state.saveCheckpoint(job, checkpoint, js.submitted, js.totalRejected(), reasonsText(&rb, reasons)) catch return error.StateUnavailable;
    js.saveSamples();
    state.finishJob(job, final, now(), failure) catch return error.StateUnavailable;

    return .{
        .job_id = job,
        .state = final,
        .submitted = js.submitted,
        .rejected = js.totalRejected(),
        .reasons = reasons,
        // A completed run has nothing to resume from.
        .checkpoint = if (final == .completed) null else checkpoint,
        .failure = failure,
    };
}

pub const RemoveResult = struct {
    removed: u64 = 0,
    /// False if cancelled or stopped by an error before every document was handled.
    complete: bool = true,
};

const page = 1000;

/// Removes every document of `source` (stores and index), page by page, each
/// page committed as one batch. Interrupting it, or a crash, leaves the rest
/// for a repeat run: records are removed last, so they still list what is left.
/// Also forgets the source's job history once nothing is left.
pub fn removeSource(
    arena: Allocator,
    state: *state_sqlite.SqliteStateStore,
    pipe: *pipeline.Pipeline,
    source: []const u8,
    control: *connector_mod.Control,
) Error!RemoveResult {
    var result: RemoveResult = .{};
    while (true) {
        if (control.isCancelled()) {
            result.complete = false;
            return result;
        }
        // Documents are removed as they are listed, so each page is the first.
        const entries = pipe.docs.list(arena, source, null, page) catch |e| return stateError(e);
        if (entries.len == 0) break;
        const done = removeEntries(pipe, entries) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            result.complete = false;
            return result;
        };
        result.removed += done;
    }
    state.forgetSource(source) catch return error.StateUnavailable;
    return result;
}

/// The documents whose address is on the blocked list (what a search never shows), found by `removeBlocked`.
const BlockedScan = struct {
    arena: Allocator,
    lists: *const domainlist.Lists,
    ids: std.ArrayList(doc.Id) = .empty,
    seen: u64 = 0,

    fn visit(ptr: *anyopaque, rec: storage.Record) storage.Error!void {
        const self: *BlockedScan = @ptrCast(@alignCast(ptr));
        self.seen += 1;
        if (self.lists.blocksUrl(rec.meta.canonical_url)) self.ids.append(self.arena, rec.id) catch return error.OutOfMemory;
    }
};

pub const BlockedResult = struct { seen: u64, matched: u64, removed: u64 = 0, complete: bool = true };

/// Removes every document whose address is on the blocked list, in batches of `page` (the stores and the index), or only
/// counts them when `apply` is false. The records are read first and removed afterwards, since the store must not change
/// during a visit. A repeat run finishes what an interrupted one left.
pub fn removeBlocked(
    arena: Allocator,
    pipe: *pipeline.Pipeline,
    lists: *const domainlist.Lists,
    apply: bool,
    control: *connector_mod.Control,
) Error!BlockedResult {
    var scan: BlockedScan = .{ .arena = arena, .lists = lists };
    pipe.docs.forEach(.{ .ptr = &scan, .visit = BlockedScan.visit }) catch |e| return stateError(e);
    var out: BlockedResult = .{ .seen = scan.seen, .matched = scan.ids.items.len };
    if (!apply) return out;
    var at: usize = 0;
    while (at < scan.ids.items.len) {
        if (control.isCancelled()) {
            out.complete = false;
            return out;
        }
        const end = @min(at + page, scan.ids.items.len);
        pipe.beginBatch() catch |e| return stateError(e);
        for (scan.ids.items[at..end]) |id| pipe.remove(id) catch |e| {
            pipe.abortBatch();
            if (e == error.OutOfMemory) return error.OutOfMemory;
            out.complete = false;
            return out;
        };
        pipe.commitBatch() catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            out.complete = false;
            return out;
        };
        out.removed += end - at;
        at = end;
    }
    return out;
}

/// Removes `entries` as one batch.
fn removeEntries(pipe: *pipeline.Pipeline, entries: []const storage.Entry) !u64 {
    try pipe.beginBatch();
    errdefer pipe.abortBatch();
    for (entries) |e| try pipe.remove(e.id);
    try pipe.commitBatch();
    return entries.len;
}

/// Removes the documents of `source` that its connector says have left the
/// source. Only items answered `.gone` are removed; `.unknown` is kept. Call
/// it after a run that completed, since an unreadable source must not look
/// like an empty one (a connector answers `.unknown` then, as a second guard).
pub fn pruneSource(
    arena: Allocator,
    pipe: *pipeline.Pipeline,
    conn: connector_mod.Connector,
    source: []const u8,
    control: *connector_mod.Control,
) Error!RemoveResult {
    var result: RemoveResult = .{};
    var cursor: ?[]const u8 = null;
    while (true) {
        if (control.isCancelled()) {
            result.complete = false;
            return result;
        }
        const entries = pipe.docs.list(arena, source, cursor, page) catch |e| return stateError(e);
        if (entries.len == 0) break;
        cursor = entries[entries.len - 1].source_id;
        var gone: std.ArrayList(storage.Entry) = .empty;
        for (entries) |e| {
            if (conn.exists(e.source_id) == .gone) gone.append(arena, e) catch return error.OutOfMemory;
        }
        if (gone.items.len == 0) continue;
        const done = removeEntries(pipe, gone.items) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            result.complete = false;
            return result;
        };
        result.removed += done;
    }
    return result;
}

fn stateError(e: anyerror) Error {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.StateUnavailable;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const memory = @import("memory.zig");
const index_sqlite = @import("index_sqlite.zig");
const indexer = @import("indexer.zig");

fn fixedNow() doc.Timestamp {
    return 1_000;
}

/// Emits `items` in order. Position is the item number, reported through
/// the sink every `every` items. Can fail after `fail_at` items.
const ScriptedConnector = struct {
    items: []const []const u8,
    every: usize = 2,
    fail_at: ?usize = null,
    fail_with: connector_mod.RunError = error.SourceFailed,
    seen_resume: ?usize = null,
    /// Items it refuses itself, before the others.
    skips: []const []const u8 = &.{},
    buf: [20]u8 = undefined,

    fn info(_: *anyopaque) connector_mod.Info {
        return .{ .kind = "scripted", .requires_network = false, .resumable = true };
    }

    fn run(ptr: *anyopaque, sink: connector_mod.Sink, control: *connector_mod.Control, resume_from: ?[]const u8) connector_mod.RunError!connector_mod.Outcome {
        const self: *ScriptedConnector = @ptrCast(@alignCast(ptr));
        var i: usize = 0;
        for (self.skips) |s| control.rejectAt(.no_text, s);
        if (resume_from) |r| {
            i = std.fmt.parseInt(usize, r, 10) catch return error.InvalidSource;
            self.seen_resume = i;
        }
        while (i < self.items.len) : (i += 1) {
            if (control.isCancelled()) return self.stopped(i);
            if (self.fail_at) |f| if (i == f) return self.fail_with;
            sink.submit(.{ .connector = "scripted", .source_id = self.items[i], .title = self.items[i], .text = self.items[i] }) catch |e| switch (e) {
                error.Rejected => {},
                error.Stopped => return self.stopped(i),
                error.OutOfMemory => return error.OutOfMemory,
            };
            if ((i + 1) % self.every == 0) {
                const pos = std.fmt.bufPrint(&self.buf, "{d}", .{i + 1}) catch unreachable;
                sink.checkpoint(pos) catch |e| switch (e) {
                    error.Stopped => return self.stopped(i + 1),
                    else => return error.SourceFailed,
                };
            }
        }
        return .{};
    }

    fn stopped(self: *ScriptedConnector, at: usize) connector_mod.Outcome {
        return .{ .interrupted = true, .checkpoint = std.fmt.bufPrint(&self.buf, "{d}", .{at}) catch unreachable };
    }

    fn connector(self: *ScriptedConnector) connector_mod.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run } };
    }
};

const Rig = struct {
    state: state_sqlite.SqliteStateStore,
    content: memory.MemoryContentStore,
    docs: memory.MemoryDocumentStore,
    idx: index_sqlite.SqliteIndex,
    pipe: pipeline.Pipeline,
    arena: std.heap.ArenaAllocator,

    fn init(r: *Rig) !void {
        r.state = try state_sqlite.SqliteStateStore.open(testing.allocator, ":memory:", true);
        r.content = .init(testing.allocator);
        r.docs = .init(testing.allocator);
        r.idx = try index_sqlite.SqliteIndex.open(":memory:", .{});
        r.pipe = .init(r.content.store(), r.docs.store(), r.idx.indexer(), .{ .now = fixedNow });
        r.arena = .init(testing.allocator);
    }
    fn deinit(r: *Rig) void {
        r.arena.deinit();
        r.idx.close();
        r.docs.deinit();
        r.content.deinit();
        r.state.close();
    }
    fn run(r: *Rig, c: *ScriptedConnector, control: *connector_mod.Control) !Result {
        return Rig.runNamed(r, c, "src", control);
    }
    fn runNamed(r: *Rig, c: *ScriptedConnector, source: []const u8, control: *connector_mod.Control) !Result {
        return runImport(r.arena.allocator(), &r.state, &r.pipe, c.connector(), source, control, fixedNow);
    }
};

test "a complete run feeds the pipeline and records a finished job" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var c: ScriptedConnector = .{ .items = &.{ "a", "b", "c" } };
    var ctl: connector_mod.Control = .{};

    const r = try rig.run(&c, &ctl);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    try testing.expectEqual(@as(u64, 3), r.submitted);
    try testing.expectEqual(@as(u64, 0), r.rejected);
    try testing.expect(r.checkpoint == null);
    try testing.expectEqual(@as(usize, 3), rig.docs.count());
    try testing.expectEqual(@as(u64, 3), try rig.idx.count());

    const job = (try rig.state.getJob(rig.arena.allocator(), r.job_id)).?;
    try testing.expectEqual(state_sqlite.JobState.completed, job.state);
    try testing.expectEqualStrings("scripted", job.connector);
    try testing.expectEqualStrings("src", job.source);
    try testing.expectEqual(@as(?doc.Timestamp, 1_000), job.finished_at);
    try testing.expectEqual(@as(u64, 3), job.submitted);
    // Nothing to resume once a run has completed.
    try testing.expect((try rig.state.resumePoint(rig.arena.allocator(), "src")) == null);
}

test "removeBlocked counts the documents of blocked domains, and removes them from every store only when asked" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    const a = rig.arena.allocator();
    const urls = [_][]const u8{ "https://bad.example/a", "https://www.bad.example/b", "https://good.example/c", "https://other.example/d" };
    for (urls, 0..) |u, i| {
        var name_buf: [8]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "d{d}", .{i});
        try rig.pipe.submit(.{ .connector = if (i % 2 == 0) "one" else "two", .source_id = name, .canonical_url = u, .title = name, .text = "some words here" });
    }
    try testing.expectEqual(@as(usize, 4), rig.docs.count());
    var lists: domainlist.Lists = .{};
    _ = try lists.blocked.add(a, "bad.example");
    var ctl: connector_mod.Control = .{};

    // A dry run only counts (the subdomain is under the domain).
    const dry = try removeBlocked(a, &rig.pipe, &lists, false, &ctl);
    try testing.expectEqual(@as(u64, 4), dry.seen);
    try testing.expectEqual(@as(u64, 2), dry.matched);
    try testing.expectEqual(@as(u64, 0), dry.removed);
    try testing.expectEqual(@as(usize, 4), rig.docs.count());

    const real = try removeBlocked(a, &rig.pipe, &lists, true, &ctl);
    try testing.expectEqual(@as(u64, 2), real.removed);
    try testing.expect(real.complete);
    try testing.expectEqual(@as(usize, 2), rig.docs.count());
    try testing.expectEqual(@as(usize, 2), rig.content.count());
    try testing.expectEqual(@as(u64, 2), try rig.idx.count());
    // A repeat finds nothing more.
    try testing.expectEqual(@as(u64, 0), (try removeBlocked(a, &rig.pipe, &lists, true, &ctl)).matched);
}

test "rejected documents are counted and do not stop the run" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var c: ScriptedConnector = .{ .items = &.{ "a", "", "c" } }; // empty text is invalid
    var ctl: connector_mod.Control = .{};
    const r = try rig.run(&c, &ctl);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    try testing.expectEqual(@as(u64, 2), r.submitted);
    try testing.expectEqual(@as(u64, 1), r.rejected);
}

test "examples of what a connector refused are kept with the job, a few per reason" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var many: [30][]const u8 = undefined;
    for (&many, 0..) |*m, i| m.* = if (i % 2 == 0) "https://example.org/a" else "https://example.org/b";
    var c: ScriptedConnector = .{ .items = &.{ "a", "b" }, .skips = &many };
    var ctl: connector_mod.Control = .{};
    const r = try rig.run(&c, &ctl);
    try testing.expectEqual(@as(u64, 30), r.rejected); // all counted
    const skips = try rig.state.skipsOf(rig.arena.allocator(), r.job_id);
    try testing.expectEqual(@as(usize, 20), skips.len); // twenty per reason are kept
    try testing.expectEqualStrings("no_text", skips[0].reason);
    try testing.expectEqualStrings("https://example.org/a", skips[0].what);
    // Another job has none.
    try testing.expectEqual(@as(usize, 0), (try rig.state.skipsOf(rig.arena.allocator(), r.job_id + 1)).len);
}

test "cancel then resume continues where it stopped" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var c: ScriptedConnector = .{ .items = &.{ "a", "b", "c", "d", "e" } };

    var ctl: connector_mod.Control = .{};
    ctl.cancel(); // cancelled before it starts: stops at item 0
    const first = try rig.run(&c, &ctl);
    try testing.expectEqual(state_sqlite.JobState.cancelled, first.state);

    // Now a partial run: fail after 3 items with checkpoints saved every 2.
    var c2: ScriptedConnector = .{ .items = &.{ "a", "b", "c", "d", "e" }, .fail_at = 3 };
    var ctl2: connector_mod.Control = .{};
    const second = try rig.run(&c2, &ctl2);
    try testing.expectEqual(state_sqlite.JobState.failed, second.state);
    try testing.expectEqualStrings("SourceFailed", second.failure.?);
    try testing.expectEqualStrings("2", second.checkpoint.?); // last saved position survives the failure

    // The next run resumes from position 2, not from the start.
    var c3: ScriptedConnector = .{ .items = &.{ "a", "b", "c", "d", "e" } };
    var ctl3: connector_mod.Control = .{};
    const third = try rig.run(&c3, &ctl3);
    try testing.expectEqual(@as(?usize, 2), c3.seen_resume);
    try testing.expectEqual(state_sqlite.JobState.completed, third.state);
    try testing.expectEqual(@as(u64, 3), third.submitted); // c, d, e
    try testing.expectEqual(@as(usize, 5), rig.docs.count());

    // And a fourth run starts from the beginning again (previous one completed).
    var c4: ScriptedConnector = .{ .items = &.{ "a", "b", "c", "d", "e" } };
    var ctl4: connector_mod.Control = .{};
    _ = try rig.run(&c4, &ctl4);
    try testing.expectEqual(@as(?usize, null), c4.seen_resume);
    // ...and the pipeline recognised everything as unchanged: the 5 here, plus
    // the one document ("c") that the failed run had already submitted after
    // its last checkpoint and that the resumed run therefore delivered twice.
    // Delivery is at-least-once; duplicate detection makes that harmless.
    try testing.expectEqual(@as(u64, 6), rig.pipe.stats.unchanged);
}

test "a connector error fails the job with its name, without crashing the runner" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var c: ScriptedConnector = .{ .items = &.{"a"}, .fail_at = 0, .fail_with = error.Offline };
    var ctl: connector_mod.Control = .{};
    const r = try rig.run(&c, &ctl);
    try testing.expectEqual(state_sqlite.JobState.failed, r.state);
    try testing.expectEqualStrings("Offline", r.failure.?);
    const job = (try rig.state.getJob(rig.arena.allocator(), r.job_id)).?;
    try testing.expectEqualStrings("Offline", job.error_message.?);
}

test "checkpoints reach the state store while the run is still going" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();

    // A connector that "crashes" the process after reporting a checkpoint:
    // the runner never gets to write the final state.
    const Crasher = struct {
        fn info(_: *anyopaque) connector_mod.Info {
            return .{ .kind = "crasher", .requires_network = false, .resumable = true };
        }
        fn run(ptr: *anyopaque, sink: connector_mod.Sink, _: *connector_mod.Control, _: ?[]const u8) connector_mod.RunError!connector_mod.Outcome {
            const state: *state_sqlite.SqliteStateStore = @ptrCast(@alignCast(ptr));
            sink.submit(.{ .connector = "crasher", .source_id = "1", .text = "one" }) catch return error.SourceFailed;
            sink.checkpoint("after-1") catch return error.SourceFailed;
            // At this instant, from outside, the job is running with a saved position.
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const live = (state.getJob(arena.allocator(), 1) catch return error.SourceFailed).?;
            std.debug.assert(live.state == .running);
            std.debug.assert(std.mem.eql(u8, live.checkpoint.?, "after-1"));
            std.debug.assert(live.submitted == 1);
            return .{};
        }
    };
    const conn: connector_mod.Connector = .{ .ptr = &rig.state, .vtable = &.{ .info = Crasher.info, .run = Crasher.run } };
    var ctl: connector_mod.Control = .{};
    const r = try runImport(rig.arena.allocator(), &rig.state, &rig.pipe, conn, "crashy", &ctl, fixedNow);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
}

/// An index that is always full, to prove NoSpace stops the connector.
const FullIndex = struct {
    fn add(_: *anyopaque, _: doc.Id, _: doc.Document) indexer.Error!void {
        return error.NoSpace;
    }
    fn remove(_: *anyopaque, _: doc.Id) indexer.Error!void {}
    fn clear(_: *anyopaque) indexer.Error!void {}
    fn check(_: *anyopaque) indexer.Error!void {}
    var dummy: u8 = 0;
    fn index() indexer.Indexer {
        return .{ .ptr = &dummy, .vtable = &.{ .add = add, .remove = remove, .clear = clear, .check = check } };
    }
};

test "a full index stops the run and the job says why" {
    var state = try state_sqlite.SqliteStateStore.open(testing.allocator, ":memory:", true);
    defer state.close();
    var content = memory.MemoryContentStore.init(testing.allocator);
    defer content.deinit();
    var docs = memory.MemoryDocumentStore.init(testing.allocator);
    defer docs.deinit();
    var pipe = pipeline.Pipeline.init(content.store(), docs.store(), FullIndex.index(), .{ .now = fixedNow });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c: ScriptedConnector = .{ .items = &.{ "a", "b", "c" } };
    var ctl: connector_mod.Control = .{};
    const r = try runImport(arena.allocator(), &state, &pipe, c.connector(), "src", &ctl, fixedNow);
    try testing.expectEqual(state_sqlite.JobState.failed, r.state);
    try testing.expect(std.mem.indexOf(u8, r.failure.?, "storage full") != null);
    try testing.expectEqual(@as(u64, 0), r.submitted);
}

// ------------------------------------------------ batching and durability

/// Records the order of batch calls across the three stores.
const Log = struct {
    events: std.ArrayList([]const u8) = .empty,
    /// Make the Nth (1-based) records commit fail, to simulate a failing disk.
    fail_docs_commit_at: ?usize = null,
    docs_commits: usize = 0,

    fn add(self: *Log, e: []const u8) void {
        self.events.append(testing.allocator, e) catch unreachable;
    }
    fn count(self: *const Log, e: []const u8) usize {
        var n: usize = 0;
        for (self.events.items) |x| {
            if (std.mem.eql(u8, x, e)) n += 1;
        }
        return n;
    }
};

const SpyContent = struct {
    inner: storage.ContentStore,
    log: *Log,
    fn put(p: *anyopaque, id: doc.Id, b: []const u8) storage.Error!void {
        const s: *SpyContent = @ptrCast(@alignCast(p));
        return s.inner.put(id, b);
    }
    fn get(p: *anyopaque, gpa: Allocator, id: doc.Id) storage.Error![]u8 {
        const s: *SpyContent = @ptrCast(@alignCast(p));
        return s.inner.get(gpa, id);
    }
    fn delete(p: *anyopaque, id: doc.Id) storage.Error!void {
        const s: *SpyContent = @ptrCast(@alignCast(p));
        return s.inner.delete(id);
    }
    fn begin(p: *anyopaque) storage.Error!void {
        const s: *SpyContent = @ptrCast(@alignCast(p));
        s.log.add("content.begin");
    }
    fn commit(p: *anyopaque) storage.Error!void {
        const s: *SpyContent = @ptrCast(@alignCast(p));
        s.log.add("content.commit");
    }
    fn rollback(p: *anyopaque) storage.Error!void {
        const s: *SpyContent = @ptrCast(@alignCast(p));
        s.log.add("content.rollback");
    }
    fn store(s: *SpyContent) storage.ContentStore {
        return .{ .ptr = s, .vtable = &.{ .put = put, .get = get, .delete = delete, .begin = begin, .commit = commit, .rollback = rollback } };
    }
};

const SpyDocs = struct {
    inner: storage.DocumentStore,
    log: *Log,
    fn upsert(p: *anyopaque, r: storage.Record) storage.Error!void {
        const s: *SpyDocs = @ptrCast(@alignCast(p));
        return s.inner.upsert(r);
    }
    fn find(p: *anyopaque, id: doc.Id) storage.Error!?storage.Record {
        const s: *SpyDocs = @ptrCast(@alignCast(p));
        return s.inner.find(id);
    }
    fn delete(p: *anyopaque, id: doc.Id) storage.Error!void {
        const s: *SpyDocs = @ptrCast(@alignCast(p));
        return s.inner.delete(id);
    }
    fn forEach(p: *anyopaque, v: storage.Visitor) storage.Error!void {
        const s: *SpyDocs = @ptrCast(@alignCast(p));
        return s.inner.forEach(v);
    }
    fn begin(p: *anyopaque) storage.Error!void {
        const s: *SpyDocs = @ptrCast(@alignCast(p));
        s.log.add("docs.begin");
    }
    fn commit(p: *anyopaque) storage.Error!void {
        const s: *SpyDocs = @ptrCast(@alignCast(p));
        s.log.docs_commits += 1;
        if (s.log.fail_docs_commit_at) |n| if (s.log.docs_commits == n) return error.Io;
        s.log.add("docs.commit");
    }
    fn rollback(p: *anyopaque) storage.Error!void {
        const s: *SpyDocs = @ptrCast(@alignCast(p));
        s.log.add("docs.rollback");
    }
    fn store(s: *SpyDocs) storage.DocumentStore {
        return .{ .ptr = s, .vtable = &.{ .upsert = upsert, .find = find, .delete = delete, .for_each = forEach, .list = list, .count_of = countOf, .begin = begin, .commit = commit, .rollback = rollback } };
    }
    fn list(p: *anyopaque, a: Allocator, c: []const u8, after: ?[]const u8, n: usize) storage.Error![]storage.Entry {
        const s: *SpyDocs = @ptrCast(@alignCast(p));
        return s.inner.list(a, c, after, n);
    }
    fn countOf(p: *anyopaque, c: []const u8) storage.Error!u64 {
        const s: *SpyDocs = @ptrCast(@alignCast(p));
        return s.inner.countOf(c);
    }
};

const SpyIndex = struct {
    inner: indexer.Indexer,
    log: *Log,
    fn add(p: *anyopaque, id: doc.Id, d: doc.Document) indexer.Error!void {
        const s: *SpyIndex = @ptrCast(@alignCast(p));
        return s.inner.add(id, d);
    }
    fn remove(p: *anyopaque, id: doc.Id) indexer.Error!void {
        const s: *SpyIndex = @ptrCast(@alignCast(p));
        return s.inner.remove(id);
    }
    fn clear(p: *anyopaque) indexer.Error!void {
        const s: *SpyIndex = @ptrCast(@alignCast(p));
        return s.inner.clear();
    }
    fn check(p: *anyopaque) indexer.Error!void {
        const s: *SpyIndex = @ptrCast(@alignCast(p));
        return s.inner.check();
    }
    fn begin(p: *anyopaque) indexer.Error!void {
        const s: *SpyIndex = @ptrCast(@alignCast(p));
        s.log.add("index.begin");
    }
    fn commit(p: *anyopaque) indexer.Error!void {
        const s: *SpyIndex = @ptrCast(@alignCast(p));
        s.log.add("index.commit");
    }
    fn rollback(p: *anyopaque) indexer.Error!void {
        const s: *SpyIndex = @ptrCast(@alignCast(p));
        s.log.add("index.rollback");
    }
    fn index(s: *SpyIndex) indexer.Indexer {
        return .{ .ptr = s, .vtable = &.{ .add = add, .remove = remove, .clear = clear, .check = check, .begin = begin, .commit = commit, .rollback = rollback } };
    }
};

const SpyRig = struct {
    state: state_sqlite.SqliteStateStore,
    content: memory.MemoryContentStore,
    docs: memory.MemoryDocumentStore,
    idx: index_sqlite.SqliteIndex,
    log: Log = .{},
    sc: SpyContent = undefined,
    sd: SpyDocs = undefined,
    si: SpyIndex = undefined,
    pipe: pipeline.Pipeline = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn init(r: *SpyRig) !void {
        r.state = try state_sqlite.SqliteStateStore.open(testing.allocator, ":memory:", true);
        r.content = .init(testing.allocator);
        r.docs = .init(testing.allocator);
        r.idx = try index_sqlite.SqliteIndex.open(":memory:", .{});
        r.log = .{};
        r.sc = .{ .inner = r.content.store(), .log = &r.log };
        r.sd = .{ .inner = r.docs.store(), .log = &r.log };
        r.si = .{ .inner = r.idx.indexer(), .log = &r.log };
        r.pipe = .init(r.sc.store(), r.sd.store(), r.si.index(), .{ .now = fixedNow });
        r.arena = .init(testing.allocator);
    }
    fn deinit(r: *SpyRig) void {
        r.arena.deinit();
        r.log.events.deinit(testing.allocator);
        r.idx.close();
        r.docs.deinit();
        r.content.deinit();
        r.state.close();
    }
};

fn manyItems(n: usize) ![]const []const u8 {
    const items = try testing.allocator.alloc([]const u8, n);
    for (items, 0..) |*it, i| it.* = try std.fmt.allocPrint(testing.allocator, "item-{d}", .{i});
    return items;
}
fn freeItems(items: []const []const u8) void {
    for (items) |it| testing.allocator.free(it);
    testing.allocator.free(items);
}

test "documents are written in batches, not one commit each" {
    var rig: SpyRig = undefined;
    try rig.init();
    defer rig.deinit();
    const items = try manyItems(250);
    defer freeItems(items);
    var c: ScriptedConnector = .{ .items = items, .every = 100 }; // checkpoints after 100 and 200
    var ctl: connector_mod.Control = .{};
    const r = try runImport(rig.arena.allocator(), &rig.state, &rig.pipe, c.connector(), "src", &ctl, fixedNow);

    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    try testing.expectEqual(@as(u64, 250), r.submitted);
    // 100 + 100 at the checkpoints, 50 at the end: three commits, not 250.
    try testing.expectEqual(@as(usize, 3), rig.log.count("docs.commit"));
    try testing.expectEqual(@as(usize, 3), rig.log.count("content.commit"));
    try testing.expectEqual(@as(usize, 3), rig.log.count("index.commit"));
    try testing.expectEqual(@as(usize, 250), rig.docs.count());
}

test "each commit goes content, then index, then records" {
    var rig: SpyRig = undefined;
    try rig.init();
    defer rig.deinit();
    var c: ScriptedConnector = .{ .items = &.{ "a", "b", "c", "d" }, .every = 2 };
    var ctl: connector_mod.Control = .{};
    _ = try runImport(rig.arena.allocator(), &rig.state, &rig.pipe, c.connector(), "src", &ctl, fixedNow);

    const e = rig.log.events.items;
    // begin x3, commit x3, per batch; two batches (at the checkpoint, and the final one is empty).
    var seen_commit: usize = 0;
    var i: usize = 0;
    while (i < e.len) : (i += 1) {
        if (std.mem.eql(u8, e[i], "content.commit")) {
            try testing.expectEqualStrings("index.commit", e[i + 1]);
            try testing.expectEqualStrings("docs.commit", e[i + 2]);
            seen_commit += 1;
        }
    }
    try testing.expect(seen_commit >= 2);
}

test "a failed commit loses only the open batch; the saved position stays behind durable data" {
    var rig: SpyRig = undefined;
    try rig.init();
    defer rig.deinit();
    // Checkpoints every 2. The 2nd records-commit (batch of items 3-4) fails.
    rig.log.fail_docs_commit_at = 2;
    var c: ScriptedConnector = .{ .items = &.{ "a", "b", "c", "d", "e", "f" }, .every = 2 };
    var ctl: connector_mod.Control = .{};
    const r = try runImport(rig.arena.allocator(), &rig.state, &rig.pipe, c.connector(), "src", &ctl, fixedNow);

    try testing.expectEqual(state_sqlite.JobState.failed, r.state);
    // Only the first batch (a, b) was made durable, and that is exactly where a resume starts.
    try testing.expectEqualStrings("2", (try rig.state.resumePoint(rig.arena.allocator(), "src")).?);
    try testing.expectEqual(@as(u64, 2), (try rig.state.getJob(rig.arena.allocator(), r.job_id)).?.submitted);
    try testing.expect(rig.log.count("docs.rollback") >= 1); // the failed batch was abandoned
}

test "a batch that is never committed leaves no trace in the stores" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var sb: [256]u8 = undefined;
    var cb: [256]u8 = undefined;
    const state_path = try std.fmt.bufPrintSentinel(&sb, ".zig-cache/tmp/{s}/state.db", .{tmp.sub_path}, 0);
    const content_path = try std.fmt.bufPrintSentinel(&cb, ".zig-cache/tmp/{s}/content.db", .{tmp.sub_path}, 0);
    const content_sqlite = @import("content_sqlite.zig");
    const d: doc.Document = .{ .connector = "c", .source_id = "1", .text = "pending text" };

    {
        var st = try state_sqlite.SqliteStateStore.open(testing.allocator, state_path, true);
        defer st.close();
        var ct = try content_sqlite.SqliteContentStore.open(testing.allocator, content_path, true);
        defer ct.close();
        try ct.store().begin();
        try st.documents().begin();
        try ct.store().put(d.id(), "pending text");
        var meta = d;
        meta.text = null;
        try st.documents().upsert(.{ .id = d.id(), .content_hash = d.contentHash(), .acquired_at = 1, .meta = meta });
        // Visible to the writer itself...
        try testing.expect((try st.documents().find(d.id())) != null);
        // ...but the process "crashes" here: both close without commit.
    }
    var st = try state_sqlite.SqliteStateStore.open(testing.allocator, state_path, true);
    defer st.close();
    var ct = try content_sqlite.SqliteContentStore.open(testing.allocator, content_path, true);
    defer ct.close();
    try testing.expect((try st.documents().find(d.id())) == null);
    try testing.expectError(error.NotFound, ct.store().get(testing.allocator, d.id()));

    // The same sequence with a commit persists.
    try ct.store().begin();
    try st.documents().begin();
    try ct.store().put(d.id(), "pending text");
    var meta = d;
    meta.text = null;
    try st.documents().upsert(.{ .id = d.id(), .content_hash = d.contentHash(), .acquired_at = 1, .meta = meta });
    try ct.store().commit();
    try st.documents().commit();
    try testing.expect((try st.documents().find(d.id())) != null);
    const got = try ct.store().get(testing.allocator, d.id());
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("pending text", got);
}
