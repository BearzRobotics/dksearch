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
const dates = @import("connectors/feeds/dates.zig");

const block_tags = [_][]const u8{
    "p",  "br", "div", "li",    "ul",         "ol",  "h1", "h2",      "h3",      "h4",     "h5",     "h6",
    "tr", "td", "th",  "table", "blockquote", "pre", "hr", "section", "article", "header", "footer",
};
/// Elements that start a new word when they open straight after another of them has closed: a run of links or spans is a
/// list (tags, menus, breadcrumbs, categories) whose items must not be glued together ("digital art" "artwork" must not become
/// "digital artartwork"). One that opens after text is not a break (`a<span>b</span>c` is "abc": a span can start inside a word),
/// and emphasis (`b`, `i`, `em`, `strong`) is not here at all.
const separating_tags = [_][]const u8{ "a", "span", "button", "label", "option", "dt", "dd", "summary" };
const dropped_tags = [_][]const u8{ "script", "style", "head", "noscript" };

pub fn toText(arena: Allocator, html: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var budget: Budget = .{};
    // A dropped tag whose end tag is missing is searched for only once: after
    // that it is just a tag. This keeps unclosed `<script>` soup linear.
    var missing_end: [dropped_tags.len]bool = @splat(false);
    // The last thing seen was the end of a link or span (no text since): the next link or span starts a new word.
    var after_item = false;
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
                if (isOneOf(t.name, &block_tags)) {
                    try out.append(arena, '\n');
                    after_item = false;
                } else if (isOneOf(t.name, &separating_tags)) {
                    if (t.closing) {
                        after_item = true;
                    } else {
                        if (after_item and out.items.len > 0 and !std.ascii.isWhitespace(out.items[out.items.len - 1])) try out.append(arena, ' ');
                        after_item = false;
                    }
                } else after_item = false;
                i = t.end;
                continue;
            }
        } else if (ch == '&') {
            if (try entity(arena, &out, html, &i)) continue;
        }
        try out.append(arena, ch);
        after_item = false;
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
        .{ "bull", "\u{2022}" },   .{ "middot", "\u{b7}" },  .{ "laquo", "\u{ab}" },   .{ "raquo", "\u{bb}" },
        .{ "reg", "\u{ae}" },      .{ "trade", "\u{2122}" }, .{ "euro", "\u{20ac}" },  .{ "pound", "\u{a3}" },
        .{ "yen", "\u{a5}" },      .{ "cent", "\u{a2}" },    .{ "sect", "\u{a7}" },    .{ "para", "\u{b6}" },
        .{ "larr", "\u{2190}" },   .{ "rarr", "\u{2192}" },  .{ "uarr", "\u{2191}" },  .{ "darr", "\u{2193}" },
        .{ "sbquo", "\u{201a}" },  .{ "bdquo", "\u{201e}" }, .{ "prime", "\u{2032}" }, .{ "minus", "\u{2212}" },
        .{ "ensp", " " },          .{ "emsp", " " },         .{ "thinsp", " " },       .{ "shy", "" },
        .{ "plusmn", "\u{b1}" },   .{ "frac12", "\u{bd}" },  .{ "micro", "\u{b5}" },   .{ "check", "\u{2713}" },
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
    /// Addresses of the page's feeds (`<link rel="alternate" type="application/rss+xml|atom+xml" href>`), at most three.
    feeds: []const []const u8 = &.{},
    /// `<meta name="generator" content="...">`: what made the page ("MediaWiki 1.43.0").
    generator: ?[]const u8 = null,
    /// `<link rel="EditURI" href="...">`: where a MediaWiki's API is (the address with `?action=rsd`).
    edit_uri: ?[]const u8 = null,
    /// `<html lang="...">`: the language the page says it is in (as written, at most 35 characters).
    lang: ?[]const u8 = null,
    /// The page's own tags (docs/decisions/0074), lower case, at most `max_tags` (100) of at most `max_tag_len` characters: the
    /// `<meta name="keywords">` and `article:tag` / `og:video:tag` metas, links marked `rel="tag"`, `data-tags` and
    /// `data-tag-name` attributes (image boards write their tags there), and the keywords of a JSON-LD block.
    tags: []const []const u8 = &.{},
    /// The page's own description (`<meta name="description">`, `og:description`, JSON-LD), at most `max_description` characters.
    description: ?[]const u8 = null,
    /// Who the page says wrote it (`author` metas, JSON-LD `author`), when it was published and last changed (Unix seconds).
    author: ?[]const u8 = null,
    published_at: ?i64 = null,
    modified_at: ?i64 = null,
    /// What the page says about itself beyond words (ADR 0075): `type` (`og:type`: article, video.movie), `site`, and for a
    /// video or picture its `duration` ("1:02:03") and `resolution` ("1920x1080").
    facts: []const Fact = &.{},
};

