//! What the crawler does with the addresses it finds (docs/decisions/0058): tidy them so one page has one address,
//! recognise the ones that lead nowhere new (crawl traps), and say which are worth asking for first. All of it works on the
//! text of the address; nothing here touches the network.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Query parameters that only say where a visitor came from or who they are: the page is the same without them.
fn isNoiseParam(name: []const u8) bool {
    if (name.len >= 4 and std.ascii.eqlIgnoreCase(name[0..4], "utm_")) return true;
    const exact = [_][]const u8{
        "fbclid",  "gclid",      "dclid",   "gbraid",  "wbraid", "msclkid",   "yclid",      "mc_cid",    "mc_eid",
        "igshid",  "_ga",        "_gl",     "ref_src", "twclid", "phpsessid", "jsessionid", "sessionid", "sessid",
        "mkt_tok", "oly_enc_id", "vero_id", "_hsenc",  "_hsmi",
    };
    for (exact) |e| if (std.ascii.eqlIgnoreCase(name, e)) return true;
    return false;
}

const Parts = struct {
    scheme: []const u8,
    host: []const u8, // with the port, as written
    path: []const u8,
    query: []const u8,
};

fn split(url: []const u8) ?Parts {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[sep + 3 ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] != '/' and rest[end] != '?' and rest[end] != '#') end += 1;
    const authority = rest[0..end];
    var after = rest[end..];
    if (std.mem.indexOfScalar(u8, after, '#')) |h| after = after[0..h];
    var path = after;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, after, '?')) |q| {
        path = after[0..q];
        query = after[q + 1 ..];
    }
    return .{ .scheme = url[0..sep], .host = authority, .path = path, .query = query };
}

fn lessParam(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The address with what does not change the page taken off: the fragment; a default port; repeated slashes and session
/// parameters in the path (`;jsessionid=...`); noise in the query (`utm_*`, `fbclid`, ...), with the rest in a fixed order.
/// An address that is not `scheme://host/...` is returned as it is.
pub fn tidy(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    const p = split(url) orelse return url;
    var out: std.ArrayList(u8) = .empty;
    for (p.scheme) |c| try out.append(arena, std.ascii.toLower(c));
    try out.appendSlice(arena, "://");
    // The host in lower case; the port only when it is not the default of the scheme.
    var host = p.host;
    var port: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |c| if (std.mem.indexOfScalar(u8, host, ']') == null or c > std.mem.lastIndexOfScalar(u8, host, ']').?) {
        port = host[c + 1 ..];
        host = host[0..c];
    };
    // A colon with no port after it (`host:`, or `host::` from a mistake) says nothing: all of them go, so that tidying twice is
    // the same as tidying once (found by the fuzzer).
    host = std.mem.trimEnd(u8, host, ":");
    for (host) |c| try out.append(arena, std.ascii.toLower(c));
    const default_port: []const u8 = if (std.ascii.eqlIgnoreCase(p.scheme, "https")) "443" else "80";
    if (port.len > 0 and !std.mem.eql(u8, port, default_port)) {
        try out.append(arena, ':');
        try out.appendSlice(arena, port);
    }
    // The path: one slash at a time, and a session parameter removed.
    var path = p.path;
    // Every one: tidying an address that is tidy must change nothing, or one page is asked for under two addresses (found by
    // the fuzzer on a path with two session parameters).
    while (std.ascii.findIgnoreCase(path, ";jsessionid")) |at| {
        var e = at + 1;
        while (e < path.len and path[e] != '/') e += 1;
        const cut = try std.mem.concat(arena, u8, &.{ path[0..at], path[e..] });
        path = cut;
    }
    if (path.len == 0) {
        try out.append(arena, '/');
    } else {
        // Empty segments and `.` are dropped, `..` takes the segment before it with it (`/a/./b//c/../d/` is `/a/b/d/`).
        var segs: std.ArrayList([]const u8) = .empty;
        var trailing = path[path.len - 1] == '/';
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |seg| {
            if (seg.len == 0) continue;
            if (std.mem.eql(u8, seg, ".")) {
                trailing = true;
                continue;
            }
            if (std.mem.eql(u8, seg, "..")) {
                _ = segs.pop();
                trailing = true;
                continue;
            }
            try segs.append(arena, seg);
            trailing = path[path.len - 1] == '/';
        }
        for (segs.items) |seg| {
            try out.append(arena, '/');
            try out.appendSlice(arena, seg);
        }
        if (segs.items.len == 0 or trailing) try out.append(arena, '/');
    }
    // The query: noise taken out, the rest in order.
    if (p.query.len > 0) {
        var kept: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, p.query, '&');
        while (it.next()) |param| {
            if (param.len == 0) continue;
            const name = param[0 .. std.mem.indexOfScalar(u8, param, '=') orelse param.len];
            if (isNoiseParam(name)) continue;
            try kept.append(arena, param);
        }
        if (kept.items.len > 0) {
            std.mem.sort([]const u8, kept.items, {}, lessParam);
            try out.append(arena, '?');
            for (kept.items, 0..) |param, i| {
                if (i > 0) try out.append(arena, '&');
                try out.appendSlice(arena, param);
            }
        }
    }
    return out.items;
}

