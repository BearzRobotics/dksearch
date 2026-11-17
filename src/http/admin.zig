//! The administration interface (docs/decisions/0012). A separate listener
//! and a separate module from the public search interface; nothing public
//! links here and nothing here is reachable from the public listener.
//!
//! First version: read-only (status, sources, jobs) behind authentication.
//! Credentials are a bearer token (scripts) or a password (browsers), kept
//! only as hashes in the secrets file, which is re-read on every check so a
//! rotated credential takes effect at once and invalidates old sessions.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const dk = @import("dksearch");
const server = @import("server.zig");
const handler = @import("handler.zig");
const admin_js = @embedFile("assets/admin.js");
const admin_js_version = html.assetVersion(admin_js);
const html = @import("html.zig");
const query = @import("query.zig");

const Response = handler.Response;
const Header = handler.Header;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const cookie_name = "dks_session";
const max_sessions = 16;
const max_verifications = 2;
const max_credential_bytes = 1024;
/// Kept below the default write timeout (10 s), so a delayed answer is still delivered.
const max_delay_ms: u64 = 5_000;
/// Login attempts that may be waiting out their delay at once; more get 429.
const max_waiting = 4;
const failure_memory_ns: i96 = 15 * 60 * std.time.ns_per_s;

pub const Options = struct {
    /// Paths of the three databases (the state one is read for the pages).
    index_path: [:0]const u8,
    state_path: [:0]const u8,
    content_path: [:0]const u8,
    secrets_path: []const u8,
    sources: []const dk.config.Source,
    /// When set, the sources are read from here (and can be edited from the
    /// interface); `sources` is then only the initial list.
    store: ?*dk.sourcestore.Store = null,
    /// The configuration file the server was started with, for editing sources.
    /// Null: sources cannot be edited from the interface.
    config_path: ?[]const u8 = null,
    version: []const u8,
    session_idle_ms: u64 = 30 * 60 * 1000,
    session_max_ms: u64 = 8 * 60 * 60 * 1000,
    /// Add `Secure` to the session cookie (set when a proxy serves HTTPS).
    cookie_secure: bool = false,
    public_stats: *const server.Stats,
    admin_stats: *const server.Stats,
    /// Name of the index tokenizer, shown on the query-testing page.
    tokenizer: []const u8 = "unicode61",
    /// The ranking weights in force, shown on the query-testing API.
    title_weight: u32 = 10,
    body_weight: u32 = 1,
    /// Present only when actions are enabled (`admin.actions`): lets the
    /// interface start and cancel imports. Null means strictly read-only.
    jobs: ?*dk.jobs.Manager = null,
    /// For the query-testing page; null hides it.
    searcher: ?dk.search.Searcher = null,
    /// Regular-expression filtering for the query-testing page and API (with
    /// the larger administration limits), if available.
    regex: ?*dk.regexsearch.Service = null,
    /// The data directory (where `api-keys.toml` lives), and the collections and anonymous access setting, for the
    /// Access page.
    data_dir: []const u8 = "",
    collections: []const dk.config.Collection = &.{},
    anonymous_collections: ?[]const []const u8 = null,
    /// The peers this node can ask, and its own name, for the Access page.
    peers: ?*dk.peers.Service = null,
    node_name: []const u8 = "",
    /// The Kiwix library's catalogue (tests point this at a local server).
    kiwix_catalog_url: []const u8 = dk.kiwix.catalog_base,
    kiwix_options: dk.kiwix.Options = .{},
};

const Session = struct {
    id: [64]u8,
    csrf: [32]u8,
    created_ns: i96,
    last_ns: i96,
    fingerprint: [32]u8,
};

