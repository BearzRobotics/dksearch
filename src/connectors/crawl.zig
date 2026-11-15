//! The `crawl` connector: fetches a configured list of web pages over HTTP or
//! HTTPS and emits one document per page.
//!
//! It is polite by construction (docs/decisions/0018):
//!
//! - nothing is fetched unless a source of this kind is configured and run;
//! - the administrator must set the user agent, and it is sent unchanged;
//! - `robots.txt` is fetched first for every host (RFC 9309), and a page it
//!   disallows is never requested. A `robots.txt` that cannot be fetched
//!   (network error, 5xx) disallows the host for the run; a 4xx answer means
//!   no rules, as the RFC says;
//! - requests to one host are at least `delay_ms` apart (more if the site's
//!   `crawl-delay` asks), one at a time, no concurrency;
//! - redirects are followed only within the same host (a leading `www.` is
//!   ignored) and each hop is checked against `robots.txt`;
//! - bodies are capped (`max_page_bytes`) and every request has a deadline.
//!
//! Only the listed URLs are fetched: it follows no links and reads no
//! sitemaps (a later step). Pages are converted to text with the same HTML
//! converter as feed entries.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");
const files = @import("files.zig");
const htmltext = @import("../htmltext.zig");
const robots = @import("crawl/robots.zig");
const fetch = @import("crawl/fetch.zig");
const cabundle = @import("crawl/cabundle.zig");

pub const kind = "crawl";
pub const default_delay_ms: u32 = 1000;
pub const min_delay_ms: u32 = 100;
pub const max_delay_ms: u32 = 3_600_000;
pub const default_max_page_bytes: u32 = 2 * 1024 * 1024;
pub const hard_max_page_bytes: u32 = 32 * 1024 * 1024;
pub const default_timeout_s: u32 = 30;
pub const max_timeout_s: u32 = 300;
const max_redirects = 5;
const max_seeds = 10_000;
const max_seeds_file_bytes = 4 * 1024 * 1024;
/// A site's `crawl-delay` is honored up to this many seconds.
const max_crawl_delay_s = 60;
const checkpoint_every = 10;
const max_user_agent = 200;
const accept_pages = "text/html,application/xhtml+xml,text/plain;q=0.9";
const accept_robots = "text/plain";

const allowed_options = [_][]const u8{ "user_agent", "seeds_file", "delay_ms", "max_page_bytes", "timeout_seconds", "ca_bundle", "language" };

// ------------------------------------------------------------ validation

fn key(buf: []u8, source: config.Source, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "source[{s}].{s}", .{ source.name, name }) catch name;
}

fn needString(source: config.Source, name: []const u8, required: bool, diag: *config.Diagnostic) config.Error!?[]const u8 {
    var kbuf: [128]u8 = undefined;
    const v = source.option(name) orelse {
        if (required) {
            diag.set("", key(&kbuf, source, name), "is required for kind \"crawl\"", .{});
            return error.InvalidValue;
        }
        return null;
    };
    switch (v) {
        .string => |s| {
            if (s.len == 0) {
                diag.set("", key(&kbuf, source, name), "must not be empty", .{});
                return error.InvalidValue;
            }
            return s;
        },
        else => {
            diag.set("", key(&kbuf, source, name), "expected string", .{});
            return error.WrongType;
        },
    }
}

fn intOption(source: config.Source, name: []const u8, lo: u32, hi: u32, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    const v = source.option(name) orelse return;
    switch (v) {
        .integer => |n| if (n < lo or n > hi) {
            diag.set("", key(&kbuf, source, name), "must be between {d} and {d}, got {d}", .{ lo, hi, n });
            return error.InvalidValue;
        },
        else => {
            diag.set("", key(&kbuf, source, name), "expected integer", .{});
            return error.WrongType;
        },
    }
}

/// A user agent is one header line of printable ASCII with a product token.
pub fn validUserAgent(ua: []const u8) bool {
    if (ua.len == 0 or ua.len > max_user_agent) return false;
    for (ua) |c| if (c < 0x20 or c > 0x7e) return false;
    return robots.productToken(ua).len > 0;
}

pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    for (source.options) |o| {
        var known = false;
        for (allowed_options) |k| {
            if (std.mem.eql(u8, k, o.key)) known = true;
        }
        if (!known) {
            diag.set("", key(&kbuf, source, o.key), "unknown option for kind \"crawl\"", .{});
            return error.UnknownKey;
        }
    }
    const ua = (try needString(source, "user_agent", true, diag)).?;
    if (!validUserAgent(ua)) {
        diag.set("", key(&kbuf, source, "user_agent"), "must be 1-{d} printable ASCII characters starting with a product name, e.g. \"mysearch/1.0 (+https://example.org/about)\"", .{max_user_agent});
        return error.InvalidValue;
    }
    _ = (try needString(source, "seeds_file", true, diag)).?;
    try intOption(source, "delay_ms", min_delay_ms, max_delay_ms, diag);
    try intOption(source, "max_page_bytes", 1, hard_max_page_bytes, diag);
    try intOption(source, "timeout_seconds", 1, max_timeout_s, diag);
    _ = try needString(source, "ca_bundle", false, diag);
    if (try needString(source, "language", false, diag)) |l| if (!files.validLanguageTag(l)) {
        diag.set("", key(&kbuf, source, "language"), "must be a language tag such as \"en\" (letters, digits and '-', at most 35 characters)", .{});
        return error.InvalidValue;
    };
}

