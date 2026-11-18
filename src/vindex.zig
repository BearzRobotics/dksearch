//! A vector index over every document that has a vector (docs/decisions/0043): the nearest documents to a query
//! vector, found by an exact scan, so semantic search can bring up documents the words did not match.
//!
//! The vectors of `vectors.db` (unit length, float32) are held in memory as int8, one byte per dimension: 768
//! dimensions cost 768 bytes a document, so a million documents are about 770 MB, and the scan is a few hundred
//! million multiply-adds with SIMD. Exact rather than approximate: there is nothing to tune, no recall to lose and
//! no graph to rebuild; a graph index (HNSW) is the step for libraries too large to scan. Quantizing to int8 changes
//! a similarity by well under a percent.
//!
//! `Holder` keeps the loaded index current: it looks at `vectors.db` now and then and loads a new copy when `dksearch
//! embed` has added vectors, while searches that began on the old copy finish on it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const doc = @import("document.zig");
const sqlite = @import("sqlite.zig");

pub const Scored = struct { id: doc.Id, score: f32 };

pub const Index = struct {
    gpa: Allocator,
    dim: u32,
    n: usize,
    ids: []doc.Id,
    /// `n * dim` quantized components.
    data: []i8,

    pub fn deinit(self: *Index) void {
        self.gpa.free(self.ids);
        self.gpa.free(self.data);
        self.* = undefined;
    }

    pub fn bytes(self: *const Index) usize {
        return self.data.len + self.ids.len * @sizeOf(doc.Id);
    }

    /// Reads the vectors of `model` from `path`. Null if there are none (or the file does not exist). Refuses with
    /// `error.TooLarge` when they would need more than `max_bytes`.
    pub fn load(gpa: Allocator, path: [:0]const u8, model: []const u8, max_bytes: usize) !?Index {
        const db = sqlite.openReadOnly(path) catch return null;
        defer _ = sqlite.c.sqlite3_close(db);
        const count_st = sqlite.Stmt.prepare(db, "SELECT COUNT(*), MAX(dim) FROM vectors WHERE model = ?1") catch return null;
        defer count_st.deinit();
        count_st.text(1, model) catch return null;
        if (!(count_st.step() catch return null)) return null;
        const n: usize = @intCast(@max(0, count_st.colInt(0)));
        const dim: usize = @intCast(@max(0, count_st.colInt(1)));
        if (n == 0 or dim == 0) return null;
        if (n * dim + n * @sizeOf(doc.Id) > max_bytes) return error.TooLarge;
        const ids = try gpa.alloc(doc.Id, n);
        errdefer gpa.free(ids);
        const data = try gpa.alloc(i8, n * dim);
        errdefer gpa.free(data);
        const st = sqlite.Stmt.prepare(db, "SELECT id, dim, vec FROM vectors WHERE model = ?1") catch return null;
        defer st.deinit();
        st.text(1, model) catch return null;
        var i: usize = 0;
        while (st.step() catch return null) {
            if (i >= n) break;
            const id_blob = st.colBlob(0) orelse continue;
            const vec = st.colBlob(2) orelse continue;
            if (id_blob.len != @sizeOf(doc.Id) or st.colInt(1) != @as(i64, @intCast(dim)) or vec.len != dim * 4) continue;
            ids[i] = id_blob[0..@sizeOf(doc.Id)].*;
            const row = data[i * dim ..][0..dim];
            for (row, 0..) |*q, d| {
                const f: f32 = @bitCast(std.mem.readInt(u32, vec[d * 4 ..][0..4], .little));
                q.* = quantize(f);
            }
            i += 1;
        }
        if (i == 0) {
            gpa.free(ids);
            gpa.free(data);
            return null;
        }
        // Rows that did not fit (another dimension, a damaged blob) were skipped: the arrays hold `i` rows.
        const ids_final = if (i == n) ids else try gpa.realloc(ids, i);
        const data_final = if (i == n) data else try gpa.realloc(data, i * dim);
        return .{ .gpa = gpa, .dim = @intCast(dim), .n = i, .ids = ids_final, .data = data_final };
    }

    /// The `k` documents most similar to `query` (a vector of this index's dimension, unit length), best first.
    pub fn search(self: *const Index, arena: Allocator, query: []const f32, k: usize) Allocator.Error![]const Scored {
        if (query.len != self.dim or self.n == 0 or k == 0) return &.{};
        const q8 = try arena.alloc(i8, self.dim);
        for (q8, query) |*o, f| o.* = quantize(f);
        const keep = @min(k, self.n);
        const top = try arena.alloc(Scored, keep);
        var have: usize = 0;
        const dim = self.dim;
        const scale: f32 = 1.0 / (127.0 * 127.0);
        for (0..self.n) |i| {
            const dp = dotI8(q8, self.data[i * dim ..][0..dim]);
            const score = @as(f32, @floatFromInt(dp)) * scale;
            if (have == keep and score <= top[have - 1].score) continue;
            // Insert into the sorted list of the best so far.
            var at = if (have < keep) have else keep - 1;
            while (at > 0 and top[at - 1].score < score) : (at -= 1) top[at] = top[at - 1];
            top[at] = .{ .id = self.ids[i], .score = score };
            if (have < keep) have += 1;
        }
        return top[0..have];
    }
};

