//! Asking other dksearch nodes (peers) the same question, and merging their answers with this node's.
//!
//! A peer is a node the operator configured, with an API key the peer issued; it answers `/api/v1/search` limited to
//! the collections of that key. Everything a peer sends is untrusted data: bodies, counts and every string are
//! bounded, ids must be well formed, and nothing is ever treated as markup. Peers are asked in parallel, each with its
//! own deadline, and a peer that fails repeatedly is left alone for a while, so one dead peer does not slow every
//! search. Local results never wait for a peer beyond the deadline, and always come first in the report.
//! See docs/research/p2p-plan.md and docs/decisions/0034-peers-and-federated-search.md.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const config = @import("config.zig");
const doc = @import("document.zig");
const search = @import("search.zig");

const have_http = build_options.crawler;
const fetch = if (have_http) @import("connectors/crawl/fetch.zig") else struct {};
const cabundle = if (have_http) @import("connectors/crawl/cabundle.zig") else struct {};

pub const max_answer_bytes = 512 * 1024;
pub const max_hits_per_peer = 50;
pub const max_field_bytes = 1000;
pub const max_snippet_bytes = 3000;
/// The constant of reciprocal-rank fusion: larger values flatten the difference between ranks.
pub const rrf_k = 60.0;
pub const user_agent = "dksearch-peer/0.1";

pub const Status = enum {
    ok,
    /// No answer within the peer's deadline.
    timeout,
    /// Could not connect, or the connection broke.
    down,
    /// The peer refused our key (401, 403) or answered with another error status.
    refused,
    /// The answer was not what the protocol says; ignored.
    bad_answer,
    /// Left out for a while after repeated failures.
    backoff,
    /// This build cannot make network requests.
    unavailable,
};

pub const Kind = enum { search, retrieve };

/// A passage a peer returned for `/api/v1/retrieve`, bounded and with its link built here.
pub const RemoteChunk = struct {
    node: []const u8,
    /// The document's node-independent identity, if the peer gave a well formed one.
    ident: ?[]const u8 = null,
    doc_id: []const u8,
    view_url: []const u8,
    source: []const u8,
    title: ?[]const u8,
    url: ?[]const u8,
    heading: []const []const u8,
    index: u32,
    of: u32,
    start: usize,
    end: usize,
    page: ?u32,
    page_source: ?[]const u8,
    entries: []const []const u8,
    score: f64,
    text: []const u8,
    before: []const []const u8,
    after: []const []const u8,
};

pub const max_chunk_text_bytes = 16 * 1024;
pub const max_chunks_per_peer = 50;

pub const Reply = struct {
    peer: []const u8,
    status: Status,
    ms: u32 = 0,
    /// Results, owned by the request arena.
    hits: []const search.Hit = &.{},
    /// Passages (for `Kind.retrieve`), owned by the request arena.
    chunks: []const RemoteChunk = &.{},
    /// Entries of the answer that were skipped for being malformed.
    skipped: u32 = 0,
    /// The status code of a refusal.
    http_status: u16 = 0,
};

const PeerState = struct {
    cfg: config.Peer,
    base: []const u8,
    /// `Bearer ...`, or null if there is no key.
    auth: ?[]const u8,
    failures: std.atomic.Value(u32) = .init(0),
    /// Monotonic time (ns) before which the peer is not asked.
    quiet_until: std.atomic.Value(i64) = .init(0),
    /// What the last real attempt (not a skip) was: status (as an int, -1 for none yet), when (unix seconds), how long.
    last_status: std.atomic.Value(i32) = .init(-1),
    last_unix: std.atomic.Value(i64) = .init(0),
    last_ms: std.atomic.Value(u32) = .init(0),
    /// When the peer last answered properly (unix seconds), 0 for never.
    last_ok_unix: std.atomic.Value(i64) = .init(0),
};

/// What the administration page shows of a peer.
pub const Info = struct {
    name: []const u8,
    url: []const u8,
    enabled: bool,
    has_key: bool,
    last_status: ?Status,
    last_unix: i64,
    last_ms: u32,
    last_ok_unix: i64,
    failures: u32,
    /// Seconds until it is asked again, 0 if not in backoff.
    quiet_secs: u32,
};