// ------------------------------------------------------------- the connector

pub const CrawlConnector = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    user_agent: []const u8,
    seeds_file: []const u8,
    delay_ms: u32,
    max_page_bytes: u32,
    timeout_s: u32,
    ca: cabundle.Choice,
    language: ?[]const u8,
    checkpoint_buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!CrawlConnector {
        const name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(name);
        const user_agent = try gpa.dupe(u8, source.optionString("user_agent").?);
        errdefer gpa.free(user_agent);
        const seeds_file = try gpa.dupe(u8, source.optionString("seeds_file").?);
        errdefer gpa.free(seeds_file);
        var ca: cabundle.Choice = .builtin;
        if (source.optionString("ca_bundle")) |c| {
            if (std.mem.eql(u8, c, "system")) {
                ca = .system;
            } else if (!std.mem.eql(u8, c, "builtin")) {
                ca = .{ .file = try gpa.dupe(u8, c) };
            }
        }
        errdefer switch (ca) {
            .file => |p| gpa.free(p),
            else => {},
        };
        const language = if (source.optionString("language")) |l| try gpa.dupe(u8, l) else null;
        return .{
            .gpa = gpa,
            .io = io,
            .name = name,
            .user_agent = user_agent,
            .seeds_file = seeds_file,
            .delay_ms = @intCast(source.optionInt("delay_ms") orelse default_delay_ms),
            .max_page_bytes = @intCast(source.optionInt("max_page_bytes") orelse default_max_page_bytes),
            .timeout_s = @intCast(source.optionInt("timeout_seconds") orelse default_timeout_s),
            .ca = ca,
            .language = language,
        };
    }

    pub fn deinit(self: *CrawlConnector) void {
        self.gpa.free(self.name);
        self.gpa.free(self.user_agent);
        self.gpa.free(self.seeds_file);
        switch (self.ca) {
            .file => |p| self.gpa.free(p),
            else => {},
        }
        if (self.language) |l| self.gpa.free(l);
        self.checkpoint_buf.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn connector(self: *CrawlConnector) api.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run } };
    }

    fn info(_: *anyopaque) api.Info {
        return .{ .kind = kind, .requires_network = true, .resumable = true };
    }

    fn run(ptr: *anyopaque, sink: api.Sink, control: *api.Control, resume_from: ?[]const u8) api.RunError!api.Outcome {
        const self: *CrawlConnector = @ptrCast(@alignCast(ptr));
        var run_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer run_arena.deinit();

        const seeds = self.readSeeds(run_arena.allocator()) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSource,
        };

        var client: http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();
        cabundle.load(&client.ca_bundle, self.gpa, self.io, self.ca) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSource,
        };
        client.now = Io.Clock.real.now(self.io);

        var r: Run = .{ .conn = self, .arena = run_arena.allocator(), .client = &client, .sink = sink, .control = control };

        var start: usize = 0;
        if (resume_from) |at| {
            for (seeds, 0..) |s, i| if (std.mem.eql(u8, s, at)) {
                start = i + 1;
            };
        }

        var done: ?[]const u8 = if (start > 0) seeds[start - 1] else null;
        var since: u32 = 0;
        for (seeds[start..]) |seed| {
            if (control.isCancelled()) return self.stopped(done);
            switch (try r.crawlSeed(seed)) {
                .stopped => return self.stopped(done),
                .stored, .skipped => {},
            }
            done = seed;
            since += 1;
            if (since >= checkpoint_every) {
                since = 0;
                sink.checkpoint(seed) catch |e| switch (e) {
                    error.Stopped => return self.stopped(done),
                    else => return error.SourceFailed,
                };
            }
        }
        // Not one page could be reached: the network is the likely cause.
        if (seeds.len > 0 and r.stored == 0 and r.network_failures > 0) return error.Offline;
        return .{};
    }

    fn stopped(self: *CrawlConnector, done: ?[]const u8) api.Outcome {
        const d = done orelse return .{ .interrupted = true };
        self.checkpoint_buf.clearRetainingCapacity();
        self.checkpoint_buf.appendSlice(self.gpa, d) catch return .{ .interrupted = true };
        return .{ .interrupted = true, .checkpoint = self.checkpoint_buf.items };
    }

    /// One absolute http(s) URL per line; blank lines and `#` comments are
    /// skipped, lines that are not usable URLs are ignored.
    fn readSeeds(self: *CrawlConnector, arena: Allocator) ![]const []const u8 {
        const data = try Io.Dir.cwd().readFileAlloc(self.io, self.seeds_file, arena, .limited(max_seeds_file_bytes));
        var out: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.indexOfScalar(u8, line, '#')) |h| line = std.mem.trim(u8, line[0..h], " \t");
            if (parseUrl(line) == null) continue;
            if (out.items.len >= max_seeds) break;
            try out.append(arena, line);
        }
        return out.items;
    }
};

// ------------------------------------------------------------------ URLs

const Url = struct {
    uri: std.Uri,
    https: bool,
    /// Lower-case host without port or brackets handling beyond the raw text.
    host: []const u8,
};

