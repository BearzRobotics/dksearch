//! Who may see which sources: scopes made from collections, and API keys.
//!
//! A *collection* is a named group of sources (`[[collection]]` in the configuration). A *scope* is the set of sources
//! a request may see: every source, or the members of some collections. An *API key* carries a list of collections
//! (or `*` for all). Keys are stored only as SHA-256 hashes in a file readable by the owner alone, next to the other
//! data (`api-keys.toml`); the token itself is shown once, when the key is made.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const toml = @import("toml");
const config = @import("config.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The sources a request may see.
pub const Scope = struct {
    /// Null: every source. Otherwise exactly these names (possibly none).
    sources: ?[]const []const u8 = null,

    pub fn allows(self: Scope, source: []const u8) bool {
        const list = self.sources orelse return true;
        for (list) |s| if (std.mem.eql(u8, s, source)) return true;
        return false;
    }

    /// True when nothing may be seen.
    pub fn none(self: Scope) bool {
        return if (self.sources) |l| l.len == 0 else false;
    }
};

pub const all_marker = "*";

/// The scope for a list of collection names: the union of their sources. `*` means every source. A name that is not
/// a collection grants nothing.
pub fn resolve(arena: Allocator, collections: []const config.Collection, names: []const []const u8) Allocator.Error!Scope {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| {
        if (std.mem.eql(u8, n, all_marker)) return .{};
        for (collections) |c| if (std.mem.eql(u8, c.name, n)) {
            for (c.sources) |s| {
                var seen = false;
                for (out.items) |x| if (std.mem.eql(u8, x, s)) {
                    seen = true;
                };
                if (!seen) try out.append(arena, s);
            }
        };
    }
    return .{ .sources = out.items };
}

// ---------------------------------------------------------------- API keys

pub const token_prefix = "dkk_";
pub const token_len = token_prefix.len + 43;
pub const max_keys = 200;
pub const max_file_bytes = 256 * 1024;
pub const file_name = "api-keys.toml";

pub const Key = struct {
    /// Eight hex digits of the hash: how the key is named in lists and commands.
    id: []const u8,
    name: []const u8,
    hash: [32]u8,
    /// Collection names, or `*`.
    collections: []const []const u8,
    /// Unix time the key was made.
    created: i64 = 0,
    /// Requests per minute the key may make; 0 is no limit.
    rate: u32 = 0,
    /// A node id (`dkn_...`): the key then works only with a valid signature of that node (see identity.zig).
    node: ?[]const u8 = null,
    /// Adult: a request with this key is not subject to safe search (see safesearch.zig).
    adult: bool = false,
};

const id_node_len = 4 + 43;
/// The most requests per minute a key can be limited to.
pub const max_rate = 1_000_000;

pub const KeyError = error{ Unreadable, Malformed, InsecurePermissions, WriteFailed, EntropyUnavailable, TooMany, BadName, Duplicate, OutOfMemory };

pub fn validKeyName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (c < 0x20 or c > 0x7e or c == '"' or c == '\\') return false;
    return true;
}

pub fn hashOf(token: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    Sha256.hash(token, &h, .{});
    return h;
}

pub fn idOf(arena: Allocator, hash: [32]u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{x}", .{hash[0..4]});
}

/// Parses the file's text; everything is allocated from `arena`.
pub fn parse(arena: Allocator, text: []const u8) KeyError![]const Key {
    var doc = toml.Document.parse(arena, text, .{ .max_bytes = max_file_bytes }, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    defer doc.deinit();
    const v = doc.root.get("key") orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        else => return error.Malformed,
    };
    if (arr.items.items.len > max_keys) return error.TooMany;
    var out = try arena.alloc(Key, arr.items.items.len);
    for (arr.items.items, 0..) |item, i| {
        const t = switch (item) {
            .table => |x| x,
            else => return error.Malformed,
        };
        const name = t.getString("name") orelse return error.Malformed;
        const hash_text = t.getString("hash") orelse return error.Malformed;
        const prefix = "sha256:";
        if (!std.mem.startsWith(u8, hash_text, prefix) or hash_text.len != prefix.len + 64) return error.Malformed;
        var h: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&h, hash_text[prefix.len..]) catch return error.Malformed;
        const colls_v = t.get("collections") orelse return error.Malformed;
        const arr2 = switch (colls_v) {
            .array => |a| a,
            else => return error.Malformed,
        };
        const colls = try arena.alloc([]const u8, arr2.items.items.len);
        for (arr2.items.items, colls) |c, *o| switch (c) {
            .string => |s| o.* = try arena.dupe(u8, s),
            else => return error.Malformed,
        };
        out[i] = .{
            .id = try idOf(arena, h),
            .name = try arena.dupe(u8, name),
            .hash = h,
            .collections = colls,
            .created = if (t.get("created")) |c| switch (c) {
                .integer => |n| n,
                else => 0,
            } else 0,
            .node = if (t.getString("node")) |n| (if (n.len == id_node_len and std.mem.startsWith(u8, n, "dkn_")) try arena.dupe(u8, n) else return error.Malformed) else null,
            .adult = if (t.get("adult")) |av| switch (av) {
                .boolean => |b| b,
                else => return error.Malformed,
            } else false,
            .rate = if (t.get("rate")) |r| switch (r) {
                .integer => |n| if (n > 0 and n <= max_rate) @intCast(n) else 0,
                else => 0,
            } else 0,
        };
    }
    return out;
}

