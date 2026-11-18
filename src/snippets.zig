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
