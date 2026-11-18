//! Fetching from hidden networks, for the crawler (docs/decisions/0044): `.onion` sites through a Tor daemon's SOCKS5
//! port and `.i2p` sites through an I2P router's HTTP proxy. Both run on the owner's machine; dksearch starts neither.
//!
//! The site's name is handed to the proxy as a name (SOCKS5 "domain name" address, or the absolute URL of an HTTP
//! proxy request) and is never resolved here, so nothing about it reaches the local resolver or the open internet.
//! Only `http://` is spoken: an onion or I2P address already authenticates and encrypts the connection, and a
//! certificate for such a name is rare.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = Io.net;
const fetch = @import("fetch.zig");

pub const Via = union(enum) {
    direct,
    /// A Tor SOCKS5 proxy (usually 127.0.0.1:9050).
    tor: net.IpAddress,
    /// An I2P HTTP proxy (usually 127.0.0.1:4444).
    i2p: net.IpAddress,
};

/// The hidden network a host belongs to, by its top-level name.
pub const Network = enum { onion, i2p };

pub fn networkOf(host: []const u8) ?Network {
    var buf: [256]u8 = undefined;
    if (host.len == 0 or host.len > buf.len) return null;
    const h = std.mem.trimEnd(u8, std.ascii.lowerString(&buf, host), ".");
    if (std.mem.endsWith(u8, h, ".onion") or std.mem.eql(u8, h, "onion")) return .onion;
    if (std.mem.endsWith(u8, h, ".i2p") or std.mem.eql(u8, h, "i2p")) return .i2p;
    return null;
}

/// `host:port` of a proxy as an address; only literal IP addresses (the proxy is on this machine or on a network the
/// owner names by address).
pub fn parseProxy(text: []const u8) ?net.IpAddress {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    if (port == 0) return null;
    return net.IpAddress.parse(text[0..colon], port) catch null;
}

const max_head_bytes = 16 * 1024;

pub fn run(io: Io, arena: Allocator, req: fetch.Request, via: Via) fetch.Failure!fetch.Response {
    const proxy = switch (via) {
        .direct => unreachable,
        .tor => |a| a,
        .i2p => |a| a,
    };
    const target = splitUrl(req.url) orelse return error.BadUrl;
    var stream = proxy.connect(io, .{ .mode = .stream }) catch |e| return if (e == error.Canceled) error.Canceled else error.Network;
    defer stream.close(io);
    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var wbuf: [2048]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    const r = &reader.interface;
    const w = &writer.interface;

    if (via == .tor) try socksConnect(r, w, target.host, target.port);

    // The request. An HTTP proxy is asked for the absolute address; a SOCKS tunnel for the path.
    const request_target = if (via == .i2p) req.url else target.path;
    w.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nAccept: {s}\r\nAccept-Encoding: identity\r\nConnection: close\r\n", .{ request_target, target.hostport, req.user_agent, req.accept }) catch return error.Network;
    if (req.if_none_match) |v| w.print("If-None-Match: {s}\r\n", .{v}) catch return error.Network;
    if (req.if_modified_since) |v| w.print("If-Modified-Since: {s}\r\n", .{v}) catch return error.Network;
    w.writeAll("\r\n") catch return error.Network;
    w.flush() catch return error.Network;

    // The status line and headers.
    const status_line = readLine(r, arena) orelse return error.BadResponse;
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.BadResponse;
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts.next();
    const status = std.fmt.parseInt(u16, parts.next() orelse return error.BadResponse, 10) catch return error.BadResponse;
    var out: fetch.Response = .{ .status = status };
    var content_length: ?usize = null;
    var chunked = false;
    var head_bytes: usize = status_line.len;
    while (true) {
        const line = readLine(r, arena) orelse return error.BadResponse;
        head_bytes += line.len;
        if (head_bytes > max_head_bytes) return error.BadResponse;
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.findIgnoreCase(value, "chunked") != null) chunked = true;
        if (std.ascii.eqlIgnoreCase(name, "content-encoding") and !std.ascii.eqlIgnoreCase(value, "identity")) return error.BadResponse;
        if (std.ascii.eqlIgnoreCase(name, "location")) out.location = arena.dupe(u8, value) catch return error.OutOfMemory;
        if (std.ascii.eqlIgnoreCase(name, "content-type")) out.content_type = arena.dupe(u8, value) catch return error.OutOfMemory;
        if (std.ascii.eqlIgnoreCase(name, "etag") and value.len <= 300) out.etag = arena.dupe(u8, value) catch return error.OutOfMemory;
        if (std.ascii.eqlIgnoreCase(name, "last-modified") and value.len <= 100) out.last_modified = arena.dupe(u8, value) catch return error.OutOfMemory;
    }
    if (status < 200 or status >= 300) return out;
    if (content_length) |n| if (n > req.max_body_bytes) return error.TooLarge;

    if (chunked) {
        var body: std.ArrayList(u8) = .empty;
        while (true) {
            const size_line = readLine(r, arena) orelse return error.BadResponse;
            const semi = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
            const size = std.fmt.parseInt(usize, std.mem.trim(u8, size_line[0..semi], " "), 16) catch return error.BadResponse;
            if (size == 0) break;
            if (body.items.len + size > req.max_body_bytes) return error.TooLarge;
            const at = body.items.len;
            body.resize(arena, at + size) catch return error.OutOfMemory;
            r.readSliceAll(body.items[at..]) catch return error.Network;
            _ = readLine(r, arena) orelse return error.BadResponse; // the CRLF after the chunk
        }
        out.body = body.items;
    } else if (content_length) |n| {
        const buf = arena.alloc(u8, n) catch return error.OutOfMemory;
        r.readSliceAll(buf) catch return error.Network;
        out.body = buf;
    } else {
        out.body = r.allocRemaining(arena, .limited(req.max_body_bytes)) catch |e| switch (e) {
            error.StreamTooLong => return error.TooLarge,
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.Network,
        };
    }
    return out;
}

