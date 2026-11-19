//! The export file (docs/decisions/0053): the documents of some sources written one JSON object per line, with their
//! full text, so that a copy can be made on another machine without the two being connected. `dksearch export` writes
//! it, a `dump` source with `format = "export"` reads it. The fields are those of the peer export
//! (`/api/v1/export`), so both ways of copying agree.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The name a file made by `dksearch export` has, and the one a `dump` source with this format looks for.
pub const suffix = ".dksearch.jsonl";

pub const Record = struct {
    id: []const u8 = "",
    /// The name of the source it came from (informational).
    source: []const u8 = "",
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    text: []const u8 = "",
    language: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    modified_at: ?i64 = null,
    published_at: ?i64 = null,
    author: ?[]const u8 = null,
    /// What the source's owner says may be done with the text: unknown, allowed or restricted.
    redistribution: []const u8 = "unknown",
};

/// One line of the file (without the line break).
pub fn encode(arena: Allocator, r: Record) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(r, .{}, &aw.writer) catch return error.OutOfMemory;
    return aw.written();
}

pub const DecodeError = error{ BadLine, OutOfMemory };

/// One line back into a record; anything that is not a record with some text is refused.
pub fn decode(arena: Allocator, line: []const u8) DecodeError!Record {
    const r = std.json.parseFromSliceLeaky(Record, arena, line, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadLine,
    };
    if (r.id.len != 32) return error.BadLine;
    return r;
}

const testing = std.testing;

test "a record survives the file: text with quotes, line breaks and non-ASCII, and optional fields" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r: Record = .{
        .id = "0123456789abcdef0123456789abcdef",
        .source = "curated",
        .url = "https://example.org/a?b=1&c=2",
        .title = "Der \"Käse\" 🧀",
        .text = "line one\nline two\twith tab and a backslash \\ and ünïcode",
        .language = "de",
        .content_type = "text/html",
        .modified_at = 1700000000,
        .redistribution = "restricted",
    };
    const line = try encode(a, r);
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null); // one line
    const back = try decode(a, line);
    try testing.expectEqualStrings(r.id, back.id);
    try testing.expectEqualStrings(r.title.?, back.title.?);
    try testing.expectEqualStrings(r.text, back.text);
    try testing.expectEqual(@as(?i64, 1700000000), back.modified_at);
    try testing.expect(back.author == null and back.published_at == null);
    try testing.expectEqualStrings("restricted", back.redistribution);
}

test "lines that are not records are refused, unknown fields are ignored" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.BadLine, decode(a, "not json"));
    try testing.expectError(error.BadLine, decode(a, "[1,2]"));
    try testing.expectError(error.BadLine, decode(a, "{\"id\":\"short\",\"text\":\"x\"}"));
    const ok = try decode(a, "{\"id\":\"0123456789abcdef0123456789abcdef\",\"text\":\"x\",\"ident\":\"zz\",\"future\":[1]}");
    try testing.expectEqualStrings("x", ok.text);
}