const Auth = union(enum) {
    none,
    token,
    session: Session,
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    started_unix: i64,
    mutex: Io.Mutex = .init,
    /// Serialises edits of the configuration file's sources.
    edit_mutex: Io.Mutex = .init,
    sessions: [max_sessions]?Session = @splat(null),
    failures: u32 = 0,
    last_failure_ns: i96 = 0,
    verifying: std.atomic.Value(u32) = .init(0),
    waiting: std.atomic.Value(u32) = .init(0),
    /// Tests: replaces the clock and skips real waiting.
    fake_now_ns: ?i96 = null,
    skip_delay: bool = false,

    pub fn init(gpa: Allocator, io: Io, opts: Options) App {
        return .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .started_unix = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s)),
        };
    }

    pub fn dispatcher(self: *App) server.Dispatcher {
        return .{ .ptr = self, .handle = handleErased, .label = label };
    }

    fn nowNs(self: *App) i96 {
        // The boot clock keeps counting while the machine is suspended, so
        // sessions cannot outlive their limits by sleeping through them.
        return self.fake_now_ns orelse Io.Clock.boot.now(self.io).nanoseconds;
    }

    fn handleErased(ptr: *anyopaque, arena: Allocator, req: server.Request) Response {
        const self: *App = @ptrCast(@alignCast(ptr));
        return self.handle(arena, req) catch |e| switch (e) {
            error.OutOfMemory => handler.plain(.service_unavailable, "temporarily out of memory\n"),
        };
    }

    /// A fixed label for the access log; never the URL.
    pub fn label(target: []const u8) []const u8 {
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
        for ([_][]const u8{ "/", "/jobs", "/jobs/skipped", "/api/v1/admin/jobs/skipped", "/sources", "/sources/new", "/sources/edit", "/actions/sources", "/settings", "/actions/settings", "/maintenance", "/actions/maintenance", "/access", "/actions/key-add", "/actions/key-remove", "/actions/peer-test", "/actions/peer-edit", "/actions/collection-edit", "/zim", "/actions/zim", "/api/v1/admin/maintenance", "/login", "/logout", "/actions/import", "/actions/cancel", "/search", "/api/v1/admin/search", "/assets/style.css", "/assets/admin.js", "/api/v1/admin/status", "/api/v1/admin/sources", "/api/v1/admin/jobs", "/api/v1/admin/imports", "/api/v1/admin/imports/cancel" }) |known| {
            if (std.mem.eql(u8, path, known)) return known;
        }
        return "other";
    }

    // --------------------------------------------------------- routing

    const Route = enum { dashboard, jobs, jobs_skipped, api_jobs_skipped, sources_page, sources_new, source_edit, action_sources, settings_page, action_settings, maintenance, action_maintenance, zim_page, action_zim, access_page, action_peer_test, action_peer_edit, action_collection_edit, action_key_add, action_key_remove, api_maintenance, login, logout, style, script, api_status, api_sources, api_jobs, action_import, action_cancel, api_imports, api_imports_cancel, search_test, api_search, other };

    fn routeOf(path: []const u8) Route {
        const table = [_]struct { []const u8, Route }{
            .{ "/", .dashboard },
            .{ "/jobs", .jobs },
            .{ "/jobs/skipped", .jobs_skipped },
            .{ "/api/v1/admin/jobs/skipped", .api_jobs_skipped },
            .{ "/sources", .sources_page },
            .{ "/sources/new", .sources_new },
            .{ "/sources/edit", .source_edit },
            .{ "/actions/sources", .action_sources },
            .{ "/settings", .settings_page },
            .{ "/actions/settings", .action_settings },
            .{ "/maintenance", .maintenance },
            .{ "/actions/maintenance", .action_maintenance },
            .{ "/access", .access_page },
            .{ "/actions/key-add", .action_key_add },
            .{ "/actions/peer-test", .action_peer_test },
            .{ "/actions/peer-edit", .action_peer_edit },
            .{ "/actions/collection-edit", .action_collection_edit },
            .{ "/actions/key-remove", .action_key_remove },
            .{ "/zim", .zim_page },
            .{ "/actions/zim", .action_zim },
            .{ "/api/v1/admin/maintenance", .api_maintenance },
            .{ "/login", .login },
            .{ "/logout", .logout },
            .{ "/assets/style.css", .style },
            .{ "/assets/admin.js", .script },
            .{ "/api/v1/admin/status", .api_status },
            .{ "/api/v1/admin/sources", .api_sources },
            .{ "/api/v1/admin/jobs", .api_jobs },
            .{ "/actions/import", .action_import },
            .{ "/actions/cancel", .action_cancel },
            .{ "/api/v1/admin/imports", .api_imports },
            .{ "/api/v1/admin/imports/cancel", .api_imports_cancel },
            .{ "/search", .search_test },
            .{ "/api/v1/admin/search", .api_search },
        };
        for (table) |t| if (std.mem.eql(u8, path, t[0])) return t[1];
        return .other;
    }

    pub fn handle(self: *App, arena: Allocator, req: server.Request) error{OutOfMemory}!Response {
        const t = query.parseTarget(arena, req.target) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadEncoding, error.TooManyParams => return handler.plain(.bad_request, "bad request target\n"),
        };
        const route = routeOf(t.path);
        const is_api = std.mem.startsWith(u8, t.path, "/api/");
        const head_ok = req.method == .GET or req.method == .HEAD;

        switch (route) {
            .other => return if (is_api)
                handler.apiError(arena, .not_found, "not_found", "no such endpoint")
            else
                handler.htmlError(arena, .not_found, "Not found", "That page does not exist."),
            .script => if (!head_ok) return methodNotAllowed(arena, is_api, "GET, HEAD") else return .{ .status = .ok, .content_type = "text/javascript; charset=utf-8", .body = admin_js, .headers = handler.headersWith(arena, &.{.{ .name = "cache-control", .value = "public, max-age=3600" }}) },
            .style => {
                if (!head_ok) return methodNotAllowed(arena, is_api, "GET, HEAD");
                return .{ .status = .ok, .content_type = "text/css; charset=utf-8", .body = html.style_css, .headers = handler.headersWith(arena, &.{.{ .name = "cache-control", .value = "public, max-age=3600" }}) };
            },
            .login => {
                if (req.method == .POST) return self.postLogin(arena, req);
                if (!head_ok) return methodNotAllowed(arena, false, "GET, HEAD, POST");
                return renderLogin(arena, .ok, null);
            },
            .logout => {
                if (req.method != .POST) return methodNotAllowed(arena, false, "POST");
                return self.postLogout(arena, req);
            },
            else => {},
        }

        const post_only = route == .action_import or route == .action_cancel or route == .api_imports_cancel or route == .action_maintenance or route == .action_zim or route == .action_peer_test or route == .action_peer_edit or route == .action_collection_edit or route == .action_key_add or route == .action_key_remove or route == .api_maintenance or route == .action_sources or route == .action_settings;
        if (post_only and req.method != .POST) return methodNotAllowed(arena, is_api, "POST");
        if (route == .api_imports and !head_ok and req.method != .POST) return methodNotAllowed(arena, true, "GET, HEAD, POST");
        if (route == .api_sources and !head_ok and req.method != .POST) return methodNotAllowed(arena, true, "GET, HEAD, POST");
        if (!post_only and route != .api_imports and route != .api_sources and !head_ok) return methodNotAllowed(arena, is_api, "GET, HEAD");
        const auth = try self.authenticate(arena, req);
        if (auth == .none) {
            if (is_api) {
                var r = try handler.apiError(arena, .unauthorized, "unauthorized", "a valid bearer token or session is required");
                r.headers = handler.headersWith(arena, &.{ handler.no_store, .{ .name = "www-authenticate", .value = "Bearer" } });
                return r;
            }
            return redirect(arena, "/login", null);
        }
        const csrf: ?[]const u8 = switch (auth) {
            .session => |s| try arena.dupe(u8, &s.csrf),
            else => null,
        };
        return switch (route) {
            .dashboard => self.pageDashboard(arena, csrf),
            .jobs => self.pageJobs(arena, csrf),
            .jobs_skipped => self.pageSkipped(arena, csrf, t.params),
            .api_jobs_skipped => self.apiSkipped(arena, t.params),
            .maintenance => self.pageMaintenance(arena, csrf),
            .action_maintenance => self.startOperation(arena, req, auth, false),
            .zim_page => self.pageZim(arena, csrf, t.params),
            .access_page => self.pageAccess(arena, csrf, null, null),
            .action_peer_test => self.testPeer(arena, req, auth),
            .action_peer_edit => self.editPeer(arena, req, auth),
            .action_collection_edit => self.editCollection(arena, req, auth),
            .action_key_add => self.addKey(arena, req, auth),
            .action_key_remove => self.removeKey(arena, req, auth),
            .action_zim => self.startZimDownload(arena, req, auth),
            .api_maintenance => self.startOperation(arena, req, auth, true),
            .api_status => self.apiStatus(arena),
            .api_sources => if (req.method == .POST) self.editSources(arena, req, auth, true) else self.apiSources(arena),
            .sources_page => self.pageSources(arena, csrf, t.params),
            .sources_new => self.pageSourcesNew(arena, csrf),
            .source_edit => self.pageSourceEdit(arena, csrf, t.params),
            .action_sources => self.editSources(arena, req, auth, false),
            .settings_page => self.pageSettings(arena, csrf, t.params),
            .action_settings => self.saveSettings(arena, req, auth),
            .api_jobs => self.apiJobs(arena),
            .api_imports => if (req.method == .POST) self.startImport(arena, req, auth, true) else self.apiImports(arena),
            .action_import => self.startImport(arena, req, auth, false),
            .api_imports_cancel => self.cancelImport(arena, req, auth, true),
            .search_test => self.pageSearchTest(arena, csrf, t.params),
            .api_search => self.apiSearchTest(arena, t.params),
            .action_cancel => self.cancelImport(arena, req, auth, false),
            else => unreachable,
        };
    }

    // ------------------------------------------------------- query testing

    const test_limit: u32 = 20;

    fn testQuery(params: query.Params) dk.search.Query {
        var q: dk.search.Query = .{ .text = params.get("q") orelse "", .limit = test_limit };
        if (params.get("connector")) |v| if (v.len > 0 and v.len <= 64) {
            q.connector = v;
        };
        if (params.get("language")) |v| if (v.len > 0 and v.len <= 64) {
            q.language = v;
        };
        return q;
    }

    fn apiSearchTest(self: *App, arena: Allocator, params: query.Params) error{OutOfMemory}!Response {
        const searcher = self.opts.searcher orelse return handler.apiError(arena, .not_found, "not_found", "searching is not available here");
        const applied = try handler.applyToken(arena, testQuery(params), handler.parseRegexParams(params));
        switch (applied.rx) {
            .none => {},
            .bad => |b| return handler.apiError(arena, .bad_request, "invalid_parameter", try std.fmt.allocPrint(arena, "{s}: {s}", .{ b.name, b.message })),
            .ok => |req| {
                const r = switch (try handler.regexSearch(arena, searcher, self.opts.regex, applied.q, req)) {
                    .ok => |r| r,
                    .failed => |n| return handler.apiError(arena, n.status, n.code, n.message),
                };
                const RHit = struct { id: []const u8, connector: []const u8, url: ?[]const u8, title: ?[]const u8, snippet: ?[]const u8, score: f64 };
                const rhits = try arena.alloc(RHit, r.page.hits.len);
                for (r.page.hits, rhits) |h, *o| o.* = .{ .id = try arena.dupe(u8, &std.fmt.bytesToHex(h.id, .lower)), .connector = h.connector, .url = h.url, .title = h.title, .snippet = h.snippet, .score = h.score };
                return handler.jsonResponse(arena, .ok, .{ .tokenizer = self.opts.tokenizer, .hits = rhits, .has_more = r.page.has_more, .regex = .{ .examined = r.examined, .truncated = r.truncated } });
            },
        }
        const page = searcher.search(arena, applied.q) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmptyQuery => handler.apiError(arena, .bad_request, "empty_query", "the query has no searchable terms"),
            error.InvalidQuery => handler.apiError(arena, .bad_request, "invalid_query", "the query is out of range"),
            error.Timeout => handler.apiError(arena, .service_unavailable, "search_timeout", "the search took too long"),
            error.Io => handler.apiError(arena, .internal_server_error, "internal_error", "the search failed"),
        };
        const Hit = struct { id: []const u8, connector: []const u8, url: ?[]const u8, title: ?[]const u8, snippet: ?[]const u8, score: f64 };
        const hits = try arena.alloc(Hit, page.hits.len);
        for (page.hits, hits) |h, *o| o.* = .{ .id = try arena.dupe(u8, &std.fmt.bytesToHex(h.id, .lower)), .connector = h.connector, .url = h.url, .title = h.title, .snippet = h.snippet, .score = h.score };
        return handler.jsonResponse(arena, .ok, .{ .tokenizer = self.opts.tokenizer, .title_weight = self.opts.title_weight, .body_weight = self.opts.body_weight, .hits = hits, .has_more = page.has_more });
    }

    fn pageSearchTest(self: *App, arena: Allocator, csrf: ?[]const u8, params: query.Params) error{OutOfMemory}!Response {
        const searcher = self.opts.searcher orelse return handler.htmlError(arena, .not_found, "Not found", "Searching is not available here.");
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        const q = testQuery(params);
        writePage(w, "Search test", csrf, "search") catch return error.OutOfMemory;
        writeSearchTest(self, arena, w, searcher, q, handler.parseRegexParams(params)) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, .ok, aw.written());
    }

    // ------------------------------------------------------------- actions

    const ActionError = struct { status: http.Status, code: []const u8, message: []const u8 };

    fn actionFailure(arena: Allocator, is_api: bool, e: ActionError) error{OutOfMemory}!Response {
        return if (is_api)
            handler.apiError(arena, e.status, e.code, e.message)
        else
            handler.htmlError(arena, e.status, "Not done", e.message);
    }

    /// Checks that actions are enabled and, for a session, the form token.
    /// Returns the parsed form on success.
    fn checkAction(self: *App, arena: Allocator, req: server.Request, auth: Auth, is_api: bool) error{OutOfMemory}!union(enum) { ok: query.Params, refused: Response } {
        if (self.opts.jobs == null) return .{ .refused = try actionFailure(arena, is_api, .{ .status = .forbidden, .code = "actions_disabled", .message = "actions are disabled (admin.actions is false); use the command line" }) };
        const form_target = try std.fmt.allocPrint(arena, "/?{s}", .{std.mem.trimEnd(u8, req.body, "\r\n")});
        const t = query.parseTarget(arena, form_target) catch return .{ .refused = try actionFailure(arena, is_api, .{ .status = .bad_request, .code = "bad_form", .message = "the form could not be read" }) };
        switch (auth) {
            .session => |s| {
                const presented = t.params.get("csrf") orelse "";
                if (presented.len != 32 or !std.crypto.timing_safe.eql([32]u8, s.csrf, presented[0..32].*)) {
                    return .{ .refused = try actionFailure(arena, is_api, .{ .status = .forbidden, .code = "bad_csrf", .message = "the request did not carry a valid form token" }) };
                }
            },
            else => {}, // a bearer token is not an ambient credential: no form token needed
        }
        return .{ .ok = t.params };
    }

    fn startImport(self: *App, arena: Allocator, req: server.Request, auth: Auth, is_api: bool) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, is_api)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const name = params.get("source") orelse "";
        self.opts.jobs.?.start(name) catch |e| return actionFailure(arena, is_api, switch (e) {
            error.UnknownSource => .{ .status = .not_found, .code = "unknown_source", .message = "no such source" },
            error.SourceDisabled => .{ .status = .conflict, .code = "source_disabled", .message = "that source is disabled in the configuration" },
            error.AlreadyRunning => .{ .status = .conflict, .code = "already_running", .message = "an import or other operation is already running" },
            error.LockHeld => .{ .status = .conflict, .code = "locked", .message = "another import, rebuild or removal is running on this data directory" },
            error.DataDirUnavailable => .{ .status = .internal_server_error, .code = "data_dir_unavailable", .message = "the data directory or its lock file cannot be used; see the server's error output" },
            error.OutOfMemory => return error.OutOfMemory,
            error.NoConcurrency => .{ .status = .service_unavailable, .code = "unavailable", .message = "cannot start a background task" },
            error.NotConfigured, error.BadArgument => .{ .status = .bad_request, .code = "bad_request", .message = "a source name is required" },
        });
        if (is_api) {
            var r = try handler.jsonResponse(arena, .accepted, .{ .started = name });
            r.status = .accepted;
            return r;
        }
        return redirect(arena, "/", null);
    }

    /// Starts a maintenance operation: check, backup or remove. Removal needs
    /// `confirm=yes` and, from the page, the source's name typed to confirm.
    fn startOperation(self: *App, arena: Allocator, req: server.Request, auth: Auth, is_api: bool) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, is_api)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const op_text = params.get("op") orelse "";
        const op: dk.jobs.Op = if (std.mem.eql(u8, op_text, "check")) .check else if (std.mem.eql(u8, op_text, "backup")) .backup else if (std.mem.eql(u8, op_text, "remove")) .remove else return actionFailure(arena, is_api, .{ .status = .bad_request, .code = "unknown_operation", .message = "op must be check, backup or remove" });
        const source = params.get("source") orelse "";
        if (op == .remove) {
            const typed = params.get("confirm") orelse "";
            // From the API `confirm=yes`; from the page the source name typed again.
            if (!std.mem.eql(u8, typed, "yes") and !(typed.len > 0 and std.mem.eql(u8, typed, source))) {
                return actionFailure(arena, is_api, .{ .status = .bad_request, .code = "confirmation_required", .message = "removing documents needs confirmation: send confirm=yes (or type the source name to confirm)" });
            }
        }
        self.opts.jobs.?.startOp(op, if (op == .check or op == .backup) null else source) catch |e| return actionFailure(arena, is_api, switch (e) {
            error.UnknownSource => .{ .status = .not_found, .code = "unknown_source", .message = "no such source" },
            error.SourceDisabled => .{ .status = .conflict, .code = "source_disabled", .message = "that source is disabled in the configuration" },
            error.NotConfigured => .{ .status = .conflict, .code = "not_configured", .message = "backups from the interface need a backup directory: set [admin] backup_dir" },
            error.BadArgument => .{ .status = .bad_request, .code = "bad_argument", .message = "a source name is required" },
            error.AlreadyRunning => .{ .status = .conflict, .code = "already_running", .message = "another operation is already running" },
            error.LockHeld => .{ .status = .conflict, .code = "locked", .message = "another import, rebuild or removal is running on this data directory" },
            error.DataDirUnavailable => .{ .status = .internal_server_error, .code = "data_dir_unavailable", .message = "the data directory or its lock file cannot be used; see the server's error output" },
            error.OutOfMemory => return error.OutOfMemory,
            error.NoConcurrency => .{ .status = .service_unavailable, .code = "unavailable", .message = "cannot start a background task" },
        });
        if (is_api) {
            var r = try handler.jsonResponse(arena, .accepted, .{ .started = op_text });
            r.status = .accepted;
            return r;
        }
        return redirect(arena, "/maintenance", null);
    }

    // --------------------------------------------------- editing sources

    fn spec_from(arena: Allocator, params: query.Params) error{OutOfMemory}!dk.sourceedit.Spec {
        const checked = struct {
            fn on(v: ?[]const u8) bool {
                const t = v orelse return false;
                return std.mem.eql(u8, t, "1") or std.mem.eql(u8, t, "on") or std.mem.eql(u8, t, "true");
            }
        }.on;
        return .{
            .name = params.get("name") orelse "",
            .kind = params.get("kind") orelse "",
            // An unchecked box sends nothing, so the form carries a hidden marker
            // saying the checkboxes were present; the API sends explicit values.
            .enabled = if (params.get("form") != null) checked(params.get("enabled")) else (if (params.get("enabled")) |v| checked(v) else true),
            .retain_text = if (params.get("form") != null) checked(params.get("retain_text")) else (if (params.get("retain_text")) |v| checked(v) else true),
            .rights = if (params.get("rights")) |r| (if (r.len > 0) r else null) else null,
            .boost = if (params.get("boost")) |b| (std.fmt.parseInt(u32, std.mem.trim(u8, b, " "), 10) catch 100) else 100,
            .schedule = if (params.get("schedule")) |sc| (if (std.mem.trim(u8, sc, " ").len > 0) std.mem.trim(u8, sc, " ") else null) else null,
            // The form posts one field per option (`opt_KEY`) and a box for any other settings; the
            // API (and older forms) send the settings as one text.
            .options = if (params.get("fields") != null)
                try dk.optioninfo.compose(arena, params.get("kind") orelse "", params, params.get("options") orelse "")
            else
                params.get("options") orelse "",
        };
    }

    /// Adds, replaces, enables/disables or deletes a `[[source]]` in the
    /// configuration file, validated as a whole, and applies it at once.
    fn editSources(self: *App, arena: Allocator, req: server.Request, auth: Auth, is_api: bool) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, is_api)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const path = self.opts.config_path orelse return actionFailure(arena, is_api, .{ .status = .conflict, .code = "no_config_file", .message = "the server was started without --config, so there is no configuration file to edit" });
        const store = self.opts.store orelse return actionFailure(arena, is_api, .{ .status = .conflict, .code = "no_config_file", .message = "editing sources is not available here" });

        const op = params.get("op") orelse "save";
        const spec = try spec_from(arena, params);
        const original: ?[]const u8 = if (params.get("original")) |o| (if (o.len > 0) o else null) else null;
        const edit: dk.sourceedit.Edit = if (std.mem.eql(u8, op, "save"))
            .{ .save = .{ .original = original, .spec = spec } }
        else if (std.mem.eql(u8, op, "delete"))
            .{ .delete = spec.name }
        else if (std.mem.eql(u8, op, "toggle"))
            .{ .set_enabled = .{ .name = spec.name, .enabled = if (params.get("enabled")) |v| std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") else false } }
        else
            return actionFailure(arena, is_api, .{ .status = .bad_request, .code = "unknown_operation", .message = "op must be save, delete or toggle" });

        self.edit_mutex.lockUncancelable(self.io);
        defer self.edit_mutex.unlock(self.io);

        // Always start from the file as it is now, so edits made by hand meanwhile are kept.
        const text = Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return actionFailure(arena, is_api, .{ .status = .internal_server_error, .code = "config_unreadable", .message = "cannot read the configuration file" }),
        };
        var problem: dk.sourceedit.Problem = .{};
        const new_text = dk.sourceedit.apply(arena, text, edit, &problem) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => {
                const msg = try arena.dupe(u8, problem.message());
                if (is_api or !std.mem.eql(u8, op, "save")) return actionFailure(arena, is_api, .{ .status = .bad_request, .code = "invalid_source", .message = msg });
                return self.renderSourceForm(arena, try csrfCopy(arena, auth), spec, original, msg, .bad_request);
            },
        };
        dk.sourceedit.writeFile(self.io, arena, path, new_text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Io => return actionFailure(arena, is_api, .{ .status = .internal_server_error, .code = "config_not_writable", .message = "the configuration file could not be written (check its permissions); nothing was changed" }),
        };
        // Make it current. The text was validated, so this cannot fail on content.
        var d: dk.config.Diagnostic = .{};
        const cfg = dk.config.loadFromSlice(self.gpa, path, new_text, &d) catch return actionFailure(arena, is_api, .{ .status = .internal_server_error, .code = "reload_failed", .message = "the file was saved but could not be reloaded; restart the server" });
        store.replace(cfg) catch return error.OutOfMemory;

        const done: []const u8 = if (std.mem.eql(u8, op, "delete")) "deleted" else if (std.mem.eql(u8, op, "toggle")) (if (spec_enabled_after(edit)) "enabled" else "disabled") else "saved";
        if (is_api) return handler.jsonResponse(arena, .ok, .{ .done = done, .name = spec.name });
        return redirect(arena, try std.fmt.allocPrint(arena, "/sources?done={s}", .{done}), null);
    }

    fn spec_enabled_after(edit: dk.sourceedit.Edit) bool {
        return switch (edit) {
            .set_enabled => |se| se.enabled,
            else => true,
        };
    }

    /// The session's form token, copied into `arena` (null for a bearer token).
    fn csrfCopy(arena: Allocator, auth: Auth) Allocator.Error!?[]const u8 {
        return switch (auth) {
            .session => |s| try arena.dupe(u8, &s.csrf),
            else => null,
        };
    }

    /// True when sources can be edited here: actions are on, a configuration
    /// file is known and the list is replaceable.
    // ------------------------------------------------------------ settings

    fn readConfigText(self: *App, arena: Allocator) ?[]const u8 {
        const path = self.opts.config_path orelse return null;
        return Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(16 * 1024 * 1024)) catch null;
    }

    fn pageSettings(self: *App, arena: Allocator, csrf: ?[]const u8, params: query.Params) error{OutOfMemory}!Response {
        return self.renderSettings(arena, csrf, params.get("done"), null, null, .ok);
    }

    /// The Settings page: every setting with its current value, editable when actions are on.
    /// `posted` (after a refused save) shows what was typed instead of what is in the file.
    fn renderSettings(self: *App, arena: Allocator, csrf: ?[]const u8, done: ?[]const u8, problem: ?[]const u8, posted: ?query.Params, status: http.Status) error{OutOfMemory}!Response {
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, "Settings", csrf, "settings") catch return error.OutOfMemory;
        const text = self.readConfigText(arena);
        const editable = self.canEditSources() and text != null;
        writeSettings(arena, w, csrf orelse "", text, editable, self.opts.config_path != null, done, problem, posted) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, status, aw.written());
    }

    fn saveSettings(self: *App, arena: Allocator, req: server.Request, auth: Auth) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, false)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const path = self.opts.config_path orelse return actionFailure(arena, false, .{ .status = .conflict, .code = "no_config_file", .message = "the server was started without --config, so there is no configuration file to edit" });
        if (!self.canEditSources()) return actionFailure(arena, false, .{ .status = .conflict, .code = "no_config_file", .message = "editing settings is not available here" });
        self.edit_mutex.lockUncancelable(self.io);
        defer self.edit_mutex.unlock(self.io);
        const text = Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "config_unreadable", .message = "cannot read the configuration file" }),
        };
        var problem: dk.sourceedit.Problem = .{};
        const changes = try dk.settinginfo.changes(arena, params);
        const new_text = dk.sourceedit.applySettings(arena, text, changes, &problem) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return self.renderSettings(arena, try csrfCopy(arena, auth), null, try arena.dupe(u8, problem.message()), params, .bad_request),
        };
        dk.sourceedit.writeFile(self.io, arena, path, new_text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Io => return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "config_not_writable", .message = "the configuration file could not be written (check its permissions); nothing was changed" }),
        };
        return redirect(arena, "/settings?done=saved", null);
    }

    fn canEditSources(self: *App) bool {
        return self.opts.jobs != null and self.opts.config_path != null and self.opts.store != null;
    }

    fn pageSources(self: *App, arena: Allocator, csrf: ?[]const u8, params: query.Params) error{OutOfMemory}!Response {
        const snap = self.snapshot(arena, 0);
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, "Sources", csrf, "sources") catch return error.OutOfMemory;
        writeSources(self, w, snap, csrf, params.get("done")) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, .ok, aw.written());
    }

    fn pageSourcesNew(self: *App, arena: Allocator, csrf: ?[]const u8) error{OutOfMemory}!Response {
        if (!self.canEditSources()) return handler.htmlError(arena, .conflict, "Not available", "Editing sources needs `admin.actions = true` and a server started with --config.");
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, "Add a source", csrf, "sources") catch return error.OutOfMemory;
        writeKindChooser(w) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, .ok, aw.written());
    }

    fn pageSourceEdit(self: *App, arena: Allocator, csrf: ?[]const u8, params: query.Params) error{OutOfMemory}!Response {
        if (!self.canEditSources()) return handler.htmlError(arena, .conflict, "Not available", "Editing sources needs `admin.actions = true` and a server started with --config.");
        var spec: dk.sourceedit.Spec = .{ .name = "", .kind = "" };
        var original: ?[]const u8 = null;
        const existing = params.get("name") orelse "";
        // No source and no kind chosen: the form would have nothing to ask, so offer the kinds.
        const kind_param: []const u8 = params.get("kind") orelse "";
        if (existing.len == 0 and kind_param.len == 0) return self.pageSourcesNew(arena, csrf);
        if (existing.len > 0) {
            const found = for (self.sources()) |src| {
                if (std.mem.eql(u8, src.name, existing)) break src;
            } else return handler.htmlError(arena, .not_found, "Not found", "No such source.");
            spec = .{
                .name = found.name,
                .kind = found.kind,
                .enabled = found.enabled,
                .retain_text = found.retain_text,
                .rights = if (found.rights) |r| @tagName(r) else null,
                .boost = found.boost,
                .schedule = found.schedule,
                .options = try dk.sourceedit.optionsText(arena, found),
            };
            original = found.name;
        } else if (params.get("kind")) |k| {
            // A new source of this kind: a working starting point to adjust.
            if (kindInfo(k)) |info| {
                spec = .{ .name = try suggestName(self, arena, k), .kind = info.kind, .options = info.template };
            }
        }
        return self.renderSourceForm(arena, csrf, spec, original, null, .ok);
    }

    fn renderSourceForm(self: *App, arena: Allocator, csrf: ?[]const u8, spec: dk.sourceedit.Spec, original: ?[]const u8, problem: ?[]const u8, status: http.Status) error{OutOfMemory}!Response {
        _ = self;
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, if (original != null) "Edit source" else "Add a source", csrf, "sources") catch return error.OutOfMemory;
        writeSourceForm(arena, w, csrf orelse "", spec, original, problem) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        var r = handler.htmlResponse(arena, status, aw.written());
        r.status = status;
        return r;
    }

    fn cancelImport(self: *App, arena: Allocator, req: server.Request, auth: Auth, is_api: bool) error{OutOfMemory}!Response {
        switch (try self.checkAction(arena, req, auth, is_api)) {
            .ok => {},
            .refused => |r| return r,
        }
        const was_running = self.opts.jobs.?.cancel();
        if (is_api) return handler.jsonResponse(arena, .ok, .{ .cancelling = was_running });
        return redirect(arena, "/", null);
    }

    fn apiImports(self: *App, arena: Allocator) error{OutOfMemory}!Response {
        const JsonLast = struct { op: []const u8, summary: ?[]const u8, source: []const u8, state: []const u8, submitted: u64, rejected: u64, skip_reasons: JsonReasons, failure: ?[]const u8, finished_at: i64 };
        const JsonRunning = struct { op: []const u8, source: []const u8, started_at: i64, submitted: u64, progress_done: u64, progress_total: u64 };
        var running: ?JsonRunning = null;
        var last: ?JsonLast = null;
        if (self.opts.jobs) |m| {
            if (try m.current(arena)) |c| running = .{ .op = @tagName(c.op), .source = c.source, .started_at = c.started_at, .submitted = c.submitted, .progress_done = c.progress_done, .progress_total = c.progress_total };
            if (try m.lastResult(arena)) |l| last = .{ .op = @tagName(l.op), .summary = l.summary, .source = l.source, .state = @tagName(l.state), .submitted = l.submitted, .rejected = l.rejected, .skip_reasons = jsonReasons(l.reasons), .failure = l.failure, .finished_at = l.finished_at };
        }
        return handler.jsonResponse(arena, .ok, .{ .actions = self.opts.jobs != null, .running = running, .last = last });
    }

    // ------------------------------------------------------- authentication

    const Loaded = struct { secrets: dk.secrets.Secrets, fingerprint: [32]u8 };

    /// Reads the secrets file afresh. Null if it cannot be read safely (then
    /// nothing authenticates).
    fn loadSecrets(self: *App) ?Loaded {
        const l = dk.secrets.loadFingerprinted(self.gpa, self.io, Io.Dir.cwd(), self.opts.secrets_path) catch return null;
        return .{ .secrets = l.secrets, .fingerprint = l.fingerprint };
    }

    fn authenticate(self: *App, arena: Allocator, req: server.Request) error{OutOfMemory}!Auth {
        _ = arena;
        var loaded = self.loadSecrets() orelse return .none;
        defer loaded.secrets.deinit(self.gpa);

        if (req.authorization) |h| {
            const prefix = "bearer ";
            if (h.len > prefix.len and std.ascii.eqlIgnoreCase(h[0..prefix.len], prefix)) {
                const presented = std.mem.trim(u8, h[prefix.len..], " ");
                if (loaded.secrets.verifyToken(presented)) return .token;
                // A wrong token is not counted or delayed: tokens have 256
                // bits, guessing is hopeless, and counting would let anyone
                // slow down the administrator's password sign-in.
                return .none;
            }
        }
        if (req.cookie) |c| if (cookieValue(c, cookie_name)) |id| {
            if (self.sessionFor(id, loaded.fingerprint)) |s| return .{ .session = s };
        };
        return .none;
    }

    fn sessionFor(self: *App, id: []const u8, fingerprint: [32]u8) ?Session {
        if (id.len != 64) return null;
        const now = self.nowNs();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.sessions) |*slot| {
            const s = slot.* orelse continue;
            if (!std.crypto.timing_safe.eql([64]u8, s.id, id[0..64].*)) continue;
            const idle = now - s.last_ns > @as(i96, self.opts.session_idle_ms) * std.time.ns_per_ms;
            const old = now - s.created_ns > @as(i96, self.opts.session_max_ms) * std.time.ns_per_ms;
            if (idle or old or !std.mem.eql(u8, &s.fingerprint, &fingerprint)) {
                slot.* = null;
                return null;
            }
            slot.*.?.last_ns = now;
            return slot.*.?;
        }
        return null;
    }

    fn newSession(self: *App, fingerprint: [32]u8) ?Session {
        var raw: [48]u8 = undefined;
        self.io.randomSecure(&raw) catch return null;
        defer std.crypto.secureZero(u8, &raw);
        const now = self.nowNs();
        var s: Session = .{ .id = undefined, .csrf = undefined, .created_ns = now, .last_ns = now, .fingerprint = fingerprint };
        s.id = std.fmt.bytesToHex(raw[0..32].*, .lower);
        s.csrf = std.fmt.bytesToHex(raw[32..48].*, .lower);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // A free slot, else the oldest session is replaced.
        var victim: usize = 0;
        for (self.sessions, 0..) |maybe, i| {
            if (maybe == null) {
                victim = i;
                break;
            }
            if (self.sessions[victim] == null or maybe.?.last_ns < self.sessions[victim].?.last_ns) victim = i;
        }
        self.sessions[victim] = s;
        return s;
    }

    fn dropSession(self: *App, id: []const u8) void {
        if (id.len != 64) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.sessions) |*slot| {
            if (slot.*) |s| if (std.mem.eql(u8, &s.id, id)) {
                slot.* = null;
            };
        }
    }

    /// Number of live sessions (for the dashboard).
    fn sessionCount(self: *App) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.sessions) |s| {
            if (s != null) n += 1;
        }
        return n;
    }

    // ------------------------------------------------------- brute-force slowing

    /// Wait before answering after `failures` consecutive failures: none for
    /// the first three, then 250 ms doubling up to 5 s.
    pub fn delayMs(failures: u32) u64 {
        if (failures <= 3) return 0;
        const shift: u6 = @intCast(@min(failures - 4, 20));
        return @min(max_delay_ms, @as(u64, 250) << shift);
    }

    fn noteFailure(self: *App) void {
        const now = self.nowNs();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (now - self.last_failure_ns > failure_memory_ns) self.failures = 0;
        self.failures +|= 1;
        self.last_failure_ns = now;
    }

    fn noteSuccess(self: *App) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.failures = 0;
    }

    /// Failures that still count: none once 15 quiet minutes have passed.
    fn effectiveFailures(self: *App) u32 {
        const now = self.nowNs();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (now - self.last_failure_ns > failure_memory_ns) self.failures = 0;
        return self.failures;
    }

    /// Makes the caller wait according to the recent failure count. Returns
    /// false, without waiting, if too many attempts are already waiting.
    fn penalty(self: *App) bool {
        const ms = delayMs(self.effectiveFailures());
        if (ms == 0 or self.skip_delay) return true;
        if (self.waiting.fetchAdd(1, .acq_rel) >= max_waiting) {
            _ = self.waiting.fetchSub(1, .acq_rel);
            return false;
        }
        defer _ = self.waiting.fetchSub(1, .acq_rel);
        self.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
        return true;
    }

    // ------------------------------------------------------------ login/logout

    fn postLogin(self: *App, arena: Allocator, req: server.Request) error{OutOfMemory}!Response {
        // The form body is parsed like a query string.
        // A trailing line break (from `curl --data-binary @file`) is not part of the form.
        const form_target = try std.fmt.allocPrint(arena, "/?{s}", .{std.mem.trimEnd(u8, req.body, "\r\n")});
        const t = query.parseTarget(arena, form_target) catch return renderLogin(arena, .bad_request, "The form could not be read.");
        const credential = t.params.get("credential") orelse "";
        if (credential.len == 0 or credential.len > max_credential_bytes) return self.loginFailed(arena);

        var loaded = self.loadSecrets() orelse return renderLogin(arena, .service_unavailable, "The credentials file cannot be read. See the server's error output.");
        defer loaded.secrets.deinit(self.gpa);

        // Slow down repeated failures first, without holding a verification slot.
        if (!self.penalty()) {
            var r = try renderLogin(arena, .too_many_requests, "Too many failed attempts. Wait a few seconds and try again.");
            r.headers = handler.headersWith(arena, &.{ handler.no_store, .{ .name = "retry-after", .value = "5" } });
            return r;
        }

        // Password checks are slow and memory-hungry on purpose: only a couple at once.
        if (self.verifying.fetchAdd(1, .acq_rel) >= max_verifications) {
            _ = self.verifying.fetchSub(1, .acq_rel);
            var r = try renderLogin(arena, .service_unavailable, "Too many sign-in attempts at once. Try again in a moment.");
            r.headers = handler.headersWith(arena, &.{ handler.no_store, .{ .name = "retry-after", .value = "2" } });
            return r;
        }
        defer _ = self.verifying.fetchSub(1, .acq_rel);

        const ok = loaded.secrets.verifyToken(credential) or loaded.secrets.verifyPassword(self.gpa, self.io, credential);
        if (!ok) return self.loginFailed(arena);

        self.noteSuccess();
        const s = self.newSession(loaded.fingerprint) orelse return renderLogin(arena, .internal_server_error, "Could not create a session.");
        const cookie = try std.fmt.allocPrint(arena, "{s}={s}; HttpOnly; SameSite=Strict; Path=/; Max-Age={d}{s}", .{
            cookie_name, s.id, self.opts.session_max_ms / 1000, if (self.opts.cookie_secure) "; Secure" else "",
        });
        return redirect(arena, "/", cookie);
    }

    fn loginFailed(self: *App, arena: Allocator) error{OutOfMemory}!Response {
        self.noteFailure();
        return renderLogin(arena, .unauthorized, "Those credentials were not accepted.");
    }

    fn postLogout(self: *App, arena: Allocator, req: server.Request) error{OutOfMemory}!Response {
        var loaded = self.loadSecrets() orelse return redirect(arena, "/login", null);
        defer loaded.secrets.deinit(self.gpa);
        const id = if (req.cookie) |c| cookieValue(c, cookie_name) else null;
        const s = if (id) |i| self.sessionFor(i, loaded.fingerprint) else null;
        if (s == null) return redirect(arena, "/login", null);

        const form_target = try std.fmt.allocPrint(arena, "/?{s}", .{req.body});
        const t = query.parseTarget(arena, form_target) catch return handler.htmlError(arena, .bad_request, "Bad request", "The form could not be read.");
        const presented = t.params.get("csrf") orelse "";
        if (presented.len != 32 or !std.crypto.timing_safe.eql([32]u8, s.?.csrf, presented[0..32].*)) {
            return handler.htmlError(arena, .forbidden, "Forbidden", "The request did not carry a valid form token.");
        }
        self.dropSession(id.?);
        const expired = try std.fmt.allocPrint(arena, "{s}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0{s}", .{ cookie_name, if (self.opts.cookie_secure) "; Secure" else "" });
        return redirect(arena, "/login", expired);
    }

    // ------------------------------------------------------------------ data

    const Snapshot = struct {
        /// The sources this snapshot describes (one list for the whole request).
        sources: []const dk.config.Source = &.{},
        counts: []const dk.state_sqlite.SqliteStateStore.SourceCount,
        jobs: []const dk.state_sqlite.Job,
        /// Last job per source, same order as `sources`.
        last: []const ?dk.state_sqlite.Job,
        sizes: [3]?u64,
    };

    /// Reads state.db read-only: safe while an import runs, never changes it.
    fn snapshot(self: *App, arena: Allocator, jobs_limit: u32) Snapshot {
        const srcs = self.sources();
        var snap: Snapshot = .{ .sources = srcs, .counts = &.{}, .jobs = &.{}, .last = &.{}, .sizes = .{ null, null, null } };
        const paths = [_][]const u8{ self.opts.index_path, self.opts.state_path, self.opts.content_path };
        for (paths, 0..) |p, i| {
            const st = Io.Dir.cwd().statFile(self.io, p, .{}) catch continue;
            snap.sizes[i] = st.size;
        }
        var state = dk.state_sqlite.SqliteStateStore.inspect(self.gpa, self.opts.state_path) catch return snap;
        defer state.close();
        snap.counts = state.countsBySource(arena) catch &.{};
        snap.jobs = state.recentJobs(arena, jobs_limit) catch &.{};
        const last = arena.alloc(?dk.state_sqlite.Job, srcs.len) catch return snap;
        for (srcs, last) |s, *out| out.* = (state.lastJob(arena, s.name) catch null);
        snap.last = last;
        return snap;
    }

    fn sources(self: *App) []const dk.config.Source {
        return if (self.opts.store) |st| st.snapshot() else self.opts.sources;
    }

    fn docsFor(snap: Snapshot, name: []const u8) u64 {
        for (snap.counts) |c| if (std.mem.eql(u8, c.source, name)) return c.documents;
        return 0;
    }

    fn uptimeSeconds(self: *App) i64 {
        const now: i64 = @intCast(@divFloor(Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
        return @max(now - self.started_unix, 0);
    }

    // ------------------------------------------------------------------ JSON

    const JsonJob = struct {
        id: i64,
        source: []const u8,
        kind: []const u8,
        state: []const u8,
        started_at: i64,
        finished_at: ?i64,
        submitted: u64,
        rejected: u64,
        skip_reasons: JsonReasons,
        error_message: ?[]const u8,
    };

    fn jsonJob(j: dk.state_sqlite.Job) JsonJob {
        const counts = if (j.reasons) |t| dk.connector.parseReasons(t) else @as(dk.connector.ReasonCounts, @splat(0));
        return .{ .id = j.id, .source = j.source, .kind = j.connector, .state = @tagName(j.state), .started_at = j.started_at, .finished_at = j.finished_at, .submitted = j.submitted, .rejected = j.rejected, .skip_reasons = jsonReasons(counts), .error_message = j.error_message };
    }

    /// Why items were skipped, one field per reason (all present, so clients
    /// can rely on the shape). The sum can be less than `rejected`: only some
    /// connectors say why.
    const JsonReasons = struct {
        robots: u64,
        network: u64,
        certificate: u64,
        http_status: u64,
        wrong_type: u64,
        too_large: u64,
        encoding: u64,
        no_text: u64,
        redirect: u64,
        limit: u64,
        unreadable: u64,
    };

    fn jsonReasons(c: dk.connector.ReasonCounts) JsonReasons {
        var out: JsonReasons = undefined;
        inline for (@typeInfo(JsonReasons).@"struct".field_names) |name| {
            @field(out, name) = c[@backingInt(@field(dk.connector.Reason, name))];
        }
        return out;
    }

    const JsonCounters = struct {
        requests: u64,
        status_2xx: u64,
        status_3xx: u64,
        status_4xx: u64,
        status_5xx: u64,
        latency_le_10ms: u64,
        latency_le_50ms: u64,
        latency_le_250ms: u64,
        latency_le_1000ms: u64,
        latency_over_1000ms: u64,
        connections_accepted: u64,
        connections_refused_busy: u64,
        connections_timed_out: u64,
    };

    fn counters(s: *const server.Stats) JsonCounters {
        const ld = struct {
            fn f(a: *const std.atomic.Value(u64)) u64 {
                return a.load(.monotonic);
            }
        }.f;
        return .{
            .requests = ld(&s.requests),
            .status_2xx = ld(&s.by_class[2]),
            .status_3xx = ld(&s.by_class[3]),
            .status_4xx = ld(&s.by_class[4]),
            .status_5xx = ld(&s.by_class[5]),
            .latency_le_10ms = ld(&s.latency[0]),
            .latency_le_50ms = ld(&s.latency[1]),
            .latency_le_250ms = ld(&s.latency[2]),
            .latency_le_1000ms = ld(&s.latency[3]),
            .latency_over_1000ms = ld(&s.latency[4]),
            .connections_accepted = ld(&s.accepted),
            .connections_refused_busy = ld(&s.refused_busy),
            .connections_timed_out = ld(&s.timed_out),
        };
    }

    fn apiStatus(self: *App, arena: Allocator) error{OutOfMemory}!Response {
        const snap = self.snapshot(arena, 0);
        var total: u64 = 0;
        for (snap.counts) |c| total += c.documents;
        var loaded = self.loadSecrets();
        defer if (loaded) |*l| l.secrets.deinit(self.gpa);
        return handler.jsonResponse(arena, .ok, .{
            .version = self.opts.version,
            .uptime_seconds = self.uptimeSeconds(),
            .actions = self.opts.jobs != null,
            .documents = total,
            .data_bytes = .{ .index = snap.sizes[0], .state = snap.sizes[1], .content = snap.sizes[2] },
            .auth = .{
                .token = if (loaded) |l| l.secrets.token_hash != null else false,
                .password = if (loaded) |l| l.secrets.password_hash != null else false,
                .sessions = self.sessionCount(),
            },
            .public = counters(self.opts.public_stats),
            .admin = counters(self.opts.admin_stats),
        });
    }

    fn apiSources(self: *App, arena: Allocator) error{OutOfMemory}!Response {
        const snap = self.snapshot(arena, 0);
        const Item = struct { name: []const u8, kind: []const u8, enabled: bool, configured: bool, documents: u64, last_job: ?JsonJob };
        var out: std.ArrayList(Item) = .empty;
        for (snap.sources, 0..) |s, i| {
            try out.append(arena, .{
                .name = s.name,
                .kind = s.kind,
                .enabled = s.enabled,
                .configured = true,
                .documents = docsFor(snap, s.name),
                .last_job = if (i < snap.last.len and snap.last[i] != null) jsonJob(snap.last[i].?) else null,
            });
        }
        // Documents under names the configuration no longer has.
        for (snap.counts) |c| {
            var known = false;
            for (snap.sources) |s| if (std.mem.eql(u8, s.name, c.source)) {
                known = true;
            };
            if (!known) try out.append(arena, .{ .name = c.source, .kind = "", .enabled = false, .configured = false, .documents = c.documents, .last_job = null });
        }
        return handler.jsonResponse(arena, .ok, .{ .sources = out.items });
    }

    fn apiJobs(self: *App, arena: Allocator) error{OutOfMemory}!Response {
        const snap = self.snapshot(arena, 50);
        const jobs = try arena.alloc(JsonJob, snap.jobs.len);
        for (snap.jobs, jobs) |j, *o| o.* = jsonJob(j);
        return handler.jsonResponse(arena, .ok, .{ .jobs = jobs });
    }

    // ------------------------------------------------------------------ HTML

    fn pageDashboard(self: *App, arena: Allocator, csrf: ?[]const u8) error{OutOfMemory}!Response {
        const snap = self.snapshot(arena, 0);
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, "Dashboard", csrf, "dashboard") catch return error.OutOfMemory;
        writeDashboard(self, arena, w, snap, csrf) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, .ok, aw.written());
    }

    fn pageMaintenance(self: *App, arena: Allocator, csrf: ?[]const u8) error{OutOfMemory}!Response {
        const snap = self.snapshot(arena, 1);
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, "Maintenance", csrf, "maintenance") catch return error.OutOfMemory;
        writeMaintenance(self, arena, w, snap, csrf) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, .ok, aw.written());
    }

    // ----------------------------------------------------- collections and API keys

    const NewKey = struct { name: []const u8, token: []const u8 };

    fn keysPath(self: *App, arena: Allocator) error{OutOfMemory}![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ self.opts.data_dir, dk.access.file_name });
    }

    fn pageAccess(self: *App, arena: Allocator, csrf: ?[]const u8, fresh: ?NewKey, notice: ?[]const u8) error{OutOfMemory}!Response {
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, "Access", csrf, "access") catch return error.OutOfMemory;
        if (notice) |n| {
            w.writeAll("<p class=\"notice\" role=\"status\">") catch return error.OutOfMemory;
            html.writeEscaped(w, n) catch return error.OutOfMemory;
            w.writeAll("</p>") catch return error.OutOfMemory;
        }
        self.writeAccess(arena, w, csrf, fresh) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        var r = handler.htmlResponse(arena, .ok, aw.written());
        r.headers = handler.headersWith(arena, &.{handler.no_store}); // a page that may show a new key is never cached
        return r;
    }

    fn writeAccess(self: *App, arena: Allocator, w: *Io.Writer, csrf: ?[]const u8, fresh: ?NewKey) !void {
        try w.writeAll("<p class=\"muted\">Who may see what. A <em>collection</em> is a named group of sources (written as <code>[[collection]]</code> in the configuration file); an <em>API key</em> lets a program see only the collections it was made for. Without keys, everyone can search everything unless <code>[access] anonymous_collections</code> says otherwise.</p>");
        if (fresh) |f| {
            try w.writeAll("<section class=\"card\"><h2>New key made</h2><p>Copy it now: it is shown only this once, and only its hash is kept. Key <strong>");
            try html.writeEscaped(w, f.name);
            try w.writeAll("</strong>:</p><p><code>");
            try html.writeEscaped(w, f.token);
            try w.writeAll("</code></p><p class=\"muted\">Send it as <code>Authorization: Bearer KEY</code>.</p></section>");
        }
        try w.writeAll("<section class=\"card\"><h2>Visitors without a key</h2><p>");
        if (self.opts.anonymous_collections) |names| {
            if (names.len == 0) {
                try w.writeAll("May see <strong>nothing</strong>: the API needs a key and the search page finds nothing.");
            } else {
                try w.writeAll("May see only the collections: ");
                for (names, 0..) |n, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll("<strong>");
                    try html.writeEscaped(w, n);
                    try w.writeAll("</strong>");
                }
                try w.writeAll(".");
            }
        } else try w.writeAll("May see <strong>every source</strong> (no limit is set).");
        try w.writeAll(" Change this with <code>[access]</code> in the configuration file (read at start).</p></section>");

        try self.writePeers(arena, w, csrf);
        try w.writeAll("<section class=\"card\"><h2>Collections</h2>");
        if (self.opts.collections.len == 0) {
            try w.writeAll("<p class=\"muted\">None defined. Add <code>[[collection]]</code> tables with <code>name</code>, an optional <code>description</code> and <code>sources = [...]</code> to the configuration file.</p>");
        } else {
            try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Name</th><th>Sources</th><th>Description</th><th></th></tr></thead><tbody>");
            for (self.opts.collections) |c| {
                try w.writeAll("<tr><td><strong>");
                try html.writeEscaped(w, c.name);
                try w.writeAll("</strong></td><td>");
                for (c.sources, 0..) |s, i| {
                    if (i > 0) try w.writeAll(", ");
                    try html.writeEscaped(w, s);
                }
                try w.writeAll("</td><td>");
                try html.writeEscaped(w, c.description);
                try w.writeAll("</td><td>");
                if (csrf) |token| if (self.canEditConfig()) {
                    try w.writeAll("<form class=\"inline\" action=\"/actions/collection-edit\" method=\"post\"><input type=\"hidden\" name=\"op\" value=\"delete\"><input type=\"hidden\" name=\"csrf\" value=\"");
                    try html.writeEscaped(w, token);
                    try w.writeAll("\"><input type=\"hidden\" name=\"name\" value=\"");
                    try html.writeEscaped(w, c.name);
                    try w.writeAll("\"><button type=\"submit\" class=\"btn danger\">Remove</button></form>");
                };
                try w.writeAll("</td></tr>");
            }
            try w.writeAll("</tbody></table></div>");
        }
        try self.writeCollectionForm(w, csrf);
        try w.writeAll("</section>");

        try w.writeAll("<section class=\"card\"><h2>API keys</h2>");
        const keys = dk.access.load(arena, self.io, Io.Dir.cwd(), try self.keysPath(arena)) catch |e| {
            try w.print("<p class=\"error\">The key file cannot be used ({t}); no key works until that is fixed (it must be readable by the owner only).</p></section>", .{e});
            return;
        };
        if (keys.len == 0) {
            try w.writeAll("<p class=\"muted\">No keys yet.</p>");
        } else {
            try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Number</th><th>Name</th><th>Collections</th><th>Limit</th><th>Made</th><th></th></tr></thead><tbody>");
            for (keys) |k| {
                try w.print("<tr><td><code>{s}</code></td><td>", .{k.id});
                try html.writeEscaped(w, k.name);
                try w.writeAll("</td><td>");
                for (k.collections, 0..) |c, i| {
                    if (i > 0) try w.writeAll(", ");
                    if (std.mem.eql(u8, c, dk.access.all_marker)) try w.writeAll("<em>everything</em>") else try html.writeEscaped(w, c);
                }
                try w.writeAll("</td><td>");
                if (k.rate > 0) try w.print("{d}/min", .{k.rate}) else try w.writeAll("<span class=\"muted\">none</span>");
                try w.writeAll("</td><td>");
                try writeTime(w, k.created);
                try w.writeAll("</td><td>");
                if (csrf) |token| {
                    try w.writeAll("<form class=\"inline\" action=\"/actions/key-remove\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
                    try html.writeEscaped(w, token);
                    try w.print("\"><input type=\"hidden\" name=\"which\" value=\"{s}\"><button type=\"submit\" class=\"btn danger\">Remove</button></form>", .{k.id});
                }
                try w.writeAll("</td></tr>");
            }
            try w.writeAll("</tbody></table></div>");
        }
        if (csrf != null and self.opts.jobs != null) {
            try w.writeAll("<h3>Make a key</h3><form class=\"stack\" action=\"/actions/key-add\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
            try html.writeEscaped(w, csrf.?);
            try w.writeAll("\"><label>Name <input name=\"name\" maxlength=\"64\" required placeholder=\"laptop\"><small>Only for you to recognise it.</small></label><fieldset><legend>May see</legend>");
            try w.writeAll("<label class=\"check\"><input type=\"checkbox\" name=\"all\" value=\"1\"> every source</label>");
            for (self.opts.collections) |c| {
                try w.writeAll("<label class=\"check\"><input type=\"checkbox\" name=\"collection\" value=\"");
                try html.writeEscaped(w, c.name);
                try w.writeAll("\"> ");
                try html.writeEscaped(w, c.name);
                try w.writeAll("</label>");
            }
            try w.writeAll("</fieldset><label>Requests per minute <input name=\"rate\" type=\"number\" min=\"0\" max=\"1000000\" value=\"0\"><small>0 is no limit. Over it, the key gets 429 until the minute ends.</small></label><p><button type=\"submit\" class=\"btn\">Make the key</button></p></form>");
        } else {
            try w.writeAll("<p class=\"muted\">Making and removing keys here needs <code>admin.actions = true</code> and a signed-in session; <code>dksearch api-key</code> works regardless.</p>");
        }
        try w.writeAll("</section>");
    }

    fn writePeers(self: *App, arena: Allocator, w: *Io.Writer, csrf: ?[]const u8) !void {
        try w.writeAll("<section class=\"card\"><h2>Peers</h2>");
        const svc = self.opts.peers orelse {
            try w.writeAll("<p class=\"muted\">No peers yet. Peers are other dksearch nodes you may ask (see the manual, <em>Peers and federated search</em>). They are saved in the configuration file and start working after a restart.</p>");
            try self.writePeerForm(w, csrf);
            try w.writeAll("</section>");
            return;
        };
        try w.writeAll("<p class=\"muted\">This node is <strong>");
        try html.writeEscaped(w, self.opts.node_name);
        try w.writeAll("</strong>. The search page and the API ask the peers when <code>peers=1</code> is given. Peers are set in the configuration file (read at start); <em>Test</em> asks a peer a small question now, which shows whether its address answers and it accepts the key. Changes made here are saved to the configuration file and apply after a restart.</p>");
        const infos = try svc.info(arena);
        try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Name</th><th>Address</th><th>Key</th><th>Last try</th><th>Last answered</th><th>Trouble</th><th></th></tr></thead><tbody>");
        const now = unixNow(self.io);
        for (infos) |p| {
            try w.writeAll("<tr><td><strong>");
            try html.writeEscaped(w, p.name);
            try w.writeAll("</strong>");
            if (!p.enabled) try w.writeAll(" <span class=\"muted\">(off)</span>");
            try w.writeAll("</td><td><code>");
            try html.writeEscaped(w, p.url);
            try w.print("</code></td><td>{s}</td><td>", .{if (p.has_key) "set" else "<span class=\"muted\">none</span>"});
            if (p.last_status) |st| {
                try w.print("{t} in {d} ms, ", .{ st, p.last_ms });
                try writeAgo(w, now - p.last_unix);
            } else try w.writeAll("<span class=\"muted\">not yet</span>");
            try w.writeAll("</td><td>");
            if (p.last_ok_unix > 0) try writeAgo(w, now - p.last_ok_unix) else try w.writeAll("<span class=\"muted\">never</span>");
            try w.writeAll("</td><td>");
            if (p.failures > 0) {
                try w.print("{d} in a row", .{p.failures});
                if (p.quiet_secs > 0) try w.print(", skipped for {d} s more", .{p.quiet_secs});
            } else try w.writeAll("<span class=\"muted\">none</span>");
            try w.writeAll("</td><td>");
            if (csrf) |token| {
                try w.writeAll("<form class=\"inline\" action=\"/actions/peer-test\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
                try html.writeEscaped(w, token);
                try w.writeAll("\"><input type=\"hidden\" name=\"peer\" value=\"");
                try html.writeEscaped(w, p.name);
                try w.writeAll("\"><button type=\"submit\" class=\"btn\">Test</button></form>");
                if (self.canEditConfig()) {
                    for ([_][3][]const u8{ .{ "toggle", if (p.enabled) "Turn off" else "Turn on", if (p.enabled) "0" else "1" }, .{ "delete", "Remove", "" } }) |b| {
                        try w.writeAll(" <form class=\"inline\" action=\"/actions/peer-edit\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
                        try html.writeEscaped(w, token);
                        try w.print("\"><input type=\"hidden\" name=\"op\" value=\"{s}\"><input type=\"hidden\" name=\"enabled\" value=\"{s}\"><input type=\"hidden\" name=\"name\" value=\"", .{ b[0], b[2] });
                        try html.writeEscaped(w, p.name);
                        try w.print("\"><button type=\"submit\" class=\"btn{s}\">{s}</button></form>", .{ if (std.mem.eql(u8, b[0], "delete")) " danger" else "", b[1] });
                    }
                }
            }
            try w.writeAll("</td></tr>");
        }
        try w.writeAll("</tbody></table></div>");
        try self.writePeerForm(w, csrf);
        try w.writeAll("</section>");
    }

    fn writeCollectionForm(self: *App, w: *Io.Writer, csrf: ?[]const u8) !void {
        if (csrf == null or !self.canEditConfig()) return;
        const store = self.opts.store orelse return;
        try w.writeAll("<h3>Add a collection</h3><form class=\"stack\" action=\"/actions/collection-edit\" method=\"post\"><input type=\"hidden\" name=\"op\" value=\"save\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.writeEscaped(w, csrf.?);
        try w.writeAll("\"><label>Name <input name=\"name\" maxlength=\"64\" required placeholder=\"books\"></label><label>Description <input name=\"description\" maxlength=\"200\"><small>Optional; shown as a hint.</small></label><fieldset><legend>Sources</legend>");
        for (store.snapshot()) |s| {
            try w.writeAll("<label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"");
            try html.writeEscaped(w, s.name);
            try w.writeAll("\"> ");
            try html.writeEscaped(w, s.name);
            try w.writeAll("</label>");
        }
        try w.writeAll("</fieldset><p class=\"muted\">Saved to the configuration file; applies after a restart.</p><p><button type=\"submit\" class=\"btn\">Add the collection</button></p></form>");
    }

    fn editCollection(self: *App, arena: Allocator, req: server.Request, auth: Auth) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, false)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const path = self.opts.config_path orelse return actionFailure(arena, false, .{ .status = .conflict, .code = "no_config_file", .message = "the server was started without --config, so there is no configuration file to edit" });
        if (!self.canEditConfig()) return actionFailure(arena, false, .{ .status = .conflict, .code = "no_config_file", .message = "editing collections is not available here" });
        const op = params.get("op") orelse "save";
        const name = std.mem.trim(u8, params.get("name") orelse "", " ");
        const edit: dk.sourceedit.CollectionEdit = if (std.mem.eql(u8, op, "save"))
            .{ .save = .{ .original = null, .spec = .{ .name = name, .description = std.mem.trim(u8, params.get("description") orelse "", " "), .sources = try params.all(arena, "source") } } }
        else if (std.mem.eql(u8, op, "delete"))
            .{ .delete = name }
        else
            return actionFailure(arena, false, .{ .status = .bad_request, .code = "unknown_operation", .message = "op must be save or delete" });
        self.edit_mutex.lockUncancelable(self.io);
        defer self.edit_mutex.unlock(self.io);
        const text = Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "config_unreadable", .message = "cannot read the configuration file" }),
        };
        const csrf = try csrfCopy(arena, auth);
        var problem: dk.sourceedit.Problem = .{};
        const new_text = dk.sourceedit.applyCollection(arena, text, edit, &problem) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return self.pageAccessWith(arena, csrf, try arena.dupe(u8, problem.message()), .bad_request),
        };
        dk.sourceedit.writeFile(self.io, arena, path, new_text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Io => return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "config_not_writable", .message = "the configuration file could not be written (check its permissions); nothing was changed" }),
        };
        return self.pageAccessWith(arena, csrf, "Saved to the configuration file. Restart dksearch for the change to take effect.", .ok);
    }

    fn canEditConfig(self: *App) bool {
        return self.opts.config_path != null and self.opts.jobs != null;
    }

    fn writePeerForm(self: *App, w: *Io.Writer, csrf: ?[]const u8) !void {
        if (csrf == null or !self.canEditConfig()) {
            try w.writeAll("<p class=\"muted\">Adding peers here needs <code>admin.actions = true</code> and a server started with <code>--config</code>; otherwise write <code>[[peer]]</code> tables in the configuration file.</p>");
            return;
        }
        try w.writeAll("<h3>Add a peer</h3><form class=\"stack\" action=\"/actions/peer-edit\" method=\"post\"><input type=\"hidden\" name=\"op\" value=\"save\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.writeEscaped(w, csrf.?);
        try w.writeAll("\"><label>This node's name <input name=\"node_name\" maxlength=\"64\" value=\"");
        try html.writeEscaped(w, self.opts.node_name);
        try w.writeAll("\" placeholder=\"home\"><small>Shown beside results other nodes get from here. Needed once.</small></label>");
        try w.writeAll("<label>Peer name <input name=\"name\" maxlength=\"64\" required placeholder=\"office\"></label>");
        try w.writeAll("<label>Address <input name=\"url\" maxlength=\"200\" required placeholder=\"https://search.example.org\"><small>The peer's address with no path.</small></label>");
        try w.writeAll("<label>Key file <input name=\"key_file\" maxlength=\"300\" placeholder=\"/etc/dksearch/office.key\"><small>A file on this server holding the key the peer made for you (<code>dksearch api-key add</code> on the peer), readable only by you. Keys are not typed here.</small></label>");
        try w.writeAll("<label>Time limit (ms) <input name=\"timeout_ms\" type=\"number\" min=\"100\" max=\"30000\" value=\"1500\"></label>");
        try w.writeAll("<p><button type=\"submit\" class=\"btn\">Add the peer</button></p></form>");
    }

    fn editPeer(self: *App, arena: Allocator, req: server.Request, auth: Auth) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, false)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const path = self.opts.config_path orelse return actionFailure(arena, false, .{ .status = .conflict, .code = "no_config_file", .message = "the server was started without --config, so there is no configuration file to edit" });
        if (!self.canEditConfig()) return actionFailure(arena, false, .{ .status = .conflict, .code = "no_config_file", .message = "editing peers is not available here" });
        const op = params.get("op") orelse "save";
        const name = std.mem.trim(u8, params.get("name") orelse "", " ");
        const edit: dk.sourceedit.PeerEdit = if (std.mem.eql(u8, op, "save")) blk: {
            const timeout = std.fmt.parseInt(u32, std.mem.trim(u8, params.get("timeout_ms") orelse "1500", " "), 10) catch 1500;
            const kf = std.mem.trim(u8, params.get("key_file") orelse "", " ");
            break :blk .{ .save = .{ .original = null, .spec = .{ .name = name, .url = std.mem.trim(u8, params.get("url") orelse "", " "), .key_file = if (kf.len > 0) kf else null, .timeout_ms = timeout } } };
        } else if (std.mem.eql(u8, op, "delete"))
            .{ .delete = name }
        else if (std.mem.eql(u8, op, "toggle"))
            .{ .set_enabled = .{ .name = name, .enabled = if (params.get("enabled")) |v| std.mem.eql(u8, v, "1") else false } }
        else
            return actionFailure(arena, false, .{ .status = .bad_request, .code = "unknown_operation", .message = "op must be save, delete or toggle" });

        self.edit_mutex.lockUncancelable(self.io);
        defer self.edit_mutex.unlock(self.io);
        const text = Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "config_unreadable", .message = "cannot read the configuration file" }),
        };
        const csrf = try csrfCopy(arena, auth);
        var problem: dk.sourceedit.Problem = .{};
        // The node name first, when one was typed that differs from the file's (a peer cannot be saved without one).
        var current = text;
        if (std.mem.eql(u8, op, "save")) {
            const nn = std.mem.trim(u8, params.get("node_name") orelse "", " ");
            if (nn.len > 0) {
                const have = try dk.sourceedit.settingText(arena, text, "node", "name");
                if (have == null or !std.mem.eql(u8, have.?, nn)) {
                    // Set without validating a half-done state: a node name alone is always valid.
                    current = dk.sourceedit.applySettings(arena, text, &.{.{ .table = "node", .key = "name", .value = .{ .string = nn } }}, &problem) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Invalid => return self.pageAccessWith(arena, csrf, try arena.dupe(u8, problem.message()), .bad_request),
                    };
                }
            }
        }
        const new_text = dk.sourceedit.applyPeer(arena, current, edit, &problem) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return self.pageAccessWith(arena, csrf, try arena.dupe(u8, problem.message()), .bad_request),
        };
        dk.sourceedit.writeFile(self.io, arena, path, new_text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Io => return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "config_not_writable", .message = "the configuration file could not be written (check its permissions); nothing was changed" }),
        };
        return self.pageAccessWith(arena, csrf, "Saved to the configuration file. Restart dksearch for the change to take effect.", .ok);
    }

    fn pageAccessWith(self: *App, arena: Allocator, csrf: ?[]const u8, notice: []const u8, status: http.Status) error{OutOfMemory}!Response {
        var r = try self.pageAccess(arena, csrf, null, notice);
        r.status = status;
        return r;
    }

    fn testPeer(self: *App, arena: Allocator, req: server.Request, auth: Auth) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, false)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const svc = self.opts.peers orelse return actionFailure(arena, false, .{ .status = .not_found, .code = "no_peers", .message = "no peers are configured" });
        const name = params.get("peer") orelse "";
        const r = svc.probe(arena, name) orelse return actionFailure(arena, false, .{ .status = .not_found, .code = "no_such_peer", .message = "no such peer" });
        const text = switch (r.status) {
            .ok => try std.fmt.allocPrint(arena, "{s}: answered in {d} ms and accepted the key (or needs none).", .{ name, r.ms }),
            .refused => try std.fmt.allocPrint(arena, "{s}: answered with status {d}: it does not accept this node's key (401 means the key is missing or invalid, 403 that it may not search).", .{ name, r.http_status }),
            .timeout => try std.fmt.allocPrint(arena, "{s}: no answer within the time limit.", .{name}),
            .down => try std.fmt.allocPrint(arena, "{s}: could not connect (check the address, the port and that the peer is running; for https, its certificate).", .{name}),
            .bad_answer => try std.fmt.allocPrint(arena, "{s}: answered, but not like a dksearch node.", .{name}),
            else => try std.fmt.allocPrint(arena, "{s}: not asked ({t}).", .{ name, r.status }),
        };
        const csrf: ?[]const u8 = switch (auth) {
            .session => |s| try arena.dupe(u8, &s.csrf),
            else => null,
        };
        return self.pageAccess(arena, csrf, null, text);
    }

    fn addKey(self: *App, arena: Allocator, req: server.Request, auth: Auth) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, false)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const name = std.mem.trim(u8, params.get("name") orelse "", " ");
        const all = params.get("all") != null;
        const rate = std.fmt.parseInt(u32, std.mem.trim(u8, params.get("rate") orelse "0", " "), 10) catch 0;
        const wanted = try params.all(arena, "collection");
        if (!all and wanted.len == 0) return actionFailure(arena, false, .{ .status = .bad_request, .code = "no_scope", .message = "tick every source or at least one collection" });
        if (all and wanted.len > 0) return actionFailure(arena, false, .{ .status = .bad_request, .code = "bad_scope", .message = "tick every source or collections, not both" });
        for (wanted) |c| {
            var known = false;
            for (self.opts.collections) |col| if (std.mem.eql(u8, col.name, c)) {
                known = true;
            };
            if (!known) return actionFailure(arena, false, .{ .status = .bad_request, .code = "unknown_collection", .message = "no such collection" });
        }
        const path = try self.keysPath(arena);
        const keys = dk.access.load(arena, self.io, Io.Dir.cwd(), path) catch return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "keys_unreadable", .message = "the key file cannot be read (it must be readable by its owner only)" });
        var tok: [dk.access.token_len]u8 = undefined;
        const chosen: []const []const u8 = if (all) &.{dk.access.all_marker} else wanted;
        const updated = dk.access.addRated(arena, self.io, keys, name, chosen, unixNow(self.io), rate, &tok) catch |e| return actionFailure(arena, false, switch (e) {
            error.Duplicate => .{ .status = .conflict, .code = "duplicate", .message = "a key with that name already exists" },
            error.BadName => .{ .status = .bad_request, .code = "bad_name", .message = "the name must be 1 to 64 printable characters without quotes" },
            error.TooMany => .{ .status = .conflict, .code = "too_many", .message = "too many keys" },
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .status = .internal_server_error, .code = "key_failed", .message = "the key could not be made" },
        });
        dk.access.save(arena, self.io, Io.Dir.cwd(), path, updated) catch return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "write_failed", .message = "the key file could not be written" });
        const csrf: ?[]const u8 = switch (auth) {
            .session => |s| try arena.dupe(u8, &s.csrf),
            else => null,
        };
        return self.pageAccess(arena, csrf, .{ .name = name, .token = try arena.dupe(u8, &tok) }, null);
    }

    fn removeKey(self: *App, arena: Allocator, req: server.Request, auth: Auth) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, false)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const which = params.get("which") orelse "";
        const path = try self.keysPath(arena);
        const keys = dk.access.load(arena, self.io, Io.Dir.cwd(), path) catch return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "keys_unreadable", .message = "the key file cannot be read" });
        const left = (try dk.access.remove(arena, keys, which)) orelse return actionFailure(arena, false, .{ .status = .not_found, .code = "no_such_key", .message = "no such key" });
        dk.access.save(arena, self.io, Io.Dir.cwd(), path, left) catch return actionFailure(arena, false, .{ .status = .internal_server_error, .code = "write_failed", .message = "the key file could not be written" });
        return redirect(arena, "/access", null);
    }

    // ----------------------------------------------------- Kiwix library

    /// A Metalink address must be on kiwix.org (or, in tests, whatever `kiwix_options` allows).
    fn kiwixUrlOk(self: *App, url: []const u8) bool {
        if (self.opts.kiwix_options.allow_http) return std.mem.startsWith(u8, url, "http://127.0.0.1:");
        const prefix = "https://";
        if (!std.mem.startsWith(u8, url, prefix)) return false;
        const rest = url[prefix.len..];
        const host_end = std.mem.indexOfAny(u8, rest, "/?#@:") orelse rest.len;
        if (host_end >= rest.len or rest[host_end] != '/') return false;
        const host = rest[0..host_end];
        return std.mem.eql(u8, host, "kiwix.org") or std.mem.endsWith(u8, host, ".kiwix.org");
    }

    fn pageZim(self: *App, arena: Allocator, csrf: ?[]const u8, params: query.Params) error{OutOfMemory}!Response {
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, "ZIM files", csrf, "zim") catch return error.OutOfMemory;
        self.writeZim(arena, w, csrf, params) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, .ok, aw.written());
    }

    fn writeZim(self: *App, arena: Allocator, w: *Io.Writer, csrf: ?[]const u8, params: query.Params) !void {
        const zim_dir = if (self.opts.jobs) |m| m.opts.zim_dir else null;
        try w.writeAll("<p class=\"muted\">Search the <a href=\"https://library.kiwix.org\">Kiwix library</a> of offline copies of Wikipedia, Wiktionary, Stack Exchange sites, books and more, and download a file to index. This page contacts <code>library.kiwix.org</code> only when you search here; nothing is downloaded without your confirmation.</p>");
        const dir = zim_dir orelse {
            try w.writeAll("<section class=\"card\"><h2>Not set up</h2><p class=\"muted\">Downloads need a folder to put the files in: add <code>zim_dir = \"/path/to/zim\"</code> to the <code>[admin]</code> table of the configuration (a folder you control and that has room for the files; the interface writes nowhere else) and enable <code>actions</code>, then restart.</p></section>");
            return;
        };

        // The confirmation for one file.
        if (params.get("file")) |file| {
            const meta4 = params.get("meta4") orelse "";
            const size = std.fmt.parseInt(u64, params.get("size") orelse "0", 10) catch 0;
            if (!dk.kiwix.validFileName(file) or !self.kiwixUrlOk(meta4)) {
                try w.writeAll("<p class=\"error\">That file cannot be downloaded from here.</p>");
                return;
            }
            try w.writeAll("<section class=\"card\"><h2>Download this file?</h2><dl class=\"facts\"><div><dt>File</dt><dd><code>");
            try html.writeEscaped(w, file);
            try w.writeAll("</code></dd></div><div><dt>Size</dt><dd>");
            try writeBytes(w, size);
            try w.writeAll("</dd></div><div><dt>Saved to</dt><dd><code>");
            try html.writeEscaped(w, dir);
            try w.writeAll("</code></dd></div></dl><p class=\"muted\">Check that the folder has room for it. The file is fetched from the library&rsquo;s mirrors over HTTPS, checked against the checksum the library publishes, and only then given its name; an interrupted download continues where it stopped. Only one task runs at a time, and imports can run meanwhile elsewhere.</p>");
            if (csrf) |token| {
                try w.writeAll("<form action=\"/actions/zim\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
                try html.writeEscaped(w, token);
                try w.writeAll("\"><input type=\"hidden\" name=\"file\" value=\"");
                try html.writeEscaped(w, file);
                try w.writeAll("\"><input type=\"hidden\" name=\"meta4\" value=\"");
                try html.writeEscaped(w, meta4);
                try w.print("\"><input type=\"hidden\" name=\"size\" value=\"{d}\"><button type=\"submit\" class=\"btn\">Download</button> <a href=\"/zim\">Cancel</a></form>", .{size});
            }
            try w.writeAll("</section>");
            return;
        }

        const q = params.get("q") orelse "";
        const lang = params.get("lang") orelse "eng";
        const start = std.fmt.parseInt(u32, params.get("start") orelse "0", 10) catch 0;
        try w.writeAll("<form class=\"inline\" action=\"/zim\" method=\"get\"><input type=\"search\" name=\"q\" maxlength=\"100\" aria-label=\"Search the library\" placeholder=\"wikipedia, chemistry, ...\" value=\"");
        try html.writeEscaped(w, q);
        try w.writeAll("\"> <input type=\"text\" name=\"lang\" maxlength=\"3\" size=\"4\" aria-label=\"Language (three letters)\" value=\"");
        try html.writeEscaped(w, lang);
        try w.writeAll("\"> <button type=\"submit\" class=\"btn\">Search</button></form>");
        if (q.len == 0 and params.get("go") == null) {
            try w.writeAll("<p class=\"muted\">Type what you are looking for (for example <code>wikipedia</code>, <code>mini</code> for short versions, <code>nopic</code> for text only) and a language code such as <code>eng</code>; leave the language empty for all.</p>");
            return;
        }
        var url_aw: Io.Writer.Allocating = .init(arena);
        const uw = &url_aw.writer;
        try uw.print("{s}?count=25&start={d}", .{ self.opts.kiwix_catalog_url, start });
        if (lang.len > 0) {
            try uw.writeAll("&lang=");
            try query.writeEncoded(uw, lang);
        }
        if (q.len > 0) {
            try uw.writeAll("&q=");
            try query.writeEncoded(uw, q);
        }
        const bytes = dk.kiwix.fetchText(self.gpa, self.io, arena, url_aw.written(), 4 * 1024 * 1024, self.opts.kiwix_options) catch {
            try w.writeAll("<p class=\"error\">The library could not be reached or gave an answer that cannot be read. Try again in a moment.</p>");
            return;
        };
        const cat = dk.kiwix.parseCatalog(arena, bytes) catch {
            try w.writeAll("<p class=\"error\">The library&rsquo;s answer could not be read.</p>");
            return;
        };
        try w.print("<p class=\"muted\">{d} matching files; showing {d}&ndash;{d}.</p>", .{ cat.total, @min(start + 1, cat.total), start + cat.entries.len });
        try w.writeAll("<table><thead><tr><th>Title</th><th>Language</th><th>Kind</th><th>Articles</th><th>Size</th><th>Made</th><th></th></tr></thead><tbody>");
        for (cat.entries) |e| {
            const file = e.fileName() orelse continue;
            try w.writeAll("<tr><td><strong>");
            try html.writeEscaped(w, e.title);
            try w.writeAll("</strong><br><span class=\"muted\">");
            try html.writeEscaped(w, e.summary);
            try w.writeAll("</span></td><td>");
            try html.writeEscaped(w, e.language);
            try w.writeAll("</td><td>");
            try html.writeEscaped(w, e.flavour);
            try w.print("</td><td>{d}</td><td>", .{e.article_count});
            try writeBytes(w, e.size);
            try w.writeAll("</td><td>");
            try html.writeEscaped(w, e.issued[0..@min(10, e.issued.len)]);
            try w.writeAll("</td><td><a href=\"/zim?file=");
            try query.writeEncoded(w, file);
            try w.writeAll("&amp;meta4=");
            try query.writeEncoded(w, e.meta4_url);
            try w.print("&amp;size={d}\">Download&hellip;</a></td></tr>", .{e.size});
        }
        try w.writeAll("</tbody></table>");
        if (start + cat.entries.len < cat.total) {
            try w.print("<p><a href=\"/zim?q=", .{});
            try query.writeEncoded(w, q);
            try w.writeAll("&amp;lang=");
            try query.writeEncoded(w, lang);
            try w.print("&amp;go=1&amp;start={d}\">More results</a></p>", .{start + cat.entries.len});
        }
    }

    fn startZimDownload(self: *App, arena: Allocator, req: server.Request, auth: Auth) error{OutOfMemory}!Response {
        const params = switch (try self.checkAction(arena, req, auth, false)) {
            .ok => |p| p,
            .refused => |r| return r,
        };
        const file = params.get("file") orelse "";
        const meta4 = params.get("meta4") orelse "";
        const size = std.fmt.parseInt(u64, params.get("size") orelse "0", 10) catch 0;
        if (!self.kiwixUrlOk(meta4)) return actionFailure(arena, false, .{ .status = .bad_request, .code = "bad_address", .message = "downloads only come from the Kiwix library (kiwix.org)" });
        self.opts.jobs.?.startDownload(.{ .meta4_url = meta4, .file_name = file, .size = size }) catch |e| return actionFailure(arena, false, switch (e) {
            error.NotConfigured => .{ .status = .conflict, .code = "not_configured", .message = "downloads need a folder: set [admin] zim_dir" },
            error.BadArgument => .{ .status = .bad_request, .code = "bad_argument", .message = "that file name or address cannot be used" },
            error.AlreadyRunning => .{ .status = .conflict, .code = "already_running", .message = "another operation is already running" },
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .status = .service_unavailable, .code = "unavailable", .message = "cannot start the download" },
        });
        return redirect(arena, "/", null);
    }

    /// Examples of what one job skipped (a few per reason), from state.db.
    fn skipsFor(self: *App, arena: Allocator, params: query.Params) error{ OutOfMemory, BadJob, Unavailable }!struct { job: i64, skips: []const dk.connector.Sample } {
        const job = std.fmt.parseInt(i64, params.get("job") orelse "", 10) catch return error.BadJob;
        var state = dk.state_sqlite.SqliteStateStore.inspect(self.gpa, self.opts.state_path) catch return error.Unavailable;
        defer state.close();
        const skips = state.skipsOf(arena, job) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unavailable,
        };
        return .{ .job = job, .skips = skips };
    }

    fn pageSkipped(self: *App, arena: Allocator, csrf: ?[]const u8, params: query.Params) error{OutOfMemory}!Response {
        const got = self.skipsFor(arena, params) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.BadJob => handler.htmlError(arena, .bad_request, "Bad request", "job must be a job number."),
            error.Unavailable => handler.htmlError(arena, .service_unavailable, "Unavailable", "The job records cannot be read now."),
        };
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, "Skipped items", csrf, "jobs") catch return error.OutOfMemory;
        writeSkipped(w, got.job, got.skips) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, .ok, aw.written());
    }

    fn apiSkipped(self: *App, arena: Allocator, params: query.Params) error{OutOfMemory}!Response {
        const got = self.skipsFor(arena, params) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.BadJob => handler.apiError(arena, .bad_request, "invalid_parameter", "job: must be a job number"),
            error.Unavailable => handler.apiError(arena, .service_unavailable, "unavailable", "the job records cannot be read now"),
        };
        return handler.jsonResponse(arena, .ok, .{ .job = got.job, .skipped = got.skips });
    }

    fn pageJobs(self: *App, arena: Allocator, csrf: ?[]const u8) error{OutOfMemory}!Response {
        const snap = self.snapshot(arena, 50);
        var aw: Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        writePage(w, "Jobs", csrf, "jobs") catch return error.OutOfMemory;
        writeJobs(w, snap.jobs) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, .ok, aw.written());
    }
};

