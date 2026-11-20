//! Fuzz targets for the code that reads input nobody here wrote: crawled HTML and feeds, robots.txt, addresses, the answers of
//! remote wikis, headers, pictures' metadata, domain lists, query text and configuration. Each target is a test: a normal
//! `zig build test` runs it once on its seed inputs (a smoke test), and `zig build test --fuzz` (or `--fuzz=1M`) searches for
//! inputs that crash it, overflow, read out of bounds, leak or break the property it checks. Debug builds check for overflow
//! and bounds, which is where most of what a fuzzer finds comes from.
//!
//! To add one: write `fn one(_: void, smith: *std.testing.Smith) anyerror!void`, take bytes with `bytes(smith, &buf)`, call the
//! code, check what must be true of the result, and register it with `run(one, &.{seed(...)})`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const htmltext = @import("htmltext.zig");
const feedlinks = @import("connectors/crawl/feedlinks.zig");
const robots = @import("connectors/crawl/robots.zig");
const frontier = @import("connectors/crawl/frontier.zig");
const mediawiki = @import("connectors/crawl/mediawiki.zig");
const langprefer = @import("langprefer.zig");
const wordforms = @import("wordforms.zig");
const queryparse = @import("queryparse.zig");
const evaluate = @import("evaluate.zig");
const exif = @import("exif.zig");
const domainlist = @import("domainlist.zig");
const docmeta = @import("docmeta.zig");
const document = @import("document.zig");
const config = @import("config.zig");

/// The bytes the fuzzer chose, at most `buf.len`.
fn bytes(smith: *testing.Smith, buf: []u8) []u8 {
    return buf[0..smith.slice(buf)];
}

/// A seed input as the fuzzer encodes one (a length, then the bytes).
fn seed(comptime text: []const u8) []const u8 {
    return &(std.mem.toBytes(@as(u32, text.len)) ++ text[0..text.len].*);
}

fn run(comptime one: fn (void, *testing.Smith) anyerror!void, comptime seeds: []const []const u8) !void {
    try testing.fuzz({}, one, .{ .corpus = seeds });
}

// --------------------------------------------------------------------------------------------------- pages and feeds

fn htmlOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const html = bytes(smith, &buf);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    _ = try htmltext.toText(a, html);
    _ = try htmltext.titleOf(a, html);
    const s = try htmltext.scanWith(a, html, 50, 20);
    try testing.expect(s.links.len <= 50 and s.images.len <= 20 and s.feeds.len <= 3);
}

test "fuzz: HTML text, titles and links never crash and stay within their limits" {
    try run(htmlOne, &.{
        seed("<html lang=en><head><title>T &amp; U</title><meta name=robots content=noindex><link rel=alternate type=application/rss+xml href=/f></head><body><a href=\"/a\">a</a><img src=x.png alt=y><script>var x='<a href=z>'</script></body></html>"),
        seed("<a href=\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"><!-- <b> --><p><p><<<>>>&#xFFFFFF;&#0;&nbsp"),
    });
}

fn feedOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const xml = bytes(smith, &buf);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const l = try feedlinks.links(ar.allocator(), testing.allocator, xml, 20);
    try testing.expect(l.len <= 20);
}

test "fuzz: RSS and Atom feeds never crash and give at most the links asked for" {
    try run(feedOne, &.{
        seed("<rss><channel><item><link>https://e.org/1</link></item></channel></rss>"),
        seed("<feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><link rel=\"alternate\" href=\"https://e.org/a\"/></entry></feed>"),
    });
}

fn robotsOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [3072]u8 = undefined;
    const text = bytes(smith, &buf);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const rules = try robots.parse(ar.allocator(), text, "dksearch");
    _ = rules.allowed("/");
    _ = rules.allowed("/a/b?c=1&d=2");
    _ = rules.allowed("");
    try testing.expect(rules.sitemaps.len <= 8);
}

test "fuzz: robots.txt never crashes the parser or the matcher" {
    try run(robotsOne, &.{
        seed("User-agent: *\nDisallow: /private/\nAllow: /private/ok$\nCrawl-delay: 2\nSitemap: https://e.org/s.xml\n"),
        seed("User-agent: dksearch\nDisallow: /*?*sid=\nDisallow: /a*b*c$\n"),
    });
}

// --------------------------------------------------------------------------------------------------- addresses

fn tidyOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const url = bytes(smith, &buf);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const t = try frontier.tidy(a, url);
    _ = frontier.isTrap(t);
    _ = frontier.score(t);
    // Tidying an address that is already tidy changes nothing: otherwise one page could be asked for under two addresses.
    const again = try frontier.tidy(a, t);
    try testing.expectEqualStrings(t, again);
}

test "fuzz: tidying an address is idempotent, and trap and priority checks never crash" {
    try run(tidyOne, &.{
        seed("HTTPS://Example.ORG:443/a//b/./c/../d?utm_source=x&b=2&a=1#frag"),
        seed("http://e.org/a;jsessionid=1/b?PHPSESSID=2&x=1"),
        seed("https://e.org/../../x"),
    });
}

fn docmetaOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const url = bytes(smith, &buf);
    const d = docmeta.derive(.{ .connector = "c", .source_id = "s", .canonical_url = url });
    if (d.path) |p| try testing.expect(std.mem.indexOf(u8, url, p) != null);
}

test "fuzz: the host, path and extension taken from an address never crash" {
    try run(docmetaOne, &.{ seed("https://user:pw@Host.Example:8080/a/b.tar.gz?x=1#y"), seed("file:///home/me/a b.txt"), seed("//[::1]:80/x") });
}