pub const Fact = struct { key: []const u8, value: []const u8 };

/// What the metas and JSON-LD of a page say about it, gathered while the page is scanned.
const Meta = struct {
    facts: std.ArrayList(Fact) = .empty,
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,

    fn fact(m: *Meta, arena: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
        for (m.facts.items) |f| if (std.mem.eql(u8, f.key, key)) return;
        const v = std.mem.trim(u8, value, " \t\r\n");
        if (v.len == 0 or v.len > 80) return;
        try m.facts.append(arena, .{ .key = key, .value = try decodeEntities(arena, v) });
    }
};

/// The seconds of an ISO 8601 duration (`PT1H2M3S`, `PT90S`, `P1DT2H`; fractions of a second dropped), or null.
pub fn isoDuration(s: []const u8) ?u64 {
    if (s.len < 3 or s.len > 40 or (s[0] != 'P' and s[0] != 'p')) return null;
    var total: u64 = 0;
    var in_time = false;
    var num: u64 = 0;
    var have_num = false;
    var any = false;
    var frac = false;
    for (s[1..]) |ch| {
        if (std.ascii.isDigit(ch)) {
            if (frac) continue;
            num = num *| 10 +| (ch - '0');
            have_num = true;
        } else if (ch == '.' or ch == ',') {
            frac = true;
        } else {
            const unit = std.ascii.toUpper(ch);
            if (unit == 'T') {
                in_time = true;
                continue;
            }
            if (!have_num) return null;
            const mult: u64 = switch (unit) {
                'D' => 86400,
                'H' => if (in_time) 3600 else return null,
                'M' => if (in_time) 60 else 30 * 86400,
                'S' => if (in_time) 1 else return null,
                'W' => 7 * 86400,
                else => return null,
            };
            total +|= num *| mult;
            num = 0;
            have_num = false;
            frac = false;
            any = true;
        }
    }
    if (have_num or !any) return null;
    return total;
}

/// "1:02:03" or "12:34" (a duration of at most a day), from seconds.
fn formatDuration(arena: Allocator, secs: u64) Allocator.Error!?[]const u8 {
    if (secs == 0 or secs > 86400 * 2) return null;
    if (secs >= 3600) return try std.fmt.allocPrint(arena, "{d}:{d:0>2}:{d:0>2}", .{ secs / 3600, secs % 3600 / 60, secs % 60 });
    return try std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ secs / 60, secs % 60 });
}

fn isNumber(s: []const u8) bool {
    if (s.len == 0 or s.len > 5) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

pub const max_tags = 100;
pub const max_tag_len = 60;
pub const max_description = 600;
/// A JSON-LD block longer than this is not read.
const max_ld_bytes = 128 * 1024;

/// A picture of a page: where it is (as written in the page: it may be relative), what the page says it shows.
pub const PageImage = struct { src: []const u8, alt: []const u8, title: []const u8, tags: []const []const u8 = &.{} };

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
/// Adds `raw` to `list` as a tag: entities decoded, lower case, underscores as spaces (`long_hair` is "long hair"), spaces
/// collapsed, `#` and quotes trimmed; not an empty or over-long one, not one with no letter or digit, not one already there.
fn addTag(arena: Allocator, list: *std.ArrayList([]const u8), raw: []const u8) Allocator.Error!void {
    if (list.items.len >= max_tags) return;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"'#,;");
    if (trimmed.len == 0 or trimmed.len > max_tag_len * 2) return;
    const decoded = try decodeEntities(arena, trimmed);
    var buf = try arena.alloc(u8, decoded.len);
    var n: usize = 0;
    var prev_space = true;
    for (decoded) |c| {
        const ch: u8 = if (c == '_') ' ' else std.ascii.toLower(c);
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            if (!prev_space) {
                buf[n] = ' ';
                n += 1;
                prev_space = true;
            }
        } else {
            buf[n] = ch;
            n += 1;
            prev_space = false;
        }
    }
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    if (n == 0 or n > max_tag_len) return;
    var has_word = false;
    for (buf[0..n]) |c| if (std.ascii.isAlphanumeric(c) or c >= 0x80) {
        has_word = true;
        break;
    };
    if (!has_word) return;
    for (list.items) |x| if (std.mem.eql(u8, x, buf[0..n])) return;
    try list.append(arena, buf[0..n]);
}

