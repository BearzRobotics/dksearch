//! Runs imports by themselves for the sources that have a `schedule`.
//!
//! Once a minute the scheduler looks at every enabled source with a schedule. A source is due when it
//! has never been imported or its last import started at least its interval ago (a failed run counts:
//! it is retried after one interval, not at once). Of the due sources the one longest overdue is
//! started, if nothing else is running; the others wait their turn. It uses the same job manager as
//! the buttons in the interface, so it shares their rules: one task at a time, the writer lock, and
//! imports resume where they stopped.
//!
//! A crawl source with `watch_seeds = true` is also due when its seeds file was changed after its last import began and
//! has been left alone for `quiet_seconds` (a batch of additions starts one import, not several). It is started the
//! same way, so it waits behind whatever is running (a manual import included) and is never started on top of it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const jobs = @import("jobs.zig");
const state_sqlite = @import("state_sqlite.zig");

pub const tick_seconds = 30;
/// How long a watched seeds file must have been left alone before its source is imported for the change.
pub const quiet_seconds = 120;

/// When a watched source's seeds file was last changed.
pub const Changed = struct { source: []const u8, at: i64 };

pub const LastStart = struct { source: []const u8, started_at: i64 };

/// The name of the source to start now, or null. `last` holds, per source, when its latest job started.
pub fn nextDue(sources: []const config.Source, last: []const LastStart, now: i64) ?[]const u8 {
    return nextDueWith(sources, last, &.{}, now);
}

/// As `nextDue`, and a source whose seeds file changed (`changed`) after its last import began is due `quiet_seconds` after
/// the change.
pub fn nextDueWith(sources: []const config.Source, last: []const LastStart, changed: []const Changed, now: i64) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_overdue: i64 = -1;
    for (sources) |s| {
        if (!s.enabled) continue;
        var last_started: ?i64 = null;
        for (last) |l| if (std.mem.eql(u8, l.source, s.name)) {
            last_started = l.started_at;
        };
        var due_at: i64 = std.math.maxInt(i64);
        if (s.schedule_seconds > 0) due_at = if (last_started) |ls| ls + s.schedule_seconds else std.math.minInt(i64) / 2; // never imported: due long ago
        for (changed) |c| if (std.mem.eql(u8, c.source, s.name)) {
            if (last_started == null or c.at > last_started.?) due_at = @min(due_at, c.at + quiet_seconds);
        };
        if (due_at == std.math.maxInt(i64)) continue; // no schedule and nothing changed
        if (due_at > now) continue;
        const overdue = now - due_at;
        if (overdue > best_overdue) {
            best_overdue = overdue;
            best = s.name;
        }
    }
    return best;
}

/// Runs until `stop` is set. Errors from starting a job (another one is running, the data directory is
/// locked by a command-line import) are not failures: the source is simply tried again later.
pub fn run(gpa: Allocator, io: Io, manager: *jobs.Manager, state_path: [:0]const u8, stop: *const std.atomic.Value(bool), log: *const fn (Io, []const u8) void) void {
    var waited: u32 = tick_seconds; // look right at the start
    while (!stop.load(.acquire)) {
        if (waited >= tick_seconds) {
            waited = 0;
            tick(gpa, io, manager, state_path, log);
        }
        io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .awake) catch return;
        waited += 1;
    }
}

/// Whether the source is imported when its seeds file changes.
fn watches(s: config.Source) bool {
    return s.enabled and std.mem.eql(u8, s.kind, "crawl") and (s.optionBool("watch_seeds") orelse false) and s.optionString("seeds_file") != null;
}

fn tick(gpa: Allocator, io: Io, manager: *jobs.Manager, state_path: [:0]const u8, log: *const fn (Io, []const u8) void) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sources = manager.sources();
    var any = false;
    for (sources) |s| if ((s.enabled and s.schedule_seconds > 0) or watches(s)) {
        any = true;
    };
    if (!any) return;
    // The watched seeds files and when they last changed.
    var changed: std.ArrayList(Changed) = .empty;
    for (sources) |s| if (watches(s)) {
        const st = Io.Dir.cwd().statFile(io, s.optionString("seeds_file").?, .{}) catch continue;
        changed.append(arena, .{ .source = s.name, .at = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s)) }) catch return;
    };
    var state = state_sqlite.SqliteStateStore.inspect(gpa, state_path) catch |e| switch (e) {
        // No state.db yet: nothing has ever run, so everything scheduled is due.
        else => {
            startDue(io, manager, sources, &.{}, changed.items, log);
            return;
        },
    };
    defer state.close();
    var last: std.ArrayList(LastStart) = .empty;
    for (sources) |s| {
        if (s.schedule_seconds == 0 and !watches(s)) continue;
        const j = (state.lastJob(arena, s.name) catch continue) orelse continue;
        last.append(arena, .{ .source = s.name, .started_at = j.started_at }) catch return;
    }
    startDue(io, manager, sources, last.items, changed.items, log);
}

