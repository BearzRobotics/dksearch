//! Request-target and query-string parsing.
//!
//! Everything here treats its input as hostile: bounded sizes, strict
//! percent-decoding, valid UTF-8 only.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Longest request target we will look at. The server's header buffer is the
/// real limit; this is a second, independent bound.
pub const max_target_bytes = 8192;
pub const max_params = 32;

pub const Error = error{
    /// Bad percent-escape, invalid UTF-8, a control byte, or an over-long target.
    BadEncoding,
    TooManyParams,
    OutOfMemory,
};

pub const Pair = struct { name: []const u8, value: []const u8 };

pub const Params = struct {
    pairs: []const Pair,

    /// Every value given for `name`, in order (for parameters that may repeat).
    pub fn all(self: Params, arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.pairs) |p| if (std.mem.eql(u8, p.name, name) and p.value.len > 0) try out.append(arena, p.value);
        return out.items;
    }

    /// First value for `name`, or null. Later duplicates are ignored.
    pub fn get(self: Params, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return null;
    }
};

pub const Target = struct {
    /// Path exactly as sent (not percent-decoded), starting with '/'.
    path: []const u8,
    params: Params,
};

/// Splits `target` into path and decoded query parameters. The path is not
/// decoded on purpose: routes match exact bytes, so `/%61pi` is just unknown.
pub fn parseTarget(arena: Allocator, target: []const u8) Error!Target {
    if (target.len == 0 or target.len > max_target_bytes or target[0] != '/') return error.BadEncoding;
    for (target) |b| if (b <= 0x20 or b == 0x7f) return error.BadEncoding;

    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q) |i| target[0..i] else target;
    const qs = if (q) |i| target[i + 1 ..] else "";

    var pairs: std.ArrayList(Pair) = .empty;
    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (pairs.items.len == max_params) return error.TooManyParams;
        const eq = std.mem.indexOfScalar(u8, part, '=');
        const raw_name = if (eq) |i| part[0..i] else part;
        const raw_value = if (eq) |i| part[i + 1 ..] else "";
        try pairs.append(arena, .{
            .name = try decode(arena, raw_name),
            .value = try decode(arena, raw_value),
        });
    }
    return .{ .path = path, .params = .{ .pairs = pairs.items } };
}

/// application/x-www-form-urlencoded decoding: '+' is a space, %XX is a byte.
/// The result must be valid UTF-8.
pub fn decode(arena: Allocator, s: []const u8) Error![]const u8 {
    var out = try arena.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        if (b == '+') {
            out[n] = ' ';
        } else if (b == '%') {
            if (i + 2 >= s.len) return error.BadEncoding; // needs two hex digits
            const hi = hexVal(s[i + 1]) orelse return error.BadEncoding;
            const lo = hexVal(s[i + 2]) orelse return error.BadEncoding;
            out[n] = (hi << 4) | lo;
            i += 2;
        } else {
            out[n] = b;
        }
        n += 1;
    }
    if (!std.unicode.utf8ValidateSlice(out[0..n])) return error.BadEncoding;
    return out[0..n];
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Writes `s` percent-encoded for use inside a query-string value.
pub fn writeEncoded(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |b| switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(b),
        else => try w.print("%{X:0>2}", .{b}),
    };
}

const testing = std.testing;

fn arenaT() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "parseTarget splits path and decodes parameters" {
    var ar = arenaT();
    defer ar.deinit();
    const t = try parseTarget(ar.allocator(), "/search?q=hello+world&language=en&q=ignored&flag&x=%C3%A9");
    try testing.expectEqualStrings("/search", t.path);
    try testing.expectEqualStrings("hello world", t.params.get("q").?);
    try testing.expectEqualStrings("en", t.params.get("language").?);
    try testing.expectEqualStrings("", t.params.get("flag").?);
    try testing.expectEqualStrings("é", t.params.get("x").?);
    try testing.expect(t.params.get("missing") == null);
}

test "parseTarget does not decode the path" {
    var ar = arenaT();
    defer ar.deinit();
    const t = try parseTarget(ar.allocator(), "/%61pi/v1");
    try testing.expectEqualStrings("/%61pi/v1", t.path);
}

test "parseTarget rejects malformed input" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectError(error.BadEncoding, parseTarget(a, ""));
    try testing.expectError(error.BadEncoding, parseTarget(a, "search"));
    try testing.expectError(error.BadEncoding, parseTarget(a, "http://evil/"));
    try testing.expectError(error.BadEncoding, parseTarget(a, "/a b"));
    try testing.expectError(error.BadEncoding, parseTarget(a, "/a\x00b"));
    try testing.expectError(error.BadEncoding, parseTarget(a, "/s?q=%"));
    try testing.expectError(error.BadEncoding, parseTarget(a, "/s?q=%4"));
    try testing.expectError(error.BadEncoding, parseTarget(a, "/s?q=%zz"));
    try testing.expectError(error.BadEncoding, parseTarget(a, "/s?q=%ff%fe"));
    const long = try a.alloc(u8, max_target_bytes + 1);
    @memset(long, 'a');
    long[0] = '/';
    try testing.expectError(error.BadEncoding, parseTarget(a, long));
}

test "parseTarget caps the number of parameters" {
    var ar = arenaT();
    defer ar.deinit();
    const a = ar.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "/s?");
    for (0..max_params + 1) |i| try buf.print(a, "k{d}=v&", .{i});
    try testing.expectError(error.TooManyParams, parseTarget(a, buf.items));
}

test "percent escapes at the very end of input are handled" {
    var ar = arenaT();
    defer ar.deinit();
    try testing.expectEqualStrings("a/", try decode(ar.allocator(), "a%2F"));
    try testing.expectError(error.BadEncoding, decode(ar.allocator(), "a%2"));
}

test "writeEncoded round-trips through decode" {
    var ar = arenaT();
    defer ar.deinit();
    var aw: std.Io.Writer.Allocating = .init(ar.allocator());
    try writeEncoded(&aw.writer, "a b&c=d/é\"<>");
    const enc = aw.written();
    try testing.expectEqualStrings("a%20b%26c%3Dd%2F%C3%A9%22%3C%3E", enc);
    try testing.expectEqualStrings("a b&c=d/é\"<>", try decode(ar.allocator(), enc));
}

test "random request targets never crash the parser" {
    var prng = std.Random.DefaultPrng.init(0x91e7);
    const rnd = prng.random();
    const alphabet = "/?&=%+ab01AF\x00\x7f\xff\xc3\xa9 \t";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for (0..4000) |_| {
        _ = arena_state.reset(.retain_capacity);
        var buf: [120]u8 = undefined;
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        const t = parseTarget(arena_state.allocator(), buf[0..len]) catch continue;
        // Whatever parsed must be valid UTF-8 and addressable.
        try testing.expect(std.unicode.utf8ValidateSlice(t.path));
        _ = t.params.get("q");
    }
}
