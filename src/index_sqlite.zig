//! SQLite FTS5 index backend (docs/decisions/0003-index-backend.md).
//!
//! One database file holds two tables:
//!   docs  one row per document: id and the metadata needed for filters and
//!         for displaying a hit.
//!   fts   the FTS5 table (title, body), keyed by `docs.rowid`.
//!
//! The file is derived data. If it is missing, corrupt, or from another
//! schema version, delete it and rebuild from the stores (rebuild.zig).
//!
//! Each `SqliteIndex` is one connection. SQLite serializes access, but a
//! single connection is still intended for one job at a time.
//!
//! Durability: WAL + synchronous=NORMAL (see `initSchema`). Because every
//! `add` is its own transaction, bulk imports should expect per-document
//! commit overhead; batching is a later optimization.
//!
//! Statements are prepared per call. That is simple and correct; caching
//! them is a later optimization once there are measurements.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");
const c = sqlite.c;
const doc = @import("document.zig");
const idx_api = @import("indexer.zig");
const search = @import("search.zig");

/// Bumped when the table layout changes. Stored in `PRAGMA user_version`.
pub const schema_version = 1;

/// Title matches count ten times as much as body matches.
const bm25_weights = "10.0, 1.0";

pub const Sync = enum {
    /// WAL with synchronous=NORMAL: syncs at checkpoints, not every commit.
    /// The default; see `SqliteIndex.initSchema`.
    normal,
    /// Sync on every commit. Slowest; rarely worth it for a rebuildable index.
    full,
    /// Never sync. Fastest; the file can be corrupted by a crash or power
    /// loss. For tests and throwaway indexes only.
    off,
};

/// How text is split into terms and normalised (docs/decisions/0013).
/// Both fold case and remove diacritics. `porter` also reduces English words
/// to their stems, so "running" matches "run"; it suits English text only.
pub const Tokenizer = enum {
    unicode61,
    porter,

    fn sql(self: Tokenizer) []const u8 {
        return switch (self) {
            .unicode61 => "unicode61 remove_diacritics 2",
            .porter => "porter unicode61 remove_diacritics 2",
        };
    }
};

pub const OpenOptions = struct {
    sync: Sync = .normal,
    /// Null keeps an existing index's tokenizer (and uses `unicode61` for a
    /// new one). A value must match the existing index, else
    /// `error.TokenizerMismatch` (unless `retokenize`).
    tokenizer: ?Tokenizer = null,
    /// Allow an existing index built with another tokenizer to be emptied and
    /// recreated with this one. Only `rebuild` sets this: the index is
    /// derived data, and it is refilled right after.
    retokenize: bool = false,
};

pub const OpenError = idx_api.Error || error{
    /// The file was written by an incompatible schema version. Delete it and
    /// rebuild.
    SchemaMismatch,
    /// The index was built with another tokenizer than the configuration
    /// asks for. Run `dksearch rebuild` to recreate it.
    TokenizerMismatch,
};

const Stmt = sqlite.Stmt;
const mapRc = sqlite.mapRc;

