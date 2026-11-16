//! Retrieval for RAG: split stored document text into section-aware chunks and rank the chunks of a few
//! candidate documents against a query. Pure functions over text; the HTTP layer finds the candidate
//! documents and reads their stored text (docs/decisions/0030).
//!
//! Chunks are cut at paragraph boundaries and never span a heading unless the section is tiny; a block
//! larger than the chunk size is split at line or sentence ends. Neighbouring chunks overlap by whole blocks
//! (up to `overlap` characters). Every chunk records the heading path above it, its byte span in the stored
//! text (so a citation can point at an exact place), and a page number when the text carries page breaks
//! (a form feed, or the line `<!-- page break -->`, as Docling can write with its page-break option).
//! Inline images (`![alt](data:...)`) are dropped: they are megabytes of base64 and never help a reader.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Target size of a chunk in bytes of text.
    chunk_chars: u32 = 1200,
    /// Whole blocks from the end of the previous chunk repeated at the start of the next, up to this many bytes.
    overlap: u32 = 150,
};

pub const min_chunk_chars = 200;
pub const max_chunk_chars = 8000;

pub const Chunk = struct {
    /// Position among the document's chunks, from 0.
    index: u32,
    /// Byte span in the stored text (a chunk that repeats overlap starts earlier than the previous one ends).
    start: usize,
    end: usize,
    /// Headings above the chunk, outermost first (text without the `#` marks).
    heading: []const []const u8,
    /// Page of the chunk's start when the text has page breaks.
    page: ?u32,
    /// The text, without inline images.
    text: []const u8,
};

const Block = struct {
    start: usize,
    end: usize,
    kind: enum { text, heading, image, page_break },
    level: u8 = 0,
    /// For a heading: its text. For text: the block's kept text (images cut out).
    text: []const u8 = "",
    page: ?u32 = null,
    /// The heading path in force for this block (shared slices).
    path: []const []const u8 = &.{},
};

fn isDataImage(block: []const u8) bool {
    const t = std.mem.trim(u8, block, " \t\r\n");
    return std.mem.startsWith(u8, t, "![") and std.mem.indexOf(u8, t, "](data:") != null;
}

