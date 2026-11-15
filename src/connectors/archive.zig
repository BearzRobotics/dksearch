//! The `archive` connector: indexes the metadata of Internet Archive items
//! (title, creator, description, subjects, dates, license fields) for items
//! matching a search query. It does not download the items themselves.
//!
//! It uses the Archive's documented "scrape" search API, which pages through
//! any number of results with a cursor, so a run can resume where it stopped
//! (docs/decisions/0019). Like the crawler it is opt-in, needs a configured
//! user agent, waits `delay_ms` between requests, caps the response size and
//! gives every request a deadline, and verifies HTTPS against the bundled
//! certificates.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");
const files = @import("files.zig");
const htmltext = @import("../htmltext.zig");
const crawl = @import("crawl.zig");
const fetch = @import("crawl/fetch.zig");
const cabundle = @import("crawl/cabundle.zig");
const dates = @import("feeds/dates.zig");

pub const kind = "archive";
pub const default_base_url = "https://archive.org";
/// The API documents a minimum page size of 100, but when this connector was
/// tried against the live service (2026-11-15) pages of 200 or fewer ignored
/// the query and repeated the first page for every cursor, while 1000 or more
/// paged correctly. So the smallest page this connector asks for is 1000;
/// `max_items` still limits how many items of a page are indexed.
pub const min_count: u32 = 1000;
pub const default_count: u32 = 1000;
pub const hard_max_count: u32 = 10_000;
pub const default_max_items: u32 = 10_000;
pub const hard_max_items: u32 = 100_000_000;
const max_response_bytes = 64 * 1024 * 1024;
const max_text_bytes = 256 * 1024;
const fields = "identifier,title,creator,description,subject,date,publicdate,language,licenseurl,rights,mediatype";

const allowed_options = [_][]const u8{ "query", "user_agent", "base_url", "count", "max_items", "delay_ms", "timeout_seconds", "ca_bundle", "language" };

pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    for (source.options) |o| {
        var known = false;
        for (allowed_options) |k| {
            if (std.mem.eql(u8, k, o.key)) known = true;
        }
        if (!known) {
            diag.set("", crawl.key(&kbuf, source, o.key), "unknown option for kind \"archive\"", .{});
            return error.UnknownKey;
        }
    }
    _ = (try crawl.needString(source, "query", true, diag)).?;
    const ua = (try crawl.needString(source, "user_agent", true, diag)).?;
    if (!crawl.validUserAgent(ua)) {
        diag.set("", crawl.key(&kbuf, source, "user_agent"), "must be 1-200 printable ASCII characters starting with a product name, e.g. \"mysearch/1.0 (+https://example.org/about)\"", .{});
        return error.InvalidValue;
    }
    if (try crawl.needString(source, "base_url", false, diag)) |u| {
        const ok = (std.mem.startsWith(u8, u, "https://") or std.mem.startsWith(u8, u, "http://")) and !std.mem.endsWith(u8, u, "/") and std.mem.indexOfAny(u8, u, " \t\r\n?#") == null;
        if (!ok) {
            diag.set("", crawl.key(&kbuf, source, "base_url"), "must start with http:// or https://, have no trailing slash, query or fragment", .{});
            return error.InvalidValue;
        }
    }
    try crawl.intOption(source, "count", min_count, hard_max_count, diag);
    try crawl.intOption(source, "max_items", 1, hard_max_items, diag);
    try crawl.intOption(source, "delay_ms", crawl.min_delay_ms, crawl.max_delay_ms, diag);
    try crawl.intOption(source, "timeout_seconds", 1, crawl.max_timeout_s, diag);
    _ = try crawl.needString(source, "ca_bundle", false, diag);
    if (try crawl.needString(source, "language", false, diag)) |l| if (!files.validLanguageTag(l)) {
        diag.set("", crawl.key(&kbuf, source, "language"), "must be a language tag such as \"en\"", .{});
        return error.InvalidValue;
    };
}

