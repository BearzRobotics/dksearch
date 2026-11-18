//! HTML to plain text, for search (feed entries and fetched web pages).
//!
//! Tags are dropped, block-level tags (paragraphs, line breaks, list items,
//! headings, table rows) become line breaks, `<script>` and `<style>` content
//! is removed with the tags, comments are removed, and the common entities
//! and numeric character references are decoded. It is not an HTML parser
//! and never fails on malformed markup: whatever it cannot make sense of is
//! kept as text. Linear time; only ASCII structure is touched, so UTF-8
//! input stays valid UTF-8.

const std = @import("std");
const Allocator = std.mem.Allocator;

const block_tags = [_][]const u8{
    "p",  "br", "div", "li",    "ul",         "ol",  "h1", "h2",      "h3",      "h4",     "h5",     "h6",
    "tr", "td", "th",  "table", "blockquote", "pre", "hr", "section", "article", "header", "footer",
};
const dropped_tags = [_][]const u8{ "script", "style", "head", "noscript" };

pub fn toText(arena: Allocator, html: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var budget: Budget = .{};
    // A dropped tag whose end tag is missing is searched for only once: after
    // that it is just a tag. This keeps unclosed `<script>` soup linear.
    var missing_end: [dropped_tags.len]bool = @splat(false);
    var i: usize = 0;
    while (i < html.len) {
        const ch = html[i];
        if (ch == '<') {
            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                const end = std.mem.indexOfPos(u8, html, i + 4, "-->");
                i = if (end) |e| e + 3 else html.len;
                continue;
            }
            if (declarationEnd(html, i)) |e| {
                i = e;
                continue;
            }
            if (tagAt(html, i, &budget)) |t| {
                if (!t.closing and !t.self_closing) {
                    if (indexOf(t.name, &dropped_tags)) |k| {
                        if (!missing_end[k]) {
                            if (endOf(html, t.end, t.name)) |e| {
                                i = e;
                                continue;
                            }
                            missing_end[k] = true;
                        }
                        i = t.end;
                        continue;
                    }
                }
                if (isOneOf(t.name, &block_tags)) try out.append(arena, '\n');
                i = t.end;
                continue;
            }
        } else if (ch == '&') {
            if (try entity(arena, &out, html, &i)) continue;
        }
        try out.append(arena, ch);
        i += 1;
    }
    return tidy(arena, out.items);
}

/// The index just after a markup declaration or processing instruction that starts at `i`
/// (`<!DOCTYPE html>`, `<?xml version="1.0"?>`), or null if there is none. They hold no text.
fn declarationEnd(s: []const u8, i: usize) ?usize {
    if (i + 1 >= s.len) return null;
    if (s[i + 1] != '!' and s[i + 1] != '?') return null;
    const limit = @min(s.len, i + 4096);
    const gt = std.mem.indexOfScalarPos(u8, s[0..limit], i + 2, '>') orelse return null;
    return gt + 1;
}

const Tag = struct { name: []const u8, closing: bool, self_closing: bool, end: usize };

/// Longest tag looked at, in bytes (attribute values such as embedded JSON can be long).
const max_tag_bytes = 8192;
/// After this many tags whose quotes did not close, quotes are no longer taken into account in the rest of a page
/// (each such tag costs a scan to `max_tag_bytes`, so hostile input could otherwise make the work quadratic).
const max_quote_failures = 64;

const Budget = struct { failures: u32 = 0 };

