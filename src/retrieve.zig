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
    /// Pictures that sit in this chunk's span, as numbers for `nthInlineImage` (from `dkimg:N` references).
    images: []const u32 = &.{},
};

const Block = struct {
    start: usize,
    end: usize,
    kind: enum { text, heading, image, page_break },
    level: u8 = 0,
    /// For a heading: its text. For text: the block's kept text (images cut out).
    text: []const u8 = "",
    /// Pictures of the original file placed in this block (`dkimg:N` references).
    images: []const u32 = &.{},
    page: ?u32 = null,
    /// The heading path in force for this block (shared slices).
    path: []const []const u8 = &.{},
};

fn isDataImage(block: []const u8) bool {
    const t = std.mem.trim(u8, block, " \t\r\n");
    return std.mem.startsWith(u8, t, "![") and std.mem.indexOf(u8, t, "](data:") != null;
}

fn withoutFormFeeds(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, 0x0c) == null) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |b| if (b != 0x0c) try out.append(arena, b);
    return std.mem.trim(u8, out.items, " \t\r\n");
}

/// One inline data image: `![alt](data:MIME;base64,DATA)`.
const DataImage = struct { start: usize, end: usize, mime: []const u8, data: []const u8 };

/// The first inline data image at or after `from`.
fn nextDataImage(s: []const u8, from: usize) ?DataImage {
    var i = from;
    while (std.mem.indexOfPos(u8, s, i, "![")) |at| {
        i = at + 2;
        // An image's alt text ends at the first `](`; it is an inline data image if what follows is `data:`.
        const close = std.mem.indexOfPos(u8, s, at + 2, "](") orelse return null;
        if (!std.mem.startsWith(u8, s[close..], "](data:")) continue;
        if (std.mem.indexOfScalar(u8, s[at..close], '\n') != null) continue;
        const paren = std.mem.indexOfScalarPos(u8, s, close, ')') orelse return null;
        const body = s[close + "](data:".len .. paren];
        const semi = std.mem.indexOfScalar(u8, body, ';') orelse continue;
        const comma = std.mem.indexOfScalar(u8, body, ',') orelse continue;
        if (comma < semi) continue;
        return .{ .start = at, .end = paren + 1, .mime = body[0..semi], .data = body[comma + 1 ..] };
    }
    return null;
}

/// Replaces each inline data image with `![](dkimg:N)`, N counting from 0 in the order they occur, so the text stays
/// small and the picture can still be fetched from the original file (see `nthInlineImage`).
pub fn replaceInlineImages(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    var n: usize = 0;
    while (nextDataImage(s, pos)) |img| {
        try out.appendSlice(arena, s[pos..img.start]);
        try out.print(arena, "![](dkimg:{d})", .{n});
        n += 1;
        pos = img.end;
    }
    if (n == 0) return s;
    try out.appendSlice(arena, s[pos..]);
    return out.items;
}

pub const Image = struct { mime: []const u8, bytes: []const u8 };

/// The `n`th inline data image of a file's text (numbered as in `replaceInlineImages`), decoded. Only picture types
/// that cannot carry script are returned.
pub fn nthInlineImage(arena: Allocator, s: []const u8, n: usize) Allocator.Error!?Image {
    var pos: usize = 0;
    var k: usize = 0;
    while (nextDataImage(s, pos)) |img| : (k += 1) {
        pos = img.end;
        if (k != n) continue;
        const allowed = [_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp" };
        var ok = false;
        for (allowed) |m| if (std.mem.eql(u8, m, img.mime)) {
            ok = true;
        };
        if (!ok) return null;
        const dec = std.base64.standard.decoderWithIgnore(" \t\r\n");
        const size = dec.calcSizeUpperBound(img.data.len);
        const buf = try arena.alloc(u8, size);
        const got = dec.decode(buf, img.data) catch return null;
        return .{ .mime = img.mime, .bytes = buf[0..got] };
    }
    return null;
}

/// The number in `dkimg:N` references of a text (`![](dkimg:3)`, any alt text), found in order, and the text without them.
fn takeImageRefs(arena: Allocator, s: []const u8, refs: *std.ArrayList(u32)) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, s, "](dkimg:") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, s, pos, "![")) |at| {
        const close = std.mem.indexOfPos(u8, s, at + 2, "](") orelse break;
        if (!std.mem.startsWith(u8, s[close..], "](dkimg:") or std.mem.indexOfScalar(u8, s[at..close], '\n') != null) {
            try out.appendSlice(arena, s[pos .. at + 2]);
            pos = at + 2;
            continue;
        }
        const paren = std.mem.indexOfScalarPos(u8, s, close, ')') orelse break;
        const num = std.fmt.parseInt(u32, s[close + "](dkimg:".len .. paren], 10) catch {
            try out.appendSlice(arena, s[pos .. at + 2]);
            pos = at + 2;
            continue;
        };
        try refs.append(arena, num);
        try out.appendSlice(arena, s[pos..at]);
        pos = paren + 1;
    }
    try out.appendSlice(arena, s[pos..]);
    return std.mem.trim(u8, out.items, " \t\r\n");
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
            var refs: std.ArrayList(u32) = .empty;
            b.text = try withoutFormFeeds(arena, try takeImageRefs(arena, try withoutInlineImages(arena, trimmed), &refs));
            b.images = refs.items;
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

