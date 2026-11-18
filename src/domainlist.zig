//! Domain lists (docs/decisions/0048): a blocklist (never shown), a demotion list (ranked lower) and the ban lists
//! of safe search. A list entry covers the domain and everything under it: `example.com` matches `example.com` and
//! `www.example.com`, not `notexample.com`.
//!
//! Lists are read from files in the common formats: one domain per line, the hosts-file format (`0.0.0.0 domain`), the
//! ad-blocker format (`||domain^`), `*.domain`, with `#` comments. dksearch ships no list: the owner names the ones to use.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Set = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,
    /// Entries given as the MD5 of a domain (32 hex digits), as banned-domain lists of some services are published:
    /// they match a host whose name (or whose parent domain) has that hash, without the list naming the domain.
    hashes: std.AutoHashMapUnmanaged([16]u8, void) = .empty,

    pub fn isEmpty(self: *const Set) bool {
        return self.map.count() == 0 and self.hashes.count() == 0;
    }

    pub fn count(self: *const Set) usize {
        return self.map.count() + self.hashes.count();
    }

    /// Adds the MD5 of a domain, as 32 hex digits. False when the text is not that.
    pub fn addHash(self: *Set, arena: Allocator, hex: []const u8) Allocator.Error!bool {
        if (hex.len != 32) return false;
        var raw: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw, hex) catch return false;
        try self.hashes.put(arena, raw, {});
        return true;
    }

    /// Adds `domain` (any case, no scheme or path). Returns false when it is not a usable domain.
    pub fn add(self: *Set, arena: Allocator, domain: []const u8) Allocator.Error!bool {
        const d = normalize(domain) orelse return false;
        var buf: [253]u8 = undefined;
        const lower = std.ascii.lowerString(&buf, d);
        if (self.map.contains(lower)) return true;
        try self.map.put(arena, try arena.dupe(u8, lower), {});
        return true;
    }

    /// Whether `host` is in the set or under a domain of it.
    pub fn matches(self: *const Set, host_in: []const u8) bool {
        if (self.isEmpty() or host_in.len == 0 or host_in.len > 253) return false;
        var buf: [253]u8 = undefined;
        var host = std.ascii.lowerString(&buf, std.mem.trimEnd(u8, host_in, "."));
        while (true) {
            if (self.map.contains(host)) return true;
            if (self.hashes.count() > 0) {
                var digest: [16]u8 = undefined;
                std.crypto.hash.Md5.hash(host, &digest, .{});
                if (self.hashes.contains(digest)) return true;
            }
            const dot = std.mem.indexOfScalar(u8, host, '.') orelse return false;
            host = host[dot + 1 ..];
        }
    }

    /// Adds the entries of a list in any of the supported formats; returns how many lines were used.
    pub fn addText(self: *Set, arena: Allocator, text: []const u8) Allocator.Error!usize {
        var used: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const d = entryOf(raw) orelse continue;
            if (d.len == 32) {
                if (try self.addHash(arena, d)) {
                    used += 1;
                    continue;
                }
            }
            if (try self.add(arena, d)) used += 1;
        }
        return used;
    }
};

/// The domain on one line of a list, or null for a comment, a blank line or something that is not a domain.
pub fn entryOf(raw: []const u8) ?[]const u8 {
    var line = raw;
    if (std.mem.indexOfScalar(u8, line, '#')) |h| line = line[0..h];
    line = std.mem.trim(u8, line, " \t\r");
    if (line.len == 0) return null;
    // Ad-blocker rules: ||example.com^ (other rule kinds are not domains).
    if (std.mem.startsWith(u8, line, "||")) {
        const rest = line[2..];
        const end = std.mem.indexOfAny(u8, rest, "^/$*") orelse rest.len;
        if (end < rest.len and rest[end] != '^') return null;
        return rest[0..end];
    }
    if (line[0] == '!' or line[0] == '[' or line[0] == '@') return null;
    // Hosts files: an address, then the names.
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const first = it.next() orelse return null;
    var name = first;
    if (isAddress(first)) name = it.next() orelse return null;
    if (std.mem.startsWith(u8, name, "*.")) name = name[2..];
    if (std.mem.startsWith(u8, name, ".")) name = name[1..];
    if (std.mem.eql(u8, name, "localhost") or std.mem.eql(u8, name, "localhost.localdomain") or std.mem.eql(u8, name, "broadcasthost")) return null;
    return name;
}

fn isAddress(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, ':') != null) return true; // IPv6, as in "::1"
    var dots: usize = 0;
    for (s) |ch| {
        if (ch == '.') dots += 1 else if (!std.ascii.isDigit(ch)) return false;
    }
    return dots == 3;
}

/// A hostname: letters, digits, '-', '_' and '.', at least one dot, labels of 1 to 63 characters; not an address.
fn normalize(d: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, std.mem.trimEnd(u8, d, "."), " ");
    if (t.len < 3 or t.len > 253) return null;
    if (std.mem.indexOfScalar(u8, t, '.') == null) return null;
    if (isAddress(t)) return null;
    var label_len: usize = 0;
    for (t) |ch| {
        if (ch == '.') {
            if (label_len == 0) return null;
            label_len = 0;
            continue;
        }
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch >= 0x80)) return null;
        label_len += 1;
        if (label_len > 63) return null;
    }
    if (label_len == 0) return null;
    return t;
}

/// The host of an address (`http://user@Host:8080/path`), lower case, or null.
pub fn hostOf(buf: *[253]u8, url: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, url, "://") orelse return null;
    var rest = url[at + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    rest = rest[0..end];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |i| rest = rest[i + 1 ..];
    if (rest.len > 0 and rest[0] == '[') return null;
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| rest = rest[0..i];
    if (rest.len == 0 or rest.len > 253) return null;
    return std.ascii.lowerString(buf, rest);
}

