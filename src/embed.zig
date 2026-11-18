//! Semantic search, opt-in (docs/decisions/0038): vectors for documents from an embedding model that the
//! administrator runs (Ollama, or any server with an OpenAI-style `/v1/embeddings`), kept in `vectors.db`, and a
//! hybrid ranking that re-orders the lexical results by meaning.
//!
//! Nothing here runs a model. The model is a separate program reached over HTTP at an address in the
//! configuration; without `[embeddings]` none of this is used, and a lone node stays purely lexical. The vectors
//! are derived data: `dksearch embed` makes them from the retained texts and can be run again at any time.
//!
//! The hybrid ranking works on the candidates the lexical search already found: it cannot bring up a document the
//! words did not match (that needs a vector index over everything, a later step). Within the candidates, the
//! order is the reciprocal-rank fusion of the lexical order and the order of similarity to the query, so a
//! document that is good by both rises, and one that only one list likes is not thrown away.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const sqlite = @import("sqlite.zig");
const doc = @import("document.zig");
const search = @import("search.zig");
const vindex = @import("vindex.zig");

const have_http = build_options.crawler;
const fetch = if (have_http) @import("connectors/crawl/fetch.zig") else struct {};
const cabundle = if (have_http) @import("connectors/crawl/cabundle.zig") else struct {};

pub const Api = enum { ollama, openai };

pub const Settings = struct {
    /// The embedding server, `http://host:port`.
    url: []const u8,
    api: Api = .ollama,
    model: []const u8,
    timeout_ms: u32 = 30000,
    /// How much of a document's text is embedded (its title and the start of its text).
    max_chars: u32 = 2000,
    /// Documents per request when making vectors.
    batch: u32 = 16,
};

pub const Error = error{ NotAvailable, Unreachable, Refused, BadAnswer, OutOfMemory };

pub const rrf_k = 60.0;
pub const max_dimensions = 8192;

/// Talks to the embedding server. One client for the life of the process.
pub const Client = struct {
    gpa: Allocator,
    io: Io,
    settings: Settings,
    http: if (have_http) std.http.Client else void,

    pub fn init(gpa: Allocator, io: Io, settings: Settings) !*Client {
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .settings = settings, .http = undefined };
        if (have_http) {
            self.http = .{ .allocator = gpa, .io = io };
            self.http.now = Io.Clock.real.now(io);
            if (std.mem.startsWith(u8, settings.url, "https://")) cabundle.load(&self.http.ca_bundle, gpa, io, .builtin) catch {};
        }
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (have_http) self.http.deinit();
        self.gpa.destroy(self);
    }

    /// One unit-length vector per text, in order.
    pub fn embed(self: *Client, arena: Allocator, texts: []const []const u8) Error![]const []const f32 {
        if (!have_http) return error.NotAvailable;
        const path: []const u8 = switch (self.settings.api) {
            .ollama => "/api/embed",
            .openai => "/v1/embeddings",
        };
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.settings.url, path });
        const payload = std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(.{ .model = self.settings.model, .input = texts }, .{})}) catch return error.OutOfMemory;
        const resp = fetch.get(&self.http, arena, .{
            .url = url,
            .user_agent = "dksearch-embed/0.1",
            .accept = "application/json",
            .max_body_bytes = 64 * 1024 * 1024,
            .body = payload,
        }, .{ .nanoseconds = @as(i96, self.settings.timeout_ms) * std.time.ns_per_ms }) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unreachable,
        };
        if (resp.status != 200) return error.Refused;
        return parseAnswer(arena, resp.body, self.settings.api, texts.len);
    }
};

