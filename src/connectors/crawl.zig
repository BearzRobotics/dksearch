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
//!   `crawl-delay` asks), one at a time: several seeds are crawled at once
//!   (`workers`), but a host is only ever asked by one of them at a time;
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
const hidden = @import("crawl/hidden.zig");
const toml = @import("toml");
const domainlist = @import("../domainlist.zig");
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
pub const default_workers: u32 = 8;
pub const default_window: u32 = 100;
pub const max_window: u32 = 10_000;
pub const max_workers: u32 = 64;
pub const max_timeout_s: u32 = 300;
const max_redirects = 5;
/// Links taken from one page, pending URLs per tree, and URLs remembered per run.
const max_links_per_page = 2000;
/// Pages found per level by one worker are kept up to this many (bounds the memory of a level).
const max_level_items = 100_000;
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

const allowed_options = [_][]const u8{ "user_agent", "seeds_file", "delay_ms", "max_page_bytes", "max_depth", "max_pages", "follow_external", "allow_private_addresses", "max_hosts", "timeout_seconds", "ca_bundle", "language", "workers", "window", "validators_file", "tor_socks", "i2p_proxy", "hidden_links", "allow_unbanned_onions", "seeds_sections", "seeds_skip" };

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
    try intOption(source, "workers", 1, max_workers, diag);
    try intOption(source, "window", 0, max_window, diag);
    _ = try needString(source, "ca_bundle", false, diag);
    _ = try needString(source, "validators_file", false, diag);
    try boolOption(source, "hidden_links", diag);
    try boolOption(source, "allow_unbanned_onions", diag);
    _ = try needString(source, "seeds_sections", false, diag);
    _ = try needString(source, "seeds_skip", false, diag);
    inline for (.{ "tor_socks", "i2p_proxy" }) |k| if (try needString(source, k, false, diag)) |v| if (hidden.parseProxy(v) == null) {
        diag.set("", key(&kbuf, source, k), "must be the address of the proxy as IP:port, e.g. \"127.0.0.1:9050\"", .{});
        return error.InvalidValue;
    };
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
    /// How many seeds are crawled at once (each in its own task, with its own connection).
    workers: u32,
    /// How many seeds are crawled together, breadth-first (0: all of them); the resume position moves per window.
    window: u32,
    ca: cabundle.Choice,
    language: ?[]const u8,
    /// Where to keep the `ETag` and `Last-Modified` of the pages at the depth limit between runs (none: no
    /// conditional requests).
    validators_file: ?[]const u8,
    /// A Tor SOCKS5 proxy and an I2P HTTP proxy, when `.onion` and `.i2p` sites may be crawled (docs/decisions/0044).
    tor: ?std.Io.net.IpAddress,
    i2p: ?std.Io.net.IpAddress,
    /// For a TOML seeds file: the sections to take (comma-separated names; empty: all) and the sections to leave out.
    seeds_sections: ?[]const u8,
    seeds_skip: ?[]const u8,
    /// Follow links from other sites into the hidden networks (a source whose seeds are there already stays there).
    hidden_links: bool,
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
        errdefer if (language) |l| gpa.free(l);
        const validators_file = if (source.optionString("validators_file")) |l| try gpa.dupe(u8, l) else null;
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
            .workers = @intCast(source.optionInt("workers") orelse default_workers),
            .window = @intCast(source.optionInt("window") orelse default_window),
            .ca = ca,
            .language = language,
            .validators_file = validators_file,
            .tor = if (source.optionString("tor_socks")) |v| hidden.parseProxy(v) else null,
            .i2p = if (source.optionString("i2p_proxy")) |v| hidden.parseProxy(v) else null,
            .hidden_links = source.optionBool("hidden_links") orelse false,
            .seeds_sections = if (source.optionString("seeds_sections")) |v| try gpa.dupe(u8, v) else null,
            .seeds_skip = if (source.optionString("seeds_skip")) |v| try gpa.dupe(u8, v) else null,
        };
    }

    /// How to reach `host`: directly, through the configured Tor or I2P proxy for a name of those networks, or null
    /// when it belongs to a hidden network that has no proxy here (it must then not be contacted at all).
    fn routeFor(self: *const CrawlConnector, host: []const u8) ?hidden.Via {
        const net_of = hidden.networkOf(host) orelse return .direct;
        return switch (net_of) {
            .onion => if (self.tor) |a| (if (hidden.validOnion(host)) hidden.Via{ .tor = a } else null) else null,
            .i2p => if (self.i2p) |a| .{ .i2p = a } else null,
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
        if (self.validators_file) |l| self.gpa.free(l);
        if (self.seeds_sections) |l| self.gpa.free(l);
        if (self.seeds_skip) |l| self.gpa.free(l);
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

        var start: usize = 0;
        if (resume_from) |at| {
            for (seeds, 0..) |sd, i| if (std.mem.eql(u8, sd.line, at)) {
                start = i + 1;
            };
        }
        if (start >= seeds.len) return .{};

        var locked: LockedSink = .{ .inner = sink, .io = self.io };
        var sh: Shared = .{ .first_seed = start };
        if (self.validators_file) |path| self.loadValidators(run_arena.allocator(), path, &sh.old);
        sh.finished = try run_arena.allocator().alloc(bool, seeds.len - start);
        @memset(sh.finished, false);
        sh.last_done = if (start > 0) seeds[start - 1].line else null;

        // One client and one `Run` per worker, kept for the whole crawl.
        const n_workers: usize = @max(1, @min(self.workers, seeds.len - start));
        const clients = try self.gpa.alloc(http.Client, n_workers);
        defer self.gpa.free(clients);
        const runs = try self.gpa.alloc(Run, n_workers);
        defer self.gpa.free(runs);
        var made: usize = 0;
        defer for (clients[0..made]) |*cl| cl.deinit();
        for (clients, runs) |*cl, *rn| {
            cl.* = .{ .allocator = self.gpa, .io = self.io };
            made += 1;
            cabundle.load(&cl.ca_bundle, self.gpa, self.io, self.ca) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSource,
            };
            cl.now = Io.Clock.real.now(self.io);
            rn.* = .{ .conn = self, .arena = run_arena.allocator(), .client = cl, .sink = locked.sink(), .control = control, .sh = &sh };
        }
        const outs = try self.gpa.alloc(std.ArrayList(Task), n_workers);
        defer {
            for (outs) |*o| o.deinit(self.gpa);
            self.gpa.free(outs);
        }
        @memset(outs, .empty);

        // The seeds are taken in windows. Inside a window the crawl is breadth-first: every seed's first page, then
        // every page one link away, and so on, so a window covers many sites early instead of one site deeply.
        // The resume position moves forward a window at a time.
        var first = start;
        windows: while (first < seeds.len) {
            const end = if (self.window == 0) seeds.len else @min(first + self.window, seeds.len);
            // Level 0: the seeds themselves (a sitemap seed contributes its pages, which follow no links).
            var level: std.ArrayList(Task) = .empty;
            defer level.deinit(self.gpa);
            for (seeds[first..end], first..) |seed, index| {
                if (control.isCancelled() or sh.stop.load(.monotonic)) break :windows;
                const u = parseUrl(seed.url) orelse {
                    _ = runs[0].reject(.limit);
                    continue;
                };
                if (!seed.sitemap) {
                    const keep = (runs[0].firstVisit(seed.url) catch return error.OutOfMemory) orelse continue;
                    try level.append(self.gpa, .{ .url = keep, .depth = 0, .seed = @intCast(index), .root = true, .site = u.host });
                } else {
                    var arena = std.heap.ArenaAllocator.init(self.gpa);
                    defer arena.deinit();
                    const a = arena.allocator();
                    var pages: std.ArrayList([]const u8) = .empty;
                    var n_files: u32 = 0;
                    if (runs[0].sitemapPages(a, seed.url, u.host, 0, &n_files, &pages) catch return error.OutOfMemory) break :windows;
                    for (pages.items) |page| {
                        const keep = (runs[0].firstVisit(page) catch return error.OutOfMemory) orelse continue;
                        try level.append(self.gpa, .{ .url = keep, .depth = self.max_depth, .seed = @intCast(index), .root = true, .site = u.host });
                    }
                }
            }
            var depth: u32 = 0;
            while (level.items.len > 0) : (depth += 1) {
                if (self.max_depth == 0) control.setProgress(first, seeds.len) else control.setProgress(sh.fetched.load(.monotonic), self.max_pages);
                var ctx: LevelContext = .{ .conn = self, .items = level.items, .runs = runs, .outs = outs };
                defer ctx.deferred.deinit(self.gpa);
                var group: Io.Group = .init;
                var started: usize = 0;
                while (started + 1 < n_workers) : (started += 1) {
                    group.concurrent(self.io, levelWorker, .{ &ctx, started + 1 }) catch break;
                }
                levelWorker(&ctx, 0) catch {};
                group.await(self.io) catch {};
                const all_taken = ctx.next.load(.monotonic) >= level.items.len and !sh.stop.load(.monotonic) and !sh.exhausted.load(.monotonic);
                // The next level: what the workers found, taken a seed at a time so that consecutive pages are on
                // different sites (a site is asked by one worker at a time, so a run of one site's pages would
                // leave the others idle).
                const next = try self.nextLevel(outs, first, end);
                // Stopped part-way through the window: it is not finished (unless this was its last level and every
                // page of it was fetched, in which case there is nothing left to repeat).
                if ((control.isCancelled() or sh.stop.load(.monotonic) or sh.exhausted.load(.monotonic)) and !(all_taken and next.len == 0)) {
                    self.gpa.free(next);
                    break :windows;
                }
                level.clearRetainingCapacity();
                try level.appendSlice(self.gpa, next);
                self.gpa.free(next);
            }
            // The window is done: its seeds are finished, in order.
            for (first..end) |index| self.finishSeed(&sh, seeds, index, locked.sink());
            if (sh.stop.load(.monotonic) or control.isCancelled()) break;
            first = end;
        }

        if (sh.out_of_memory.load(.monotonic)) return error.OutOfMemory;
        if (self.validators_file) |path| self.saveValidators(path, &sh);
        sh.mutex.lockUncancelable(self.io);
        const done = sh.last_done;
        sh.mutex.unlock(self.io);
        if (control.isCancelled() or sh.stop.load(.monotonic)) return self.stopped(done);
        // Not one page could be reached: the network is the likely cause.
        if (sh.stored.load(.monotonic) == 0 and sh.network_failures.load(.monotonic) > 0) return error.Offline;
        return .{};
    }

    /// One page of the crawl: the address, how many links from its seed it is, which seed it belongs to (and so its
    /// site, which decides which links may be followed), and whether the administrator named it.
    const Task = struct {
        url: []const u8,
        depth: u32,
        seed: u32,
        root: bool = false,
        site: []const u8,
    };

    const LevelContext = struct {
        conn: *CrawlConnector,
        items: []const Task,
        runs: []Run,
        outs: []std.ArrayList(Task),
        next: std.atomic.Value(usize) = .init(0),
        /// Pages set aside because their site was busy; fetched when the level's queue is empty.
        deferred: std.ArrayList(Task) = .empty,
        deferred_mutex: Io.Mutex = .init,
    };

    /// A worker of one level: takes the next page of the level until there are none, fetching, storing and
    /// collecting the links of each into its own list.
    fn levelWorker(ctx: *LevelContext, w: usize) Io.Cancelable!void {
        const self = ctx.conn;
        const r = &ctx.runs[w];
        const sh = r.sh;
        while (true) {
            if (r.control.isCancelled() or sh.stop.load(.monotonic) or sh.exhausted.load(.monotonic)) return;
            var task: ?Task = null;
            const index = ctx.next.fetchAdd(1, .monotonic);
            if (index < ctx.items.len) {
                const t = ctx.items[index];
                // A site that is being asked right now would keep this worker waiting while other sites' pages wait
                // in the queue: set it aside for later (once the queue is empty everything left is simply fetched).
                if (r.hostBusy(t.url)) {
                    ctx.deferred_mutex.lockUncancelable(self.io);
                    ctx.deferred.append(self.gpa, t) catch {
                        ctx.deferred_mutex.unlock(self.io);
                        sh.out_of_memory.store(true, .monotonic);
                        sh.stop.store(true, .monotonic);
                        return;
                    };
                    ctx.deferred_mutex.unlock(self.io);
                    continue;
                }
                task = t;
            } else {
                ctx.deferred_mutex.lockUncancelable(self.io);
                task = ctx.deferred.pop();
                ctx.deferred_mutex.unlock(self.io);
                if (task == null) return;
            }
            const result = r.fetchOne(task.?, &ctx.outs[w]) catch {
                sh.out_of_memory.store(true, .monotonic);
                sh.stop.store(true, .monotonic);
                return;
            };
            if (result == .stopped) {
                sh.stop.store(true, .monotonic);
                return;
            }
        }
    }

    /// Merges the workers' found links into the next level, round-robin over the seeds of the window `first..end`.
    fn nextLevel(self: *CrawlConnector, outs: []std.ArrayList(Task), first: usize, end: usize) Allocator.Error![]Task {
        const n = end - first;
        const buckets = try self.gpa.alloc(std.ArrayList(Task), n);
        defer {
            for (buckets) |*b| b.deinit(self.gpa);
            self.gpa.free(buckets);
        }
        @memset(buckets, .empty);
        var total: usize = 0;
        for (outs) |*o| {
            for (o.items) |t| {
                try buckets[t.seed - first].append(self.gpa, t);
                total += 1;
            }
            o.clearRetainingCapacity();
        }
        const merged = try self.gpa.alloc(Task, total);
        var at: usize = 0;
        var round: usize = 0;
        while (at < total) : (round += 1) {
            for (buckets) |*b| {
                if (round < b.items.len) {
                    merged[at] = b.items[round];
                    at += 1;
                }
            }
        }
        return merged;
    }

    /// Records that seed `index` is finished and moves the resume position forward over every seed that is now
    /// finished in a row from the start; every few seeds the position is reported to the pipeline.
    fn finishSeed(self: *CrawlConnector, sh: *Shared, seeds: []const Seed, index: usize, sink: api.Sink) void {
        sh.mutex.lockUncancelable(self.io);
        sh.finished[index - sh.first_seed] = true;
        var moved = false;
        while (sh.prefix < sh.finished.len and sh.finished[sh.prefix]) {
            sh.last_done = seeds[sh.first_seed + sh.prefix].line;
            sh.prefix += 1;
            moved = true;
        }
        sh.unsaved = 0;
        var report: ?[]const u8 = null;
        if (moved) {
            sh.finished_since_checkpoint += 1;
            if (sh.finished_since_checkpoint >= checkpoint_every) {
                sh.finished_since_checkpoint = 0;
                report = sh.last_done;
            }
        }
        sh.mutex.unlock(self.io);
        if (report) |line| sink.checkpoint(line) catch |e| switch (e) {
            error.Stopped => sh.stop.store(true, .monotonic),
            else => {},
        };
    }

    fn stopped(self: *CrawlConnector, done: ?[]const u8) api.Outcome {
        const d = done orelse return .{ .interrupted = true };
        self.checkpoint_buf.clearRetainingCapacity();
        self.checkpoint_buf.appendSlice(self.gpa, d) catch return .{ .interrupted = true };
        return .{ .interrupted = true, .checkpoint = self.checkpoint_buf.items };
    }

    /// The validators of the last run: `URL<TAB>ETag<TAB>Last-Modified` per line (either validator may be empty).
    /// A file that is missing or damaged is no validators: every page is simply fetched in full.
    fn loadValidators(self: *CrawlConnector, arena: Allocator, path: []const u8, into: *std.StringHashMapUnmanaged(Validator)) void {
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(max_validators_bytes)) catch return;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, '\t');
            const url = f.next() orelse continue;
            const etag = f.next() orelse continue;
            const lm = f.next() orelse continue;
            if (url.len == 0 or (etag.len == 0 and lm.len == 0) or parseUrl(url) == null) continue;
            if (into.count() >= max_validators) break;
            into.put(arena, url, .{ .etag = if (etag.len > 0) etag else null, .last_modified = if (lm.len > 0) lm else null }) catch return;
        }
    }

    /// Writes the validators back: this run's, and the earlier ones for pages this run did not reach (a partial run
    /// must not forget the rest). Replaced atomically; a failure only means the next run fetches in full.
    fn saveValidators(self: *CrawlConnector, path: []const u8, sh: *Shared) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        const add = struct {
            fn one(list: *std.ArrayList(u8), gpa: Allocator, url: []const u8, v: Validator) void {
                list.print(gpa, "{s}\t{s}\t{s}\n", .{ url, v.etag orelse "", v.last_modified orelse "" }) catch {};
            }
        }.one;
        sh.mutex.lockUncancelable(self.io);
        defer sh.mutex.unlock(self.io);
        var it = sh.fresh.iterator();
        while (it.next()) |e| add(&out, self.gpa, e.key_ptr.*, e.value_ptr.*);
        var old_it = sh.old.iterator();
        while (old_it.next()) |e| if (!sh.fresh.contains(e.key_ptr.*)) add(&out, self.gpa, e.key_ptr.*, e.value_ptr.*);
        const tmp = std.fmt.allocPrint(self.gpa, "{s}.tmp", .{path}) catch return;
        defer self.gpa.free(tmp);
        const cwd = Io.Dir.cwd();
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = out.items }) catch return;
        cwd.rename(tmp, cwd, path, self.io) catch {
            cwd.deleteFile(self.io, tmp) catch {};
        };
    }

    /// One entry per line: an absolute http(s) URL, or `sitemap URL`. Blank
    /// lines and `#` comments are skipped, lines that are not usable are
    /// ignored.
    fn readTomlSeeds(self: *CrawlConnector, arena: Allocator, data: []const u8) ![]const Seed {
        return tomlSeeds(arena, data, self.seeds_sections, self.seeds_skip);
    }

    fn readSeeds(self: *CrawlConnector, arena: Allocator) ![]const Seed {
        const data = try Io.Dir.cwd().readFileAlloc(self.io, self.seeds_file, arena, .limited(max_seeds_file_bytes));
        if (std.mem.endsWith(u8, self.seeds_file, ".toml")) return self.readTomlSeeds(arena, data);
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

/// Whether `name` is in a comma-separated list of section names (case-insensitive).
fn inNameList(list: ?[]const u8, name: []const u8) bool {
    const l = list orelse return false;
    var it = std.mem.tokenizeAny(u8, l, ", \t");
    while (it.next()) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// Seeds from a TOML file: sections (`[computers]` with `[[computers.site]]` entries) or plain `[[site]]` entries, each
/// with a `url` (and `sitemap = true` for a sitemap). `seeds_sections` and `seeds_skip` choose sections.
fn tomlSeeds(arena: Allocator, data: []const u8, sections: ?[]const u8, skip: ?[]const u8) ![]const Seed {
    var tdiag: toml.Diagnostic = .{};
    const tdoc = toml.Document.parse(arena, data, .{}, &tdiag) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidToml;
    var out: std.ArrayList(Seed) = .empty;
    const SiteReader = struct {
        fn sites(a: Allocator, v: toml.Value, list: *std.ArrayList(Seed)) !void {
            const arr = switch (v) {
                .array => |x| x,
                else => return,
            };
            for (arr.items.items) |item| {
                const t = switch (item) {
                    .table => |x| x,
                    else => continue,
                };
                const url = t.getString("url") orelse continue;
                if (parseUrl(url) == null) continue;
                if (list.items.len >= max_seeds) return;
                const sm = if (t.get("sitemap")) |s| (switch (s) {
                    .boolean => |b| b,
                    else => false,
                }) else false;
                try list.append(a, .{ .line = try a.dupe(u8, url), .url = try a.dupe(u8, url), .sitemap = sm });
            }
        }
    };
    if (tdoc.root.get("site")) |v| try SiteReader.sites(arena, v, &out);
    for (tdoc.root.entries.keys(), tdoc.root.entries.values()) |name, value| {
        if (std.mem.eql(u8, name, "site")) continue;
        const section = switch (value) {
            .table => |x| x,
            else => continue,
        };
        if (sections != null and !inNameList(sections, name)) continue;
        if (inNameList(skip, name)) continue;
        if (section.get("site")) |v| try SiteReader.sites(arena, v, &out);
    }
    return out.items;
}

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
/// True if `a` is an address that must not be reached from a crawl of the public web: unspecified, loopback,
/// private, link-local, shared (carrier-grade NAT), documentation, benchmarking, multicast or reserved; and the
/// IPv6 forms of those, including IPv4 addresses mapped into IPv6.
pub fn addressIsPrivate(a: std.Io.net.IpAddress) bool {
    switch (a) {
        .ip4 => |x| return ip4IsPrivate(x.bytes),
        .ip6 => |x| {
            const b = x.bytes;
            // ::ffff:a.b.c.d is the IPv4 address a.b.c.d.
            if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) return ip4IsPrivate(b[12..16].*);
            if (std.mem.allEqual(u8, b[0..15], 0) and (b[15] == 0 or b[15] == 1)) return true; // :: and ::1
            if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return true; // fe80::/10 link-local
            if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique local
            if (b[0] == 0xff) return true; // multicast
            if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return true; // documentation
            if (b[0] == 0x01 and b[1] == 0 and std.mem.allEqual(u8, b[2..8], 0)) return true; // discard-only 100::/64
            return false;
        },
    }
}

fn ip4IsPrivate(b: [4]u8) bool {
    return b[0] == 0 or b[0] == 10 or b[0] == 127 or b[0] >= 224 or
        (b[0] == 100 and b[1] >= 64 and b[1] <= 127) or
        (b[0] == 169 and b[1] == 254) or
        (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or
        (b[0] == 192 and b[1] == 168) or
        (b[0] == 192 and b[1] == 0 and b[2] == 0) or
        (b[0] == 192 and b[1] == 0 and b[2] == 2) or
        (b[0] == 198 and (b[1] == 18 or b[1] == 19)) or
        (b[0] == 198 and b[1] == 51 and b[2] == 100) or
        (b[0] == 203 and b[1] == 0 and b[2] == 113);
}

/// Resolves `host` and says whether any address it has is private (see `addressIsPrivate`). A name that does not
/// resolve is not private: the request will fail on its own. Names that look like addresses are judged by `isPrivateHost`.
pub fn resolvesToPrivate(io: Io, host: []const u8) bool {
    if (isPrivateHost(host)) return true;
    const hn = std.Io.net.HostName.init(host) catch return true;
    var buf: [32]std.Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buf);
    var name_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    var fut = io.async(std.Io.net.HostName.lookup, .{ hn, io, &queue, .{ .port = 443, .canonical_name_buffer = &name_buf } });
    defer fut.cancel(io) catch {};
    var private = false;
    while (true) {
        const r = queue.getOne(io) catch break; // closed: the lookup is finished (or failed)
        switch (r) {
            .address => |ad| if (addressIsPrivate(ad)) {
                private = true;
            },
            .canonical_name => {},
        }
    }
    return private;
}

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
    return ip4IsPrivate(b);
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
    /// Held while this origin is being asked, so only one worker talks to it at a time (and, from creation
    /// until its `robots.txt` is read, so nobody uses rules that are not there yet).
    lock: Io.Mutex = .init,
    /// True while a worker holds `lock` for a request, so others can look for other work instead of waiting.
    busy: std.atomic.Value(bool) = .init(false),
    /// Whether the name resolves to a private, loopback or link-local address; asked once, under `lock`.
    resolves_private: ?bool = null,
};

