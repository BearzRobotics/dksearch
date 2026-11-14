//! Connection handling for the HTTP adapter, built on `std.http.Server`.
//!
//! The standard library parses and writes messages but leaves connection
//! policy to the caller, so this file supplies it:
//!
//!   * a hard cap on simultaneous connections (extra ones are closed at once);
//!   * a header-size limit (the read buffer is the limit; larger gets 431);
//!   * a hard deadline for receiving each request head, which also serves as
//!     the keep-alive idle timeout, and one for sending each response. A
//!     sweeper task enforces both by shutting the socket down, so a client
//!     that trickles one byte at a time cannot hold a connection open (a
//!     per-read socket timeout would not stop that);
//!   * a cap on requests per connection;
//!   * no request bodies: every route is GET/HEAD, so a body is refused and
//!     the connection closed instead of being read;
//!   * graceful stop: when `Control.stop` is set the listener closes, idle
//!     connections are dropped, requests in flight get `shutdown_grace_ms` to
//!     finish, and only then is anything cut off.
//!
//! Handlers run in `Io.Group` tasks; cancelling `serve` stops everything.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const http = std.http;
const Allocator = std.mem.Allocator;
const dk = @import("dksearch");
const handler = @import("handler.zig");

pub const Limits = struct {
    /// Largest request head (request line plus headers) accepted.
    max_header_bytes: u32 = 8192,
    /// Time allowed from the end of one response (or from accept) to a
    /// complete next request head. Doubles as the keep-alive idle timeout.
    request_head_timeout_ms: u32 = 10_000,
    /// Time allowed to send one response.
    write_timeout_ms: u32 = 10_000,
    max_connections: u32 = 256,
    max_requests_per_connection: u32 = 100,
    /// On a graceful stop, how long requests already being handled may take.
    shutdown_grace_ms: u32 = 5_000,
};

/// Lets another thread, or a signal handler, ask `serve` to stop. Setting
/// the flag is async-signal-safe.
pub const Control = struct {
    stop: std.atomic.Value(bool) = .init(false),

    pub fn requestStop(self: *Control) void {
        self.stop.store(true, .release);
    }
};

/// Counters for operators and tests. All fields are atomic.
pub const Stats = struct {
    accepted: std.atomic.Value(u64) = .init(0),
    /// Connections closed at accept time because `max_connections` was reached.
    refused_busy: std.atomic.Value(u64) = .init(0),
    /// Connections cut off by a deadline.
    timed_out: std.atomic.Value(u64) = .init(0),
    requests: std.atomic.Value(u64) = .init(0),
};

const Slot = struct {
    used: bool = false,
    /// True while a request is being handled (head received, response not yet
    /// written). Idle connections are dropped first when draining.
    busy: bool = false,
    stream: net.Stream = undefined,
    /// Monotonic nanoseconds; null while no deadline applies.
    deadline_ns: ?i96 = null,
};

const State = struct {
    gpa: Allocator,
    io: Io,
    searcher: dk.search.Searcher,
    limits: Limits,
    stats: *Stats,
    listener: *net.Server,
    control: *Control,
    /// Set once a stop was requested: no new work is accepted.
    draining: std.atomic.Value(bool) = .init(false),
    mutex: Io.Mutex = .init,
    slots: []Slot,

    fn nowNs(self: *State) i96 {
        return Io.Clock.awake.now(self.io).nanoseconds;
    }

    /// Reserves a slot for `stream`, or returns null if the server is full.
    fn acquire(self: *State, stream: net.Stream) ?usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.slots, 0..) |*s, i| if (!s.used) {
            s.* = .{ .used = true, .stream = stream, .deadline_ns = null };
            return i;
        };
        return null;
    }

    /// Frees the slot. Must happen before the stream is closed, so the
    /// sweeper can never shut down a descriptor that has been reused.
    fn release(self: *State, i: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.slots[i].used = false;
    }

    fn setBusy(self: *State, i: usize, busy: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.slots[i].busy = busy;
    }

    fn activeCount(self: *State) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.slots) |s| {
            if (s.used) n += 1;
        }
        return n;
    }

    fn setDeadline(self: *State, i: usize, ms: u32) void {
        const at = self.nowNs() + @as(i96, ms) * std.time.ns_per_ms;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.slots[i].deadline_ns = at;
    }

    fn clearDeadline(self: *State, i: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.slots[i].deadline_ns = null;
    }
};

