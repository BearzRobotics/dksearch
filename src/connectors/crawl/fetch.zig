//! One HTTP(S) GET with a hard deadline, a body size cap and no automatic
//! redirects, on Zig's standard HTTP/TLS client.
//!
//! The standard client has no read timeout, so the request runs as one task
//! of an `Io.Select` next to a sleeping task; whichever finishes first wins
//! and the other is cancelled (which interrupts a blocked read or connect).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;

pub const Failure = error{
    /// Could not connect or the connection broke.
    Network,
    Timeout,
    /// The TLS handshake or certificate check failed.
    Tls,
    BadUrl,
    /// The response was not valid HTTP or used an unsupported encoding.
    BadResponse,
    TooLarge,
    Canceled,
    OutOfMemory,
};

pub const Response = struct {
    status: u16,
    /// `Location` of a redirect, if any. Allocated in the caller's arena.
    location: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    /// `ETag` and `Last-Modified` of the answer, to ask again conditionally next time.
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    /// `dk-node` and `dk-sig` of the answer: the node that says it made it and its signature (see identity.zig).
    node: ?[]const u8 = null,
    node_sig: ?[]const u8 = null,
    body: []const u8 = &.{},
};

pub const Request = struct {
    url: []const u8,
    user_agent: []const u8,
    accept: []const u8,
    max_body_bytes: usize,
    /// The value of an `Authorization` header, if one is to be sent (API keys of peers).
    authorization: ?[]const u8 = null,
    /// Validators from an earlier answer: the server may answer 304 (nothing changed) without a body.
    if_none_match: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,
    /// A request body (the request is then a POST) and its media type.
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
    /// More headers to send (a peer's signature, at most four).
    extra_headers: []const http.Header = &.{},
};

/// Fetches `req.url`. Everything returned is allocated from `arena`; on
/// `Timeout` or `Canceled` the arena may hold partial garbage, which the
/// caller frees with the rest of it.
pub fn get(client: *http.Client, arena: Allocator, req: Request, timeout: Io.Duration) Failure!Response {
    const io = client.io;
    var buffer: [2]Task = undefined;
    var select: Io.Select(Task) = .init(io, &buffer);
    select.concurrent(.done, run, .{ client, arena, req }) catch return error.Network;
    select.concurrent(.timeout, sleep, .{ io, timeout }) catch {
        select.cancelDiscard();
        return error.Network;
    };
    const first = select.await() catch {
        select.cancelDiscard();
        return error.Canceled;
    };
    select.cancelDiscard();
    return switch (first) {
        .done => |r| r,
        .timeout => error.Timeout,
    };
}

const Task = union(enum) {
    done: Failure!Response,
    timeout: void,
};

fn sleep(io: Io, d: Io.Duration) void {
    io.sleep(d, .awake) catch {};
}

fn run(client: *http.Client, arena: Allocator, req: Request) Failure!Response {
    const uri = std.Uri.parse(req.url) catch return error.BadUrl;
    var headers: [8]http.Header = undefined;
    var n_headers: usize = 0;
    headers[n_headers] = .{ .name = "accept", .value = req.accept };
    n_headers += 1;
    if (req.authorization) |a| {
        headers[n_headers] = .{ .name = "authorization", .value = a };
        n_headers += 1;
    }
    if (req.if_none_match) |v| {
        headers[n_headers] = .{ .name = "if-none-match", .value = v };
        n_headers += 1;
    }
    if (req.if_modified_since) |v| {
        headers[n_headers] = .{ .name = "if-modified-since", .value = v };
        n_headers += 1;
    }
    for (req.extra_headers[0..@min(req.extra_headers.len, 4)]) |h| {
        headers[n_headers] = h;
        n_headers += 1;
    }
    var request = client.request(if (req.body != null) .POST else .GET, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = req.user_agent }, .content_type = if (req.body != null) .{ .override = req.content_type } else .default },
        .extra_headers = headers[0..n_headers],
    }) catch |e| return mapRequestError(e);
    defer request.deinit();

    if (req.body) |b| {
        const copy = try arena.dupe(u8, b);
        request.sendBodyComplete(copy) catch return error.Network;
    } else request.sendBodiless() catch return error.Network;
    var redirect_buffer: [0]u8 = undefined;
    var response = request.receiveHead(&redirect_buffer) catch |e| return switch (e) {
        error.Canceled => error.Canceled,
        error.HttpHeadersInvalid,
        error.HttpHeadersOversize,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        error.HttpContentEncodingUnsupported,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.UnsupportedUriScheme,
        => error.BadResponse,
        else => if (isTls(@errorName(e))) error.Tls else error.Network,
    };

    var out: Response = .{ .status = @backingInt(response.head.status) };
    if (response.head.location) |l| out.location = try arena.dupe(u8, l);
    if (response.head.content_type) |c| out.content_type = try arena.dupe(u8, c);
    var hit = response.head.iterateHeaders();
    while (hit.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "etag") and h.value.len <= 300) out.etag = try arena.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "last-modified") and h.value.len <= 100) out.last_modified = try arena.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "dk-node") and h.value.len <= 64) out.node = try arena.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "dk-sig") and h.value.len <= 120) out.node_sig = try arena.dupe(u8, h.value);
    }

    // Only a successful answer's body is wanted; for anything else the
    // connection is simply closed rather than drained.
    if (out.status < 200 or out.status >= 300) return out;
    if (response.head.content_length) |n| if (n > req.max_body_bytes) return error.TooLarge;

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.BadResponse,
    };
    var transfer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, decompress_buffer);
    out.body = reader.allocRemaining(arena, .limited(req.max_body_bytes)) catch |e| switch (e) {
        error.StreamTooLong => return error.TooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return if (response.bodyErr()) |_| error.BadResponse else error.Network,
    };
    return out;
}

fn mapRequestError(e: http.Client.RequestError) Failure {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.UnsupportedUriScheme, error.UriMissingHost, error.InvalidHostName => error.BadUrl,
        error.CertificateBundleLoadFailure => error.Tls,
        else => if (isTls(@errorName(e))) error.Tls else error.Network,
    };
}

fn isTls(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "Tls") or std.mem.startsWith(u8, name, "Certificate");
}