pub const SqliteIndex = struct {
    db: *c.sqlite3,

    /// Opens (creating if needed) the index at `path`; ":memory:" gives a
    /// throwaway index.
    pub fn open(path: [:0]const u8, options: OpenOptions) OpenError!SqliteIndex {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return mapRc(rc);
        }
        var self: SqliteIndex = .{ .db = db.? };
        errdefer self.close();
        try self.initSchema(options);
        return self;
    }

    pub fn close(self: *SqliteIndex) void {
        _ = c.sqlite3_close(self.db);
        self.* = undefined;
    }

    fn exec(self: SqliteIndex, sql: [:0]const u8) idx_api.Error!void {
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return mapRc(rc);
    }

    fn userVersion(self: SqliteIndex) idx_api.Error!i64 {
        const st = try Stmt.prepare(self.db, "PRAGMA user_version");
        defer st.deinit();
        if (!try st.step()) return error.Io;
        return st.colInt(0);
    }

    fn initSchema(self: SqliteIndex, options: OpenOptions) OpenError!void {
        // The index is rebuildable, so durability is traded for write speed:
        // WAL with synchronous=NORMAL syncs at checkpoints rather than on
        // every commit. After a power loss the last few commits may be lost
        // (re-import or rebuild restores them) but the file stays consistent.
        // WAL needs a local filesystem; for ":memory:" it is a no-op.
        try self.exec(switch (options.sync) {
            .normal => "PRAGMA synchronous = NORMAL; PRAGMA journal_mode = WAL;",
            .full => "PRAGMA synchronous = FULL; PRAGMA journal_mode = WAL;",
            .off => "PRAGMA synchronous = OFF; PRAGMA journal_mode = WAL;",
        });
        const v = try self.userVersion();
        if (v != 0 and v != schema_version) return error.SchemaMismatch;
        var tokenizer: Tokenizer = options.tokenizer orelse .unicode61;
        if (v != 0) {
            const have = (try self.existingTokenizer()) orelse tokenizer;
            if (options.tokenizer) |want| {
                if (have != want) {
                    if (!options.retokenize) return error.TokenizerMismatch;
                    try self.exec("DROP TABLE fts; DROP TABLE docs;");
                }
            } else tokenizer = have; // keep what the index has
        }
        const create = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(title, body, tokenize = '{s}');", .{tokenizer.sql()}, 0);
        defer std.heap.page_allocator.free(create);
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS docs(
            \\  rowid        INTEGER PRIMARY KEY,
            \\  id           BLOB NOT NULL UNIQUE,
            \\  connector    TEXT NOT NULL,
            \\  url          TEXT,
            \\  title        TEXT,
            \\  language     TEXT,
            \\  content_type TEXT,
            \\  published_at INTEGER
            \\);
            \\CREATE INDEX IF NOT EXISTS docs_language ON docs(language);
            \\CREATE INDEX IF NOT EXISTS docs_connector ON docs(connector);
        );
        try self.exec(create);
        if (v == 0) try self.exec("PRAGMA user_version = 1");
    }

    /// The tokenizer the existing `fts` table was created with, if any.
    fn existingTokenizer(self: SqliteIndex) idx_api.Error!?Tokenizer {
        const st = try Stmt.prepare(self.db, "SELECT sql FROM sqlite_master WHERE name = 'fts'");
        defer st.deinit();
        if (!try st.step()) return null;
        const text = st.colText(0) orelse return null;
        return if (std.mem.indexOf(u8, text, "porter") != null) .porter else .unicode61;
    }

    pub fn indexer(self: *SqliteIndex) idx_api.Indexer {
        return .{ .ptr = self, .vtable = &.{ .add = add, .remove = remove, .clear = clear, .check = check, .begin = batchBegin, .commit = batchCommit, .rollback = batchRollback } };
    }

    pub fn searcher(self: *SqliteIndex) search.Searcher {
        return .{ .ptr = self, .vtable = &.{ .search = searchImpl } };
    }

    /// Number of indexed documents.
    pub fn count(self: *SqliteIndex) idx_api.Error!u64 {
        const st = try Stmt.prepare(self.db, "SELECT count(*) FROM docs");
        defer st.deinit();
        if (!try st.step()) return error.Io;
        return @intCast(st.colInt(0));
    }

    // ------------------------------------------------------------ writes

    // Each operation is a SAVEPOINT, which is a plain transaction when used
    // alone and nests inside a batch opened with `batchBegin`.
    fn begin(self: *SqliteIndex) idx_api.Error!void {
        try self.exec("SAVEPOINT op");
    }
    fn commit(self: *SqliteIndex) idx_api.Error!void {
        try self.exec("RELEASE op");
    }
    fn rollback(self: *SqliteIndex) void {
        self.exec("ROLLBACK TO op; RELEASE op") catch {};
    }

    fn batchBegin(ptr: *anyopaque) idx_api.Error!void {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        try self.exec("BEGIN IMMEDIATE");
    }
    fn batchCommit(ptr: *anyopaque) idx_api.Error!void {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        try self.exec("COMMIT");
    }
    fn batchRollback(ptr: *anyopaque) idx_api.Error!void {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        try self.exec("ROLLBACK");
    }

    fn add(ptr: *anyopaque, id: doc.Id, d: doc.Document) idx_api.Error!void {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        try self.begin();
        errdefer self.rollback();

        const rowid = blk: {
            const st = try Stmt.prepare(self.db,
                \\INSERT INTO docs(id, connector, url, title, language, content_type, published_at)
                \\VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
                \\ON CONFLICT(id) DO UPDATE SET
                \\  connector = excluded.connector, url = excluded.url, title = excluded.title,
                \\  language = excluded.language, content_type = excluded.content_type,
                \\  published_at = excluded.published_at
                \\RETURNING rowid
            );
            defer st.deinit();
            try st.blob(1, &id);
            try st.text(2, d.connector);
            try st.text(3, d.canonical_url);
            try st.text(4, d.title);
            try st.text(5, d.language);
            try st.text(6, d.content_type);
            try st.int(7, d.published_at);
            if (!try st.step()) return error.Io;
            break :blk st.colInt(0);
        };

        {
            const st = try Stmt.prepare(self.db, "DELETE FROM fts WHERE rowid = ?1");
            defer st.deinit();
            try st.int(1, rowid);
            _ = try st.step();
        }
        {
            const st = try Stmt.prepare(self.db, "INSERT INTO fts(rowid, title, body) VALUES(?1, ?2, ?3)");
            defer st.deinit();
            try st.int(1, rowid);
            try st.text(2, d.title orelse "");
            // Records that only reference content are still findable by
            // their summary.
            try st.text(3, d.text orelse d.summary orelse "");
            _ = try st.step();
        }
        try self.commit();
    }

    fn remove(ptr: *anyopaque, id: doc.Id) idx_api.Error!void {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        try self.begin();
        errdefer self.rollback();
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM fts WHERE rowid = (SELECT rowid FROM docs WHERE id = ?1)");
            defer st.deinit();
            try st.blob(1, &id);
            _ = try st.step();
        }
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM docs WHERE id = ?1");
            defer st.deinit();
            try st.blob(1, &id);
            _ = try st.step();
        }
        try self.commit();
    }

    fn clear(ptr: *anyopaque) idx_api.Error!void {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        try self.begin();
        errdefer self.rollback();
        try self.exec("DELETE FROM fts; DELETE FROM docs;");
        try self.commit();
    }

    fn check(ptr: *anyopaque) idx_api.Error!void {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        // FTS5's own structural check; fails with a corruption code.
        try self.exec("INSERT INTO fts(fts) VALUES('integrity-check')");
        // Every document row must have exactly one FTS row, and vice versa.
        const st = try Stmt.prepare(self.db,
            \\SELECT (SELECT count(*) FROM docs) = (SELECT count(*) FROM fts)
            \\   AND NOT EXISTS (SELECT 1 FROM docs WHERE rowid NOT IN (SELECT rowid FROM fts))
        );
        defer st.deinit();
        if (!try st.step()) return error.Io;
        if (st.colInt(0) != 1) return error.Corrupt;
    }

    // ------------------------------------------------------------ search

    fn searchImpl(ptr: *anyopaque, arena: Allocator, q: search.Query) search.Error!search.Page {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));

        const limit: u32 = if (q.limit == 0) search.default_limit else q.limit;
        if (limit > search.max_limit) return error.InvalidQuery;
        if (@as(u64, q.offset) + limit > search.max_window) return error.InvalidQuery;

        const match = try buildMatch(arena, q.text);

        const st = Stmt.prepare(self.db,
            \\SELECT d.id, d.connector, d.url, d.title,
            \\       snippet(fts, 1, ?1, ?2, '…', 16),
            \\       -bm25(fts, 10.0, 1.0)
            \\FROM fts JOIN docs d ON d.rowid = fts.rowid
            \\WHERE fts MATCH ?3
            \\  AND (?4 IS NULL OR d.language = ?4)
            \\  AND (?5 IS NULL OR d.content_type = ?5)
            \\  AND (?6 IS NULL OR d.connector = ?6)
            \\ORDER BY bm25(fts, 10.0, 1.0), d.id
            \\LIMIT ?7 OFFSET ?8
        ) catch |e| return searchError(e);
        defer st.deinit();
        st.text(1, search.match_start) catch |e| return searchError(e);
        st.text(2, search.match_end) catch |e| return searchError(e);
        st.text(3, match) catch |e| return searchError(e);
        st.text(4, q.language) catch |e| return searchError(e);
        st.text(5, q.content_type) catch |e| return searchError(e);
        st.text(6, q.connector) catch |e| return searchError(e);
        // One extra row tells us whether another page follows.
        st.int(7, @as(i64, limit) + 1) catch |e| return searchError(e);
        st.int(8, q.offset) catch |e| return searchError(e);

        var hits: std.ArrayList(search.Hit) = .empty;
        var more = false;
        while (st.step() catch |e| return searchError(e)) {
            if (hits.items.len == limit) {
                more = true;
                break;
            }
            const idb = c.sqlite3_column_blob(st.s, 0) orelse return error.Io;
            if (c.sqlite3_column_bytes(st.s, 0) != @sizeOf(doc.Id)) return error.Io;
            var id: doc.Id = undefined;
            @memcpy(&id, @as([*]const u8, @ptrCast(idb))[0..@sizeOf(doc.Id)]);
            try hits.append(arena, .{
                .id = id,
                .connector = try arena.dupe(u8, st.colText(1) orelse ""),
                .url = try dupeOpt(arena, st.colText(2)),
                .title = try dupeOpt(arena, st.colText(3)),
                .snippet = try dupeOpt(arena, st.colText(4)),
                .score = st.colFloat(5),
            });
        }
        return .{ .hits = hits.items, .has_more = more };
    }
};

