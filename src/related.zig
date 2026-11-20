//! Related searches (docs/decisions/0073): refinements of a search, taken from the results themselves. dksearch keeps no
//! history of what people searched for, so what other people searched for cannot be offered; what can is the words that recur
//! in the titles of the results ("kernel", "distribution" for `linux`), which narrow the search in directions the results
//! already show. Only words that appear in the titles of at least two results on at least two sites are offered, so that one
//! site's habit of putting its name in every title is not taken for a topic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const search = @import("search.zig");
const queryparse = @import("queryparse.zig");

pub const max_words = 6;

/// Words of titles that say nothing about what a page is about.
const dull = [_][]const u8{
    "documentation", "docs",     "wiki",    "home",         "homepage",  "page",      "pages",    "index",    "official",  "website",  "site",      "guide",     "manual",
    "wikipedia",     "github",   "free",    "best",         "using",     "with",      "from",     "this",     "that",      "your",     "what",      "about",     "into",
    "over",          "after",    "before",  "more",         "most",      "also",      "have",     "been",     "will",      "would",    "could",     "should",    "their",
    "there",         "where",    "which",   "while",        "these",     "those",     "other",    "than",     "then",      "them",     "they",      "were",      "when",
    "only",          "some",     "such",    "like",         "just",      "very",      "much",     "many",     "make",      "made",     "does",      "list",      "lists",
    "news",          "blog",     "online",  "introduction", "overview",  "getting",   "started",  "learn",    "learning",  "tutorial", "tutorials", "reference", "main",
    "project",       "projects", "open",    "source",       "community", "forum",     "support",  "download", "downloads", "latest",   "version",   "release",   "releases",
    "update",        "updates",  "welcome", "contents",     "table",     "section",   "chapter",  "article",  "articles",  "topics",   "topic",     "tagged",    "category",
    "categories",    "search",   "results", "stack",        "exchange",  "questions", "question", "answers",  "answer",    "review",   "reviews",   "software",  "program",
    "programs",
};

fn isDull(w: []const u8) bool {
    for (dull) |d| if (std.mem.eql(u8, d, w)) return true;
    return queryparse.isFiller(w);
}

/// The words of `text` worth considering, lower case (ASCII letters lowered; other letters as they are): four to twenty-four
/// letters or digits, not all digits.
fn nextWord(text: []const u8, pos: *usize, buf: *[24]u8) ?[]const u8 {
    var i = pos.*;
    while (i < text.len) {
        while (i < text.len and !(std.ascii.isAlphanumeric(text[i]) or text[i] >= 0x80)) i += 1;
        const start = i;
        var n: usize = 0;
        var digits_only = true;
        while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] >= 0x80)) : (i += 1) {
            if (n < buf.len) buf[n] = std.ascii.toLower(text[i]);
            n += 1;
            if (!std.ascii.isDigit(text[i])) digits_only = false;
        }
        if (i == start) break;
        if (n >= 4 and n <= buf.len and !digits_only) {
            pos.* = i;
            return buf[0..n];
        }
    }
    pos.* = text.len;
    return null;
}

/// Whether a word is one of the query's, or a form of one (the same first five letters: "program" and "programming").
fn inQuery(query_words: []const []const u8, w: []const u8) bool {
    for (query_words) |q| {
        if (std.mem.eql(u8, q, w)) return true;
        const n = @min(@min(q.len, w.len), 5);
        if (n >= 4 and std.mem.eql(u8, q[0..n], w[0..n])) return true;
    }
    return false;
}

const Entry = struct { word: []const u8, results: u32 = 0, sites: u32 = 0, last_site: ?[]const u8 = null, seen_in: usize = std.math.maxInt(usize) };