// ---------------------------------------------------------------- helpers

fn methodNotAllowed(arena: Allocator, is_api: bool, allow: []const u8) error{OutOfMemory}!Response {
    var r = if (is_api)
        try handler.apiError(arena, .method_not_allowed, "method_not_allowed", "method not allowed")
    else
        try handler.htmlError(arena, .method_not_allowed, "Method not allowed", "That method is not allowed here.");
    r.headers = handler.headersWith(arena, &.{ .{ .name = "allow", .value = allow }, handler.no_store });
    return r;
}

fn redirect(arena: Allocator, location: []const u8, set_cookie: ?[]const u8) error{OutOfMemory}!Response {
    const extra: []const Header = if (set_cookie) |c|
        &.{ .{ .name = "location", .value = location }, .{ .name = "set-cookie", .value = c }, handler.no_store }
    else
        &.{ .{ .name = "location", .value = location }, handler.no_store };
    return .{ .status = .see_other, .content_type = "text/plain; charset=utf-8", .body = "", .headers = handler.headersWith(arena, extra) };
}

/// The value of cookie `name` in a `Cookie` header, if present.
pub fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len > name.len and std.mem.startsWith(u8, p, name) and p[name.len] == '=') return p[name.len + 1 ..];
    }
    return null;
}

fn renderLogin(arena: Allocator, status: http.Status, notice: ?[]const u8) error{OutOfMemory}!Response {
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    html.writeHead(w, "dksearch administration") catch return error.OutOfMemory;
    w.writeAll("<body class=\"home admin\"><main><h1 class=\"brand\">dksearch administration</h1>\n" ++
        "<form class=\"search\" action=\"/login\" method=\"post\" autocomplete=\"off\">" ++
        "<input type=\"password\" name=\"credential\" maxlength=\"1024\" aria-label=\"Password or token\" placeholder=\"Password or token\" autofocus required>" ++
        "<button type=\"submit\">Sign in</button></form>\n") catch return error.OutOfMemory;
    if (notice) |n| {
        w.writeAll("<p class=\"error\" role=\"alert\">") catch return error.OutOfMemory;
        html.writeEscaped(w, n) catch return error.OutOfMemory;
        w.writeAll("</p>") catch return error.OutOfMemory;
    }
    w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
    return handler.htmlResponse(arena, status, aw.written());
}

