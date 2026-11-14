//! Raw access to the vendored SQLite C API (see vendor/sqlite/README.md).
//!
//! Only the index backend should import this file. Nothing outside it may
//! depend on SQLite types (docs/decisions/0002-core-module-layout.md).

const std = @import("std");
pub const c = @import("sqlite_c");

const testing = std.testing;

/// Runs `sql` (no rows expected) and returns the result code.
fn exec(db: *c.sqlite3, sql: [:0]const u8) c_int {
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
    try testing.expectEqual(c.SQLITE_OK, exec(db, "CREATE VIRTUAL TABLE t USING fts5(a)"));
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
    try testing.expectEqual(c.SQLITE_OK, exec(db,
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
    try testing.expectEqual(c.SQLITE_OK, exec(db,
        \\CREATE VIRTUAL TABLE d USING fts5(body);
        \\INSERT INTO d(body) VALUES ('alpha beta');
        \\INSERT INTO d(d) VALUES ('integrity-check');
        \\INSERT INTO d(d) VALUES ('rebuild');
    ));
}
