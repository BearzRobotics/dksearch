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
const Io = std.Io;
const idx_api = @import("indexer.zig");
const search = @import("search.zig");
const image_mod = @import("image.zig");
const queryparse = @import("queryparse.zig");
const lexicon_mod = @import("lexicon.zig");
const retrieve = @import("retrieve.zig");
const editdistance = @import("editdistance.zig");
const docmeta = @import("docmeta.zig");
const derive = docmeta.derive;

/// Most tags and custom fields kept per document.
const max_meta_fields = 32;
/// Most conditions in one search.
const max_filters = 16;

/// Bumped when the table layout changes. Stored in `PRAGMA user_version`.
pub const schema_version = 1;

/// In `auto` mode, an exact search with fewer hits than this is repeated with
/// typo tolerance (and the fuller result is used if it finds more).
const auto_fuzzy_below = 3;

/// When plain words also match words one typo away.
pub const FuzzyMode = enum {
    /// Never, unless the person writes `word~`.
    off,
    /// Only when the exact words find nothing.
    auto,
    /// Always.
    always,
};

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
    /// Documents with at least this many bytes of text also get their passages indexed, for retrieval inside large
    /// documents (`search.chunk_index_min_kb`). 0 turns it off.
    chunk_min_bytes: u32 = 64 * 1024,
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
    /// True: the query language is off and every word is plain text (`[search] query_syntax = "simple"`).
    simple_syntax: bool = false,
    /// Typo tolerance when a search does not say. Off for a bare index, so that
    /// code using the index directly gets exact words; `serve` sets it from
    /// `[search] fuzzy` (default `auto`).
    fuzzy_mode: FuzzyMode = .off,
    /// How much a match in the title counts against one in the body when ranking
    /// (`[search] title_weight`, `body_weight`).
    title_weight: u32 = 10,
    body_weight: u32 = 1,
    /// Newer documents rank higher by up to this many percent (0 = off); the boost halves for every
    /// `recency_days` of age (`[search] recency_boost`, `recency_half_life_days`).
    recency_percent: u32 = 0,
    recency_days: u32 = 365,
    /// Stop words and synonyms applied to searches (must outlive the index); null for none.
    lexicon: ?*const lexicon_mod.Lexicon = null,
    /// What is left of the search's time limit for its second attempt (the typo-tolerant repeat), so that
    /// the two together never exceed the limit.
    retry_budget_ms: ?u32 = null,
    /// See `OpenOptions.chunk_min_bytes`.
    chunk_min_bytes: u32 = 0,
    /// A time limit for each search, if set (`setQueryTimeout`).
    timeout: ?struct { io: Io, ms: u32 } = null,
    /// True if the `docs` table has the metadata columns filters use (an index
    /// made before they existed gets them on its next writable open).
    has_meta: bool = false,
    /// True if the vocabulary table exists (typo tolerance then uses the words that are really in the index).
    has_vocab: bool = false,

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
        registerFunctions(self.db);
        try self.initSchema(options);
        self.has_meta = self.detectMeta();
        self.has_vocab = self.detectVocab();
        self.chunk_min_bytes = options.chunk_min_bytes;
        return self;
    }

    pub fn close(self: *SqliteIndex) void {
        _ = c.sqlite3_close(self.db);
        self.* = undefined;
    }

    /// Limits each search to `ms` milliseconds (0 = no limit): SQLite is told to
    /// stop, and the search fails with `error.Timeout`. Set it before sharing
    /// the index between threads.
    /// Turns the query language off (`simple`) or on; set it before sharing the index.
    pub fn setSimpleSyntax(self: *SqliteIndex, simple: bool) void {
        self.simple_syntax = simple;
    }

    pub fn setFuzzyMode(self: *SqliteIndex, mode: FuzzyMode) void {
        self.fuzzy_mode = mode;
    }

    pub fn setWeights(self: *SqliteIndex, title: u32, body: u32) void {
        self.title_weight = title;
        self.body_weight = body;
    }

    pub fn setLexicon(self: *SqliteIndex, l: ?*const lexicon_mod.Lexicon) void {
        self.lexicon = l;
    }

    pub fn setRecency(self: *SqliteIndex, percent: u32, half_life_days: u32) void {
        self.recency_percent = percent;
        self.recency_days = @max(half_life_days, 1);
    }

    pub fn setQueryTimeout(self: *SqliteIndex, io: Io, ms: u32) void {
        self.timeout = if (ms == 0) null else .{ .io = io, .ms = ms };
    }

    /// Opens an existing index for searching only: read-only, nothing is
    /// created or changed. Used by `SearchPool`.
    pub fn openReadOnly(path: [:0]const u8) OpenError!SqliteIndex {
        const db = sqlite.openReadOnly(path) catch |e| return e;
        var self: SqliteIndex = .{ .db = db };
        errdefer self.close();
        try self.exec("PRAGMA query_only = 1;");
        registerFunctions(db);
        self.has_meta = self.detectMeta();
        self.has_vocab = self.detectVocab();
        return self;
    }

    /// SQL functions the queries use: `dk_hamming(a, b)`, the number of differing bits.
    fn registerFunctions(db: *c.sqlite3) void {
        _ = c.sqlite3_create_function(db, "dk_hamming", 2, c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC, null, hammingFn, null, null);
        _ = c.sqlite3_create_function(db, "dk_edits", 3, c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC, null, editsFn, null, null);
    }

    /// `dk_edits(a, b, limit)`: the edit distance of two words if at most `limit`, else NULL.
    fn editsFn(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
        _ = argc;
        const pa = c.sqlite3_value_text(argv[0]);
        const pb = c.sqlite3_value_text(argv[1]);
        if (pa == null or pb == null) return c.sqlite3_result_null(ctx);
        const a = pa[0..@intCast(c.sqlite3_value_bytes(argv[0]))];
        const b = pb[0..@intCast(c.sqlite3_value_bytes(argv[1]))];
        const limit: u8 = @intCast(std.math.clamp(c.sqlite3_value_int(argv[2]), 0, 3));
        if (editdistance.within(a, b, limit)) |d| c.sqlite3_result_int(ctx, d) else c.sqlite3_result_null(ctx);
    }

    fn hammingFn(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
        _ = argc;
        const a: u64 = @bitCast(c.sqlite3_value_int64(argv[0]));
        const b: u64 = @bitCast(c.sqlite3_value_int64(argv[1]));
        c.sqlite3_result_int(ctx, @popCount(a ^ b));
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
                    try self.exec("DROP TABLE IF EXISTS fts_vocab; DROP TABLE fts; DROP TABLE docs; DROP TABLE IF EXISTS doc_meta; DROP TABLE IF EXISTS chunks_fts; DROP TABLE IF EXISTS chunk_map;");
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
        // The index's words with their document counts, for typo tolerance (see `expandWord`).
        try self.exec("CREATE VIRTUAL TABLE IF NOT EXISTS fts_vocab USING fts5vocab(fts, 'row');");
        // The passages of large documents: a contentless full-text index (the text is read back from the stored
        // document and re-chunked) and the map from its rows to documents. Created if missing; derived data like
        // the rest, refilled by `rebuild`.
        const create_chunks = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(heading, body, content = '', contentless_delete = 1, tokenize = '{s}');", .{tokenizer.sql()}, 0);
        defer std.heap.page_allocator.free(create_chunks);
        try self.exec(create_chunks);
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS chunk_map(
            \\  rowid INTEGER PRIMARY KEY,
            \\  doc   INTEGER NOT NULL,
            \\  idx   INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS chunk_map_doc ON chunk_map(doc);
        );
        try self.migrateMeta();
        // Perceptual hashes of pictures, for search by image. Created if missing
        // (older indexes get it on their next write); it never changes the schema version.
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS image_hash(
            \\  id   BLOB PRIMARY KEY,
            \\  hash INTEGER NOT NULL
            \\) WITHOUT ROWID;
        );
        if (v == 0) try self.exec("PRAGMA user_version = 1");
    }

    fn detectVocab(self: SqliteIndex) bool {
        const st = Stmt.prepare(self.db, "SELECT 1 FROM sqlite_master WHERE name = 'fts_vocab'") catch return false;
        defer st.deinit();
        return st.step() catch false;
    }

    fn detectMeta(self: SqliteIndex) bool {
        return self.hasColumn("domain");
    }

    fn hasColumn(self: SqliteIndex, name: []const u8) bool {
        const st = Stmt.prepare(self.db, "SELECT 1 FROM pragma_table_info('docs') WHERE name = ?1") catch return false;
        defer st.deinit();
        st.text(1, name) catch return false;
        return st.step() catch false;
    }

    /// Adds what filters need to an index made without it: columns for the
    /// dates, size, author, kind, extension, host and path, and a table of
    /// tags and custom fields. Existing documents keep empty values until they
    /// are indexed again (`rebuild`, or the next import that changes them).
    fn migrateMeta(self: SqliteIndex) OpenError!void {
        const columns = [_][]const u8{
            "modified_at INTEGER", "indexed_at INTEGER", "author TEXT", "size INTEGER",
            "ext TEXT",            "domain TEXT",        "path TEXT",   "kind TEXT",
        };
        for (columns) |col| {
            const name = col[0..std.mem.indexOfScalar(u8, col, ' ').?];
            if (self.hasColumn(name)) continue;
            var buf: [96]u8 = undefined;
            const sql = std.fmt.bufPrint(&buf, "ALTER TABLE docs ADD COLUMN {s}\x00", .{col}) catch unreachable;
            try self.exec(sql[0 .. sql.len - 1 :0]);
        }
        try self.exec(
            \\CREATE INDEX IF NOT EXISTS docs_domain ON docs(domain);
            \\CREATE INDEX IF NOT EXISTS docs_ext ON docs(ext);
            \\CREATE INDEX IF NOT EXISTS docs_kind ON docs(kind);
            \\CREATE INDEX IF NOT EXISTS docs_modified ON docs(modified_at);
            \\CREATE TABLE IF NOT EXISTS doc_meta(
            \\  doc   INTEGER NOT NULL,
            \\  key   TEXT NOT NULL,
            \\  value TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS doc_meta_doc ON doc_meta(doc);
            \\CREATE INDEX IF NOT EXISTS doc_meta_kv ON doc_meta(key, value);
        );
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
        return .{ .ptr = self, .vtable = &.{ .search = searchImpl, .info = infoImpl, .search_chunks = searchChunksImpl, .source_stats = sourceStatsImpl, .words = wordsImpl, .doc_freq = docFreqImpl, .export_page = exportPageImpl } };
    }

    pub fn imageSearcher(self: *SqliteIndex) search.ImageSearcher {
        return .{ .ptr = self, .vtable = &.{ .near = nearImpl } };
    }

    /// Pictures whose hash is within `max_distance` bits of `hash`, nearest first.
    /// An index with no hashes (or an older one without the table) has none.
    pub fn nearImpl(ptr: *anyopaque, arena: Allocator, hash: u64, max_distance: u8, limit: u32) search.Error!search.ImagePage {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        if (limit == 0 or limit > search.max_limit) return error.InvalidQuery;
        const st = Stmt.prepare(self.db,
            \\SELECT d.id, d.connector, d.url, d.title, dk_hamming(i.hash, ?1) AS dist
            \\FROM image_hash i JOIN docs d ON d.id = i.id
            \\WHERE dist <= ?2
            \\ORDER BY dist, d.id
            \\LIMIT ?3
        ) catch return .{ .hits = &.{} };
        defer st.deinit();
        st.int(1, @bitCast(hash)) catch |e| return searchError(e);
        st.int(2, max_distance) catch |e| return searchError(e);
        st.int(3, limit) catch |e| return searchError(e);
        var deadline: Deadline = undefined;
        if (self.timeout) |t| {
            deadline = .{ .io = t.io, .deadline_ns = Io.Timestamp.now(t.io, .awake).nanoseconds + @as(i96, t.ms) * std.time.ns_per_ms };
            c.sqlite3_progress_handler(self.db, 2000, progressCallback, &deadline);
        } else deadline = .{ .io = undefined, .deadline_ns = 0 };
        defer if (self.timeout != null) c.sqlite3_progress_handler(self.db, 0, null, null);

        var hits: std.ArrayList(search.ImageHit) = .empty;
        while (st.step() catch |e| return if (deadline.fired) error.Timeout else searchError(e)) {
            const idb = c.sqlite3_column_blob(st.s, 0) orelse return error.Io;
            if (c.sqlite3_column_bytes(st.s, 0) != @sizeOf(doc.Id)) return error.Io;
            var id: doc.Id = undefined;
            @memcpy(&id, @as([*]const u8, @ptrCast(idb))[0..@sizeOf(doc.Id)]);
            try hits.append(arena, .{
                .id = id,
                .connector = try arena.dupe(u8, st.colText(1) orelse ""),
                .url = try dupeOpt(arena, st.colText(2)),
                .title = try dupeOpt(arena, st.colText(3)),
                .distance = @intCast(st.colInt(4)),
            });
        }
        return .{ .hits = hits.items };
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
                \\INSERT INTO docs(id, connector, url, title, language, content_type, published_at,
                \\                 modified_at, indexed_at, author, size, ext, domain, path, kind)
                \\VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
                \\ON CONFLICT(id) DO UPDATE SET
                \\  connector = excluded.connector, url = excluded.url, title = excluded.title,
                \\  language = excluded.language, content_type = excluded.content_type,
                \\  published_at = excluded.published_at, modified_at = excluded.modified_at,
                \\  indexed_at = excluded.indexed_at, author = excluded.author, size = excluded.size,
                \\  ext = excluded.ext, domain = excluded.domain, path = excluded.path, kind = excluded.kind
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
            const derived = derive(d);
            try st.int(8, d.modified_at);
            try st.int(9, d.acquired_at);
            try st.text(10, d.author);
            try st.int(11, derived.size);
            try st.text(12, derived.ext());
            try st.text(13, derived.host());
            try st.text(14, derived.path);
            try st.text(15, derived.kind);
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
        // Tags and custom fields (every extra but the picture hash), replacing any earlier ones.
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM doc_meta WHERE doc = ?1");
            defer st.deinit();
            try st.int(1, rowid);
            _ = try st.step();
        }
        var stored: usize = 0;
        for (d.extra) |e| {
            if (std.mem.eql(u8, e.key, "phash") or std.mem.eql(u8, e.key, "file_size")) continue;
            if (stored >= max_meta_fields or e.key.len == 0 or e.key.len > 32 or e.value.len == 0 or e.value.len > 256) continue;
            const st = try Stmt.prepare(self.db, "INSERT INTO doc_meta(doc, key, value) VALUES(?1, lower(?2), ?3)");
            defer st.deinit();
            try st.int(1, rowid);
            try st.text(2, e.key);
            try st.text(3, e.value);
            _ = try st.step();
            stored += 1;
        }
        try self.indexChunks(rowid, d.text);
        // A picture's perceptual hash (extra "phash", 16 hex digits), replacing
        // any earlier one; a document without it has none.
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM image_hash WHERE id = ?1");
            defer st.deinit();
            try st.blob(1, &id);
            _ = try st.step();
        }
        for (d.extra) |e| if (std.mem.eql(u8, e.key, "phash")) {
            if (image_mod.fromHex(e.value)) |h| {
                const st = try Stmt.prepare(self.db, "INSERT INTO image_hash(id, hash) VALUES(?1, ?2)");
                defer st.deinit();
                try st.blob(1, &id);
                try st.int(2, @bitCast(h));
                _ = try st.step();
            }
            break;
        };
        try self.commit();
    }

    /// Replaces the passage index of document `rowid`: its old passages go, and a large text gets new ones.
    fn indexChunks(self: *SqliteIndex, rowid: i64, text: ?[]const u8) idx_api.Error!void {
        try self.dropChunks(rowid);
        const t = text orelse return;
        if (self.chunk_min_bytes == 0 or t.len < self.chunk_min_bytes) return;
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const cs = retrieve.chunk(arena, t, retrieve.index_chunk_options) catch return error.OutOfMemory;
        const max_chunks = 20000;
        for (cs[0..@min(cs.len, max_chunks)]) |ch| {
            const map = try Stmt.prepare(self.db, "INSERT INTO chunk_map(doc, idx) VALUES(?1, ?2) RETURNING rowid");
            defer map.deinit();
            try map.int(1, rowid);
            try map.int(2, ch.index);
            if (!try map.step()) return error.Io;
            const row = map.colInt(0);
            const st = try Stmt.prepare(self.db, "INSERT INTO chunks_fts(rowid, heading, body) VALUES(?1, ?2, ?3)");
            defer st.deinit();
            try st.int(1, row);
            const heading = std.mem.join(arena, " / ", ch.heading) catch return error.OutOfMemory;
            try st.text(2, heading);
            try st.text(3, ch.text);
            _ = try st.step();
        }
    }

    fn dropChunks(self: *SqliteIndex, rowid: i64) idx_api.Error!void {
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM chunks_fts WHERE rowid IN (SELECT rowid FROM chunk_map WHERE doc = ?1)");
            defer st.deinit();
            try st.int(1, rowid);
            _ = try st.step();
        }
        const st = try Stmt.prepare(self.db, "DELETE FROM chunk_map WHERE doc = ?1");
        defer st.deinit();
        try st.int(1, rowid);
        _ = try st.step();
    }

    fn remove(ptr: *anyopaque, id: doc.Id) idx_api.Error!void {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        try self.begin();
        errdefer self.rollback();
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM chunks_fts WHERE rowid IN (SELECT rowid FROM chunk_map WHERE doc = (SELECT rowid FROM docs WHERE id = ?1))");
            defer st.deinit();
            try st.blob(1, &id);
            _ = try st.step();
        }
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM chunk_map WHERE doc = (SELECT rowid FROM docs WHERE id = ?1)");
            defer st.deinit();
            try st.blob(1, &id);
            _ = try st.step();
        }
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM fts WHERE rowid = (SELECT rowid FROM docs WHERE id = ?1)");
            defer st.deinit();
            try st.blob(1, &id);
            _ = try st.step();
        }
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM doc_meta WHERE doc = (SELECT rowid FROM docs WHERE id = ?1)");
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
        {
            const st = try Stmt.prepare(self.db, "DELETE FROM image_hash WHERE id = ?1");
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
        try self.exec("DELETE FROM fts; DELETE FROM docs; DELETE FROM image_hash; DELETE FROM doc_meta; DELETE FROM chunks_fts; DELETE FROM chunk_map;");
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

    /// What the index records about one document.
    pub fn exportPageImpl(ptr: *anyopaque, arena: Allocator, connector: []const u8, after: i64, limit: u32) search.Error![]const search.ExportRow {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        const sql = if (self.has_meta)
            "SELECT rowid, id, url, title, language, content_type, modified_at, published_at, author FROM docs WHERE connector = ?1 AND rowid > ?2 ORDER BY rowid LIMIT ?3"
        else
            "SELECT rowid, id, url, title, language, content_type, NULL, published_at, NULL FROM docs WHERE connector = ?1 AND rowid > ?2 ORDER BY rowid LIMIT ?3";
        const st = Stmt.prepare(self.db, sql) catch |e| return searchError(e);
        defer st.deinit();
        st.text(1, connector) catch |e| return searchError(e);
        st.int(2, after) catch |e| return searchError(e);
        st.int(3, limit) catch |e| return searchError(e);
        var out: std.ArrayList(search.ExportRow) = .empty;
        const dup = struct {
            fn one(a: Allocator, s: Stmt, i: c_int) Allocator.Error!?[]const u8 {
                const t = s.colText(i) orelse return null;
                return try a.dupe(u8, t);
            }
        }.one;
        while (st.step() catch |e| return searchError(e)) {
            const blob = st.colBlob(1) orelse continue;
            if (blob.len != @sizeOf(doc.Id)) continue;
            try out.append(arena, .{
                .cursor = st.colInt(0),
                .id = blob[0..@sizeOf(doc.Id)].*,
                .url = try dup(arena, st, 2),
                .title = try dup(arena, st, 3),
                .language = try dup(arena, st, 4),
                .content_type = try dup(arena, st, 5),
                .modified_at = colOptInt(st, 6),
                .published_at = colOptInt(st, 7),
                .author = try dup(arena, st, 8),
            });
        }
        return out.items;
    }
    pub fn docFreqImpl(ptr: *anyopaque, arena: Allocator, words_in: []const []const u8) search.Error![]const u32 {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        const out = try arena.alloc(u32, words_in.len);
        @memset(out, 0);
        for (words_in, out) |w, *o| {
            const st = Stmt.prepare(self.db, "SELECT doc FROM fts_vocab WHERE term = ?1") catch return out;
            defer st.deinit();
            st.text(1, w) catch return out;
            if (st.step() catch false) o.* = @intCast(@max(0, st.colInt(0)));
        }
        return out;
    }
    pub fn wordsImpl(ptr: *anyopaque, arena: Allocator, word: []const u8, kind: search.WordKind, limit: u32) search.Error![]const []const u8 {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        if (word.len == 0 or word.len > 64 or limit == 0) return &.{};
        switch (kind) {
            .spelling => {
                const edits = queryparse.autoEdits(word.len);
                const got = try self.expandWord(arena, word, if (edits == 0) 1 else edits);
                return got[0..@min(got.len, limit)];
            },
            .prefix => {
                var upper = try arena.dupe(u8, word);
                upper[upper.len - 1] +%= 1;
                const st = Stmt.prepare(self.db, "SELECT term FROM fts_vocab WHERE term > ?1 AND term >= ?1 AND term < ?2 ORDER BY doc DESC, term LIMIT ?3") catch return &.{};
                defer st.deinit();
                st.text(1, word) catch |e| return searchError(e);
                st.text(2, upper) catch |e| return searchError(e);
                st.int(3, limit) catch |e| return searchError(e);
                var out: std.ArrayList([]const u8) = .empty;
                while (st.step() catch |e| return searchError(e)) {
                    const t = st.colText(0) orelse continue;
                    try out.append(arena, try arena.dupe(u8, t));
                }
                return out.items;
            },
        }
    }
    pub fn sourceStatsImpl(ptr: *anyopaque, arena: Allocator) search.Error![]const search.SourceStat {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        const sql = if (self.has_meta) "SELECT connector, COUNT(*), MAX(indexed_at) FROM docs GROUP BY connector" else "SELECT connector, COUNT(*), NULL FROM docs GROUP BY connector";
        const st = Stmt.prepare(self.db, sql) catch |e| return searchError(e);
        defer st.deinit();
        var out: std.ArrayList(search.SourceStat) = .empty;
        while (st.step() catch |e| return searchError(e)) {
            const name = st.colText(0) orelse continue;
            const n = st.colInt(1);
            try out.append(arena, .{ .name = try arena.dupe(u8, name), .docs = if (n < 0) 0 else @intCast(n), .last_added = colOptInt(st, 2) });
        }
        return out.items;
    }
    pub fn infoImpl(ptr: *anyopaque, arena: Allocator, id: doc.Id) search.Error!?search.Hit {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        const columns = if (self.has_meta)
            "d.language, d.content_type, d.modified_at, d.size, d.author, d.kind, d.domain, d.published_at, d.indexed_at"
        else
            "d.language, d.content_type, NULL, NULL, NULL, NULL, NULL, d.published_at, NULL";
        const sql = try std.fmt.allocPrint(arena, "SELECT d.id, d.connector, d.url, d.title, NULL, 0.0, {s} FROM docs d WHERE d.id = ?1", .{columns});
        const st = Stmt.prepare(self.db, try arena.dupeSentinel(u8, sql, 0)) catch |e| return searchError(e);
        defer st.deinit();
        st.blob(1, &id) catch |e| return searchError(e);
        if (!(st.step() catch |e| return searchError(e))) return null;
        var hit = try hitFromRow(arena, st);
        hit.published_at = colOptInt(st, 13);
        hit.indexed_at = colOptInt(st, 14);
        return hit;
    }

    /// The `Hit` in the current row of a SELECT whose columns are: id, connector, url, title,
    /// snippet, score, language, content_type, modified_at, size, author, kind, domain.
    fn hitFromRow(arena: Allocator, st: Stmt) search.Error!search.Hit {
        const idb = c.sqlite3_column_blob(st.s, 0) orelse return error.Io;
        if (c.sqlite3_column_bytes(st.s, 0) != @sizeOf(doc.Id)) return error.Io;
        var id: doc.Id = undefined;
        @memcpy(&id, @as([*]const u8, @ptrCast(idb))[0..@sizeOf(doc.Id)]);
        return .{
            .id = id,
            .connector = try arena.dupe(u8, st.colText(1) orelse ""),
            .url = try dupeOpt(arena, st.colText(2)),
            .title = try dupeOpt(arena, st.colText(3)),
            .snippet = try dupeOpt(arena, st.colText(4)),
            .score = st.colFloat(5),
            .language = try dupeOpt(arena, st.colText(6)),
            .content_type = try dupeOpt(arena, st.colText(7)),
            .modified_at = colOptInt(st, 8),
            .size = if (colOptInt(st, 9)) |v| @intCast(@max(v, 0)) else null,
            .author = try dupeOpt(arena, st.colText(10)),
            .kind = try dupeOpt(arena, st.colText(11)),
            .domain = try dupeOpt(arena, st.colText(12)),
        };
    }

    /// The best passages of large documents for `q`: the chunk index searched with the query's words and conditions
    /// (the same document filters and source choice as a search). No typo tolerance; empty if there is no chunk
    /// index or nothing matches.
    pub fn searchChunksImpl(ptr: *anyopaque, arena: Allocator, q: search.Query, limit: u32) search.Error![]const search.ChunkHit {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));
        if (limit == 0 or limit > 500) return error.InvalidQuery;
        if (!self.has_meta) return &.{};
        const now: i64 = if (self.timeout) |t| @intCast(@divTrunc(Io.Timestamp.now(t.io, .real).nanoseconds, std.time.ns_per_s)) else 0;
        if (q.filters.len + q.filter_strings.len > max_filters) return error.InvalidQuery;
        const base_filters = blk: {
            if (q.filter_strings.len == 0) break :blk q.filters;
            const out = try arena.alloc(search.Filter, q.filters.len + q.filter_strings.len);
            @memcpy(out[0..q.filters.len], q.filters);
            for (q.filter_strings, out[q.filters.len..]) |text, *dst| {
                dst.* = (try queryparse.parseFilterString(arena, text, now)) orelse return error.InvalidQuery;
            }
            break :blk out;
        };
        const parsed = self.parseQuery(arena, q.text, false, now) catch |e| switch (e) {
            error.EmptyQuery => return &.{},
            else => return e,
        };
        if (parsed.fts.len == 0) return &.{};
        const filters = try mergeFilters(arena, base_filters, parsed.filters);

        var sql: std.ArrayList(u8) = .empty;
        var binds: std.ArrayList(Bind) = .empty;
        try sql.appendSlice(arena,
            \\SELECT d.id, m.idx, -bm25(chunks_fts, 2.0, 1.0)
            \\FROM chunks_fts JOIN chunk_map m ON m.rowid = chunks_fts.rowid JOIN docs d ON d.rowid = m.doc
            \\WHERE chunks_fts MATCH ?3
            \\  AND (?4 IS NULL OR d.language = ?4)
            \\  AND (?5 IS NULL OR d.content_type = ?5)
            \\  AND (?6 IS NULL OR d.connector = ?6)
        );
        try filterSql(arena, filters, q.collections, &sql, &binds);
        try scopeSql(arena, q.scope, &sql, &binds);
        try sql.appendSlice(arena, " ORDER BY bm25(chunks_fts, 2.0, 1.0), d.id, m.idx LIMIT ?7");
        const st = Stmt.prepare(self.db, try arena.dupeSentinel(u8, sql.items, 0)) catch return &.{}; // no chunk index here
        defer st.deinit();
        st.text(3, parsed.fts) catch |e| return searchError(e);
        st.text(4, q.language) catch |e| return searchError(e);
        st.text(5, q.content_type) catch |e| return searchError(e);
        st.text(6, q.connector) catch |e| return searchError(e);
        st.int(7, limit) catch |e| return searchError(e);
        for (binds.items, 0..) |b, i| {
            const n: c_int = @intCast(9 + i);
            (switch (b) {
                .text => |t| st.text(n, t),
                .int => |v| st.int(n, v),
            }) catch |e| return searchError(e);
        }
        var guard: Deadline = undefined;
        if (self.timeout) |t| {
            guard = .{ .io = t.io, .deadline_ns = Io.Timestamp.now(t.io, .awake).nanoseconds + @as(i96, t.ms) * std.time.ns_per_ms };
            c.sqlite3_progress_handler(self.db, 2000, progressCallback, &guard);
        } else guard = .{ .io = undefined, .deadline_ns = 0 };
        defer if (self.timeout != null) c.sqlite3_progress_handler(self.db, 0, null, null);
        var out: std.ArrayList(search.ChunkHit) = .empty;
        while (st.step() catch |e| return if (guard.fired) error.Timeout else searchError(e)) {
            const idb = c.sqlite3_column_blob(st.s, 0) orelse return error.Io;
            if (c.sqlite3_column_bytes(st.s, 0) != @sizeOf(doc.Id)) return error.Io;
            var id: doc.Id = undefined;
            @memcpy(&id, @as([*]const u8, @ptrCast(idb))[0..@sizeOf(doc.Id)]);
            try out.append(arena, .{ .id = id, .index = @intCast(st.colInt(1)), .score = st.colFloat(2) });
        }
        return out.items;
    }

    pub fn searchImpl(ptr: *anyopaque, arena: Allocator, q: search.Query) search.Error!search.Page {
        const self: *SqliteIndex = @ptrCast(@alignCast(ptr));

        const limit: u32 = if (q.limit == 0) search.default_limit else q.limit;
        if (limit > search.max_limit) return error.InvalidQuery;
        if (@as(u64, q.offset) + limit > search.max_window) return error.InvalidQuery;

        const now: i64 = if (self.timeout) |t| @intCast(@divTrunc(Io.Timestamp.now(t.io, .real).nanoseconds, std.time.ns_per_s)) else 0;
        if (q.filters.len + q.filter_strings.len > max_filters) return error.InvalidQuery;
        // Conditions given as separate strings are read the way the query language reads them.
        const base_filters = blk: {
            if (q.filter_strings.len == 0) break :blk q.filters;
            const out = try arena.alloc(search.Filter, q.filters.len + q.filter_strings.len);
            @memcpy(out[0..q.filters.len], q.filters);
            for (q.filter_strings, out[q.filters.len..]) |text, *dst| {
                dst.* = (try queryparse.parseFilterString(arena, text, now)) orelse return error.InvalidQuery;
            }
            break :blk out;
        };

        if (self.simple_syntax) {
            const m = try buildMatchSimple(arena, q.text);
            return self.runMatch(arena, q, base_filters, limit, m, null, false);
        }

        // Typo tolerance: forced on or off by the search, or by the server's mode;
        // in `auto` an exact search that finds nothing is repeated with it.
        const forced: ?bool = switch (q.fuzzy) {
            .on => true,
            .off => false,
            .default => switch (self.fuzzy_mode) {
                .always => true,
                .off => false,
                .auto => null,
            },
        };
        const first = self.parseQuery(arena, q.text, forced orelse false, now) catch |e| {
            // Conditions given as parameters can stand alone, without words to find.
            if (e == error.EmptyQuery and base_filters.len > 0) return self.runMatch(arena, q, base_filters, limit, "", null, false);
            return e;
        };
        const all = try mergeFilters(arena, base_filters, first.filters);
        const t0: i96 = if (self.timeout) |t| Io.Timestamp.now(t.io, .awake).nanoseconds else 0;
        const page = try self.runMatch(arena, q, all, limit, first.fts, interpretedOf(first), first.fuzzy_applied);
        if (forced == null and page.hits.len < auto_fuzzy_below and q.offset == 0 and first.fts.len > 0) {
            // The repeat gets what is left of the time limit, and is skipped if the first attempt used half of it:
            // two full attempts would outlast the connection's own deadline.
            var budget: ?u32 = null;
            if (self.timeout) |t| {
                const used_ms: i96 = @divTrunc(Io.Timestamp.now(t.io, .awake).nanoseconds - t0, std.time.ns_per_ms);
                if (used_ms * 2 >= t.ms) return page;
                budget = t.ms - @as(u32, @intCast(used_ms));
            }
            if (self.parseQuery(arena, q.text, true, now)) |second| {
                if (second.fuzzy_applied) {
                    self.retry_budget_ms = budget;
                    defer self.retry_budget_ms = null;
                    // A repeat that runs out of time leaves the first answer standing.
                    const again = self.runMatch(arena, q, all, limit, second.fts, interpretedOf(second), true) catch |e| switch (e) {
                        error.Timeout => return page,
                        else => return e,
                    };
                    if (again.hits.len > page.hits.len) return again;
                }
            } else |_| {}
        }
        return page;
    }

    fn mergeFilters(arena: Allocator, a: []const search.Filter, b: []const search.Filter) search.Error![]const search.Filter {
        if (b.len == 0) return a;
        if (a.len + b.len > max_filters) return error.InvalidQuery;
        const out = try arena.alloc(search.Filter, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return out;
    }

    /// The words of the index within `max_edits` edits of `word`, closest first and, among equals, the most common first.
    /// The words that begin like `word` are looked at first (most typos keep the first letter); if there are none, all
    /// words of about the same length are. Time-limited like a search.
    fn expandCb(ctx: *anyopaque, arena: Allocator, word: []const u8, max_edits: u8) Allocator.Error![]const []const u8 {
        const self: *SqliteIndex = @ptrCast(@alignCast(ctx));
        return self.expandWord(arena, word, max_edits) catch &.{};
    }

    fn expandWord(self: *SqliteIndex, arena: Allocator, word: []const u8, max_edits: u8) search.Error![]const []const u8 {
        if (word.len == 0 or max_edits == 0) return &.{};
        const Found = struct { term: []const u8, edits: u8, docs: i64 };
        var found: std.ArrayList(Found) = .empty;
        const lo_len: i64 = @as(i64, @intCast(word.len)) - max_edits;
        const hi_len: i64 = @as(i64, @intCast(word.len)) + max_edits;
        var guard: Deadline = undefined;
        defer if (self.timeout != null) c.sqlite3_progress_handler(self.db, 0, null, null);
        var tier: u8 = 0;
        while (tier < 2) : (tier += 1) {
            // Each tier has its own short budget: the words with the same first letter may take a while on a very
            // large index, and looking at every word is only worth a moment.
            if (self.timeout) |t| {
                const budget: u32 = if (tier == 0) 1000 else 250;
                const ms: u32 = @min(t.ms, budget);
                guard = .{ .io = t.io, .deadline_ns = Io.Timestamp.now(t.io, .awake).nanoseconds + @as(i96, ms) * std.time.ns_per_ms };
                c.sqlite3_progress_handler(self.db, 500, progressCallback, &guard);
            } else guard = .{ .io = undefined, .deadline_ns = 0 };
            // Tier 0: words with the same first letter (a range of the vocabulary). Tier 1: all of them.
            const sql = if (tier == 0)
                "SELECT term, doc, dk_edits(term, ?1, ?2) FROM fts_vocab WHERE term >= ?3 AND term < ?4 AND length(term) BETWEEN ?5 AND ?6 AND dk_edits(term, ?1, ?2) IS NOT NULL"
            else
                "SELECT term, doc, dk_edits(term, ?1, ?2) FROM fts_vocab WHERE length(term) BETWEEN ?5 AND ?6 AND dk_edits(term, ?1, ?2) IS NOT NULL";
            const st = Stmt.prepare(self.db, sql) catch return &.{}; // an index made before this table: variants are used
            defer st.deinit();
            st.text(1, word) catch |e| return searchError(e);
            st.int(2, max_edits) catch |e| return searchError(e);
            if (tier == 0) {
                // The first character, however many bytes it takes, as the bounds of the range.
                const n = std.unicode.utf8ByteSequenceLength(word[0]) catch 1;
                const first = word[0..@min(n, word.len)];
                st.text(3, first) catch |e| return searchError(e);
                var upper = try arena.dupe(u8, first);
                upper[upper.len - 1] +%= 1;
                st.text(4, upper) catch |e| return searchError(e);
            }
            st.int(5, @max(lo_len, 1)) catch |e| return searchError(e);
            st.int(6, hi_len) catch |e| return searchError(e);
            while (st.step() catch |e| {
                if (guard.fired) break; // out of time: what was found so far is used
                return searchError(e);
            }) {
                const term = st.colText(0) orelse continue;
                if (std.mem.eql(u8, term, word)) continue;
                try found.append(arena, .{ .term = try arena.dupe(u8, term), .edits = @intCast(st.colInt(2)), .docs = st.colInt(1) });
                if (found.items.len >= 2000) break;
            }
            if (found.items.len > 0) break;
        }
        std.mem.sort(Found, found.items, {}, struct {
            fn lt(_: void, a: Found, b: Found) bool {
                if (a.edits != b.edits) return a.edits < b.edits;
                if (a.docs != b.docs) return a.docs > b.docs;
                return std.mem.lessThan(u8, a.term, b.term);
            }
        }.lt);
        // Only the closest spellings count when there are enough of them: a rarer word two edits away would
        // otherwise outscore the word that was meant (rare words weigh more in the ranking).
        var n = @min(found.items.len, queryparse.max_expansions);
        if (found.items.len > 0) {
            const best = found.items[0].edits;
            var at_best: usize = 0;
            for (found.items) |f| if (f.edits == best) {
                at_best += 1;
            };
            if (at_best >= 1 and best < max_edits) n = @min(n, at_best);
        }
        const out = try arena.alloc([]const u8, n);
        for (found.items[0..n], out) |f, *o| o.* = f.term;
        return out;
    }

    fn parseQuery(self: *const SqliteIndex, arena: Allocator, text: []const u8, fuzzy_words: bool, now: i64) search.Error!queryparse.Parsed {
        return queryparse.parseWith(arena, text, .{ .fuzzy_words = fuzzy_words, .now = now, .lexicon = self.lexicon, .expander = if (self.has_vocab) .{ .ctx = @constCast(self), .f = expandCb } else null }) catch |e| switch (e) {
            error.EmptyQuery => error.EmptyQuery,
            error.InvalidQuery => error.InvalidQuery,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn interpretedOf(p: queryparse.Parsed) ?[]const u8 {
        return if (p.advanced or p.fuzzy_applied) p.shown else null;
    }

    const Bind = union(enum) { text: []const u8, int: i64 };

    /// Escapes `%`, `_` and `\` for a LIKE pattern written with ESCAPE '\'.
    fn likeEscape(arena: Allocator, text: []const u8, before: []const u8, after: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, before);
        for (text) |b| {
            if (b == '%' or b == '_' or b == '\\') try out.append(arena, '\\');
            try out.append(arena, b);
        }
        try out.appendSlice(arena, after);
        return out.items;
    }

    /// Appends ` AND <condition>` for each filter to `sql`, with the values to
    /// bind (numbered from 9 up) in `binds`. Values never become SQL text.
    fn filterSql(arena: Allocator, filters: []const search.Filter, colls: []const search.CollectionDef, sql: *std.ArrayList(u8), binds: *std.ArrayList(Bind)) search.Error!void {
        const P = struct {
            arena: Allocator,
            binds: *std.ArrayList(Bind),
            colls: []const search.CollectionDef,
            fn add(self: @This(), b: Bind) Allocator.Error![]const u8 {
                try self.binds.append(self.arena, b);
                return std.fmt.allocPrint(self.arena, "?{d}", .{8 + self.binds.items.len});
            }
        };
        const pb: P = .{ .arena = arena, .binds = binds, .colls = colls };
        // Positive conditions on the same text field are alternatives (`ext:pdf ext:md`
        // means either); everything else must all hold.
        var any_of: std.ArrayList(u8) = .empty;
        for (filters, 0..) |f, i| {
            if (f.negate or !isAlternative(f.field)) continue;
            var first = true;
            for (filters[0..i]) |g| if (!g.negate and g.field == f.field) {
                first = false;
            };
            if (!first) continue;
            var same: usize = 0;
            for (filters) |g| if (!g.negate and g.field == f.field) {
                same += 1;
            };
            if (same < 2) continue;
            var parts: std.ArrayList(u8) = .empty;
            for (filters) |g| if (!g.negate and g.field == f.field) {
                var one: std.ArrayList(u8) = .empty;
                try filterClause(arena, g, pb, &one);
                if (parts.items.len > 0) try parts.appendSlice(arena, " OR ");
                try parts.print(arena, "COALESCE(({s}), 0)", .{one.items});
            };
            try any_of.print(arena, " AND ({s})", .{parts.items});
        }
        try sql.appendSlice(arena, any_of.items);
        for (filters, 0..) |f, fi| {
            if (!f.negate and isAlternative(f.field)) {
                var same: usize = 0;
                for (filters) |g| if (!g.negate and g.field == f.field) {
                    same += 1;
                };
                if (same >= 2) continue; // already written as a group
            }
            _ = fi;
            var cl: std.ArrayList(u8) = .empty;
            try filterClause(arena, f, pb, &cl);
            if (cl.items.len == 0) continue;
            // A document without the property does not satisfy the condition, and does satisfy its negation.
            try sql.print(arena, " AND {s}COALESCE(({s}), 0)", .{ if (f.negate) "NOT " else "", cl.items });
        }
    }

    /// ` AND d.connector IN (...)` for the sources the caller may see; nothing when there is no limit.
    fn scopeSql(arena: Allocator, scope: ?[]const []const u8, sql: *std.ArrayList(u8), binds: *std.ArrayList(Bind)) search.Error!void {
        const list = scope orelse return;
        if (list.len == 0) return sql.appendSlice(arena, " AND 0");
        try sql.appendSlice(arena, " AND d.connector IN (");
        for (list, 0..) |name, i| {
            try binds.append(arena, .{ .text = name });
            if (i > 0) try sql.appendSlice(arena, ", ");
            try sql.print(arena, "?{d}", .{8 + binds.items.len});
        }
        try sql.append(arena, ')');
    }

    fn isAlternative(field: search.FilterField) bool {
        return switch (field) {
            .source, .collection, .language, .mime, .kind, .ext, .domain, .path, .author, .tag => true,
            else => false,
        };
    }

    fn filterClause(arena: Allocator, f: search.Filter, pb: anytype, cl: *std.ArrayList(u8)) search.Error!void {
        {
            switch (f.field) {
                .source => try cl.print(arena, "d.connector = {s}", .{try pb.add(.{ .text = f.text })}),
                .collection => {
                    // Any source of the collection; a name that is not one matches nothing.
                    var members: ?[]const []const u8 = null;
                    for (pb.colls) |col| if (std.ascii.eqlIgnoreCase(col.name, f.text)) {
                        members = col.sources;
                    };
                    const list = members orelse {
                        try cl.appendSlice(arena, "0");
                        return;
                    };
                    if (list.len == 0) return cl.appendSlice(arena, "0");
                    try cl.appendSlice(arena, "d.connector IN (");
                    for (list, 0..) |m, i| {
                        if (i > 0) try cl.appendSlice(arena, ", ");
                        try cl.appendSlice(arena, try pb.add(.{ .text = m }));
                    }
                    try cl.append(arena, ')');
                },
                .language => {
                    const n = try pb.add(.{ .text = f.text });
                    // "en" also matches "en-US", ignoring case.
                    try cl.print(arena, "lower(substr(d.language, 1, length({s}))) = lower({s}) AND (length(d.language) = length({s}) OR substr(d.language, length({s}) + 1, 1) = '-')", .{ n, n, n, n });
                },
                .mime => {
                    if (std.mem.endsWith(u8, f.text, "/*")) {
                        try cl.print(arena, "lower(d.content_type) LIKE {s} ESCAPE '\\'", .{try pb.add(.{ .text = try likeEscape(arena, f.text[0 .. f.text.len - 1], "", "%") })});
                    } else {
                        const exact = try pb.add(.{ .text = f.text });
                        const with_params = try pb.add(.{ .text = try likeEscape(arena, f.text, "", ";%") });
                        try cl.print(arena, "(lower(d.content_type) = {s} OR lower(d.content_type) LIKE {s} ESCAPE '\\')", .{ exact, with_params });
                    }
                },
                .kind => try cl.print(arena, "d.kind = {s}", .{try pb.add(.{ .text = f.text })}),
                .ext => try cl.print(arena, "d.ext = {s}", .{try pb.add(.{ .text = f.text })}),
                .domain => {
                    const exact = try pb.add(.{ .text = f.text });
                    const sub = try pb.add(.{ .text = try likeEscape(arena, f.text, "%.", "") });
                    try cl.print(arena, "(d.domain = {s} OR d.domain LIKE {s} ESCAPE '\\')", .{ exact, sub });
                },
                .path => try cl.print(arena, "d.path LIKE {s} ESCAPE '\\'", .{try pb.add(.{ .text = try likeEscape(arena, f.text, "", "%") })}),
                .author => try cl.print(arena, "d.author LIKE {s} ESCAPE '\\'", .{try pb.add(.{ .text = try likeEscape(arena, f.text, "%", "%") })}),
                .size, .modified, .created, .indexed => {
                    const col = switch (f.field) {
                        .size => "d.size",
                        .modified => "d.modified_at",
                        .created => "d.published_at",
                        else => "d.indexed_at",
                    };
                    if (f.min) |v| try cl.print(arena, "{s} >= {s}", .{ col, try pb.add(.{ .int = v }) });
                    if (f.max) |v| try cl.print(arena, "{s}{s} <= {s}", .{ if (f.min != null) " AND " else "", col, try pb.add(.{ .int = v }) });
                },
                .tag => try cl.print(arena, "EXISTS (SELECT 1 FROM doc_meta m WHERE m.doc = d.rowid AND m.key = 'tag' AND m.value = {s} COLLATE NOCASE)", .{try pb.add(.{ .text = f.text })}),
                .meta => {
                    const k = try pb.add(.{ .text = f.key });
                    const v = try pb.add(.{ .text = try likeEscape(arena, f.text, "%", "%") });
                    try cl.print(arena, "EXISTS (SELECT 1 FROM doc_meta m WHERE m.doc = d.rowid AND m.key = {s} AND m.value LIKE {s} ESCAPE '\\')", .{ k, v });
                },
            }
        }
    }

    /// The ORDER BY clause: relevance (or, with no words to rank by, recency) unless asked otherwise.
    /// Documents without the property sort last; ties fall back to relevance and then to the id.
    fn orderBy(arena: Allocator, sort: search.Sort, text_mode: bool, bm: []const u8) Allocator.Error![]const u8 {
        const date = "COALESCE(d.modified_at, d.published_at, d.indexed_at";
        if (text_mode) return switch (sort) {
            .relevance => try std.fmt.allocPrint(arena, " ORDER BY {s}, d.id", .{bm}),
            .newest => try std.fmt.allocPrint(arena, " ORDER BY {s}, -1) DESC, {s}, d.id", .{ date, bm }),
            .oldest => try std.fmt.allocPrint(arena, " ORDER BY {s}, 9223372036854775807) ASC, {s}, d.id", .{ date, bm }),
            .largest => try std.fmt.allocPrint(arena, " ORDER BY COALESCE(d.size, -1) DESC, {s}, d.id", .{bm}),
            .smallest => try std.fmt.allocPrint(arena, " ORDER BY COALESCE(d.size, 9223372036854775807) ASC, {s}, d.id", .{bm}),
            .title => try std.fmt.allocPrint(arena, " ORDER BY lower(COALESCE(d.title, '')) ASC, {s}, d.id", .{bm}),
        };
        return switch (sort) {
            .relevance, .newest => " ORDER BY " ++ date ++ ", 0) DESC, d.id",
            .oldest => " ORDER BY " ++ date ++ ", 9223372036854775807) ASC, d.id",
            .largest => " ORDER BY COALESCE(d.size, -1) DESC, d.id",
            .smallest => " ORDER BY COALESCE(d.size, 9223372036854775807) ASC, d.id",
            .title => " ORDER BY lower(COALESCE(d.title, '')) ASC, d.id",
        };
    }

    fn runMatch(self: *SqliteIndex, arena: Allocator, q: search.Query, filters: []const search.Filter, limit: u32, match: []const u8, interpreted: ?[]const u8, fuzzy: bool) search.Error!search.Page {
        if (filters.len > 0 and !self.has_meta) return error.InvalidQuery; // an index from before filters: `rebuild` upgrades it
        const columns = if (self.has_meta) "d.language, d.content_type, d.modified_at, d.size, d.author, d.kind, d.domain" else "d.language, d.content_type, NULL, NULL, NULL, NULL, NULL";
        const text_mode = match.len > 0;
        // The score: the weighted text match, times the source's boost and a recency factor. bm25 is
        // negative (smaller is better), so a factor above 1 helps.
        var factors: std.ArrayList(u8) = .empty;
        var src_expr: []const u8 = "1.0";
        if (q.boosts.len > 0) {
            var cs: std.ArrayList(u8) = .empty;
            try cs.appendSlice(arena, "(CASE d.connector");
            for (q.boosts) |b| {
                try cs.appendSlice(arena, " WHEN '");
                for (b.source) |ch| {
                    if (ch == '\'') try cs.append(arena, '\'');
                    try cs.append(arena, ch);
                }
                try cs.print(arena, "' THEN {d}.{d:0>2}", .{ b.percent / 100, b.percent % 100 });
            }
            try cs.appendSlice(arena, " ELSE 1.0 END)");
            src_expr = cs.items;
        }
        var rec_expr: []const u8 = "1.0";
        if (self.recency_percent > 0 and self.has_meta) {
            rec_expr = try std.fmt.allocPrint(arena, "(1.0 + {d}.{d:0>2} / (1.0 + MAX(0, CAST(strftime('%s','now') AS INTEGER) - COALESCE(d.modified_at, d.published_at, d.indexed_at, 0)) / 86400.0 / {d}.0))", .{ self.recency_percent / 100, self.recency_percent % 100, self.recency_days });
        }
        try factors.print(arena, "{s} * {s}", .{ src_expr, rec_expr });
        const bm = try std.fmt.allocPrint(arena, "bm25(fts, {d}.0, {d}.0) * {s}", .{ self.title_weight, self.body_weight, factors.items });
        const explain_cols = if (q.explain and text_mode)
            try std.fmt.allocPrint(arena, ", -bm25(fts, {d}.0, {d}.0), -bm25(fts, 1.0, 0.0), -bm25(fts, 0.0, 1.0), {s}, {s}", .{ self.title_weight, self.body_weight, src_expr, rec_expr })
        else
            "";
        var sql: std.ArrayList(u8) = .empty;
        var binds: std.ArrayList(Bind) = .empty;
        if (text_mode) {
            try sql.print(arena,
                \\SELECT d.id, d.connector, d.url, d.title,
                \\       snippet(fts, 1, ?1, ?2, '…', 16),
                \\       -({s}), {s}{s}
                \\FROM fts JOIN docs d ON d.rowid = fts.rowid
                \\WHERE fts MATCH ?3
            , .{ bm, columns, explain_cols });
        } else {
            try sql.print(arena, "SELECT d.id, d.connector, d.url, d.title, NULL, 0.0, {s} FROM docs d WHERE 1", .{columns});
        }
        try sql.appendSlice(arena,
            \\ AND (?4 IS NULL OR d.language = ?4)
            \\  AND (?5 IS NULL OR d.content_type = ?5)
            \\  AND (?6 IS NULL OR d.connector = ?6)
        );
        try filterSql(arena, filters, q.collections, &sql, &binds);
        try scopeSql(arena, q.scope, &sql, &binds);
        if (q.sort != .relevance and q.sort != .title and !self.has_meta) return error.InvalidQuery; // an old index: `rebuild` upgrades it
        try sql.appendSlice(arena, try orderBy(arena, q.sort, text_mode, bm));
        try sql.appendSlice(arena, " LIMIT ?7 OFFSET ?8");
        const st = Stmt.prepare(self.db, try arena.dupeSentinel(u8, sql.items, 0)) catch |e| return searchError(e);
        defer st.deinit();
        if (text_mode) {
            st.text(1, search.match_start) catch |e| return searchError(e);
            st.text(2, search.match_end) catch |e| return searchError(e);
            st.text(3, match) catch |e| return searchError(e);
        }
        st.text(4, q.language) catch |e| return searchError(e);
        st.text(5, q.content_type) catch |e| return searchError(e);
        st.text(6, q.connector) catch |e| return searchError(e);
        // One extra row tells us whether another page follows.
        st.int(7, @as(i64, limit) + 1) catch |e| return searchError(e);
        st.int(8, q.offset) catch |e| return searchError(e);
        for (binds.items, 0..) |b, i| {
            const n: c_int = @intCast(9 + i);
            (switch (b) {
                .text => |t| st.text(n, t),
                .int => |v| st.int(n, v),
            }) catch |e| return searchError(e);
        }

        var guard: Deadline = undefined;
        if (self.timeout) |t| {
            guard = .{ .io = t.io, .deadline_ns = Io.Timestamp.now(t.io, .awake).nanoseconds + @as(i96, self.retry_budget_ms orelse t.ms) * std.time.ns_per_ms };
            c.sqlite3_progress_handler(self.db, 2000, progressCallback, &guard);
        } else guard = .{ .io = undefined, .deadline_ns = 0 };
        defer if (self.timeout != null) c.sqlite3_progress_handler(self.db, 0, null, null);

        var hits: std.ArrayList(search.Hit) = .empty;
        var more = false;
        while (st.step() catch |e| return if (guard.fired) error.Timeout else searchError(e)) {
            if (hits.items.len == limit) {
                more = true;
                break;
            }
            var hit = try hitFromRow(arena, st);
            if (q.explain and text_mode) hit.explain = .{ .text = st.colFloat(13), .title = st.colFloat(14), .body = st.colFloat(15), .source = st.colFloat(16), .recency = st.colFloat(17) };
            try hits.append(arena, hit);
        }
        return .{ .hits = hits.items, .has_more = more, .interpreted = interpreted, .fuzzy = fuzzy };
    }
};

/// Several read-only connections to one index file, so concurrent searches
/// run in parallel instead of queueing on a single connection (SQLite
/// serialises the use of one connection). WAL mode lets any number of readers
/// run alongside the single writer. A search takes any idle connection; if
/// all are busy it waits on a semaphore (no spinning) until one is free.
fn colOptInt(st: Stmt, i: c_int) ?i64 {
    if (c.sqlite3_column_type(st.s, i) == c.SQLITE_NULL) return null;
    return st.colInt(i);
}

/// The deadline of one search, watched from SQLite's progress callback.
const Deadline = struct {
    io: Io,
    deadline_ns: i96,
    fired: bool = false,
};

fn progressCallback(ctx: ?*anyopaque) callconv(.c) c_int {
    const d: *Deadline = @ptrCast(@alignCast(ctx.?));
    if (Io.Timestamp.now(d.io, .awake).nanoseconds >= d.deadline_ns) {
        d.fired = true;
        return 1; // non-zero: interrupt the statement
    }
    return 0;
}

pub const SearchPool = struct {
    gpa: Allocator,
    io: Io,
    slots: []Slot,
    /// One permit per idle connection.
    idle: Io.Semaphore,

    const Slot = struct {
        index: SqliteIndex,
        busy: std.atomic.Value(bool) = .init(false),
    };

    /// `size` connections (at least one) to the existing index at `path`.
    pub fn open(gpa: Allocator, io: Io, path: [:0]const u8, size: usize) OpenError!SearchPool {
        const n = @max(size, 1);
        const slots = try gpa.alloc(Slot, n);
        var opened: usize = 0;
        errdefer {
            for (slots[0..opened]) |*sl| sl.index.close();
            gpa.free(slots);
        }
        while (opened < n) : (opened += 1) {
            slots[opened] = .{ .index = try SqliteIndex.openReadOnly(path) };
        }
        return .{ .gpa = gpa, .io = io, .slots = slots, .idle = .{ .permits = n } };
    }

    pub fn close(self: *SearchPool) void {
        for (self.slots) |*sl| sl.index.close();
        self.gpa.free(self.slots);
        self.* = undefined;
    }

    /// See `SqliteIndex.setSimpleSyntax`; call before searching.
    pub fn setSimpleSyntax(self: *SearchPool, simple: bool) void {
        for (self.slots) |*sl| sl.index.setSimpleSyntax(simple);
    }

    pub fn setFuzzyMode(self: *SearchPool, mode: FuzzyMode) void {
        for (self.slots) |*sl| sl.index.setFuzzyMode(mode);
    }

    pub fn setWeights(self: *SearchPool, title: u32, body: u32) void {
        for (self.slots) |*sl| sl.index.setWeights(title, body);
    }

    pub fn setLexicon(self: *SearchPool, l: ?*const lexicon_mod.Lexicon) void {
        for (self.slots) |*sl| sl.index.setLexicon(l);
    }

    pub fn setRecency(self: *SearchPool, percent: u32, half_life_days: u32) void {
        for (self.slots) |*sl| sl.index.setRecency(percent, half_life_days);
    }

    /// See `SqliteIndex.setQueryTimeout`; call before searching.
    pub fn setQueryTimeout(self: *SearchPool, ms: u32) void {
        for (self.slots) |*sl| sl.index.setQueryTimeout(self.io, ms);
    }

    pub fn searcher(self: *SearchPool) search.Searcher {
        return .{ .ptr = self, .vtable = &.{ .search = poolSearch, .info = poolInfo, .search_chunks = poolSearchChunks, .source_stats = poolSourceStats, .words = poolWords, .doc_freq = poolDocFreq, .export_page = poolExportPage } };
    }

    pub fn imageSearcher(self: *SearchPool) search.ImageSearcher {
        return .{ .ptr = self, .vtable = &.{ .near = poolNear } };
    }

    fn poolNear(ptr: *anyopaque, arena: Allocator, hash: u64, max_distance: u8, limit: u32) search.Error!search.ImagePage {
        const self: *SearchPool = @ptrCast(@alignCast(ptr));
        self.idle.waitUncancelable(self.io);
        defer self.idle.post(self.io);
        for (self.slots) |*slot| {
            if (slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                defer slot.busy.store(false, .release);
                return SqliteIndex.nearImpl(&slot.index, arena, hash, max_distance, limit);
            }
        }
        unreachable;
    }

    fn poolExportPage(ptr: *anyopaque, arena: Allocator, connector: []const u8, after: i64, limit: u32) search.Error![]const search.ExportRow {
        const self: *SearchPool = @ptrCast(@alignCast(ptr));
        self.idle.waitUncancelable(self.io);
        defer self.idle.post(self.io);
        for (self.slots) |*slot| {
            if (slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                defer slot.busy.store(false, .release);
                return SqliteIndex.exportPageImpl(&slot.index, arena, connector, after, limit);
            }
        }
        unreachable;
    }
    fn poolDocFreq(ptr: *anyopaque, arena: Allocator, words_in: []const []const u8) search.Error![]const u32 {
        const self: *SearchPool = @ptrCast(@alignCast(ptr));
        self.idle.waitUncancelable(self.io);
        defer self.idle.post(self.io);
        for (self.slots) |*slot| {
            if (slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                defer slot.busy.store(false, .release);
                return SqliteIndex.docFreqImpl(&slot.index, arena, words_in);
            }
        }
        unreachable;
    }
    fn poolWords(ptr: *anyopaque, arena: Allocator, word: []const u8, kind: search.WordKind, limit: u32) search.Error![]const []const u8 {
        const self: *SearchPool = @ptrCast(@alignCast(ptr));
        self.idle.waitUncancelable(self.io);
        defer self.idle.post(self.io);
        for (self.slots) |*slot| {
            if (slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                defer slot.busy.store(false, .release);
                return SqliteIndex.wordsImpl(&slot.index, arena, word, kind, limit);
            }
        }
        unreachable;
    }
    fn poolSourceStats(ptr: *anyopaque, arena: Allocator) search.Error![]const search.SourceStat {
        const self: *SearchPool = @ptrCast(@alignCast(ptr));
        self.idle.waitUncancelable(self.io);
        defer self.idle.post(self.io);
        for (self.slots) |*slot| {
            if (slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                defer slot.busy.store(false, .release);
                return SqliteIndex.sourceStatsImpl(&slot.index, arena);
            }
        }
        unreachable;
    }
    fn poolInfo(ptr: *anyopaque, arena: Allocator, id: doc.Id) search.Error!?search.Hit {
        const self: *SearchPool = @ptrCast(@alignCast(ptr));
        self.idle.waitUncancelable(self.io);
        defer self.idle.post(self.io);
        for (self.slots) |*slot| {
            if (slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                defer slot.busy.store(false, .release);
                return SqliteIndex.infoImpl(&slot.index, arena, id);
            }
        }
        unreachable;
    }

    fn poolSearchChunks(ptr: *anyopaque, arena: Allocator, q: search.Query, limit: u32) search.Error![]const search.ChunkHit {
        const self: *SearchPool = @ptrCast(@alignCast(ptr));
        self.idle.waitUncancelable(self.io);
        defer self.idle.post(self.io);
        for (self.slots) |*slot| {
            if (slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                defer slot.busy.store(false, .release);
                return SqliteIndex.searchChunksImpl(&slot.index, arena, q, limit);
            }
        }
        unreachable;
    }

    fn poolSearch(ptr: *anyopaque, arena: Allocator, q: search.Query) search.Error!search.Page {
        const self: *SearchPool = @ptrCast(@alignCast(ptr));
        // A permit means at least one slot is idle; claim it.
        self.idle.waitUncancelable(self.io);
        defer self.idle.post(self.io);
        for (self.slots) |*slot| {
            if (slot.busy.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
                defer slot.busy.store(false, .release);
                return SqliteIndex.searchImpl(&slot.index, arena, q);
            }
        }
        unreachable; // permits never exceed the number of idle slots
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
fn buildMatchSimple(arena: Allocator, text: []const u8) search.Error![]const u8 {
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

test "simple mode: buildMatchSimple quotes every term and neutralizes syntax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("\"hello\" \"world\"", try buildMatchSimple(a, "  hello   world "));
    try testing.expectEqualStrings("\"hello world\" \"x\"", try buildMatchSimple(a, "\"hello world\" x"));
    try testing.expectEqualStrings("\"title:foo\" \"OR\" \"bar*\"", try buildMatchSimple(a, "title:foo OR bar*"));
    try testing.expectEqualStrings("\"unterminated phrase\"", try buildMatchSimple(a, "\"unterminated phrase"));
    try testing.expectEqualStrings("\"café\"", try buildMatchSimple(a, "café"));
    try testing.expectError(error.EmptyQuery, buildMatchSimple(a, ""));
    try testing.expectError(error.InvalidQuery, buildMatchSimple(a, "x\x00y"));
    try testing.expectError(error.EmptyQuery, buildMatchSimple(a, " !!! ... \"\" "));
    const long = try a.alloc(u8, search.max_query_bytes + 1);
    @memset(long, 'a');
    try testing.expectError(error.InvalidQuery, buildMatchSimple(a, long));
    try testing.expectError(error.InvalidQuery, buildMatchSimple(a, "a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee ff gg"));
}

test "a search past its time limit stops with Timeout; without a limit it finishes" {
    var idx = try SqliteIndex.open(":memory:", .{ .sync = .off });
    defer idx.close();
    // Many documents share one word, so ranking them takes a measurable time.
    for (0..30_000) |i| {
        var idb: [16]u8 = undefined;
        var tb: [96]u8 = undefined;
        _ = try put(&idx, "t", try std.fmt.bufPrint(&idb, "d{d}", .{i}), null, try std.fmt.bufPrint(&tb, "common filler words number {d} appear in every document here", .{i}));
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    idx.setQueryTimeout(testing.io, 1);
    try testing.expectError(error.Timeout, searchAll(arena.allocator(), &idx, "common"));
    // The connection is usable afterwards, and with no limit the search completes.
    idx.setQueryTimeout(testing.io, 0);
    const page = try searchAll(arena.allocator(), &idx, "common");
    try testing.expectEqual(@as(usize, 10), page.hits.len);
}

test "pictures are found by hash distance, nearest first, and forgotten with their document" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const base: u64 = 0xF0F0_F0F0_0F0F_0F0F;
    const hashes = [_]u64{ base, base ^ 0b111, base ^ 0xFFFF, ~base }; // 0, 3, 16 and 64 bits away
    var ids: [4]doc.Id = undefined;
    for (hashes, 0..) |h, i| {
        var nb: [8]u8 = undefined;
        const hex = image_mod.toHex(h);
        const d: doc.Document = .{
            .connector = "t",
            .source_id = try std.fmt.bufPrint(&nb, "img{d}", .{i}),
            .title = "a picture",
            .text = "a picture",
            .extra = &.{.{ .key = "phash", .value = &hex }},
        };
        ids[i] = d.id();
        try idx.indexer().add(ids[i], d);
    }
    // A document without a hash is never an image hit.
    _ = try put(&idx, "t", "text", "words", "just words");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const near = try idx.imageSearcher().near(a, base, 10, 10);
    try testing.expectEqual(@as(usize, 2), near.hits.len);
    try testing.expectEqual(ids[0], near.hits[0].id);
    try testing.expectEqual(@as(u8, 0), near.hits[0].distance);
    try testing.expectEqual(ids[1], near.hits[1].id);
    try testing.expectEqual(@as(u8, 3), near.hits[1].distance);
    try testing.expectEqual(@as(usize, 3), (try idx.imageSearcher().near(a, base, 16, 10)).hits.len);
    try testing.expectEqual(@as(usize, 1), (try idx.imageSearcher().near(a, base, 64, 1)).hits.len); // limit applies

    // Re-adding a document without a hash drops its hash; removing drops it too.
    const again: doc.Document = .{ .connector = "t", .source_id = "img1", .title = "a picture", .text = "a picture" };
    try idx.indexer().add(again.id(), again);
    try idx.indexer().remove(ids[0]);
    const left = try idx.imageSearcher().near(a, base, 64, 10);
    try testing.expectEqual(@as(usize, 2), left.hits.len); // img2 and img3 remain
    // An index without the table (an older one) simply has no pictures.
    try idx.exec("DROP TABLE image_hash");
    try testing.expectEqual(@as(usize, 0), (try idx.imageSearcher().near(a, base, 64, 10)).hits.len);
}

test "the query language finds what it says: OR, NOT, grouping, prefix, fuzzy, proximity" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    _ = try put(&idx, "t", "1", "Wayland", "linux wayland compositor for the kernel");
    _ = try put(&idx, "t", "2", "BSD", "bsd kernel module loader");
    _ = try put(&idx, "t", "3", "Android", "linux android phone kernel");
    _ = try put(&idx, "t", "4", "Windows", "the window manager and a tiling window layout");
    _ = try put(&idx, "t", "5", "Tiling", "window and then several other words before manager appears");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Case = struct { q: []const u8, want: []const []const u8 };
    const cases = [_]Case{
        .{ .q = "linux wayland", .want = &.{"1"} },
        .{ .q = "linux AND wayland", .want = &.{"1"} },
        .{ .q = "wayland OR bsd", .want = &.{ "1", "2" } },
        .{ .q = "linux NOT android", .want = &.{"1"} },
        .{ .q = "linux -android", .want = &.{"1"} },
        .{ .q = "+kernel -android", .want = &.{ "1", "2" } },
        .{ .q = "(linux OR bsd) AND kernel", .want = &.{ "1", "2", "3" } },
        .{ .q = "kernel -(android OR bsd)", .want = &.{"1"} },
        .{ .q = "comp*", .want = &.{"1"} },
        .{ .q = "compositer~", .want = &.{"1"} }, // one typo
        .{ .q = "compositar~ -bsd", .want = &.{"1"} },
        .{ .q = "\"window manager\"", .want = &.{"4"} },
        .{ .q = "\"window manager\"~2", .want = &.{"4"} },
        .{ .q = "\"window manager\"~8", .want = &.{ "4", "5" } },
        .{ .q = "nomatchword OR wayland", .want = &.{"1"} },
        .{ .q = "linux and phone", .want = &.{} }, // lower case "and" is just a word
    };
    for (cases) |case| {
        const page = try searchAll(a, &idx, case.q);
        errdefer std.debug.print("query: {s} gave {d} hits\n", .{ case.q, page.hits.len });
        try testing.expectEqual(case.want.len, page.hits.len);
        for (case.want) |w| {
            var found = false;
            for (page.hits) |h| {
                const id = doc.idFromSource("t", w);
                if (std.mem.eql(u8, &h.id, &id)) found = true;
            }
            try testing.expect(found);
        }
    }
    // The page says how a language query was read, and nothing for plain words.
    const lang = try searchAll(a, &idx, "linux OR bsd -android");
    try testing.expectEqualStrings("linux OR bsd NOT android", lang.interpreted.?);
    try testing.expect((try searchAll(a, &idx, "linux wayland")).interpreted == null);
    // Only negative terms: nothing to search for.
    try testing.expectError(error.EmptyQuery, searchAll(a, &idx, "-android"));

    // Typo tolerance, as `serve` configures it by default: a misspelling finds the right page, and
    // says it did; an exact spelling needs none; turning it off turns it off.
    idx.setFuzzyMode(.auto);
    const typo = try searchAll(a, &idx, "wayalnd");
    try testing.expectEqual(@as(usize, 1), typo.hits.len);
    try testing.expect(typo.fuzzy);
    try testing.expectEqualStrings("wayalnd~", typo.interpreted.?);
    try testing.expect(!(try searchAll(a, &idx, "wayland")).fuzzy);
    const two = try searchAll(a, &idx, "compositer kernal"); // two typos in two words
    try testing.expectEqual(@as(usize, 1), two.hits.len);
    // Words of three letters or fewer are never guessed at.
    try testing.expectEqual(@as(usize, 0), (try searchAll(a, &idx, "bsa")).hits.len);
    idx.setFuzzyMode(.off);
    try testing.expectEqual(@as(usize, 0), (try searchAll(a, &idx, "wayalnd")).hits.len);
    idx.setFuzzyMode(.auto);
    try testing.expectEqual(@as(usize, 0), (try idx.searcher().search(a, .{ .text = "wayalnd", .fuzzy = .off })).hits.len);
    try testing.expect((try idx.searcher().search(a, .{ .text = "wayalnd", .fuzzy = .on })).fuzzy);
    idx.setFuzzyMode(.always);
    try testing.expect((try searchAll(a, &idx, "wayland")).fuzzy); // expanded even when exact would do
    idx.setFuzzyMode(.off);

    // Simple mode turns the language off: AND/OR/NOT/ - are plain words.
    idx.setSimpleSyntax(true);
    try testing.expectEqual(@as(usize, 0), (try searchAll(a, &idx, "wayland OR bsd")).hits.len);
    try testing.expectEqual(@as(usize, 1), (try searchAll(a, &idx, "wayland compositor")).hits.len);
}

test "random queries never make SQLite reject the expression or crash" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    _ = try put(&idx, "t", "1", "A title", "alpha beta gamma delta window manager one two three");
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const pieces = [_][]const u8{ "alpha", "bet*", "gam~", "AND", "OR", "NOT", "(", ")", "\"", "\"window manager\"~3", "-", "+", " ", " ", "~", "*", "title:", "NEAR(", "x", "é", "''" };
    for (0..1500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var q: std.ArrayList(u8) = .empty;
        for (0..rnd.uintLessThan(usize, 12) + 1) |_| try q.appendSlice(arena.allocator(), pieces[rnd.uintLessThan(usize, pieces.len)]);
        if (searchAll(arena.allocator(), &idx, q.items)) |_| {} else |e| switch (e) {
            error.EmptyQuery, error.InvalidQuery => {},
            else => {
                std.debug.print("query {s} failed with {t}\n", .{ q.items, e });
                return e;
            },
        }
    }
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

test "typo tolerance uses the words of the index: two edits for longer words, ranked by closeness" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    _ = try put(&idx, "t", "1", "Zoo", "The elephant walked slowly through the zoo.");
    _ = try put(&idx, "t", "2", "Mail", "Please receive the parcel at the front door.");
    _ = try put(&idx, "t", "3", "Other", "A completely unrelated sentence about bread.");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two edits (f for ph) on a long word; a swap; one edit on a short word.
    try testing.expectEqual(@as(usize, 1), (try searchAll(a, &idx, "elefant~")).hits.len);
    try testing.expectEqual(@as(usize, 1), (try searchAll(a, &idx, "recieve~")).hits.len);
    try testing.expectEqual(@as(usize, 1), (try searchAll(a, &idx, "zooo~")).hits.len);
    // ~1 asks for one edit only; two edits away is then not found.
    try testing.expectEqual(@as(usize, 0), (try searchAll(a, &idx, "elefant~1")).hits.len);
    try testing.expectEqual(@as(usize, 1), (try searchAll(a, &idx, "elefant~2")).hits.len);
    // A word with nothing close finds nothing, and the interpreted query shows what was searched.
    try testing.expectEqual(@as(usize, 0), (try searchAll(a, &idx, "xylophonist~")).hits.len);
    const p = try searchAll(a, &idx, "elefant~");
    try testing.expect(std.mem.indexOf(u8, p.interpreted.?, "elefant~") != null);
    // The expansion is bounded however large the vocabulary: only real words, closest first.
    const words = try idx.expandWord(a, "elefant", 2);
    try testing.expect(words.len >= 1 and std.mem.eql(u8, words[0], "elephant"));
    try testing.expect(words.len <= queryparse.max_expansions);
}

