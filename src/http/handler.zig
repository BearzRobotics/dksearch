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
/// Pictures per page of the image gallery.
pub const gallery_page_size: u32 = 40;

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

const Route = enum { help_search, help_regex, home, search_page, sources_page, api_search, api_retrieve, api_answer, api_suggest, api_similar, unlock_page, lock_action, login_page, logout_action, feedback_action, suggest_action, search_script, api_export, api_peers, api_health, style, document, zim, wopi, other };

fn route(path: []const u8) Route {
    if (std.mem.eql(u8, path, "/")) return .home;
    if (std.mem.eql(u8, path, "/search")) return .search_page;
    if (std.mem.eql(u8, path, "/sources")) return .sources_page;
    if (std.mem.eql(u8, path, "/help") or std.mem.eql(u8, path, "/help/search")) return .help_search;
    if (std.mem.eql(u8, path, "/help/regex")) return .help_regex;
    if (std.mem.eql(u8, path, "/api/v1/search")) return .api_search;
    if (std.mem.eql(u8, path, "/api/v1/retrieve")) return .api_retrieve;
    if (std.mem.eql(u8, path, "/api/v1/answer")) return .api_answer;
    if (std.mem.eql(u8, path, "/unlock")) return .unlock_page;
    if (std.mem.eql(u8, path, "/lock")) return .lock_action;
    if (std.mem.eql(u8, path, "/login")) return .login_page;
    if (std.mem.eql(u8, path, "/logout")) return .logout_action;
    if (std.mem.eql(u8, path, "/feedback")) return .feedback_action;
    if (std.mem.eql(u8, path, "/suggest")) return .suggest_action;
    if (std.mem.eql(u8, path, "/api/v1/suggest")) return .api_suggest;
    if (std.mem.eql(u8, path, "/api/v1/similar")) return .api_similar;
    if (std.mem.eql(u8, path, "/api/v1/export")) return .api_export;
    if (std.mem.eql(u8, path, "/api/v1/peers")) return .api_peers;
    if (std.mem.eql(u8, path, "/api/v1/health")) return .api_health;
    if (std.mem.eql(u8, path, "/assets/style.css")) return .style;
    if (std.mem.eql(u8, path, "/assets/search.js")) return .search_script;
    if (std.mem.startsWith(u8, path, "/doc/")) return .document;
    if (std.mem.startsWith(u8, path, "/zim/")) return .zim;
    if (std.mem.startsWith(u8, path, "/wopi/files/")) return .wopi;
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
    /// The embedding server and the vectors, when `[embeddings]` is set (semantic=1 on search).
    embed: ?*const dk.embed.Service = null,
    /// Documents per source, counted now and then, for the source list and the page that lists the sources.
    source_stats: ?*dk.sourcestats.Cache = null,
    /// Domains never shown (the blocklist, and safe search's ban lists when on); null for none. The index applies it
    /// to searches; the handler to documents opened by id, peers' results and the like.
    lists: ?*const dk.domainlist.Lists = null,
    /// Safe search (ADR 0049): on for visitors by default; `unlock` holds the PIN and the unlocked browsers. `safe` is
    /// set for each request: whether safe search applies to the one being answered.
    /// Fetches the pictures of the web for the gallery (`[images] remote`); null: the gallery shows only local pictures.
    relay: ?*dk.imagerelay.Relay = null,
    safe_default: bool = false,
    unlock: ?*dk.safesearch.Unlock = null,
    /// The thumbnail cache of the gallery (`[images] thumbnails`); null: the gallery shows the originals.
    thumbs: ?*dk.thumbcache.Cache = null,
    /// The owner's password sign-in (`dksearch owner-password`, or the Access page of the administration interface).
    owner: ?*dk.owner.OwnerLogin = null,
    /// Add `Secure` to the sign-in cookie (set it when a proxy serves the site over HTTPS).
    cookie_secure: bool = false,
    /// What the request's `Accept-Language` said (set per request, never configured).
    accept_language: ?[]const u8 = null,
    /// Where the owner's marks on results are kept (`feedback.jsonl`); null: no feedback buttons. And whether the request
    /// being answered is from the owner signed in (set per request).
    feedback: ?*dk.feedback.Store = null,
    is_owner: bool = false,
    safe: bool = false,
    /// Results of highly boosted sources first (`[search] trusted_first`, from `trusted_min_boost` percent); a request's
    /// own `trusted=1` or `trusted=0` overrides it.
    trusted_first: bool = false,
    trusted_min_boost: u32 = 150,
    /// The most results one domain may have in a search (`[search] per_domain`; 0: no limit); a request's own
    /// `per_domain` overrides it.
    per_domain: u32 = 0,
    /// The collection the search page searches when nothing is picked (`search.default_collection`).
    default_collection: ?[]const u8 = null,
    /// A document server that office files can be opened in (`[docserver]`).
    docserver: ?*const dk.docserver.Service = null,
    /// The optional AI answer over retrieved passages (`[answers]`; null when off).
    answers: ?*dk.answer.Service = null,
    /// Other search engines as a fallback (opt-in; null when `[fallback]` is off).
    fallback: ?*const dk.fallback.Settings = null,
    /// This node's identity (signs answers to callers that sent a nonce) and the nonces already seen (so a signed
    /// request cannot be used twice). Both null when the node has no identity.
    identity: ?*const dk.identity.Identity = null,
    replay: ?*dk.identity.Replay = null,
    /// Other nodes this one can ask (`peers=1`), if any are configured.
    peers: ?*dk.peers.Service = null,
    /// What retrieval derives from stored texts (chunks, PDF page indexes), kept between requests.
    retrieve_cache: ?*dk.retrievecache.Cache = null,
    /// The configured sources, for the Source drop-down (follows edits made in the admin panel).
    sources: ?*dk.sourcestore.Store = null,
    /// Named groups of sources, for the `collection:` filter and the Collections choice.
    collections: []const dk.config.Collection = &.{},
    /// The collections anyone may search without an API key; null means every source.
    anonymous: ?[]const []const u8 = null,
    /// API keys, if the server has any; null means none can be used.
    keys: ?*dk.access.KeyStore = null,
    /// What the caller of the request being handled may see. Set for each request by `handleAuthorized`, never
    /// by the request itself.
    scope: dk.access.Scope = .{},
    /// True if the caller presented a valid API key (as opposed to being anonymous).
    keyed: bool = false,
};

/// Limits `q` to what the caller may see and tells it what the `collection:` names mean.
fn limitQuery(arena: Allocator, q: *dk.search.Query, services: Services) error{OutOfMemory}!void {
    q.scope = services.scope.sources;
    q.safe_search = services.safe;
    if (q.trusted_first == null and services.trusted_first) q.trusted_first = true;
    q.trusted_min_percent = services.trusted_min_boost;
    if (q.per_domain == 0) q.per_domain = services.per_domain;
    if (q.prefer_languages.len == 0) q.prefer_languages = try dk.langprefer.parseAcceptLanguage(arena, services.accept_language);
    const defs = try arena.alloc(dk.search.CollectionDef, services.collections.len);
    for (services.collections, defs) |c, *d| d.* = .{ .name = c.name, .sources = c.sources };
    q.collections = defs;
}

/// How much each source counts in the ranking (only those that differ from 100).
fn sourceBoosts(arena: Allocator, services: Services) error{OutOfMemory}![]const dk.search.SourceBoost {
    const store = services.sources orelse return &.{};
    var out: std.ArrayList(dk.search.SourceBoost) = .empty;
    for (store.snapshot()) |src| if (src.enabled and src.boost != 100) try out.append(arena, .{ .source = try arena.dupe(u8, src.name), .percent = src.boost });
    return out.items;
}

/// The collections the caller may search: those with at least one source it may see.
fn collectionChoices(arena: Allocator, services: Services) error{OutOfMemory}![]const html.CollectionChoice {
    var out: std.ArrayList(html.CollectionChoice) = .empty;
    for (services.collections) |c| {
        var any = false;
        for (c.sources) |s| if (services.scope.allows(s)) {
            any = true;
        };
        if (any) try out.append(arena, .{ .name = c.name, .description = c.description });
    }
    return out.items;
}

/// The enabled sources, sorted by kind and then name, for the Source drop-down.
/// `sourceChoices` with the number of documents of each (for the pages that show the list).
fn sourceChoicesFor(arena: Allocator, services: Services, searcher: dk.search.Searcher) error{OutOfMemory}![]const html.SourceChoice {
    const choices = try sourceChoices(arena, services);
    const cache = services.source_stats orelse return choices;
    const stats = try cache.get(arena, searcher);
    const out = try arena.alloc(html.SourceChoice, choices.len);
    for (choices, out) |c, *o| {
        o.* = c;
        for (stats) |s| if (std.mem.eql(u8, s.name, c.name)) {
            o.docs = s.docs;
        };
    }
    return out;
}

/// `/sources`: the sources the caller may search, with what each holds and which collections it is in.
fn sourcesPage(arena: Allocator, searcher: dk.search.Searcher, services: Services) error{OutOfMemory}!Response {
    const choices = try sourceChoicesFor(arena, services, searcher);
    const stats: []const dk.search.SourceStat = if (services.source_stats) |c| try c.get(arena, searcher) else &.{};
    const rows = try arena.alloc(html.SourceRow, choices.len);
    for (choices, rows) |c, *r| {
        var last: ?i64 = null;
        for (stats) |s| if (std.mem.eql(u8, s.name, c.name)) {
            last = s.last_added;
        };
        var colls: std.ArrayList([]const u8) = .empty;
        for (services.collections) |col| {
            if (services.scope.sources != null and !collectionVisible(services, col)) continue;
            for (col.sources) |m| if (std.mem.eql(u8, m, c.name)) {
                try colls.append(arena, col.name);
                break;
            };
        }
        r.* = .{ .name = c.name, .kind = c.kind, .docs = c.docs, .last_added = last, .collections = colls.items };
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    html.writeSourcesPage(&aw.writer, rows, 0) catch return error.OutOfMemory;
    return htmlResponse(arena, .ok, aw.written());
}

/// True if the caller's scope covers every source of `col` (so naming it reveals nothing).
fn collectionVisible(services: Services, col: dk.config.Collection) bool {
    for (col.sources) |m| if (!services.scope.allows(m)) return false;
    return true;
}

/// Results that hold the same text or are the same page, folded into the first (the best), which lists where else
/// they are in `same_in`. Results without an identity are never folded.
fn groupDuplicates(arena: Allocator, hits: []const dk.search.Hit) error{OutOfMemory}![]const dk.search.Hit {
    var out: std.ArrayList(dk.search.Hit) = .empty;
    var first_of: std.StringHashMapUnmanaged(usize) = .empty;
    for (hits) |h| {
        if (h.ident) |ident| {
            if (first_of.get(ident)) |at| {
                var names: std.ArrayList([]const u8) = .empty;
                try names.appendSlice(arena, out.items[at].same_in);
                if (!std.mem.eql(u8, out.items[at].connector, h.connector)) {
                    var have = false;
                    for (names.items) |n| if (std.mem.eql(u8, n, h.connector)) {
                        have = true;
                    };
                    if (!have) try names.append(arena, h.connector);
                }
                out.items[at].same_in = names.items;
                continue;
            }
            try first_of.put(arena, ident, out.items.len);
        }
        try out.append(arena, h);
    }
    return out.items;
}

fn sourceChoices(arena: Allocator, services: Services) error{OutOfMemory}![]const html.SourceChoice {
    const store = services.sources orelse return &.{};
    var out: std.ArrayList(html.SourceChoice) = .empty;
    for (store.snapshot()) |src| if (src.enabled and services.scope.allows(src.name)) try out.append(arena, .{ .name = try arena.dupe(u8, src.name), .kind = try arena.dupe(u8, src.kind) });
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
    return handleAuthorized(arena, searcher, services, method, target, null);
}

/// Like `handleServices`, for a caller that may present an API key (`Authorization: Bearer dkk_...`): what it may
/// see is the scope of its key, or, with no key, the anonymous scope of the server.
pub fn handleAuthorized(arena: Allocator, searcher: dk.search.Searcher, services: Services, method: http.Method, target: []const u8, authorization: ?[]const u8) Response {
    return handleSigned(arena, searcher, services, method, target, authorization, .{});
}

/// What a request says about who sent it beyond the API key: the address it was sent to and a peer's signature
/// (see identity.zig).
pub const Caller = struct {
    /// The request's Cookie header and body (the safe-search unlock form is the one thing here that is posted).
    cookie: ?[]const u8 = null,
    body: []const u8 = "",
    host: ?[]const u8 = null,
    /// The request's Accept-Language header: pages in other languages rank lower.
    accept_language: ?[]const u8 = null,
    signed: ?dk.identity.Signed = null,
    /// A `dk-nonce` without a signature: the caller only wants the answer signed.
    nonce_only: ?[]const u8 = null,
};

/// Like `handleAuthorized`, for a caller that may also have signed its request. A key bound to a node needs that
/// node's signature, and when this node has an identity it signs the answers to callers that sent a nonce.
pub fn handleSigned(arena: Allocator, searcher: dk.search.Searcher, services: Services, method: http.Method, target: []const u8, authorization: ?[]const u8, caller: Caller) Response {
    var resp = handleInner(arena, searcher, services, method, target, authorization, caller) catch |e| switch (e) {
        error.OutOfMemory => plain(.service_unavailable, "temporarily out of memory\n"),
    };
    if (services.identity) |id| {
        const nonce: ?[]const u8 = if (caller.signed) |s| s.nonce else caller.nonce_only;
        if (nonce) |n| if (n.len == 22) {
            const sig = dk.identity.signResponse(arena, id, n, @backingInt(resp.status), resp.body) catch return resp;
            var id_buf: [dk.identity.id_len]u8 = undefined;
            const node = arena.dupe(u8, id.idText(&id_buf)) catch return resp;
            const headers = arena.alloc(Header, resp.headers.len + 2) catch return resp;
            @memcpy(headers[0..resp.headers.len], resp.headers);
            headers[resp.headers.len] = .{ .name = "dk-node", .value = node };
            headers[resp.headers.len + 1] = .{ .name = "dk-sig", .value = sig };
            resp.headers = headers;
        };
    }
    return resp;
}

/// The cookie that holds the key of a browser that signed in at /login.
pub const login_cookie = "dks_key";

/// The value of cookie `name` in a Cookie header.
fn cookieValue(cookie: ?[]const u8, name: []const u8) ?[]const u8 {
    const header = cookie orelse return null;
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len > name.len + 1 and std.mem.startsWith(u8, p, name) and p[name.len] == '=') return p[name.len + 1 ..];
    }
    return null;
}

/// The collections a bearer token's key may see, or an error message (a token that is not a valid key).
fn scopeFor(arena: Allocator, services: Services, authorization: ?[]const u8, caller: Caller, method: http.Method, target: []const u8) error{OutOfMemory}!union(enum) { ok: struct { scope: dk.access.Scope, keyed: bool, limited: ?u32 = null, adult: bool = false, owner: bool = false }, refused: []const u8 } {
    if (authorization) |h| {
        const prefix = "Bearer ";
        if (std.ascii.startsWithIgnoreCase(h, prefix)) {
            const token = std.mem.trim(u8, h[prefix.len..], " \t");
            const store = services.keys orelse return .{ .refused = "this server has no API keys" };
            const found = (try store.lookup(arena, token)) orelse return .{ .refused = "the API key is not valid" };
            // A key bound to a node works only with that node's signature on this very request.
            if (found.node) |bound| {
                const replay = services.replay orelse return .{ .refused = "this key is bound to a node, and this server has no node identity to check signatures with" };
                const signed = caller.signed orelse return .{ .refused = "this key needs a signed request from its node (dk-node, dk-time, dk-nonce, dk-sig)" };
                var pk: [32]u8 = undefined;
                const host = try std.ascii.allocLowerString(arena, caller.host orelse "");
                const now = std.Io.Clock.real.now(replay.io).toSeconds();
                const verdict = dk.identity.verifyRequest(arena, signed, @tagName(method), target, host, now, replay, &pk);
                if (verdict != .ok) return .{ .refused = switch (verdict) {
                    .bad_time => "the request's signature is too old or from the future (check both clocks)",
                    .replayed => "the request's signature was already used",
                    else => "the request's signature is not valid",
                } };
                const want = dk.identity.parseId(bound) orelse return .{ .refused = "this key's node id is not valid" };
                if (!std.mem.eql(u8, &want, &pk)) return .{ .refused = "the request is signed by another node than the one this key is bound to" };
            }
            // A key with a limit: counted here; the seconds to wait if it is over.
            const wait: ?u32 = store.allow(found.id, found.rate);
            return .{ .ok = .{ .scope = try dk.access.resolve(arena, services.collections, found.collections), .keyed = true, .limited = wait, .adult = found.adult } };
        }
    }
    // A browser that signed in as the owner (the password at /login) sees everything, safe search lifted.
    if (authorization == null) if (services.owner) |o| if (o.valid(caller.cookie)) {
        return .{ .ok = .{ .scope = .{}, .keyed = true, .limited = null, .adult = true, .owner = true } };
    };
    // A browser that signed in with a key (the cookie of /login) is that key. A key that is no longer valid, or that is
    // bound to a node (which needs signatures), is not an error here: the browser is simply anonymous again.
    if (cookieValue(caller.cookie, login_cookie)) |token| if (services.keys) |store| {
        if (try store.lookup(arena, token)) |found| if (found.node == null) {
            const wait: ?u32 = store.allow(found.id, found.rate);
            return .{ .ok = .{ .scope = try dk.access.resolve(arena, services.collections, found.collections), .keyed = true, .limited = wait, .adult = found.adult } };
        };
    };
    // Anonymous: every source unless the server limits it to some collections.
    const names = services.anonymous orelse return .{ .ok = .{ .scope = .{}, .keyed = false } };
    return .{ .ok = .{ .scope = try dk.access.resolve(arena, services.collections, names), .keyed = false } };
}

fn handleInner(arena: Allocator, searcher: dk.search.Searcher, services_in: Services, method: http.Method, target: []const u8, authorization: ?[]const u8, caller: Caller) error{OutOfMemory}!Response {
    var services = services_in;
    services.accept_language = caller.accept_language;
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
    if (method != .GET and method != .HEAD and !((r == .unlock_page or r == .lock_action or r == .login_page or r == .logout_action or r == .feedback_action or r == .suggest_action) and method == .POST)) {
        var resp = if (is_api)
            try apiError(arena, .method_not_allowed, "method_not_allowed", "use GET")
        else
            try htmlError(arena, .method_not_allowed, "Method not allowed", "Use GET.");
        resp.headers = headersWith(arena, &.{ .{ .name = "allow", .value = "GET, HEAD" }, no_store });
        return resp;
    }

    // A document server's requests carry their own token (in the address, and Collabora also in an Authorization
    // header, which is not an API key): that token alone decides.
    if (r == .wopi) return wopiPage(arena, searcher, services, t.path, t.params);

    // Who is asking, and what they may see. Pages that show no documents need no key.
    switch (try scopeFor(arena, services_in, authorization, caller, method, target)) {
        .ok => |c| {
            services.scope = c.scope;
            services.keyed = c.keyed;
            services.is_owner = c.owner;
            // Safe search applies unless this caller is adult (a key marked so) or has unlocked this browser.
            services.safe = services.safe_default and !c.adult and !(if (services.unlock) |u| u.unlocked(caller.cookie) else false);
            if (c.limited) |wait| {
                const secs = try std.fmt.allocPrint(arena, "{d}", .{wait});
                var resp = if (is_api) try apiError(arena, .too_many_requests, "rate_limited", "this API key has made too many requests this minute") else try htmlError(arena, .too_many_requests, "Too many requests", "This key has made too many requests this minute. Try again shortly.");
                resp.headers = headersWith(arena, &.{ .{ .name = "retry-after", .value = secs }, no_store });
                return resp;
            }
        },
        .refused => |why| {
            var resp = if (is_api) try apiError(arena, .unauthorized, "invalid_key", why) else try htmlError(arena, .unauthorized, "Not allowed", why);
            resp.headers = headersWith(arena, &.{ .{ .name = "www-authenticate", .value = "Bearer" }, no_store });
            return resp;
        },
    }
    // Copying documents needs a key, however open the server is to anonymous searches.
    if ((r == .api_export or r == .api_peers) and !services.keyed) {
        var resp = try apiError(arena, .unauthorized, "key_required", "exporting documents needs an API key (Authorization: Bearer ...)");
        resp.headers = headersWith(arena, &.{ .{ .name = "www-authenticate", .value = "Bearer" }, no_store });
        return resp;
    }
    if (is_api and r != .api_health and !services.keyed and services.scope.none()) {
        var resp = try apiError(arena, .unauthorized, "key_required", "this server needs an API key (Authorization: Bearer ...)");
        resp.headers = headersWith(arena, &.{ .{ .name = "www-authenticate", .value = "Bearer" }, no_store });
        return resp;
    }

    return switch (r) {
        .home => blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            html.writeHomeForm(&aw.writer, null, .{ .semantic_offered = services.embed != null, .login = loginNote(services), .safe_note = safeNote(services), .answers_offered = services.answers != null and !services.scope.none(), .regex_enabled = regex != null, .sources = try sourceChoicesFor(arena, services, searcher), .collections = try collectionChoices(arena, services), .peer_names = try peerNames(arena, services) }) catch return error.OutOfMemory;
            break :blk htmlResponse(arena, .ok, aw.written());
        },
        .style => .{ .status = .ok, .content_type = css_ct, .body = html.style_css, .headers = headersWith(arena, &.{asset_cache}) },
        .search_script => .{ .status = .ok, .content_type = "text/javascript; charset=utf-8", .body = html.search_js, .headers = headersWith(arena, &.{asset_cache}) },
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
        .api_search => try apiSearch(arena, searcher, regex, services, try sourceChoices(arena, services), try sourceBoosts(arena, services), t.params),
        .api_retrieve => try apiRetrieve(arena, searcher, services, t.params),
        .api_answer => try apiAnswer(arena, searcher, services, t.params),
        .api_suggest => try apiSuggest(arena, searcher, t.params),
        .unlock_page => try unlockPage(arena, services, method, caller),
        .login_page => try loginPage(arena, services, method, caller),
        .logout_action => try logoutAction(arena, services),
        .feedback_action => try feedbackAction(arena, services, method, caller),
        .suggest_action => try suggestAction(arena, services, method, caller),
        .lock_action => try lockAction(arena, services, caller),
        .api_similar => try apiSimilar(arena, searcher, services, t.params),
        .api_export => try apiExport(arena, searcher, services, t.params),
        .api_peers => try apiPeers(arena, services),
        .search_page => try pageSearch(arena, searcher, regex, services, try sourceChoicesFor(arena, services, searcher), try sourceBoosts(arena, services), t.params),
        .sources_page => try sourcesPage(arena, searcher, services),
        .document => try documentPage(arena, searcher, services, t.path, t.params),
        .zim => try zimPage(arena, services, t.path),
        .wopi => unreachable, // answered above
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
    if (params.get("trusted")) |v| if (v.len > 0) {
        if (std.mem.eql(u8, v, "1")) {
            q.trusted_first = true;
        } else if (std.mem.eql(u8, v, "0")) {
            q.trusted_first = false;
        } else return .{ .bad = .{ .name = "trusted", .message = "must be 1 (sources you trust first) or 0" } };
    };
    if (params.get("per_domain")) |v| if (v.len > 0) {
        const n = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = .{ .name = "per_domain", .message = "must be a number from 0 to 50" } };
        if (n > 50) return .{ .bad = .{ .name = "per_domain", .message = "must be a number from 0 to 50" } };
        q.per_domain = n;
    };
    if (params.get("after")) |v| if (v.len > 0) {
        q.after = dk.search.Cursor.parse(v) orelse return .{ .bad = .{ .name = "after", .message = "must be a next_cursor value from a previous page" } };
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
    /// Further excerpts, when `snippets=N` asked for them (empty otherwise).
    more_snippets: []const []const u8,
    /// "onion" or "i2p" for a result on a hidden network (a normal browser cannot open it), else null.
    network: ?[]const u8,
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
    /// The peer node the result came from; null for this node.
    node: ?[]const u8 = null,
    /// Other nodes that have the same page.
    also_on: []const []const u8 = &.{},
    /// The document's identity that does not depend on the node (the same page or the same text on another node
    /// has the same one); null when there is neither an address nor stored text to make it from.
    ident: ?[]const u8 = null,
    /// With `group=1`: other sources that hold the same text, folded into this result.
    same_in: []const []const u8 = &.{},
};
/// What `semantic=1` did: whether the order was changed by meaning, and why not when it was not.
const SemanticNote = struct { used: bool, model: ?[]const u8 = null, compared: u32 = 0, reason: ?[]const u8 = null, index: bool = false, from_vectors: u32 = 0, made_now: u32 = 0 };

const PeerNote = struct { peer: []const u8, status: []const u8, ms: u32, results: u32, http_status: ?u16 = null, cached: bool = false };
const ApiPage = struct { hits: []const ApiHit, has_more: bool, interpreted: ?[]const u8 = null, fuzzy: bool = false, ignored_words: []const []const u8 = &.{}, peers: ?[]const PeerNote = null, semantic: ?SemanticNote = null, external: ?[]const dk.fallback.External = null, external_status: ?[]const ExternalStatus = null, next_cursor: ?[]const u8 = null };
const ExternalStatus = struct { provider: []const u8, status: []const u8 };

const Federated = struct { hits: []const dk.search.Hit, notes: []const PeerNote };

/// The enabled peers' names for the "Also ask peers" box; none when the caller's view is limited.
fn peerNames(arena: Allocator, services: Services) error{OutOfMemory}![]const []const u8 {
    const svc = services.peers orelse return &.{};
    if (svc.enabledCount() == 0 or services.scope.sources != null) return &.{};
    const names = try arena.alloc([]const u8, svc.peers.len);
    var n: usize = 0;
    for (svc.peers) |p| if (p.cfg.enabled) {
        names[n] = p.cfg.name;
        n += 1;
    };
    return names[0..n];
}

const SemanticResult = struct { page: dk.search.Page, note: SemanticNote };

fn wantsSemantic(params: query.Params) bool {
    const v = params.get("semantic") orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
}

