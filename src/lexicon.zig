//! Stop words and synonyms, applied to a search when it is read, never to the index (so changing
//! the files needs no rebuild).
//!
//! - A stop word file holds one word per line. Those words are left out of searches (`the`, `of`),
//!   unless that would leave nothing to search for. Words inside quotes are never dropped.
//! - A synonym file holds one group per line, the members separated by commas
//!   (`car, auto, automobile`). A plain word of the query matches any member of its group. Members
//!   may be several words, which are then matched as a phrase.
//!
//! Lines starting with `#` and empty lines are ignored. Words are compared without regard to the
//! case of their ASCII letters. Both lists are small by design (bounded below).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_stop_words = 5000;
pub const max_synonym_groups = 5000;
pub const max_group_members = 16;
pub const max_word_bytes = 64;

pub const Lexicon = struct {
    stops: std.StringHashMapUnmanaged(void) = .empty,
    /// Lowercased word -> the other members of its groups (every group a word belongs to, merged).
    synonyms: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    pub fn isStop(self: *const Lexicon, word: []const u8) bool {
        var buf: [max_word_bytes]u8 = undefined;
        if (word.len == 0 or word.len > buf.len) return false;
        return self.stops.contains(std.ascii.lowerString(&buf, word));
    }

    /// The words that mean the same as `word` (not including it), or none.
    pub fn synonymsOf(self: *const Lexicon, word: []const u8) []const []const u8 {
        var buf: [max_word_bytes]u8 = undefined;
        if (word.len == 0 or word.len > buf.len) return &.{};
        return self.synonyms.get(std.ascii.lowerString(&buf, word)) orelse &.{};
    }

    pub fn isEmpty(self: *const Lexicon) bool {
        return self.stops.count() == 0 and self.synonyms.count() == 0;
    }
};

pub const ParseError = error{ OutOfMemory, TooMany, BadLine };

pub const Problem = struct { line: usize = 0 };

fn lowered(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, s.len);
    return std.ascii.lowerString(out, s);
}

/// Adds the stop words in `text`. Everything is allocated from `arena`, which must outlive the lexicon.
pub fn addStopWords(arena: Allocator, lex: *Lexicon, text: []const u8, problem: *Problem) ParseError!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // A line may hold several words separated by spaces or commas.
        var it = std.mem.tokenizeAny(u8, line, " \t,");
        while (it.next()) |w| {
            if (w.len > max_word_bytes) {
                problem.line = n;
                return error.BadLine;
            }
            if (lex.stops.count() >= max_stop_words) return error.TooMany;
            try lex.stops.put(arena, try lowered(arena, w), {});
        }
    }
}

/// Adds the synonym groups in `text`.
pub fn addSynonyms(arena: Allocator, lex: *Lexicon, text: []const u8, problem: *Problem) ParseError!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    var groups: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var members: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, line, ',');
        while (it.next()) |m_raw| {
            const m = std.mem.trim(u8, m_raw, " \t");
            if (m.len == 0) continue;
            if (m.len > max_word_bytes or std.mem.indexOfAny(u8, m, "\"\x00") != null) {
                problem.line = n;
                return error.BadLine;
            }
            try members.append(arena, try lowered(arena, m));
        }
        if (members.items.len < 2 or members.items.len > max_group_members) {
            problem.line = n;
            return error.BadLine;
        }
        groups += 1;
        if (groups > max_synonym_groups) return error.TooMany;
        // Every member gets the others (merged with what it already had from other groups).
        for (members.items, 0..) |m, i| {
            var merged: std.ArrayList([]const u8) = .empty;
            if (lex.synonyms.get(m)) |old| try merged.appendSlice(arena, old);
            for (members.items, 0..) |other, j| {
                if (i == j) continue;
                var seen = false;
                for (merged.items) |x| if (std.mem.eql(u8, x, other)) {
                    seen = true;
                };
                if (!seen) try merged.append(arena, other);
            }
            // Keep the expansion of one word modest: a long OR is slow and rarely wanted.
            if (merged.items.len > 2 * max_group_members) merged.items.len = 2 * max_group_members;
            try lex.synonyms.put(arena, m, merged.items);
        }
    }
}

const testing = std.testing;

test "stop words: case-insensitive, several to a line, comments ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lex: Lexicon = .{};
    var p: Problem = .{};
    try addStopWords(arena.allocator(), &lex, "# articles\nthe\nA, an\n\n  Of  \n", &p);
    try testing.expect(lex.isStop("the") and lex.isStop("THE") and lex.isStop("a") and lex.isStop("an") and lex.isStop("of"));
    try testing.expect(!lex.isStop("then") and !lex.isStop(""));
    const long: [100]u8 = @splat('x');
    try testing.expect(!lex.isStop(&long));
}

test "synonyms: groups work both ways, merge, and bad lines are reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lex: Lexicon = .{};
    var p: Problem = .{};
    try addSynonyms(a, &lex, "car, Auto, motor car\n# comment\nauto, automobile\n", &p);
    const car = lex.synonymsOf("CAR");
    try testing.expectEqual(@as(usize, 2), car.len);
    try testing.expectEqualStrings("auto", car[0]);
    try testing.expectEqualStrings("motor car", car[1]);
    const auto = lex.synonymsOf("auto"); // from two groups, merged without repeats
    try testing.expectEqual(@as(usize, 3), auto.len);
    try testing.expectEqual(@as(usize, 0), lex.synonymsOf("boat").len);
    try testing.expectError(error.BadLine, addSynonyms(a, &lex, "alone\n", &p));
    try testing.expectEqual(@as(usize, 1), p.line);
    try testing.expectError(error.BadLine, addSynonyms(a, &lex, "ok, fine\nsay \"hi\", hello\n", &p));
    try testing.expectEqual(@as(usize, 2), p.line);
}