fn searchError(e: idx_api.Error) search.Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
}

fn dupeOpt(a: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (s) |x| try a.dupe(u8, x) else null;
}

/// Turns user text into an FTS5 MATCH expression in which every term is a
/// quoted string, so query operators, column filters and punctuation in the
/// input are literal text, never syntax. Words are ANDed; text inside double
/// quotes becomes one phrase. Terms with no letters or digits (pure
/// punctuation) are dropped because the tokenizer would discard them anyway.
fn buildMatch(arena: Allocator, text: []const u8) search.Error![]const u8 {
    if (text.len > search.max_query_bytes) return error.InvalidQuery;
    // A NUL would end the string early inside SQLite's C code.
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidQuery;
    var out: std.ArrayList(u8) = .empty;
    var terms: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
            continue;
        }
        var end: usize = undefined;
        var start: usize = undefined;
        if (ch == '"') {
            start = i + 1;
            end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse text.len;
            i = @min(end + 1, text.len);
        } else {
            start = i;
            end = i;
            while (end < text.len and !std.ascii.isWhitespace(text[end]) and text[end] != '"') end += 1;
            i = end;
        }
        const term = text[start..end];
        if (!hasWordChar(term)) continue;
        if (terms == 32) return error.InvalidQuery;
        if (terms > 0) try out.append(arena, ' ');
        try out.append(arena, '"');
        for (term) |b| {
            if (b == '"') try out.append(arena, '"'); // escape by doubling
            try out.append(arena, b);
        }
        try out.append(arena, '"');
        terms += 1;
    }
    if (terms == 0) return error.EmptyQuery;
    return out.items;
}