/// With `semantic=1`: the lexical results (a wider pool than asked for) re-ordered by meaning. Falls back to the
/// plain lexical page, with the reason, when there is no embedding server, no vectors yet, the query cannot be
/// embedded, or the request pages past the first page.
fn semanticSearch(arena: Allocator, searcher: dk.search.Searcher, services: Services, params: query.Params, q: dk.search.Query) error{ OutOfMemory, Search }!SemanticResult {
    const lexical = struct {
        fn run(a: Allocator, s: dk.search.Searcher, query_: dk.search.Query, why: []const u8) error{ OutOfMemory, Search }!SemanticResult {
            const page = s.search(a, query_) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Search;
            return .{ .page = page, .note = .{ .used = false, .reason = why } };
        }
    }.run;
    const svc = services.embed orelse return lexical(arena, searcher, q, "this server has no embedding model configured");
    const text = params.get("q") orelse "";
    if (text.len == 0 or q.offset != 0) return lexical(arena, searcher, q, "semantic ordering applies to the first page of a search with words");
    // Lazy mode makes the vectors a search lacks, so it needs the store to write to (and creates it) and the texts to embed.
    const lazy = svc.client.settings.lazy and services.content != null;
    var store = (if (lazy) (dk.embed.Store.open(svc.vectors_path) catch null) else dk.embed.Store.openReadOnly(svc.vectors_path)) orelse
        return lexical(arena, searcher, q, if (lazy) "the vector store could not be opened" else "no vectors yet (run `dksearch embed`)");
    defer store.close();
    const model = svc.client.settings.model;
    const key = svc.client.settings.vectorKey();
    const vecs = svc.client.embed(arena, &.{try svc.client.settings.queryText(arena, text)}) catch return lexical(arena, searcher, q, "the embedding server could not be reached or refused the query");
    var wide = q;
    const want: u32 = if (q.limit == 0) 10 else q.limit;
    wide.limit = @min(@max(want * 3, 30), 100);
    const page = searcher.search(arena, wide) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Search;
    const made_now: u32 = if (lazy) @intCast(dk.embed.fillMissing(arena, svc.client, &store, services.content.?, page.hits, svc.client.settings.lazy_max, svc.client.settings.lazy_timeout_ms)) else 0;
    // With the vector index and no filters: the nearest documents of the whole index join the lexical candidates, so
    // a document the words missed can be found. (A filter or a language needs the lexical side to apply it.)
    if (svc.holder) |holder| if (q.filters.len == 0 and q.connector == null and q.language == null and q.content_type == null) {
        if (holder.acquire()) |idx| {
            defer holder.release(idx);
            const near = try idx.search(arena, vecs[0], wide.limit);
            var vector_hits: std.ArrayList(dk.search.Hit) = .empty;
            for (near) |n| {
                var found: ?dk.search.Hit = null;
                for (page.hits) |h| if (std.mem.eql(u8, &h.id, &n.id)) {
                    found = h;
                };
                if (found == null) {
                    const info = searcher.info(arena, n.id) catch null;
                    if (info) |h| if (services.scope.allows(h.connector) and !hitBlocked(services, h)) {
                        found = h;
                    };
                }
                if (found) |h| try vector_hits.append(arena, h);
            }
            const merged = try dk.embed.fuseTwo(arena, page.hits, vector_hits.items);
            var out = page;
            out.hits = merged.hits[0..@min(merged.hits.len, want)];
            out.has_more = page.has_more or merged.hits.len > want;
            return .{ .page = out, .note = .{ .used = true, .model = model, .compared = @intCast(near.len), .index = true, .from_vectors = @intCast(merged.only_second), .made_now = made_now } };
        }
    };
    const fused = try dk.embed.fuse(arena, &store, key, vecs[0], page.hits);
    var out = page;
    out.hits = fused.hits[0..@min(fused.hits.len, want)];
    out.has_more = page.has_more or fused.hits.len > want;
    return .{ .page = out, .note = .{ .used = fused.compared > 0, .model = model, .compared = @intCast(fused.compared), .made_now = made_now, .reason = if (fused.compared == 0) "none of these documents has a vector yet" else null } };
}

fn wantsPeers(params: query.Params) bool {
    const v = params.get("peers") orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "on");
}

fn statusText(s: dk.peers.Status) []const u8 {
    return switch (s) {
        .ok => "answered",
        .timeout => "was too slow",
        .down => "could not be reached",
        .refused => "refused the request (check the key)",
        .bad_answer => "sent an answer that could not be used",
        .untrusted => "answered, but not signed by the node it is pinned to (check its node id)",
        .backoff => "was skipped for a moment after failing",
        .unavailable => "cannot be asked (this build has no network support)",
    };
}

/// With `peers=1`: asks the peers the same question and merges their results with `local`. Null when the caller did
/// not ask, there are no peers, or the caller's view is limited (a restricted caller is never given other nodes'
/// results, and a restricted node's answers are not for sale to peers with a wider key), or this is not the first page.
fn federate(arena: Allocator, services: Services, params: query.Params, q: dk.search.Query, local: []const dk.search.Hit) error{OutOfMemory}!?Federated {
    if (!wantsPeers(params)) return null;
    const svc = services.peers orelse return null;
    if (svc.enabledCount() == 0 or services.scope.sources != null or q.offset != 0) return null;
    const text = params.get("q") orelse return null;
    if (text.len == 0) return null;
    const limit: u32 = @min(if (q.limit == 0) 10 else q.limit, dk.peers.max_hits_per_peer);
    const extra = try std.fmt.allocPrint(arena, "&limit={d}", .{limit});
    const replies = try svc.ask(arena, .search, text, extra);
    const notes = try arena.alloc(PeerNote, replies.len);
    for (replies, notes) |r, *n| n.* = .{ .peer = r.peer, .status = @tagName(r.status), .ms = r.ms, .results = @intCast(r.hits.len), .http_status = if (r.http_status != 0) r.http_status else null, .cached = r.cached };
    return .{ .hits = try withoutBlocked(arena, services, try dk.peers.fuse(arena, local, replies, limit)), .notes = notes };
}

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

const max_export_documents = 200;
const max_export_text_bytes = 4 * 1024 * 1024;
const max_export_page_bytes = 16 * 1024 * 1024;

const ExportDoc = struct {
    id: []const u8,
    ident: ?[]const u8,
    source: []const u8,
    url: ?[]const u8,
    title: ?[]const u8,
    text: []const u8,
    language: ?[]const u8,
    content_type: ?[]const u8,
    modified_at: ?i64,
    published_at: ?i64,
    author: ?[]const u8,
    /// What the source's owner says may be done with the text: unknown, allowed or restricted.
    redistribution: []const u8,
};

/// `GET /api/v1/export?source=NAME[&after=CURSOR][&limit=N]`: the documents of a source whose owner set `share = true`,
/// with their full text, for a peer that replicates them. Needs a key whose scope includes the source.
fn apiExport(arena: Allocator, searcher: dk.search.Searcher, services: Services, params: query.Params) error{OutOfMemory}!Response {
    const name = params.get("source") orelse return apiError(arena, .bad_request, "invalid_parameter", "source: is required");
    const store = services.content orelse return apiError(arena, .service_unavailable, "no_content", "document texts are not available here");
    const sources = services.sources orelse return apiError(arena, .not_found, "not_shared", "no such source, or it is not shared");
    var found: ?dk.config.Source = null;
    for (sources.snapshot()) |s| if (std.mem.eql(u8, s.name, name)) {
        found = s;
    };
    // A source that does not exist, is off, is not shared or is outside the key's scope looks the same.
    const src = found orelse return apiError(arena, .not_found, "not_shared", "no such source, or it is not shared");
    if (!src.enabled or !src.share or !services.scope.allows(src.name)) return apiError(arena, .not_found, "not_shared", "no such source, or it is not shared");
    if (src.rights != null and src.rights.? == .forbidden) return apiError(arena, .not_found, "not_shared", "no such source, or it is not shared");
    const after = std.fmt.parseInt(i64, params.get("after") orelse "0", 10) catch return apiError(arena, .bad_request, "invalid_parameter", "after: must be a cursor from an earlier answer");
    if (after < 0) return apiError(arena, .bad_request, "invalid_parameter", "after: must be a cursor from an earlier answer");
    const limit = std.fmt.parseInt(u32, params.get("limit") orelse "50", 10) catch return apiError(arena, .bad_request, "invalid_parameter", "limit: must be 1 to 200");
    if (limit < 1 or limit > max_export_documents) return apiError(arena, .bad_request, "invalid_parameter", "limit: must be 1 to 200");

    const rows = searcher.exportPage(arena, src.name, after, limit) catch |e| return searchFailure(arena, e, true);
    const redistribution: []const u8 = if (src.rights) |r| @tagName(r) else "unknown";
    var out: std.ArrayList(ExportDoc) = .empty;
    var bytes: usize = 0;
    var last: ?i64 = null;
    var cut = false;
    for (rows) |row| {
        // The cursor moves past documents without retained text or too large: they cannot be sent.
        const text = store.get(arena, row.id) catch {
            last = row.cursor;
            continue;
        };
        if (text.len > max_export_text_bytes) {
            last = row.cursor;
            continue;
        }
        if (bytes + text.len > max_export_page_bytes and out.items.len > 0) {
            cut = true; // this one starts the next page
            break;
        }
        bytes += text.len;
        const stamp = store.stamp(row.id);
        try out.append(arena, .{
            .id = try arena.dupe(u8, &std.fmt.bytesToHex(row.id, .lower)),
            .ident = try dk.peers.identHex(arena, row.url, stamp),
            .source = src.name,
            .url = row.url,
            .title = row.title,
            .text = text,
            .language = row.language,
            .content_type = row.content_type,
            .modified_at = row.modified_at,
            .published_at = row.published_at,
            .author = row.author,
            .redistribution = redistribution,
        });
        last = row.cursor;
    }
    // Another page may follow when this one was full or was cut for size.
    const more = rows.len >= limit or cut;
    var resp = try jsonResponse(arena, .ok, .{ .source = src.name, .documents = out.items, .next = if (more and last != null) try std.fmt.allocPrint(arena, "{d}", .{last.?}) else null });
    resp.headers = headersWith(arena, &.{no_store});
    return resp;
}

const AnswerOutcome = union(enum) {
    ok: struct { text: []const u8, model: []const u8, passages: []const dk.answer.Passage },
    off,
    no_passages,
    busy,
    unavailable,
    bad_question,
};

/// The AI answer to `question`: the best passages (the retrieval of `/api/v1/retrieve`) go to the model of
/// `[answers]` through Ollama. Nothing is asked of the model when no passage was found.
fn answerFor(arena: Allocator, searcher: dk.search.Searcher, services: Services, question: []const u8) error{OutOfMemory}!AnswerOutcome {
    const svc = services.answers orelse return .off;
    const q = std.mem.trim(u8, question, " \t\r\n");
    if (q.len < 3 or q.len > 500) return .bad_question;
    var enc: std.Io.Writer.Allocating = .init(arena);
    query.writeEncoded(&enc.writer, q) catch return error.OutOfMemory;
    const target = try std.fmt.allocPrint(arena, "/api/v1/retrieve?q={s}&k={d}", .{ enc.written(), svc.passages });
    const t = query.parseTarget(arena, target) catch return error.OutOfMemory;
    const resp = try apiRetrieve(arena, searcher, services, t.params);
    if (resp.status != .ok) return .no_passages;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{}) catch return .no_passages;
    const chunks = switch (parsed) {
        .object => |o| switch (o.get("chunks") orelse return .no_passages) {
            .array => |a| a.items,
            else => return .no_passages,
        },
        else => return .no_passages,
    };
    var list: std.ArrayList(dk.answer.Passage) = .empty;
    for (chunks) |c| {
        const o = switch (c) {
            .object => |x| x,
            else => continue,
        };
        const text = switch (o.get("text") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const src: []const u8 = switch (o.get("source") orelse .null) {
            .string => |s| s,
            else => "",
        };
        const title: ?[]const u8 = switch (o.get("title") orelse .null) {
            .string => |s| s,
            else => null,
        };
        const view: []const u8 = switch (o.get("view_url") orelse .null) {
            .string => |s| s,
            else => "",
        };
        try list.append(arena, .{ .title = title, .source = src, .text = text, .view_url = view });
    }
    if (list.items.len == 0) return .no_passages;
    const text = svc.answer(arena, q, list.items) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Busy => .busy,
        error.ModelUnavailable => .unavailable,
    };
    return .{ .ok = .{ .text = text, .model = svc.model, .passages = list.items } };
}

/// `GET /api/v1/answer?q=QUESTION`: a short answer from the local model, made from the best passages, with them.
fn apiAnswer(arena: Allocator, searcher: dk.search.Searcher, services: Services, params: query.Params) error{OutOfMemory}!Response {
    const outcome = try answerFor(arena, searcher, services, params.get("q") orelse "");
    switch (outcome) {
        .off => return apiError(arena, .not_found, "answers_off", "answers are not turned on on this server ([answers])"),
        .bad_question => return apiError(arena, .bad_request, "invalid_parameter", "q: a question of 3 to 500 characters is required"),
        .no_passages => return jsonResponse(arena, .ok, .{ .answer = @as(?[]const u8, null), .reason = "no passage in the documents matched the question", .sources = &[_]u8{} }),
        .busy => {
            var r = try apiError(arena, .too_many_requests, "busy", "this server has reached its limit of answers for this minute");
            r.headers = headersWith(arena, &.{ .{ .name = "retry-after", .value = "10" }, no_store });
            return r;
        },
        .unavailable => return apiError(arena, .service_unavailable, "model_unavailable", "the model could not be reached or gave no answer (is Ollama running with the model of [answers]?)"),
        .ok => |ok| {
            const Src = struct { n: u32, title: ?[]const u8, source: []const u8, view_url: []const u8 };
            const sources = try arena.alloc(Src, ok.passages.len);
            for (ok.passages, sources, 1..) |p, *s, n| s.* = .{ .n = @intCast(n), .title = p.title, .source = p.source, .view_url = p.view_url };
            var r = try jsonResponse(arena, .ok, .{ .answer = ok.text, .model = ok.model, .sources = sources, .notice = "Written by a language model from these passages; it can be wrong." });
            r.headers = headersWith(arena, &.{no_store});
            return r;
        },
    }
}

/// `GET /api/v1/peers`: the peers this node is willing to introduce (`introduce = true`), by name and address only.
/// For a caller with a key; they are suggestions the caller's operator may accept, nothing is added by asking.
/// What the Login button says: nothing when nobody can sign in here (no owner password, no keys).
fn loginNote(services: Services) html.LoginNote {
    const owner_set = if (services.owner) |o| o.hasPassword() else false;
    if (!owner_set and services.keys == null) return .none;
    return if (services.keyed) .signed_in else .offered;
}

/// What the pages say about safe search to this visitor.
fn safeNote(services: Services) html.SafeNote {
    if (!services.safe_default) return .none;
    if (!services.safe) return .unlocked;
    return if (services.unlock) |u| (if (u.hasPin()) .on_unlockable else .on) else .on;
}

/// The unlock page and the unlock itself (a PIN posted from the form): the cookie it sets marks this browser as
/// adult for `unlock_hours`.
fn unlockPage(arena: Allocator, services: Services, method: http.Method, caller: Caller) error{OutOfMemory}!Response {
    const u = services.unlock orelse return htmlError(arena, .not_found, "Not found", "Safe search cannot be unlocked on this server.");
    if (!u.hasPin()) return htmlError(arena, .not_found, "Not found", "Safe search cannot be unlocked on this server (no PIN is set).");
    var message: ?[]const u8 = null;
    if (method == .POST) {
        const form_target = try std.fmt.allocPrint(arena, "/?{s}", .{std.mem.trimEnd(u8, caller.body, "\r\n")});
        const t = query.parseTarget(arena, form_target) catch return htmlError(arena, .bad_request, "Bad request", "The form could not be read.");
        switch (u.tryUnlock(t.params.get("pin") orelse "")) {
            .ok => |token| {
                const cookie = try std.fmt.allocPrint(arena, "{s}={s}; HttpOnly; SameSite=Lax; Path=/; Max-Age={d}", .{ dk.safesearch.cookie_name, token, @as(u64, u.hours) * 3600 });
                return .{ .status = .see_other, .content_type = "text/plain; charset=utf-8", .body = "", .headers = headersWith(arena, &.{ .{ .name = "location", .value = "/" }, .{ .name = "set-cookie", .value = cookie }, no_store }) };
            },
            .wrong => message = "That PIN is not right.",
            .throttled => {
                var r = try htmlError(arena, .too_many_requests, "Too many tries", "Too many wrong PINs; wait a minute and try again.");
                r.headers = headersWith(arena, &.{ .{ .name = "retry-after", .value = "60" }, no_store });
                return r;
            },
            .not_set => return htmlError(arena, .not_found, "Not found", "No PIN is set."),
        }
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    html.writeHead(w, "Unlock safe search - dksearch") catch return error.OutOfMemory;
    w.writeAll("<body class=\"home\"><main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1><h2>Unlock safe search</h2><p class=\"muted\">Safe search hides some sites from this server's results. Enter the PIN to see everything in this browser for a while.</p><form class=\"search\" action=\"/unlock\" method=\"post\" autocomplete=\"off\"><input type=\"password\" name=\"pin\" maxlength=\"64\" aria-label=\"PIN\" placeholder=\"PIN\" autofocus required><button type=\"submit\">Unlock</button></form>") catch return error.OutOfMemory;
    if (message) |m| {
        w.writeAll("<p class=\"error\" role=\"alert\">") catch return error.OutOfMemory;
        html.writeEscaped(w, m) catch return error.OutOfMemory;
        w.writeAll("</p>") catch return error.OutOfMemory;
    }
    w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
    var r = htmlResponse(arena, .ok, aw.written());
    r.headers = headersWith(arena, &.{no_store});
    return r;
}

/// `/feedback`: the owner's mark on a result (POST `q`, `url`, `grade` of 1, -1 or 0), added to `feedback.jsonl`. Only the
/// owner signed in (the password at /login) may: anyone else is refused, and nothing is written.
fn feedbackAction(arena: Allocator, services: Services, method: http.Method, caller: Caller) error{OutOfMemory}!Response {
    if (method != .POST) {
        var resp = plain(.method_not_allowed, "use POST\n");
        resp.headers = headersWith(arena, &.{ .{ .name = "allow", .value = "POST" }, no_store });
        return resp;
    }
    const store = services.feedback orelse return plain(.not_found, "no feedback on this server\n");
    if (!services.is_owner) return plain(.forbidden, "sign in as the owner to mark results\n");
    const form_target = try std.fmt.allocPrint(arena, "/?{s}", .{std.mem.trimEnd(u8, caller.body, "\r\n")});
    const t = query.parseTarget(arena, form_target) catch return plain(.bad_request, "the form could not be read\n");
    const grade = std.fmt.parseInt(i32, t.params.get("grade") orelse "", 10) catch return plain(.bad_request, "grade must be 1, -1 or 0\n");
    const now = std.Io.Clock.real.now(store.io).toSeconds();
    store.record(arena, t.params.get("q") orelse "", t.params.get("url") orelse "", grade, now) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => plain(.bad_request, "the query, the address or the grade is not valid\n"),
        error.TooBig => plain(.insufficient_storage, "the feedback file is full\n"),
        error.Io => plain(.service_unavailable, "the feedback could not be saved\n"),
    };
    var resp = plain(.ok, "ok\n");
    resp.headers = headersWith(arena, &.{no_store});
    return resp;
}

/// `/suggest`: the owner says sites should have been among the results of a search (POST `q`, `url`: one address or several,
/// whitespace between them). Each is added to
/// `suggested-sites.txt` (a crawl source reads it, so the site is indexed on the next run) and kept as a good answer for
/// that search (`feedback.jsonl`), which `dksearch eval` then reports as missing until it is found.
fn suggestAction(arena: Allocator, services: Services, method: http.Method, caller: Caller) error{OutOfMemory}!Response {
    if (method != .POST) {
        var resp = plain(.method_not_allowed, "use POST\n");
        resp.headers = headersWith(arena, &.{ .{ .name = "allow", .value = "POST" }, no_store });
        return resp;
    }
    const store = services.feedback orelse return plain(.not_found, "no feedback on this server\n");
    if (!services.is_owner) return plain(.forbidden, "sign in as the owner to suggest sites\n");
    const form_target = try std.fmt.allocPrint(arena, "/?{s}", .{std.mem.trimEnd(u8, caller.body, "\r\n")});
    const t = query.parseTarget(arena, form_target) catch return plain(.bad_request, "the form could not be read\n");
    // One address, or a list: any whitespace between them (a line each, as a text area sends them). At most 50 at a time.
    const q = t.params.get("q") orelse "";
    const now = std.Io.Clock.real.now(store.io).toSeconds();
    var added: u32 = 0;
    var known: u32 = 0;
    var seen: u32 = 0;
    var refused: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, t.params.get("url") orelse "", " \t\r\n");
    while (it.next()) |address| {
        seen += 1;
        if (seen > 50) return plain(.bad_request, "at most 50 addresses at a time\n");
        const was_new = store.addSuggested(arena, address) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                if (refused.items.len < 200) try refused.print(arena, "{s}{s}", .{ if (refused.items.len > 0) ", " else "", address[0..@min(address.len, 60)] });
                continue;
            },
            error.TooBig => return plain(.insufficient_storage, "the list of suggested sites is full\n"),
            error.Io => return plain(.service_unavailable, "the suggestion could not be saved\n"),
        };
        if (was_new) added += 1 else known += 1;
        if (q.len > 0) store.record(arena, q, address, 1, now) catch {};
    }
    if (added == 0 and known == 0) return plain(.bad_request, if (refused.items.len > 0)
        try std.fmt.allocPrint(arena, "not an address to crawl (it must start with http:// or https:// and have a domain name): {s}\n", .{refused.items})
    else
        "give an address\n");
    var msg: std.ArrayList(u8) = .empty;
    if (added > 0) try msg.print(arena, "added {d}", .{added});
    if (known > 0) try msg.print(arena, "{s}already there {d}", .{ if (msg.items.len > 0) "; " else "", known });
    if (refused.items.len > 0) try msg.print(arena, "; not an address: {s}", .{refused.items});
    if (added > 0) try msg.appendSlice(arena, " (they are crawled when the suggested-sites source next runs)");
    try msg.append(arena, '\n');
    var resp = plain(.ok, msg.items);
    resp.headers = headersWith(arena, &.{no_store});
    return resp;
}

/// `/login`: the owner signs in with the password (`dksearch owner-password`), or a browser with an API key (made with
/// `dksearch api-key add`). Either is kept in a cookie, so that browser sees what it may see: everything for the owner
/// (safe search lifted), the key's collections for a key (and, for a key made with --adult, no safe search). A key
/// bound to a node cannot sign in: it needs signatures a browser cannot make.
fn loginPage(arena: Allocator, services: Services, method: http.Method, caller: Caller) error{OutOfMemory}!Response {
    if (services.keys == null and services.owner == null) return htmlError(arena, .not_found, "Not found", "Signing in is not set up on this server.");
    var message: ?[]const u8 = null;
    if (method == .POST) {
        const form_target = try std.fmt.allocPrint(arena, "/?{s}", .{std.mem.trimEnd(u8, caller.body, "\r\n")});
        const t = query.parseTarget(arena, form_target) catch return htmlError(arena, .bad_request, "Bad request", "The form could not be read.");
        const given = std.mem.trim(u8, t.params.get("credential") orelse (t.params.get("key") orelse ""), " \t");
        const secure: []const u8 = if (services.cookie_secure) "; Secure" else "";
        if (std.mem.startsWith(u8, given, "dkk_")) {
            const found = if (services.keys) |store| (if (given.len <= 200) try store.lookup(arena, given) else null) else null;
            if (found) |f| {
                if (f.node == null) {
                    const cookie = try std.fmt.allocPrint(arena, "{s}={s}; HttpOnly; SameSite=Lax; Path=/; Max-Age=2592000{s}", .{ login_cookie, given, secure });
                    return .{ .status = .see_other, .content_type = "text/plain; charset=utf-8", .body = "", .headers = headersWith(arena, &.{ .{ .name = "location", .value = "/" }, .{ .name = "set-cookie", .value = cookie }, no_store }) };
                }
                message = "That key is bound to a node and cannot be used in a browser.";
            } else message = "That key is not valid.";
        } else if (services.owner) |o| {
            switch (o.tryLogin(given)) {
                .ok => |r| {
                    const cookie = try std.fmt.allocPrint(arena, "{s}={s}; HttpOnly; SameSite=Lax; Path=/; Max-Age={d}{s}", .{ dk.owner.cookie_name, &r.value, r.max_age, secure });
                    return .{ .status = .see_other, .content_type = "text/plain; charset=utf-8", .body = "", .headers = headersWith(arena, &.{ .{ .name = "location", .value = "/" }, .{ .name = "set-cookie", .value = cookie }, no_store }) };
                },
                .wrong => message = "That password is not right.",
                .not_set => message = "There is no owner password on this server. Set one with dksearch owner-password, or on the Access page of the administration interface.",
                .throttled => {
                    var r = try htmlError(arena, .too_many_requests, "Too many tries", "Too many wrong passwords; wait a minute and try again.");
                    r.headers = headersWith(arena, &.{ .{ .name = "retry-after", .value = "60" }, no_store });
                    return r;
                },
            }
        } else message = "That key is not valid.";
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    html.writeHead(w, "Login - dksearch") catch return error.OutOfMemory;
    w.writeAll("<body class=\"home\"><main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1><h2>Login</h2>") catch return error.OutOfMemory;
    const owner_in = if (services.owner) |o| o.valid(caller.cookie) else false;
    if (owner_in or (cookieValue(caller.cookie, login_cookie) != null and services.keyed)) {
        w.writeAll("<p class=\"muted\">You are logged in. <form class=\"inline\" action=\"/logout\" method=\"post\"><button type=\"submit\">Logout</button></form></p>") catch return error.OutOfMemory;
    } else {
        w.writeAll("<p class=\"muted\">Log in to see everything this server holds. Use the owner password, or an API key made by the owner.</p><form class=\"stack\" action=\"/login\" method=\"post\"><label>Password or API key <input type=\"password\" name=\"credential\" autocomplete=\"current-password\" spellcheck=\"false\" maxlength=\"200\" required autofocus></label> <button type=\"submit\">Login</button></form>") catch return error.OutOfMemory;
    }
    if (message) |m| {
        w.writeAll("<p class=\"error\" role=\"alert\">") catch return error.OutOfMemory;
        html.writeEscaped(w, m) catch return error.OutOfMemory;
        w.writeAll("</p>") catch return error.OutOfMemory;
    }
    w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
    var r = htmlResponse(arena, .ok, aw.written());
    r.headers = headersWith(arena, &.{no_store});
    return r;
}

/// Logs the browser out: both cookies are deleted.
fn logoutAction(arena: Allocator, services: Services) error{OutOfMemory}!Response {
    const secure: []const u8 = if (services.cookie_secure) "; Secure" else "";
    const key_gone = try std.fmt.allocPrint(arena, "{s}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0{s}", .{ login_cookie, secure });
    const owner_gone = try std.fmt.allocPrint(arena, "{s}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0{s}", .{ dk.owner.cookie_name, secure });
    return .{ .status = .see_other, .content_type = "text/plain; charset=utf-8", .body = "", .headers = headersWith(arena, &.{ .{ .name = "location", .value = "/" }, .{ .name = "set-cookie", .value = key_gone }, .{ .name = "set-cookie", .value = owner_gone }, no_store }) };
}

/// Ends the unlock of this browser: safe search is on again.
fn lockAction(arena: Allocator, services: Services, caller: Caller) error{OutOfMemory}!Response {
    if (services.unlock) |u| u.lock(caller.cookie);
    const cleared = try std.fmt.allocPrint(arena, "{s}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0", .{dk.safesearch.cookie_name});
    return .{ .status = .see_other, .content_type = "text/plain; charset=utf-8", .body = "", .headers = headersWith(arena, &.{ .{ .name = "location", .value = "/" }, .{ .name = "set-cookie", .value = cleared }, no_store }) };
}

/// Documents like `id`: by vector when the server has a vector index with this document in it, otherwise by the words
/// that set the document apart (docs/decisions/0046). Never the document itself, and only what the caller may see.
fn similarTo(arena: Allocator, searcher: dk.search.Searcher, services: Services, id: dk.document.Id, limit: u32) error{OutOfMemory}![]const dk.search.Hit {
    var out: std.ArrayList(dk.search.Hit) = .empty;
    if (services.embed) |svc| if (svc.holder) |holder| {
        if (dk.embed.Store.openReadOnly(svc.vectors_path)) |opened| {
            var store = opened;
            defer store.close();
            if (store.get(arena, id, svc.client.settings.vectorKey())) |vec| if (holder.acquire()) |idx| {
                defer holder.release(idx);
                for (try idx.search(arena, vec, limit + 1)) |n| {
                    if (std.mem.eql(u8, &n.id, &id)) continue;
                    const h = (searcher.info(arena, n.id) catch null) orelse continue;
                    if (!services.scope.allows(h.connector) or hitBlocked(services, h)) continue;
                    try out.append(arena, h);
                    if (out.items.len >= limit) break;
                }
                if (out.items.len > 0) return out.items;
            };
        }
    };
    const store = services.content orelse return &.{};
    const text = store.get(arena, id) catch return &.{};
    const cands = try dk.similar.candidates(arena, text, 40, 256 * 1024);
    if (cands.len == 0) return &.{};
    const words = try arena.alloc([]const u8, cands.len);
    for (cands, words) |c, *w| w.* = c.word;
    const df = searcher.docFreq(arena, words) catch return &.{};
    if (df.len != cands.len) return &.{};
    var docs: u64 = 0;
    for (searcher.sourceStats(arena) catch &.{}) |s| docs += s.docs;
    const picked = try dk.similar.pick(arena, cands, df, docs, 8);
    if (picked.len == 0) return &.{};
    var q: dk.search.Query = .{ .text = try std.mem.join(arena, " OR ", picked), .limit = limit + 1 };
    try limitQuery(arena, &q, services);
    const page = searcher.search(arena, q) catch return &.{};
    for (page.hits) |h| {
        if (std.mem.eql(u8, &h.id, &id)) continue;
        try out.append(arena, h);
        if (out.items.len >= limit) break;
    }
    return out.items;
}

/// `GET /api/v1/similar?id=HEX[&limit=N]`: documents like the one given.
fn apiSimilar(arena: Allocator, searcher: dk.search.Searcher, services: Services, params: query.Params) error{OutOfMemory}!Response {
    const hex = params.get("id") orelse "";
    var id: dk.document.Id = undefined;
    if (hex.len != 2 * @sizeOf(dk.document.Id)) return apiError(arena, .bad_request, "invalid_parameter", "id must be the 32 hex digits of a document id");
    _ = std.fmt.hexToBytes(&id, hex) catch return apiError(arena, .bad_request, "invalid_parameter", "id must be the 32 hex digits of a document id");
    const limit: u32 = if (params.get("limit")) |v| (std.fmt.parseInt(u32, v, 10) catch return apiError(arena, .bad_request, "invalid_parameter", "limit must be a number")) else 10;
    if (limit == 0 or limit > 50) return apiError(arena, .bad_request, "invalid_parameter", "limit must be 1 to 50");
    const here = (searcher.info(arena, id) catch null) orelse return apiError(arena, .not_found, "not_found", "no such document");
    if (!services.scope.allows(here.connector) or hitBlocked(services, here)) return apiError(arena, .not_found, "not_found", "no such document");
    const found = try similarTo(arena, searcher, services, id, limit);
    const hits = try arena.alloc(ApiHit, found.len);
    for (found, hits) |h, *o| o.* = try apiHit(arena, h);
    return jsonResponse(arena, .ok, .{ .hits = hits });
}

/// Words that can only be in a plain query word: letters and digits (no operators, quotes or wildcards).
fn plainWord(w: []const u8) bool {
    if (w.len == 0 or w.len > 40) return false;
    for (w) |b| if (b < 0x80 and !std.ascii.isAlphanumeric(b)) return false;
    return true;
}

/// `GET /api/v1/suggest?q=...`: the query with its last word completed, most common completions first (at most 8).
fn apiSuggest(arena: Allocator, searcher: dk.search.Searcher, params: query.Params) error{OutOfMemory}!Response {
    const q = std.mem.trim(u8, params.get("q") orelse "", " \t");
    var out: std.ArrayList([]const u8) = .empty;
    if (q.len > 0 and q.len <= 200 and q[q.len - 1] != ' ') {
        const cut = if (std.mem.lastIndexOfScalar(u8, q, ' ')) |i| i + 1 else 0;
        const last = q[cut..];
        if (plainWord(last)) {
            const lower = try std.ascii.allocLowerString(arena, last);
            const found = searcher.words(arena, lower, .prefix, 8) catch &.{};
            for (found) |w| try out.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ q[0..cut], w }));
        }
    }
    var resp = try jsonResponse(arena, .ok, .{ .query = q, .suggestions = out.items });
    resp.headers = headersWith(arena, &.{no_store});
    return resp;
}

