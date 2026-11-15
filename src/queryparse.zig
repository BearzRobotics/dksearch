//! The query language of the search box, translated into an FTS5 MATCH
//! expression.
//!
//!     "kernel module"      exact phrase
//!     linux wayland        both words (AND is the default)
//!     linux AND wayland    both words, spelled out
//!     linux OR bsd         either word
//!     linux NOT android    linux, without android
//!     -android             the same, as a prefix on a word (needs a positive term)
//!     +linux               the word must be present (it is anyway; allowed for habit)
//!     (linux OR bsd) kernel   grouping
//!     comp*                words that start with "comp"
//!     compositor~          the word or one typo away from it (one edit)
//!     "window manager"~5   the words within five positions of each other
//!
//! `AND`, `OR` and `NOT` are operators only in capitals; in lower case they
//! are ordinary words, and any of them can be searched for literally by
//! quoting it. Everything the user types ends up inside a double-quoted FTS5
//! string, so column filters (`title:x`), `^`, `NEAR` and the other FTS5
//! operators cannot be written by hand: only the operators this module itself
//! emits reach SQLite. The parser is forgiving (a stray `)` is ignored, a
//! missing one is supplied, an unterminated quote runs to the end), and
//! bounded: 1024 bytes, 32 terms, nesting of 8, and a cap on what fuzzy
//! expansion may produce.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_query_bytes = 1024;
pub const max_terms = 32;
pub const max_depth = 8;
/// Fuzzy words must be this long (shorter ones have too many near neighbours).
pub const fuzzy_min_len = 3;
pub const fuzzy_max_len = 12;
/// Words shorter than this are never made fuzzy by `Options.fuzzy_words` (one
/// edit away from a three-letter word is most of the dictionary); writing
/// `word~` still works from `fuzzy_min_len`.
pub const implicit_fuzzy_min_len = 4;
/// Largest proximity distance accepted.
pub const max_near = 50;
/// Upper bound on the FTS5 expression, after fuzzy expansion.
const max_expression_bytes = 48 * 1024;

pub const Error = error{
    /// No positive, searchable term.
    EmptyQuery,
    /// Too long, too many terms, NUL byte, or the expansion grew too large.
    InvalidQuery,
    OutOfMemory,
};

pub const Options = struct {
    /// Treat every plain word as if it had been written `word~`: it also matches
    /// words one typo away. Applies to words only (not phrases, prefixes or
    /// words that are not plain letters and digits).
    fuzzy_words: bool = false,
};

pub const Parsed = struct {
    /// True if `fuzzy_words` changed at least one word (so a repeat search
    /// with it can differ from the plain one).
    fuzzy_applied: bool = false,
    /// The FTS5 MATCH expression.
    fts: []const u8,
    /// The query as understood, for showing to the person who typed it.
    shown: []const u8,
    /// True if the query used anything beyond plain words and phrases.
    advanced: bool,
};

const Kind = enum { word, prefix, fuzzy, phrase, near };

const Term = struct {
    text: []const u8,
    kind: Kind,
    /// Distance for `near`.
    n: u32 = 0,
};

const Unit = union(enum) {
    term: Term,
    group: *Or,
};

const And = struct {
    positive: std.ArrayList(Unit) = .empty,
    negative: std.ArrayList(Unit) = .empty,
};

const Or = struct {
    branches: std.ArrayList(*And) = .empty,
};