pub const Service = struct {
    gpa: Allocator,
    io: Io,
    node: []const u8,
    peers: []PeerState,
    client: if (have_http) std.http.Client else void,

    /// `cfgs` as configured; keys given by `key_file` are read here (a file that cannot be read leaves the peer
    /// without a key, which its server will refuse).
    pub fn init(gpa: Allocator, io: Io, node: []const u8, cfgs: []const config.Peer) !*Service {
        const self = try gpa.create(Service);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .node = try gpa.dupe(u8, node), .peers = try gpa.alloc(PeerState, cfgs.len), .client = undefined };
        var made: usize = 0;
        errdefer {
            for (self.peers[0..made]) |p| freeState(gpa, p);
            gpa.free(self.peers);
            gpa.free(self.node);
        }
        for (cfgs, self.peers) |c, *slot| {
            var key: ?[]const u8 = c.key;
            var owned: ?[]u8 = null;
            if (c.key_file) |path| {
                if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096))) |text| {
                    owned = text;
                    key = std.mem.trim(u8, text, " \t\r\n");
                } else |_| key = null;
            }
            const auth: ?[]const u8 = if (key) |k| (if (k.len > 0) try std.fmt.allocPrint(gpa, "Bearer {s}", .{k}) else null) else null;
            if (owned) |o| gpa.free(o);
            errdefer if (auth) |a| gpa.free(a);
            slot.* = .{ .cfg = c, .base = try gpa.dupe(u8, c.url), .auth = auth };
            made += 1;
        }
        if (have_http) {
            self.client = .{ .allocator = gpa, .io = io };
            self.client.now = Io.Clock.real.now(io);
            var https = false;
            for (cfgs) |c| if (std.mem.startsWith(u8, c.url, "https://")) {
                https = true;
            };
            if (https) cabundle.load(&self.client.ca_bundle, gpa, io, .builtin) catch {};
        }
        return self;
    }

    fn freeState(gpa: Allocator, p: PeerState) void {
        gpa.free(p.base);
        if (p.auth) |a| gpa.free(a);
    }

    pub fn deinit(self: *Service) void {
        const gpa = self.gpa;
        if (have_http) self.client.deinit();
        for (self.peers) |p| freeState(gpa, p);
        gpa.free(self.peers);
        gpa.free(self.node);
        gpa.destroy(self);
    }

    pub fn enabledCount(self: *const Service) usize {
        var n: usize = 0;
        for (self.peers) |p| if (p.cfg.enabled) {
            n += 1;
        };
        return n;
    }

    const Slot = struct {
        svc: *Service,
        peer: *PeerState,
        q: []const u8,
        kind: Kind,
        /// Further query parameters, already encoded, starting with `&`.
        extra: []const u8,
        /// The task's own memory, freed after the answer is copied out.
        arena: std.heap.ArenaAllocator,
        reply: Reply,
        done: bool = false,
    };

    /// Asks every enabled peer the same question, in parallel; returns one reply per enabled peer, in
    /// configuration order, with everything in `arena`. `extra` is appended to the query string as given
    /// (`&limit=10`, `&k=8&context=1`).
    pub fn ask(self: *Service, arena: Allocator, kind: Kind, q: []const u8, extra: []const u8) Allocator.Error![]Reply {
        const slots = try arena.alloc(Slot, self.peers.len);
        var n: usize = 0;
        var group: Io.Group = .init;
        for (self.peers) |*p| {
            if (!p.cfg.enabled) continue;
            slots[n] = .{ .svc = self, .peer = p, .q = q, .kind = kind, .extra = extra, .arena = .init(self.gpa), .reply = .{ .peer = p.cfg.name, .status = .down } };
            n += 1;
        }
        for (slots[0..n]) |*s| {
            group.concurrent(self.io, runSlot, .{s}) catch runSlot(s); // no thread to spare: ask in turn
        }
        group.await(self.io) catch {};
        const out = try arena.alloc(Reply, n);
        for (slots[0..n], out) |*s, *o| {
            defer s.arena.deinit();
            o.* = s.reply;
            o.peer = try arena.dupe(u8, s.reply.peer);
            const hits = try arena.alloc(search.Hit, s.reply.hits.len);
            for (s.reply.hits, hits) |h, *dst| dst.* = try copyHit(arena, h);
            o.hits = hits;
            const chunks = try arena.alloc(RemoteChunk, s.reply.chunks.len);
            for (s.reply.chunks, chunks) |c, *dst| dst.* = try copyChunk(arena, c);
            o.chunks = chunks;
        }
        return out;
    }

    fn runSlot(s: *Slot) void {
        s.reply = s.svc.timed(s.arena.allocator(), s.peer, s.kind, s.q, s.extra, false);
        s.done = true;
    }

    /// One attempt, timed and remembered for the administration page. A skip because of backoff is not an attempt.
    fn timed(self: *Service, a: Allocator, p: *PeerState, kind: Kind, q: []const u8, extra: []const u8, force: bool) Reply {
        const t0 = nowNs(self.io);
        if (force) p.quiet_until.store(0, .monotonic);
        var r = self.askOne(a, p, kind, q, extra);
        r.ms = @intCast(@max(0, @divTrunc(nowNs(self.io) - t0, std.time.ns_per_ms)));
        if (r.status != .backoff and r.status != .unavailable) {
            const now = Io.Clock.real.now(self.io).toSeconds();
            p.last_status.store(@backingInt(r.status), .monotonic);
            p.last_unix.store(now, .monotonic);
            p.last_ms.store(r.ms, .monotonic);
            if (r.status == .ok) p.last_ok_unix.store(now, .monotonic);
        }
        return r;
    }

    /// Asks the named peer a small question right now (whatever its backoff), for the pairing test: `ok` means the
    /// address answers and the key is accepted. Null if there is no such peer.
    pub fn probe(self: *Service, arena: Allocator, name: []const u8) ?Reply {
        for (self.peers) |*p| if (std.mem.eql(u8, p.cfg.name, name)) {
            var tmp = std.heap.ArenaAllocator.init(self.gpa);
            defer tmp.deinit();
            var r = self.timed(tmp.allocator(), p, .search, "dksearch", "&limit=1", true);
            r.hits = &.{};
            r.chunks = &.{};
            r.peer = arena.dupe(u8, r.peer) catch return null;
            return r;
        };
        return null;
    }

    pub fn info(self: *Service, arena: Allocator) Allocator.Error![]Info {
        const out = try arena.alloc(Info, self.peers.len);
        const now = nowNs(self.io);
        for (self.peers, out) |*p, *o| {
            const ls = p.last_status.load(.monotonic);
            const quiet = p.quiet_until.load(.monotonic) - now;
            o.* = .{
                .name = try arena.dupe(u8, p.cfg.name),
                .url = try arena.dupe(u8, p.cfg.url),
                .enabled = p.cfg.enabled,
                .has_key = p.auth != null,
                .last_status = if (ls < 0) null else @fromBackingInt(@intCast(ls)),
                .last_unix = p.last_unix.load(.monotonic),
                .last_ms = p.last_ms.load(.monotonic),
                .last_ok_unix = p.last_ok_unix.load(.monotonic),
                .failures = p.failures.load(.monotonic),
                .quiet_secs = if (quiet > 0) @intCast(@divTrunc(quiet, std.time.ns_per_s)) else 0,
            };
        }
        return out;
    }

    fn askOne(self: *Service, a: Allocator, p: *PeerState, kind: Kind, q: []const u8, extra: []const u8) Reply {
        var r: Reply = .{ .peer = p.cfg.name, .status = .down };
        if (!have_http) {
            r.status = .unavailable;
            return r;
        }
        const t0 = nowNs(self.io);
        if (t0 < p.quiet_until.load(.monotonic)) {
            r.status = .backoff;
            return r;
        }
        var url: Io.Writer.Allocating = .init(a);
        url.writer.print("{s}/api/v1/{s}?q=", .{ p.base, @tagName(kind) }) catch return r;
        writeEncoded(&url.writer, q) catch return r;
        url.writer.writeAll(extra) catch return r;
        // Finding passages reads and splits documents: it is given twice the time of a search.
        const wait_ms: i96 = @as(i96, p.cfg.timeout_ms) * (if (kind == .retrieve) @as(i96, 2) else 1);
        const resp = fetch.get(&self.client, a, .{ .url = url.written(), .user_agent = user_agent, .accept = "application/json", .max_body_bytes = max_answer_bytes, .authorization = p.auth }, .{ .nanoseconds = wait_ms * std.time.ns_per_ms }) catch |e| {
            r.status = switch (e) {
                error.Timeout => .timeout,
                error.BadResponse, error.TooLarge => .bad_answer,
                else => .down,
            };
            self.penalise(p);
            return r;
        };
        if (resp.status != 200) {
            r.status = .refused;
            r.http_status = resp.status;
            self.penalise(p);
            return r;
        }
        switch (kind) {
            .search => {
                const parsed = parseAnswer(a, resp.body, p.cfg.name, p.base) catch {
                    r.status = .bad_answer;
                    self.penalise(p);
                    return r;
                };
                r.hits = parsed.hits;
                r.skipped = parsed.skipped;
            },
            .retrieve => {
                const parsed = parseRetrieveAnswer(a, resp.body, p.cfg.name, p.base) catch {
                    r.status = .bad_answer;
                    self.penalise(p);
                    return r;
                };
                r.chunks = parsed.chunks;
                r.skipped = parsed.skipped;
            },
        }
        p.failures.store(0, .monotonic);
        p.quiet_until.store(0, .monotonic);
        r.status = .ok;
        return r;
    }

    /// After a failure the peer is left alone for 5 s, doubling with each further failure up to 5 minutes.
    fn penalise(self: *Service, p: *PeerState) void {
        const n = p.failures.fetchAdd(1, .monotonic) + 1;
        const secs: i64 = @min(300, @as(i64, 5) << @intCast(@min(n - 1, 6)));
        p.quiet_until.store(nowNs(self.io) + secs * std.time.ns_per_s, .monotonic);
    }
};