fn startDue(io: Io, manager: *jobs.Manager, sources: []const config.Source, last: []const LastStart, changed: []const Changed, log: *const fn (Io, []const u8) void) void {
    const now = Io.Clock.real.now(io).toSeconds();
    const name = nextDueWith(sources, last, changed, now) orelse return;
    manager.start(name) catch return; // busy or locked: try again at the next tick
    var buf: [128]u8 = undefined;
    log(io, std.fmt.bufPrint(&buf, "scheduled import of {s} started", .{name}) catch "scheduled import started");
}

const testing = std.testing;

test "interval text: words, numbers with units, and the limits" {
    try testing.expectEqual(@as(?u32, 3600), config.parseInterval("hourly"));
    try testing.expectEqual(@as(?u32, 86400), config.parseInterval("daily"));
    try testing.expectEqual(@as(?u32, 604800), config.parseInterval("weekly"));
    try testing.expectEqual(@as(?u32, 1800), config.parseInterval("30m"));
    try testing.expectEqual(@as(?u32, 6 * 3600), config.parseInterval(" 6h "));
    try testing.expectEqual(@as(?u32, 2 * 86400), config.parseInterval("2d"));
    for ([_][]const u8{ "", "h", "5m", "0d", "366d", "1w", "daily!", "-1h", "6 h", "99999999999d" }) |bad| try testing.expectEqual(@as(?u32, null), config.parseInterval(bad));
}

test "the source longest overdue is chosen; unscheduled, disabled and not-yet-due ones are not" {
    const srcs = [_]config.Source{
        .{ .name = "manual", .kind = "files" },
        .{ .name = "off", .kind = "files", .enabled = false, .schedule_seconds = 600 },
        .{ .name = "fresh", .kind = "files", .schedule_seconds = 3600 },
        .{ .name = "old", .kind = "files", .schedule_seconds = 3600 },
        .{ .name = "older", .kind = "files", .schedule_seconds = 3600 },
        .{ .name = "never", .kind = "files", .schedule_seconds = 86400 },
    };
    const now: i64 = 1_000_000;
    const last = [_]LastStart{
        .{ .source = "fresh", .started_at = now - 100 },
        .{ .source = "old", .started_at = now - 4000 },
        .{ .source = "older", .started_at = now - 9000 },
        .{ .source = "off", .started_at = 0 },
    };
    try testing.expectEqualStrings("never", nextDue(&srcs, &last, now).?); // never imported: overdue the longest
    const without_never = srcs[0..5];
    try testing.expectEqualStrings("older", nextDue(without_never, &last, now).?);
    try testing.expect(nextDue(srcs[0..3], &last, now) == null);
    // A job that just started makes its source not due.
    const just = [_]LastStart{ .{ .source = "fresh", .started_at = now }, .{ .source = "old", .started_at = now }, .{ .source = "older", .started_at = now } };
    try testing.expect(nextDue(without_never, &just, now) == null);
}

test "a watched seeds file makes its source due after the quiet time, once, and never before the last import began" {
    const sources = [_]config.Source{
        .{ .name = "suggested", .kind = "crawl", .schedule_seconds = 0 },
        .{ .name = "daily", .kind = "crawl", .schedule_seconds = 86400 },
    };
    const day = 86400;
    const now: i64 = 10 * day;
    const fresh = [_]LastStart{ .{ .source = "suggested", .started_at = now - 1000 }, .{ .source = "daily", .started_at = now - 100 } };
    // Nothing changed since the last import: nothing is due.
    try testing.expect(nextDueWith(&sources, &fresh, &.{.{ .source = "suggested", .at = now - 2000 }}, now) == null);
    // Changed after it began, but only a minute ago: wait for more suggestions.
    try testing.expect(nextDueWith(&sources, &fresh, &.{.{ .source = "suggested", .at = now - 60 }}, now) == null);
    // Changed and left alone for the quiet time: due.
    try testing.expectEqualStrings("suggested", nextDueWith(&sources, &fresh, &.{.{ .source = "suggested", .at = now - 500 }}, now).?);
    // A manual import that began after the change takes care of it.
    const manual = [_]LastStart{ .{ .source = "suggested", .started_at = now - 10 }, .{ .source = "daily", .started_at = now - 100 } };
    try testing.expect(nextDueWith(&sources, &manual, &.{.{ .source = "suggested", .at = now - 500 }}, now) == null);
    // Never imported, with a seeds file: due once the file has been left alone.
    try testing.expectEqualStrings("suggested", nextDueWith(&sources, &.{.{ .source = "daily", .started_at = now - 100 }}, &.{.{ .source = "suggested", .at = now - 500 }}, now).?);
    // A source that is not watched and has no schedule is never due, whatever else changes.
    try testing.expect(nextDueWith(&sources, &fresh, &.{.{ .source = "other", .at = now - 500 }}, now) == null);
}
