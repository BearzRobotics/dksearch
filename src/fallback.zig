//! Other search engines as a fallback (docs/decisions/0041): off by default, opt-in, labelled as external.
//!
//! Two independent things, both under `[fallback]`:
//!
//!  * **Link-out buttons.** Known engines (DuckDuckGo, Brave, Google, Bing, ...) and the operator's own, as links
//!    that open the engine with the visitor's words. This server sends nothing anywhere; the visitor's browser goes
//!    to the engine only if they click.
//!  * **Providers** that this server asks for web results itself (Brave Search API, a SearXNG instance, Marginalia),
//!    so they can be shown below the local results. The visitor's words then leave this server for that service, which
//!    is why it is separate, off unless configured, rate limited, and the page says where results came from.
//!
//! Everything a provider sends is untrusted: sizes are bounded, only http and https links are kept, and the page
//! escapes it all. External results are never mixed into the ranking.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const have_http = build_options.crawler;
const fetch = if (have_http) @import("connectors/crawl/fetch.zig") else struct {};
const cabundle = if (have_http) @import("connectors/crawl/cabundle.zig") else struct {};

/// A link-out: `url` holds one `%s`, replaced by the percent-encoded words.
pub const Engine = struct { name: []const u8, label: []const u8, url: []const u8 };

pub const builtin_engines = [_]Engine{
    .{ .name = "duckduckgo", .label = "DuckDuckGo", .url = "https://duckduckgo.com/?q=%s" },
    .{ .name = "brave", .label = "Brave Search", .url = "https://search.brave.com/search?q=%s" },
    .{ .name = "google", .label = "Google", .url = "https://www.google.com/search?q=%s" },
    .{ .name = "bing", .label = "Bing", .url = "https://www.bing.com/search?q=%s" },
    .{ .name = "startpage", .label = "Startpage", .url = "https://www.startpage.com/do/search?q=%s" },
    .{ .name = "ecosia", .label = "Ecosia", .url = "https://www.ecosia.org/search?q=%s" },
    .{ .name = "qwant", .label = "Qwant", .url = "https://www.qwant.com/?q=%s" },
    .{ .name = "mojeek", .label = "Mojeek", .url = "https://www.mojeek.com/search?q=%s" },
    .{ .name = "marginalia", .label = "Marginalia", .url = "https://search.marginalia.nu/search?query=%s" },
    .{ .name = "kagi", .label = "Kagi", .url = "https://kagi.com/search?q=%s" },
    .{ .name = "yandex", .label = "Yandex", .url = "https://yandex.com/search/?text=%s" },
    .{ .name = "wikipedia", .label = "Wikipedia", .url = "https://en.wikipedia.org/w/index.php?search=%s" },
    .{ .name = "archive", .label = "Internet Archive", .url = "https://archive.org/search?query=%s" },
    .{ .name = "github", .label = "GitHub", .url = "https://github.com/search?q=%s" },
    .{ .name = "stackoverflow", .label = "Stack Overflow", .url = "https://stackoverflow.com/search?q=%s" },
};

pub fn builtin(name: []const u8) ?Engine {
    for (builtin_engines) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

/// True if `template` is an http(s) address with exactly one `%s` and no characters that break out of an attribute.
pub fn validTemplate(template: []const u8) bool {
    if (!(std.mem.startsWith(u8, template, "https://") or std.mem.startsWith(u8, template, "http://"))) return false;
    if (std.mem.indexOfAny(u8, template, " \"'<>\\\t\r\n") != null) return false;
    const first = std.mem.indexOf(u8, template, "%s") orelse return false;
    return std.mem.indexOfPos(u8, template, first + 2, "%s") == null;
}

/// The link for `words`: the template with `%s` replaced by the percent-encoded words.
pub fn linkFor(arena: Allocator, template: []const u8, words: []const u8) Allocator.Error![]const u8 {
    const at = std.mem.indexOf(u8, template, "%s") orelse return arena.dupe(u8, template);
    var out: Io.Writer.Allocating = .init(arena);
    out.writer.writeAll(template[0..at]) catch return error.OutOfMemory;
    for (words) |b| switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => out.writer.writeByte(b) catch return error.OutOfMemory,
        ' ' => out.writer.writeByte('+') catch return error.OutOfMemory,
        else => out.writer.print("%{X:0>2}", .{b}) catch return error.OutOfMemory,
    };
    out.writer.writeAll(template[at + 2 ..]) catch return error.OutOfMemory;
    return out.written();
}

