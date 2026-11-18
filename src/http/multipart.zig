//! A small reader for `multipart/form-data` request bodies (RFC 7578): the text fields and the files of one form, as the
//! browser sends them. Only what the administration forms need: no nested parts, no encodings, a bounded number of parts.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Part = struct {
    /// The form field name.
    name: []const u8,
    /// The file name the browser sent, for a file field.
    filename: ?[]const u8,
    data: []const u8,
};

pub const max_parts = 16;

/// The boundary of a `Content-Type: multipart/form-data; boundary=...` header value.
pub fn boundaryOf(content_type: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) return null;
    var it = std.mem.splitScalar(u8, content_type, ';');
    _ = it.next();
    while (it.next()) |param| {
        const p = std.mem.trim(u8, param, " \t");
        if (!std.ascii.startsWithIgnoreCase(p, "boundary=")) continue;
        var v = p["boundary=".len..];
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        if (v.len == 0 or v.len > 70) return null;
        return v;
    }
    return null;
}

/// The parts of `body`, which must be well formed; null otherwise. The data points into `body`.
pub fn parts(arena: Allocator, body: []const u8, boundary: []const u8) Allocator.Error!?[]const Part {
    const delim = try std.fmt.allocPrint(arena, "--{s}", .{boundary});
    var out: std.ArrayList(Part) = .empty;
    var pos = std.mem.indexOf(u8, body, delim) orelse return null;
    while (true) {
        pos += delim.len;
        if (std.mem.startsWith(u8, body[pos..], "--")) return out.items; // the closing delimiter
        if (!std.mem.startsWith(u8, body[pos..], "\r\n")) return null;
        pos += 2;
        const head_end = std.mem.indexOf(u8, body[pos..], "\r\n\r\n") orelse return null;
        const head = body[pos .. pos + head_end];
        const data_start = pos + head_end + 4;
        const next = std.mem.indexOfPos(u8, body, data_start, try std.fmt.allocPrint(arena, "\r\n{s}", .{delim})) orelse return null;
        if (out.items.len >= max_parts) return null;
        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        while (lines.next()) |line| {
            if (!std.ascii.startsWithIgnoreCase(line, "content-disposition:")) continue;
            name = paramOf(line, "name");
            filename = paramOf(line, "filename");
        }
        try out.append(arena, .{ .name = name orelse return null, .filename = filename, .data = body[data_start..next] });
        pos = next + 2; // past the CRLF before the next delimiter
    }
}

/// `name="value"` in a header line (matching a whole parameter name, so `name` is not found inside `filename`).
fn paramOf(line: []const u8, key: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, key)) |at| {
        from = at + key.len;
        if (at == 0 or !(line[at - 1] == ' ' or line[at - 1] == ';')) continue;
        if (!std.mem.startsWith(u8, line[from..], "=\"")) continue;
        const start = from + 2;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
        return line[start..end];
    }
    return null;
}

/// The data of the field called `name`, or null.
pub fn field(list: []const Part, name: []const u8) ?[]const u8 {
    for (list) |p| if (std.mem.eql(u8, p.name, name)) return p.data;
    return null;
}

const testing = std.testing;

test "a browser's form: text fields and a file are read, the boundary is found" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("XyZ", boundaryOf("multipart/form-data; boundary=XyZ").?);
    try testing.expectEqualStrings("a b", boundaryOf("multipart/form-data; charset=x; boundary=\"a b\"").?);
    try testing.expect(boundaryOf("application/x-www-form-urlencoded") == null);
    try testing.expect(boundaryOf("multipart/form-data") == null);
    const body = "--XyZ\r\nContent-Disposition: form-data; name=\"csrf\"\r\n\r\nabc123\r\n" ++
        "--XyZ\r\nContent-Disposition: form-data; name=\"image\"; filename=\"cat.png\"\r\nContent-Type: image/png\r\n\r\n\x89PNG\r\n--not-a-boundary\r\n\x00\xff\r\n" ++
        "--XyZ\r\nContent-Disposition: form-data; name=\"distance\"\r\n\r\n8\r\n--XyZ--\r\n";
    const got = (try parts(a, body, "XyZ")).?;
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("abc123", field(got, "csrf").?);
    try testing.expectEqualStrings("8", field(got, "distance").?);
    try testing.expectEqualStrings("cat.png", got[1].filename.?);
    try testing.expectEqualStrings("\x89PNG\r\n--not-a-boundary\r\n\x00\xff", got[1].data); // binary data kept as it is
    try testing.expect(got[0].filename == null);
    try testing.expect(field(got, "nothing") == null);
}

test "a malformed body is refused, never crashes" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "", "no boundary at all", "--B", "--B\r\n", "--B\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\ndata", "--B\r\nno-name: 1\r\n\r\nx\r\n--B--" }) |bad| {
        try testing.expect((try parts(a, bad, "B")) == null);
    }
    // Too many parts.
    var big: std.ArrayList(u8) = .empty;
    for (0..max_parts + 2) |i| try big.print(a, "--B\r\nContent-Disposition: form-data; name=\"f{d}\"\r\n\r\nv\r\n", .{i});
    try big.appendSlice(a, "--B--\r\n");
    try testing.expect((try parts(a, big.items, "B")) == null);
}
