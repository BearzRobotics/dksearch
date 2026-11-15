//! Document metadata and import-job state in SQLite (`state.db`).
//!
//! Source-of-truth data (docs/decisions/0006-persistent-storage.md): unlike the
//! index it cannot be rebuilt, so it carries a versioned schema with forward
//! migrations (see `sqlite.migrate`).
//!
//! It holds two things:
//!   * `documents`: one record per imported document (everything except the
//!     main text, which lives in the content store);
//!   * `jobs`: one row per import run, with its counters and the connector's
//!     opaque checkpoint, so an interrupted run can resume.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");
const c = sqlite.c;
const Stmt = sqlite.Stmt;
const doc = @import("document.zig");
const storage = @import("storage.zig");

const migrations = [_][:0]const u8{
    \\CREATE TABLE documents(
    \\  id           BLOB PRIMARY KEY,
    \\  connector    TEXT NOT NULL,
    \\  source_id    TEXT NOT NULL,
    \\  content_hash BLOB,
    \\  acquired_at  INTEGER,
    \\  meta         TEXT NOT NULL
    \\) WITHOUT ROWID;
    \\CREATE INDEX documents_source ON documents(connector, source_id);
    \\CREATE TABLE jobs(
    \\  id          INTEGER PRIMARY KEY,
    \\  source      TEXT NOT NULL,
    \\  connector   TEXT NOT NULL,
    \\  state       TEXT NOT NULL CHECK (state IN ('running','completed','failed','cancelled','interrupted')),
    \\  started_at  INTEGER NOT NULL,
    \\  finished_at INTEGER,
    \\  submitted   INTEGER NOT NULL DEFAULT 0,
    \\  rejected    INTEGER NOT NULL DEFAULT 0,
    \\  checkpoint  BLOB,
    \\  error       TEXT
    \\);
    \\CREATE INDEX jobs_source ON jobs(source, id);
};

pub const OpenError = sqlite.MigrateError;

pub const JobState = enum {
    running,
    completed,
    failed,
    cancelled,
    /// Was `running` when the process stopped; found that way at startup.
    interrupted,
};

pub const Job = struct {
    id: i64,
    source: []const u8,
    connector: []const u8,
    state: JobState,
    started_at: doc.Timestamp,
    finished_at: ?doc.Timestamp,
    submitted: u64,
    rejected: u64,
    /// The connector's opaque resume position, as last saved.
    checkpoint: ?[]const u8,
    error_message: ?[]const u8,
};