test "words of the vocabulary: completions of a prefix, most common first, and the spelling of a mistyped word" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    _ = try put(&idx, "t", "1", "Zoo", "The elephant and the elevator; an elephant again.");
    _ = try put(&idx, "t", "2", "Two", "Another elephant, and an electric eel.");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = idx.searcher();
    const ele = try s.words(a, "ele", .prefix, 3);
    try testing.expectEqual(@as(usize, 3), ele.len);
    try testing.expectEqualStrings("elephant", ele[0]); // in both documents, so first
    for (ele) |w| try testing.expect(std.mem.startsWith(u8, w, "ele"));
    try testing.expectEqual(@as(usize, 0), (try s.words(a, "zzz", .prefix, 5)).len);
    try testing.expectEqual(@as(usize, 0), (try s.words(a, "", .prefix, 5)).len);
    const dfs = try s.docFreq(a, &.{ "elephant", "elevator", "nothere" });
    try testing.expectEqual(@as(u32, 2), dfs[0]);
    try testing.expectEqual(@as(u32, 1), dfs[1]);
    try testing.expectEqual(@as(u32, 0), dfs[2]);
    const sp = try s.words(a, "elefant", .spelling, 1);
    try testing.expectEqual(@as(usize, 1), sp.len);
    try testing.expectEqualStrings("elephant", sp[0]);
}

