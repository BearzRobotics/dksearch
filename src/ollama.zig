//! Talking to an Ollama server (docs/decisions/0042): finding it, listing the models it has, pulling and removing
//! models, and asking one to answer. Ollama is a separate program the administrator runs; dksearch never starts it,
//! never starts it silently and never pulls a model without being told to. Everything here is optional: without an
//! `[ollama]` table and with no Ollama at the default address, nothing in this file is used.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const connector = @import("connector.zig");

const have_http = build_options.crawler;
const fetch = if (have_http) @import("connectors/crawl/fetch.zig") else struct {};

pub const default_url = "http://127.0.0.1:11434";

pub const Error = error{ NotAvailable, Unreachable, Refused, BadAnswer, Cancelled, OutOfMemory };

pub const Model = struct {
    name: []const u8,
    size: u64,
    /// Unix seconds, 0 if unknown.
    modified: i64 = 0,
    family: []const u8 = "",
    parameters: []const u8 = "",
    quantization: []const u8 = "",
};

/// True if the name can be sent to Ollama safely: letters, digits and `. _ - : /` (`library/llama3.2:3b`,
/// `hf.co/org/repo:Q4_K_M`), at most 200 characters.
pub fn validModelName(name: []const u8) bool {
    if (name.len == 0 or name.len > 200) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == ':' or c == '/')) return false;
    return name[0] != '-' and name[0] != '/' and std.mem.indexOf(u8, name, "..") == null;
}

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    base: []const u8,
    http: if (have_http) std.http.Client else void,

    pub fn init(gpa: Allocator, io: Io, url: []const u8) !*Client {
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .base = try gpa.dupe(u8, std.mem.trimEnd(u8, url, "/")), .http = undefined };
        if (have_http) {
            self.http = .{ .allocator = gpa, .io = io };
            self.http.now = Io.Clock.real.now(io);
        }
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (have_http) self.http.deinit();
        self.gpa.free(self.base);
        self.gpa.destroy(self);
    }

    const Call = struct { method: ?std.http.Method = null, body: ?[]const u8 = null, timeout_s: u32 = 5, max_bytes: usize = 4 * 1024 * 1024 };

    fn call(self: *Client, arena: Allocator, path: []const u8, c: Call) Error![]const u8 {
        if (!have_http) return error.NotAvailable;
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base, path });
        const resp = fetch.get(&self.http, arena, .{
            .url = url,
            .user_agent = "dksearch-ollama/0.1",
            .accept = "application/json",
            .max_body_bytes = c.max_bytes,
            .body = c.body,
            .method = c.method,
        }, .fromSeconds(c.timeout_s)) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Cancelled,
            else => error.Unreachable,
        };
        if (resp.status != 200) return error.Refused;
        return resp.body;
    }

    /// The server's version, or null if nothing answers at the address.
    pub fn version(self: *Client, arena: Allocator) ?[]const u8 {
        const body = self.call(arena, "/api/version", .{ .timeout_s = 2 }) catch return null;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
        const obj = switch (root) {
            .object => |o| o,
            else => return null,
        };
        return switch (obj.get("version") orelse return null) {
            .string => |s| arena.dupe(u8, s[0..@min(s.len, 40)]) catch null,
            else => null,
        };
    }

    pub fn list(self: *Client, arena: Allocator) Error![]const Model {
        const body = try self.call(arena, "/api/tags", .{});
        return parseTags(arena, body);
    }

    /// Pulls `name` (downloads the model into Ollama). Blocks until it is done, fails or `control` is cancelled.
    pub fn pull(self: *Client, arena: Allocator, name: []const u8, control: ?*connector.Control) Error!void {
        if (!validModelName(name)) return error.Refused;
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .model = name, .name = name, .stream = false }, .{})});
        if (control) |ctl| {
            var buffer: [2]PullTask = undefined;
            var select: Io.Select(PullTask) = .init(self.io, &buffer);
            select.concurrent(.done, pullCall, .{ self, arena, body }) catch return error.Unreachable;
            select.concurrent(.watch, watchCancel, .{ self.io, ctl }) catch {
                select.cancelDiscard();
                return error.Unreachable;
            };
            const first = select.await() catch {
                select.cancelDiscard();
                return error.Cancelled;
            };
            select.cancelDiscard();
            return switch (first) {
                .done => |r| r,
                .watch => error.Cancelled,
            };
        }
        return pullCall(self, arena, body);
    }

    const PullTask = union(enum) { done: Error!void, watch: void };

    fn pullCall(self: *Client, arena: Allocator, body: []const u8) Error!void {
        // A model is gigabytes: the request may take hours. The answer is a small JSON status.
        const answer = try self.call(arena, "/api/pull", .{ .body = body, .timeout_s = 4 * 3600, .max_bytes = 1024 * 1024 });
        if (std.mem.indexOf(u8, answer, "\"error\"") != null and std.mem.indexOf(u8, answer, "\"success\"") == null) return error.Refused;
    }

    fn watchCancel(io: Io, control: *connector.Control) void {
        while (!control.isCancelled()) io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch return;
    }

    pub fn remove(self: *Client, arena: Allocator, name: []const u8) Error!void {
        if (!validModelName(name)) return error.Refused;
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .model = name, .name = name }, .{})});
        _ = try self.call(arena, "/api/delete", .{ .method = .DELETE, .body = body });
    }

    /// One answer from `model` to the `system` and `user` messages, without streaming.
    pub fn chat(self: *Client, arena: Allocator, model: []const u8, system: []const u8, user: []const u8, timeout_s: u32) Error![]const u8 {
        if (!validModelName(model)) return error.Refused;
        const Msg = struct { role: []const u8, content: []const u8 };
        const msgs = [_]Msg{ .{ .role = "system", .content = system }, .{ .role = "user", .content = user } };
        const body = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .model = model, .messages = &msgs, .stream = false, .options = .{ .temperature = 0.2 } }, .{})});
        const answer = try self.call(arena, "/api/chat", .{ .body = body, .timeout_s = timeout_s, .max_bytes = 4 * 1024 * 1024 });
        return parseChat(arena, answer);
    }
};