const Lexer = struct {
    text: []const u8,
    i: usize = 0,

    const Token = union(enum) {
        word: struct { text: []const u8, prefix: bool, fuzzy: bool },
        phrase: struct { text: []const u8, near: ?u32 },
        lparen,
        rparen,
        op_and,
        op_or,
        op_not,
        plus,
        minus,
        end,
    };

    fn isSpace(b: u8) bool {
        return std.ascii.isWhitespace(b);
    }

    fn hasWordChar(s: []const u8) bool {
        for (s) |b| if (std.ascii.isAlphanumeric(b) or b >= 0x80) return true;
        return false;
    }

    fn next(self: *Lexer) Token {
        while (self.i < self.text.len and isSpace(self.text[self.i])) self.i += 1;
        if (self.i >= self.text.len) return .end;
        const ch = self.text[self.i];
        switch (ch) {
            '(' => {
                self.i += 1;
                return .lparen;
            },
            ')' => {
                self.i += 1;
                return .rparen;
            },
            '+', '-' => {
                // A sign only when something follows it directly.
                if (self.i + 1 < self.text.len and !isSpace(self.text[self.i + 1])) {
                    self.i += 1;
                    return if (ch == '+') .plus else .minus;
                }
            },
            '"' => {
                const start = self.i + 1;
                const close = std.mem.indexOfScalarPos(u8, self.text, start, '"');
                const end = close orelse self.text.len;
                self.i = if (close) |c| c + 1 else self.text.len;
                var near: ?u32 = null;
                if (close != null and self.i < self.text.len and self.text[self.i] == '~') {
                    var j = self.i + 1;
                    var n: u32 = 0;
                    const digits_start = j;
                    while (j < self.text.len and std.ascii.isDigit(self.text[j]) and j - digits_start < 4) : (j += 1) n = n * 10 + (self.text[j] - '0');
                    if (j > digits_start) {
                        near = @min(n, max_near);
                        self.i = j;
                    }
                }
                return .{ .phrase = .{ .text = self.text[start..end], .near = near } };
            },
            else => {},
        }
        // A word runs to whitespace, a quote or a parenthesis.
        const start = self.i;
        var end = start;
        while (end < self.text.len and !isSpace(self.text[end]) and self.text[end] != '"' and self.text[end] != '(' and self.text[end] != ')') end += 1;
        self.i = end;
        var w = self.text[start..end];
        if (std.mem.eql(u8, w, "AND")) return .op_and;
        if (std.mem.eql(u8, w, "OR")) return .op_or;
        if (std.mem.eql(u8, w, "NOT")) return .op_not;
        var prefix = false;
        var fuzzy = false;
        // `word~` or `word~1` (any digits are accepted; one edit is what it means).
        if (std.mem.lastIndexOfScalar(u8, w, '~')) |t| {
            const tail = w[t + 1 ..];
            var all_digits = true;
            for (tail) |b| if (!std.ascii.isDigit(b)) {
                all_digits = false;
            };
            if (all_digits and t > 0) {
                fuzzy = true;
                w = w[0..t];
            }
        }
        if (!fuzzy and w.len > 1 and w[w.len - 1] == '*') {
            prefix = true;
            w = w[0 .. w.len - 1];
        }
        return .{ .word = .{ .text = w, .prefix = prefix, .fuzzy = fuzzy } };
    }
};

