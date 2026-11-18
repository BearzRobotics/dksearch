//! Raw access to the vendored SQLite C API (see vendor/sqlite/README.md), plus
//! the small helpers shared by every SQLite-backed store: statements,
//! error mapping and schema migrations.
//!
//! Only the SQLite-backed stores and the index backend may import this file.
//! Nothing outside them depends on SQLite types
//! (docs/decisions/0002-core-module-layout.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const c = @import("sqlite_c");

/// The failures every SQLite-backed store can report. A subset of each
/// store interface's error set, so it coerces to them.
pub const Error = error{ NoSpace, Corrupt, Io, OutOfMemory };

pub fn mapRc(rc: c_int) Error {
    return switch (rc & 0xff) {
        c.SQLITE_FULL => error.NoSpace,
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.Corrupt,
        else => error.Io,
    };
}

/// SQLITE_TRANSIENT: tells SQLite to copy bound text/blobs.
// SQLITE_TRANSIENT is the address -1 used as a destructor marker. It is not a
// real function, and a function pointer type demands alignment on ARM, so a
// direct @ptrFromInt or @ptrCast does not compile there; reading the same
// bits through an extern union does.
const transient: c.sqlite3_destructor_type = (extern union {
    bits: usize,
    destructor: c.sqlite3_destructor_type,
}{ .bits = std.math.maxInt(usize) }).destructor;

/// Opens (creating if needed) a read-write database.
pub fn open(path: [:0]const u8) Error!*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
    if (rc != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return mapRc(rc);
    }
    return db.?;
}

/// Opens an existing database read-only; never creates or changes anything.
pub fn openReadOnly(path: [:0]const u8) Error!*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READONLY, null);
    if (rc != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return mapRc(rc);
    }
    return db.?;
}

/// True if SQLite's own `PRAGMA integrity_check` reports "ok".
pub fn integrityOk(db: *c.sqlite3) Error!bool {
    const st = try Stmt.prepare(db, "PRAGMA integrity_check(1)");
    defer st.deinit();
    if (!try st.step()) return error.Io;
    const msg = st.colText(0) orelse return false;
    return std.mem.eql(u8, msg, "ok");
}

pub fn execSql(db: *c.sqlite3, sql: [:0]const u8) Error!void {
    const rc = c.sqlite3_exec(db, sql.ptr, null, null, null);
    if (rc != c.SQLITE_OK) return mapRc(rc);
}

pub const Stmt = struct {
    s: *c.sqlite3_stmt,

    pub fn prepare(db: *c.sqlite3, sql: [:0]const u8) Error!Stmt {
        var s: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql.ptr, -1, &s, null);
        if (rc != c.SQLITE_OK) return mapRc(rc);
        return .{ .s = s.? };
    }
    pub fn deinit(self: Stmt) void {
        _ = c.sqlite3_finalize(self.s);
    }
    /// Binds text, or NULL for a null slice.
    pub fn text(self: Stmt, i: c_int, v: ?[]const u8) Error!void {
        const rc = if (v) |x|
            c.sqlite3_bind_text(self.s, i, x.ptr, @intCast(x.len), transient)
        else
            c.sqlite3_bind_null(self.s, i);
        if (rc != c.SQLITE_OK) return mapRc(rc);
    }
    /// Binds a blob, or NULL for a null slice.
    pub fn blob(self: Stmt, i: c_int, v: ?[]const u8) Error!void {
        const rc = if (v) |x|
            c.sqlite3_bind_blob(self.s, i, x.ptr, @intCast(x.len), transient)
        else
            c.sqlite3_bind_null(self.s, i);
        if (rc != c.SQLITE_OK) return mapRc(rc);
    }
    pub fn real(self: Stmt, i: c_int, v: f64) Error!void {
        const rc = c.sqlite3_bind_double(self.s, i, v);
        if (rc != c.SQLITE_OK) return mapRc(rc);
    }
    pub fn int(self: Stmt, i: c_int, v: ?i64) Error!void {
        const rc = if (v) |x| c.sqlite3_bind_int64(self.s, i, x) else c.sqlite3_bind_null(self.s, i);
        if (rc != c.SQLITE_OK) return mapRc(rc);
    }
    /// True if a row is available, false when done.
    pub fn step(self: Stmt) Error!bool {
        const rc = c.sqlite3_step(self.s);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => mapRc(rc),
        };
    }
    pub fn isNull(self: Stmt, i: c_int) bool {
        return c.sqlite3_column_type(self.s, i) == c.SQLITE_NULL;
    }
    /// Borrowed from SQLite; valid until the next step or deinit.
    pub fn colText(self: Stmt, i: c_int) ?[]const u8 {
        const p = c.sqlite3_column_text(self.s, i) orelse return null;
        const n: usize = @intCast(c.sqlite3_column_bytes(self.s, i));
        return p[0..n];
    }
    /// Borrowed from SQLite; valid until the next step or deinit.
    pub fn colBlob(self: Stmt, i: c_int) ?[]const u8 {
        const p = c.sqlite3_column_blob(self.s, i) orelse return null;
        const n: usize = @intCast(c.sqlite3_column_bytes(self.s, i));
        return @as([*]const u8, @ptrCast(p))[0..n];
    }
    pub fn colInt(self: Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(self.s, i);
    }
    pub fn colFloat(self: Stmt, i: c_int) f64 {
        return c.sqlite3_column_double(self.s, i);
    }
};