pub const ArchiveConnector = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    query: []const u8,
    user_agent: []const u8,
    base_url: []const u8,
    count: u32,
    max_items: u32,
    delay_ms: u32,
    timeout_s: u32,
    ca: cabundle.Choice,
    language: ?[]const u8,
    checkpoint_buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!ArchiveConnector {
        const name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(name);
        const query = try gpa.dupe(u8, source.optionString("query").?);
        errdefer gpa.free(query);
        const user_agent = try gpa.dupe(u8, source.optionString("user_agent").?);
        errdefer gpa.free(user_agent);
        const base_url = try gpa.dupe(u8, source.optionString("base_url") orelse default_base_url);
        errdefer gpa.free(base_url);
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
            .query = query,
            .user_agent = user_agent,
            .base_url = base_url,
            .count = @intCast(source.optionInt("count") orelse default_count),
            .max_items = @intCast(source.optionInt("max_items") orelse default_max_items),
            .delay_ms = @intCast(source.optionInt("delay_ms") orelse crawl.default_delay_ms),
            .timeout_s = @intCast(source.optionInt("timeout_seconds") orelse crawl.default_timeout_s),
            .ca = ca,
            .language = language,
        };
    }

    pub fn deinit(self: *ArchiveConnector) void {
        self.gpa.free(self.name);
        self.gpa.free(self.query);
        self.gpa.free(self.user_agent);
        self.gpa.free(self.base_url);
        switch (self.ca) {
            .file => |p| self.gpa.free(p),
            else => {},
        }
        if (self.language) |l| self.gpa.free(l);
        self.checkpoint_buf.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn connector(self: *ArchiveConnector) api.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run } };
    }

    fn info(_: *anyopaque) api.Info {
        return .{ .kind = kind, .requires_network = true, .resumable = true };
    }

    fn run(ptr: *anyopaque, sink: api.Sink, control: *api.Control, resume_from: ?[]const u8) api.RunError!api.Outcome {
        const self: *ArchiveConnector = @ptrCast(@alignCast(ptr));
        var client: http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();
        cabundle.load(&client.ca_bundle, self.gpa, self.io, self.ca) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSource,
        };
        client.now = Io.Clock.real.now(self.io);

        var cursor_buf: std.ArrayList(u8) = .empty;
        defer cursor_buf.deinit(self.gpa);
        if (resume_from) |r| try cursor_buf.appendSlice(self.gpa, r);

        var seen: u64 = 0;
        var first = true;
        while (seen < self.max_items) {
            if (control.isCancelled()) return self.stopped(cursor_buf.items);
            if (!first and !self.pause(control)) return self.stopped(cursor_buf.items);

            var page = std.heap.ArenaAllocator.init(self.gpa);
            defer page.deinit();
            const a = page.allocator();
            const url = try self.pageUrl(a, self.count, cursor_buf.items);
            const got = fetch.get(&client, a, .{
                .url = url,
                .user_agent = self.user_agent,
                .accept = "application/json",
                .max_body_bytes = max_response_bytes,
            }, .fromSeconds(self.timeout_s)) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return self.stopped(cursor_buf.items),
                // Nothing at all fetched yet and the network is down: say so.
                error.Network, error.Timeout => return if (first and resume_from == null) error.Offline else error.SourceFailed,
                else => return error.SourceFailed,
            };
            first = false;
            if (got.status < 200 or got.status >= 300) return error.SourceFailed; // includes 429: try later

            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, got.body, .{}) catch return error.SourceFailed;
            const root = switch (parsed) {
                .object => |o| o,
                else => return error.SourceFailed,
            };
            const items = switch (root.get("items") orelse return error.SourceFailed) {
                .array => |arr| arr.items,
                else => return error.SourceFailed,
            };
            for (items) |item| {
                if (seen >= self.max_items) break;
                seen += 1;
                switch (try self.submitItem(a, item, sink, control)) {
                    .stopped => return self.stopped(cursor_buf.items),
                    .ok => {},
                }
            }

            // The cursor to continue from; absent on the last page.
            const next: ?[]const u8 = if (root.get("cursor")) |c| switch (c) {
                .string => |s| if (s.len > 0) s else null,
                else => null,
            } else null;
            const cur = next orelse break;
            if (items.len == 0) break;
            cursor_buf.clearRetainingCapacity();
            try cursor_buf.appendSlice(self.gpa, cur);
            sink.checkpoint(cur) catch |e| switch (e) {
                error.Stopped => return self.stopped(cursor_buf.items),
                else => return error.SourceFailed,
            };
        }
        return .{};
    }

    fn stopped(self: *ArchiveConnector, cursor: []const u8) api.Outcome {
        if (cursor.len == 0) return .{ .interrupted = true };
        self.checkpoint_buf.clearRetainingCapacity();
        self.checkpoint_buf.appendSlice(self.gpa, cursor) catch return .{ .interrupted = true };
        return .{ .interrupted = true, .checkpoint = self.checkpoint_buf.items };
    }

    /// Waits `delay_ms`, in short steps so cancellation is noticed.
    fn pause(self: *ArchiveConnector, control: *api.Control) bool {
        var left: i64 = self.delay_ms;
        while (left > 0) {
            if (control.isCancelled()) return false;
            const step = @min(left, 200);
            self.io.sleep(.fromMilliseconds(step), .awake) catch return false;
            left -= step;
        }
        return !control.isCancelled();
    }

    fn pageUrl(self: *ArchiveConnector, a: Allocator, count: u32, cursor: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "{s}/services/search/v1/scrape?fields={s}&count={d}&q=", .{ self.base_url, fields, count });
        try percentEncode(a, &out, self.query);
        if (cursor.len > 0) {
            try out.appendSlice(a, "&cursor=");
            try percentEncode(a, &out, cursor);
        }
        return out.items;
    }

    const Submitted = enum { ok, stopped };

    fn submitItem(self: *ArchiveConnector, a: Allocator, item: std.json.Value, sink: api.Sink, control: *api.Control) error{OutOfMemory}!Submitted {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                control.reject(.limit);
                return .ok;
            },
        };
        const identifier = oneString(a, obj.get("identifier")) catch return error.OutOfMemory;
        const id = identifier orelse {
            control.reject(.limit);
            return .ok;
        };
        if (id.len == 0 or id.len > 256 or std.mem.indexOfAny(u8, id, "/?#\\ \t\r\n") != null) {
            control.reject(.limit);
            return .ok;
        }
        const title = try oneLine(a, obj.get("title"));
        const creator = try joined(a, obj.get("creator"), "; ");
        const description_raw = try joined(a, obj.get("description"), "\n");
        const description = if (description_raw.len > 0) try htmltext.toText(a, description_raw) else "";
        const subjects = try joined(a, obj.get("subject"), "; ");

        var text: std.ArrayList(u8) = .empty;
        if (title.len > 0) try text.print(a, "{s}\n", .{title});
        if (creator.len > 0) try text.print(a, "By {s}\n", .{creator});
        if (description.len > 0) try text.print(a, "{s}\n", .{description});
        if (subjects.len > 0) try text.print(a, "Subjects: {s}\n", .{subjects});
        if (text.items.len > max_text_bytes) text.items.len = utf8Cut(text.items, max_text_bytes);
        const body = std.mem.trim(u8, text.items, " \t\r\n");
        if (body.len == 0) {
            control.reject(.no_text);
            return .ok;
        }

        const url = try std.fmt.allocPrint(a, "{s}/details/{s}", .{ self.base_url, id });
        const license_url = try oneLine(a, obj.get("licenseurl"));
        const rights_text = try oneLine(a, obj.get("rights"));
        const media = try oneLine(a, obj.get("mediatype"));
        const language: ?[]const u8 = self.language;

        var extra: std.ArrayList(doc.Extra) = .empty;
        if (media.len > 0) try extra.append(a, .{ .key = "mediatype", .value = media });
        if (subjects.len > 0) try extra.append(a, .{ .key = "subjects", .value = subjects });
        const lang_raw = try joined(a, obj.get("language"), "; ");
        if (lang_raw.len > 0) try extra.append(a, .{ .key = "archive_language", .value = lang_raw });

        const d: doc.Document = .{
            .connector = self.name,
            .source_id = id,
            .source_dataset = "Internet Archive",
            .canonical_url = url,
            .title = if (title.len > 0) title else null,
            .text = body,
            .language = language,
            .content_type = "text/plain",
            .author = if (creator.len > 0) creator else null,
            .published_at = parseDate(try oneLine(a, obj.get("date"))),
            .modified_at = parseDate(try oneLine(a, obj.get("publicdate"))),
            .rights = .{
                .license_url = if (license_url.len > 0 and std.mem.startsWith(u8, license_url, "http")) license_url else null,
                .attribution = try std.fmt.allocPrint(a, "Metadata of the Internet Archive item {s}", .{id}),
                .access_notes = if (rights_text.len > 0)
                    try std.fmt.allocPrint(a, "Item rights statement: {s}. The metadata only is indexed; the item itself has its own terms.", .{rights_text})
                else
                    "Only the item's metadata is indexed; the item itself has its own terms.",
                .redistribution = .unknown,
            },
            .extra = extra.items,
        };
        sink.submit(d) catch |e| switch (e) {
            error.Rejected => return .ok, // the pipeline counts it
            error.Stopped => return .stopped,
            error.OutOfMemory => return error.OutOfMemory,
        };
        _ = control.submitted.fetchAdd(1, .monotonic);
        return .ok;
    }
};