/// "onion" or "i2p" for an address on one of those networks (a normal browser cannot open it), else null.
pub fn hiddenNetworkOf(url: ?[]const u8) ?[]const u8 {
    const u = url orelse return null;
    var buf: [253]u8 = undefined;
    const host = hostOf(&buf, u) orelse return null;
    if (std.mem.endsWith(u8, host, ".onion")) return "onion";
    if (std.mem.endsWith(u8, host, ".i2p")) return "i2p";
    return null;
}

/// The lists of this process, set by the program once they are read, for code that has no other way to reach them (the
/// crawler asks it before contacting a site). Null: no lists.
pub var global: ?*const Lists = null;

/// What is hidden and what is ranked lower, for the whole server.
pub const Lists = struct {
    /// Never shown, to anyone: the blocklist, plus the ban lists when safe search is on.
    blocked: Set = .{},
    demoted: Set = .{},
    /// A demoted domain's score is multiplied by this many percent (1 to 99).
    demote_percent: u32 = 30,

    /// True if the address of a result is on the blocked list.
    pub fn blocksUrl(self: *const Lists, url: ?[]const u8) bool {
        const u = url orelse return false;
        if (self.blocked.isEmpty()) return false;
        var buf: [253]u8 = undefined;
        const host = hostOf(&buf, u) orelse return false;
        return self.blocked.matches(host);
    }
};

/// Reads the list files into `set` (a file that cannot be read is an error naming it).
pub fn loadFiles(io: Io, arena: Allocator, set: *Set, paths: []const []const u8, failed: *[]const u8) error{ OutOfMemory, Unreadable }!void {
    for (paths) |p| {
        const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(256 * 1024 * 1024)) catch |e| {
            failed.* = p;
            return if (e == error.OutOfMemory) error.OutOfMemory else error.Unreadable;
        };
        _ = try set.addText(arena, text);
    }
}

const testing = std.testing;

test "list formats: plain, hosts, ad-blocker, wildcard, comments" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var s: Set = .{};
    const used = try s.addText(a,
        \\# a comment
        \\plain.example
        \\0.0.0.0 hosts.example   # trailing comment
        \\127.0.0.1 localhost
        \\::1 localhost
        \\||adblock.example^
        \\||path.example/ads
        \\*.wild.example
        \\!an adblock comment
        \\@@||allowed.example^
        \\UPPER.Example
        \\1.2.3.4
        \\nodots
        \\
        \\bad domain.example
    );
    try testing.expectEqual(@as(usize, 5), used);
    for ([_][]const u8{ "plain.example", "hosts.example", "adblock.example", "wild.example", "upper.example" }) |d| try testing.expect(s.matches(d));
    try testing.expect(!s.matches("path.example")); // a rule with a path is not a whole domain
    try testing.expect(!s.matches("allowed.example"));
    try testing.expect(!s.matches("localhost"));
}

test "a domain covers its subdomains, not look-alikes" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var s: Set = .{};
    try testing.expect(try s.add(ar.allocator(), "Example.COM"));
    try testing.expect(!(try s.add(ar.allocator(), "com") or try s.add(ar.allocator(), "127.0.0.1")));
    try testing.expect(s.matches("example.com"));
    try testing.expect(s.matches("WWW.Example.com"));
    try testing.expect(s.matches("a.b.c.example.com."));
    try testing.expect(!s.matches("notexample.com"));
    try testing.expect(!s.matches("example.com.evil.net"));
    try testing.expect(!s.matches("com"));
    try testing.expect(!s.matches(""));
}

test "the host of an address" {
    var buf: [253]u8 = undefined;
    try testing.expectEqualStrings("example.com", hostOf(&buf, "https://user:pw@Example.com:8080/a?b#c").?);
    try testing.expectEqualStrings("x.onion", hostOf(&buf, "http://x.onion").?);
    try testing.expect(hostOf(&buf, "file:///home/a") == null); // no host
    try testing.expect(hostOf(&buf, "http://[::1]/x") == null);
    try testing.expect(hostOf(&buf, "no scheme") == null);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var l: Lists = .{};
    _ = try l.blocked.add(ar.allocator(), "bad.example");
    try testing.expect(l.blocksUrl("https://www.bad.example/x"));
    try testing.expect(!l.blocksUrl("https://good.example/x"));
    try testing.expect(!l.blocksUrl(null));
}

test "entries given as MD5 hashes match the domain and what is under it, and say nothing about the domain" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("hidden.example", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var s: Set = .{};
    const used = try s.addText(a, "# hashes of banned domains\n" ++ "plain.example\n" ++ hex ++ "\n" ++ "0123456789abcdef0123456789abcdeg\n");
    try testing.expectEqual(@as(usize, 2), used); // the last line is neither a hash nor a domain
    try testing.expect(s.matches("hidden.example"));
    try testing.expect(s.matches("WWW.Hidden.Example"));
    try testing.expect(s.matches("a.b.hidden.example"));
    try testing.expect(!s.matches("nothidden.example"));
    try testing.expect(!s.matches("example"));
    try testing.expect(s.matches("plain.example"));
    try testing.expectEqual(@as(usize, 2), s.count());
    try testing.expect(!s.isEmpty());
}

test "addresses on hidden networks are recognised" {
    try testing.expectEqualStrings("onion", hiddenNetworkOf("http://abc.onion/x").?);
    try testing.expectEqualStrings("i2p", hiddenNetworkOf("http://forum.i2p/").?);
    try testing.expect(hiddenNetworkOf("https://example.org/onion") == null);
    try testing.expect(hiddenNetworkOf("https://notonion.com/") == null);
    try testing.expect(hiddenNetworkOf(null) == null);
}
