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
const search = @import("search.zig");
const snippets = @import("snippets.zig");
const lexicon = @import("lexicon.zig");
const wordforms = @import("wordforms.zig");

pub const max_query_bytes = 1024;
pub const max_terms = 32;
pub const max_depth = 8;
/// Fuzzy words must be this long (shorter ones have too many near neighbours).
pub const fuzzy_min_len = 3;
pub const fuzzy_max_len = 24;
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
    /// "Now" in Unix seconds, for relative dates such as `modified:7d`. Zero
    /// means unknown: relative dates are then not understood.
    now: i64 = 0,
    /// Treat every plain word as if it had been written `word~`: it also matches
    /// words one typo away. Applies to words only (not phrases, prefixes or
    /// words that are not plain letters and digits).
    fuzzy_words: bool = false,
    /// Stop words and synonyms (see `lexicon.zig`); null leaves the query as typed.
    lexicon: ?*const lexicon.Lexicon = null,
    /// Finds the words of the index that are within a number of edits of a word, for typo tolerance. Without it
    /// a fuzzy word is expanded to every spelling one edit away, whether or not it exists.
    expander: ?Expander = null,
    /// Leaves out of the required words those that are too common to be worth it (see `Common`); null keeps every word.
    common: ?Common = null,
    /// Also search each plain word as the other forms of it that the index has (see wordforms.zig); null: as typed.
    forms: ?Forms = null,
};

/// Looks words up in the index's vocabulary. `f` returns the words within `max_edits` of `word` (not `word`
/// itself), best first, at most `max_expansions`.
pub const Expander = struct {
    /// Whether the index has this word (lower case). A word it has is not respelled when the search is repeated with
    /// typo tolerance on its own account: only a word that is not there is.
    known: ?*const fn (ctx: *anyopaque, word: []const u8) bool = null,
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, arena: Allocator, word: []const u8, max_edits: u8) Allocator.Error![]const []const u8,
};

/// How many edits a fuzzy word may be off: one for words of three to five letters, two from six, unless the
/// person wrote `word~1` or `word~2`.
pub fn autoEdits(len: usize) u8 {
    return if (len < fuzzy_min_len) 0 else if (len <= 5) 1 else if (len <= 6) 2 else 3;
}

pub const max_expansions = 12;

/// What the output stage needs besides the words: the lexicon, and whether stop words are in force.
const Lx = struct {
    lexicon: ?*const lexicon.Lexicon = null,
    stops: bool = false,
    expander: ?Expander = null,
    /// Words so common in the index that they are not worth requiring (see `Common`), when other words remain.
    common: ?Common = null,
    /// Where the words that were left out are noted (for telling the person), without repeats.
    ignored: ?*std.ArrayList([]const u8) = null,
    /// Where the words searched for in the text are noted (for making excerpts), without repeats.
    terms: ?*std.ArrayList(snippets.Term) = null,
    /// Where the index's own words that are other forms of a plain word are looked up ("program" finds "programming"), see
    /// wordforms.zig. Null: words are searched as typed.
    forms: ?Forms = null,
};

/// Question and filler words that are never worth requiring in a query that has other words ("how to program in c" is a
/// search for `program` and `c`): they say what kind of answer is wanted, not what it is about, and a page about the
/// thing rarely says "how". Quoted phrases, `title:` words and words someone excludes are not touched, and a query of
/// nothing else is searched as typed.
pub fn isFiller(word: []const u8) bool {
    const fillers = [_][]const u8{
        "how",    "what",  "why",  "when", "where", "which", "who", "is",   "are", "was", "were", "do", "does", "did", "can",  "could",
        "should", "would", "will", "i",    "me",    "my",    "you", "your", "to",  "in",  "on",   "at", "of",   "for", "with", "a",
        "an",     "the",
    };
    for (fillers) |f| if (std.ascii.eqlIgnoreCase(f, word)) return true;
    return false;
}

/// Decides whether a plain word is too common in the index to be required (it appears in a large share of the
/// documents): such a word is left out of the required terms of a query that has other words. The reason: ranking has
/// to read every occurrence of every required word, and a word like "in" has tens of thousands of long position
/// lists, which made searches such as "how to program in c" take many seconds for nothing a person wanted.
/// Looks up the words of the index that begin with `stem`, the commonest first (at most `limit`).
pub const Forms = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, arena: Allocator, stem: []const u8, limit: u32) Allocator.Error![]const []const u8,
};

pub const Common = struct {
    ctx: *anyopaque,
    isCommon: *const fn (ctx: *anyopaque, word: []const u8) bool,
};

pub const Parsed = struct {
    /// Conditions written in the query (`ext:pdf`, `size:>1mb`), to be applied
    /// to the documents. A query of filters alone has an empty `fts`.
    filters: []const search.Filter = &.{},
    /// True if `fuzzy_words` changed at least one word (so a repeat search
    /// with it can differ from the plain one).
    fuzzy_applied: bool = false,
    /// The FTS5 MATCH expression.
    fts: []const u8,
    /// The query as understood, for showing to the person who typed it.
    shown: []const u8,
    /// True if the query used anything beyond plain words and phrases.
    advanced: bool,
    /// Very common words that were left out of the required words (`Options.common`).
    ignored: []const []const u8 = &.{},
    /// Only very common words were typed, so they are searched after all.
    heavy: bool = false,
    /// For a heavy search of two or more plain words ("to be or not to be"): the words as one phrase, `"to be or not to be"`,
    /// which is selective where the words alone are not. Null otherwise.
    phrase: ?[]const u8 = null,
    /// The words the text is searched for (not those restricted to the title, nor excluded ones), lower case.
    terms: []const snippets.Term = &.{},
};

const Kind = enum { word, prefix, fuzzy, phrase, near };

/// Which full-text column a term is restricted to (`title:kernel`).
const Column = enum { title, body };