pub fn userVersion(db: *c.sqlite3) Error!i64 {
    const st = try Stmt.prepare(db, "PRAGMA user_version");
    defer st.deinit();
    if (!try st.step()) return error.Io;
    return st.colInt(0);
}

pub const MigrateError = Error || error{
    /// Read-only inspection of a file that is older than this program: it
    /// would be upgraded by the next normal open, which inspection must not do.
    NeedsUpgrade,
    /// The file was written by a newer version of this program. Refusing to
    /// touch it: open it with the version that wrote it, or restore a backup.
    NewerSchema,
    /// A migration step failed. It was rolled back; the file is unchanged
    /// (and a backup of the pre-migration state exists next to it).
    MigrationFailed,
};

/// For read-only inspection: the schema must already be at `steps.len`.
pub fn requireCurrent(db: *c.sqlite3, steps: usize) MigrateError!void {
    const v = try userVersion(db);
    if (v < 0 or v > steps) return error.NewerSchema;
    if (v < steps) return error.NeedsUpgrade;
}

/// Brings the database up to `steps.len`. Step `i` takes the schema from
/// version `i` to `i + 1` and must be one SQL script. The version is kept in
/// `PRAGMA user_version`.
///
///  * A new file (version 0) simply gets every step.
///  * An older file is first copied to `PATH.pre-vN` (a consistent copy made
///    with `VACUUM INTO`; `N` is the version being left), then each missing
///    step runs in its own transaction together with the version bump. A
///    failing step is rolled back, so the file is never half-migrated.
///  * A newer file is refused.
///
/// In-memory databases are migrated without a backup.
pub fn migrate(db: *c.sqlite3, path: [:0]const u8, steps: []const [:0]const u8) MigrateError!void {
    const current = try userVersion(db);
    if (current < 0 or current > steps.len) return error.NewerSchema;
    const from: usize = @intCast(current);
    if (from == steps.len) return;

    if (from > 0 and !std.mem.eql(u8, path, ":memory:") and path.len > 0) {
        var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
        const backup = std.fmt.bufPrintSentinel(&buf, "{s}.pre-v{d}", .{ path, from }, 0) catch return error.Io;
        _ = std.c.unlink(backup.ptr); // a stale copy from an earlier attempt would make VACUUM INTO fail
        const st = try Stmt.prepare(db, "VACUUM INTO ?1");
        defer st.deinit();
        try st.text(1, backup);
        _ = try st.step();
    }

    for (steps[from..], from..) |sql, i| {
        try execSql(db, "BEGIN IMMEDIATE");
        var ok = false;
        defer if (!ok) execSql(db, "ROLLBACK") catch {};
        execSql(db, sql) catch return error.MigrationFailed;
        var vbuf: [48]u8 = undefined;
        const bump = std.fmt.bufPrintSentinel(&vbuf, "PRAGMA user_version = {d}", .{i + 1}, 0) catch return error.Io;
        execSql(db, bump) catch return error.MigrationFailed;
        try execSql(db, "COMMIT");
        ok = true;
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Runs `sql` (no rows expected) and returns the result code.
fn rawExec(db: *c.sqlite3, sql: [:0]const u8) c_int {
    return c.sqlite3_exec(db, sql.ptr, null, null, null);
}

fn openMemory() !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return error.OpenFailed;
    }
    return db.?;
}