/// One line without its line end; null at the end of the stream or when it is absurdly long.
fn readLine(r: *Io.Reader, arena: Allocator) ?[]const u8 {
    const line = r.takeDelimiterInclusive('\n') catch return null;
    if (line.len > max_head_bytes) return null;
    return arena.dupe(u8, std.mem.trimEnd(u8, line, "\r\n")) catch null;
}

const Target = struct { host: []const u8, port: u16, hostport: []const u8, path: []const u8 };

fn splitUrl(url: []const u8) ?Target {
    const prefix = "http://";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) return null;
    const rest = url[prefix.len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const hostport = rest[0..end];
    if (hostport.len == 0 or std.mem.indexOfScalar(u8, hostport, '@') != null) return null;
    var host = hostport;
    var port: u16 = 80;
    if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |c| {
        host = hostport[0..c];
        port = std.fmt.parseInt(u16, hostport[c + 1 ..], 10) catch return null;
    }
    if (host.len == 0 or host.len > 255) return null;
    var path = rest[end..];
    if (path.len == 0 or path[0] != '/') path = if (path.len == 0) "/" else path; // "?x" without a path is left to the server
    return .{ .host = host, .port = port, .hostport = hostport, .path = path };
}

/// RFC 1928 with no authentication: the name is sent as a domain name, so Tor resolves it (inside the network).
fn socksConnect(r: *Io.Reader, w: *Io.Writer, host: []const u8, port: u16) fetch.Failure!void {
    w.writeAll(&.{ 5, 1, 0 }) catch return error.Network;
    w.flush() catch return error.Network;
    var reply: [2]u8 = undefined;
    r.readSliceAll(&reply) catch return error.Network;
    if (reply[0] != 5 or reply[1] != 0) return error.BadResponse;
    var head: [5]u8 = .{ 5, 1, 0, 3, @intCast(host.len) };
    w.writeAll(&head) catch return error.Network;
    w.writeAll(host) catch return error.Network;
    w.writeAll(&.{ @intCast(port >> 8), @intCast(port & 0xff) }) catch return error.Network;
    w.flush() catch return error.Network;
    var rep: [4]u8 = undefined;
    r.readSliceAll(&rep) catch return error.Network;
    if (rep[0] != 5) return error.BadResponse;
    // 0 succeeded; anything else (host unreachable, refused, TTL expired, ...) means the site cannot be reached.
    if (rep[1] != 0) return error.Network;
    const skip: usize = switch (rep[3]) {
        1 => 4 + 2,
        4 => 16 + 2,
        3 => blk: {
            const n = r.takeByte() catch return error.Network;
            break :blk @as(usize, n) + 2;
        },
        else => return error.BadResponse,
    };
    r.discardAll(skip) catch return error.Network;
}