fn hasWordChar(s: []const u8) bool {
    for (s) |b| if (std.ascii.isAlphanumeric(b) or b >= 0x80) return true;
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn put(idx: *SqliteIndex, connector: []const u8, source_id: []const u8, title: ?[]const u8, text: []const u8) !doc.Id {
    const d: doc.Document = .{ .connector = connector, .source_id = source_id, .title = title, .text = text };
    try idx.indexer().add(d.id(), d);
    return d.id();
}

fn searchAll(arena: Allocator, idx: *SqliteIndex, text: []const u8) !search.Page {
    return idx.searcher().search(arena, .{ .text = text });
}

test "buildMatch quotes every term and neutralizes syntax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("\"hello\" \"world\"", try buildMatch(a, "  hello   world "));
    try testing.expectEqualStrings("\"hello world\" \"x\"", try buildMatch(a, "\"hello world\" x"));
    try testing.expectEqualStrings("\"title:foo\" \"OR\" \"bar*\"", try buildMatch(a, "title:foo OR bar*"));
    try testing.expectEqualStrings("\"unterminated phrase\"", try buildMatch(a, "\"unterminated phrase"));
    try testing.expectEqualStrings("\"café\"", try buildMatch(a, "café"));
    try testing.expectError(error.EmptyQuery, buildMatch(a, ""));
    try testing.expectError(error.InvalidQuery, buildMatch(a, "x\x00y"));
    try testing.expectError(error.EmptyQuery, buildMatch(a, " !!! ... \"\" "));
    const long = try a.alloc(u8, search.max_query_bytes + 1);
    @memset(long, 'a');
    try testing.expectError(error.InvalidQuery, buildMatch(a, long));
    try testing.expectError(error.InvalidQuery, buildMatch(a, "a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee ff gg"));
}

