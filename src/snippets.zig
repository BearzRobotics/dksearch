//! More than one excerpt per result: further passages of a document that contain the query's words, away from the
//! excerpt the index already gave (docs/decisions/0045). Taken from the stored text, so they need the content store.

const std = @import("std");
const Allocator = std.mem.Allocator;
const search = @import("search.zig");

/// Longest text looked through for one document; beyond it the document is not searched for more excerpts.
pub const max_text_bytes: usize = 1024 * 1024;
const half_window: usize = 90;

/// The plain words of a query worth marking: letters and digits, two or more, without the words of operators and
/// without anything excluded with `-` or written as `field:value`.
pub fn queryTerms(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |raw| {
        if (raw[0] == '-' or std.mem.indexOfScalar(u8, raw, ':') != null) continue;
        if (std.mem.eql(u8, raw, "AND") or std.mem.eql(u8, raw, "OR") or std.mem.eql(u8, raw, "NOT")) continue;
        var start: usize = 0;
        while (start < raw.len) {
            while (start < raw.len and !wordByte(raw[start])) start += 1;
            var end = start;
            while (end < raw.len and wordByte(raw[end])) end += 1;
            if (end - start >= 2) try out.append(arena, try std.ascii.allocLowerString(arena, raw[start..end]));
            start = end;
        }
        if (out.items.len >= 12) break;
    }
    return out.items;
}

fn wordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// A word of the query, to be found in a text.
pub const Term = struct {
    /// Lower case.
    text: []const u8,
    /// Matches every word that begins with it.
    prefix: bool = false,
};

/// The words in an excerpt, as FTS5's own `snippet()` makes (a window of 16 words).
pub const window_words = 16;
/// How much of a text is looked through for the best excerpt.
pub const max_scan_bytes: usize = 2 * 1024 * 1024;
const max_terms = 16;
const max_windows = 50_000;
const context_words = 4;

const Word = struct { start: u32, end: u32, term: i8 };

/// The best excerpt of `text` for `terms`, in one pass over the text (time grows with the length of the text, not with how
/// often a word occurs, which SQLite's own `snippet()` cannot promise: it is slow on a very common word in a long
/// document). The best window of `window_words` words is the one with the most different query words, then the most
/// occurrences, the earliest on a tie, with a few words of context before it. Matches are bracketed with `search.match_start`
/// and `search.match_end`; `…` marks a cut; runs of white space become one space. With no match the text starts the
/// excerpt. Null for a text with no words.
pub fn bestExcerpt(arena: Allocator, text_in: []const u8, terms: []const Term) Allocator.Error!?[]const u8 {
    var text = text_in[0..@min(text_in.len, max_scan_bytes)];
    while (text.len > 0 and text.len < text_in.len and (text[text.len - 1] & 0xC0) == 0x80) text = text[0 .. text.len - 1];
    if (text.len == 0) return null;
    const nterms = @min(terms.len, max_terms);

    // The words of the text, each with the query word it is (or none).
    var words: std.ArrayList(Word) = .empty;
    var matches: std.ArrayList(u32) = .empty; // indexes into `words` of the matched ones
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !wordByte(text[i])) i += 1;
        if (i >= text.len) break;
        const start = i;
        while (i < text.len and wordByte(text[i])) i += 1;
        var term: i8 = -1;
        const len = i - start;
        if (len <= 48) {
            var buf: [48]u8 = undefined;
            const lower = std.ascii.lowerString(buf[0..len], text[start..i]);
            for (terms[0..nterms], 0..) |t, k| {
                const hit = if (t.prefix) std.mem.startsWith(u8, lower, t.text) else std.mem.eql(u8, lower, t.text);
                if (hit) {
                    term = @intCast(k);
                    break;
                }
            }
        }
        if (term >= 0) try matches.append(arena, @intCast(words.items.len));
        try words.append(arena, .{ .start = @intCast(start), .end = @intCast(i), .term = term });
    }
    if (words.items.len == 0) return null;

    // The best window: it starts at a matched word.
    var first: usize = 0;
    var best_score: u32 = 0;
    const considered = @min(matches.items.len, max_windows);
    for (0..considered) |mi| {
        const w0 = matches.items[mi];
        var mask: u16 = 0;
        var count: u32 = 0;
        var j = mi;
        while (j < matches.items.len and matches.items[j] < w0 + window_words) : (j += 1) {
            mask |= @as(u16, 1) << @intCast(words.items[matches.items[j]].term);
            count += 1;
        }
        const score = @as(u32, @popCount(mask)) * 1000 + count;
        if (score > best_score) {
            best_score = score;
            first = w0;
        }
    }
    const lead = @min(first, context_words);
    const ws: usize = first - lead;
    const we: usize = @min(ws + window_words - 1, words.items.len - 1);

    var out: std.ArrayList(u8) = .empty;
    if (ws > 0) try out.appendSlice(arena, "…");
    // Matched words with only white space between them share one bracket, as FTS5 brackets a whole matched phrase.
    var open = false;
    var k = ws;
    while (k <= we) : (k += 1) {
        const w = words.items[k];
        const gap: []const u8 = if (k > ws) text[words.items[k - 1].end..w.start] else "";
        var only_space = gap.len > 0;
        for (gap) |b| if (!std.ascii.isWhitespace(b)) {
            only_space = false;
        };
        if (open and !(w.term >= 0 and only_space)) {
            try out.appendSlice(arena, search.match_end);
            open = false;
        }
        if (k > ws) try appendGap(arena, &out, gap);
        if (w.term >= 0 and !open) {
            try out.appendSlice(arena, search.match_start);
            open = true;
        }
        try out.appendSlice(arena, text[w.start..w.end]);
    }
    if (open) try out.appendSlice(arena, search.match_end);
    if (we + 1 < words.items.len) try out.appendSlice(arena, "…");
    return out.items;
}