fn parseDate(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    if (dates.parse(text)) |t| return t;
    // A bare year: 1999.
    if (text.len == 4) {
        var buf: [20]u8 = undefined;
        const iso = std.fmt.bufPrint(&buf, "{s}-01-01T00:00:00Z", .{text}) catch return null;
        return dates.parseIso(iso);
    }
    return null;
}

/// The longest prefix of `s` that is at most `max` bytes and ends on a
/// UTF-8 boundary.
fn utf8Cut(s: []const u8, max: usize) usize {
    var n = @min(s.len, max);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// A JSON value that is a string, or the first string of an array; trimmed.
fn oneString(a: Allocator, v: ?std.json.Value) Allocator.Error!?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| try a.dupe(u8, std.mem.trim(u8, s, " \t\r\n")),
        .array => |arr| for (arr.items) |x| {
            if (x == .string) break try a.dupe(u8, std.mem.trim(u8, x.string, " \t\r\n"));
        } else null,
        else => null,
    };
}

/// `oneString` with line breaks and runs of spaces folded to single spaces.
fn oneLine(a: Allocator, v: ?std.json.Value) Allocator.Error![]const u8 {
    const s = (try oneString(a, v)) orelse return "";
    var out: std.ArrayList(u8) = .empty;
    var pending = false;
    for (s) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') {
            pending = out.items.len > 0;
            continue;
        }
        if (pending) try out.append(a, ' ');
        pending = false;
        try out.append(a, ch);
    }
    return out.items;
}

