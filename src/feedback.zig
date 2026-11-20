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
/// Sites the owner suggests: one address per line, the seeds file of a crawl source (`seeds_file`).
pub const suggested_file = "suggested-sites.txt";
pub const max_suggested_sites = 5000;
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

    /// Adds `url` to the suggested sites (the seeds file of a crawl source); false if it was already there.
    /// `Invalid` for an address that is not a plain http(s) address.
    pub fn addSuggested(self: *Store, arena: Allocator, url_in: []const u8) Error!bool {
        const url = std.mem.trim(u8, url_in, " \t\r\n");
        if (!validSiteUrl(url)) return error.Invalid;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const old = self.dir.readFileAlloc(self.io, suggested_file, arena, .limited(4 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => "",
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Io,
        };
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, old, '\n');
        while (it.next()) |l| {
            const line = std.mem.trim(u8, l, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            lines += 1;
            if (sameSeed(line, url)) return false;
        }
        if (lines >= max_suggested_sites) return error.TooBig;
        const f = self.dir.createFile(self.io, suggested_file, .{ .truncate = false }) catch return error.Io;
        defer f.close(self.io);
        const size = (f.stat(self.io) catch return error.Io).size;
        const text = try std.fmt.allocPrint(arena, "{s}{s}\n", .{ if (size > 0 and old.len > 0 and old[old.len - 1] != '\n') "\n" else "", url });
        f.writePositionalAll(self.io, text, size) catch return error.Io;
        return true;
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

/// Whether `url` is an address worth crawling as a seed: http or https, a host with a dot (or an onion or i2p name), no
/// credentials, no spaces or control characters, at most `max_url_bytes`.
pub fn validSiteUrl(url: []const u8) bool {
    if (url.len < 10 or url.len > max_url_bytes) return false;
    const rest = if (std.ascii.startsWithIgnoreCase(url, "https://")) url[8..] else if (std.ascii.startsWithIgnoreCase(url, "http://")) url[7..] else return false;
    for (url) |c| if (c <= 0x20 or c == 0x7f or c == '"' or c == '<' or c == '>') return false;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    return std.mem.indexOfScalar(u8, authority, '.') != null;
}

fn sameSeed(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

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

test "suggested sites are added once, as one address a line, and only plain http(s) addresses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var store = Store.init(testing.io, tmp.dir);
    try testing.expect(try store.addSuggested(a, "https://www.system-rescue.org/"));
    try testing.expect(try store.addSuggested(a, " https://clonezilla.org \n"));
    try testing.expect(!(try store.addSuggested(a, "https://www.system-rescue.org")));
    try testing.expect(!(try store.addSuggested(a, "HTTPS://CLONEZILLA.ORG/")));
    try testing.expectError(error.Invalid, store.addSuggested(a, "ftp://example.org/"));
    try testing.expectError(error.Invalid, store.addSuggested(a, "https://user:pw@example.org/"));
    try testing.expectError(error.Invalid, store.addSuggested(a, "https://localhost/"));
    try testing.expectError(error.Invalid, store.addSuggested(a, "https://exa mple.org/"));
    try testing.expectError(error.Invalid, store.addSuggested(a, "javascript:alert(1)"));
    const text = try tmp.dir.readFileAlloc(testing.io, suggested_file, a, .limited(10_000));
    try testing.expectEqualStrings("https://www.system-rescue.org/\nhttps://clonezilla.org\n", text);
    // A file that lacks its last newline still gets one line for each.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = suggested_file, .data = "https://a.example.org/" });
    try testing.expect(try store.addSuggested(a, "https://b.example.org/"));
    try testing.expectEqualStrings("https://a.example.org/\nhttps://b.example.org/\n", try tmp.dir.readFileAlloc(testing.io, suggested_file, a, .limited(10_000)));
}
