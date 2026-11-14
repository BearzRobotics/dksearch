//! Retained document text in a SQLite database (`content.db`).
//!
//! This is source-of-truth data (docs/decisions/0006-persistent-storage.md):
//! the search index is rebuilt from it. Each text is stored deflate-compressed
//! (zlib container, which carries its own checksum) together with its SHA-256
//! and uncompressed size. A read re-checks all three, so damaged content is
//! reported as `Corrupt` instead of being indexed.
//!
//! One statement per operation, so each put/delete is atomic on its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Io = std.Io;
const sqlite = @import("sqlite.zig");
const c = sqlite.c;
const Stmt = sqlite.Stmt;
const doc = @import("document.zig");
const storage = @import("storage.zig");

/// Texts larger than this are refused rather than compressed in memory.
pub const max_text_bytes = 1 << 30;

const migrations = [_][:0]const u8{
    \\CREATE TABLE content(
    \\  id   BLOB PRIMARY KEY,
    \\  hash BLOB NOT NULL,
    \\  size INTEGER NOT NULL,
    \\  data BLOB NOT NULL
    \\) WITHOUT ROWID;
};

pub const OpenError = sqlite.MigrateError;

pub const SqliteContentStore = struct {
    gpa: Allocator,
    db: *c.sqlite3,

    /// `path` may be ":memory:". Durability is the same trade-off as the index
    /// (WAL, synchronous=NORMAL) unless `sync_off` is set, which is for tests.
    pub fn open(gpa: Allocator, path: [:0]const u8, sync_off: bool) OpenError!SqliteContentStore {
        const db = try sqlite.open(path);
        errdefer _ = c.sqlite3_close(db);
        // Source of truth: keep the default of syncing on commit (FULL) unless
        // asked otherwise, in WAL mode so readers never block the writer.
        try sqlite.execSql(db, if (sync_off)
            "PRAGMA synchronous = OFF; PRAGMA journal_mode = WAL;"
        else
            "PRAGMA synchronous = FULL; PRAGMA journal_mode = WAL;");
        try sqlite.migrate(db, path, &migrations);
        return .{ .gpa = gpa, .db = db };
    }

    pub fn close(self: *SqliteContentStore) void {
        _ = c.sqlite3_close(self.db);
        self.* = undefined;
    }

    pub fn store(self: *SqliteContentStore) storage.ContentStore {
        return .{ .ptr = self, .vtable = &.{ .put = put, .get = get, .delete = delete } };
    }

    pub fn count(self: *SqliteContentStore) sqlite.Error!u64 {
        const st = try Stmt.prepare(self.db, "SELECT count(*) FROM content");
        defer st.deinit();
        if (!try st.step()) return error.Io;
        return @intCast(st.colInt(0));
    }

    fn put(ptr: *anyopaque, id: doc.Id, bytes: []const u8) storage.Error!void {
        const self: *SqliteContentStore = @ptrCast(@alignCast(ptr));
        if (bytes.len > max_text_bytes) return error.NoSpace;
        const packed_bytes = try compress(self.gpa, bytes);
        defer self.gpa.free(packed_bytes);
        const hash = doc.hashContent(bytes);

        const st = try Stmt.prepare(self.db,
            \\INSERT INTO content(id, hash, size, data) VALUES(?1, ?2, ?3, ?4)
            \\ON CONFLICT(id) DO UPDATE SET hash = excluded.hash, size = excluded.size, data = excluded.data
        );
        defer st.deinit();
        try st.blob(1, &id);
        try st.blob(2, &hash);
        try st.int(3, @intCast(bytes.len));
        try st.blob(4, packed_bytes);
        _ = try st.step();
    }

    fn get(ptr: *anyopaque, gpa: Allocator, id: doc.Id) storage.Error![]u8 {
        const self: *SqliteContentStore = @ptrCast(@alignCast(ptr));
        const st = try Stmt.prepare(self.db, "SELECT hash, size, data FROM content WHERE id = ?1");
        defer st.deinit();
        try st.blob(1, &id);
        if (!try st.step()) return error.NotFound;

        const stored_hash = st.colBlob(0) orelse return error.Corrupt;
        const size_i = st.colInt(1);
        const data = st.colBlob(2) orelse return error.Corrupt;
        if (stored_hash.len != @sizeOf(doc.ContentHash) or size_i < 0 or size_i > max_text_bytes) return error.Corrupt;

        const text = decompress(gpa, data, @intCast(size_i)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Corrupt => return error.Corrupt,
        };
        errdefer gpa.free(text);
        const actual = doc.hashContent(text);
        if (!std.mem.eql(u8, &actual, stored_hash)) return error.Corrupt;
        return text;
    }

    fn delete(ptr: *anyopaque, id: doc.Id) storage.Error!void {
        const self: *SqliteContentStore = @ptrCast(@alignCast(ptr));
        const st = try Stmt.prepare(self.db, "DELETE FROM content WHERE id = ?1");
        defer st.deinit();
        try st.blob(1, &id);
        _ = try st.step();
    }
};