pub fn parseTags(arena: Allocator, body: []const u8) Error![]const Model {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.BadAnswer;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.BadAnswer,
    };
    const arr = switch (obj.get("models") orelse return error.BadAnswer) {
        .array => |a| a,
        .null => return &.{},
        else => return error.BadAnswer,
    };
    var out: std.ArrayList(Model) = .empty;
    for (arr.items) |item| {
        if (out.items.len >= 500) break;
        const o = switch (item) {
            .object => |x| x,
            else => continue,
        };
        const name = switch (o.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!validModelName(name)) continue;
        var m: Model = .{ .name = try arena.dupe(u8, name), .size = 0 };
        if (o.get("size")) |s| switch (s) {
            .integer => |n| m.size = if (n > 0) @intCast(n) else 0,
            else => {},
        };
        if (o.get("details")) |d| switch (d) {
            .object => |dd| {
                inline for (.{ .{ "family", &m.family }, .{ "parameter_size", &m.parameters }, .{ "quantization_level", &m.quantization } }) |f| {
                    if (dd.get(f[0])) |v| switch (v) {
                        .string => |s| f[1].* = try arena.dupe(u8, s[0..@min(s.len, 40)]),
                        else => {},
                    };
                }
            },
            else => {},
        };
        try out.append(arena, m);
    }
    return out.items;
}

pub fn parseChat(arena: Allocator, body: []const u8) Error![]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.BadAnswer;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.BadAnswer,
    };
    const msg = switch (obj.get("message") orelse return error.BadAnswer) {
        .object => |m| m,
        else => return error.BadAnswer,
    };
    const text = switch (msg.get("content") orelse return error.BadAnswer) {
        .string => |s| s,
        else => return error.BadAnswer,
    };
    return arena.dupe(u8, text[0..@min(text.len, 64 * 1024)]);
}