/// What the workers of one run share. `mutex` guards the host table, the visited set and the position
/// bookkeeping; the counters are atomic.
/// What a server said about a page that lets us ask "has it changed?" next time.
const Validator = struct { etag: ?[]const u8, last_modified: ?[]const u8 };
const max_validators = 2_000_000;
const max_validators_bytes = 512 * 1024 * 1024;

const Shared = struct {
    mutex: Io.Mutex = .init,
    /// The validators of the last run (read only while crawling) and the ones learned in this run (under `mutex`).
    old: std.StringHashMapUnmanaged(Validator) = .empty,
    fresh: std.StringHashMapUnmanaged(Validator) = .empty,
    /// Pages the server said had not changed (answered 304).
    not_modified: std.atomic.Value(u64) = .init(0),
    hosts: std.StringHashMapUnmanaged(*Host) = .empty,
    /// Every URL fetched or queued this run, so none is requested twice.
    visited: std.StringHashMapUnmanaged(void) = .empty,
    /// Page requests made (robots.txt excluded), against `max_pages`.
    fetched: std.atomic.Value(u64) = .init(0),
    exhausted: std.atomic.Value(bool) = .init(false),
    stored: std.atomic.Value(u64) = .init(0),
    network_failures: std.atomic.Value(u64) = .init(0),
    /// Set when a worker has to stop the whole run (cancelled, the pipeline refused, out of memory).
    stop: std.atomic.Value(bool) = .init(false),
    out_of_memory: std.atomic.Value(bool) = .init(false),
    /// The next seed to hand out.
    next_seed: std.atomic.Value(usize) = .init(0),
    /// Seeds from `first_seed` on: which are finished, how many in a row from the start, and the line of the
    /// last of those (the position to resume from: everything before it is done). Under `mutex`.
    first_seed: usize = 0,
    finished: []bool = &.{},
    prefix: usize = 0,
    last_done: ?[]const u8 = null,
    finished_since_checkpoint: u32 = 0,
    /// Pages stored since the work was last committed. Under `mutex`.
    unsaved: u32 = 0,
};