fn writeEncoded(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text) |b| switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(b),
        else => try w.print("%{X:0>2}", .{b}),
    };
}

fn nowNs(io: Io) i64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
}

fn copyHit(a: Allocator, h: search.Hit) Allocator.Error!search.Hit {
    var o = h;
    o.connector = try a.dupe(u8, h.connector);
    if (h.url) |v| o.url = try a.dupe(u8, v);
    if (h.title) |v| o.title = try a.dupe(u8, v);
    if (h.snippet) |v| o.snippet = try a.dupe(u8, v);
    if (h.language) |v| o.language = try a.dupe(u8, v);
    if (h.content_type) |v| o.content_type = try a.dupe(u8, v);
    if (h.author) |v| o.author = try a.dupe(u8, v);
    if (h.kind) |v| o.kind = try a.dupe(u8, v);
    if (h.domain) |v| o.domain = try a.dupe(u8, v);
    if (h.node) |v| o.node = try a.dupe(u8, v);
    if (h.remote_view) |v| o.remote_view = try a.dupe(u8, v);
    if (h.ident) |v| o.ident = try a.dupe(u8, v);
    return o;
}

fn dupeAll(a: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, list.len);
    for (list, out) |s, *d| d.* = try a.dupe(u8, s);
    return out;
}

fn copyChunk(a: Allocator, c: RemoteChunk) Allocator.Error!RemoteChunk {
    var o = c;
    o.node = try a.dupe(u8, c.node);
    if (c.ident) |v| o.ident = try a.dupe(u8, v);
    o.doc_id = try a.dupe(u8, c.doc_id);
    o.view_url = try a.dupe(u8, c.view_url);
    o.source = try a.dupe(u8, c.source);
    if (c.title) |v| o.title = try a.dupe(u8, v);
    if (c.url) |v| o.url = try a.dupe(u8, v);
    if (c.page_source) |v| o.page_source = try a.dupe(u8, v);
    o.heading = try dupeAll(a, c.heading);
    o.entries = try dupeAll(a, c.entries);
    o.text = try a.dupe(u8, c.text);
    o.before = try dupeAll(a, c.before);
    o.after = try dupeAll(a, c.after);
    return o;
}

