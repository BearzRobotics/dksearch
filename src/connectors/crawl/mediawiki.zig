//! MediaWiki sites (docs/decisions/0059): a wiki has an official API for programs, and one of its calls lists every article.
//! That is a far better way to reach the whole of a wiki than following the links of its front page. This file only builds
//! the addresses of the calls and reads their answers; the crawler makes the requests (so robots.txt, the delay and the backoff
//! apply to them like to any page).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Whether a page's generator says it was made by MediaWiki.
pub fn isMediaWiki(generator: ?[]const u8) bool {
    const g = generator orelse return false;
    return std.ascii.startsWithIgnoreCase(g, "MediaWiki");
}

/// The address of the API from the `EditURI` link of a page (`//wiki.example.org/w/api.php?action=rsd`, relative to the page);
/// null when it cannot be made. The query is taken off.
pub fn apiFromEditUri(arena: Allocator, page_url: []const u8, edit_uri: []const u8) Allocator.Error!?[]const u8 {
    const no_query = edit_uri[0 .. std.mem.indexOfScalar(u8, edit_uri, '?') orelse edit_uri.len];
    if (no_query.len == 0) return null;
    const sep = std.mem.indexOf(u8, page_url, "://") orelse return null;
    const scheme = page_url[0..sep];
    const rest = page_url[sep + 3 ..];
    const authority_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const origin = page_url[0 .. sep + 3 + authority_end];
    if (std.mem.startsWith(u8, no_query, "//")) return try std.fmt.allocPrint(arena, "{s}:{s}", .{ scheme, no_query });
    if (std.mem.startsWith(u8, no_query, "/")) return try std.fmt.allocPrint(arena, "{s}{s}", .{ origin, no_query });
    if (std.ascii.startsWithIgnoreCase(no_query, "http://") or std.ascii.startsWithIgnoreCase(no_query, "https://")) return try arena.dupe(u8, no_query);
    return null;
}

pub fn siteinfoUrl(arena: Allocator, api: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}?action=query&meta=siteinfo&siprop=general&format=json", .{api});
}

/// The call that lists the articles (main namespace, redirects left out), 500 at a time; `cont` is the `apcontinue` of the
/// previous answer.
pub fn listUrl(arena: Allocator, api: []const u8, cont: ?[]const u8) Allocator.Error![]const u8 {
    const base = try std.fmt.allocPrint(arena, "{s}?action=query&list=allpages&aplimit=500&apnamespace=0&apfilterredir=nonredirects&format=json", .{api});
    const c = cont orelse return base;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, base);
    try out.appendSlice(arena, "&apcontinue=");
    try encodeTitle(arena, &out, c);
    return out.items;
}

/// `articlepath` of the siteinfo answer (`/wiki/$1`, `/index.php?title=$1`); null if the answer is not that.
pub fn parseArticlePath(arena: Allocator, body: []const u8) Allocator.Error!?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    const q = (switch (root) {
        .object => |o| o.get("query"),
        else => null,
    }) orelse return null;
    const g = (switch (q) {
        .object => |o| o.get("general"),
        else => null,
    }) orelse return null;
    const ap = (switch (g) {
        .object => |o| o.get("articlepath"),
        else => null,
    }) orelse return null;
    const text = switch (ap) {
        .string => |s| s,
        else => return null,
    };
    if (std.mem.indexOf(u8, text, "$1") == null or text.len > 200) return null;
    return text;
}

pub const Listing = struct {
    titles: []const []const u8,
    /// The `apcontinue` to ask the next page of the list with, or null at the end.
    next: ?[]const u8,
};

/// The titles of an `allpages` answer, and where the list goes on.
pub fn parseList(arena: Allocator, body: []const u8) Allocator.Error!Listing {
    var titles: std.ArrayList([]const u8) = .empty;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return .{ .titles = &.{}, .next = null };
    const obj = switch (root) {
        .object => |o| o,
        else => return .{ .titles = &.{}, .next = null },
    };
    if (obj.get("query")) |q| if (q == .object) if (q.object.get("allpages")) |pages| if (pages == .array) {
        for (pages.array.items) |p| {
            if (p != .object) continue;
            const t = p.object.get("title") orelse continue;
            if (t == .string and t.string.len > 0 and t.string.len <= 300) try titles.append(arena, t.string);
        }
    };
    var next: ?[]const u8 = null;
    if (obj.get("continue")) |c| if (c == .object) if (c.object.get("apcontinue")) |ac| if (ac == .string and ac.string.len <= 300) {
        next = ac.string;
    };
    return .{ .titles = titles.items, .next = next };
}