const Parser = struct {
    arena: Allocator,
    lex: Lexer,
    peeked: ?Lexer.Token = null,
    terms: usize = 0,
    advanced: bool = false,
    too_many: bool = false,
    fuzzy_words: bool = false,
    fuzzy_applied: bool = false,

    fn peek(self: *Parser) Lexer.Token {
        if (self.peeked == null) self.peeked = self.lex.next();
        return self.peeked.?;
    }
    fn take(self: *Parser) Lexer.Token {
        const t = self.peek();
        self.peeked = null;
        return t;
    }

    fn parseOr(self: *Parser, depth: u32) Allocator.Error!*Or {
        const or_node = try self.arena.create(Or);
        or_node.* = .{};
        while (true) {
            const and_node = try self.parseAnd(depth);
            try or_node.branches.append(self.arena, and_node);
            if (self.peek() == .op_or) {
                _ = self.take();
                self.advanced = true;
                continue;
            }
            break;
        }
        return or_node;
    }

    fn parseAnd(self: *Parser, depth: u32) Allocator.Error!*And {
        const node = try self.arena.create(And);
        node.* = .{};
        var negate_next = false;
        while (true) {
            const t = self.peek();
            switch (t) {
                .end, .op_or => break,
                .rparen => {
                    if (depth > 0) break;
                    _ = self.take(); // a stray ")" at the top level: ignored
                },
                .op_and => {
                    _ = self.take();
                    self.advanced = true;
                },
                .plus => {
                    _ = self.take();
                    self.advanced = true;
                },
                .minus, .op_not => {
                    _ = self.take();
                    self.advanced = true;
                    negate_next = true;
                },
                .lparen => {
                    _ = self.take();
                    if (depth + 1 >= max_depth) continue; // too deep: the parenthesis is ignored
                    const inner = try self.parseOr(depth + 1);
                    if (self.peek() == .rparen) _ = self.take(); // a missing ")" is supplied
                    self.advanced = true;
                    const unit: Unit = .{ .group = inner };
                    try (if (negate_next) node.negative else node.positive).append(self.arena, unit);
                    negate_next = false;
                },
                .word => |w| {
                    _ = self.take();
                    if (!Lexer.hasWordChar(w.text)) continue;
                    if (self.terms >= max_terms) {
                        self.too_many = true;
                        continue;
                    }
                    self.terms += 1;
                    var kind: Kind = if (w.fuzzy) .fuzzy else if (w.prefix) .prefix else .word;
                    if (kind != .word) self.advanced = true;
                    if (kind == .word and self.fuzzy_words and w.text.len >= implicit_fuzzy_min_len and fuzzyEligible(w.text)) {
                        kind = .fuzzy; // asked for through the options, not by the person: not "advanced"
                        self.fuzzy_applied = true;
                    }
                    const unit: Unit = .{ .term = .{ .text = w.text, .kind = kind } };
                    try (if (negate_next) node.negative else node.positive).append(self.arena, unit);
                    negate_next = false;
                },
                .phrase => |p| {
                    _ = self.take();
                    if (!Lexer.hasWordChar(p.text)) continue;
                    if (self.terms >= max_terms) {
                        self.too_many = true;
                        continue;
                    }
                    self.terms += 1;
                    const kind: Kind = if (p.near != null) .near else .phrase;
                    if (kind == .near) self.advanced = true;
                    const unit: Unit = .{ .term = .{ .text = p.text, .kind = kind, .n = p.near orelse 0 } };
                    try (if (negate_next) node.negative else node.positive).append(self.arena, unit);
                    negate_next = false;
                },
            }
        }
        return node;
    }
};

/// Whether a word can be fuzzy-expanded: plain letters and digits of a length
/// that has few enough neighbours to be useful.
pub fn fuzzyEligible(word: []const u8) bool {
    if (word.len < fuzzy_min_len or word.len > fuzzy_max_len) return false;
    for (word) |b| if (!std.ascii.isAlphanumeric(b)) return false;
    return true;
}

/// Parses `text`. The result's strings are allocated from `arena`.
pub fn parse(arena: Allocator, text: []const u8) Error!Parsed {
    return parseWith(arena, text, .{});
}

pub fn parseWith(arena: Allocator, text: []const u8, options: Options) Error!Parsed {
    if (text.len > max_query_bytes) return error.InvalidQuery;
    // A NUL would end the string early inside SQLite's C code.
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidQuery;
    var p: Parser = .{ .arena = arena, .lex = .{ .text = text }, .fuzzy_words = options.fuzzy_words };
    const root = try p.parseOr(0);
    if (p.too_many) return error.InvalidQuery;

    var fts: std.ArrayList(u8) = .empty;
    if (!try emitOr(arena, &fts, root)) return error.EmptyQuery;
    if (fts.items.len > max_expression_bytes) return error.InvalidQuery;
    var shown: std.ArrayList(u8) = .empty;
    _ = try showOr(arena, &shown, root);
    return .{ .fts = fts.items, .shown = shown.items, .advanced = p.advanced, .fuzzy_applied = p.fuzzy_applied };
}

// ------------------------------------------------------------- FTS5 output

fn quoted(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(arena, '"');
    for (s) |b| {
        if (b == '"') try out.append(arena, '"'); // escape by doubling
        try out.append(arena, b);
    }
    try out.append(arena, '"');
}