const testing = std.testing;

/// A pretend Tor: speaks SOCKS5, records the name it was asked for, then answers the HTTP request that follows.
pub const FakeProxy = struct {
    listener: net.Server,
    future: Io.Future(void),
    mode: enum { tor, i2p },
    /// Connections accepted, whatever came of them.
    connections: usize = 0,
    asked_host: [64]u8 = undefined,
    asked_len: usize = 0,
    asked_target: [128]u8 = undefined,
    target_len: usize = 0,
    reply: []const u8,
    refuse: bool = false,

    pub fn start(p: *FakeProxy, mode: @TypeOf(p.mode), reply: []const u8) !void {
        p.* = .{
            .listener = try (try net.IpAddress.parseIp4("127.0.0.1", 0)).listen(testing.io, .{ .reuse_address = true }),
            .future = undefined,
            .mode = mode,
            .reply = reply,
        };
        p.future = try testing.io.concurrent(loop, .{p});
    }
    pub fn stop(p: *FakeProxy) void {
        _ = p.future.cancel(testing.io);
        p.listener.deinit(testing.io);
    }
    pub fn address(p: *FakeProxy) net.IpAddress {
        return p.listener.socket.address;
    }
    fn loop(p: *FakeProxy) void {
        while (true) {
            const s = p.listener.accept(testing.io) catch return;
            p.connections += 1;
            defer s.close(testing.io);
            p.handle(s) catch return;
        }
    }
    fn handle(p: *FakeProxy, s: net.Stream) !void {
        var rbuf: [1024]u8 = undefined;
        var r = s.reader(testing.io, &rbuf);
        var wbuf: [1024]u8 = undefined;
        var w = s.writer(testing.io, &wbuf);
        if (p.mode == .tor) {
            var g: [3]u8 = undefined;
            try r.interface.readSliceAll(&g);
            try w.interface.writeAll(&.{ 5, 0 });
            try w.interface.flush();
            var h: [5]u8 = undefined;
            try r.interface.readSliceAll(&h);
            p.asked_len = h[4];
            try r.interface.readSliceAll(p.asked_host[0..p.asked_len]);
            var port: [2]u8 = undefined;
            try r.interface.readSliceAll(&port);
            if (p.refuse) {
                try w.interface.writeAll(&.{ 5, 4, 0, 1, 0, 0, 0, 0, 0, 0 });
                try w.interface.flush();
                return;
            }
            try w.interface.writeAll(&.{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 });
            try w.interface.flush();
        }
        // The request head.
        var head: [1024]u8 = undefined;
        var n: usize = 0;
        while (n < head.len) {
            head[n] = try r.interface.takeByte();
            n += 1;
            if (n >= 4 and std.mem.eql(u8, head[n - 4 .. n], "\r\n\r\n")) break;
        }
        const first_end = std.mem.indexOfScalar(u8, head[0..n], '\r') orelse n;
        const line = head[0..first_end];
        const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse 0;
        const sp2 = std.mem.lastIndexOfScalar(u8, line, ' ') orelse line.len;
        const tgt = line[sp1 + 1 .. sp2];
        p.target_len = @min(tgt.len, p.asked_target.len);
        @memcpy(p.asked_target[0..p.target_len], tgt[0..p.target_len]);
        try w.interface.writeAll(p.reply);
        try w.interface.flush();
    }
};

