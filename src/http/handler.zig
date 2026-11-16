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

const csp = "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; " ++
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

const Route = enum { help_search, help_regex, home, search_page, api_search, api_health, style, document, other };

fn route(path: []const u8) Route {
    if (std.mem.eql(u8, path, "/")) return .home;
    if (std.mem.eql(u8, path, "/search")) return .search_page;
    if (std.mem.eql(u8, path, "/help") or std.mem.eql(u8, path, "/help/search")) return .help_search;
    if (std.mem.eql(u8, path, "/help/regex")) return .help_regex;
    if (std.mem.eql(u8, path, "/api/v1/search")) return .api_search;
    if (std.mem.eql(u8, path, "/api/v1/health")) return .api_health;
    if (std.mem.eql(u8, path, "/assets/style.css")) return .style;
    if (std.mem.startsWith(u8, path, "/doc/")) return .document;
    return .other;
}

/// Handles one request. Never fails: problems become error responses.
/// `HEAD` is routed like `GET`; the transport layer omits the body.
pub fn handle(arena: Allocator, searcher: dk.search.Searcher, method: http.Method, target: []const u8) Response {
    return handleWith(arena, searcher, null, method, target);
}

/// Like `handle`, with the regex filter available when `regex` is set.
pub fn handleWith(arena: Allocator, searcher: dk.search.Searcher, regex: ?*dk.regexsearch.Service, method: http.Method, target: []const u8) Response {
    return handleServices(arena, searcher, .{ .regex = regex }, method, target);
}

/// What the public pages can use besides the index.
pub const Services = struct {
    /// The regular-expression filter, if the server offers it.
    regex: ?*dk.regexsearch.Service = null,
    /// Stored document texts, for the document viewer.
    content: ?dk.storage.ContentStore = null,
    /// Original files of the sources that allow them to be opened (`serve_originals`).
    originals: ?*const dk.originals.Service = null,
};

pub fn handleServices(arena: Allocator, searcher: dk.search.Searcher, services: Services, method: http.Method, target: []const u8) Response {
    return handleInner(arena, searcher, services, method, target) catch |e| switch (e) {
        error.OutOfMemory => plain(.service_unavailable, "temporarily out of memory\n"),
    };
}

fn handleInner(arena: Allocator, searcher: dk.search.Searcher, services: Services, method: http.Method, target: []const u8) error{OutOfMemory}!Response {
    const regex = services.regex;
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
        .home => blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            html.writeHomeWith(&aw.writer, null, regex != null) catch return error.OutOfMemory;
            break :blk htmlResponse(arena, .ok, aw.written());
        },
        .style => .{ .status = .ok, .content_type = css_ct, .body = html.style_css, .headers = headersWith(arena, &.{asset_cache}) },
        .api_health => try jsonResponse(arena, .ok, .{ .status = "ok" }),
        .help_search => blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            html.writeHelpSearch(&aw.writer, regex != null) catch return error.OutOfMemory;
            break :blk htmlResponse(arena, .ok, aw.written());
        },
        .help_regex => blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            html.writeHelpRegex(&aw.writer, if (regex) |svc| svc.limits else null) catch return error.OutOfMemory;
            break :blk htmlResponse(arena, .ok, aw.written());
        },
        .api_search => try apiSearch(arena, searcher, regex, t.params),
        .search_page => try pageSearch(arena, searcher, regex, t.params),
        .document => try documentPage(arena, searcher, services, t.path),
        .other => unreachable,
    };
}

// ------------------------------------------------------------ parameters

pub const ParamError = struct { name: []const u8, message: []const u8 };

const Parsed = union(enum) {
    ok: struct { q: dk.search.Query, re: ?dk.regexsearch.Request, typed: []const u8 },
    bad: ParamError,
};