/// A spelling of the query that finds something, when the query as typed found nothing: each plain word is replaced by
/// its closest word of the index. Null when no word has a neighbour or the corrected query finds nothing either.
fn didYouMean(arena: Allocator, searcher: dk.search.Searcher, q: dk.search.Query) error{OutOfMemory}!?[]const u8 {
    if (q.text.len == 0 or q.text.len > 200) return null;
    var fixed: std.ArrayList(u8) = .empty;
    var changed = false;
    var it = std.mem.tokenizeScalar(u8, q.text, ' ');
    while (it.next()) |w| {
        if (fixed.items.len > 0) try fixed.append(arena, ' ');
        var use = w;
        // Only a word the index does not have is respelled: a word it has ("linux", "written") is already right, and
        // question words are not worth correcting.
        if (plainWord(w) and w.len >= 3 and !dk.queryparse.isFiller(w)) {
            const lower = try std.ascii.allocLowerString(arena, w);
            const have = searcher.words(arena, lower, .known, 1) catch &.{};
            if (have.len == 0) {
                const near = searcher.words(arena, lower, .spelling, 1) catch &.{};
                if (near.len > 0) {
                    use = near[0];
                    changed = true;
                }
            }
        }
        try fixed.appendSlice(arena, use);
    }
    if (!changed) return null;
    var probe = q;
    probe.text = fixed.items;
    probe.limit = 1;
    probe.offset = 0;
    const page = searcher.search(arena, probe) catch return null;
    if (page.hits.len == 0) return null;
    return fixed.items;
}

fn apiPeers(arena: Allocator, services: Services) error{OutOfMemory}!Response {
    const Entry = struct { name: []const u8, url: []const u8 };
    var list: std.ArrayList(Entry) = .empty;
    var node: []const u8 = "";
    if (services.peers) |svc| {
        node = svc.node;
        for (svc.peers) |p| if (p.cfg.enabled and p.cfg.introduce) try list.append(arena, .{ .name = p.cfg.name, .url = p.cfg.url });
    }
    var resp = try jsonResponse(arena, .ok, .{ .node = node, .peers = list.items });
    resp.headers = headersWith(arena, &.{no_store});
    return resp;
}

fn apiSearch(arena: Allocator, searcher: dk.search.Searcher, regex: ?*dk.regexsearch.Service, services: Services, sources: []const html.SourceChoice, boosts: []const dk.search.SourceBoost, params: query.Params) error{OutOfMemory}!Response {
    const parsed = switch (try parseQuery(arena, params, false)) {
        .ok => |p| p,
        .bad => |b| return apiError(arena, .bad_request, "invalid_parameter", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    var q = parsed.q;
    q.boosts = boosts;
    try limitQuery(arena, &q, services);
    switch (try applySources(arena, &q, sources, services.collections, params, null)) {
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
        for (r.page.hits, hits) |h, *out| out.* = try apiHit(arena, try withIdent(arena, services, h));
        return jsonResponse(arena, .ok, .{ .hits = hits, .has_more = r.page.has_more, .interpreted = r.page.interpreted, .fuzzy = r.page.fuzzy, .regex = .{ .examined = r.examined, .truncated = r.truncated } });
    }
    // `fallback=1`: web results from the providers of `[fallback]` (this server sends the words to them).
    var ext_results: ?[]const dk.fallback.External = null;
    var ext_status: ?[]const ExternalStatus = null;
    if (if (params.get("fallback")) |v| std.mem.eql(u8, v, "1") else false) {
        if (services.fallback) |fb| if (fb.service) |svc| if (!services.scope.none() and q.offset == 0 and q.text.len > 0) {
            const replies = try svc.ask(arena, params.get("q") orelse "");
            var all: std.ArrayList(dk.fallback.External) = .empty;
            const st = try arena.alloc(ExternalStatus, replies.len);
            for (replies, st) |r, *s| {
                s.* = .{ .provider = r.provider, .status = @tagName(r.status) };
                for (r.results) |ext| if (!(if (services.lists) |l| l.hidesUrl(ext.url, services.safe) else false)) try all.append(arena, ext);
            }
            ext_results = all.items;
            ext_status = st;
        };
    }
    var semantic: ?SemanticNote = null;
    const page = blk: {
        if (wantsSemantic(params)) {
            const r = semanticSearch(arena, searcher, services, params, q) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Search => return searchFailure(arena, error.Io, true),
            };
            semantic = r.note;
            break :blk r.page;
        }
        break :blk searcher.search(arena, q) catch |e| return searchFailure(arena, e, true);
    };

    const local = try arena.alloc(dk.search.Hit, page.hits.len);
    for (page.hits, local) |h, *dst| dst.* = try withIdent(arena, services, h);
    const fed = try federate(arena, services, params, q, local);
    const grouped = if (fed == null and (if (params.get("group")) |g| std.mem.eql(u8, g, "1") else false)) try groupDuplicates(arena, local) else local;
    const shown = try withMoreSnippets(arena, services, try withFirstSnippets(arena, services, if (fed) |f| f.hits else grouped, parsed_typed_for_terms(params)), parsed_typed_for_terms(params), snippetCount(params));
    const hits = try arena.alloc(ApiHit, shown.len);
    for (shown, hits) |h, *out| out.* = try apiHit(arena, h);
    // The cursor of the next page: after the last result of this one, for a relevance-ordered search of words.
    var cursor_buf: [48]u8 = undefined;
    const next_cursor: ?[]const u8 = if (page.has_more and page.hits.len > 0 and q.sort == .relevance and q.text.len > 0 and !(q.trusted_first orelse false) and q.offset + page.hits.len < dk.search.max_cursor_window)
        try arena.dupe(u8, (dk.search.Cursor{ .score = page.hits[page.hits.len - 1].score, .id = page.hits[page.hits.len - 1].id }).format(&cursor_buf))
    else
        null;
    return jsonResponse(arena, .ok, ApiPage{ .next_cursor = next_cursor, .hits = hits, .has_more = page.has_more, .interpreted = page.interpreted, .ignored_words = page.ignored, .fuzzy = page.fuzzy, .peers = if (fed) |f| f.notes else null, .semantic = semantic, .external = ext_results, .external_status = ext_status });
}

/// Whether a result belongs to a domain that must not be shown (the blocklist; with safe search, its ban lists too).
fn hitBlocked(services: Services, h: dk.search.Hit) bool {
    const l = services.lists orelse return false;
    if (h.domain) |d| if (l.hides(d, services.safe)) return true;
    return l.hidesUrl(h.url, services.safe);
}

fn withoutBlocked(arena: Allocator, services: Services, hits: []const dk.search.Hit) error{OutOfMemory}![]const dk.search.Hit {
    const l = services.lists orelse return hits;
    if (l.blocked.isEmpty() and !(services.safe and !l.safe.isEmpty())) return hits;
    var out: std.ArrayList(dk.search.Hit) = .empty;
    for (hits) |h| if (!hitBlocked(services, h)) try out.append(arena, h);
    return out.items;
}

/// How many excerpts per result were asked for (`snippets=N`): 1 (the usual one) to 5.
fn snippetCount(params: query.Params) u8 {
    const v = params.get("snippets") orelse return 1;
    const n = std.fmt.parseInt(u8, v, 10) catch return 1;
    return @min(@max(n, 1), 5);
}

fn parsed_typed_for_terms(params: query.Params) []const u8 {
    return params.get("q") orelse "";
}

/// The hits of this node with up to `n - 1` further excerpts from their stored text (nothing when `n` is 1, there is
/// no content store, or the document is not stored).
/// The excerpt of a result that came without one: a search of only very common words does not ask SQLite for it (that
/// is slow for words that occur thousands of times in a document), so it is made here from the stored text.
fn withFirstSnippets(arena: Allocator, services: Services, hits: []const dk.search.Hit, typed: []const u8) error{OutOfMemory}![]const dk.search.Hit {
    var missing = false;
    for (hits) |h| if (h.snippet == null and h.node == null) {
        missing = true;
    };
    if (!missing) return hits;
    const store = services.content orelse return hits;
    const terms = try dk.snippets.queryTerms(arena, typed);
    if (terms.len == 0) return hits;
    const out = try arena.alloc(dk.search.Hit, hits.len);
    for (hits, out) |h, *dst| {
        dst.* = h;
        if (h.snippet != null or h.node != null) continue;
        const text = store.get(arena, h.id) catch continue;
        const got = try dk.snippets.more(arena, text, terms, null, 1);
        if (got.len > 0) dst.snippet = got[0];
    }
    return out;
}

fn withMoreSnippets(arena: Allocator, services: Services, hits: []const dk.search.Hit, typed: []const u8, n: u8) error{OutOfMemory}![]const dk.search.Hit {
    if (n <= 1) return hits;
    const store = services.content orelse return hits;
    const terms = try dk.snippets.queryTerms(arena, typed);
    if (terms.len == 0) return hits;
    const out = try arena.alloc(dk.search.Hit, hits.len);
    for (hits, out) |h, *dst| {
        dst.* = h;
        if (h.node != null) continue;
        const text = store.get(arena, h.id) catch continue;
        dst.more_snippets = try dk.snippets.more(arena, text, terms, h.snippet, n - 1);
    }
    return out;
}

/// `h` with its node-independent identity filled in (from its address, or the hash of its stored text).
fn withIdent(arena: Allocator, services: Services, h_in: dk.search.Hit) error{OutOfMemory}!dk.search.Hit {
    var h = h_in;
    if (h.ident != null) return h;
    const stamp: ?[32]u8 = if (services.content) |store| store.stamp(h.id) else null;
    h.ident = try dk.peers.identHex(arena, h.url, stamp);
    return h;
}

fn apiHit(arena: Allocator, h: dk.search.Hit) error{OutOfMemory}!ApiHit {
    return .{
        .id = try arena.dupe(u8, &std.fmt.bytesToHex(h.id, .lower)),
        .connector = h.connector,
        .url = h.url,
        .title = h.title,
        .snippet = h.snippet,
        .more_snippets = h.more_snippets,
        .network = dk.domainlist.hiddenNetworkOf(h.url),
        .score = h.score,
        .view_url = h.remote_view orelse try std.fmt.allocPrint(arena, "/doc/{s}", .{std.fmt.bytesToHex(h.id, .lower)}),
        .node = h.node,
        .also_on = h.also_on,
        .ident = h.ident,
        .same_in = h.same_in,
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
    if (!validSourceName(name) or !services.scope.allows(name)) return htmlError(arena, .not_found, "Not found", "No such article.");
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
    var want_open = false;
    var want_relay = false;
    var want_thumb = false;
    var want_image: ?usize = null;
    if (std.mem.endsWith(u8, hex, "/open")) {
        want_open = true;
        hex = hex[0 .. hex.len - "/open".len];
    } else if (std.mem.endsWith(u8, hex, "/file")) {
        want_file = true;
        hex = hex[0 .. hex.len - "/file".len];
    } else if (std.mem.endsWith(u8, hex, "/thumb")) {
        want_thumb = true;
        hex = hex[0 .. hex.len - "/thumb".len];
    } else if (std.mem.endsWith(u8, hex, "/image")) {
        want_relay = true;
        hex = hex[0 .. hex.len - "/image".len];
    } else if (std.mem.indexOf(u8, hex, "/image/")) |at| {
        want_image = std.fmt.parseInt(usize, hex[at + "/image/".len ..], 10) catch return htmlError(arena, .not_found, "Not found", "No such picture.");
        hex = hex[0..at];
    }
    var id: dk.document.Id = undefined;
    if (hex.len != 2 * @sizeOf(dk.document.Id)) return htmlError(arena, .not_found, "Not found", "No such document.");
    _ = std.fmt.hexToBytes(&id, hex) catch return htmlError(arena, .not_found, "Not found", "No such document.");
    const info = searcher.info(arena, id) catch |e| return searchFailure(arena, e, false);
    const hit = info orelse return htmlError(arena, .not_found, "Not found", "No such document.");
    // A document outside the caller's scope, or of a blocked domain, is as good as absent.
    if (!services.scope.allows(hit.connector) or hitBlocked(services, hit)) return htmlError(arena, .not_found, "Not found", "No such document.");
    if (want_relay) return relayedImage(arena, services, id, hit);
    if (want_thumb) return thumbnail(arena, services, id, hit);
    const can_open = if (services.originals) |o| (if (hit.url) |u| o.serves(hit.connector, u) else false) else false;
    if (want_file) return if (can_open) originalFile(arena, services.originals.?, hit) else htmlError(arena, .not_found, "Not found", "The original file of this document is not available here.");
    if (want_image) |n| return if (can_open) documentImage(arena, services.originals.?, hit, n) else htmlError(arena, .not_found, "Not found", "The pictures of this document are not available here.");
    // The document server shows office files read-only; the caller was checked above.
    const doc_format: ?dk.docserver.Format = if (services.docserver != null and can_open) (if (hit.url) |u| dk.docserver.formatOf(u) else null) else null;
    if (want_open) return if (doc_format) |f| openInDocServer(arena, services.docserver.?, hex, hit, f) else htmlError(arena, .not_found, "Not found", "This document cannot be opened in a document server here.");
    // A ZIM article can be read from the file itself.
    var open_links: std.ArrayList(html.OpenLink) = .empty;
    if (can_open) {
        try open_links.append(arena, .{ .href = try std.fmt.allocPrint(arena, "/doc/{s}/file", .{hex}), .label = "Open the original file" });
        if (doc_format != null) try open_links.append(arena, .{ .href = try std.fmt.allocPrint(arena, "/doc/{s}/open", .{hex}), .label = "Open in the document viewer" });
    } else if (services.zims) |z| if (hit.url) |u| if (zimAddress(u)) |za| if (z.has(za.name)) {
        try open_links.append(arena, .{ .href = try std.fmt.allocPrint(arena, "/zim/{s}/{s}", .{ za.name, za.path }), .label = "Read the article" });
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
        // Pictures that the converter embedded in the file are served from the original (`/doc/ID/image/N`).
        const image_base: ?[]const u8 = if (can_open) try std.fmt.allocPrint(arena, "/doc/{s}/image/", .{hex}) else null;
        rendered = dk.render.markdown(arena, t, image_base) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLarge => null, // too big to format: the plain text is shown
        };
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    const similar = try similarTo(arena, searcher, services, id, 5);
    html.writeDocument(&aw.writer, hit, text, cut, open_links.items, rendered, is_markdown, similar) catch return error.OutOfMemory;
    return htmlResponse(arena, .ok, aw.written());
}

/// Sends the browser to the document server to view `hit`'s file: Collabora by redirect, OnlyOffice by a small page
/// that starts its viewer. The token lets the server fetch just this file for an hour.
fn openInDocServer(arena: Allocator, svc: *const dk.docserver.Service, hex: []const u8, hit: dk.search.Hit, format: dk.docserver.Format) error{OutOfMemory}!Response {
    var id: dk.document.Id = undefined;
    _ = std.fmt.hexToBytes(&id, hex) catch return htmlError(arena, .not_found, "Not found", "No such document.");
    var buf: [dk.docserver.token_len]u8 = undefined;
    const token = try arena.dupe(u8, dk.docserver.makeToken(&svc.secret, id, svc.now() + dk.docserver.token_ttl_seconds, &buf));
    switch (svc.settings.kind) {
        .collabora => {
            const to = try dk.docserver.collaboraUrl(arena, svc.settings, hex, token);
            return .{ .status = .see_other, .content_type = "text/plain; charset=utf-8", .body = "", .headers = headersWith(arena, &.{ .{ .name = "location", .value = to }, no_store }) };
        },
        .onlyoffice => {
            const name = baseName(hit.url orelse "");
            const version = try std.fmt.allocPrint(arena, "{d}", .{hit.modified_at orelse 0});
            const cfg = try dk.docserver.onlyofficeConfig(arena, svc.settings, hex, token, name, format, version);
            const page = try dk.docserver.onlyofficePage(arena, svc.settings, cfg, if (hit.title) |t| t else name);
            var r = htmlResponse(arena, .ok, page.html);
            // Its own policy instead of the usual one (two policies would both apply, and the stricter wins).
            const headers = try arena.alloc(Header, 4);
            headers[0] = .{ .name = "content-security-policy", .value = page.csp };
            headers[1] = no_store;
            headers[2] = .{ .name = "referrer-policy", .value = "no-referrer" };
            headers[3] = .{ .name = "x-content-type-options", .value = "nosniff" };
            r.headers = headers;
            return r;
        },
    }
}

fn baseName(url: []const u8) []const u8 {
    const no_query = url[0 .. std.mem.indexOfAny(u8, url, "?#") orelse url.len];
    return no_query[(std.mem.lastIndexOfScalar(u8, no_query, '/') orelse return no_query) + 1 ..];
}

/// What a document server asks of dksearch (WOPI): `/wopi/files/ID` (the file's details) and
/// `/wopi/files/ID/contents` (the file). Only with a token made for that document and still valid; the token is
/// the whole authorization, since the server has no key.
fn wopiPage(arena: Allocator, searcher: dk.search.Searcher, services: Services, path: []const u8, params: query.Params) error{OutOfMemory}!Response {
    const svc = services.docserver orelse return htmlError(arena, .not_found, "Not found", "That page does not exist.");
    var hex = path["/wopi/files/".len..];
    var contents = false;
    if (std.mem.endsWith(u8, hex, "/contents")) {
        contents = true;
        hex = hex[0 .. hex.len - "/contents".len];
    }
    const refused = struct {
        fn at(a: Allocator) error{OutOfMemory}!Response {
            return apiError(a, .unauthorized, "invalid_token", "the access token is missing, expired or for another document");
        }
    }.at;
    var id: dk.document.Id = undefined;
    if (hex.len != 2 * @sizeOf(dk.document.Id)) return refused(arena);
    _ = std.fmt.hexToBytes(&id, hex) catch return refused(arena);
    const token = params.get("access_token") orelse return refused(arena);
    const for_id = dk.docserver.checkToken(&svc.secret, token, svc.now()) orelse return refused(arena);
    if (!std.mem.eql(u8, &for_id, &id)) return refused(arena);
    const hit = (searcher.info(arena, id) catch |e| return searchFailure(arena, e, true)) orelse return apiError(arena, .not_found, "not_found", "no such document");
    const origin = services.originals orelse return apiError(arena, .not_found, "not_found", "the original file is not available");
    const url = hit.url orelse return apiError(arena, .not_found, "not_found", "the original file is not available");
    if (!origin.serves(hit.connector, url) or dk.docserver.formatOf(url) == null) return apiError(arena, .not_found, "not_found", "the original file is not available");
    const served = origin.read(arena, hit.connector, url) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotServed, error.NotFound, error.Forbidden => apiError(arena, .not_found, "not_found", "the original file is not available"),
        error.TooLarge => apiError(arena, .payload_too_large, "too_large", "the file is too large"),
        error.Io => apiError(arena, .internal_server_error, "internal_error", "the file could not be read"),
    };
    if (contents) {
        return .{ .status = .ok, .content_type = "application/octet-stream", .body = served.bytes, .headers = headersWith(arena, &.{ .{ .name = "x-content-type-options", .value = "nosniff" }, .{ .name = "cache-control", .value = "private, no-store" }, .{ .name = "x-wopi-itemversion", .value = try std.fmt.allocPrint(arena, "{d}", .{hit.modified_at orelse 0}) } }) };
    }
    const info: dk.docserver.CheckFileInfo = .{ .BaseFileName = served.filename, .Size = served.bytes.len, .Version = try std.fmt.allocPrint(arena, "{d}", .{hit.modified_at orelse 0}) };
    var r = try jsonResponse(arena, .ok, info);
    r.headers = headersWith(arena, &.{no_store});
    return r;
}

/// The original file of a document, for the browser to show or download.
/// `/doc/ID/thumb`: a small JPEG of the picture, from the cache when it is there, else made now from the original (a
/// file this server may serve, or a web picture fetched through the relay) and kept. Anything that cannot be shrunk (a
/// picture format that is not read here, too large, too many at once) sends the browser to the original instead, so a
/// picture is never missing from the gallery. The thumbnail is cached by the browser too.
fn thumbnail(arena: Allocator, services: Services, id: dk.document.Id, hit: dk.search.Hit) error{OutOfMemory}!Response {
    const cache = services.thumbs orelse return htmlError(arena, .not_found, "Not found", "Thumbnails are not turned on here.");
    if (!(if (hit.kind) |k| std.mem.eql(u8, k, "image") else false)) return htmlError(arena, .not_found, "Not found", "No picture here.");
    const hex = std.fmt.bytesToHex(id, .lower);
    const is_file = if (hit.url) |u| std.mem.startsWith(u8, u, "file://") else false;
    const original_route = try std.fmt.allocPrint(arena, "/doc/{s}/{s}", .{ &hex, if (is_file) "file" else "image" });
    if (cache.get(arena, id)) |bytes| return thumbnailResponse(arena, bytes);
    // The original.
    const original: []const u8 = blk: {
        if (is_file) {
            const o = services.originals orelse return htmlError(arena, .not_found, "Not found", "No picture here.");
            if (!o.serves(hit.connector, hit.url.?)) return htmlError(arena, .not_found, "Not found", "No picture here.");
            const served = o.read(arena, hit.connector, hit.url.?) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => htmlError(arena, .not_found, "Not found", "The picture is not available."),
            };
            break :blk served.bytes;
        }
        const relay = services.relay orelse return htmlError(arena, .not_found, "Not found", "No picture here.");
        const store = services.content orelse return htmlError(arena, .not_found, "Not found", "No picture here.");
        const page_url = hit.url orelse return htmlError(arena, .not_found, "Not found", "No picture here.");
        if (!std.mem.startsWith(u8, page_url, "http")) return htmlError(arena, .not_found, "Not found", "No picture here.");
        const text = store.get(arena, id) catch return htmlError(arena, .not_found, "Not found", "No picture here.");
        const prefix = "Image: ";
        if (!std.mem.startsWith(u8, text, prefix)) return htmlError(arena, .not_found, "Not found", "No picture here.");
        const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const img = relay.fetchImage(arena, std.mem.trim(u8, text[prefix.len..line_end], " \r")) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return htmlError(arena, .not_found, "Not found", "The picture could not be fetched."),
        };
        break :blk img.bytes;
    };
    const small = cache.make(arena, original) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // Not shrinkable here (or too busy): let the browser take the original.
        error.NotAPicture, error.TooLarge, error.Unsupported, error.Busy => return .{ .status = .see_other, .content_type = "text/plain; charset=utf-8", .body = "", .headers = headersWith(arena, &.{ .{ .name = "location", .value = original_route }, no_store }) },
    };
    cache.put(arena, id, small);
    return thumbnailResponse(arena, small);
}

fn thumbnailResponse(arena: Allocator, bytes: []const u8) error{OutOfMemory}!Response {
    const headers = try arena.alloc(Header, 4);
    headers[0] = .{ .name = "x-content-type-options", .value = "nosniff" };
    headers[1] = .{ .name = "content-security-policy", .value = "default-src 'none'; sandbox" };
    headers[2] = .{ .name = "cross-origin-resource-policy", .value = "same-origin" };
    headers[3] = .{ .name = "cache-control", .value = "private, max-age=86400" };
    return .{ .status = .ok, .content_type = "image/jpeg", .body = bytes, .headers = headers };
}

