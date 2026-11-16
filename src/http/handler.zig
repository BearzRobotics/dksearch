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

const Route = enum { help_search, help_regex, home, search_page, api_search, api_retrieve, api_health, style, document, zim, other };

fn route(path: []const u8) Route {
    if (std.mem.eql(u8, path, "/")) return .home;
    if (std.mem.eql(u8, path, "/search")) return .search_page;
    if (std.mem.eql(u8, path, "/help") or std.mem.eql(u8, path, "/help/search")) return .help_search;
    if (std.mem.eql(u8, path, "/help/regex")) return .help_regex;
    if (std.mem.eql(u8, path, "/api/v1/search")) return .api_search;
    if (std.mem.eql(u8, path, "/api/v1/retrieve")) return .api_retrieve;
    if (std.mem.eql(u8, path, "/api/v1/health")) return .api_health;
    if (std.mem.eql(u8, path, "/assets/style.css")) return .style;
    if (std.mem.startsWith(u8, path, "/doc/")) return .document;
    if (std.mem.startsWith(u8, path, "/zim/")) return .zim;
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
    /// ZIM files whose articles can be shown from the file itself.
    zims: ?*const dk.zimserve.Service = null,
    /// The configured sources, for the Source drop-down (follows edits made in the admin panel).
    sources: ?*dk.sourcestore.Store = null,
};

/// How much each source counts in the ranking (only those that differ from 100).
fn sourceBoosts(arena: Allocator, services: Services) error{OutOfMemory}![]const dk.search.SourceBoost {
    const store = services.sources orelse return &.{};
    var out: std.ArrayList(dk.search.SourceBoost) = .empty;
    for (store.snapshot()) |src| if (src.enabled and src.boost != 100) try out.append(arena, .{ .source = try arena.dupe(u8, src.name), .percent = src.boost });
    return out.items;
}

