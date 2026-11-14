//! Operator maintenance: checking the stored data and making backups.
//!
//! Both work on the SQLite files directly and are safe while `dksearch serve`
//! or `dksearch import` is running: files are opened read-only, nothing is
//! upgraded or recovered, and a backup is a consistent snapshot.
//!
//! What matters most is `state.db` (document records and job positions) and
//! `content.db` (the retained text). They are the only copy of what was
//! imported. `index.db` is derived: `rebuild` recreates it, so it is checked
//! but not backed up.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");
const c = sqlite.c;
const storage = @import("storage.zig");
const index_sqlite = @import("index_sqlite.zig");
const content_sqlite = @import("content_sqlite.zig");
const state_sqlite = @import("state_sqlite.zig");

pub const Paths = struct {
    index: [:0]const u8,
    state: [:0]const u8,
    content: [:0]const u8,
};

pub const FileState = enum {
    /// The file does not exist (nothing imported yet, or deleted).
    absent,
    ok,
    /// SQLite or a content check found damage.
    damaged,
    /// Written by a newer dksearch; this one will not touch it.
    newer_version,
    /// Older than this program; any normal command upgrades it first.
    needs_upgrade,
    /// Could not be opened or read (permissions, I/O error).
    unreadable,
};

pub const Report = struct {
    index: FileState = .absent,
    state: FileState = .absent,
    content: FileState = .absent,
    /// Records in `state.db`.
    documents: u64 = 0,
    /// Documents in `index.db`, when it could be read.
    indexed: ?u64 = null,
    /// Retained texts in `content.db`.
    texts: u64 = 0,
    /// Records whose text was not retained (retain_text = false, or lost).
    without_text: u64 = 0,
    /// Retained texts that fail decompression, size or hash verification.
    corrupt_texts: u64 = 0,
    /// Texts no record refers to: harmless leftovers of interrupted imports.
    orphan_texts: u64 = 0,
    /// Whether the cross-checks ran (they need both state and content readable).
    cross_checked: bool = false,

    /// No damage and nothing refused to open. Absent files and the notes
    /// below are not problems.
    pub fn healthy(self: Report) bool {
        for ([_]FileState{ self.index, self.state, self.content }) |f| {
            switch (f) {
                .absent, .ok => {},
                else => return false,
            }
        }
        return self.corrupt_texts == 0;
    }
};

/// An exclusive advisory lock on `data_dir/write.lock`, held by commands that
/// write the stores (`import`, `rebuild`) so that two of them never run on one
/// data directory: the second would, among other things, mark the first one's
/// running job as interrupted. The operating system releases it when the
/// process ends, however it ends, so a crash leaves no stale lock.
pub const WriterLock = struct {
    file: Io.File,

    pub const Error = error{
        /// Another process holds it.
        Busy,
        /// The lock file could not be created or locked (permissions, disk).
        Io,
    };

    pub fn acquire(io: Io, dir: Io.Dir, name: []const u8) Error!WriterLock {
        const file = dir.createFile(io, name, .{ .truncate = false }) catch return error.Io;
        errdefer file.close(io);
        const got = file.tryLock(io, .exclusive) catch return error.Io;
        if (!got) return error.Busy;
        return .{ .file = file };
    }

    pub fn release(self: WriterLock, io: Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};

pub const CheckError = error{OutOfMemory};

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn mapOpen(e: sqlite.MigrateError) FileState {
    return switch (e) {
        error.NewerSchema => .newer_version,
        error.NeedsUpgrade => .needs_upgrade,
        error.Corrupt => .damaged,
        else => .unreadable,
    };
}

pub fn check(gpa: Allocator, io: Io, paths: Paths) CheckError!Report {
    var r: Report = .{};

    var state: ?state_sqlite.SqliteStateStore = null;
    defer if (state) |*s| s.close();
    var content: ?content_sqlite.SqliteContentStore = null;
    defer if (content) |*s| s.close();

    if (exists(io, paths.state)) {
        if (state_sqlite.SqliteStateStore.inspect(gpa, paths.state)) |opened| {
            var s = opened;
            state = s;
            r.state = if (sqlite.integrityOk(s.db) catch false) .ok else .damaged;
            r.documents = s.documentCount() catch blk: {
                r.state = .damaged;
                break :blk 0;
            };
        } else |e| r.state = mapOpen(e);
    }
    if (exists(io, paths.content)) {
        if (content_sqlite.SqliteContentStore.inspect(gpa, paths.content)) |opened| {
            var s = opened;
            content = s;
            r.content = if (sqlite.integrityOk(s.db) catch false) .ok else .damaged;
            r.texts = s.count() catch 0;
        } else |e| r.content = mapOpen(e);
    }
    if (exists(io, paths.index)) {
        if (index_sqlite.SqliteIndex.open(paths.index, .{ .sync = .off })) |opened| {
            var idx = opened;
            defer idx.close();
            const intact = (sqlite.integrityOk(idx.db) catch false) and blk: {
                idx.indexer().check() catch break :blk false;
                break :blk true;
            };
            r.index = if (intact) .ok else .damaged;
            r.indexed = idx.count() catch null;
        } else |e| r.index = switch (e) {
            error.SchemaMismatch => .newer_version,
            error.Corrupt => .damaged,
            else => .unreadable,
        };
    }

    // Cross-checks: every record's text must exist and verify. Reading each
    // text decompresses it and compares its SHA-256, so this is the slow part.
    if (r.state == .ok and r.content == .ok) {
        r.cross_checked = true;
        const Ctx = struct {
            content: storage.ContentStore,
            gpa: Allocator,
            report: *Report,
            fn visit(ptr: *anyopaque, rec: storage.Record) storage.Error!void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const text = self.content.get(self.gpa, rec.id) catch |e| switch (e) {
                    error.NotFound => {
                        self.report.without_text += 1;
                        return;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        self.report.corrupt_texts += 1;
                        return;
                    },
                };
                self.gpa.free(text);
            }
        };
        var ctx: Ctx = .{ .content = content.?.store(), .gpa = gpa, .report = &r };
        state.?.documents().forEach(.{ .ptr = &ctx, .visit = Ctx.visit }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => r.state = .damaged,
        };
        const referenced = r.documents -| r.without_text;
        r.orphan_texts = r.texts -| referenced;
    }
    return r;
}

