//! The owner's feedback on results (docs/decisions/0064): a good or a bad mark on a result of a search, kept in
//! `feedback.jsonl` in the data directory, one line for each mark:
//!
//!     {"query": "how to program in c", "url": "https://...", "grade": 1, "time": 1763600000}
//!
//! A grade of 1 says the result is a good answer to that search, -1 that it should not have been shown, 0 takes an earlier
//! mark back. `dksearch eval` reads the file as it is (the last mark for a query and address wins). Only the owner signed in
//! to the results page can add to it; nothing is sent anywhere.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const search = @import("search.zig");

pub const file_name = "feedback.jsonl";
/// The file stops growing here (a mark is about a hundred bytes: this is a couple hundred thousand of them).
pub const max_file_bytes: u64 = 32 * 1024 * 1024;
pub const max_url_bytes = 2000;

pub const Error = error{ OutOfMemory, Invalid, TooBig, Io };

pub const Store = struct {
    io: Io,
    dir: Io.Dir,
    mutex: Io.Mutex = .init,

    pub fn init(io: Io, dir: Io.Dir) Store {
        return .{ .io = io, .dir = dir };
    }

    /// Adds a mark. `Invalid` for an empty or oversized query or address or a grade other than -1, 0 and 1.
    pub fn record(self: *Store, arena: Allocator, query: []const u8, url: []const u8, grade: i32, now_s: i64) Error!void {
        if (query.len == 0 or query.len > search.max_query_bytes) return error.Invalid;
        if (url.len == 0 or url.len > max_url_bytes) return error.Invalid;
        if (grade < -1 or grade > 1) return error.Invalid;
        var aw: Io.Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("query") catch return error.OutOfMemory;
        s.write(query) catch return error.OutOfMemory;
        s.objectField("url") catch return error.OutOfMemory;
        s.write(url) catch return error.OutOfMemory;
        s.objectField("grade") catch return error.OutOfMemory;
        s.write(grade) catch return error.OutOfMemory;
        s.objectField("time") catch return error.OutOfMemory;
        s.write(now_s) catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
        aw.writer.writeByte('\n') catch return error.OutOfMemory;
        const line = aw.written();

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const f = self.dir.createFile(self.io, file_name, .{ .truncate = false }) catch return error.Io;
        defer f.close(self.io);
        const size = (f.stat(self.io) catch return error.Io).size;
        if (size + line.len > max_file_bytes) return error.TooBig;
        f.writePositionalAll(self.io, line, size) catch return error.Io;
    }
};

const testing = std.testing;

test "marks are appended one to a line and checked" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var store = Store.init(testing.io, tmp.dir);
    try store.record(a, "how to program in c", "https://e.org/c", 1, 100);
    try store.record(a, "say \"hi\"\nnow", "https://e.org/h?x=1&y=2", -1, 101);
    try store.record(a, "how to program in c", "https://e.org/c", 0, 102);
    try testing.expectError(error.Invalid, store.record(a, "", "https://e.org", 1, 1));
    try testing.expectError(error.Invalid, store.record(a, "q", "", 1, 1));
    try testing.expectError(error.Invalid, store.record(a, "q", "https://e.org", 2, 1));
    const text = try tmp.dir.readFileAlloc(testing.io, file_name, a, .limited(10_000));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |l| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, l, .{});
        try testing.expect(v.object.get("query") != null and v.object.get("grade") != null);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    // The text of the query survives quoting and a newline in it.
    try testing.expect(std.mem.indexOf(u8, text, "say \\\"hi\\\"\\nnow") != null);
}