/// Reads the server's answer: `{"embeddings":[[..],..]}` (Ollama) or `{"data":[{"embedding":[..]},..]}` (OpenAI).
pub fn parseAnswer(arena: Allocator, body: []const u8, api: Api, expect: usize) Error![]const []const f32 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.BadAnswer;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.BadAnswer,
    };
    const out = try arena.alloc([]const f32, expect);
    switch (api) {
        .ollama => {
            const arr = switch (obj.get("embeddings") orelse return error.BadAnswer) {
                .array => |a| a,
                else => return error.BadAnswer,
            };
            if (arr.items.len != expect) return error.BadAnswer;
            for (arr.items, out) |item, *o| o.* = try vectorOf(arena, item);
        },
        .openai => {
            const arr = switch (obj.get("data") orelse return error.BadAnswer) {
                .array => |a| a,
                else => return error.BadAnswer,
            };
            if (arr.items.len != expect) return error.BadAnswer;
            for (arr.items, out) |item, *o| {
                const emb = switch (item) {
                    .object => |io_| io_.get("embedding") orelse return error.BadAnswer,
                    else => return error.BadAnswer,
                };
                o.* = try vectorOf(arena, emb);
            }
        },
    }
    // All vectors must have the same size.
    for (out) |v| if (v.len != out[0].len) return error.BadAnswer;
    return out;
}

fn vectorOf(arena: Allocator, v: std.json.Value) Error![]const f32 {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.BadAnswer,
    };
    if (arr.items.len == 0 or arr.items.len > max_dimensions) return error.BadAnswer;
    const out = try arena.alloc(f32, arr.items.len);
    var norm: f64 = 0;
    for (arr.items, out) |n, *o| {
        const f: f64 = switch (n) {
            .float => |x| x,
            .integer => |i| @floatFromInt(i),
            else => return error.BadAnswer,
        };
        if (!std.math.isFinite(f)) return error.BadAnswer;
        o.* = @floatCast(f);
        norm += f * f;
    }
    // Stored and compared as unit vectors, so similarity is a dot product.
    if (norm > 0) {
        const inv: f32 = @floatCast(1.0 / @sqrt(norm));
        for (out) |*o| o.* *= inv;
    }
    return out;
}

pub fn dot(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len) return -2;
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

/// What to embed for a document: its title and the start of its text, at most `max_chars` bytes.
pub fn textFor(arena: Allocator, title: ?[]const u8, text: []const u8, max_chars: u32) Allocator.Error![]const u8 {
    var end: usize = @min(text.len, max_chars);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    if (title) |t| if (t.len > 0) return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ t, text[0..end] });
    return arena.dupe(u8, text[0..end]);
}

// ------------------------------------------------------------------------------------------------ store

pub const Store = struct {
    db: *sqlite.c.sqlite3,

    const schema = "CREATE TABLE IF NOT EXISTS vectors(id BLOB NOT NULL, model TEXT NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL, PRIMARY KEY(id, model)) WITHOUT ROWID;";

    pub fn open(path: [:0]const u8) !Store {
        const db = try sqlite.open(path);
        errdefer _ = sqlite.c.sqlite3_close(db);
        try sqlite.execSql(db, schema);
        return .{ .db = db };
    }

    /// For serving: no writing, and null if there is no store yet.
    pub fn openReadOnly(path: [:0]const u8) ?Store {
        const db = sqlite.openReadOnly(path) catch return null;
        return .{ .db = db };
    }

    pub fn close(self: *Store) void {
        _ = sqlite.c.sqlite3_close(self.db);
    }

    pub fn put(self: *Store, id: doc.Id, model: []const u8, v: []const f32) !void {
        const st = try sqlite.Stmt.prepare(self.db, "INSERT OR REPLACE INTO vectors(id, model, dim, vec) VALUES(?1, ?2, ?3, ?4)");
        defer st.deinit();
        try st.blob(1, &id);
        try st.text(2, model);
        try st.int(3, @intCast(v.len));
        try st.blob(4, std.mem.sliceAsBytes(v));
        _ = try st.step();
    }

    pub fn has(self: *Store, id: doc.Id, model: []const u8) bool {
        const st = sqlite.Stmt.prepare(self.db, "SELECT 1 FROM vectors WHERE id = ?1 AND model = ?2") catch return false;
        defer st.deinit();
        st.blob(1, &id) catch return false;
        st.text(2, model) catch return false;
        return st.step() catch false;
    }

    /// The vector of `id` made by `model` (copied into `arena`), or null.
    pub fn get(self: *Store, arena: Allocator, id: doc.Id, model: []const u8) ?[]const f32 {
        const st = sqlite.Stmt.prepare(self.db, "SELECT dim, vec FROM vectors WHERE id = ?1 AND model = ?2") catch return null;
        defer st.deinit();
        st.blob(1, &id) catch return null;
        st.text(2, model) catch return null;
        if (!(st.step() catch return null)) return null;
        const dim: usize = @intCast(@max(0, st.colInt(0)));
        const bytes = st.colBlob(1) orelse return null;
        if (dim == 0 or dim > max_dimensions or bytes.len != dim * 4) return null;
        const out = arena.alloc(f32, dim) catch return null;
        @memcpy(std.mem.sliceAsBytes(out), bytes);
        return out;
    }

    pub fn count(self: *Store, model: []const u8) u64 {
        const st = sqlite.Stmt.prepare(self.db, "SELECT COUNT(*) FROM vectors WHERE model = ?1") catch return 0;
        defer st.deinit();
        st.text(1, model) catch return 0;
        if (!(st.step() catch return 0)) return 0;
        return @intCast(@max(0, st.colInt(0)));
    }
};