const Term = struct {
    text: []const u8,
    kind: Kind,
    /// Distance for `near`; for `fuzzy`, the edits asked for with `~1` or `~2` (0: by the word's length).
    n: u32 = 0,
    column: ?Column = null,
};

const Group = struct { node: *Or, column: ?Column = null };

const Unit = union(enum) {
    term: Term,
    group: Group,
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
    /// A word that came glued to a column (`title:word`), handed out next.
    queued: ?[]const u8 = null,
    key_buf: [48]u8 = undefined,

    const Token = union(enum) {
        word: struct { text: []const u8, prefix: bool, fuzzy: bool, edits: u8 = 0 },
        phrase: struct { text: []const u8, near: ?u32 },
        /// `key:value`, with a key from `filter_keys`.
        filter: struct { key: []const u8, value: []const u8 },
        /// `title:` or `body:` (the restricted term follows).
        column: Column,
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
        if (self.queued) |w| {
            self.queued = null;
            return finishWord(w);
        }
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
        const w = self.text[start..end];
        if (std.mem.eql(u8, w, "AND")) return .op_and;
        if (std.mem.eql(u8, w, "OR")) return .op_or;
        if (std.mem.eql(u8, w, "NOT")) return .op_not;
        // `key:value`: a filter, or a column restriction (`title:`/`body:`).
        if (std.mem.indexOfScalar(u8, w, ':')) |colon| if (colon > 0 and colon < self.key_buf.len) {
            const key = std.ascii.lowerString(self.key_buf[0..colon], w[0..colon]);
            var value = w[colon + 1 ..];
            if (columnOf(key)) |col| {
                if (value.len > 0) self.queued = value;
                return .{ .column = col };
            }
            if (isFilterKey(key)) {
                if (value.len == 0 and self.i < self.text.len and self.text[self.i] == '"') {
                    const open = self.i + 1;
                    const close = std.mem.indexOfScalarPos(u8, self.text, open, '"');
                    value = self.text[open .. close orelse self.text.len];
                    self.i = if (close) |c2| c2 + 1 else self.text.len;
                }
                if (value.len > 0) return .{ .filter = .{ .key = key, .value = value } };
            }
        };
        return finishWord(w);
    }

    /// A plain word with its `*` or `~` suffix taken off.
    fn finishWord(word: []const u8) Token {
        var w = word;
        var prefix = false;
        var fuzzy = false;
        var edits: u8 = 0;
        // `word~` (the number of edits follows the word's length), `word~1` or `word~2`; any other digits mean `~2`.
        if (std.mem.lastIndexOfScalar(u8, w, '~')) |t| {
            const tail = w[t + 1 ..];
            var all_digits = true;
            for (tail) |b| if (!std.ascii.isDigit(b)) {
                all_digits = false;
            };
            if (all_digits and t > 0) {
                fuzzy = true;
                edits = if (tail.len == 0) 0 else if (tail[0] == '1') 1 else 2;
                w = w[0..t];
            }
        }
        if (!fuzzy and w.len > 1 and w[w.len - 1] == '*') {
            prefix = true;
            w = w[0 .. w.len - 1];
        }
        return .{ .word = .{ .text = w, .prefix = prefix, .fuzzy = fuzzy, .edits = edits } };
    }
};

fn columnOf(key: []const u8) ?Column {
    if (std.mem.eql(u8, key, "title")) return .title;
    if (std.mem.eql(u8, key, "body") or std.mem.eql(u8, key, "text")) return .body;
    return null;
}

const filter_names = [_]struct { []const u8, search.FilterField }{
    .{ "collection", .collection },
    .{ "source", .source },
    .{ "src", .source },
    .{ "connector", .source },
    .{ "lang", .language },
    .{ "language", .language },
    .{ "mime", .mime },
    .{ "type", .kind },
    .{ "kind", .kind },
    .{ "ext", .ext },
    .{ "extension", .ext },
    .{ "domain", .domain },
    .{ "site", .domain },
    .{ "host", .domain },
    .{ "path", .path },
    .{ "dir", .path },
    .{ "author", .author },
    .{ "by", .author },
    .{ "size", .size },
    .{ "modified", .modified },
    .{ "updated", .modified },
    .{ "created", .created },
    .{ "published", .created },
    .{ "date", .created },
    .{ "indexed", .indexed },
    .{ "added", .indexed },
    .{ "tag", .tag },
};

fn isMetaKey(key: []const u8) bool {
    const prefix = if (std.mem.startsWith(u8, key, "meta.")) "meta." else if (std.mem.startsWith(u8, key, "field.")) "field." else return false;
    const name = key[prefix.len..];
    if (name.len == 0 or name.len > 32) return false;
    for (name) |b| if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '.')) return false;
    return true;
}

fn isFilterKey(key: []const u8) bool {
    for (filter_names) |f| if (std.mem.eql(u8, key, f[0])) return true;
    return isMetaKey(key);
}

const max_filter_text = 200;
const max_filters = 16;

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// The start and the last second of a date written `2026`, `2026-03` or `2026-03-15`.
fn datePeriod(text: []const u8) ?struct { start: i64, end: i64 } {
    var it = std.mem.splitScalar(u8, text, '-');
    const ys = it.next() orelse return null;
    if (ys.len != 4) return null;
    const y = std.fmt.parseInt(i64, ys, 10) catch return null;
    if (y < 1970 or y > 2200) return null;
    const ms = it.next();
    const ds = it.next();
    if (it.next() != null) return null;
    if (ms == null) return .{ .start = daysFromCivil(y, 1, 1) * 86400, .end = daysFromCivil(y + 1, 1, 1) * 86400 - 1 };
    if (ms.?.len != 2) return null;
    const m = std.fmt.parseInt(i64, ms.?, 10) catch return null;
    if (m < 1 or m > 12) return null;
    if (ds == null) {
        const ny = if (m == 12) y + 1 else y;
        const nm = if (m == 12) 1 else m + 1;
        return .{ .start = daysFromCivil(y, m, 1) * 86400, .end = daysFromCivil(ny, nm, 1) * 86400 - 1 };
    }
    if (ds.?.len != 2) return null;
    const d = std.fmt.parseInt(i64, ds.?, 10) catch return null;
    if (d < 1 or d > 31) return null;
    const start = daysFromCivil(y, m, d) * 86400;
    return .{ .start = start, .end = start + 86399 };
}