/// The pages of the interface, in navigation order: key, path, label.
const nav_items = [_]struct { []const u8, []const u8, []const u8 }{
    .{ "dashboard", "/", "Dashboard" },
    .{ "sources", "/sources", "Sources" },
    .{ "jobs", "/jobs", "Jobs" },
    .{ "settings", "/settings", "Settings" },
    .{ "maintenance", "/maintenance", "Maintenance" },
    .{ "zim", "/zim", "ZIM files" },
    .{ "access", "/access", "Access" },
    .{ "search", "/search", "Search test" },
};

fn writePage(w: *Io.Writer, title: []const u8, csrf: ?[]const u8, current: []const u8) Io.Writer.Error!void {
    var tbuf: [96]u8 = undefined;
    try html.writeHead(w, std.fmt.bufPrint(&tbuf, "{s} - dksearch administration", .{title}) catch title);
    try w.writeAll("<body class=\"admin\"><header class=\"adminbar\"><div class=\"adminbar-inner\"><a class=\"logo\" href=\"/\">dksearch <small>administration</small></a><nav aria-label=\"Sections\">");
    for (nav_items) |n| {
        try w.print("<a href=\"{s}\"{s}>{s}</a>", .{ n[1], if (std.mem.eql(u8, n[0], current)) " aria-current=\"page\"" else "", n[2] });
    }
    try w.writeAll("</nav><span class=\"grow\"></span>");
    if (csrf) |token| {
        try w.writeAll("<form action=\"/logout\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.writeEscaped(w, token);
        try w.writeAll("\"><button type=\"submit\" class=\"btn secondary\">Sign out</button></form>");
    }
    try w.print("</div></header><main><script src=\"/assets/admin.js?v={s}\" defer></script><h1>{s}</h1>\n", .{ admin_js_version, title });
}

fn writeSearchTest(app: *App, arena: Allocator, w: *Io.Writer, searcher: dk.search.Searcher, q: dk.search.Query, rx: handler.RegexParams) !void {
    try w.writeAll("<form class=\"search\" action=\"/search\" method=\"get\"><input type=\"search\" name=\"q\" maxlength=\"1024\" aria-label=\"Query\" autofocus value=\"");
    try html.writeEscaped(w, q.text);
    try w.writeAll("\"><button type=\"submit\">Run query</button>");
    if (app.opts.regex != null) {
        const pattern = switch (rx) {
            .ok => |r| r.pattern,
            else => "",
        };
        const icase = switch (rx) {
            .ok => |r| r.ignore_case,
            else => false,
        };
        try w.writeAll("<details open><summary>Regex</summary><label>Pattern <input name=\"regex\" maxlength=\"2000\" spellcheck=\"false\" value=\"");
        try html.writeEscaped(w, pattern);
        try w.writeAll("\"></label><label><input type=\"checkbox\" name=\"regex_flags\" value=\"i\"");
        if (icase) try w.writeAll(" checked");
        try w.writeAll("> ignore case</label></details>");
    }
    try w.writeAll("</form>\n");
    try w.print("<p class=\"muted\">Runs the same search as the public page and shows the ranking score of each result (higher is better; a match in the title counts ten times a match in the text; tokenizer: {s}). The search syntax works here as on the public page: quotes, OR, NOT, filters such as <code>ext:pdf</code>, and <code>re:/pattern/</code> for a regular expression.</p>\n", .{app.opts.tokenizer});
    const applied = try handler.applyToken(arena, q, rx);
    const q_run = applied.q;
    const rx_run = applied.rx;
    if (q_run.text.len == 0 and rx_run != .ok) return;
    var examined: ?struct { n: u32, truncated: bool } = null;
    const page = blk: {
        switch (rx_run) {
            .none => {},
            .bad => |b| {
                try w.writeAll("<p class=\"error\" role=\"alert\">");
                try html.writeEscaped(w, b.message);
                try w.writeAll("</p>\n");
                return;
            },
            .ok => |req| switch (try handler.regexSearch(arena, searcher, app.opts.regex, q_run, req)) {
                .ok => |r| {
                    examined = .{ .n = r.examined, .truncated = r.truncated };
                    break :blk r.page;
                },
                .failed => |n| {
                    try w.writeAll("<p class=\"error\" role=\"alert\">");
                    try html.writeEscaped(w, n.message);
                    try w.writeAll("</p>\n");
                    return;
                },
            },
        }
        break :blk searcher.search(arena, q_run) catch |e| {
            try w.writeAll("<p class=\"error\" role=\"alert\">");
            try html.writeEscaped(w, switch (e) {
                error.EmptyQuery => "The query has no searchable terms.",
                error.InvalidQuery => "The query is not valid (too long or too many terms).",
                error.Timeout => "The search took too long (see [search] query_timeout_ms); try more specific words.",
                else => "The search failed; see the server's error output.",
            });
            try w.writeAll("</p>\n");
            return;
        };
    };
    if (examined) |e| try w.print("<p class=\"muted\">Regex checked {d} candidate document(s){s}.</p>\n", .{ e.n, if (e.truncated) "; a limit was reached, so more matches may exist" else "" });
    if (page.hits.len == 0) return w.writeAll("<p>No results.</p>\n");
    try w.print("<p class=\"muted\">{d} result(s){s}.</p>\n", .{ page.hits.len, if (page.has_more) ", more exist" else "" });
    try w.writeAll("<table><thead><tr><th>#</th><th>Score</th><th>Title</th><th>Source</th><th>Kind</th><th>Size</th><th>Modified</th><th>Id</th></tr></thead><tbody>\n");
    for (page.hits, 1..) |h, i| {
        try w.print("<tr><td>{d}</td><td>{d:.4}</td><td>", .{ i, h.score });
        const title = h.title orelse "(untitled)";
        if (h.url) |u| if (html.isLinkable(u)) {
            try w.writeAll("<a href=\"");
            try html.writeEscaped(w, u);
            try w.writeAll("\" rel=\"noreferrer\">");
            try html.writeEscaped(w, title);
            try w.writeAll("</a>");
        } else try html.writeEscaped(w, title) else try html.writeEscaped(w, title);
        try w.writeAll("</td><td>");
        try html.writeEscaped(w, h.connector);
        try w.writeAll("</td><td>");
        if (h.kind) |k| try html.writeEscaped(w, k);
        try w.writeAll("</td><td>");
        if (h.size) |n| try html.writeSize(w, n);
        try w.writeAll("</td><td>");
        if (h.modified_at) |t| try html.writeDate(w, t);
        try w.print("</td><td><code>{x}</code></td></tr>\n", .{h.id});
        if (h.snippet) |sn| {
            try w.writeAll("<tr><td></td><td colspan=\"7\" class=\"muted\">");
            try html.writeSnippet(w, sn);
            try w.writeAll("</td></tr>\n");
        }
    }
    try w.writeAll("</tbody></table>\n");
}

/// "2026-11-14 10:20:30 UTC".
fn writeTime(w: *Io.Writer, unix: i64) Io.Writer.Error!void {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(unix, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ day.year, @backingInt(md.month), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

fn writeBytes(w: *Io.Writer, n: ?u64) Io.Writer.Error!void {
    const v = n orelse return w.writeAll("&mdash;");
    if (v >= 1 << 30) return w.print("{d:.1} GiB", .{@as(f64, @floatFromInt(v)) / (1 << 30)});
    if (v >= 1 << 20) return w.print("{d:.1} MiB", .{@as(f64, @floatFromInt(v)) / (1 << 20)});
    if (v >= 1 << 10) return w.print("{d:.1} KiB", .{@as(f64, @floatFromInt(v)) / (1 << 10)});
    try w.print("{d} B", .{v});
}

fn badgeClass(state: dk.state_sqlite.JobState) []const u8 {
    return switch (state) {
        .completed => "ok",
        .failed => "err",
        .running => "run",
        .cancelled, .interrupted => "warn",
    };
}

fn writeBadge(w: *Io.Writer, state: dk.state_sqlite.JobState) Io.Writer.Error!void {
    try w.print("<span class=\"badge {s}\">{s}</span>", .{ badgeClass(state), @tagName(state) });
}

fn writeJobCells(w: *Io.Writer, j: dk.state_sqlite.Job) Io.Writer.Error!void {
    try w.writeAll("<td>");
    try writeBadge(w, j.state);
    try w.writeAll("</td><td>");
    try writeTime(w, j.started_at);
    try w.print("</td><td class=\"num\">{d}</td><td class=\"num\">", .{j.submitted});
    if (j.rejected > 0) try w.print("<a href=\"/jobs/skipped?job={d}\">{d}</a>", .{ j.id, j.rejected }) else try w.writeAll("0");
    if (j.reasons) |t| {
        // Our own "reason=count" text, never connector- or site-supplied.
        try w.print(" <span class=\"muted\">({s})</span>", .{t});
    }
    try w.writeAll("</td>");
}

/// "3 d 4 h", "2 h 5 min", "45 s".
fn writeDuration(w: *Io.Writer, seconds: u64) Io.Writer.Error!void {
    const d = seconds / 86400;
    const h = (seconds % 86400) / 3600;
    const m = (seconds % 3600) / 60;
    if (d > 0) return w.print("{d} d {d} h", .{ d, h });
    if (h > 0) return w.print("{d} h {d} min", .{ h, m });
    if (m > 0) return w.print("{d} min {d} s", .{ m, seconds % 60 });
    try w.print("{d} s", .{seconds});
}

/// "5 min ago", "just now".
fn writeAgo(w: *Io.Writer, seconds: i64) Io.Writer.Error!void {
    if (seconds < 5) return w.writeAll("just now");
    try writeDuration(w, @intCast(seconds));
    try w.writeAll(" ago");
}

fn writeStat(w: *Io.Writer, value: []const u8, label: []const u8) Io.Writer.Error!void {
    try w.print("<div class=\"stat\"><span class=\"stat-n\">{s}</span><span class=\"stat-l\">{s}</span></div>", .{ value, label });
}

fn writeImportsPanel(app: *App, arena: Allocator, w: *Io.Writer, csrf: ?[]const u8) !void {
    const m = app.opts.jobs orelse {
        try w.writeAll("<section class=\"card\"><h2>Imports</h2><p class=\"muted\">Starting imports from here is turned off (<code>admin.actions</code> is false). Use <code>dksearch import</code> on the command line.</p></section>\n");
        return;
    };
    if (try m.current(arena)) |c| {
        try w.writeAll("<section class=\"card running\" id=\"import-live\" data-running=\"1\"><h2>");
        switch (c.op) {
            .import => try w.writeAll("Importing "),
            .check => try w.writeAll("Checking the stored data"),
            .backup => try w.writeAll("Backing up"),
            .remove => try w.writeAll("Removing "),
            .download => try w.writeAll("Downloading "),
        }
        if (c.op == .import or c.op == .remove or c.op == .download) {
            try w.writeAll("<strong>");
            try html.writeEscaped(w, c.source);
            try w.writeAll("</strong>");
        }
        try w.writeAll("</h2>");
        if (c.progress_total > 0) {
            try w.print("<progress id=\"import-bar\" max=\"{d}\" value=\"{d}\"></progress> <span data-f=\"percent\" class=\"muted\">{d:.1} %</span>", .{ c.progress_total, @min(c.progress_done, c.progress_total), 100.0 * @as(f64, @floatFromInt(@min(c.progress_done, c.progress_total))) / @as(f64, @floatFromInt(c.progress_total)) });
        } else {
            try w.writeAll("<progress id=\"import-bar\"></progress> <span data-f=\"percent\" class=\"muted\">size unknown</span>");
        }
        try w.print("<dl class=\"facts\"><div><dt>{s}</dt><dd data-f=\"docs\">{d}</dd></div><div><dt>Speed</dt><dd data-f=\"rate\">measuring</dd></div><div><dt>Time left</dt><dd data-f=\"eta\">estimating</dd></div><div><dt>Running for</dt><dd data-f=\"elapsed\">", .{ if (c.op == .remove) "Removed" else "Documents", c.submitted });
        try writeDuration(w, @intCast(@max(0, unixNow(app.io) - c.started_at)));
        try w.writeAll("</dd></div></dl>\n<noscript><p class=\"muted\">Without JavaScript the numbers above only update when you reload the page.</p></noscript>");
        if (csrf) |token| {
            try w.writeAll("<form action=\"/actions/cancel\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
            try html.writeEscaped(w, token);
            try w.writeAll("\"><button type=\"submit\" class=\"btn danger\">Cancel the import</button></form>");
        }
        try w.writeAll("</section>\n");
        return;
    }
    try w.writeAll("<section class=\"card\"><h2>Imports</h2>");
    if (csrf) |token| {
        var any = false;
        for (app.sources()) |s| {
            if (!s.enabled) continue;
            any = true;
            try w.writeAll("<form class=\"inline\" action=\"/actions/import\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
            try html.writeEscaped(w, token);
            try w.writeAll("\"><input type=\"hidden\" name=\"source\" value=\"");
            try html.writeEscaped(w, s.name);
            try w.writeAll("\"><button type=\"submit\" class=\"btn\">Import ");
            try html.writeEscaped(w, s.name);
            try w.writeAll("</button></form> ");
        }
        if (!any) try w.writeAll("<p class=\"muted\">No enabled sources.</p>");
    } else {
        try w.writeAll("<p class=\"muted\">Sign in with the password to use the buttons, or use the API.</p>");
    }
    if (try m.lastResult(arena)) |l| {
        try w.print("<p class=\"muted\">Last operation started from here: {s} ", .{opTitle(l.op).ptr[0..opTitle(l.op).len]});
        try html.writeEscaped(w, l.source);
        try w.writeAll(" ");
        try writeBadge(w, l.state);
        if (l.op == .import) try w.print(" {d} submitted, {d} skipped", .{ l.submitted, l.rejected });
        if (l.summary) |sm| {
            try w.writeAll(" &mdash; ");
            try html.writeEscaped(w, sm);
        }
        {
            var rb: [256]u8 = undefined;
            var rw: Io.Writer = .fixed(&rb);
            dk.connector.formatReasons(l.reasons, &rw) catch {};
            if (rw.end > 0) try w.print(" ({s})", .{rb[0..rw.end]});
        }
        try w.writeAll(", finished ");
        try writeTime(w, l.finished_at);
        if (l.failure) |f| {
            try w.writeAll(". Problem: ");
            try html.writeEscaped(w, f);
        }
        try w.writeAll(".</p>");
    }
    try w.writeAll("</section>\n");
}

fn unixNow(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn writeDashboard(app: *App, arena: Allocator, w: *Io.Writer, snap: App.Snapshot, csrf: ?[]const u8) !void {
    var total: u64 = 0;
    var max_docs: u64 = 1;
    for (snap.counts) |c| {
        total += c.documents;
        max_docs = @max(max_docs, c.documents);
    }
    var storage_total: u64 = 0;
    for (snap.sizes) |sz| storage_total += sz orelse 0;

    // Summary cards.
    try w.writeAll("<section class=\"statgrid\">");
    var nb: [32]u8 = undefined;
    try writeStat(w, std.fmt.bufPrint(&nb, "{d}", .{total}) catch "?", "documents");
    var sb: [32]u8 = undefined;
    try writeStat(w, std.fmt.bufPrint(&sb, "{d}", .{snap.sources.len}) catch "?", "sources");
    {
        var bb: [48]u8 = undefined;
        var bw: Io.Writer = .fixed(&bb);
        try writeBytes(&bw, storage_total);
        try writeStat(w, bw.buffered(), "stored data");
        var ub: [48]u8 = undefined;
        var uw: Io.Writer = .fixed(&ub);
        try writeDuration(&uw, @intCast(@max(0, app.uptimeSeconds())));
        try writeStat(w, uw.buffered(), "uptime");
    }
    try w.print("</section>\n<p class=\"muted\">dksearch {s}. {s}</p>\n", .{
        app.opts.version,
        if (app.opts.jobs != null) "Imports can be started below; rebuild, check, backup and removal are command-line only." else "Read-only view: use the command line to import, rebuild, check or back up.",
    });

    try writeImportsPanel(app, arena, w, csrf);

    try w.writeAll("<h2>Sources</h2>\n");
    if (snap.sources.len == 0 and snap.counts.len == 0) {
        try w.writeAll("<p>No sources are configured. dksearch works without them; add a <code>[[source]]</code> to the configuration to import documents (see <code>dksearch help config</code>).</p>\n");
    } else {
        try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Name</th><th>Kind</th><th>Documents</th><th>Last import</th><th>Started</th><th class=\"num\">Submitted</th><th class=\"num\">Skipped</th></tr></thead><tbody>\n");
        for (snap.sources, 0..) |s, i| {
            try w.writeAll("<tr><td><strong>");
            try html.writeEscaped(w, s.name);
            try w.writeAll("</strong>");
            if (!s.enabled) try w.writeAll(" <span class=\"badge off\">disabled</span>");
            try w.writeAll("</td><td>");
            try html.writeEscaped(w, s.kind);
            const docs = App.docsFor(snap, s.name);
            try w.print("</td><td><meter min=\"0\" max=\"{d}\" value=\"{d}\"></meter> <span class=\"num\">{d}</span></td>", .{ max_docs, docs, docs });
            if (i < snap.last.len and snap.last[i] != null) {
                try writeJobCells(w, snap.last[i].?);
            } else try w.writeAll("<td colspan=\"4\" class=\"muted\">never run</td>");
            try w.writeAll("</tr>\n");
        }
        for (snap.counts) |c| {
            var known = false;
            for (snap.sources) |s| if (std.mem.eql(u8, s.name, c.source)) {
                known = true;
            };
            if (known) continue;
            try w.writeAll("<tr><td><strong>");
            try html.writeEscaped(w, c.source);
            try w.print("</strong></td><td><span class=\"badge off\">not in the configuration</span></td><td><meter min=\"0\" max=\"{d}\" value=\"{d}\"></meter> <span class=\"num\">{d}</span></td><td colspan=\"4\" class=\"muted\">&mdash;</td></tr>\n", .{ max_docs, c.documents, c.documents });
        }
        try w.writeAll("</tbody></table></div>\n");
    }

    try w.writeAll("<h2>Storage</h2><div class=\"tablewrap\"><table class=\"data\"><tbody>");
    const names = [_][]const u8{ "index.db", "state.db", "content.db" };
    const what = [_][]const u8{ "the search index (rebuildable)", "document records and import history", "the retained text" };
    const max_size: u64 = blk: {
        var mx: u64 = 1;
        for (snap.sizes) |sz| mx = @max(mx, sz orelse 0);
        break :blk mx;
    };
    for (names, what, snap.sizes) |n, d, sz| {
        try w.print("<tr><th>{s}</th><td class=\"muted\">{s}</td><td><meter min=\"0\" max=\"{d}\" value=\"{d}\"></meter></td><td class=\"num\">", .{ n, d, max_size, sz orelse 0 });
        try writeBytes(w, sz);
        try w.writeAll("</td></tr>");
    }
    try w.writeAll("</tbody></table></div>\n");

    try w.writeAll("<details><summary>Traffic since start</summary><div class=\"tablewrap\"><table class=\"data\"><thead><tr><th></th><th class=\"num\">Requests</th><th class=\"num\">2xx</th><th class=\"num\">3xx</th><th class=\"num\">4xx</th><th class=\"num\">5xx</th><th class=\"num\">&le;10 ms</th><th class=\"num\">&le;50 ms</th><th class=\"num\">&le;250 ms</th><th class=\"num\">&le;1 s</th><th class=\"num\">slower</th><th class=\"num\">Refused busy</th><th class=\"num\">Timed out</th></tr></thead><tbody>\n");
    for ([_]struct { []const u8, *const server.Stats }{ .{ "Public", app.opts.public_stats }, .{ "Admin", app.opts.admin_stats } }) |row| {
        const c = App.counters(row.@"1");
        try w.print("<tr><th>{s}</th><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td><td class=\"num\">{d}</td></tr>\n", .{
            row.@"0",
            c.requests,
            c.status_2xx,
            c.status_3xx,
            c.status_4xx,
            c.status_5xx,
            c.latency_le_10ms,
            c.latency_le_50ms,
            c.latency_le_250ms,
            c.latency_le_1000ms,
            c.latency_over_1000ms,
            c.connections_refused_busy,
            c.connections_timed_out,
        });
    }
    try w.writeAll("</tbody></table></div></details>\n");
    try w.print("<p class=\"muted\">{d} active session(s). A job shown as running may belong to an import that was killed; the next command that opens the data marks it interrupted.</p>\n", .{app.sessionCount()});
}

fn writeSources(app: *App, w: *Io.Writer, snap: App.Snapshot, csrf: ?[]const u8, done: ?[]const u8) !void {
    if (done) |d| {
        // Only fixed words are ever shown, never the request's own text.
        const msg: ?[]const u8 = if (std.mem.eql(u8, d, "saved")) "Saved. The change is in effect now; the previous file is kept next to it as .bak." else if (std.mem.eql(u8, d, "deleted")) "Deleted from the configuration. Documents it imported stay until you remove them under Maintenance." else if (std.mem.eql(u8, d, "enabled")) "Enabled." else if (std.mem.eql(u8, d, "disabled")) "Disabled." else null;
        if (msg) |m| try w.print("<p class=\"notice ok\" role=\"status\">{s}</p>\n", .{m});
    }
    const editable = app.canEditSources() and csrf != null;
    if (snap.sources.len == 0) {
        try w.writeAll("<p>No sources are configured. dksearch works without them; a source tells it what to index.</p>\n");
    } else {
        try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Name</th><th>Kind</th><th>Where from</th><th>Documents</th><th>State</th>");
        if (editable) try w.writeAll("<th></th>");
        try w.writeAll("</tr></thead><tbody>\n");
        for (snap.sources) |s| {
            try w.writeAll("<tr><td><strong>");
            try html.writeEscaped(w, s.name);
            try w.writeAll("</strong></td><td>");
            try html.writeEscaped(w, s.kind);
            try w.writeAll("</td><td class=\"muted\">");
            // The one option that says where the source comes from, if there is one.
            for ([_][]const u8{ "path", "dump", "catalog", "seeds_file", "query" }) |k| {
                if (s.optionString(k)) |v| {
                    try html.writeEscaped(w, v);
                    break;
                }
            }
            try w.print("</td><td class=\"num\">{d}</td><td>", .{App.docsFor(snap, s.name)});
            try w.writeAll(if (s.enabled) "<span class=\"badge ok\">enabled</span>" else "<span class=\"badge off\">disabled</span>");
            try w.writeAll("</td>");
            if (editable) {
                try w.writeAll("<td class=\"actions\"><a class=\"btn secondary\" href=\"/sources/edit?name=");
                try query.writeEncoded(w, s.name);
                try w.writeAll("\">Edit</a> ");
                for ([_]struct { []const u8, []const u8, []const u8, []const u8 }{
                    .{ "toggle", if (s.enabled) "0" else "1", if (s.enabled) "Disable" else "Enable", "secondary" },
                    .{ "delete", "", "Delete", "danger" },
                }) |b| {
                    try w.print("<form class=\"inline\" action=\"/actions/sources\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"{s}\"><input type=\"hidden\" name=\"op\" value=\"{s}\"><input type=\"hidden\" name=\"enabled\" value=\"{s}\"><input type=\"hidden\" name=\"name\" value=\"", .{ csrf.?, b[0], b[1] });
                    try html.writeEscaped(w, s.name);
                    try w.print("\"><button type=\"submit\" class=\"btn {s}\">{s}</button></form> ", .{ b[3], b[2] });
                }
                try w.writeAll("</td>");
            }
            try w.writeAll("</tr>\n");
        }
        try w.writeAll("</tbody></table></div>\n");
    }
    if (editable) {
        try w.writeAll("<p><a class=\"btn\" href=\"/sources/new\">Add a source</a></p><p class=\"muted\">Changes are written to the configuration file (the previous version is kept as <code>.bak</code>) and take effect at once. Deleting a source only removes it from the file; its documents stay until you remove them under Maintenance.</p>\n");
    } else if (app.opts.jobs == null) {
        try w.writeAll("<p class=\"muted\">Editing sources from here is turned off (<code>admin.actions</code> is false). Edit the configuration file and restart, or see <code>dksearch help config</code>.</p>\n");
    } else if (app.opts.config_path == null) {
        try w.writeAll("<p class=\"muted\">The server was started without <code>--config</code>, so there is no configuration file to edit here.</p>\n");
    } else {
        try w.writeAll("<p class=\"muted\">Sign in with the password to edit sources.</p>\n");
    }
}

const KindInfo = struct {
    kind: []const u8,
    title: []const u8,
    /// One or two sentences for the chooser.
    blurb: []const u8,
    /// What it needs, in a line.
    needs: []const u8,
    /// A starting point that is valid as it stands (paths and names are examples to change).
    template: []const u8,
};

const kind_infos = [_]KindInfo{
    .{
        .kind = "files",
        .title = "A folder of text files",
        .blurb = "Indexes the .txt and Markdown files in a folder on this machine, such as your notes.",
        .needs = "The folder's path.",
        .template = "path = \"/home/me/notes\"   # the folder to index (change this)\n# pdf_text = true         # also index PDFs (needs the pdftotext program: sudo apt install poppler-utils)\n# office = true          # also index Word, OpenDocument and EPUB files (no outside program needed)\n# html = true            # also index .html files as web pages\n# media = true           # also index audio and video by their tags (needs ffprobe: sudo apt install ffmpeg)\n# serve_originals = true  # let results open the original file in the browser (restart the server after changing)\n",
    },
    .{
        .kind = "wikipedia",
        .title = "A Wikipedia dump",
        .blurb = "Indexes the articles of a Wikipedia dump file you have already downloaded (the .xml.bz2 from dumps.wikimedia.org).",
        .needs = "The dump file's path.",
        .template = "dump = \"/data/enwiki-latest-pages-articles-multistream.xml.bz2\"   # the downloaded file (change this)\n",
    },
    .{
        .kind = "zim",
        .title = "A Kiwix (ZIM) file",
        .blurb = "Indexes the articles of a .zim file from the Kiwix project: offline copies of Wikipedia, Wiktionary, Stack Exchange, documentation sites and more.",
        .needs = "The .zim file's path (optionally the address where you serve it, for links).",
        .template = "path = \"/data/wikipedia_en_all_maxi.zim\"   # the downloaded .zim file (change this)\n# url_base = \"http://localhost:8080/content/wikipedia_en_all_maxi/\"   # optional: makes each result link to a kiwix-serve\n",
    },
    .{
        .kind = "dump",
        .title = "Archives and data dumps",
        .blurb = "Indexes ZIP archives, WARC web archives (including Common Crawl files), Stack Exchange data dumps and Reddit dumps that you already have on disk.",
        .needs = "The file or folder and the format: zip, warc, stackexchange or reddit.",
        .template = "path = \"/data/dumps\"   # a file, or a folder of files (change this)\nformat = \"warc\"       # zip, warc, stackexchange (Posts.xml) or reddit (.jsonl / .zst)\n# site_url = \"https://cooking.stackexchange.com\"   # stackexchange: for links\n# subreddits = \"linux, programming\"                # reddit: keep only these\n# min_score = 1                                    # stackexchange and reddit\n",
    },
    .{
        .kind = "gutenberg",
        .title = "Project Gutenberg books",
        .blurb = "Indexes Project Gutenberg books from its catalog file and a folder of book files you have downloaded.",
        .needs = "The catalog CSV and the books folder.",
        .template = "catalog = \"/data/pg_catalog.csv\"   # change these two paths\nbooks = \"/data/books\"\n",
    },
    .{
        .kind = "feeds",
        .title = "RSS and Atom feeds",
        .blurb = "Indexes the entries of feed files you have downloaded (a file, or a folder of them). It never fetches anything itself.",
        .needs = "The path of a feed file or a folder of them.",
        .template = "path = \"/srv/feeds\"   # a feed file or a folder of them (change this)\n",
    },
    .{
        .kind = "crawl",
        .title = "A list of web pages (crawler)",
        .blurb = "Fetches the web pages you list in a text file, one address per line, and can follow links on the same site. Polite by default: it obeys robots.txt and waits between requests.",
        .needs = "A seeds file (one URL per line) and who you are (user agent).",
        .template = "seeds_file = \"/etc/dksearch/seeds.txt\"   # one URL per line (change this)\nuser_agent = \"mysearch/1.0 (+https://example.org/about)\"   # who you are, so site owners can reach you\nmax_depth = 1       # 0 = only the listed pages; 1 = also pages they link to on the same site\nmax_pages = 500\n",
    },
    .{
        .kind = "archive",
        .title = "Internet Archive items",
        .blurb = "Indexes the descriptions (titles, creators, subjects) of items at archive.org that match a search you give it, such as a whole collection. It does not download the items themselves.",
        .needs = "A search query, and who you are (user agent).",
        .template = "query = \"collection:prelinger AND mediatype:movies\"   # any archive.org search (change this)\nuser_agent = \"mysearch/1.0 (+https://example.org/about)\"   # who you are; archive.org asks for this\nmax_items = 1000    # a safety limit; raise it for bigger collections\n",
    },
};

fn kindInfo(kind: []const u8) ?KindInfo {
    for (kind_infos) |k| if (std.mem.eql(u8, k.kind, kind)) return k;
    return null;
}

/// A free name like "archive-2" for a new source of `kind`.
fn suggestName(app: *App, arena: Allocator, kind: []const u8) Allocator.Error![]const u8 {
    var n: u32 = 1;
    while (n < 1000) : (n += 1) {
        const name = if (n == 1) try arena.dupe(u8, kind) else try std.fmt.allocPrint(arena, "{s}-{d}", .{ kind, n });
        const taken = for (app.sources()) |s| {
            if (std.mem.eql(u8, s.name, name)) break true;
        } else false;
        if (!taken) return name;
    }
    return kind;
}

fn writeKindChooser(w: *Io.Writer) !void {
    try w.writeAll("<p class=\"muted\">What do you want to index? Pick one; the next page is filled in with an example you only need to adjust.</p><div class=\"cards\">");
    for (kind_infos) |k| {
        if (!kindAvailable(k.kind)) continue;
        try w.print("<a class=\"choice\" href=\"/sources/edit?kind={s}\"><strong>{s}</strong><span>{s}</span><small>Needs: {s}</small></a>", .{ k.kind, k.title, k.blurb, k.needs });
    }
    try w.writeAll("</div><p><a class=\"btn secondary\" href=\"/sources\">Cancel</a></p>\n");
}

fn kindAvailable(kind: []const u8) bool {
    for (dk.connectors.kinds) |k| if (std.mem.eql(u8, k, kind)) return true;
    return false;
}

/// One labelled field for each option of the source's kind, filled from its current settings,
/// and a box for any setting the form does not know.
fn writeOptionFields(arena: Allocator, w: *Io.Writer, spec: dk.sourceedit.Spec) !void {
    const opts = dk.optioninfo.forKind(spec.kind);
    const split = try dk.optioninfo.split(arena, spec.kind, spec.options);
    try w.writeAll("<fieldset class=\"options\"><legend>Settings of this kind of source</legend>");
    for (opts, split.values) |o, current| {
        switch (o.type) {
            .flag => {
                const on = if (current) |v| std.mem.eql(u8, v, "true") else o.default_on;
                try w.writeAll("<label class=\"check\"><input type=\"checkbox\" name=\"opt_");
                try html.writeEscaped(w, o.key);
                try w.print("\" value=\"1\"{s}> ", .{if (on) " checked" else ""});
                try html.writeEscaped(w, o.label);
                try w.writeAll("<small>");
                try html.writeEscaped(w, o.help);
                try w.writeAll("</small></label>");
            },
            else => {
                try w.writeAll("<label>");
                try html.writeEscaped(w, o.label);
                if (o.required) try w.writeAll(" <span class=\"req\" title=\"required\">*</span>");
                try w.print(" <input name=\"opt_{s}\" type=\"{s}\"", .{ o.key, if (o.type == .number) "number" else "text" });
                if (o.type == .number) try w.print(" min=\"{d}\" max=\"{d}\"", .{ o.min, o.max });
                if (o.type != .number) try w.writeAll(" spellcheck=\"false\" autocomplete=\"off\"");
                try w.writeAll(" maxlength=\"2000\"");
                if (o.required) try w.writeAll(" required");
                const hint = if (o.placeholder.len > 0) o.placeholder else o.default;
                if (hint.len > 0) {
                    try w.writeAll(" placeholder=\"");
                    try html.writeEscaped(w, hint);
                    try w.writeByte('"');
                }
                if (current) |v| {
                    try w.writeAll(" value=\"");
                    try html.writeEscaped(w, v);
                    try w.writeByte('"');
                }
                try w.writeAll("><small>");
                try html.writeEscaped(w, o.help);
                if (o.default.len > 0) {
                    try w.writeAll(" Default: ");
                    try html.writeEscaped(w, o.default);
                    try w.writeAll(".");
                }
                try w.writeAll("</small></label>");
            },
        }
    }
    try w.writeAll("</fieldset>");
    try w.writeAll("<details");
    if (split.rest.len > 0) try w.writeAll(" open");
    try w.writeAll("><summary>Other settings</summary><label>Anything else, one <code>key = value</code> per line <textarea name=\"options\" rows=\"3\" spellcheck=\"false\" maxlength=\"16384\">");
    try html.writeEscaped(w, split.rest);
    try w.writeAll("</textarea><small>For a setting this form does not list. Saving checks everything and tells you what is wrong.</small></label></details>");
}

/// The Settings page body.
fn writeSettings(arena: Allocator, w: *Io.Writer, csrf: []const u8, text: ?[]const u8, editable: bool, has_file: bool, done: ?[]const u8, problem: ?[]const u8, posted: ?query.Params) !void {
    if (done != null) try w.writeAll("<p class=\"notice ok\" role=\"status\">Saved. The server reads its settings when it starts: restart it for the changes to take effect. The previous file is kept as <code>.bak</code>.</p>\n");
    if (problem) |p| {
        try w.writeAll("<p class=\"notice err\" role=\"alert\">");
        try html.writeEscaped(w, p);
        try w.writeAll("</p>\n");
    }
    if (!has_file) {
        try w.writeAll("<p class=\"notice\">The server was started without <code>--config</code>, so there is no configuration file to show or edit.</p>");
        return;
    }
    if (!editable) try w.writeAll("<p class=\"notice\">Read only. Turn on <code>[admin] actions = true</code> to change settings from here.</p>\n");
    try w.writeAll("<p class=\"muted\">Empty fields use their default. Settings are read when the server starts, so a saved change applies after a restart. Everything is checked before it is saved.</p>\n");
    try w.writeAll("<form class=\"stack\" action=\"/actions/settings\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
    try html.writeEscaped(w, csrf);
    try w.writeAll("\">");
    for (dk.settinginfo.groups) |g| {
        try w.writeAll("<fieldset class=\"options\"><legend>");
        try html.writeEscaped(w, g.title);
        try w.writeAll("</legend><p class=\"muted small\">");
        try html.writeEscaped(w, g.note);
        try w.writeAll("</p>");
        for (g.fields) |f| {
            const name = try std.fmt.allocPrint(arena, "s_{s}_{s}", .{ f.table, f.key });
            // What to show: what was just typed, else what the file says.
            const typed: ?[]const u8 = if (posted) |pp| pp.get(name) else null;
            const in_file: ?[]const u8 = if (text) |t| try dk.sourceedit.settingText(arena, t, f.table, f.key) else null;
            const dis: []const u8 = if (editable) "" else " disabled";
            switch (f.type) {
                .flag => {
                    const on = if (posted != null) typed != null else if (in_file) |v| std.mem.eql(u8, v, "true") else std.mem.eql(u8, f.default, "true");
                    try w.print("<label class=\"check\"><input type=\"checkbox\" name=\"{s}\" value=\"1\"{s}{s}> ", .{ name, if (on) " checked" else "", dis });
                    try html.writeEscaped(w, f.label);
                    try w.writeAll("<small>");
                    try html.writeEscaped(w, f.help);
                    try w.writeAll("</small></label>");
                },
                .choice => {
                    const current = typed orelse in_file orelse f.default;
                    try w.writeAll("<label>");
                    try html.writeEscaped(w, f.label);
                    try w.print(" <select name=\"{s}\"{s}>", .{ name, dis });
                    for (f.choices) |c| {
                        try w.print("<option value=\"{s}\"{s}>{s}</option>", .{ c, if (std.mem.eql(u8, c, current)) " selected" else "", c });
                    }
                    try w.writeAll("</select><small>");
                    try html.writeEscaped(w, f.help);
                    try w.writeAll("</small></label>");
                },
                .number, .text => {
                    try w.writeAll("<label>");
                    try html.writeEscaped(w, f.label);
                    try w.print(" <input name=\"{s}\" type=\"{s}\"{s}", .{ name, if (f.type == .number) "number" else "text", dis });
                    if (f.type == .number) try w.print(" min=\"{d}\" max=\"{d}\"", .{ f.min, f.max }) else try w.writeAll(" spellcheck=\"false\" autocomplete=\"off\"");
                    try w.writeAll(" maxlength=\"1000\"");
                    const hint = if (f.placeholder.len > 0) f.placeholder else f.default;
                    if (hint.len > 0) {
                        try w.writeAll(" placeholder=\"");
                        try html.writeEscaped(w, hint);
                        try w.writeByte('"');
                    }
                    if (typed orelse in_file) |v| {
                        try w.writeAll(" value=\"");
                        try html.writeEscaped(w, v);
                        try w.writeByte('"');
                    }
                    try w.writeAll("><small>");
                    try html.writeEscaped(w, f.help);
                    if (f.default.len > 0) {
                        try w.writeAll(" Default: ");
                        try html.writeEscaped(w, f.default);
                        try w.writeAll(".");
                    }
                    try w.writeAll("</small></label>");
                },
            }
        }
        try w.writeAll("</fieldset>");
    }
    if (editable) try w.writeAll("<p><button type=\"submit\" class=\"btn\">Save settings</button></p>");
    try w.writeAll("</form>\n<p class=\"muted\">Other settings (where the data lives, access to the credentials file, more server limits) are changed in the file by hand; see <code>man dksearch</code>.</p>\n");
}

fn writeSourceForm(arena: Allocator, w: *Io.Writer, csrf: []const u8, spec: dk.sourceedit.Spec, original: ?[]const u8, problem: ?[]const u8) !void {
    if (problem) |p| {
        try w.writeAll("<p class=\"notice err\" role=\"alert\">");
        try html.writeEscaped(w, p);
        try w.writeAll("</p>\n");
    }
    try w.writeAll("<form class=\"stack\" action=\"/actions/sources\" method=\"post\"><input type=\"hidden\" name=\"op\" value=\"save\"><input type=\"hidden\" name=\"form\" value=\"1\"><input type=\"hidden\" name=\"csrf\" value=\"");
    try html.writeEscaped(w, csrf);
    try w.writeAll("\"><input type=\"hidden\" name=\"original\" value=\"");
    if (original) |o| try html.writeEscaped(w, o);
    try w.writeAll("\"><label>Name <input name=\"name\" required maxlength=\"64\" pattern=\"[a-z0-9][a-z0-9_\\-]*\" autocomplete=\"off\" value=\"");
    try html.writeEscaped(w, spec.name);
    try w.writeAll("\"><small>Letters a-z, digits, - and _. Renaming a source starts its import history afresh.</small></label>");
    // The kind is fixed once chosen (the options below belong to it); a new source picks it in the chooser.
    try w.writeAll("<p>Kind: <strong>");
    try html.writeEscaped(w, spec.kind);
    try w.writeAll("</strong><input type=\"hidden\" name=\"kind\" value=\"");
    try html.writeEscaped(w, spec.kind);
    try w.writeAll("\"><input type=\"hidden\" name=\"fields\" value=\"1\"></p>");
    try w.print("<label class=\"check\"><input type=\"checkbox\" name=\"enabled\" value=\"1\"{s}> enabled</label>", .{if (spec.enabled) " checked" else ""});
    try w.print("<label class=\"check\"><input type=\"checkbox\" name=\"retain_text\" value=\"1\"{s}> keep each document&rsquo;s text (needed to rebuild the index without the source)</label>", .{if (spec.retain_text) " checked" else ""});
    try w.writeAll("<label>Rights <select name=\"rights\">");
    for ([_][]const u8{ "", "unknown", "allowed", "restricted", "forbidden" }) |r| {
        const sel = if (spec.rights) |cur| std.mem.eql(u8, cur, r) else r.len == 0;
        try w.print("<option value=\"{s}\"{s}>{s}</option>", .{ r, if (sel) " selected" else "", if (r.len == 0) "the connector&rsquo;s default" else r });
    }
    try w.writeAll("</select><small>What may be done with the content. This is your decision, not legal advice.</small></label>");
    try w.writeAll("<label>Schedule <input type=\"text\" name=\"schedule\" maxlength=\"16\" placeholder=\"daily\" value=\"");
    try html.writeEscaped(w, spec.schedule orelse "");
    try w.writeAll("\"><small>Import this source again by itself: <code>hourly</code>, <code>daily</code>, <code>weekly</code>, or a number with m, h or d (<code>30m</code>, <code>6h</code>, <code>2d</code>; at least 10 minutes). Counted from when the last import started. Needs <code>admin.actions</code>; empty means never (import by hand, or use a timer). Only one import runs at a time; a due source waits its turn.</small></label>");
    try w.print("<label>Ranking boost (%) <input type=\"number\" name=\"boost\" min=\"1\" max=\"1000\" value=\"{d}\"><small>100 changes nothing. 150 ranks this source&rsquo;s results half as high again in search; 50 halves them. Useful to put curated sources ahead of large, noisy ones.</small></label>", .{spec.boost});
    try writeOptionFields(arena, w, spec);
    try w.writeAll("<p><button type=\"submit\" class=\"btn\">Save</button> <a class=\"btn secondary\" href=\"/sources\">Cancel</a></p></form>\n");
    if (kindInfo(spec.kind)) |info| {
        try w.print("<details open><summary>About {s}</summary><p>", .{info.title});
        try html.writeEscaped(w, info.blurb);
        try w.writeAll("</p><p class=\"muted\">Needs: ");
        try html.writeEscaped(w, info.needs);
        try w.writeAll("</p></details>\n");
    }
    try w.writeAll("<p class=\"muted\">Every option of every kind is described in <code>man dksearch</code>. The text after a <code>#</code> is a note and is ignored. If something is wrong, saving tells you what.</p>\n");
}

fn opTitle(op: dk.jobs.Op) []const u8 {
    return switch (op) {
        .import => "Import",
        .check => "Check of the stored data",
        .backup => "Backup",
        .remove => "Removal",
        .download => "Download",
    };
}

fn writeMaintenance(app: *App, arena: Allocator, w: *Io.Writer, snap: App.Snapshot, csrf: ?[]const u8) !void {
    const m = app.opts.jobs orelse {
        try w.writeAll("<section class=\"card\"><h2>Maintenance</h2><p class=\"muted\">Running maintenance from here is turned off (<code>admin.actions</code> is false). Use the command line: <code>dksearch check</code>, <code>backup</code>, <code>remove</code>, <code>rebuild</code>, <code>restore</code> (see <code>dksearch help</code>).</p></section>\n");
        return;
    };
    try writeImportsPanel(app, arena, w, csrf);
    const idle = (try m.current(arena)) == null;
    const token = csrf orelse {
        try w.writeAll("<p class=\"muted\">Sign in with the password to use the buttons, or use the API (<code>POST /api/v1/admin/maintenance</code>).</p>\n");
        return;
    };
    const off = if (idle) "" else " disabled";

    try w.writeAll("<section class=\"card\"><h2>Check the stored data</h2><p class=\"muted\">Verifies the databases and every stored text against its record (read-only). It can take a long time on a large index; the progress bar shows how far it is.</p>");
    try w.print("<form action=\"/actions/maintenance\" method=\"post\"><input type=\"hidden\" name=\"op\" value=\"check\"><input type=\"hidden\" name=\"csrf\" value=\"{s}\"><button type=\"submit\" class=\"btn\"{s}>Run the check</button></form></section>\n", .{ token, off });

    try w.writeAll("<section class=\"card\"><h2>Back up</h2>");
    if (m.opts.backup_dir) |dir| {
        try w.writeAll("<p class=\"muted\">Writes verified copies of <code>state.db</code> and <code>content.db</code> (the only copies of what was imported) into a new folder under <code>");
        try html.writeEscaped(w, dir);
        try w.print("</code>. The server keeps working. The index is not copied; <code>dksearch restore</code> recreates it.</p><form action=\"/actions/maintenance\" method=\"post\"><input type=\"hidden\" name=\"op\" value=\"backup\"><input type=\"hidden\" name=\"csrf\" value=\"{s}\"><button type=\"submit\" class=\"btn\"{s}>Back up now</button></form>", .{ token, off });
    } else {
        try w.writeAll("<p class=\"muted\">Not set up: add <code>backup_dir = \"/path/to/backups\"</code> to the <code>[admin]</code> table of the configuration (a folder you control; the interface never writes anywhere else) and restart.</p>");
    }
    try w.writeAll("</section>\n");

    try w.writeAll("<section class=\"card\"><h2>Remove a source&rsquo;s documents</h2><p class=\"muted\">Deletes every document the source imported from the index, the stored text and the records, and forgets its import history. This cannot be undone (restore from a backup). Type the source&rsquo;s name to confirm.</p>");
    var any = false;
    for (snap.counts) |c| {
        any = true;
        try w.print("<form class=\"inline\" action=\"/actions/maintenance\" method=\"post\"><input type=\"hidden\" name=\"op\" value=\"remove\"><input type=\"hidden\" name=\"csrf\" value=\"{s}\"><input type=\"hidden\" name=\"source\" value=\"", .{token});
        try html.writeEscaped(w, c.source);
        try w.print("\"><strong>", .{});
        try html.writeEscaped(w, c.source);
        try w.print("</strong> ({d} documents) <input name=\"confirm\" placeholder=\"type the name\" autocomplete=\"off\" maxlength=\"64\"> <button type=\"submit\" class=\"btn danger\"{s}>Remove</button></form><br>", .{ c.documents, off });
    }
    if (!any) try w.writeAll("<p class=\"muted\">No documents have been imported yet.</p>");
    try w.writeAll("</section>\n");

    try w.writeAll("<section class=\"card\"><h2>Rebuild and restore</h2><p class=\"muted\">These stay on the command line: <code>dksearch rebuild</code> recreates the index (stop <code>serve</code> first), and <code>dksearch restore DIR</code> recreates the stored data from a backup. Both replace files the running server is using.</p></section>\n");
}

fn writeSkipped(w: *Io.Writer, job: i64, skips: []const dk.connector.Sample) Io.Writer.Error!void {
    try w.print("<p>Examples of what job {d} skipped: up to twenty for each reason, taken as the run went. The counts on the Jobs page are complete; this list is only a sample, so you can see <em>what</em> is being left out. <a href=\"/jobs\">Back to the jobs</a></p>", .{job});
    if (skips.len == 0) return w.writeAll("<p class=\"muted\">No examples were recorded (the connector does not name what it skips, or nothing was skipped).</p>\n");
    try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Why</th><th>Address or path</th></tr></thead><tbody>\n");
    for (skips) |s| {
        try w.writeAll("<tr><td>");
        try html.writeEscaped(w, s.reason);
        try w.writeAll("</td><td><code>");
        try html.writeEscaped(w, s.what);
        try w.writeAll("</code></td></tr>\n");
    }
    try w.writeAll("</tbody></table></div>\n");
}

fn writeJobs(w: *Io.Writer, jobs: []const dk.state_sqlite.Job) Io.Writer.Error!void {
    if (jobs.len == 0) return w.writeAll("<p>No imports have run yet.</p>\n");
    try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Job</th><th>Source</th><th>Kind</th><th>State</th><th>Started</th><th class=\"num\">Submitted</th><th class=\"num\">Skipped</th><th>Note</th></tr></thead><tbody>\n");
    for (jobs) |j| {
        try w.print("<tr><td>{d}</td><td>", .{j.id});
        try html.writeEscaped(w, j.source);
        try w.writeAll("</td><td>");
        try html.writeEscaped(w, j.connector);
        try w.writeAll("</td>");
        try writeJobCells(w, j);
        try w.writeAll("<td>");
        if (j.error_message) |m| try html.writeEscaped(w, m);
        try w.writeAll("</td></tr>\n");
    }
    try w.writeAll("</tbody></table></div>\n");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const secrets_mod = dk.secrets;

const Fixture = struct {
    tmp: testing.TmpDir,
    index_path: [160:0]u8 = undefined,
    state_path: [160:0]u8 = undefined,
    content_path: [160:0]u8 = undefined,
    secrets_path: [160]u8 = undefined,
    secrets_len: usize = 0,
    token: [secrets_mod.token_len]u8 = undefined,
    public_stats: server.Stats = .{},
    admin_stats: server.Stats = .{},
    app: App = undefined,
    sources: [2]dk.config.Source,
    notes: ?testing.TmpDir = null,
    note_opts: [1]dk.config.Option = undefined,
    manager: dk.jobs.Manager = undefined,
    manager_ready: bool = false,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        f.notes = null; // a struct made with `undefined` gets no field defaults
        f.manager_ready = false;
        f.sources = .{
            .{ .name = "notes", .kind = "files" },
            .{ .name = "wiki", .kind = "wikipedia", .enabled = false },
        };
        f.public_stats = .{};
        f.admin_stats = .{};
        const base = try std.fmt.bufPrint(&f.secrets_path, ".zig-cache/tmp/{s}", .{f.tmp.sub_path});
        const bl = base.len;
        _ = try std.fmt.bufPrintSentinel(&f.index_path, "{s}/index.db", .{f.secrets_path[0..bl]}, 0);
        _ = try std.fmt.bufPrintSentinel(&f.state_path, "{s}/state.db", .{f.secrets_path[0..bl]}, 0);
        _ = try std.fmt.bufPrintSentinel(&f.content_path, "{s}/content.db", .{f.secrets_path[0..bl]}, 0);
        const sp = try std.fmt.bufPrint(&f.secrets_path, ".zig-cache/tmp/{s}/admin.toml", .{f.tmp.sub_path});
        f.secrets_len = sp.len;

        // Some imported data: two documents of "notes", one of a source that
        // is no longer configured (with a name that needs escaping), a job.
        {
            var state = try dk.state_sqlite.SqliteStateStore.open(testing.allocator, std.mem.sliceTo(&f.state_path, 0), true);
            defer state.close();
            const docs = state.documents();
            for ([_][2][]const u8{ .{ "notes", "a" }, .{ "notes", "b" }, .{ "gone<b>", "x" } }) |d| {
                try docs.upsert(.{ .id = dk.document.idFromSource(d[0], d[1]), .content_hash = null, .acquired_at = 1, .meta = .{ .connector = d[0], .source_id = d[1] } });
            }
            const j = try state.startJob("notes", "files", 1709634030);
            try state.saveCheckpoint(j, null, 2, 3, "robots=2, http_status=1");
            try state.finishJob(j, .completed, 1709634040, null);
        }

        var s: secrets_mod.Secrets = .{};
        defer s.deinit(testing.allocator);
        s.token_hash = @splat(0);
        _ = try s.newToken(testing.io, &f.token);
        try s.setPassword(testing.allocator, testing.io, "correct horse");
        try secrets_mod.save(testing.io, f.tmp.dir, "admin.toml", s);

        f.app = App.init(testing.allocator, testing.io, .{
            .index_path = std.mem.sliceTo(&f.index_path, 0),
            .state_path = std.mem.sliceTo(&f.state_path, 0),
            .content_path = std.mem.sliceTo(&f.content_path, 0),
            .secrets_path = f.secrets_path[0..f.secrets_len],
            .sources = &f.sources,
            .version = "9.9.9",
            .public_stats = &f.public_stats,
            .admin_stats = &f.admin_stats,
        });
        f.app.skip_delay = true;
        f.app.fake_now_ns = 1_000_000_000_000;
    }

    fn deinit(f: *Fixture) void {
        if (f.manager_ready) f.manager.deinit();
        if (f.notes) |*n| {
            testing.allocator.free(f.note_opts[0].value.string);
            n.cleanup();
        }
        f.tmp.cleanup();
    }

    /// Turns on actions: a job manager over a small directory of notes.
    fn enableJobs(f: *Fixture) !void {
        f.notes = testing.tmpDir(.{ .iterate = true });
        try f.notes.?.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "the keeper trims the lamp" });
        try f.notes.?.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "gulls over the rocks" });
        var np: [160]u8 = undefined;
        const path = try std.fmt.bufPrint(&np, ".zig-cache/tmp/{s}", .{f.notes.?.sub_path});
        f.note_opts = .{.{ .key = "path", .value = .{ .string = try testing.allocator.dupe(u8, path) } }};
        f.sources[0].options = &f.note_opts;
        f.manager = dk.jobs.Manager.init(testing.allocator, testing.io, .{
            .data_dir = f.secrets_path[0 .. f.secrets_len - "/admin.toml".len],
            .index_path = std.mem.sliceTo(&f.index_path, 0),
            .state_path = std.mem.sliceTo(&f.state_path, 0),
            .content_path = std.mem.sliceTo(&f.content_path, 0),
            .sources = &f.sources,
            .sync_off = true,
        });
        f.manager_ready = true;
        f.app.opts.jobs = &f.manager;
    }

    fn waitIdle(f: *Fixture) !void {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var waited: u32 = 0;
        while (waited < 3000) : (waited += 1) {
            if ((try f.manager.current(arena.allocator())) == null) return;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.TestTimedOut;
    }

    fn call(f: *Fixture, arena: Allocator, method: http.Method, target: []const u8, opts: struct { auth: ?[]const u8 = null, cookie: ?[]const u8 = null, body: []const u8 = "" }) !Response {
        return f.app.handle(arena, .{ .method = method, .target = target, .authorization = opts.auth, .cookie = opts.cookie, .body = opts.body });
    }

    fn bearer(f: *Fixture, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "Bearer {s}", .{f.token});
    }

    fn header(r: Response, name: []const u8) ?[]const u8 {
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// Signs in with the password and returns the "dks_session=..." cookie pair.
    fn signIn(f: *Fixture, arena: Allocator) ![]const u8 {
        const r = try f.call(arena, .POST, "/login", .{ .body = "credential=correct+horse" });
        try testing.expectEqual(http.Status.see_other, r.status);
        const set = header(r, "set-cookie").?;
        return arena.dupe(u8, set[0..std.mem.indexOfScalar(u8, set, ';').?]);
    }
};

fn csrfOf(page: []const u8) []const u8 {
    const key = "name=\"csrf\" value=\"";
    const i = std.mem.indexOf(u8, page, key).? + key.len;
    return page[i .. i + 32];
}

test "unauthenticated requests are turned away, not served" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const page = try f.call(a, .GET, "/", .{});
    try testing.expectEqual(http.Status.see_other, page.status);
    try testing.expectEqualStrings("/login", Fixture.header(page, "location").?);

    const api = try f.call(a, .GET, "/api/v1/admin/status", .{});
    try testing.expectEqual(http.Status.unauthorized, api.status);
    try testing.expectEqualStrings("Bearer", Fixture.header(api, "www-authenticate").?);
    try testing.expect(std.mem.indexOf(u8, api.body, "version") == null); // nothing leaks

    const login = try f.call(a, .GET, "/login", .{});
    try testing.expectEqual(http.Status.ok, login.status);
    try testing.expect(std.mem.indexOf(u8, login.body, "type=\"password\"") != null);
    try testing.expect(std.mem.indexOf(u8, login.body, "method=\"post\"") != null);

    for ([_][]const u8{ "/jobs", "/api/v1/admin/sources", "/api/v1/admin/jobs" }) |p| {
        const r = try f.call(a, .GET, p, .{});
        try testing.expect(r.status == .see_other or r.status == .unauthorized);
    }
}

test "bearer token: accepted when right, refused and counted when wrong" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try f.call(a, .GET, "/api/v1/admin/status", .{ .auth = try f.bearer(a) });
    try testing.expectEqual(http.Status.ok, ok.status);
    try testing.expect(std.mem.indexOf(u8, ok.body, "\"version\":\"9.9.9\"") != null);
    try testing.expect(std.mem.indexOf(u8, ok.body, "\"documents\":3") != null);
    try testing.expect(std.mem.indexOf(u8, ok.body, "\"token\":true") != null);
    try testing.expect(std.mem.indexOf(u8, ok.body, "\"password\":true") != null);
    try testing.expectEqualStrings("no-store", Fixture.header(ok, "cache-control").?);
    try testing.expectEqual(@as(u32, 0), f.app.failures);

    const bad = try f.call(a, .GET, "/api/v1/admin/status", .{ .auth = "Bearer dks_wrong" });
    try testing.expectEqual(http.Status.unauthorized, bad.status);
    try testing.expectEqual(@as(u32, 0), f.app.failures); // wrong tokens are not counted
    const lower = try f.call(a, .GET, "/api/v1/admin/status", .{ .auth = try std.fmt.allocPrint(a, "bearer {s}", .{f.token}) });
    try testing.expectEqual(http.Status.ok, lower.status); // the scheme is case-insensitive
    const basic = try f.call(a, .GET, "/api/v1/admin/status", .{ .auth = "Basic dXNlcjpwdw==" });
    try testing.expectEqual(http.Status.unauthorized, basic.status);
}