/// A tag starting at `i` (the `<`), if it looks like one. The tag ends at the first `>` that is not inside a quoted
/// attribute value, as in a browser, so `<span data-x='{"a":"<b>"}'>` is one tag; if a quote never closes the first
/// `>` ends it.
fn tagAt(s: []const u8, i: usize, budget: *Budget) ?Tag {
    const limit = @min(s.len, i + max_tag_bytes);
    var j = i + 1;
    const closing = j < limit and s[j] == '/';
    if (closing) j += 1;
    const start = j;
    while (j < limit and std.ascii.isAlphanumeric(s[j])) j += 1;
    if (j == start) return null; // "a < b" or "<>" is text
    const name_end = j;
    var gt: ?usize = null;
    if (budget.failures < max_quote_failures) {
        var quote: u8 = 0;
        var last: u8 = 0; // the last character that is not white space, outside quotes
        var k = name_end;
        while (k < limit) : (k += 1) {
            const c = s[k];
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            if ((c == '"' or c == '\'') and last == '=') {
                quote = c;
            } else if (c == '>') {
                gt = k;
                break;
            }
            if (!std.ascii.isWhitespace(c)) last = c;
        }
        if (gt == null) budget.failures += 1;
    }
    const end = gt orelse (std.mem.indexOfScalarPos(u8, s[0..limit], i + 1, '>') orelse return null);
    return .{ .name = s[start..name_end], .closing = closing, .self_closing = s[end - 1] == '/', .end = end + 1 };
}

fn indexOf(name: []const u8, list: []const []const u8) ?usize {
    for (list, 0..) |n, k| if (std.ascii.eqlIgnoreCase(name, n)) return k;
    return null;
}

fn isOneOf(name: []const u8, list: []const []const u8) bool {
    return indexOf(name, list) != null;
}

/// Index just after `</name>`, searching from `from`.
fn endOf(s: []const u8, from: usize, name: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, s, i, '<')) |lt| {
        if (lt + 2 + name.len <= s.len and s[lt + 1] == '/' and std.ascii.eqlIgnoreCase(s[lt + 2 .. lt + 2 + name.len], name)) {
            const gt = std.mem.indexOfScalarPos(u8, s, lt, '>') orelse return null;
            return gt + 1;
        }
        i = lt + 1;
    }
    return null;
}

fn entity(arena: Allocator, out: *std.ArrayList(u8), s: []const u8, i: *usize) Allocator.Error!bool {
    const start = i.*;
    const semi = std.mem.indexOfScalarPos(u8, s[0..@min(s.len, start + 12)], start + 1, ';') orelse return false;
    const name = s[start + 1 .. semi];
    const named = [_]struct { []const u8, []const u8 }{
        .{ "nbsp", " " },          .{ "amp", "&" },          .{ "lt", "<" },           .{ "gt", ">" },
        .{ "quot", "\"" },         .{ "apos", "'" },         .{ "ndash", "\u{2013}" }, .{ "mdash", "\u{2014}" },
        .{ "hellip", "\u{2026}" }, .{ "rsquo", "\u{2019}" }, .{ "lsquo", "\u{2018}" }, .{ "rdquo", "\u{201d}" },
        .{ "ldquo", "\u{201c}" },  .{ "copy", "\u{a9}" },    .{ "times", "\u{d7}" },   .{ "deg", "\u{b0}" },
    };
    for (named) |n| if (std.mem.eql(u8, name, n[0])) {
        try out.appendSlice(arena, n[1]);
        i.* = semi + 1;
        return true;
    };
    if (name.len >= 2 and name[0] == '#') {
        const cp = (if (name[1] == 'x' or name[1] == 'X')
            std.fmt.parseInt(u21, name[2..], 16)
        else
            std.fmt.parseInt(u21, name[1..], 10)) catch return false;
        if (cp == 0 or !std.unicode.utf8ValidCodepoint(cp)) return false;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return false;
        try out.appendSlice(arena, buf[0..n]);
        i.* = semi + 1;
        return true;
    }
    return false;
}

/// Trims lines, collapses runs of spaces and of blank lines.
fn tidy(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var blank_run: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) {
            blank_run += 1;
            continue;
        }
        if (out.items.len > 0) try out.appendSlice(arena, if (blank_run > 1) "\n\n" else "\n");
        blank_run = 0;
        var prev_space = false;
        for (line) |c| {
            const sp = c == ' ' or c == '\t';
            if (sp and prev_space) continue;
            try out.append(arena, if (sp) ' ' else c);
            prev_space = sp;
        }
    }
    return out.items;
}