pub const ParsedChunks = struct { chunks: []const RemoteChunk, skipped: u32 };

fn stringArray(a: Allocator, v: ?std.json.Value, max_items: usize, max_bytes: usize) Allocator.Error![]const []const u8 {
    const arr = switch (v orelse return &.{}) {
        .array => |x| x,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        if (out.items.len >= max_items) break;
        if (try bounded(a, item, max_bytes)) |s| try out.append(a, s);
    }
    return out.items;
}

/// Reads the body of a peer's `/api/v1/retrieve` answer with the same distrust as `parseAnswer`: a `chunks` array of
/// objects, each with a well formed `doc_id` and `text`; counts and sizes bounded; the link built from the id.
pub fn parseRetrieveAnswer(a: Allocator, body: []const u8, node: []const u8, base: []const u8) AnswerError!ParsedChunks {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.BadAnswer;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.BadAnswer,
    };
    const arr = switch (obj.get("chunks") orelse return error.BadAnswer) {
        .array => |x| x,
        else => return error.BadAnswer,
    };
    var out: std.ArrayList(RemoteChunk) = .empty;
    var skipped: u32 = 0;
    for (arr.items) |item| {
        if (out.items.len >= max_chunks_per_peer) break;
        const c = switch (item) {
            .object => |o| o,
            else => {
                skipped += 1;
                continue;
            },
        };
        const id_hex = switch (c.get("doc_id") orelse .null) {
            .string => |s| s,
            else => {
                skipped += 1;
                continue;
            },
        };
        var id: doc.Id = undefined;
        const text = try bounded(a, c.get("text"), max_chunk_text_bytes);
        if (id_hex.len != 32 or (std.fmt.hexToBytes(&id, id_hex) catch null) == null or text == null) {
            skipped += 1;
            continue;
        }
        const source = (try bounded(a, c.get("source"), 64)) orelse {
            skipped += 1;
            continue;
        };
        const score: f64 = switch (c.get("score") orelse .null) {
            .float => |f| if (std.math.isFinite(f)) f else 0,
            .integer => |i| @floatFromInt(i),
            else => 0,
        };
        try out.append(a, .{
            .node = node,
            .ident = try validIdent(a, c.get("ident")),
            .doc_id = try a.dupe(u8, id_hex),
            .view_url = try std.fmt.allocPrint(a, "{s}/doc/{s}", .{ base, id_hex }),
            .source = source,
            .title = try bounded(a, c.get("title"), max_field_bytes),
            .url = try bounded(a, c.get("url"), max_field_bytes * 2),
            .heading = try stringArray(a, c.get("heading"), 8, 300),
            .index = smallInt(c.get("index"), u32) orelse 0,
            .of = smallInt(c.get("of"), u32) orelse 0,
            .start = smallInt(c.get("start"), usize) orelse 0,
            .end = smallInt(c.get("end"), usize) orelse 0,
            .page = smallInt(c.get("page"), u32),
            .page_source = try bounded(a, c.get("page_source"), 16),
            .entries = try stringArray(a, c.get("entries"), 8, 200),
            .score = score,
            .text = text.?,
            .before = try stringArray(a, c.get("before"), 3, max_chunk_text_bytes),
            .after = try stringArray(a, c.get("after"), 3, max_chunk_text_bytes),
        });
    }
    if (skipped > 3 and skipped * 2 > arr.items.len) return error.BadAnswer;
    return .{ .chunks = out.items, .skipped = skipped };
}

pub const Parsed = struct { hits: []const search.Hit, skipped: u32 };

pub const AnswerError = error{ BadAnswer, OutOfMemory };

fn bounded(a: Allocator, v: ?std.json.Value, max: usize) Allocator.Error!?[]const u8 {
    const s = switch (v orelse return null) {
        .string => |x| x,
        else => return null,
    };
    var end = @min(s.len, max);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1; // not in the middle of a character
    return try a.dupe(u8, s[0..end]);
}

fn smallInt(v: ?std.json.Value, comptime T: type) ?T {
    return switch (v orelse return null) {
        .integer => |i| std.math.cast(T, i),
        else => null,
    };
}