test "api: sources and jobs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth = try f.bearer(a);

    const src = try f.call(a, .GET, "/api/v1/admin/sources", .{ .auth = auth });
    try testing.expectEqual(http.Status.ok, src.status);
    try testing.expect(std.mem.indexOf(u8, src.body, "\"name\":\"notes\"") != null);
    try testing.expect(std.mem.indexOf(u8, src.body, "\"documents\":2") != null);
    try testing.expect(std.mem.indexOf(u8, src.body, "\"state\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, src.body, "\"configured\":false") != null); // the removed source
    try testing.expect(std.mem.indexOf(u8, src.body, "\"enabled\":false") != null);

    const jobs = try f.call(a, .GET, "/api/v1/admin/jobs", .{ .auth = auth });
    try testing.expect(std.mem.indexOf(u8, jobs.body, "\"submitted\":2") != null);
    try testing.expect(std.mem.indexOf(u8, jobs.body, "\"started_at\":1709634030") != null);
    // Why items were skipped: every reason is present, with its count.
    try testing.expect(std.mem.indexOf(u8, jobs.body, "\"skip_reasons\":{\"robots\":2,\"network\":0,\"certificate\":0,\"http_status\":1,") != null);
    const sk = try f.call(a, .GET, "/api/v1/admin/jobs/skipped?job=1", .{ .auth = auth });
    try testing.expectEqual(http.Status.ok, sk.status);
    try testing.expect(std.mem.indexOf(u8, sk.body, "\"skipped\":[]") != null);
    try testing.expectEqual(http.Status.bad_request, (try f.call(a, .GET, "/api/v1/admin/jobs/skipped?job=x", .{ .auth = auth })).status);
    const skp = try f.call(a, .GET, "/jobs/skipped?job=1", .{ .cookie = try f.signIn(a) });
    try testing.expectEqual(http.Status.ok, skp.status);
    try testing.expect(std.mem.indexOf(u8, skp.body, "No examples were recorded") != null);
    const page = try f.call(a, .GET, "/jobs", .{ .auth = auth });
    try testing.expect(std.mem.indexOf(u8, page.body, "(robots=2, http_status=1)") != null);
}