/// `text` as an http(s) URL with a host and no credentials, or null. The
/// host points into `text`; it is lowercased by `hostKey` where compared.
fn parseUrl(text: []const u8) ?Url {
    if (text.len > 4096) return null;
    const uri = std.Uri.parse(text) catch return null;
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!https and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    if (uri.user != null or uri.password != null) return null;
    const host_c = uri.host orelse return null;
    const host = switch (host_c) {
        .raw, .percent_encoded => |h| h,
    };
    if (host.len == 0) return null;
    return .{ .uri = uri, .https = https, .host = host };
}

/// The host with a leading "www." removed, lowercased into `buf`; used to
/// decide whether a redirect stays on the same site.
fn siteKey(buf: []u8, host: []const u8) []const u8 {
    var h = host;
    if (h.len > 4 and std.ascii.eqlIgnoreCase(h[0..4], "www.")) h = h[4..];
    const n = @min(h.len, buf.len);
    return std.ascii.lowerString(buf[0..n], h[0..n]);
}

fn sameSite(a: []const u8, b: []const u8) bool {
    var ba: [256]u8 = undefined;
    var bb: [256]u8 = undefined;
    if (a.len > ba.len or b.len > bb.len) return false;
    return std.mem.eql(u8, siteKey(&ba, a), siteKey(&bb, b));
}

fn componentText(c: std.Uri.Component) []const u8 {
    return switch (c) {
        .raw, .percent_encoded => |s| s,
    };
}

/// The request target for robots matching: path plus query.
fn targetOf(arena: Allocator, u: Url) Allocator.Error![]const u8 {
    const path = if (u.uri.path.isEmpty()) "/" else componentText(u.uri.path);
    if (u.uri.query) |q| return std.fmt.allocPrint(arena, "{s}?{s}", .{ path, componentText(q) });
    return path;
}

/// "scheme://host[:port]" in lower case, the unit robots.txt applies to.
fn originOf(arena: Allocator, u: Url) Allocator.Error![]const u8 {
    const scheme: []const u8 = if (u.https) "https" else "http";
    const lower = try std.ascii.allocLowerString(arena, u.host);
    if (u.uri.port) |p| return std.fmt.allocPrint(arena, "{s}://{s}:{d}", .{ scheme, lower, p });
    return std.fmt.allocPrint(arena, "{s}://{s}", .{ scheme, lower });
}

/// The URL without its fragment, as the page's identity.
fn withoutFragment(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const h = std.mem.indexOfScalar(u8, text, '#') orelse return text;
    return arena.dupe(u8, text[0..h]);
}

/// Resolves a redirect `location` against `base` (the URL just requested).
fn resolveRedirect(arena: Allocator, base: []const u8, location: []const u8) Allocator.Error!?[]const u8 {
    const loc = std.mem.trim(u8, location, " \t\r\n");
    if (loc.len == 0 or loc.len > 4096) return null;
    if (std.ascii.startsWithIgnoreCase(loc, "http://") or std.ascii.startsWithIgnoreCase(loc, "https://")) return try withoutFragment(arena, loc);
    const b = parseUrl(base) orelse return null;
    const scheme: []const u8 = if (b.https) "https" else "http";
    const origin = try originOf(arena, b);
    if (std.mem.startsWith(u8, loc, "//")) return try withoutFragment(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ scheme, loc }));
    if (loc[0] == '/') return try withoutFragment(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ origin, loc }));
    // Any other scheme ("javascript:", "mailto:", ...) or a bare fragment.
    const colon = std.mem.indexOfScalar(u8, loc, ':');
    const slash = std.mem.indexOfScalar(u8, loc, '/');
    if (loc[0] == '#' or (colon != null and (slash == null or colon.? < slash.?))) return null;
    // Relative to the directory of the current path.
    const path = componentText(b.uri.path);
    const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |k| path[0 .. k + 1] else "/";
    return try withoutFragment(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ origin, dir, loc }));
}

// ---------------------------------------------------------------- the run

const Host = struct {
    rules: robots.Rules,
    /// When the last request to this origin finished (monotonic).
    last: ?Io.Timestamp = null,
};