/// `/doc/ID/image`: the picture of a web picture record, fetched now from where it is and passed on, nothing kept. Only
/// for documents of kind image that the crawler recorded (the address comes from the stored text, never from the request).
fn relayedImage(arena: Allocator, services: Services, id: dk.document.Id, hit: dk.search.Hit) error{OutOfMemory}!Response {
    const gone = try htmlError(arena, .not_found, "Not found", "No picture here.");
    const relay = services.relay orelse return gone;
    const store = services.content orelse return gone;
    if (!(if (hit.kind) |k| std.mem.eql(u8, k, "image") else false)) return gone;
    const page_url = hit.url orelse return gone;
    if (!std.mem.startsWith(u8, page_url, "http")) return gone;
    const text = store.get(arena, id) catch return gone;
    const prefix = "Image: ";
    if (!std.mem.startsWith(u8, text, prefix)) return gone;
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const address = std.mem.trim(u8, text[prefix.len..line_end], " \r");
    const img = relay.fetchImage(arena, address) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Busy => {
            var r = try htmlError(arena, .service_unavailable, "Busy", "Too many pictures are being fetched; try again in a moment.");
            r.headers = headersWith(arena, &.{ .{ .name = "retry-after", .value = "2" }, no_store });
            return r;
        },
        else => return gone,
    };
    const headers = try arena.alloc(Header, 5);
    headers[0] = .{ .name = "x-content-type-options", .value = "nosniff" };
    headers[1] = .{ .name = "content-security-policy", .value = "default-src 'none'; sandbox" };
    headers[2] = .{ .name = "cross-origin-resource-policy", .value = "same-origin" };
    headers[3] = .{ .name = "referrer-policy", .value = "no-referrer" };
    // The browser may keep it for a while (this server keeps nothing).
    headers[4] = .{ .name = "cache-control", .value = "private, max-age=3600" };
    return .{ .status = .ok, .content_type = img.content_type, .body = img.bytes, .headers = headers };
}

fn originalFile(arena: Allocator, svc: *const dk.originals.Service, hit: dk.search.Hit) error{OutOfMemory}!Response {
    const served = svc.read(arena, hit.connector, hit.url.?) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotServed, error.NotFound, error.Forbidden => htmlError(arena, .not_found, "Not found", "The original file is not available (it may have been moved or removed)."),
        error.TooLarge => htmlError(arena, .payload_too_large, "Too large", "That file is too large to be served here."),
        error.Io => htmlError(arena, .internal_server_error, "Error", "The file could not be read."),
    };
    // No script policy beyond "nothing may frame this": the browser's own PDF viewer needs room, and
    // what is served inline (PDF, images, plain text) cannot run script on this origin.
    const headers = try arena.alloc(Header, 6);
    headers[0] = .{ .name = "x-content-type-options", .value = "nosniff" };
    headers[1] = .{ .name = "referrer-policy", .value = "no-referrer" };
    headers[2] = .{ .name = "content-security-policy", .value = "frame-ancestors 'none'" };
    headers[3] = .{ .name = "cross-origin-resource-policy", .value = "same-origin" };
    headers[4] = .{ .name = "content-disposition", .value = try dk.originals.dispositionFor(arena, served.inline_view, served.filename) };
    // A picture in a gallery is asked for again whenever the page is shown: let the browser keep it for a while.
    headers[5] = .{ .name = "cache-control", .value = if (std.mem.startsWith(u8, served.content_type, "image/")) "private, max-age=600" else "no-store" };
    return .{ .status = .ok, .content_type = served.content_type, .body = served.bytes, .headers = headers };
}

/// One picture embedded in a Markdown original (`![](data:image/png;base64,...)`), numbered in order of appearance.
fn documentImage(arena: Allocator, svc: *const dk.originals.Service, hit: dk.search.Hit, n: usize) error{OutOfMemory}!Response {
    const served = svc.read(arena, hit.connector, hit.url.?) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotServed, error.NotFound, error.Forbidden => htmlError(arena, .not_found, "Not found", "The original file is not available (it may have been moved or removed)."),
        error.TooLarge => htmlError(arena, .payload_too_large, "Too large", "That file is too large to be served here."),
        error.Io => htmlError(arena, .internal_server_error, "Error", "The file could not be read."),
    };
    const img = (try dk.retrieve.nthInlineImage(arena, served.bytes, n)) orelse return htmlError(arena, .not_found, "Not found", "No such picture in this document.");
    const headers = try arena.alloc(Header, 4);
    headers[0] = .{ .name = "x-content-type-options", .value = "nosniff" };
    headers[1] = .{ .name = "content-security-policy", .value = "default-src 'none'; sandbox" };
    headers[2] = .{ .name = "cross-origin-resource-policy", .value = "same-origin" };
    headers[3] = .{ .name = "cache-control", .value = "private, max-age=600" };
    return .{ .status = .ok, .content_type = img.mime, .body = img.bytes, .headers = headers };
}

// ------------------------------------------------------------ HTML pages

/// Turns the ticked sources (`source`, repeatable) and the single `connector` into source conditions on `q`: each is
/// a source name or `kind:NAME` for every source of a kind, and they are alternatives. Returns what was picked.
fn applySources(arena: Allocator, q: *dk.search.Query, sources: []const html.SourceChoice, colls: []const dk.config.Collection, params: query.Params, default: ?[]const u8) error{OutOfMemory}!union(enum) { ok: []const []const u8, bad: ParamError } {
    var picked: std.ArrayList([]const u8) = .empty;
    for (try params.all(arena, "source")) |v| {
        if (!validFilter(v)) return .{ .bad = .{ .name = "source", .message = "invalid value" } };
        if (picked.items.len >= 64) return .{ .bad = .{ .name = "source", .message = "at most 64 sources" } };
        try picked.append(arena, v);
    }
    // Nothing picked: the server's default collection, when it has one.
    if (picked.items.len == 0 and q.connector == null) if (default) |name| try picked.append(arena, try std.fmt.allocPrint(arena, "collection:{s}", .{name}));
    // The single `connector` is an exact match unless it names a kind or is combined with ticked sources.
    const connector_is_kind = if (q.connector) |c| std.mem.startsWith(u8, c, "kind:") else false;
    const fold = picked.items.len > 0 or connector_is_kind;
    if (q.connector) |c| try picked.append(arena, c);
    if (fold) {
        var list: std.ArrayList(dk.search.Filter) = .empty;
        for (picked.items) |c| {
            if (std.mem.startsWith(u8, c, "kind:")) {
                for (sources) |src| if (std.mem.eql(u8, src.kind, c["kind:".len..])) try list.append(arena, .{ .field = .source, .text = src.name });
            } else if (std.mem.startsWith(u8, c, "collection:")) {
                for (colls) |col| if (std.mem.eql(u8, col.name, c["collection:".len..])) {
                    for (col.sources) |m| try list.append(arena, .{ .field = .source, .text = m });
                };
            } else try list.append(arena, .{ .field = .source, .text = c });
        }
        // Only kinds or collections with no sources: match nothing rather than everything.
        if (list.items.len == 0) try list.append(arena, .{ .field = .source, .text = "(no source of that kind)" });
        q.filters = list.items;
        q.connector = null;
    }
    return .{ .ok = picked.items };
}

// ------------------------------------------------------------ retrieval API

const max_retrieve_text_bytes = 8 * 1024 * 1024; // of one document read for chunking
const max_retrieve_total_bytes = 64 * 1024 * 1024; // of all candidates together
const max_chunk_candidates = 60; // passages taken from the chunk index

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
    /// Page: from the text's own page breaks (`page_source` "text"), or, for text without them, placed by matching
    /// against the PDF of the same work (`page_source` "pdf"); null when neither is possible.
    page: ?u32,
    page_source: ?[]const u8,
    /// Entry names in the passage (bold terms that open paragraphs, as in encyclopedias converted to Markdown).
    entries: []const []const u8,
    score: f64,
    text: []const u8,
    before: []const []const u8,
    after: []const []const u8,
    /// Pictures that sit in this passage of the original file: `n` and, when the original can be served, the address.
    images: []const RetrievedImage,
    /// The peer node the passage came from; null for this node. Its `view_url` is then an address on that peer.
    node: ?[]const u8 = null,
    /// Other nodes that returned the same passage.
    also_on: []const []const u8 = &.{},
    /// The document's identity that does not depend on the node (see `ApiHit.ident`).
    ident: ?[]const u8 = null,
};

/// With `peers=1`: asks the peers for their best passages and merges them with `local` by reciprocal-rank fusion
/// (BM25 scores of different indexes are not comparable). The same passage of the same page on several nodes counts
/// once. Pictures of a peer's passages are not carried over (their addresses need that peer's key). Null when not
/// asked for or not allowed (see `federate`).
fn federateRetrieval(arena: Allocator, services: Services, params: query.Params, text: []const u8, k: u32, context: u32, local: []const RetrievedChunk) error{OutOfMemory}!?struct { chunks: []const RetrievedChunk, notes: []const PeerNote } {
    if (!wantsPeers(params)) return null;
    const svc = services.peers orelse return null;
    if (svc.enabledCount() == 0 or services.scope.sources != null) return null;
    var extra: std.Io.Writer.Allocating = .init(arena);
    extra.writer.print("&k={d}&context={d}", .{ k, context }) catch return error.OutOfMemory;
    for ([_][]const u8{ "chunk_chars", "overlap" }) |name| if (params.get(name)) |v| if (v.len > 0 and v.len < 8 and std.mem.indexOfNone(u8, v, "0123456789") == null) extra.writer.print("&{s}={s}", .{ name, v }) catch return error.OutOfMemory;
    const replies = try svc.ask(arena, .retrieve, text, extra.written());
    const notes = try arena.alloc(PeerNote, replies.len);
    for (replies, notes) |r, *n| n.* = .{ .peer = r.peer, .status = @tagName(r.status), .ms = r.ms, .results = @intCast(r.chunks.len), .http_status = if (r.http_status != 0) r.http_status else null, .cached = r.cached };

    const Entry = struct { chunk: RetrievedChunk, score: f64, order: usize, also: std.ArrayList([]const u8) = .empty };
    var entries: std.ArrayList(Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    for (local, 0..) |c, rank| {
        const key = try retrievalKey(arena, c.ident, c.url, c.start, null, c.doc_id, c.index);
        try seen.put(arena, key, entries.items.len);
        try entries.append(arena, .{ .chunk = c, .score = 1.0 / (dk.peers.rrf_k + @as(f64, @floatFromInt(rank + 1))), .order = entries.items.len });
    }
    for (replies) |r| {
        if (r.status != .ok) continue;
        for (r.chunks, 0..) |c, rank| {
            if (if (services.lists) |l| l.hidesUrl(c.url, services.safe) else false) continue;
            const contribution = 1.0 / (dk.peers.rrf_k + @as(f64, @floatFromInt(rank + 1)));
            const key = try retrievalKey(arena, c.ident, c.url, c.start, c.node, c.doc_id, c.index);
            if (seen.get(key)) |at| {
                entries.items[at].score += contribution;
                var have = false;
                if (entries.items[at].chunk.node) |n0| if (std.mem.eql(u8, n0, c.node)) {
                    have = true;
                };
                for (entries.items[at].also.items) |x| if (std.mem.eql(u8, x, c.node)) {
                    have = true;
                };
                if (!have) try entries.items[at].also.append(arena, c.node);
                continue;
            }
            try seen.put(arena, key, entries.items.len);
            try entries.append(arena, .{ .chunk = .{
                .doc_id = c.doc_id,
                .view_url = c.view_url,
                .source = c.source,
                .title = c.title,
                .url = c.url,
                .heading = c.heading,
                .index = c.index,
                .of = c.of,
                .start = c.start,
                .end = c.end,
                .page = c.page,
                .page_source = c.page_source,
                .entries = c.entries,
                .score = c.score,
                .text = c.text,
                .before = c.before,
                .after = c.after,
                .images = &.{},
                .node = c.node,
                .ident = c.ident,
            }, .score = contribution, .order = entries.items.len });
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            if (x.score != y.score) return x.score > y.score;
            return x.order < y.order;
        }
    }.less);
    const n = @min(k, entries.items.len);
    const out = try arena.alloc(RetrievedChunk, n);
    for (entries.items[0..n], out) |e, *o| {
        o.* = e.chunk;
        o.score = e.score;
        o.also_on = e.also.items;
    }
    return .{ .chunks = out, .notes = notes };
}

/// What makes two passages the same across nodes: the same web page and start in it; passages of documents without a
/// shared address (files) are only the same as themselves.
fn retrievalKey(arena: Allocator, ident: ?[]const u8, url: ?[]const u8, start: usize, node: ?[]const u8, doc_id: []const u8, index: u32) error{OutOfMemory}![]const u8 {
    if (ident) |i| return std.fmt.allocPrint(arena, "i:{s}#{d}", .{ i, start });
    if (try dk.peers.identity(arena, url)) |ident_url| return std.fmt.allocPrint(arena, "{s}#{d}", .{ ident_url, start });
    return std.fmt.allocPrint(arena, "{s}/{s}#{d}", .{ node orelse "", doc_id, index });
}

const RetrievedImage = struct { n: u32, url: ?[]const u8 };

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
    try limitQuery(arena, &q, services);
    switch (try applySources(arena, &q, try sourceChoices(arena, services), services.collections, params, null)) {
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

    // Passages of very large documents (books) come from the chunk index, so a document whose relevant section is a
    // small part of it is found anyway; a document found only that way is added to the candidates.
    const chunk_hits = searcher.searchChunks(arena, q, max_chunk_candidates) catch &.{};
    var combined: std.ArrayList(dk.search.Hit) = .empty;
    try combined.appendSlice(arena, page.hits);
    var extra: u32 = 0;
    for (chunk_hits) |ch| {
        var known = false;
        for (combined.items) |h| if (std.mem.eql(u8, &h.id, &ch.id)) {
            known = true;
            break;
        };
        if (known or extra >= 20) continue;
        const info = searcher.info(arena, ch.id) catch null;
        if (info) |h| {
            try combined.append(arena, h);
            extra += 1;
        }
    }

    // The same work in several formats (book.md, book.pdf, book.epub in one folder) is one candidate: the
    // format that keeps the most structure wins.
    var kept: std.ArrayList(dk.search.Hit) = .empty;
    var duplicates: u32 = 0;
    // The PDF copy of a work whose other copy was kept: its page breaks give the kept copy page numbers.
    var twins: std.ArrayList(dk.search.Hit) = .empty;
    for (combined.items) |h| {
        if (dedupe) if (h.url) |u| {
            const stem = dk.retrieve.stemOf(u);
            var merged = false;
            for (kept.items) |*have| {
                const ku = have.url orelse continue;
                if (std.mem.eql(u8, have.connector, h.connector) and std.mem.eql(u8, dk.retrieve.stemOf(ku), stem)) {
                    const loser = if (dk.retrieve.formatRank(u) < dk.retrieve.formatRank(ku)) have.* else h;
                    if (dk.retrieve.formatRank(u) < dk.retrieve.formatRank(ku)) have.* = h;
                    if (std.ascii.endsWithIgnoreCase(loser.url orelse "", ".pdf")) try twins.append(arena, loser);
                    merged = true;
                    duplicates += 1;
                    break;
                }
            }
            if (merged) continue;
        };
        try kept.append(arena, h);
    }

    // Chunk the candidates' stored texts (cached between requests; entries are held until the response is made).
    var held: std.ArrayList(*dk.retrievecache.Entry) = .empty;
    defer if (services.retrieve_cache) |c| for (held.items) |e| c.release(e);
    const Doc = struct { hit: dk.search.Hit, chunks: []const dk.retrieve.Chunk, from_index: bool };
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
        // A document with passages in the chunk index is chunked as the index was (so the numbers agree) and only
        // those passages compete; any other is chunked as asked and all its passages compete.
        var wanted: std.ArrayList(u32) = .empty;
        for (chunk_hits) |ch| if (std.mem.eql(u8, &ch.id, &h.id)) try wanted.append(arena, ch.index);
        const from_index = wanted.items.len > 0;
        const opts: dk.retrieve.Options = if (from_index) dk.retrieve.index_chunk_options else .{ .chunk_chars = chunk_chars, .overlap = overlap };
        const got = (try cachedChunks(arena, services.retrieve_cache, store, h.id, opts, &held)) orelse {
            skipped += 1; // no stored text (the source does not keep it, or it is gone)
            continue;
        };
        total += got.text_bytes;
        const cs = got.chunks;
        const di: u32 = @intCast(docs.items.len);
        try docs.append(arena, .{ .hit = h, .chunks = cs, .from_index = from_index });
        for (cs) |c| {
            if (from_index and std.mem.indexOfScalar(u32, wanted.items, c.index) == null) continue;
            try all_text.append(arena, c.text);
            try all_head.append(arena, try std.mem.join(arena, " / ", c.heading));
            try owner.append(arena, .{ .doc = di, .chunk = c.index });
        }
    }
    var page_indexes: std.ArrayList(?dk.retrieve.PageIndex) = .empty;
    var page_built: std.ArrayList(bool) = .empty;
    try page_indexes.resize(arena, twins.items.len);
    try page_built.appendNTimes(arena, false, twins.items.len);
    @memset(page_indexes.items, null);
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
        var page_no: ?u32 = c.page;
        var page_source: ?[]const u8 = if (c.page != null) "text" else null;
        if (page_no == null) if (d.hit.url) |du| {
            // No page breaks here: look for the same work as a PDF among the duplicates set aside.
            for (twins.items, 0..) |tw, ti| {
                const tu = tw.url orelse continue;
                if (!std.mem.eql(u8, tw.connector, d.hit.connector) or !std.mem.eql(u8, dk.retrieve.stemOf(tu), dk.retrieve.stemOf(du))) continue;
                if (page_indexes.items.len <= ti) try page_indexes.resize(arena, twins.items.len);
                if (!page_built.items[ti]) {
                    page_built.items[ti] = true;
                    page_indexes.items[ti] = try cachedPages(arena, services.retrieve_cache, store, tw.id, &held);
                }
                if (page_indexes.items[ti]) |*pi| {
                    if (try pi.pageOf(arena, c.text)) |pg| {
                        page_no = pg;
                        page_source = "pdf";
                    }
                }
                break;
            }
        };
        const can_open = if (services.originals) |svc| (if (d.hit.url) |u| svc.serves(d.hit.connector, u) else false) else false;
        const images = try arena.alloc(RetrievedImage, c.images.len);
        for (c.images, images) |n, *im| im.* = .{ .n = n, .url = if (can_open) try std.fmt.allocPrint(arena, "/doc/{s}/image/{d}", .{ hex, n }) else null };
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
            .page = page_no,
            .page_source = page_source,
            .entries = c.entries,
            .score = r.score,
            .text = c.text,
            .before = before,
            .after = after,
            .images = images,
            .ident = (try withIdent(arena, services, d.hit)).ident,
        };
    }
    const fed = try federateRetrieval(arena, services, params, params.get("q") orelse "", k, context, out);
    return jsonResponse(arena, .ok, .{ .chunks = if (fed) |f| f.chunks else out, .candidates = @as(u32, @intCast(kept.items.len)), .duplicates_merged = duplicates, .without_text = skipped, .peers = if (fed) |f| f.notes else null });
}

const CachedChunks = struct { chunks: []const dk.retrieve.Chunk, text_bytes: usize };

