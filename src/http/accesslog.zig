//! The optional access log (docs/decisions/0012).
//!
//! One line per request, and only these fields: UTC time, method, a fixed
//! route label (never the URL), status, duration in milliseconds and response
//! bytes. No query string, no target, no client address, no user agent, no
//! cookie or credential is ever passed to this module, so none can be logged.

const std = @import("std");
const Io = std.Io;

pub const AccessLog = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    /// Null: standard error.
    file: ?Io.File = null,

    /// `destination` is "stderr" or a file path, which is created or appended to.
    pub fn open(io: Io, destination: []const u8) Io.File.OpenError!AccessLog {
        if (std.mem.eql(u8, destination, "stderr")) return .{ .io = io };
        const f = try Io.Dir.cwd().createFile(io, destination, .{ .truncate = false, .permissions = Io.File.Permissions.fromMode(0o600) });
        return .{ .io = io, .file = f };
    }

    pub fn close(self: *AccessLog) void {
        if (self.file) |f| f.close(self.io);
        self.* = undefined;
    }

    /// Appends one line. Failures to write are ignored: logging must never
    /// stop the server from answering.
    pub fn record(self: *AccessLog, method: []const u8, route: []const u8, status: u16, duration_ms: u64, bytes: u64) void {
        var buf: [256]u8 = undefined;
        const secs: i64 = @intCast(@divFloor(Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        const line = format(&buf, secs, method, route, status, duration_ms, bytes) orelse return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.file) |f| {
            // Append at the file's current end, looked up each time, so a log
            // truncated by logrotate (copytruncate) starts over cleanly
            // instead of leaving a hole.
            const end = (f.stat(self.io) catch return).size;
            f.writePositionalAll(self.io, line, end) catch return;
        } else {
            Io.File.stderr().writeStreamingAll(self.io, line) catch {};
        }
    }
};

/// "2026-11-14T10:20:30Z GET /search 200 12ms 3456B\n", or null if it does
/// not fit (method and route are short fixed strings, so it always does).
pub fn format(buf: []u8, unix_seconds: i64, method: []const u8, route: []const u8, status: u16, duration_ms: u64, bytes: u64) ?[]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(unix_seconds, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z {s} {s} {d} {d}ms {d}B\n", .{
        day.year,             @backingInt(md.month),   md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        method,               route,                   status,
        duration_ms,          bytes,
    }) catch null;
}

const testing = std.testing;

test "a line has the fixed fields and nothing else" {
    var buf: [256]u8 = undefined;
    const line = format(&buf, 1709634030, "GET", "/search", 200, 12, 3456).?;
    try testing.expectEqualStrings("2024-03-05T10:20:30Z GET /search 200 12ms 3456B\n", line);
}

test "writes to a file, appending to what is there" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.log", .data = "old line\n" });
    var path_buf: [200]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/a.log", .{tmp.sub_path});
    var log = try AccessLog.open(testing.io, path);
    log.record("GET", "/", 200, 1, 10);
    log.record("POST", "/login", 303, 250, 0);
    log.close();
    const text = try tmp.dir.readFileAlloc(testing.io, "a.log", testing.allocator, .limited(4096));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "old line\n"));
    try testing.expect(std.mem.indexOf(u8, text, "Z GET / 200 1ms 10B\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Z POST /login 303 250ms 0B\n") != null);
}

test "a truncated log starts over without leaving a hole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [200]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/t.log", .{tmp.sub_path});
    var log = try AccessLog.open(testing.io, path);
    defer log.close();
    log.record("GET", "/", 200, 1, 1);
    log.record("GET", "/", 200, 1, 1);
    const f = try tmp.dir.openFile(testing.io, "t.log", .{ .mode = .read_write });
    try f.setLength(testing.io, 0); // what copytruncate does
    f.close(testing.io);
    log.record("GET", "/x", 404, 2, 3);
    const text = try tmp.dir.readFileAlloc(testing.io, "t.log", testing.allocator, .limited(4096));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOfScalar(u8, text, 0) == null);
    try testing.expect(std.mem.endsWith(u8, text, "Z GET /x 404 2ms 3B\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
}