/// All strings of a string-or-array value, joined with `sep`.
fn joined(a: Allocator, v: ?std.json.Value, sep: []const u8) Allocator.Error![]const u8 {
    const val = v orelse return "";
    switch (val) {
        .string => |s| return try a.dupe(u8, std.mem.trim(u8, s, " \t\r\n")),
        .array => |arr| {
            var out: std.ArrayList(u8) = .empty;
            for (arr.items) |x| {
                if (x != .string) continue;
                const t = std.mem.trim(u8, x.string, " \t\r\n");
                if (t.len == 0) continue;
                if (out.items.len > 0) try out.appendSlice(a, sep);
                try out.appendSlice(a, t);
                if (out.items.len > max_text_bytes) break;
            }
            return out.items;
        },
        else => return "",
    }
}

fn percentEncode(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~') {
            try out.append(a, ch);
        } else {
            try out.append(a, '%');
            try out.append(a, hex[ch >> 4]);
            try out.append(a, hex[ch & 15]);
        }
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const nettest = @import("nettest.zig");

test "validate: query and user agent are required; base_url is checked" {
    var d: config.Diagnostic = .{};
    const ok = [_]config.Option{
        .{ .key = "query", .value = .{ .string = "collection:gutenberg" } },
        .{ .key = "user_agent", .value = .{ .string = "mysearch/1.0 (+https://example.org/about)" } },
    };
    try validate(.{ .name = "ia", .kind = "archive", .options = &ok }, &d);
    try testing.expectError(error.InvalidValue, validate(.{ .name = "ia", .kind = "archive", .options = ok[1..] }, &d));
    try testing.expectEqualStrings("source[ia].query", d.key());
    try testing.expectError(error.InvalidValue, validate(.{ .name = "ia", .kind = "archive", .options = ok[0..1] }, &d));
    try testing.expectEqualStrings("source[ia].user_agent", d.key());
    const bad = ok ++ [_]config.Option{.{ .key = "base_url", .value = .{ .string = "ftp://x" } }};
    try testing.expectError(error.InvalidValue, validate(.{ .name = "ia", .kind = "archive", .options = &bad }, &d));
    const big = ok ++ [_]config.Option{.{ .key = "count", .value = .{ .integer = 50000 } }};
    try testing.expectError(error.InvalidValue, validate(.{ .name = "ia", .kind = "archive", .options = &big }, &d));
    const small = ok ++ [_]config.Option{.{ .key = "count", .value = .{ .integer = 500 } }};
    try testing.expectError(error.InvalidValue, validate(.{ .name = "ia", .kind = "archive", .options = &small }, &d));
}