fn quantize(f: f32) i8 {
    const v = std.math.clamp(f * 127.0, -127.0, 127.0);
    return @intFromFloat(@round(v));
}

fn dotI8(a: []const i8, b: []const i8) i32 {
    const lanes = 16;
    var acc: @Vector(lanes, i32) = @splat(0);
    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const va: @Vector(lanes, i8) = a[i..][0..lanes].*;
        const vb: @Vector(lanes, i8) = b[i..][0..lanes].*;
        acc += @as(@Vector(lanes, i32), va) * @as(@Vector(lanes, i32), vb);
    }
    var sum: i32 = @reduce(.Add, acc);
    while (i < a.len) : (i += 1) sum += @as(i32, a[i]) * @as(i32, b[i]);
    return sum;
}

/// Keeps one loaded `Index` current. A search takes a reference with `acquire` and gives it back with `release`;
/// a newer copy replaces the old one, which is freed when its last search is done.
pub const Holder = struct {
    gpa: Allocator,
    io: Io,
    path: [:0]const u8,
    model: []const u8,
    max_bytes: usize,
    check_every_s: i64 = 30,
    mutex: Io.Mutex = .init,
    current: ?*Entry = null,
    /// Size and time of `vectors.db` when it was loaded, and when it was last looked at (monotonic seconds).
    loaded_size: i64 = -1,
    loaded_mtime: i96 = 0,
    checked_at: i64 = -1_000_000,
    /// Why there is no index, for the status line.
    last_error: ?[]const u8 = null,

    const Entry = struct { index: Index, refs: u32 = 0, retired: bool = false };

    pub fn init(gpa: Allocator, io: Io, path: [:0]const u8, model: []const u8, max_bytes: usize) Holder {
        return .{ .gpa = gpa, .io = io, .path = path, .model = model, .max_bytes = max_bytes };
    }

    pub fn deinit(self: *Holder) void {
        if (self.current) |e| {
            e.index.deinit();
            self.gpa.destroy(e);
        }
    }

    fn nowS(self: *const Holder) i64 {
        return @intCast(@divFloor(Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_s));
    }

    /// The index for use, loaded or refreshed if the file changed; null if there are no vectors (or too many to
    /// hold). Call `release` when done.
    pub fn acquire(self: *Holder) ?*Index {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now = self.nowS();
        if (now - self.checked_at >= self.check_every_s) {
            self.checked_at = now;
            self.refreshLocked();
        }
        const e = self.current orelse return null;
        e.refs += 1;
        return &e.index;
    }

    pub fn release(self: *Holder, idx: *Index) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const e: *Entry = @fieldParentPtr("index", idx);
        e.refs -= 1;
        if (e.retired and e.refs == 0) {
            e.index.deinit();
            self.gpa.destroy(e);
        }
    }

    fn refreshLocked(self: *Holder) void {
        const st = Io.Dir.cwd().statFile(self.io, self.path, .{}) catch return;
        if (@as(i64, @intCast(st.size)) == self.loaded_size and st.mtime.nanoseconds == self.loaded_mtime and self.current != null) return;
        self.last_error = null;
        const loaded = Index.load(self.gpa, self.path, self.model, self.max_bytes) catch |e| {
            self.last_error = if (e == error.TooLarge) "the vectors need more memory than index_mb allows" else "the vectors could not be loaded";
            return;
        };
        self.loaded_size = @intCast(st.size);
        self.loaded_mtime = st.mtime.nanoseconds;
        const fresh = loaded orelse return;
        const entry = self.gpa.create(Entry) catch {
            var f = fresh;
            f.deinit();
            return;
        };
        entry.* = .{ .index = fresh };
        if (self.current) |old| {
            if (old.refs == 0) {
                old.index.deinit();
                self.gpa.destroy(old);
            } else old.retired = true;
        }
        self.current = entry;
    }
};