// ------------------------------------------------------------------------------------------------ ranking

/// What the server needs for semantic search: the embedding client and where the vectors are.
pub const Service = struct {
    client: *Client,
    vectors_path: [:0]const u8,
    /// The in-memory index of every vector, when `index_mb` allows one.
    holder: ?*vindex.Holder = null,
};

/// Merges two orderings of documents (best first) by reciprocal rank: a document in both rises, one in only one list
/// keeps that list's share. `only_second` counts documents that the first list did not have. Ties keep `first`'s order.
pub fn fuseTwo(arena: Allocator, first: []const search.Hit, second: []const search.Hit) Allocator.Error!struct { hits: []const search.Hit, only_second: usize } {
    const Entry = struct { hit: search.Hit, score: f64, order: usize };
    var entries: std.ArrayList(Entry) = .empty;
    var by_id: std.AutoHashMapUnmanaged(doc.Id, usize) = .empty;
    for (first, 0..) |h, rank| {
        try by_id.put(arena, h.id, entries.items.len);
        try entries.append(arena, .{ .hit = h, .score = 1.0 / (rrf_k + @as(f64, @floatFromInt(rank + 1))), .order = entries.items.len });
    }
    const first_n = entries.items.len;
    for (second, 0..) |h, rank| {
        const share = 1.0 / (rrf_k + @as(f64, @floatFromInt(rank + 1)));
        if (by_id.get(h.id)) |at| {
            entries.items[at].score += share;
        } else {
            try by_id.put(arena, h.id, entries.items.len);
            try entries.append(arena, .{ .hit = h, .score = share, .order = entries.items.len });
        }
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.order < b.order;
        }
    }.less);
    const out = try arena.alloc(search.Hit, entries.items.len);
    for (entries.items, out) |e, *o| {
        o.* = e.hit;
        o.score = e.score;
    }
    return .{ .hits = out, .only_second = entries.items.len - first_n };
}

pub const Fused = struct {
    hits: []const search.Hit,
    /// How many of the hits had a vector to compare.
    compared: usize,
};

