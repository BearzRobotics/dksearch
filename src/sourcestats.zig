//! How many documents each source has and when one was last added, kept for a few minutes so that showing it on
//! every search page costs nothing: counting groups the whole index, which is slow on a large one.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const search = @import("search.zig");

pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    ttl_seconds: u32 = 300,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    items: []const search.SourceStat = &.{},
    /// Monotonic time the numbers were made; null before the first time.
    at_ns: ?i64 = null,

    pub fn init(gpa: Allocator, io: Io) Cache {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Cache) void {
        self.arena.deinit();
    }

    fn nowNs(self: *const Cache) i64 {
        return @intCast(Io.Timestamp.now(self.io, .awake).nanoseconds);
    }

    /// The numbers, copied into `arena`; counted again when they are older than the time to live. If counting
    /// fails the old numbers (or none) are returned.
    pub fn get(self: *Cache, arena: Allocator, searcher: search.Searcher) Allocator.Error![]const search.SourceStat {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now = self.nowNs();
        const stale = if (self.at_ns) |t| now - t > @as(i64, self.ttl_seconds) * std.time.ns_per_s else true;
        if (stale) self.refresh(searcher, now);
        const out = try arena.alloc(search.SourceStat, self.items.len);
        for (self.items, out) |s, *o| o.* = .{ .name = try arena.dupe(u8, s.name), .docs = s.docs, .last_added = s.last_added };
        return out;
    }

    fn refresh(self: *Cache, searcher: search.Searcher, now: i64) void {
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const fresh = searcher.sourceStats(tmp.allocator()) catch {
            self.at_ns = now; // do not retry on every request
            return;
        };
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const copy = a.alloc(search.SourceStat, fresh.len) catch {
            self.items = &.{};
            return;
        };
        for (fresh, copy) |s, *o| o.* = .{ .name = a.dupe(u8, s.name) catch "", .docs = s.docs, .last_added = s.last_added };
        self.items = copy;
        self.at_ns = now;
    }
};

const testing = std.testing;

test "the numbers are counted once and reused until they are old" {
    const Fake = struct {
        calls: u32 = 0,
        fn stats(ptr: *anyopaque, arena: Allocator) search.Error![]const search.SourceStat {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            const out = try arena.alloc(search.SourceStat, 1);
            out[0] = .{ .name = "a", .docs = 10 + self.calls, .last_added = 5 };
            return out;
        }
        fn doSearch(_: *anyopaque, _: Allocator, _: search.Query) search.Error!search.Page {
            return .{ .hits = &.{}, .has_more = false };
        }
    };
    var fake: Fake = .{};
    const s: search.Searcher = .{ .ptr = &fake, .vtable = &.{ .search = Fake.doSearch, .source_stats = Fake.stats } };
    var c = Cache.init(testing.allocator, testing.io);
    defer c.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const first = try c.get(ar.allocator(), s);
    try testing.expectEqual(@as(u64, 11), first[0].docs);
    _ = try c.get(ar.allocator(), s);
    try testing.expectEqual(@as(u32, 1), fake.calls);
    c.ttl_seconds = 0;
    std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
    const again = try c.get(ar.allocator(), s);
    try testing.expectEqual(@as(u64, 12), again[0].docs);
    // A searcher that cannot say gives nothing.
    const none: search.Searcher = .{ .ptr = &fake, .vtable = &.{ .search = Fake.doSearch } };
    var c2 = Cache.init(testing.allocator, testing.io);
    defer c2.deinit();
    try testing.expectEqual(@as(usize, 0), (try c2.get(ar.allocator(), none)).len);
}