pub const BackupError = error{
    /// The source could not be read, or the destination could not be written.
    Io,
    /// The copy was written but did not pass SQLite's integrity check.
    VerifyFailed,
    NoSpace,
};

/// Writes a consistent snapshot of the SQLite database at `src` to the new
/// file `dest`, then verifies the copy. `dest` must not exist. Safe while
/// other processes write to `src`; the snapshot is the state at one instant.
/// `durable` syncs the copy to disk before returning; only tests turn it off.
pub fn backupFile(src: [:0]const u8, dest: [:0]const u8, durable: bool) BackupError!void {
    const db = sqlite.openReadOnly(src) catch return error.Io;
    defer _ = c.sqlite3_close(db);
    sqlite.execSql(db, if (durable) "PRAGMA synchronous = FULL" else "PRAGMA synchronous = OFF") catch return error.Io;
    {
        const st = sqlite.Stmt.prepare(db, "VACUUM INTO ?1") catch return error.Io;
        defer st.deinit();
        st.text(1, dest) catch return error.Io;
        _ = st.step() catch |e| switch (e) {
            error.NoSpace => return error.NoSpace,
            else => return error.Io,
        };
    }
    const copy = sqlite.openReadOnly(dest) catch return error.VerifyFailed;
    defer _ = c.sqlite3_close(copy);
    if (!(sqlite.integrityOk(copy) catch false)) return error.VerifyFailed;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const doc = @import("document.zig");
const pipeline = @import("pipeline.zig");

fn tmpPath(buf: []u8, tmp: *testing.TmpDir, name: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name }, 0);
}

/// Creates the three files with `n` documents, the way an import would.
fn populate(tmp: *testing.TmpDir, n: usize, pb: *[3][160]u8) !Paths {
    const paths: Paths = .{
        .index = try tmpPath(&pb[0], tmp, "index.db"),
        .state = try tmpPath(&pb[1], tmp, "state.db"),
        .content = try tmpPath(&pb[2], tmp, "content.db"),
    };
    var state = try state_sqlite.SqliteStateStore.open(testing.allocator, paths.state, true);
    defer state.close();
    var content = try content_sqlite.SqliteContentStore.open(testing.allocator, paths.content, true);
    defer content.close();
    var index = try index_sqlite.SqliteIndex.open(paths.index, .{ .sync = .off });
    defer index.close();
    var pipe = pipeline.Pipeline.init(content.store(), state.documents(), index.indexer(), .{ .now = fixedNow });
    for (0..n) |i| {
        var idb: [16]u8 = undefined;
        var tb: [40]u8 = undefined;
        const d: doc.Document = .{
            .connector = "t",
            .source_id = try std.fmt.bufPrint(&idb, "doc{d}", .{i}),
            .text = try std.fmt.bufPrint(&tb, "text of document number {d}", .{i}),
        };
        _ = try pipe.sink().submit(d);
    }
    return paths;
}

fn fixedNow() doc.Timestamp {
    return 1;
}

test "a healthy data directory checks out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [3][160]u8 = undefined;
    const paths = try populate(&tmp, 5, &pb);

    const r = try check(testing.allocator, testing.io, paths);
    try testing.expect(r.healthy());
    try testing.expectEqual(FileState.ok, r.index);
    try testing.expectEqual(FileState.ok, r.state);
    try testing.expectEqual(FileState.ok, r.content);
    try testing.expectEqual(@as(u64, 5), r.documents);
    try testing.expectEqual(@as(?u64, 5), r.indexed);
    try testing.expectEqual(@as(u64, 5), r.texts);
    try testing.expectEqual(@as(u64, 0), r.without_text);
    try testing.expectEqual(@as(u64, 0), r.orphan_texts);
    try testing.expect(r.cross_checked);
}