/// "1500", "10k", "1.5mb", "2gb" as a number of bytes.
fn parseSize(text: []const u8) ?i64 {
    var t = text;
    var mult: i64 = 1;
    const units = [_]struct { []const u8, i64 }{ .{ "kb", 1 << 10 }, .{ "mb", 1 << 20 }, .{ "gb", 1 << 30 }, .{ "k", 1 << 10 }, .{ "m", 1 << 20 }, .{ "g", 1 << 30 }, .{ "b", 1 } };
    for (units) |u| if (t.len > u[0].len and std.ascii.eqlIgnoreCase(t[t.len - u[0].len ..], u[0])) {
        mult = u[1];
        t = t[0 .. t.len - u[0].len];
        break;
    };
    if (t.len == 0) return null;
    const v = std.fmt.parseFloat(f64, t) catch return null;
    if (!(v >= 0) or v > 1e15) return null;
    return @intFromFloat(v * @as(f64, @floatFromInt(mult)));
}

const Range = struct { min: ?i64 = null, max: ?i64 = null };

/// A numeric condition: `>x`, `>=x`, `<x`, `<=x`, `a..b`, a single value (the
/// whole period for a date), or for dates a span back from now (`7d`, `3w`,
/// `6m`, `1y`).
fn parseRange(field: search.FilterField, value: []const u8, now: i64) ?Range {
    const is_date = field != .size;
    const Edge = struct { lo: i64, hi: i64 };
    const edge = struct {
        fn of(f: search.FilterField, v: []const u8) ?Edge {
            if (f == .size) {
                const n = parseSize(v) orelse return null;
                return .{ .lo = n, .hi = n };
            }
            const p = datePeriod(v) orelse return null;
            return .{ .lo = p.start, .hi = p.end };
        }
    }.of;
    if (std.mem.indexOf(u8, value, "..")) |dots| {
        const a = value[0..dots];
        const b = value[dots + 2 ..];
        var r: Range = .{};
        if (a.len > 0) r.min = (edge(field, a) orelse return null).lo;
        if (b.len > 0) r.max = (edge(field, b) orelse return null).hi;
        if (a.len == 0 and b.len == 0) return null;
        return r;
    }
    if (std.mem.startsWith(u8, value, ">=")) return .{ .min = (edge(field, value[2..]) orelse return null).lo };
    if (std.mem.startsWith(u8, value, "<=")) return .{ .max = (edge(field, value[2..]) orelse return null).hi };
    if (std.mem.startsWith(u8, value, ">")) {
        const e = edge(field, value[1..]) orelse return null;
        return .{ .min = e.hi + 1 };
    }
    if (std.mem.startsWith(u8, value, "<")) {
        const e = edge(field, value[1..]) orelse return null;
        return .{ .max = e.lo - 1 };
    }
    if (is_date) {
        // A span back from now: 7d, 3w, 6m, 1y.
        if (value.len >= 2 and now > 0) {
            const unit = value[value.len - 1];
            const per: ?i64 = switch (unit) {
                'd' => 86400,
                'w' => 7 * 86400,
                'm' => 30 * 86400,
                'y' => 365 * 86400,
                else => null,
            };
            if (per) |sec| if (std.fmt.parseInt(i64, value[0 .. value.len - 1], 10)) |n| {
                if (n >= 0 and n <= 100000) return .{ .min = now - n * sec };
            } else |_| {};
        }
    }
    const e = edge(field, value) orelse return null;
    return .{ .min = e.lo, .max = e.hi };
}

/// The filter a `key:value` token stands for, or null if the value makes no
/// sense for that key (the token is then searched as ordinary text).
fn makeFilter(arena: Allocator, key: []const u8, value_in: []const u8, now: i64) Allocator.Error!?search.Filter {
    const value = std.mem.trim(u8, value_in, " \t");
    if (value.len == 0 or value.len > max_filter_text) return null;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return null;
    var field: ?search.FilterField = null;
    var meta_key: []const u8 = "";
    for (filter_names) |f| if (std.mem.eql(u8, key, f[0])) {
        field = f[1];
    };
    if (field == null and isMetaKey(key)) {
        field = .meta;
        meta_key = try std.ascii.allocLowerString(arena, key[(std.mem.indexOfScalar(u8, key, '.') orelse 0) + 1 ..]);
    }
    const f = field orelse return null;
    switch (f) {
        .size, .modified, .created, .indexed => {
            const r = parseRange(f, value, now) orelse return null;
            return .{ .field = f, .min = r.min, .max = r.max };
        },
        .ext => {
            // One extension, or a list of them (`ext:pdf,docx,odt`): any of them.
            var parts: usize = 0;
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |part_in| {
                var v = std.mem.trim(u8, part_in, " \t");
                if (v.len > 0 and v[0] == '.') v = v[1..];
                if (v.len == 0 or v.len > 8) return null;
                for (v) |b| if (!std.ascii.isAlphanumeric(b)) return null;
                parts += 1;
                if (parts > 16) return null;
            }
            var clean: std.ArrayList(u8) = .empty;
            var it2 = std.mem.splitScalar(u8, value, ',');
            while (it2.next()) |part_in| {
                var v = std.mem.trim(u8, part_in, " \t");
                if (v.len > 0 and v[0] == '.') v = v[1..];
                if (clean.items.len > 0) try clean.append(arena, ',');
                for (v) |b| try clean.append(arena, std.ascii.toLower(b));
            }
            return .{ .field = f, .text = clean.items };
        },
        .domain => {
            for (value) |b| if (!(std.ascii.isAlphanumeric(b) or b == '.' or b == '-')) return null;
            return .{ .field = f, .text = try std.ascii.allocLowerString(arena, value) };
        },
        .source, .language, .path, .author => return .{ .field = f, .text = try arena.dupe(u8, value) },
        .mime, .kind, .tag, .collection => return .{ .field = f, .text = try std.ascii.allocLowerString(arena, value) },
        .meta => return .{ .field = f, .key = meta_key, .text = try std.ascii.allocLowerString(arena, value) },
    }
}