/// Serialises the pipeline's sink, which one thread at a time may use.
const LockedSink = struct {
    inner: api.Sink,
    io: Io,
    mutex: Io.Mutex = .init,

    fn sink(self: *LockedSink) api.Sink {
        return .{ .ptr = self, .vtable = &.{ .submit = submit, .checkpoint = checkpoint } };
    }

    fn submit(ptr: *anyopaque, d: doc.Document) api.Sink.Error!void {
        const self: *LockedSink = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.inner.submit(d);
    }

    fn checkpoint(ptr: *anyopaque, position: []const u8) api.Sink.Error!void {
        const self: *LockedSink = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.inner.checkpoint(position);
    }
};

const Run = struct {
    conn: *CrawlConnector,
    /// Lives for the whole run: host table and parsed robots rules.
    arena: Allocator,
    /// This worker's own HTTP client.
    client: *http.Client,
    /// The locked sink (shared by all workers).
    sink: api.Sink,
    control: *api.Control,
    sh: *Shared,
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

    /// True if the origin of `url` is known and a worker is asking it right now.
    fn hostBusy(self: *Run, url: []const u8) bool {
        const u = parseUrl(url) orelse return false;
        var buf: [300]u8 = undefined;
        const scheme: []const u8 = if (u.https) "https" else "http";
        const origin = (if (u.uri.port) |pt|
            std.fmt.bufPrint(&buf, "{s}://{s}:{d}", .{ scheme, u.host, pt })
        else
            std.fmt.bufPrint(&buf, "{s}://{s}", .{ scheme, u.host })) catch return false;
        for (origin) |*ch| ch.* = std.ascii.toLower(ch.*);
        const io = self.conn.io;
        self.sh.mutex.lockUncancelable(io);
        defer self.sh.mutex.unlock(io);
        const h = self.sh.hosts.get(origin) orelse return false;
        return h.busy.load(.monotonic);
    }

    /// The (cached) robots rules for the origin of `u`.
    /// `listed` is true for a page the administrator named (a seed or a sitemap
    /// entry): such a site is always allowed; `max_hosts` bounds only sites
    /// reached by following links and redirects.
    fn hostFor(self: *Run, u: Url, listed: bool) error{ OutOfMemory, Canceled, TooManyHosts }!*Host {
        const io = self.conn.io;
        const origin = try originOf(self.arena, u);
        self.sh.mutex.lockUncancelable(io);
        if (self.sh.hosts.get(origin)) |h| {
            self.sh.mutex.unlock(io);
            return h; // its rules are ready once its lock can be taken (see `Host.lock`)
        }
        if (!listed and self.sh.hosts.count() >= self.conn.max_hosts) {
            self.sh.mutex.unlock(io);
            return error.TooManyHosts;
        }
        const host = self.arena.create(Host) catch {
            self.sh.mutex.unlock(io);
            return error.OutOfMemory;
        };
        host.* = .{ .rules = .disallow_all };
        host.lock.lockUncancelable(io); // taken before anyone can find the host
        self.sh.hosts.put(self.arena, origin, host) catch {
            host.lock.unlock(io);
            self.sh.mutex.unlock(io);
            return error.OutOfMemory;
        };
        self.sh.mutex.unlock(io);
        defer host.lock.unlock(io);
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
            const via = self.conn.routeFor((parseUrl(url) orelse return .disallow_all).host) orelse return .disallow_all;
            const resp = fetch.get(self.client, a, .{
                .url = url,
                .user_agent = self.conn.user_agent,
                .accept = accept_robots,
                .max_body_bytes = robots.max_bytes,
                .via = via,
            }, self.timeout());
            host.last = Io.Timestamp.now(self.conn.io, .awake);
            const got = resp catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.Network, error.Timeout => {
                    _ = self.sh.network_failures.fetchAdd(1, .monotonic);
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
        /// The server answered 304 to a conditional request: the stored copy is still current.
        unchanged,
        skipped,
        stopped,
    };

    /// One polite GET of `start`: robots.txt, the host's turn, the request and
    /// same-site redirects. Everything is allocated in `a`.
    fn get(self: *Run, a: Allocator, start: []const u8, site_host: []const u8, accept: []const u8, max_bytes: usize, listed: bool, cond: ?Validator) error{OutOfMemory}!Fetched {
        var url = try withoutFragment(a, start);
        var hops: u32 = 0;
        const fetched_now = self.sh.fetched.fetchAdd(1, .monotonic) + 1;
        // The progress follows every page, not only the start of each breadth-first level (it lagged by a whole level).
        if (self.conn.max_depth != 0) self.control.setProgress(fetched_now, self.conn.max_pages);
        self.setCurrent(url);
        while (true) {
            const u = parseUrl(url) orelse return self.skip(.limit);
            // A banned site is not contacted at all (not even for its robots.txt), seed or link.
            if (domainlist.global) |l| if (l.blocked.matches(u.host)) return self.skip(.banned);
            const host = self.hostFor(u, listed and hops == 0) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return .stopped,
                error.TooManyHosts => return self.skip(.limit),
            };
            // One worker at a time asks a host: the lock is held through the wait for its turn and the request.
            host.lock.lockUncancelable(self.conn.io);
            host.busy.store(true, .monotonic);
            defer {
                host.busy.store(false, .monotonic);
                host.lock.unlock(self.conn.io);
            }
            // A name of a hidden network goes to the proxy by name, over http only, and is never resolved here; with no
            // proxy for it, it is not contacted at all.
            const via = self.conn.routeFor(u.host) orelse return self.skip(.limit);
            if (via != .direct and u.https) return self.skip(.limit);
            // A site the administrator did not list must not lead into the private network, whatever its name says:
            // every address the name resolves to is checked (once per host).
            if (via == .direct and !self.conn.allow_private and !sameSite(u.host, site_host)) {
                if (host.resolves_private == null) host.resolves_private = resolvesToPrivate(self.conn.io, u.host);
                if (host.resolves_private.?) return self.skip(.limit);
            }
            if (!host.rules.allowed(try targetOf(a, u))) return self.skip(.robots);
            if (!self.waitTurn(host)) return .stopped;

            const resp = fetch.get(self.client, a, .{
                .url = url,
                .user_agent = self.conn.user_agent,
                .accept = accept,
                .max_body_bytes = max_bytes,
                .via = via,
                // Only the first request of the chain: after a redirect the validators are for another address.
                .if_none_match = if (hops == 0) (if (cond) |c| c.etag else null) else null,
                .if_modified_since = if (hops == 0) (if (cond) |c| c.last_modified else null) else null,
            }, self.timeout());
            host.last = Io.Timestamp.now(self.conn.io, .awake);
            const got = resp catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return .stopped,
                error.Network, error.Timeout => {
                    _ = self.sh.network_failures.fetchAdd(1, .monotonic);
                    return self.skip(.network);
                },
                // A certificate that does not verify is a refusal, not an outage.
                error.Tls => return self.skip(.certificate),
                error.TooLarge => return self.skip(.too_large),
                else => return self.skip(.http_status),
            };

            if (got.status == 304 and cond != null and hops == 0) return .unchanged;
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
        // The hidden networks are entered only on request, and never left again from inside: a crawl that began on an
        // onion or I2P site does not wander onto the open internet.
        if (hidden.networkOf(host) != null) return self.conn.hidden_links and self.conn.routeFor(host) != null;
        if (hidden.networkOf(site) != null) return false;
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
        const io = self.conn.io;
        self.sh.mutex.lockUncancelable(io);
        defer self.sh.mutex.unlock(io);
        if (self.sh.visited.count() >= max_visited) return null;
        const gop = try self.sh.visited.getOrPut(self.arena, url);
        if (gop.found_existing) return null;
        gop.key_ptr.* = try self.arena.dupe(u8, url);
        return gop.key_ptr.*;
    }

    /// Expands the sitemap (or sitemap index) at `url` into page URLs on the
    /// sitemap's own site. Returns true if the run was stopped.
    fn sitemapPages(self: *Run, a: Allocator, url: []const u8, site: []const u8, level: u32, n_files: *u32, out: *std.ArrayList([]const u8)) error{OutOfMemory}!bool {
        if (n_files.* >= max_sitemap_files or self.sh.fetched.load(.monotonic) >= self.conn.max_pages) return false;
        n_files.* += 1;
        var tmp = std.heap.ArenaAllocator.init(self.conn.gpa);
        defer tmp.deinit();
        const t = tmp.allocator();
        const got = switch (try self.get(t, url, site, accept_sitemap, max_sitemap_bytes, level == 0, null)) {
            .stopped => return true,
            .skipped, .unchanged => return false,
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

    /// Fetches and stores one page of the crawl and appends the links worth following (to `out`).
    fn fetchOne(self: *Run, t: CrawlConnector.Task, out: *std.ArrayList(CrawlConnector.Task)) error{OutOfMemory}!Result {
        const gpa = self.conn.gpa;
        if (self.sh.fetched.load(.monotonic) >= self.conn.max_pages) {
            self.sh.exhausted.store(true, .monotonic);
            return .skipped;
        }
        var page = std.heap.ArenaAllocator.init(gpa);
        defer page.deinit();
        const a = page.allocator();
        // A page at the depth limit has no links to follow, so a server that says it has not changed lets us skip it.
        const leaf = t.depth >= self.conn.max_depth;
        const cond: ?Validator = if (leaf and self.conn.validators_file != null) self.sh.old.get(t.url) else null;
        const got = switch (try self.get(a, t.url, t.site, accept_pages, self.conn.max_page_bytes, t.root, cond)) {
            .stopped => return .stopped,
            .skipped => return .skipped,
            .unchanged => {
                _ = self.sh.not_modified.fetchAdd(1, .monotonic);
                return .skipped;
            },
            .page => |p| p,
        };
        // A redirect target counts as seen too.
        if (!std.mem.eql(u8, got.url, t.url)) _ = try self.firstVisit(got.url);

        const stored = try self.store(a, got.url, got.resp);
        switch (stored.result) {
            .stopped => return .stopped,
            .stored, .skipped => {},
        }
        if (leaf and self.conn.validators_file != null and (got.resp.etag != null or got.resp.last_modified != null)) try self.rememberValidators(t.url, got.resp);
        if (t.depth >= self.conn.max_depth) return stored.result;
        for (stored.links) |link| {
            if (out.items.len >= max_level_items) break;
            const target = (try resolveRedirect(a, got.url, link)) orelse continue;
            const tu = parseUrl(target) orelse continue;
            if (!self.mayVisit(t.site, tu.host) or looksBinary(tu.uri.path)) continue;
            const keep = (try self.firstVisit(target)) orelse continue;
            try out.append(gpa, .{ .url = keep, .depth = t.depth + 1, .seed = t.seed, .site = t.site });
        }
        return stored.result;
    }

    fn rememberValidators(self: *Run, url: []const u8, resp: fetch.Response) error{OutOfMemory}!void {
        const io = self.conn.io;
        self.sh.mutex.lockUncancelable(io);
        defer self.sh.mutex.unlock(io);
        if (self.sh.fresh.count() >= max_validators) return;
        const owned_url = try self.arena.dupe(u8, url);
        try self.sh.fresh.put(self.arena, owned_url, .{
            .etag = if (resp.etag) |e| try self.arena.dupe(u8, e) else null,
            .last_modified = if (resp.last_modified) |l| try self.arena.dupe(u8, l) else null,
        });
    }

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
        _ = self.sh.stored.fetchAdd(1, .monotonic);
        const io = self.conn.io;
        var save_at: ?[]const u8 = null;
        self.sh.mutex.lockUncancelable(io);
        self.sh.unsaved += 1;
        if (self.sh.unsaved >= save_every_pages) {
            self.sh.unsaved = 0;
            save_at = self.sh.last_done;
        }
        self.sh.mutex.unlock(io);
        // Restarting from the last finished address re-reads the unfinished ones: nothing is skipped.
        if (save_at) |safe_pos| self.sink.checkpoint(safe_pos) catch |e| switch (e) {
            error.Stopped => return .{ .result = .stopped },
            else => {}, // not fatal: the next page tries again
        };
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

test {
    _ = hidden;
}

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
    c.workers = 1; // the test servers answer one request at a time and the tests rely on the order
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

test "an onion seed is crawled through the Tor proxy by name; with no proxy configured it is not contacted" {
    var proxy: hidden.FakeProxy = undefined;
    try proxy.start(.tor, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 70\r\n\r\n<html><head><title>Hidden</title></head><body>Onion page</body></html>");
    defer proxy.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var conn = try testConnector(&tmp, "http://abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion/\n", "dksearch-test/1.0 (+https://example.org/bot)");
    defer conn.deinit();
    conn.max_depth = 0;
    // No proxy: nothing is contacted, and the seed is refused.
    {
        var got: Collect = .{};
        defer got.deinit();
        var ctl: api.Control = .{};
        _ = try conn.connector().run(got.sink(), &ctl, null);
        try testing.expectEqual(@as(usize, 0), got.ids.items.len);
        try testing.expectEqual(@as(u64, 1), ctl.rejected.load(.monotonic));
        try testing.expectEqual(@as(usize, 0), proxy.connections);
    }
    conn.tor = proxy.address();
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expectEqual(@as(usize, 1), got.ids.items.len);
    try testing.expectEqualStrings("Hidden", got.titles.items[0]);
    try testing.expectEqualStrings("Onion page", got.texts.items[0]);
    try testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion", proxy.asked_host[0..proxy.asked_len]);
    try testing.expect(proxy.connections >= 2); // robots.txt and the page
}

test "a site on the ban list (given as a hash) is not contacted at all, seed or not" {
    var proxy: hidden.FakeProxy = undefined;
    try proxy.start(.tor, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello");
    defer proxy.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var conn = try testConnector(&tmp, "http://abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion/\nhttp://www.abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion/page\n", "dksearch-test/1.0 (+https://example.org/bot)");
    defer conn.deinit();
    conn.max_depth = 0;
    conn.tor = proxy.address();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var lists: domainlist.Lists = .{};
    _ = try lists.blocked.addText(ar.allocator(), &hex);
    domainlist.global = &lists;
    defer domainlist.global = null;
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expectEqual(@as(usize, 0), got.ids.items.len);
    try testing.expectEqual(@as(usize, 0), proxy.connections); // not even robots.txt
    try testing.expectEqual(@as(u64, 2), ctl.reasonCounts()[@backingInt(api.Reason.banned)]);
}

test "a TOML seeds file gives its sections' sites; sections can be chosen and left out" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\[[site]]
        \\url = "https://top.example/"
        \\[computers]
        \\title = "Computers"
        \\[[computers.site]]
        \\url = "https://c1.example/"
        \\name = "one"
        \\[[computers.site]]
        \\url = "https://c2.example/map.xml"
        \\sitemap = true
        \\[Adult]
        \\[[Adult.site]]
        \\url = "https://adult.example/"
        \\[misc]
        \\[[misc.site]]
        \\url = "not a url"
        \\[[misc.site]]
        \\url = "http://m1.example/"
    ;
    const all = try tomlSeeds(a, text, null, null);
    try testing.expectEqual(@as(usize, 5), all.len); // the bad address is dropped
    const without_adult = try tomlSeeds(a, text, null, "adult, other");
    try testing.expectEqual(@as(usize, 4), without_adult.len);
    for (without_adult) |sd| try testing.expect(std.mem.indexOf(u8, sd.url, "adult.example") == null);
    const only = try tomlSeeds(a, text, "Computers", null);
    try testing.expectEqual(@as(usize, 3), only.len); // the section's two and the top-level [[site]]
    try testing.expect(only[2].sitemap);
    try testing.expectEqualStrings("https://c2.example/map.xml", only[2].url);
    try testing.expectError(error.InvalidToml, tomlSeeds(a, "[[site]\nurl =", null, null));
}

test "a crawl reads its seeds from a TOML file" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/a", .body = "<html><head><title>Seed A</title></head><body>from the toml file</body></html>" },
        .{ .path = "/b", .body = "<html><head><title>Seed B</title></head><body>skipped section</body></html>" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ub: [2][96]u8 = undefined;
    const toml_text = try std.fmt.allocPrint(testing.allocator, "[good]\n[[good.site]]\nurl = \"{s}\"\n[Adult]\n[[Adult.site]]\nurl = \"{s}\"\n", .{ srv.url(&ub[0], "/a"), srv.url(&ub[1], "/b") });
    defer testing.allocator.free(toml_text);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "links.toml", .data = toml_text });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, "links.toml", &pbuf);
    const opts = [_]config.Option{
        .{ .key = "user_agent", .value = .{ .string = "dksearch-test/1.0 (+https://example.org/bot)" } },
        .{ .key = "seeds_file", .value = .{ .string = pbuf[0..n] } },
        .{ .key = "seeds_skip", .value = .{ .string = "adult" } },
    };
    var conn = try CrawlConnector.init(testing.allocator, testing.io, .{ .name = "web", .kind = "crawl", .options = &opts });
    defer conn.deinit();
    conn.delay_ms = 0;
    conn.timeout_s = 5;
    conn.workers = 1;
    conn.max_depth = 0;
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expectEqual(@as(usize, 1), got.ids.items.len);
    try testing.expectEqualStrings("Seed A", got.titles.items[0]);
    try testing.expectEqual(@as(usize, 0), srv.count("/b")); // the left-out section is never requested
}

test "the proxy options are checked, and routing follows the network of the name" {
    var d: config.Diagnostic = .{};
    const base = [_]config.Option{
        .{ .key = "user_agent", .value = .{ .string = "mysearch/1.0 (+https://example.org/about)" } },
        .{ .key = "seeds_file", .value = .{ .string = "seeds.txt" } },
    };
    const good = base ++ [_]config.Option{ .{ .key = "tor_socks", .value = .{ .string = "127.0.0.1:9050" } }, .{ .key = "i2p_proxy", .value = .{ .string = "127.0.0.1:4444" } }, .{ .key = "hidden_links", .value = .{ .boolean = true } } };
    try validate(.{ .name = "c", .kind = "crawl", .options = &good }, &d);
    const bad = base ++ [_]config.Option{.{ .key = "tor_socks", .value = .{ .string = "tor.example:9050" } }};
    try testing.expectError(error.InvalidValue, validate(.{ .name = "c", .kind = "crawl", .options = &bad }, &d));
    try testing.expectEqualStrings("source[c].tor_socks", d.key());
    var c = try CrawlConnector.init(testing.allocator, testing.io, .{ .name = "c", .kind = "crawl", .options = &good });
    defer c.deinit();
    try testing.expect(c.routeFor("example.org").? == .direct);
    try testing.expect(c.routeFor("abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion").? == .tor);
    try testing.expect(c.routeFor("x.onion") == null); // not a version 3 address: never contacted
    try testing.expect(c.routeFor("expyuzz4wqqyqhjn.onion") == null);
    try testing.expect(c.routeFor("x.i2p").? == .i2p);
    c.i2p = null;
    try testing.expect(c.routeFor("x.i2p") == null);
}

test "addresses in private ranges are recognised in both IP versions, including IPv4 mapped into IPv6" {
    const Ip = std.Io.net.IpAddress;
    const private = [_][]const u8{ "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "198.18.0.1", "192.0.2.5", "203.0.113.9", "::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::ffff:192.168.0.1", "2001:db8::1" };
    for (private) |t| try testing.expect(addressIsPrivate(try Ip.parse(t, 80)));
    const public = [_][]const u8{ "8.8.8.8", "1.1.1.1", "93.184.216.34", "172.32.0.1", "172.15.0.1", "100.63.0.1", "100.128.0.1", "2606:4700:4700::1111", "2a00:1450:4001::1", "::ffff:8.8.8.8" };
    for (public) |t| try testing.expect(!addressIsPrivate(try Ip.parse(t, 80)));
    // A name that the system resolves to the loopback address is private whatever it is called.
    try testing.expect(resolvesToPrivate(testing.io, "localhost"));
}

test "pages at the depth limit are asked for conditionally on the next run, and a 304 is not stored again" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/a", .body = "<p>stable page</p>", .etag = "\"v1\"" },
        .{ .path = "/b", .body = "<p>no validator page</p>" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [2][96]u8 = undefined;
    const seeds = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}\n", .{ srv.url(&b[0], "/a"), srv.url(&b[1], "/b") });
    defer testing.allocator.free(seeds);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "seeds.txt", .data = seeds });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, "seeds.txt", &pbuf);
    const seeds_path = try testing.allocator.dupe(u8, pbuf[0..n]);
    defer testing.allocator.free(seeds_path);
    const vpath = try std.fmt.allocPrint(testing.allocator, "{s}.validators", .{seeds_path});
    defer testing.allocator.free(vpath);
    const opts = [_]config.Option{
        .{ .key = "user_agent", .value = .{ .string = "dksearch-test/1.0 (+https://example.org/bot)" } },
        .{ .key = "seeds_file", .value = .{ .string = seeds_path } },
        .{ .key = "validators_file", .value = .{ .string = vpath } },
    };
    var conn = try CrawlConnector.init(testing.allocator, testing.io, .{ .name = "web", .kind = "crawl", .options = &opts });
    defer conn.deinit();
    conn.delay_ms = 0;
    conn.timeout_s = 5;
    conn.workers = 1;
    conn.max_depth = 0; // the listed pages only: every one is at the limit

    var first: Collect = .{};
    defer first.deinit();
    var ctl1: api.Control = .{};
    _ = try conn.connector().run(first.sink(), &ctl1, null);
    try testing.expectEqual(@as(usize, 2), first.ids.items.len);
    try testing.expectEqual(@as(usize, 0), srv.conditional);
    const saved = try tmp.dir.readFileAlloc(testing.io, "seeds.txt.validators", testing.allocator, .limited(4096));
    defer testing.allocator.free(saved);
    try testing.expect(std.mem.indexOf(u8, saved, "/a\t\"v1\"\t") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "/b\t") == null); // nothing to ask with

    // Again: /a is asked conditionally and answered 304 (not submitted); /b has no validator and is fetched in full.
    var second: Collect = .{};
    defer second.deinit();
    var ctl2: api.Control = .{};
    _ = try conn.connector().run(second.sink(), &ctl2, null);
    try testing.expectEqual(@as(usize, 1), srv.conditional);
    try testing.expectEqual(@as(usize, 1), second.ids.items.len);
    try testing.expectEqualStrings("no validator page", second.texts.items[0]);
    // The validators survive a run that did not change them.
    const again = try tmp.dir.readFileAlloc(testing.io, "seeds.txt.validators", testing.allocator, .limited(4096));
    defer testing.allocator.free(again);
    try testing.expect(std.mem.indexOf(u8, again, "/a\t\"v1\"\t") != null);
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