fn domainOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const text = bytes(smith, &buf);
    _ = domainlist.entryOf(text);
    _ = domainlist.firstBadLine(text);
    var hb: [253]u8 = undefined;
    if (domainlist.hostOf(&hb, text)) |h| try testing.expect(h.len <= 253);
    _ = domainlist.hiddenNetworkOf(text);
}

test "fuzz: lines of a domain list and the host of an address never crash" {
    try run(domainOne, &.{ seed("0.0.0.0 ads.example.org"), seed("||tracker.example.com^"), seed("http://a.onion/x") });
}

// --------------------------------------------------------------------------------------------------- answers of remote servers

fn wikiOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const body = bytes(smith, &buf);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const l = try mediawiki.parseList(a, body);
    for (l.titles) |t| try testing.expect(t.len > 0 and t.len <= 300);
    _ = try mediawiki.parseArticlePath(a, body);
    _ = try mediawiki.apiFromEditUri(a, "https://wiki.example.org/wiki/Main_Page", body);
    _ = try mediawiki.apiFromEditUri(a, body, "//wiki.example.org/w/api.php?action=rsd");
}

test "fuzz: the answers of a wiki's API never crash and keep their limits" {
    try run(wikiOne, &.{
        seed("{\"continue\":{\"apcontinue\":\"X\"},\"query\":{\"allpages\":[{\"title\":\"A\"},{\"title\":\"B C\"}]}}"),
        seed("{\"query\":{\"general\":{\"articlepath\":\"/wiki/$1\"}}}"),
    });
}

// --------------------------------------------------------------------------------------------------- what people type

fn languageOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const header = bytes(smith, &buf);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const langs = try langprefer.parseAcceptLanguage(a, header);
    try testing.expect(langs.len <= langprefer.max_preferred);
    for (langs) |l| {
        try testing.expect(l.len >= 2 and l.len <= 3);
        for (l) |ch| try testing.expect(std.ascii.isLower(ch));
    }
    if (try langprefer.csv(a, langs)) |list| _ = langprefer.foreign(header, header, list);
    // The stem of a word is the beginning of the word, in lower case, and long enough to be worth asking for.
    var sb: [wordforms.max_word]u8 = undefined;
    if (wordforms.stemPrefix(&sb, header)) |stem| {
        try testing.expect(stem.len >= wordforms.min_stem and stem.len <= header.len);
        try testing.expect(std.ascii.startsWithIgnoreCase(header, stem));
        _ = wordforms.isForm(stem, header);
    }
}

test "fuzz: Accept-Language, language checks and word stems never crash and keep their promises" {
    try run(languageOne, &.{ seed("en-US,en;q=0.9,fr;q=0.5,*;q=0.1"), seed("programming"), seed("x;q=,,,;;") });
}

fn queryOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const text = bytes(smith, &buf);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const variants = [_]queryparse.Options{ .{}, .{ .fuzzy_words = true } };
    for (variants) |opts| {
        const p = queryparse.parseWith(a, text, opts) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => continue, // an empty or invalid query is refused, which is allowed
        };
        // Whatever the person typed, what goes to the index is quoted properly: an even number of quotes.
        var quotes: usize = 0;
        for (p.fts) |ch| quotes += @intFromBool(ch == '"');
        try testing.expect(quotes % 2 == 0);
    }
}

test "fuzz: query text is parsed or refused, and what goes to the index is always quoted properly" {
    try run(queryOne, &.{ seed("title:linux \"scheduler design\"~3 -android OR (bsd AND ext:pdf)"), seed("how to program in c"), seed("a~ b* \"unclosed (((") });
}

fn judgmentsOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const text = bytes(smith, &buf);
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    var diag: evaluate.Diagnostic = .{};
    const j = evaluate.parseJudgments(ar.allocator(), text, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BadJudgments => return,
    };
    for (j) |x| try testing.expect(x.query.len > 0 and (x.relevant.len > 0 or x.irrelevant.len > 0));
}

test "fuzz: judgments and feedback lines are parsed or refused with a line number, never a crash" {
    try run(judgmentsOne, &.{
        seed("{\"query\":\"q\",\"relevant\":[\"u\"],\"irrelevant\":[\"v\"]}\n{\"query\":\"q\",\"url\":\"w\",\"grade\":-1,\"time\":1}\n"),
        seed("# c\n\n{\"query\":\"a\",\"relevant\":{\"u\":3}}"),
    });
}

// --------------------------------------------------------------------------------------------------- files

fn exifOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    _ = exif.read(bytes(smith, &buf));
}

test "fuzz: the metadata of a picture never crashes the reader" {
    try run(exifOne, &.{ seed("\xff\xd8\xff\xe1\x00\x10Exif\x00\x00II*\x00\x08\x00\x00\x00\x00\x00"), seed("\xff\xd8\xff\xd9") });
}

fn configOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    const text = bytes(smith, &buf);
    var diag: config.Diagnostic = .{};
    var c = config.loadFromSlice(testing.allocator, "fuzz.toml", text, &diag) catch return;
    c.deinit();
}

test "fuzz: a configuration file is accepted or refused, and nothing leaks either way" {
    try run(configOne, &.{
        seed("[storage]\ndata_dir = \"/tmp/x\"\n[search]\nper_domain = 3\ntitle_weight = 100\n"),
        seed("[storage]\ndata_dir = \"/tmp/x\"\n[[source]]\nname = \"a\"\nkind = \"crawl\"\nseeds_file = \"/s.txt\"\nuser_agent = \"t/1 (+https://e.org)\"\n"),
        seed("[storage\ndata_dir = = \"\n"),
    });
}