/// Emits one term; false if it ends up with nothing to search for.
fn emitTerm(arena: Allocator, out: *std.ArrayList(u8), t: Term) Allocator.Error!bool {
    switch (t.kind) {
        .word, .phrase => try quoted(arena, out, t.text),
        .prefix => {
            try quoted(arena, out, t.text);
            try out.append(arena, '*');
        },
        .fuzzy => try emitFuzzy(arena, out, t.text),
        .near => {
            // Split into words; one word is just that word.
            var words: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, t.text, " \t\r\n");
            while (it.next()) |w| if (Lexer.hasWordChar(w)) try words.append(arena, w);
            if (words.items.len == 0) return false;
            if (words.items.len == 1) {
                try quoted(arena, out, words.items[0]);
            } else {
                try out.appendSlice(arena, "NEAR(");
                for (words.items, 0..) |w, i| {
                    if (i > 0) try out.append(arena, ' ');
                    try quoted(arena, out, w);
                }
                try out.print(arena, ", {d})", .{t.n});
            }
        },
    }
    return true;
}

const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";

/// `word` and every word one edit away (a letter dropped, swapped with its
/// neighbour, replaced or inserted), as an OR. Words that are not plain
/// letters and digits, or are too short or long, are searched as written.
fn emitFuzzy(arena: Allocator, out: *std.ArrayList(u8), word: []const u8) Allocator.Error!void {
    var plain = word.len >= fuzzy_min_len and word.len <= fuzzy_max_len;
    if (plain) for (word) |b| if (!std.ascii.isAlphanumeric(b)) {
        plain = false;
    };
    if (!plain) return quoted(arena, out, word);

    const lower = try std.ascii.allocLowerString(arena, word);
    try out.append(arena, '(');
    try quoted(arena, out, lower);
    var buf: [fuzzy_max_len + 1]u8 = undefined;
    // Deletions.
    for (0..lower.len) |i| {
        @memcpy(buf[0..i], lower[0..i]);
        @memcpy(buf[i .. lower.len - 1], lower[i + 1 ..]);
        try out.appendSlice(arena, " OR ");
        try quoted(arena, out, buf[0 .. lower.len - 1]);
    }
    // Swaps of neighbours.
    for (0..lower.len - 1) |i| {
        if (lower[i] == lower[i + 1]) continue;
        @memcpy(buf[0..lower.len], lower);
        buf[i] = lower[i + 1];
        buf[i + 1] = lower[i];
        try out.appendSlice(arena, " OR ");
        try quoted(arena, out, buf[0..lower.len]);
    }
    // Substitutions.
    for (0..lower.len) |i| for (alphabet) |c| {
        if (c == lower[i]) continue;
        @memcpy(buf[0..lower.len], lower);
        buf[i] = c;
        try out.appendSlice(arena, " OR ");
        try quoted(arena, out, buf[0..lower.len]);
    };
    // Insertions.
    for (0..lower.len + 1) |i| for (alphabet) |c| {
        @memcpy(buf[0..i], lower[0..i]);
        buf[i] = c;
        @memcpy(buf[i + 1 .. lower.len + 1], lower[i..]);
        try out.appendSlice(arena, " OR ");
        try quoted(arena, out, buf[0 .. lower.len + 1]);
    };
    try out.append(arena, ')');
}

fn emitUnit(arena: Allocator, out: *std.ArrayList(u8), u: Unit) Allocator.Error!bool {
    switch (u) {
        .term => |t| return emitTerm(arena, out, t),
        .group => |g| {
            const mark = out.items.len;
            try out.append(arena, '(');
            if (!try emitOr(arena, out, g)) {
                out.items.len = mark;
                return false;
            }
            try out.append(arena, ')');
            return true;
        },
    }
}