const Run = struct {
    conn: *CrawlConnector,
    /// Lives for the whole run: host table and parsed robots rules.
    arena: Allocator,
    client: *http.Client,
    sink: api.Sink,
    control: *api.Control,
    hosts: std.StringHashMapUnmanaged(*Host) = .empty,
    stored: u64 = 0,
    network_failures: u64 = 0,

    const Result = enum { stored, skipped, stopped };

    fn reject(self: *Run) Result {
        _ = self.control.rejected.fetchAdd(1, .monotonic);
        return .skipped;
    }

    /// Sleeps until `host` may be contacted again, in short steps so a
    /// cancellation is noticed. Returns false if cancelled.
    fn waitTurn(self: *Run, host: *Host) bool {
        const io = self.conn.io;
        const delay_s: u64 = if (host.rules.crawl_delay_s) |s| @min(s, max_crawl_delay_s) else 0;
        const gap_ns: i96 = @as(i96, @max(self.conn.delay_ms, @as(u32, @intCast(delay_s * 1000)))) * std.time.ns_per_ms;
        const last = host.last orelse return !self.control.isCancelled();
        while (true) {
            if (self.control.isCancelled()) return false;
            const elapsed = last.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
            if (elapsed >= gap_ns) return true;
            const left_ms: i64 = @intCast(@divTrunc(gap_ns - elapsed, std.time.ns_per_ms) + 1);
            io.sleep(.fromMilliseconds(@min(left_ms, 200)), .awake) catch return false;
        }
    }

    fn timeout(self: *Run) Io.Duration {
        return .fromSeconds(self.conn.timeout_s);
    }

    /// The (cached) robots rules for the origin of `u`.
    fn hostFor(self: *Run, u: Url) error{ OutOfMemory, Canceled }!*Host {
        const origin = try originOf(self.arena, u);
        if (self.hosts.get(origin)) |h| return h;
        const host = try self.arena.create(Host);
        host.* = .{ .rules = .allow_all };
        try self.hosts.put(self.arena, origin, host);
        host.rules = try self.fetchRobots(origin, host);
        return host;
    }

    fn fetchRobots(self: *Run, origin: []const u8, host: *Host) error{ OutOfMemory, Canceled }!robots.Rules {
        var tmp = std.heap.ArenaAllocator.init(self.conn.gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        var url: []const u8 = try std.fmt.allocPrint(a, "{s}/robots.txt", .{origin});
        var hops: u32 = 0;
        while (true) {
            if (!self.waitTurn(host)) return error.Canceled;
            const resp = fetch.get(self.client, a, .{
                .url = url,
                .user_agent = self.conn.user_agent,
                .accept = accept_robots,
                .max_body_bytes = robots.max_bytes,
            }, self.timeout());
            host.last = Io.Timestamp.now(self.conn.io, .awake);
            const got = resp catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.Network, error.Timeout => {
                    self.network_failures += 1;
                    return .disallow_all;
                },
                // Unusable or oversized: do not guess, stay away for this run.
                else => return .disallow_all,
            };
            if (got.status >= 300 and got.status < 400) {
                hops += 1;
                const loc = got.location orelse return .disallow_all;
                const next = (try resolveRedirect(a, url, loc)) orelse return .disallow_all;
                const here = parseUrl(url) orelse return .disallow_all;
                const there = parseUrl(next) orelse return .disallow_all;
                if (hops > max_redirects or !sameSite(here.host, there.host)) return .disallow_all;
                url = next;
                continue;
            }
            if (got.status >= 200 and got.status < 300) {
                return robots.parse(self.arena, got.body, robots.productToken(self.conn.user_agent));
            }
            if (got.status >= 400 and got.status < 500) return .allow_all;
            return .disallow_all;
        }
    }

    fn crawlSeed(self: *Run, seed: []const u8) error{OutOfMemory}!Result {
        var page = std.heap.ArenaAllocator.init(self.conn.gpa);
        defer page.deinit();
        const a = page.allocator();

        var url = try withoutFragment(a, seed);
        var hops: u32 = 0;
        while (true) {
            const u = parseUrl(url) orelse return self.reject();
            const host = self.hostFor(u) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return .stopped,
            };
            if (!host.rules.allowed(try targetOf(a, u))) return self.reject();
            if (!self.waitTurn(host)) return .stopped;

            const resp = fetch.get(self.client, a, .{
                .url = url,
                .user_agent = self.conn.user_agent,
                .accept = accept_pages,
                .max_body_bytes = self.conn.max_page_bytes,
            }, self.timeout());
            host.last = Io.Timestamp.now(self.conn.io, .awake);
            const got = resp catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return .stopped,
                error.Network, error.Timeout => {
                    self.network_failures += 1;
                    return self.reject();
                },
                // A certificate that does not verify is a refusal, not an outage.
                else => return self.reject(),
            };

            if (got.status >= 300 and got.status < 400) {
                hops += 1;
                const loc = got.location orelse return self.reject();
                const next = (try resolveRedirect(a, url, loc)) orelse return self.reject();
                const there = parseUrl(next) orelse return self.reject();
                if (hops > max_redirects or !sameSite(u.host, there.host)) return self.reject();
                url = next;
                continue;
            }
            if (got.status < 200 or got.status >= 300) return self.reject();
            return self.store(a, url, got);
        }
    }

    fn store(self: *Run, a: Allocator, url: []const u8, got: fetch.Response) error{OutOfMemory}!Result {
        const ct = parseContentType(got.content_type);
        const is_html = ct.media.len == 0 or std.mem.eql(u8, ct.media, "text/html") or std.mem.eql(u8, ct.media, "application/xhtml+xml");
        if (!is_html and !std.mem.eql(u8, ct.media, "text/plain")) return self.reject();

        const utf8 = (try toUtf8(a, got.body, ct.charset)) orelse return self.reject();
        const text = if (is_html) try htmltext.toText(a, utf8) else std.mem.trim(u8, utf8, " \t\r\n");
        if (text.len == 0) return self.reject();
        const title: ?[]const u8 = if (is_html) try htmltext.titleOf(a, utf8) else null;

        const u = parseUrl(url).?;
        const d: doc.Document = .{
            .connector = self.conn.name,
            .source_id = url,
            .canonical_url = url,
            .source_dataset = u.host,
            .title = title,
            .text = text,
            .language = self.conn.language,
            .content_type = if (is_html) "text/html" else "text/plain",
            .rights = .{
                .attribution = try std.fmt.allocPrint(a, "Fetched from {s}", .{u.host}),
                .access_notes = "Page content belongs to its publisher; check its terms before reuse.",
                .redistribution = .unknown,
            },
        };
        self.sink.submit(d) catch |e| switch (e) {
            error.Rejected => return .skipped, // the pipeline counts and reports it
            error.Stopped => return .stopped,
            error.OutOfMemory => return error.OutOfMemory,
        };
        _ = self.control.submitted.fetchAdd(1, .monotonic);
        self.stored += 1;
        return .stored;
    }
};