/// The text of `id` cut to the size retrieval works on (on a character boundary).
fn limitedText(text: []const u8) []const u8 {
    if (text.len <= max_retrieve_text_bytes) return text;
    var end: usize = max_retrieve_text_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// The chunks of a document's stored text, from the cache when it holds them for this version of the content, made
/// (and kept) otherwise. Null if there is no stored text. A held cache entry is added to `held`; the caller releases
/// them once it no longer uses the chunks. Without a cache or a version stamp the chunks live in `arena`.
fn cachedChunks(arena: Allocator, cache: ?*dk.retrievecache.Cache, store: dk.storage.ContentStore, id: dk.document.Id, opts: dk.retrieve.Options, held: *std.ArrayList(*dk.retrievecache.Entry)) error{OutOfMemory}!?CachedChunks {
    if (cache) |c| if (store.stamp(id)) |st| {
        const key = dk.retrievecache.Cache.keyOf(id, st, .chunks, @intCast(opts.chunk_chars), @intCast(opts.overlap));
        if (c.acquire(key)) |e| {
            try held.append(arena, e);
            return .{ .chunks = e.chunks, .text_bytes = e.text_bytes };
        }
        // The text is read into the entry's own memory: chunks (headings especially) may point into it.
        const e = try c.begin(key);
        const bytes = store.get(e.arena.allocator(), id) catch |err| {
            c.discard(e);
            return if (err == error.OutOfMemory) error.OutOfMemory else null;
        };
        const text = limitedText(bytes);
        e.chunks = dk.retrieve.chunk(e.arena.allocator(), text, opts) catch {
            c.discard(e);
            return error.OutOfMemory;
        };
        const kept = c.publish(e, text.len);
        try held.append(arena, kept);
        return .{ .chunks = kept.chunks, .text_bytes = kept.text_bytes };
    };
    const bytes = store.get(arena, id) catch return null;
    const text = limitedText(bytes);
    return .{ .chunks = dk.retrieve.chunk(arena, text, opts) catch return error.OutOfMemory, .text_bytes = text.len };
}

/// The page index of a PDF's text, cached like the chunks. Null if there is no text or no page breaks.
fn cachedPages(arena: Allocator, cache: ?*dk.retrievecache.Cache, store: dk.storage.ContentStore, id: dk.document.Id, held: *std.ArrayList(*dk.retrievecache.Entry)) error{OutOfMemory}!?dk.retrieve.PageIndex {
    if (cache) |c| if (store.stamp(id)) |st| {
        const key = dk.retrievecache.Cache.keyOf(id, st, .pages, 0, 0);
        if (c.acquire(key)) |e| {
            try held.append(arena, e);
            return e.pages;
        }
        const t = store.get(arena, id) catch return null;
        const e = try c.begin(key);
        e.pages = dk.retrieve.PageIndex.build(e.arena.allocator(), t) catch null;
        const kept = c.publish(e, t.len);
        try held.append(arena, kept);
        return kept.pages;
    };
    const t = store.get(arena, id) catch return null;
    return dk.retrieve.PageIndex.build(arena, t) catch null;
}

/// Whether the search itself says what sort of file it wants (`kind:`, `mime:`, `ext:`), in a filter or in its words.
fn asksForMedia(q: dk.search.Query) bool {
    const keys = [_][]const u8{ "kind:", "mime:", "ext:" };
    for (keys) |k| {
        if (std.ascii.findIgnoreCase(q.text, k) != null) return true;
        for (q.filter_strings) |f| if (std.ascii.findIgnoreCase(f, k) != null) return true;
    }
    return false;
}

fn pageSearch(arena: Allocator, searcher: dk.search.Searcher, regex: ?*dk.regexsearch.Service, services: Services, sources: []const html.SourceChoice, boosts: []const dk.search.SourceBoost, params: query.Params) error{OutOfMemory}!Response {
    const parsed = switch (try parseQuery(arena, params, true)) {
        .ok => |p| p,
        .bad => |b| return htmlError(arena, .bad_request, "Bad request", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    var q = parsed.q;
    q.boosts = boosts;
    // The Images button: only pictures, shown as a gallery.
    const gallery = if (params.get("images")) |v| std.mem.eql(u8, v, "1") else false;
    if (gallery) {
        const more = try arena.alloc([]const u8, q.filter_strings.len + 1);
        @memcpy(more[0..q.filter_strings.len], q.filter_strings);
        more[q.filter_strings.len] = "kind:image";
        q.filter_strings = more;
        q.limit = gallery_page_size;
    } else if (!asksForMedia(q)) {
        // Pictures are found with the Images button: an ordinary search is about pages. (A picture indexed from a page
        // carries the page's address and the page's words, and would crowd out the page itself.)
        const more = try arena.alloc([]const u8, q.filter_strings.len + 1);
        @memcpy(more[0..q.filter_strings.len], q.filter_strings);
        more[q.filter_strings.len] = "-kind:image";
        q.filter_strings = more;
    }
    try limitQuery(arena, &q, services);
    // The ticked sources (`source`, repeatable) and the older single `connector`: each is a source name or
    // `kind:NAME` for every source of a kind. They are alternatives (`kind:zim` is all its sources).
    // The default collection applies when nothing is picked, the visitor did not ask for everything, and the
    // caller can see all of it.
    const all_asked = if (params.get("sources")) |v| std.mem.eql(u8, v, "all") else false;
    var default: ?[]const u8 = null;
    if (services.default_collection) |name| if (!all_asked) for (services.collections) |col| if (std.mem.eql(u8, col.name, name) and collectionVisible(services, col)) {
        default = name;
    };
    const picked = switch (try applySources(arena, &q, sources, services.collections, params, default)) {
        .ok => |p| p,
        .bad => |b| return htmlError(arena, .bad_request, "Bad request", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
    };
    const defaulted = if (default) |d| (picked.len == 1 and std.mem.startsWith(u8, picked[0], "collection:") and std.mem.eql(u8, picked[0]["collection:".len..], d) and (try params.all(arena, "source")).len == 0) else false;
    var form: html.Form = .{ .feedback = services.feedback != null and services.is_owner, .login = loginNote(services), .safe_note = safeNote(services), .default_note = if (defaulted) default else null, .all_sources = all_asked, .q = parsed.typed, .language = q.language orelse "", .picked = picked, .regex_enabled = regex != null, .exact_only = q.fuzzy == .off, .sources = sources, .collections = try collectionChoices(arena, services), .sort = params.get("sort") orelse "" };
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

    var semantic_note: ?SemanticNote = null;
    const page = (if (wantsSemantic(params) and services.embed != null and q.text.len > 0) blk: {
        const r = semanticSearch(arena, searcher, services, params, q) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Search => return searchFailure(arena, error.Io, false),
        };
        semantic_note = r.note;
        break :blk r.page;
    } else searcher.search(arena, q)) catch |e| switch (e) {
        // An empty box just shows the form again.
        error.EmptyQuery => {
            var aw: std.Io.Writer.Allocating = .init(arena);
            html.writeHomeForm(&aw.writer, "Enter something to search for.", .{ .regex_enabled = regex != null, .sources = sources, .collections = try collectionChoices(arena, services), .peer_names = try peerNames(arena, services) }) catch return error.OutOfMemory;
            return htmlResponse(arena, .ok, aw.written());
        },
        else => return searchFailure(arena, e, false),
    };

    var shown = page;
    // The same text in several sources is one result, naming the others (`group=0` shows them all).
    if (!(if (params.get("group")) |g| std.mem.eql(u8, g, "0") else false)) {
        const with_ident = try arena.alloc(dk.search.Hit, page.hits.len);
        for (page.hits, with_ident) |h, *dst| dst.* = try withIdent(arena, services, h);
        shown.hits = try groupDuplicates(arena, with_ident);
    }
    form.peer_names = try peerNames(arena, services);
    if (try federate(arena, services, params, q, page.hits)) |f| {
        shown.hits = f.hits;
        form.peers_on = true;
        const notes = try arena.alloc(html.PeerNote, f.notes.len);
        for (f.notes, notes) |src, *dst| {
            const status: dk.peers.Status = std.meta.stringToEnum(dk.peers.Status, src.status).?;
            dst.* = .{ .name = src.peer, .ok = status == .ok, .text = if (status == .ok) (if (src.cached) try std.fmt.allocPrint(arena, "{d} {s} (from a moment ago)", .{ src.results, if (src.results == 1) "result" else "results" }) else try std.fmt.allocPrint(arena, "{d} {s} in {d} ms", .{ src.results, if (src.results == 1) "result" else "results", src.ms })) else statusText(status) };
        }
        form.peer_notes = notes;
    } else if (wantsPeers(params)) form.peers_on = true;
    if (services.answers != null and !services.scope.none()) {
        form.answers_offered = true;
        if (if (params.get("answer")) |v| std.mem.eql(u8, v, "1") else false) {
            form.answer_checked = true;
            if (q.offset == 0) switch (try answerFor(arena, searcher, services, parsed.typed)) {
                .ok => |ok| {
                    const srcs = try arena.alloc(html.AnswerSource, ok.passages.len);
                    for (ok.passages, srcs, 1..) |p, *s, n| s.* = .{ .n = @intCast(n), .title = p.title orelse p.source, .href = p.view_url, .source = p.source };
                    form.answer = .{ .text = ok.text, .model = ok.model, .sources = srcs };
                },
                .no_passages => form.answer_note = "No passage in the documents matched well enough to write an answer.",
                .busy => form.answer_note = "This server has reached its limit of answers for this minute; try again shortly.",
                .unavailable => form.answer_note = "The answer could not be written: the model did not respond.",
                .bad_question => form.answer_note = "A question of 3 to 500 characters is needed for an answer.",
                .off => {},
            };
        }
    }
    form.snippets = snippetCount(params);
    if (gallery) {
        form.images = true;
        form.page_size = gallery_page_size;
        const ok = try arena.alloc(bool, shown.hits.len);
        for (shown.hits, ok) |h, *o| {
            const u = h.url orelse {
                o.* = false;
                continue;
            };
            o.* = if (std.mem.startsWith(u8, u, "file://"))
                (if (services.originals) |orig| h.node == null and orig.serves(h.connector, u) else false)
            else
                services.relay != null and h.node == null and std.mem.startsWith(u8, u, "http");
        }
        form.gallery_ok = ok;
        form.gallery_thumbs = services.thumbs != null;
    }
    form.semantic_offered = services.embed != null;
    form.semantic_checked = semantic_note != null;
    if (semantic_note) |n| form.semantic_text = if (n.used)
        try std.fmt.allocPrint(arena, "Ordered by meaning with {s}{s}{s}.", .{ n.model orelse "the embedding model", if (n.index) " (documents the words missed are included)" else "", if (n.made_now > 0) try std.fmt.allocPrint(arena, "; {d} documents were embedded just now and kept", .{n.made_now}) else "" })
    else
        try std.fmt.allocPrint(arena, "Not ordered by meaning: {s}.", .{n.reason orelse "no reason given"});
    shown.hits = try withMoreSnippets(arena, services, try withFirstSnippets(arena, services, shown.hits, parsed.typed), parsed.typed, form.snippets);
    try applyFallback(arena, services, params, &form, shown.hits.len, q.offset);
    if (shown.hits.len == 0 and q.offset == 0) form.did_you_mean = try didYouMean(arena, searcher, q);
    var aw: std.Io.Writer.Allocating = .init(arena);
    html.writeResults(&aw.writer, form, shown, q.offset, if (gallery) gallery_page_size else html_page_size) catch return error.OutOfMemory;
    return htmlResponse(arena, .ok, aw.written());
}

/// The opt-in fallback for the page: when the local search found few results, links to other engines and, if
/// providers are configured, a way to ask them (or their results, with `web=1` or `fallback.auto`).
fn applyFallback(arena: Allocator, services: Services, params: query.Params, form: *html.Form, local: usize, offset: u32) error{OutOfMemory}!void {
    const fb = services.fallback orelse return;
    if (services.scope.none() or offset != 0 or form.q.len == 0) return;
    if (!fb.wanted(local)) return;
    const links = try arena.alloc(html.FallbackLink, fb.engines.len);
    for (fb.engines, links) |e, *l| l.* = .{ .label = e.label, .href = try dk.fallback.linkFor(arena, e.url, form.q) };
    form.fallback_links = links;
    const svc = fb.service orelse return;
    const asked = if (params.get("web")) |v| std.mem.eql(u8, v, "1") else false;
    if (!asked and !fb.auto) {
        var names: std.ArrayList(u8) = .empty;
        for (svc.providers, 0..) |p, i| {
            if (i > 0) try names.appendSlice(arena, ", ");
            try names.appendSlice(arena, p.name);
        }
        var enc: std.Io.Writer.Allocating = .init(arena);
        query.writeEncoded(&enc.writer, form.q) catch return error.OutOfMemory;
        form.web_href = try std.fmt.allocPrint(arena, "/search?q={s}&web=1", .{enc.written()});
        form.web_names = names.items;
        return;
    }
    const replies = try svc.ask(arena, form.q);
    var ext: std.ArrayList(dk.fallback.External) = .empty;
    var notes: std.ArrayList([]const u8) = .empty;
    for (replies) |r| switch (r.status) {
        .ok => try ext.appendSlice(arena, r.results),
        .limited => try notes.append(arena, try std.fmt.allocPrint(arena, "{s}: this server has reached its limit of web requests for this minute; try again shortly.", .{r.provider})),
        .failed, .unavailable => try notes.append(arena, try std.fmt.allocPrint(arena, "{s}: no answer.", .{r.provider})),
    };
    form.external = ext.items;
    form.external_notes = notes.items;
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

test "API keys and the anonymous scope decide what search, documents and articles show" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const wiki: dk.document.Document = .{ .connector = "wiki", .source_id = "1", .title = "Wiki page", .text = "the shared word lives here" };
    const notes: dk.document.Document = .{ .connector = "notes", .source_id = "1", .title = "Note", .text = "the shared word is also here" };
    try idx.indexer().add(wiki.id(), wiki);
    try idx.indexer().add(notes.id(), notes);

    const colls = [_]dk.config.Collection{
        .{ .name = "public", .sources = &.{"notes"} },
        .{ .name = "reference", .sources = &.{"wiki"} },
    };
    var store = dk.access.KeyStore.init(testing.allocator, testing.io, try tmp.dir.realPathFileAlloc(testing.io, ".", a));
    defer store.deinit();
    var tok_ref: [dk.access.token_len]u8 = undefined;
    var tok_all: [dk.access.token_len]u8 = undefined;
    var keys = try dk.access.add(a, testing.io, &.{}, "ref", &.{"reference"}, 1, &tok_ref);
    keys = try dk.access.add(a, testing.io, keys, "all", &.{"*"}, 2, &tok_all);
    try dk.access.save(a, testing.io, tmp.dir, dk.access.file_name, keys);

    // Anonymous visitors see only the "public" collection; keys see theirs.
    const services: Services = .{ .collections = &colls, .anonymous = &.{"public"}, .keys = &store };
    const get = struct {
        fn at(arena: Allocator, searcher: dk.search.Searcher, sv: Services, target: []const u8, auth: ?[]const u8) Response {
            return handleAuthorized(arena, searcher, sv, .GET, target, auth);
        }
    }.at;
    const bearer = struct {
        fn of(arena: Allocator, token: []const u8) ![]const u8 {
            return std.fmt.allocPrint(arena, "Bearer {s}", .{token});
        }
    }.of;
    const wiki_hex = std.fmt.bytesToHex(wiki.id(), .lower);
    const notes_hex = std.fmt.bytesToHex(notes.id(), .lower);

    const anon = get(a, idx.searcher(), services, "/api/v1/search?q=shared", null);
    try testing.expectEqual(http.Status.ok, anon.status);
    try testing.expect(std.mem.indexOf(u8, anon.body, "\"connector\":\"notes\"") != null);
    try testing.expect(std.mem.indexOf(u8, anon.body, "\"connector\":\"wiki\"") == null);
    // The same through the page, and with the source named in the query or the parameters: still limited.
    try testing.expect(std.mem.indexOf(u8, get(a, idx.searcher(), services, "/search?q=shared+source%3Awiki", null).body, "Wiki page") == null);
    try testing.expect(std.mem.indexOf(u8, get(a, idx.searcher(), services, "/api/v1/search?q=shared&connector=wiki", null).body, "\"connector\":\"wiki\"") == null);
    // Documents outside the scope are as good as absent; those inside are shown.
    try testing.expectEqual(http.Status.not_found, get(a, idx.searcher(), services, try std.fmt.allocPrint(a, "/doc/{s}", .{wiki_hex}), null).status);
    try testing.expectEqual(http.Status.ok, get(a, idx.searcher(), services, try std.fmt.allocPrint(a, "/doc/{s}", .{notes_hex}), null).status);
    // A key for "reference" sees the wiki and not the notes; the key for everything sees both.
    const ref = get(a, idx.searcher(), services, "/api/v1/search?q=shared", try bearer(a, &tok_ref));
    try testing.expect(std.mem.indexOf(u8, ref.body, "\"connector\":\"wiki\"") != null and std.mem.indexOf(u8, ref.body, "\"connector\":\"notes\"") == null);
    try testing.expectEqual(http.Status.ok, get(a, idx.searcher(), services, try std.fmt.allocPrint(a, "/doc/{s}", .{wiki_hex}), try bearer(a, &tok_ref)).status);
    try testing.expectEqual(http.Status.not_found, get(a, idx.searcher(), services, try std.fmt.allocPrint(a, "/doc/{s}", .{notes_hex}), try bearer(a, &tok_ref)).status);
    const everything = get(a, idx.searcher(), services, "/api/v1/search?q=shared", try bearer(a, &tok_all));
    try testing.expect(std.mem.indexOf(u8, everything.body, "\"connector\":\"wiki\"") != null and std.mem.indexOf(u8, everything.body, "\"connector\":\"notes\"") != null);
    // The collection choice: the page offers the collections the caller may use, and "collection:" works in a query.
    try testing.expect(std.mem.indexOf(u8, get(a, idx.searcher(), services, "/", null).body, "value=\"collection:public\"") != null);
    try testing.expect(std.mem.indexOf(u8, get(a, idx.searcher(), services, "/", null).body, "value=\"collection:reference\"") == null);
    try testing.expect(std.mem.indexOf(u8, get(a, idx.searcher(), services, "/", try bearer(a, &tok_all)).body, "value=\"collection:reference\"") != null);
    const by_coll = get(a, idx.searcher(), services, "/api/v1/search?q=shared+collection%3Areference", try bearer(a, &tok_all));
    try testing.expect(std.mem.indexOf(u8, by_coll.body, "\"connector\":\"wiki\"") != null and std.mem.indexOf(u8, by_coll.body, "\"connector\":\"notes\"") == null);
    // A key that is not valid is refused, not treated as anonymous.
    try testing.expectEqual(http.Status.unauthorized, get(a, idx.searcher(), services, "/api/v1/search?q=shared", "Bearer dkk_notakeynotakeynotakeynotakeynotakeynotake").status);
    try testing.expectEqual(http.Status.unauthorized, get(a, idx.searcher(), .{ .collections = &colls }, "/api/v1/search?q=shared", "Bearer dkk_x").status); // no key store
    // Nothing for anonymous visitors: the API needs a key, the page still loads and finds nothing.
    const closed: Services = .{ .collections = &colls, .anonymous = &.{}, .keys = &store };
    const need = get(a, idx.searcher(), closed, "/api/v1/search?q=shared", null);
    try testing.expectEqual(http.Status.unauthorized, need.status);
    try testing.expect(std.mem.indexOf(u8, need.body, "key_required") != null);
    try testing.expectEqual(http.Status.ok, get(a, idx.searcher(), closed, "/api/v1/health", null).status);
    try testing.expectEqual(http.Status.ok, get(a, idx.searcher(), closed, "/", null).status);
    try testing.expect(std.mem.indexOf(u8, get(a, idx.searcher(), closed, "/search?q=shared", null).body, "Wiki page") == null);
    try testing.expectEqual(http.Status.ok, get(a, idx.searcher(), closed, "/api/v1/search?q=shared", try bearer(a, &tok_all)).status);
    // Without any access settings everything is open, as before.
    try testing.expectEqual(http.Status.ok, get(a, idx.searcher(), .{}, "/api/v1/search?q=shared", null).status);
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

test "office files open in the document server: the viewer link, Collabora's redirect, OnlyOffice's page, and WOPI with a token" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "notes");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes/report.docx", .data = "PK fake docx bytes" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes/a.pdf", .data = "%PDF-1.4 fake" });
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = try std.fmt.allocPrint(a, "{s}/notes", .{try tmp.dir.realPathFileAlloc(testing.io, ".", a)});
    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const docx: dk.document.Document = .{ .connector = "notes", .source_id = "d", .title = "Report", .text = "text", .canonical_url = try std.fmt.allocPrint(a, "file://{s}/report.docx", .{base}), .modified_at = 1700000000 };
    const pdf: dk.document.Document = .{ .connector = "notes", .source_id = "p", .title = "P", .text = "text", .canonical_url = try std.fmt.allocPrint(a, "file://{s}/a.pdf", .{base}) };
    const hidden: dk.document.Document = .{ .connector = "other", .source_id = "h", .title = "H", .text = "text", .canonical_url = try std.fmt.allocPrint(a, "file://{s}/report.docx", .{base}) };
    for ([_]dk.document.Document{ docx, pdf, hidden }) |d| try idx.indexer().add(d.id(), d);
    const roots = [_]dk.originals.Root{ .{ .connector = "notes", .base = base }, .{ .connector = "other", .base = base } };
    const originals: dk.originals.Service = .{ .io = testing.io, .roots = &roots };
    var collabora = try dk.docserver.Service.init(testing.io, .{ .kind = .collabora, .url = "http://127.0.0.1:9980", .public_url = "http://172.17.0.1:8080" });
    var onlyoffice = try dk.docserver.Service.init(testing.io, .{ .kind = .onlyoffice, .url = "http://127.0.0.1:8090", .public_url = "http://172.17.0.1:8080", .jwt_secret = "s3cret" });
    const hex = std.fmt.bytesToHex(docx.id(), .lower);
    const pdf_hex = std.fmt.bytesToHex(pdf.id(), .lower);
    const hidden_hex = std.fmt.bytesToHex(hidden.id(), .lower);
    const with_c: Services = .{ .originals = &originals, .docserver = &collabora };
    const with_o: Services = .{ .originals = &originals, .docserver = &onlyoffice };
    const get = struct {
        fn at(arena: Allocator, searcher: dk.search.Searcher, sv: Services, target: []const u8) Response {
            return handleServices(arena, searcher, sv, .GET, target);
        }
    }.at;

    // The viewer offers the link for an office file only, and only when a document server is set up.
    try testing.expect(std.mem.indexOf(u8, get(a, idx.searcher(), with_c, try std.fmt.allocPrint(a, "/doc/{s}", .{hex})).body, "/open\">Open in the document viewer") != null);
    try testing.expect(std.mem.indexOf(u8, get(a, idx.searcher(), with_c, try std.fmt.allocPrint(a, "/doc/{s}", .{pdf_hex})).body, "document viewer") == null);
    try testing.expect(std.mem.indexOf(u8, get(a, idx.searcher(), .{ .originals = &originals }, try std.fmt.allocPrint(a, "/doc/{s}", .{hex})).body, "document viewer") == null);
    try testing.expectEqual(http.Status.not_found, get(a, idx.searcher(), with_c, try std.fmt.allocPrint(a, "/doc/{s}/open", .{pdf_hex})).status);
    try testing.expectEqual(http.Status.not_found, get(a, idx.searcher(), .{ .originals = &originals }, try std.fmt.allocPrint(a, "/doc/{s}/open", .{hex})).status);

    // Collabora: a redirect to its editor with the WOPI address and a token.
    const red = get(a, idx.searcher(), with_c, try std.fmt.allocPrint(a, "/doc/{s}/open", .{hex}));
    try testing.expectEqual(http.Status.see_other, red.status);
    var location: []const u8 = "";
    for (red.headers) |h| if (std.mem.eql(u8, h.name, "location")) {
        location = h.value;
    };
    try testing.expect(std.mem.startsWith(u8, location, "http://127.0.0.1:9980/browser/dist/cool.html?WOPISrc=http%3A%2F%2F172.17.0.1%3A8080%2Fwopi%2Ffiles%2F"));
    const token = location[std.mem.indexOf(u8, location, "access_token=").? + "access_token=".len ..];

    // WOPI with that token: the details and the file; with another document's id, a wrong token or none: refused.
    const info = get(a, idx.searcher(), with_c, try std.fmt.allocPrint(a, "/wopi/files/{s}?access_token={s}", .{ hex, token }));
    try testing.expectEqual(http.Status.ok, info.status);
    try testing.expect(std.mem.indexOf(u8, info.body, "\"BaseFileName\":\"report.docx\"") != null);
    try testing.expect(std.mem.indexOf(u8, info.body, "\"UserCanWrite\":false") != null);
    try testing.expect(std.mem.indexOf(u8, info.body, "\"Size\":18") != null);
    const body = get(a, idx.searcher(), with_c, try std.fmt.allocPrint(a, "/wopi/files/{s}/contents?access_token={s}", .{ hex, token }));
    try testing.expectEqual(http.Status.ok, body.status);
    try testing.expectEqualStrings("PK fake docx bytes", body.body);
    try testing.expectEqual(http.Status.unauthorized, get(a, idx.searcher(), with_c, try std.fmt.allocPrint(a, "/wopi/files/{s}/contents?access_token={s}", .{ hidden_hex, token })).status);
    try testing.expectEqual(http.Status.unauthorized, get(a, idx.searcher(), with_c, try std.fmt.allocPrint(a, "/wopi/files/{s}/contents", .{hex})).status);
    try testing.expectEqual(http.Status.unauthorized, get(a, idx.searcher(), with_c, try std.fmt.allocPrint(a, "/wopi/files/{s}/contents?access_token=nonsense", .{hex})).status);
    // Collabora also sends the token as an Authorization header; that must not be taken for an API key.
    const with_header = handleAuthorized(a, idx.searcher(), with_c, .GET, try std.fmt.allocPrint(a, "/wopi/files/{s}?access_token={s}", .{ hex, token }), try std.fmt.allocPrint(a, "Bearer {s}", .{token}));
    try testing.expectEqual(http.Status.ok, with_header.status);
    // A token from another server (another secret) is no good, and without a document server the paths do not exist.
    try testing.expectEqual(http.Status.unauthorized, get(a, idx.searcher(), with_o, try std.fmt.allocPrint(a, "/wopi/files/{s}/contents?access_token={s}", .{ hex, token })).status);
    try testing.expectEqual(http.Status.not_found, get(a, idx.searcher(), .{ .originals = &originals }, try std.fmt.allocPrint(a, "/wopi/files/{s}/contents?access_token={s}", .{ hex, token })).status);

    // A document the caller may not see cannot be opened, even though the document server could fetch it.
    const colls = [_]dk.config.Collection{.{ .name = "mine", .sources = &.{"notes"} }};
    const limited: Services = .{ .originals = &originals, .docserver = &collabora, .collections = &colls, .anonymous = &.{"mine"} };
    try testing.expectEqual(http.Status.see_other, get(a, idx.searcher(), limited, try std.fmt.allocPrint(a, "/doc/{s}/open", .{hex})).status);
    try testing.expectEqual(http.Status.not_found, get(a, idx.searcher(), limited, try std.fmt.allocPrint(a, "/doc/{s}/open", .{hidden_hex})).status);

    // OnlyOffice: a page with its viewer script, the file's token address, a JWT, and a policy that allows that script.
    const page = get(a, idx.searcher(), with_o, try std.fmt.allocPrint(a, "/doc/{s}/open", .{hex}));
    try testing.expectEqual(http.Status.ok, page.status);
    try testing.expect(std.mem.indexOf(u8, page.body, "http://127.0.0.1:8090/web-apps/apps/api/documents/api.js") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "DocsAPI.DocEditor") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "\"mode\":\"view\"") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, ",\"token\":\"ey") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "/wopi/files/") != null);
    var policy: []const u8 = "";
    for (page.headers) |h| if (std.mem.eql(u8, h.name, "content-security-policy")) {
        policy = h.value;
    };
    try testing.expect(std.mem.indexOf(u8, policy, "'sha256-") != null);
    var policies: usize = 0;
    for (page.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "content-security-policy")) {
        policies += 1;
    };
    try testing.expectEqual(@as(usize, 1), policies);
    try testing.expect(std.mem.indexOf(u8, policy, "frame-src http://127.0.0.1:8090") != null);
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

test "peers: asked only on request, reported when they fail, never for a limited caller, and the page offers the box" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const hits = [_]dk.search.Hit{.{ .id = .{ 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .connector = "notes", .url = "https://e.org/a", .title = "Note", .snippet = null, .score = 1 }};
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    const peers_cfg = [_]dk.config.Peer{.{ .name = "office", .url = "http://127.0.0.1:1", .timeout_ms = 500 }};
    const svc = try dk.peers.Service.init(testing.allocator, testing.io, "home", &peers_cfg);
    defer svc.deinit();
    const colls = [_]dk.config.Collection{.{ .name = "public", .sources = &.{"notes"} }};
    const open: Services = .{ .peers = svc };
    // Not asked unless the request says so.
    const unasked = handleServices(a, fake.searcher(), open, .GET, "/api/v1/search?q=note");
    try testing.expect(std.mem.indexOf(u8, unasked.body, "\"peers\":null") != null);
    // Asked: the peer is down, the local result is still there and the peer is named in the report.
    const asked = handleServices(a, fake.searcher(), open, .GET, "/api/v1/search?q=note&peers=1");
    try testing.expectEqual(http.Status.ok, asked.status);
    try testing.expect(std.mem.indexOf(u8, asked.body, "\"peer\":\"office\"") != null);
    try testing.expect(std.mem.indexOf(u8, asked.body, "\"status\":\"down\"") != null);
    try testing.expect(std.mem.indexOf(u8, asked.body, "\"title\":\"Note\"") != null);
    // The page: the box on the home page and the results page, the note above the results.
    try testing.expect(std.mem.indexOf(u8, handleServices(a, fake.searcher(), open, .GET, "/").body, "Also ask peers (office)") != null);
    const page = handleServices(a, fake.searcher(), open, .GET, "/search?q=note&peers=1");
    // (The peer failed a moment ago, so it is skipped now; either way the page says so.)
    try testing.expect(std.mem.indexOf(u8, page.body, "<strong>office</strong> was skipped") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "checked") != null);
    // Passages: asked for in the same way, reported in the same way; a limited caller gets none.
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    try mem.store().put(hits[0].id, "Odin had two ravens.");
    const with_content: Services = .{ .peers = svc, .content = mem.store() };
    svc.peers[0].quiet_until.store(0, .monotonic);
    const rp = handleServices(a, fake.searcher(), with_content, .GET, "/api/v1/retrieve?q=odin+ravens&peers=1");
    try testing.expectEqual(http.Status.ok, rp.status);
    try testing.expect(std.mem.indexOf(u8, rp.body, "\"peer\":\"office\"") != null);
    try testing.expect(std.mem.indexOf(u8, rp.body, "Odin had two ravens") != null);
    try testing.expect(std.mem.indexOf(u8, handleServices(a, fake.searcher(), with_content, .GET, "/api/v1/retrieve?q=odin+ravens").body, "\"peers\":null") != null);
    // A caller whose view is limited gets neither the box nor the peers.
    const limited: Services = .{ .peers = svc, .collections = &colls, .anonymous = &.{"public"} };
    const lim = handleServices(a, fake.searcher(), limited, .GET, "/api/v1/search?q=note&peers=1");
    try testing.expect(std.mem.indexOf(u8, lim.body, "\"peers\":null") != null);
    try testing.expect(std.mem.indexOf(u8, handleServices(a, fake.searcher(), limited, .GET, "/").body, "Also ask peers") == null);
}