/// The text of the first `<title>` element, or null if there is none or it is
/// empty. Case-insensitive; the content goes through the same entity decoding
/// and tidying as `toText`.
pub fn titleOf(arena: Allocator, html: []const u8) Allocator.Error!?[]const u8 {
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(html, from, "<title")) |open| {
        const after = open + "<title".len;
        // "<title" must end the tag name: "<titlefoo>" is another element.
        if (after < html.len and html[after] != '>' and !std.ascii.isWhitespace(html[after])) {
            from = after;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, html, after, '>') orelse return null;
        const close = std.ascii.findIgnoreCasePos(html, gt + 1, "</title") orelse return null;
        const t = try toText(arena, html[gt + 1 .. close]);
        const one_line = try collapseLines(arena, t);
        return if (one_line.len == 0) null else one_line;
    }
    return null;
}

fn collapseLines(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending = false;
    for (s) |ch| {
        if (ch == '\n' or ch == '\r' or ch == '\t' or ch == ' ') {
            pending = out.items.len > 0;
            continue;
        }
        if (pending) try out.append(arena, ' ');
        pending = false;
        try out.append(arena, ch);
    }
    return out.items;
}

/// What a page says about itself for crawlers, and where it links.
pub const Scan = struct {
    /// `<meta name="robots" content="noindex">` (or "none"): do not index.
    noindex: bool = false,
    /// `<meta name="robots" content="nofollow">` (or "none"): follow nothing.
    nofollow: bool = false,
    /// `href` of `<a>` and `<area>` elements, entities decoded, in page order.
    /// Links marked `rel="nofollow"` are left out. Empty if the page is nofollow.
    links: []const []const u8 = &.{},
    /// Pictures of the page (`<img>` and the `og:image` of the page), when asked for (`scanWith`).
    images: []const PageImage = &.{},
};

/// A picture of a page: where it is (as written in the page: it may be relative), what the page says it shows.
pub const PageImage = struct { src: []const u8, alt: []const u8, title: []const u8 };

/// The smallest side (pixels, when the page says it) that makes a picture worth recording: icons and tracking pixels are not.
pub const min_image_side: u32 = 100;

/// One pass over `html`: robots meta directives and up to `max_links` links.
/// Like `toText` it is linear, ignores comments, `<script>` and `<style>`, and
/// never fails on malformed markup.
pub fn scan(arena: Allocator, html: []const u8, max_links: usize) Allocator.Error!Scan {
    return scanWith(arena, html, max_links, 0);
}