/// The file's text for `keys`.
pub fn render(arena: Allocator, keys: []const Key) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "# dksearch API keys (hashes only). Made with `dksearch api-key add` or the administration page.\n");
    for (keys) |k| {
        try out.print(arena, "\n[[key]]\nname = \"{s}\"\nhash = \"sha256:{x}\"\ncreated = {d}\ncollections = [", .{ k.name, &k.hash, k.created });
        for (k.collections, 0..) |c, i| {
            if (i > 0) try out.appendSlice(arena, ", ");
            try out.print(arena, "\"{s}\"", .{c});
        }
        try out.appendSlice(arena, "]\n");
        if (k.rate > 0) try out.print(arena, "rate = {d}\n", .{k.rate});
        if (k.node) |n| try out.print(arena, "node = \"{s}\"\n", .{n});
        if (k.adult) try out.appendSlice(arena, "adult = true\n");
    }
    return out.items;
}

/// The key a presented token belongs to, or null. Compares in constant time.
pub fn find(keys: []const Key, token: []const u8) ?Key {
    if (token.len != token_len or !std.mem.startsWith(u8, token, token_prefix)) return null;
    const h = hashOf(token);
    var found: ?Key = null;
    for (keys) |k| if (std.crypto.timing_safe.eql([32]u8, k.hash, h)) {
        found = k;
    };
    return found;
}

/// A new random token (shown once to whoever makes the key).
pub fn newToken(io: Io, out: *[token_len]u8) KeyError![]const u8 {
    var raw: [32]u8 = undefined;
    io.randomSecure(&raw) catch return error.EntropyUnavailable;
    defer std.crypto.secureZero(u8, &raw);
    @memcpy(out[0..token_prefix.len], token_prefix);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out[token_prefix.len..], &raw);
    return out;
}

/// Loads the keys from `path` under `dir`. A missing file is no keys; a file others can read is refused.
pub fn load(arena: Allocator, io: Io, dir: Io.Dir, path: []const u8) KeyError![]const Key {
    const file = dir.openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return error.Unreadable,
    };
    defer file.close(io);
    const st = file.stat(io) catch return error.Unreadable;
    if (@hasDecl(@TypeOf(st.permissions), "toMode")) {
        if (st.permissions.toMode() & 0o077 != 0) return error.InsecurePermissions;
    }
    if (st.size > max_file_bytes) return error.Malformed;
    const buf = try arena.alloc(u8, @intCast(st.size));
    const n = file.readPositionalAll(io, buf, 0) catch return error.Unreadable;
    return parse(arena, buf[0..n]);
}

/// Writes the keys (mode 0600, through a temporary file and a rename).
pub fn save(arena: Allocator, io: Io, dir: Io.Dir, path: []const u8, keys: []const Key) KeyError!void {
    const text = try render(arena, keys);
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&name_buf, "{s}.{x}.tmp", .{ path, rnd }) catch return error.WriteFailed;
    {
        const f = dir.createFile(io, tmp, .{ .truncate = true, .permissions = Io.File.Permissions.fromMode(0o600) }) catch return error.WriteFailed;
        defer f.close(io);
        f.setPermissions(io, Io.File.Permissions.fromMode(0o600)) catch return error.WriteFailed;
        f.writePositionalAll(io, text, 0) catch return error.WriteFailed;
        f.sync(io) catch return error.WriteFailed;
    }
    dir.rename(tmp, dir, path, io) catch return error.WriteFailed;
}