test "passages of large documents are indexed, found with their conditions, replaced on update and removed" {
    var idx = try SqliteIndex.open(":memory:", .{ .chunk_min_bytes = 2000 });
    defer idx.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A long text with one distinctive word in one section; and a short document that is not chunk-indexed.
    var big: std.ArrayList(u8) = .empty;
    for (0..30) |i| try big.print(a, "## Section {d}\n\nOrdinary filler about harvests and rain in section {d}, nothing special at all.\n\n", .{ i, i });
    try big.appendSlice(a, "## Zebra\n\nThe quagga is a rare word found only here.\n\n");
    for (30..40) |i| try big.print(a, "## Section {d}\n\nMore ordinary filler about harvests and rain in section {d}.\n\n", .{ i, i });
    const d: doc.Document = .{ .connector = "books", .source_id = "big", .title = "Big", .text = big.items, .content_type = "text/markdown" };
    try idx.indexer().add(d.id(), d);
    const small: doc.Document = .{ .connector = "notes", .source_id = "small", .title = "Small", .text = "A quagga mention in a short note." };
    try idx.indexer().add(small.id(), small);

    const hits = try idx.searcher().searchChunks(a, .{ .text = "quagga" }, 10);
    try testing.expectEqual(@as(usize, 1), hits.len); // only the large document has passages
    try testing.expectEqualSlices(u8, &d.id(), &hits[0].id);
    // The index of the chunk is the one `retrieve.chunk` gives the same text.
    const cs = try retrieve.chunk(a, big.items, retrieve.index_chunk_options);
    try testing.expect(std.mem.indexOf(u8, cs[hits[0].index].text, "quagga") != null);
    // The search's conditions apply.
    try testing.expectEqual(@as(usize, 0), (try idx.searcher().searchChunks(a, .{ .text = "quagga", .connector = "notes" }, 10)).len);
    try testing.expectEqual(@as(usize, 1), (try idx.searcher().searchChunks(a, .{ .text = "quagga", .connector = "books" }, 10)).len);
    try testing.expectEqual(@as(usize, 0), (try idx.searcher().searchChunks(a, .{ .text = "unicorn" }, 10)).len);
    // Updating replaces the passages; removing deletes them.
    const d2: doc.Document = .{ .connector = "books", .source_id = "big", .title = "Big", .text = try std.mem.concat(a, u8, &.{ big.items, "\n\n## Last\n\nA unicorn appears at the very end.\n\n" }), .content_type = "text/markdown" };
    try idx.indexer().add(d2.id(), d2);
    try testing.expectEqual(@as(usize, 1), (try idx.searcher().searchChunks(a, .{ .text = "unicorn" }, 10)).len);
    try testing.expectEqual(@as(usize, 1), (try idx.searcher().searchChunks(a, .{ .text = "quagga" }, 10)).len); // not doubled
    try idx.indexer().remove(d2.id());
    try testing.expectEqual(@as(usize, 0), (try idx.searcher().searchChunks(a, .{ .text = "quagga" }, 10)).len);
    // Off: nothing is indexed.
    var off = try SqliteIndex.open(":memory:", .{ .chunk_min_bytes = 0 });
    defer off.close();
    try off.indexer().add(d.id(), d);
    try testing.expectEqual(@as(usize, 0), (try off.searcher().searchChunks(a, .{ .text = "quagga" }, 10)).len);
}