/// A condition written on its own, as in the query language: `ext:pdf`, `-domain:example.org`,
/// `size:>1mb`. Null if it is not one (an unknown key, or a value that makes no sense).
pub fn parseFilterString(arena: Allocator, text: []const u8, now: i64) Allocator.Error!?search.Filter {
    var t = std.mem.trim(u8, text, " \t");
    var negate = false;
    if (t.len > 0 and t[0] == '-') {
        negate = true;
        t = t[1..];
    }
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    if (colon == 0 or colon > 48) return null;
    const key = try std.ascii.allocLowerString(arena, t[0..colon]);
    if (!isFilterKey(key)) return null;
    var value = t[colon + 1 ..];
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    var f = (try makeFilter(arena, key, value, now)) orelse return null;
    f.negate = negate;
    return f;
}

const Parser = struct {
    arena: Allocator,
    lex: Lexer,
    peeked: ?Lexer.Token = null,
    terms: usize = 0,
    advanced: bool = false,
    too_many: bool = false,
    fuzzy_words: bool = false,
    fuzzy_applied: bool = false,
    now: i64 = 0,
    filters: std.ArrayList(search.Filter) = .empty,
    /// How each filter was written, for showing the query back ("-ext:pdf").
    filter_text: std.ArrayList([]const u8) = .empty,
    pending_column: ?Column = null,

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
                .column => |col| {
                    _ = self.take();
                    self.advanced = true;
                    self.pending_column = col;
                },
                .filter => |f| {
                    _ = self.take();
                    self.advanced = true;
                    const made = if (self.filters.items.len < max_filters) try makeFilter(self.arena, f.key, f.value, self.now) else null;
                    if (made) |flt| {
                        var fl = flt;
                        fl.negate = negate_next;
                        try self.filters.append(self.arena, fl);
                        try self.filter_text.append(self.arena, try std.fmt.allocPrint(self.arena, "{s}{s}:{s}", .{ if (negate_next) "-" else "", f.key, f.value }));
                    } else if (self.terms < max_terms) {
                        // Not a condition that makes sense: search for it as text.
                        self.terms += 1;
                        const lit = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ f.key, f.value });
                        if (Lexer.hasWordChar(lit)) try (if (negate_next) node.negative else node.positive).append(self.arena, .{ .term = .{ .text = lit, .kind = .word } });
                    }
                    negate_next = false;
                },
                .lparen => {
                    _ = self.take();
                    if (depth + 1 >= max_depth) continue; // too deep: the parenthesis is ignored
                    // A column in front of a group restricts the whole group, not its first term.
                    const group_column = self.pending_column;
                    self.pending_column = null;
                    const inner = try self.parseOr(depth + 1);
                    if (self.peek() == .rparen) _ = self.take(); // a missing ")" is supplied
                    self.advanced = true;
                    const unit: Unit = .{ .group = .{ .node = inner, .column = group_column } };
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
                    const unit: Unit = .{ .term = .{ .text = w.text, .kind = kind, .n = w.edits, .column = self.pending_column } };
                    self.pending_column = null;
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
                    const unit: Unit = .{ .term = .{ .text = p.text, .kind = kind, .n = p.near orelse 0, .column = self.pending_column } };
                    self.pending_column = null;
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
    var p: Parser = .{ .arena = arena, .lex = .{ .text = text }, .fuzzy_words = options.fuzzy_words, .now = options.now };
    const root = try p.parseOr(0);
    if (p.too_many) return error.InvalidQuery;

    var fts: std.ArrayList(u8) = .empty;
    var ignored: std.ArrayList([]const u8) = .empty;
    var terms: std.ArrayList(snippets.Term) = .empty;
    var lx: Lx = .{ .lexicon = options.lexicon, .stops = options.lexicon != null and options.lexicon.?.stops.count() > 0, .expander = options.expander, .common = options.common, .ignored = &ignored, .terms = &terms, .forms = options.forms };
    var has_terms = try emitOr(arena, &fts, lx, root);
    var heavy = false;
    if (!has_terms and (lx.stops or lx.common != null)) {
        heavy = lx.common != null and ignored.items.len > 0;
        // Only stop words, or only very common words, were typed (`the`): search for them after all rather than for
        // nothing.
        lx.stops = false;
        lx.common = null;
        ignored.clearRetainingCapacity();
        terms.clearRetainingCapacity();
        fts.items.len = 0;
        has_terms = try emitOr(arena, &fts, lx, root);
    }
    if (!has_terms) {
        // Nothing to look for in the text. Conditions alone are a valid search
        // (everything that satisfies them), but only if at least one is positive.
        var positive = false;
        for (p.filters.items) |f| if (!f.negate) {
            positive = true;
        };
        if (!positive) return error.EmptyQuery;
        fts.items.len = 0;
    }
    if (fts.items.len > max_expression_bytes) return error.InvalidQuery;
    var shown: std.ArrayList(u8) = .empty;
    _ = try showOr(arena, &shown, root);
    for (p.filter_text.items) |t| {
        if (shown.items.len > 0) try shown.append(arena, ' ');
        try shown.appendSlice(arena, t);
    }
    var phrase: ?[]const u8 = null;
    if (heavy and !p.advanced and std.mem.indexOfScalar(u8, shown.items, ' ') != null) plain: {
        for (shown.items) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == ' ' or ch == '\'')) break :plain;
        phrase = try std.fmt.allocPrint(arena, "\"{s}\"", .{try std.ascii.allocLowerString(arena, shown.items)});
    }
    return .{ .phrase = phrase, .fts = fts.items, .shown = shown.items, .advanced = p.advanced, .fuzzy_applied = p.fuzzy_applied, .filters = p.filters.items, .ignored = ignored.items, .heavy = heavy, .terms = terms.items };
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