pub const SqliteStateStore = struct {
    gpa: Allocator,
    db: *c.sqlite3,
    /// Backs the strings of the record `find` returns.
    find_arena: std.heap.ArenaAllocator,
    /// Backs the strings of the record `forEach` is currently visiting.
    visit_arena: std.heap.ArenaAllocator,
    /// Jobs found `running` at open time and marked `interrupted`.
    recovered_jobs: u64 = 0,

    pub fn open(gpa: Allocator, path: [:0]const u8, sync_off: bool) OpenError!SqliteStateStore {
        const db = try sqlite.open(path);
        errdefer _ = c.sqlite3_close(db);
        try sqlite.execSql(db, if (sync_off)
            "PRAGMA synchronous = OFF; PRAGMA journal_mode = WAL;"
        else
            "PRAGMA synchronous = FULL; PRAGMA journal_mode = WAL;");
        try sqlite.migrate(db, path, &migrations);

        var self: SqliteStateStore = .{
            .gpa = gpa,
            .db = db,
            .find_arena = .init(gpa),
            .visit_arena = .init(gpa),
        };
        errdefer self.find_arena.deinit();
        errdefer self.visit_arena.deinit();

        // A job still marked running belongs to a process that no longer exists.
        const st = try Stmt.prepare(db, "UPDATE jobs SET state = 'interrupted' WHERE state = 'running'");
        defer st.deinit();
        _ = try st.step();
        self.recovered_jobs = @intCast(c.sqlite3_changes(db));
        return self;
    }

    /// Opens an existing file read-only for `maintenance.check`. Unlike
    /// `open` it neither upgrades the schema nor marks running jobs
    /// interrupted, so it is safe while an import is running.
    pub fn inspect(gpa: Allocator, path: [:0]const u8) OpenError!SqliteStateStore {
        const db = try sqlite.openReadOnly(path);
        errdefer _ = c.sqlite3_close(db);
        try sqlite.requireCurrent(db, migrations.len);
        return .{ .gpa = gpa, .db = db, .find_arena = .init(gpa), .visit_arena = .init(gpa) };
    }

    pub fn close(self: *SqliteStateStore) void {
        self.find_arena.deinit();
        self.visit_arena.deinit();
        _ = c.sqlite3_close(self.db);
        self.* = undefined;
    }

    pub fn documents(self: *SqliteStateStore) storage.DocumentStore {
        return .{ .ptr = self, .vtable = &.{ .upsert = upsert, .find = find, .delete = delete, .for_each = forEach, .list = list, .count_of = countOf, .begin = begin, .commit = commit, .rollback = rollback } };
    }

    fn begin(ptr: *anyopaque) storage.Error!void {
        const self: *SqliteStateStore = @ptrCast(@alignCast(ptr));
        try sqlite.execSql(self.db, "BEGIN IMMEDIATE");
    }
    fn commit(ptr: *anyopaque) storage.Error!void {
        const self: *SqliteStateStore = @ptrCast(@alignCast(ptr));
        try sqlite.execSql(self.db, "COMMIT");
    }
    fn rollback(ptr: *anyopaque) storage.Error!void {
        const self: *SqliteStateStore = @ptrCast(@alignCast(ptr));
        try sqlite.execSql(self.db, "ROLLBACK");
    }

    pub fn documentCount(self: *SqliteStateStore) sqlite.Error!u64 {
        const st = try Stmt.prepare(self.db, "SELECT count(*) FROM documents");
        defer st.deinit();
        if (!try st.step()) return error.Io;
        return @intCast(st.colInt(0));
    }

    // ------------------------------------------------------ documents

    fn upsert(ptr: *anyopaque, rec: storage.Record) storage.Error!void {
        const self: *SqliteStateStore = @ptrCast(@alignCast(ptr));
        // Never store the main text here: it belongs to the content store.
        var meta = rec.meta;
        meta.text = null;
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        std.json.Stringify.value(meta, .{ .emit_null_optional_fields = false }, &aw.writer) catch return error.OutOfMemory;

        const st = try Stmt.prepare(self.db,
            \\INSERT INTO documents(id, connector, source_id, content_hash, acquired_at, meta)
            \\VALUES(?1, ?2, ?3, ?4, ?5, ?6)
            \\ON CONFLICT(id) DO UPDATE SET connector = excluded.connector, source_id = excluded.source_id,
            \\  content_hash = excluded.content_hash, acquired_at = excluded.acquired_at, meta = excluded.meta
        );
        defer st.deinit();
        try st.blob(1, &rec.id);
        try st.text(2, meta.connector);
        try st.text(3, meta.source_id);
        try st.blob(4, if (rec.content_hash) |*h| h else null);
        try st.int(5, rec.acquired_at);
        try st.text(6, aw.written());
        _ = try st.step();
    }

    /// Builds a record from the current row of `st`, allocating strings from `arena`.
    fn rowToRecord(arena: Allocator, st: Stmt) storage.Error!storage.Record {
        const id_blob = st.colBlob(0) orelse return error.Corrupt;
        if (id_blob.len != @sizeOf(doc.Id)) return error.Corrupt;
        var rec: storage.Record = undefined;
        @memcpy(&rec.id, id_blob);

        rec.content_hash = null;
        if (st.colBlob(1)) |h| {
            if (h.len != @sizeOf(doc.ContentHash)) return error.Corrupt;
            var hash: doc.ContentHash = undefined;
            @memcpy(&hash, h);
            rec.content_hash = hash;
        }
        rec.acquired_at = if (st.isNull(2)) null else st.colInt(2);

        const json = st.colText(3) orelse return error.Corrupt;
        rec.meta = std.json.parseFromSliceLeaky(doc.Document, arena, json, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Corrupt,
        };
        return rec;
    }

    fn find(ptr: *anyopaque, id: doc.Id) storage.Error!?storage.Record {
        const self: *SqliteStateStore = @ptrCast(@alignCast(ptr));
        _ = self.find_arena.reset(.retain_capacity);
        const st = try Stmt.prepare(self.db, "SELECT id, content_hash, acquired_at, meta FROM documents WHERE id = ?1");
        defer st.deinit();
        try st.blob(1, &id);
        if (!try st.step()) return null;
        return try rowToRecord(self.find_arena.allocator(), st);
    }

    fn delete(ptr: *anyopaque, id: doc.Id) storage.Error!void {
        const self: *SqliteStateStore = @ptrCast(@alignCast(ptr));
        const st = try Stmt.prepare(self.db, "DELETE FROM documents WHERE id = ?1");
        defer st.deinit();
        try st.blob(1, &id);
        _ = try st.step();
    }

    fn list(ptr: *anyopaque, arena: Allocator, connector: []const u8, after: ?[]const u8, limit: usize) storage.Error![]storage.Entry {
        const self: *SqliteStateStore = @ptrCast(@alignCast(ptr));
        // Uses the (connector, source_id) index, so each page costs only its size.
        const st = try Stmt.prepare(self.db, if (after == null)
            "SELECT id, source_id FROM documents WHERE connector = ?1 ORDER BY source_id LIMIT ?3"
        else
            "SELECT id, source_id FROM documents WHERE connector = ?1 AND source_id > ?2 ORDER BY source_id LIMIT ?3");
        defer st.deinit();
        try st.text(1, connector);
        if (after) |a| try st.text(2, a);
        try st.int(3, @intCast(limit));
        var out: std.ArrayList(storage.Entry) = .empty;
        while (try st.step()) {
            const id_blob = st.colBlob(0) orelse return error.Corrupt;
            if (id_blob.len != @sizeOf(doc.Id)) return error.Corrupt;
            var e: storage.Entry = undefined;
            @memcpy(&e.id, id_blob);
            e.source_id = try arena.dupe(u8, st.colText(1) orelse return error.Corrupt);
            try out.append(arena, e);
        }
        return out.items;
    }

    fn countOf(ptr: *anyopaque, connector: []const u8) storage.Error!u64 {
        const self: *SqliteStateStore = @ptrCast(@alignCast(ptr));
        const st = try Stmt.prepare(self.db, "SELECT count(*) FROM documents WHERE connector = ?1");
        defer st.deinit();
        try st.text(1, connector);
        if (!try st.step()) return error.Io;
        return @intCast(st.colInt(0));
    }

    /// Forgets the job history of `source`, so the next import of a source
    /// with that name starts from the beginning.
    pub fn forgetSource(self: *SqliteStateStore, source: []const u8) sqlite.Error!void {
        const st = try Stmt.prepare(self.db, "DELETE FROM jobs WHERE source = ?1");
        defer st.deinit();
        try st.text(1, source);
        _ = try st.step();
    }

    fn forEach(ptr: *anyopaque, visitor: storage.Visitor) storage.Error!void {
        const self: *SqliteStateStore = @ptrCast(@alignCast(ptr));
        const st = try Stmt.prepare(self.db, "SELECT id, content_hash, acquired_at, meta FROM documents ORDER BY id");
        defer st.deinit();
        while (try st.step()) {
            _ = self.visit_arena.reset(.retain_capacity);
            const rec = try rowToRecord(self.visit_arena.allocator(), st);
            try visitor.visit(visitor.ptr, rec);
        }
    }

    // ------------------------------------------------------ jobs

    /// Records the start of an import run and returns its id.
    pub fn startJob(self: *SqliteStateStore, source: []const u8, connector: []const u8, now: doc.Timestamp) sqlite.Error!i64 {
        const st = try Stmt.prepare(self.db, "INSERT INTO jobs(source, connector, state, started_at) VALUES(?1, ?2, 'running', ?3)");
        defer st.deinit();
        try st.text(1, source);
        try st.text(2, connector);
        try st.int(3, now);
        _ = try st.step();
        return c.sqlite3_last_insert_rowid(self.db);
    }

    /// Saves progress. Call it as often as losing that much work would hurt.
    /// A null `checkpoint` updates only the counters and keeps the position
    /// saved earlier.
    pub fn saveCheckpoint(self: *SqliteStateStore, job: i64, checkpoint: ?[]const u8, submitted: u64, rejected: u64) sqlite.Error!void {
        const st = try Stmt.prepare(self.db, "UPDATE jobs SET checkpoint = COALESCE(?2, checkpoint), submitted = ?3, rejected = ?4 WHERE id = ?1");
        defer st.deinit();
        try st.int(1, job);
        try st.blob(2, checkpoint);
        try st.int(3, @intCast(submitted));
        try st.int(4, @intCast(rejected));
        _ = try st.step();
    }

    /// Ends a run. `final` must not be `running`.
    pub fn finishJob(self: *SqliteStateStore, job: i64, final: JobState, now: doc.Timestamp, error_message: ?[]const u8) sqlite.Error!void {
        std.debug.assert(final != .running);
        const st = try Stmt.prepare(self.db, "UPDATE jobs SET state = ?2, finished_at = ?3, error = ?4 WHERE id = ?1");
        defer st.deinit();
        try st.int(1, job);
        try st.text(2, @tagName(final));
        try st.int(3, now);
        try st.text(4, error_message);
        _ = try st.step();
    }

    /// The job with this id, strings allocated from `arena`.
    pub fn getJob(self: *SqliteStateStore, arena: Allocator, job: i64) storage.Error!?Job {
        const st = try Stmt.prepare(self.db, job_select ++ " WHERE id = ?1");
        defer st.deinit();
        try st.int(1, job);
        if (!try st.step()) return null;
        return try rowToJob(arena, st);
    }

    /// Where to resume `source`: the checkpoint of its most recent job, if that
    /// job did not complete and saved one. Null means start from the beginning.
    pub fn resumePoint(self: *SqliteStateStore, arena: Allocator, source: []const u8) storage.Error!?[]const u8 {
        const st = try Stmt.prepare(self.db, "SELECT state, checkpoint FROM jobs WHERE source = ?1 ORDER BY id DESC LIMIT 1");
        defer st.deinit();
        try st.text(1, source);
        if (!try st.step()) return null;
        const state = st.colText(0) orelse return error.Corrupt;
        if (std.mem.eql(u8, state, "completed")) return null;
        const cp = st.colBlob(1) orelse return null;
        return try arena.dupe(u8, cp);
    }

    /// The most recent jobs, newest first, strings allocated from `arena`.
    pub fn recentJobs(self: *SqliteStateStore, arena: Allocator, limit: u32) storage.Error![]Job {
        const st = try Stmt.prepare(self.db, job_select ++ " ORDER BY id DESC LIMIT ?1");
        defer st.deinit();
        try st.int(1, limit);
        var out: std.ArrayList(Job) = .empty;
        while (try st.step()) try out.append(arena, try rowToJob(arena, st));
        return out.items;
    }

    pub const SourceCount = struct { source: []const u8, documents: u64 };

    /// Document counts per source name (the `connector` of each record).
    pub fn countsBySource(self: *SqliteStateStore, arena: Allocator) storage.Error![]SourceCount {
        const st = try Stmt.prepare(self.db, "SELECT connector, count(*) FROM documents GROUP BY connector ORDER BY connector");
        defer st.deinit();
        var out: std.ArrayList(SourceCount) = .empty;
        while (try st.step()) {
            try out.append(arena, .{
                .source = try arena.dupe(u8, st.colText(0) orelse return error.Corrupt),
                .documents = @intCast(st.colInt(1)),
            });
        }
        return out.items;
    }

    /// The newest job of `source`, if any.
    pub fn lastJob(self: *SqliteStateStore, arena: Allocator, source: []const u8) storage.Error!?Job {
        const st = try Stmt.prepare(self.db, job_select ++ " WHERE source = ?1 ORDER BY id DESC LIMIT 1");
        defer st.deinit();
        try st.text(1, source);
        if (!try st.step()) return null;
        return try rowToJob(arena, st);
    }

    const job_select = "SELECT id, source, connector, state, started_at, finished_at, submitted, rejected, checkpoint, error FROM jobs";

    fn rowToJob(arena: Allocator, st: Stmt) storage.Error!Job {
        const state_text = st.colText(3) orelse return error.Corrupt;
        return .{
            .id = st.colInt(0),
            .source = try arena.dupe(u8, st.colText(1) orelse return error.Corrupt),
            .connector = try arena.dupe(u8, st.colText(2) orelse return error.Corrupt),
            .state = std.meta.stringToEnum(JobState, state_text) orelse return error.Corrupt,
            .started_at = st.colInt(4),
            .finished_at = if (st.isNull(5)) null else st.colInt(5),
            .submitted = @intCast(st.colInt(6)),
            .rejected = @intCast(st.colInt(7)),
            .checkpoint = if (st.colBlob(8)) |b| try arena.dupe(u8, b) else null,
            .error_message = if (st.colText(9)) |t| try arena.dupe(u8, t) else null,
        };
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn open(path: [:0]const u8) !SqliteStateStore {
    return SqliteStateStore.open(testing.allocator, path, true);
}

test "records round-trip with full metadata, and never keep the text" {
    var s = try open(":memory:");
    defer s.close();
    const ds = s.documents();

    const related = [_]doc.Related{.{ .kind = "translation", .target = "pg-77" }};
    const extra = [_]doc.Extra{.{ .key = "bookshelf", .value = "Best Books Ever" }};
    const d: doc.Document = .{
        .connector = "gutenberg",
        .source_id = "1342",
        .source_dataset = "pg_catalog",
        .dataset_version = "2026-11-08",
        .revision = "r3",
        .canonical_url = "https://example.org/ebooks/1342",
        .title = "Pride and Prejudice — \"quoted\" é",
        .text = "THE MAIN TEXT MUST NOT END UP HERE",
        .summary = "A novel.",
        .language = "en",
        .content_type = "text/plain",
        .author = "Austen, Jane",
        .published_at = 1813,
        .modified_at = 2000,
        .acquired_at = 3000,
        .rights = .{ .license = "Public domain in the USA", .attribution = "Project Gutenberg", .redistribution = .restricted },
        .related = &related,
        .extra = &extra,
    };
    try ds.upsert(.{ .id = d.id(), .content_hash = d.contentHash(), .acquired_at = 3000, .meta = d });

    const rec = (try ds.find(d.id())).?;
    try testing.expectEqual(d.id(), rec.id);
    try testing.expectEqual(d.contentHash().?, rec.content_hash.?);
    try testing.expectEqual(@as(?doc.Timestamp, 3000), rec.acquired_at);
    try testing.expectEqualStrings("Pride and Prejudice — \"quoted\" é", rec.meta.title.?);
    try testing.expectEqualStrings("2026-11-08", rec.meta.dataset_version.?);
    try testing.expectEqualStrings("Public domain in the USA", rec.meta.rights.license.?);
    try testing.expectEqual(doc.Redistribution.restricted, rec.meta.rights.redistribution);
    try testing.expectEqualStrings("pg-77", rec.meta.related[0].target);
    try testing.expectEqualStrings("Best Books Ever", rec.meta.extra[0].value);
    try testing.expectEqual(@as(?doc.Timestamp, 1813), rec.meta.published_at);
    try testing.expect(rec.meta.text == null);

    // Not even in the raw row.
    const st = try Stmt.prepare(s.db, "SELECT count(*) FROM documents WHERE meta LIKE '%MAIN TEXT%'");
    defer st.deinit();
    try testing.expect(try st.step());
    try testing.expectEqual(@as(i64, 0), st.colInt(0));
}

test "upsert replaces, delete removes, unknown ids are null" {
    var s = try open(":memory:");
    defer s.close();
    const ds = s.documents();
    const d: doc.Document = .{ .connector = "c", .source_id = "1", .content_ref = "r", .revision = "1" };
    try testing.expect((try ds.find(d.id())) == null);
    try ds.upsert(.{ .id = d.id(), .content_hash = null, .acquired_at = null, .meta = d });
    var d2 = d;
    d2.revision = "2";
    try ds.upsert(.{ .id = d.id(), .content_hash = null, .acquired_at = 5, .meta = d2 });
    try testing.expectEqual(@as(u64, 1), try s.documentCount());
    const rec = (try ds.find(d.id())).?;
    try testing.expectEqualStrings("2", rec.meta.revision.?);
    try testing.expect(rec.content_hash == null);
    try ds.delete(d.id());
    try ds.delete(d.id());
    try testing.expect((try ds.find(d.id())) == null);
}

test "forEach visits everything in a stable order and stops on a visitor error" {
    var s = try open(":memory:");
    defer s.close();
    const ds = s.documents();
    for ([_][]const u8{ "a", "b", "c", "d" }) |sid| {
        const d: doc.Document = .{ .connector = "c", .source_id = sid, .content_ref = "r", .title = sid };
        try ds.upsert(.{ .id = d.id(), .content_hash = null, .acquired_at = null, .meta = d });
    }
    const V = struct {
        titles: [8][]const u8 = undefined,
        n: usize = 0,
        stop_at: usize = 99,
        fn visit(ptr: *anyopaque, rec: storage.Record) storage.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // Strings must be valid during the call even though the arena is reused later.
            self.titles[self.n] = rec.meta.title.?;
            self.n += 1;
            if (self.n == self.stop_at) return error.Io;
        }
    };
    var v1: V = .{};
    try ds.forEach(.{ .ptr = &v1, .visit = V.visit });
    try testing.expectEqual(@as(usize, 4), v1.n);

    var v2: V = .{ .stop_at = 2 };
    try testing.expectError(error.Io, ds.forEach(.{ .ptr = &v2, .visit = V.visit }));
    try testing.expectEqual(@as(usize, 2), v2.n);
}

test "a damaged metadata row is Corrupt, not a crash" {
    var s = try open(":memory:");
    defer s.close();
    const ds = s.documents();
    const d: doc.Document = .{ .connector = "c", .source_id = "1", .content_ref = "r" };
    try ds.upsert(.{ .id = d.id(), .content_hash = null, .acquired_at = null, .meta = d });
    try sqlite.execSql(s.db, "UPDATE documents SET meta = '{not json'");
    try testing.expectError(error.Corrupt, ds.find(d.id()));
    try sqlite.execSql(s.db, "UPDATE documents SET meta = '{\"source_id\":\"1\"}'"); // required field missing
    try testing.expectError(error.Corrupt, ds.find(d.id()));
    try sqlite.execSql(s.db, "UPDATE documents SET meta = '{\"connector\":\"c\",\"source_id\":\"1\",\"from_the_future\":1}'");
    try testing.expect((try ds.find(d.id())) != null); // unknown fields are ignored
    try sqlite.execSql(s.db, "UPDATE documents SET content_hash = x'0102'");
    try testing.expectError(error.Corrupt, ds.find(d.id()));
}

test "job lifecycle with checkpoints and counters" {
    var s = try open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const j = try s.startJob("gutenberg-local", "gutenberg", 100);
    var job = (try s.getJob(a, j)).?;
    try testing.expectEqual(JobState.running, job.state);
    try testing.expectEqual(@as(doc.Timestamp, 100), job.started_at);

    try s.saveCheckpoint(j, "row:400", 400, 1);
    try s.saveCheckpoint(j, "row:500", 500, 3);
    try s.saveCheckpoint(j, null, 510, 4); // counters only: the position stays
    try s.finishJob(j, .completed, 200, null);
    job = (try s.getJob(a, j)).?;
    try testing.expectEqual(JobState.completed, job.state);
    try testing.expectEqual(@as(?doc.Timestamp, 200), job.finished_at);
    try testing.expectEqual(@as(u64, 510), job.submitted);
    try testing.expectEqual(@as(u64, 4), job.rejected);
    try testing.expectEqualStrings("row:500", job.checkpoint.?);
    try testing.expect((try s.getJob(a, 9999)) == null);

    const j2 = try s.startJob("gutenberg-local", "gutenberg", 300);
    try s.finishJob(j2, .failed, 310, "disk full");
    job = (try s.getJob(a, j2)).?;
    try testing.expectEqualStrings("disk full", job.error_message.?);
}

test "resume point: only after an unfinished job that saved a checkpoint" {
    var s = try open(":memory:");
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect((try s.resumePoint(a, "src")) == null); // never ran

    const j1 = try s.startJob("src", "gutenberg", 1);
    try s.saveCheckpoint(j1, "pos-10", 10, 0);
    try s.finishJob(j1, .cancelled, 2, null);
    try testing.expectEqualStrings("pos-10", (try s.resumePoint(a, "src")).?);

    const j2 = try s.startJob("src", "gutenberg", 3);
    try s.finishJob(j2, .failed, 4, "boom"); // failed before any checkpoint
    try testing.expect((try s.resumePoint(a, "src")) == null);

    const j3 = try s.startJob("src", "gutenberg", 5);
    try s.saveCheckpoint(j3, "pos-99", 99, 0);
    try s.finishJob(j3, .completed, 6, null);
    try testing.expect((try s.resumePoint(a, "src")) == null); // finished: next run starts over

    try testing.expect((try s.resumePoint(a, "other-source")) == null); // sources are independent
}

test "jobs left running by a crash are found and marked interrupted on reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pb, ".zig-cache/tmp/{s}/state.db", .{tmp.sub_path}, 0);

    var job_id: i64 = undefined;
    {
        var s = try open(path);
        defer s.close();
        try testing.expectEqual(@as(u64, 0), s.recovered_jobs);
        job_id = try s.startJob("wiki", "wikipedia", 10);
        try s.saveCheckpoint(job_id, "offset:123456", 42, 1);
        // No finishJob: the process "dies" here.
    }
    var s = try open(path);
    defer s.close();
    try testing.expectEqual(@as(u64, 1), s.recovered_jobs);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const job = (try s.getJob(arena.allocator(), job_id)).?;
    try testing.expectEqual(JobState.interrupted, job.state);
    try testing.expectEqualStrings("offset:123456", (try s.resumePoint(arena.allocator(), "wiki")).?);
}