/// Adds a key named `name` for `collections` (names are not checked against the configuration here) and returns the
/// new list. The token is written to `token_out`; only its hash is kept.
pub fn add(arena: Allocator, io: Io, keys: []const Key, name: []const u8, collections: []const []const u8, now: i64, token_out: *[token_len]u8) KeyError![]const Key {
    return addRated(arena, io, keys, name, collections, now, 0, token_out);
}

/// Like `add`, with a limit of `rate` requests per minute (0: none).
pub fn addRated(arena: Allocator, io: Io, keys: []const Key, name: []const u8, collections: []const []const u8, now: i64, rate: u32, token_out: *[token_len]u8) KeyError![]const Key {
    return addBound(arena, io, keys, name, collections, now, rate, null, token_out);
}

/// Like `addRated`, bound to the node `node` (a `dkn_...` id) when given.
pub fn addBound(arena: Allocator, io: Io, keys: []const Key, name: []const u8, collections: []const []const u8, now: i64, rate: u32, node: ?[]const u8, token_out: *[token_len]u8) KeyError![]const Key {
    if (node) |n| if (n.len != id_node_len or !std.mem.startsWith(u8, n, "dkn_")) return error.BadName;
    if (!validKeyName(name)) return error.BadName;
    if (keys.len >= max_keys) return error.TooMany;
    for (keys) |k| if (std.mem.eql(u8, k.name, name)) return error.Duplicate;
    _ = try newToken(io, token_out);
    const h = hashOf(token_out);
    const out = try arena.alloc(Key, keys.len + 1);
    @memcpy(out[0..keys.len], keys);
    out[keys.len] = .{ .id = try idOf(arena, h), .name = try arena.dupe(u8, name), .hash = h, .collections = try arena.dupe([]const u8, collections), .created = now, .rate = @min(rate, max_rate), .node = if (node) |n| try arena.dupe(u8, n) else null };
    return out;
}

/// A copy of `keys` in which the key named `name` is marked adult (not subject to safe search).
pub fn withAdult(arena: Allocator, keys: []const Key, name: []const u8) Allocator.Error![]const Key {
    const out = try arena.dupe(Key, keys);
    for (out) |*k| if (std.mem.eql(u8, k.name, name)) {
        k.adult = true;
    };
    return out;
}

/// The keys without the one named or with id `which` (null if there is none).
pub fn remove(arena: Allocator, keys: []const Key, which: []const u8) Allocator.Error!?[]const Key {
    var at: ?usize = null;
    for (keys, 0..) |k, i| if (std.mem.eql(u8, k.id, which) or std.mem.eql(u8, k.name, which)) {
        at = i;
    };
    const i = at orelse return null;
    const out = try arena.alloc(Key, keys.len - 1);
    @memcpy(out[0..i], keys[0..i]);
    @memcpy(out[i..], keys[i + 1 ..]);
    return out;
}