test "a scope limits every result, and collection: means any source of the collection" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    _ = try put(&idx, "wiki", "1", "Wiki", "the common word appears here");
    _ = try put(&idx, "notes", "1", "Notes", "the common word appears here too");
    _ = try put(&idx, "mail", "1", "Mail", "the common word appears here also");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const colls = [_]search.CollectionDef{ .{ .name = "mine", .sources = &.{ "notes", "mail" } }, .{ .name = "empty", .sources = &.{} } };
    const run = struct {
        fn go(ar: Allocator, i: *SqliteIndex, q: search.Query) !usize {
            return (try i.searcher().search(ar, q)).hits.len;
        }
    }.go;
    try testing.expectEqual(@as(usize, 3), try run(a, &idx, .{ .text = "common" }));
    // The scope limits the results, whatever else is asked.
    try testing.expectEqual(@as(usize, 1), try run(a, &idx, .{ .text = "common", .scope = &.{"notes"} }));
    try testing.expectEqual(@as(usize, 0), try run(a, &idx, .{ .text = "common", .scope = &.{} }));
    try testing.expectEqual(@as(usize, 0), try run(a, &idx, .{ .text = "common source:wiki", .scope = &.{"notes"} }));
    try testing.expectEqual(@as(usize, 0), try run(a, &idx, .{ .text = "common", .scope = &.{"notes"}, .connector = "wiki" }));
    // A collection: any of its sources; combined with the scope, only those inside it.
    try testing.expectEqual(@as(usize, 2), try run(a, &idx, .{ .text = "common collection:mine", .collections = &colls }));
    try testing.expectEqual(@as(usize, 1), try run(a, &idx, .{ .text = "common collection:mine", .collections = &colls, .scope = &.{ "wiki", "notes" } }));
    try testing.expectEqual(@as(usize, 1), try run(a, &idx, .{ .text = "common -collection:mine", .collections = &colls }));
    try testing.expectEqual(@as(usize, 0), try run(a, &idx, .{ .text = "common collection:empty", .collections = &colls }));
    try testing.expectEqual(@as(usize, 0), try run(a, &idx, .{ .text = "common collection:nosuch", .collections = &colls }));
    // Searching by conditions alone is limited too.
    try testing.expectEqual(@as(usize, 1), try run(a, &idx, .{ .text = "", .filter_strings = &.{"source:mail"}, .scope = &.{"mail"} }));
    try testing.expectEqual(@as(usize, 0), try run(a, &idx, .{ .text = "", .filter_strings = &.{"source:mail"}, .scope = &.{"notes"} }));
}