test "title matches outrank body matches; ties break by id" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const body_id = try put(&idx, "t", "body", "Something else", "a long text that mentions truth once");
    const title_id = try put(&idx, "t", "title", "The truth", "unrelated words here");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const page = try searchAll(arena.allocator(), &idx, "truth");
    try testing.expectEqual(@as(usize, 2), page.hits.len);
    try testing.expectEqual(title_id, page.hits[0].id);
    try testing.expectEqual(body_id, page.hits[1].id);
    try testing.expect(page.hits[0].score > page.hits[1].score);
    try testing.expect(!page.has_more);
}

test "re-adding an id replaces the old text; remove deletes" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const id = try put(&idx, "t", "1", "T", "alpha");
    _ = try put(&idx, "t", "1", "T", "beta");
    try testing.expectEqual(@as(u64, 1), try idx.count());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try searchAll(arena.allocator(), &idx, "alpha")).hits.len);
    try testing.expectEqual(@as(usize, 1), (try searchAll(arena.allocator(), &idx, "beta")).hits.len);

    try idx.indexer().remove(id);
    try idx.indexer().remove(id); // removing an absent id is fine
    try testing.expectEqual(@as(u64, 0), try idx.count());
    try testing.expectEqual(@as(usize, 0), (try searchAll(arena.allocator(), &idx, "beta")).hits.len);
    try idx.indexer().check();
}

test "phrase queries and snippets" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    _ = try put(&idx, "t", "1", "A", "it is a truth universally acknowledged");
    _ = try put(&idx, "t", "2", "B", "universally a truth is rare");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const page = try searchAll(arena.allocator(), &idx, "\"truth universally\"");
    try testing.expectEqual(@as(usize, 1), page.hits.len);
    try testing.expectEqualStrings("A", page.hits[0].title.?);
    const snip = page.hits[0].snippet.?;
    // FTS5 brackets the whole matched phrase, not each word.
    try testing.expect(std.mem.indexOf(u8, snip, search.match_start ++ "truth universally" ++ search.match_end) != null);
}

test "filters narrow results" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const en: doc.Document = .{ .connector = "wiki", .source_id = "1", .text = "shared term", .language = "en", .content_type = "text/html" };
    const de: doc.Document = .{ .connector = "gutenberg", .source_id = "2", .text = "shared term", .language = "de", .content_type = "text/plain" };
    try idx.indexer().add(en.id(), en);
    try idx.indexer().add(de.id(), de);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = idx.searcher();

    try testing.expectEqual(@as(usize, 2), (try s.search(arena.allocator(), .{ .text = "shared" })).hits.len);
    const by_lang = try s.search(arena.allocator(), .{ .text = "shared", .language = "de" });
    try testing.expectEqual(@as(usize, 1), by_lang.hits.len);
    try testing.expectEqualStrings("gutenberg", by_lang.hits[0].connector);
    try testing.expectEqual(@as(usize, 1), (try s.search(arena.allocator(), .{ .text = "shared", .connector = "wiki" })).hits.len);
    try testing.expectEqual(@as(usize, 1), (try s.search(arena.allocator(), .{ .text = "shared", .content_type = "text/plain" })).hits.len);
    try testing.expectEqual(@as(usize, 0), (try s.search(arena.allocator(), .{ .text = "shared", .language = "fr" })).hits.len);
}