// ------------------------------------------------------------------------------------------------ providers

pub const ProviderKind = enum { brave, searxng, marginalia };

pub const Provider = struct {
    name: []const u8,
    kind: ProviderKind,
    /// A base address; the default for the kind when null (SearXNG has none: it must be given).
    url: ?[]const u8 = null,
    key: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    timeout_ms: u32 = 4000,
    count: u32 = 5,
};

pub const External = struct { provider: []const u8, title: []const u8, url: []const u8, snippet: ?[]const u8 };

pub const Status = enum { ok, unavailable, failed, limited };

pub const Reply = struct {
    provider: []const u8,
    status: Status,
    results: []const External = &.{},
};

/// What the HTTP layer needs: the link-outs to show, when to show them, and the providers (if any).
pub const Settings = struct {
    engines: []const Engine,
    /// Shown when the local search found fewer results than this (0: always).
    min_results: u32 = 3,
    /// Ask the providers by itself when local results are few (otherwise only when the visitor asks: `web=1`).
    auto: bool = false,
    service: ?*Service = null,

    pub fn wanted(self: *const Settings, local_results: usize) bool {
        return self.min_results == 0 or local_results < self.min_results;
    }
};

const max_title = 300;
const max_snippet = 600;
const max_url = 1000;
const max_body = 2 * 1024 * 1024;