const Piece = struct { start: usize, end: usize, text: []const u8, page: ?u32, path: []const []const u8, heading: bool, images: []const u32 = &.{} };

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
            if (b.text.len == 0 and b.images.len == 0) continue;
            if (b.text.len <= max) {
                try pieces.append(arena, .{ .start = b.start, .end = b.end, .text = b.text, .page = b.page, .path = b.path, .heading = false, .images = b.images });
            } else {
                var parts: std.ArrayList([]const u8) = .empty;
                try splitLong(arena, b.text, max, &parts);
                for (parts.items, 0..) |p, part_no| {
                    // The span of a part is found in the original block; images cut out make it approximate,
                    // so fall back to the whole block's span.
                    const at = std.mem.indexOf(u8, text[b.start..b.end], p[0..@min(p.len, 40)]);
                    const s = if (at) |a| b.start + a else b.start;
                    try pieces.append(arena, .{ .start = s, .end = @min(s + p.len, b.end), .text = p, .page = b.page, .path = b.path, .heading = false, .images = if (part_no == 0) b.images else &.{} });
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
            const add = if (p.text.len == 0) 0 else p.text.len + 2;
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
        var imgs: std.ArrayList(u32) = .empty;
        for (pieces.items[i..j], i..) |p, k| {
            try imgs.appendSlice(arena, p.images);
            if (p.text.len == 0) continue;
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
            .images = imgs.items,
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

/// Common English words that carry no meaning for finding a passage; used only to shape a question into a search.
const question_stop_words = [_][]const u8{
    "a", "about", "after", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "been", "before", "being", "but", "by", "can", "could", "did", "do", "does", "doing", "done", "each", "for", "from", "had", "has", "have", "he", "her", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its", "me", "my", "no", "not", "of", "on", "or", "our", "she", "should", "so", "some", "such", "than", "that", "the", "their", "them", "then", "there", "these", "they", "this", "those", "to", "us", "was", "we", "were", "what", "when", "where", "which", "who", "whom", "why", "will", "with", "would", "you", "your",
};

pub fn isQuestionStopWord(word: []const u8) bool {
    return isQuestionStop(word);
}

fn isQuestionStop(word: []const u8) bool {
    var buf: [16]u8 = undefined;
    if (word.len > buf.len) return false;
    const low = std.ascii.lowerString(&buf, word);
    for (question_stop_words) |s| if (std.mem.eql(u8, s, low)) return true;
    return false;
}

/// The search used to find candidate documents for a question. A question in plain words ("What did the ravens of
/// Odin do each day?") is turned into its meaningful words joined by OR, so that a document need not contain every
/// word of the question; ranking then favours those with more of the rarer ones. A query that already uses the
/// query language (quotes, OR, NOT, a minus, parentheses, a `field:`) is left as written, and so is one that would
/// be left with no words.
pub fn candidateQuery(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, text, "\"():-*~+") != null) return text;
    var out: std.ArrayList(u8) = .empty;
    var seen_words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,.;!?'`[]{}<>=/\\|&^%$#@_");
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "OR") or std.mem.eql(u8, w, "AND") or std.mem.eql(u8, w, "NOT")) return text;
        if (w.len < 2 or isQuestionStop(w)) continue;
        var dup = false;
        for (seen_words.items) |x| if (std.ascii.eqlIgnoreCase(x, w)) {
            dup = true;
        };
        if (dup) continue;
        if (seen_words.items.len >= 16) break;
        try seen_words.append(arena, w);
        if (out.items.len > 0) try out.appendSlice(arena, " OR ");
        try out.appendSlice(arena, w);
    }
    if (out.items.len == 0) return text;
    return out.items;
}