const ContentType = struct { media: []const u8, charset: ?[]const u8 };

/// "text/html; charset=UTF-8" -> media "text/html" (lower case), charset "UTF-8".
fn parseContentType(value: ?[]const u8) ContentType {
    const v = value orelse return .{ .media = "", .charset = null };
    var parts = std.mem.splitScalar(u8, v, ';');
    const media = std.mem.trim(u8, parts.first(), " \t");
    var charset: ?[]const u8 = null;
    while (parts.next()) |p| {
        const kv = std.mem.trim(u8, p, " \t");
        if (kv.len > 8 and std.ascii.eqlIgnoreCase(kv[0..8], "charset=")) {
            charset = std.mem.trim(u8, kv[8..], " \t\"'");
        }
    }
    return .{ .media = media, .charset = charset };
}

/// The body as UTF-8, or null when its declared encoding is not understood.
/// UTF-8 and ASCII pass through; ISO-8859-1 and Windows-1252 are widened
/// (Windows-1252's 0x80-0x9F block is read as Latin-1 controls); with no
/// declared charset, bytes that are not valid UTF-8 are taken as Latin-1.
fn toUtf8(a: Allocator, body_in: []const u8, charset: ?[]const u8) Allocator.Error!?[]const u8 {
    var body = body_in;
    if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) body = body[3..];
    const latin1 = [_][]const u8{ "iso-8859-1", "latin1", "windows-1252", "cp1252", "l1" };
    const utf8 = [_][]const u8{ "utf-8", "utf8", "us-ascii", "ascii" };
    var widen = false;
    if (charset) |cs| {
        var lowered: [32]u8 = undefined;
        if (cs.len > lowered.len) return null;
        const l = std.ascii.lowerString(&lowered, cs);
        for (latin1) |n| if (std.mem.eql(u8, l, n)) {
            widen = true;
        };
        if (!widen) {
            var ok = false;
            for (utf8) |n| if (std.mem.eql(u8, l, n)) {
                ok = true;
            };
            if (!ok) return null;
            if (!std.unicode.utf8ValidateSlice(body)) return null;
        }
    } else if (!std.unicode.utf8ValidateSlice(body)) {
        widen = true;
    }
    if (!widen) return body;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, body.len + body.len / 4);
    for (body) |b| {
        if (b < 0x80) {
            try out.append(a, b);
        } else {
            try out.append(a, 0xC0 | (b >> 6));
            try out.append(a, 0x80 | (b & 0x3F));
        }
    }
    return out.items;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const net = Io.net;

test "validate requires a user agent and a seeds file, and checks ranges" {
    var d: config.Diagnostic = .{};
    const ok_opts = [_]config.Option{
        .{ .key = "user_agent", .value = .{ .string = "mysearch/1.0 (+https://example.org/about)" } },
        .{ .key = "seeds_file", .value = .{ .string = "seeds.txt" } },
    };
    try validate(.{ .name = "c", .kind = "crawl", .options = &ok_opts }, &d);

    try testing.expectError(error.InvalidValue, validate(.{ .name = "c", .kind = "crawl", .options = ok_opts[1..] }, &d));
    try testing.expectEqualStrings("source[c].user_agent", d.key());
    try testing.expectError(error.InvalidValue, validate(.{ .name = "c", .kind = "crawl", .options = ok_opts[0..1] }, &d));
    try testing.expectEqualStrings("source[c].seeds_file", d.key());

    const bad_ua = [_]config.Option{ .{ .key = "user_agent", .value = .{ .string = "bad\r\nHeader: x" } }, ok_opts[1] };
    try testing.expectError(error.InvalidValue, validate(.{ .name = "c", .kind = "crawl", .options = &bad_ua }, &d));
    const fast = ok_opts ++ [_]config.Option{.{ .key = "delay_ms", .value = .{ .integer = 5 } }};
    try testing.expectError(error.InvalidValue, validate(.{ .name = "c", .kind = "crawl", .options = &fast }, &d));
    const unknown = ok_opts ++ [_]config.Option{.{ .key = "follow", .value = .{ .boolean = true } }};
    try testing.expectError(error.UnknownKey, validate(.{ .name = "c", .kind = "crawl", .options = &unknown }, &d));
}