/// Appends `title` as MediaWiki writes it in an address: spaces as `_`, and bytes that are not safe percent-encoded.
fn encodeTitle(arena: Allocator, out: *std.ArrayList(u8), title: []const u8) Allocator.Error!void {
    for (title) |b| {
        if (b == ' ') {
            try out.append(arena, '_');
        } else if (std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '.' or b == '~' or b == ':' or b == '/' or b == '(' or b == ')' or b == ',' or b == '!' or b == '*' or b == ';' or b == '@') {
            try out.append(arena, b);
        } else {
            try out.print(arena, "%{X:0>2}", .{b});
        }
    }
}

/// The address of the article `title` on the wiki at `origin` (`https://wiki.example.org`), by the siteinfo `articlepath`.
pub fn articleUrl(arena: Allocator, origin: []const u8, articlepath: []const u8, title: []const u8) Allocator.Error![]const u8 {
    const at = std.mem.indexOf(u8, articlepath, "$1") orelse return try std.fmt.allocPrint(arena, "{s}{s}", .{ origin, articlepath });
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, origin);
    try out.appendSlice(arena, articlepath[0..at]);
    try encodeTitle(arena, &out, title);
    try out.appendSlice(arena, articlepath[at + 2 ..]);
    return out.items;
}

const testing = std.testing;

test "MediaWiki is recognised by its generator; the API address comes from the EditURI link" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expect(isMediaWiki("MediaWiki 1.43.0") and !isMediaWiki("WordPress 6.4") and !isMediaWiki(null));
    try testing.expectEqualStrings("https://wiki.e.org/w/api.php", (try apiFromEditUri(a, "https://wiki.e.org/wiki/Main_Page", "//wiki.e.org/w/api.php?action=rsd")).?);
    try testing.expectEqualStrings("https://wiki.e.org/api.php", (try apiFromEditUri(a, "https://wiki.e.org/", "/api.php?action=rsd")).?);
    try testing.expectEqualStrings("http://x.org/api.php", (try apiFromEditUri(a, "https://wiki.e.org/", "http://x.org/api.php?action=rsd")).?);
    try testing.expect((try apiFromEditUri(a, "https://wiki.e.org/", "api.php")) == null);
}

test "the siteinfo answer gives the article path; the list gives titles and where it goes on" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("/wiki/$1", (try parseArticlePath(a, "{\"query\":{\"general\":{\"articlepath\":\"/wiki/$1\",\"sitename\":\"X\"}}}")).?);
    try testing.expect((try parseArticlePath(a, "{\"query\":{}}")) == null);
    try testing.expect((try parseArticlePath(a, "not json")) == null);
    try testing.expect((try parseArticlePath(a, "{\"query\":{\"general\":{\"articlepath\":\"/no-placeholder\"}}}")) == null);
    const l = try parseList(a, "{\"continue\":{\"apcontinue\":\"Gamma Ray\",\"continue\":\"-||\"},\"query\":{\"allpages\":[{\"pageid\":1,\"ns\":0,\"title\":\"Alpha\"},{\"pageid\":2,\"ns\":0,\"title\":\"Beta Page\"}]}}");
    try testing.expectEqual(@as(usize, 2), l.titles.len);
    try testing.expectEqualStrings("Beta Page", l.titles[1]);
    try testing.expectEqualStrings("Gamma Ray", l.next.?);
    const end = try parseList(a, "{\"batchcomplete\":\"\",\"query\":{\"allpages\":[{\"title\":\"Z\"}]}}");
    try testing.expect(end.next == null and end.titles.len == 1);
    try testing.expectEqual(@as(usize, 0), (try parseList(a, "garbage")).titles.len);
}

test "article addresses and the list call are built the way MediaWiki writes them" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("https://w.org/wiki/Beta_Page", try articleUrl(a, "https://w.org", "/wiki/$1", "Beta Page"));
    try testing.expectEqualStrings("https://w.org/index.php?title=C%2B%2B", try articleUrl(a, "https://w.org", "/index.php?title=$1", "C++"));
    try testing.expectEqualStrings("https://w.org/wiki/Caf%C3%A9_(drink)", try articleUrl(a, "https://w.org", "/wiki/$1", "Café (drink)"));
    try testing.expectEqualStrings("https://w.org/w/api.php?action=query&list=allpages&aplimit=500&apnamespace=0&apfilterredir=nonredirects&format=json", try listUrl(a, "https://w.org/w/api.php", null));
    try testing.expect(std.mem.endsWith(u8, try listUrl(a, "https://w.org/w/api.php", "Gamma Ray"), "&apcontinue=Gamma_Ray"));
}