/// The text between two words: punctuation kept, runs of white space made one space.
fn appendGap(arena: Allocator, out: *std.ArrayList(u8), gap: []const u8) Allocator.Error!void {
    var in_space = false;
    for (gap) |b| {
        if (std.ascii.isWhitespace(b)) {
            if (!in_space) try out.append(arena, ' ');
            in_space = true;
        } else {
            in_space = false;
            try out.append(arena, b);
        }
    }
    if (gap.len == 0) try out.append(arena, ' ');
}

/// Up to `max` excerpts of `text`, each around a place where one of `terms` occurs, at least `2 * half_window` bytes
/// apart from each other and from `skip` (the excerpt already shown, with its markers; null for none). Matches are
/// bracketed with `search.match_start`/`match_end` like every snippet. Best-first is not attempted: they come in the
/// order of the text.
pub fn more(arena: Allocator, text: []const u8, terms: []const []const u8, skip: ?[]const u8, max: usize) Allocator.Error![]const []const u8 {
    if (max == 0 or terms.len == 0 or text.len == 0 or text.len > max_text_bytes) return &.{};
    const lower = try std.ascii.allocLowerString(arena, text);
    // Where the excerpt already shown sits in the text (its first words, without markers).
    var taken: std.ArrayList(usize) = .empty;
    if (skip) |s| if (firstPlain(arena, s)) |plain| if (std.mem.indexOf(u8, text, plain)) |at| try taken.append(arena, at + plain.len / 2);
    var out: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (out.items.len < max and pos < lower.len) {
        // The next occurrence of any term at or after `pos`.
        var best: ?usize = null;
        for (terms) |t| if (std.mem.indexOfPos(u8, lower, pos, t)) |at| {
            if (best == null or at < best.?) best = at;
        };
        const at = best orelse break;
        var clash = false;
        for (taken.items) |c| if (@max(at, c) - @min(at, c) < 2 * half_window) {
            clash = true;
        };
        if (clash) {
            pos = at + 1;
            continue;
        }
        try taken.append(arena, at);
        try out.append(arena, try window(arena, text, lower, terms, at));
        pos = at + half_window;
    }
    return out.items;
}