test "URL handling: sites, redirects, targets" {
    try testing.expect(parseUrl("ftp://x/") == null);
    try testing.expect(parseUrl("http://user:pw@x/") == null);
    try testing.expect(parseUrl("http:///nohost") == null);
    try testing.expect(parseUrl("https://Example.org/a?b=1").?.https);
    try testing.expect(sameSite("www.Example.org", "example.ORG"));
    try testing.expect(!sameSite("example.org", "evil.example.org"));
    try testing.expect(!sameSite("example.org", "example.org.evil.net"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/a?b=1", try targetOf(a, parseUrl("https://x.org/a?b=1#frag").?));
    try testing.expectEqualStrings("/", try targetOf(a, parseUrl("https://x.org").?));
    try testing.expectEqualStrings("https://x.org:8443", try originOf(a, parseUrl("https://X.org:8443/p").?));
    try testing.expectEqualStrings("https://x.org/new", (try resolveRedirect(a, "https://x.org/old/page", "/new#f")).?);
    try testing.expectEqualStrings("https://x.org/old/other", (try resolveRedirect(a, "https://x.org/old/page", "other")).?);
    try testing.expectEqualStrings("http://y.org/z", (try resolveRedirect(a, "https://x.org/p", "http://y.org/z")).?);
    try testing.expectEqualStrings("https://y.org/z", (try resolveRedirect(a, "https://x.org/p", "//y.org/z")).?);
    try testing.expect((try resolveRedirect(a, "https://x.org/p", "javascript:alert(1)")) == null);
}

test "content types and charsets" {
    const ct = parseContentType("Text/HTML; Charset=\"ISO-8859-1\"");
    try testing.expectEqualStrings("Text/HTML", ct.media);
    try testing.expectEqualStrings("ISO-8859-1", ct.charset.?);
    try testing.expectEqualStrings("", parseContentType(null).media);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("caf\u{e9}", (try toUtf8(a, "caf\xe9", "iso-8859-1")).?);
    try testing.expectEqualStrings("caf\u{e9}", (try toUtf8(a, "caf\xe9", null)).?);
    try testing.expectEqualStrings("caf\u{e9}", (try toUtf8(a, "\xEF\xBB\xBFcaf\u{e9}", "utf-8")).?);
    try testing.expect((try toUtf8(a, "caf\xe9", "utf-8")) == null);
    try testing.expect((try toUtf8(a, "x", "shift_jis")) == null);
}

// A tiny HTTP server for tests: serves canned routes on a loopback port and
// records what it was asked.
const big_body: []const u8 = "<p>" ++ &@as([5000]u8, @splat('x')) ++ "</p>";

const Route = struct {
    path: []const u8,
    status: u16 = 200,
    content_type: []const u8 = "text/html; charset=utf-8",
    body: []const u8 = "",
    location: ?[]const u8 = null,
    /// Stall this long before answering (to test the deadline).
    stall_ms: i64 = 0,
};

const TestServer = struct {
    listener: net.Server,
    port: u16,
    routes: []const Route,
    future: Io.Future(void),
    mutex: Io.Mutex = .init,
    paths: std.ArrayList([]u8) = .empty,
    agents: std.ArrayList([]u8) = .empty,
    times: std.ArrayList(i96) = .empty,

    fn start(s: *TestServer, routes: []const Route) !void {
        s.* = .{
            .listener = try (try net.IpAddress.parseIp4("127.0.0.1", 0)).listen(testing.io, .{ .reuse_address = true }),
            .port = 0,
            .routes = routes,
            .future = undefined,
        };
        s.port = s.listener.socket.address.getPort();
        s.future = try testing.io.concurrent(loop, .{s});
    }

    fn stop(s: *TestServer) void {
        _ = s.future.cancel(testing.io);
        s.listener.deinit(testing.io);
        for (s.paths.items) |p| testing.allocator.free(p);
        for (s.agents.items) |p| testing.allocator.free(p);
        s.paths.deinit(testing.allocator);
        s.agents.deinit(testing.allocator);
        s.times.deinit(testing.allocator);
    }

    fn url(s: *TestServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ s.port, path }) catch unreachable;
    }

    fn count(s: *TestServer, path: []const u8) usize {
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        var n: usize = 0;
        for (s.paths.items) |p| if (std.mem.eql(u8, p, path)) {
            n += 1;
        };
        return n;
    }

    fn loop(s: *TestServer) void {
        while (true) {
            const stream = s.listener.accept(testing.io) catch return;
            defer stream.close(testing.io);
            s.handle(stream) catch |e| if (e == error.Canceled) return;
        }
    }

    fn handle(s: *TestServer, stream: net.Stream) !void {
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
        while (lines.next()) |l| if (std.ascii.startsWithIgnoreCase(l, "user-agent:")) {
            agent = std.mem.trim(u8, l[11..], " ");
        };
        {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            try s.paths.append(testing.allocator, try testing.allocator.dupe(u8, path));
            try s.agents.append(testing.allocator, try testing.allocator.dupe(u8, agent));
            try s.times.append(testing.allocator, Io.Timestamp.now(io, .awake).nanoseconds);
        }
        var found: ?Route = null;
        for (s.routes) |rt| if (std.mem.eql(u8, rt.path, path)) {
            found = rt;
        };
        const rt = found orelse Route{ .path = path, .status = 404, .content_type = "text/plain", .body = "not found" };
        if (rt.stall_ms > 0) try io.sleep(.fromMilliseconds(rt.stall_ms), .awake);
        try w.interface.print("HTTP/1.1 {d} X\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: close\r\n", .{ rt.status, rt.content_type, rt.body.len });
        if (rt.location) |l| try w.interface.print("location: {s}\r\n", .{l});
        try w.interface.writeAll("\r\n");
        try w.interface.writeAll(rt.body);
        try w.interface.flush();
    }
};

const runner = @import("../runner.zig");
const memory = @import("../memory.zig");
const pipeline = @import("../pipeline.zig");
const state_sqlite = @import("../state_sqlite.zig");
const index_sqlite = @import("../index_sqlite.zig");

