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
    version: []const u8,
    session_idle_ms: u64 = 30 * 60 * 1000,
    session_max_ms: u64 = 8 * 60 * 60 * 1000,
    /// Add `Secure` to the session cookie (set when a proxy serves HTTPS).
    cookie_secure: bool = false,
    public_stats: *const server.Stats,
    admin_stats: *const server.Stats,
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
        for ([_][]const u8{ "/", "/jobs", "/login", "/logout", "/assets/style.css", "/api/v1/admin/status", "/api/v1/admin/sources", "/api/v1/admin/jobs" }) |known| {
            if (std.mem.eql(u8, path, known)) return known;
        }
        return "other";
    }

    // --------------------------------------------------------- routing

    const Route = enum { dashboard, jobs, login, logout, style, api_status, api_sources, api_jobs, other };

    fn routeOf(path: []const u8) Route {
        const table = [_]struct { []const u8, Route }{
            .{ "/", .dashboard },
            .{ "/jobs", .jobs },
            .{ "/login", .login },
            .{ "/logout", .logout },
            .{ "/assets/style.css", .style },
            .{ "/api/v1/admin/status", .api_status },
            .{ "/api/v1/admin/sources", .api_sources },
            .{ "/api/v1/admin/jobs", .api_jobs },
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

        if (!head_ok) return methodNotAllowed(arena, is_api, "GET, HEAD");
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
            .api_status => self.apiStatus(arena),
            .api_sources => self.apiSources(arena),
            .api_jobs => self.apiJobs(arena),
            else => unreachable,
        };
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
        counts: []const dk.state_sqlite.SqliteStateStore.SourceCount,
        jobs: []const dk.state_sqlite.Job,
        /// Last job per configured source, same order as `opts.sources`.
        last: []const ?dk.state_sqlite.Job,
        sizes: [3]?u64,
    };

    /// Reads state.db read-only: safe while an import runs, never changes it.
    fn snapshot(self: *App, arena: Allocator, jobs_limit: u32) Snapshot {
        var snap: Snapshot = .{ .counts = &.{}, .jobs = &.{}, .last = &.{}, .sizes = .{ null, null, null } };
        const paths = [_][]const u8{ self.opts.index_path, self.opts.state_path, self.opts.content_path };
        for (paths, 0..) |p, i| {
            const st = Io.Dir.cwd().statFile(self.io, p, .{}) catch continue;
            snap.sizes[i] = st.size;
        }
        var state = dk.state_sqlite.SqliteStateStore.inspect(self.gpa, self.opts.state_path) catch return snap;
        defer state.close();
        snap.counts = state.countsBySource(arena) catch &.{};
        snap.jobs = state.recentJobs(arena, jobs_limit) catch &.{};
        const last = arena.alloc(?dk.state_sqlite.Job, self.opts.sources.len) catch return snap;
        for (self.opts.sources, last) |s, *out| out.* = (state.lastJob(arena, s.name) catch null);
        snap.last = last;
        return snap;
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
        error_message: ?[]const u8,
    };

    fn jsonJob(j: dk.state_sqlite.Job) JsonJob {
        return .{ .id = j.id, .source = j.source, .kind = j.connector, .state = @tagName(j.state), .started_at = j.started_at, .finished_at = j.finished_at, .submitted = j.submitted, .rejected = j.rejected, .error_message = j.error_message };
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
        for (self.opts.sources, 0..) |s, i| {
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
            for (self.opts.sources) |s| if (std.mem.eql(u8, s.name, c.source)) {
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
        writeDashboard(self, w, snap) catch return error.OutOfMemory;
        w.writeAll("</main></body></html>\n") catch return error.OutOfMemory;
        return handler.htmlResponse(arena, .ok, aw.written());
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

fn writePage(w: *Io.Writer, title: []const u8, csrf: ?[]const u8, current: []const u8) Io.Writer.Error!void {
    var tbuf: [96]u8 = undefined;
    try html.writeHead(w, std.fmt.bufPrint(&tbuf, "{s} - dksearch administration", .{title}) catch title);
    try w.writeAll("<body class=\"admin\"><main><header class=\"adminbar\"><span class=\"brand\">dksearch administration</span><nav>");
    for ([_]struct { []const u8, []const u8, []const u8 }{ .{ "dashboard", "/", "Dashboard" }, .{ "jobs", "/jobs", "Jobs" } }) |n| {
        try w.print("<a href=\"{s}\"{s}>{s}</a> ", .{ n[1], if (std.mem.eql(u8, n[0], current)) " aria-current=\"page\"" else "", n[2] });
    }
    try w.writeAll("</nav>");
    if (csrf) |token| {
        try w.writeAll("<form action=\"/logout\" method=\"post\"><input type=\"hidden\" name=\"csrf\" value=\"");
        try html.writeEscaped(w, token);
        try w.writeAll("\"><button type=\"submit\">Sign out</button></form>");
    }
    try w.print("</header><h1>{s}</h1>\n", .{title});
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

fn writeJobCells(w: *Io.Writer, j: dk.state_sqlite.Job) Io.Writer.Error!void {
    try w.print("<td>{s}</td><td>", .{@tagName(j.state)});
    try writeTime(w, j.started_at);
    try w.print("</td><td>{d}</td><td>{d}</td>", .{ j.submitted, j.rejected });
}

fn writeDashboard(app: *App, w: *Io.Writer, snap: App.Snapshot) Io.Writer.Error!void {
    var total: u64 = 0;
    for (snap.counts) |c| total += c.documents;
    try w.print("<p class=\"muted\">dksearch {s}. Up {d} s. {d} documents. Read-only view: use the command line to import, rebuild, check or back up.</p>\n", .{ app.opts.version, app.uptimeSeconds(), total });

    try w.writeAll("<h2>Sources</h2>\n");
    if (app.opts.sources.len == 0 and snap.counts.len == 0) {
        try w.writeAll("<p>No sources are configured. dksearch works without them; add a <code>[[source]]</code> to the configuration to import documents.</p>\n");
    } else {
        try w.writeAll("<table><thead><tr><th>Name</th><th>Kind</th><th>Enabled</th><th>Documents</th><th>Last import</th><th>Started</th><th>Submitted</th><th>Rejected</th></tr></thead><tbody>\n");
        for (app.opts.sources, 0..) |s, i| {
            try w.writeAll("<tr><td>");
            try html.writeEscaped(w, s.name);
            try w.writeAll("</td><td>");
            try html.writeEscaped(w, s.kind);
            try w.print("</td><td>{s}</td><td>{d}</td>", .{ if (s.enabled) "yes" else "no", App.docsFor(snap, s.name) });
            if (i < snap.last.len and snap.last[i] != null) {
                try writeJobCells(w, snap.last[i].?);
            } else try w.writeAll("<td colspan=\"4\">never run</td>");
            try w.writeAll("</tr>\n");
        }
        for (snap.counts) |c| {
            var known = false;
            for (app.opts.sources) |s| if (std.mem.eql(u8, s.name, c.source)) {
                known = true;
            };
            if (known) continue;
            try w.writeAll("<tr><td>");
            try html.writeEscaped(w, c.source);
            try w.print("</td><td colspan=\"2\">not in the configuration</td><td>{d}</td><td colspan=\"4\">&mdash;</td></tr>\n", .{c.documents});
        }
        try w.writeAll("</tbody></table>\n");
    }

    try w.writeAll("<h2>Data</h2><table><tbody><tr><th>index.db</th><td>");
    try writeBytes(w, snap.sizes[0]);
    try w.writeAll("</td></tr><tr><th>state.db</th><td>");
    try writeBytes(w, snap.sizes[1]);
    try w.writeAll("</td></tr><tr><th>content.db</th><td>");
    try writeBytes(w, snap.sizes[2]);
    try w.writeAll("</td></tr></tbody></table>\n");

    try w.writeAll("<h2>Traffic since start</h2><table><thead><tr><th></th><th>Requests</th><th>2xx</th><th>3xx</th><th>4xx</th><th>5xx</th><th>&le;10 ms</th><th>&le;50 ms</th><th>&le;250 ms</th><th>&le;1 s</th><th>slower</th><th>Refused busy</th><th>Timed out</th></tr></thead><tbody>\n");
    for ([_]struct { []const u8, *const server.Stats }{ .{ "Public", app.opts.public_stats }, .{ "Admin", app.opts.admin_stats } }) |row| {
        const c = App.counters(row.@"1");
        try w.print("<tr><th>{s}</th><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td></tr>\n", .{
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
    try w.writeAll("</tbody></table>\n");
    try w.print("<p class=\"muted\">{d} active session(s). A job shown as running may belong to an import that was killed; the next command that opens the data marks it interrupted.</p>\n", .{app.sessionCount()});
}

fn writeJobs(w: *Io.Writer, jobs: []const dk.state_sqlite.Job) Io.Writer.Error!void {
    if (jobs.len == 0) return w.writeAll("<p>No imports have run yet.</p>\n");
    try w.writeAll("<table><thead><tr><th>Job</th><th>Source</th><th>Kind</th><th>State</th><th>Started</th><th>Submitted</th><th>Rejected</th><th>Note</th></tr></thead><tbody>\n");
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
    try w.writeAll("</tbody></table>\n");
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

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
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
            try state.saveCheckpoint(j, null, 2, 0);
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
        f.tmp.cleanup();
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
