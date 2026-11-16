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
const xml = @import("../xml.zig");

pub const kind = "crawl";
pub const default_delay_ms: u32 = 1000;
pub const min_delay_ms: u32 = 100;
pub const max_delay_ms: u32 = 3_600_000;
pub const default_max_page_bytes: u32 = 2 * 1024 * 1024;
pub const hard_max_page_bytes: u32 = 32 * 1024 * 1024;
pub const default_max_depth: u32 = 3;
pub const hard_max_depth: u32 = 10;
pub const default_max_pages: u32 = 1000;
pub const hard_max_pages: u32 = 1_000_000;
pub const default_max_hosts: u32 = 100;
pub const hard_max_hosts: u32 = 100_000;
pub const default_timeout_s: u32 = 30;
pub const max_timeout_s: u32 = 300;
const max_redirects = 5;
/// Links taken from one page, pending URLs per tree, and URLs remembered per run.
const max_links_per_page = 2000;
const max_queue = 50_000;
const max_visited = 2_000_000;
const max_sitemap_urls = 50_000;
const max_sitemap_bytes = 10 * 1024 * 1024;
const max_sitemap_files = 50;
const accept_sitemap = "application/xml,text/xml;q=0.9,text/plain;q=0.5";
const max_seeds = 10_000;
const max_seeds_file_bytes = 4 * 1024 * 1024;
/// A site's `crawl-delay` is honored up to this many seconds.
const max_crawl_delay_s = 60;
const checkpoint_every = 10;
/// While one address is still being crawled, the work so far is committed every this many pages
/// (with the position of the last finished address), so a crash loses a few pages, not the whole crawl.
const save_every_pages = 25;
const max_user_agent = 200;
const accept_pages = "text/html,application/xhtml+xml,text/plain;q=0.9";
const accept_robots = "text/plain";

const allowed_options = [_][]const u8{ "user_agent", "seeds_file", "delay_ms", "max_page_bytes", "max_depth", "max_pages", "follow_external", "allow_private_addresses", "max_hosts", "timeout_seconds", "ca_bundle", "language" };

// ------------------------------------------------------------ validation

pub fn key(buf: []u8, source: config.Source, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "source[{s}].{s}", .{ source.name, name }) catch name;
}