test "percent encoding of queries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try percentEncode(arena.allocator(), &out, "collection:gutenberg AND date:[1900 TO 1950]&x=é");
    try testing.expectEqualStrings("collection%3Agutenberg%20AND%20date%3A%5B1900%20TO%201950%5D%26x%3D%C3%A9", out.items);
}

const page1 =
    \\{"items":[
    \\ {"identifier":"book-one","title":"The First Book","creator":["A. Author","B. Writer"],"description":"<p>A <b>tale</b> of a lighthouse.</p>","subject":["sea","stories"],"date":"1923-05-01T00:00:00Z","publicdate":"2010-01-02T03:04:05Z","language":"eng","licenseurl":"https://creativecommons.org/publicdomain/zero/1.0/","mediatype":"texts"},
    \\ {"identifier":"book-two","title":"Second","creator":"C. Third","date":"1999","rights":"Public domain in the USA"},
    \\ {"identifier":"bad/id","title":"slash"},
    \\ {"title":"no identifier"},
    \\ {"identifier":"empty-one"}
    \\],"count":5,"cursor":"CUR1","total":7}
;
const page2 =
    \\{"items":[
    \\ {"identifier":"book-three","title":"Third book about harbours","description":["Line one","Line two"]},
    \\ {"identifier":"book-four","title":"Fourth"}
    \\],"count":2,"total":7}
;

fn archiveSource(base: []const u8, extra: []const config.Option) !ArchiveConnector {
    var opts: std.ArrayList(config.Option) = .empty;
    defer opts.deinit(testing.allocator);
    try opts.append(testing.allocator, .{ .key = "query", .value = .{ .string = "collection:test AND mediatype:texts" } });
    try opts.append(testing.allocator, .{ .key = "user_agent", .value = .{ .string = "t/1" } });
    try opts.append(testing.allocator, .{ .key = "base_url", .value = .{ .string = base } });
    for (extra) |e| try opts.append(testing.allocator, e);
    var c = try ArchiveConnector.init(testing.allocator, testing.io, .{ .name = "ia", .kind = "archive", .options = opts.items });
    c.delay_ms = 0; // validation forbids this; tests only
    c.timeout_s = 5;
    return c;
}

test "pages through results with a cursor and indexes the metadata" {
    var srv: nettest.TestServer = undefined;
    try srv.open();
    try srv.serve(&.{
        .{ .path = "/services/search/v1/scrape?fields=" ++ fields ++ "&count=1000&q=collection%3Atest%20AND%20mediatype%3Atexts", .content_type = "application/json", .body = page1 },
        .{ .path = "/services/search/v1/scrape?fields=" ++ fields ++ "&count=1000&q=collection%3Atest%20AND%20mediatype%3Atexts&cursor=CUR1", .content_type = "application/json", .body = page2 },
    });
    defer srv.stop();
    var base_buf: [64]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{srv.port}) catch unreachable;
    var conn = try archiveSource(base, &.{.{ .key = "count", .value = .{ .integer = 1000 } }});
    defer conn.deinit();

    var got: nettest.Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    const out = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expect(!out.interrupted);
    // book-one, book-two, book-three, book-four are indexed; the id with a
    // slash, the item without an identifier and the empty one are refused.
    try testing.expectEqual(@as(usize, 4), got.ids.items.len);
    try testing.expectEqualStrings("book-one", got.ids.items[0]);
    try testing.expectEqualStrings("The First Book", got.titles.items[0]);
    try testing.expect(std.mem.indexOf(u8, got.texts.items[0], "By A. Author; B. Writer") != null);
    try testing.expect(std.mem.indexOf(u8, got.texts.items[0], "A tale of a lighthouse.") != null);
    try testing.expect(std.mem.indexOf(u8, got.texts.items[0], "Subjects: sea; stories") != null);
    try testing.expect(std.mem.indexOf(u8, got.texts.items[2], "Line one\nLine two") != null);
    try testing.expectEqual(@as(u64, 4), ctl.submitted.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), ctl.rejected.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), srv.paths.items.len); // exactly two requests
    try testing.expectEqualStrings("t/1", srv.agents.items[0]);
}