/// Removes `![alt](data:...)` images from text (returns `s` itself when there are none).
pub fn withoutInlineImages(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, s, "](data:") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '!' and i + 1 < s.len and s[i + 1] == '[') {
            // An image's alt text ends at the first `](`; it is an inline data image if what follows is `data:`.
            if (std.mem.indexOfPos(u8, s, i + 2, "](")) |close| {
                if (std.mem.startsWith(u8, s[close..], "](data:") and std.mem.indexOfScalar(u8, s[i..close], '\n') == null) {
                    if (std.mem.indexOfScalarPos(u8, s, close, ')')) |paren| {
                        i = paren + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

fn headingOf(line: []const u8) ?struct { level: u8, text: []const u8 } {
    var n: usize = 0;
    while (n < line.len and line[n] == '#') n += 1;
    if (n == 0 or n > 6 or n >= line.len or line[n] != ' ') return null;
    return .{ .level = @intCast(n), .text = std.mem.trim(u8, line[n..], " \t#") };
}

/// Splits `text` into blocks (separated by blank lines) with heading paths and pages.
fn blocks(arena: Allocator, text: []const u8) Allocator.Error![]Block {
    var out: std.ArrayList(Block) = .empty;
    var stack: std.ArrayList(struct { level: u8, text: []const u8 }) = .empty;
    var page: u32 = 1;
    var saw_pages = false;
    var pos: usize = 0;
    while (pos < text.len) {
        // Skip blank lines.
        while (pos < text.len and (text[pos] == '\n' or text[pos] == '\r')) pos += 1;
        if (pos >= text.len) break;
        var end = pos;
        while (end < text.len) {
            const nl = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse {
                end = text.len;
                break;
            };
            // A blank line (possibly with spaces) ends the block.
            var j = nl + 1;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\r')) j += 1;
            if (j >= text.len or text[j] == '\n') {
                end = nl;
                break;
            }
            end = nl + 1;
        }
        const raw = text[pos..end];
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        var b: Block = .{ .start = pos, .end = end, .kind = .text };
        if (std.mem.eql(u8, trimmed, "<!-- page break -->") or std.mem.indexOfScalar(u8, raw, 0x0c) != null) {
            // A form feed or the marker: the next text is on the next page. Text sharing the block with a
            // form feed is kept.
            saw_pages = true;
            page += @intCast(std.mem.count(u8, raw, "\x0c") + @intFromBool(std.mem.eql(u8, trimmed, "<!-- page break -->")));
            if (std.mem.eql(u8, trimmed, "<!-- page break -->")) {
                b.kind = .page_break;
                try out.append(arena, b);
                pos = end;
                continue;
            }
        }
        if (isDataImage(raw)) {
            b.kind = .image;
        } else if (headingOf(trimmed)) |h| {
            while (stack.items.len > 0 and stack.items[stack.items.len - 1].level >= h.level) _ = stack.pop();
            try stack.append(arena, .{ .level = h.level, .text = h.text });
            b.kind = .heading;
            b.level = h.level;
            b.text = h.text;
        } else {
            b.text = try withoutInlineImages(arena, trimmed);
        }
        b.page = if (saw_pages) page else null;
        const path = try arena.alloc([]const u8, stack.items.len);
        for (stack.items, path) |s, *p| p.* = s.text;
        b.path = path;
        try out.append(arena, b);
        pos = end;
    }
    // Page numbers before the first break were recorded as null; once breaks exist, the first pages are 1.
    if (saw_pages) for (out.items) |*b| {
        if (b.page == null) b.page = 1;
    };
    return out.items;
}

/// Splits a block longer than `max` at line ends, then sentence ends, then anywhere on a space.
fn splitLong(arena: Allocator, text: []const u8, max: usize, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var rest = text;
    while (rest.len > max) {
        var cut = max;
        // Back up to a line end, a sentence end or a space, within the last third of the window.
        const floor = max * 2 / 3;
        var found: ?usize = null;
        var k = max;
        while (k > floor) : (k -= 1) {
            if (rest[k - 1] == '\n') {
                found = k;
                break;
            }
        }
        if (found == null) {
            k = max;
            while (k > floor) : (k -= 1) {
                if ((rest[k - 1] == '.' or rest[k - 1] == '!' or rest[k - 1] == '?') and (k == rest.len or rest[k] == ' ' or rest[k] == '\n')) {
                    found = k;
                    break;
                }
            }
        }
        if (found == null) {
            k = max;
            while (k > floor) : (k -= 1) {
                if (rest[k - 1] == ' ') {
                    found = k;
                    break;
                }
            }
        }
        cut = found orelse max;
        // Never cut inside a UTF-8 sequence.
        while (cut > 0 and cut < rest.len and (rest[cut] & 0xC0) == 0x80) cut -= 1;
        if (cut == 0) cut = max;
        try out.append(arena, std.mem.trim(u8, rest[0..cut], " \t\r\n"));
        rest = std.mem.trimStart(u8, rest[cut..], " \t\r\n");
    }
    if (rest.len > 0) try out.append(arena, rest);
}

const Piece = struct { start: usize, end: usize, text: []const u8, page: ?u32, path: []const []const u8, heading: bool };

/// Chunks `text`. Everything is allocated from `arena`.
pub fn chunk(arena: Allocator, text: []const u8, options: Options) Allocator.Error![]const Chunk {
    const max: usize = std.math.clamp(options.chunk_chars, min_chunk_chars, max_chunk_chars);
    const bl = try blocks(arena, text);

    // Pieces: text blocks (long ones split), with headings kept as pieces so that sections can start a chunk.
    var pieces: std.ArrayList(Piece) = .empty;
    for (bl) |b| switch (b.kind) {
        .image, .page_break => {},
        .heading => try pieces.append(arena, .{ .start = b.start, .end = b.end, .text = text[b.start..b.end], .page = b.page, .path = b.path, .heading = true }),
        .text => {
            if (b.text.len == 0) continue;
            if (b.text.len <= max) {
                try pieces.append(arena, .{ .start = b.start, .end = b.end, .text = b.text, .page = b.page, .path = b.path, .heading = false });
            } else {
                var parts: std.ArrayList([]const u8) = .empty;
                try splitLong(arena, b.text, max, &parts);
                for (parts.items) |p| {
                    // The span of a part is found in the original block; images cut out make it approximate,
                    // so fall back to the whole block's span.
                    const at = std.mem.indexOf(u8, text[b.start..b.end], p[0..@min(p.len, 40)]);
                    const s = if (at) |a| b.start + a else b.start;
                    try pieces.append(arena, .{ .start = s, .end = @min(s + p.len, b.end), .text = p, .page = b.page, .path = b.path, .heading = false });
                }
            }
        },
    };

    var chunks: std.ArrayList(Chunk) = .empty;
    var i: usize = 0;
    while (i < pieces.items.len) {
        var j = i;
        var size: usize = 0;
        while (j < pieces.items.len) {
            const p = pieces.items[j];
            const add = p.text.len + 2;
            if (j > i) {
                if (size + add > max) break;
                // A new section starts a new chunk once this one has enough in it.
                if (p.heading and size >= max / 3) break;
            }
            size += add;
            j += 1;
        }
        // The chunk is pieces[i..j]; its text joins them with blank lines.
        var buf: std.ArrayList(u8) = .empty;
        var first_text: ?usize = null;
        for (pieces.items[i..j], i..) |p, k| {
            if (buf.items.len > 0) try buf.appendSlice(arena, "\n\n");
            try buf.appendSlice(arena, p.text);
            if (first_text == null and !p.heading) first_text = k;
        }
        const head = pieces.items[first_text orelse i];
        try chunks.append(arena, .{
            .index = @intCast(chunks.items.len),
            .start = pieces.items[i].start,
            .end = pieces.items[j - 1].end,
            .heading = head.path,
            .page = pieces.items[i].page,
            .text = buf.items,
        });
        if (j >= pieces.items.len) break;
        // The next chunk starts with whole pieces from the end of this one, within the overlap budget, but
        // always moves forward.
        var next = j;
        var budget: usize = options.overlap;
        while (next > i + 1 and !pieces.items[next - 1].heading and pieces.items[next - 1].text.len <= budget) {
            budget -= pieces.items[next - 1].text.len;
            next -= 1;
        }
        i = next;
    }
    return chunks.items;
}

// ------------------------------------------------------------------ ranking

pub const Scored = struct {
    /// Index into the candidate chunks given to `rank`.
    at: usize,
    score: f64,
};

/// The words of a query that should be found in a chunk: its plain words and phrase words, lowercased,
/// without operators, conditions (`ext:pdf`), excluded words and regular-expression tokens.
pub fn queryTerms(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |raw| {
        var tok = raw;
        if (tok[0] == '-') continue; // excluded
        if (std.mem.startsWith(u8, tok, "re:")) continue;
        if (std.mem.eql(u8, tok, "OR") or std.mem.eql(u8, tok, "AND") or std.mem.eql(u8, tok, "NOT")) continue;
        // `field:value` conditions (but a word after `title:` or `body:` counts).
        if (std.mem.indexOfScalar(u8, tok, ':')) |c| {
            const key = tok[0..c];
            if (std.mem.eql(u8, key, "title") or std.mem.eql(u8, key, "body")) tok = tok[c + 1 ..] else continue;
        }
        var w = std.mem.tokenizeAny(u8, tok, "\"()+*~.,;!?'`[]{}<>=/\\|&^%$#@_");
        while (w.next()) |word| {
            if (word.len == 0) continue;
            const low = try arena.alloc(u8, word.len);
            _ = std.ascii.lowerString(low, word);
            var seen = false;
            for (out.items) |x| if (std.mem.eql(u8, x, low)) {
                seen = true;
            };
            if (!seen) try out.append(arena, low);
        }
    }
    return out.items;
}

fn countWord(haystack_lower: []const u8, word: []const u8) u32 {
    var n: u32 = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack_lower, from, word)) |at| {
        const before_ok = at == 0 or !std.ascii.isAlphanumeric(haystack_lower[at - 1]);
        const after = at + word.len;
        const after_ok = after >= haystack_lower.len or !std.ascii.isAlphanumeric(haystack_lower[after]);
        if (before_ok and after_ok) n += 1;
        from = at + word.len;
    }
    return n;
}

/// BM25 of every chunk against `terms` (idf computed over these chunks, a heading match counting double);
/// returns the chunks with a nonzero score, best first, ties by position. `heading_text[i]` is chunk i's
/// headings joined.
pub fn rank(arena: Allocator, terms: []const []const u8, texts: []const []const u8, heading_text: []const []const u8) Allocator.Error![]const Scored {
    const n = texts.len;
    if (n == 0 or terms.len == 0) return &.{};
    const lowered = try arena.alloc([]u8, n);
    const lengths = try arena.alloc(f64, n);
    var total_len: f64 = 0;
    for (texts, lowered, lengths) |t, *l, *len| {
        l.* = try arena.alloc(u8, t.len);
        _ = std.ascii.lowerString(l.*, t);
        len.* = @floatFromInt(@max(t.len, 1));
        total_len += len.*;
    }
    const avg = total_len / @as(f64, @floatFromInt(n));
    const head_lower = try arena.alloc([]u8, n);
    for (heading_text, head_lower) |h, *l| {
        l.* = try arena.alloc(u8, h.len);
        _ = std.ascii.lowerString(l.*, h);
    }
    const scores = try arena.alloc(f64, n);
    @memset(scores, 0);
    const k1: f64 = 1.2;
    const bb: f64 = 0.75;
    for (terms) |term| {
        var df: f64 = 0;
        const tf = try arena.alloc(f64, n);
        for (0..n) |i| {
            const c = countWord(lowered[i], term) + 2 * countWord(head_lower[i], term);
            tf[i] = @floatFromInt(c);
            if (c > 0) df += 1;
        }
        if (df == 0) continue;
        const nf: f64 = @floatFromInt(n);
        const idf = @log(1.0 + (nf - df + 0.5) / (df + 0.5));
        for (0..n) |i| {
            if (tf[i] == 0) continue;
            scores[i] += idf * (tf[i] * (k1 + 1.0)) / (tf[i] + k1 * (1.0 - bb + bb * lengths[i] / avg));
        }
    }
    var out: std.ArrayList(Scored) = .empty;
    for (scores, 0..) |s, i| if (s > 0) try out.append(arena, .{ .at = i, .score = s });
    std.mem.sort(Scored, out.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.at < b.at;
        }
    }.lt);
    return out.items;
}