fn addTagList(arena: Allocator, list: *std.ArrayList([]const u8), raw: []const u8, separators: []const u8) Allocator.Error!void {
    var it = std.mem.tokenizeAny(u8, raw, separators);
    while (it.next()) |part| try addTag(arena, list, part);
}

/// The tags in an attribute value like `data-tags="long_hair blue_eyes"`, as a slice (for a picture).
fn tagSlice(arena: Allocator, raw: ?[]const u8) Allocator.Error![]const []const u8 {
    const r = raw orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    try addTagList(arena, &list, r, " \t\r\n,");
    return list.items;
}

/// C preprocessor words and the like: `#include` and `#define` in a page of code are not tags.
const not_hashtags = [_][]const u8{ "include", "define", "ifdef", "ifndef", "endif", "pragma", "else", "elif", "undef", "error", "warning", "if", "region", "endregion", "import", "end", "top", "main", "content" };

/// Adds the hashtags of `text` (`#Linux #Nature`) to `list`: a `#` at the start or after a space or punctuation (not in
/// the middle of a word: `C#`, `page.html#top`), then letters, digits, `_` or non-ASCII letters, with at least one letter, not a
/// colour (`#fff`, `#00ff00`) and not a preprocessor word. A hashtag written in camel case (`#DigitalArt`) is added as it is
/// (`digitalart`) and as words (`digital art`), since people search for the words.
fn addHashtags(arena: Allocator, list: *std.ArrayList([]const u8), text: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '#')) |h| {
        i = h + 1;
        if (list.items.len >= max_tags) return;
        if (h > 0 and (std.ascii.isAlphanumeric(text[h - 1]) or text[h - 1] == '#' or text[h - 1] == '&' or text[h - 1] == '/' or text[h - 1] >= 0x80)) continue;
        var e = i;
        var letters: usize = 0;
        var hex_only = true;
        while (e < text.len and (std.ascii.isAlphanumeric(text[e]) or text[e] == '_' or text[e] >= 0x80)) : (e += 1) {
            if (std.ascii.isAlphabetic(text[e]) or text[e] >= 0x80) letters += 1;
            if (!std.ascii.isHex(text[e])) hex_only = false;
        }
        const raw = text[i..e];
        i = e;
        if (raw.len < 2 or raw.len > max_tag_len or letters == 0) continue;
        if (hex_only and (raw.len == 3 or raw.len == 4 or raw.len == 6 or raw.len == 8)) continue; // a colour
        var skip = false;
        for (not_hashtags) |w| if (std.ascii.eqlIgnoreCase(raw, w)) {
            skip = true;
        };
        if (skip) continue;
        try addTag(arena, list, raw);
        // Camel case as words: lower-to-upper changes are breaks (`DigitalArt`, `3DModeling`).
        var words: std.ArrayList(u8) = .empty;
        var broke = false;
        for (raw, 0..) |c, k| {
            if (k > 0 and std.ascii.isUpper(c) and (std.ascii.isLower(raw[k - 1]) or std.ascii.isDigit(raw[k - 1]))) {
                try words.append(arena, ' ');
                broke = true;
            }
            try words.append(arena, c);
        }
        if (broke) try addTag(arena, list, words.items);
    }
}

/// The page's tags with the hashtags of its text added (each once, at most `max_tags`).
pub fn withHashtags(arena: Allocator, tags: []const []const u8, text: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, tags);
    try addHashtags(arena, &list, text);
    return list.items;
}

/// The text inside the element that opened just before `start`, up to its closing tag (tags inside it dropped), when short.
fn innerText(arena: Allocator, html: []const u8, start: usize, closing: []const u8) Allocator.Error!?[]const u8 {
    const window = html[start..@min(html.len, start + 300)];
    const end = std.ascii.findIgnoreCase(window, closing) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    for (window[0..end]) |c| {
        if (c == '<') in_tag = true else if (c == '>') in_tag = false else if (!in_tag) try out.append(arena, c);
    }
    return out.items;
}

/// What a JSON-LD block says about the page (`{"keywords": "a, b", "description": "...", "author": {"name": "..."}}`, possibly
/// nested in `@graph` or arrays): keywords, description, author, dates, and a video's or picture's duration and size. A block
/// that is not JSON, or is too deep, gives nothing.
fn readJsonLd(arena: Allocator, content: []const u8, tags: *std.ArrayList([]const u8), out: *Scan, meta: *Meta) Allocator.Error!void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{}) catch return;
    try walkJsonLd(arena, root, 0, tags, out, meta);
}