/// Like `scan`, and also up to `max_images` pictures: `<img>` with a `src` (or a lazy-loading `data-src`) that is not an inline
/// `data:` address and is not marked smaller than `min_image_side`, and the page's `og:image`.
pub fn scanWith(arena: Allocator, html: []const u8, max_links: usize, max_images: usize) Allocator.Error!Scan {
    var out: Scan = .{};
    var links: std.ArrayList([]const u8) = .empty;
    var images: std.ArrayList(PageImage) = .empty;
    var missing_end: [dropped_tags.len]bool = @splat(false);
    var budget: Budget = .{};
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        i = lt;
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i + 4, "-->");
            i = if (end) |e| e + 3 else html.len;
            continue;
        }
        if (declarationEnd(html, i)) |e| {
            i = e;
            continue;
        }
        const t = tagAt(html, i, &budget) orelse {
            i += 1;
            continue;
        };
        i = t.end;
        if (t.closing) continue;
        if (indexOf(t.name, &dropped_tags)) |k| {
            // Skip the content of script, style, noscript and head; but "head"
            // holds the meta tags we want, so only the other three are skipped.
            if (std.ascii.eqlIgnoreCase(t.name, "head")) continue;
            if (!t.self_closing and !missing_end[k]) {
                if (endOf(html, t.end, t.name)) |e| {
                    i = e;
                } else missing_end[k] = true;
            }
            continue;
        }
        const body = html[lt..t.end];
        if (max_images > 0 and images.items.len < max_images and std.ascii.eqlIgnoreCase(t.name, "img")) {
            const raw = attr(body, "src") orelse (attr(body, "data-src") orelse continue);
            const src = std.mem.trim(u8, raw, " \t\r\n");
            if (src.len == 0 or src.len > 2000 or std.ascii.startsWithIgnoreCase(src, "data:") or std.ascii.startsWithIgnoreCase(src, "javascript:")) continue;
            if (attr(body, "width")) |w| if (std.fmt.parseInt(u32, std.mem.trim(u8, w, " px"), 10)) |n| {
                if (n < min_image_side) continue;
            } else |_| {};
            if (attr(body, "height")) |h| if (std.fmt.parseInt(u32, std.mem.trim(u8, h, " px"), 10)) |n| {
                if (n < min_image_side) continue;
            } else |_| {};
            try images.append(arena, .{
                .src = try decodeEntities(arena, src),
                .alt = try decodeEntities(arena, std.mem.trim(u8, attr(body, "alt") orelse "", " \t\r\n")),
                .title = try decodeEntities(arena, std.mem.trim(u8, attr(body, "title") orelse "", " \t\r\n")),
            });
            continue;
        }
        if (max_images > 0 and images.items.len < max_images and std.ascii.eqlIgnoreCase(t.name, "meta")) {
            if (attr(body, "property")) |prop| if (std.ascii.eqlIgnoreCase(prop, "og:image")) {
                if (attr(body, "content")) |c| {
                    const src = std.mem.trim(u8, c, " \t\r\n");
                    if (src.len > 0 and src.len <= 2000 and !std.ascii.startsWithIgnoreCase(src, "data:")) try images.append(arena, .{ .src = try decodeEntities(arena, src), .alt = "", .title = "" });
                }
                continue;
            };
        }
        if (std.ascii.eqlIgnoreCase(t.name, "meta")) {
            const name = attr(body, "name") orelse continue;
            if (!std.ascii.eqlIgnoreCase(name, "robots") and !std.ascii.eqlIgnoreCase(name, "dksearch")) continue;
            const content = attr(body, "content") orelse continue;
            if (hasToken(content, "noindex") or hasToken(content, "none")) out.noindex = true;
            if (hasToken(content, "nofollow") or hasToken(content, "none")) out.nofollow = true;
        } else if ((std.ascii.eqlIgnoreCase(t.name, "a") or std.ascii.eqlIgnoreCase(t.name, "area")) and links.items.len < max_links) {
            const href = attr(body, "href") orelse continue;
            if (attr(body, "rel")) |rel| if (hasToken(rel, "nofollow")) continue;
            const trimmed = std.mem.trim(u8, href, " \t\r\n");
            if (trimmed.len == 0) continue;
            try links.append(arena, try decodeEntities(arena, trimmed));
        }
    }
    if (!out.nofollow) out.links = links.items;
    out.images = images.items;
    return out;
}

/// The value of attribute `name` inside the text of one tag (`<a href="x">`),
/// quoted or bare, matched case-insensitively. Null if absent.
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 1; // past '<'
    while (i < tag.len and !std.ascii.isWhitespace(tag[i])) i += 1; // tag name
    while (i < tag.len) {
        while (i < tag.len and (std.ascii.isWhitespace(tag[i]) or tag[i] == '/')) i += 1;
        const ns = i;
        while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '=' and tag[i] != '>' and tag[i] != '/') i += 1;
        const an = tag[ns..i];
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        var value: []const u8 = "";
        if (i < tag.len and tag[i] == '=') {
            i += 1;
            while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
            if (i < tag.len and (tag[i] == '"' or tag[i] == '\'')) {
                const q = tag[i];
                const vs = i + 1;
                const ve = std.mem.indexOfScalarPos(u8, tag, vs, q) orelse return null;
                value = tag[vs..ve];
                i = ve + 1;
            } else {
                const vs = i;
                while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '>') i += 1;
                value = tag[vs..i];
            }
        }
        if (an.len > 0 and std.ascii.eqlIgnoreCase(an, name)) return value;
        if (an.len == 0) i += 1; // never stall on odd bytes
    }
    return null;
}