/// Longest address followed, and the other limits that mark an address as one that leads nowhere new.
pub const max_url_len = 2000;
const max_segments = 12;
const max_query_params = 8;

/// Query parameters of a page that is made on the fly from a search or a view of one page: following them never ends.
fn isDynamicParam(name: []const u8, value: []const u8) bool {
    const search = [_][]const u8{ "s", "q", "query", "search", "keyword", "keywords", "replytocom", "share", "oldid", "diff", "printable", "veaction", "mobileaction", "redlink" };
    for (search) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    if (std.ascii.eqlIgnoreCase(name, "action")) {
        const views = [_][]const u8{ "edit", "history", "raw", "info", "delete", "purge", "submit", "watch", "unwatch", "markpatrolled", "rollback", "render" };
        for (views) |v| if (std.ascii.eqlIgnoreCase(value, v)) return true;
    }
    return false;
}

/// Whether following this address is a trap or a waste: a very long address, a very deep path, a path that repeats
/// itself (`/a/b/a/b/a/b`, the sign of a relative link going round in circles), many query parameters, an on-the-fly page
/// (search results, an edit or history view of a wiki page, `Special:` pages of a wiki, comment-reply links).
pub fn isTrap(url: []const u8) bool {
    if (url.len > max_url_len) return true;
    const p = split(url) orelse return false;
    var segments: usize = 0;
    var seen: [max_segments + 1][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, p.path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (seg.len >= 7 and (std.ascii.startsWithIgnoreCase(seg, "Special:") or std.ascii.startsWithIgnoreCase(seg, "Special%3A"))) return true;
        if (segments >= max_segments) return true;
        var same: usize = 0;
        for (seen[0..segments]) |s| if (std.mem.eql(u8, s, seg)) {
            same += 1;
        };
        if (same >= 2) return true; // the third time the same name appears
        seen[segments] = seg;
        segments += 1;
    }
    if (p.query.len > 0) {
        var params: usize = 0;
        var qi = std.mem.splitScalar(u8, p.query, '&');
        while (qi.next()) |param| {
            if (param.len == 0) continue;
            params += 1;
            const eq = std.mem.indexOfScalar(u8, param, '=');
            const name = param[0 .. eq orelse param.len];
            const value = if (eq) |e| param[e + 1 ..] else "";
            if (isDynamicParam(name, value)) return true;
            // A wiki's title parameter can name a Special page.
            if (std.ascii.eqlIgnoreCase(name, "title") and (std.ascii.startsWithIgnoreCase(value, "Special:") or std.ascii.startsWithIgnoreCase(value, "Special%3A"))) return true;
        }
        if (params > max_query_params) return true;
    }
    return false;
}

/// How worth asking for first an address is (smaller is better): the pages near the top of a site, without a query, with a
/// short address, are the ones people write and link to; the deep and the parameterised ones are the long tail.
pub fn score(url: []const u8) u32 {
    const p = split(url) orelse return @intCast(@min(url.len, 1000));
    var segments: u32 = 0;
    var it = std.mem.splitScalar(u8, p.path, '/');
    while (it.next()) |seg| if (seg.len > 0) {
        segments += 1;
    };
    return segments * 10 + (if (p.query.len > 0) @as(u32, 25) else 0) + @as(u32, @intCast(@min(url.len / 32, 20)));
}

const testing = std.testing;

fn tidyTo(url: []const u8, want: []const u8) !void {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectEqualStrings(want, try tidy(ar.allocator(), url));
}