test "state persists across reopen; a newer schema is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&pb, ".zig-cache/tmp/{s}/state.db", .{tmp.sub_path}, 0);
    const d: doc.Document = .{ .connector = "c", .source_id = "kept", .content_ref = "r", .title = "Kept" };
    {
        var s = try open(path);
        defer s.close();
        try s.documents().upsert(.{ .id = d.id(), .content_hash = null, .acquired_at = 1, .meta = d });
    }
    {
        var s = try open(path);
        defer s.close();
        try testing.expectEqualStrings("Kept", (try s.documents().find(d.id())).?.meta.title.?);
        try sqlite.execSql(s.db, "PRAGMA user_version = 99");
    }
    try testing.expectError(error.NewerSchema, open(path));
}

test "full pipeline over the persistent stores, then a rebuild from them" {
    const content_sqlite = @import("content_sqlite.zig");
    const index_sqlite = @import("index_sqlite.zig");
    const pipeline = @import("pipeline.zig");
    const rebuild = @import("rebuild.zig");

    var state = try open(":memory:");
    defer state.close();
    var content = try content_sqlite.SqliteContentStore.open(testing.allocator, ":memory:", true);
    defer content.close();
    var live = try index_sqlite.SqliteIndex.open(":memory:", .{});
    defer live.close();

    const Now = struct {
        fn f() doc.Timestamp {
            return 7;
        }
    };
    var pipe = pipeline.Pipeline.init(content.store(), state.documents(), live.indexer(), .{ .now = Now.f });
    try pipe.submit(.{ .connector = "g", .source_id = "1", .title = "Moby Dick", .text = "Call me Ishmael.", .language = "en", .revision = "r1" });
    try pipe.submit(.{ .connector = "g", .source_id = "2", .title = "Emma", .text = "Emma Woodhouse, handsome, clever, and rich", .language = "en" });
    try pipe.submit(.{ .connector = "g", .source_id = "1", .title = "Moby Dick", .text = "Call me Ishmael.", .language = "en", .revision = "r1" }); // duplicate
    try testing.expectEqual(@as(u64, 2), pipe.stats.added);
    try testing.expectEqual(@as(u64, 1), pipe.stats.unchanged);

    var fresh = try index_sqlite.SqliteIndex.open(":memory:", .{});
    defer fresh.close();
    const stats = try rebuild.rebuild(testing.allocator, fresh.indexer(), content.store(), state.documents());
    try testing.expectEqual(@as(u64, 2), stats.reindexed);
    try testing.expectEqual(@as(u64, 0), stats.unrecoverable);
    try fresh.indexer().check();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "ishmael", "emma clever" }) |q| {
        const a = try live.searcher().search(arena.allocator(), .{ .text = q });
        const b = try fresh.searcher().search(arena.allocator(), .{ .text = q });
        try testing.expectEqual(@as(usize, 1), a.hits.len);
        try testing.expectEqual(a.hits[0].id, b.hits[0].id);
        try testing.expectEqualStrings(a.hits[0].title.?, b.hits[0].title.?);
    }
}