fn parseQuery(arena: Allocator, params: query.Params, html_mode: bool) error{OutOfMemory}!Parsed {
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
    if (params.get("fuzzy")) |v| if (v.len > 0) {
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "true")) {
            q.fuzzy = .on;
        } else if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "exact")) {
            q.fuzzy = .off;
        } else return .{ .bad = .{ .name = "fuzzy", .message = "must be 1 (always allow typos), 0 (exact words only), or left out (the server's default)" } };
    };
    if (html_mode) {
        q.limit = html_page_size; // the page size is not user-controlled
    } else if (params.get("limit")) |v| if (v.len > 0) {
        q.limit = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = .{ .name = "limit", .message = "must be a non-negative integer" } };
    };
    const re: ?dk.regexsearch.Request = switch (parseRegexParams(params)) {
        .none => null,
        .ok => |r| r,
        .bad => |b| return .{ .bad = b },
    };
    // A pattern written in the search box: re:/…/i
    const tok = dk.regexsearch.extractToken(arena, q.text) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnterminatedPattern => .{ .bad = .{ .name = "q", .message = "a pattern written re:/… needs a closing slash, like re:/colou?r/" } },
        error.BadFlag => .{ .bad = .{ .name = "q", .message = "after the closing slash only the flag i (ignore case) is allowed" } },
        error.TooManyPatterns => .{ .bad = .{ .name = "q", .message = "only one re:/…/ pattern per search" } },
    };
    if (tok.request) |r| {
        if (re != null) return .{ .bad = .{ .name = "regex", .message = "use either the regex parameter or re:/…/ in the query, not both" } };
        q.text = tok.text;
        return .{ .ok = .{ .q = q, .re = r, .typed = params.get("q") orelse "" } };
    }
    return .{ .ok = .{ .q = q, .re = re, .typed = q.text } };
}

pub const RegexParams = union(enum) { none, ok: dk.regexsearch.Request, bad: ParamError };

/// Applies a `re:/…/` written in the query text: the text loses the token and
/// the regex request is taken from it. Used where the query and the regex
/// parameters are parsed separately.
pub fn applyToken(arena: Allocator, q: dk.search.Query, rx: RegexParams) error{OutOfMemory}!struct { q: dk.search.Query, rx: RegexParams } {
    const tok = dk.regexsearch.extractToken(arena, q.text) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnterminatedPattern => .{ .q = q, .rx = .{ .bad = .{ .name = "q", .message = "a pattern written re:/… needs a closing slash, like re:/colou?r/" } } },
        error.BadFlag => .{ .q = q, .rx = .{ .bad = .{ .name = "q", .message = "after the closing slash only the flag i (ignore case) is allowed" } } },
        error.TooManyPatterns => .{ .q = q, .rx = .{ .bad = .{ .name = "q", .message = "only one re:/…/ pattern per search" } } },
    };
    const r = tok.request orelse return .{ .q = q, .rx = rx };
    if (rx != .none) return .{ .q = q, .rx = .{ .bad = .{ .name = "regex", .message = "use either the regex parameter or re:/…/ in the query, not both" } } };
    var out = q;
    out.text = tok.text;
    return .{ .q = out, .rx = .{ .ok = r } };
}

/// Regular-expression filter parameters: `regex` is the pattern, `regex_flags`
/// may contain `i` (ignore case), `regex_dialect` is `perl` (default) or `ere`.
pub fn parseRegexParams(params: query.Params) RegexParams {
    const p = params.get("regex") orelse return .none;
    if (p.len == 0) return .none;
    var req: dk.regexsearch.Request = .{ .pattern = p };
    if (params.get("regex_flags")) |fl| {
        for (fl) |ch| switch (ch) {
            'i' => req.ignore_case = true,
            else => return .{ .bad = .{ .name = "regex_flags", .message = "only the flag i (ignore case) is supported" } },
        };
    }
    if (params.get("regex_dialect")) |d| if (d.len > 0) {
        req.dialect = std.meta.stringToEnum(dk.regexsearch.Dialect, d) orelse
            return .{ .bad = .{ .name = "regex_dialect", .message = "must be perl or ere" } };
    };
    return .{ .ok = req };
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
const ApiPage = struct { hits: []const ApiHit, has_more: bool, interpreted: ?[]const u8 = null, fuzzy: bool = false };

pub const RegexNote = struct { status: http.Status, code: []const u8, message: []const u8 };

/// The words-and-regex search: the page and how much was checked, or why not.
pub fn regexSearch(arena: Allocator, searcher: dk.search.Searcher, service: ?*dk.regexsearch.Service, q: dk.search.Query, req: dk.regexsearch.Request) error{OutOfMemory}!union(enum) { ok: dk.regexsearch.Result, failed: RegexNote } {
    const svc = service orelse return .{ .failed = .{ .status = .bad_request, .code = "regex_disabled", .message = "regular-expression search is not enabled on this server" } };
    var diag: dk.regexsearch.PatternDiag = .{};
    const r = svc.run(arena, searcher, q, req, &diag) catch |e| return .{ .failed = switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EmptyQuery => .{ .status = .bad_request, .code = "empty_query", .message = "a regular-expression search also needs at least one word, which chooses the documents to check" },
        error.InvalidQuery => .{ .status = .bad_request, .code = "invalid_query", .message = "the query or paging parameters are out of range" },
        error.InvalidPattern => .{ .status = .bad_request, .code = "invalid_pattern", .message = try std.fmt.allocPrint(arena, "invalid pattern: {s}", .{diag.message}) },
        error.TooComplex => .{ .status = .unprocessable_entity, .code = "pattern_too_complex", .message = "the pattern is too complex to run on these documents; simplify it" },
        error.Timeout => .{ .status = .service_unavailable, .code = "search_timeout", .message = "the search took too long; try more specific words (very common words match too much of the index)" },
        error.Busy => .{ .status = .too_many_requests, .code = "busy", .message = "too many regular-expression searches are running; try again in a moment" },
        error.Io => .{ .status = .internal_server_error, .code = "internal_error", .message = "the search failed" },
    } };
    return .{ .ok = r };
}