const testing = std.testing;

fn textsOf(arena: Allocator, cs: []const Chunk) ![]const []const u8 {
    const out = try arena.alloc([]const u8, cs.len);
    for (cs, out) |c, *o| o.* = c.text;
    return out;
}

test "inline data images are removed from the middle of text, other images and links are kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("before  after", try withoutInlineImages(a, "before ![Image](data:image/png;base64,AAAA==) after"));
    try testing.expectEqualStrings("![pic](a.png) and [link](data:x)", try withoutInlineImages(a, "![pic](a.png) and [link](data:x)"));
    const same = "no images here";
    try testing.expectEqual(same.ptr, (try withoutInlineImages(a, same)).ptr);
    // An unterminated one is left alone rather than eating the rest.
    try testing.expectEqualStrings("x ![a](data:AAAA", try withoutInlineImages(a, "x ![a](data:AAAA"));
}

test "chunks follow sections, keep heading paths and exact spans, and drop inline images" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc =
        "# Book\n\nIntro paragraph about trolls.\n\n![Image](data:image/png;base64,AAAA)\n\n" ++
        "## Norse\n\nOdin had two ravens.\n\n### Ravens\n\nHuginn and Muninn flew over the world each day.\n\n" ++
        "## Greek\n\nZeus ruled from Olympus.";
    const cs = try chunk(a, doc, .{ .chunk_chars = 200, .overlap = 0 });
    try testing.expect(cs.len >= 1);
    // Nothing of the image is in any chunk.
    for (cs) |c| try testing.expect(std.mem.indexOf(u8, c.text, "base64") == null);
    // Spans lie inside the document and cover the text of the chunk.
    for (cs) |c| {
        try testing.expect(c.end <= doc.len and c.start < c.end);
        try testing.expectEqual(@as(u32, @intCast(c.index)), c.index);
    }
    // Everything said is in some chunk.
    const all = try std.mem.join(a, "\n", try textsOf(a, cs));
    for ([_][]const u8{ "trolls", "Odin", "Huginn", "Zeus" }) |w| try testing.expect(std.mem.indexOf(u8, all, w) != null);
}