/// `(p1 AND p2) NOT (n1 OR n2)`; false if there is no positive part.
fn emitAnd(arena: Allocator, out: *std.ArrayList(u8), a: *const And) Allocator.Error!bool {
    const mark = out.items.len;
    var wrote: usize = 0;
    if (a.negative.items.len > 0) try out.append(arena, '(');
    for (a.positive.items) |u| {
        const at = out.items.len;
        if (wrote > 0) try out.appendSlice(arena, " AND ");
        if (try emitUnit(arena, out, u)) {
            wrote += 1;
        } else out.items.len = at;
    }
    if (wrote == 0) {
        out.items.len = mark;
        return false;
    }
    if (a.negative.items.len > 0) {
        try out.appendSlice(arena, ") NOT (");
        var neg: usize = 0;
        for (a.negative.items) |u| {
            const at = out.items.len;
            if (neg > 0) try out.appendSlice(arena, " OR ");
            if (try emitUnit(arena, out, u)) {
                neg += 1;
            } else out.items.len = at;
        }
        if (neg == 0) {
            // Nothing searchable to exclude: just the positive part.
            out.items.len = mark;
            try out.append(arena, '(');
            wrote = 0;
            for (a.positive.items) |u| {
                const at = out.items.len;
                if (wrote > 0) try out.appendSlice(arena, " AND ");
                if (try emitUnit(arena, out, u)) wrote += 1 else out.items.len = at;
            }
        }
        try out.append(arena, ')');
    }
    return true;
}

fn emitOr(arena: Allocator, out: *std.ArrayList(u8), o: *const Or) Allocator.Error!bool {
    var wrote: usize = 0;
    for (o.branches.items) |b| {
        const at = out.items.len;
        if (wrote > 0) try out.appendSlice(arena, " OR ");
        if (try emitAnd(arena, out, b)) {
            wrote += 1;
        } else out.items.len = at;
    }
    return wrote > 0;
}

// ---------------------------------------------------------- readable output

fn showTerm(arena: Allocator, out: *std.ArrayList(u8), t: Term) Allocator.Error!void {
    switch (t.kind) {
        .word => try out.appendSlice(arena, t.text),
        .prefix => try out.print(arena, "{s}*", .{t.text}),
        .fuzzy => try out.print(arena, "{s}~", .{t.text}),
        .phrase => try out.print(arena, "\"{s}\"", .{t.text}),
        .near => try out.print(arena, "\"{s}\"~{d}", .{ t.text, t.n }),
    }
}

fn showUnit(arena: Allocator, out: *std.ArrayList(u8), u: Unit) Allocator.Error!bool {
    switch (u) {
        .term => |t| {
            // A term with nothing searchable in it is not shown.
            if (!Lexer.hasWordChar(t.text)) return false;
            try showTerm(arena, out, t);
            return true;
        },
        .group => |g| {
            const mark = out.items.len;
            try out.append(arena, '(');
            if (!try showOr(arena, out, g)) {
                out.items.len = mark;
                return false;
            }
            try out.append(arena, ')');
            return true;
        },
    }
}

fn showAnd(arena: Allocator, out: *std.ArrayList(u8), a: *const And) Allocator.Error!bool {
    const mark = out.items.len;
    var wrote: usize = 0;
    for (a.positive.items) |u| {
        const at = out.items.len;
        if (wrote > 0) try out.appendSlice(arena, " AND ");
        if (try showUnit(arena, out, u)) wrote += 1 else out.items.len = at;
    }
    if (wrote == 0) {
        out.items.len = mark;
        return false;
    }
    for (a.negative.items) |u| {
        const at = out.items.len;
        try out.appendSlice(arena, " NOT ");
        if (!try showUnit(arena, out, u)) out.items.len = at;
    }
    return true;
}

fn showOr(arena: Allocator, out: *std.ArrayList(u8), o: *const Or) Allocator.Error!bool {
    var wrote: usize = 0;
    for (o.branches.items) |b| {
        const at = out.items.len;
        if (wrote > 0) try out.appendSlice(arena, " OR ");
        if (try showAnd(arena, out, b)) wrote += 1 else out.items.len = at;
    }
    return wrote > 0;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn expectFts(text: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), text);
    try testing.expectEqualStrings(want, p.fts);
}

test "plain words and phrases behave as before" {
    try expectFts("  hello   world ", "\"hello\" AND \"world\"");
    try expectFts("\"hello world\" x", "\"hello world\" AND \"x\"");
    try expectFts("\"unterminated phrase", "\"unterminated phrase\"");
    try expectFts("café", "\"café\"");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "linux wayland \"window manager\"");
    try testing.expect(!p.advanced);
    try testing.expectEqualStrings("linux AND wayland AND \"window manager\"", p.shown);
}