pub const Service = struct {
    gpa: Allocator,
    io: Io,
    providers: []const Provider,
    /// Keys read from their files at start, by provider index (null: none).
    keys: []?[]const u8,
    max_per_minute: u32,
    mutex: Io.Mutex = .init,
    window: i64 = 0,
    used: u32 = 0,
    client: if (have_http) std.http.Client else void,

    pub fn init(gpa: Allocator, io: Io, providers: []const Provider, max_per_minute: u32) !*Service {
        const self = try gpa.create(Service);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .providers = providers, .keys = try gpa.alloc(?[]const u8, providers.len), .max_per_minute = max_per_minute, .client = undefined };
        errdefer gpa.free(self.keys);
        for (providers, self.keys) |p, *k| {
            k.* = null;
            if (p.key) |v| k.* = try gpa.dupe(u8, v);
            if (p.key_file) |path| {
                if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096))) |text| {
                    defer gpa.free(text);
                    k.* = try gpa.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
                } else |_| {}
            }
        }
        if (have_http) {
            self.client = .{ .allocator = gpa, .io = io };
            self.client.now = Io.Clock.real.now(io);
            cabundle.load(&self.client.ca_bundle, gpa, io, .builtin) catch {};
        }
        return self;
    }

    pub fn deinit(self: *Service) void {
        for (self.keys) |k| if (k) |v| self.gpa.free(v);
        self.gpa.free(self.keys);
        if (have_http) self.client.deinit();
        self.gpa.destroy(self);
    }

    /// Counts one request against the per-minute limit of all callers together.
    fn allow(self: *Service) bool {
        const now_s = Io.Clock.real.now(self.io).toSeconds();
        const window = @divFloor(now_s, 60);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (window != self.window) {
            self.window = window;
            self.used = 0;
        }
        if (self.used >= self.max_per_minute) return false;
        self.used += 1;
        return true;
    }

    /// Asks every provider for web results for `words`, one after the other (each within its time limit).
    pub fn ask(self: *Service, arena: Allocator, words: []const u8) Allocator.Error![]Reply {
        const out = try arena.alloc(Reply, self.providers.len);
        for (self.providers, self.keys, out) |p, key, *o| {
            o.* = .{ .provider = p.name, .status = .failed };
            if (!have_http) {
                o.status = .unavailable;
                continue;
            }
            if (!self.allow()) {
                o.status = .limited;
                continue;
            }
            const resp = self.askOne(arena, p, key, words) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            o.* = .{ .provider = p.name, .status = .ok, .results = resp };
        }
        return out;
    }

    const AskError = error{ OutOfMemory, Failed };

    fn askOne(self: *Service, a: Allocator, p: Provider, key: ?[]const u8, words: []const u8) AskError![]const External {
        var enc: Io.Writer.Allocating = .init(a);
        for (words) |b| switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => enc.writer.writeByte(b) catch return error.OutOfMemory,
            else => enc.writer.print("%{X:0>2}", .{b}) catch return error.OutOfMemory,
        };
        const q = enc.written();
        var hdrs: [2]std.http.Header = undefined;
        var n: usize = 0;
        const url: []const u8 = switch (p.kind) {
            .brave => blk: {
                const k = key orelse return error.Failed;
                hdrs[n] = .{ .name = "x-subscription-token", .value = k };
                n += 1;
                break :blk try std.fmt.allocPrint(a, "{s}/res/v1/web/search?q={s}&count={d}", .{ std.mem.trimEnd(u8, p.url orelse "https://api.search.brave.com", "/"), q, p.count });
            },
            .searxng => try std.fmt.allocPrint(a, "{s}/search?q={s}&format=json", .{ std.mem.trimEnd(u8, p.url orelse return error.Failed, "/"), q }),
            .marginalia => try std.fmt.allocPrint(a, "{s}/{s}/search/{s}?count={d}", .{ std.mem.trimEnd(u8, p.url orelse "https://api.marginalia.nu", "/"), key orelse "public", q, p.count }),
        };
        const resp = fetch.get(&self.client, a, .{
            .url = url,
            .user_agent = "dksearch-fallback/0.1",
            .accept = "application/json",
            .max_body_bytes = max_body,
            .extra_headers = hdrs[0..n],
        }, .{ .nanoseconds = @as(i96, p.timeout_ms) * std.time.ns_per_ms }) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Failed;
        if (resp.status != 200) return error.Failed;
        return parseResults(a, resp.body, p) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Failed;
    }
};

fn jsonText(a: Allocator, v: ?std.json.Value, max: usize) Allocator.Error!?[]const u8 {
    const s = switch (v orelse return null) {
        .string => |x| x,
        else => return null,
    };
    var end = @min(s.len, max);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    const t = std.mem.trim(u8, s[0..end], " \t\r\n");
    if (t.len == 0) return null;
    return try a.dupe(u8, t);
}

/// The results of a provider's answer: at most `count`, each with an http(s) address, bounded text, nothing else.
pub fn parseResults(a: Allocator, body: []const u8, p: Provider) error{ OutOfMemory, BadAnswer }![]const External {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.BadAnswer;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.BadAnswer,
    };
    const list: std.json.Array = switch (p.kind) {
        .brave => switch (obj.get("web") orelse return error.BadAnswer) {
            .object => |w| switch (w.get("results") orelse return error.BadAnswer) {
                .array => |x| x,
                else => return error.BadAnswer,
            },
            else => return error.BadAnswer,
        },
        .searxng, .marginalia => switch (obj.get("results") orelse return error.BadAnswer) {
            .array => |x| x,
            else => return error.BadAnswer,
        },
    };
    var out: std.ArrayList(External) = .empty;
    for (list.items) |item| {
        if (out.items.len >= p.count) break;
        const o = switch (item) {
            .object => |x| x,
            else => continue,
        };
        const url = (try jsonText(a, o.get("url"), max_url)) orelse continue;
        if (!(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))) continue;
        const snippet_key: []const u8 = switch (p.kind) {
            .brave, .marginalia => "description",
            .searxng => "content",
        };
        try out.append(a, .{
            .provider = p.name,
            .title = (try jsonText(a, o.get("title"), max_title)) orelse url,
            .url = url,
            .snippet = try jsonText(a, o.get(snippet_key), max_snippet),
        });
    }
    return out.items;
}