test "password login creates a session that works until it expires" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const wrong = try f.call(a, .POST, "/login", .{ .body = "credential=nope" });
    try testing.expectEqual(http.Status.unauthorized, wrong.status);
    try testing.expect(Fixture.header(wrong, "set-cookie") == null);
    try testing.expect(std.mem.indexOf(u8, wrong.body, "were not accepted") != null);
    try testing.expectEqual(@as(u32, 1), f.app.failures);
    for ([_][]const u8{ "", "credential=", "other=1", "credential" }) |body| {
        const r = try f.call(a, .POST, "/login", .{ .body = body });
        try testing.expectEqual(http.Status.unauthorized, r.status);
    }

    const login = try f.call(a, .POST, "/login", .{ .body = "credential=correct+horse" });
    try testing.expectEqual(http.Status.see_other, login.status);
    const set = Fixture.header(login, "set-cookie").?;
    for ([_][]const u8{ "dks_session=", "HttpOnly", "SameSite=Strict", "Path=/", "Max-Age=28800" }) |part| {
        try testing.expect(std.mem.indexOf(u8, set, part) != null);
    }
    try testing.expect(std.mem.indexOf(u8, set, "Secure") == null);
    try testing.expectEqual(@as(u32, 0), f.app.failures); // success clears the count
    const cookie = set[0..std.mem.indexOfScalar(u8, set, ';').?];

    const dash = try f.call(a, .GET, "/", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.ok, dash.status);
    try testing.expect(std.mem.indexOf(u8, dash.body, ">notes<") != null);
    try testing.expect(std.mem.indexOf(u8, dash.body, "gone&lt;b&gt;") != null); // escaped
    try testing.expect(std.mem.indexOf(u8, dash.body, "gone<b>") == null);
    try testing.expect(std.mem.indexOf(u8, dash.body, "not in the configuration") != null);
    try testing.expect(std.mem.indexOf(u8, dash.body, "9.9.9") != null);
    const jobs = try f.call(a, .GET, "/jobs", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.ok, jobs.status);
    try testing.expect(std.mem.indexOf(u8, jobs.body, "2024-03-05 10:20:30 UTC") != null);

    // Idle for longer than the limit: gone.
    f.app.fake_now_ns.? += 31 * 60 * std.time.ns_per_s;
    const stale = try f.call(a, .GET, "/", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.see_other, stale.status);
}