test "the title and body weights decide which counts more" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const body_id = try put(&idx, "t", "body", "Something else", "a long text that mentions truth once");
    const title_id = try put(&idx, "t", "title", "The truth", "unrelated words here");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(title_id, (try searchAll(a, &idx, "truth")).hits[0].id);
    idx.setWeights(1, 1000); // the text matters far more than the title
    const flipped = try searchAll(a, &idx, "truth");
    try testing.expectEqual(body_id, flipped.hits[0].id);
    idx.setWeights(1000, 1);
    try testing.expectEqual(title_id, (try searchAll(a, &idx, "truth")).hits[0].id);
}

test "a source's boost, the recency boost and the explanation of a score" {
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const day: i64 = 86400;
    const now: i64 = Io.Clock.real.now(testing.io).toSeconds();
    try putDoc(&idx, .{ .connector = "a", .source_id = "1", .title = "Anchor", .text = "anchor anchor", .modified_at = now - 3000 * day });
    try putDoc(&idx, .{ .connector = "b", .source_id = "2", .title = "Anchor", .text = "anchor anchor", .modified_at = now - 3000 * day });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two identical documents tie; a boost on source b puts it first, a cut puts it last.
    const boosted = try idx.searcher().search(a, .{ .text = "anchor", .boosts = &.{.{ .source = "b", .percent = 200 }} });
    try testing.expectEqualStrings("b", boosted.hits[0].connector);
    try testing.expect(boosted.hits[0].score > boosted.hits[1].score * 1.9);
    const cut = try idx.searcher().search(a, .{ .text = "anchor", .boosts = &.{.{ .source = "b", .percent = 50 }} });
    try testing.expectEqualStrings("a", cut.hits[0].connector);

    // A newer document of the same text ranks above an old one once recency counts.
    try putDoc(&idx, .{ .connector = "c", .source_id = "3", .title = "Anchor", .text = "anchor anchor", .modified_at = now - day });
    idx.setRecency(100, 365);
    const fresh = try idx.searcher().search(a, .{ .text = "anchor" });
    try testing.expectEqualStrings("c", fresh.hits[0].connector);
    try testing.expect(fresh.hits[0].score > fresh.hits[2].score * 1.5);

    // The explanation: the factors multiply back to the score.
    const ex = try idx.searcher().search(a, .{ .text = "anchor", .explain = true, .boosts = &.{.{ .source = "c", .percent = 150 }} });
    const h = ex.hits[0];
    try testing.expectEqualStrings("c", h.connector);
    const e = h.explain.?;
    try testing.expectApproxEqRel(1.5, e.source, 1e-9);
    try testing.expect(e.recency > 1.9 and e.recency <= 2.0);
    try testing.expectApproxEqRel(h.score, e.text * e.source * e.recency, 1e-9);
    try testing.expect(e.title > 0 and e.body > 0);
    // Without asking, nothing is added.
    try testing.expect((try idx.searcher().search(a, .{ .text = "anchor" })).hits[0].explain == null);
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
    // The documents are still there. "title:Title" is the column restriction of the
    // query language (it finds the title), but other column names are plain words.
    try testing.expectEqual(@as(u64, 1), try idx.count());
    try testing.expectEqual(@as(usize, 1), (try s.search(arena.allocator(), .{ .text = "title:Title" })).hits.len);
    try testing.expectEqual(@as(usize, 0), (try s.search(arena.allocator(), .{ .text = "title:body" })).hits.len);
    try testing.expectEqual(@as(usize, 0), (try s.search(arena.allocator(), .{ .text = "nosuch:Title" })).hits.len);
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

test "pool: same answers as one connection, also from many threads at once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200:0]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pb, ".zig-cache/tmp/{s}/p.db", .{tmp.sub_path}, 0);
    var idx = try SqliteIndex.open(path, .{ .sync = .off });
    defer idx.close();
    for (0..200) |i| {
        var idb: [16]u8 = undefined;
        var tb: [80]u8 = undefined;
        try idx.indexer().add(doc.idFromSource("t", try std.fmt.bufPrint(&idb, "d{d}", .{i})), .{
            .connector = "t",
            .source_id = try std.fmt.bufPrint(&idb, "d{d}", .{i}),
            .text = try std.fmt.bufPrint(&tb, "lamp number {d} keeper {d} harbour", .{ i, i % 7 }),
        });
    }
    var pool = try SearchPool.open(testing.allocator, testing.io, path, 3);
    defer pool.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const want = try idx.searcher().search(arena.allocator(), .{ .text = "keeper harbour", .limit = 5 });
    const got = try pool.searcher().search(arena.allocator(), .{ .text = "keeper harbour", .limit = 5 });
    try testing.expectEqual(want.hits.len, got.hits.len);
    for (want.hits, got.hits) |a, b| try testing.expectEqualSlices(u8, &a.id, &b.id);

    // More threads than connections, all searching at once.
    const Worker = struct {
        fn run(p: *SearchPool, failures: *std.atomic.Value(u32)) void {
            var a = std.heap.ArenaAllocator.init(testing.allocator);
            defer a.deinit();
            for (0..40) |_| {
                _ = a.reset(.retain_capacity);
                const page = p.searcher().search(a.allocator(), .{ .text = "lamp harbour", .limit = 10 }) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                    return;
                };
                if (page.hits.len != 10) _ = failures.fetchAdd(1, .monotonic);
            }
        }
    };
    var failures: std.atomic.Value(u32) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &failures });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(u32, 0), failures.load(.monotonic));

    // A pool never creates or changes anything: a missing file is an error.
    var missing: [200:0]u8 = undefined;
    const mp = try std.fmt.bufPrintSentinel(&missing, ".zig-cache/tmp/{s}/nope.db", .{tmp.sub_path}, 0);
    try testing.expectError(error.Io, SearchPool.open(testing.allocator, testing.io, mp, 2));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "nope.db", .{}));
}