/// Whether a plain word is left out of the required words (a question or filler word, or one so common in the index that
/// it does not help), noting it for the page to say so. Words with a column, and words someone asked to be respelled
/// (`word~2`), are never left out.
fn leftOut(arena: Allocator, lx: Lx, t: Term) Allocator.Error!bool {
    const c = lx.common orelse return false;
    if (t.column != null) return false;
    if (!(isFiller(t.text) or c.isCommon(c.ctx, t.text))) return false;
    if (lx.ignored) |list| {
        var seen = false;
        for (list.items) |w| if (std.ascii.eqlIgnoreCase(w, t.text)) {
            seen = true;
        };
        if (!seen) try list.append(arena, t.text);
    }
    return true;
}

/// Emits one term; false if it ends up with nothing to search for.
fn emitTerm(arena: Allocator, out: *std.ArrayList(u8), lx: Lx, t: Term) Allocator.Error!bool {
    switch (t.kind) {
        .word => {
            if (lx.stops and (lx.lexicon.?).isStop(t.text)) return false;
            if (try leftOut(arena, lx, t)) return false;
            const syn: []const []const u8 = if (lx.lexicon) |l| l.synonymsOf(t.text) else &.{};
            var stem_buf: [wordforms.max_word]u8 = undefined;
            if (lx.forms) |fl| if (t.column == null) if (wordforms.stemPrefix(&stem_buf, t.text)) |st| {
                // The word, and the other forms of it that the index has ("program" finds "programming"), each as its own
                // word so that each counts by how rare it is.
                const typed = try std.ascii.allocLowerString(arena, t.text);
                var picked: std.ArrayList([]const u8) = .empty;
                try picked.append(arena, typed);
                const found = try fl.f(fl.ctx, arena, st, wordforms.max_forms * 6);
                for (found) |w| {
                    if (picked.items.len >= wordforms.max_forms) break;
                    if (std.mem.eql(u8, w, typed) or !wordforms.isForm(st, w)) continue;
                    try picked.append(arena, w);
                }
                if (picked.items.len > 1 or syn.len > 0) {
                    try out.append(arena, '(');
                    for (picked.items, 0..) |w, i| {
                        if (i > 0) try out.appendSlice(arena, " OR ");
                        try quoted(arena, out, w);
                    }
                    for (syn) |sw| {
                        try out.appendSlice(arena, " OR ");
                        try quoted(arena, out, sw);
                    }
                    try out.append(arena, ')');
                    for (picked.items) |w| {
                        var wt = t;
                        wt.text = w;
                        try noteTerms(arena, lx, wt);
                    }
                    return true;
                }
            };
            if (syn.len == 0) {
                try quoted(arena, out, t.text);
            } else {
                try out.append(arena, '(');
                try quoted(arena, out, t.text);
                for (syn) |sw| {
                    try out.appendSlice(arena, " OR ");
                    try quoted(arena, out, sw);
                }
                try out.append(arena, ')');
            }
        },
        .phrase => try quoted(arena, out, t.text),
        .prefix => {
            try quoted(arena, out, t.text);
            try out.append(arena, '*');
        },
        .fuzzy => {
            if (lx.stops and (lx.lexicon.?).isStop(t.text)) return false;
            // A word that was only made fuzzy by the repeat of a search that found nothing is left out like any other.
            if (t.n == 0 and try leftOut(arena, lx, t)) return false;
            try emitFuzzy(arena, out, lx, t.text, @intCast(t.n));
        },
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
    try noteTerms(arena, lx, t);
    return true;
}

/// Notes the words of an emitted term that the text is searched for, for making excerpts.
fn noteTerms(arena: Allocator, lx: Lx, t: Term) Allocator.Error!void {
    const list = lx.terms orelse return;
    if (t.column) |c| if (c == .title) return; // the excerpt is of the text
    var i: usize = 0;
    while (i < t.text.len) {
        while (i < t.text.len and !(std.ascii.isAlphanumeric(t.text[i]) or t.text[i] >= 0x80)) i += 1;
        const start = i;
        while (i < t.text.len and (std.ascii.isAlphanumeric(t.text[i]) or t.text[i] >= 0x80)) i += 1;
        if (i == start) break;
        const word = try std.ascii.allocLowerString(arena, t.text[start..i]);
        const prefix = t.kind == .prefix and i == t.text.len;
        var seen = false;
        for (list.items) |x| if (std.mem.eql(u8, x.text, word) and x.prefix == prefix) {
            seen = true;
        };
        if (!seen and list.items.len < 16) try list.append(arena, .{ .text = word, .prefix = prefix });
    }
}

const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";

/// `word` and every word one edit away (a letter dropped, swapped with its
/// neighbour, replaced or inserted), as an OR. Words that are not plain
/// letters and digits, or are too short or long, are searched as written.
fn emitFuzzy(arena: Allocator, out: *std.ArrayList(u8), lx: Lx, word: []const u8, asked_edits: u8) Allocator.Error!void {
    var plain = word.len >= fuzzy_min_len and word.len <= fuzzy_max_len;
    if (plain) for (word) |b| if (!std.ascii.isAlphanumeric(b)) {
        plain = false;
    };
    if (!plain) return quoted(arena, out, word);

    const lower = try std.ascii.allocLowerString(arena, word);
    // With the index's vocabulary: the words that exist within the allowed number of edits, best first.
    if (lx.expander) |ex| {
        if (asked_edits == 0) if (ex.known) |is_known| if (is_known(ex.ctx, lower)) return quoted(arena, out, lower);
        const edits = if (asked_edits > 0) asked_edits else autoEdits(lower.len);
        const found = try ex.f(ex.ctx, arena, lower, edits);
        try out.append(arena, '(');
        try quoted(arena, out, lower);
        for (found[0..@min(found.len, max_expansions)]) |w| {
            if (std.mem.eql(u8, w, lower)) continue;
            try out.appendSlice(arena, " OR ");
            try quoted(arena, out, w);
        }
        try out.append(arena, ')');
        return;
    }
    // Without a vocabulary every spelling one edit away is generated, which is only sensible for shorter words.
    if (lower.len > 12) return quoted(arena, out, lower);
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

fn columnPrefix(arena: Allocator, out: *std.ArrayList(u8), col: ?Column) Allocator.Error!void {
    if (col) |c| try out.appendSlice(arena, switch (c) {
        .title => "title : ",
        .body => "body : ",
    });
}

fn emitUnit(arena: Allocator, out: *std.ArrayList(u8), lx: Lx, u: Unit) Allocator.Error!bool {
    switch (u) {
        .term => |t| {
            const mark = out.items.len;
            try columnPrefix(arena, out, t.column);
            if (!try emitTerm(arena, out, lx, t)) {
                out.items.len = mark;
                return false;
            }
            return true;
        },
        .group => |g| {
            const mark = out.items.len;
            try columnPrefix(arena, out, g.column);
            try out.append(arena, '(');
            if (!try emitOr(arena, out, lx, g.node)) {
                out.items.len = mark;
                return false;
            }
            try out.append(arena, ')');
            return true;
        },
    }
}

/// `(p1 AND p2) NOT (n1 OR n2)`; false if there is no positive part.
fn emitAnd(arena: Allocator, out: *std.ArrayList(u8), lx: Lx, a: *const And) Allocator.Error!bool {
    const mark = out.items.len;
    var wrote: usize = 0;
    // What is excluded is taken as typed: a very common word someone asks to leave out stays a word to leave out.
    var negative_lx = lx;
    negative_lx.common = null;
    negative_lx.forms = null; // a word to leave out is left out as typed
    negative_lx.terms = null; // and is not a word to look for in an excerpt
    if (a.negative.items.len > 0) try out.append(arena, '(');
    for (a.positive.items) |u| {
        const at = out.items.len;
        if (wrote > 0) try out.appendSlice(arena, " AND ");
        if (try emitUnit(arena, out, lx, u)) {
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
            if (try emitUnit(arena, out, negative_lx, u)) {
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
                if (try emitUnit(arena, out, lx, u)) wrote += 1 else out.items.len = at;
            }
        }
        try out.append(arena, ')');
    }
    return true;
}

fn emitOr(arena: Allocator, out: *std.ArrayList(u8), lx: Lx, o: *const Or) Allocator.Error!bool {
    var wrote: usize = 0;
    for (o.branches.items) |b| {
        const at = out.items.len;
        if (wrote > 0) try out.appendSlice(arena, " OR ");
        if (try emitAnd(arena, out, lx, b)) {
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
        .fuzzy => if (t.n > 0) try out.print(arena, "{s}~{d}", .{ t.text, t.n }) else try out.print(arena, "{s}~", .{t.text}),
        .phrase => try out.print(arena, "\"{s}\"", .{t.text}),
        .near => try out.print(arena, "\"{s}\"~{d}", .{ t.text, t.n }),
    }
}

fn showColumn(arena: Allocator, out: *std.ArrayList(u8), col: ?Column) Allocator.Error!void {
    if (col) |c| try out.appendSlice(arena, switch (c) {
        .title => "title:",
        .body => "body:",
    });
}

fn showUnit(arena: Allocator, out: *std.ArrayList(u8), u: Unit) Allocator.Error!bool {
    switch (u) {
        .term => |t| {
            // A term with nothing searchable in it is not shown.
            if (!Lexer.hasWordChar(t.text)) return false;
            try showColumn(arena, out, t.column);
            try showTerm(arena, out, t);
            return true;
        },
        .group => |g| {
            const mark = out.items.len;
            try showColumn(arena, out, g.column);
            try out.append(arena, '(');
            if (!try showOr(arena, out, g.node)) {
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

fn ftsWith(arena: Allocator, lex: *const lexicon.Lexicon, text: []const u8) ![]const u8 {
    return (try parseWith(arena, text, .{ .lexicon = lex })).fts;
}

test "stop words are left out, unless nothing else is left; synonyms widen a word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lex: lexicon.Lexicon = .{};
    var problem: lexicon.Problem = .{};
    try lexicon.addStopWords(a, &lex, "the\nof\n", &problem);
    try lexicon.addSynonyms(a, &lex, "car, auto, motor car\n", &problem);

    try testing.expectEqualStrings("\"history\" AND \"Rome\"", try ftsWith(a, &lex, "the history of Rome"));
    try testing.expectEqualStrings("\"the\" AND \"of\"", try ftsWith(a, &lex, "the of")); // only stop words: kept
    try testing.expectEqualStrings("\"the end\"", try ftsWith(a, &lex, "\"the end\"")); // inside a phrase: kept
    try testing.expectEqualStrings("(\"car\" OR \"auto\" OR \"motor car\") AND \"repair\"", try ftsWith(a, &lex, "car repair"));
    try testing.expectEqualStrings("title : (\"car\" OR \"auto\" OR \"motor car\")", try ftsWith(a, &lex, "title:car"));
    // The readable form shows the query as typed, without the expansions.
    const p = try parseWith(a, "the car", .{ .lexicon = &lex });
    try testing.expectEqualStrings("the AND car", p.shown);
    // Without a lexicon nothing changes.
    try expectFts("the history of Rome", "\"the\" AND \"history\" AND \"of\" AND \"Rome\"");
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

fn parseNow(text: []const u8, now: i64, arena: Allocator) !Parsed {
    return parseWith(arena, text, .{ .now = now });
}

test "filters: text fields, negation, quoting, aliases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "kernel ext:PDF -domain:Example.org author:\"Jo Smith\" tag:Linux site:docs.rs lang:en type:pdf source:notes mime:image/*");
    try testing.expectEqualStrings("\"kernel\"", p.fts);
    try testing.expect(p.advanced);
    try testing.expectEqual(@as(usize, 9), p.filters.len);
    try testing.expectEqual(search.FilterField.ext, p.filters[0].field);
    try testing.expectEqualStrings("pdf", p.filters[0].text); // lower-cased
    try testing.expectEqual(search.FilterField.domain, p.filters[1].field);
    try testing.expect(p.filters[1].negate);
    try testing.expectEqualStrings("example.org", p.filters[1].text);
    try testing.expectEqualStrings("Jo Smith", p.filters[2].text); // a quoted value keeps its spaces and case
    try testing.expectEqualStrings("linux", p.filters[3].text);
    try testing.expectEqual(search.FilterField.domain, p.filters[4].field); // site: is domain:
    try testing.expectEqual(search.FilterField.kind, p.filters[6].field); // type: is kind:
    try testing.expectEqualStrings("image/*", p.filters[8].text);
    try testing.expectEqualStrings("kernel ext:PDF -domain:Example.org author:Jo Smith tag:Linux site:docs.rs lang:en type:pdf source:notes mime:image/*", p.shown);
}

test "filters: sizes and dates, ranges, relative spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const day = 86400;
    const jan1 = 20454 * day; // 2026-01-01 00:00 UTC
    var p = try parseNow("x size:>1mb size:<=10k size:1kb..2kb", 0, a);
    try testing.expectEqual(@as(?i64, (1 << 20) + 1), p.filters[0].min);
    try testing.expectEqual(@as(?i64, 10 * 1024), p.filters[1].max);
    try testing.expectEqual(@as(?i64, 1024), p.filters[2].min);
    try testing.expectEqual(@as(?i64, 2048), p.filters[2].max);

    p = try parseNow("x modified:>2026-01-01 created:2026-01 indexed:2025..2026-02-03 modified:<=2026-01-01", 0, a);
    try testing.expectEqual(@as(?i64, jan1 + day), p.filters[0].min); // after that day
    try testing.expectEqual(@as(?i64, jan1), p.filters[1].min); // the whole month
    try testing.expectEqual(@as(?i64, jan1 + 31 * day - 1), p.filters[1].max);
    try testing.expectEqual(@as(?i64, 20089 * day), p.filters[2].min); // 2025-01-01
    try testing.expectEqual(@as(?i64, (jan1 + 33 * day) + day - 1), p.filters[2].max); // end of 2026-02-03
    try testing.expectEqual(@as(?i64, jan1 + day - 1), p.filters[3].max);

    // Relative spans need a clock.
    p = try parseNow("x modified:7d", jan1, a);
    try testing.expectEqual(@as(?i64, jan1 - 7 * day), p.filters[0].min);
    p = try parseNow("x modified:7d", 0, a);
    try testing.expectEqual(@as(usize, 0), p.filters.len); // not understood: searched as text
    try testing.expectEqualStrings("\"x\" AND \"modified:7d\"", p.fts);
}

test "filters alone are a search; negated filters alone are not; bad values are text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const only = try parse(a, "ext:pdf");
    try testing.expectEqualStrings("", only.fts);
    try testing.expectEqual(@as(usize, 1), only.filters.len);
    try testing.expectEqualStrings("ext:pdf", only.shown);
    try testing.expectError(error.EmptyQuery, parse(a, "-ext:pdf"));
    try testing.expectError(error.EmptyQuery, parse(a, "NOT type:image"));
    for ([_][]const u8{ "size:big", "modified:yesterday", "ext:", "ext:toolongextension", "domain:bad_domain!", "created:2026-13" }) |q| {
        errdefer std.debug.print("query: {s}\n", .{q});
        const p = try parse(a, q);
        try testing.expectEqual(@as(usize, 0), p.filters.len);
        try testing.expect(p.fts.len > 0); // searched as ordinary text
    }
    // Unknown keys stay ordinary text, as before.
    const unknown = try parse(a, "color:red");
    try testing.expectEqualStrings("\"color:red\"", unknown.fts);
    try testing.expectEqual(@as(usize, 0), unknown.filters.len);
}

test "meta fields and columns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parse(a, "x meta.Camera:ACME field.page-count:12");
    try testing.expectEqual(search.FilterField.meta, m.filters[0].field);
    try testing.expectEqualStrings("camera", m.filters[0].key);
    try testing.expectEqualStrings("acme", m.filters[0].text);
    try testing.expectEqualStrings("page-count", m.filters[1].key);

    // Columns restrict a term or a group to the title or the body.
    const c1 = try parse(a, "title:kernel body:module");
    try testing.expectEqualStrings("title : \"kernel\" AND body : \"module\"", c1.fts);
    const c2 = try parse(a, "title:\"window manager\" title:(linux OR bsd)");
    try testing.expectEqualStrings("title : \"window manager\" AND title : (\"linux\" OR \"bsd\")", c2.fts);
    try testing.expectEqualStrings("title:\"window manager\" AND title:(linux OR bsd)", c2.shown);
    const c3 = try parse(a, "x title:");
    try testing.expectEqualStrings("\"x\"", c3.fts); // a dangling column restricts nothing
}

test "syntax cannot reach FTS5: operators, column filters and quotes are inert" {
    try expectFts("title:foo", "title : \"foo\""); // a column restriction the parser itself writes
    try expectFts("bogus:foo", "\"bogus:foo\""); // any other key: is just text
    try expectFts("title:\"a\" : x", "title : \"a\" AND \"x\"");
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
                // The only words the parser writes outside quotes: AND OR NOT NEAR title body.
                ' ', '*', ',', ':', '0'...'9', 'A', 'N', 'D', 'O', 'R', 'T', 'E', 'a'...'z' => {},
                else => return error.UnexpectedCharacterOutsideQuotes,
            }
            try testing.expect(depth >= 0);
        }
        try testing.expect(!in_quote);
        try testing.expectEqual(@as(i32, 0), depth);
    }
}