test "pagination is stable and reports has_more" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    for (0..5) |n| {
        var sid: [8]u8 = undefined;
        const s = try std.fmt.bufPrint(&sid, "{d}", .{n});
        _ = try put(&idx, "t", s, null, "same words everywhere");
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = idx.searcher();

    const p1 = try s.search(arena.allocator(), .{ .text = "words", .limit = 2 });
    const p2 = try s.search(arena.allocator(), .{ .text = "words", .limit = 2, .offset = 2 });
    const p3 = try s.search(arena.allocator(), .{ .text = "words", .limit = 2, .offset = 4 });
    try testing.expectEqual(@as(usize, 2), p1.hits.len);
    try testing.expect(p1.has_more);
    try testing.expect(p2.has_more);
    try testing.expectEqual(@as(usize, 1), p3.hits.len);
    try testing.expect(!p3.has_more);

    // No overlaps or gaps; identical on repeat.
    var seen = std.AutoHashMap(doc.Id, void).init(testing.allocator);
    defer seen.deinit();
    for ([_]search.Page{ p1, p2, p3 }) |p| for (p.hits) |h| try seen.putNoClobber(h.id, {});
    try testing.expectEqual(@as(u32, 5), seen.count());
    const again = try s.search(arena.allocator(), .{ .text = "words", .limit = 2 });
    try testing.expectEqual(p1.hits[0].id, again.hits[0].id);
    try testing.expectEqual(p1.hits[1].id, again.hits[1].id);
}

test "hostile query text never errors or escapes into FTS syntax" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    _ = try put(&idx, "t", "1", "Title", "some body text with words");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = idx.searcher();

    const inputs = [_][]const u8{
        "foo\"bar",    "\"unterminated", "title:Title",            "NEAR(a b)",
        "a AND OR b",  "-negated",       "(((",                    "*",
        "body: ^text", "x\x00y",         "'; DROP TABLE docs; --", "\"\"\"",
        "\xff\xfe",
    };
    for (inputs) |in| {
        if (s.search(arena.allocator(), .{ .text = in })) |_| {} else |e| {
            // Rejecting is fine; failing inside the engine (Io) is not.
            try testing.expect(e == error.EmptyQuery or e == error.InvalidQuery);
        }
    }
    // The documents are still there and column syntax did not leak: "title:Title"
    // is searched as literal words, so it does not match via the title column.
    try testing.expectEqual(@as(u64, 1), try idx.count());
    try testing.expectEqual(@as(usize, 0), (try s.search(arena.allocator(), .{ .text = "title:Title" })).hits.len);
}

test "limit and window bounds" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = idx.searcher();
    try testing.expectError(error.InvalidQuery, s.search(arena.allocator(), .{ .text = "x", .limit = search.max_limit + 1 }));
    try testing.expectError(error.InvalidQuery, s.search(arena.allocator(), .{ .text = "x", .limit = 10, .offset = search.max_window }));
    try testing.expectError(error.EmptyQuery, s.search(arena.allocator(), .{ .text = "  " }));
}

test "clear and integrity check" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    _ = try put(&idx, "t", "1", "T", "alpha");
    try idx.indexer().check();
    try idx.indexer().clear();
    try testing.expectEqual(@as(u64, 0), try idx.count());
    try idx.indexer().check();
}

test "integrity check detects a document without an FTS row" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    _ = try put(&idx, "t", "1", "T", "alpha");
    try idx.exec("DELETE FROM fts");
    try testing.expectError(error.Corrupt, idx.indexer().check());
}

