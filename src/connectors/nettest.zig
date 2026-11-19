//! Test support for the network connectors: a small HTTP server on a loopback
//! port that serves canned routes and records what it was asked, and a sink
//! that collects documents. Only imported from tests.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const api = @import("../connector.zig");
const doc = @import("../document.zig");

// A tiny HTTP server for tests: serves canned routes on a loopback port and
// records what it was asked.
pub const big_body: []const u8 = "<p>" ++ &@as([5000]u8, @splat('x')) ++ "</p>";

pub const Route = struct {
    path: []const u8,
    status: u16 = 200,
    content_type: []const u8 = "text/html; charset=utf-8",
    body: []const u8 = "",
    location: ?[]const u8 = null,
    /// Stall this long before answering (to test the deadline).
    stall_ms: i64 = 0,
    /// Sent as `ETag`; a request with the same `If-None-Match` is answered 304 without a body.
    etag: ?[]const u8 = null,
    /// Answer 429 (with `retry_after`, if set) to the first this-many requests of this path, then as the route says.
    refuse_first: u32 = 0,
    retry_after: ?[]const u8 = null,
};

pub const TestServer = struct {
    listener: net.Server,
    port: u16,
    routes: []const Route,
    future: Io.Future(void),
    mutex: Io.Mutex = .init,
    paths: std.ArrayList([]u8) = .empty,
    agents: std.ArrayList([]u8) = .empty,
    times: std.ArrayList(i96) = .empty,
    /// How many requests carried `If-None-Match`.
    conditional: usize = 0,

    pub fn start(s: *TestServer, routes: []const Route) !void {
        try s.open();
        try s.serve(routes);
    }

    /// Listens, so the port is known before the routes are (bodies may name it).
    pub fn open(s: *TestServer) !void {
        return s.openAt("127.0.0.1");
    }

    pub fn openAt(s: *TestServer, ip: []const u8) !void {
        s.* = .{
            .listener = try (try net.IpAddress.parseIp4(ip, 0)).listen(testing.io, .{ .reuse_address = true }),
            .port = 0,
            .routes = &.{},
            .future = undefined,
        };
        s.port = s.listener.socket.address.getPort();
    }

    pub fn serve(s: *TestServer, routes: []const Route) !void {
        s.routes = routes;
        s.future = try testing.io.concurrent(loop, .{s});
    }

    pub fn stop(s: *TestServer) void {
        _ = s.future.cancel(testing.io);
        s.listener.deinit(testing.io);
        for (s.paths.items) |p| testing.allocator.free(p);
        for (s.agents.items) |p| testing.allocator.free(p);
        s.paths.deinit(testing.allocator);
        s.agents.deinit(testing.allocator);
        s.times.deinit(testing.allocator);
    }

    pub fn url(s: *TestServer, buf: []u8, path: []const u8) []const u8 {
        return s.urlAt(buf, "127.0.0.1", path);
    }

    pub fn urlAt(s: *TestServer, buf: []u8, ip: []const u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://{s}:{d}{s}", .{ ip, s.port, path }) catch unreachable;
    }

    pub fn count(s: *TestServer, path: []const u8) usize {
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        var n: usize = 0;
        for (s.paths.items) |p| if (std.mem.eql(u8, p, path)) {
            n += 1;
        };
        return n;
    }

    pub fn loop(s: *TestServer) void {
        while (true) {
            const stream = s.listener.accept(testing.io) catch return;
            defer stream.close(testing.io);
            s.handle(stream) catch |e| if (e == error.Canceled) return;
        }
    }

    pub fn handle(s: *TestServer, stream: net.Stream) !void {
        const io = testing.io;
        var rbuf: [4096]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        var wbuf: [1024]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        // Read the request head.
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(testing.allocator);
        while (std.mem.indexOf(u8, head.items, "\r\n\r\n") == null) {
            const b = r.interface.takeByte() catch return;
            try head.append(testing.allocator, b);
            if (head.items.len > 8192) return;
        }
        var lines = std.mem.splitSequence(u8, head.items, "\r\n");
        const first = lines.next() orelse return;
        var parts = std.mem.splitScalar(u8, first, ' ');
        _ = parts.next();
        const path = parts.next() orelse return;
        var agent: []const u8 = "";
        var if_none_match: ?[]const u8 = null;
        while (lines.next()) |l| {
            if (std.ascii.startsWithIgnoreCase(l, "user-agent:")) agent = std.mem.trim(u8, l[11..], " ");
            if (std.ascii.startsWithIgnoreCase(l, "if-none-match:")) if_none_match = std.mem.trim(u8, l["if-none-match:".len..], " ");
        }
        {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            try s.paths.append(testing.allocator, try testing.allocator.dupe(u8, path));
            try s.agents.append(testing.allocator, try testing.allocator.dupe(u8, agent));
            try s.times.append(testing.allocator, Io.Timestamp.now(io, .awake).nanoseconds);
            if (if_none_match != null) s.conditional += 1;
        }
        var found: ?Route = null;
        for (s.routes) |rt| if (std.mem.eql(u8, rt.path, path)) {
            found = rt;
        };
        const rt = found orelse Route{ .path = path, .status = 404, .content_type = "text/plain", .body = "not found" };
        if (rt.stall_ms > 0) try io.sleep(.fromMilliseconds(rt.stall_ms), .awake);
        if (rt.etag) |tag| if (if_none_match) |inm| if (std.mem.eql(u8, tag, inm)) {
            try w.interface.print("HTTP/1.1 304 Not Modified\r\netag: {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{tag});
            try w.interface.flush();
            return;
        };
        const refused = rt.refuse_first > 0 and s.count(path) <= rt.refuse_first;
        const status: u16 = if (refused) 429 else rt.status;
        const body: []const u8 = if (refused) "" else rt.body;
        try w.interface.print("HTTP/1.1 {d} X\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: close\r\n", .{ status, rt.content_type, body.len });
        if (refused) if (rt.retry_after) |ra| try w.interface.print("retry-after: {s}\r\n", .{ra});
        if (rt.etag) |tag| try w.interface.print("etag: {s}\r\n", .{tag});
        if (rt.location) |l| try w.interface.print("location: {s}\r\n", .{l});
        try w.interface.writeAll("\r\n");
        try w.interface.writeAll(body);
        try w.interface.flush();
    }
};

pub const Collect = struct {
    titles: std.ArrayList([]u8) = .empty,
    ids: std.ArrayList([]u8) = .empty,
    texts: std.ArrayList([]u8) = .empty,
    pub fn deinit(c: *Collect) void {
        for (c.titles.items) |t| testing.allocator.free(t);
        for (c.ids.items) |t| testing.allocator.free(t);
        for (c.texts.items) |t| testing.allocator.free(t);
        c.titles.deinit(testing.allocator);
        c.ids.deinit(testing.allocator);
        c.texts.deinit(testing.allocator);
    }
    pub fn submit(ptr: *anyopaque, d: doc.Document) api.Sink.Error!void {
        const c: *Collect = @ptrCast(@alignCast(ptr));
        try c.titles.append(testing.allocator, try testing.allocator.dupe(u8, d.title orelse ""));
        try c.ids.append(testing.allocator, try testing.allocator.dupe(u8, d.source_id));
        try c.texts.append(testing.allocator, try testing.allocator.dupe(u8, d.text orelse ""));
    }
    pub fn sink(c: *Collect) api.Sink {
        return .{ .ptr = c, .vtable = &.{ .submit = submit } };
    }
};