test "a session is dropped after its absolute lifetime even if used" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);
    // Use it every 20 minutes (always within the idle limit) for 9 hours.
    var minutes: u32 = 0;
    var alive = true;
    while (minutes < 9 * 60) : (minutes += 20) {
        f.app.fake_now_ns.? += 20 * 60 * std.time.ns_per_s;
        const r = try f.call(a, .GET, "/", .{ .cookie = cookie });
        if (r.status != .ok) {
            alive = false;
            break;
        }
    }
    try testing.expect(!alive);
    try testing.expect(minutes >= 8 * 60 - 20); // and not before ~8 hours
}

test "a trailing newline on the form body is ignored" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try f.call(arena.allocator(), .POST, "/login", .{ .body = "credential=correct+horse\r\n" });
    try testing.expectEqual(http.Status.see_other, r.status);
}

test "the token also signs in through the form when used as the credential" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try f.call(a, .POST, "/login", .{ .body = try std.fmt.allocPrint(a, "credential={s}", .{f.token}) });
    try testing.expectEqual(http.Status.see_other, r.status);
}

test "logout needs the session's form token, then ends the session" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);

    const dash = try f.call(a, .GET, "/", .{ .cookie = cookie });
    const csrf = csrfOf(dash.body);

    const none = try f.call(a, .POST, "/logout", .{ .cookie = cookie, .body = "" });
    try testing.expectEqual(http.Status.forbidden, none.status);
    const wrong = try f.call(a, .POST, "/logout", .{ .cookie = cookie, .body = "csrf=00000000000000000000000000000000" });
    try testing.expectEqual(http.Status.forbidden, wrong.status);
    // Still signed in after the refused attempts.
    try testing.expectEqual(http.Status.ok, (try f.call(a, .GET, "/", .{ .cookie = cookie })).status);
    // A bearer token cannot use the form token.
    const via_token = try f.call(a, .POST, "/logout", .{ .auth = try f.bearer(a), .body = try std.fmt.allocPrint(a, "csrf={s}", .{csrf}) });
    try testing.expectEqual(http.Status.see_other, via_token.status);
    try testing.expectEqualStrings("/login", Fixture.header(via_token, "location").?);

    const out = try f.call(a, .POST, "/logout", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}", .{csrf}) });
    try testing.expectEqual(http.Status.see_other, out.status);
    try testing.expect(std.mem.indexOf(u8, Fixture.header(out, "set-cookie").?, "Max-Age=0") != null);
    try testing.expectEqual(http.Status.see_other, (try f.call(a, .GET, "/", .{ .cookie = cookie })).status); // gone
}

test "rotating a credential ends old sessions and old tokens at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);
    const old_auth = try f.bearer(a);
    try testing.expectEqual(http.Status.ok, (try f.call(a, .GET, "/", .{ .cookie = cookie })).status);

    var s = try secrets_mod.load(testing.allocator, testing.io, f.tmp.dir, "admin.toml");
    defer s.deinit(testing.allocator);
    var nt: [secrets_mod.token_len]u8 = undefined;
    _ = try s.newToken(testing.io, &nt);
    try secrets_mod.save(testing.io, f.tmp.dir, "admin.toml", s);

    try testing.expectEqual(http.Status.see_other, (try f.call(a, .GET, "/", .{ .cookie = cookie })).status);
    try testing.expectEqual(http.Status.unauthorized, (try f.call(a, .GET, "/api/v1/admin/status", .{ .auth = old_auth })).status);
    const fresh = try std.fmt.allocPrint(a, "Bearer {s}", .{nt});
    try testing.expectEqual(http.Status.ok, (try f.call(a, .GET, "/api/v1/admin/status", .{ .auth = fresh })).status);
}

test "no credentials, or a readable secrets file, means nothing signs in" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth = try f.bearer(a);

    // Loosen the file mode.
    const file = try f.tmp.dir.openFile(testing.io, "admin.toml", .{});
    try file.setPermissions(testing.io, Io.File.Permissions.fromMode(0o644));
    file.close(testing.io);
    try testing.expectEqual(http.Status.unauthorized, (try f.call(a, .GET, "/api/v1/admin/status", .{ .auth = auth })).status);
    const login = try f.call(a, .POST, "/login", .{ .body = "credential=correct+horse" });
    try testing.expectEqual(http.Status.service_unavailable, login.status);

    // Remove it altogether.
    try f.tmp.dir.deleteFile(testing.io, "admin.toml");
    try testing.expectEqual(http.Status.unauthorized, (try f.call(a, .GET, "/api/v1/admin/status", .{ .auth = auth })).status);
    try testing.expectEqual(http.Status.unauthorized, (try f.call(a, .POST, "/login", .{ .body = "credential=correct+horse" })).status);
}

test "methods and routes: wrong methods are 405, unknown paths 404" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth = try f.bearer(a);

    const put = try f.call(a, .PUT, "/", .{ .auth = auth });
    try testing.expectEqual(http.Status.method_not_allowed, put.status);
    try testing.expect(Fixture.header(put, "allow") != null);
    try testing.expectEqual(http.Status.method_not_allowed, (try f.call(a, .POST, "/api/v1/admin/status", .{ .auth = auth })).status);
    try testing.expectEqual(http.Status.method_not_allowed, (try f.call(a, .GET, "/logout", .{})).status);
    try testing.expectEqual(http.Status.not_found, (try f.call(a, .GET, "/nope", .{ .auth = auth })).status);
    try testing.expectEqual(http.Status.not_found, (try f.call(a, .GET, "/api/v1/admin/nope", .{ .auth = auth })).status);
    // The public routes do not exist here, and the style sheet needs no sign-in.
    try testing.expectEqual(http.Status.not_found, (try f.call(a, .GET, "/search?q=x", .{ .auth = auth })).status);
    try testing.expectEqual(http.Status.ok, (try f.call(a, .GET, "/assets/style.css", .{})).status);
}

test "failed attempts slow down, with a ceiling; concurrent verifications are capped" {
    try testing.expectEqual(@as(u64, 0), App.delayMs(0));
    try testing.expectEqual(@as(u64, 0), App.delayMs(3));
    try testing.expectEqual(@as(u64, 250), App.delayMs(4));
    try testing.expectEqual(@as(u64, 500), App.delayMs(5));
    try testing.expectEqual(@as(u64, 5_000), App.delayMs(100));
    try testing.expectEqual(@as(u64, 5_000), App.delayMs(std.math.maxInt(u32)));

    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..5) |_| _ = try f.call(a, .POST, "/login", .{ .body = "credential=wrong" });
    try testing.expectEqual(@as(u32, 5), f.app.failures);
    // The count is forgotten after a quiet period.
    f.app.fake_now_ns.? += 16 * 60 * std.time.ns_per_s;
    _ = try f.call(a, .POST, "/login", .{ .body = "credential=wrong" });
    try testing.expectEqual(@as(u32, 1), f.app.failures);

    // Stale failures stop delaying anyone after the quiet period.
    f.app.failures = 12;
    f.app.last_failure_ns = f.app.fake_now_ns.?;
    try testing.expectEqual(@as(u32, 12), f.app.effectiveFailures());
    f.app.fake_now_ns.? += 16 * 60 * std.time.ns_per_s;
    try testing.expectEqual(@as(u32, 0), f.app.effectiveFailures());

    // Many attempts waiting out a delay: the extra ones are turned away at once.
    f.app.skip_delay = false;
    f.app.failures = 8; // a 4 s delay
    f.app.last_failure_ns = f.app.fake_now_ns.?;
    f.app.waiting.store(max_waiting, .release);
    const throttled = try f.call(a, .POST, "/login", .{ .body = "credential=correct+horse" });
    try testing.expectEqual(http.Status.too_many_requests, throttled.status);
    try testing.expect(Fixture.header(throttled, "retry-after") != null);
    f.app.waiting.store(0, .release);
    f.app.failures = 0;
    f.app.skip_delay = true;

    f.app.verifying.store(max_verifications, .release);
    const busy = try f.call(a, .POST, "/login", .{ .body = "credential=correct+horse" });
    try testing.expectEqual(http.Status.service_unavailable, busy.status);
    try testing.expect(Fixture.header(busy, "retry-after") != null);
}

test "cookie parsing and the Secure option" {
    try testing.expectEqualStrings("abc", cookieValue("a=1; dks_session=abc; b=2", "dks_session").?);
    try testing.expectEqualStrings("abc", cookieValue("dks_session=abc", "dks_session").?);
    try testing.expect(cookieValue("xdks_session=abc", "dks_session") == null);
    try testing.expect(cookieValue("dks_session", "dks_session") == null);
    try testing.expect(cookieValue("", "dks_session") == null);

    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.app.opts.cookie_secure = true;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try f.call(arena.allocator(), .POST, "/login", .{ .body = "credential=correct+horse" });
    try testing.expect(std.mem.indexOf(u8, Fixture.header(r, "set-cookie").?, "; Secure") != null);
}

test "responses carry the security headers; access labels never include queries" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try f.call(a, .GET, "/login", .{});
    try testing.expectEqualStrings("nosniff", Fixture.header(r, "x-content-type-options").?);
    try testing.expect(Fixture.header(r, "content-security-policy") != null);
    try testing.expectEqualStrings("/login", App.label("/login?secret=1"));
    try testing.expectEqualStrings("other", App.label("/api/v1/admin/status/../x"));
}

test "actions are refused when they are not enabled" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const api = try f.call(a, .POST, "/api/v1/admin/imports", .{ .auth = try f.bearer(a), .body = "source=notes" });
    try testing.expectEqual(http.Status.forbidden, api.status);
    try testing.expect(std.mem.indexOf(u8, api.body, "actions_disabled") != null);
    const cookie = try f.signIn(a);
    const dash = try f.call(a, .GET, "/", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, dash.body, "turned off") != null);
    try testing.expect(std.mem.indexOf(u8, dash.body, "/actions/import") == null); // no buttons
    const form = try f.call(a, .POST, "/actions/import", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&source=notes", .{csrfOf(dash.body)}) });
    try testing.expectEqual(http.Status.forbidden, form.status);
    const st = try f.call(a, .GET, "/api/v1/admin/status", .{ .auth = try f.bearer(a) });
    try testing.expect(std.mem.indexOf(u8, st.body, "\"actions\":false") != null);
}

test "actions need authentication, the right method, and for sessions a form token" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No credentials: nothing starts.
    try testing.expectEqual(http.Status.unauthorized, (try f.call(a, .POST, "/api/v1/admin/imports", .{ .body = "source=notes" })).status);
    try testing.expectEqual(http.Status.see_other, (try f.call(a, .POST, "/actions/import", .{ .body = "source=notes" })).status);
    // Wrong methods.
    try testing.expectEqual(http.Status.method_not_allowed, (try f.call(a, .GET, "/actions/import", .{ .auth = try f.bearer(a) })).status);
    try testing.expectEqual(http.Status.method_not_allowed, (try f.call(a, .GET, "/api/v1/admin/imports/cancel", .{ .auth = try f.bearer(a) })).status);
    try testing.expectEqual(http.Status.method_not_allowed, (try f.call(a, .PUT, "/api/v1/admin/imports", .{ .auth = try f.bearer(a) })).status);

    // A session without (or with a wrong) form token is refused, and nothing ran.
    const cookie = try f.signIn(a);
    const none = try f.call(a, .POST, "/actions/import", .{ .cookie = cookie, .body = "source=notes" });
    try testing.expectEqual(http.Status.forbidden, none.status);
    const wrong = try f.call(a, .POST, "/actions/import", .{ .cookie = cookie, .body = "csrf=00000000000000000000000000000000&source=notes" });
    try testing.expectEqual(http.Status.forbidden, wrong.status);
    try testing.expect((try f.manager.lastResult(a)) == null);
    try testing.expect((try f.manager.current(a)) == null);
}

test "start an import through the API, watch it finish, and see it on the dashboard" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth = try f.bearer(a);

    const bad = try f.call(a, .POST, "/api/v1/admin/imports", .{ .auth = auth, .body = "source=nope" });
    try testing.expectEqual(http.Status.not_found, bad.status);
    const off = try f.call(a, .POST, "/api/v1/admin/imports", .{ .auth = auth, .body = "source=wiki" });
    try testing.expectEqual(http.Status.conflict, off.status); // disabled in the configuration
    try testing.expect(std.mem.indexOf(u8, off.body, "source_disabled") != null);

    const ok = try f.call(a, .POST, "/api/v1/admin/imports", .{ .auth = auth, .body = "source=notes" });
    try testing.expectEqual(http.Status.accepted, ok.status);
    try testing.expect(std.mem.indexOf(u8, ok.body, "\"started\":\"notes\"") != null);
    try f.waitIdle();

    const cur = try f.call(a, .GET, "/api/v1/admin/imports", .{ .auth = auth });
    try testing.expect(std.mem.indexOf(u8, cur.body, "\"actions\":true") != null);
    try testing.expect(std.mem.indexOf(u8, cur.body, "\"running\":null") != null);
    try testing.expect(std.mem.indexOf(u8, cur.body, "\"state\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, cur.body, "\"submitted\":2") != null);

    // The dashboard offers the button and reports the result.
    const cookie = try f.signIn(a);
    const dash = try f.call(a, .GET, "/", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, dash.body, "action=\"/actions/import\"") != null);
    try testing.expect(std.mem.indexOf(u8, dash.body, "Import notes") != null);
    try testing.expect(std.mem.indexOf(u8, dash.body, "Import wiki") == null); // disabled sources get no button
    try testing.expect(std.mem.indexOf(u8, dash.body, "Last operation started from here") != null);
}

test "maintenance: check, backup, confirmed removal, and the page" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var backups = testing.tmpDir(.{});
    defer backups.cleanup();
    var bp: [160]u8 = undefined;
    const bdir = try std.fmt.bufPrint(&bp, ".zig-cache/tmp/{s}", .{backups.sub_path});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const auth = try f.bearer(a);

    // Nothing is possible without credentials.
    const anon = try f.call(a, .POST, "/api/v1/admin/maintenance", .{ .body = "op=check" });
    try testing.expectEqual(http.Status.unauthorized, anon.status);
    const get = try f.call(a, .GET, "/api/v1/admin/maintenance", .{ .auth = auth });
    try testing.expectEqual(http.Status.method_not_allowed, get.status);

    _ = try f.call(a, .POST, "/api/v1/admin/imports", .{ .auth = auth, .body = "source=notes" });
    try f.waitIdle();

    const unknown = try f.call(a, .POST, "/api/v1/admin/maintenance", .{ .auth = auth, .body = "op=format" });
    try testing.expectEqual(http.Status.bad_request, unknown.status);
    try testing.expect(std.mem.indexOf(u8, unknown.body, "unknown_operation") != null);

    const check = try f.call(a, .POST, "/api/v1/admin/maintenance", .{ .auth = auth, .body = "op=check" });
    try testing.expectEqual(http.Status.accepted, check.status);
    try f.waitIdle();
    const after = try f.call(a, .GET, "/api/v1/admin/imports", .{ .auth = auth });
    try testing.expect(std.mem.indexOf(u8, after.body, "\"op\":\"check\"") != null);
    try testing.expect(std.mem.indexOf(u8, after.body, "state.db ok: 5 documents") != null); // the fixture's own records

    // Backup needs a configured folder.
    const nobak = try f.call(a, .POST, "/api/v1/admin/maintenance", .{ .auth = auth, .body = "op=backup" });
    try testing.expectEqual(http.Status.conflict, nobak.status);
    try testing.expect(std.mem.indexOf(u8, nobak.body, "not_configured") != null);
    f.manager.opts.backup_dir = bdir;
    const bak = try f.call(a, .POST, "/api/v1/admin/maintenance", .{ .auth = auth, .body = "op=backup" });
    try testing.expectEqual(http.Status.accepted, bak.status);
    try f.waitIdle();

    // Removal must be confirmed.
    const noconf = try f.call(a, .POST, "/api/v1/admin/maintenance", .{ .auth = auth, .body = "op=remove&source=notes" });
    try testing.expectEqual(http.Status.bad_request, noconf.status);
    try testing.expect(std.mem.indexOf(u8, noconf.body, "confirmation_required") != null);
    const wrong = try f.call(a, .POST, "/api/v1/admin/maintenance", .{ .auth = auth, .body = "op=remove&source=notes&confirm=nope" });
    try testing.expectEqual(http.Status.bad_request, wrong.status);

    // The page shows the buttons only to a signed-in session, with its token.
    const cookie = try f.signIn(a);
    const page = try f.call(a, .GET, "/maintenance", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.ok, page.status);
    try testing.expect(std.mem.indexOf(u8, page.body, "Run the check") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "Back up now") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "type the name") != null);
    const csrf = csrfOf(page.body);
    const form = try std.fmt.allocPrint(a, "op=remove&source=notes&confirm=notes&csrf={s}", .{csrf});
    const bad_csrf = try f.call(a, .POST, "/actions/maintenance", .{ .cookie = cookie, .body = "op=remove&source=notes&confirm=notes&csrf=wrong" });
    try testing.expectEqual(http.Status.forbidden, bad_csrf.status);
    const done = try f.call(a, .POST, "/actions/maintenance", .{ .cookie = cookie, .body = form });
    try testing.expectEqual(http.Status.see_other, done.status);
    try f.waitIdle();
    const last = try f.call(a, .GET, "/api/v1/admin/imports", .{ .auth = auth });
    try testing.expect(std.mem.indexOf(u8, last.body, "\"op\":\"remove\"") != null);
    // The fixture's database already held two records for "notes", plus the two imported files.
    try testing.expect(std.mem.indexOf(u8, last.body, "Removed 4 documents of notes") != null);

    // Without a session (token only) the page explains how to proceed.
    const tok = try f.call(a, .GET, "/maintenance", .{ .auth = auth });
    try testing.expect(std.mem.indexOf(u8, tok.body, "Sign in with the password") != null);
}