fn jsonText(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .integer, .float, .number_string => null,
        else => null,
    };
}

/// A name from a JSON-LD author: a string, an object with a `name`, or the first of an array of them.
fn ldAuthor(v: std.json.Value) ?[]const u8 {
    switch (v) {
        .string => |s| return s,
        .object => |o| if (o.get("name")) |n| return jsonText(n),
        .array => |a| if (a.items.len > 0) return ldAuthor(a.items[0]),
        else => {},
    }
    return null;
}

fn walkJsonLd(arena: Allocator, v: std.json.Value, depth: u32, tags: *std.ArrayList([]const u8), out: *Scan, meta: *Meta) Allocator.Error!void {
    if (depth > 6) return;
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                const val = e.value_ptr.*;
                if (std.ascii.eqlIgnoreCase(key, "keywords")) {
                    switch (val) {
                        .string => |s| try addTagList(arena, tags, s, ",;"),
                        .array => |a| for (a.items[0..@min(a.items.len, 100)]) |item| if (item == .string) try addTag(arena, tags, item.string),
                        else => {},
                    }
                } else if (std.ascii.eqlIgnoreCase(key, "description")) {
                    if (out.description == null and val == .string) out.description = try cleanDescription(arena, val.string);
                } else if (std.ascii.eqlIgnoreCase(key, "author") or std.ascii.eqlIgnoreCase(key, "creator")) {
                    if (out.author == null) if (ldAuthor(val)) |n| {
                        out.author = try cleanAuthor(arena, n);
                    };
                    if (val == .object) try walkJsonLd(arena, val, depth + 1, tags, out, meta);
                } else if (std.ascii.eqlIgnoreCase(key, "datePublished") or std.ascii.eqlIgnoreCase(key, "uploadDate") or std.ascii.eqlIgnoreCase(key, "dateCreated")) {
                    if (out.published_at == null) if (jsonText(val)) |s| {
                        out.published_at = dates.parseIso(s);
                    };
                } else if (std.ascii.eqlIgnoreCase(key, "dateModified")) {
                    if (out.modified_at == null) if (jsonText(val)) |s| {
                        out.modified_at = dates.parseIso(s);
                    };
                } else if (std.ascii.eqlIgnoreCase(key, "duration")) {
                    if (jsonText(val)) |s| if (isoDuration(s)) |secs| if (try formatDuration(arena, secs)) |f| try meta.fact(arena, "duration", f);
                } else if (std.mem.eql(u8, key, "width") or std.mem.eql(u8, key, "height")) {
                    var buf: [16]u8 = undefined;
                    const text: ?[]const u8 = switch (val) {
                        .integer => |n| if (n > 0 and n < 100000) std.fmt.bufPrint(&buf, "{d}", .{n}) catch null else null,
                        .string => |s| if (isNumber(s)) s else null,
                        else => null,
                    };
                    if (text) |t| {
                        const kept = try arena.dupe(u8, t);
                        if (key[0] == 'w') {
                            if (meta.width == null) meta.width = kept;
                        } else if (meta.height == null) meta.height = kept;
                    }
                } else {
                    try walkJsonLd(arena, val, depth + 1, tags, out, meta);
                }
            }
        },
        .array => |a| for (a.items[0..@min(a.items.len, 50)]) |item| try walkJsonLd(arena, item, depth + 1, tags, out, meta),
        else => {},
    }
}

/// An author's name: not an address, not a long text; entities decoded.
fn cleanAuthor(arena: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 0 or t.len > 120 or std.mem.indexOf(u8, t, "://") != null) return null;
    return try decodeEntities(arena, t);
}

