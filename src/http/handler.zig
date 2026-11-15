//! Transport-independent request handling: route a method and request target
//! to a `Response`. No sockets here, so every behaviour is unit-testable.
//!
//! This is an adapter over the core `Searcher`; it holds no search logic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const dk = @import("dksearch");
const query = @import("query.zig");
const html = @import("html.zig");

pub const Header = http.Header;

pub const Response = struct {
    status: http.Status,
    content_type: []const u8,
    body: []const u8,
    headers: []const Header = &.{},
};

/// Longest filter value (language, connector) we accept.
const max_filter_bytes = 64;
/// Results per page on the HTML page.
pub const html_page_size: u32 = 10;

const csp = "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; " ++
    "base-uri 'none'; frame-ancestors 'none'";

/// Sent with every response.
pub const common_headers = [_]Header{
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "referrer-policy", .value = "no-referrer" },
    .{ .name = "content-security-policy", .value = csp },
    .{ .name = "cross-origin-resource-policy", .value = "same-origin" },
};
pub const no_store = Header{ .name = "cache-control", .value = "no-store" };
const asset_cache = Header{ .name = "cache-control", .value = "public, max-age=3600" };

pub const html_ct = "text/html; charset=utf-8";
const json_ct = "application/json";
const css_ct = "text/css; charset=utf-8";

pub fn headersWith(arena: Allocator, extra: []const Header) []const Header {
    const out = arena.alloc(Header, common_headers.len + extra.len) catch return &common_headers;
    @memcpy(out[0..common_headers.len], &common_headers);
    @memcpy(out[common_headers.len..], extra);
    return out;
}

const Route = enum { home, search_page, api_search, api_health, style, other };

fn route(path: []const u8) Route {
    if (std.mem.eql(u8, path, "/")) return .home;
    if (std.mem.eql(u8, path, "/search")) return .search_page;
    if (std.mem.eql(u8, path, "/api/v1/search")) return .api_search;
    if (std.mem.eql(u8, path, "/api/v1/health")) return .api_health;
    if (std.mem.eql(u8, path, "/assets/style.css")) return .style;
    return .other;
}

/// Handles one request. Never fails: problems become error responses.
/// `HEAD` is routed like `GET`; the transport layer omits the body.
pub fn handle(arena: Allocator, searcher: dk.search.Searcher, method: http.Method, target: []const u8) Response {
    return handleInner(arena, searcher, method, target) catch |e| switch (e) {
        error.OutOfMemory => plain(.service_unavailable, "temporarily out of memory\n"),
    };
}

fn handleInner(arena: Allocator, searcher: dk.search.Searcher, method: http.Method, target: []const u8) error{OutOfMemory}!Response {
    const t = query.parseTarget(arena, target) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // Cannot tell whether the client wants JSON or HTML; use plain text.
        error.BadEncoding, error.TooManyParams => return plain(.bad_request, "bad request target\n"),
    };
    const r = route(t.path);
    const is_api = std.mem.startsWith(u8, t.path, "/api/");

    if (r == .other) {
        if (is_api) return apiError(arena, .not_found, "not_found", "no such endpoint");
        return htmlError(arena, .not_found, "Not found", "That page does not exist.");
    }
    if (method != .GET and method != .HEAD) {
        var resp = if (is_api)
            try apiError(arena, .method_not_allowed, "method_not_allowed", "use GET")
        else
            try htmlError(arena, .method_not_allowed, "Method not allowed", "Use GET.");
        resp.headers = headersWith(arena, &.{ .{ .name = "allow", .value = "GET, HEAD" }, no_store });
        return resp;
    }

    return switch (r) {
        .home => try renderHtml(arena, .ok, struct {
            fn f(w: *std.Io.Writer) !void {
                try html.writeHome(w, null);
            }
        }.f),
        .style => .{ .status = .ok, .content_type = css_ct, .body = html.style_css, .headers = headersWith(arena, &.{asset_cache}) },
        .api_health => try jsonResponse(arena, .ok, .{ .status = "ok" }),
        .api_search => try apiSearch(arena, searcher, t.params),
        .search_page => try pageSearch(arena, searcher, t.params),
        .other => unreachable,
    };
}