fn putDoc(idx: *SqliteIndex, d: doc.Document) !void {
    try idx.indexer().add(d.id(), d);
}

fn titles(arena: Allocator, idx: *SqliteIndex, text: []const u8, filters: []const search.Filter) ![]const u8 {
    const page = try idx.searcher().search(arena, .{ .text = text, .filters = filters });
    var out: std.ArrayList(u8) = .empty;
    for (page.hits) |h| {
        if (out.items.len > 0) try out.append(arena, ',');
        try out.appendSlice(arena, h.title orelse "?");
    }
    // The titles sorted, so the check does not depend on tie order.
    const items = try arena.dupe(u8, out.items);
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, items, ',');
    while (it.next()) |p| try parts.append(arena, p);
    std.mem.sort([]const u8, parts.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return std.mem.join(arena, ",", parts.items);
}

test "filters narrow results by file type, host, size, dates, author, tags and fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const day = 86400;
    try putDoc(&idx, .{ .connector = "web", .source_id = "1", .title = "A", .text = "kernel notes", .canonical_url = "https://docs.example.org/guide/a.html", .content_type = "text/html", .language = "en-US", .author = "Jo Smith", .modified_at = 100 * day, .acquired_at = 200 * day, .extra = &.{ .{ .key = "tag", .value = "Linux" }, .{ .key = "camera", .value = "ACME 100" } } });
    try putDoc(&idx, .{ .connector = "web", .source_id = "2", .title = "B", .text = "kernel manual with a lot more words in it than the others have", .canonical_url = "https://example.org/files/b.pdf", .content_type = "application/pdf", .language = "de", .modified_at = 300 * day, .acquired_at = 200 * day });
    try putDoc(&idx, .{ .connector = "disk", .source_id = "3", .title = "C", .text = "kernel readme", .canonical_url = "file:///home/x/c.md", .content_type = "text/markdown", .acquired_at = 400 * day, .extra = &.{.{ .key = "tag", .value = "bsd" }} });

    const F = search.Filter;
    try testing.expectEqualStrings("A,B,C", try titles(a, &idx, "kernel", &.{}));
    try testing.expectEqualStrings("B", try titles(a, &idx, "kernel", &.{.{ .field = .ext, .text = "pdf" }}));
    try testing.expectEqualStrings("A,C", try titles(a, &idx, "kernel", &.{.{ .field = .ext, .text = "pdf", .negate = true }}));
    try testing.expectEqualStrings("C", try titles(a, &idx, "kernel", &.{.{ .field = .kind, .text = "markdown" }}));
    try testing.expectEqualStrings("A,B", try titles(a, &idx, "kernel", &.{.{ .field = .domain, .text = "example.org" }})); // subdomains count
    try testing.expectEqualStrings("A", try titles(a, &idx, "kernel", &.{.{ .field = .domain, .text = "docs.example.org" }}));
    try testing.expectEqualStrings("", try titles(a, &idx, "kernel", &.{.{ .field = .domain, .text = "ample.org" }})); // not a suffix of letters
    try testing.expectEqualStrings("A", try titles(a, &idx, "kernel", &.{.{ .field = .language, .text = "en" }})); // en matches en-US
    try testing.expectEqualStrings("B", try titles(a, &idx, "kernel", &.{.{ .field = .language, .text = "DE" }}));
    try testing.expectEqualStrings("C", try titles(a, &idx, "kernel", &.{.{ .field = .source, .text = "disk" }}));
    try testing.expectEqualStrings("A", try titles(a, &idx, "kernel", &.{.{ .field = .mime, .text = "text/html" }}));
    try testing.expectEqualStrings("A,C", try titles(a, &idx, "kernel", &.{.{ .field = .mime, .text = "text/*" }}));
    try testing.expectEqualStrings("B", try titles(a, &idx, "kernel", &.{.{ .field = .size, .min = 30 }}));
    try testing.expectEqualStrings("A", try titles(a, &idx, "kernel", &.{.{ .field = .author, .text = "smith" }}));
    try testing.expectEqualStrings("A,B", try titles(a, &idx, "kernel", &.{.{ .field = .modified, .min = 0 }})); // C has no date
    try testing.expectEqualStrings("B", try titles(a, &idx, "kernel", &.{.{ .field = .modified, .min = 200 * day }}));
    try testing.expectEqualStrings("A,B", try titles(a, &idx, "kernel", &.{.{ .field = .indexed, .max = 300 * day }}));
    try testing.expectEqualStrings("C", try titles(a, &idx, "kernel", &.{.{ .field = .indexed, .min = 300 * day }}));
    try testing.expectEqualStrings("C", try titles(a, &idx, "kernel", &.{.{ .field = .modified, .min = 0, .negate = true }})); // no date satisfies the negation
    try testing.expectEqualStrings("A", try titles(a, &idx, "kernel", &.{.{ .field = .tag, .text = "linux" }}));
    try testing.expectEqualStrings("A", try titles(a, &idx, "kernel", &.{.{ .field = .meta, .key = "camera", .text = "acme" }}));
    try testing.expectEqualStrings("A,B", try titles(a, &idx, "kernel", &.{.{ .field = .tag, .text = "bsd", .negate = true }}));
    try testing.expectEqualStrings("B", try titles(a, &idx, "kernel", &.{ .{ .field = .domain, .text = "example.org" }, .{ .field = .language, .text = "en", .negate = true } })); // all must hold
    try testing.expectEqualStrings("A", try titles(a, &idx, "kernel", &.{.{ .field = .path, .text = "/guide/" }}));

    // Special characters in values are text, not SQL or wildcards.
    try testing.expectEqualStrings("", try titles(a, &idx, "kernel", &.{.{ .field = .author, .text = "%" }}));
    try testing.expectEqualStrings("", try titles(a, &idx, "kernel", &.{.{ .field = .ext, .text = "pdf' OR '1'='1" }}));
    _ = F;

    // Hits carry what is known about the document.
    const page = try idx.searcher().search(a, .{ .text = "manual" });
    try testing.expectEqual(@as(usize, 1), page.hits.len);
    try testing.expectEqualStrings("pdf", page.hits[0].kind.?);
    try testing.expectEqualStrings("example.org", page.hits[0].domain.?);
    try testing.expectEqual(@as(?i64, 300 * day), page.hits[0].modified_at);
    try testing.expect(page.hits[0].size.? > 30);
}