fn compress(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    // `Compress` is large (hundreds of KiB of tables), so it lives on the heap.
    const comp = try gpa.create(flate.Compress);
    defer gpa.destroy(comp);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    var aw = try Io.Writer.Allocating.initCapacity(gpa, bytes.len / 2 + 64);
    errdefer aw.deinit();
    comp.* = flate.Compress.init(&aw.writer, window, .zlib, .default) catch return error.OutOfMemory;
    comp.writer.writeAll(bytes) catch return error.OutOfMemory;
    comp.finish() catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn decompress(gpa: Allocator, data: []const u8, expected_size: usize) error{ OutOfMemory, Corrupt }![]u8 {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var in: Io.Reader = .fixed(data);
    var d = flate.Decompress.init(&in, .zlib, window);
    // The recorded size bounds the output, so a damaged or hostile stream
    // cannot make us allocate without limit.
    const out = d.reader.allocRemaining(gpa, .limited(expected_size + 1)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    errdefer gpa.free(out);
    if (out.len != expected_size) return error.Corrupt;
    return out;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "round trip, replace, delete" {
    var s = try SqliteContentStore.open(testing.allocator, ":memory:", true);
    defer s.close();
    const cs = s.store();
    const id = doc.idFromSource("c", "1");

    try testing.expectError(error.NotFound, cs.get(testing.allocator, id));
    try cs.put(id, "first version");
    try cs.put(id, "second version, longer");
    try testing.expectEqual(@as(u64, 1), try s.count());
    const got = try cs.get(testing.allocator, id);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("second version, longer", got);

    try cs.delete(id);
    try cs.delete(id);
    try testing.expectError(error.NotFound, cs.get(testing.allocator, id));
}

test "empty, large and non-ASCII texts survive intact, and compress" {
    var s = try SqliteContentStore.open(testing.allocator, ":memory:", true);
    defer s.close();
    const cs = s.store();

    const big = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = "the quick brown fox "[i % 20];

    const cases = [_]struct { sid: []const u8, text: []const u8 }{
        .{ .sid = "empty", .text = "" },
        .{ .sid = "utf8", .text = "Café — 日本語 — ΑΒΓ" },
        .{ .sid = "big", .text = big },
    };
    for (cases) |cse| {
        const id = doc.idFromSource("c", cse.sid);
        try cs.put(id, cse.text);
        const got = try cs.get(testing.allocator, id);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, cse.text, got);
    }

    // Repetitive text must actually shrink.
    const st = try Stmt.prepare(s.db, "SELECT length(data) FROM content WHERE id = ?1");
    defer st.deinit();
    try st.blob(1, &doc.idFromSource("c", "big"));
    try testing.expect(try st.step());
    try testing.expect(st.colInt(0) < big.len / 10);
}

test "incompressible data round-trips too" {
    var s = try SqliteContentStore.open(testing.allocator, ":memory:", true);
    defer s.close();
    var prng = std.Random.DefaultPrng.init(42);
    var noise: [100_000]u8 = undefined;
    prng.random().bytes(&noise);
    const id = doc.idFromSource("c", "noise");
    try s.store().put(id, &noise);
    const got = try s.store().get(testing.allocator, id);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &noise, got);
}

test "damaged content is reported as Corrupt, not returned" {
    var s = try SqliteContentStore.open(testing.allocator, ":memory:", true);
    defer s.close();
    const cs = s.store();
    const id = doc.idFromSource("c", "1");
    try cs.put(id, "some reasonably long text so there are bytes to damage, and then some more text to damage as well, plus a third sentence");

    // Flip one byte of the stored stream.
    try sqlite.execSql(s.db, "UPDATE content SET data = substr(data, 1, 10) || x'ff' || substr(data, 12)");
    try testing.expectError(error.Corrupt, cs.get(testing.allocator, id));

    // A stream that is intact but whose recorded hash does not match.
    try cs.put(id, "intact text");
    try sqlite.execSql(s.db, "UPDATE content SET hash = zeroblob(32)");
    try testing.expectError(error.Corrupt, cs.get(testing.allocator, id));

    // A wrong recorded size must not cause an unbounded allocation or a wrong answer.
    try cs.put(id, "intact text");
    try sqlite.execSql(s.db, "UPDATE content SET size = 3");
    try testing.expectError(error.Corrupt, cs.get(testing.allocator, id));
    try sqlite.execSql(s.db, "UPDATE content SET size = 999999");
    try testing.expectError(error.Corrupt, cs.get(testing.allocator, id));
}

test "content persists across reopen and refuses a newer schema" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pb, ".zig-cache/tmp/{s}/content.db", .{tmp.sub_path}, 0);
    const id = doc.idFromSource("c", "kept");
    {
        var s = try SqliteContentStore.open(testing.allocator, path, true);
        defer s.close();
        try s.store().put(id, "durable text");
    }
    {
        var s = try SqliteContentStore.open(testing.allocator, path, true);
        defer s.close();
        const got = try s.store().get(testing.allocator, id);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("durable text", got);
        try sqlite.execSql(s.db, "PRAGMA user_version = 99");
    }
    try testing.expectError(error.NewerSchema, SqliteContentStore.open(testing.allocator, path, true));
}