/// The enabled sources, sorted by kind and then name, for the Source drop-down.
fn sourceChoices(arena: Allocator, services: Services) error{OutOfMemory}![]const html.SourceChoice {
    const store = services.sources orelse return &.{};
    var out: std.ArrayList(html.SourceChoice) = .empty;
    for (store.snapshot()) |src| if (src.enabled) try out.append(arena, .{ .name = try arena.dupe(u8, src.name), .kind = try arena.dupe(u8, src.kind) });
    std.mem.sort(html.SourceChoice, out.items, {}, struct {
        fn lt(_: void, a: html.SourceChoice, b: html.SourceChoice) bool {
            const k = std.mem.order(u8, a.kind, b.kind);
            if (k != .eq) return k == .lt;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.items;
}

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
            html.writeHomeForm(&aw.writer, null, .{ .regex_enabled = regex != null, .sources = try sourceChoices(arena, services) }) catch return error.OutOfMemory;
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
        .api_search => try apiSearch(arena, searcher, regex, try sourceChoices(arena, services), try sourceBoosts(arena, services), t.params),
        .api_retrieve => try apiRetrieve(arena, searcher, services, t.params),
        .search_page => try pageSearch(arena, searcher, regex, try sourceChoices(arena, services), try sourceBoosts(arena, services), t.params),
        .document => try documentPage(arena, searcher, services, t.path, t.params),
        .zim => try zimPage(arena, services, t.path),
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
    if (params.get("sort")) |v| if (v.len > 0) {
        q.sort = std.meta.stringToEnum(dk.search.Sort, v) orelse
            return .{ .bad = .{ .name = "sort", .message = "must be relevance, newest, oldest, largest, smallest or title" } };
    };
    q.filter_strings = params.all(arena, "filter") catch return error.OutOfMemory;
    if (q.filter_strings.len > 16) return .{ .bad = .{ .name = "filter", .message = "at most 16 filters" } };
    for (q.filter_strings) |f| if (f.len > 200) return .{ .bad = .{ .name = "filter", .message = "a filter is at most 200 characters" } };
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
    /// A page on this server for the document: its details, stored text and original (`/doc/<id>`).
    view_url: []const u8,
    language: ?[]const u8,
    content_type: ?[]const u8,
    /// page, text, markdown, pdf, document, image, video, audio, data or other.
    kind: ?[]const u8,
    domain: ?[]const u8,
    author: ?[]const u8,
    /// Size in bytes (of the original file when the source knows it, otherwise of the text).
    size: ?u64,
    /// Unix time in seconds, when the source gave one.
    modified_at: ?i64,
    /// With `explain=1`: the parts of the score (text match in the title and in the body, the source's
    /// boost, the recency factor).
    explain: ?dk.search.Explain = null,
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

fn apiSearch(arena: Allocator, searcher: dk.search.Searcher, regex: ?*dk.regexsearch.Service, sources: []const html.SourceChoice, boosts: []const dk.search.SourceBoost, params: query.Params) error{OutOfMemory}!Response {
    const parsed = switch (try parseQuery(arena, params, false)) {
        .ok => |p| p,
        .bad => |b| return apiError(arena, .bad_request, "invalid_parameter", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    var q = parsed.q;
    q.boosts = boosts;
    switch (try applySources(arena, &q, sources, params)) {
        .ok => {},
        .bad => |b| return apiError(arena, .bad_request, "invalid_parameter", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    }
    if (params.get("explain")) |v| q.explain = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
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
        .view_url = try std.fmt.allocPrint(arena, "/doc/{s}", .{std.fmt.bytesToHex(h.id, .lower)}),
        .language = h.language,
        .content_type = h.content_type,
        .kind = h.kind,
        .domain = h.domain,
        .author = h.author,
        .size = h.size,
        .modified_at = h.modified_at,
        .explain = h.explain,
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

// ------------------------------------------------------------ ZIM articles

/// `zim://name/encoded/path` split into the source name and the (still encoded) path.
fn zimAddress(url: []const u8) ?struct { name: []const u8, path: []const u8 } {
    const prefix = "zim://";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0 or slash + 1 >= rest.len) return null;
    return .{ .name = rest[0..slash], .path = rest[slash + 1 ..] };
}

fn validSourceName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) return false;
    return true;
}

/// An article, picture or page from a ZIM file: `/zim/<source>/<path>`.
fn zimPage(arena: Allocator, services: Services, path: []const u8) error{OutOfMemory}!Response {
    const svc = services.zims orelse return htmlError(arena, .not_found, "Not found", "Articles are not served here.");
    const rest = path["/zim/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return htmlError(arena, .not_found, "Not found", "No such article.");
    const name = rest[0..slash];
    if (!validSourceName(name)) return htmlError(arena, .not_found, "Not found", "No such article.");
    const decoded = (try dk.zimserve.decodePath(arena, rest[slash + 1 ..])) orelse return htmlError(arena, .not_found, "Not found", "No such article.");
    const got = svc.fetch(arena, name, decoded) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotServed, error.NotFound, error.Unsupported => htmlError(arena, .not_found, "Not found", "No such article in that file."),
        error.TooLarge => htmlError(arena, .payload_too_large, "Too large", "That entry is too large to be shown here."),
        error.Io => htmlError(arena, .internal_server_error, "Error", "The ZIM file could not be read."),
    };

    if (dk.zimserve.isHtml(got.mime)) {
        const ctx: dk.zimserve.LinkContext = .{ .connector = name, .entry_path = got.path };
        const body = dk.htmlsafe.sanitizeAlloc(arena, got.bytes, .{ .rewrite = dk.zimserve.rewriteLink, .ctx = @constCast(&ctx), .max_output_bytes = 4 * 1024 * 1024 }) catch return error.OutOfMemory;
        var aw: std.Io.Writer.Allocating = .init(arena);
        html.writeArticle(&aw.writer, got.title, name, body) catch return error.OutOfMemory;
        return htmlResponse(arena, .ok, aw.written());
    }
    // Pictures and plain text are sent as they are, under a policy that lets them do nothing else.
    const is_svg = std.mem.startsWith(u8, got.mime, "image/svg");
    const headers = try arena.alloc(Header, 4);
    headers[0] = .{ .name = "x-content-type-options", .value = "nosniff" };
    headers[1] = .{ .name = "referrer-policy", .value = "no-referrer" };
    headers[2] = .{ .name = "content-security-policy", .value = if (is_svg) "default-src 'none'; style-src 'unsafe-inline'; sandbox" else "default-src 'none'; img-src 'self'" };
    headers[3] = asset_cache;
    const ct: []const u8 = if (std.mem.startsWith(u8, got.mime, "text/plain")) "text/plain; charset=utf-8" else got.mime;
    return .{ .status = .ok, .content_type = ct, .body = got.bytes, .headers = headers };
}

// ------------------------------------------------------------ document viewer

/// Longest stored text shown on the viewer page, in bytes.
const max_view_bytes = 512 * 1024;

fn documentPage(arena: Allocator, searcher: dk.search.Searcher, services: Services, path: []const u8, params: query.Params) error{OutOfMemory}!Response {
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
    // A ZIM article can be read from the file itself.
    var open_link: ?html.OpenLink = null;
    if (can_open) {
        open_link = .{ .href = try std.fmt.allocPrint(arena, "/doc/{s}/file", .{hex}), .label = "Open the original file" };
    } else if (services.zims) |z| if (hit.url) |u| if (zimAddress(u)) |za| if (z.has(za.name)) {
        open_link = .{ .href = try std.fmt.allocPrint(arena, "/zim/{s}/{s}", .{ za.name, za.path }), .label = "Read the article" };
    };

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
    // Markdown is shown formatted (safely), with a link to the plain text.
    const is_markdown = if (hit.content_type) |ct| std.mem.startsWith(u8, ct, "text/markdown") else false;
    const plain_view = if (params.get("view")) |v| std.mem.eql(u8, v, "text") else false;
    var rendered: ?[]const u8 = null;
    if (is_markdown and !plain_view) if (text) |t| {
        rendered = dk.render.markdown(arena, t) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => null, // too big to format: the plain text is shown
        };
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    html.writeDocument(&aw.writer, hit, text, cut, open_link, rendered, is_markdown) catch return error.OutOfMemory;
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

/// Turns the ticked sources (`source`, repeatable) and the single `connector` into source conditions on `q`: each is
/// a source name or `kind:NAME` for every source of a kind, and they are alternatives. Returns what was picked.
fn applySources(arena: Allocator, q: *dk.search.Query, sources: []const html.SourceChoice, params: query.Params) error{OutOfMemory}!union(enum) { ok: []const []const u8, bad: ParamError } {
    var picked: std.ArrayList([]const u8) = .empty;
    for (try params.all(arena, "source")) |v| {
        if (!validFilter(v)) return .{ .bad = .{ .name = "source", .message = "invalid value" } };
        if (picked.items.len >= 64) return .{ .bad = .{ .name = "source", .message = "at most 64 sources" } };
        try picked.append(arena, v);
    }
    // The single `connector` is an exact match unless it names a kind or is combined with ticked sources.
    const connector_is_kind = if (q.connector) |c| std.mem.startsWith(u8, c, "kind:") else false;
    const fold = picked.items.len > 0 or connector_is_kind;
    if (q.connector) |c| try picked.append(arena, c);
    if (fold) {
        var list: std.ArrayList(dk.search.Filter) = .empty;
        for (picked.items) |c| {
            if (std.mem.startsWith(u8, c, "kind:")) {
                for (sources) |src| if (std.mem.eql(u8, src.kind, c["kind:".len..])) try list.append(arena, .{ .field = .source, .text = src.name });
            } else try list.append(arena, .{ .field = .source, .text = c });
        }
        // Only kinds with no sources: match nothing rather than everything.
        if (list.items.len == 0) try list.append(arena, .{ .field = .source, .text = "(no source of that kind)" });
        q.filters = list.items;
        q.connector = null;
    }
    return .{ .ok = picked.items };
}

// ------------------------------------------------------------ retrieval API

const max_retrieve_text_bytes = 8 * 1024 * 1024; // of one document read for chunking
const max_retrieve_total_bytes = 64 * 1024 * 1024; // of all candidates together

const RetrievedChunk = struct {
    doc_id: []const u8,
    view_url: []const u8,
    source: []const u8,
    title: ?[]const u8,
    url: ?[]const u8,
    /// Headings above the chunk, outermost first.
    heading: []const []const u8,
    /// Position among the document's chunks, and how many there are.
    index: u32,
    of: u32,
    /// Byte span in the document's stored text.
    start: usize,
    end: usize,
    /// Page, when the text has page breaks.
    page: ?u32,
    score: f64,
    text: []const u8,
    before: []const []const u8,
    after: []const []const u8,
};

/// `GET /api/v1/retrieve`: the best passages for a question, for a RAG client. The candidate documents are found
/// the way a search finds them (so every filter and source choice works), their stored text is split into
/// chunks and the chunks are ranked on the query's words. No model is involved.
fn apiRetrieve(arena: Allocator, searcher: dk.search.Searcher, services: Services, params: query.Params) error{OutOfMemory}!Response {
    const store = services.content orelse return apiError(arena, .service_unavailable, "no_content", "document texts are not available (nothing has been imported yet)");
    const parsed = switch (try parseQuery(arena, params, false)) {
        .ok => |p| p,
        .bad => |b| return apiError(arena, .bad_request, "invalid_parameter", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    var q = parsed.q;
    q.boosts = try sourceBoosts(arena, services);
    switch (try applySources(arena, &q, try sourceChoices(arena, services), params)) {
        .ok => {},
        .bad => |b| return apiError(arena, .bad_request, "invalid_parameter", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    }
    const bounded = struct {
        fn get(ps: query.Params, name: []const u8, default: u32, min: u32, max: u32) error{Bad}!u32 {
            const v = ps.get(name) orelse return default;
            if (v.len == 0) return default;
            const n = std.fmt.parseInt(u32, v, 10) catch return error.Bad;
            if (n < min or n > max) return error.Bad;
            return n;
        }
    };
    const k = bounded.get(params, "k", 8, 1, 50) catch return apiError(arena, .bad_request, "invalid_parameter", "k: must be 1 to 50");
    const candidates = bounded.get(params, "candidates", 30, 1, 100) catch return apiError(arena, .bad_request, "invalid_parameter", "candidates: must be 1 to 100");
    const context = bounded.get(params, "context", 0, 0, 3) catch return apiError(arena, .bad_request, "invalid_parameter", "context: must be 0 to 3");
    const chunk_chars = bounded.get(params, "chunk_chars", 1200, dk.retrieve.min_chunk_chars, dk.retrieve.max_chunk_chars) catch return apiError(arena, .bad_request, "invalid_parameter", "chunk_chars: must be 200 to 8000");
    const overlap = bounded.get(params, "overlap", 150, 0, 2000) catch return apiError(arena, .bad_request, "invalid_parameter", "overlap: must be 0 to 2000");
    const all_terms = try dk.retrieve.queryTerms(arena, q.text);
    if (all_terms.len == 0) return apiError(arena, .bad_request, "empty_query", "retrieval needs at least one word to look for");
    // Words like "what" and "the" say nothing about which passage answers; leave them out unless that is everything.
    var meaningful: std.ArrayList([]const u8) = .empty;
    for (all_terms) |w| if (!dk.retrieve.isQuestionStopWord(w)) try meaningful.append(arena, w);
    const terms = if (meaningful.items.len > 0) meaningful.items else all_terms;
    const dedupe = if (params.get("dedupe")) |v| !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) else true;
    // The candidates: a plain-words question matches documents with any of its meaningful words.
    q.text = try dk.retrieve.candidateQuery(arena, q.text);

    q.limit = candidates;
    q.offset = 0;
    q.sort = .relevance;
    const page = searcher.search(arena, q) catch |e| return searchFailure(arena, e, true);

    // The same work in several formats (book.md, book.pdf, book.epub in one folder) is one candidate: the
    // format that keeps the most structure wins.
    var kept: std.ArrayList(dk.search.Hit) = .empty;
    var duplicates: u32 = 0;
    for (page.hits) |h| {
        if (dedupe) if (h.url) |u| {
            const stem = dk.retrieve.stemOf(u);
            var merged = false;
            for (kept.items) |*have| {
                const ku = have.url orelse continue;
                if (std.mem.eql(u8, have.connector, h.connector) and std.mem.eql(u8, dk.retrieve.stemOf(ku), stem)) {
                    if (dk.retrieve.formatRank(u) < dk.retrieve.formatRank(ku)) have.* = h;
                    merged = true;
                    duplicates += 1;
                    break;
                }
            }
            if (merged) continue;
        };
        try kept.append(arena, h);
    }

    // Chunk the candidates' stored texts.
    const Doc = struct { hit: dk.search.Hit, chunks: []const dk.retrieve.Chunk };
    var docs: std.ArrayList(Doc) = .empty;
    var all_text: std.ArrayList([]const u8) = .empty;
    var all_head: std.ArrayList([]const u8) = .empty;
    var owner: std.ArrayList(struct { doc: u32, chunk: u32 }) = .empty;
    var total: usize = 0;
    var skipped: u32 = 0;
    for (kept.items) |h| {
        if (total >= max_retrieve_total_bytes) {
            skipped += 1;
            continue;
        }
        const bytes = store.get(arena, h.id) catch {
            skipped += 1; // no stored text (the source does not keep it, or it is gone)
            continue;
        };
        var text = bytes;
        if (text.len > max_retrieve_text_bytes) {
            var end: usize = max_retrieve_text_bytes;
            while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
            text = text[0..end];
        }
        total += text.len;
        const cs = dk.retrieve.chunk(arena, text, .{ .chunk_chars = chunk_chars, .overlap = overlap }) catch return error.OutOfMemory;
        const di: u32 = @intCast(docs.items.len);
        try docs.append(arena, .{ .hit = h, .chunks = cs });
        for (cs) |c| {
            try all_text.append(arena, c.text);
            try all_head.append(arena, try std.mem.join(arena, " / ", c.heading));
            try owner.append(arena, .{ .doc = di, .chunk = c.index });
        }
    }
    const ranked = try dk.retrieve.rank(arena, terms, all_text.items, all_head.items);
    const n_out = @min(ranked.len, k);
    const out = try arena.alloc(RetrievedChunk, n_out);
    for (ranked[0..n_out], out) |r, *o| {
        const ow = owner.items[r.at];
        const d = docs.items[ow.doc];
        const c = d.chunks[ow.chunk];
        const lo = ow.chunk -| context;
        const hi = @min(ow.chunk + context + 1, @as(u32, @intCast(d.chunks.len)));
        const before = try arena.alloc([]const u8, ow.chunk - lo);
        for (before, lo..) |*b, i| b.* = d.chunks[i].text;
        const after = try arena.alloc([]const u8, hi - (ow.chunk + 1));
        for (after, ow.chunk + 1..) |*b, i| b.* = d.chunks[i].text;
        const hex = std.fmt.bytesToHex(d.hit.id, .lower);
        o.* = .{
            .doc_id = try arena.dupe(u8, &hex),
            .view_url = try std.fmt.allocPrint(arena, "/doc/{s}", .{hex}),
            .source = d.hit.connector,
            .title = d.hit.title,
            .url = d.hit.url,
            .heading = c.heading,
            .index = c.index,
            .of = @intCast(d.chunks.len),
            .start = c.start,
            .end = c.end,
            .page = c.page,
            .score = r.score,
            .text = c.text,
            .before = before,
            .after = after,
        };
    }
    return jsonResponse(arena, .ok, .{ .chunks = out, .candidates = @as(u32, @intCast(kept.items.len)), .duplicates_merged = duplicates, .without_text = skipped });
}

fn pageSearch(arena: Allocator, searcher: dk.search.Searcher, regex: ?*dk.regexsearch.Service, sources: []const html.SourceChoice, boosts: []const dk.search.SourceBoost, params: query.Params) error{OutOfMemory}!Response {
    const parsed = switch (try parseQuery(arena, params, true)) {
        .ok => |p| p,
        .bad => |b| return htmlError(arena, .bad_request, "Bad request", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    var q = parsed.q;
    q.boosts = boosts;
    // The ticked sources (`source`, repeatable) and the older single `connector`: each is a source name or
    // `kind:NAME` for every source of a kind. They are alternatives (`kind:zim` is all its sources).
    const picked = switch (try applySources(arena, &q, sources, params)) {
        .ok => |p| p,
        .bad => |b| return htmlError(arena, .bad_request, "Bad request", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    var form: html.Form = .{ .q = parsed.typed, .language = q.language orelse "", .picked = picked, .regex_enabled = regex != null, .exact_only = q.fuzzy == .off, .sources = sources, .sort = params.get("sort") orelse "" };
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
            html.writeHomeForm(&aw.writer, "Enter something to search for.", .{ .regex_enabled = regex != null, .sources = sources }) catch return error.OutOfMemory;
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

test "the API tells what it knows about each hit, takes filter and sort parameters, and refuses bad ones" {
    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const day = 86400;
    const docs = [_]dk.document.Document{
        .{ .connector = "notes", .source_id = "a", .title = "Alpha", .text = "kernel notes", .canonical_url = "https://docs.example.org/guide/a.pdf", .content_type = "application/pdf", .author = "Jo", .language = "en", .modified_at = 20 * day, .extra = &.{.{ .key = "file_size", .value = "4096" }} },
        .{ .connector = "notes", .source_id = "b", .title = "Beta", .text = "kernel readme", .canonical_url = "https://example.org/b.md", .content_type = "text/markdown", .modified_at = 10 * day },
    };
    for (docs) |d| try idx.indexer().add(d.id(), d);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const r = handle(a, idx.searcher(), .GET, "/api/v1/search?q=kernel&sort=oldest");
    try testing.expectEqual(http.Status.ok, r.status);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, r.body, .{});
    const hits = parsed.object.get("hits").?.array.items;
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("Beta", hits[0].object.get("title").?.string); // oldest first
    const first = hits[1].object;
    try testing.expectEqualStrings("pdf", first.get("kind").?.string);
    try testing.expectEqualStrings("docs.example.org", first.get("domain").?.string);
    try testing.expectEqualStrings("application/pdf", first.get("content_type").?.string);
    try testing.expectEqualStrings("Jo", first.get("author").?.string);
    try testing.expectEqual(@as(i64, 4096), first.get("size").?.integer);
    try testing.expectEqual(@as(i64, 20 * day), first.get("modified_at").?.integer);
    try testing.expect(std.mem.startsWith(u8, first.get("view_url").?.string, "/doc/"));

    // Repeated filter parameters, in the query language's spelling.
    const f = handle(a, idx.searcher(), .GET, "/api/v1/search?q=kernel&filter=ext:md&filter=-domain:docs.example.org");
    const only = (try std.json.parseFromSliceLeaky(std.json.Value, a, f.body, .{})).object.get("hits").?.array.items;
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqualStrings("Beta", only[0].object.get("title").?.string);
    // Mistakes are 400 with a name, never a crash.
    for ([_][]const u8{ "/api/v1/search?q=kernel&sort=sideways", "/api/v1/search?q=kernel&filter=nonsense:1", "/api/v1/search?q=kernel&filter=size:big" }) |t| {
        errdefer std.debug.print("target: {s}\n", .{t});
        try testing.expectEqual(http.Status.bad_request, handle(a, idx.searcher(), .GET, t).status);
    }
    // The page keeps the chosen order and offers it.
    const page = handle(a, idx.searcher(), .GET, "/search?q=kernel&sort=newest");
    try testing.expect(std.mem.indexOf(u8, page.body, "<option value=\"newest\" selected>Newest</option>") != null);
}

test "retrieval: the best passages of the candidate documents, with headings, spans, neighbours and attribution" {
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const id_a: dk.document.Id = .{ 0xaa, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const id_b: dk.document.Id = .{ 0xbb, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try mem.store().put(id_a, "# Mythology\n\n## Norse\n\nOdin had two ravens, Huginn and Muninn, who flew over the world.\n\n## Greek\n\nZeus ruled from Olympus and threw thunderbolts.");
    try mem.store().put(id_b, "A cookbook about bread and soup, with nothing about birds.");
    const hits = [_]dk.search.Hit{
        .{ .id = id_a, .connector = "books", .url = "file:///x/myth.md", .title = "Myths", .snippet = null, .score = 2 },
        .{ .id = id_b, .connector = "cooking", .url = null, .title = "Cooking", .snippet = null, .score = 1 },
    };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    const services: Services = .{ .content = mem.store() };
    const r = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/api/v1/retrieve?q=odin+ravens&k=3&context=1&chunk_chars=200&overlap=0");
    try testing.expectEqual(http.Status.ok, r.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    const chunks = parsed.value.object.get("chunks").?.array.items;
    try testing.expect(chunks.len >= 1);
    const first = chunks[0].object;
    try testing.expectEqualStrings("books", first.get("source").?.string);
    try testing.expect(std.mem.indexOf(u8, first.get("text").?.string, "ravens") != null);
    try testing.expectEqualStrings("Mythology", first.get("heading").?.array.items[0].string);
    try testing.expect(std.mem.startsWith(u8, first.get("view_url").?.string, "/doc/aa"));
    try testing.expect(first.get("end").?.integer > first.get("start").?.integer);
    try testing.expect(first.get("of").?.integer >= 1);
    try testing.expect(first.get("page").? == .null);
    for (chunks) |c| try testing.expect(!std.mem.eql(u8, c.object.get("source").?.string, "cooking")); // no matching passage
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("candidates").?.integer);
    // The candidates were asked for like a search: the query's words, the sources picked.
    _ = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/api/v1/retrieve?q=odin&source=books&candidates=5");
    try testing.expectEqual(@as(u32, 5), fake.last.?.limit);
    try testing.expectEqualStrings("books", fake.last.?.filters[0].text);
    // A question is searched by its meaningful words, joined by OR.
    _ = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/api/v1/retrieve?q=What+did+the+ravens+of+Odin+do");
    try testing.expectEqualStrings("ravens OR Odin", fake.last.?.text);
    // The same work in two formats is one candidate (the Markdown one); dedupe=0 keeps both.
    const id_c: dk.document.Id = .{ 0xcc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try mem.store().put(id_c, "Odin had two ravens (the PDF copy).");
    const dup_hits = [_]dk.search.Hit{
        .{ .id = id_c, .connector = "books", .url = "file:///x/myth.pdf", .title = "Myths", .snippet = null, .score = 3 },
        hits[0],
    };
    fake.result = .{ .hits = &dup_hits, .has_more = false };
    const merged = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/api/v1/retrieve?q=odin+ravens");
    var mp = try std.json.parseFromSlice(std.json.Value, testing.allocator, merged.body, .{});
    defer mp.deinit();
    try testing.expectEqual(@as(i64, 1), mp.value.object.get("candidates").?.integer);
    try testing.expectEqual(@as(i64, 1), mp.value.object.get("duplicates_merged").?.integer);
    for (mp.value.object.get("chunks").?.array.items) |c| try testing.expect(std.mem.startsWith(u8, c.object.get("view_url").?.string, "/doc/aa"));
    const both = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/api/v1/retrieve?q=odin+ravens&dedupe=0");
    var bp = try std.json.parseFromSlice(std.json.Value, testing.allocator, both.body, .{});
    defer bp.deinit();
    try testing.expectEqual(@as(i64, 2), bp.value.object.get("candidates").?.integer);
    // Bad parameters and a query with no words are refused, and so is a server with no stored texts.
    try testing.expectEqual(http.Status.bad_request, handleServices(ar.allocator(), fake.searcher(), services, .GET, "/api/v1/retrieve?q=odin&k=0").status);
    try testing.expectEqual(http.Status.bad_request, handleServices(ar.allocator(), fake.searcher(), services, .GET, "/api/v1/retrieve?q=ext%3Amd").status);
    try testing.expectEqual(http.Status.service_unavailable, handleServices(ar.allocator(), fake.searcher(), .{}, .GET, "/api/v1/retrieve?q=odin").status);
}

test "the Source filter is a list of tick boxes grouped by kind; the ticked ones are searched and stay ticked" {
    var store = dk.sourcestore.Store.init(testing.allocator, testing.io, &.{
        .{ .name = "wiki", .kind = "wikipedia" },
        .{ .name = "notes", .kind = "files" },
        .{ .name = "docs", .kind = "files" },
        .{ .name = "knots", .kind = "zim" },
        .{ .name = "chemistry", .kind = "zim" },
        .{ .name = "off", .kind = "files", .enabled = false },
    });
    defer store.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    const services: Services = .{ .sources = &store };
    const home = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/");
    for ([_][]const u8{
        "<fieldset class=\"sources\">",
        "<strong>Local files</strong><label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"kind:files\"> all of these</label><label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"docs\"> docs</label><label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"notes\"> notes</label>",
        "<strong>ZIM files</strong><label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"kind:zim\"> all of these</label><label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"chemistry\"> chemistry</label>",
        "<strong>Wikipedia</strong><label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"wiki\"> wiki</label>", // one source: no "all" box
    }) |n| {
        errdefer std.debug.print("missing: {s}\n", .{n});
        try testing.expect(std.mem.indexOf(u8, home.body, n) != null);
    }
    try testing.expect(std.mem.indexOf(u8, home.body, "value=\"off\"") == null); // disabled sources are not offered
    try testing.expect(std.mem.indexOf(u8, home.body, " checked>") == null); // nothing ticked: all sources

    // Several ticked sources are alternatives, stay ticked, and travel with the paging links.
    const two = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/search?q=x&source=wiki&source=notes");
    try testing.expect(std.mem.indexOf(u8, two.body, "value=\"wiki\" checked>") != null);
    try testing.expect(std.mem.indexOf(u8, two.body, "value=\"notes\" checked>") != null);
    try testing.expect(std.mem.indexOf(u8, two.body, "value=\"docs\" checked>") == null);
    const used2 = fake.last.?;
    try testing.expect(used2.connector == null);
    try testing.expectEqual(@as(usize, 2), used2.filters.len);
    try testing.expectEqualStrings("wiki", used2.filters[0].text);
    try testing.expectEqualStrings("notes", used2.filters[1].text);

    // "All of these" for a kind searches every source of the kind and ticks them all.
    const kind = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/search?q=x&source=kind:zim&source=wiki");
    try testing.expect(std.mem.indexOf(u8, kind.body, "value=\"kind:zim\" checked>") != null);
    try testing.expect(std.mem.indexOf(u8, kind.body, "value=\"knots\" checked>") != null);
    const used = fake.last.?;
    try testing.expectEqual(@as(usize, 3), used.filters.len);
    try testing.expectEqualStrings("chemistry", used.filters[0].text);
    try testing.expectEqualStrings("knots", used.filters[1].text);
    try testing.expectEqualStrings("wiki", used.filters[2].text);

    // The older single `connector=` parameter still works.
    const old = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/search?q=x&connector=wiki");
    try testing.expect(std.mem.indexOf(u8, old.body, "value=\"wiki\" checked>") != null);
    try testing.expectEqualStrings("wiki", fake.last.?.connector.?);

    // A kind with no sources matches nothing, never everything.
    _ = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/search?q=x&source=kind:feeds");
    try testing.expectEqual(@as(usize, 1), fake.last.?.filters.len);
    try testing.expectEqualStrings("(no source of that kind)", fake.last.?.filters[0].text);

    // A name that is not in the list stays ticked (escaped), so it can be unticked.
    const odd = handleServices(ar.allocator(), fake.searcher(), services, .GET, "/search?q=x&source=gone%3Cb%3E");
    try testing.expect(std.mem.indexOf(u8, odd.body, "<strong>Not configured</strong>") != null);
    try testing.expect(std.mem.indexOf(u8, odd.body, "value=\"gone&lt;b&gt;\" checked>") != null);
    // With no source store there is no list at all.
    const bare = handleServices(ar.allocator(), fake.searcher(), .{}, .GET, "/");
    try testing.expect(std.mem.indexOf(u8, bare.body, "fieldset") == null);
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
    for ([_][]const u8{ "Trip &lt;plan&gt;", "Packing list &amp; <b>route</b>", "file:///home/me/notes/trip.md", "markdown", "2023-11-14", "Jo", "notes" }) |needle| {
        errdefer std.debug.print("missing: {s}\n{s}\n", .{ needle, r.body });
        try testing.expect(std.mem.indexOf(u8, r.body, needle) != null);
    }
    // Markdown is formatted, safely; the plain view is the escaped text.
    try testing.expect(std.mem.indexOf(u8, r.body, "class=\"doctext rendered\"") != null);
    const as_text = handleServices(ar.allocator(), idx.searcher(), .{ .content = store.store() }, .GET, try std.fmt.allocPrint(ar.allocator(), "{s}?view=text", .{target}));
    try testing.expect(std.mem.indexOf(u8, as_text.body, "<pre class=\"doctext\">") != null);
    try testing.expect(std.mem.indexOf(u8, as_text.body, "Packing list &amp; &lt;b&gt;route&lt;/b&gt;") != null); // plain text is escaped
    try testing.expect(std.mem.indexOf(u8, as_text.body, "Show it formatted") != null);
    // The file address is shown as text, never as a link a browser cannot follow.
    try testing.expect(std.mem.indexOf(u8, r.body, "href=\"file:") == null);

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

test "ZIM articles are served from the file: sanitized, links and images through us, redirects followed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sample.zim", .data = dk.zim_sample });
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const abs = try tmp.dir.realPathFileAlloc(testing.io, "sample.zim", a);
    const archives = [_]dk.zimserve.Archive{.{ .connector = "sea", .path = abs }};
    const svc: dk.zimserve.Service = .{ .io = testing.io, .gpa = testing.allocator, .archives = &archives };
    const services: Services = .{ .zims = &svc };
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    const get = struct {
        fn at(arena: Allocator, f: *FakeSearch, sv: Services, path: []const u8) Response {
            return handleServices(arena, f.searcher(), sv, .GET, path);
        }
    }.at;

    const page = get(a, &fake, services, "/zim/sea/Lighthouse");
    try testing.expectEqual(http.Status.ok, page.status);
    try testing.expect(std.mem.startsWith(u8, page.content_type, "text/html"));
    for ([_][]const u8{ "<h1>Lighthouse</h1>", "A lighthouse is a tower", "polished the lens" }) |n| {
        errdefer std.debug.print("missing {s}\n{s}\n", .{ n, page.body });
        try testing.expect(std.mem.indexOf(u8, page.body, n) != null);
    }
    // The article's own script and style never reach the page.
    try testing.expect(std.mem.indexOf(u8, page.body, "var x=") == null);
    try testing.expect(std.mem.indexOf(u8, page.body, "p{}") == null);
    // A redirect shows its target; a picture and plain text are sent as they are.
    try testing.expect(std.mem.indexOf(u8, get(a, &fake, services, "/zim/sea/Light").body, "A lighthouse is a tower") != null);
    const logo = get(a, &fake, services, "/zim/sea/logo.png");
    try testing.expectEqualStrings("image/png", logo.content_type);
    try testing.expect(std.mem.startsWith(u8, logo.body, "\x89PNG"));
    const notes = get(a, &fake, services, "/zim/sea/notes.txt");
    try testing.expectEqualStrings("text/plain; charset=utf-8", notes.content_type);
    try testing.expect(std.mem.indexOf(u8, notes.body, "Spring tides") != null);
    // Percent-encoded paths work; unknown names and paths are 404, never an error page of ours.
    try testing.expectEqual(http.Status.ok, get(a, &fake, services, "/zim/sea/%4Cighthouse").status);
    for ([_][]const u8{ "/zim/sea/Nope", "/zim/other/Lighthouse", "/zim/sea/", "/zim/sea", "/zim/Sea/Lighthouse", "/zim/sea/%zz", "/zim/sea/M/Title", "/zim/../Lighthouse" }) |p| {
        errdefer std.debug.print("path: {s}\n", .{p});
        try testing.expectEqual(http.Status.not_found, get(a, &fake, services, p).status);
    }
    // Not configured: nothing is served.
    try testing.expectEqual(http.Status.not_found, get(a, &fake, .{}, "/zim/sea/Lighthouse").status);
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