/// The author, dates, type, site, and a video's or picture's duration and size that a `<meta>` gives.
fn readMetaFacts(arena: Allocator, name: []const u8, content: []const u8, out: *Scan, meta: *Meta) Allocator.Error!void {
    const author_metas = [_][]const u8{ "author", "article:author", "og:article:author", "parsely-author", "dc.creator", "sailthru.author", "video:director" };
    const published_metas = [_][]const u8{ "article:published_time", "og:article:published_time", "datepublished", "uploaddate", "date", "dc.date", "dc.date.issued", "pubdate", "publishdate", "parsely-pub-date", "og:video:release_date", "video:release_date", "sailthru.date" };
    const modified_metas = [_][]const u8{ "article:modified_time", "og:updated_time", "datemodified", "og:article:modified_time" };
    if (out.author == null) for (author_metas) |m| if (std.ascii.eqlIgnoreCase(name, m)) {
        out.author = try cleanAuthor(arena, content);
    };
    if (out.published_at == null) for (published_metas) |m| if (std.ascii.eqlIgnoreCase(name, m)) {
        out.published_at = dates.parseIso(content);
    };
    if (out.modified_at == null) for (modified_metas) |m| if (std.ascii.eqlIgnoreCase(name, m)) {
        out.modified_at = dates.parseIso(content);
    };
    const c = std.mem.trim(u8, content, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(name, "og:type")) {
        if (c.len <= 40) try meta.fact(arena, "type", try std.ascii.allocLowerString(arena, c));
    } else if (std.ascii.eqlIgnoreCase(name, "og:site_name")) {
        try meta.fact(arena, "site", c);
    } else if (std.ascii.eqlIgnoreCase(name, "og:video:duration") or std.ascii.eqlIgnoreCase(name, "video:duration") or std.ascii.eqlIgnoreCase(name, "music:duration")) {
        if (isNumber(c)) if (try formatDuration(arena, std.fmt.parseInt(u64, c, 10) catch 0)) |f| try meta.fact(arena, "duration", f);
    } else if (std.ascii.eqlIgnoreCase(name, "og:video:width") or std.ascii.eqlIgnoreCase(name, "og:image:width")) {
        if (isNumber(c) and meta.width == null) meta.width = try arena.dupe(u8, c);
    } else if (std.ascii.eqlIgnoreCase(name, "og:video:height") or std.ascii.eqlIgnoreCase(name, "og:image:height")) {
        if (isNumber(c) and meta.height == null) meta.height = try arena.dupe(u8, c);
    }
}

fn cleanDescription(arena: Allocator, raw: []const u8) Allocator.Error!?[]const u8 {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len == 0) return null;
    const decoded = try decodeEntities(arena, t[0..@min(t.len, max_description * 2)]);
    var end = @min(decoded.len, max_description);
    while (end > 0 and end < decoded.len and (decoded[end] & 0xC0) == 0x80) end -= 1; // not inside a character
    return decoded[0..end];
}