fn testRequest(url: []const u8) fetch.Request {
    return .{ .url = url, .user_agent = "dksearch-test/1.0", .accept = "text/html", .max_body_bytes = 1 << 16 };
}

test "an onion address is handed to Tor by name and the page comes back, with a length or in chunks" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var p: FakeProxy = undefined;
    try p.start(.tor, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 11\r\nETag: \"v1\"\r\n\r\nhello onion");
    defer p.stop();
    const got = try run(testing.io, ar.allocator(), testRequest("http://abcdefghij234567.onion/a/b?x=1"), .{ .tor = p.address() });
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqualStrings("hello onion", got.body);
    try testing.expectEqualStrings("text/html", got.content_type.?);
    try testing.expectEqualStrings("\"v1\"", got.etag.?);
    try testing.expectEqualStrings("abcdefghij234567.onion", p.asked_host[0..p.asked_len]); // the name, never an address
    try testing.expectEqualStrings("/a/b?x=1", p.asked_target[0..p.target_len]);

    var c: FakeProxy = undefined;
    try c.start(.tor, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n onion\r\n0\r\n\r\n");
    defer c.stop();
    const chunked = try run(testing.io, ar.allocator(), testRequest("http://x.onion:8080/"), .{ .tor = c.address() });
    try testing.expectEqualStrings("hello onion", chunked.body);
}

test "an I2P site is asked for through the router's HTTP proxy with its absolute address" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var p: FakeProxy = undefined;
    try p.start(.i2p, "HTTP/1.1 301 Moved\r\nLocation: http://other.i2p/new\r\nContent-Length: 0\r\n\r\n");
    defer p.stop();
    const got = try run(testing.io, ar.allocator(), testRequest("http://example.i2p/page"), .{ .i2p = p.address() });
    try testing.expectEqual(@as(u16, 301), got.status);
    try testing.expectEqualStrings("http://other.i2p/new", got.location.?);
    try testing.expectEqualStrings("http://example.i2p/page", p.asked_target[0..p.target_len]);
}

test "a refused tunnel, a too-large page, https and a missing proxy are failures, not hangs" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var p: FakeProxy = undefined;
    try p.start(.tor, "");
    p.refuse = true;
    defer p.stop();
    try testing.expectError(error.Network, run(testing.io, ar.allocator(), testRequest("http://down.onion/"), .{ .tor = p.address() }));
    var big: FakeProxy = undefined;
    try big.start(.tor, "HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n\r\n");
    defer big.stop();
    try testing.expectError(error.TooLarge, run(testing.io, ar.allocator(), testRequest("http://big.onion/"), .{ .tor = big.address() }));
    try testing.expectError(error.BadUrl, run(testing.io, ar.allocator(), testRequest("https://secure.onion/"), .{ .tor = p.address() }));
    try testing.expectError(error.Network, run(testing.io, ar.allocator(), testRequest("http://x.onion/"), .{ .tor = try net.IpAddress.parse("127.0.0.1", 1) }));
}

test "hosts of the hidden networks are told apart, and proxies are literal addresses" {
    try testing.expectEqual(Network.onion, networkOf("abc.onion").?);
    try testing.expectEqual(Network.onion, networkOf("ABC.Onion.").?);
    try testing.expectEqual(Network.i2p, networkOf("forum.i2p").?);
    try testing.expect(networkOf("example.org") == null);
    try testing.expect(networkOf("notonion.com") == null);
    try testing.expect(networkOf("x.onion.evil.net") == null);
    try testing.expect(parseProxy("127.0.0.1:9050") != null);
    try testing.expect(parseProxy("127.0.0.1") == null);
    try testing.expect(parseProxy("tor.local:9050") == null);
    try testing.expect(parseProxy("127.0.0.1:0") == null);
}