pub fn needString(source: config.Source, name: []const u8, required: bool, diag: *config.Diagnostic) config.Error!?[]const u8 {
    var kbuf: [128]u8 = undefined;
    const v = source.option(name) orelse {
        if (required) {
            diag.set("", key(&kbuf, source, name), "is required for kind \"{s}\"", .{source.kind});
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

pub fn intOption(source: config.Source, name: []const u8, lo: u32, hi: u32, diag: *config.Diagnostic) config.Error!void {
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

pub fn boolOption(source: config.Source, name: []const u8, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    const v = source.option(name) orelse return;
    switch (v) {
        .boolean => {},
        else => {
            diag.set("", key(&kbuf, source, name), "expected boolean", .{});
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
    try intOption(source, "max_depth", 0, hard_max_depth, diag);
    try intOption(source, "max_pages", 1, hard_max_pages, diag);
    try intOption(source, "max_hosts", 1, hard_max_hosts, diag);
    try boolOption(source, "follow_external", diag);
    try boolOption(source, "allow_private_addresses", diag);
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
    max_depth: u32,
    max_pages: u32,
    max_hosts: u32,
    follow_external: bool,
    allow_private: bool,
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
            .max_depth = @intCast(source.optionInt("max_depth") orelse default_max_depth),
            .max_pages = @intCast(source.optionInt("max_pages") orelse default_max_pages),
            .max_hosts = @intCast(source.optionInt("max_hosts") orelse default_max_hosts),
            .follow_external = source.optionBool("follow_external") orelse false,
            .allow_private = source.optionBool("allow_private_addresses") orelse false,
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
            for (seeds, 0..) |sd, i| if (std.mem.eql(u8, sd.line, at)) {
                start = i + 1;
            };
        }

        var done: ?[]const u8 = if (start > 0) seeds[start - 1].line else null;
        r.last_done = done;
        var since: u32 = 0;
        for (seeds[start..], start..) |seed, seed_index| {
            // With no link following the seeds are the whole job; otherwise the
            // number of pages is open-ended and only the page budget bounds it.
            if (self.max_depth == 0) control.setProgress(seed_index, seeds.len) else control.setProgress(r.fetched, self.max_pages);
            if (control.isCancelled()) return self.stopped(done);
            switch (try r.crawlSeed(seed)) {
                .stopped => return self.stopped(done),
                .stored, .skipped => {},
            }
            if (r.exhausted) break; // the page budget for this run is spent
            done = seed.line;
            r.last_done = done;
            r.unsaved = 0;
            since += 1;
            if (since >= checkpoint_every) {
                since = 0;
                sink.checkpoint(seed.line) catch |e| switch (e) {
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

    /// One entry per line: an absolute http(s) URL, or `sitemap URL`. Blank
    /// lines and `#` comments are skipped, lines that are not usable are
    /// ignored.
    fn readSeeds(self: *CrawlConnector, arena: Allocator) ![]const Seed {
        const data = try Io.Dir.cwd().readFileAlloc(self.io, self.seeds_file, arena, .limited(max_seeds_file_bytes));
        var out: std.ArrayList(Seed) = .empty;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (std.mem.indexOfScalar(u8, line, '#')) |h| line = std.mem.trim(u8, line[0..h], " \t");
            var url = line;
            var sitemap = false;
            if (line.len > 8 and std.ascii.eqlIgnoreCase(line[0..7], "sitemap") and (line[7] == ' ' or line[7] == '\t')) {
                sitemap = true;
                url = std.mem.trim(u8, line[8..], " \t");
            }
            if (parseUrl(url) == null) continue;
            if (out.items.len >= max_seeds) break;
            try out.append(arena, .{ .line = line, .url = url, .sitemap = sitemap });
        }
        return out.items;
    }
};

const Seed = struct {
    /// The whole line, which is also the resume position.
    line: []const u8,
    url: []const u8,
    sitemap: bool,
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

/// True for hosts that name this machine or a private network: "localhost",
/// names with no dot or ending in a local-only suffix, IPv4 literals in
/// loopback, private, link-local, carrier-grade NAT, multicast or reserved
/// ranges, any IPv6 literal, and numbers that merely look like addresses
/// (decimal, hex or short forms some resolvers accept). A name that *resolves*
/// to a private address cannot be told from here.
fn isPrivateHost(host_in: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (host_in.len == 0 or host_in.len > buf.len) return true;
    const host = std.ascii.lowerString(&buf, host_in);
    if (host[0] == '[' or std.mem.indexOfScalar(u8, host, ':') != null) return true; // IPv6 literal
    const trimmed = std.mem.trimEnd(u8, host, ".");
    if (trimmed.len == 0) return true;
    const suffixes = [_][]const u8{ ".localhost", ".local", ".internal", ".lan", ".home", ".home.arpa", ".corp", ".intranet", ".localdomain" };
    if (std.mem.eql(u8, trimmed, "localhost")) return true;
    for (suffixes) |x| if (std.mem.endsWith(u8, trimmed, x)) return true;
    if (std.mem.indexOfScalar(u8, trimmed, '.') == null) return true; // a bare name resolves through the local network
    // Anything made only of digits, dots and hex marks is an address in disguise.
    var numeric = true;
    for (trimmed) |c| if (!(std.ascii.isHex(c) or c == '.' or c == 'x')) {
        numeric = false;
    };
    if (!numeric) return false;
    const quad = std.Io.net.Ip4Address.parse(trimmed, 0) catch return true; // odd forms: refuse
    const b = quad.bytes;
    return b[0] == 0 or b[0] == 10 or b[0] == 127 or b[0] >= 224 or
        (b[0] == 100 and b[1] >= 64 and b[1] <= 127) or
        (b[0] == 169 and b[1] == 254) or
        (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or
        (b[0] == 192 and b[1] == 168) or
        (b[0] == 192 and b[1] == 0 and b[2] == 0) or
        (b[0] == 198 and (b[1] == 18 or b[1] == 19));
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
    /// Every URL fetched or queued this run, so none is requested twice.
    visited: std.StringHashMapUnmanaged(void) = .empty,
    /// Page requests made (robots.txt excluded), against `max_pages`.
    fetched: u64 = 0,
    exhausted: bool = false,
    stored: u64 = 0,
    /// The last address that was crawled completely: a safe place to resume from.
    last_done: ?[]const u8 = null,
    /// Pages stored since the work was last committed.
    unsaved: u32 = 0,
    network_failures: u64 = 0,
    /// The address being fetched, named in the examples of what was skipped (a copy, because the address
    /// itself lives in a short-lived arena).
    current_buf: [api.Control.max_sample_bytes]u8 = undefined,
    current_len: usize = 0,

    fn setCurrent(self: *Run, url: []const u8) void {
        const n = @min(url.len, self.current_buf.len);
        @memcpy(self.current_buf[0..n], url[0..n]);
        self.current_len = n;
    }

    const Result = enum { stored, skipped, stopped };

    fn reject(self: *Run, why: api.Reason) Result {
        self.control.rejectAt(why, self.current_buf[0..self.current_len]);
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
    /// `listed` is true for a page the administrator named (a seed or a sitemap
    /// entry): such a site is always allowed; `max_hosts` bounds only sites
    /// reached by following links and redirects.
    fn hostFor(self: *Run, u: Url, listed: bool) error{ OutOfMemory, Canceled, TooManyHosts }!*Host {
        const origin = try originOf(self.arena, u);
        if (self.hosts.get(origin)) |h| return h;
        if (!listed and self.hosts.count() >= self.conn.max_hosts) return error.TooManyHosts;
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

    const Fetched = union(enum) {
        /// `url` is where the answer came from, after redirects.
        page: struct { url: []const u8, resp: fetch.Response },
        skipped,
        stopped,
    };

    /// One polite GET of `start`: robots.txt, the host's turn, the request and
    /// same-site redirects. Everything is allocated in `a`.
    fn get(self: *Run, a: Allocator, start: []const u8, site_host: []const u8, accept: []const u8, max_bytes: usize, listed: bool) error{OutOfMemory}!Fetched {
        var url = try withoutFragment(a, start);
        var hops: u32 = 0;
        self.fetched += 1;
        self.setCurrent(url);
        while (true) {
            const u = parseUrl(url) orelse return self.skip(.limit);
            const host = self.hostFor(u, listed and hops == 0) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return .stopped,
                error.TooManyHosts => return self.skip(.limit),
            };
            if (!host.rules.allowed(try targetOf(a, u))) return self.skip(.robots);
            if (!self.waitTurn(host)) return .stopped;

            const resp = fetch.get(self.client, a, .{
                .url = url,
                .user_agent = self.conn.user_agent,
                .accept = accept,
                .max_body_bytes = max_bytes,
            }, self.timeout());
            host.last = Io.Timestamp.now(self.conn.io, .awake);
            const got = resp catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return .stopped,
                error.Network, error.Timeout => {
                    self.network_failures += 1;
                    return self.skip(.network);
                },
                // A certificate that does not verify is a refusal, not an outage.
                error.Tls => return self.skip(.certificate),
                error.TooLarge => return self.skip(.too_large),
                else => return self.skip(.http_status),
            };

            if (got.status >= 300 and got.status < 400) {
                hops += 1;
                const loc = got.location orelse return self.skip(.redirect);
                const next = (try resolveRedirect(a, url, loc)) orelse return self.skip(.redirect);
                const there = parseUrl(next) orelse return self.skip(.redirect);
                if (hops > max_redirects or !self.mayVisit(site_host, there.host)) return self.skip(.redirect);
                url = next;
                continue;
            }
            if (got.status < 200 or got.status >= 300) return self.skip(.http_status);
            return .{ .page = .{ .url = url, .resp = got } };
        }
    }

    /// Whether a link or redirect to `host` may be followed from a crawl that
    /// started on `site`: the same site always; another site only if
    /// `follow_external` is on, and then never a private or local address
    /// unless `allow_private_addresses` says so.
    fn mayVisit(self: *Run, site: []const u8, host: []const u8) bool {
        if (sameSite(host, site)) return true;
        if (!self.conn.follow_external) return false;
        return self.conn.allow_private or !isPrivateHost(host);
    }

    fn skip(self: *Run, why: api.Reason) Fetched {
        self.control.rejectAt(why, self.current_buf[0..self.current_len]);
        return .skipped;
    }

    /// True the first time `url` is seen this run; remembers it. Also false
    /// once the table is full, which keeps memory bounded.
    fn firstVisit(self: *Run, url: []const u8) error{OutOfMemory}!?[]const u8 {
        if (self.visited.count() >= max_visited) return null;
        const gop = try self.visited.getOrPut(self.arena, url);
        if (gop.found_existing) return null;
        gop.key_ptr.* = try self.arena.dupe(u8, url);
        return gop.key_ptr.*;
    }

    fn crawlSeed(self: *Run, seed: Seed) error{OutOfMemory}!Result {
        const u = parseUrl(seed.url) orelse return self.reject(.limit);
        if (!seed.sitemap) return self.crawlTree(seed.url, 0, u.host);

        // A sitemap lists pages: fetch each of them, and follow no links from
        // them (the sitemap already says what the site wants indexed).
        var arena = std.heap.ArenaAllocator.init(self.conn.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var pages: std.ArrayList([]const u8) = .empty;
        var n_files: u32 = 0;
        if (try self.sitemapPages(a, seed.url, u.host, 0, &n_files, &pages)) return .stopped;
        var last: Result = .skipped;
        for (pages.items) |page| {
            last = try self.crawlTree(page, self.conn.max_depth, u.host);
            if (last == .stopped) return .stopped;
            if (self.exhausted) break;
        }
        return last;
    }

    /// Expands the sitemap (or sitemap index) at `url` into page URLs on the
    /// sitemap's own site. Returns true if the run was stopped.
    fn sitemapPages(self: *Run, a: Allocator, url: []const u8, site: []const u8, level: u32, n_files: *u32, out: *std.ArrayList([]const u8)) error{OutOfMemory}!bool {
        if (n_files.* >= max_sitemap_files or self.fetched >= self.conn.max_pages) return false;
        n_files.* += 1;
        var tmp = std.heap.ArenaAllocator.init(self.conn.gpa);
        defer tmp.deinit();
        const t = tmp.allocator();
        const got = switch (try self.get(t, url, site, accept_sitemap, max_sitemap_bytes, level == 0)) {
            .stopped => return true,
            .skipped => return false,
            .page => |p| p,
        };
        // A sitemap may be served gzip-compressed as a file (sitemap.xml.gz),
        // which is not the same as a Content-Encoding the HTTP client undoes.
        const body = if (isGzip(got.resp.body)) (gunzip(t, got.resp.body, max_sitemap_bytes) orelse {
            _ = self.reject(.too_large);
            return false;
        }) else got.resp.body;
        var h: SitemapHandler = .{ .arena = a, .urls = .empty };
        defer h.text.deinit(self.conn.gpa);
        h.gpa = self.conn.gpa;
        var parser: xml.Parser(SitemapHandler) = undefined;
        parser.init(self.conn.gpa, &h) catch return error.OutOfMemory;
        defer parser.deinit();
        parser.feed(body, true) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // Too many entries stops the parser on purpose; keep what we have.
            error.Stopped => {},
            error.Malformed => {
                _ = self.reject(.wrong_type);
                return false;
            },
        };
        for (h.urls.items) |loc| {
            const target = (try resolveRedirect(a, got.url, loc)) orelse continue;
            const tu = parseUrl(target) orelse continue;
            if (!sameSite(tu.host, site)) continue; // a sitemap may only name its own site
            if (h.is_index) {
                if (level >= 2) continue;
                if (try self.sitemapPages(a, target, site, level + 1, n_files, out)) return true;
            } else if (out.items.len < max_sitemap_urls) {
                try out.append(a, target);
            }
        }
        return false;
    }

    /// Breadth-first from `root`, following same-site links down to
    /// `max_depth`. `depth0` is the depth of `root` itself.
    fn crawlTree(self: *Run, root: []const u8, depth0: u32, site: []const u8) error{OutOfMemory}!Result {
        const gpa = self.conn.gpa;
        var queue: std.ArrayList(Item) = .empty;
        defer queue.deinit(gpa);
        const first = (try self.firstVisit(root)) orelse return .skipped;
        try queue.append(gpa, .{ .url = first, .depth = depth0 });
        var any = false;
        var head: usize = 0;
        while (head < queue.items.len) {
            if (self.control.isCancelled()) return .stopped;
            if (self.fetched >= self.conn.max_pages) {
                self.exhausted = true;
                break;
            }
            const item = queue.items[head];
            head += 1;

            var page = std.heap.ArenaAllocator.init(gpa);
            defer page.deinit();
            const a = page.allocator();
            const got = switch (try self.get(a, item.url, site, accept_pages, self.conn.max_page_bytes, head == 1)) {
                .stopped => return .stopped,
                .skipped => continue,
                .page => |p| p,
            };
            // A redirect target counts as seen too.
            if (!std.mem.eql(u8, got.url, item.url)) _ = try self.firstVisit(got.url);

            const stored = try self.store(a, got.url, got.resp);
            switch (stored.result) {
                .stopped => return .stopped,
                .stored => any = true,
                .skipped => {},
            }
            if (item.depth >= self.conn.max_depth) continue;
            for (stored.links) |link| {
                if (queue.items.len - head >= max_queue) break;
                const target = (try resolveRedirect(a, got.url, link)) orelse continue;
                const tu = parseUrl(target) orelse continue;
                if (!self.mayVisit(site, tu.host) or looksBinary(tu.uri.path)) continue;
                const keep = (try self.firstVisit(target)) orelse continue;
                try queue.append(gpa, .{ .url = keep, .depth = item.depth + 1 });
            }
        }
        return if (any) .stored else .skipped;
    }

    const Item = struct { url: []const u8, depth: u32 };

    const Stored = struct { result: Result, links: []const []const u8 = &.{} };

    fn store(self: *Run, a: Allocator, url: []const u8, got: fetch.Response) error{OutOfMemory}!Stored {
        const ct = parseContentType(got.content_type);
        const is_html = ct.media.len == 0 or std.mem.eql(u8, ct.media, "text/html") or std.mem.eql(u8, ct.media, "application/xhtml+xml");
        if (!is_html and !std.mem.eql(u8, ct.media, "text/plain")) return .{ .result = self.reject(.wrong_type) };

        const utf8 = (try toUtf8(a, got.body, ct.charset)) orelse return .{ .result = self.reject(.encoding) };
        const scanned: htmltext.Scan = if (is_html) try htmltext.scan(a, utf8, max_links_per_page) else .{};
        // The page may say "do not index" yet still lead to pages that are fine.
        if (scanned.noindex) return .{ .result = self.reject(.no_text), .links = scanned.links };
        const text = if (is_html) try htmltext.toText(a, utf8) else std.mem.trim(u8, utf8, " \t\r\n");
        if (text.len == 0) return .{ .result = self.reject(.no_text), .links = scanned.links };
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
            error.Rejected => return .{ .result = .skipped, .links = scanned.links }, // the pipeline counts it
            error.Stopped => return .{ .result = .stopped },
            error.OutOfMemory => return error.OutOfMemory,
        };
        _ = self.control.submitted.fetchAdd(1, .monotonic);
        self.stored += 1;
        self.unsaved += 1;
        if (self.unsaved >= save_every_pages) {
            self.unsaved = 0;
            // Restarting from the last finished address re-reads the current one: nothing is skipped.
            if (self.last_done) |safe_pos| self.sink.checkpoint(safe_pos) catch |e| switch (e) {
                error.Stopped => return .{ .result = .stopped },
                else => {}, // not fatal: the next page tries again
            };
        }
        return .{ .result = .stored, .links = scanned.links };
    }
};

fn isGzip(bytes: []const u8) bool {
    return bytes.len > 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

/// The decompressed bytes of a gzip file, or null if it is damaged or would
/// expand past `limit` (so a small file cannot become a huge one).
fn gunzip(a: Allocator, gz: []const u8, limit: usize) ?[]const u8 {
    const flate = std.compress.flate;
    var in: std.Io.Reader = .fixed(gz);
    const window = a.alloc(u8, flate.max_window_len) catch return null;
    var d = flate.Decompress.init(&in, .gzip, window);
    return d.reader.allocRemaining(a, .limited(limit)) catch null;
}

/// Collects the `<loc>` values of a sitemap or sitemap index.
const SitemapHandler = struct {
    arena: Allocator,
    gpa: Allocator = undefined,
    urls: std.ArrayList([]const u8),
    text: std.ArrayList(u8) = .empty,
    in_loc: bool = false,
    is_index: bool = false,
    const P = xml.Parser(SitemapHandler);

    fn local(name: []const u8) []const u8 {
        return if (std.mem.lastIndexOfScalar(u8, name, ':')) |i| name[i + 1 ..] else name;
    }

    pub fn startElement(self: *SitemapHandler, _: *P, name: []const u8, _: xml.Attrs) void {
        const n = local(name);
        if (std.mem.eql(u8, n, "sitemapindex")) self.is_index = true;
        if (std.mem.eql(u8, n, "loc")) {
            self.in_loc = true;
            self.text.clearRetainingCapacity();
        }
    }

    pub fn characters(self: *SitemapHandler, p: *P, bytes: []const u8) void {
        if (!self.in_loc) return;
        if (self.text.items.len + bytes.len > 4096) return; // too long to be a URL; dropped at the end
        self.text.appendSlice(self.gpa, bytes) catch p.stop();
    }

    pub fn endElement(self: *SitemapHandler, p: *P, name: []const u8) void {
        if (!std.mem.eql(u8, local(name), "loc")) return;
        self.in_loc = false;
        const v = std.mem.trim(u8, self.text.items, " \t\r\n");
        if (v.len == 0 or v.len >= 4096) return;
        if (self.urls.items.len >= max_sitemap_urls) return p.stop();
        const copy = self.arena.dupe(u8, v) catch return p.stop();
        self.urls.append(self.arena, copy) catch p.stop();
    }
};

/// Links to files that are not pages are not worth a request.
fn looksBinary(path: std.Uri.Component) bool {
    const text = componentText(path);
    const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse return false;
    if (std.mem.indexOfScalarPos(u8, text, dot, '/') != null) return false;
    const ext = text[dot + 1 ..];
    const skip = [_][]const u8{
        "jpg", "jpeg", "png",  "gif", "webp", "svg",   "ico", "bmp", "tif", "tiff", "pdf", "zip",  "gz",  "tgz",  "bz2",  "xz",
        "7z",  "rar",  "exe",  "dmg", "iso",  "msi",   "apk", "mp3", "mp4", "mkv",  "avi", "mov",  "wav", "ogg",  "flac", "webm",
        "css", "js",   "json", "xml", "woff", "woff2", "ttf", "eot", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub",
    };
    for (skip) |x| if (std.ascii.eqlIgnoreCase(ext, x)) return true;
    return false;
}

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

const nettest = @import("nettest.zig");
const TestServer = nettest.TestServer;
const Route = nettest.Route;
const Collect = nettest.Collect;
const big_body = nettest.big_body;

const runner = @import("../runner.zig");
const memory = @import("../memory.zig");
const pipeline = @import("../pipeline.zig");
const state_sqlite = @import("../state_sqlite.zig");
const index_sqlite = @import("../index_sqlite.zig");

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
    // ...and each is explained.
    const why = ctl.reasonCounts();
    try testing.expectEqual(@as(u64, 1), why[@backingInt(api.Reason.robots)]);
    try testing.expectEqual(@as(u64, 1), why[@backingInt(api.Reason.wrong_type)]);
    try testing.expectEqual(@as(u64, 1), why[@backingInt(api.Reason.http_status)]);

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

/// Runs a crawl of `seeds` against `srv` and returns what was stored.
fn crawlWith(srv: *TestServer, tmp: *testing.TmpDir, seeds_text: []const u8, depth: u32, pages: u32, got: *Collect, ctl: *api.Control) !void {
    var conn = try testConnector(tmp, seeds_text, "t/1");
    defer conn.deinit();
    conn.max_depth = depth;
    conn.max_pages = pages;
    _ = srv;
    _ = try conn.connector().run(got.sink(), ctl, null);
}

fn hasId(got: *const Collect, suffix: []const u8) bool {
    for (got.ids.items) |id| if (std.mem.endsWith(u8, id, suffix)) return true;
    return false;
}

const site_routes = [_]Route{
    .{ .path = "/robots.txt", .status = 404 },
    .{ .path = "/", .body = "<title>Home</title><p>home</p><a href=\"/a\">a</a> <a href=\"b.html\">b</a> <a href=\"http://elsewhere.invalid/x\">out</a> <a href=\"/pic.png\">pic</a> <a rel=\"nofollow\" href=\"/nofollow\">nf</a> <a href=\"/a#frag\">again</a> <a href=\"mailto:x@y\">mail</a>" },
    .{ .path = "/a", .body = "<p>page a</p><a href=\"/\">home</a><a href=\"/deep1\">d1</a>" },
    .{ .path = "/b.html", .body = "<p>page b</p>" },
    .{ .path = "/deep1", .body = "<p>deep one</p><a href=\"/deep2\">d2</a>" },
    .{ .path = "/deep2", .body = "<p>deep two</p><a href=\"/deep3\">d3</a>" },
    .{ .path = "/deep3", .body = "<p>deep three</p>" },
    .{ .path = "/nofollow", .body = "<p>should not be fetched</p>" },
    .{ .path = "/noindex", .body = "<meta name=\"robots\" content=\"noindex\"><p>hidden</p><a href=\"/visible\">v</a>" },
    .{ .path = "/visible", .body = "<p>visible</p>" },
};

test "links are followed on the same site, to the depth limit, each page once" {
    var srv: TestServer = undefined;
    try srv.start(&site_routes);
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [96]u8 = undefined;
    const seed = srv.url(&b, "/");

    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    try crawlWith(&srv, &tmp, seed, 2, 100, &got, &ctl);
    // Depth 2 from "/": a and b.html (1), deep1 (2); not deep2. No cycles, no
    // binaries, no nofollow, no other site, no mail links.
    try testing.expectEqual(@as(usize, 4), got.ids.items.len);
    try testing.expect(hasId(&got, "/a") and hasId(&got, "/b.html") and hasId(&got, "/deep1"));
    try testing.expectEqual(@as(usize, 1), srv.count("/a")); // linked twice, fetched once
    try testing.expectEqual(@as(usize, 1), srv.count("/")); // linked back to, fetched once
    try testing.expectEqual(@as(usize, 0), srv.count("/deep2"));
    try testing.expectEqual(@as(usize, 0), srv.count("/pic.png"));
    try testing.expectEqual(@as(usize, 0), srv.count("/nofollow"));
    try testing.expectEqual(@as(usize, 1), srv.count("/robots.txt"));
}

test "depth 0 fetches only the seeds; the page budget stops a run" {
    var srv: TestServer = undefined;
    try srv.start(&site_routes);
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [96]u8 = undefined;
    const seed = srv.url(&b, "/");

    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    try crawlWith(&srv, &tmp, seed, 0, 100, &got, &ctl);
    try testing.expectEqual(@as(usize, 1), got.ids.items.len);

    var got2: Collect = .{};
    defer got2.deinit();
    var ctl2: api.Control = .{};
    try crawlWith(&srv, &tmp, seed, 10, 3, &got2, &ctl2);
    try testing.expectEqual(@as(usize, 3), got2.ids.items.len); // "/", then two of its links
}

test "noindex pages are not stored but their links are followed" {
    var srv: TestServer = undefined;
    try srv.start(&site_routes);
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [96]u8 = undefined;
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    try crawlWith(&srv, &tmp, srv.url(&b, "/noindex"), 3, 100, &got, &ctl);
    try testing.expect(!hasId(&got, "/noindex"));
    try testing.expect(hasId(&got, "/visible"));
}

test "robots.txt applies to followed links too" {
    var routes = site_routes;
    routes[0] = .{ .path = "/robots.txt", .content_type = "text/plain", .body = "User-agent: *\nDisallow: /deep\n" };
    var srv: TestServer = undefined;
    try srv.start(&routes);
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [96]u8 = undefined;
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    try crawlWith(&srv, &tmp, srv.url(&b, "/"), 5, 100, &got, &ctl);
    try testing.expectEqual(@as(usize, 0), srv.count("/deep1"));
    try testing.expect(hasId(&got, "/a"));
}

test "sitemaps and sitemap indexes list pages, only for their own site" {
    var srv: TestServer = undefined;
    var index_buf: [400]u8 = undefined;
    var map_buf: [600]u8 = undefined;
    try srv.open();
    const index = try std.fmt.bufPrint(&index_buf, "<?xml version=\"1.0\"?><sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\"><sitemap><loc>http://127.0.0.1:{d}/map1.xml</loc></sitemap><sitemap><loc>/map2.xml.gz</loc></sitemap></sitemapindex>", .{srv.port});
    const map = try std.fmt.bufPrint(&map_buf, "<?xml version=\"1.0\"?><urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\"><url><loc>http://127.0.0.1:{d}/p1</loc></url><url><loc>/p2</loc></url><url><loc>http://elsewhere.invalid/p3</loc></url></urlset>", .{srv.port});
    try srv.serve(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/index.xml", .content_type = "application/xml", .body = index },
        .{ .path = "/map1.xml", .content_type = "application/xml", .body = map },
        .{ .path = "/p1", .body = "<p>one</p><a href=\"/linked\">l</a>" },
        .{ .path = "/p2", .body = "<p>two</p>" },
        .{ .path = "/linked", .body = "<p>not wanted: sitemap pages follow no links</p>" },
        .{ .path = "/bad.xml", .content_type = "application/xml", .body = "<urlset><url><loc>http://x" },
    });
    defer srv.stop();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [96]u8 = undefined;
    var line: [140]u8 = undefined;
    const seed = try std.fmt.bufPrint(&line, "sitemap {s}\n", .{srv.url(&b, "/index.xml")});
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    try crawlWith(&srv, &tmp, seed, 3, 100, &got, &ctl);
    try testing.expectEqual(@as(usize, 2), got.ids.items.len);
    try testing.expect(hasId(&got, "/p1") and hasId(&got, "/p2"));
    try testing.expectEqual(@as(usize, 0), srv.count("/linked"));
    try testing.expectEqual(@as(usize, 1), srv.count("/map2.xml.gz")); // asked for, not there
    try testing.expect(ctl.rejected.load(.monotonic) >= 1);

    // A malformed sitemap is skipped, not fatal.
    var got2: Collect = .{};
    defer got2.deinit();
    var ctl2: api.Control = .{};
    const seed2 = try std.fmt.bufPrint(&line, "sitemap {s}\n", .{srv.url(&b, "/bad.xml")});
    try crawlWith(&srv, &tmp, seed2, 3, 100, &got2, &ctl2);
    try testing.expectEqual(@as(usize, 0), got2.ids.items.len);
}

test "private and local hosts are recognised" {
    for ([_][]const u8{ "localhost", "LOCALHOST.", "printer.local", "nas", "router.lan", "10.1.2.3", "127.0.0.1", "192.168.0.9", "172.16.5.5", "172.31.255.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "[::1]", "[fe80::1]", "2130706433", "0x7f.0.0.1", "127.1", "1.2.3", "service.internal", "a.localhost" }) |h| {
        errdefer std.debug.print("should be private: {s}\n", .{h});
        try testing.expect(isPrivateHost(h));
    }
    for ([_][]const u8{ "example.org", "www.example.co.uk", "8.8.8.8", "172.32.0.1", "172.15.0.1", "100.63.0.1", "93.184.216.34", "xn--bcher-kva.example", "a.b.c.d.example" }) |h| {
        errdefer std.debug.print("should be public: {s}\n", .{h});
        try testing.expect(!isPrivateHost(h));
    }
}

test "links to other sites are followed only when asked, and never to private addresses by default" {
    var other: TestServer = undefined;
    other.openAt("127.0.0.2") catch return error.SkipZigTest;
    try other.serve(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/x", .body = "<p>on the other site</p>" },
    });
    defer other.stop();

    var origin: TestServer = undefined;
    try origin.open();
    var link_buf: [128]u8 = undefined;
    var page_buf: [400]u8 = undefined;
    const link = other.urlAt(&link_buf, "127.0.0.2", "/x");
    const page = try std.fmt.bufPrint(&page_buf, "<p>start</p><a href=\"{s}\">elsewhere</a><a href=\"/mine\">mine</a>", .{link});
    try origin.serve(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/", .body = page },
        .{ .path = "/mine", .body = "<p>same site</p>" },
    });
    defer origin.stop();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [96]u8 = undefined;
    const seed = origin.url(&b, "/");

    // Default: the other site is left alone.
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    try crawlWith(&origin, &tmp, seed, 3, 100, &got, &ctl);
    try testing.expect(hasId(&got, "/mine") and !hasId(&got, "/x"));
    try testing.expectEqual(@as(usize, 0), other.count("/x"));

    // follow_external alone still refuses a private (here loopback) address.
    {
        var conn = try testConnector(&tmp, seed, "t/1");
        defer conn.deinit();
        conn.follow_external = true;
        var g: Collect = .{};
        defer g.deinit();
        var c: api.Control = .{};
        _ = try conn.connector().run(g.sink(), &c, null);
        try testing.expect(!hasId(&g, "/x"));
        try testing.expectEqual(@as(usize, 0), other.count("/x"));
    }

    // With both options it goes there, after asking that site's robots.txt.
    {
        var conn = try testConnector(&tmp, seed, "t/1");
        defer conn.deinit();
        conn.follow_external = true;
        conn.allow_private = true;
        var g: Collect = .{};
        defer g.deinit();
        var c: api.Control = .{};
        _ = try conn.connector().run(g.sink(), &c, null);
        try testing.expect(hasId(&g, "/x") and hasId(&g, "/mine"));
        try testing.expectEqual(@as(usize, 1), other.count("/robots.txt"));
    }

    // max_hosts bounds how many sites one run talks to.
    {
        var conn = try testConnector(&tmp, seed, "t/1");
        defer conn.deinit();
        conn.follow_external = true;
        conn.allow_private = true;
        conn.max_hosts = 1;
        var g: Collect = .{};
        defer g.deinit();
        var c: api.Control = .{};
        _ = try conn.connector().run(g.sink(), &c, null);
        try testing.expect(hasId(&g, "/mine") and !hasId(&g, "/x"));
    }
}

test "sites you list are never cut off by max_hosts; only discovered sites count" {
    var a_srv: TestServer = undefined;
    try a_srv.start(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/p", .body = "<p>on the first site</p>" },
    });
    defer a_srv.stop();
    var b_srv: TestServer = undefined;
    b_srv.openAt("127.0.0.2") catch return error.SkipZigTest;
    try b_srv.serve(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/q", .body = "<p>on the second site</p>" },
    });
    defer b_srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b1: [96]u8 = undefined;
    var b2: [96]u8 = undefined;
    var seeds: [200]u8 = undefined;
    const text = try std.fmt.bufPrint(&seeds, "{s}\n{s}\n", .{ a_srv.url(&b1, "/p"), b_srv.urlAt(&b2, "127.0.0.2", "/q") });
    var conn = try testConnector(&tmp, text, "t/1");
    defer conn.deinit();
    conn.max_hosts = 1; // two different sites are listed, so both must be fetched
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expectEqual(@as(usize, 2), got.ids.items.len);
    try testing.expectEqual(@as(u64, 0), ctl.rejected.load(.monotonic));
}

test "a redirect to another site needs follow_external too" {
    var other: TestServer = undefined;
    other.openAt("127.0.0.2") catch return error.SkipZigTest;
    try other.serve(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/landing", .body = "<p>landed</p>" },
    });
    defer other.stop();
    var origin: TestServer = undefined;
    try origin.open();
    var loc_buf: [128]u8 = undefined;
    try origin.serve(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/go", .status = 301, .location = other.urlAt(&loc_buf, "127.0.0.2", "/landing"), .body = "" },
    });
    defer origin.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [96]u8 = undefined;
    const seed = origin.url(&b, "/go");
    {
        var conn = try testConnector(&tmp, seed, "t/1");
        defer conn.deinit();
        var g: Collect = .{};
        defer g.deinit();
        var c: api.Control = .{};
        _ = try conn.connector().run(g.sink(), &c, null);
        try testing.expectEqual(@as(usize, 0), g.ids.items.len);
    }
    {
        var conn = try testConnector(&tmp, seed, "t/1");
        defer conn.deinit();
        conn.follow_external = true;
        conn.allow_private = true;
        var g: Collect = .{};
        defer g.deinit();
        var c: api.Control = .{};
        _ = try conn.connector().run(g.sink(), &c, null);
        try testing.expectEqual(@as(usize, 1), g.ids.items.len);
        try testing.expect(hasId(&g, "/landing"));
    }
}

test "gzip-compressed sitemaps are read, and a decompression bomb is refused" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/s.xml.gz", .content_type = "application/gzip", .body = @embedFile("testdata/crawl/sitemap.xml.gz") },
        .{ .path = "/bomb.xml.gz", .content_type = "application/gzip", .body = @embedFile("testdata/crawl/bomb.xml.gz") },
        .{ .path = "/gz1", .body = "<p>gz one</p>" },
        .{ .path = "/gz2", .body = "<p>gz two</p>" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [96]u8 = undefined;
    var line: [140]u8 = undefined;

    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    try crawlWith(&srv, &tmp, try std.fmt.bufPrint(&line, "sitemap {s}\n", .{srv.url(&b, "/s.xml.gz")}), 0, 100, &got, &ctl);
    try testing.expectEqual(@as(usize, 2), got.ids.items.len);
    try testing.expect(hasId(&got, "/gz1") and hasId(&got, "/gz2"));

    var got2: Collect = .{};
    defer got2.deinit();
    var ctl2: api.Control = .{};
    try crawlWith(&srv, &tmp, try std.fmt.bufPrint(&line, "sitemap {s}\n", .{srv.url(&b, "/bomb.xml.gz")}), 0, 100, &got2, &ctl2);
    try testing.expectEqual(@as(usize, 0), got2.ids.items.len);
    try testing.expect(ctl2.rejected.load(.monotonic) >= 1);
}