/// Re-orders `lexical` (best first) by reciprocal-rank fusion of that order and the order of similarity to `query`.
/// Hits with no vector keep only their lexical share. Ties keep the lexical order.
pub fn fuse(arena: Allocator, store: *Store, model: []const u8, query: []const f32, lexical: []const search.Hit) Allocator.Error!Fused {
    const Entry = struct { hit: search.Hit, lex: usize, sim: ?f32, score: f64 = 0 };
    const entries = try arena.alloc(Entry, lexical.len);
    var compared: usize = 0;
    for (lexical, entries, 0..) |h, *e, i| {
        e.* = .{ .hit = h, .lex = i, .sim = null };
        if (store.get(arena, h.id, model)) |v| {
            e.sim = dot(query, v);
            compared += 1;
        }
    }
    // Rank by similarity among those that have one.
    const order = try arena.alloc(usize, entries.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, entries, struct {
        fn less(es: []Entry, a: usize, b: usize) bool {
            const sa = es[a].sim orelse -3.0;
            const sb = es[b].sim orelse -3.0;
            if (sa != sb) return sa > sb;
            return es[a].lex < es[b].lex;
        }
    }.less);
    for (entries) |*e| e.score = 1.0 / (rrf_k + @as(f64, @floatFromInt(e.lex + 1)));
    var rank: usize = 0;
    for (order) |i| {
        if (entries[i].sim == null) continue;
        entries[i].score += 1.0 / (rrf_k + @as(f64, @floatFromInt(rank + 1)));
        rank += 1;
    }
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.lex < b.lex;
        }
    }.less);
    const out = try arena.alloc(search.Hit, entries.len);
    for (entries, out) |e, *o| {
        o.* = e.hit;
        o.score = e.score;
    }
    return .{ .hits = out, .compared = compared };
}

const testing = std.testing;

test "answers of both kinds are read, vectors are made unit length, and wrong shapes are refused" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const o = try parseAnswer(a, "{\"embeddings\":[[3,4],[0,2]]}", .ollama, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.6), o[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), o[0][1], 0.0001);
    const oa = try parseAnswer(a, "{\"data\":[{\"embedding\":[1.0,0.0]},{\"embedding\":[0.0,5.0]}]}", .openai, 2);
    try testing.expectApproxEqAbs(@as(f32, 1.0), oa[1][1], 0.0001);
    for ([_][]const u8{ "", "[]", "{}", "{\"embeddings\":[[1]]}", "{\"embeddings\":[[1],[1,2]]}", "{\"embeddings\":[[],[]]}", "{\"embeddings\":[[\"x\"],[1]]}" }) |bad| {
        try testing.expectError(error.BadAnswer, parseAnswer(a, bad, .ollama, 2));
    }
    try testing.expectApproxEqAbs(@as(f32, 1.0), dot(o[0], o[0]), 0.0001);
    try testing.expectEqualStrings("T\n\nabc", try textFor(a, "T", "abcdef", 3));
    try testing.expectEqualStrings("é", try textFor(a, null, "é€", 3)); // not cut inside a character
}

fn hitOf(byte: u8) search.Hit {
    var id: doc.Id = @splat(0);
    id[0] = byte;
    return .{ .id = id, .connector = "s", .url = null, .title = null, .snippet = null, .score = 0 };
}