pub fn scanWith(arena: Allocator, html: []const u8, max_links: usize, max_images: usize) Allocator.Error!Scan {
    var out: Scan = .{};
    var links: std.ArrayList([]const u8) = .empty;
    var images: std.ArrayList(PageImage) = .empty;
    var feeds: std.ArrayList([]const u8) = .empty;
    var tags: std.ArrayList([]const u8) = .empty;
    var meta: Meta = .{};
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
                    // A JSON-LD block says what the page is (keywords, description): read before it is skipped.
                    if (std.ascii.eqlIgnoreCase(t.name, "script")) if (attr(html[lt..t.end], "type")) |ty| if (std.ascii.findIgnoreCase(ty, "ld+json") != null) {
                        const raw = html[t.end..e];
                        const cut = std.mem.lastIndexOf(u8, raw, "</") orelse raw.len;
                        if (cut <= max_ld_bytes) try readJsonLd(arena, raw[0..cut], &tags, &out, &meta);
                    };
                    i = e;
                } else missing_end[k] = true;
            }
            continue;
        }
        const body = html[lt..t.end];
        // Image boards put a post's tags in a `data-tags` attribute (of the post, the picture or the link).
        if (std.mem.indexOf(u8, body, "data-tag") != null) {
            if (attr(body, "data-tags")) |dt| try addTagList(arena, &tags, dt, " \t\r\n,");
            if (attr(body, "data-tag-name")) |tn| try addTag(arena, &tags, tn);
        }
        if (out.lang == null and std.ascii.eqlIgnoreCase(t.name, "html")) {
            if (attr(body, "lang")) |l| {
                const v = std.mem.trim(u8, l, " \t\r\n\"'");
                if (v.len >= 2 and v.len <= 35) out.lang = try arena.dupe(u8, v);
            }
            continue;
        }
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
                .tags = try tagSlice(arena, attr(body, "data-tags")),
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
        if (std.ascii.eqlIgnoreCase(t.name, "link")) {
            const rel = attr(body, "rel") orelse "";
            const ty = attr(body, "type") orelse "";
            if (hasToken(rel, "edituri")) {
                if (attr(body, "href")) |href| {
                    const trimmed = std.mem.trim(u8, href, " \t\r\n");
                    if (trimmed.len > 0 and trimmed.len <= 2000 and out.edit_uri == null) out.edit_uri = try decodeEntities(arena, trimmed);
                }
            } else if (feeds.items.len < 3 and hasToken(rel, "alternate") and (std.ascii.startsWithIgnoreCase(ty, "application/rss+xml") or std.ascii.startsWithIgnoreCase(ty, "application/atom+xml"))) {
                if (attr(body, "href")) |href| {
                    const trimmed = std.mem.trim(u8, href, " \t\r\n");
                    if (trimmed.len > 0 and trimmed.len <= 2000) try feeds.append(arena, try decodeEntities(arena, trimmed));
                }
            }
            continue;
        }
        // Links marked as tags (`rel="tag"`, WordPress and many others): the text of the link is a tag.
        if (std.ascii.eqlIgnoreCase(t.name, "a")) if (attr(body, "rel")) |rel| if (hasToken(rel, "tag")) {
            if (try innerText(arena, html, t.end, "</a")) |tx| try addTag(arena, &tags, tx);
        };
        if (std.ascii.eqlIgnoreCase(t.name, "meta")) {
            const name = attr(body, "name") orelse (attr(body, "property") orelse (attr(body, "itemprop") orelse continue));
            if (attr(body, "content")) |c| {
                const keyword_metas = [_][]const u8{ "keywords", "news_keywords", "parsely-tags", "sailthru.tags" };
                const single_tag_metas = [_][]const u8{ "article:tag", "og:video:tag", "video:tag", "book:tag" };
                const description_metas = [_][]const u8{ "description", "og:description", "twitter:description" };
                for (keyword_metas) |m| if (std.ascii.eqlIgnoreCase(name, m)) try addTagList(arena, &tags, c, ",;");
                for (single_tag_metas) |m| if (std.ascii.eqlIgnoreCase(name, m)) try addTag(arena, &tags, c);
                if (out.description == null) for (description_metas) |m| if (std.ascii.eqlIgnoreCase(name, m)) {
                    out.description = try cleanDescription(arena, c);
                };
                try readMetaFacts(arena, name, c, &out, &meta);
            }
            if (std.ascii.eqlIgnoreCase(name, "generator")) {
                if (attr(body, "content")) |g| if (out.generator == null and g.len <= 120) {
                    out.generator = try decodeEntities(arena, std.mem.trim(u8, g, " \t\r\n"));
                };
                continue;
            }
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
    out.feeds = feeds.items;
    out.tags = tags.items;
    if (meta.width != null and meta.height != null) {
        const res = try std.fmt.allocPrint(arena, "{s}x{s}", .{ meta.width.?, meta.height.? });
        try meta.fact(arena, "resolution", res);
    }
    out.facts = meta.facts.items;
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

/// `s` with the HTML entities (`&amp;`, `&bull;`, `&#8226;`) decoded.
pub fn decodeEntities(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
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

test "the feeds a page names are found, in order, and a stylesheet link is not one" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const html = "<head><link rel=\"stylesheet\" href=\"/s.css\"><link rel=\"alternate\" type=\"application/rss+xml\" title=\"Posts\" href=\"/feed.xml\">" ++
        "<link rel=\"alternate\" type=\"application/atom+xml\" href=\"https://e.org/atom\"><link rel=\"alternate\" hreflang=\"fr\" href=\"/fr\"></head><body></body>";
    const s = try scan(ar.allocator(), html, 10);
    try testing.expectEqual(@as(usize, 2), s.feeds.len);
    try testing.expectEqualStrings("/feed.xml", s.feeds[0]);
    try testing.expectEqualStrings("https://e.org/atom", s.feeds[1]);
}

test "a MediaWiki page says so, and where its API is" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const html = "<head><meta name=\"generator\" content=\"MediaWiki 1.43.0\"><link rel=\"EditURI\" type=\"application/rsd+xml\" href=\"//wiki.e.org/w/api.php?action=rsd\"></head><body></body>";
    const s = try scan(ar.allocator(), html, 10);
    try testing.expectEqualStrings("MediaWiki 1.43.0", s.generator.?);
    try testing.expectEqualStrings("//wiki.e.org/w/api.php?action=rsd", s.edit_uri.?);
    const plain = try scan(ar.allocator(), "<head><meta name=\"robots\" content=\"noindex\"></head>", 10);
    try testing.expect(plain.generator == null and plain.edit_uri == null and plain.noindex);
}

test "the page's own language comes from the html element" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const s = try scan(ar.allocator(), "<!doctype html><html lang=\"zh-CN\" class=a><head><title>x</title></head><body></body></html>", 10);
    try testing.expectEqualStrings("zh-CN", s.lang.?);
    try testing.expect((try scan(ar.allocator(), "<html><body>x</body></html>", 10)).lang == null);
}