fn apiSearch(arena: Allocator, searcher: dk.search.Searcher, regex: ?*dk.regexsearch.Service, params: query.Params) error{OutOfMemory}!Response {
    const parsed = switch (try parseQuery(arena, params, false)) {
        .ok => |p| p,
        .bad => |b| return apiError(arena, .bad_request, "invalid_parameter", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    const q = parsed.q;
    if (parsed.re) |req| {
        const r = switch (try regexSearch(arena, searcher, regex, q, req)) {
            .ok => |r| r,
            .failed => |n| {
                var resp = try apiError(arena, n.status, n.code, n.message);
                if (n.status == .too_many_requests) resp.headers = headersWith(arena, &.{ .{ .name = "retry-after", .value = "2" }, no_store });
                return resp;
            },
        };
        const hits = try arena.alloc(ApiHit, r.page.hits.len);
        for (r.page.hits, hits) |h, *out| out.* = try apiHit(arena, h);
        return jsonResponse(arena, .ok, .{ .hits = hits, .has_more = r.page.has_more, .interpreted = r.page.interpreted, .fuzzy = r.page.fuzzy, .regex = .{ .examined = r.examined, .truncated = r.truncated } });
    }
    const page = searcher.search(arena, q) catch |e| return searchFailure(arena, e, true);

    const hits = try arena.alloc(ApiHit, page.hits.len);
    for (page.hits, hits) |h, *out| out.* = try apiHit(arena, h);
    return jsonResponse(arena, .ok, ApiPage{ .hits = hits, .has_more = page.has_more, .interpreted = page.interpreted, .fuzzy = page.fuzzy });
}

fn apiHit(arena: Allocator, h: dk.search.Hit) error{OutOfMemory}!ApiHit {
    return .{
        .id = try arena.dupe(u8, &std.fmt.bytesToHex(h.id, .lower)),
        .connector = h.connector,
        .url = h.url,
        .title = h.title,
        .snippet = h.snippet,
        .score = h.score,
    };
}

fn searchFailure(arena: Allocator, e: dk.search.Error, api: bool) error{OutOfMemory}!Response {
    const status: http.Status, const code: []const u8, const msg: []const u8 = switch (e) {
        error.EmptyQuery => .{ .bad_request, "empty_query", "the query has no searchable terms" },
        error.InvalidQuery => .{ .bad_request, "invalid_query", "the query or paging parameters are out of range" },
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => .{ .service_unavailable, "search_timeout", "the search took too long; try more specific words (very common words match too much of the index)" },
        // Details belong in logs, never in responses.
        error.Io => .{ .internal_server_error, "internal_error", "the search failed" },
    };
    var resp = if (api) try apiError(arena, status, code, msg) else try htmlError(arena, status, "Search problem", msg);
    if (e == error.Timeout) resp.headers = headersWith(arena, &.{ .{ .name = "retry-after", .value = "5" }, no_store });
    return resp;
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

// ------------------------------------------------------------ document viewer

/// Longest stored text shown on the viewer page, in bytes.
const max_view_bytes = 512 * 1024;

fn documentPage(arena: Allocator, searcher: dk.search.Searcher, services: Services, path: []const u8) error{OutOfMemory}!Response {
    var hex = path["/doc/".len..];
    var want_file = false;
    if (std.mem.endsWith(u8, hex, "/file")) {
        want_file = true;
        hex = hex[0 .. hex.len - "/file".len];
    }
    var id: dk.document.Id = undefined;
    if (hex.len != 2 * @sizeOf(dk.document.Id)) return htmlError(arena, .not_found, "Not found", "No such document.");
    _ = std.fmt.hexToBytes(&id, hex) catch return htmlError(arena, .not_found, "Not found", "No such document.");
    const info = searcher.info(arena, id) catch |e| return searchFailure(arena, e, false);
    const hit = info orelse return htmlError(arena, .not_found, "Not found", "No such document.");
    const can_open = if (services.originals) |o| (if (hit.url) |u| o.serves(hit.connector, u) else false) else false;
    if (want_file) return if (can_open) originalFile(arena, services.originals.?, hit) else htmlError(arena, .not_found, "Not found", "The original file of this document is not available here.");

    var text: ?[]const u8 = null;
    var cut = false;
    if (services.content) |store| {
        if (store.get(arena, id)) |bytes| {
            if (bytes.len > max_view_bytes) {
                // Cut at a character boundary.
                var end: usize = max_view_bytes;
                while (end > 0 and (bytes[end] & 0xC0) == 0x80) end -= 1;
                text = bytes[0..end];
                cut = true;
            } else text = bytes;
        } else |_| {}
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    html.writeDocument(&aw.writer, hit, text, cut, can_open) catch return error.OutOfMemory;
    return htmlResponse(arena, .ok, aw.written());
}

/// The original file of a document, for the browser to show or download.
fn originalFile(arena: Allocator, svc: *const dk.originals.Service, hit: dk.search.Hit) error{OutOfMemory}!Response {
    const served = svc.read(arena, hit.connector, hit.url.?) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotServed, error.NotFound, error.Forbidden => htmlError(arena, .not_found, "Not found", "The original file is not available (it may have been moved or removed)."),
        error.TooLarge => htmlError(arena, .payload_too_large, "Too large", "That file is too large to be served here."),
        error.Io => htmlError(arena, .internal_server_error, "Error", "The file could not be read."),
    };
    // No script policy beyond "nothing may frame this": the browser's own PDF viewer needs room, and
    // what is served inline (PDF, images, plain text) cannot run script on this origin.
    const headers = try arena.alloc(Header, 5);
    headers[0] = .{ .name = "x-content-type-options", .value = "nosniff" };
    headers[1] = .{ .name = "referrer-policy", .value = "no-referrer" };
    headers[2] = .{ .name = "content-security-policy", .value = "frame-ancestors 'none'" };
    headers[3] = .{ .name = "cross-origin-resource-policy", .value = "same-origin" };
    headers[4] = .{ .name = "content-disposition", .value = try dk.originals.dispositionFor(arena, served.inline_view, served.filename) };
    return .{ .status = .ok, .content_type = served.content_type, .body = served.bytes, .headers = headers };
}

// ------------------------------------------------------------ HTML pages

fn pageSearch(arena: Allocator, searcher: dk.search.Searcher, regex: ?*dk.regexsearch.Service, params: query.Params) error{OutOfMemory}!Response {
    const parsed = switch (try parseQuery(arena, params, true)) {
        .ok => |p| p,
        .bad => |b| return htmlError(arena, .bad_request, "Bad request", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    const q = parsed.q;
    var form: html.Form = .{ .q = parsed.typed, .language = q.language orelse "", .connector = q.connector orelse "", .regex_enabled = regex != null, .exact_only = q.fuzzy == .off };
    if (parsed.re) |req| {
        // A pattern typed in the box is already part of `q` and travels with it; only one given
        // as a parameter has to be carried separately (the pager and the exact-spelling link).
        if (std.mem.eql(u8, parsed.typed, q.text)) {
            form.regex = req.pattern;
            form.regex_ignore_case = req.ignore_case;
        }
        const result = try regexSearch(arena, searcher, regex, q, req);
        var aw: std.Io.Writer.Allocating = .init(arena);
        switch (result) {
            .ok => |r| {
                html.writeResults(&aw.writer, form, r.page, q.offset, html_page_size) catch return error.OutOfMemory;
                return htmlResponse(arena, .ok, aw.written());
            },
            .failed => |n| {
                form.regex_notice = n.message;
                html.writeResults(&aw.writer, form, .{ .hits = &.{}, .has_more = false }, 0, html_page_size) catch return error.OutOfMemory;
                var resp = htmlResponse(arena, n.status, aw.written());
                if (n.status == .too_many_requests) resp.headers = headersWith(arena, &.{ .{ .name = "retry-after", .value = "2" }, no_store });
                return resp;
            },
        }
    }

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
        // Scripts only from this origin (the admin interface's one file): never inline, never eval.
        try testing.expect(std.mem.indexOf(u8, policy, "script-src 'self'") != null);
        try testing.expect(std.mem.indexOf(u8, policy, "unsafe") == null);
        try testing.expect(std.mem.indexOf(u8, policy, "default-src 'none'") != null);
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

test "pages link the stylesheet by a content fingerprint, and the versioned address serves it" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    const home = handle(ar.allocator(), fake.searcher(), .GET, "/");
    const want = "href=\"/assets/style.css?v=" ++ html.style_version ++ "\"";
    try testing.expect(std.mem.indexOf(u8, home.body, want) != null);
    const css = handle(ar.allocator(), fake.searcher(), .GET, "/assets/style.css?v=" ++ html.style_version);
    try testing.expectEqual(http.Status.ok, css.status);
    try testing.expect(std.mem.indexOf(u8, css.body, ".sidetoggle") != null);
}

test "the document viewer shows what is known and the stored text, escaped; unknown ids are 404" {
    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    var store = dk.memory.MemoryContentStore.init(testing.allocator);
    defer store.deinit();
    const d: dk.document.Document = .{ .connector = "notes", .source_id = "a", .title = "Trip <plan>", .text = "Packing list & <b>route</b>", .canonical_url = "file:///home/me/notes/trip.md", .content_type = "text/markdown", .author = "Jo", .modified_at = 1_700_000_000, .language = "en" };
    try idx.indexer().add(d.id(), d);
    try store.store().put(d.id(), d.text.?);

    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const hex = std.fmt.bytesToHex(d.id(), .lower);
    const target = try std.fmt.allocPrint(ar.allocator(), "/doc/{s}", .{hex});
    const r = handleServices(ar.allocator(), idx.searcher(), .{ .content = store.store() }, .GET, target);
    try testing.expectEqual(http.Status.ok, r.status);
    for ([_][]const u8{ "Trip &lt;plan&gt;", "Packing list &amp; &lt;b&gt;route&lt;/b&gt;", "file:///home/me/notes/trip.md", "markdown", "2023-11-14", "Jo", "notes" }) |needle| {
        errdefer std.debug.print("missing: {s}\n{s}\n", .{ needle, r.body });
        try testing.expect(std.mem.indexOf(u8, r.body, needle) != null);
    }
    // The file address is shown as text, never as a link a browser cannot follow.
    try testing.expect(std.mem.indexOf(u8, r.body, "href=\"file:") == null);
    try testing.expect(std.mem.indexOf(u8, r.body, "<b>route</b>") == null);

    // Without the content store only the metadata is shown.
    const bare = handleServices(ar.allocator(), idx.searcher(), .{}, .GET, target);
    try testing.expectEqual(http.Status.ok, bare.status);
    try testing.expect(std.mem.indexOf(u8, bare.body, "not stored on this server") != null);

    // Results link to the viewer when the address cannot be opened.
    const found = handleServices(ar.allocator(), idx.searcher(), .{}, .GET, "/search?q=packing");
    try testing.expect(std.mem.indexOf(u8, found.body, target) != null);

    for ([_][]const u8{ "/doc/", "/doc/zz", "/doc/00112233445566778899aabbccddeeff", "/doc/0011223344556677889900aabbccddeeffaa", "/doc/../etc/passwd" }) |t| {
        const nf = handleServices(ar.allocator(), idx.searcher(), .{}, .GET, t);
        errdefer std.debug.print("target: {s}\n", .{t});
        try testing.expectEqual(http.Status.not_found, nf.status);
    }
}

test "original files are served only for sources that allow it, from inside their folder" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "notes");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes/a.pdf", .data = "%PDF-1.4 fake" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes/page.html", .data = "<script>alert(1)</script>" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "secret.txt", .data = "outside" });

    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const abs = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const base = try std.fmt.allocPrint(a, "{s}/notes", .{abs});

    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const mk = struct {
        fn doc(connector: []const u8, id: []const u8, url: []const u8) dk.document.Document {
            return .{ .connector = connector, .source_id = id, .title = id, .text = "text", .canonical_url = url };
        }
    };
    const pdf = mk.doc("notes", "pdf", try std.fmt.allocPrint(a, "file://{s}/a.pdf", .{base}));
    const html_doc = mk.doc("notes", "html", try std.fmt.allocPrint(a, "file://{s}/page.html", .{base}));
    const outside = mk.doc("notes", "out", try std.fmt.allocPrint(a, "file://{s}/secret.txt", .{abs}));
    const other = mk.doc("elsewhere", "other", try std.fmt.allocPrint(a, "file://{s}/a.pdf", .{base}));
    for ([_]dk.document.Document{ pdf, html_doc, outside, other }) |d| try idx.indexer().add(d.id(), d);

    const roots = [_]dk.originals.Root{.{ .connector = "notes", .base = base }};
    const svc: dk.originals.Service = .{ .io = testing.io, .roots = &roots };
    const services: Services = .{ .originals = &svc };
    const get = struct {
        fn at(arena: Allocator, searcher: dk.search.Searcher, sv: Services, d: dk.document.Document, suffix: []const u8) !Response {
            const hex = std.fmt.bytesToHex(d.id(), .lower);
            return handleServices(arena, searcher, sv, .GET, try std.fmt.allocPrint(arena, "/doc/{s}{s}", .{ hex, suffix }));
        }
    }.at;

    const r = try get(a, idx.searcher(), services, pdf, "/file");
    try testing.expectEqual(http.Status.ok, r.status);
    try testing.expectEqualStrings("application/pdf", r.content_type);
    try testing.expectEqualStrings("%PDF-1.4 fake", r.body);
    var disposition: []const u8 = "";
    for (r.headers) |h| if (std.mem.eql(u8, h.name, "content-disposition")) {
        disposition = h.value;
    };
    try testing.expect(std.mem.startsWith(u8, disposition, "inline;"));

    // HTML is only ever shown as text.
    const h = try get(a, idx.searcher(), services, html_doc, "/file");
    try testing.expectEqualStrings("text/plain; charset=utf-8", h.content_type);

    // The viewer offers the original only where it can be opened.
    const page = try get(a, idx.searcher(), services, pdf, "");
    try testing.expect(std.mem.indexOf(u8, page.body, "/file\">Open the original file") != null);
    const page_off = try get(a, idx.searcher(), .{}, pdf, "");
    try testing.expect(std.mem.indexOf(u8, page_off.body, "Open the original file") == null);

    // Not allowed: no service, another source, a file outside the folder.
    try testing.expectEqual(http.Status.not_found, (try get(a, idx.searcher(), .{}, pdf, "/file")).status);
    try testing.expectEqual(http.Status.not_found, (try get(a, idx.searcher(), services, other, "/file")).status);
    try testing.expectEqual(http.Status.not_found, (try get(a, idx.searcher(), services, outside, "/file")).status);
    try testing.expectEqual(http.Status.not_found, (try get(a, idx.searcher(), services, pdf, "/file/x")).status);
}

// ----------------------------------------------------- regular-expression filter

const RegexFixture = struct {
    store: dk.memory.MemoryContentStore,
    fake: FakeSearch,
    svc: dk.regexsearch.Service,
    hits: [2]dk.search.Hit,

    fn init(f: *RegexFixture, limits: dk.regexsearch.Limits) !void {
        f.store = dk.memory.MemoryContentStore.init(testing.allocator);
        const ids = [2]dk.document.Id{ dk.document.idFromSource("t", "a"), dk.document.idFromSource("t", "b") };
        try f.store.store().put(ids[0], "The order number is 123-456 today");
        try f.store.store().put(ids[1], "No digits in this order at all");
        for (&f.hits, ids, 0..) |*h, id, i| h.* = .{ .id = id, .connector = "t", .url = if (i == 0) "https://e.org/a" else null, .title = if (i == 0) "A" else "B", .snippet = null, .score = 3 - @as(f64, @floatFromInt(i)) };
        f.fake = .{ .result = .{ .hits = &f.hits, .has_more = false } };
        f.svc = dk.regexsearch.Service.init(testing.io, f.store.store(), limits);
    }
    fn deinit(f: *RegexFixture) void {
        f.store.deinit();
    }
    fn get(f: *RegexFixture, arena: *std.heap.ArenaAllocator, with_service: bool, target: []const u8) Response {
        return handleWith(arena.allocator(), f.fake.searcher(), if (with_service) &f.svc else null, .GET, target);
    }
};

test "API regex filter keeps matching documents and says how much was checked" {
    var f: RegexFixture = undefined;
    try f.init(.{});
    defer f.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const r = f.get(&ar, true, "/api/v1/search?q=order&regex=%5Cd%7B3%7D-%5Cd%2B");
    try testing.expectEqual(http.Status.ok, r.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    const hits = parsed.value.object.get("hits").?.array.items;
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("A", hits[0].object.get("title").?.string);
    try testing.expect(std.mem.indexOf(u8, hits[0].object.get("snippet").?.string, "\x02123-456\x03") != null);
    const note = parsed.value.object.get("regex").?.object;
    try testing.expectEqual(@as(i64, 2), note.get("examined").?.integer);
    try testing.expect(!note.get("truncated").?.bool);

    // Ignore case through the flag.
    const r2 = f.get(&ar, true, "/api/v1/search?q=order&regex=ORDER&regex_flags=i");
    try testing.expectEqual(http.Status.ok, r2.status);
    try testing.expect(std.mem.indexOf(u8, r2.body, "\"title\":\"A\"") != null and std.mem.indexOf(u8, r2.body, "\"title\":\"B\"") != null);
}

test "re:/pattern/ in the query text works like the regex parameters" {
    var f: RegexFixture = undefined;
    try f.init(.{});
    defer f.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const typed = f.get(&ar, true, "/api/v1/search?q=order%20re:/%5Cd%7B3%7D-%5Cd%2B/");
    const param = f.get(&ar, true, "/api/v1/search?q=order&regex=%5Cd%7B3%7D-%5Cd%2B");
    try testing.expectEqual(http.Status.ok, typed.status);
    try testing.expectEqualStrings(param.body, typed.body);
    // Negated: the documents that do not match.
    const neg = f.get(&ar, true, "/api/v1/search?q=order%20-re:/%5Cd%7B3%7D-%5Cd%2B/");
    try testing.expectEqual(http.Status.ok, neg.status);
    try testing.expect(!std.mem.eql(u8, neg.body, typed.body));
    // Mistakes get a message, and so does using both forms.
    for ([_][]const u8{ "/api/v1/search?q=order%20re:/abc", "/api/v1/search?q=order%20re:/a/g", "/api/v1/search?q=order%20re:/a/%20re:/b/", "/api/v1/search?q=order%20re:/a/&regex=b" }) |t| {
        const r = f.get(&ar, true, t);
        errdefer std.debug.print("target: {s}\n", .{t});
        try testing.expectEqual(http.Status.bad_request, r.status);
    }
    // Without the regex service it is refused as before, and the page keeps the typed text.
    const off = f.get(&ar, false, "/api/v1/search?q=order%20re:/a/");
    try testing.expectEqual(http.Status.bad_request, off.status);
    const page = f.get(&ar, true, "/search?q=order%20re:/%5Cd%2B/");
    try testing.expect(std.mem.indexOf(u8, page.body, "value=\"order re:/\\d+/\"") != null);
}

test "API regex errors are JSON with stable codes" {
    var f: RegexFixture = undefined;
    try f.init(.{});
    defer f.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const cases = [_]struct { target: []const u8, service: bool, status: http.Status, code: []const u8 }{
        .{ .target = "/api/v1/search?q=order&regex=(unclosed", .service = true, .status = .bad_request, .code = "invalid_pattern" },
        .{ .target = "/api/v1/search?q=order&regex=a&regex_flags=x", .service = true, .status = .bad_request, .code = "invalid_parameter" },
        .{ .target = "/api/v1/search?q=order&regex=a&regex_dialect=pcre", .service = true, .status = .bad_request, .code = "invalid_parameter" },
        .{ .target = "/api/v1/search?q=order&regex=a", .service = false, .status = .bad_request, .code = "regex_disabled" },
    };
    for (cases) |c| {
        const r = f.get(&ar, c.service, c.target);
        try testing.expectEqual(c.status, r.status);
        const needle = try std.fmt.allocPrint(ar.allocator(), "\"code\":\"{s}\"", .{c.code});
        try testing.expect(std.mem.indexOf(u8, r.body, needle) != null);
    }
    // A pattern that cannot finish is refused as too complex (422).
    var hay: [60]u8 = @splat('a');
    hay[59] = 'b';
    try f.store.store().put(f.hits[0].id, &hay);
    try f.store.store().put(f.hits[1].id, &hay);
    var small: RegexFixture = undefined;
    try small.init(.{ .max_complex = 1, .max_steps = 20_000 });
    defer small.deinit();
    try small.store.store().put(small.hits[0].id, &hay);
    const r = small.get(&ar, true, "/api/v1/search?q=order&regex=(a%2B)%2B%24");
    try testing.expectEqual(http.Status.unprocessable_entity, r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "pattern_too_complex") != null);
}

test "a busy regex service answers 429 with Retry-After" {
    var f: RegexFixture = undefined;
    try f.init(.{ .concurrency = 1, .queue_ms = 10 });
    defer f.deinit();
    f.svc.permits.waitUncancelable(testing.io); // another query holds the only turn
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const r = f.get(&ar, true, "/api/v1/search?q=order&regex=order");
    try testing.expectEqual(http.Status.too_many_requests, r.status);
    try testing.expectEqualStrings("2", headerValue(r, "retry-after").?);
    f.svc.permits.post(testing.io);
}

test "the HTML page offers the regex field only when enabled, escapes it and keeps it when paging" {
    var f: RegexFixture = undefined;
    try f.init(.{});
    defer f.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const home_off = f.get(&ar, false, "/");
    // The regex is part of the query language: no separate box, and the side panel
    // explains it only when the server has it.
    try testing.expect(std.mem.indexOf(u8, home_off.body, "name=\"regex\"") == null);
    try testing.expect(std.mem.indexOf(u8, home_off.body, "re:/") == null);
    const home_on = f.get(&ar, true, "/");
    try testing.expect(std.mem.indexOf(u8, home_on.body, "name=\"regex\"") == null);
    try testing.expect(std.mem.indexOf(u8, home_on.body, "re:/") != null);
    try testing.expect(std.mem.indexOf(u8, home_on.body, "class=\"side\"") != null);

    // A pattern typed in the box is shown escaped (never as markup) and kept in the box.
    const r = f.get(&ar, true, "/search?q=order%20re:/%3Cb%3E%5Cd%2B/");
    try testing.expect(std.mem.indexOf(u8, r.body, "<b>\\d+") == null);
    try testing.expect(std.mem.indexOf(u8, r.body, "&lt;b&gt;\\d+") != null);

    const bad = f.get(&ar, true, "/search?q=order&regex=(x");
    try testing.expectEqual(http.Status.bad_request, bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "invalid pattern") != null);

    // The pager link carries the regex.
    f.fake.result = .{ .hits = &f.hits, .has_more = true };
    const paged = f.get(&ar, true, "/search?q=order&regex=order&regex_flags=i");
    try testing.expect(std.mem.indexOf(u8, paged.body, "regex=order&amp;regex_flags=i") != null or std.mem.indexOf(u8, paged.body, "regex=order") != null);
}

