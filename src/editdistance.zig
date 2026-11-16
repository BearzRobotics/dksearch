//! Edit distance between two words for typo tolerance: the number of insertions, deletions, substitutions and
//! swaps of neighbouring letters (optimal string alignment), counted on UTF-8 characters, stopping as soon as it
//! is certain to exceed a limit.

const std = @import("std");

pub const max_len = 48;

/// Decodes `s` into code points (at most `max_len`); null if it is longer.
fn decode(s: []const u8, out: *[max_len]u21) ?usize {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return null).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n == max_len) return null;
        out[n] = cp;
        n += 1;
    }
    return n;
}

/// The distance between `a` and `b` if it is at most `limit`, else null (also null for text that is not valid UTF-8
/// or longer than `max_len` characters).
pub fn within(a: []const u8, b: []const u8, limit: u8) ?u8 {
    var ab: [max_len]u21 = undefined;
    var bb: [max_len]u21 = undefined;
    const n = decode(a, &ab) orelse return null;
    const m = decode(b, &bb) orelse return null;
    const diff = if (n > m) n - m else m - n;
    if (diff > limit) return null;
    // Three rows are enough for swaps (distance of the row before the previous one).
    var prev2: [max_len + 1]u8 = @splat(0);
    var prev: [max_len + 1]u8 = undefined;
    var cur: [max_len + 1]u8 = undefined;
    for (0..m + 1) |j| prev[j] = @intCast(j);
    for (1..n + 1) |i| {
        cur[0] = @intCast(i);
        var row_min: u8 = cur[0];
        for (1..m + 1) |j| {
            const cost: u8 = if (ab[i - 1] == bb[j - 1]) 0 else 1;
            var v = @min(@min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            if (i > 1 and j > 1 and ab[i - 1] == bb[j - 2] and ab[i - 2] == bb[j - 1]) v = @min(v, prev2[j - 2] + 1);
            cur[j] = v;
            row_min = @min(row_min, v);
        }
        if (row_min > limit) return null;
        prev2 = prev;
        prev = cur;
    }
    const d = prev[m];
    return if (d <= limit) d else null;
}

const testing = std.testing;

test "distances: substitution, insertion, deletion and swap each cost one" {
    try testing.expectEqual(@as(?u8, 0), within("receive", "receive", 2));
    try testing.expectEqual(@as(?u8, 1), within("recieve", "receive", 2)); // a swap
    try testing.expectEqual(@as(?u8, 1), within("recive", "receive", 2)); // a missing letter
    try testing.expectEqual(@as(?u8, 1), within("receiive", "receive", 2)); // an extra one
    try testing.expectEqual(@as(?u8, 1), within("recoive", "receive", 2)); // a wrong one
    try testing.expectEqual(@as(?u8, 2), within("elefant", "elephant", 2));
    try testing.expectEqual(@as(?u8, null), within("elefant", "elephant", 1));
    try testing.expectEqual(@as(?u8, null), within("cat", "elephant", 2)); // lengths too far apart
    try testing.expectEqual(@as(?u8, 1), within("café", "cafe", 1)); // a character, not a byte
    try testing.expectEqual(@as(?u8, null), within("\xff\xfe", "ab", 2)); // not UTF-8
    try testing.expectEqual(@as(?u8, 0), within("", "", 1));
    try testing.expectEqual(@as(?u8, 2), within("ab", "", 2));
}