/// The keys of a running server, re-read when the file changes (at most once a second is it looked at), so a key made
/// or removed on the command line or in the administration pages takes effect without a restart.
pub const KeyStore = struct {
    gpa: Allocator,
    io: Io,
    /// The data directory (where `api-keys.toml` lives).
    dir_path: []const u8,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    keys: []const Key = &.{},
    size: u64 = std.math.maxInt(u64),
    mtime_ns: i96 = 0,
    checked_ns: i96 = 0,
    /// Requests counted in the current minute, by key id.
    windows: std.StringHashMapUnmanaged(struct { window: i64, count: u32 }) = .empty,

    pub fn init(gpa: Allocator, io: Io, dir_path: []const u8) KeyStore {
        return .{ .gpa = gpa, .io = io, .dir_path = dir_path, .arena = .init(gpa) };
    }

    pub fn deinit(self: *KeyStore) void {
        self.windows.deinit(self.gpa);
        self.arena.deinit();
    }

    pub const Found = struct { id: []const u8, name: []const u8, collections: []const []const u8, rate: u32 = 0, node: ?[]const u8 = null, adult: bool = false };

    /// Counts a request of key `id` against its limit of `rate` a minute (fixed one-minute windows). Null if it may
    /// go ahead; otherwise the seconds until the window ends.
    pub fn allow(self: *KeyStore, id: []const u8, rate: u32) ?u32 {
        if (rate == 0) return null;
        const now_s: i64 = std.Io.Clock.real.now(self.io).toSeconds();
        const window = @divFloor(now_s, 60);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const gop = self.windows.getOrPut(self.gpa, id) catch return null; // out of memory: do not block anyone
        if (!gop.found_existing) {
            gop.key_ptr.* = self.arena.allocator().dupe(u8, id) catch {
                _ = self.windows.remove(id);
                return null;
            };
            gop.value_ptr.* = .{ .window = window, .count = 0 };
        }
        if (gop.value_ptr.window != window) gop.value_ptr.* = .{ .window = window, .count = 0 };
        if (gop.value_ptr.count >= rate) return @intCast(@max(1, (window + 1) * 60 - now_s));
        gop.value_ptr.count += 1;
        return null;
    }

    /// The key a presented token belongs to (strings copied into `out`), or null.
    pub fn lookup(self: *KeyStore, out: Allocator, token: []const u8) Allocator.Error!?Found {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.refresh();
        const k = find(self.keys, token) orelse return null;
        const colls = try out.alloc([]const u8, k.collections.len);
        for (k.collections, colls) |c, *o| o.* = try out.dupe(u8, c);
        return .{ .id = try out.dupe(u8, k.id), .name = try out.dupe(u8, k.name), .collections = colls, .rate = k.rate, .node = if (k.node) |n| try out.dupe(u8, n) else null, .adult = k.adult };
    }

    fn refresh(self: *KeyStore) void {
        const now = Io.Timestamp.now(self.io, .awake).nanoseconds;
        if (self.checked_ns != 0 and now - self.checked_ns < std.time.ns_per_s) return;
        self.checked_ns = now;
        var dir = Io.Dir.cwd().openDir(self.io, self.dir_path, .{}) catch return self.drop();
        defer dir.close(self.io);
        const st = dir.statFile(self.io, file_name, .{}) catch return self.drop();
        const mtime: i96 = st.mtime.nanoseconds;
        if (st.size == self.size and mtime == self.mtime_ns) return;
        // Changed: read it again into a fresh arena. A file that cannot be used means no keys (fail closed).
        var fresh = std.heap.ArenaAllocator.init(self.gpa);
        const keys = load(fresh.allocator(), self.io, dir, file_name) catch {
            fresh.deinit();
            return self.drop();
        };
        self.arena.deinit();
        self.arena = fresh;
        self.keys = keys;
        self.size = st.size;
        self.mtime_ns = mtime;
    }

    fn drop(self: *KeyStore) void {
        self.arena.deinit();
        self.arena = .init(self.gpa);
        self.keys = &.{};
        self.size = std.math.maxInt(u64);
        self.mtime_ns = 0;
    }
};

const testing = std.testing;

test "a scope is the union of its collections' sources; * is everything; unknown names grant nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const colls = [_]config.Collection{
        .{ .name = "books", .sources = &.{ "folklore", "banking" } },
        .{ .name = "docs", .sources = &.{ "docs", "banking" } },
    };
    const s = try resolve(a, &colls, &.{ "books", "docs" });
    try testing.expectEqual(@as(usize, 3), s.sources.?.len); // banking once
    try testing.expect(s.allows("folklore") and s.allows("docs") and !s.allows("reddit"));
    try testing.expect((try resolve(a, &colls, &.{"*"})).allows("anything"));
    try testing.expect((try resolve(a, &colls, &.{"nope"})).none());
    try testing.expect((try resolve(a, &colls, &.{})).none());
}

test "keys: made, found by token, stored as hashes, removed by id or name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tok1: [token_len]u8 = undefined;
    var tok2: [token_len]u8 = undefined;
    var keys = try add(a, testing.io, &.{}, "laptop", &.{"books"}, 1700000000, &tok1);
    keys = try add(a, testing.io, keys, "peer b", &.{ "docs", "books" }, 1700000001, &tok2);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectError(error.Duplicate, add(a, testing.io, keys, "laptop", &.{}, 0, &tok1));
    try testing.expectError(error.BadName, add(a, testing.io, keys, "bad\"name", &.{}, 0, &tok1));
    try testing.expectEqualStrings("laptop", find(keys, &tok1).?.name);
    try testing.expectEqualStrings("peer b", find(keys, &tok2).?.name);
    try testing.expect(find(keys, "dkk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx") == null);
    try testing.expect(find(keys, "nonsense") == null);
    // The file holds hashes, never the token.
    const text = try render(a, keys);
    try testing.expect(std.mem.indexOf(u8, text, tok1[0..]) == null);
    const back = try parse(a, text);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("laptop", find(back, &tok1).?.name);
    try testing.expectEqual(@as(usize, 2), find(back, &tok2).?.collections.len);
    try testing.expectEqual(@as(i64, 1700000001), back[1].created);
    // Removal by id or by name.
    const without = (try remove(a, back, back[0].id)).?;
    try testing.expectEqual(@as(usize, 1), without.len);
    try testing.expectEqualStrings("peer b", without[0].name);
    try testing.expect((try remove(a, back, "nobody")) == null);
    try testing.expectEqual(@as(usize, 1), (try remove(a, back, "peer b")).?.len);
}