test "help pages explain the search syntax and regex, with this server's limits" {
    var f: RegexFixture = undefined;
    try f.init(.{ .max_candidates = 123, .budget_ms = 456 });
    defer f.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const tips = f.get(&ar, true, "/help/search");
    try testing.expectEqual(http.Status.ok, tips.status);
    for ([_][]const u8{ "AND", "OR", "NOT", "comp*", "compositor~", "~5", "one typo away", "regular expressions" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, tips.body, needle) != null);
    }
    try testing.expectEqualStrings(tips.body, f.get(&ar, true, "/help").body);
    const rx = f.get(&ar, true, "/help/regex");
    try testing.expect(std.mem.indexOf(u8, rx.body, "How a regex search works") != null);
    try testing.expect(std.mem.indexOf(u8, rx.body, "123 documents checked") != null);
    try testing.expect(std.mem.indexOf(u8, rx.body, "456 ms") != null);
    // Without regex enabled the tips page does not mention it, and the home page links the tips.
    const tips_off = f.get(&ar, false, "/help/search");
    try testing.expect(std.mem.indexOf(u8, tips_off.body, "/help/regex") == null);
    try testing.expect(std.mem.indexOf(u8, f.get(&ar, true, "/").body, "href=\"/help/search\"") != null);
    try testing.expect(std.mem.indexOf(u8, f.get(&ar, true, "/").body, "href=\"/help/regex\"") != null);
}

