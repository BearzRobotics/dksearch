//! Similar documents (docs/decisions/0046): the words that set a document apart, to be searched for. A word counts
//! for more the more often the document uses it and the fewer documents have it at all.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Candidate = struct { word: []const u8, tf: u32 };

/// The most frequent words of `text` (lower case, 4 to 30 letters or digits, not only digits), at most `max`.
/// Only the first `max_scan` bytes are read.
pub fn candidates(arena: Allocator, text: []const u8, max: usize, max_scan: usize) Allocator.Error![]const Candidate {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    const t = text[0..@min(text.len, max_scan)];
    var i: usize = 0;
    while (i < t.len) {
        while (i < t.len and !isWord(t[i])) i += 1;
        const start = i;
        while (i < t.len and isWord(t[i])) i += 1;
        const w = t[start..i];
        if (w.len < 4 or w.len > 30 or allDigits(w)) continue;
        const lower = try std.ascii.allocLowerString(arena, w);
        const gop = try counts.getOrPut(arena, lower);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }
    var list: std.ArrayList(Candidate) = .empty;
    var it = counts.iterator();
    while (it.next()) |e| try list.append(arena, .{ .word = e.key_ptr.*, .tf = e.value_ptr.* });
    std.mem.sort(Candidate, list.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            if (a.tf != b.tf) return a.tf > b.tf;
            return std.mem.lessThan(u8, a.word, b.word);
        }
    }.lt);
    return list.items[0..@min(list.items.len, max)];
}

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}

fn allDigits(w: []const u8) bool {
    for (w) |b| if (!std.ascii.isDigit(b)) return false;
    return true;
}

/// The `k` best words by `tf * ln(docs / df)`, ignoring words that most documents have (`df` over a third of `docs`)
/// and words no other document has beyond this one. `df[i]` is the number of documents with `cands[i]`.
pub fn pick(arena: Allocator, cands: []const Candidate, df: []const u32, docs: u64, k: usize) Allocator.Error![]const []const u8 {
    const Scored = struct { word: []const u8, score: f64 };
    var list: std.ArrayList(Scored) = .empty;
    const n: f64 = @floatFromInt(@max(docs, 2));
    for (cands, df) |c, d| {
        if (d == 0) continue;
        if (@as(f64, @floatFromInt(d)) * 3.0 > n) continue;
        try list.append(arena, .{ .word = c.word, .score = @as(f64, @floatFromInt(c.tf)) * @log(n / @as(f64, @floatFromInt(d))) });
    }
    std.mem.sort(Scored, list.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.word, b.word);
        }
    }.lt);
    const out = try arena.alloc([]const u8, @min(k, list.items.len));
    for (out, list.items[0..out.len]) |*o, s| o.* = s.word;
    return out;
}

const testing = std.testing;

test "candidates are the frequent words, and the choice favours rare ones" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = "Raven raven RAVEN and the valley, the valley again; 12345 two ravens fly over the valley. Odin sees.";
    const c = try candidates(a, text, 10, 1 << 20);
    try testing.expectEqualStrings("raven", c[0].word);
    try testing.expectEqual(@as(u32, 3), c[0].tf);
    for (c) |x| try testing.expect(x.word.len >= 4 and !std.mem.eql(u8, x.word, "12345"));
    // "valley" is as frequent as "raven" in the text but in most documents, so it is dropped; "ravens" is rare.
    var df = try a.alloc(u32, c.len);
    for (c, df[0..]) |x, *d| d.* = if (std.mem.eql(u8, x.word, "valley")) 80 else if (std.mem.eql(u8, x.word, "raven")) 4 else 10;
    const picked = try pick(a, c, df, 100, 2);
    try testing.expectEqual(@as(usize, 2), picked.len);
    try testing.expectEqualStrings("raven", picked[0]);
    for (picked) |p| try testing.expect(!std.mem.eql(u8, p, "valley"));
    try testing.expectEqual(@as(usize, 0), (try pick(a, c, df, 100, 0)).len);
}