test "vendored SQLite is the pinned version" {
    try testing.expectEqualStrings("3.54.1", std.mem.span(c.sqlite3_libversion()));
}

test "FTS5 is compiled in; extension loading is not" {
    const db = try openMemory();
    defer _ = c.sqlite3_close(db);
    try testing.expectEqual(c.SQLITE_OK, rawExec(db, "CREATE VIRTUAL TABLE t USING fts5(a)"));
    // The header still declares the loader; what matters is how SQLite was built.
    try testing.expect(c.sqlite3_compileoption_used("OMIT_LOAD_EXTENSION") != 0);
    try testing.expect(c.sqlite3_compileoption_used("ENABLE_FTS5") != 0);
    try testing.expect(c.sqlite3_compileoption_used("DQS=0") != 0);
}

/// Returns the first column of the first row as an owned string.
fn queryText(db: *c.sqlite3, sql: [:0]const u8) ![]u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.NoRow;
    const p = c.sqlite3_column_text(stmt, 0) orelse return error.NullColumn;
    return testing.allocator.dupe(u8, std.mem.span(p));
}

test "FTS5: weighted BM25 ranking, phrase query and snippet" {
    const db = try openMemory();
    defer _ = c.sqlite3_close(db);
    try testing.expectEqual(c.SQLITE_OK, rawExec(db,
        \\CREATE VIRTUAL TABLE d USING fts5(title, body, tokenize = 'unicode61 remove_diacritics 2');
        \\INSERT INTO d(rowid, title, body) VALUES
        \\ (1, 'Pride and Prejudice', 'It is a truth universally acknowledged'),
        \\ (2, 'A truth about whales', 'Call me Ishmael. Some years ago'),
        \\ (3, 'Café notes', 'nothing relevant at all');
    ));

    // Title weighted 10x body: the doc with "truth" in its title wins.
    const first = try queryText(db, "SELECT rowid FROM d WHERE d MATCH 'truth' ORDER BY bm25(d, 10.0, 1.0) LIMIT 1");
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("2", first);

    // Phrase: adjacent words only.
    const phrase = try queryText(db, "SELECT rowid FROM d WHERE d MATCH '\"truth universally\"'");
    defer testing.allocator.free(phrase);
    try testing.expectEqualStrings("1", phrase);

    // Diacritics folded by the tokenizer.
    const folded = try queryText(db, "SELECT rowid FROM d WHERE d MATCH 'cafe'");
    defer testing.allocator.free(folded);
    try testing.expectEqualStrings("3", folded);

    const snip = try queryText(db, "SELECT snippet(d, 1, '[', ']', '...', 5) FROM d WHERE d MATCH 'ishmael'");
    defer testing.allocator.free(snip);
    try testing.expect(std.mem.indexOf(u8, snip, "[Ishmael]") != null);
}

test "FTS5: integrity-check and rebuild commands are available" {
    const db = try openMemory();
    defer _ = c.sqlite3_close(db);
    try testing.expectEqual(c.SQLITE_OK, rawExec(db,
        \\CREATE VIRTUAL TABLE d USING fts5(body);
        \\INSERT INTO d(body) VALUES ('alpha beta');
        \\INSERT INTO d(d) VALUES ('integrity-check');
        \\INSERT INTO d(d) VALUES ('rebuild');
    ));
}