test "AND, OR, NOT, signs and grouping" {
    try expectFts("linux AND wayland", "\"linux\" AND \"wayland\"");
    try expectFts("linux OR bsd", "\"linux\" OR \"bsd\"");
    try expectFts("linux NOT android", "(\"linux\") NOT (\"android\")");
    try expectFts("linux -android", "(\"linux\") NOT (\"android\")");
    try expectFts("+linux +wayland", "\"linux\" AND \"wayland\"");
    try expectFts("(linux OR bsd) AND kernel", "(\"linux\" OR \"bsd\") AND \"kernel\"");
    try expectFts("linux wayland OR bsd", "\"linux\" AND \"wayland\" OR \"bsd\""); // AND binds tighter
    try expectFts("a -b -c", "(\"a\") NOT (\"b\" OR \"c\")");
    try expectFts("a NOT (b OR c)", "(\"a\") NOT ((\"b\" OR \"c\"))");
    try expectFts("kernel -(android OR ios)", "(\"kernel\") NOT ((\"android\" OR \"ios\"))");
}

test "lower-case operators are words; quoted operators are words; a hyphen inside a word is kept" {
    try expectFts("linux and bsd", "\"linux\" AND \"and\" AND \"bsd\"");
    try expectFts("\"AND\" or", "\"AND\" AND \"or\"");
    try expectFts("e-mail x-ray", "\"e-mail\" AND \"x-ray\"");
    try expectFts("a - b", "\"a\" AND \"b\"");
}

test "prefix, proximity and fuzzy" {
    try expectFts("comp*", "\"comp\"*");
    try expectFts("\"window manager\"~5", "NEAR(\"window\" \"manager\", 5)");
    try expectFts("\"window manager\"~500", "NEAR(\"window\" \"manager\", 50)"); // capped
    try expectFts("\"solo\"~3", "\"solo\"");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), "compositor~");
    try testing.expect(p.advanced);
    // The word itself, a deletion, a swap, a substitution and an insertion are all there.
    for ([_][]const u8{ "\"compositor\"", "\"compsitor\"", "\"comopsitor\"", "\"compositer\"", "\"compositors\"" }) |v| {
        try testing.expect(std.mem.indexOf(u8, p.fts, v) != null);
    }
    try testing.expectEqualStrings("compositor~", p.shown);
    // Short words, long words and non-ASCII words are not expanded.
    try expectFts("ab~", "\"ab\"");
    try expectFts("extraordinarily~", "\"extraordinarily\"");
    try expectFts("café~", "\"café\"");
}

test "fuzzy_words expands plain words only, and says whether it did" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseWith(a, "wayland \"exact phrase\" pre* ab -android", .{ .fuzzy_words = true });
    try testing.expect(p.fuzzy_applied);
    try testing.expect(p.advanced); // from the - and pre*, not from fuzzy_words
    try testing.expect(std.mem.indexOf(u8, p.fts, "\"wayalnd\"") != null); // a swap of the word
    try testing.expect(std.mem.indexOf(u8, p.fts, "\"exact phrase\"") != null);
    try testing.expect(std.mem.indexOf(u8, p.fts, "\"pre\"*") != null);
    try testing.expect(std.mem.indexOf(u8, p.fts, "\"ab\"") != null); // too short to expand
    try testing.expectEqualStrings("wayland~ AND \"exact phrase\" AND pre* AND ab NOT android~", p.shown);
    // Nothing to expand: not applied, and the plain parse is the same as before.
    const none = try parseWith(a, "ab \"a phrase\" x*", .{ .fuzzy_words = true });
    try testing.expect(!none.fuzzy_applied);
    const plain = try parse(a, "wayland");
    try testing.expect(!plain.fuzzy_applied);
    try testing.expect(!plain.advanced);
}