// ------------------------------------------------------------ parameters

const ParamError = struct { name: []const u8, message: []const u8 };

const Parsed = union(enum) {
    ok: dk.search.Query,
    bad: ParamError,
};

fn parseQuery(params: query.Params, html_mode: bool) Parsed {
    var q: dk.search.Query = .{ .text = params.get("q") orelse "" };
    inline for (.{ "language", "content_type", "connector" }) |name| {
        if (params.get(name)) |v| if (v.len > 0) {
            if (!validFilter(v)) return .{ .bad = .{ .name = name, .message = "invalid filter value" } };
            @field(q, name) = v;
        };
    }
    if (params.get("offset")) |v| if (v.len > 0) {
        q.offset = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = .{ .name = "offset", .message = "must be a non-negative integer" } };
    };
    if (html_mode) {
        q.limit = html_page_size; // the page size is not user-controlled
    } else if (params.get("limit")) |v| if (v.len > 0) {
        q.limit = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = .{ .name = "limit", .message = "must be a non-negative integer" } };
    };
    return .{ .ok = q };
}

fn validFilter(v: []const u8) bool {
    if (v.len > max_filter_bytes) return false;
    for (v) |b| if (b < 0x20 or b == 0x7f) return false;
    return true;
}

// ------------------------------------------------------------ JSON API

const ApiHit = struct {
    id: []const u8,
    connector: []const u8,
    url: ?[]const u8,
    title: ?[]const u8,
    snippet: ?[]const u8,
    score: f64,
};
const ApiPage = struct { hits: []const ApiHit, has_more: bool };