test "a long section is split into chunks of about the asked size, with overlap and moving forward" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc: std.ArrayList(u8) = .empty;
    try doc.appendSlice(a, "## Long\n\n");
    for (0..40) |i| try doc.print(a, "Paragraph number {d} says something about wolves and the moon.\n\n", .{i});
    const cs = try chunk(a, doc.items, .{ .chunk_chars = 400, .overlap = 130 });
    try testing.expect(cs.len > 4);
    for (cs) |c| try testing.expect(c.text.len <= 400 + 2);
    // Overlap: the second chunk repeats the end of the first; starts always advance.
    try testing.expect(cs[1].start < cs[0].end);
    for (cs[1..], 0..) |c, i| try testing.expect(c.start > cs[i].start);
    try testing.expectEqualStrings("Long", cs[0].heading[0]);
    // No overlap: no repeats.
    const plain = try chunk(a, doc.items, .{ .chunk_chars = 400, .overlap = 0 });
    for (plain[1..], 0..) |c, i| try testing.expect(c.start >= plain[i].end);
}

test "one huge paragraph is split on line, sentence or space ends, never inside a character" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc: std.ArrayList(u8) = .empty;
    for (0..300) |_| try doc.appendSlice(a, "Ünïcode wörds without any full stop at all ");
    const cs = try chunk(a, doc.items, .{ .chunk_chars = 500, .overlap = 0 });
    try testing.expect(cs.len > 10);
    for (cs) |c| {
        try testing.expect(c.text.len <= 502);
        try testing.expect(std.unicode.utf8ValidateSlice(c.text));
    }
}