const testing = std.testing;
const nettest = if (have_http) @import("connectors/nettest.zig") else struct {};

test "model names are checked, and answers are read within bounds" {
    for ([_][]const u8{ "llama3.2:3b", "library/nomic-embed-text", "hf.co/org/repo:Q4_K_M", "qwen2.5-0.5b-instruct:latest" }) |n| try testing.expect(validModelName(n));
    for ([_][]const u8{ "", "-rf", "/etc", "a b", "a\"b", "a;b", "../x", "x\\y" }) |n| try testing.expect(!validModelName(n));
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const tags = try parseTags(a, "{\"models\":[{\"name\":\"llama3.2:3b\",\"size\":2019393189,\"details\":{\"family\":\"llama\",\"parameter_size\":\"3.2B\",\"quantization_level\":\"Q4_K_M\"}},{\"name\":\"bad name\",\"size\":1},{\"size\":5},7]}");
    try testing.expectEqual(@as(usize, 1), tags.len);
    try testing.expectEqual(@as(u64, 2019393189), tags[0].size);
    try testing.expectEqualStrings("3.2B", tags[0].parameters);
    try testing.expectEqual(@as(usize, 0), (try parseTags(a, "{\"models\":null}")).len);
    for ([_][]const u8{ "", "[]", "{}", "{\"models\":5}" }) |bad| try testing.expectError(error.BadAnswer, parseTags(a, bad));
    try testing.expectEqualStrings("Hi", try parseChat(a, "{\"message\":{\"role\":\"assistant\",\"content\":\"Hi\"}}"));
    try testing.expectError(error.BadAnswer, parseChat(a, "{\"message\":{}}"));
}

test "the client lists models, pulls and removes one, and says when nothing answers" {
    if (!have_http) return error.SkipZigTest;
    var srv: nettest.TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/api/version", .content_type = "application/json", .body = "{\"version\":\"0.9.9\"}" },
        .{ .path = "/api/tags", .content_type = "application/json", .body = "{\"models\":[{\"name\":\"m1:latest\",\"size\":100}]}" },
        .{ .path = "/api/pull", .content_type = "application/json", .body = "{\"status\":\"success\"}" },
        .{ .path = "/api/delete", .content_type = "application/json", .body = "" },
        .{ .path = "/api/chat", .content_type = "application/json", .body = "{\"message\":{\"content\":\"The ravens.\"}}" },
    });
    defer srv.stop();
    var ub: [64]u8 = undefined;
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const c = try Client.init(testing.allocator, testing.io, srv.url(&ub, ""));
    defer c.deinit();
    try testing.expectEqualStrings("0.9.9", c.version(a).?);
    const models = try c.list(a);
    try testing.expectEqualStrings("m1:latest", models[0].name);
    try c.pull(a, "nomic-embed-text", null);
    var ctl: connector.Control = .{};
    try c.pull(a, "nomic-embed-text", &ctl); // with the cancel watcher
    try c.remove(a, "nomic-embed-text");
    try testing.expectEqualStrings("The ravens.", try c.chat(a, "m1", "be brief", "who flew?", 5));
    try testing.expectError(error.Refused, c.pull(a, "bad name; rm", null));
    const gone = try Client.init(testing.allocator, testing.io, "http://127.0.0.1:1");
    defer gone.deinit();
    try testing.expect(gone.version(a) == null);
    try testing.expectError(error.Unreachable, gone.list(a));
    // A cancelled pull stops waiting.
    var slow: nettest.TestServer = undefined;
    try slow.start(&.{.{ .path = "/api/pull", .content_type = "application/json", .body = "{\"status\":\"success\"}", .stall_ms = 5000 }});
    defer slow.stop();
    var ub2: [64]u8 = undefined;
    const c2 = try Client.init(testing.allocator, testing.io, slow.url(&ub2, ""));
    defer c2.deinit();
    var cancelled: connector.Control = .{};
    cancelled.cancelled.store(true, .monotonic);
    try testing.expectError(error.Cancelled, c2.pull(a, "m", &cancelled));
}