test "the key file is written for its owner only, and a readable one is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tok: [token_len]u8 = undefined;
    const keys = try add(a, testing.io, &.{}, "k", &.{"*"}, 5, &tok);
    try save(a, testing.io, tmp.dir, file_name, keys);
    const back = try load(a, testing.io, tmp.dir, file_name);
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expect(find(back, &tok) != null);
    const st = try (try tmp.dir.openFile(testing.io, file_name, .{})).stat(testing.io);
    if (@hasDecl(@TypeOf(st.permissions), "toMode")) try testing.expectEqual(@as(u32, 0), st.permissions.toMode() & 0o077);
    // Missing: no keys. Readable by others: refused.
    try testing.expectEqual(@as(usize, 0), (try load(a, testing.io, tmp.dir, "missing.toml")).len);
    var f = try tmp.dir.openFile(testing.io, file_name, .{});
    defer f.close(testing.io);
    try f.setPermissions(testing.io, Io.File.Permissions.fromMode(0o644));
    try testing.expectError(error.InsecurePermissions, load(a, testing.io, tmp.dir, file_name));
}

test "a key store notices a key made after it started, and one removed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    var store = KeyStore.init(testing.allocator, testing.io, base);
    defer store.deinit();
    var tok: [token_len]u8 = undefined;
    try testing.expect((try store.lookup(a, "dkk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")) == null);
    const keys = try add(a, testing.io, &.{}, "k", &.{"books"}, 5, &tok);
    try save(a, testing.io, tmp.dir, file_name, keys);
    store.checked_ns = 0; // the file is looked at at most once a second; look now
    const found = (try store.lookup(a, &tok)).?;
    try testing.expectEqualStrings("k", found.name);
    try testing.expectEqualStrings("books", found.collections[0]);
    // Removed: gone at the next look.
    try save(a, testing.io, tmp.dir, file_name, &.{});
    store.checked_ns = 0;
    try testing.expect((try store.lookup(a, &tok)) == null);
}

test "a key's limit is stored, read back, and counted per minute" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tok: [token_len]u8 = undefined;
    var keys = try addRated(a, testing.io, &.{}, "slow", &.{"*"}, 1, 2, &tok);
    var tok2: [token_len]u8 = undefined;
    keys = try add(a, testing.io, keys, "free", &.{"*"}, 2, &tok2);
    const text = try render(a, keys);
    try testing.expect(std.mem.indexOf(u8, text, "rate = 2") != null);
    const back = try parse(a, text);
    try testing.expectEqual(@as(u32, 2), back[0].rate);
    try testing.expectEqual(@as(u32, 0), back[1].rate);
    var store = KeyStore.init(testing.allocator, testing.io, ".");
    defer store.deinit();
    // Two requests pass, the third is told to wait; no limit never waits; another key has its own count.
    try testing.expect(store.allow("aaaa", 2) == null);
    try testing.expect(store.allow("aaaa", 2) == null);
    const wait = store.allow("aaaa", 2);
    try testing.expect(wait != null and wait.? >= 1 and wait.? <= 60);
    try testing.expect(store.allow("bbbb", 2) == null);
    for (0..100) |_| try testing.expect(store.allow("cccc", 0) == null);
}

test "a key bound to a node is stored and read back, and a bad node id is refused" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tok: [token_len]u8 = undefined;
    const node = "dkn_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const keys = try addBound(a, testing.io, &.{}, "b", &.{"*"}, 1, 0, node, &tok);
    const back = try parse(a, try render(a, keys));
    try testing.expectEqualStrings(node, back[0].node.?);
    var tok2: [token_len]u8 = undefined;
    try testing.expectError(error.BadName, addBound(a, testing.io, &.{}, "c", &.{"*"}, 1, 0, "not-an-id", &tok2));
}
