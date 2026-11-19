//! Word forms (docs/decisions/0063): a person who searches for "program" means "programming" and "programs" too. Stemming the
//! whole index would answer that but needs a rebuild and makes excerpts slow, so the search asks for the word and for words that
//! begin with its stem instead (`"program" OR "program"*`). This file finds the stem: a plain English suffix strip, not a
//! linguist's; a word it does not know how to shorten is searched as it is.

const std = @import("std");

pub const max_word = 40;
/// A stem shorter than this is too broad a prefix ("star" is also start, starch and stark).
pub const min_stem = 5;

/// The prefix to ask for besides `word`, lower case in `buf`; null when `word` is not a plain English word of at least five
/// letters or its stem would be too short.
pub fn stemPrefix(buf: *[max_word]u8, word: []const u8) ?[]const u8 {
    if (word.len < min_stem or word.len > max_word) return null;
    for (word, 0..) |ch, i| {
        if (!std.ascii.isAlphabetic(ch)) return null;
        buf[i] = std.ascii.toLower(ch);
    }
    var n = word.len;
    const suffixes = [_][]const u8{ "ations", "ation", "ments", "ment", "ness", "ions", "ings", "ers", "ies", "ied", "ing", "ion", "ly", "er", "ed", "es", "s" };
    for (suffixes) |suf| {
        if (n >= suf.len + min_stem - 1 and std.mem.endsWith(u8, buf[0..n], suf)) {
            // "ss", "us" and "is" end a word that is not a plural ("class", "bonus", "analysis").
            if (std.mem.eql(u8, suf, "s") and n >= 2 and (buf[n - 2] == 's' or buf[n - 2] == 'u' or buf[n - 2] == 'i')) break;
            n -= suf.len;
            break;
        }
    }
    // A doubled consonant came from adding the suffix (programm-ing, runn-ing).
    if (n >= 2 and buf[n - 1] == buf[n - 2] and !isVowel(buf[n - 1]) and buf[n - 1] != 'l' and buf[n - 1] != 's' and buf[n - 1] != 'z') n -= 1;
    // A final e does not survive a suffix (schedul-ing): the prefix leaves it off, so "schedule" finds "scheduling".
    if (n > min_stem and buf[n - 1] == 'e') n -= 1;
    if (n < min_stem) return null;
    return buf[0..n];
}

fn isVowel(c: u8) bool {
    return switch (c) {
        'a', 'e', 'i', 'o', 'u' => true,
        else => false,
    };
}

const testing = std.testing;

fn stemOf(word: []const u8) ?[]const u8 {
    const S = struct {
        var buf: [max_word]u8 = undefined;
    };
    return stemPrefix(&S.buf, word);
}

test "a word is shortened to the stem its other forms begin with" {
    try testing.expectEqualStrings("program", stemOf("program").?);
    try testing.expectEqualStrings("program", stemOf("programming").?);
    try testing.expectEqualStrings("program", stemOf("programmers").?);
    try testing.expectEqualStrings("start", stemOf("starters").?);
    try testing.expectEqualStrings("start", stemOf("started").?);
    try testing.expectEqualStrings("schedul", stemOf("schedule").?);
    try testing.expectEqualStrings("schedul", stemOf("scheduling").?);
    try testing.expectEqualStrings("librar", stemOf("libraries").?);
    try testing.expectEqualStrings("kernel", stemOf("Kernels").?);
    try testing.expectEqualStrings("comprehens", stemOf("comprehension").?);
    try testing.expectEqualStrings("class", stemOf("classes").?[0..5]);
}

test "short words, words that are not plain letters and words with nothing to strip are left alone" {
    try testing.expect(stemOf("c") == null and stemOf("list") == null and stemOf("lists") == null and stemOf("run") == null);
    try testing.expect(stemOf("c++") == null and stemOf("python3") == null and stemOf("naïve") == null);
    const long: [50]u8 = @splat('a');
    try testing.expect(stemOf(&long) == null);
    // Not plurals.
    try testing.expectEqualStrings("class", stemOf("class").?);
    try testing.expectEqualStrings("analysis", stemOf("analysis").?);
}