/// Whether `list` (separated by spaces or commas) has `token`, ignoring case.
fn hasToken(list: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n,");
    while (it.next()) |w| if (std.ascii.eqlIgnoreCase(w, token)) return true;
    return false;
}

fn decodeEntities(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') if (try entity(arena, &out, s, &i)) continue;
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectText(html: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(want, try toText(arena.allocator(), html));
}

test "paragraphs and breaks become lines; inline tags vanish" {
    try expectText("<p>First <b>bold</b> and <a href=\"x\">link</a>.</p><p>Second.</p>", "First bold and link.\nSecond.");
    try expectText("a<br>b<br/>c", "a\nb\nc");
    try expectText("<ul><li>one</li><li>two</li></ul>", "one\ntwo");
    try expectText("<h1>Title</h1>body", "Title\nbody");
}

test "a > inside a quoted attribute value does not end the tag (embedded JSON, inline SVG)" {
    try expectText("a<span data-mw='{\"parts\":[\"<span class=x>hidden</span>\"]}'>shown</span>b", "ashownb");
    try expectText("a<div data-icon=\"<svg><path d='M1 2'/></svg>\">kept</div>b", "a\nkept\nb");
    // A quote that never closes: the first > ends the tag, as before.
    try expectText("a<span title=\"oops>text</span>b", "atext" ++ "b");
    // Unquoted and spaced values, and a stray quote that is not a value.
    try expectText("a<p class = \"c\" id=x>t</p>", "a\nt");
    try expectText("a<b \"quoted\" word>x</b>", "ax");
}

test "script, style and comments are removed with their content" {
    try expectText("a<script>alert('x')</script>b<style>p{}</style>c<!-- hidden -->d", "abcd");
    try expectText("a<script>never closed", "anever closed"); // the stray tag goes, the text stays
}

test "a doctype and processing instructions are markup, not text" {
    try expectText("<!DOCTYPE html>\n<html><body><p>hi</p></body></html>", "hi");
    try expectText("<!doctype HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" \"http://www.w3.org/TR/html4/strict.dtd\"><p>x</p>", "x");
    try expectText("<?xml version=\"1.0\" encoding=\"UTF-8\"?><p>x</p>", "x");
    try expectText("a <! b", "a <! b"); // never closed: stays text
    try expectText("1 <3 you", "1 <3 you");
}

test "entities and character references" {
    try expectText("5&nbsp;km &amp; &lt;b&gt; &quot;q&quot; &#8212; &#x41; &copy;", "5 km & <b> \"q\" \u{2014} A \u{a9}");
    try expectText("not &an entity; &#0; &#xD800; &", "not &an entity; &#0; &#xD800; &");
}

test "malformed markup is kept as text, never an error" {
    try expectText("a < b and c > d", "a < b and c > d");
    try expectText("<unclosed text", "<unclosed text");
    try expectText("<>x<<p>y", "<>x<\ny");
    try expectText("", "");
}

test "unicode survives; whitespace is tidied" {
    try expectText("  <p>Café  \u{4e2d}\u{6587}</p>\n\n\n<p> x </p>", "Café \u{4e2d}\u{6587}\n\nx"); // a blank line stays a paragraph break
}

test "random tag soup: no crash, valid UTF-8" {
    var prng = std.Random.DefaultPrng.init(0x4817);
    const rnd = prng.random();
    const pieces = [_][]const u8{ "<", ">", "</", "/>", "<p>", "</p>", "<br>", "<script>", "</script>", "<!--", "-->", "&", ";", "&amp;", "&#65;", "&#xZZ;", "caf\xc3\xa9", " ", "\n", "a", "<a href=\"", "\">", "<style>" };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for (0..4000) |_| {
        _ = arena_state.reset(.retain_capacity);
        var src: std.ArrayList(u8) = .empty;
        for (0..rnd.uintLessThan(usize, 50)) |_| src.appendSlice(arena_state.allocator(), pieces[rnd.uintLessThan(usize, pieces.len)]) catch unreachable;
        const out = try toText(arena_state.allocator(), src.items);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        try testing.expect(out.len <= src.items.len + 4);
    }
}

test "many unclosed script tags stay linear" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    for (0..60_000) |_| try src.appendSlice(a, "<script>x");
    const out = try toText(a, src.items);
    try testing.expect(out.len <= src.items.len);
}