test "Access: collections are listed, keys are made (shown once), listed and removed, with the form token" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);
    const colls = [_]dk.config.Collection{.{ .name = "books", .description = "Books", .sources = &.{"notes"} }};
    f.app.opts.collections = &colls;
    f.app.opts.data_dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{f.tmp.sub_path});
    f.app.opts.anonymous_collections = &.{"books"};

    const page = try f.call(a, .GET, "/access", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.ok, page.status);
    try testing.expect(std.mem.indexOf(u8, page.body, "No keys yet") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "<strong>books</strong>") != null);
    const csrf = csrfOf(page.body);

    const bad_csrf = try f.call(a, .POST, "/actions/key-add", .{ .cookie = cookie, .body = "csrf=wrong&name=x&all=1" });
    try testing.expectEqual(http.Status.forbidden, bad_csrf.status);
    const no_scope = try f.call(a, .POST, "/actions/key-add", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&name=x", .{csrf}) });
    try testing.expectEqual(http.Status.bad_request, no_scope.status);
    const unknown = try f.call(a, .POST, "/actions/key-add", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&name=x&collection=nope", .{csrf}) });
    try testing.expectEqual(http.Status.bad_request, unknown.status);

    const made = try f.call(a, .POST, "/actions/key-add", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&name=laptop&collection=books", .{csrf}) });
    try testing.expectEqual(http.Status.ok, made.status);
    try testing.expect(std.mem.indexOf(u8, made.body, "dkk_") != null);
    try testing.expect(std.mem.indexOf(u8, made.body, "only this once") != null);
    const dup = try f.call(a, .POST, "/actions/key-add", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&name=laptop&all=1", .{csrf}) });
    try testing.expectEqual(http.Status.conflict, dup.status);

    // Listed afterwards, without the key itself; then removed.
    const listed = try f.call(a, .GET, "/access", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, listed.body, "laptop") != null);
    try testing.expect(std.mem.indexOf(u8, listed.body, "dkk_") == null);
    const at = std.mem.indexOf(u8, listed.body, "name=\"which\" value=\"").? + "name=\"which\" value=\"".len;
    const id = listed.body[at .. at + 8];
    const removed = try f.call(a, .POST, "/actions/key-remove", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&which={s}", .{ csrf, id }) });
    try testing.expectEqual(http.Status.see_other, removed.status);
    try testing.expect(std.mem.indexOf(u8, (try f.call(a, .GET, "/access", .{ .cookie = cookie })).body, "No keys yet") != null);
    try testing.expectEqual(http.Status.not_found, (try f.call(a, .POST, "/actions/key-remove", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&which=ffffffff", .{csrf}) })).status);
}

test "Access: peers are listed with their status and can be tested" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);
    const none = try f.call(a, .GET, "/access", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, none.body, "No peers") != null);

    const cfgs = [_]dk.config.Peer{.{ .name = "office", .url = "http://127.0.0.1:1", .timeout_ms = 500 }};
    const svc = try dk.peers.Service.init(testing.allocator, testing.io, "home", &cfgs);
    defer svc.deinit();
    f.app.opts.peers = svc;
    f.app.opts.node_name = "home";
    const page = try f.call(a, .GET, "/access", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, page.body, "<strong>office</strong>") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "not yet") != null);
    const csrf = csrfOf(page.body);
    try testing.expectEqual(http.Status.forbidden, (try f.call(a, .POST, "/actions/peer-test", .{ .cookie = cookie, .body = "csrf=wrong&peer=office" })).status);
    try testing.expectEqual(http.Status.not_found, (try f.call(a, .POST, "/actions/peer-test", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&peer=nobody", .{csrf}) })).status);
    const tested = try f.call(a, .POST, "/actions/peer-test", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&peer=office", .{csrf}) });
    try testing.expectEqual(http.Status.ok, tested.status);
    try testing.expect(std.mem.indexOf(u8, tested.body, "could not connect") != null);
    // Remembered: the next view shows the failure and the backoff.
    const after = try f.call(a, .GET, "/access", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, after.body, "down in") != null);
    try testing.expect(std.mem.indexOf(u8, after.body, "1 in a row") != null);
}

test "ZIM files: the page explains when no folder is set, confirms before downloading, and only takes kiwix.org addresses" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);

    const off = try f.call(a, .GET, "/zim", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.ok, off.status);
    try testing.expect(std.mem.indexOf(u8, off.body, "zim_dir") != null);

    f.manager.opts.zim_dir = "/nonexistent-dksearch-zim-dir";
    const ok_url = "https%3A%2F%2Fdownload.kiwix.org%2Fzim%2Fwikipedia%2Fa_2026-01.zim.meta4";
    const confirm = try f.call(a, .GET, try std.fmt.allocPrint(a, "/zim?file=a_2026-01.zim&meta4={s}&size=1048576", .{ok_url}), .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, confirm.body, "Download this file?") != null);
    try testing.expect(std.mem.indexOf(u8, confirm.body, "1.0 MiB") != null or std.mem.indexOf(u8, confirm.body, "MiB") != null);
    try testing.expect(std.mem.indexOf(u8, confirm.body, "/nonexistent-dksearch-zim-dir") != null);
    const csrf = csrfOf(confirm.body);

    const evil = try f.call(a, .GET, "/zim?file=a.zim&meta4=https%3A%2F%2Fevil.example%2Fa.zim.meta4&size=1", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, evil.body, "cannot be downloaded") != null);
    const lookalike = try f.call(a, .GET, "/zim?file=a.zim&meta4=https%3A%2F%2Fkiwix.org.evil.example%2Fa.zim.meta4&size=1", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, lookalike.body, "cannot be downloaded") != null);
    const userinfo = try f.call(a, .GET, "/zim?file=a.zim&meta4=https%3A%2F%2Fkiwix.org%40evil.example%2Fa.zim.meta4&size=1", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, userinfo.body, "cannot be downloaded") != null);

    const bad_csrf = try f.call(a, .POST, "/actions/zim", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf=wrong&file=a_2026-01.zim&meta4={s}", .{ok_url}) });
    try testing.expectEqual(http.Status.forbidden, bad_csrf.status);
    const refused = try f.call(a, .POST, "/actions/zim", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&file=a_2026-01.zim&meta4=https%3A%2F%2Fevil.example%2Fa.zim.meta4", .{csrf}) });
    try testing.expectEqual(http.Status.bad_request, refused.status);
    const bad_name = try f.call(a, .POST, "/actions/zim", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&file=..%2Fa.zim&meta4={s}", .{ csrf, ok_url }) });
    try testing.expectEqual(http.Status.bad_request, bad_name.status);
}

test "sources can be added, edited, disabled and deleted from the interface, and apply at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A configuration file with one source, loaded the way `serve` would.
    const original =
        \\# my config
        \\[[source]]
        \\name = "notes"
        \\kind = "files"
        \\path = "/home/me/notes"
        \\
    ;
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "cfg.toml", .data = original });
    var pb: [200]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/cfg.toml", .{f.tmp.sub_path});
    var d: dk.config.Diagnostic = .{};
    var cfg0 = try dk.config.loadFromSlice(testing.allocator, cfg_path, original, &d);
    defer cfg0.deinit();
    var store = dk.sourcestore.Store.init(testing.allocator, testing.io, cfg0.sources);
    defer store.deinit();
    f.app.opts.store = &store;
    f.app.opts.config_path = cfg_path;
    f.manager.opts.store = &store;

    const cookie = try f.signIn(a);
    const list = try f.call(a, .GET, "/sources", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, list.body, "Add a source") != null);
    const csrf = csrfOf(list.body);

    // The add form is there; saving a valid source takes effect at once.
    const form = try f.call(a, .GET, "/sources/edit?kind=feeds", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.ok, form.status);
    try testing.expect(std.mem.indexOf(u8, form.body, "name=\"options\"") != null); // for settings the form has no field for
    try testing.expect(std.mem.indexOf(u8, form.body, "name=\"opt_path\"") != null); // a field for each setting of the kind
    // Without a kind the page offers the choice of kinds instead of an empty form.
    const chooser = try f.call(a, .GET, "/sources/edit", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, chooser.body, "opt_path") == null);
    const add = try std.fmt.allocPrint(a, "op=save&form=1&csrf={s}&original=&name=news&kind=feeds&enabled=1&retain_text=1&rights=restricted&options=path+%3D+%22%2Fsrv%2Ffeeds%22", .{csrf});
    const saved = try f.call(a, .POST, "/actions/sources", .{ .cookie = cookie, .body = add });
    try testing.expectEqual(http.Status.see_other, saved.status);
    try testing.expectEqualStrings("/sources?done=saved", Fixture.header(saved, "location").?);
    try testing.expectEqual(@as(usize, 2), store.snapshot().len);
    const file = try f.tmp.dir.readFileAlloc(testing.io, "cfg.toml", a, .limited(10_000));
    try testing.expect(std.mem.indexOf(u8, file, "# my config") != null);
    try testing.expect(std.mem.indexOf(u8, file, "name = \"news\"") != null);
    const bak = try f.tmp.dir.readFileAlloc(testing.io, "cfg.toml.bak", a, .limited(10_000));
    try testing.expectEqualStrings(original, bak);
    const after = try f.call(a, .GET, "/sources?done=saved", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, after.body, "news") != null);
    try testing.expect(std.mem.indexOf(u8, after.body, "Saved.") != null);
    // The dashboard's import buttons follow the new list.
    const dash = try f.call(a, .GET, "/", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, dash.body, "Import news") != null);

    // The form's own fields: typed, quoted, and read back into the fields when editing.
    const fielded = try std.fmt.allocPrint(a, "op=save&form=1&fields=1&csrf={s}&original=&name=pages&kind=crawl&enabled=1&retain_text=1&opt_seeds_file=%2Fetc%2Fseeds.txt&opt_user_agent=test%2F1.0+%28me%29&opt_max_depth=1&opt_follow_external=1&opt_delay_ms=&options=", .{csrf});
    const fsaved = try f.call(a, .POST, "/actions/sources", .{ .cookie = cookie, .body = fielded });
    try testing.expectEqual(http.Status.see_other, fsaved.status);
    const file2 = try f.tmp.dir.readFileAlloc(testing.io, "cfg.toml", a, .limited(10_000));
    try testing.expect(std.mem.indexOf(u8, file2, "max_depth = 1") != null);
    try testing.expect(std.mem.indexOf(u8, file2, "follow_external = true") != null);
    try testing.expect(std.mem.indexOf(u8, file2, "seeds_file = \"/etc/seeds.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, file2, "delay_ms") == null); // an empty field leaves the default
    const refill = try f.call(a, .GET, "/sources/edit?name=pages", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, refill.body, "value=\"/etc/seeds.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, refill.body, "name=\"opt_follow_external\" value=\"1\" checked") != null);
    // A number that is not a number is refused by name.
    const bad_number = try std.fmt.allocPrint(a, "op=save&form=1&fields=1&csrf={s}&original=pages&name=pages&kind=crawl&enabled=1&retain_text=1&opt_seeds_file=%2Fetc%2Fseeds.txt&opt_user_agent=test%2F1.0+%28me%29&opt_delay_ms=fast&options=", .{csrf});
    const bn = try f.call(a, .POST, "/actions/sources", .{ .cookie = cookie, .body = bad_number });
    try testing.expectEqual(http.Status.bad_request, bn.status);
    try testing.expect(std.mem.indexOf(u8, bn.body, "delay_ms") != null);
    const del_pages = try std.fmt.allocPrint(a, "op=delete&name=pages&csrf={s}", .{csrf});
    try testing.expectEqual(http.Status.see_other, (try f.call(a, .POST, "/actions/sources", .{ .cookie = cookie, .body = del_pages })).status);
    try testing.expectEqual(@as(usize, 2), store.snapshot().len);

    // A bad edit is refused with the reason, the form comes back filled in, the file is untouched.
    const before_bad = try f.tmp.dir.readFileAlloc(testing.io, "cfg.toml", a, .limited(10_000));
    const bad = try std.fmt.allocPrint(a, "op=save&form=1&csrf={s}&original=&name=oops&kind=files&enabled=1&retain_text=1&options=bogus+%3D+1", .{csrf});
    const refused = try f.call(a, .POST, "/actions/sources", .{ .cookie = cookie, .body = bad });
    try testing.expectEqual(http.Status.bad_request, refused.status);
    try testing.expect(std.mem.indexOf(u8, refused.body, "unknown option") != null);
    try testing.expect(std.mem.indexOf(u8, refused.body, "value=\"oops\"") != null);
    const after_bad = try f.tmp.dir.readFileAlloc(testing.io, "cfg.toml", a, .limited(10_000));
    try testing.expectEqualStrings(before_bad, after_bad);
    try testing.expectEqual(@as(usize, 2), store.snapshot().len);

    // Wrong or missing token: refused. Bearer tokens use the API.
    const nocsrf = try f.call(a, .POST, "/actions/sources", .{ .cookie = cookie, .body = "op=delete&name=news&csrf=nope" });
    try testing.expectEqual(http.Status.forbidden, nocsrf.status);
    const auth = try f.bearer(a);
    const off = try f.call(a, .POST, "/api/v1/admin/sources", .{ .auth = auth, .body = "op=toggle&name=news&enabled=0" });
    try testing.expectEqual(http.Status.ok, off.status);
    try testing.expect(!store.snapshot()[1].enabled);
    const gone = try f.call(a, .POST, "/api/v1/admin/sources", .{ .auth = auth, .body = "op=delete&name=news" });
    try testing.expectEqual(http.Status.ok, gone.status);
    try testing.expectEqual(@as(usize, 1), store.snapshot().len);
    const missing = try f.call(a, .POST, "/api/v1/admin/sources", .{ .auth = auth, .body = "op=delete&name=ghost" });
    try testing.expectEqual(http.Status.bad_request, missing.status);
    try testing.expect(std.mem.indexOf(u8, missing.body, "invalid_source") != null);

    // Without a configuration file there is nothing to edit.
    f.app.opts.config_path = null;
    const none = try f.call(a, .POST, "/api/v1/admin/sources", .{ .auth = auth, .body = "op=delete&name=notes" });
    try testing.expectEqual(http.Status.conflict, none.status);
    try testing.expect(std.mem.indexOf(u8, none.body, "no_config_file") != null);
    f.manager.opts.store = null;
}

test "settings: shown with their values, saved through the same checks, refused with the reason" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original =
        \\# my config
        \\[search]
        \\fuzzy = "off"
        \\
        \\[[source]]
        \\name = "notes"
        \\kind = "files"
        \\path = "/home/me/notes"
        \\
    ;
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "cfg.toml", .data = original });
    var pb: [200]u8 = undefined;
    const cfg_path = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/cfg.toml", .{f.tmp.sub_path});
    var d: dk.config.Diagnostic = .{};
    var cfg0 = try dk.config.loadFromSlice(testing.allocator, cfg_path, original, &d);
    defer cfg0.deinit();
    var store = dk.sourcestore.Store.init(testing.allocator, testing.io, cfg0.sources);
    defer store.deinit();
    f.app.opts.store = &store;
    f.app.opts.config_path = cfg_path;
    f.manager.opts.store = &store;

    const cookie = try f.signIn(a);
    const page = try f.call(a, .GET, "/settings", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.ok, page.status);
    try testing.expect(std.mem.indexOf(u8, page.body, "name=\"s_search_fuzzy\"") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "<option value=\"off\" selected>off</option>") != null); // from the file
    try testing.expect(std.mem.indexOf(u8, page.body, "Save settings") != null);
    const csrf = csrfOf(page.body);

    // A good save: the file changes, comments and sources stay, the old file is kept.
    const good = try std.fmt.allocPrint(a, "csrf={s}&s_search_fuzzy=always&s_search_query_syntax=advanced&s_search_query_timeout_ms=9000&s_search_regex=1&s_server_port=&s_admin_cookie_secure=1", .{csrf});
    const saved = try f.call(a, .POST, "/actions/settings", .{ .cookie = cookie, .body = good });
    try testing.expectEqual(http.Status.see_other, saved.status);
    try testing.expectEqualStrings("/settings?done=saved", Fixture.header(saved, "location").?);
    const file = try f.tmp.dir.readFileAlloc(testing.io, "cfg.toml", a, .limited(10_000));
    try testing.expect(std.mem.indexOf(u8, file, "# my config") != null);
    try testing.expect(std.mem.indexOf(u8, file, "fuzzy = \"always\"") != null);
    try testing.expect(std.mem.indexOf(u8, file, "query_timeout_ms = 9000") != null);
    try testing.expect(std.mem.indexOf(u8, file, "cookie_secure = true") != null);
    try testing.expect(std.mem.indexOf(u8, file, "query_syntax") == null); // the default is not written
    try testing.expect(std.mem.indexOf(u8, file, "name = \"notes\"") != null);
    const bak = try f.tmp.dir.readFileAlloc(testing.io, "cfg.toml.bak", a, .limited(10_000));
    try testing.expectEqualStrings(original, bak);
    const again = try f.call(a, .GET, "/settings?done=saved", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, again.body, "restart it") != null);
    try testing.expect(std.mem.indexOf(u8, again.body, "value=\"9000\"") != null);

    // A refused save says why, keeps what was typed, and leaves the file alone.
    const before = try f.tmp.dir.readFileAlloc(testing.io, "cfg.toml", a, .limited(10_000));
    const bad = try std.fmt.allocPrint(a, "csrf={s}&s_search_fuzzy=sometimes&s_search_query_timeout_ms=999999", .{csrf});
    const refused = try f.call(a, .POST, "/actions/settings", .{ .cookie = cookie, .body = bad });
    try testing.expectEqual(http.Status.bad_request, refused.status);
    try testing.expect(std.mem.indexOf(u8, refused.body, "fuzzy") != null);
    try testing.expect(std.mem.indexOf(u8, refused.body, "value=\"999999\"") != null);
    try testing.expectEqualStrings(before, try f.tmp.dir.readFileAlloc(testing.io, "cfg.toml", a, .limited(10_000)));
    const wrong = try f.call(a, .POST, "/actions/settings", .{ .cookie = cookie, .body = "csrf=nope&s_search_fuzzy=off" });
    try testing.expectEqual(http.Status.forbidden, wrong.status);

    // Without a configuration file there is nothing to show.
    f.app.opts.config_path = null;
    const none = try f.call(a, .GET, "/settings", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, none.body, "without <code>--config</code>") != null);
    f.manager.opts.store = null;
}

test "every kind's starting template is valid as it stands, and the chooser leads to it" {
    // Whoever picks a kind and saves without editing must get a valid source.
    for (kind_infos) |k| {
        errdefer std.debug.print("template for {s} is not valid\n", .{k.kind});
        var problem: dk.sourceedit.Problem = .{};
        const out = try dk.sourceedit.apply(testing.allocator, "", .{ .save = .{ .original = null, .spec = .{ .name = "demo", .kind = k.kind, .options = k.template } } }, &problem);
        testing.allocator.free(out);
    }
    // Every kind this build has appears in the chooser, with a link that prefills the form.
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.toml", .data = "" });
    var pb: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/c.toml", .{tmp.sub_path});
    var d: dk.config.Diagnostic = .{};
    var cfg0 = try dk.config.loadFromSlice(testing.allocator, path, "", &d);
    defer cfg0.deinit();
    var store = dk.sourcestore.Store.init(testing.allocator, testing.io, cfg0.sources);
    defer store.deinit();
    f.app.opts.store = &store;
    f.app.opts.config_path = path;
    f.manager.opts.store = &store;
    defer f.manager.opts.store = null;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);
    const chooser = try f.call(a, .GET, "/sources/new", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.ok, chooser.status);
    for (kind_infos) |k| {
        if (!kindAvailable(k.kind)) continue;
        const link = try std.fmt.allocPrint(a, "href=\"/sources/edit?kind={s}\"", .{k.kind});
        try testing.expect(std.mem.indexOf(u8, chooser.body, link) != null);
    }
    const form = try f.call(a, .GET, "/sources/edit?kind=archive", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, form.body, "collection:prelinger") != null);
    try testing.expect(std.mem.indexOf(u8, form.body, "value=\"archive\"") != null); // a suggested name
    try testing.expect(std.mem.indexOf(u8, form.body, "About Internet Archive items") != null);
}

test "a form post with the session's token starts an import; a busy data directory is refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);
    const dash = try f.call(a, .GET, "/", .{ .cookie = cookie });
    const csrf = csrfOf(dash.body);

    // Another process holds the writer lock.
    const held = try dk.maintenance.WriterLock.acquire(testing.io, f.tmp.dir, "write.lock");
    const locked = try f.call(a, .POST, "/actions/import", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&source=notes", .{csrf}) });
    try testing.expectEqual(http.Status.conflict, locked.status);
    held.release(testing.io);

    const r = try f.call(a, .POST, "/actions/import", .{ .cookie = cookie, .body = try std.fmt.allocPrint(a, "csrf={s}&source=notes", .{csrf}) });
    try testing.expectEqual(http.Status.see_other, r.status);
    try testing.expectEqualStrings("/", Fixture.header(r, "location").?);
    try f.waitIdle();
    try testing.expect((try f.manager.lastResult(a)) != null);

    // Cancelling with nothing running is harmless.
    const c = try f.call(a, .POST, "/api/v1/admin/imports/cancel", .{ .auth = try f.bearer(a) });
    try testing.expectEqual(http.Status.ok, c.status);
    try testing.expect(std.mem.indexOf(u8, c.body, "\"cancelling\":false") != null);
}

const FakeSearcher = struct {
    result: dk.search.Error!dk.search.Page,
    last_text: []const u8 = "",

    fn search(ptr: *anyopaque, _: Allocator, q: dk.search.Query) dk.search.Error!dk.search.Page {
        const self: *FakeSearcher = @ptrCast(@alignCast(ptr));
        self.last_text = q.text;
        return self.result;
    }
    fn searcher(self: *FakeSearcher) dk.search.Searcher {
        return .{ .ptr = self, .vtable = &.{ .search = search } };
    }
};

test "query testing page and API show scores, escape everything, and need sign-in" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const hits = [_]dk.search.Hit{
        .{ .id = @splat(0xab), .connector = "wiki<i>", .url = "https://e.org/?a=1&b=2", .title = "T <b>1</b>", .snippet = "x \x02hit\x03 <y>", .score = 12.5 },
        .{ .id = @splat(0x01), .connector = "c", .url = "javascript:alert(1)", .title = null, .snippet = null, .score = 0.25 },
    };
    var fake: FakeSearcher = .{ .result = .{ .hits = &hits, .has_more = true } };
    f.app.opts.searcher = fake.searcher();
    f.app.opts.tokenizer = "porter";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Signed out: refused.
    try testing.expectEqual(http.Status.see_other, (try f.call(a, .GET, "/search?q=x", .{})).status);
    try testing.expectEqual(http.Status.unauthorized, (try f.call(a, .GET, "/api/v1/admin/search?q=x", .{})).status);

    const cookie = try f.signIn(a);
    const page = try f.call(a, .GET, "/search?q=lamp%20%3Cscript%3E", .{ .cookie = cookie });
    try testing.expectEqual(http.Status.ok, page.status);
    try testing.expectEqualStrings("lamp <script>", fake.last_text);
    try testing.expect(std.mem.indexOf(u8, page.body, "12.5000") != null); // the score
    try testing.expect(std.mem.indexOf(u8, page.body, "T &lt;b&gt;1&lt;/b&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "wiki&lt;i&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "href=\"https://e.org/?a=1&amp;b=2\"") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "href=\"javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, page.body, "<mark>hit</mark> &lt;y&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "(untitled)") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "tokenizer: porter") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "value=\"lamp &lt;script&gt;\"") != null); // the box keeps the text, escaped
    try testing.expect(std.mem.indexOf(u8, page.body, "<script>") == null); // no inline script, ever
    try testing.expect(std.mem.indexOf(u8, page.body, "javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, page.body, "abababababababababababababababab") != null);

    // An empty box just shows the form; a failing search says so without details.
    const empty = try f.call(a, .GET, "/search", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, empty.body, "Run query") != null);
    try testing.expect(std.mem.indexOf(u8, empty.body, "<table>") == null);
    fake.result = error.Io;
    const failed = try f.call(a, .GET, "/search?q=x", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, failed.body, "search failed") != null);
    fake.result = error.EmptyQuery;
    try testing.expect(std.mem.indexOf(u8, (try f.call(a, .GET, "/search?q=%21%21", .{ .cookie = cookie })).body, "no searchable terms") != null);

    // API: JSON with scores and the weights.
    fake.result = .{ .hits = &hits, .has_more = false };
    const api = try f.call(a, .GET, "/api/v1/admin/search?q=lamp", .{ .auth = try f.bearer(a) });
    try testing.expectEqual(http.Status.ok, api.status);
    try testing.expect(std.mem.indexOf(u8, api.body, "\"score\":12.5") != null);
    try testing.expect(std.mem.indexOf(u8, api.body, "\"title_weight\":10") != null);
    try testing.expect(std.mem.indexOf(u8, api.body, "\"tokenizer\":\"porter\"") != null);
    fake.result = error.InvalidQuery;
    try testing.expectEqual(http.Status.bad_request, (try f.call(a, .GET, "/api/v1/admin/search?q=x", .{ .auth = try f.bearer(a) })).status);

    // Without a searcher the page is absent.
    f.app.opts.searcher = null;
    try testing.expectEqual(http.Status.not_found, (try f.call(a, .GET, "/search?q=x", .{ .cookie = cookie })).status);
}

test "Access: peers are added to the configuration file, switched and removed from the page, with the reasons for refusals" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.toml", .data = "# mine\n" });
    var pb: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/c.toml", .{tmp.sub_path});
    f.app.opts.config_path = path;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);
    const page = try f.call(a, .GET, "/access", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, page.body, "Add a peer") != null);
    const csrf = csrfOf(page.body);
    const post = struct {
        fn go(fx: *Fixture, ar: Allocator, ck: []const u8, token: []const u8, rest: []const u8) !Response {
            return fx.call(ar, .POST, "/actions/peer-edit", .{ .cookie = ck, .body = try std.fmt.allocPrint(ar, "csrf={s}&{s}", .{ token, rest }) });
        }
    }.go;
    try testing.expectEqual(http.Status.forbidden, (try f.call(a, .POST, "/actions/peer-edit", .{ .cookie = cookie, .body = "csrf=wrong&op=save&name=x&url=http%3A%2F%2Fh" })).status);
    // Refused with the reason: no node name, then a bad address.
    const no_node = try post(&f, a, cookie, csrf, "op=save&name=office&url=https%3A%2F%2Fs.example.org");
    try testing.expectEqual(http.Status.bad_request, no_node.status);
    try testing.expect(std.mem.indexOf(u8, no_node.body, "node.name") != null);
    const bad = try post(&f, a, cookie, csrf, "op=save&node_name=home&name=office&url=ftp%3A%2F%2Fx");
    try testing.expectEqual(http.Status.bad_request, bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "peer[0].url") != null);
    try testing.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(testing.io, "c.toml", a, .limited(4096)), "peer") == null); // nothing was written
    // Added.
    const ok = try post(&f, a, cookie, csrf, "op=save&node_name=home&name=office&url=https%3A%2F%2Fs.example.org%2F&key_file=%2Fetc%2Foffice.key&timeout_ms=900");
    try testing.expectEqual(http.Status.ok, ok.status);
    try testing.expect(std.mem.indexOf(u8, ok.body, "Restart dksearch") != null);
    const file = try tmp.dir.readFileAlloc(testing.io, "c.toml", a, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, file, "# mine") != null);
    try testing.expect(std.mem.indexOf(u8, file, "name = \"home\"") != null);
    try testing.expect(std.mem.indexOf(u8, file, "url = \"https://s.example.org") != null);
    try testing.expect(std.mem.indexOf(u8, file, "timeout_ms = 900") != null);
    // Off, on, removed.
    _ = try post(&f, a, cookie, csrf, "op=toggle&name=office&enabled=0");
    try testing.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(testing.io, "c.toml", a, .limited(4096)), "enabled = false") != null);
    _ = try post(&f, a, cookie, csrf, "op=delete&name=office");
    try testing.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(testing.io, "c.toml", a, .limited(4096)), "office") == null);
    try testing.expectEqual(http.Status.bad_request, (try post(&f, a, cookie, csrf, "op=delete&name=nobody")).status);
}

test "Access: collections are added and removed from the page, written to the configuration file" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.enableJobs();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "[[source]]\nname = \"a\"\nkind = \"files\"\npath = \"/tmp\"\n[[source]]\nname = \"b\"\nkind = \"files\"\npath = \"/tmp\"\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.toml", .data = text });
    var pb: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/c.toml", .{tmp.sub_path});
    var d: dk.config.Diagnostic = .{};
    var cfg0 = try dk.config.loadFromSlice(testing.allocator, path, text, &d);
    defer cfg0.deinit();
    var store = dk.sourcestore.Store.init(testing.allocator, testing.io, cfg0.sources);
    defer store.deinit();
    f.app.opts.store = &store;
    f.app.opts.config_path = path;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookie = try f.signIn(a);
    const page = try f.call(a, .GET, "/access", .{ .cookie = cookie });
    try testing.expect(std.mem.indexOf(u8, page.body, "Add a collection") != null);
    try testing.expect(std.mem.indexOf(u8, page.body, "name=\"source\" value=\"a\"") != null);
    const csrf = csrfOf(page.body);
    const post = struct {
        fn go(fx: *Fixture, ar: Allocator, ck: []const u8, token: []const u8, rest: []const u8) !Response {
            return fx.call(ar, .POST, "/actions/collection-edit", .{ .cookie = ck, .body = try std.fmt.allocPrint(ar, "csrf={s}&{s}", .{ token, rest }) });
        }
    }.go;
    try testing.expectEqual(http.Status.bad_request, (try post(&f, a, cookie, csrf, "op=save&name=empty")).status); // no source ticked
    const bad = try post(&f, a, cookie, csrf, "op=save&name=x&source=ghost");
    try testing.expectEqual(http.Status.bad_request, bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "ghost") != null);
    const ok = try post(&f, a, cookie, csrf, "op=save&name=mine&description=my+stuff&source=a&source=b");
    try testing.expectEqual(http.Status.ok, ok.status);
    try testing.expect(std.mem.indexOf(u8, ok.body, "Restart dksearch") != null);
    const file = try tmp.dir.readFileAlloc(testing.io, "c.toml", a, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, file, "[[collection]]") != null and std.mem.indexOf(u8, file, "sources = [\"a\", \"b\"]") != null);
    _ = try post(&f, a, cookie, csrf, "op=delete&name=mine");
    try testing.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(testing.io, "c.toml", a, .limited(4096)), "collection") == null);
    try testing.expectEqual(http.Status.bad_request, (try post(&f, a, cookie, csrf, "op=delete&name=mine")).status);
}
