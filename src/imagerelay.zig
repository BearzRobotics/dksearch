//! The image relay (docs/decisions/0052): fetches one picture of the web when someone looks at it and hands it on, so the
//! search page can show pictures found by the crawler without the visitor's browser contacting the source and without
//! anything being stored here. It only fetches addresses the caller names (the handler takes them from the index, never
//! from the request), refuses private and local addresses, follows a few redirects (each checked again), accepts only
//! answers whose type is a picture and caps their size and how many are fetched at once.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const have_http = build_options.crawler;
const fetch = if (have_http) @import("connectors/crawl/fetch.zig") else struct {};
const crawl = if (have_http) @import("connectors/crawl.zig") else struct {};

pub const Error = error{ Busy, BadAddress, Refused, TooLarge, Unreachable, NotAnImage, NotAvailable, OutOfMemory };

pub const Image = struct { content_type: []const u8, bytes: []const u8 };

pub const Relay = struct {
    gpa: Allocator,
    io: Io,
    max_bytes: usize = 8 * 1024 * 1024,
    max_concurrent: u32 = 6,
    timeout_s: u32 = 15,
    /// Tests only: allow addresses on this machine.
    allow_private: bool = false,
    busy: std.atomic.Value(u32) = .init(0),

    /// Fetches the picture at `url` (http or https). Everything returned is allocated from `arena`.
    pub fn fetchImage(self: *Relay, arena: Allocator, url: []const u8) Error!Image {
        if (!have_http) return error.NotAvailable;
        if (self.busy.fetchAdd(1, .acq_rel) >= self.max_concurrent) {
            _ = self.busy.fetchSub(1, .acq_rel);
            return error.Busy;
        }
        defer _ = self.busy.fetchSub(1, .acq_rel);
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();
        var current = url;
        var hops: u32 = 0;
        while (true) : (hops += 1) {
            const uri = std.Uri.parse(current) catch return error.BadAddress;
            if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.BadAddress;
            const host_c = uri.host orelse return error.BadAddress;
            const host = switch (host_c) {
                .raw, .percent_encoded => |h| h,
            };
            if (host.len == 0) return error.BadAddress;
            if (uri.user != null or uri.password != null) return error.BadAddress;
            if (!self.allow_private and crawl.resolvesToPrivate(self.io, host)) return error.Refused;
            const resp = fetch.get(&client, arena, .{
                .url = current,
                .user_agent = "dksearch-image-relay/0.1",
                .accept = "image/*",
                .max_body_bytes = self.max_bytes,
            }, .fromSeconds(self.timeout_s)) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooLarge => error.TooLarge,
                else => error.Unreachable,
            };
            if (resp.status >= 300 and resp.status < 400) {
                if (hops >= 3) return error.Refused;
                const loc = resp.location orelse return error.Refused;
                current = (try resolveLocation(arena, current, loc)) orelse return error.Refused;
                continue;
            }
            if (resp.status != 200) return error.Refused;
            const ct = resp.content_type orelse return error.NotAnImage;
            const media = std.mem.trim(u8, ct[0 .. std.mem.indexOfScalar(u8, ct, ';') orelse ct.len], " ");
            if (!std.ascii.startsWithIgnoreCase(media, "image/") or media.len > 40) return error.NotAnImage;
            return .{ .content_type = try arena.dupe(u8, media), .bytes = resp.body };
        }
    }
};

fn resolveLocation(arena: Allocator, base: []const u8, loc: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.indexOf(u8, loc, "://") != null) return try arena.dupe(u8, loc);
    const at = std.mem.indexOf(u8, base, "://") orelse return null;
    const origin_end = std.mem.indexOfScalarPos(u8, base, at + 3, '/') orelse base.len;
    if (loc.len > 1 and loc[0] == '/' and loc[1] == '/') return try std.fmt.allocPrint(arena, "{s}:{s}", .{ base[0..at], loc });
    if (loc.len > 0 and loc[0] == '/') return try std.fmt.allocPrint(arena, "{s}{s}", .{ base[0..origin_end], loc });
    return null; // a path relative to the redirecting address is not followed
}

const testing = std.testing;
const nettest = @import("connectors/nettest.zig");

test "a picture is fetched and handed on; anything else, other kinds of answers and oversized pictures are refused" {
    if (!have_http) return error.SkipZigTest;
    var srv: nettest.TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/pic.png", .content_type = "image/png", .body = "\x89PNG-not-really-but-typed-as-a-picture" },
        .{ .path = "/moved", .status = 302, .location = "/pic.png" },
        .{ .path = "/page.html", .content_type = "text/html", .body = "<p>not a picture</p>" },
        .{ .path = "/big.jpg", .content_type = "image/jpeg", .body = nettest.big_body },
        .{ .path = "/gone.png", .status = 404, .content_type = "image/png", .body = "x" },
    });
    defer srv.stop();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var ub: [96]u8 = undefined;
    const base = srv.url(&ub, "");
    var relay: Relay = .{ .gpa = testing.allocator, .io = testing.io, .allow_private = true, .max_bytes = 1000 };
    const got = try relay.fetchImage(a, try std.fmt.allocPrint(a, "{s}/pic.png", .{base}));
    try testing.expectEqualStrings("image/png", got.content_type);
    try testing.expect(std.mem.startsWith(u8, got.bytes, "\x89PNG"));
    // A redirect to a picture is followed.
    try testing.expectEqualStrings("image/png", (try relay.fetchImage(a, try std.fmt.allocPrint(a, "{s}/moved", .{base}))).content_type);
    // Not a picture, too large, missing, not an http address.
    try testing.expectError(error.NotAnImage, relay.fetchImage(a, try std.fmt.allocPrint(a, "{s}/page.html", .{base})));
    try testing.expectError(error.TooLarge, relay.fetchImage(a, try std.fmt.allocPrint(a, "{s}/big.jpg", .{base})));
    try testing.expectError(error.Refused, relay.fetchImage(a, try std.fmt.allocPrint(a, "{s}/gone.png", .{base})));
    try testing.expectError(error.BadAddress, relay.fetchImage(a, "ftp://example.org/x.png"));
    try testing.expectError(error.BadAddress, relay.fetchImage(a, "http://user:pw@example.org/x.png"));
    // This machine's own addresses are refused unless the test allows them.
    var strict: Relay = .{ .gpa = testing.allocator, .io = testing.io };
    try testing.expectError(error.Refused, strict.fetchImage(a, try std.fmt.allocPrint(a, "{s}/pic.png", .{base})));
    // Too many at once: refused at once, not queued.
    var one: Relay = .{ .gpa = testing.allocator, .io = testing.io, .allow_private = true, .max_concurrent = 0 };
    try testing.expectError(error.Busy, one.fetchImage(a, try std.fmt.allocPrint(a, "{s}/pic.png", .{base})));
    try testing.expectEqual(@as(u32, 0), one.busy.load(.monotonic));
}