const testing = std.testing;
const nettest = if (have_http) @import("connectors/nettest.zig") else struct {};

test "links are built from templates, templates are checked, and the known engines are all valid" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("https://duckduckgo.com/?q=odin+%26+ravens%3F+caf%C3%A9", try linkFor(a, "https://duckduckgo.com/?q=%s", "odin & ravens? café"));
    for (builtin_engines) |e| try testing.expect(validTemplate(e.url));
    try testing.expect(builtin("brave") != null and builtin("nosuch") == null);
    for ([_][]const u8{ "ftp://x/?q=%s", "https://x/?q=", "https://x/?q=%s&r=%s", "https://x/\"?q=%s", "javascript:%s", "https://x/ ?q=%s" }) |bad| try testing.expect(!validTemplate(bad));
}

test "answers of the three kinds are read; links that are not http(s), missing fields and extras are dropped" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const brave: Provider = .{ .name = "brave", .kind = .brave, .count = 2 };
    const got = try parseResults(a, "{\"web\":{\"results\":[{\"title\":\"Odin\",\"url\":\"https://e.org/odin\",\"description\":\"A <b>god</b>\"},{\"title\":\"x\",\"url\":\"javascript:alert(1)\"},{\"url\":\"http://e.org/two\"},{\"title\":\"third\",\"url\":\"https://e.org/3\"}]}}", brave);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("A <b>god</b>", got[0].snippet.?); // text; the page escapes it
    try testing.expectEqualStrings("http://e.org/two", got[1].title); // no title: the address
    const sx = try parseResults(a, "{\"results\":[{\"title\":\"T\",\"url\":\"https://s.org\",\"content\":\"body\"}]}", .{ .name = "s", .kind = .searxng });
    try testing.expectEqualStrings("body", sx[0].snippet.?);
    const mg = try parseResults(a, "{\"results\":[{\"url\":\"https://m.org\",\"title\":\"M\",\"description\":\"d\"}]}", .{ .name = "m", .kind = .marginalia });
    try testing.expectEqualStrings("d", mg[0].snippet.?);
    for ([_][]const u8{ "", "[]", "{}", "{\"web\":5}", "{\"results\":{}}" }) |bad| try testing.expectError(error.BadAnswer, parseResults(a, bad, brave));
}

test "providers are asked within the rate limit, a failing one does not stop the others" {
    if (!have_http) return error.SkipZigTest;
    var srv: nettest.TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/search?q=odin%20ravens&format=json", .content_type = "application/json", .body = "{\"results\":[{\"title\":\"T\",\"url\":\"https://s.org/a\",\"content\":\"c\"}]}" },
        .{ .path = "/public/search/odin%20ravens?count=3", .status = 500, .content_type = "application/json", .body = "{}" },
    });
    defer srv.stop();
    var ub: [64]u8 = undefined;
    const base = srv.url(&ub, "");
    const providers = [_]Provider{
        .{ .name = "mine", .kind = .searxng, .url = base },
        .{ .name = "broken", .kind = .marginalia, .url = base, .count = 3 },
    };
    const svc = try Service.init(testing.allocator, testing.io, &providers, 3);
    defer svc.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try svc.ask(a, "odin ravens");
    try testing.expectEqual(Status.ok, r[0].status);
    try testing.expectEqualStrings("https://s.org/a", r[0].results[0].url);
    try testing.expectEqual(Status.failed, r[1].status);
    // One more question uses the third request of the minute; the next ones are refused, nothing is sent.
    _ = try svc.ask(a, "odin ravens");
    const limited = try svc.ask(a, "odin ravens");
    try testing.expectEqual(Status.limited, limited[0].status);
    try testing.expectEqual(@as(usize, 2), srv.count("/search?q=odin%20ravens&format=json"));
}