const CommonSet = struct {
    words: []const []const u8,
    fn is(ctx: *anyopaque, word: []const u8) bool {
        const self: *const CommonSet = @ptrCast(@alignCast(ctx));
        for (self.words) |w| if (std.ascii.eqlIgnoreCase(w, word)) return true;
        return false;
    }
};

test "very common words are not required when the query has other words; the page can say which" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var set: CommonSet = .{ .words = &.{ "to", "in", "the" } };
    const common: Common = .{ .ctx = &set, .isCommon = CommonSet.is };
    const p = try parseWith(a, "how to program in C", .{ .common = common });
    // "how" is a question word, "to" and "in" are very common: none of them is required.
    try testing.expectEqualStrings("\"program\" AND \"C\"", p.fts);
    try testing.expectEqual(@as(usize, 3), p.ignored.len);
    try testing.expectEqualStrings("how", p.ignored[0]);
    try testing.expectEqualStrings("to", p.ignored[1]);
    try testing.expectEqualStrings("in", p.ignored[2]);
    try testing.expect(!p.heavy);
    // The words to find in an excerpt are the ones searched for (lower case), not the left out ones.
    try testing.expectEqual(@as(usize, 2), p.terms.len);
    try testing.expectEqualStrings("program", p.terms[0].text);
    try testing.expectEqualStrings("c", p.terms[1].text);
    // Question words go even where the index has not said they are common, and a query of them alone is searched as typed.
    var none: CommonSet = .{ .words = &.{} };
    const q2 = try parseWith(a, "what is a monad", .{ .common = .{ .ctx = &none, .isCommon = CommonSet.is } });
    try testing.expectEqualStrings("\"monad\"", q2.fts);
    try testing.expectEqual(@as(usize, 3), q2.ignored.len);
    const only_q = try parseWith(a, "what is", .{ .common = .{ .ctx = &none, .isCommon = CommonSet.is } });
    try testing.expectEqualStrings("\"what\" AND \"is\"", only_q.fts);
    // A quoted phrase is exact, a word someone excludes stays excluded, a title-only word is kept.
    const phrase = try parseWith(a, "\"how to\" program", .{ .common = common });
    try testing.expect(std.mem.indexOf(u8, phrase.fts, "\"how to\"") != null and phrase.ignored.len == 0);
    const neg = try parseWith(a, "program -in", .{ .common = common });
    try testing.expect(std.mem.indexOf(u8, neg.fts, "NOT") != null and std.mem.indexOf(u8, neg.fts, "\"in\"") != null);
    const titled = try parseWith(a, "title:the program", .{ .common = common });
    try testing.expect(std.mem.indexOf(u8, titled.fts, "\"the\"") != null);
    // Only very common words: searched after all, and said to be a heavy search.
    const only = try parseWith(a, "to the", .{ .common = common });
    try testing.expectEqualStrings("\"to\" AND \"the\"", only.fts);
    try testing.expect(only.heavy and only.ignored.len == 0);
    // Without the callback every word is required, as typed.
    const plain = try parseWith(a, "how to program in C", .{});
    try testing.expectEqualStrings("\"how\" AND \"to\" AND \"program\" AND \"in\" AND \"C\"", plain.fts);
}