test "results carry an identity that does not depend on the node: the address for web pages, the text for files" {
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const id_a: dk.document.Id = .{ 0xa1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const id_b: dk.document.Id = .{ 0xb1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const id_c: dk.document.Id = .{ 0xc1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try mem.store().put(id_a, "the very same text");
    try mem.store().put(id_b, "the very same text");
    try mem.store().put(id_c, "another text");
    const hits = [_]dk.search.Hit{
        .{ .id = id_a, .connector = "disk1", .url = "file:///home/a/x.txt", .title = "A", .snippet = null, .score = 3 },
        .{ .id = id_b, .connector = "disk2", .url = "file:///mnt/b/y.txt", .title = "B", .snippet = null, .score = 2 },
        .{ .id = id_c, .connector = "disk2", .url = "file:///mnt/b/z.txt", .title = "C", .snippet = null, .score = 1 },
    };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    const r = handleServices(a, fake.searcher(), .{ .content = mem.store() }, .GET, "/api/v1/search?q=text");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("hits").?.array.items;
    const ia = items[0].object.get("ident").?.string;
    try testing.expectEqual(@as(usize, 32), ia.len);
    try testing.expectEqualStrings(ia, items[1].object.get("ident").?.string); // the same text elsewhere
    try testing.expect(!std.mem.eql(u8, ia, items[2].object.get("ident").?.string));
    // Without stored text a file has no identity; a web page always does.
    const none = handleServices(a, fake.searcher(), .{}, .GET, "/api/v1/search?q=text");
    try testing.expect(std.mem.indexOf(u8, none.body, "\"ident\":null") != null);
}

test "a key with a limit gets 429 and retry-after once it is over it; other callers are not affected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var store = dk.access.KeyStore.init(testing.allocator, testing.io, try tmp.dir.realPathFileAlloc(testing.io, ".", a));
    defer store.deinit();
    var tok_slow: [dk.access.token_len]u8 = undefined;
    var tok_free: [dk.access.token_len]u8 = undefined;
    var keys = try dk.access.addRated(a, testing.io, &.{}, "slow", &.{"*"}, 1, 2, &tok_slow);
    keys = try dk.access.add(a, testing.io, keys, "free", &.{"*"}, 2, &tok_free);
    try dk.access.save(a, testing.io, tmp.dir, dk.access.file_name, keys);
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    const services: Services = .{ .keys = &store };
    const bearer = struct {
        fn of(arena: Allocator, t: []const u8) ![]const u8 {
            return std.fmt.allocPrint(arena, "Bearer {s}", .{t});
        }
    }.of;
    const slow = try bearer(a, &tok_slow);
    for (0..2) |_| try testing.expectEqual(http.Status.ok, handleAuthorized(a, fake.searcher(), services, .GET, "/api/v1/search?q=x", slow).status);
    const over = handleAuthorized(a, fake.searcher(), services, .GET, "/api/v1/search?q=x", slow);
    try testing.expectEqual(http.Status.too_many_requests, over.status);
    try testing.expect(std.mem.indexOf(u8, over.body, "rate_limited") != null);
    var retry: []const u8 = "";
    for (over.headers) |h| if (std.mem.eql(u8, h.name, "retry-after")) {
        retry = h.value;
    };
    try testing.expect((std.fmt.parseInt(u32, retry, 10) catch 0) >= 1);
    // The page says it too; anonymous callers and the key without a limit are not counted.
    try testing.expectEqual(http.Status.too_many_requests, handleAuthorized(a, fake.searcher(), services, .GET, "/search?q=x", slow).status);
    for (0..5) |_| try testing.expectEqual(http.Status.ok, handleAuthorized(a, fake.searcher(), services, .GET, "/api/v1/search?q=x", try bearer(a, &tok_free)).status);
    try testing.expectEqual(http.Status.ok, handleServices(a, fake.searcher(), services, .GET, "/api/v1/search?q=x").status);
}

test "source list with counts, the sources page, a default collection with the way out, and duplicates folded" {
    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const docs = [_]dk.document.Document{
        .{ .connector = "books", .source_id = "1", .title = "Edda", .text = "ravens of the north", .canonical_url = "file:///b/edda.txt", .acquired_at = 1700000000 },
        .{ .connector = "backup", .source_id = "1", .title = "Edda copy", .text = "ravens of the north", .canonical_url = "file:///bk/edda.txt", .acquired_at = 1700000500 },
        .{ .connector = "notes", .source_id = "1", .title = "Note", .text = "ravens in my notes", .canonical_url = "file:///n/note.txt", .acquired_at = 1600000000 },
    };
    for (docs) |d| {
        try idx.indexer().add(d.id(), d);
        try mem.store().put(d.id(), d.text.?);
    }
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cfgs = [_]dk.config.Source{
        .{ .name = "books", .kind = "files", .options = &.{} },
        .{ .name = "backup", .kind = "files", .options = &.{} },
        .{ .name = "notes", .kind = "files", .options = &.{} },
    };
    var store = dk.sourcestore.Store.init(testing.allocator, testing.io, &cfgs);
    defer store.deinit();
    var stats = dk.sourcestats.Cache.init(testing.allocator, testing.io);
    defer stats.deinit();
    const colls = [_]dk.config.Collection{.{ .name = "reading", .sources = &.{ "books", "backup" } }};
    const services: Services = .{ .sources = &store, .source_stats = &stats, .content = mem.store(), .collections = &colls, .default_collection = "reading" };

    // The picker shows how many documents each source has; the sources page lists them with their collections.
    const home = handleServices(a, idx.searcher(), services, .GET, "/");
    try testing.expect(std.mem.indexOf(u8, home.body, "books <small class=\"muted\">(1)</small>") != null);
    const sp = handleServices(a, idx.searcher(), services, .GET, "/sources");
    try testing.expectEqual(http.Status.ok, sp.status);
    try testing.expect(std.mem.indexOf(u8, sp.body, "<strong>notes</strong>") != null);
    try testing.expect(std.mem.indexOf(u8, sp.body, "reading") != null);
    try testing.expect(std.mem.indexOf(u8, sp.body, "href=\"/search?q=source%3Abooks\"") != null);

    // Nothing picked: the default collection, with a note and the link to everything; the notes source is left out.
    const def = handleServices(a, idx.searcher(), services, .GET, "/search?q=ravens");
    try testing.expect(std.mem.indexOf(u8, def.body, "Searching only <strong>reading</strong>") != null);
    try testing.expect(std.mem.indexOf(u8, def.body, "Note") == null);
    try testing.expect(std.mem.indexOf(u8, def.body, "sources=all") != null);
    // The same text in two sources is one result naming the other.
    try testing.expect(std.mem.indexOf(u8, def.body, "same text in ") != null);
    try testing.expect(std.mem.indexOf(u8, def.body, "Edda copy") == null);
    // Everything on request; the pager keeps that; a pick or group=0 changes it.
    const all = handleServices(a, idx.searcher(), services, .GET, "/search?q=ravens&sources=all");
    try testing.expect(std.mem.indexOf(u8, all.body, "Note") != null);
    try testing.expect(std.mem.indexOf(u8, all.body, "Searching only") == null);
    const picked = handleServices(a, idx.searcher(), services, .GET, "/search?q=ravens&source=notes");
    try testing.expect(std.mem.indexOf(u8, picked.body, "Searching only") == null and std.mem.indexOf(u8, picked.body, "Note") != null);
    const ungrouped = handleServices(a, idx.searcher(), services, .GET, "/search?q=ravens&sources=all&group=0");
    try testing.expect(std.mem.indexOf(u8, ungrouped.body, "Edda copy") != null);
    // The API is not limited by the default, and folds duplicates only when asked.
    const api = handleServices(a, idx.searcher(), services, .GET, "/api/v1/search?q=ravens");
    try testing.expect(std.mem.indexOf(u8, api.body, "\"Note\"") != null and std.mem.indexOf(u8, api.body, "Edda copy") != null);
    const grouped = handleServices(a, idx.searcher(), services, .GET, "/api/v1/search?q=ravens&group=1");
    try testing.expect(std.mem.indexOf(u8, grouped.body, "Edda copy") == null);
    try testing.expect(std.mem.indexOf(u8, grouped.body, "\"same_in\":[\"backup\"]") != null or std.mem.indexOf(u8, grouped.body, "\"same_in\":[\"books\"]") != null);
    // A caller who cannot see all of the default collection is not given the default.
    const partial = [_]dk.config.Collection{ .{ .name = "reading", .sources = &.{ "books", "backup" } }, .{ .name = "bk", .sources = &.{"books"} } };
    const limited: Services = .{ .sources = &store, .source_stats = &stats, .content = mem.store(), .collections = &partial, .default_collection = "reading", .anonymous = &.{"bk"} };
    const lim = handleServices(a, idx.searcher(), limited, .GET, "/search?q=ravens");
    try testing.expect(std.mem.indexOf(u8, lim.body, "Searching only") == null);
}

test "semantic=1 says why when it cannot reorder, and the plain results are still returned" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const hits = [_]dk.search.Hit{.{ .id = .{ 0x21, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .connector = "n", .url = null, .title = "Lamp", .snippet = null, .score = 1 }};
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    // Not configured.
    const none = handleServices(a, fake.searcher(), .{}, .GET, "/api/v1/search?q=lamp&semantic=1");
    try testing.expectEqual(http.Status.ok, none.status);
    try testing.expect(std.mem.indexOf(u8, none.body, "no embedding model configured") != null);
    try testing.expect(std.mem.indexOf(u8, none.body, "\"title\":\"Lamp\"") != null);
    // Not asked for: no note at all.
    try testing.expect(std.mem.indexOf(u8, handleServices(a, fake.searcher(), .{}, .GET, "/api/v1/search?q=lamp").body, "\"semantic\":null") != null);
    // Configured, but no vectors made yet.
    const client = try dk.embed.Client.init(testing.allocator, testing.io, .{ .url = "http://127.0.0.1:1", .model = "m", .timeout_ms = 300 });
    defer client.deinit();
    const svc: dk.embed.Service = .{ .client = client, .vectors_path = "/nonexistent-dksearch/vectors.db" };
    const nov = handleServices(a, fake.searcher(), .{ .embed = &svc }, .GET, "/api/v1/search?q=lamp&semantic=1");
    try testing.expect(std.mem.indexOf(u8, nov.body, "no vectors yet") != null);
    // Vectors exist, the model server is down: the query cannot be embedded.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/vectors.db", .{tmp.sub_path}, 0);
    var store = try dk.embed.Store.open(vp);
    try store.put(hits[0].id, "m", &.{ 1.0, 0.0 });
    store.close();
    const svc2: dk.embed.Service = .{ .client = client, .vectors_path = vp };
    const down = handleServices(a, fake.searcher(), .{ .embed = &svc2 }, .GET, "/api/v1/search?q=lamp&semantic=1");
    try testing.expectEqual(http.Status.ok, down.status);
    try testing.expect(std.mem.indexOf(u8, down.body, "could not be reached") != null);
    // Paging past the first page is not reordered.
    try testing.expect(std.mem.indexOf(u8, handleServices(a, fake.searcher(), .{ .embed = &svc2 }, .GET, "/api/v1/search?q=lamp&semantic=1&offset=10").body, "first page") != null);
    // The search page offers the choice when a model is set up (and not otherwise), and says what happened.
    try testing.expect(std.mem.indexOf(u8, handleServices(a, fake.searcher(), .{}, .GET, "/").body, "Also search by meaning") == null);
    try testing.expect(std.mem.indexOf(u8, handleServices(a, fake.searcher(), .{ .embed = &svc2 }, .GET, "/").body, "Also search by meaning (AI)") != null);
    const page = handleServices(a, fake.searcher(), .{ .embed = &svc2 }, .GET, "/search?q=lamp&semantic=1");
    try testing.expectEqual(http.Status.ok, page.status);
    try testing.expect(std.mem.indexOf(u8, page.body, "name=\"semantic\" value=\"1\" checked") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "Not ordered by meaning") != null and std.mem.indexOf(u8, page.body, "could not be reached") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "Lamp") != null); // the plain results are still shown
}

test "export: only shared sources, only with a key that covers them, paged with a cursor, with their text and rights" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const docs = [_]dk.document.Document{
        .{ .connector = "books", .source_id = "1", .title = "Edda", .text = "ravens of the north", .canonical_url = "https://e.org/edda", .modified_at = 500 },
        .{ .connector = "books", .source_id = "2", .title = "Saga", .text = "a second book", .canonical_url = "file:///b/saga.txt" },
        .{ .connector = "diary", .source_id = "1", .title = "Diary", .text = "private words" },
        .{ .connector = "secret", .source_id = "1", .title = "Secret", .text = "forbidden words" },
    };
    for (docs) |d| {
        try idx.indexer().add(d.id(), d);
        try mem.store().put(d.id(), d.text.?);
    }
    const cfgs = [_]dk.config.Source{
        .{ .name = "books", .kind = "files", .share = true, .rights = .allowed },
        .{ .name = "diary", .kind = "files" },
        .{ .name = "secret", .kind = "files", .share = true, .rights = .forbidden }, // refused by the file's validation; here for the API's own check
        .{ .name = "off", .kind = "files", .enabled = false, .share = true },
    };
    var sources = dk.sourcestore.Store.init(testing.allocator, testing.io, &cfgs);
    defer sources.deinit();
    var keys_store = dk.access.KeyStore.init(testing.allocator, testing.io, try tmp.dir.realPathFileAlloc(testing.io, ".", a));
    defer keys_store.deinit();
    var tok_all: [dk.access.token_len]u8 = undefined;
    var tok_diary: [dk.access.token_len]u8 = undefined;
    var keys = try dk.access.add(a, testing.io, &.{}, "all", &.{"*"}, 1, &tok_all);
    keys = try dk.access.add(a, testing.io, keys, "diaryonly", &.{"onlydiary"}, 2, &tok_diary);
    try dk.access.save(a, testing.io, tmp.dir, dk.access.file_name, keys);
    const colls = [_]dk.config.Collection{.{ .name = "onlydiary", .sources = &.{"diary"} }};
    const services: Services = .{ .sources = &sources, .content = mem.store(), .keys = &keys_store, .collections = &colls };
    const get = struct {
        fn at(arena: Allocator, searcher: dk.search.Searcher, sv: Services, target: []const u8, token: ?[]const u8) !Response {
            const auth: ?[]const u8 = if (token) |t| try std.fmt.allocPrint(arena, "Bearer {s}", .{t}) else null;
            return handleAuthorized(arena, searcher, sv, .GET, target, auth);
        }
    }.at;

    // No key: refused, however open the server is.
    try testing.expectEqual(http.Status.unauthorized, (try get(a, idx.searcher(), services, "/api/v1/export?source=books", null)).status);
    // A key for everything: the shared source, with text, rights and an identity.
    const r = try get(a, idx.searcher(), services, "/api/v1/export?source=books&limit=1", &tok_all);
    try testing.expectEqual(http.Status.ok, r.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    const first = parsed.value.object.get("documents").?.array.items;
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings("ravens of the north", first[0].object.get("text").?.string);
    try testing.expectEqualStrings("allowed", first[0].object.get("redistribution").?.string);
    try testing.expectEqual(@as(usize, 32), first[0].object.get("ident").?.string.len);
    const next = parsed.value.object.get("next").?.string;
    // The next page continues after the cursor and ends.
    const r2 = try get(a, idx.searcher(), services, try std.fmt.allocPrint(a, "/api/v1/export?source=books&limit=1&after={s}", .{next}), &tok_all);
    try testing.expect(std.mem.indexOf(u8, r2.body, "a second book") != null and std.mem.indexOf(u8, r2.body, "ravens") == null);
    const r3 = try get(a, idx.searcher(), services, try std.fmt.allocPrint(a, "/api/v1/export?source=books&limit=50&after={s}", .{next}), &tok_all);
    try testing.expect(std.mem.indexOf(u8, r3.body, "\"next\":null") != null);
    // Not shared, forbidden, switched off, unknown, or outside the key's collections: all the same answer.
    for ([_][]const u8{ "diary", "secret", "off", "nosuch" }) |name| {
        const x = try get(a, idx.searcher(), services, try std.fmt.allocPrint(a, "/api/v1/export?source={s}", .{name}), &tok_all);
        try testing.expectEqual(http.Status.not_found, x.status);
    }
    try testing.expectEqual(http.Status.not_found, (try get(a, idx.searcher(), services, "/api/v1/export?source=books", &tok_diary)).status);
    // Bad parameters.
    try testing.expectEqual(http.Status.bad_request, (try get(a, idx.searcher(), services, "/api/v1/export", &tok_all)).status);
    try testing.expectEqual(http.Status.bad_request, (try get(a, idx.searcher(), services, "/api/v1/export?source=books&limit=1000", &tok_all)).status);
    try testing.expectEqual(http.Status.bad_request, (try get(a, idx.searcher(), services, "/api/v1/export?source=books&after=-1", &tok_all)).status);
}

test "peers offered for introduction: only with a key, only those marked, with name and address and nothing else" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var keys_store = dk.access.KeyStore.init(testing.allocator, testing.io, try tmp.dir.realPathFileAlloc(testing.io, ".", a));
    defer keys_store.deinit();
    var tok: [dk.access.token_len]u8 = undefined;
    const keys = try dk.access.add(a, testing.io, &.{}, "k", &.{"*"}, 1, &tok);
    try dk.access.save(a, testing.io, tmp.dir, dk.access.file_name, keys);
    const cfgs = [_]dk.config.Peer{
        .{ .name = "lab", .url = "https://lab.example.org", .key = "dkk_secretsecret", .introduce = true },
        .{ .name = "hidden", .url = "https://hidden.example.org", .key = "dkk_other" },
        .{ .name = "off", .url = "https://off.example.org", .introduce = true, .enabled = false },
    };
    const svc = try dk.peers.Service.init(testing.allocator, testing.io, "home", &cfgs);
    defer svc.deinit();
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    const services: Services = .{ .peers = svc, .keys = &keys_store };
    try testing.expectEqual(http.Status.unauthorized, handleServices(a, fake.searcher(), services, .GET, "/api/v1/peers").status);
    const r = handleAuthorized(a, fake.searcher(), services, .GET, "/api/v1/peers", try std.fmt.allocPrint(a, "Bearer {s}", .{&tok}));
    try testing.expectEqual(http.Status.ok, r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "\"name\":\"lab\"") != null and std.mem.indexOf(u8, r.body, "https://lab.example.org") != null);
    try testing.expect(std.mem.indexOf(u8, r.body, "hidden") == null and std.mem.indexOf(u8, r.body, "off.example") == null);
    try testing.expect(std.mem.indexOf(u8, r.body, "secret") == null and std.mem.indexOf(u8, r.body, "dkk_") == null); // no key ever leaves
    try testing.expect(std.mem.indexOf(u8, r.body, "\"node\":\"home\"") != null);
}

test "a key bound to a node works only with that node's signature on that very request; answers are signed for callers that ask" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const caller = dk.identity.Identity.generate(testing.io);
    const stranger = dk.identity.Identity.generate(testing.io);
    const me = dk.identity.Identity.generate(testing.io);
    var caller_id: [dk.identity.id_len]u8 = undefined;
    var keys_store = dk.access.KeyStore.init(testing.allocator, testing.io, try tmp.dir.realPathFileAlloc(testing.io, ".", a));
    defer keys_store.deinit();
    var tok_bound: [dk.access.token_len]u8 = undefined;
    var tok_plain: [dk.access.token_len]u8 = undefined;
    var keys = try dk.access.addBound(a, testing.io, &.{}, "bound", &.{"*"}, 1, 0, caller.idText(&caller_id), &tok_bound);
    keys = try dk.access.add(a, testing.io, keys, "plain", &.{"*"}, 2, &tok_plain);
    try dk.access.save(a, testing.io, tmp.dir, dk.access.file_name, keys);
    var replay = dk.identity.Replay.init(testing.allocator, testing.io);
    defer replay.deinit();
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    const services: Services = .{ .keys = &keys_store, .identity = &me, .replay = &replay };
    const target = "/api/v1/search?q=odin";
    const bearer = try std.fmt.allocPrint(a, "Bearer {s}", .{&tok_bound});
    const host = "peer.example.org:8080";

    // No signature, or a bad one: refused, with the reason.
    const unsigned = handleSigned(a, fake.searcher(), services, .GET, target, bearer, .{ .host = host });
    try testing.expectEqual(http.Status.unauthorized, unsigned.status);
    try testing.expect(std.mem.indexOf(u8, unsigned.body, "signed request") != null);
    const by_stranger = try dk.identity.signRequest(a, testing.io, &stranger, "GET", target, host);
    const wrong = handleSigned(a, fake.searcher(), services, .GET, target, bearer, .{ .host = host, .signed = .{ .node = by_stranger.node, .time = by_stranger.time, .nonce = by_stranger.nonce, .sig = by_stranger.sig } });
    try testing.expectEqual(http.Status.unauthorized, wrong.status);
    try testing.expect(std.mem.indexOf(u8, wrong.body, "another node") != null);
    // The bound node's own signature: accepted, and the answer is signed over the nonce.
    const h = try dk.identity.signRequest(a, testing.io, &caller, "GET", target, host);
    const signed: dk.identity.Signed = .{ .node = h.node, .time = h.time, .nonce = h.nonce, .sig = h.sig };
    const ok = handleSigned(a, fake.searcher(), services, .GET, target, bearer, .{ .host = host, .signed = signed });
    try testing.expectEqual(http.Status.ok, ok.status);
    var dk_node: []const u8 = "";
    var dk_sig: []const u8 = "";
    for (ok.headers) |hd| {
        if (std.mem.eql(u8, hd.name, "dk-node")) dk_node = hd.value;
        if (std.mem.eql(u8, hd.name, "dk-sig")) dk_sig = hd.value;
    }
    var my_id: [dk.identity.id_len]u8 = undefined;
    try testing.expectEqualStrings(me.idText(&my_id), dk_node);
    try testing.expect(dk.identity.verifyResponse(a, me.publicKey(), dk_sig, h.nonce, 200, ok.body));
    // The same signed request again, for another path, or for another host: refused.
    const again = handleSigned(a, fake.searcher(), services, .GET, target, bearer, .{ .host = host, .signed = signed });
    try testing.expectEqual(http.Status.unauthorized, again.status);
    try testing.expect(std.mem.indexOf(u8, again.body, "already used") != null);
    const h2 = try dk.identity.signRequest(a, testing.io, &caller, "GET", target, host);
    const s2: dk.identity.Signed = .{ .node = h2.node, .time = h2.time, .nonce = h2.nonce, .sig = h2.sig };
    try testing.expectEqual(http.Status.unauthorized, handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=thor", bearer, .{ .host = host, .signed = s2 }).status);
    try testing.expectEqual(http.Status.unauthorized, handleSigned(a, fake.searcher(), services, .GET, target, bearer, .{ .host = "evil.example.org", .signed = s2 }).status);
    // A key that is not bound needs no signature; a node without an identity cannot honour a bound key.
    try testing.expectEqual(http.Status.ok, handleSigned(a, fake.searcher(), services, .GET, target, try std.fmt.allocPrint(a, "Bearer {s}", .{&tok_plain}), .{}).status);
    const no_identity: Services = .{ .keys = &keys_store };
    try testing.expectEqual(http.Status.unauthorized, handleSigned(a, fake.searcher(), no_identity, .GET, target, bearer, .{ .host = host, .signed = signed }).status);
    // A caller that only sends a nonce gets a signed answer, without having proved who it is.
    const nonce_only = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/health", null, .{ .nonce_only = "abcdefghijklmnopqrstuv" });
    var has_sig = false;
    for (nonce_only.headers) |hd| if (std.mem.eql(u8, hd.name, "dk-sig")) {
        has_sig = true;
    };
    try testing.expect(has_sig);
}

test "the fallback: nothing without it, links when local results are few, web results only when asked, labelled external" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const hit: dk.search.Hit = .{ .id = .{ 0x31, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .connector = "n", .url = null, .title = "Lamp", .snippet = null, .score = 1 };
    const one = [_]dk.search.Hit{hit};
    var few: FakeSearch = .{ .result = .{ .hits = &one, .has_more = false } };
    var none: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    // Off: no mention of other engines at all.
    try testing.expect(std.mem.indexOf(u8, handleServices(a, few.searcher(), .{}, .GET, "/search?q=lamp").body, "Search elsewhere") == null);
    const engines = [_]dk.fallback.Engine{ dk.fallback.builtin("duckduckgo").?, .{ .name = "mine", .label = "Mine <b>", .url = "https://s.example.org/?q=%s" } };
    var settings: dk.fallback.Settings = .{ .engines = &engines, .min_results = 3 };
    const services: Services = .{ .fallback = &settings };
    const page = handleServices(a, few.searcher(), services, .GET, "/search?q=odin+%26+ravens");
    try testing.expect(std.mem.indexOf(u8, page.body, "Search elsewhere") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "https://duckduckgo.com/?q=odin+%26+ravens") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "Mine &lt;b&gt;") != null); // the label is escaped
    try testing.expect(std.mem.indexOf(u8, page.body, "rel=\"noopener noreferrer nofollow\"") != null);
    // Enough local results: the links are not shown; with the minimum at 0 they always are.
    settings.min_results = 1;
    try testing.expect(std.mem.indexOf(u8, handleServices(a, few.searcher(), services, .GET, "/search?q=lamp").body, "Search elsewhere") == null);
    settings.min_results = 0;
    try testing.expect(std.mem.indexOf(u8, handleServices(a, few.searcher(), services, .GET, "/search?q=lamp").body, "Search elsewhere") != null);
    settings.min_results = 3;
    // Nothing found at all: the links are there.
    try testing.expect(std.mem.indexOf(u8, handleServices(a, none.searcher(), services, .GET, "/search?q=zzz").body, "Search elsewhere") != null);
    // Providers: offered, not asked by default; asked on request, a failure is said, the limit is said.
    const provs = [_]dk.fallback.Provider{.{ .name = "mine", .kind = .searxng, .url = "http://127.0.0.1:1", .timeout_ms = 300 }};
    const svc = try dk.fallback.Service.init(testing.allocator, testing.io, &provs, 2);
    defer svc.deinit();
    settings.service = svc;
    const offered = handleServices(a, few.searcher(), services, .GET, "/search?q=lamp");
    try testing.expect(std.mem.indexOf(u8, offered.body, "Also search the web through mine") != null);
    try testing.expect(std.mem.indexOf(u8, offered.body, "From the web") == null);
    const asked = handleServices(a, few.searcher(), services, .GET, "/search?q=lamp&web=1");
    try testing.expect(std.mem.indexOf(u8, asked.body, "mine: no answer") != null);
    // The API only with fallback=1, and not for a caller who cannot search.
    try testing.expect(std.mem.indexOf(u8, handleServices(a, few.searcher(), services, .GET, "/api/v1/search?q=lamp").body, "\"external\":null") != null);
    const api = handleServices(a, few.searcher(), services, .GET, "/api/v1/search?q=lamp&fallback=1");
    try testing.expect(std.mem.indexOf(u8, api.body, "\"external_status\":[{\"provider\":\"mine\"") != null);
    const colls = [_]dk.config.Collection{.{ .name = "c", .sources = &.{"n"} }};
    const closed: Services = .{ .fallback = &settings, .collections = &colls, .anonymous = &.{} };
    try testing.expect(std.mem.indexOf(u8, handleServices(a, few.searcher(), closed, .GET, "/search?q=lamp").body, "Search elsewhere") == null);
}

test "suggestions complete the last word; an empty result offers a spelling that finds something" {
    const Spell = struct {
        var hit = [_]dk.search.Hit{.{ .id = @splat(7), .connector = "t", .url = "https://e.org/e", .title = "Elephants", .snippet = null, .score = 1 }};
        fn search(_: *anyopaque, _: Allocator, q: dk.search.Query) dk.search.Error!dk.search.Page {
            if (std.mem.eql(u8, q.text, "elephant")) return .{ .hits = &hit, .has_more = false };
            return .{ .hits = &.{}, .has_more = false };
        }
        fn words(_: *anyopaque, arena: Allocator, w: []const u8, kind: dk.search.WordKind, _: u32) dk.search.Error![]const []const u8 {
            const list = try arena.alloc([]const u8, 1);
            if (kind == .known) return &.{}; // nothing typed in this test is a word the index has
            list[0] = if (kind == .prefix) "elephant" else if (std.mem.eql(u8, w, "elefant")) "elephant" else "zzz";
            return if (kind == .spelling and !std.mem.eql(u8, w, "elefant")) &.{} else list;
        }
    };
    var dummy: u8 = 0;
    const s: dk.search.Searcher = .{ .ptr = &dummy, .vtable = &.{ .search = Spell.search, .words = Spell.words } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const sug = handle(a, s, .GET, "/api/v1/suggest?q=big+ele");
    try testing.expectEqual(http.Status.ok, sug.status);
    try testing.expect(std.mem.indexOf(u8, sug.body, "\"big elephant\"") != null);
    // Operators and an empty or finished (trailing space) query give nothing.
    try testing.expect(std.mem.indexOf(u8, handle(a, s, .GET, "/api/v1/suggest?q=ele*").body, "\"suggestions\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, handle(a, s, .GET, "/api/v1/suggest?q=").body, "\"suggestions\":[]") != null);
    const page = handle(a, s, .GET, "/search?q=elefant");
    try testing.expect(std.mem.indexOf(u8, page.body, "Did you mean") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "q=elephant") != null);
    // A query that found something, or whose correction finds nothing, offers nothing.
    try testing.expect(std.mem.indexOf(u8, handle(a, s, .GET, "/search?q=elephant").body, "Did you mean") == null);
    try testing.expect(std.mem.indexOf(u8, handle(a, s, .GET, "/search?q=qqqq").body, "Did you mean") == null);
}

test "snippets=N adds further excerpts from the stored text, in the page and in the API, and the pager keeps the choice" {
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const id: dk.document.Id = .{ 0x51, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "The raven opens the tale. ");
    for (0..30) |_| try text.appendSlice(testing.allocator, "Filler about harvests and the weather in the valley. ");
    try text.appendSlice(testing.allocator, "A second raven watches from the roof of the hall. ");
    try mem.store().put(id, text.items);
    var hits = [_]dk.search.Hit{.{ .id = id, .connector = "books", .url = "https://e.org/saga", .title = "Saga", .snippet = "The \x02raven\x03 opens the tale.", .score = 1 }};
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = true } };
    const services: Services = .{ .content = mem.store() };
    // Not asked: nothing more.
    const unasked = handleServices(a, fake.searcher(), services, .GET, "/api/v1/search?q=raven");
    try testing.expect(std.mem.indexOf(u8, unasked.body, "\"more_snippets\":[]") != null);
    // Asked: the second place of the word appears, marked.
    const api = handleServices(a, fake.searcher(), services, .GET, "/api/v1/search?q=raven&snippets=3");
    try testing.expect(std.mem.indexOf(u8, api.body, "roof of the hall") != null);
    try testing.expect(std.mem.indexOf(u8, api.body, "\\u0002raven\\u0003") != null);
    const page = handleServices(a, fake.searcher(), services, .GET, "/search?q=raven&snippets=3");
    try testing.expect(std.mem.indexOf(u8, page.body, "<p class=\"snippet more\">") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "snippets=3") != null); // kept by the next-page link
    // A hit whose text is not stored, or a silly value, is shown as usual.
    var other = [_]dk.search.Hit{.{ .id = @splat(9), .connector = "books", .url = "https://e.org/x", .title = "X", .snippet = null, .score = 1 }};
    fake.result = .{ .hits = &other, .has_more = false };
    try testing.expect(std.mem.indexOf(u8, handleServices(a, fake.searcher(), services, .GET, "/search?q=raven&snippets=99").body, "snippet more") == null);
}