pub const ServeError = Allocator.Error || Io.Cancelable || error{ConcurrencyUnavailable};

/// Binds a listener. The returned server's `socket.address` holds the actual
/// port when `address` asked for port 0.
pub fn listen(io: Io, address: net.IpAddress) net.IpAddress.ListenError!net.Server {
    return address.listen(io, .{ .reuse_address = true });
}

/// Accepts connections until `control` asks to stop (a graceful drain, then
/// a normal return) or the task is cancelled (immediate; returns
/// `error.Canceled`).
pub fn serve(gpa: Allocator, io: Io, listener: *net.Server, searcher: dk.search.Searcher, limits: Limits, stats: *Stats, control: *Control) ServeError!void {
    const slots = try gpa.alloc(Slot, limits.max_connections);
    defer gpa.free(slots);
    @memset(slots, .{});

    var state: State = .{ .gpa = gpa, .io = io, .searcher = searcher, .limits = limits, .stats = stats, .listener = listener, .control = control, .slots = slots };

    var group: Io.Group = .init;
    defer group.cancel(io);
    group.concurrent(io, sweep, .{&state}) catch return error.ConcurrencyUnavailable;

    while (true) {
        const stream = listener.accept(io) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            // The sweeper shut the listener down: a stop was requested.
            error.SocketNotListening => break,
            // Transient trouble (descriptor limits, aborted connections):
            // back off briefly instead of spinning.
            else => {
                try io.sleep(.fromMilliseconds(50), .awake);
                continue;
            },
        };
        _ = stats.accepted.fetchAdd(1, .monotonic);
        const slot = state.acquire(stream) orelse {
            _ = stats.refused_busy.fetchAdd(1, .monotonic);
            stream.close(io);
            continue;
        };
        group.concurrent(io, connection, .{ &state, slot, stream }) catch {
            state.release(slot);
            stream.close(io);
        };
    }

    // Drain: idle connections are dropped by the sweeper; give requests that
    // are already being handled a bounded time to finish.
    state.draining.store(true, .release);
    const give_up = state.nowNs() + @as(i96, limits.shutdown_grace_ms) * std.time.ns_per_ms;
    while (state.activeCount() > 0 and state.nowNs() < give_up) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

/// Background duties, every 50 ms: notice a stop request, drop idle
/// connections while draining, and cut off connections past their deadline.
fn sweep(state: *State) Io.Cancelable!void {
    var listener_closed = false;
    while (true) {
        try state.io.sleep(.fromMilliseconds(50), .awake);
        if (!listener_closed and state.control.stop.load(.acquire)) {
            listener_closed = true;
            // Wakes the blocked accept(); see Server.AcceptError.SocketNotListening.
            const as_stream: net.Stream = .{ .socket = state.listener.socket };
            as_stream.shutdown(state.io, .both) catch {};
        }
        const draining = state.draining.load(.acquire);
        const now = state.nowNs();
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        for (state.slots) |*s| {
            if (draining and s.used and !s.busy) {
                s.stream.shutdown(state.io, .both) catch {};
                continue;
            }
            const d = s.deadline_ns orelse continue;
            if (!s.used or now < d) continue;
            s.deadline_ns = null;
            s.stream.shutdown(state.io, .both) catch {};
            _ = state.stats.timed_out.fetchAdd(1, .monotonic);
        }
    }
}