const Collect = struct {
    titles: std.ArrayList([]u8) = .empty,
    ids: std.ArrayList([]u8) = .empty,
    texts: std.ArrayList([]u8) = .empty,
    fn deinit(c: *Collect) void {
        for (c.titles.items) |t| testing.allocator.free(t);
        for (c.ids.items) |t| testing.allocator.free(t);
        for (c.texts.items) |t| testing.allocator.free(t);
        c.titles.deinit(testing.allocator);
        c.ids.deinit(testing.allocator);
        c.texts.deinit(testing.allocator);
    }
    fn submit(ptr: *anyopaque, d: doc.Document) api.Sink.Error!void {
        const c: *Collect = @ptrCast(@alignCast(ptr));
        try c.titles.append(testing.allocator, try testing.allocator.dupe(u8, d.title orelse ""));
        try c.ids.append(testing.allocator, try testing.allocator.dupe(u8, d.source_id));
        try c.texts.append(testing.allocator, try testing.allocator.dupe(u8, d.text orelse ""));
    }
    fn sink(c: *Collect) api.Sink {
        return .{ .ptr = c, .vtable = &.{ .submit = submit } };
    }
};

/// A connector for tests: fast delay, one seed file in `tmp`.
fn testConnector(tmp: *testing.TmpDir, seeds: []const u8, ua: []const u8) !CrawlConnector {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "seeds.txt", .data = seeds });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, "seeds.txt", &pbuf);
    const opts = [_]config.Option{
        .{ .key = "user_agent", .value = .{ .string = ua } },
        .{ .key = "seeds_file", .value = .{ .string = pbuf[0..n] } },
    };
    var c = try CrawlConnector.init(testing.allocator, testing.io, .{ .name = "web", .kind = "crawl", .options = &opts });
    c.delay_ms = 0; // validation forbids this; tests only
    c.timeout_s = 5;
    return c;
}

test "fetches seeds, obeys robots.txt, converts HTML, identifies itself" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/robots.txt", .content_type = "text/plain", .body = "User-agent: *\nDisallow: /private\n" },
        .{ .path = "/a", .body = "<html><head><title>Page &amp; A</title></head><body><p>Hello <b>world</b></p><script>x()</script></body></html>" },
        .{ .path = "/private/b", .body = "<p>secret</p>" },
        .{ .path = "/plain", .content_type = "text/plain", .body = "just text\n" },
        .{ .path = "/latin", .content_type = "text/html; charset=iso-8859-1", .body = "<p>caf\xe9</p>" },
        .{ .path = "/pdf", .content_type = "application/pdf", .body = "%PDF" },
        .{ .path = "/gone", .status = 404, .body = "x" },
    });
    defer srv.stop();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [6][96]u8 = undefined;
    var seeds: std.ArrayList(u8) = .empty;
    defer seeds.deinit(testing.allocator);
    for ([_][]const u8{ "/a", "/private/b", "/plain", "/latin", "/pdf", "/gone" }, 0..) |p, i| {
        try seeds.print(testing.allocator, "{s}\n", .{srv.url(&b[i], p)});
    }
    try seeds.appendSlice(testing.allocator, "# a comment\n\nnot a url\n");
    var conn = try testConnector(&tmp, seeds.items, "dksearch-test/1.0 (+https://example.org/bot)");
    defer conn.deinit();

    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    const out = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expect(!out.interrupted);

    try testing.expectEqual(@as(usize, 3), got.ids.items.len);
    try testing.expectEqualStrings("Page & A", got.titles.items[0]);
    try testing.expectEqualStrings("Hello world", got.texts.items[0]);
    try testing.expectEqualStrings("just text", got.texts.items[1]);
    try testing.expectEqualStrings("caf\u{e9}", got.texts.items[2]);
    try testing.expectEqual(@as(u64, 3), ctl.submitted.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), ctl.rejected.load(.monotonic)); // robots, pdf, 404

    try testing.expectEqual(@as(usize, 0), srv.count("/private/b")); // never requested
    try testing.expectEqual(@as(usize, 1), srv.count("/robots.txt")); // once per host
    for (srv.agents.items) |ag| try testing.expectEqualStrings("dksearch-test/1.0 (+https://example.org/bot)", ag);
}

test "same-site redirects are followed, other sites are not, loops end" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/robots.txt", .status = 404, .body = "" },
        .{ .path = "/old", .status = 301, .location = "/new", .body = "" },
        .{ .path = "/new", .body = "<p>moved here</p>" },
        .{ .path = "/away", .status = 302, .location = "http://elsewhere.invalid/x", .body = "" },
        .{ .path = "/loop", .status = 302, .location = "/loop", .body = "" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [3][96]u8 = undefined;
    var seeds: std.ArrayList(u8) = .empty;
    defer seeds.deinit(testing.allocator);
    for ([_][]const u8{ "/old", "/away", "/loop" }, 0..) |p, i| try seeds.print(testing.allocator, "{s}\n", .{srv.url(&b[i], p)});
    var conn = try testConnector(&tmp, seeds.items, "t/1");
    defer conn.deinit();

    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expectEqual(@as(usize, 1), got.ids.items.len);
    try testing.expect(std.mem.endsWith(u8, got.ids.items[0], "/new")); // identified by the final URL
    try testing.expectEqual(@as(u64, 2), ctl.rejected.load(.monotonic));
    try testing.expectEqual(@as(usize, max_redirects + 1), srv.count("/loop")); // bounded
}