test "max_items stops early and a failed page is a failure, not silence" {
    var srv: nettest.TestServer = undefined;
    try srv.open();
    try srv.serve(&.{
        .{ .path = "/services/search/v1/scrape?fields=" ++ fields ++ "&count=1000&q=collection%3Atest%20AND%20mediatype%3Atexts", .content_type = "application/json", .body = page1 },
    });
    defer srv.stop();
    var base_buf: [64]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{srv.port}) catch unreachable;
    var conn = try archiveSource(base, &.{ .{ .key = "count", .value = .{ .integer = 1000 } }, .{ .key = "max_items", .value = .{ .integer = 2 } } });
    defer conn.deinit();
    var got: nettest.Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expectEqual(@as(usize, 2), got.ids.items.len);
    try testing.expectEqual(@as(usize, 1), srv.paths.items.len);

    // Resuming from a cursor the server does not know gives a 404: a failure.
    var ctl2: api.Control = .{};
    try testing.expectError(error.SourceFailed, conn.connector().run(got.sink(), &ctl2, "BADCURSOR"));
}

test "an unreachable archive is Offline" {
    var dead = try (try Io.net.IpAddress.parseIp4("127.0.0.1", 0)).listen(testing.io, .{ .reuse_address = true });
    const port = dead.socket.address.getPort();
    dead.deinit(testing.io);
    var base_buf: [64]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port}) catch unreachable;
    var conn = try archiveSource(base, &.{});
    defer conn.deinit();
    var got: nettest.Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    try testing.expectError(error.Offline, conn.connector().run(got.sink(), &ctl, null));
}

test "cancelling reports the cursor to resume from" {
    var srv: nettest.TestServer = undefined;
    try srv.open();
    try srv.serve(&.{
        .{ .path = "/services/search/v1/scrape?fields=" ++ fields ++ "&count=1000&q=collection%3Atest%20AND%20mediatype%3Atexts", .content_type = "application/json", .body = page1 },
        .{ .path = "/services/search/v1/scrape?fields=" ++ fields ++ "&count=1000&q=collection%3Atest%20AND%20mediatype%3Atexts&cursor=CUR1", .content_type = "application/json", .body = page2 },
    });
    defer srv.stop();
    var base_buf: [64]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{srv.port}) catch unreachable;
    var conn = try archiveSource(base, &.{.{ .key = "count", .value = .{ .integer = 1000 } }});
    defer conn.deinit();

    const Stopper = struct {
        ctl: *api.Control,
        fn submit(ptr: *anyopaque, _: doc.Document) api.Sink.Error!void {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            s.ctl.cancel(); // after the first document of page 1
        }
    };
    var ctl: api.Control = .{};
    var st: Stopper = .{ .ctl = &ctl };
    const out = try conn.connector().run(.{ .ptr = &st, .vtable = &.{ .submit = Stopper.submit } }, &ctl, null);
    try testing.expect(out.interrupted);
    try testing.expectEqualStrings("CUR1", out.checkpoint.?);

    // The whole of page 1 was handled before the cancel was noticed, so the
    // cursor for page 2 is the resume point.
    var got: nettest.Collect = .{};
    defer got.deinit();
    var ctl2: api.Control = .{};
    _ = try conn.connector().run(got.sink(), &ctl2, "CUR1");
    try testing.expectEqual(@as(usize, 2), got.ids.items.len);
    try testing.expectEqualStrings("book-three", got.ids.items[0]);
}
