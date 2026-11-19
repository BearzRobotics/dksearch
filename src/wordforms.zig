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

/// The most forms of a word one query asks for (the typed word first, then the commonest forms in the index).
pub const max_forms = 8;

/// Endings that make another form of a word: "program" + "ming", "programs", "programmers", "comprehension"s, but not
/// "comprehensive", "programmatic" or "progress".
const endings = [_][]const u8{ "", "s", "es", "e", "ed", "d", "ing", "ings", "er", "ers", "or", "ors", "ion", "ions", "ation", "ations", "ly", "ment", "ments", "ness", "y", "ies", "ied", "al", "ally" };

/// Whether `term` (a word of the index, lower case) is another form of the word with this `stem`: the stem followed by an
/// ending from the list, with the last letter doubled where the ending was added ("programm" + "ing").
pub fn isForm(stem: []const u8, term: []const u8) bool {
    if (term.len < stem.len or !std.mem.startsWith(u8, term, stem)) return false;
    const rest = term[stem.len..];
    for (endings) |e| if (std.mem.eql(u8, rest, e)) return true;
    if (rest.len > 0 and stem.len > 0 and rest[0] == stem[stem.len - 1] and !isVowel(rest[0])) {
        for (endings[4..]) |e| if (e.len > 0 and std.mem.eql(u8, rest[1..], e)) return true;
    }
    return false;
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

test "other forms are the stem with an ending; words that only start the same are not" {
    try testing.expect(isForm("program", "program") and isForm("program", "programs") and isForm("program", "programming"));
    try testing.expect(isForm("program", "programmer") and isForm("program", "programmers") and isForm("program", "programmed"));
    try testing.expect(isForm("comprehens", "comprehension") and isForm("comprehens", "comprehensions"));
    try testing.expect(!isForm("comprehens", "comprehensive") and !isForm("program", "programmatic") and !isForm("program", "progress"));
    try testing.expect(isForm("schedul", "schedule") and isForm("schedul", "scheduling") and isForm("schedul", "scheduler"));
    try testing.expect(!isForm("program", "prog") and !isForm("start", "starting-point") and !isForm("start", "startup"));
}