test "seeds on different hosts are crawled at the same time, and the resume position stays valid" {
    // Four servers that each need 500 ms for their page: in a row that is two seconds, at once about half a second.
    var srvs: [4]TestServer = undefined;
    var started: usize = 0;
    defer for (srvs[0..started]) |*sv| sv.stop();
    var seeds: std.ArrayList(u8) = .empty;
    defer seeds.deinit(testing.allocator);
    var bufs: [4][96]u8 = undefined;
    for (&srvs, 0..) |*sv, i| {
        try sv.start(&.{
            .{ .path = "/robots.txt", .status = 404 },
            .{ .path = "/page", .body = "<p>page body</p>", .stall_ms = 500 },
        });
        started += 1;
        try seeds.print(testing.allocator, "{s}\n", .{sv.url(&bufs[i], "/page")});
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var conn = try testConnector(&tmp, seeds.items, "t/1");
    defer conn.deinit();
    conn.workers = 4;
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    const t0 = Io.Timestamp.now(testing.io, .awake);
    const out = try conn.connector().run(got.sink(), &ctl, null);
    const took_ms = @divTrunc(t0.durationTo(Io.Timestamp.now(testing.io, .awake)).nanoseconds, std.time.ns_per_ms);
    try testing.expect(!out.interrupted);
    try testing.expectEqual(@as(usize, 4), got.ids.items.len);
    try testing.expect(took_ms < 1400); // not the two seconds of a crawl one page at a time

    // A run stopped part-way reports the last seed before which every seed is finished, never one that is not.
    var got2: Collect = .{};
    defer got2.deinit();
    var ctl2: api.Control = .{};
    ctl2.cancel();
    const cut = try conn.connector().run(got2.sink(), &ctl2, null);
    try testing.expect(cut.interrupted);
    try testing.expect(cut.checkpoint == null);
}

test "a window is crawled breadth-first: every seed's first page before any seed's second" {
    var srv: TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/robots.txt", .status = 404 },
        .{ .path = "/a", .body = "<p>seed a</p><a href=\"/a1\">x</a>" },
        .{ .path = "/a1", .body = "<p>a one</p>" },
        .{ .path = "/b", .body = "<p>seed b</p><a href=\"/b1\">x</a>" },
        .{ .path = "/b1", .body = "<p>b one</p>" },
        .{ .path = "/c", .body = "<p>seed c</p>" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [3][96]u8 = undefined;
    var seeds: std.ArrayList(u8) = .empty;
    defer seeds.deinit(testing.allocator);
    for ([_][]const u8{ "/a", "/b", "/c" }, 0..) |p, i| try seeds.print(testing.allocator, "{s}\n", .{srv.url(&b[i], p)});
    var conn = try testConnector(&tmp, seeds.items, "t/1");
    defer conn.deinit();
    conn.max_depth = 1;
    var got: Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expectEqual(@as(usize, 5), got.texts.items.len);
    // The three seeds first, then what they link to: not seed a and its page before seed b.
    try testing.expect(std.mem.startsWith(u8, got.texts.items[0], "seed a"));
    try testing.expect(std.mem.startsWith(u8, got.texts.items[1], "seed b"));
    try testing.expect(std.mem.startsWith(u8, got.texts.items[2], "seed c"));
    try testing.expect(std.mem.startsWith(u8, got.texts.items[3], "a one"));
    try testing.expect(std.mem.startsWith(u8, got.texts.items[4], "b one"));
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
    conn.window = 1; // each seed is its own window, so the resume position moves after every seed

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