fn firstPlain(arena: Allocator, snippet: []const u8) ?[]const u8 {
    // The longest run between markers or ellipses, which is plain text of the document.
    var best: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, snippet, search.match_start ++ search.match_end ++ "\u{2026}");
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \n");
        if (p.len > best.len) best = p;
    }
    if (best.len < 12) return null;
    return arena.dupe(u8, best) catch null;
}

fn window(arena: Allocator, text: []const u8, lower: []const u8, terms: []const []const u8, at: usize) Allocator.Error![]const u8 {
    var lo = at -| half_window;
    var hi = @min(text.len, at + half_window);
    // Whole characters and, where there is a space close by, whole words.
    while (lo > 0 and (text[lo] & 0xC0) == 0x80) lo -= 1;
    while (hi < text.len and (text[hi] & 0xC0) == 0x80) hi += 1;
    if (lo > 0) if (std.mem.indexOfScalarPos(u8, text, lo, ' ')) |sp| if (sp < at) {
        lo = sp + 1;
    };
    if (hi < text.len) if (std.mem.lastIndexOfScalar(u8, text[at..hi], ' ')) |sp| if (at + sp > at) {
        hi = at + sp;
    };
    var out: std.ArrayList(u8) = .empty;
    if (lo > 0) try out.appendSlice(arena, "\u{2026}");
    var i = lo;
    while (i < hi) {
        var matched: usize = 0;
        for (terms) |t| if (std.mem.startsWith(u8, lower[i..hi], t) and t.len > matched) {
            matched = t.len;
        };
        if (matched > 0) {
            try out.appendSlice(arena, search.match_start);
            try out.appendSlice(arena, text[i .. i + matched]);
            try out.appendSlice(arena, search.match_end);
            i += matched;
        } else {
            const b = text[i];
            // Control bytes (and so a stray marker byte) never enter an excerpt.
            if (b >= 0x20 or b == '\t') try out.append(arena, if (b == '\n' or b == '\t') ' ' else b);
            i += 1;
        }
    }
    if (hi < text.len) try out.appendSlice(arena, "\u{2026}");
    return out.items;
}

const testing = std.testing;

test "query terms: plain words only" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const t = try queryTerms(ar.allocator(), "Odin AND \"two ravens\" -wolf ext:pdf a (huginn OR muninn)*");
    try testing.expectEqual(@as(usize, 5), t.len);
    try testing.expectEqualStrings("odin", t[0]);
    try testing.expectEqualStrings("two", t[1]);
    try testing.expectEqualStrings("ravens", t[2]);
    try testing.expectEqualStrings("huginn", t[3]);
    try testing.expectEqualStrings("muninn", t[4]);
}

test "further excerpts come from other places of the text, away from the one already shown" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "The raven is a bird of myth. ");
    for (0..40) |_| try text.appendSlice(a, "Filler about harvests and the weather in the valley. ");
    try text.appendSlice(a, "Another RAVEN appears at the end of the tale, black as night. ");
    for (0..40) |_| try text.appendSlice(a, "More filler about rivers and hills and roads. ");
    try text.appendSlice(a, "A last raven sits on the roof.");
    const terms = [_][]const u8{"raven"};
    const shown = "The \x02raven\x03 is a bird of myth. Filler about harvests";
    const got = try more(a, text.items, &terms, shown, 3);
    try testing.expectEqual(@as(usize, 2), got.len); // the first place is the shown one; the other two are new
    try testing.expect(std.mem.indexOf(u8, got[0], "\x02RAVEN\x03") != null); // the text's own spelling, marked
    try testing.expect(std.mem.indexOf(u8, got[0], "black as night") != null);
    try testing.expect(std.mem.indexOf(u8, got[1], "roof") != null);
    for (got) |g| try testing.expect(g.len < 260);
    // Nothing to find, nothing asked, or too large.
    try testing.expectEqual(@as(usize, 0), (try more(a, text.items, &.{"zzz"}, null, 3)).len);
    try testing.expectEqual(@as(usize, 0), (try more(a, text.items, &terms, null, 0)).len);
    try testing.expectEqual(@as(usize, 1), (try more(a, text.items, &terms, null, 1)).len);
}