/// Up to `max_words` words that recur in the titles of `hits`, best first. `query_words` are the words of the search, lower case.
pub fn words(arena: Allocator, query_words: []const []const u8, hits: []const search.Hit) Allocator.Error![]const []const u8 {
    if (hits.len < 5) return &.{};
    var map: std.StringHashMapUnmanaged(usize) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    var sites: std.StringHashMapUnmanaged(void) = .empty;
    for (hits, 0..) |h, hi| {
        const title = h.title orelse continue;
        const site = h.domain orelse (h.url orelse "");
        var pos: usize = 0;
        var buf: [24]u8 = undefined;
        while (nextWord(title, &pos, &buf)) |w| {
            if (isDull(w) or inQuery(query_words, w)) continue;
            const key = try arena.dupe(u8, w);
            const gop = try map.getOrPut(arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = entries.items.len;
                try entries.append(arena, .{ .word = key });
            }
            const e = &entries.items[gop.value_ptr.*];
            if (e.seen_in == hi) continue; // once for each result
            e.seen_in = hi;
            e.results += 1;
            if (e.last_site == null or !std.mem.eql(u8, e.last_site.?, site)) {
                // Counted once for each site (hits of one site are not always together, so this errs towards counting more).
                const sk = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ e.word, site });
                const sg = try sites.getOrPut(arena, sk);
                if (!sg.found_existing) e.sites += 1;
                e.last_site = site;
            }
        }
    }
    // Words in at least two results on two sites, and not in most of the results (those are the topic of the whole search).
    var kept: std.ArrayList(Entry) = .empty;
    for (entries.items) |e| {
        if (e.results < 2 or e.sites < 2) continue;
        if (e.results * 10 >= hits.len * 7) continue;
        try kept.append(arena, e);
    }
    std.mem.sort(Entry, kept.items, {}, struct {
        fn better(_: void, a: Entry, b: Entry) bool {
            if (a.results != b.results) return a.results > b.results;
            if (a.sites != b.sites) return a.sites > b.sites;
            return std.mem.lessThan(u8, a.word, b.word);
        }
    }.better);
    const n = @min(kept.items.len, max_words);
    const out = try arena.alloc([]const u8, n);
    for (kept.items[0..n], out) |e, *o| o.* = e.word;
    return out;
}

const testing = std.testing;

fn hit(title: []const u8, domain: []const u8) search.Hit {
    return .{ .id = @splat(0), .connector = "t", .url = null, .title = title, .snippet = null, .score = 1, .domain = domain };
}

test "words that recur in the titles on several sites are offered; the query's own, dull and one-site words are not" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const hits = [_]search.Hit{
        hit("Linux kernel documentation", "kernel.org"),
        hit("Linux kernel scheduler design", "lwn.net"),
        hit("Choosing a Linux distribution", "distrowatch.com"),
        hit("The best Linux distribution for servers", "example.org"),
        hit("Linux server administration guide", "docs.example.org"),
        hit("MyWiki: Linux notes, Linux notes", "mywiki.example.net"),
        hit("MyWiki: Linux setup", "mywiki.example.net"),
        hit("Linux", "wikipedia.org"),
    };
    const w = try words(a, &.{"linux"}, &hits);
    try testing.expect(w.len >= 2);
    try testing.expectEqualStrings("kernel", w[0]); // two results, two sites
    var has_distribution = false;
    for (w) |x| {
        try testing.expect(!std.mem.eql(u8, x, "linux") and !std.mem.eql(u8, x, "guide") and !std.mem.eql(u8, x, "documentation"));
        try testing.expect(!std.mem.eql(u8, x, "mywiki")); // two results but one site
        if (std.mem.eql(u8, x, "distribution")) has_distribution = true;
    }
    try testing.expect(has_distribution);
    // Forms of a query word are not offered back ("program" for "programming"), and a short result list offers nothing.
    const few = [_]search.Hit{ hit("Programming in C", "a.org"), hit("Programming languages", "b.org"), hit("C programming basics", "c.org") };
    try testing.expectEqual(@as(usize, 0), (try words(a, &.{"program"}, &few)).len);
    const forms = [_]search.Hit{ hit("Programming basics", "a.org"), hit("Programming tools", "b.org"), hit("Programming basics", "c.org"), hit("Programming tools", "d.org"), hit("Programming", "e.org") };
    for (try words(a, &.{"program"}, &forms)) |x| try testing.expect(!std.mem.startsWith(u8, x, "progr"));
    // A word in most of the titles is the topic of the whole search, not a refinement of it.
    const all = [_]search.Hit{ hit("Gadget manual repairs", "a.org"), hit("Gadget repairs", "b.org"), hit("Gadget repairs fast", "c.org"), hit("Gadget repairs shop", "d.org"), hit("Gadget repairs near", "e.org") };
    for (try words(a, &.{"gadget"}, &all)) |x| try testing.expect(!std.mem.eql(u8, x, "repairs"));
}
