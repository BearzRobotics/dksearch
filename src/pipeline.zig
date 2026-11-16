//! The shared ingestion pipeline: the one `Sink` implementation connectors
//! feed. Order of work per record (SPEC section 5):
//!
//!   validate -> id + hash -> duplicate/revision check -> retain content ->
//!   index -> record provenance
//!
//! The provenance record is written last on purpose. If the process dies
//! earlier, the record is missing, so the next import of the same item
//! repeats the (idempotent) content and index writes instead of being
//! skipped as a duplicate with a half-finished state.
//!
//! Not thread-safe: use one pipeline per ingestion job, or serialize access.

const std = @import("std");
const doc = @import("document.zig");
const connector = @import("connector.zig");
const storage = @import("storage.zig");
const indexer = @import("indexer.zig");

pub const Stats = struct {
    /// New documents stored and indexed.
    added: u64 = 0,
    /// Known documents whose content or revision changed.
    updated: u64 = 0,
    /// Known documents with identical content and revision; nothing written.
    unchanged: u64 = 0,
    /// Records refused (invalid, or a store/index failure for that record).
    rejected: u64 = 0,
    removed: u64 = 0,
};

pub const Options = struct {
    /// Keep `Document.text` in the content store so the index can be rebuilt
    /// without reacquiring the source. Turn off for sources whose terms
    /// forbid retention.
    retain_text: bool = true,
    /// Replaces the redistribution flag of every document, when set.
    rights_override: ?doc.Redistribution = null,
    /// Unix time in seconds, used when a document carries no `acquired_at`.
    now: *const fn () doc.Timestamp,
};

pub const Pipeline = struct {
    content: storage.ContentStore,
    docs: storage.DocumentStore,
    index: indexer.Indexer,
    options: Options,
    stats: Stats = .{},
    /// True between `beginBatch` and `commitBatch`/`abortBatch`.
    in_batch: bool = false,

    pub fn init(content: storage.ContentStore, docs: storage.DocumentStore, index: indexer.Indexer, options: Options) Pipeline {
        return .{ .content = content, .docs = docs, .index = index, .options = options };
    }

    /// Opens a batch on the content store, the index and the document store.
    /// Everything submitted until `commitBatch` is made durable together,
    /// with one sync per store instead of one per document. A no-op if a
    /// batch is already open.
    pub fn beginBatch(self: *Pipeline) (storage.Error || indexer.Error)!void {
        if (self.in_batch) return;
        try self.content.begin();
        errdefer self.content.rollback() catch {};
        try self.index.begin();
        errdefer self.index.rollback() catch {};
        try self.docs.begin();
        self.in_batch = true;
    }

    /// Makes the open batch durable. The order matters and is the point: the
    /// content and the index are committed first, and the provenance records
    /// last. A crash between the steps leaves content or index entries with no
    /// record yet, which a re-import repeats harmlessly, and never a record
    /// whose content is missing. A no-op if no batch is open.
    ///
    /// If a step fails the batch stays open, so that `abortBatch` can roll
    /// back every store (a store whose commit already succeeded has nothing
    /// left to roll back, which is harmless).
    pub fn commitBatch(self: *Pipeline) (storage.Error || indexer.Error)!void {
        if (!self.in_batch) return;
        try self.content.commit();
        try self.index.commit();
        try self.docs.commit();
        self.in_batch = false;
    }

    /// Abandons the open batch: nothing submitted since `beginBatch` is kept.
    /// Best effort; a no-op if no batch is open.
    pub fn abortBatch(self: *Pipeline) void {
        if (!self.in_batch) return;
        self.in_batch = false;
        self.docs.rollback() catch {};
        self.index.rollback() catch {};
        self.content.rollback() catch {};
    }

    /// The `Sink` to hand to connectors. Valid while `self` is.
    pub fn sink(self: *Pipeline) connector.Sink {
        return .{ .ptr = self, .vtable = &.{ .submit = submitErased } };
    }

    fn submitErased(ptr: *anyopaque, d: doc.Document) connector.Sink.Error!void {
        const self: *Pipeline = @ptrCast(@alignCast(ptr));
        return self.submit(d);
    }

    pub fn submit(self: *Pipeline, d_in: doc.Document) connector.Sink.Error!void {
        d_in.validate() catch {
            self.stats.rejected += 1;
            return error.Rejected;
        };

        var d = d_in;
        if (self.options.rights_override) |r| d.rights.redistribution = r;

        const id = d.id();
        const hash = d.contentHash();
        // The index records when a document was added; the same moment goes in the record below.
        if (d.acquired_at == null) d.acquired_at = self.options.now();

        const existing = self.docs.find(id) catch |e| return self.fail(e);
        if (existing) |old| {
            if (sameVersion(old, hash, d.revision)) {
                self.stats.unchanged += 1;
                return;
            }
        }

        if (self.options.retain_text) if (d.text) |t| {
            self.content.put(id, t) catch |e| return self.fail(e);
        };
        self.index.add(id, d) catch |e| return self.failIndex(e);
        var meta = d;
        meta.text = null; // main text lives in the content store, not here
        self.docs.upsert(.{
            .id = id,
            .content_hash = hash,
            .acquired_at = d.acquired_at,
            .meta = meta,
        }) catch |e| return self.fail(e);

        if (existing == null) self.stats.added += 1 else self.stats.updated += 1;
    }

    /// Removes a document everywhere: retained text, index entry, record.
    /// The record goes last, in the same order as `submit` writes, so a crash
    /// leaves a record that a repeated removal still finds and finishes.
    pub fn remove(self: *Pipeline, id: doc.Id) (storage.Error || indexer.Error)!void {
        try self.content.delete(id);
        try self.index.remove(id);
        try self.docs.delete(id);
        self.stats.removed += 1;
    }

    fn fail(self: *Pipeline, e: storage.Error) connector.Sink.Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            // Storage is full: continuing would only produce more failures.
            error.NoSpace => error.Stopped,
            error.NotFound, error.Corrupt, error.Io => blk: {
                self.stats.rejected += 1;
                break :blk error.Rejected;
            },
        };
    }

    fn failIndex(self: *Pipeline, e: indexer.Error) connector.Sink.Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.NoSpace => error.Stopped,
            error.Corrupt, error.Io => blk: {
                self.stats.rejected += 1;
                break :blk error.Rejected;
            },
        };
    }
};

