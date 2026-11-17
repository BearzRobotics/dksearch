//! The peer connector (docs/decisions/0039): copies the documents of a source on another dksearch node into this
//! one, so they can be searched here when that node is away and show up like any other source.
//!
//! The other node must have set `share = true` on the source and given this node an API key whose collections
//! include it; the documents come from its `GET /api/v1/export`. A replica is an ordinary source: it has its own
//! name, rights, schedule and boost, and each document keeps the redistribution flag the owner stated and says
//! where it was copied from. What a peer sends is untrusted: sizes are bounded, text must be valid UTF-8 and the
//! ids well formed. Nothing is executed.
//!
//! Options:
//!   url             required: the other node, `http://host:port` or `https://host`
//!   source          required: the name of the source on that node
//!   key_file        a file holding the API key (or `key`; the file is better, keep it mode 0600)
//!   max_file_bytes  optional: largest text accepted for one document (default 4 MiB)
//!   timeout_seconds optional: per request (default 60)
//!   language        optional: language tag for documents that carry none
//!
//! Resume position: the cursor of the last finished page. A document the other node later removes is not removed
//! here (it keeps what it copied), and a document it changes is updated by the next run.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");
const files = @import("files.zig");
const fetch = @import("crawl/fetch.zig");
const cabundle = @import("crawl/cabundle.zig");

pub const kind = "peer";
pub const default_max_file_bytes: u32 = 4 * 1024 * 1024;
const allowed_options = [_][]const u8{ "url", "source", "key", "key_file", "max_file_bytes", "timeout_seconds", "language" };
const max_page_bytes = 64 * 1024 * 1024;
const page_size = 50;

pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    for (source.options) |o| {
        var known = false;
        for (allowed_options) |k| {
            if (std.mem.eql(u8, k, o.key)) known = true;
        }
        if (!known) {
            diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].{s}", .{ source.name, o.key }) catch o.key, "unknown option for kind \"peer\"", .{});
            return error.UnknownKey;
        }
    }
    inline for (.{ "url", "source" }) |req| {
        const key = std.fmt.bufPrint(&kbuf, "source[{s}]." ++ req, .{source.name}) catch req;
        switch (source.option(req) orelse {
            diag.set("", key, "is required for kind \"peer\"", .{});
            return error.InvalidValue;
        }) {
            .string => |s| if (s.len == 0) {
                diag.set("", key, "must not be empty", .{});
                return error.InvalidValue;
            },
            else => {
                diag.set("", key, "expected string", .{});
                return error.WrongType;
            },
        }
    }
    const url = std.mem.trimEnd(u8, source.optionString("url").?, "/");
    const rest = if (std.mem.startsWith(u8, url, "https://")) url[8..] else if (std.mem.startsWith(u8, url, "http://")) url[7..] else "";
    if (rest.len == 0 or std.mem.indexOfAny(u8, rest, "/?#@ \"'<>") != null) {
        diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].url", .{source.name}) catch "url", "must look like http://host:port or https://host (no path, no credentials)", .{});
        return error.InvalidValue;
    }
    if (!config.validSourceName(source.optionString("source").?)) {
        diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].source", .{source.name}) catch "source", "must be the other node's source name (letters, digits, - and _)", .{});
        return error.InvalidValue;
    }
    if (source.option("key") != null and source.option("key_file") != null) {
        diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].key", .{source.name}) catch "key", "give either key or key_file, not both", .{});
        return error.InvalidValue;
    }
    for ([_][]const u8{ "key", "key_file" }) |k| if (source.option(k)) |v| switch (v) {
        .string => {},
        else => {
            diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].{s}", .{ source.name, k }) catch k, "expected string", .{});
            return error.WrongType;
        },
    };
    inline for (.{ .{ "max_file_bytes", 1, 64 * 1024 * 1024 }, .{ "timeout_seconds", 1, 3600 } }) |opt| {
        if (source.option(opt[0])) |v| {
            const key = std.fmt.bufPrint(&kbuf, "source[{s}]." ++ opt[0], .{source.name}) catch opt[0];
            switch (v) {
                .integer => |n| if (n < opt[1] or n > opt[2]) {
                    diag.set("", key, "must be between {d} and {d}, got {d}", .{ opt[1], opt[2], n });
                    return error.InvalidValue;
                },
                else => {
                    diag.set("", key, "expected integer", .{});
                    return error.WrongType;
                },
            }
        }
    }
    if (source.optionString("language")) |l| if (!files.validLanguageTag(l)) {
        diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].language", .{source.name}) catch "language", "must be a language tag such as \"en\"", .{});
        return error.InvalidValue;
    };
}