test "recent jobs, last job and counts by source" {
    var s = try SqliteStateStore.open(testing.allocator, ":memory:", true);
    defer s.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try s.recentJobs(a, 10)).len);
    try testing.expect((try s.lastJob(a, "x")) == null);

    const j1 = try s.startJob("alpha", "files", 100);
    try s.finishJob(j1, .completed, 110, null);
    const j2 = try s.startJob("beta", "files", 120);
    try s.finishJob(j2, .failed, 130, "boom");
    const j3 = try s.startJob("alpha", "files", 140);
    _ = j3;

    const recent = try s.recentJobs(a, 2);
    try testing.expectEqual(@as(usize, 2), recent.len);
    try testing.expectEqualStrings("alpha", recent[0].source); // newest first
    try testing.expectEqual(JobState.running, recent[0].state);
    try testing.expectEqualStrings("beta", recent[1].source);
    try testing.expectEqualStrings("boom", recent[1].error_message.?);
    const last = (try s.lastJob(a, "alpha")).?;
    try testing.expectEqual(@as(i64, 3), last.id);

    const docs = s.documents();
    try docs.upsert(.{ .id = doc.idFromSource("alpha", "1"), .content_hash = null, .acquired_at = 1, .meta = .{ .connector = "alpha", .source_id = "1" } });
    try docs.upsert(.{ .id = doc.idFromSource("alpha", "2"), .content_hash = null, .acquired_at = 1, .meta = .{ .connector = "alpha", .source_id = "2" } });
    try docs.upsert(.{ .id = doc.idFromSource("beta", "1"), .content_hash = null, .acquired_at = 1, .meta = .{ .connector = "beta", .source_id = "1" } });
    const counts = try s.countsBySource(a);
    try testing.expectEqual(@as(usize, 2), counts.len);
    try testing.expectEqualStrings("alpha", counts[0].source);
    try testing.expectEqual(@as(u64, 2), counts[0].documents);
    try testing.expectEqual(@as(u64, 1), counts[1].documents);
}