/// Reads the body of a peer's `/api/v1/search` answer. Anything that is not an object with a `hits` array is refused;
/// a malformed entry is skipped (and counted); a few skipped entries are tolerated, mostly skipped ones are not.
pub fn parseAnswer(a: Allocator, body: []const u8, node: []const u8, base: []const u8) AnswerError!Parsed {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.BadAnswer;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.BadAnswer,
    };
    const arr = switch (obj.get("hits") orelse return error.BadAnswer) {
        .array => |x| x,
        else => return error.BadAnswer,
    };
    var out: std.ArrayList(search.Hit) = .empty;
    var skipped: u32 = 0;
    for (arr.items) |item| {
        if (out.items.len >= max_hits_per_peer) break;
        const h = switch (item) {
            .object => |o| o,
            else => {
                skipped += 1;
                continue;
            },
        };
        const id_hex = switch (h.get("id") orelse .null) {
            .string => |s| s,
            else => {
                skipped += 1;
                continue;
            },
        };
        var id: doc.Id = undefined;
        if (id_hex.len != 32 or (std.fmt.hexToBytes(&id, id_hex) catch null) == null) {
            skipped += 1;
            continue;
        }
        const connector = (try bounded(a, h.get("connector"), 64)) orelse {
            skipped += 1;
            continue;
        };
        const score: f64 = switch (h.get("score") orelse .null) {
            .float => |f| if (std.math.isFinite(f)) f else 0,
            .integer => |i| @floatFromInt(i),
            else => 0,
        };
        try out.append(a, .{
            .id = id,
            .connector = connector,
            .url = try bounded(a, h.get("url"), max_field_bytes * 2),
            .title = try bounded(a, h.get("title"), max_field_bytes),
            .snippet = try bounded(a, h.get("snippet"), max_snippet_bytes),
            .score = score,
            .language = try bounded(a, h.get("language"), 32),
            .content_type = try bounded(a, h.get("content_type"), 128),
            .kind = try bounded(a, h.get("kind"), 32),
            .domain = try bounded(a, h.get("domain"), 255),
            .author = try bounded(a, h.get("author"), 255),
            .size = smallInt(h.get("size"), u64),
            .modified_at = smallInt(h.get("modified_at"), i64),
            .node = node,
            .ident = try validIdent(a, h.get("ident")),
            // The page is built from the id, never taken from the answer: a peer cannot point us elsewhere.
            .remote_view = try std.fmt.allocPrint(a, "{s}/doc/{s}", .{ base, id_hex }),
        });
    }
    if (skipped > 3 and skipped * 2 > arr.items.len) return error.BadAnswer;
    return .{ .hits = out.items, .skipped = skipped };
}

// ------------------------------------------------------------------ merging

/// The identity of a document that does not depend on the node: for a web page the hash of its address as `identity`
/// makes it (so http and https, fragments and trailing slashes do not matter), otherwise the hash of the stored text
/// (`stamp`, the content store's hash of it). Null when neither is known. 32 hex digits.
pub fn identHex(arena: Allocator, url: ?[]const u8, stamp: ?[32]u8) Allocator.Error!?[]const u8 {
    var digest: [32]u8 = undefined;
    if (try identity(arena, url)) |ident| {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("u\x00");
        h.update(ident);
        h.final(&digest);
    } else if (stamp) |s| {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("t\x00");
        h.update(&s);
        h.final(&digest);
    } else return null;
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    return try arena.dupe(u8, &hex);
}

/// `v` if it is exactly 32 lower-case hex digits (copied), else null: a peer's claimed identity is only used as a key.
fn validIdent(a: Allocator, v: ?std.json.Value) Allocator.Error!?[]const u8 {
    const s = switch (v orelse return null) {
        .string => |x| x,
        else => return null,
    };
    if (s.len != 32) return null;
    for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return null;
    return try a.dupe(u8, s);
}

/// The address with what does not identify a page removed: scheme and host in lower case, no fragment, no trailing
/// slash. Null for addresses that mean something only on one machine (files).
pub fn identity(a: Allocator, url: ?[]const u8) Allocator.Error!?[]const u8 {
    const u = url orelse return null;
    const scheme_end = std.mem.indexOf(u8, u, "://") orelse return null;
    if (!std.ascii.eqlIgnoreCase(u[0..scheme_end], "http") and !std.ascii.eqlIgnoreCase(u[0..scheme_end], "https")) return null;
    var end = std.mem.indexOfScalar(u8, u, '#') orelse u.len;
    while (end > scheme_end + 3 and u[end - 1] == '/') end -= 1;
    const host_end = std.mem.indexOfScalarPos(u8, u[0..end], scheme_end + 3, '/') orelse end;
    // http and https of the same page are the same page: the scheme is left out of the identity.
    const out = try a.dupe(u8, u[scheme_end + 3 .. end]);
    for (out[0 .. host_end - scheme_end - 3]) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

const Entry = struct { hit: search.Hit, score: f64, order: usize, also: std.ArrayList([]const u8) = .empty };

/// Merges this node's results with the peers' by reciprocal-rank fusion: a result's score is the sum of
/// 1/(60 + rank) over the lists it is in (scores themselves are not comparable between indexes). The same page
/// found on several nodes is one result, shown from this node if it has it, and naming the others in `also_on`.
/// At most `limit` results.
pub fn fuse(a: Allocator, local: []const search.Hit, replies: []const Reply, limit: usize) Allocator.Error![]const search.Hit {
    var entries: std.ArrayList(Entry) = .empty;
    var by_identity: std.StringHashMapUnmanaged(usize) = .empty;
    var by_node_id: std.StringHashMapUnmanaged(usize) = .empty;
    const Lists = struct { hits: []const search.Hit, node: ?[]const u8 };
    var lists: std.ArrayList(Lists) = .empty;
    try lists.append(a, .{ .hits = local, .node = null });
    for (replies) |r| if (r.status == .ok) try lists.append(a, .{ .hits = r.hits, .node = r.peer });
    for (lists.items) |l| for (l.hits, 0..) |h, rank| {
        const contribution = 1.0 / (rrf_k + @as(f64, @floatFromInt(rank + 1)));
        // The node-independent identity decides when there is one (the same file on two nodes); else the address.
        const ident: ?[]const u8 = if (h.ident) |i| try std.fmt.allocPrint(a, "i:{s}", .{i}) else try identity(a, h.url);
        const alt = try std.fmt.allocPrint(a, "{s}/{x}", .{ h.node orelse "", &h.id });
        const found: ?usize = if (ident) |k| by_identity.get(k) else by_node_id.get(alt);
        if (found) |at| {
            entries.items[at].score += contribution;
            if (l.node) |nd| {
                var seen = false;
                if (entries.items[at].hit.node) |n0| if (std.mem.eql(u8, n0, nd)) {
                    seen = true;
                };
                for (entries.items[at].also.items) |x| if (std.mem.eql(u8, x, nd)) {
                    seen = true;
                };
                if (!seen) try entries.items[at].also.append(a, nd);
            }
            continue;
        }
        try entries.append(a, .{ .hit = h, .score = contribution, .order = entries.items.len });
        const at = entries.items.len - 1;
        if (ident) |k| try by_identity.put(a, k, at) else try by_node_id.put(a, alt, at);
    };
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            if (x.score != y.score) return x.score > y.score;
            return x.order < y.order;
        }
    }.less);
    const n = @min(limit, entries.items.len);
    const out = try a.alloc(search.Hit, n);
    for (entries.items[0..n], out) |e, *o| {
        o.* = e.hit;
        o.score = e.score;
        o.also_on = e.also.items;
    }
    return out;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn hitOf(id_byte: u8, url: ?[]const u8, node: ?[]const u8) search.Hit {
    var id: doc.Id = @splat(0);
    id[0] = id_byte;
    return .{ .id = id, .connector = "s", .url = url, .title = "t", .snippet = null, .score = 1, .node = node };
}