test "the query text itself can carry filters and column restrictions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    try putDoc(&idx, .{ .connector = "web", .source_id = "1", .title = "Window manager", .text = "tiling is nice", .canonical_url = "https://a.org/x.html", .content_type = "text/html" });
    try putDoc(&idx, .{ .connector = "web", .source_id = "2", .title = "Notes", .text = "a window manager is a program", .canonical_url = "https://a.org/y.pdf", .content_type = "application/pdf" });

    try testing.expectEqualStrings("Notes,Window manager", try titles(a, &idx, "window manager", &.{}));
    try testing.expectEqualStrings("Window manager", try titles(a, &idx, "title:window", &.{}));
    try testing.expectEqualStrings("Notes", try titles(a, &idx, "body:program", &.{}));
    try testing.expectEqualStrings("Notes", try titles(a, &idx, "window ext:pdf", &.{}));
    try testing.expectEqualStrings("Window manager", try titles(a, &idx, "window -ext:pdf", &.{}));
    try testing.expectEqualStrings("Notes,Window manager", try titles(a, &idx, "site:a.org type:pdf OR type:page", &.{}));
}

test "a search made only of filters lists matches, newest first; an old index refuses filters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    try putDoc(&idx, .{ .connector = "d", .source_id = "1", .title = "Old", .text = "t", .canonical_url = "file:///a.pdf", .modified_at = 10 });
    try putDoc(&idx, .{ .connector = "d", .source_id = "2", .title = "New", .text = "t", .canonical_url = "file:///b.pdf", .modified_at = 20 });
    try putDoc(&idx, .{ .connector = "d", .source_id = "3", .title = "Other", .text = "t", .canonical_url = "file:///c.txt", .modified_at = 30 });
    const page = try idx.searcher().search(a, .{ .text = "ext:pdf" });
    try testing.expectEqual(@as(usize, 2), page.hits.len);
    try testing.expectEqualStrings("New", page.hits[0].title.?);
    try testing.expectEqualStrings("Old", page.hits[1].title.?);
    // Parameters alone, with no text at all.
    const by_param = try idx.searcher().search(a, .{ .text = "", .filters = &.{.{ .field = .ext, .text = "txt" }} });
    try testing.expectEqual(@as(usize, 1), by_param.hits.len);
    try testing.expectError(error.EmptyQuery, idx.searcher().search(a, .{ .text = "-ext:pdf" }));

    idx.has_meta = false; // as an index from before filters
    try testing.expectError(error.InvalidQuery, idx.searcher().search(a, .{ .text = "t ext:pdf" }));
    const plain = try idx.searcher().search(a, .{ .text = "t" });
    try testing.expect(plain.hits.len == 3);
}