test "results report how the query was read and whether typos were allowed" {
    var f: FakeSearch = .{ .result = .{ .hits = &sample_hits, .has_more = false, .interpreted = "linux OR bsd", .fuzzy = true } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const api = run(&f, .GET, "/api/v1/search?q=linux+OR+bsd&fuzzy=1", &ar);
    try testing.expectEqual(http.Status.ok, api.status);
    try testing.expect(std.mem.indexOf(u8, api.body, "\"interpreted\":\"linux OR bsd\"") != null);
    try testing.expect(std.mem.indexOf(u8, api.body, "\"fuzzy\":true") != null);
    try testing.expectEqual(dk.search.Fuzzy.on, f.last.?.fuzzy);
    _ = run(&f, .GET, "/api/v1/search?q=x&fuzzy=0", &ar);
    try testing.expectEqual(dk.search.Fuzzy.off, f.last.?.fuzzy);
    _ = run(&f, .GET, "/api/v1/search?q=x", &ar);
    try testing.expectEqual(dk.search.Fuzzy.default, f.last.?.fuzzy);
    const bad = run(&f, .GET, "/api/v1/search?q=x&fuzzy=maybe", &ar);
    try testing.expectEqual(http.Status.bad_request, bad.status);
    // The page tells the person, and offers the exact search back.
    const page = run(&f, .GET, "/search?q=linux+OR+bsd", &ar);
    try testing.expect(std.mem.indexOf(u8, page.body, "similar spellings") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "&amp;fuzzy=0\">Search exactly as typed") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "Searching for: <code>linux OR bsd</code>") != null);
}