test "a robots.txt that cannot be read disallows the host; an unreachable site is Offline" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/robots.txt", .status = 503, .body = "" },
        .{ .path = "/a", .body = "<p>x</p>" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [96]u8 = undefined;
    var conn = try testConnector(&tmp, srv.url(&b, "/a"), "t/1");
    defer conn.deinit();
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expectEqual(@as(usize, 0), got.ids.items.len);
    try testing.expectEqual(@as(usize, 0), srv.count("/a"));

    // Nothing listens on a port we just released.
    var dead = try (try net.IpAddress.parseIp4("127.0.0.1", 0)).listen(testing.io, .{ .reuse_address = true });
    const port = dead.socket.address.getPort();
    dead.deinit(testing.io);
    var url_buf: [64]u8 = undefined;
    var conn2 = try testConnector(&tmp, try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port}), "t/1");
    defer conn2.deinit();
    var ctl2: api.Control = .{};
    try testing.expectError(error.Offline, conn2.connector().run(got.sink(), &ctl2, null));
}

test "oversized pages and stalled servers are refused within bounds" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/big", .body = big_body },
        .{ .path = "/slow", .body = "<p>late</p>", .stall_ms = 5000 },
        .{ .path = "/ok", .body = "<p>fine</p>" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [3][96]u8 = undefined;
    var seeds: std.ArrayList(u8) = .empty;
    defer seeds.deinit(testing.allocator);
    for ([_][]const u8{ "/big", "/ok", "/slow" }, 0..) |p, i| try seeds.print(testing.allocator, "{s}\n", .{srv.url(&b[i], p)});
    var conn = try testConnector(&tmp, seeds.items, "t/1");
    defer conn.deinit();
    conn.max_page_bytes = 1000;
    conn.timeout_s = 1;

    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    const t0 = Io.Timestamp.now(testing.io, .awake);
    _ = try conn.connector().run(got.sink(), &ctl, null);
    const took_ms = @divTrunc(t0.durationTo(Io.Timestamp.now(testing.io, .awake)).nanoseconds, std.time.ns_per_ms);
    try testing.expect(took_ms < 4000);
    try testing.expectEqual(@as(usize, 1), got.ids.items.len);
    try testing.expectEqualStrings("fine", got.texts.items[0]);
    try testing.expectEqual(@as(u64, 2), ctl.rejected.load(.monotonic));
}

test "requests to one host are spaced by the delay" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/robots.txt", .body = "User-agent: *\nAllow: /\n", .content_type = "text/plain" },
        .{ .path = "/1", .body = "<p>one</p>" },
        .{ .path = "/2", .body = "<p>two</p>" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [2][96]u8 = undefined;
    var seeds: std.ArrayList(u8) = .empty;
    defer seeds.deinit(testing.allocator);
    for ([_][]const u8{ "/1", "/2" }, 0..) |p, i| try seeds.print(testing.allocator, "{s}\n", .{srv.url(&b[i], p)});
    var conn = try testConnector(&tmp, seeds.items, "t/1");
    defer conn.deinit();
    conn.delay_ms = 300;
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expectEqual(@as(usize, 2), got.ids.items.len);
    // robots.txt, /1, /2: consecutive requests at least ~300 ms apart.
    try testing.expectEqual(@as(usize, 3), srv.times.items.len);
    for (1..3) |i| {
        const gap_ms = @divTrunc(srv.times.items[i] - srv.times.items[i - 1], std.time.ns_per_ms);
        try testing.expect(gap_ms >= 250);
    }
}

test "cancelling stops the run and reports where to resume" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/1", .body = "<p>one</p>" },
        .{ .path = "/2", .body = "<p>two</p>" },
        .{ .path = "/3", .body = "<p>three</p>" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [3][96]u8 = undefined;
    var seeds: std.ArrayList(u8) = .empty;
    defer seeds.deinit(testing.allocator);
    for ([_][]const u8{ "/1", "/2", "/3" }, 0..) |p, i| try seeds.print(testing.allocator, "{s}\n", .{srv.url(&b[i], p)});
    var conn = try testConnector(&tmp, seeds.items, "t/1");
    defer conn.deinit();

    // Cancel from inside the sink after the first page.
    const Stopper = struct {
        inner: *Collect,
        ctl: *api.Control,
        fn submit(ptr: *anyopaque, d: doc.Document) api.Sink.Error!void {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            try Collect.submit(s.inner, d);
            s.ctl.cancel();
        }
    };
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    var st: Stopper = .{ .inner = &got, .ctl = &ctl };
    const out = try conn.connector().run(.{ .ptr = &st, .vtable = &.{ .submit = Stopper.submit } }, &ctl, null);
    try testing.expect(out.interrupted);
    try testing.expectEqual(@as(usize, 1), got.ids.items.len);

    // Resuming from the checkpoint continues after the first seed.
    var got2: Collect = .{};
    defer got2.deinit();
    var ctl2: api.Control = .{};
    _ = try conn.connector().run(got2.sink(), &ctl2, out.checkpoint);
    try testing.expectEqual(@as(usize, 2), got2.ids.items.len);
    try testing.expect(std.mem.endsWith(u8, got2.ids.items[0], "/2"));
}