test "the metadata columns are added to an older index, and removal clears tags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    // An index as it was before filters.
    try idx.exec("DROP TABLE doc_meta; DROP INDEX docs_domain; DROP INDEX docs_ext; DROP INDEX docs_kind; DROP INDEX docs_modified; ALTER TABLE docs DROP COLUMN modified_at; ALTER TABLE docs DROP COLUMN indexed_at; ALTER TABLE docs DROP COLUMN author; ALTER TABLE docs DROP COLUMN size; ALTER TABLE docs DROP COLUMN ext; ALTER TABLE docs DROP COLUMN domain; ALTER TABLE docs DROP COLUMN path; ALTER TABLE docs DROP COLUMN kind;");
    try testing.expect(!idx.detectMeta());
    try idx.migrateMeta();
    try testing.expect(idx.detectMeta());
    idx.has_meta = true;
    const d: doc.Document = .{ .connector = "c", .source_id = "1", .title = "T", .text = "hello", .extra = &.{.{ .key = "tag", .value = "x" }} };
    try putDoc(&idx, d);
    try testing.expectEqualStrings("T", try titles(a, &idx, "hello", &.{.{ .field = .tag, .text = "x" }}));
    try idx.indexer().remove(d.id());
    const st = try Stmt.prepare(idx.db, "SELECT count(*) FROM doc_meta");
    defer st.deinit();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 0), st.colInt(0));
}

test "results can be ordered by date, size or title, and conditions can be given as strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var idx = try SqliteIndex.open(":memory:", .{});
    defer idx.close();
    const day = 86400;
    try putDoc(&idx, .{ .connector = "d", .source_id = "1", .title = "Charlie", .text = "kernel", .canonical_url = "file:///a/c.pdf", .modified_at = 10 * day, .extra = &.{.{ .key = "file_size", .value = "500" }} });
    try putDoc(&idx, .{ .connector = "d", .source_id = "2", .title = "alpha", .text = "kernel kernel kernel", .canonical_url = "file:///a/a.md", .modified_at = 30 * day, .extra = &.{.{ .key = "file_size", .value = "9000" }} });
    try putDoc(&idx, .{ .connector = "d", .source_id = "3", .title = "Bravo", .text = "kernel", .canonical_url = "file:///a/b.pdf", .modified_at = 20 * day, .extra = &.{.{ .key = "file_size", .value = "70" }} });
    try putDoc(&idx, .{ .connector = "d", .source_id = "4", .title = "Undated", .text = "kernel", .canonical_url = "file:///a/u.txt" });

    const order = struct {
        fn of(ar: Allocator, i: *SqliteIndex, sort: search.Sort, strings: []const []const u8) ![]const u8 {
            const page = try i.searcher().search(ar, .{ .text = "kernel", .sort = sort, .filter_strings = strings });
            var out: std.ArrayList(u8) = .empty;
            for (page.hits) |h| {
                if (out.items.len > 0) try out.append(ar, ',');
                try out.appendSlice(ar, h.title.?);
            }
            return out.items;
        }
    }.of;
    try testing.expectEqualStrings("alpha,Bravo,Charlie,Undated", try order(a, &idx, .newest, &.{}));
    try testing.expectEqualStrings("Charlie,Bravo,alpha,Undated", try order(a, &idx, .oldest, &.{}));
    try testing.expectEqualStrings("alpha,Charlie,Bravo,Undated", try order(a, &idx, .largest, &.{}));
    // A document whose source gives no file size is as large as its text (here six bytes).
    try testing.expectEqualStrings("Undated,Bravo,Charlie,alpha", try order(a, &idx, .smallest, &.{}));
    try testing.expectEqualStrings("alpha,Bravo,Charlie,Undated", try order(a, &idx, .title, &.{})); // case-insensitive
    const rel = try order(a, &idx, .relevance, &.{});
    try testing.expect(std.mem.startsWith(u8, rel, "alpha,")); // the most repeated word ranks first
    // Strings are conditions in the query language's spelling.
    try testing.expectEqualStrings("Charlie,Bravo", try order(a, &idx, .oldest, &.{"ext:pdf"}));
    try testing.expectEqualStrings("Bravo", try order(a, &idx, .oldest, &.{ "ext:pdf", "-size:>100" }));
    try testing.expectEqualStrings("Charlie,Bravo,alpha,Undated", try order(a, &idx, .oldest, &.{"-ext:zip"}));
    try testing.expectError(error.InvalidQuery, idx.searcher().search(a, .{ .text = "kernel", .filter_strings = &.{"nonsense:1"} }));
    try testing.expectError(error.InvalidQuery, idx.searcher().search(a, .{ .text = "kernel", .filter_strings = &.{"size:big"} }));
    // An index from before filters cannot sort by date.
    idx.has_meta = false;
    try testing.expectError(error.InvalidQuery, idx.searcher().search(a, .{ .text = "kernel", .sort = .newest }));
    _ = try idx.searcher().search(a, .{ .text = "kernel", .sort = .title });
}