test "page breaks give page numbers; without them there are none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paged = try chunk(a, "First page text.\n\n<!-- page break -->\n\nSecond page text.\n\n<!-- page break -->\n\nThird page text.", .{ .chunk_chars = 200, .overlap = 0 });
    try testing.expect(paged.len >= 1);
    try testing.expectEqual(@as(?u32, 1), paged[0].page);
    const ff = try chunk(a, "One.\n\n\x0cTwo.", .{});
    try testing.expectEqual(@as(?u32, 1), ff[0].page);
    const none = try chunk(a, "No pages here.\n\nAt all.", .{});
    try testing.expectEqual(@as(?u32, null), none[0].page);
    try testing.expectEqual(@as(usize, 0), (try chunk(a, "", .{})).len);
}

test "query terms drop operators and conditions; ranking prefers rare words and headings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const terms = try queryTerms(a, "ravens OR \"Odin's wolves\" -dragon ext:md title:Norse re:/x/ NOT");
    try testing.expectEqual(@as(usize, 5), terms.len); // ravens odin s wolves norse
    try testing.expectEqualStrings("ravens", terms[0]);
    for (terms) |t| try testing.expect(!std.mem.eql(u8, t, "dragon") and !std.mem.eql(u8, t, "ext"));

    const t = [_][]const u8{ "The ravens of Odin were Huginn and Muninn.", "Ravens are black birds.", "Wolves hunt in packs.", "Nothing relevant at all." };
    const h = [_][]const u8{ "Norse", "Birds", "Animals", "" };
    const r = try rank(a, &.{ "odin", "ravens" }, &t, &h);
    try testing.expectEqual(@as(usize, 2), r.len); // only chunks with a match
    try testing.expectEqual(@as(usize, 0), r[0].at); // has both, and the rarer word
    try testing.expectEqual(@as(usize, 1), r[1].at);
    // A heading match counts.
    const r2 = try rank(a, &.{"birds"}, &t, &h);
    try testing.expectEqual(@as(usize, 1), r2[0].at);
    try testing.expectEqual(@as(usize, 0), (try rank(a, &.{"zebra"}, &t, &h)).len);
}