test "tidy: one page, one address" {
    try tidyTo("HTTPS://Example.ORG:443/a//b/?utm_source=x&b=2&a=1&fbclid=zz#top", "https://example.org/a/b/?a=1&b=2");
    try tidyTo("http://example.org:80/", "http://example.org/");
    try tidyTo("http://example.org:8080/x", "http://example.org:8080/x");
    try tidyTo("https://example.org", "https://example.org/");
    try tidyTo("https://example.org/page;jsessionid=ABC123/more?PHPSESSID=q&id=5", "https://example.org/page/more?id=5");
    try tidyTo("https://example.org/?utm_campaign=a&utm_medium=b", "https://example.org/");
    try tidyTo("https://example.org/wiki/Foo?action=view&oldid=3", "https://example.org/wiki/Foo?action=view&oldid=3");
    try tidyTo("not a url", "not a url");
    // The same page reached with the parameters in another order is one address.
    try tidyTo("https://e.org/s?z=1&a=2", "https://e.org/s?a=2&z=1");
    try tidyTo("https://e.org/s?a=2&z=1", "https://e.org/s?a=2&z=1");
    // A colon with no port: one or several are dropped, once and for all.
    try tidyTo("http://example.org:/a", "http://example.org/a");
    try tidyTo("s://e.orhttps:://e.org/", "s://e.orhttps/e.org/");
    // More than one session parameter in a path: all go, and a second tidying finds nothing more to do.
    try tidyTo("https://e.org/a;jsessionid=1/http://x.org/b;JSESSIONID=2/c;jsessionid=3?x=1", "https://e.org/a/http:/x.org/b/c?x=1");
    // Dot segments: `/./features/` is `/features/`, `..` goes up one.
    try tidyTo("https://www.dragonflybsd.org/./features/", "https://www.dragonflybsd.org/features/");
    try tidyTo("https://e.org/a/./b//c/../d/", "https://e.org/a/b/d/");
    try tidyTo("https://e.org/a/b/..", "https://e.org/a/");
    try tidyTo("https://e.org/a/b/c.html", "https://e.org/a/b/c.html");
    try tidyTo("https://e.org/../x", "https://e.org/x");
}

test "isTrap: loops, depth, on-the-fly pages and wiki special pages" {
    try testing.expect(!isTrap("https://e.org/"));
    try testing.expect(!isTrap("https://e.org/docs/guide/intro.html"));
    try testing.expect(!isTrap("https://e.org/wiki/Kernel"));
    try testing.expect(!isTrap("https://e.org/a/b/a/c")); // a name twice is fine
    try testing.expect(isTrap("https://e.org/a/b/a/b/a/b")); // round in circles
    try testing.expect(isTrap("https://e.org/x/x/x"));
    try testing.expect(isTrap("https://e.org/1/2/3/4/5/6/7/8/9/10/11/12/13")); // too deep
    try testing.expect(isTrap("https://e.org/search?q=linux"));
    try testing.expect(isTrap("https://e.org/?s=linux"));
    try testing.expect(isTrap("https://e.org/index.php?title=Foo&action=edit"));
    try testing.expect(isTrap("https://e.org/index.php?title=Foo&action=history"));
    try testing.expect(!isTrap("https://e.org/index.php?title=Foo&action=view"));
    try testing.expect(isTrap("https://e.org/index.php?title=Foo&oldid=77"));
    try testing.expect(isTrap("https://wiki.e.org/wiki/Special:RecentChanges"));
    try testing.expect(isTrap("https://wiki.e.org/index.php?title=Special:AllPages"));
    try testing.expect(isTrap("https://e.org/post?replytocom=12"));
    try testing.expect(isTrap("https://e.org/p?a=1&b=2&c=3&d=4&e=5&f=6&g=7&h=8&i=9"));
    var long: [2100]u8 = undefined;
    @memcpy(long[0..19], "https://e.org/aaaa?");
    @memset(long[19..], 'a');
    try testing.expect(isTrap(&long));
}

test "score: top-level pages before deep and parameterised ones" {
    try testing.expect(score("https://e.org/") < score("https://e.org/docs/"));
    try testing.expect(score("https://e.org/docs/") < score("https://e.org/docs/a/b/c"));
    try testing.expect(score("https://e.org/docs/a") < score("https://e.org/docs/a?page=2"));
}