test "excerpts keep whole characters and drop control bytes" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = "caf\u{e9} \u{e9}t\u{e9} \x02fake\x03 marker and the word odin in the middle of \u{4e16}\u{754c} text";
    const got = try more(a, text, &.{"odin"}, null, 2);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(std.unicode.utf8ValidateSlice(got[0]));
    try testing.expect(std.mem.indexOf(u8, got[0], "\x02odin\x03") != null);
    try testing.expect(std.mem.indexOf(u8, got[0], "fake") != null and std.mem.indexOf(u8, got[0], "\x02fake") == null);
}

test "bestExcerpt: the window with the most different query words, marked, with context; no match starts the text; cost does not depend on how common the word is" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = "Intro words that mention linux once. Long filler about gardens and tea and cake for a while, nothing relevant here at all. " ++
        "Then the real part: nftables and linux firewall rules live in the kernel, said the guide.";
    const terms = [_]Term{ .{ .text = "linux" }, .{ .text = "firewall" }, .{ .text = "nftables" } };
    const got = (try bestExcerpt(a, text, &terms)).?;
    // "linux firewall" follow each other, so they share one bracket; "nftables" stands alone.
    try testing.expect(std.mem.indexOf(u8, got, "\x02nftables\x03") != null and std.mem.indexOf(u8, got, "\x02linux firewall\x03") != null);
    try testing.expect(std.mem.startsWith(u8, got, "…"));
    try testing.expect(std.mem.indexOf(u8, got, "gardens") == null);
    // A prefix term, case folded, and no match: the start of the text.
    const pre = (try bestExcerpt(a, "Kernels and kernel modules", &.{.{ .text = "kern", .prefix = true }})).?;
    try testing.expect(std.mem.indexOf(u8, pre, "\x02Kernels\x03") != null);
    const none = (try bestExcerpt(a, "alpha beta gamma", &.{.{ .text = "zzz" }})).?;
    try testing.expectEqualStrings("alpha beta gamma", none);
    try testing.expect((try bestExcerpt(a, "  ... ", &terms)) == null);
    // White space is collapsed and a long text is cut with an ellipsis.
    const long = (try bestExcerpt(a, "one\n\n  two   three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen", &.{.{ .text = "two" }})).?;
    try testing.expect(std.mem.indexOf(u8, long, "\n") == null and std.mem.endsWith(u8, long, "…"));
    // A very common word in a long text: linear, and a window still comes out.
    const big = try a.alloc(u8, 1500 * 1000);
    var p: usize = 0;
    while (p + 4 <= big.len) : (p += 4) @memcpy(big[p..][0..4], "in c");
    // (A quadratic algorithm would not finish this in reasonable time: 750,000 matches.)
    const c = (try bestExcerpt(a, big, &.{ .{ .text = "in" }, .{ .text = "c" } })).?;
    try testing.expect(c.len > 10);
}

test "bestExcerpt: matched words that follow each other share one bracket, as a phrase does" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = (try bestExcerpt(a, "it is a truth universally acknowledged", &.{ .{ .text = "truth" }, .{ .text = "universally" } })).?;
    try testing.expect(std.mem.indexOf(u8, got, "\x02truth universally\x03") != null);
    const apart = (try bestExcerpt(a, "truth, and then universally", &.{ .{ .text = "truth" }, .{ .text = "universally" } })).?;
    try testing.expect(std.mem.indexOf(u8, apart, "\x02truth\x03,") != null and std.mem.indexOf(u8, apart, "\x02universally\x03") != null);
}