test "common named entities are decoded" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try testing.expectEqualStrings("Library \u{2022} Index \u{b7} A \u{2192} B \u{2122}", (try titleOf(ar.allocator(), "<title>Library &bull; Index &middot; A &rarr; B &trade;</title>")).?);
    try testing.expectEqualStrings("a&unknown;b", (try titleOf(ar.allocator(), "<title>a&unknown;b</title>")).?);
}

test "links and spans that follow one another are separate words; emphasis in the middle of a word is not a break" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("digital art artwork concept art", try toText(a, "<div class=tags><a href=/t/1>digital art</a><a href=/t/2>artwork</a><a href=/t/3>concept art</a></div>"));
    try testing.expectEqualStrings("nature plants", try toText(a, "<span class=tag>nature</span><span class=tag>plants</span>"));
    try testing.expectEqualStrings("Home Docs Blog", try toText(a, "<nav><a href=/>Home</a><a href=/d>Docs</a><a href=/b>Blog</a></nav>"));
    // Unchanged: text before a link, a plural after one, and emphasis.
    try testing.expectEqualStrings("the cats and boldface", try toText(a, "the <a href=/c>cat</a>s and <b>bold</b>face"));
    try testing.expectEqualStrings("a b", try toText(a, "a <span>b</span>"));
}

test "a page's tags and description are found in its metas, links, data attributes and JSON-LD" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const page =
        \\<html><head><title>T</title>
        \\<meta name="keywords" content="Digital Art, artwork; concept art">
        \\<meta property="article:tag" content="Night">
        \\<meta property="og:video:tag" content="  stars ">
        \\<meta name="description" content="A page &amp; its picture.">
        \\<meta property="og:description" content="ignored: one description is enough">
        \\<script type="application/ld+json">{"@type":"VideoObject","keywords":"anime, long_hair","description":"not used","@graph":[{"keywords":["Plants","trees"]}]}</script>
        \\</head><body>
        \\<a href="/t/x" rel="tag">Outdoors</a><a rel="nofollow tag" href="/t/y"><b>hotel</b></a>
        \\<article data-tags="blue_eyes long_hair 1girl"><img src="/p.png" alt="pic" width=300 data-tags="school_uniform nurse"></article>
        \\<a href="/z" data-tag-name="Cosplaying">z</a>
        \\</body></html>
    ;
    const s = try scanWith(a, page, 10, 10);
    const want = [_][]const u8{ "digital art", "artwork", "concept art", "night", "stars", "anime", "long hair", "plants", "trees", "outdoors", "hotel", "blue eyes", "1girl", "school uniform", "nurse", "cosplaying" };
    for (want) |w| {
        var found = false;
        for (s.tags) |t| if (std.mem.eql(u8, t, w)) {
            found = true;
        };
        if (!found) std.debug.print("missing tag: {s}\n", .{w});
        try testing.expect(found);
    }
    // Each once ("long hair" was in two places), and the description is the first one, decoded.
    try testing.expectEqual(@as(usize, want.len), s.tags.len);
    try testing.expectEqualStrings("A page & its picture.", s.description.?);
    // A picture keeps its own tags.
    try testing.expectEqual(@as(usize, 1), s.images.len);
    try testing.expectEqual(@as(usize, 2), s.images[0].tags.len);
    try testing.expectEqualStrings("school uniform", s.images[0].tags[0]);
}

test "tags are normalised and limited: nothing but punctuation, nothing too long, at most sixty" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var html: std.ArrayList(u8) = .empty;
    try html.appendSlice(a, "<meta name=keywords content=\"#Tag One, ---, '', ");
    const too_long: [61]u8 = @splat('x');
    try html.appendSlice(a, &too_long);
    try html.appendSlice(a, ", ");
    for (0..130) |i| try html.print(a, "t{d},", .{i});
    try html.appendSlice(a, "\">");
    const s = try scanWith(a, html.items, 10, 0);
    try testing.expectEqual(@as(usize, max_tags), s.tags.len);
    try testing.expectEqualStrings("tag one", s.tags[0]);
    try testing.expectEqualStrings("t0", s.tags[1]); // "---", "''" and the long one are not tags
    // A broken JSON-LD block, an unclosed script and deep nesting give nothing and never fail.
    const bad = try scanWith(a, "<script type=\"application/ld+json\">{\"keywords\": [1,2,{\"x\"</script><script type=ld+json>{\"keywords\":\"never closed", 10, 0);
    try testing.expectEqual(@as(usize, 0), bad.tags.len);
}