test "similar documents: the words that set a document apart are searched for, the document itself and what the caller may not see are left out" {
    const Sim = struct {
        var query_seen: [200]u8 = undefined;
        var query_len: usize = 0;
        var hits = [_]dk.search.Hit{
            .{ .id = @splat(1), .connector = "books", .url = "https://e.org/self", .title = "Self", .snippet = null, .score = 3 },
            .{ .id = @splat(2), .connector = "books", .url = "https://e.org/a", .title = "Other A", .snippet = null, .score = 2 },
            .{ .id = @splat(3), .connector = "books", .url = "https://e.org/b", .title = "Other B", .snippet = null, .score = 1 },
        };
        fn search(_: *anyopaque, _: Allocator, q: dk.search.Query) dk.search.Error!dk.search.Page {
            query_len = @min(q.text.len, query_seen.len);
            @memcpy(query_seen[0..query_len], q.text[0..query_len]);
            return .{ .hits = &hits, .has_more = false };
        }
        fn info(_: *anyopaque, _: Allocator, id: dk.document.Id) dk.search.Error!?dk.search.Hit {
            for (hits) |h| if (std.mem.eql(u8, &h.id, &id)) return h;
            return null;
        }
        fn docFreq(_: *anyopaque, arena: Allocator, words: []const []const u8) dk.search.Error![]const u32 {
            const out = try arena.alloc(u32, words.len);
            for (words, out) |w, *o| o.* = if (std.mem.eql(u8, w, "raven")) 3 else if (std.mem.eql(u8, w, "valley")) 90 else 5;
            return out;
        }
        fn stats(_: *anyopaque, arena: Allocator) dk.search.Error![]const dk.search.SourceStat {
            const out = try arena.alloc(dk.search.SourceStat, 1);
            out[0] = .{ .name = "books", .docs = 100, .last_added = null };
            return out;
        }
    };
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    try mem.store().put(@splat(1), "The raven and the valley. Raven again, ravens everywhere, valley valley valley, ancient sagas.");
    var dummy: u8 = 0;
    const s: dk.search.Searcher = .{ .ptr = &dummy, .vtable = &.{ .search = Sim.search, .info = Sim.info, .doc_freq = Sim.docFreq, .source_stats = Sim.stats } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const hex = "01010101010101010101010101010101";
    const r = handleServices(a, s, .{ .content = mem.store() }, .GET, "/api/v1/similar?id=" ++ hex);
    try testing.expectEqual(http.Status.ok, r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "Other A") != null and std.mem.indexOf(u8, r.body, "Other B") != null);
    try testing.expect(std.mem.indexOf(u8, r.body, "\"Self\"") == null); // not itself
    try testing.expect(std.mem.indexOf(u8, Sim.query_seen[0..Sim.query_len], "raven") != null);
    try testing.expect(std.mem.indexOf(u8, Sim.query_seen[0..Sim.query_len], "valley") == null); // too common
    try testing.expect(std.mem.indexOf(u8, Sim.query_seen[0..Sim.query_len], " OR ") != null);
    // The document page lists them.
    const page = handleServices(a, s, .{ .content = mem.store() }, .GET, "/doc/" ++ hex);
    try testing.expect(std.mem.indexOf(u8, page.body, "Similar documents") != null);
    // Bad ids and unknown documents.
    try testing.expectEqual(http.Status.bad_request, handleServices(a, s, .{ .content = mem.store() }, .GET, "/api/v1/similar?id=zz").status);
    try testing.expectEqual(http.Status.not_found, handleServices(a, s, .{ .content = mem.store() }, .GET, "/api/v1/similar?id=09090909090909090909090909090909").status);
    try testing.expectEqual(http.Status.bad_request, handleServices(a, s, .{ .content = mem.store() }, .GET, "/api/v1/similar?id=" ++ hex ++ "&limit=0").status);
    // Without the stored text there is nothing to go on.
    try testing.expect(std.mem.indexOf(u8, handleServices(a, s, .{}, .GET, "/api/v1/similar?id=" ++ hex).body, "\"hits\":[]") != null);
}

test "blocked domains: their documents are not found by id, not offered as similar, not taken from peers or fallbacks" {
    var lists: dk.domainlist.Lists = .{};
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    _ = try lists.blocked.add(a, "bad.example");
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const id_bad: dk.document.Id = @splat(0x61);
    const id_ok: dk.document.Id = @splat(0x62);
    try mem.store().put(id_bad, "text of a blocked page");
    try mem.store().put(id_ok, "text of a fine page");
    var hits = [_]dk.search.Hit{
        .{ .id = id_bad, .connector = "web", .url = "https://www.bad.example/x", .title = "Bad", .snippet = null, .score = 2, .domain = "www.bad.example" },
        .{ .id = id_ok, .connector = "web", .url = "https://good.example/y", .title = "Good", .snippet = null, .score = 1, .domain = "good.example" },
    };
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    const Info = struct {
        var all: []const dk.search.Hit = &.{};
        fn info(_: *anyopaque, _: Allocator, id: dk.document.Id) dk.search.Error!?dk.search.Hit {
            for (all) |h| if (std.mem.eql(u8, &h.id, &id)) return h;
            return null;
        }
        fn search(ptr: *anyopaque, _: Allocator, q: dk.search.Query) dk.search.Error!dk.search.Page {
            _ = q;
            _ = ptr;
            return .{ .hits = all, .has_more = false };
        }
    };
    Info.all = &hits;
    _ = &fake;
    var dummy: u8 = 0;
    const s: dk.search.Searcher = .{ .ptr = &dummy, .vtable = &.{ .search = Info.search, .info = Info.info } };
    const services: Services = .{ .content = mem.store(), .lists = &lists };
    try testing.expectEqual(http.Status.not_found, handleServices(a, s, services, .GET, "/doc/61616161616161616161616161616161").status);
    try testing.expectEqual(http.Status.ok, handleServices(a, s, services, .GET, "/doc/62626262626262626262626262626262").status);
    try testing.expectEqual(http.Status.not_found, handleServices(a, s, services, .GET, "/api/v1/similar?id=61616161616161616161616161616161").status);
    // Without the lists the same document opens.
    try testing.expectEqual(http.Status.ok, handleServices(a, s, .{ .content = mem.store() }, .GET, "/doc/61616161616161616161616161616161").status);
    try testing.expect(hitBlocked(services, hits[0]) and !hitBlocked(services, hits[1]));
    const kept = try withoutBlocked(a, services, &hits);
    try testing.expectEqual(@as(usize, 1), kept.len);
    // A hit with no domain is judged by its address.
    var bare = hits[0];
    bare.domain = null;
    try testing.expect(hitBlocked(services, bare));
}

test "results on hidden networks are marked, and per_domain is checked" {
    var hits = [_]dk.search.Hit{
        .{ .id = @splat(1), .connector = "web", .url = "http://abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion/", .title = "Hidden", .snippet = null, .score = 2 },
        .{ .id = @splat(2), .connector = "web", .url = "https://example.org/", .title = "Plain", .snippet = null, .score = 1 },
    };
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const api = run(&fake, .GET, "/api/v1/search?q=hidden", &ar);
    try testing.expect(std.mem.indexOf(u8, api.body, "\"network\":\"onion\"") != null);
    try testing.expect(std.mem.indexOf(u8, api.body, "\"network\":null") != null);
    const page = run(&fake, .GET, "/search?q=hidden", &ar);
    try testing.expect(std.mem.indexOf(u8, page.body, ">Tor</span>") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "Tor Browser") != null);
    // per_domain reaches the search; silly values are refused.
    _ = run(&fake, .GET, "/api/v1/search?q=hidden&per_domain=2", &ar);
    try testing.expectEqual(@as(u32, 2), fake.last.?.per_domain);
    try testing.expectEqual(http.Status.bad_request, run(&fake, .GET, "/api/v1/search?q=hidden&per_domain=99", &ar).status);
    try testing.expectEqual(http.Status.bad_request, run(&fake, .GET, "/api/v1/search?q=hidden&per_domain=x", &ar).status);
    // The server's default applies when the request says nothing.
    _ = handleServices(a, fake.searcher(), .{ .per_domain = 3 }, .GET, "/api/v1/search?q=hidden");
    try testing.expectEqual(@as(u32, 3), fake.last.?.per_domain);
}

test "safe search: on for visitors, a PIN unlocks a browser for a while, an adult key is never filtered, the ban is never lifted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var pin_secret: dk.secrets.Secrets = .{};
    defer pin_secret.deinit(testing.allocator);
    try pin_secret.setPassword(testing.allocator, testing.io, "4321");
    try dk.secrets.save(testing.io, tmp.dir, dk.safesearch.pin_file_name, pin_secret);
    var unlock = try dk.safesearch.Unlock.init(testing.allocator, testing.io, tmp.dir, 8);
    defer unlock.deinit();
    var lists: dk.domainlist.Lists = .{};
    _ = try lists.blocked.add(a, "banned.example");
    _ = try lists.safe.add(a, "adult.example");
    var keys_store = dk.access.KeyStore.init(testing.allocator, testing.io, try tmp.dir.realPathFileAlloc(testing.io, ".", a));
    defer keys_store.deinit();
    var tok_adult: [dk.access.token_len]u8 = undefined;
    var tok_kid: [dk.access.token_len]u8 = undefined;
    var keys = try dk.access.add(a, testing.io, &.{}, "adult", &.{"*"}, 1, &tok_adult);
    keys = try dk.access.withAdult(a, keys, "adult");
    keys = try dk.access.add(a, testing.io, keys, "kid", &.{"*"}, 2, &tok_kid);
    try dk.access.save(a, testing.io, tmp.dir, dk.access.file_name, keys);
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    const services: Services = .{ .lists = &lists, .safe_default = true, .unlock = &unlock, .keys = &keys_store };
    // The visitor's search is marked safe; the key marked adult is not.
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{});
    try testing.expect(fake.last.?.safe_search);
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", try std.fmt.allocPrint(a, "Bearer {s}", .{&tok_adult}), .{});
    try testing.expect(!fake.last.?.safe_search);
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", try std.fmt.allocPrint(a, "Bearer {s}", .{&tok_kid}), .{});
    try testing.expect(fake.last.?.safe_search);
    // The page says so, with a way to unlock.
    const home = handleSigned(a, fake.searcher(), services, .GET, "/", null, .{});
    try testing.expect(std.mem.indexOf(u8, home.body, "Safe search is on.") != null and std.mem.indexOf(u8, home.body, "action=\"/unlock\"") != null and std.mem.indexOf(u8, home.body, "name=\"pin\"") != null);
    // The unlock form: a wrong PIN is told so and sets nothing; the right one sets a cookie.
    try testing.expectEqual(http.Status.ok, handleSigned(a, fake.searcher(), services, .GET, "/unlock", null, .{}).status);
    const wrong = handleSigned(a, fake.searcher(), services, .POST, "/unlock", null, .{ .body = "pin=0000" });
    try testing.expect(std.mem.indexOf(u8, wrong.body, "not right") != null);
    try testing.expect(headerValue(wrong, "set-cookie") == null);
    const right = handleSigned(a, fake.searcher(), services, .POST, "/unlock", null, .{ .body = "pin=4321" });
    try testing.expectEqual(http.Status.see_other, right.status);
    const set = headerValue(right, "set-cookie").?;
    try testing.expect(std.mem.startsWith(u8, set, "dks_adult=") and std.mem.indexOf(u8, set, "HttpOnly") != null and std.mem.indexOf(u8, set, "Max-Age=28800") != null);
    const cookie = set[0..std.mem.indexOfScalar(u8, set, ';').?];
    // With the cookie the search is not safe, the page says so, and the ban is still on.
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{ .cookie = cookie });
    try testing.expect(!fake.last.?.safe_search);
    try testing.expect(std.mem.indexOf(u8, handleSigned(a, fake.searcher(), services, .GET, "/", null, .{ .cookie = cookie }).body, "Safe search is off in this browser") != null);
    var unlocked_services = services;
    unlocked_services.safe = false;
    try testing.expect(hitBlocked(unlocked_services, .{ .id = @splat(1), .connector = "w", .url = "https://banned.example/x", .title = null, .snippet = null, .score = 1 }));
    try testing.expect(!hitBlocked(unlocked_services, .{ .id = @splat(2), .connector = "w", .url = "https://adult.example/x", .title = null, .snippet = null, .score = 1 }));
    var safe_services = services;
    safe_services.safe = true;
    try testing.expect(hitBlocked(safe_services, .{ .id = @splat(2), .connector = "w", .url = "https://adult.example/x", .title = null, .snippet = null, .score = 1 }));
    // Turning it back on ends the unlock.
    const back = handleSigned(a, fake.searcher(), services, .POST, "/lock", null, .{ .cookie = cookie });
    try testing.expectEqual(http.Status.see_other, back.status);
    try testing.expect(std.mem.indexOf(u8, headerValue(back, "set-cookie").?, "Max-Age=0") != null);
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{ .cookie = cookie });
    try testing.expect(fake.last.?.safe_search);
    // Without a PIN, or with safe search off, there is nothing to unlock.
    const no_unlock: Services = .{ .lists = &lists, .safe_default = true };
    try testing.expectEqual(http.Status.not_found, handleSigned(a, fake.searcher(), no_unlock, .GET, "/unlock", null, .{}).status);
    _ = handleSigned(a, fake.searcher(), .{ .lists = &lists }, .GET, "/api/v1/search?q=odin", null, .{});
    try testing.expect(!fake.last.?.safe_search);
}

test "sign in with a key: the browser gets the key's collections, an adult key skips safe search, a bad or removed key is anonymous again" {
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var keys_store = dk.access.KeyStore.init(testing.allocator, testing.io, try tmp.dir.realPathFileAlloc(testing.io, ".", a));
    defer keys_store.deinit();
    const cols = [_]dk.config.Collection{
        .{ .name = "web", .description = "", .sources = &.{"curated"} },
        .{ .name = "books", .description = "", .sources = &.{"folklore"} },
    };
    var tok_me: [dk.access.token_len]u8 = undefined;
    var tok_adult: [dk.access.token_len]u8 = undefined;
    var keys = try dk.access.add(a, testing.io, &.{}, "me", &.{"*"}, 1, &tok_me);
    keys = try dk.access.add(a, testing.io, keys, "grown-up", &.{"*"}, 2, &tok_adult);
    keys = try dk.access.withAdult(a, keys, "grown-up");
    try dk.access.save(a, testing.io, tmp.dir, dk.access.file_name, keys);
    const made_token: []const u8 = &tok_me;
    const adult_token: []const u8 = &tok_adult;
    var lists: dk.domainlist.Lists = .{};
    const services: Services = .{ .keys = &keys_store, .collections = &cols, .anonymous = &.{"web"}, .lists = &lists, .safe_default = true };
    // Anonymous: only the public collection, safe search on, and the page offers signing in.
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{});
    try testing.expect(fake.last.?.safe_search);
    try testing.expect(std.mem.indexOf(u8, handleSigned(a, fake.searcher(), services, .GET, "/", null, .{}).body, "class=\"loginbtn\"><a href=\"/login\">Login</a>") != null);
    try testing.expectEqual(http.Status.ok, handleSigned(a, fake.searcher(), services, .GET, "/login", null, .{}).status);
    // A wrong key is told so and sets nothing; a good one sets the cookie.
    const wrong = handleSigned(a, fake.searcher(), services, .POST, "/login", null, .{ .body = "credential=dkk_nope" });
    try testing.expectEqual(http.Status.ok, wrong.status);
    try testing.expect(std.mem.indexOf(u8, wrong.body, "not valid") != null and headerValue(wrong, "set-cookie") == null);
    const good = handleSigned(a, fake.searcher(), services, .POST, "/login", null, .{ .body = try std.fmt.allocPrint(a, "credential={s}", .{made_token}) });
    try testing.expectEqual(http.Status.see_other, good.status);
    const set = headerValue(good, "set-cookie").?;
    try testing.expect(std.mem.startsWith(u8, set, "dks_key=dkk_") and std.mem.indexOf(u8, set, "HttpOnly") != null and std.mem.indexOf(u8, set, "Secure") == null);
    const cookie = try std.fmt.allocPrint(a, "other=1; dks_key={s}", .{made_token});
    // With the cookie: the key's scope (everything, for --all), keyed, the page offers signing out.
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{ .cookie = cookie });
    try testing.expect(fake.last.?.safe_search); // this key is not an adult key
    const signed = handleSigned(a, fake.searcher(), services, .GET, "/", null, .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, signed.body, "action=\"/logout\"") != null and std.mem.indexOf(u8, signed.body, ">Logout<") != null);
    // An adult key skips safe search.
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{ .cookie = try std.fmt.allocPrint(a, "dks_key={s}", .{adult_token}) });
    try testing.expect(!fake.last.?.safe_search);
    // A key that is not valid (any more) is anonymous, not an error.
    const stale = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{ .cookie = "dks_key=dkk_removed" });
    try testing.expectEqual(http.Status.ok, stale.status);
    try testing.expect(fake.last.?.safe_search);
    // Signing out clears the cookie. Behind HTTPS the cookie is Secure.
    const out = handleSigned(a, fake.searcher(), services, .POST, "/logout", null, .{ .cookie = cookie });
    try testing.expectEqual(http.Status.see_other, out.status);
    try testing.expect(std.mem.indexOf(u8, headerValue(out, "set-cookie").?, "Max-Age=0") != null);
    var https = services;
    https.cookie_secure = true;
    const secure_login = handleSigned(a, fake.searcher(), https, .POST, "/login", null, .{ .body = try std.fmt.allocPrint(a, "credential={s}", .{made_token}) });
    try testing.expect(std.mem.indexOf(u8, headerValue(secure_login, "set-cookie").?, "; Secure") != null);
    // A server without keys has no sign-in page.
    try testing.expectEqual(http.Status.not_found, handleSigned(a, fake.searcher(), .{}, .GET, "/login", null, .{}).status);
}

test "owner login: the password gives the full view with safe search lifted, a wrong one is told so, and logout clears the cookie" {
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var owner = try dk.owner.OwnerLogin.init(testing.allocator, testing.io, tmp.dir, 30);
    defer owner.deinit();
    const cols = [_]dk.config.Collection{.{ .name = "web", .description = "", .sources = &.{"curated"} }};
    var lists: dk.domainlist.Lists = .{};
    const services: Services = .{ .owner = &owner, .collections = &cols, .anonymous = &.{"web"}, .lists = &lists, .safe_default = true };
    // No password yet: no button, and the page says what to do.
    try testing.expect(std.mem.indexOf(u8, handleSigned(a, fake.searcher(), services, .GET, "/", null, .{}).body, "loginbtn") == null);
    try testing.expect(std.mem.indexOf(u8, handleSigned(a, fake.searcher(), services, .POST, "/login", null, .{ .body = "credential=whatever" }).body, "no owner password") != null);
    try owner.setPassword("correct horse battery");
    // A visitor: the public collection, safe search on, and a Login button.
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{});
    try testing.expect(fake.last.?.safe_search);
    try testing.expect(fake.last.?.scope != null); // only the public collection
    try testing.expect(std.mem.indexOf(u8, handleSigned(a, fake.searcher(), services, .GET, "/", null, .{}).body, ">Login</a>") != null);
    // A wrong password is told so and sets nothing; the right one sets the owner cookie.
    const wrong = handleSigned(a, fake.searcher(), services, .POST, "/login", null, .{ .body = "credential=not+the+password" });
    try testing.expect(std.mem.indexOf(u8, wrong.body, "not right") != null and headerValue(wrong, "set-cookie") == null);
    const good = handleSigned(a, fake.searcher(), services, .POST, "/login", null, .{ .body = "credential=correct+horse+battery" });
    try testing.expectEqual(http.Status.see_other, good.status);
    const set = headerValue(good, "set-cookie").?;
    try testing.expect(std.mem.startsWith(u8, set, "dks_owner=") and std.mem.indexOf(u8, set, "HttpOnly") != null and std.mem.indexOf(u8, set, "Max-Age=2592000") != null);
    // With the cookie: every source (no scope), safe search lifted, a Logout button.
    const cookie = set["dks_owner=".len..std.mem.indexOfScalar(u8, set, ';').?];
    const header = try std.fmt.allocPrint(a, "other=1; dks_owner={s}", .{cookie});
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{ .cookie = header });
    try testing.expect(!fake.last.?.safe_search);
    try testing.expect(fake.last.?.scope == null); // no limit: every source
    const home = handleSigned(a, fake.searcher(), services, .GET, "/", null, .{ .cookie = header });
    try testing.expect(std.mem.indexOf(u8, home.body, ">Logout<") != null and std.mem.indexOf(u8, home.body, ">Login</a>") == null);
    // Logout clears both cookies; a changed password ends every login.
    const out = handleSigned(a, fake.searcher(), services, .POST, "/logout", null, .{ .cookie = header });
    try testing.expectEqual(http.Status.see_other, out.status);
    var cleared: u32 = 0;
    for (out.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "set-cookie") and std.mem.indexOf(u8, h.value, "Max-Age=0") != null) {
        cleared += 1;
    };
    try testing.expectEqual(@as(u32, 2), cleared);
    try owner.setPassword("a different password");
    _ = handleSigned(a, fake.searcher(), services, .GET, "/api/v1/search?q=odin", null, .{ .cookie = header });
    try testing.expect(fake.last.?.safe_search);
}

test "the search pages load the script that makes the box multi-line, and serve it" {
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const home = run(&fake, .GET, "/", &ar);
    try testing.expect(std.mem.indexOf(u8, home.body, "<script src=\"/assets/search.js?v=") != null);
    // The box is still a plain input, so the page works without the script (Enter searches).
    try testing.expect(std.mem.indexOf(u8, home.body, "<input type=\"search\" name=\"q\"") != null);
    try testing.expect(std.mem.indexOf(u8, run(&fake, .GET, "/search?q=odin", &ar).body, "/assets/search.js") != null);
    const js = run(&fake, .GET, "/assets/search.js", &ar);
    try testing.expectEqual(http.Status.ok, js.status);
    try testing.expect(std.mem.startsWith(u8, js.content_type, "text/javascript"));
    try testing.expect(std.mem.indexOf(u8, js.body, "shiftKey") != null and std.mem.indexOf(u8, js.body, "requestSubmit") != null);
    // A query with a line break searches like one with a space.
    try testing.expectEqual(http.Status.ok, run(&fake, .GET, "/search?q=odin%0D%0Aoneeye", &ar).status);
}

test "thumbnails: made on first use from the original, kept, served after the original is gone; what cannot be shrunk goes to the original; off means none" {
    if (!dk.image.available) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "pics");
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = try std.fmt.allocPrint(a, "{s}/pics", .{try tmp.dir.realPathFileAlloc(testing.io, ".", a)});
    // A real picture (made by the encoder) and a file that is a picture only by its name.
    const raw = try a.alloc(u8, 400 * 300 * 3);
    for (raw, 0..) |*b, i| b.* = @intCast((i * 7) % 256);
    const big = try dk.jpegenc.encodeRgb(testing.allocator, raw, 400, 300, 90);
    defer testing.allocator.free(big);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pics/sky.jpg", .data = big });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pics/logo.svg", .data = "<svg xmlns=\"http://www.w3.org/2000/svg\"/>" });
    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const sky: dk.document.Document = .{ .connector = "pics", .source_id = "sky", .title = "sky", .text = "blue sky", .content_type = "image/jpeg", .canonical_url = try std.fmt.allocPrint(a, "file://{s}/sky.jpg", .{base}) };
    const logo: dk.document.Document = .{ .connector = "pics", .source_id = "logo", .title = "logo", .text = "a logo", .content_type = "image/svg+xml", .canonical_url = try std.fmt.allocPrint(a, "file://{s}/logo.svg", .{base}) };
    const page: dk.document.Document = .{ .connector = "pics", .source_id = "page", .title = "page", .text = "words", .content_type = "text/plain", .canonical_url = try std.fmt.allocPrint(a, "file://{s}/sky.jpg", .{base}) };
    for ([_]dk.document.Document{ sky, logo, page }) |d| try idx.indexer().add(d.id(), d);
    const roots = [_]dk.originals.Root{.{ .connector = "pics", .base = base }};
    const originals: dk.originals.Service = .{ .io = testing.io, .roots = &roots };
    const thumb_dir = try std.fmt.allocPrint(a, "{s}/thumbs", .{try tmp.dir.realPathFileAlloc(testing.io, ".", a)});
    var cache = dk.thumbcache.Cache.init(testing.allocator, testing.io, .{ .dir = thumb_dir, .max_bytes = 1 << 28, .px = 100, .quality = 70 });
    const services: Services = .{ .originals = &originals, .thumbs = &cache };
    const s = idx.searcher();
    const sky_hex = std.fmt.bytesToHex(sky.id(), .lower);
    const logo_hex = std.fmt.bytesToHex(logo.id(), .lower);
    const page_hex = std.fmt.bytesToHex(page.id(), .lower);
    // First use: made from the original, small, and stored.
    const first = handleServices(a, s, services, .GET, try std.fmt.allocPrint(a, "/doc/{s}/thumb", .{&sky_hex}));
    try testing.expectEqual(http.Status.ok, first.status);
    try testing.expectEqualStrings("image/jpeg", first.content_type);
    try testing.expect(first.body.len < big.len);
    const got = try dk.image.info(first.body);
    try testing.expect(got.width == 100 and got.height == 75);
    try testing.expect(std.mem.indexOf(u8, headerValue(first, "cache-control").?, "max-age=86400") != null);
    try testing.expectEqual(@as(u64, 1), cache.stats(a).files);
    // The original goes away: the stored thumbnail is still served.
    try tmp.dir.deleteFile(testing.io, "pics/sky.jpg");
    const again = handleServices(a, s, services, .GET, try std.fmt.allocPrint(a, "/doc/{s}/thumb", .{&sky_hex}));
    try testing.expectEqual(http.Status.ok, again.status);
    try testing.expectEqualSlices(u8, first.body, again.body);
    // A picture format that is not shrunk here goes to the original; a document that is not a picture is not found.
    const svg = handleServices(a, s, services, .GET, try std.fmt.allocPrint(a, "/doc/{s}/thumb", .{&logo_hex}));
    try testing.expectEqual(http.Status.see_other, svg.status);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "/doc/{s}/file", .{&logo_hex}), headerValue(svg, "location").?);
    try testing.expectEqual(http.Status.not_found, handleServices(a, s, services, .GET, try std.fmt.allocPrint(a, "/doc/{s}/thumb", .{&page_hex})).status);
    // Off: no route. On: the gallery asks for thumbnails.
    try testing.expectEqual(http.Status.not_found, handleServices(a, s, .{ .originals = &originals }, .GET, try std.fmt.allocPrint(a, "/doc/{s}/thumb", .{&sky_hex})).status);
    const gallery = handleServices(a, s, services, .GET, "/search?q=sky&images=1");
    try testing.expect(std.mem.indexOf(u8, gallery.body, "/thumb\"") != null);
    const without = handleServices(a, s, .{ .originals = &originals }, .GET, "/search?q=sky&images=1");
    try testing.expect(std.mem.indexOf(u8, without.body, "/thumb\"") == null);
}