/// A document address without its extension: the same work in several file formats has the same stem.
pub fn stemOf(url: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse 0;
    const dot = std.mem.lastIndexOfScalar(u8, url, '.') orelse return url;
    return if (dot > slash) url[0..dot] else url;
}

/// How well a format keeps a work's structure; lower is better. Used to keep one copy of a work that exists in
/// several formats.
pub fn formatRank(url: []const u8) u8 {
    const dot = std.mem.lastIndexOfScalar(u8, url, '.') orelse return 9;
    const ext = url[dot + 1 ..];
    const order = [_][]const u8{ "md", "html", "htm", "epub", "docx", "odt", "txt", "pdf" };
    for (order, 0..) |o, i| if (std.ascii.eqlIgnoreCase(ext, o)) return @intCast(i);
    return 8;
}

const testing = std.testing;

fn textsOf(arena: Allocator, cs: []const Chunk) ![]const []const u8 {
    const out = try arena.alloc([]const u8, cs.len);
    for (cs, out) |c, *o| o.* = c.text;
    return out;
}

test "inline pictures become numbered references, can be fetched by number, and travel with their chunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = "# Folk\n\nIntro.\n\n![Image](data:image/png;base64,iVBORw0KGgo=)\n\nCaption of the first picture.\n\n## More\n\n![](data:image/jpeg;base64,/9j/4AAQ)\n\nEnd.";
    const slim = try replaceInlineImages(a, file);
    try testing.expectEqualStrings("# Folk\n\nIntro.\n\n![](dkimg:0)\n\nCaption of the first picture.\n\n## More\n\n![](dkimg:1)\n\nEnd.", slim);
    try testing.expectEqual(slim.ptr, (try replaceInlineImages(a, slim)).ptr); // nothing left to replace
    const first = (try nthInlineImage(a, file, 0)).?;
    try testing.expectEqualStrings("image/png", first.mime);
    try testing.expectEqualStrings("\x89PNG\r\n\x1a\n", first.bytes);
    try testing.expectEqualStrings("image/jpeg", (try nthInlineImage(a, file, 1)).?.mime);
    try testing.expect((try nthInlineImage(a, file, 2)) == null);
    try testing.expect((try nthInlineImage(a, "![](data:image/svg+xml;base64,PHN2Zz4=)", 0)) == null); // not a type to serve
    // The chunk holding the first picture lists it, and its text has no markup.
    const cs = try chunk(a, slim, .{ .chunk_chars = 200, .overlap = 0 });
    var found0 = false;
    var found1 = false;
    for (cs) |c| {
        try testing.expect(std.mem.indexOf(u8, c.text, "dkimg") == null);
        for (c.images) |n| {
            if (n == 0) {
                found0 = true;
                try testing.expect(std.mem.indexOf(u8, c.text, "Intro") != null or std.mem.indexOf(u8, c.text, "Caption") != null);
            }
            if (n == 1) found1 = true;
        }
    }
    try testing.expect(found0 and found1);
}

test "a question becomes its meaningful words joined by OR; query-language queries are left alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ravens OR Odin OR day", try candidateQuery(a, "What did the ravens of Odin do each day?"));
    try testing.expectEqualStrings("ravens", try candidateQuery(a, "ravens ravens the"));
    try testing.expectEqualStrings("\"two words\" more", try candidateQuery(a, "\"two words\" more"));
    try testing.expectEqualStrings("a OR b", try candidateQuery(a, "a OR b"));
    try testing.expectEqualStrings("odin -thor", try candidateQuery(a, "odin -thor"));
    try testing.expectEqualStrings("title:odin ravens", try candidateQuery(a, "title:odin ravens"));
    try testing.expectEqualStrings("the of", try candidateQuery(a, "the of")); // nothing meaningful: as typed
    try testing.expectEqualStrings("file:///b/Book", stemOf("file:///b/Book.pdf"));
    try testing.expectEqualStrings("https://x.org/a.b/c", stemOf("https://x.org/a.b/c"));
    try testing.expect(formatRank("x.md") < formatRank("x.epub") and formatRank("x.epub") < formatRank("x.pdf") and formatRank("x.pdf") < formatRank("x.zzz"));
}

test "form feeds count pages and are not part of the chunk text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try chunk(a, "Page one text.\n\n\x0c\n\nPage two text.\n\n\x0c\n\nPage three.", .{ .chunk_chars = 200, .overlap = 0 });
    try testing.expect(cs.len >= 1);
    for (cs) |c| try testing.expect(std.mem.indexOfScalar(u8, c.text, 0x0c) == null);
    try testing.expectEqual(@as(?u32, 1), cs[0].page);
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