test "missing files are reported as absent and are not created" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [3][160]u8 = undefined;
    const paths: Paths = .{
        .index = try tmpPath(&pb[0], &tmp, "index.db"),
        .state = try tmpPath(&pb[1], &tmp, "state.db"),
        .content = try tmpPath(&pb[2], &tmp, "content.db"),
    };
    const r = try check(testing.allocator, testing.io, paths);
    try testing.expect(r.healthy());
    try testing.expectEqual(FileState.absent, r.state);
    try testing.expect(!r.cross_checked);
    try testing.expect(!exists(testing.io, paths.state));
    try testing.expect(!exists(testing.io, paths.index));
}

test "a record without retained text, an orphan text and a missing index are noticed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [3][160]u8 = undefined;
    const paths = try populate(&tmp, 3, &pb);
    {
        // Drop one record's text, and add a text no record refers to.
        var content = try content_sqlite.SqliteContentStore.open(testing.allocator, paths.content, true);
        defer content.close();
        try content.store().delete(doc.idFromSource("t", "doc1"));
        try content.store().put(doc.idFromSource("t", "ghost"), "orphaned");
    }
    const r = try check(testing.allocator, testing.io, paths);
    try testing.expect(r.healthy()); // neither is damage
    try testing.expectEqual(@as(u64, 1), r.without_text);
    try testing.expectEqual(@as(u64, 1), r.orphan_texts);
}

test "damaged retained text is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [3][160]u8 = undefined;
    const paths = try populate(&tmp, 3, &pb);
    {
        var content = try content_sqlite.SqliteContentStore.open(testing.allocator, paths.content, true);
        defer content.close();
        // Flip stored data without touching the recorded hash.
        try sqlite.execSql(content.db, "UPDATE content SET data = x'00112233' WHERE id = (SELECT min(id) FROM content)");
    }
    const r = try check(testing.allocator, testing.io, paths);
    try testing.expect(!r.healthy());
    try testing.expectEqual(@as(u64, 1), r.corrupt_texts);
}

test "an older schema is reported, not upgraded; a newer one is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [3][160]u8 = undefined;
    const paths = try populate(&tmp, 1, &pb);
    {
        var s = try state_sqlite.SqliteStateStore.open(testing.allocator, paths.state, true);
        defer s.close();
        try sqlite.execSql(s.db, "PRAGMA user_version = 0");
    }
    {
        var s = try content_sqlite.SqliteContentStore.open(testing.allocator, paths.content, true);
        defer s.close();
        try sqlite.execSql(s.db, "PRAGMA user_version = 99");
    }
    const r = try check(testing.allocator, testing.io, paths);
    try testing.expect(!r.healthy());
    try testing.expectEqual(FileState.needs_upgrade, r.state);
    try testing.expectEqual(FileState.newer_version, r.content);
    // Still at the old version: inspection did not migrate it.
    const db = try sqlite.openReadOnly(paths.state);
    defer _ = c.sqlite3_close(db);
    try testing.expectEqual(@as(i64, 0), try sqlite.userVersion(db));
}

test "a file that is not a database is damaged or unreadable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [3][160]u8 = undefined;
    const paths = try populate(&tmp, 1, &pb);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "state.db", .data = "this is not a database at all, just some text of sufficient length to fill a header" });
    _ = std.c.unlink(@ptrCast(try std.fmt.bufPrintSentinel(&pb[0], "{s}-wal", .{paths.state}, 0)));
    const r = try check(testing.allocator, testing.io, paths);
    try testing.expect(!r.healthy());
    try testing.expect(r.state != .ok);
}

test "backup makes a verified, independent snapshot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [3][160]u8 = undefined;
    const paths = try populate(&tmp, 4, &pb);
    var b1: [160]u8 = undefined;
    var b2: [160]u8 = undefined;
    const dest_state = try tmpPath(&b1, &tmp, "copy-state.db");
    const dest_content = try tmpPath(&b2, &tmp, "copy-content.db");
    try backupFile(paths.state, dest_state, false);
    try backupFile(paths.content, dest_content, false);

    // The copies form a healthy data directory of their own.
    var b3: [160]u8 = undefined;
    const r = try check(testing.allocator, testing.io, .{
        .index = try tmpPath(&b3, &tmp, "none.db"),
        .state = dest_state,
        .content = dest_content,
    });
    try testing.expect(r.healthy());
    try testing.expectEqual(@as(u64, 4), r.documents);
    try testing.expect(r.cross_checked);
    try testing.expectEqual(@as(u64, 0), r.without_text);

    // An existing destination is never overwritten.
    try testing.expectError(error.Io, backupFile(paths.state, dest_state, false));
    // A missing source is an error and creates nothing.
    var b4: [160]u8 = undefined;
    try testing.expectError(error.Io, backupFile(try tmpPath(&b4, &tmp, "nope.db"), dest_state, false));
}

test "the writer lock is exclusive and is released" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try WriterLock.acquire(testing.io, tmp.dir, "write.lock");
    try testing.expectError(error.Busy, WriterLock.acquire(testing.io, tmp.dir, "write.lock"));
    a.release(testing.io);
    const b = try WriterLock.acquire(testing.io, tmp.dir, "write.lock");
    b.release(testing.io);
}
