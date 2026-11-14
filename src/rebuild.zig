//! Rebuild an index from the content and document stores.
//!
//! The index is derived data (SPEC section 10). This routine empties it and
//! re-adds every record for which the main text is still retained. It never
//! contacts a source, so it works offline. It is safe to re-run: if it is
//! interrupted, the index is partial but consistent, and running it again
//! completes the job.

const std = @import("std");
const Allocator = std.mem.Allocator;
const doc = @import("document.zig");
const storage = @import("storage.zig");
const indexer = @import("indexer.zig");

pub const Stats = struct {
    /// Documents added back to the index.
    reindexed: u64 = 0,
    /// Records whose main text is not retained (retention disabled, or the
    /// content store has no entry). They stay out of the index until the
    /// source is imported again.
    unrecoverable: u64 = 0,
    /// Records whose retained text could not be read (corrupt or I/O error).
    failed: u64 = 0,
};

pub const Error = indexer.Error || storage.Error;

pub fn rebuild(gpa: Allocator, index: indexer.Indexer, content: storage.ContentStore, docs: storage.DocumentStore) Error!Stats {
    try index.clear();

    const Ctx = struct {
        gpa: Allocator,
        index: indexer.Indexer,
        content: storage.ContentStore,
        stats: Stats = .{},
        /// First fatal (non-per-record) error; iteration stops when set.
        fatal: ?Error = null,

        fn visit(ptr: *anyopaque, rec: storage.Record) storage.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const text = self.content.get(self.gpa, rec.id) catch |e| switch (e) {
                error.NotFound => {
                    self.stats.unrecoverable += 1;
                    return;
                },
                error.OutOfMemory => {
                    self.fatal = error.OutOfMemory;
                    return error.OutOfMemory;
                },
                error.Corrupt, error.Io, error.NoSpace => {
                    self.stats.failed += 1;
                    return;
                },
            };
            defer self.gpa.free(text);
            var d = rec.meta;
            d.text = text;
            self.index.add(rec.id, d) catch |e| {
                self.fatal = e;
                return error.Io; // stops the iteration; the real error is in `fatal`
            };
            self.stats.reindexed += 1;
        }
    };

    var ctx: Ctx = .{ .gpa = gpa, .index = index, .content = content };
    docs.forEach(.{ .ptr = &ctx, .visit = Ctx.visit }) catch |e| return ctx.fatal orelse e;
    return ctx.stats;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const memory = @import("memory.zig");
const pipeline = @import("pipeline.zig");
const search = @import("search.zig");
const index_sqlite = @import("index_sqlite.zig");

fn fixedNow() doc.Timestamp {
    return 1;
}

test "rebuilding an empty index from the stores reproduces search results" {
    var content = memory.MemoryContentStore.init(testing.allocator);
    defer content.deinit();
    var docs = memory.MemoryDocumentStore.init(testing.allocator);
    defer docs.deinit();
    var live = try index_sqlite.SqliteIndex.open(":memory:", .{});
    defer live.close();

    var pipe = pipeline.Pipeline.init(content.store(), docs.store(), live.indexer(), .{ .now = fixedNow });
    try pipe.submit(.{ .connector = "g", .source_id = "1", .title = "Moby Dick", .text = "Call me Ishmael.", .language = "en" });
    try pipe.submit(.{ .connector = "g", .source_id = "2", .title = "Emma", .text = "Emma Woodhouse, handsome, clever, and rich", .language = "en" });
    try pipe.submit(.{ .connector = "g", .source_id = "3", .title = "Pride", .text = "A truth universally acknowledged", .language = "en" });

    var fresh = try index_sqlite.SqliteIndex.open(":memory:", .{});
    defer fresh.close();
    const stats = try rebuild(testing.allocator, fresh.indexer(), content.store(), docs.store());
    try testing.expectEqual(@as(u64, 3), stats.reindexed);
    try testing.expectEqual(@as(u64, 0), stats.unrecoverable);
    try fresh.indexer().check();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "ishmael", "emma", "\"truth universally\"", "clever rich" }) |q| {
        const a = try live.searcher().search(arena.allocator(), .{ .text = q, .language = "en" });
        const b = try fresh.searcher().search(arena.allocator(), .{ .text = q, .language = "en" });
        try testing.expect(a.hits.len > 0);
        try testing.expectEqual(a.hits.len, b.hits.len);
        for (a.hits, b.hits) |x, y| {
            try testing.expectEqual(x.id, y.id);
            try testing.expectEqualStrings(x.title.?, y.title.?);
            try testing.expectEqual(x.score, y.score);
        }
    }
}

test "rebuild reports records whose text was not retained and is re-runnable" {
    var content = memory.MemoryContentStore.init(testing.allocator);
    defer content.deinit();
    var docs = memory.MemoryDocumentStore.init(testing.allocator);
    defer docs.deinit();
    var idx = try index_sqlite.SqliteIndex.open(":memory:", .{});
    defer idx.close();

    var keep = pipeline.Pipeline.init(content.store(), docs.store(), idx.indexer(), .{ .now = fixedNow });
    var no_keep = pipeline.Pipeline.init(content.store(), docs.store(), idx.indexer(), .{ .retain_text = false, .now = fixedNow });
    try keep.submit(.{ .connector = "c", .source_id = "kept", .text = "retained words" });
    try no_keep.submit(.{ .connector = "c", .source_id = "gone", .text = "unretained words" });

    const first = try rebuild(testing.allocator, idx.indexer(), content.store(), docs.store());
    try testing.expectEqual(@as(u64, 1), first.reindexed);
    try testing.expectEqual(@as(u64, 1), first.unrecoverable);
    const second = try rebuild(testing.allocator, idx.indexer(), content.store(), docs.store());
    try testing.expectEqual(first.reindexed, second.reindexed);
    try testing.expectEqual(@as(u64, 1), try idx.count());
}