test "index persists across reopen; foreign schema versions are refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [256]u8 = undefined;
    const path = try std.mem.printSentinel(&pbuf, ".zig-cache/tmp/{s}/index.db", .{tmp.sub_path}, 0);

    {
        var idx = try SqliteIndex.open(path, .{ .sync = .off });
        defer idx.close();
        _ = try put(&idx, "t", "1", "Kept", "durable words");
    }
    {
        var idx = try SqliteIndex.open(path, .{ .sync = .off });
        defer idx.close();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const page = try searchAll(arena.allocator(), &idx, "durable");
        try testing.expectEqual(@as(usize, 1), page.hits.len);
        try testing.expectEqualStrings("Kept", page.hits[0].title.?);
        try idx.exec("PRAGMA user_version = 99");
    }
    try testing.expectError(error.SchemaMismatch, SqliteIndex.open(path, .{ .sync = .off }));
}

test "non-database file is reported as corrupt, not crashed on" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "junk.db", .data = "this is definitely not a sqlite database file........................." });
    var pbuf: [256]u8 = undefined;
    const path = try std.mem.printSentinel(&pbuf, ".zig-cache/tmp/{s}/junk.db", .{tmp.sub_path}, 0);
    try testing.expectError(error.Corrupt, SqliteIndex.open(path, .{ .sync = .off }));
}

test "porter tokenizer: stems English words; the default does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Tokenizer{ .unicode61, .porter }) |tk| {
        var idx = try SqliteIndex.open(":memory:", .{ .tokenizer = tk });
        defer idx.close();
        try idx.indexer().add(doc.idFromSource("t", "1"), .{ .connector = "t", .source_id = "1", .title = "Gardening", .text = "The keeper was running along the shores and watching lighthouses." });
        const run = try idx.searcher().search(a, .{ .text = "run" });
        const lighthouse = try idx.searcher().search(a, .{ .text = "lighthouse" });
        const watched = try idx.searcher().search(a, .{ .text = "watched" });
        const exact = try idx.searcher().search(a, .{ .text = "running" });
        try testing.expectEqual(@as(usize, 1), exact.hits.len);
        if (tk == .porter) {
            try testing.expectEqual(@as(usize, 1), run.hits.len);
            try testing.expectEqual(@as(usize, 1), lighthouse.hits.len);
            try testing.expectEqual(@as(usize, 1), watched.hits.len);
        } else {
            try testing.expectEqual(@as(usize, 0), run.hits.len);
            try testing.expectEqual(@as(usize, 0), lighthouse.hits.len);
            try testing.expectEqual(@as(usize, 0), watched.hits.len);
        }
    }
}

test "an index keeps its tokenizer; a different one is refused unless retokenizing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200:0]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pb, ".zig-cache/tmp/{s}/i.db", .{tmp.sub_path}, 0);
    {
        var idx = try SqliteIndex.open(path, .{ .tokenizer = .porter, .sync = .off });
        defer idx.close();
        try idx.indexer().add(doc.idFromSource("t", "1"), .{ .connector = "t", .source_id = "1", .text = "running" });
    }
    try testing.expectError(error.TokenizerMismatch, SqliteIndex.open(path, .{ .tokenizer = .unicode61, .sync = .off }));
    {
        // Without an opinion, the existing tokenizer is kept.
        var idx = try SqliteIndex.open(path, .{ .sync = .off });
        defer idx.close();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try testing.expectEqual(@as(usize, 1), (try idx.searcher().search(arena.allocator(), .{ .text = "run" })).hits.len);
    }
    {
        // Retokenizing empties the index; the caller refills it.
        var idx = try SqliteIndex.open(path, .{ .tokenizer = .unicode61, .retokenize = true, .sync = .off });
        defer idx.close();
        try testing.expectEqual(@as(u64, 0), try idx.count());
        try idx.indexer().add(doc.idFromSource("t", "1"), .{ .connector = "t", .source_id = "1", .text = "running" });
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try testing.expectEqual(@as(usize, 0), (try idx.searcher().search(arena.allocator(), .{ .text = "run" })).hits.len);
    }
    try testing.expectError(error.TokenizerMismatch, SqliteIndex.open(path, .{ .tokenizer = .porter, .sync = .off }));
}