test "the same page on several nodes is one result, from this node, naming the others; fusion orders by rank" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const local = [_]search.Hit{ hitOf(1, "https://Example.org/a/", null), hitOf(2, "file:///x/b.txt", null) };
    const from_p = [_]search.Hit{ hitOf(9, "http://example.org/a#top", "p"), hitOf(8, "https://example.org/only-p", "p") };
    const from_q = [_]search.Hit{ hitOf(7, "https://example.org/only-q", "q"), hitOf(6, "https://example.org/a", "q") };
    const replies = [_]Reply{
        .{ .peer = "p", .status = .ok, .hits = &from_p },
        .{ .peer = "q", .status = .ok, .hits = &from_q },
        .{ .peer = "r", .status = .timeout },
    };
    const out = try fuse(a, &local, &replies, 10);
    try testing.expectEqual(@as(usize, 4), out.len);
    // The page on all three nodes comes first; it is shown from this node and names both others.
    try testing.expect(out[0].node == null);
    try testing.expectEqual(@as(usize, 2), out[0].also_on.len);
    try testing.expectEqualStrings("p", out[0].also_on[0]);
    try testing.expectEqualStrings("q", out[0].also_on[1]);
    // The limit applies after merging.
    try testing.expectEqual(@as(usize, 2), (try fuse(a, &local, &replies, 2)).len);
    // Without peers the local order is kept.
    const alone = try fuse(a, &local, &.{}, 10);
    try testing.expectEqual(@as(usize, 2), alone.len);
    try testing.expectEqual(@as(u8, 1), alone[0].id[0]);
}

test "an answer is read within bounds, ids are checked, links come from the id, and nonsense is refused" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const good = "{\"hits\":[{\"id\":\"0102030405060708090a0b0c0d0e0f10\",\"connector\":\"books\",\"url\":\"https://e.org/x\",\"title\":\"<b>T</b>\",\"snippet\":\"a \\u0002b\\u0003\",\"score\":2.5,\"view_url\":\"http://evil.example/\",\"size\":10},{\"id\":\"zz\",\"connector\":\"x\"},5,{\"id\":\"0102030405060708090a0b0c0d0e0f11\"}],\"has_more\":false}";
    const p = try parseAnswer(a, good, "office", "http://peer:8080");
    try testing.expectEqual(@as(usize, 1), p.hits.len);
    try testing.expectEqual(@as(u32, 3), p.skipped);
    try testing.expectEqualStrings("office", p.hits[0].node.?);
    try testing.expectEqualStrings("<b>T</b>", p.hits[0].title.?); // kept as text; escaping is the page's job
    try testing.expectEqualStrings("http://peer:8080/doc/0102030405060708090a0b0c0d0e0f10", p.hits[0].remote_view.?);
    try testing.expectEqual(@as(?u64, 10), p.hits[0].size);
    // Oversized fields are cut, not refused.
    const xs = try a.alloc(u8, 5000);
    @memset(xs, 'x');
    const long = try std.fmt.allocPrint(a, "{{\"hits\":[{{\"id\":\"0102030405060708090a0b0c0d0e0f10\",\"connector\":\"b\",\"title\":\"{s}\"}}]}}", .{xs});
    try testing.expectEqual(@as(usize, max_field_bytes), (try parseAnswer(a, long, "n", "http://h")).hits[0].title.?.len);
    for ([_][]const u8{ "", "[]", "{}", "{\"hits\":5}", "not json", "{\"hits\":[1,2,3,4,5,6,7,8]}" }) |bad| try testing.expectError(error.BadAnswer, parseAnswer(a, bad, "n", "http://h"));
}

test "identity ignores case of the host, fragments, trailing slashes and http against https; files have none" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const x = (try identity(a, "HTTPS://Example.ORG/Path/#frag")).?;
    try testing.expectEqualStrings(x, (try identity(a, "http://example.org/Path")).?);
    try testing.expect((try identity(a, "file:///etc/passwd")) == null);
    try testing.expect((try identity(a, null)) == null);
    try testing.expect(!std.mem.eql(u8, x, (try identity(a, "https://example.org/path")).?)); // paths are case sensitive
}