fn sameVersion(old: storage.Record, hash: ?doc.ContentHash, revision: ?[]const u8) bool {
    const h_old = old.content_hash orelse return false;
    const h_new = hash orelse return false;
    if (!std.mem.eql(u8, &h_old, &h_new)) return false;
    const old_rev = old.meta.revision;
    if (old_rev == null and revision == null) return true;
    if (old_rev == null or revision == null) return false;
    return std.mem.eql(u8, old_rev.?, revision.?);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const memory = @import("memory.zig");

fn fixedNow() doc.Timestamp {
    return 1_000;
}

/// Index fake: remembers titles by id and can be told to fail.
const FakeIndex = struct {
    adds: u32 = 0,
    last_id: ?doc.Id = null,
    fail_with: ?indexer.Error = null,

    fn add(ptr: *anyopaque, id: doc.Id, _: doc.Document) indexer.Error!void {
        const self: *FakeIndex = @ptrCast(@alignCast(ptr));
        if (self.fail_with) |e| return e;
        self.adds += 1;
        self.last_id = id;
    }
    fn remove(_: *anyopaque, _: doc.Id) indexer.Error!void {}
    fn clear(_: *anyopaque) indexer.Error!void {}
    fn check(_: *anyopaque) indexer.Error!void {}
    fn index(self: *FakeIndex) indexer.Indexer {
        return .{ .ptr = self, .vtable = &.{ .add = add, .remove = remove, .clear = clear, .check = check } };
    }
};

const Harness = struct {
    content: memory.MemoryContentStore,
    docs: memory.MemoryDocumentStore,
    idx: FakeIndex = .{},
    pipe: Pipeline = undefined,

    fn init(h: *Harness, opts: struct { retain_text: bool = true, rights: ?doc.Redistribution = null }) void {
        h.content = .init(testing.allocator);
        h.docs = .init(testing.allocator);
        h.pipe = .init(h.content.store(), h.docs.store(), h.idx.index(), .{ .retain_text = opts.retain_text, .rights_override = opts.rights, .now = fixedNow });
    }
    fn deinit(h: *Harness) void {
        h.content.deinit();
        h.docs.deinit();
    }
};

test "new document is retained, indexed and recorded" {
    var h: Harness = undefined;
    h.idx = .{};
    h.init(.{});
    defer h.deinit();

    const d: doc.Document = .{ .connector = "c", .source_id = "1", .text = "hello world", .revision = "r1" };
    try h.pipe.sink().submit(d);

    try testing.expectEqual(@as(u64, 1), h.pipe.stats.added);
    try testing.expectEqual(@as(u32, 1), h.idx.adds);
    const kept = try h.content.store().get(testing.allocator, d.id());
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("hello world", kept);
    const rec = (try h.docs.store().find(d.id())).?;
    try testing.expectEqual(@as(?doc.Timestamp, 1_000), rec.acquired_at);
    try testing.expectEqualStrings("r1", rec.meta.revision.?);
    try testing.expect(rec.meta.text == null); // text is only in the content store
}

test "resubmitting identical content is a no-op" {
    var h: Harness = undefined;
    h.idx = .{};
    h.init(.{});
    defer h.deinit();

    const d: doc.Document = .{ .connector = "c", .source_id = "1", .text = "same" };
    try h.pipe.submit(d);
    try h.pipe.submit(d);

    try testing.expectEqual(@as(u64, 1), h.pipe.stats.added);
    try testing.expectEqual(@as(u64, 1), h.pipe.stats.unchanged);
    try testing.expectEqual(@as(u32, 1), h.idx.adds);
}

test "changed content or revision updates in place" {
    var h: Harness = undefined;
    h.idx = .{};
    h.init(.{});
    defer h.deinit();

    try h.pipe.submit(.{ .connector = "c", .source_id = "1", .text = "v1", .revision = "1" });
    try h.pipe.submit(.{ .connector = "c", .source_id = "1", .text = "v2", .revision = "1" });
    try h.pipe.submit(.{ .connector = "c", .source_id = "1", .text = "v2", .revision = "2" });

    try testing.expectEqual(@as(u64, 1), h.pipe.stats.added);
    try testing.expectEqual(@as(u64, 2), h.pipe.stats.updated);
    try testing.expectEqual(@as(usize, 1), h.docs.count());
    try testing.expectEqual(@as(u32, 3), h.idx.adds);
    const kept = try h.content.store().get(testing.allocator, doc.idFromSource("c", "1"));
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("v2", kept);
}

test "invalid records are rejected and leave no trace" {
    var h: Harness = undefined;
    h.idx = .{};
    h.init(.{});
    defer h.deinit();

    try testing.expectError(error.Rejected, h.pipe.submit(.{ .connector = "c", .source_id = "1" }));
    try testing.expectError(error.Rejected, h.pipe.submit(.{ .connector = "c", .source_id = "2", .text = "\xff" }));
    try testing.expectEqual(@as(u64, 2), h.pipe.stats.rejected);
    try testing.expectEqual(@as(usize, 0), h.docs.count());
    try testing.expectEqual(@as(usize, 0), h.content.count());
    try testing.expectEqual(@as(u32, 0), h.idx.adds);
}

test "retain_text = false indexes and records but keeps no content" {
    var h: Harness = undefined;
    h.idx = .{};
    h.init(.{ .retain_text = false });
    defer h.deinit();

    try h.pipe.submit(.{ .connector = "c", .source_id = "1", .text = "no retention" });
    try testing.expectEqual(@as(u32, 1), h.idx.adds);
    try testing.expectEqual(@as(usize, 1), h.docs.count());
    try testing.expectEqual(@as(usize, 0), h.content.count());
}

test "rights override replaces the connector's redistribution flag" {
    var h: Harness = undefined;
    h.idx = .{};
    h.init(.{ .rights = .forbidden });
    defer h.deinit();

    const d: doc.Document = .{ .connector = "c", .source_id = "1", .text = "x", .rights = .{ .redistribution = .allowed } };
    try h.pipe.submit(d);
    const e = (try h.docs.store().find(d.id())).?;
    try testing.expectEqual(doc.Redistribution.forbidden, e.meta.rights.redistribution);
}

test "index failure writes no provenance record, so a retry is not skipped" {
    var h: Harness = undefined;
    h.idx = .{ .fail_with = error.Io };
    h.init(.{});
    defer h.deinit();

    const d: doc.Document = .{ .connector = "c", .source_id = "1", .text = "x" };
    try testing.expectError(error.Rejected, h.pipe.submit(d));
    try testing.expectEqual(@as(usize, 0), h.docs.count());

    h.idx.fail_with = null;
    try h.pipe.submit(d);
    try testing.expectEqual(@as(u64, 1), h.pipe.stats.added);
    try testing.expectEqual(@as(u32, 1), h.idx.adds);
}

test "NoSpace from the index stops the connector" {
    var h: Harness = undefined;
    h.idx = .{ .fail_with = error.NoSpace };
    h.init(.{});
    defer h.deinit();
    try testing.expectError(error.Stopped, h.pipe.submit(.{ .connector = "c", .source_id = "1", .text = "x" }));
}