test "vectors are stored per model, and the hybrid order lifts what is close in meaning, keeping what has no vector" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [160:0]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pb, ".zig-cache/tmp/{s}/vectors.db", .{tmp.sub_path}, 0);
    var store = try Store.open(path);
    defer store.close();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const h = [_]search.Hit{ hitOf(1), hitOf(2), hitOf(3), hitOf(4) };
    // The lexical order is 1, 2, 3, 4. By meaning, 3 is closest to the query, 2 is far, 4 has no vector.
    try store.put(h[0].id, "m", &.{ 0.0, 1.0 });
    try store.put(h[1].id, "m", &.{ -1.0, 0.0 });
    try store.put(h[2].id, "m", &.{ 1.0, 0.0 });
    try store.put(h[0].id, "other", &.{ 1.0, 0.0 }); // another model's vector is not used
    try testing.expect(store.has(h[0].id, "m") and !store.has(h[3].id, "m"));
    try testing.expectEqual(@as(u64, 3), store.count("m"));
    const got = (store.get(a, h[2].id, "m")).?;
    try testing.expectEqual(@as(usize, 2), got.len);
    const fused = try fuse(a, &store, "m", &.{ 1.0, 0.0 }, &h);
    try testing.expectEqual(@as(usize, 3), fused.compared);
    // 3 is third lexically but first by meaning, 2 is second lexically but last by meaning: 3 passes 2. 4 has only
    // its lexical share and stays last.
    var pos3: usize = 0;
    var pos2: usize = 0;
    for (fused.hits, 0..) |x, i| {
        if (x.id[0] == 3) pos3 = i;
        if (x.id[0] == 2) pos2 = i;
    }
    try testing.expect(pos3 < pos2);
    try testing.expectEqual(@as(u8, 4), fused.hits[3].id[0]);
    try testing.expect(fused.hits[0].score >= fused.hits[1].score);
    // Without any vector the lexical order is kept exactly.
    var empty_store = try Store.open(try std.fmt.bufPrintSentinel(&pb, ".zig-cache/tmp/{s}/none.db", .{tmp.sub_path}, 0));
    defer empty_store.close();
    const same = try fuse(a, &empty_store, "m", &.{ 1.0, 0.0 }, &h);
    try testing.expectEqual(@as(usize, 0), same.compared);
    for (same.hits, 0..) |x, i| try testing.expectEqual(@as(u8, @intCast(i + 1)), x.id[0]);
}

const nettest = if (have_http) @import("connectors/nettest.zig") else struct {};

test "the client asks an Ollama-style server and a failing server is an error, not a crash" {
    if (!have_http) return error.SkipZigTest;
    var srv: nettest.TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/api/embed", .content_type = "application/json", .body = "{\"embeddings\":[[3,4],[0,2]]}" },
        .{ .path = "/v1/embeddings", .status = 500, .content_type = "application/json", .body = "{}" },
    });
    defer srv.stop();
    var ub: [64]u8 = undefined;
    const url = srv.url(&ub, "");
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const client = try Client.init(testing.allocator, testing.io, .{ .url = url, .model = "m", .timeout_ms = 2000 });
    defer client.deinit();
    const v = try client.embed(a, &.{ "one", "two" });
    try testing.expectEqual(@as(usize, 2), v.len);
    try testing.expectApproxEqAbs(@as(f32, 0.8), v[0][1], 0.0001);
    const bad = try Client.init(testing.allocator, testing.io, .{ .url = url, .api = .openai, .model = "m", .timeout_ms = 2000 });
    defer bad.deinit();
    try testing.expectError(error.Refused, bad.embed(a, &.{"x"}));
    const gone = try Client.init(testing.allocator, testing.io, .{ .url = "http://127.0.0.1:1", .model = "m", .timeout_ms = 500 });
    defer gone.deinit();
    try testing.expectError(error.Unreachable, gone.embed(a, &.{"x"}));
}

test "two orderings are merged by reciprocal rank, and what only the second found is counted" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const lexical = [_]search.Hit{ hitOf(1), hitOf(2), hitOf(3) };
    const vector = [_]search.Hit{ hitOf(3), hitOf(9), hitOf(1) };
    const r = try fuseTwo(a, &lexical, &vector);
    try testing.expectEqual(@as(usize, 4), r.hits.len);
    try testing.expectEqual(@as(usize, 1), r.only_second); // 9 came from the vectors alone
    // 1 and 3 are in both lists and lead; 2 and 9 each have one share, and 2 (first list) goes before 9.
    try testing.expect(r.hits[0].id[0] == 1 or r.hits[0].id[0] == 3);
    try testing.expectEqual(@as(u8, 2), r.hits[2].id[0]);
    try testing.expectEqual(@as(u8, 9), r.hits[3].id[0]);
    const alone = try fuseTwo(a, &lexical, &.{});
    for (alone.hits, 0..) |h, i| try testing.expectEqual(@as(u8, @intCast(i + 1)), h.id[0]);
}