const nettest = if (have_http) @import("connectors/nettest.zig") else struct {};

test "peers are asked in parallel: one answers, one is slow, one is down, one refuses; the bad ones are left alone for a while" {
    if (!have_http) return error.SkipZigTest;
    var fast: nettest.TestServer = undefined;
    try fast.start(&.{.{ .path = "/api/v1/search?q=odin%20ravens&limit=10", .content_type = "application/json", .body = "{\"hits\":[{\"id\":\"0102030405060708090a0b0c0d0e0f10\",\"connector\":\"books\",\"url\":\"https://e.org/x\",\"title\":\"Odin\",\"score\":3}],\"has_more\":false}" }});
    defer fast.stop();
    var slow: nettest.TestServer = undefined;
    try slow.start(&.{.{ .path = "/api/v1/search?q=odin%20ravens&limit=10", .content_type = "application/json", .body = "{\"hits\":[]}", .stall_ms = 3000 }});
    defer slow.stop();
    var denied: nettest.TestServer = undefined;
    try denied.start(&.{.{ .path = "/api/v1/search?q=odin%20ravens&limit=10", .status = 401, .content_type = "application/json", .body = "{}" }});
    defer denied.stop();
    var closed: nettest.TestServer = undefined;
    try closed.open();
    const closed_port = closed.port;
    closed.listener.deinit(testing.io); // nothing listens here any more
    for (closed.paths.items) |p| testing.allocator.free(p);

    var ub: [4][64]u8 = undefined;
    const peers = [_]config.Peer{
        .{ .name = "fast", .url = fast.url(&ub[0], ""), .key = "dkk_k" },
        .{ .name = "slow", .url = slow.url(&ub[1], ""), .timeout_ms = 300 },
        .{ .name = "denied", .url = denied.url(&ub[2], "") },
        .{ .name = "gone", .url = try std.fmt.bufPrint(&ub[3], "http://127.0.0.1:{d}", .{closed_port}) },
        .{ .name = "off", .url = "http://127.0.0.1:1", .enabled = false },
    };
    const svc = try Service.init(testing.allocator, testing.io, "home", &peers);
    defer svc.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const t0 = nowNs(testing.io);
    const replies = try svc.ask(a, .search, "odin ravens", "&limit=10");
    const took_ms = @divTrunc(nowNs(testing.io) - t0, std.time.ns_per_ms);
    try testing.expect(took_ms < 2000); // the slow peer's 3 s were not waited for
    try testing.expectEqual(@as(usize, 4), replies.len); // the disabled one is not asked
    try testing.expectEqual(Status.ok, replies[0].status);
    try testing.expectEqual(@as(usize, 1), replies[0].hits.len);
    try testing.expectEqualStrings("fast", replies[0].hits[0].node.?);
    try testing.expectEqual(Status.timeout, replies[1].status);
    try testing.expectEqual(Status.refused, replies[2].status);
    try testing.expectEqual(@as(u16, 401), replies[2].http_status);
    try testing.expectEqual(Status.down, replies[3].status);
    // Asked again at once: the failed ones are not tried (backoff), the good one is.
    const again = try svc.ask(a, .search, "odin ravens", "&limit=10");
    try testing.expectEqual(Status.ok, again[0].status);
    try testing.expectEqual(Status.backoff, again[1].status);
    try testing.expectEqual(Status.backoff, again[2].status);
    try testing.expectEqual(Status.backoff, again[3].status);
    try testing.expectEqual(@as(usize, 1), slow.count("/api/v1/search?q=odin%20ravens&limit=10"));
}

test "a retrieval answer is read within bounds, ids are checked, links come from the id, pictures are not carried" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const body = "{\"chunks\":[{\"doc_id\":\"0102030405060708090a0b0c0d0e0f10\",\"view_url\":\"http://evil/\",\"source\":\"books\",\"title\":\"Edda\",\"url\":\"https://e.org/edda\",\"heading\":[\"Norse\",5],\"index\":2,\"of\":9,\"start\":10,\"end\":99,\"page\":4,\"page_source\":\"text\",\"entries\":[\"ODIN\"],\"score\":1.5,\"text\":\"Odin had <i>two</i> ravens\",\"before\":[\"b\"],\"after\":[],\"images\":[{\"n\":1,\"url\":\"/doc/x/image/1\"}]},{\"doc_id\":\"bad\",\"text\":\"x\",\"source\":\"s\"},{\"doc_id\":\"0102030405060708090a0b0c0d0e0f11\",\"source\":\"s\"}],\"candidates\":3}";
    const p = try parseRetrieveAnswer(a, body, "office", "http://peer:8080");
    try testing.expectEqual(@as(usize, 1), p.chunks.len);
    try testing.expectEqual(@as(u32, 2), p.skipped);
    const c = p.chunks[0];
    try testing.expectEqualStrings("http://peer:8080/doc/0102030405060708090a0b0c0d0e0f10", c.view_url);
    try testing.expectEqual(@as(usize, 1), c.heading.len); // the non-string entry is dropped
    try testing.expectEqualStrings("Odin had <i>two</i> ravens", c.text); // text stays text
    try testing.expectEqual(@as(?u32, 4), c.page);
    for ([_][]const u8{ "", "{}", "{\"chunks\":{}}", "[1]" }) |bad| try testing.expectError(error.BadAnswer, parseRetrieveAnswer(a, bad, "n", "http://h"));
}

