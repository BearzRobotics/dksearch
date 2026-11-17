//! A memory-bounded cache of what retrieval derives from a document: its chunks, and the page index of a PDF's
//! text. Making them means reading the stored text (an inflate), splitting it, and for a PDF hashing every four-word
//! run; the answers do not change until the document does, so they are kept, keyed by the document, the version of
//! its stored content (the content hash, see `ContentStore.stamp`) and the chunking options.
//!
//! Entries are reference-counted: a request that is using one holds it, so another request's eviction cannot free
//! text that is still being written into a response. The budget is a target, not a hard limit: entries in use stay
//! even when the cache is over budget.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const doc = @import("document.zig");
const retrieve = @import("retrieve.zig");

pub const Kind = enum(u8) { chunks, pages };

pub const Key = struct {
    id: doc.Id,
    /// The first bytes of the content hash: enough to tell versions apart.
    stamp: [8]u8,
    kind: Kind,
    chunk_chars: u32 = 0,
    overlap: u32 = 0,
};

pub const Entry = struct {
    /// Everything of this entry lives here.
    arena: std.heap.ArenaAllocator,
    chunks: []const retrieve.Chunk = &.{},
    pages: ?retrieve.PageIndex = null,
    /// Bytes of the document's text this was made from (what the per-request limit counts).
    text_bytes: usize = 0,
    bytes: usize = 0,
    refs: u32 = 1,
    last_used: u64 = 0,
    evicted: bool = false,
    key: Key,
};

pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    budget: usize,
    mutex: Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(Key, *Entry) = .empty,
    used: usize = 0,
    tick: u64 = 0,
    hits: std.atomic.Value(u64) = .init(0),
    misses: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: Allocator, io: Io, budget_bytes: usize) Cache {
        return .{ .gpa = gpa, .io = io, .budget = budget_bytes };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.map.valueIterator();
        while (it.next()) |e| {
            e.*.arena.deinit();
            self.gpa.destroy(e.*);
        }
        self.map.deinit(self.gpa);
    }

    pub fn keyOf(id: doc.Id, stamp: [32]u8, kind: Kind, chunk_chars: u32, overlap: u32) Key {
        return .{ .id = id, .stamp = stamp[0..8].*, .kind = kind, .chunk_chars = chunk_chars, .overlap = overlap };
    }

    /// The cached entry for `key`, held (call `release`), or null.
    pub fn acquire(self: *Cache, key: Key) ?*Entry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const e = self.map.get(key) orelse {
            _ = self.misses.fetchAdd(1, .monotonic);
            return null;
        };
        e.refs += 1;
        self.tick += 1;
        e.last_used = self.tick;
        _ = self.hits.fetchAdd(1, .monotonic);
        return e;
    }

    /// A new entry whose data lives in an arena of the cache's allocator. Fill it, then `publish` it.
    pub fn begin(self: *Cache, key: Key) Allocator.Error!*Entry {
        const e = try self.gpa.create(Entry);
        e.* = .{ .arena = .init(self.gpa), .key = key };
        return e;
    }

    /// Throws away an entry from `begin` that will not be published.
    pub fn discard(self: *Cache, e: *Entry) void {
        e.arena.deinit();
        self.gpa.destroy(e);
    }

    /// Makes `e` (from `begin`, filled) available to others and returns it held. If someone else published the
    /// same key meanwhile, theirs is returned (held) and `e` is discarded.
    pub fn publish(self: *Cache, e: *Entry, text_bytes: usize) *Entry {
        e.text_bytes = text_bytes;
        e.bytes = e.arena.queryCapacity() + @sizeOf(Entry);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.get(e.key)) |other| {
            other.refs += 1;
            e.arena.deinit();
            self.gpa.destroy(e);
            return other;
        }
        self.map.put(self.gpa, e.key, e) catch {
            // Out of memory for the table: the entry is used by this request only and freed on release.
            e.evicted = true;
            return e;
        };
        self.tick += 1;
        e.last_used = self.tick;
        self.used += e.bytes;
        self.evictLocked();
        return e;
    }

    /// Gives up a hold from `acquire` or `publish`.
    pub fn release(self: *Cache, e: *Entry) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        e.refs -= 1;
        if (e.refs == 0 and e.evicted) {
            e.arena.deinit();
            self.gpa.destroy(e);
        } else if (e.refs == 0) self.evictLocked();
    }

    /// Drops least recently used entries nobody holds until the cache is within its budget.
    fn evictLocked(self: *Cache) void {
        while (self.used > self.budget) {
            var oldest: ?*Entry = null;
            var it = self.map.valueIterator();
            while (it.next()) |e| {
                if (e.*.refs != 0) continue;
                if (oldest == null or e.*.last_used < oldest.?.last_used) oldest = e.*;
            }
            const victim = oldest orelse return;
            _ = self.map.remove(victim.key);
            self.used -= victim.bytes;
            victim.arena.deinit();
            self.gpa.destroy(victim);
        }
    }
};

const testing = std.testing;

fn fill(c: *Cache, key: Key, words: usize) !*Entry {
    const e = try c.begin(key);
    const a = e.arena.allocator();
    const text = try a.alloc(u8, words);
    @memset(text, 'x');
    e.chunks = try retrieve.chunk(a, text, .{});
    return c.publish(e, words);
}

test "a published entry is found again, a changed version is not, and the least recently used goes first" {
    var c = Cache.init(testing.allocator, testing.io, 64 * 1024);
    defer c.deinit();
    const id1 = doc.idFromSource("c", "1");
    const id2 = doc.idFromSource("c", "2");
    const s1: [32]u8 = @splat(1);
    const s2: [32]u8 = @splat(2);
    const k1 = Cache.keyOf(id1, s1, .chunks, 1200, 150);
    try testing.expect(c.acquire(k1) == null);
    const e = try fill(&c, k1, 100);
    c.release(e);
    const again = c.acquire(k1).?;
    try testing.expectEqual(@as(usize, 100), again.text_bytes);
    c.release(again);
    // Another version of the same document, or other options, is another entry.
    try testing.expect(c.acquire(Cache.keyOf(id1, s2, .chunks, 1200, 150)) == null);
    try testing.expect(c.acquire(Cache.keyOf(id1, s1, .chunks, 800, 150)) == null);
    // Over the budget: the oldest unused entry is dropped, an entry in use is kept.
    const hold = try fill(&c, Cache.keyOf(id2, s1, .chunks, 1200, 150), 40 * 1024);
    const big = try fill(&c, Cache.keyOf(id2, s2, .chunks, 1200, 150), 40 * 1024);
    c.release(big);
    try testing.expect(c.acquire(k1) == null); // the small old one was evicted
    try testing.expect(c.acquire(Cache.keyOf(id2, s1, .chunks, 1200, 150)) != null); // still held, so still there
    c.release(hold);
    c.release(hold); // the extra hold from acquire above
}

test "two requests making the same entry end up sharing one" {
    var c = Cache.init(testing.allocator, testing.io, 1024 * 1024);
    defer c.deinit();
    const k = Cache.keyOf(doc.idFromSource("c", "1"), @splat(7), .pages, 0, 0);
    const first = try fill(&c, k, 10);
    const second = try fill(&c, k, 10); // made at the same time elsewhere: the published one wins
    try testing.expect(first == second);
    c.release(first);
    c.release(second);
}