test "hashtags in the text are tags; colours, code, numbers and the middle of words are not" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = "Posted by Lea #Linux #Nature #DigitalArt, #3DModeling. See page.html#top, C# and F#, colour #fff and #00ff00, issue #123, #include <stdio.h>, # heading, #l, #Zebra_crossing!, #\u{65e5}\u{672c}\u{8a9e}";
    const tags = try withHashtags(a, &.{"already"}, text);
    const want = [_][]const u8{ "already", "linux", "nature", "digitalart", "digital art", "3dmodeling", "zebra crossing", "\u{65e5}\u{672c}\u{8a9e}" };
    for (want) |w| {
        var found = false;
        for (tags) |t| if (std.mem.eql(u8, t, w)) {
            found = true;
        };
        if (!found) std.debug.print("missing: {s}\n", .{w});
        try testing.expect(found);
    }
    for (tags) |t| {
        for ([_][]const u8{ "top", "fff", "00ff00", "123", "include", "heading", "l" }) |bad| try testing.expect(!std.mem.eql(u8, t, bad));
    }
}

test "ISO 8601 durations" {
    try testing.expectEqual(@as(?u64, 3723), isoDuration("PT1H2M3S"));
    try testing.expectEqual(@as(?u64, 90), isoDuration("PT90S"));
    try testing.expectEqual(@as(?u64, 93600), isoDuration("P1DT2H"));
    try testing.expectEqual(@as(?u64, 754), isoDuration("PT12M34.5S"));
    try testing.expectEqual(@as(?u64, null), isoDuration("PT"));
    try testing.expectEqual(@as(?u64, null), isoDuration("12:34"));
    try testing.expectEqual(@as(?u64, null), isoDuration("PT5"));
    try testing.expectEqual(@as(?u64, null), isoDuration("P5H"));
}

test "author, dates, type, duration and size come from metas and JSON-LD" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const meta_page =
        \\<head><meta name="author" content="Lea Pinto &amp; Co"><meta property="article:published_time" content="2024-05-01T12:30:00Z">
        \\<meta property="article:modified_time" content="2024-06-02"><meta property="og:type" content="Video.Movie"><meta property="og:site_name" content="Vids">
        \\<meta property="og:video:duration" content="3723"><meta property="og:video:width" content="1920"><meta property="og:video:height" content="1080"></head>
    ;
    const m = try scanWith(a, meta_page, 10, 0);
    try testing.expectEqualStrings("Lea Pinto & Co", m.author.?);
    try testing.expectEqual(@as(?i64, 1714566600), m.published_at);
    try testing.expectEqual(@as(?i64, 1717286400), m.modified_at);
    var got: [4][]const u8 = .{ "", "", "", "" };
    for (m.facts) |f| {
        if (std.mem.eql(u8, f.key, "type")) got[0] = f.value;
        if (std.mem.eql(u8, f.key, "site")) got[1] = f.value;
        if (std.mem.eql(u8, f.key, "duration")) got[2] = f.value;
        if (std.mem.eql(u8, f.key, "resolution")) got[3] = f.value;
    }
    try testing.expectEqualStrings("video.movie", got[0]);
    try testing.expectEqualStrings("Vids", got[1]);
    try testing.expectEqualStrings("1:02:03", got[2]);
    try testing.expectEqualStrings("1920x1080", got[3]);

    const ld_page =
        \\<script type="application/ld+json">{"@type":"VideoObject","name":"x","author":{"@type":"Person","name":"Sam"},"uploadDate":"2023-01-02T03:04:05+01:00",
        \\"dateModified":"2023-02-01","duration":"PT12M34S","width":1280,"height":"720","keywords":"a, b"}</script>
    ;
    const l = try scanWith(a, ld_page, 10, 0);
    try testing.expectEqualStrings("Sam", l.author.?);
    try testing.expectEqual(@as(?i64, 1672625045), l.published_at);
    try testing.expect(l.modified_at != null);
    try testing.expectEqual(@as(usize, 2), l.tags.len);
    var dur: []const u8 = "";
    var res: []const u8 = "";
    for (l.facts) |f| {
        if (std.mem.eql(u8, f.key, "duration")) dur = f.value;
        if (std.mem.eql(u8, f.key, "resolution")) res = f.value;
    }
    try testing.expectEqualStrings("12:34", dur);
    try testing.expectEqualStrings("1280x720", res);

    // An author that is an address, a date that is not one, and a duration of nonsense give nothing.
    const bad = try scanWith(a, "<meta name=author content='https://example.org/u/1'><meta name=date content='soon'><meta property=og:video:duration content='0'>", 10, 0);
    try testing.expect(bad.author == null and bad.published_at == null and bad.facts.len == 0);
}