const FormsSet = struct {
    words: []const []const u8,
    fn find(ctx: *anyopaque, arena: Allocator, stem: []const u8, limit: u32) Allocator.Error![]const []const u8 {
        _ = arena;
        _ = limit;
        _ = stem;
        const self: *const FormsSet = @ptrCast(@alignCast(ctx));
        return self.words;
    }
};

test "word forms: a plain word is also the other forms of it that the index has, each as its own word" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var set: FormsSet = .{ .words = &.{ "programming", "programs", "programmatic", "program", "progress" } };
    const forms: Forms = .{ .ctx = &set, .f = FormsSet.find };
    const p = try parseWith(a, "how to program in C", .{ .common = .{ .ctx = @constCast(&CommonSet{ .words = &.{} }), .isCommon = CommonSet.is }, .forms = forms });
    // The typed word first, then its forms (not "programmatic" or "progress"), then the short word as typed.
    try testing.expectEqualStrings("(\"program\" OR \"programming\" OR \"programs\") AND \"C\"", p.fts);
    try testing.expectEqual(@as(usize, 4), p.terms.len);
    try testing.expectEqualStrings("program", p.terms[0].text);
    // Nothing found beyond the word itself: it is searched as typed. Phrases and words to leave out stay as typed.
    var none: FormsSet = .{ .words = &.{"program"} };
    const alone = try parseWith(a, "program", .{ .forms = .{ .ctx = &none, .f = FormsSet.find } });
    try testing.expectEqualStrings("\"program\"", alone.fts);
    const phrase = try parseWith(a, "\"program\" -programming", .{ .forms = forms });
    try testing.expect(std.mem.indexOf(u8, phrase.fts, "NOT (\"programming\")") != null and std.mem.indexOf(u8, phrase.fts, " OR ") == null);
    // Off by default.
    const plain = try parseWith(a, "programming", .{});
    try testing.expectEqualStrings("\"programming\"", plain.fts);
}