test "passages are asked for with the same limits, and a peer's passages arrive attributed" {
    if (!have_http) return error.SkipZigTest;
    var srv: nettest.TestServer = undefined;
    try srv.start(&.{.{ .path = "/api/v1/retrieve?q=odin&k=3&context=1", .content_type = "application/json", .body = "{\"chunks\":[{\"doc_id\":\"0102030405060708090a0b0c0d0e0f10\",\"source\":\"books\",\"text\":\"Odin\",\"score\":2}]}" }});
    defer srv.stop();
    var ub: [64]u8 = undefined;
    const peers = [_]config.Peer{.{ .name = "p", .url = srv.url(&ub, "") }};
    const svc = try Service.init(testing.allocator, testing.io, "home", &peers);
    defer svc.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const replies = try svc.ask(ar.allocator(), .retrieve, "odin", "&k=3&context=1");
    try testing.expectEqual(Status.ok, replies[0].status);
    try testing.expectEqual(@as(usize, 1), replies[0].chunks.len);
    try testing.expectEqualStrings("p", replies[0].chunks[0].node);
}

test "the pairing test says whether the peer answers and accepts the key, and the status is remembered" {
    if (!have_http) return error.SkipZigTest;
    var good: nettest.TestServer = undefined;
    try good.start(&.{.{ .path = "/api/v1/search?q=dksearch&limit=1", .content_type = "application/json", .body = "{\"hits\":[]}" }});
    defer good.stop();
    var bad: nettest.TestServer = undefined;
    try bad.start(&.{.{ .path = "/api/v1/search?q=dksearch&limit=1", .status = 401, .content_type = "application/json", .body = "{}" }});
    defer bad.stop();
    var ub: [2][64]u8 = undefined;
    const peers = [_]config.Peer{ .{ .name = "good", .url = good.url(&ub[0], ""), .key = "k" }, .{ .name = "bad", .url = bad.url(&ub[1], "") } };
    const svc = try Service.init(testing.allocator, testing.io, "home", &peers);
    defer svc.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expect(svc.probe(a, "nope") == null);
    try testing.expectEqual(Status.ok, svc.probe(a, "good").?.status);
    try testing.expectEqual(Status.refused, svc.probe(a, "bad").?.status);
    try testing.expectEqual(Status.refused, svc.probe(a, "bad").?.status); // a test is not held back by backoff
    const infos = try svc.info(a);
    try testing.expectEqual(Status.ok, infos[0].last_status.?);
    try testing.expect(infos[0].has_key and infos[0].last_ok_unix > 0);
    try testing.expectEqual(Status.refused, infos[1].last_status.?);
    try testing.expect(!infos[1].has_key and infos[1].last_ok_unix == 0 and infos[1].failures == 2 and infos[1].quiet_secs > 0);
}

test "identity: the same page or the same text is the same on every node, and a different one differs" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const t1: [32]u8 = @splat(1);
    const t2: [32]u8 = @splat(2);
    // A web page: the address decides (http/https, fragment, slash do not matter); the text does not.
    const w1 = (try identHex(a, "https://Example.org/a/", t1)).?;
    try testing.expectEqual(@as(usize, 32), w1.len);
    try testing.expectEqualStrings(w1, (try identHex(a, "http://example.org/a#x", t2)).?);
    try testing.expect(!std.mem.eql(u8, w1, (try identHex(a, "https://example.org/b", t1)).?));
    // A file: the text decides, wherever it lives.
    const f1 = (try identHex(a, "file:///home/a/x.txt", t1)).?;
    try testing.expectEqualStrings(f1, (try identHex(a, "file:///mnt/other/y.txt", t1)).?);
    try testing.expect(!std.mem.eql(u8, f1, (try identHex(a, "file:///home/a/x.txt", t2)).?));
    // A file's identity is not a web page's.
    try testing.expect(!std.mem.eql(u8, f1, w1));
    try testing.expect((try identHex(a, "file:///x", null)) == null);
    // The same file on two nodes merges although their addresses differ; a claimed identity must be well formed.
    var h1 = hitOf(1, "file:///home/a/x.txt", null);
    h1.ident = f1;
    var h2 = hitOf(2, "file:///mnt/other/y.txt", "p");
    h2.ident = f1;
    var h3 = hitOf(3, "file:///z", "p");
    h3.ident = (try identHex(a, "file:///z", t2)).?;
    const local = [_]search.Hit{h1};
    const remote = [_]search.Hit{ h2, h3 };
    const merged = try fuse(a, &local, &[_]Reply{.{ .peer = "p", .status = .ok, .hits = &remote }}, 10);
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqualStrings("p", merged[0].also_on[0]);
    const body = "{\"hits\":[{\"id\":\"0102030405060708090a0b0c0d0e0f10\",\"connector\":\"b\",\"ident\":\"ABC\"},{\"id\":\"0102030405060708090a0b0c0d0e0f11\",\"connector\":\"b\",\"ident\":\"00112233445566778899aabbccddeeff\"}]}";
    const parsed = try parseAnswer(a, body, "n", "http://h");
    try testing.expect(parsed.hits[0].ident == null);
    try testing.expectEqualStrings("00112233445566778899aabbccddeeff", parsed.hits[1].ident.?);
}