fn apiSearch(arena: Allocator, searcher: dk.search.Searcher, params: query.Params) error{OutOfMemory}!Response {
    const q = switch (parseQuery(params, false)) {
        .ok => |q| q,
        .bad => |b| return apiError(arena, .bad_request, "invalid_parameter", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    const page = searcher.search(arena, q) catch |e| return searchFailure(arena, e, true);

    const hits = try arena.alloc(ApiHit, page.hits.len);
    for (page.hits, hits) |h, *out| {
        out.* = .{
            .id = try arena.dupe(u8, &std.fmt.bytesToHex(h.id, .lower)),
            .connector = h.connector,
            .url = h.url,
            .title = h.title,
            .snippet = h.snippet,
            .score = h.score,
        };
    }
    return jsonResponse(arena, .ok, ApiPage{ .hits = hits, .has_more = page.has_more });
}

fn searchFailure(arena: Allocator, e: dk.search.Error, api: bool) error{OutOfMemory}!Response {
    const status: http.Status, const code: []const u8, const msg: []const u8 = switch (e) {
        error.EmptyQuery => .{ .bad_request, "empty_query", "the query has no searchable terms" },
        error.InvalidQuery => .{ .bad_request, "invalid_query", "the query or paging parameters are out of range" },
        error.OutOfMemory => return error.OutOfMemory,
        // Details belong in logs, never in responses.
        error.Io => .{ .internal_server_error, "internal_error", "the search failed" },
    };
    return if (api) apiError(arena, status, code, msg) else htmlError(arena, status, "Search problem", msg);
}

pub fn jsonResponse(arena: Allocator, status: http.Status, value: anytype) error{OutOfMemory}!Response {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &aw.writer) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return .{
        .status = status,
        .content_type = json_ct,
        .body = aw.written(),
        .headers = headersWith(arena, &.{no_store}),
    };
}

pub fn apiError(arena: Allocator, status: http.Status, code: []const u8, message: []const u8) error{OutOfMemory}!Response {
    return jsonResponse(arena, status, .{ .@"error" = .{ .code = code, .message = message } });
}

// ------------------------------------------------------------ HTML pages

fn pageSearch(arena: Allocator, searcher: dk.search.Searcher, params: query.Params) error{OutOfMemory}!Response {
    const q = switch (parseQuery(params, true)) {
        .ok => |q| q,
        .bad => |b| return htmlError(arena, .bad_request, "Bad request", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    const form: html.Form = .{ .q = q.text, .language = q.language orelse "", .connector = q.connector orelse "" };

    const page = searcher.search(arena, q) catch |e| switch (e) {
        // An empty box just shows the form again.
        error.EmptyQuery => {
            var aw: std.Io.Writer.Allocating = .init(arena);
            html.writeHome(&aw.writer, "Enter something to search for.") catch return error.OutOfMemory;
            return htmlResponse(arena, .ok, aw.written());
        },
        else => return searchFailure(arena, e, false),
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    html.writeResults(&aw.writer, form, page, q.offset, html_page_size) catch return error.OutOfMemory;
    return htmlResponse(arena, .ok, aw.written());
}

fn renderHtml(arena: Allocator, status: http.Status, comptime f: fn (*std.Io.Writer) anyerror!void) error{OutOfMemory}!Response {
    var aw: std.Io.Writer.Allocating = .init(arena);
    f(&aw.writer) catch return error.OutOfMemory;
    return htmlResponse(arena, status, aw.written());
}

pub fn htmlResponse(arena: Allocator, status: http.Status, body: []const u8) Response {
    return .{ .status = status, .content_type = html_ct, .body = body, .headers = headersWith(arena, &.{no_store}) };
}

pub fn htmlError(arena: Allocator, status: http.Status, title: []const u8, message: []const u8) error{OutOfMemory}!Response {
    var aw: std.Io.Writer.Allocating = .init(arena);
    html.writeError(&aw.writer, title, message) catch return error.OutOfMemory;
    return htmlResponse(arena, status, aw.written());
}

pub fn plain(status: http.Status, body: []const u8) Response {
    return .{ .status = status, .content_type = "text/plain; charset=utf-8", .body = body, .headers = &common_headers };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Searcher fake: returns a canned result and records the last query.
const FakeSearch = struct {
    result: dk.search.Error!dk.search.Page,
    last: ?dk.search.Query = null,

    fn search(ptr: *anyopaque, _: Allocator, q: dk.search.Query) dk.search.Error!dk.search.Page {
        const self: *FakeSearch = @ptrCast(@alignCast(ptr));
        self.last = q;
        return self.result;
    }
    fn searcher(self: *FakeSearch) dk.search.Searcher {
        return .{ .ptr = self, .vtable = &.{ .search = search } };
    }
};

const sample_hits = [_]dk.search.Hit{.{
    .id = .{ 0xab, 0xcd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .connector = "wiki",
    .url = "https://e.org/x",
    .title = "Title \"quoted\"",
    .snippet = "a \x02b\x03",
    .score = 2.5,
}};

fn run(fake: *FakeSearch, method: http.Method, target: []const u8, arena: *std.heap.ArenaAllocator) Response {
    return handle(arena.allocator(), fake.searcher(), method, target);
}

fn headerValue(r: Response, name: []const u8) ?[]const u8 {
    for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

test "API search returns JSON with hex ids and passes parameters through" {
    var f: FakeSearch = .{ .result = .{ .hits = &sample_hits, .has_more = true } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const r = run(&f, .GET, "/api/v1/search?q=hello+world&language=en&connector=wiki&limit=5&offset=10", &ar);

    try testing.expectEqual(http.Status.ok, r.status);
    try testing.expectEqualStrings("application/json", r.content_type);
    try testing.expectEqualStrings("hello world", f.last.?.text);
    try testing.expectEqualStrings("en", f.last.?.language.?);
    try testing.expectEqualStrings("wiki", f.last.?.connector.?);
    try testing.expectEqual(@as(u32, 5), f.last.?.limit);
    try testing.expectEqual(@as(u32, 10), f.last.?.offset);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    const hit = parsed.value.object.get("hits").?.array.items[0].object;
    try testing.expectEqualStrings("abcd0000000000000000000000000000", hit.get("id").?.string);
    try testing.expectEqualStrings("Title \"quoted\"", hit.get("title").?.string);
    try testing.expectEqualStrings("a \x02b\x03", hit.get("snippet").?.string);
    try testing.expect(parsed.value.object.get("has_more").?.bool);
}

test "API errors are JSON with a stable code" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const cases = [_]struct { e: dk.search.Error, status: http.Status, code: []const u8 }{
        .{ .e = error.EmptyQuery, .status = .bad_request, .code = "empty_query" },
        .{ .e = error.InvalidQuery, .status = .bad_request, .code = "invalid_query" },
        .{ .e = error.Io, .status = .internal_server_error, .code = "internal_error" },
    };
    for (cases) |c| {
        var f: FakeSearch = .{ .result = c.e };
        const r = run(&f, .GET, "/api/v1/search?q=x", &ar);
        try testing.expectEqual(c.status, r.status);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(c.code, parsed.value.object.get("error").?.object.get("code").?.string);
    }
}

test "engine failure details never reach the client" {
    var f: FakeSearch = .{ .result = error.Io };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const r = run(&f, .GET, "/api/v1/search?q=x", &ar);
    try testing.expect(std.mem.indexOf(u8, r.body, "sqlite") == null);
    try testing.expectEqual(http.Status.internal_server_error, r.status);
}

test "bad parameters are 400 and never reach the searcher" {
    var f: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    for ([_][]const u8{
        "/api/v1/search?q=x&limit=abc",
        "/api/v1/search?q=x&limit=-1",
        "/api/v1/search?q=x&offset=1.5",
        "/api/v1/search?q=x&language=en%00",
        "/api/v1/search?q=x&language=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "/api/v1/search?q=%ff",
        "/api/v1/search?q=%zz",
    }) |t| {
        const r = run(&f, .GET, t, &ar);
        try testing.expectEqual(http.Status.bad_request, r.status);
        try testing.expect(f.last == null);
    }
}

test "health, routing and methods" {
    var f: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();

    const h = run(&f, .GET, "/api/v1/health", &ar);
    try testing.expectEqual(http.Status.ok, h.status);
    try testing.expectEqualStrings("{\"status\":\"ok\"}\n", h.body);

    const nf = run(&f, .GET, "/api/v1/nope", &ar);
    try testing.expectEqual(http.Status.not_found, nf.status);
    try testing.expectEqualStrings("application/json", nf.content_type);
    const nf_html = run(&f, .GET, "/nope", &ar);
    try testing.expectEqual(http.Status.not_found, nf_html.status);
    try testing.expect(std.mem.startsWith(u8, nf_html.content_type, "text/html"));
    // Path is matched exactly: no decoding, no trailing-slash magic.
    try testing.expectEqual(http.Status.not_found, run(&f, .GET, "/%73earch?q=x", &ar).status);
    try testing.expectEqual(http.Status.not_found, run(&f, .GET, "/search/?q=x", &ar).status);

    for ([_]http.Method{ .POST, .PUT, .DELETE, .PATCH, .OPTIONS }) |m| {
        const r = run(&f, m, "/api/v1/search?q=x", &ar);
        try testing.expectEqual(http.Status.method_not_allowed, r.status);
        try testing.expectEqualStrings("GET, HEAD", headerValue(r, "allow").?);
    }
    try testing.expect(f.last == null);
    try testing.expectEqual(http.Status.ok, run(&f, .HEAD, "/api/v1/health", &ar).status);
}

test "malformed targets get a plain 400" {
    var f: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    for ([_][]const u8{ "", "search", "*", "http://x/", "/a b", "/\x00" }) |t| {
        const r = run(&f, .GET, t, &ar);
        try testing.expectEqual(http.Status.bad_request, r.status);
        try testing.expect(std.mem.startsWith(u8, r.content_type, "text/plain"));
    }
}

test "every response carries the security headers" {
    var f: FakeSearch = .{ .result = .{ .hits = &sample_hits, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    for ([_][]const u8{ "/", "/search?q=x", "/api/v1/search?q=x", "/api/v1/health", "/assets/style.css", "/nope", "/api/x", "/bad target" }) |t| {
        const r = run(&f, .GET, t, &ar);
        try testing.expectEqualStrings("nosniff", headerValue(r, "x-content-type-options").?);
        try testing.expectEqualStrings("no-referrer", headerValue(r, "referrer-policy").?);
        const policy = headerValue(r, "content-security-policy").?;
        try testing.expect(std.mem.indexOf(u8, policy, "default-src 'none'") != null);
        try testing.expect(std.mem.indexOf(u8, policy, "script-src") == null); // no script allowed at all
    }
}

test "HTML search page: form, results, fixed page size, empty box" {
    var f: FakeSearch = .{ .result = .{ .hits = &sample_hits, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();

    const home = run(&f, .GET, "/", &ar);
    try testing.expectEqual(http.Status.ok, home.status);
    try testing.expect(std.mem.indexOf(u8, home.body, "<form class=\"search\" action=\"/search\"") != null);

    // The page size is not user-controlled, even if `limit` is supplied.
    const r = run(&f, .GET, "/search?q=hello&limit=100", &ar);
    try testing.expectEqual(http.Status.ok, r.status);
    try testing.expectEqual(html_page_size, f.last.?.limit);
    try testing.expect(std.mem.indexOf(u8, r.body, "Title &quot;quoted&quot;") != null);
    try testing.expect(std.mem.indexOf(u8, r.body, "<mark>b</mark>") != null);

    var empty: FakeSearch = .{ .result = error.EmptyQuery };
    const e = run(&empty, .GET, "/search?q=", &ar);
    try testing.expectEqual(http.Status.ok, e.status);
    try testing.expect(std.mem.indexOf(u8, e.body, "Enter something to search for.") != null);

    var invalid: FakeSearch = .{ .result = error.InvalidQuery };
    try testing.expectEqual(http.Status.bad_request, run(&invalid, .GET, "/search?q=x", &ar).status);
}

test "reflected input is escaped in the HTML page" {
    var f: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const r = run(&f, .GET, "/search?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E&language=%22%3E%3Cimg%3E", &ar);
    try testing.expect(std.mem.indexOf(u8, r.body, "<script>") == null);
    try testing.expect(std.mem.indexOf(u8, r.body, "<img>") == null);
    try testing.expect(std.mem.indexOf(u8, r.body, "&lt;script&gt;alert(1)&lt;/script&gt;") != null);
}

test "stylesheet is served with caching" {
    var f: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const r = run(&f, .GET, "/assets/style.css", &ar);
    try testing.expectEqual(http.Status.ok, r.status);
    try testing.expect(std.mem.startsWith(u8, r.content_type, "text/css"));
    try testing.expect(r.body.len > 100);
    try testing.expect(std.mem.indexOf(u8, headerValue(r, "cache-control").?, "max-age") != null);
}

test "end to end against the real index" {
    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const d: dk.document.Document = .{ .connector = "gutenberg", .source_id = "1342", .title = "Pride and Prejudice", .text = "It is a truth universally acknowledged", .canonical_url = "https://example.org/pg1342" };
    try idx.indexer().add(d.id(), d);

    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const api = handle(ar.allocator(), idx.searcher(), .GET, "/api/v1/search?q=%22truth+universally%22");
    try testing.expectEqual(http.Status.ok, api.status);
    try testing.expect(std.mem.indexOf(u8, api.body, "Pride and Prejudice") != null);

    const page = handle(ar.allocator(), idx.searcher(), .GET, "/search?q=truth");
    try testing.expectEqual(http.Status.ok, page.status);
    try testing.expect(std.mem.indexOf(u8, page.body, "href=\"https://example.org/pg1342\"") != null);

    // Hostile search text must produce a clean 4xx, never a 500.
    for ([_][]const u8{ "/api/v1/search?q=%22", "/api/v1/search?q=title%3Ax+OR+*", "/api/v1/search?q=%00", "/api/v1/search?q=NEAR(" }) |t| {
        const r = handle(ar.allocator(), idx.searcher(), .GET, t);
        try testing.expect(r.status == .ok or r.status == .bad_request);
    }
}