const testing = std.testing;
const embed = @import("embed.zig");

fn unit(a: Allocator, seed: u64, dim: usize) ![]f32 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const v = try a.alloc(f32, dim);
    var norm: f32 = 0;
    for (v) |*x| {
        x.* = r.floatNorm(f32);
        norm += x.* * x.*;
    }
    const inv = 1.0 / @sqrt(norm);
    for (v) |*x| x.* *= inv;
    return v;
}

fn idOf(n: u32) doc.Id {
    var id: doc.Id = @splat(0);
    std.mem.writeInt(u32, id[0..4], n, .little);
    return id;
}

test "the nearest vectors are found exactly enough: the right documents, in order, as a brute-force scan finds them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/vectors.db", .{tmp.sub_path}, 0);
    var store = try embed.Store.open(path);
    const dim = 48;
    const n = 300;
    const vecs = try a.alloc([]f32, n);
    for (vecs, 0..) |*v, i| {
        v.* = try unit(a, i + 1, dim);
        try store.put(idOf(@intCast(i)), "m", v.*);
    }
    try store.put(idOf(9999), "other", vecs[0]); // another model's vector is not in this index
    store.close();
    var idx = (try Index.load(testing.allocator, path, "m", 1 << 30)).?;
    defer idx.deinit();
    try testing.expectEqual(@as(usize, n), idx.n);
    try testing.expectEqual(@as(u32, dim), idx.dim);
    // Searching with a stored vector finds it first with a score near 1; the top ten match the exact order.
    const q = vecs[42];
    const got = try idx.search(a, q, 10);
    try testing.expectEqual(@as(usize, 10), got.len);
    try testing.expectEqualSlices(u8, &idOf(42), &got[0].id);
    try testing.expect(got[0].score > 0.98);
    for (got[1..], 0..) |g, i| try testing.expect(g.score <= got[i].score);
    const Pair = struct { i: usize, s: f32 };
    const exact = try a.alloc(Pair, n);
    for (vecs, exact, 0..) |v, *e, i| e.* = .{ .i = i, .s = embed.dot(q, v) };
    std.mem.sort(Pair, exact, {}, struct {
        fn less(_: void, x: Pair, y: Pair) bool {
            return x.s > y.s;
        }
    }.less);
    var agree: usize = 0;
    for (got) |g| for (exact[0..10]) |e| if (std.mem.eql(u8, &g.id, &idOf(@intCast(e.i)))) {
        agree += 1;
    };
    try testing.expect(agree >= 9); // quantization may swap two neighbours that are almost equal
    // Wrong dimension or nothing asked: nothing.
    try testing.expectEqual(@as(usize, 0), (try idx.search(a, q[0..10], 5)).len);
    try testing.expectEqual(@as(usize, 0), (try idx.search(a, q, 0)).len);
    try testing.expectEqual(@as(usize, 300), (try idx.search(a, q, 1000)).len); // fewer vectors than asked for
    // No vectors for a model, no file, or too large to hold.
    try testing.expect((try Index.load(testing.allocator, path, "nomodel", 1 << 30)) == null);
    try testing.expect((try Index.load(testing.allocator, "/nonexistent-dksearch/vectors.db", "m", 1 << 30)) == null);
    try testing.expectError(error.TooLarge, Index.load(testing.allocator, path, "m", 1000));
}

test "the holder loads on first use, picks up new vectors when the file changes, and old copies finish their searches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/vectors.db", .{tmp.sub_path}, 0);
    var h = Holder.init(testing.allocator, testing.io, path, "m", 1 << 30);
    defer h.deinit();
    h.check_every_s = 0;
    try testing.expect(h.acquire() == null); // no file yet
    var store = try embed.Store.open(path);
    try store.put(idOf(1), "m", &.{ 1.0, 0.0 });
    store.close();
    const first = h.acquire().?;
    try testing.expectEqual(@as(usize, 1), first.n);
    // More vectors arrive while a search still holds the first copy.
    var store2 = try embed.Store.open(path);
    try store2.put(idOf(2), "m", &.{ 0.0, 1.0 });
    try store2.put(idOf(3), "m", &.{ 0.6, 0.8 });
    store2.close();
    const second = h.acquire().?;
    try testing.expectEqual(@as(usize, 3), second.n);
    try testing.expectEqual(@as(usize, 1), first.n); // still valid for the search that has it
    h.release(first); // frees the old copy
    h.release(second);
}