test "trusted first: asked for by the server's default or by a request, and then no cursor is offered" {
    var hits = [_]dk.search.Hit{.{ .id = @splat(1), .connector = "books", .url = "https://e.org/a", .title = "A", .snippet = null, .score = 2 }};
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = true } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    _ = run(&fake, .GET, "/api/v1/search?q=odin", &ar);
    try testing.expect(fake.last.?.trusted_first == null);
    const with_cursor = run(&fake, .GET, "/api/v1/search?q=odin", &ar);
    try testing.expect(std.mem.indexOf(u8, with_cursor.body, "next_cursor\":\"") != null);
    _ = run(&fake, .GET, "/api/v1/search?q=odin&trusted=1", &ar);
    try testing.expect(fake.last.?.trusted_first.?);
    const trusted = run(&fake, .GET, "/api/v1/search?q=odin&trusted=1", &ar);
    try testing.expect(std.mem.indexOf(u8, trusted.body, "next_cursor\":null") != null);
    try testing.expectEqual(http.Status.bad_request, run(&fake, .GET, "/api/v1/search?q=odin&trusted=maybe", &ar).status);
    _ = handleServices(a, fake.searcher(), .{ .trusted_first = true, .trusted_min_boost = 200 }, .GET, "/api/v1/search?q=odin");
    try testing.expect(fake.last.?.trusted_first.? and fake.last.?.trusted_min_percent == 200);
    _ = handleServices(a, fake.searcher(), .{ .trusted_first = true }, .GET, "/api/v1/search?q=odin&trusted=0");
    try testing.expect(!fake.last.?.trusted_first.?);
}

test "the Images button shows only pictures as a gallery, from this server's own files, and the pager keeps the choice" {
    var hits = [_]dk.search.Hit{
        .{ .id = @splat(1), .connector = "pics", .url = "file:///pics/blue-sky.png", .title = "blue-sky", .snippet = null, .score = 2, .kind = "image" },
        .{ .id = @splat(2), .connector = "pics", .url = "file:///pics/other.svg", .title = "other", .snippet = null, .score = 1, .kind = "image" },
    };
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = true } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // The form has the button; an ordinary search is the usual list and asks for no kind.
    try testing.expect(std.mem.indexOf(u8, run(&fake, .GET, "/", &ar).body, "name=\"images\" value=\"1\"") != null);
    const ordinary = run(&fake, .GET, "/search?q=wallpapers", &ar);
    try testing.expect(std.mem.indexOf(u8, ordinary.body, "class=\"gallery\"") == null and std.mem.indexOf(u8, ordinary.body, "<ol class=\"results\"") != null);
    // An ordinary search leaves pictures out (the button finds them), unless the search itself asks for a kind of file.
    var left_out = false;
    for (fake.last.?.filter_strings) |f| if (std.mem.eql(u8, f, "-kind:image")) {
        left_out = true;
    };
    try testing.expect(left_out);
    _ = run(&fake, .GET, "/search?q=wallpapers+kind%3Aimage", &ar);
    for (fake.last.?.filter_strings) |f| try testing.expect(!std.mem.eql(u8, f, "-kind:image"));
    _ = run(&fake, .GET, "/search?q=wallpapers&filter=ext%3Apng", &ar);
    for (fake.last.?.filter_strings) |f| try testing.expect(!std.mem.eql(u8, f, "-kind:image"));
    // With the button: the kind filter is added, the page is a grid of 40, and the pager keeps `images=1`.
    const g = run(&fake, .GET, "/search?q=wallpapers&images=1", &ar);
    try testing.expectEqual(http.Status.ok, g.status);
    var has_kind = false;
    for (fake.last.?.filter_strings) |f| if (std.mem.eql(u8, f, "kind:image")) {
        has_kind = true;
    };
    try testing.expect(has_kind);
    try testing.expectEqual(@as(u32, gallery_page_size), fake.last.?.limit);
    try testing.expect(std.mem.indexOf(u8, g.body, "<ul class=\"gallery\">") != null and std.mem.indexOf(u8, g.body, "<ol class=\"results\"") == null);
    try testing.expect(std.mem.indexOf(u8, g.body, "images=1") != null); // in the next-page link
    // Without served originals there is no picture to show, only the names; the pages still open.
    try testing.expect(std.mem.indexOf(u8, g.body, "no preview") != null and std.mem.indexOf(u8, g.body, "<img") == null);
    try testing.expect(std.mem.indexOf(u8, g.body, "href=\"/doc/01010101") != null);
    _ = a;
}

test "web pictures: the gallery shows them through the relay, which fetches the recorded address and stores nothing" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = "http://127.0.0.1:1";
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const id_ok: dk.document.Id = @splat(0x71);
    const id_bad: dk.document.Id = @splat(0x72);
    const id_page: dk.document.Id = @splat(0x73);
    try mem.store().put(id_ok, try std.fmt.allocPrint(a, "Image: {s}/pic.png\nPage: https://gallery.example/p\nBlue sky\n", .{base}));
    try mem.store().put(id_bad, try std.fmt.allocPrint(a, "Image: {s}/not.html\nPage: https://gallery.example/p\n", .{base}));
    try mem.store().put(id_page, "A page of words, not a picture record");
    var hits = [_]dk.search.Hit{
        .{ .id = id_ok, .connector = "web", .url = "https://gallery.example/p", .title = "Blue sky", .snippet = null, .score = 3, .kind = "image" },
        .{ .id = id_bad, .connector = "web", .url = "https://gallery.example/p", .title = "Not a picture", .snippet = null, .score = 2, .kind = "image" },
        .{ .id = id_page, .connector = "web", .url = "https://gallery.example/q", .title = "A page", .snippet = null, .score = 1, .kind = "page" },
    };
    const Info = struct {
        var all: []const dk.search.Hit = &.{};
        fn info(_: *anyopaque, _: Allocator, id: dk.document.Id) dk.search.Error!?dk.search.Hit {
            for (all) |h| if (std.mem.eql(u8, &h.id, &id)) return h;
            return null;
        }
        fn search(_: *anyopaque, _: Allocator, _: dk.search.Query) dk.search.Error!dk.search.Page {
            return .{ .hits = all, .has_more = false };
        }
    };
    Info.all = &hits;
    var dummy: u8 = 0;
    const s: dk.search.Searcher = .{ .ptr = &dummy, .vtable = &.{ .search = Info.search, .info = Info.info } };
    var relay: dk.imagerelay.Relay = .{ .gpa = testing.allocator, .io = testing.io, .allow_private = true };
    const services: Services = .{ .content = mem.store(), .relay = &relay };
    // An address that cannot be reached (the fetch itself is tested in imagerelay.zig), a document that is not a picture
    // record, and a server with no relay: not found.
    try testing.expectEqual(http.Status.not_found, handleServices(a, s, services, .GET, "/doc/72727272727272727272727272727272/image").status);
    try testing.expectEqual(http.Status.not_found, handleServices(a, s, services, .GET, "/doc/73737373737373737373737373737373/image").status);
    try testing.expectEqual(http.Status.not_found, handleServices(a, s, .{ .content = mem.store() }, .GET, "/doc/71717171717171717171717171717171/image").status);
    // Too many at once: told to wait.
    var busy: dk.imagerelay.Relay = .{ .gpa = testing.allocator, .io = testing.io, .allow_private = true, .max_concurrent = 0 };
    const waiting = handleServices(a, s, .{ .content = mem.store(), .relay = &busy }, .GET, "/doc/71717171717171717171717171717171/image");
    try testing.expectEqual(http.Status.service_unavailable, waiting.status);
    // The gallery shows web pictures from the relay, and only the names when there is none.
    const gallery = handleServices(a, s, services, .GET, "/search?q=sky&images=1");
    try testing.expect(std.mem.indexOf(u8, gallery.body, "src=\"/doc/71717171717171717171717171717171/image\"") != null);
    const none = handleServices(a, s, .{ .content = mem.store() }, .GET, "/search?q=sky&images=1");
    try testing.expect(std.mem.indexOf(u8, none.body, "<img") == null and std.mem.indexOf(u8, none.body, "no preview") != null);
}

test "answers: off by default, a question is needed, nothing is asked of the model without passages, and an unreachable model is said" {
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const id: dk.document.Id = .{ 0x41, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try mem.store().put(id, "# Edda\n\nOdin had two ravens, Huginn and Muninn.");
    const hits = [_]dk.search.Hit{.{ .id = id, .connector = "books", .url = "file:///x/edda.md", .title = "Edda", .snippet = null, .score = 1 }};
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var found: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    var empty: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    // Off: 404 on the API, and no box on the page.
    try testing.expectEqual(http.Status.not_found, handleServices(a, found.searcher(), .{ .content = mem.store() }, .GET, "/api/v1/answer?q=who+had+ravens").status);
    try testing.expect(std.mem.indexOf(u8, handleServices(a, found.searcher(), .{ .content = mem.store() }, .GET, "/").body, "AI model") == null);
    const client = try dk.ollama.Client.init(testing.allocator, testing.io, "http://127.0.0.1:1");
    defer client.deinit();
    var svc: dk.answer.Service = .{ .client = client, .model = "m", .passages = 4, .max_chars = 4000, .timeout_s = 2, .max_per_minute = 5, .io = testing.io };
    const services: Services = .{ .content = mem.store(), .answers = &svc };
    try testing.expectEqual(http.Status.bad_request, handleServices(a, found.searcher(), services, .GET, "/api/v1/answer?q=hi").status);
    // No passage: an empty answer with the reason, and the model is not asked (the limit is not used).
    const none = handleServices(a, empty.searcher(), services, .GET, "/api/v1/answer?q=who+had+ravens");
    try testing.expectEqual(http.Status.ok, none.status);
    try testing.expect(std.mem.indexOf(u8, none.body, "\"answer\":null") != null);
    try testing.expectEqual(@as(u32, 0), svc.used);
    // Passages found, the model does not answer: 503 with the reason.
    const down = handleServices(a, found.searcher(), services, .GET, "/api/v1/answer?q=who+had+ravens");
    try testing.expectEqual(http.Status.service_unavailable, down.status);
    try testing.expect(std.mem.indexOf(u8, down.body, "model_unavailable") != null);
    // The page offers the box, and says when the model did not respond.
    try testing.expect(std.mem.indexOf(u8, handleServices(a, found.searcher(), services, .GET, "/").body, "Also write an answer") != null);
    const page = handleServices(a, found.searcher(), services, .GET, "/search?q=who+had+ravens&answer=1");
    try testing.expect(std.mem.indexOf(u8, page.body, "the model did not respond") != null);
}

test "retrieval cache: the same answer twice, served from the cache, and a changed document is read again" {
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const id_a: dk.document.Id = .{ 0xaa, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try mem.store().put(id_a, "# Mythology\n\nOdin had two ravens, Huginn and Muninn, who flew over the world.");
    const hits = [_]dk.search.Hit{.{ .id = id_a, .connector = "books", .url = "file:///x/myth.md", .title = "Myths", .snippet = null, .score = 2 }};
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    var cache = dk.retrievecache.Cache.init(testing.allocator, testing.io, 1024 * 1024);
    defer cache.deinit();
    const services: Services = .{ .content = mem.store(), .retrieve_cache = &cache };
    const target = "/api/v1/retrieve?q=odin+ravens";
    const first = handleServices(ar.allocator(), fake.searcher(), services, .GET, target);
    try testing.expectEqual(http.Status.ok, first.status);
    try testing.expectEqual(@as(u64, 0), cache.hits.load(.monotonic));
    const second = handleServices(ar.allocator(), fake.searcher(), services, .GET, target);
    try testing.expectEqual(@as(u64, 1), cache.hits.load(.monotonic));
    try testing.expectEqualStrings(first.body, second.body);
    // The document changes: its stored hash differs, so the cached chunks are not used.
    try mem.store().put(id_a, "# Mythology\n\nOdin had two ravens and a spear called Gungnir.");
    const third = handleServices(ar.allocator(), fake.searcher(), services, .GET, target);
    try testing.expectEqual(@as(u64, 1), cache.hits.load(.monotonic));
    try testing.expect(std.mem.indexOf(u8, third.body, "Gungnir") != null);
    try testing.expect(std.mem.indexOf(u8, third.body, "Huginn") == null);
}

test "retrieval: a Markdown work without page breaks gets pages from its PDF twin; entry names are listed" {
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const id_m: dk.document.Id = .{ 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const id_p: dk.document.Id = .{ 0x22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try mem.store().put(id_m, "# Myths\n\n**URD:** The first page tells of rivers and mountains in the old north country.\n\n**MUNINN:** On the second page Odin sends Huginn and Muninn out over the whole world every morning.\n\n**FENRIR:** The third page is about wolves, moons and the end of all things at Ragnarok.");
    try mem.store().put(id_p, "The first page tells of rivers and mountains in the old north country.\n\n\x0c\n\nOn the second page Odin sends Huginn and Muninn out over the whole world every morning.\n\n\x0c\n\nThe third page is about wolves, moons and the end of all things at Ragnarok.");
    const hits = [_]dk.search.Hit{
        .{ .id = id_p, .connector = "books", .url = "file:///b/myths.pdf", .title = "Myths", .snippet = null, .score = 2 },
        .{ .id = id_m, .connector = "books", .url = "file:///b/myths.md", .title = "Myths", .snippet = null, .score = 1 },
    };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    const r = handleServices(ar.allocator(), fake.searcher(), .{ .content = mem.store() }, .GET, "/api/v1/retrieve?q=Odin+Huginn+Muninn+morning&chunk_chars=200&overlap=0");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.body, .{});
    defer parsed.deinit();
    const first = parsed.value.object.get("chunks").?.array.items[0].object;
    try testing.expectEqualStrings("/doc/11", first.get("view_url").?.string[0..7]); // the Markdown copy was kept
    try testing.expectEqual(@as(i64, 2), first.get("page").?.integer);
    try testing.expectEqualStrings("pdf", first.get("page_source").?.string);
    const entries = first.get("entries").?.array.items;
    try testing.expect(entries.len >= 1);
    var has_muninn = false;
    for (entries) |e| if (std.mem.eql(u8, e.string, "MUNINN")) {
        has_muninn = true;
    };
    try testing.expect(has_muninn);
}

test "pictures embedded in a Markdown original are served from it, and shown in the viewer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "books");
    // Two tiny pictures (1x1 PNG, then a GIF header) among text; and one of a type that is not served.
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
    const file = "# Title\n\n![Image](data:image/png;base64," ++ png ++ ")\n\nText.\n\n![](data:image/gif;base64,R0lGODlhAQABAAAAACw=)\n\n![](data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=)\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "books/b.md", .data = file });
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const abs = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const base = try std.fmt.allocPrint(a, "{s}/books", .{abs});
    var idx = try dk.index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();
    var mem = dk.memory.MemoryContentStore.init(testing.allocator);
    defer mem.deinit();
    const d: dk.document.Document = .{ .connector = "books", .source_id = "b", .title = "B", .text = "# Title\n\n![](dkimg:0)\n\nText.\n\n![](dkimg:1)\n\n![](dkimg:2)", .canonical_url = try std.fmt.allocPrint(a, "file://{s}/b.md", .{base}), .content_type = "text/markdown" };
    try idx.indexer().add(d.id(), d);
    try mem.store().put(d.id(), d.text.?);
    const roots = [_]dk.originals.Root{.{ .connector = "books", .base = base }};
    const svc: dk.originals.Service = .{ .io = testing.io, .roots = &roots };
    const services: Services = .{ .originals = &svc, .content = mem.store() };
    const hex = std.fmt.bytesToHex(d.id(), .lower);
    const img = handleServices(a, idx.searcher(), services, .GET, try std.fmt.allocPrint(a, "/doc/{s}/image/0", .{hex}));
    try testing.expectEqual(http.Status.ok, img.status);
    try testing.expectEqualStrings("image/png", img.content_type);
    try testing.expectEqualStrings("\x89PNG", img.body[0..4]);
    try testing.expectEqualStrings("image/gif", handleServices(a, idx.searcher(), services, .GET, try std.fmt.allocPrint(a, "/doc/{s}/image/1", .{hex})).content_type);
    // A type that could carry script is not served; neither is a number that does not exist, or a source without originals.
    try testing.expectEqual(http.Status.not_found, handleServices(a, idx.searcher(), services, .GET, try std.fmt.allocPrint(a, "/doc/{s}/image/2", .{hex})).status);
    try testing.expectEqual(http.Status.not_found, handleServices(a, idx.searcher(), services, .GET, try std.fmt.allocPrint(a, "/doc/{s}/image/9", .{hex})).status);
    try testing.expectEqual(http.Status.not_found, handleServices(a, idx.searcher(), services, .GET, try std.fmt.allocPrint(a, "/doc/{s}/image/x", .{hex})).status);
    try testing.expectEqual(http.Status.not_found, handleServices(a, idx.searcher(), .{ .content = mem.store() }, .GET, try std.fmt.allocPrint(a, "/doc/{s}/image/0", .{hex})).status);
    // The viewer shows them through that address.
    const page = handleServices(a, idx.searcher(), services, .GET, try std.fmt.allocPrint(a, "/doc/{s}", .{hex}));
    try testing.expect(std.mem.indexOf(u8, page.body, try std.fmt.allocPrint(a, "<img src=\"/doc/{s}/image/0\"", .{hex})) != null);
    const page_off = handleServices(a, idx.searcher(), .{ .content = mem.store() }, .GET, try std.fmt.allocPrint(a, "/doc/{s}", .{hex}));
    try testing.expect(std.mem.indexOf(u8, page_off.body, "<img") == null);
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
    const r = small.get(&ar, true, "/api/v1/search?q=order&regex=(a%2B)%2B%5C1%24");
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
    for ([_][]const u8{ "AND", "OR", "NOT", "comp*", "compositor~", "~5", "a typo or two away", "regular expressions" }) |needle| {
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

test "the browser's Accept-Language reaches the search, which ranks other languages lower" {
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    _ = handleSigned(a, fake.searcher(), .{}, .GET, "/search?q=odin", null, .{ .accept_language = "fr-CA,fr;q=0.9,en;q=0.5" });
    try testing.expectEqual(@as(usize, 2), fake.last.?.prefer_languages.len);
    try testing.expectEqualStrings("fr", fake.last.?.prefer_languages[0]);
    _ = handleSigned(a, fake.searcher(), .{}, .GET, "/api/v1/search?q=odin", null, .{});
    try testing.expectEqual(@as(usize, 0), fake.last.?.prefer_languages.len);
}

test "feedback: only the owner signed in sees the buttons and can mark a result; the mark is kept for eval" {
    var hits = [_]dk.search.Hit{.{ .id = @splat(1), .connector = "web", .url = "https://e.org/c", .title = "Learn C", .snippet = null, .score = 2, .kind = "page" }};
    var fake: FakeSearch = .{ .result = .{ .hits = &hits, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var owner = try dk.owner.OwnerLogin.init(testing.allocator, testing.io, tmp.dir, 30);
    defer owner.deinit();
    try owner.setPassword("correct horse battery");
    var store = dk.feedback.Store.init(testing.io, tmp.dir);
    const services: Services = .{ .owner = &owner, .feedback = &store };
    // A visitor: no buttons, and a mark is refused and writes nothing.
    try testing.expect(std.mem.indexOf(u8, handleSigned(a, fake.searcher(), services, .GET, "/search?q=c", null, .{}).body, "data-feedback") == null);
    const refused = handleSigned(a, fake.searcher(), services, .POST, "/feedback", null, .{ .body = "q=c&url=https%3A%2F%2Fe.org%2Fc&grade=1" });
    try testing.expectEqual(http.Status.forbidden, refused.status);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, dk.feedback.file_name, .{}));
    // The owner: buttons on the list (with the query), and the mark is written.
    const good = handleSigned(a, fake.searcher(), services, .POST, "/login", null, .{ .body = "credential=correct+horse+battery" });
    const set = headerValue(good, "set-cookie").?;
    const header = try std.fmt.allocPrint(a, "dks_owner={s}", .{set["dks_owner=".len..std.mem.indexOfScalar(u8, set, ';').?]});
    const page = handleSigned(a, fake.searcher(), services, .GET, "/search?q=how+to+c", null, .{ .cookie = header });
    try testing.expect(std.mem.indexOf(u8, page.body, "<ol class=\"results\" start=\"1\" data-feedback=\"1\" data-q=\"how to c\">") != null);
    const ok = handleSigned(a, fake.searcher(), services, .POST, "/feedback", null, .{ .cookie = header, .body = "q=how+to+c&url=https%3A%2F%2Fe.org%2Fc&grade=1" });
    try testing.expectEqual(http.Status.ok, ok.status);
    const bad_grade = handleSigned(a, fake.searcher(), services, .POST, "/feedback", null, .{ .cookie = header, .body = "q=how+to+c&url=https%3A%2F%2Fe.org%2Fc&grade=5" });
    try testing.expectEqual(http.Status.bad_request, bad_grade.status);
    try testing.expectEqual(http.Status.method_not_allowed, handleSigned(a, fake.searcher(), services, .GET, "/feedback", null, .{ .cookie = header }).status);
    const text = try tmp.dir.readFileAlloc(testing.io, dk.feedback.file_name, a, .limited(10_000));
    try testing.expect(std.mem.indexOf(u8, text, "\"query\":\"how to c\"") != null and std.mem.indexOf(u8, text, "\"grade\":1") != null);
    // Without a store there are no buttons even for the owner.
    const without_store: Services = .{ .owner = &owner };
    try testing.expect(std.mem.indexOf(u8, handleSigned(a, fake.searcher(), without_store, .GET, "/search?q=c", null, .{ .cookie = header }).body, "data-feedback") == null);
    try testing.expectEqual(http.Status.not_found, handleSigned(a, fake.searcher(), without_store, .POST, "/feedback", null, .{ .cookie = header, .body = "q=c&url=u&grade=1" }).status);
}

test "a spelling suggestion respells only the words the index does not have" {
    const Spell = struct {
        var hit = [_]dk.search.Hit{.{ .id = @splat(7), .connector = "t", .url = "https://e.org/l", .title = "Linux", .snippet = null, .score = 1 }};
        fn search(_: *anyopaque, _: Allocator, q: dk.search.Query) dk.search.Error!dk.search.Page {
            if (std.mem.indexOf(u8, q.text, "language") != null) return .{ .hits = &hit, .has_more = false };
            return .{ .hits = &.{}, .has_more = false };
        }
        fn words(_: *anyopaque, arena: Allocator, w: []const u8, kind: dk.search.WordKind, _: u32) dk.search.Error![]const []const u8 {
            const list = try arena.alloc([]const u8, 1);
            switch (kind) {
                .known => {
                    if (!std.mem.eql(u8, w, "linux") and !std.mem.eql(u8, w, "what")) return &.{};
                    list[0] = w;
                },
                .spelling => {
                    list[0] = if (std.mem.eql(u8, w, "lanague")) "language" else if (std.mem.eql(u8, w, "linux")) "linus" else "wheat";
                },
                .prefix => return &.{},
            }
            return list;
        }
    };
    var dummy: u8 = 0;
    const s: dk.search.Searcher = .{ .ptr = &dummy, .vtable = &.{ .search = Spell.search, .words = Spell.words } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const page = handle(a, s, .GET, "/search?q=what+linux+lanague");
    try testing.expect(std.mem.indexOf(u8, page.body, "Did you mean") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "what linux language") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "linus") == null and std.mem.indexOf(u8, page.body, "wheat") == null);
}

test "suggest: only the owner can add a site; it goes to the crawl list and is kept as a good answer" {
    var fake: FakeSearch = .{ .result = .{ .hits = &.{}, .has_more = false } };
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var owner = try dk.owner.OwnerLogin.init(testing.allocator, testing.io, tmp.dir, 30);
    defer owner.deinit();
    try owner.setPassword("correct horse battery");
    var store = dk.feedback.Store.init(testing.io, tmp.dir);
    const services: Services = .{ .owner = &owner, .feedback = &store };
    // A visitor: no form, a suggestion is refused and nothing is written.
    try testing.expect(std.mem.indexOf(u8, handleSigned(a, fake.searcher(), services, .GET, "/search?q=linux+rescue+cd", null, .{}).body, "form class=\"suggest\"") == null);
    try testing.expectEqual(http.Status.forbidden, handleSigned(a, fake.searcher(), services, .POST, "/suggest", null, .{ .body = "q=x&url=https%3A%2F%2Fclonezilla.org%2F" }).status);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, dk.feedback.suggested_file, .{}));
    // The owner: the form is on the page even with no results; the site is added once and kept as a good answer.
    const good = handleSigned(a, fake.searcher(), services, .POST, "/login", null, .{ .body = "credential=correct+horse+battery" });
    const set = headerValue(good, "set-cookie").?;
    const header = try std.fmt.allocPrint(a, "dks_owner={s}", .{set["dks_owner=".len..std.mem.indexOfScalar(u8, set, ';').?]});
    const page = handleSigned(a, fake.searcher(), services, .GET, "/search?q=linux+rescue+cd", null, .{ .cookie = header });
    try testing.expect(std.mem.indexOf(u8, page.body, "<form class=\"suggest\" data-q=\"linux rescue cd\"><textarea name=\"url\"") != null);
    const first = handleSigned(a, fake.searcher(), services, .POST, "/suggest", null, .{ .cookie = header, .body = "q=linux+rescue+cd&url=https%3A%2F%2Fclonezilla.org%2F" });
    try testing.expectEqual(http.Status.ok, first.status);
    try testing.expect(std.mem.startsWith(u8, first.body, "added"));
    const again = handleSigned(a, fake.searcher(), services, .POST, "/suggest", null, .{ .cookie = header, .body = "q=linux+rescue+cd&url=https%3A%2F%2Fclonezilla.org%2F" });
    try testing.expect(std.mem.startsWith(u8, again.body, "already"));
    try testing.expectEqual(http.Status.bad_request, handleSigned(a, fake.searcher(), services, .POST, "/suggest", null, .{ .cookie = header, .body = "q=x&url=javascript%3Aalert(1)" }).status);
    try testing.expectEqual(http.Status.method_not_allowed, handleSigned(a, fake.searcher(), services, .GET, "/suggest", null, .{ .cookie = header }).status);
    try testing.expectEqualStrings("https://clonezilla.org/\n", try tmp.dir.readFileAlloc(testing.io, dk.feedback.suggested_file, a, .limited(10_000)));
    // Several at once, a line each: the new ones are added, the known one is counted, the rubbish is named.
    const many = handleSigned(a, fake.searcher(), services, .POST, "/suggest", null, .{ .cookie = header, .body = "q=linux+rescue+cd&url=https%3A%2F%2Fa.example.org%2F%0D%0Ahttps%3A%2F%2Fclonezilla.org%2F%0D%0Anot+an+address%0D%0Ahttps%3A%2F%2Fb.example.org%2Fx" });
    try testing.expectEqual(http.Status.ok, many.status);
    try testing.expect(std.mem.indexOf(u8, many.body, "added 2; already there 1; not an address: not, an, address") != null);
    try testing.expectEqualStrings("https://clonezilla.org/\nhttps://a.example.org/\nhttps://b.example.org/x\n", try tmp.dir.readFileAlloc(testing.io, dk.feedback.suggested_file, a, .limited(10_000)));
    try testing.expectEqual(http.Status.bad_request, handleSigned(a, fake.searcher(), services, .POST, "/suggest", null, .{ .cookie = header, .body = "q=x&url=" }).status);
    const marks = try tmp.dir.readFileAlloc(testing.io, dk.feedback.file_name, a, .limited(10_000));
    try testing.expect(std.mem.indexOf(u8, marks, "\"query\":\"linux rescue cd\"") != null and std.mem.indexOf(u8, marks, "https://clonezilla.org/") != null and std.mem.indexOf(u8, marks, "\"grade\":1") != null);
}