test "titleOf finds the first title, decodes it and ignores lookalikes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Tom & Jerry", (try titleOf(a, "<html><head><TITLE lang=en>\n Tom &amp;\n Jerry </TITLE></head>")).?);
    try testing.expectEqualStrings("Real", (try titleOf(a, "<titlefoo>no</titlefoo><title>Real</title>")).?);
    try testing.expect((try titleOf(a, "<p>none</p>")) == null);
    try testing.expect((try titleOf(a, "<title>   </title>")) == null);
    try testing.expect((try titleOf(a, "<title>never closed")) == null);
}

test "scan finds links, robots directives and respects nofollow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html =
        \\<html><head><META NAME="Robots" CONTENT="noindex, follow"><script>var s = "<a href='/no'>";</script></head>
        \\<body><a href="/one">1</a> <A HREF='two?x=1&amp;y=2' class=c>2</A>
        \\<a href=bare>3</a><a rel="nofollow noopener" href="/skip">4</a><a>5</a><a href="">6</a>
        \\<!-- <a href="/commented"> --><area href="/map"/></body></html>
    ;
    const r = try scan(a, html, 100);
    try testing.expect(r.noindex);
    try testing.expect(!r.nofollow);
    try testing.expectEqual(@as(usize, 4), r.links.len);
    try testing.expectEqualStrings("/one", r.links[0]);
    try testing.expectEqualStrings("two?x=1&y=2", r.links[1]);
    try testing.expectEqualStrings("bare", r.links[2]);
    try testing.expectEqualStrings("/map", r.links[3]);

    const nf = try scan(a, "<meta name=robots content=nofollow><a href=/x>x</a>", 100);
    try testing.expect(nf.nofollow and nf.links.len == 0 and !nf.noindex);
    const none = try scan(a, "<meta name=\"robots\" content=\"none\">", 100);
    try testing.expect(none.noindex and none.nofollow);
    const capped = try scan(a, "<a href=1><a href=2><a href=3>", 2);
    try testing.expectEqual(@as(usize, 2), capped.links.len);
}

test "scan never fails on junk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(11);
    var buf: [300]u8 = undefined;
    for (0..500) |_| {
        for (&buf) |*b| b.* = "<>a href=\"'=/ &;!-meta robots\n"[prng.random().uintLessThan(usize, 30)];
        _ = try scan(arena.allocator(), &buf, 50);
    }
}

test "pictures of a page: img and og:image, relative addresses kept as written, icons and inline data left out" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const html =
        \\<html><head><meta property="og:image" content="https://cdn.example/cover.jpg"><title>Gallery</title></head><body>
        \\<img src="/pics/blue-sky.jpg" alt="Blue &amp; sky" title="A sky" width="1200" height="800">
        \\<img src="icon.png" width="16" height="16" alt="icon">
        \\<img src="data:image/png;base64,AAAA" alt="inline">
        \\<img data-src="lazy.webp" alt="Lazy one">
        \\<img alt="no source">
        \\<img src="tracker.gif" width="1" height="1">
        \\</body></html>
    ;
    const s = try scanWith(a, html, 10, 10);
    try testing.expectEqual(@as(usize, 3), s.images.len); // og:image, the sky, the lazy one
    try testing.expectEqualStrings("https://cdn.example/cover.jpg", s.images[0].src);
    try testing.expectEqualStrings("/pics/blue-sky.jpg", s.images[1].src);
    try testing.expectEqualStrings("Blue & sky", s.images[1].alt);
    try testing.expectEqualStrings("A sky", s.images[1].title);
    try testing.expectEqualStrings("lazy.webp", s.images[2].src);
    // Not asked for: none; the limit is kept.
    try testing.expectEqual(@as(usize, 0), (try scan(a, html, 10)).images.len);
    try testing.expectEqual(@as(usize, 1), (try scanWith(a, html, 10, 1)).images.len);
}