test "syntax cannot reach FTS5: operators, column filters and quotes are inert" {
    try expectFts("title:foo", "\"title:foo\"");
    try expectFts("^start", "\"^start\"");
    try expectFts("NEAR(a b)", "\"NEAR\" AND (\"a\" AND \"b\")");
    try expectFts("a\"b", "\"a\" AND \"b\"");
    try expectFts("\"he said \"\"hi\"\"\"", "\"he said \" AND \"hi\"");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.EmptyQuery, parse(arena.allocator(), "*")); // nothing searchable
}

test "forgiving: stray and missing parentheses, dangling operators" {
    try expectFts("(linux OR bsd", "(\"linux\" OR \"bsd\")");
    try expectFts("linux) bsd", "\"linux\" AND \"bsd\"");
    try expectFts("linux AND", "\"linux\"");
    try expectFts("OR linux", "\"linux\"");
    try expectFts("linux OR NOT android", "\"linux\"");
    try expectFts("a OR (-b)", "\"a\"");
    {
        // Nesting past the limit is flattened, never refused or unbounded.
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const deep = try parse(arena.allocator(), "((((((((((((a))))))))))))");
        try testing.expect(std.mem.indexOf(u8, deep.fts, "\"a\"") != null);
        var open: usize = 0;
        for (deep.fts) |ch| open += @intFromBool(ch == '(');
        try testing.expect(open <= max_depth);
    }
}

test "no positive term is an empty query; limits are enforced" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "   ", "!!! ...", "-android", "NOT android", "-a -b", "()", "AND OR NOT", "\"\"" }) |q| {
        errdefer std.debug.print("query: {s}\n", .{q});
        try testing.expectError(error.EmptyQuery, parse(a, q));
    }
    try testing.expectError(error.InvalidQuery, parse(a, "x\x00y"));
    const long = try a.alloc(u8, max_query_bytes + 1);
    @memset(long, 'a');
    try testing.expectError(error.InvalidQuery, parse(a, long));
    try testing.expectError(error.InvalidQuery, parse(a, "a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee ff gg"));
    // Many fuzzy words stay under the expression cap or are refused, never unbounded.
    var many: std.ArrayList(u8) = .empty;
    for (0..30) |_| try many.appendSlice(a, "abcdefghijkl~ ");
    if (parse(a, many.items)) |p| {
        try testing.expect(p.fts.len <= max_expression_bytes);
    } else |e| try testing.expectEqual(error.InvalidQuery, e);
}

test "random queries never crash and always give balanced, quote-safe output" {
    var prng = std.Random.DefaultPrng.init(0x9a11);
    const rnd = prng.random();
    const pieces = [_][]const u8{ "a", "bb", "AND", "OR", "NOT", "(", ")", "\"", "~", "~3", "*", "+", "-", " ", " ", "x~", "pre*", "\"p q\"~2", "é", "title:", "NEAR", ":" };
    for (0..3000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var q: std.ArrayList(u8) = .empty;
        for (0..rnd.uintLessThan(usize, 14) + 1) |_| try q.appendSlice(arena.allocator(), pieces[rnd.uintLessThan(usize, pieces.len)]);
        const p = parse(arena.allocator(), q.items) catch continue;
        // Outside quoted strings, only the operators this module emits may appear.
        var in_quote = false;
        var depth: i32 = 0;
        var i: usize = 0;
        while (i < p.fts.len) : (i += 1) {
            const ch = p.fts[i];
            if (ch == '"') {
                if (in_quote and i + 1 < p.fts.len and p.fts[i + 1] == '"') {
                    i += 1; // a doubled quote inside a string
                    continue;
                }
                in_quote = !in_quote;
                continue;
            }
            if (in_quote) continue;
            switch (ch) {
                '(' => depth += 1,
                ')' => depth -= 1,
                ' ', '*', ',', '0'...'9', 'A', 'N', 'D', 'O', 'R', 'T', 'E' => {},
                else => return error.UnexpectedCharacterOutsideQuotes,
            }
            try testing.expect(depth >= 0);
        }
        try testing.expect(!in_quote);
        try testing.expectEqual(@as(i32, 0), depth);
    }
}