pub const PeerConnector = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    url: []const u8,
    remote_source: []const u8,
    key: ?[]const u8,
    key_file: ?[]const u8,
    max_file_bytes: u32,
    timeout_s: u32,
    language: ?[]const u8,
    checkpoint_buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!PeerConnector {
        const name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(name);
        const url = try gpa.dupe(u8, std.mem.trimEnd(u8, source.optionString("url").?, "/"));
        errdefer gpa.free(url);
        const remote = try gpa.dupe(u8, source.optionString("source").?);
        errdefer gpa.free(remote);
        const key = if (source.optionString("key")) |k| try gpa.dupe(u8, k) else null;
        errdefer if (key) |k| gpa.free(k);
        const key_file = if (source.optionString("key_file")) |k| try gpa.dupe(u8, k) else null;
        errdefer if (key_file) |k| gpa.free(k);
        const language = if (source.optionString("language")) |l| try gpa.dupe(u8, l) else null;
        return .{
            .gpa = gpa,
            .io = io,
            .name = name,
            .url = url,
            .remote_source = remote,
            .key = key,
            .key_file = key_file,
            .max_file_bytes = @intCast(source.optionInt("max_file_bytes") orelse default_max_file_bytes),
            .timeout_s = @intCast(source.optionInt("timeout_seconds") orelse 60),
            .language = language,
        };
    }

    pub fn deinit(self: *PeerConnector) void {
        self.gpa.free(self.name);
        self.gpa.free(self.url);
        self.gpa.free(self.remote_source);
        if (self.key) |k| self.gpa.free(k);
        if (self.key_file) |k| self.gpa.free(k);
        if (self.language) |l| self.gpa.free(l);
        self.checkpoint_buf.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn connector(self: *PeerConnector) api.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run } };
    }

    fn info(_: *anyopaque) api.Info {
        return .{ .kind = kind, .requires_network = true, .resumable = true };
    }

    fn stopped(self: *PeerConnector, cursor: []const u8) api.Outcome {
        if (cursor.len == 0) return .{ .interrupted = true };
        self.checkpoint_buf.clearRetainingCapacity();
        self.checkpoint_buf.appendSlice(self.gpa, cursor) catch return .{ .interrupted = true };
        return .{ .interrupted = true, .checkpoint = self.checkpoint_buf.items };
    }

    fn run(ptr: *anyopaque, sink: api.Sink, control: *api.Control, resume_from: ?[]const u8) api.RunError!api.Outcome {
        const self: *PeerConnector = @ptrCast(@alignCast(ptr));
        var auth: ?[]const u8 = null;
        defer if (auth) |a| self.gpa.free(a);
        var key_owned: ?[]u8 = null;
        defer if (key_owned) |k| self.gpa.free(k);
        var key: ?[]const u8 = self.key;
        if (self.key_file) |path| {
            const text = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(4096)) catch return error.InvalidSource;
            key_owned = text;
            key = std.mem.trim(u8, text, " \t\r\n");
        }
        if (key) |k| if (k.len > 0) {
            auth = std.fmt.allocPrint(self.gpa, "Bearer {s}", .{k}) catch return error.OutOfMemory;
        };

        var client: http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();
        cabundle.load(&client.ca_bundle, self.gpa, self.io, .builtin) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSource,
        };
        client.now = Io.Clock.real.now(self.io);

        var cursor: std.ArrayList(u8) = .empty;
        defer cursor.deinit(self.gpa);
        try cursor.appendSlice(self.gpa, resume_from orelse "0");
        var done: u64 = 0;
        var first = true;
        while (true) {
            if (control.isCancelled()) return self.stopped(cursor.items);
            var page = std.heap.ArenaAllocator.init(self.gpa);
            defer page.deinit();
            const a = page.allocator();
            const url = try std.fmt.allocPrint(a, "{s}/api/v1/export?source={s}&after={s}&limit={d}", .{ self.url, self.remote_source, cursor.items, page_size });
            const got = fetch.get(&client, a, .{
                .url = url,
                .user_agent = "dksearch-peer/0.1",
                .accept = "application/json",
                .max_body_bytes = max_page_bytes,
                .authorization = auth,
            }, .fromSeconds(self.timeout_s)) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return self.stopped(cursor.items),
                error.Network, error.Timeout => return if (first and resume_from == null) error.Offline else error.SourceFailed,
                else => return error.SourceFailed,
            };
            first = false;
            // 401 or 404 mean the key is wrong or the source is not shared with it: nothing to copy.
            if (got.status != 200) return error.SourceFailed;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, got.body, .{}) catch return error.SourceFailed;
            const root = switch (parsed) {
                .object => |o| o,
                else => return error.SourceFailed,
            };
            const docs = switch (root.get("documents") orelse return error.SourceFailed) {
                .array => |arr| arr.items,
                else => return error.SourceFailed,
            };
            for (docs) |item| {
                switch (try self.submitOne(a, item, sink, control)) {
                    .ok => {},
                    .stopped => return self.stopped(cursor.items),
                }
                done += 1;
            }
            control.setProgress(done, 0);
            const next: ?[]const u8 = if (root.get("next")) |n| switch (n) {
                .string => |s| if (s.len > 0 and s.len < 24 and std.mem.indexOfNone(u8, s, "0123456789") == null) s else null,
                else => null,
            } else null;
            const nx = next orelse break;
            if (std.mem.eql(u8, nx, cursor.items)) break; // a peer that does not move forward must not loop us
            cursor.clearRetainingCapacity();
            try cursor.appendSlice(self.gpa, nx);
            sink.checkpoint(cursor.items) catch |e| switch (e) {
                error.Stopped => return self.stopped(cursor.items),
                else => return error.SourceFailed,
            };
        }
        return .{};
    }

    const Step = enum { ok, stopped };

    fn str(obj: std.json.ObjectMap, key: []const u8, max: usize) ?[]const u8 {
        const v = obj.get(key) orelse return null;
        return switch (v) {
            .string => |s| if (s.len <= max) s else s[0..max],
            else => null,
        };
    }

    fn int(obj: std.json.ObjectMap, key: []const u8) ?i64 {
        const v = obj.get(key) orelse return null;
        return switch (v) {
            .integer => |n| n,
            else => null,
        };
    }

    fn submitOne(self: *PeerConnector, a: Allocator, item: std.json.Value, sink: api.Sink, control: *api.Control) api.RunError!Step {
        const obj = switch (item) {
            .object => |o| o,
            else => return self.reject(control, .unreadable, "(not an object)"),
        };
        const id = str(obj, "id", 64) orelse return self.reject(control, .unreadable, "(no id)");
        var raw: doc.Id = undefined;
        if (id.len != 32 or (std.fmt.hexToBytes(&raw, id) catch null) == null) return self.reject(control, .unreadable, id);
        const text = str(obj, "text", self.max_file_bytes + 1) orelse return self.reject(control, .no_text, id);
        if (text.len > self.max_file_bytes) return self.reject(control, .too_large, id);
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return self.reject(control, .no_text, id);
        // std.json already refuses invalid UTF-8 in strings; a NUL byte is not text.
        if (std.mem.indexOfScalar(u8, text, 0) != null) return self.reject(control, .unreadable, id);
        const url_raw = str(obj, "url", 2000);
        const url: ?[]const u8 = if (url_raw) |u| (if (std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://")) u else null) else null;
        const owner = str(obj, "redistribution", 16) orelse "unknown";
        const redistribution: doc.Redistribution = if (std.mem.eql(u8, owner, "allowed")) .allowed else if (std.mem.eql(u8, owner, "restricted")) .restricted else .unknown;
        var extras: std.ArrayList(doc.Extra) = .empty;
        extras.append(a, .{ .key = "origin", .value = std.fmt.allocPrint(a, "{s}/{s}", .{ self.url, self.remote_source }) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        const d: doc.Document = .{
            .connector = self.name,
            .source_id = id,
            .canonical_url = url,
            .title = str(obj, "title", 1000),
            .text = text,
            .language = str(obj, "language", 35) orelse self.language,
            .content_type = str(obj, "content_type", 100),
            .author = str(obj, "author", 255),
            .modified_at = int(obj, "modified_at"),
            .published_at = int(obj, "published_at"),
            .rights = .{
                .attribution = std.fmt.allocPrint(a, "Copied from {s}, source {s}", .{ self.url, self.remote_source }) catch return error.OutOfMemory,
                .access_notes = "Copied from another dksearch node whose owner shared it; the rights stated there apply.",
                .redistribution = redistribution,
            },
            .extra = extras.items,
        };
        sink.submit(d) catch |e| switch (e) {
            error.Rejected => return .ok, // the pipeline counts it
            error.Stopped => return .stopped,
            error.OutOfMemory => return error.OutOfMemory,
        };
        _ = control.submitted.fetchAdd(1, .monotonic);
        return .ok;
    }

    fn reject(self: *PeerConnector, control: *api.Control, why: api.Reason, what: []const u8) Step {
        _ = self;
        control.rejectAt(why, what); // counts it too
        return .ok;
    }
};

// -------------------------------------------------------------------------------------------------- tests

const testing = std.testing;
const nettest = @import("nettest.zig");

fn testSource(url: []const u8, extra: []const config.Option) !config.Source {
    const opts = try testing.allocator.alloc(config.Option, extra.len + 2);
    opts[0] = .{ .key = "url", .value = .{ .string = url } };
    opts[1] = .{ .key = "source", .value = .{ .string = "books" } };
    @memcpy(opts[2..], extra);
    return .{ .name = "replica", .kind = "peer", .options = opts };
}

test "a shared source is copied page by page, with its rights, and a bad document is counted not fatal" {
    var srv: nettest.TestServer = undefined;
    const page1 = "{\"source\":\"books\",\"documents\":[" ++
        "{\"id\":\"0102030405060708090a0b0c0d0e0f10\",\"title\":\"Edda\",\"text\":\"Odin had two ravens\",\"url\":\"https://e.org/edda\",\"redistribution\":\"allowed\",\"language\":\"en\",\"modified_at\":100}," ++
        "{\"id\":\"zz\",\"text\":\"bad id\"}," ++
        "{\"id\":\"0102030405060708090a0b0c0d0e0f11\",\"text\":\"\"}," ++
        "{\"id\":\"0102030405060708090a0b0c0d0e0f12\",\"title\":\"Local\",\"text\":\"a file\",\"url\":\"file:///home/x/a.txt\"}" ++
        "],\"next\":\"4\"}";
    const page2 = "{\"source\":\"books\",\"documents\":[{\"id\":\"0102030405060708090a0b0c0d0e0f13\",\"text\":\"second page text\",\"redistribution\":\"restricted\"}],\"next\":null}";
    try srv.start(&.{
        .{ .path = "/api/v1/export?source=books&after=0&limit=50", .content_type = "application/json", .body = page1 },
        .{ .path = "/api/v1/export?source=books&after=4&limit=50", .content_type = "application/json", .body = page2 },
    });
    defer srv.stop();
    var ub: [64]u8 = undefined;
    const source = try testSource(srv.url(&ub, ""), &.{});
    defer testing.allocator.free(source.options);
    var conn = try PeerConnector.init(testing.allocator, testing.io, source);
    defer conn.deinit();
    var got: nettest.Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    const out = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expect(!out.interrupted);
    try testing.expectEqual(@as(usize, 3), got.ids.items.len); // Edda, Local, the second page's
    try testing.expectEqualStrings("0102030405060708090a0b0c0d0e0f10", got.ids.items[0]);
    try testing.expectEqualStrings("Odin had two ravens", got.texts.items[0]);
    try testing.expectEqualStrings("second page text", got.texts.items[2]);
    try testing.expectEqual(@as(u64, 3), ctl.submitted.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), ctl.rejected.load(.monotonic)); // the bad id and the empty text
    try testing.expectEqual(@as(usize, 1), srv.count("/api/v1/export?source=books&after=4&limit=50"));
    // A run resumed from the last page's cursor asks for that page only.
    var again: nettest.Collect = .{};
    defer again.deinit();
    var ctl2: api.Control = .{};
    _ = try conn.connector().run(again.sink(), &ctl2, "4");
    try testing.expectEqual(@as(usize, 1), again.ids.items.len);
}

test "a refusal, a peer that does not answer and a source with a bad address are errors, not crashes" {
    var srv: nettest.TestServer = undefined;
    try srv.start(&.{.{ .path = "/api/v1/export?source=books&after=0&limit=50", .status = 404, .content_type = "application/json", .body = "{}" }});
    defer srv.stop();
    var ub: [64]u8 = undefined;
    const source = try testSource(srv.url(&ub, ""), &.{});
    defer testing.allocator.free(source.options);
    var conn = try PeerConnector.init(testing.allocator, testing.io, source);
    defer conn.deinit();
    var got: nettest.Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    try testing.expectError(error.SourceFailed, conn.connector().run(got.sink(), &ctl, null));
    const down = try testSource("http://127.0.0.1:1", &.{.{ .key = "timeout_seconds", .value = .{ .integer = 2 } }});
    defer testing.allocator.free(down.options);
    var conn2 = try PeerConnector.init(testing.allocator, testing.io, down);
    defer conn2.deinit();
    try testing.expectError(error.Offline, conn2.connector().run(got.sink(), &ctl, null));
    var d: config.Diagnostic = .{};
    const bad = try testSource("ftp://x", &.{});
    defer testing.allocator.free(bad.options);
    try testing.expectError(error.InvalidValue, validate(bad, &d));
    const both = try testSource("http://x:1", &.{ .{ .key = "key", .value = .{ .string = "a" } }, .{ .key = "key_file", .value = .{ .string = "b" } } });
    defer testing.allocator.free(both.options);
    try testing.expectError(error.InvalidValue, validate(both, &d));
    const ok = try testSource("https://search.example.org", &.{.{ .key = "key_file", .value = .{ .string = "/etc/k" } }});
    defer testing.allocator.free(ok.options);
    try validate(ok, &d);
}