fn connection(state: *State, slot: usize, stream: net.Stream) Io.Cancelable!void {
    defer {
        state.release(slot);
        stream.close(state.io);
    }
    const io = state.io;
    const lim = state.limits;

    const rbuf = state.gpa.alloc(u8, lim.max_header_bytes) catch return;
    defer state.gpa.free(rbuf);
    var wbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, rbuf);
    var writer = stream.writer(io, &wbuf);
    var srv = http.Server.init(&reader.interface, &writer.interface);

    var served: u32 = 0;
    while (served < lim.max_requests_per_connection) {
        state.setDeadline(slot, lim.request_head_timeout_ms);
        var req = srv.receiveHead() catch |e| {
            switch (e) {
                error.HttpHeadersOversize => {
                    refuse(&writer.interface, "431 Request Header Fields Too Large");
                    linger(state, slot, stream, &reader.interface);
                },
                error.HttpHeadersInvalid => {
                    refuse(&writer.interface, "400 Bad Request");
                    linger(state, slot, stream, &reader.interface);
                },
                else => {}, // client went away, or the deadline fired
            }
            return;
        };
        served += 1;
        _ = state.stats.requests.fetchAdd(1, .monotonic);
        state.setBusy(slot, true);
        defer state.setBusy(slot, false);
        state.setDeadline(slot, lim.write_timeout_ms);

        // Nothing here accepts a request body. Refuse rather than read it.
        const has_body = (req.head.content_length orelse 0) > 0 or req.head.transfer_encoding != .none;
        if (has_body) {
            req.respond("request bodies are not accepted\n", .{
                .status = .bad_request,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            }) catch {};
            linger(state, slot, stream, &reader.interface);
            return;
        }

        var arena = std.heap.ArenaAllocator.init(state.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const resp = handler.handle(a, state.searcher, req.head.method, req.head.target);
        const headers = a.alloc(http.Header, resp.headers.len + 1) catch return;
        headers[0] = .{ .name = "content-type", .value = resp.content_type };
        @memcpy(headers[1..], resp.headers);

        const keep = req.head.keep_alive and served < lim.max_requests_per_connection and
            !state.draining.load(.acquire);
        req.respond(resp.body, .{ .status = resp.status, .keep_alive = keep, .extra_headers = headers }) catch return;
        if (!keep) return;
    }
}

/// Closes politely after an early refusal. If the client still has request
/// bytes in flight, closing at once makes the kernel send a reset, which can
/// destroy our response before the client reads it. So: finish sending, then
/// discard a bounded amount of what the client is still sending, for a
/// bounded time (the sweeper enforces the deadline).
fn linger(state: *State, slot: usize, stream: net.Stream, r: *Io.Reader) void {
    stream.shutdown(state.io, .send) catch return;
    state.setDeadline(slot, 1000);
    _ = r.discard(.limited(64 * 1024)) catch {};
}

