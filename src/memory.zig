//! In-memory implementations of the storage interfaces.
//!
//! Intended for tests, fixtures and small ephemeral runs. They keep
//! everything in RAM and lose it on exit; they are not a storage backend
//! decision (SPEC section 16).

const std = @import("std");
const Allocator = std.mem.Allocator;
const doc = @import("document.zig");
const storage = @import("storage.zig");

pub const MemoryContentStore = struct {
    gpa: Allocator,
    map: std.AutoHashMapUnmanaged(doc.Id, []u8) = .empty,

    pub fn init(gpa: Allocator) MemoryContentStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MemoryContentStore) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.map.deinit(self.gpa);
    }

    pub fn count(self: *const MemoryContentStore) usize {
        return self.map.count();
    }

    pub fn store(self: *MemoryContentStore) storage.ContentStore {
        return .{ .ptr = self, .vtable = &.{ .put = put, .get = get, .delete = delete } };
    }

    fn put(ptr: *anyopaque, id: doc.Id, bytes: []const u8) storage.Error!void {
        const self: *MemoryContentStore = @ptrCast(@alignCast(ptr));
        const copy = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(copy);
        const gop = try self.map.getOrPut(self.gpa, id);
        if (gop.found_existing) self.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = copy;
    }

    fn get(ptr: *anyopaque, gpa: Allocator, id: doc.Id) storage.Error![]u8 {
        const self: *MemoryContentStore = @ptrCast(@alignCast(ptr));
        const v = self.map.get(id) orelse return error.NotFound;
        return gpa.dupe(u8, v);
    }

    fn delete(ptr: *anyopaque, id: doc.Id) storage.Error!void {
        const self: *MemoryContentStore = @ptrCast(@alignCast(ptr));
        if (self.map.fetchRemove(id)) |kv| self.gpa.free(kv.value);
    }
};

pub const MemoryDocumentStore = struct {
    gpa: Allocator,
    map: std.AutoHashMapUnmanaged(doc.Id, Stored) = .empty,

    /// Each record owns an arena holding its deep-copied metadata.
    const Stored = struct {
        rec: storage.Record,
        arena: std.heap.ArenaAllocator,
    };

    pub fn init(gpa: Allocator) MemoryDocumentStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MemoryDocumentStore) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| v.arena.deinit();
        self.map.deinit(self.gpa);
    }

    pub fn count(self: *const MemoryDocumentStore) usize {
        return self.map.count();
    }

    pub fn store(self: *MemoryDocumentStore) storage.DocumentStore {
        return .{ .ptr = self, .vtable = &.{ .upsert = upsert, .find = find, .delete = delete, .for_each = forEach } };
    }

    fn upsert(ptr: *anyopaque, rec: storage.Record) storage.Error!void {
        const self: *MemoryDocumentStore = @ptrCast(@alignCast(ptr));
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        var owned = rec;
        owned.meta = try rec.meta.clone(arena.allocator());
        const gop = try self.map.getOrPut(self.gpa, rec.id);
        if (gop.found_existing) gop.value_ptr.arena.deinit();
        gop.value_ptr.* = .{ .rec = owned, .arena = arena };
    }

    fn find(ptr: *anyopaque, id: doc.Id) storage.Error!?storage.Record {
        const self: *MemoryDocumentStore = @ptrCast(@alignCast(ptr));
        const v = self.map.get(id) orelse return null;
        return v.rec;
    }

    fn delete(ptr: *anyopaque, id: doc.Id) storage.Error!void {
        const self: *MemoryDocumentStore = @ptrCast(@alignCast(ptr));
        if (self.map.fetchRemove(id)) |kv| {
            var a = kv.value.arena;
            a.deinit();
        }
    }

    fn forEach(ptr: *anyopaque, visitor: storage.Visitor) storage.Error!void {
        const self: *MemoryDocumentStore = @ptrCast(@alignCast(ptr));
        var it = self.map.valueIterator();
        while (it.next()) |v| try visitor.visit(visitor.ptr, v.rec);
    }
};

const testing = std.testing;

test "content store: put, replace, get, delete" {
    var m = MemoryContentStore.init(testing.allocator);
    defer m.deinit();
    const s = m.store();
    const id = doc.idFromSource("c", "1");

    try testing.expectError(error.NotFound, s.get(testing.allocator, id));
    try s.put(id, "one");
    try s.put(id, "two");
    const got = try s.get(testing.allocator, id);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("two", got);

    try s.delete(id);
    try s.delete(id); // deleting a missing id is fine
    try testing.expectError(error.NotFound, s.get(testing.allocator, id));
}

test "document store: upsert deep-copies metadata, replaces, deletes" {
    var m = MemoryDocumentStore.init(testing.allocator);
    defer m.deinit();
    const s = m.store();
    const d: doc.Document = .{ .connector = "c", .source_id = "1", .text = "hello" };

    try testing.expect((try s.find(d.id())) == null);

    var rev = [_]u8{ 'r', '1' };
    var meta = d;
    meta.revision = &rev;
    meta.text = null;
    try s.upsert(.{ .id = d.id(), .content_hash = d.contentHash(), .acquired_at = 100, .meta = meta });
    rev[1] = '9'; // caller's buffer changes; the store kept its own copy
    const found = (try s.find(d.id())).?;
    try testing.expectEqualStrings("r1", found.meta.revision.?);
    try testing.expectEqual(d.contentHash().?, found.content_hash.?);

    meta.revision = "r2";
    try s.upsert(.{ .id = d.id(), .content_hash = null, .acquired_at = 200, .meta = meta });
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expectEqualStrings("r2", (try s.find(d.id())).?.meta.revision.?);

    try s.delete(d.id());
    try s.delete(d.id());
    try testing.expect((try s.find(d.id())) == null);
}

test "document store: forEach visits every record and stops on error" {
    var m = MemoryDocumentStore.init(testing.allocator);
    defer m.deinit();
    const s = m.store();
    for ([_][]const u8{ "1", "2", "3" }) |sid| {
        const d: doc.Document = .{ .connector = "c", .source_id = sid, .content_ref = "r" };
        try s.upsert(.{ .id = d.id(), .content_hash = null, .acquired_at = null, .meta = d });
    }

    const Count = struct {
        n: usize = 0,
        stop_at: usize = std.math.maxInt(usize),
        fn visit(ptr: *anyopaque, _: storage.Record) storage.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.n += 1;
            if (self.n == self.stop_at) return error.Io;
        }
    };
    var c: Count = .{};
    try s.forEach(.{ .ptr = &c, .visit = Count.visit });
    try testing.expectEqual(@as(usize, 3), c.n);

    var c2: Count = .{ .stop_at = 2 };
    try testing.expectError(error.Io, s.forEach(.{ .ptr = &c2, .visit = Count.visit }));
    try testing.expectEqual(@as(usize, 2), c2.n);
}