test "a ContentStore feeds the rebuild path just like the memory one" {
    const rebuild = @import("rebuild.zig");
    const memory = @import("memory.zig");
    const index_sqlite = @import("index_sqlite.zig");
    const pipeline = @import("pipeline.zig");

    var content = try SqliteContentStore.open(testing.allocator, ":memory:", true);
    defer content.close();
    var docs = memory.MemoryDocumentStore.init(testing.allocator);
    defer docs.deinit();
    var live = try index_sqlite.SqliteIndex.open(":memory:", .{});
    defer live.close();

    const Now = struct {
        fn f() doc.Timestamp {
            return 1;
        }
    };
    var pipe = pipeline.Pipeline.init(content.store(), docs.store(), live.indexer(), .{ .now = Now.f });
    try pipe.submit(.{ .connector = "g", .source_id = "1", .title = "Moby Dick", .text = "Call me Ishmael." });

    var fresh = try index_sqlite.SqliteIndex.open(":memory:", .{});
    defer fresh.close();
    const stats = try rebuild.rebuild(testing.allocator, fresh.indexer(), content.store(), docs.store());
    try testing.expectEqual(@as(u64, 1), stats.reindexed);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const page = try fresh.searcher().search(arena.allocator(), .{ .text = "ishmael" });
    try testing.expectEqual(@as(usize, 1), page.hits.len);
}