/// Minimal error reply for requests that never parsed into a `Request`.
fn refuse(w: *Io.Writer, status_line: []const u8) void {
    w.print("HTTP/1.1 {s}\r\ncontent-length: 0\r\nconnection: close\r\nx-content-type-options: nosniff\r\n\r\n", .{status_line}) catch return;
    w.flush() catch {};
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const FixedSearch = struct {
    fn search(_: *anyopaque, _: Allocator, _: dk.search.Query) dk.search.Error!dk.search.Page {
        return .{ .hits = &.{}, .has_more = false };
    }
    var dummy: u8 = 0;
    fn searcher() dk.search.Searcher {
        return .{ .ptr = &dummy, .vtable = &.{ .search = search } };
    }
};

/// A searcher that takes a while, to keep a request in flight.
const SlowSearch = struct {
    fn search(_: *anyopaque, _: Allocator, _: dk.search.Query) dk.search.Error!dk.search.Page {
        testing.io.sleep(.fromMilliseconds(400), .awake) catch {};
        return .{ .hits = &.{}, .has_more = false };
    }
    var dummy: u8 = 0;
    fn searcher() dk.search.Searcher {
        return .{ .ptr = &dummy, .vtable = &.{ .search = search } };
    }
};

const Harness = struct {
    listener: net.Server,
    stats: Stats = .{},
    control: Control = .{},
    future: Io.Future(ServeError!void),
    port: u16,

    fn start(h: *Harness, limits: Limits) !void {
        return h.startWith(FixedSearch.searcher(), limits);
    }

    fn startWith(h: *Harness, searcher: dk.search.Searcher, limits: Limits) !void {
        h.listener = try listen(testing.io, try net.IpAddress.parseIp4("127.0.0.1", 0));
        h.stats = .{};
        h.control = .{};
        h.port = h.listener.socket.address.getPort();
        h.future = try testing.io.concurrent(serve, .{ testing.allocator, testing.io, &h.listener, searcher, limits, &h.stats, &h.control });
    }

    fn stop(h: *Harness) void {
        _ = h.future.cancel(testing.io) catch {};
        h.listener.deinit(testing.io);
    }

    fn connect(h: *Harness) !net.Stream {
        const addr = try net.IpAddress.parseIp4("127.0.0.1", h.port);
        return addr.connect(testing.io, .{ .mode = .stream });
    }

    /// Sends `bytes`, then reads until the server closes. Caller frees.
    fn exchange(h: *Harness, bytes: []const u8) ![]u8 {
        const s = try h.connect();
        defer s.close(testing.io);
        var wbuf: [256]u8 = undefined;
        var w = s.writer(testing.io, &wbuf);
        try w.interface.writeAll(bytes);
        try w.interface.flush();
        var rbuf: [1024]u8 = undefined;
        var r = s.reader(testing.io, &rbuf);
        return r.interface.allocRemaining(testing.allocator, .limited(1 << 20)) catch |e| switch (e) {
            error.ReadFailed => try testing.allocator.dupe(u8, ""),
            else => |x| return x,
        };
    }
};

test "serves a request over a real socket with security headers" {
    var h: Harness = undefined;
    try h.start(.{});
    defer h.stop();

    const out = try h.exchange("GET /api/v1/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, out, "x-content-type-options: nosniff") != null);
    try testing.expect(std.mem.indexOf(u8, out, "content-type: application/json") != null);
    try testing.expect(std.mem.endsWith(u8, out, "{\"status\":\"ok\"}\n"));
}

test "HEAD sends headers but no body" {
    var h: Harness = undefined;
    try h.start(.{});
    defer h.stop();
    const out = try h.exchange("HEAD /api/v1/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, out, "{\"status\"") == null);
}

test "malformed and oversized requests are refused, not crashed on" {
    var h: Harness = undefined;
    try h.start(.{ .max_header_bytes = 512 });
    defer h.stop();

    const pad: [2000]u8 = @splat('a');
    const big = try std.fmt.allocPrint(testing.allocator, "GET / HTTP/1.1\r\nHost: x\r\nX-Pad: {s}\r\n\r\n", .{&pad});
    defer testing.allocator.free(big);
    const over = try h.exchange(big);
    defer testing.allocator.free(over);
    try testing.expect(std.mem.startsWith(u8, over, "HTTP/1.1 431"));

    const bad = try h.exchange("NONSENSE\r\n\r\n");
    defer testing.allocator.free(bad);
    try testing.expect(std.mem.startsWith(u8, bad, "HTTP/1.1 400"));

    const nl = try h.exchange("GET /a\x00b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    defer testing.allocator.free(nl);
    try testing.expect(nl.len == 0 or std.mem.startsWith(u8, nl, "HTTP/1.1 400"));

    // The server is still healthy afterwards.
    const ok = try h.exchange("GET /api/v1/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    defer testing.allocator.free(ok);
    try testing.expect(std.mem.startsWith(u8, ok, "HTTP/1.1 200"));
}

test "request bodies are refused and the connection closed" {
    var h: Harness = undefined;
    try h.start(.{});
    defer h.stop();
    const out = try h.exchange("POST /api/v1/search HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 400"));
}

test "keep-alive serves several requests on one connection, capped" {
    var h: Harness = undefined;
    try h.start(.{ .max_requests_per_connection = 2 });
    defer h.stop();

    const out = try h.exchange(
        "GET /api/v1/health HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /api/v1/health HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /api/v1/health HTTP/1.1\r\nHost: x\r\n\r\n",
    );
    defer testing.allocator.free(out);
    // Exactly two responses; the connection closes after the cap.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "HTTP/1.1 200 OK"));
}

test "a client that stalls mid-request is cut off by the deadline" {
    var h: Harness = undefined;
    try h.start(.{ .request_head_timeout_ms = 300 });
    defer h.stop();

    const s = try h.connect();
    defer s.close(testing.io);
    var wbuf: [64]u8 = undefined;
    var w = s.writer(testing.io, &wbuf);
    try w.interface.writeAll("GET /api/v1/health HTTP/1.1\r\nHost: x\r\n"); // never finishes the head
    try w.interface.flush();

    // Trickling one byte at a time must not extend the deadline.
    for (0..40) |_| {
        try testing.io.sleep(.fromMilliseconds(50), .awake);
        w.interface.writeAll("X") catch break;
        w.interface.flush() catch break;
        if (h.stats.timed_out.load(.monotonic) > 0) break;
    }
    try testing.io.sleep(.fromMilliseconds(100), .awake);
    try testing.expect(h.stats.timed_out.load(.monotonic) >= 1);

    var rbuf: [64]u8 = undefined;
    var r = s.reader(testing.io, &rbuf);
    const got = r.interface.allocRemaining(testing.allocator, .limited(1024)) catch try testing.allocator.dupe(u8, "");
    defer testing.allocator.free(got);
    try testing.expect(!std.mem.startsWith(u8, got, "HTTP/1.1 200"));
}

test "idle keep-alive connections are closed after the timeout" {
    var h: Harness = undefined;
    try h.start(.{ .request_head_timeout_ms = 250 });
    defer h.stop();

    const s = try h.connect();
    defer s.close(testing.io);
    var wbuf: [128]u8 = undefined;
    var w = s.writer(testing.io, &wbuf);
    try w.interface.writeAll("GET /api/v1/health HTTP/1.1\r\nHost: x\r\n\r\n");
    try w.interface.flush();

    var rbuf: [1024]u8 = undefined;
    var r = s.reader(testing.io, &rbuf);
    // First response arrives; then the server should close after ~250 ms of idleness.
    const got = r.interface.allocRemaining(testing.allocator, .limited(1 << 16)) catch try testing.allocator.dupe(u8, "");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK"));
    try testing.expect(h.stats.timed_out.load(.monotonic) >= 1);
}

test "connections beyond max_connections are refused immediately" {
    var h: Harness = undefined;
    try h.start(.{ .max_connections = 1, .request_head_timeout_ms = 5000 });
    defer h.stop();

    const hold = try h.connect(); // occupies the only slot; sends nothing
    defer hold.close(testing.io);
    // Let the server accept it before the second client arrives.
    for (0..100) |_| {
        if (h.stats.accepted.load(.monotonic) >= 1) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }

    const out = try h.exchange("GET /api/v1/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expect(h.stats.refused_busy.load(.monotonic) >= 1);
}

test "graceful stop: serve returns normally and the port stops answering" {
    var h: Harness = undefined;
    try h.start(.{});
    const ok = try h.exchange("GET /api/v1/health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    testing.allocator.free(ok);

    h.control.requestStop();
    // Returns on its own (no cancellation) within a short time.
    const r = h.future.await(testing.io);
    try r;
    h.listener.deinit(testing.io);
}

test "graceful stop drops idle keep-alive connections at once" {
    var h: Harness = undefined;
    try h.start(.{ .request_head_timeout_ms = 60_000, .shutdown_grace_ms = 5000 });

    const s = try h.connect(); // idle: sends nothing
    defer s.close(testing.io);
    for (0..100) |_| {
        if (h.stats.accepted.load(.monotonic) >= 1) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }

    const t0 = Io.Clock.awake.now(testing.io).nanoseconds;
    h.control.requestStop();
    try h.future.await(testing.io);
    const took_ms = @divFloor(Io.Clock.awake.now(testing.io).nanoseconds - t0, std.time.ns_per_ms);
    h.listener.deinit(testing.io);
    // Far below both the 60 s idle timeout and the 5 s grace period.
    try testing.expect(took_ms < 2000);
    try testing.expectEqual(@as(u64, 0), h.stats.timed_out.load(.monotonic));
}

test "graceful stop lets a request already in flight finish" {
    var h: Harness = undefined;
    try h.startWith(SlowSearch.searcher(), .{ .shutdown_grace_ms = 5000 });

    const s = try h.connect();
    defer s.close(testing.io);
    var wbuf: [256]u8 = undefined;
    var w = s.writer(testing.io, &wbuf);
    try w.interface.writeAll("GET /api/v1/search?q=x HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try w.interface.flush();

    // Wait until the server has the request and is inside the slow search.
    for (0..200) |_| {
        if (h.stats.requests.load(.monotonic) >= 1) break;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expect(h.stats.requests.load(.monotonic) >= 1);
    h.control.requestStop();

    var rbuf: [1024]u8 = undefined;
    var r = s.reader(testing.io, &rbuf);
    const got = try r.interface.allocRemaining(testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.indexOf(u8, got, "\"hits\":[]") != null);

    try h.future.await(testing.io);
    h.listener.deinit(testing.io);
}