fn tmpPath(tmp: *std.testing.TmpDir, buf: []u8, name: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name }, 0);
}

test "migrate: fresh file gets every step; reopening is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const path = try tmpPath(&tmp, &pb, "m.db");
    const steps = [_][:0]const u8{ "CREATE TABLE a(x)", "CREATE TABLE b(y)" };
    {
        const db = try open(path);
        defer _ = c.sqlite3_close(db);
        try execSql(db, "PRAGMA synchronous = OFF");
        try migrate(db, path, &steps);
        try testing.expectEqual(@as(i64, 2), try userVersion(db));
    }
    const db = try open(path);
    defer _ = c.sqlite3_close(db);
    try migrate(db, path, &steps);
    try testing.expectEqual(@as(i64, 2), try userVersion(db));
}

test "migrate: older file is backed up, then upgraded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const path = try tmpPath(&tmp, &pb, "m.db");
    {
        const db = try open(path);
        defer _ = c.sqlite3_close(db);
        try execSql(db, "PRAGMA synchronous = OFF");
        try migrate(db, path, &.{"CREATE TABLE a(x); INSERT INTO a VALUES (1)"});
    }
    const db = try open(path);
    defer _ = c.sqlite3_close(db);
    try execSql(db, "PRAGMA synchronous = OFF");
    try migrate(db, path, &.{ "CREATE TABLE a(x); INSERT INTO a VALUES (1)", "ALTER TABLE a ADD COLUMN y DEFAULT 7" });
    try testing.expectEqual(@as(i64, 2), try userVersion(db));

    // The backup holds the old schema (version 1, no column y).
    var bb: [300]u8 = undefined;
    const backup = try std.fmt.bufPrintSentinel(&bb, "{s}.pre-v1", .{path}, 0);
    const bdb = try open(backup);
    defer _ = c.sqlite3_close(bdb);
    try testing.expectEqual(@as(i64, 1), try userVersion(bdb));
    try testing.expect(c.SQLITE_OK != c.sqlite3_exec(bdb, "SELECT y FROM a", null, null, null));
}

test "migrate: a failing step rolls back completely and leaves the version alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const path = try tmpPath(&tmp, &pb, "m.db");
    const db = try open(path);
    defer _ = c.sqlite3_close(db);
    try execSql(db, "PRAGMA synchronous = OFF");
    try migrate(db, path, &.{"CREATE TABLE a(x)"});

    // Step 2 does something visible, then fails: none of it may survive.
    const bad = [_][:0]const u8{ "CREATE TABLE a(x)", "CREATE TABLE half(z); INSERT INTO no_such_table VALUES (1)" };
    try testing.expectError(error.MigrationFailed, migrate(db, path, &bad));
    try testing.expectEqual(@as(i64, 1), try userVersion(db));
    try testing.expect(c.SQLITE_OK != c.sqlite3_exec(db, "SELECT z FROM half", null, null, null));
    // And a corrected step can still be applied afterwards.
    try migrate(db, path, &.{ "CREATE TABLE a(x)", "CREATE TABLE half(z)" });
    try testing.expectEqual(@as(i64, 2), try userVersion(db));
}

test "migrate: a file from a newer version is refused untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [256]u8 = undefined;
    const path = try tmpPath(&tmp, &pb, "m.db");
    const db = try open(path);
    defer _ = c.sqlite3_close(db);
    try execSql(db, "PRAGMA synchronous = OFF");
    try migrate(db, path, &.{ "CREATE TABLE a(x)", "CREATE TABLE b(y)", "CREATE TABLE c(z)" });
    try testing.expectError(error.NewerSchema, migrate(db, path, &.{ "CREATE TABLE a(x)", "CREATE TABLE b(y)" }));
    try testing.expectEqual(@as(i64, 3), try userVersion(db));
}
