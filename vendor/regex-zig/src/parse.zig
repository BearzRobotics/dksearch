//! Parser for the Perl-style syntax family. Three dialects share one parser:
//!
//!   * .perl       — Perl/PCRE flavour: `^`/`$` match at text boundaries unless
//!                   (?m); (?s) lets `.` match '\n'; `\h` is horizontal space.
//!   * .oniguruma  — Oniguruma "Ruby" flavour as used by Sublime syntaxes:
//!                   `^`/`$` are always line anchors; (?m) lets `.` match '\n';
//!                   `\h` is a hex digit; `{,n}` is accepted.
//!   * .posix_ere  — POSIX extended expressions with the GNU `\w \W \s \S \b \B`
//!                   and back-references: `.` matches '\n', `^`/`$` are text
//!                   anchors, a quantifier may follow a quantifier (`a*?` is
//!                   `(a*)?`, never lazy), `(?` has no meaning, a backslash in
//!                   a bracket expression is a literal, and any other escape
//!                   stands for the character itself. Matching is still
//!                   leftmost-first, so the span of a match may differ from a
//!                   leftmost-longest engine; whether a match exists does not.
//!
//! Matching is byte-based for now: a pattern byte >= 0x80 is a literal byte,
//! and `.` and negated classes consume one byte. Unicode properties (\p{..})
//! are reported as unsupported rather than ignored (SPEC §5).

const std = @import("std");
const ast = @import("ast.zig");
const ByteSet = @import("byteset.zig").ByteSet;

const Node = ast.Node;

pub const Dialect = enum { perl, oniguruma, posix_ere };

pub const Limits = struct {
    max_pattern_len: usize = 64 * 1024,
    max_depth: u32 = 200,
    max_repeat: u32 = 1000,
    max_program_len: usize = 100_000,
    /// Backtracking steps allowed per find call.
    max_steps: u64 = 10_000_000,
    /// Backtrack-stack frames allowed.
    max_stack: usize = 4 * 1024 * 1024,
};

pub const Error = error{
    OutOfMemory,
    /// The pattern is malformed. See the Diagnostic for what and where.
    InvalidPattern,
    /// Valid in some engines but not implemented here. See the Diagnostic.
    Unsupported,
    /// A configured Limits value was exceeded.
    LimitExceeded,
};

/// Describes the first problem found. `message` is a static string.
pub const Diagnostic = struct {
    pos: usize = 0,
    message: []const u8 = "",
};

pub const Name = struct { name: []const u8, index: u32 };

pub const Parsed = struct {
    root: *const Node,
    group_count: u32,
    names: []const Name,
    utf8: bool = false,
};

/// A range of code points.
const Range = struct { lo: u32, hi: u32 };

const max_cp: u32 = 0x10FFFF;

/// The bytes of one UTF-8 sequence class: each position has a range of bytes.
const ByteRange = struct { lo: u8, hi: u8 };

/// Splits the code point range lo..hi into sequences of byte ranges, so that a byte-matching engine matches exactly the
/// characters in it (the classic UTF-8 range splitting; surrogates are left out).
fn utf8Sequences(arena: std.mem.Allocator, lo_in: u32, hi_in: u32, out: *std.ArrayList([]const ByteRange)) std.mem.Allocator.Error!void {
    var lo = lo_in;
    var hi = hi_in;
    if (lo > hi) return;
    // Never encode surrogates.
    if (lo <= 0xDFFF and hi >= 0xD800) {
        if (lo < 0xD800) try utf8Sequences(arena, lo, 0xD7FF, out);
        if (hi > 0xDFFF) try utf8Sequences(arena, 0xE000, hi, out);
        return;
    }
    // Split at the limits of one-, two- and three-byte sequences.
    const limits = [_]u32{ 0x7F, 0x7FF, 0xFFFF };
    for (limits) |m| {
        if (lo <= m and hi > m) {
            try utf8Sequences(arena, lo, m, out);
            try utf8Sequences(arena, m + 1, hi, out);
            return;
        }
    }
    if (hi < 0x80) {
        const seq = try arena.alloc(ByteRange, 1);
        seq[0] = .{ .lo = @intCast(lo), .hi = @intCast(hi) };
        try out.append(arena, seq);
        return;
    }
    // Make the ranges of the continuation bytes full ranges where they can be.
    var i: u5 = 1;
    while (i < 4) : (i += 1) {
        const m: u32 = (@as(u32, 1) << (6 * i)) - 1;
        if ((lo & ~m) != (hi & ~m)) {
            if ((lo & m) != 0) {
                try utf8Sequences(arena, lo, lo | m, out);
                try utf8Sequences(arena, (lo | m) + 1, hi, out);
                return;
            }
            if ((hi & m) != m) {
                try utf8Sequences(arena, lo, (hi & ~m) - 1, out);
                try utf8Sequences(arena, hi & ~m, hi, out);
                return;
            }
        }
    }
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(lo), &a) catch return;
    _ = std.unicode.utf8Encode(@intCast(hi), &b) catch return;
    const seq = try arena.alloc(ByteRange, n);
    for (seq, 0..) |*r, k| r.* = .{ .lo = a[k], .hi = b[k] };
    try out.append(arena, seq);
    lo = 0;
    hi = 0;
}

fn rangeLessThan(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo;
}

/// Sorted, merged ranges.
fn mergeRanges(arena: std.mem.Allocator, ranges: []const Range) std.mem.Allocator.Error![]const Range {
    const copy = try arena.dupe(Range, ranges);
    std.mem.sort(Range, copy, {}, rangeLessThan);
    var out: std.ArrayList(Range) = .empty;
    for (copy) |r| {
        if (out.items.len > 0 and r.lo <= out.items[out.items.len - 1].hi +| 1) {
            if (r.hi > out.items[out.items.len - 1].hi) out.items[out.items.len - 1].hi = r.hi;
        } else try out.append(arena, r);
    }
    return out.items;
}

/// The code points of 0x80..0x10FFFF that `ranges` (sorted, merged) do not contain.
fn complementRanges(arena: std.mem.Allocator, ranges: []const Range) std.mem.Allocator.Error![]const Range {
    var out: std.ArrayList(Range) = .empty;
    var next: u32 = 0x80;
    for (ranges) |r| {
        if (r.hi < 0x80) continue;
        const lo = @max(r.lo, 0x80);
        if (lo > next) try out.append(arena, .{ .lo = next, .hi = lo - 1 });
        next = @max(next, r.hi + 1);
    }
    if (next <= max_cp) try out.append(arena, .{ .lo = next, .hi = max_cp });
    return out.items;
}

fn asciiPart(s: ByteSet) ByteSet {
    return .{ .bits = .{ s.bits[0], s.bits[1], 0, 0 } };
}

fn invertAscii(s: ByteSet) ByteSet {
    return .{ .bits = .{ ~s.bits[0], ~s.bits[1], 0, 0 } };
}

fn seqLen(lead: u8) usize {
    if (lead < 0x80) return 1;
    if (lead >= 0xC2 and lead <= 0xDF) return 2;
    if (lead >= 0xE0 and lead <= 0xEF) return 3;
    if (lead >= 0xF0 and lead <= 0xF4) return 4;
    return 0;
}

const Flags = struct {
    ignore_case: bool = false,
    /// ^ and $ are line anchors (always on for .oniguruma).
    line_anchors: bool = false,
    dot_all: bool = false,
    extended: bool = false,
};

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    dialect: Dialect,
    limits: Limits,
    flags: Flags,
    depth: u32 = 0,
    group_count: u32 = 0,
    names: std.ArrayList(Name) = .empty,
    max_backref: u32 = 0,
    backref_pos: usize = 0,
    diag: *Diagnostic,
    /// Characters, not bytes: `.`, classes, escapes and literals work on whole UTF-8 characters.
    utf8: bool = false,

    fn fail(p: *Parser, err: Error, pos: usize, msg: []const u8) Error {
        p.diag.* = .{ .pos = pos, .message = msg };
        return err;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn eat(p: *Parser, c: u8) bool {
        if (p.peek() == c) {
            p.pos += 1;
            return true;
        }
        return false;
    }

    fn startsWith(p: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, p.src[p.pos..], s);
    }

    fn node(p: *Parser, n: Node) Error!*const Node {
        const ptr = try p.arena.create(Node);
        ptr.* = n;
        return ptr;
    }

    fn enter(p: *Parser) Error!void {
        p.depth += 1;
        if (p.depth > p.limits.max_depth)
            return p.fail(error.LimitExceeded, p.pos, "pattern nesting too deep");
    }

    fn leave(p: *Parser) void {
        p.depth -= 1;
    }

    // alt := concat ('|' concat)*
    fn parseAlt(p: *Parser) Error!*const Node {
        try p.enter();
        defer p.leave();
        const first = try p.parseConcat();
        if (p.peek() != '|') return first;
        var alts: std.ArrayList(*const Node) = .empty;
        try alts.append(p.arena, first);
        while (p.eat('|')) try alts.append(p.arena, try p.parseConcat());
        return p.node(.{ .alt = alts.items });
    }

    fn parseConcat(p: *Parser) Error!*const Node {
        var items: std.ArrayList(*const Node) = .empty;
        while (true) {
            p.skipExtended();
            const c = p.peek() orelse break;
            if (c == '|' or c == ')') break;
            if (p.startsWith("\\Q")) {
                // \Q...\E: literal text. A following quantifier binds to the
                // last character only, as in Perl.
                p.pos += 2;
                const body_start = p.pos;
                const end = std.mem.indexOfPos(u8, p.src, body_start, "\\E") orelse p.src.len;
                p.pos = if (end == p.src.len) end else end + 2;
                if (end == body_start) continue;
                for (p.src[body_start .. end - 1]) |b| try items.append(p.arena, try p.literal(b));
                try items.append(p.arena, try p.parseQuantifiers(try p.literal(p.src[end - 1])));
                continue;
            }
            const atom = (try p.parseAtom()) orelse continue;
            try items.append(p.arena, try p.parseQuantifiers(atom));
        }
        return switch (items.items.len) {
            0 => p.node(.empty),
            1 => items.items[0],
            else => p.node(.{ .concat = items.items }),
        };
    }

    /// In extended mode, skip whitespace and `# comment` lines.
    fn skipExtended(p: *Parser) void {
        if (!p.flags.extended) return;
        while (p.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c) {
                p.pos += 1;
            } else if (c == '#') {
                while (p.peek()) |d| : (p.pos += 1) if (d == '\n') break;
            } else break;
        }
    }

    const Quant = struct { min: u32, max: ?u32, braces: bool };

    /// Parses a quantifier at the cursor, or returns null leaving the cursor
    /// untouched (a `{` that is not a valid quantifier is a literal).
    fn tryQuantifier(p: *Parser) Error!?Quant {
        const c = p.peek() orelse return null;
        switch (c) {
            '*' => {
                p.pos += 1;
                return .{ .min = 0, .max = null, .braces = false };
            },
            '+' => {
                p.pos += 1;
                return .{ .min = 1, .max = null, .braces = false };
            },
            '?' => {
                p.pos += 1;
                return .{ .min = 0, .max = 1, .braces = false };
            },
            '{' => {
                const save = p.pos;
                p.pos += 1;
                const lo = p.number();
                var hi: ?u32 = lo;
                var has_comma = false;
                if (p.eat(',')) {
                    has_comma = true;
                    hi = p.number();
                }
                const closed = p.eat('}');
                const valid = closed and (lo != null or (has_comma and hi != null and p.dialect == .oniguruma));
                if (!valid) {
                    p.pos = save;
                    return null;
                }
                const min = lo orelse 0;
                const max: ?u32 = if (has_comma) hi else min;
                if (max) |m| if (m < min)
                    return p.fail(error.InvalidPattern, save, "repeat range is reversed");
                if (min > p.limits.max_repeat or (max orelse 0) > p.limits.max_repeat)
                    return p.fail(error.LimitExceeded, save, "repeat count too large");
                return .{ .min = min, .max = max, .braces = true };
            },
            else => return null,
        }
    }

    fn number(p: *Parser) ?u32 {
        const start = p.pos;
        var v: u64 = 0;
        while (p.peek()) |c| : (p.pos += 1) {
            if (c < '0' or c > '9') break;
            v = @min(v * 10 + (c - '0'), std.math.maxInt(u32));
        }
        return if (p.pos == start) null else @intCast(v);
    }

    fn parseQuantifiers(p: *Parser, atom: *const Node) Error!*const Node {
        var cur = atom;
        var count: u32 = 0;
        while (true) {
            p.skipExtended();
            const qpos = p.pos;
            const q = (try p.tryQuantifier()) orelse break;
            if (count > 0 and p.dialect == .perl)
                return p.fail(error.InvalidPattern, qpos, "nested quantifier");
            var greed: ast.Greed = .greedy;
            if (p.dialect == .posix_ere) {
                // No lazy or possessive forms: a following `?` or `+` is
                // another quantifier, read on the next turn of the loop.
            } else if (p.eat('?')) {
                greed = .lazy;
            } else if (p.peek() == '+' and !(q.braces and p.dialect == .oniguruma)) {
                p.pos += 1;
                greed = .possessive;
            }
            try p.enter();
            cur = try p.node(.{ .repeat = .{ .sub = cur, .min = q.min, .max = q.max, .greed = greed } });
            count += 1;
        }
        p.depth -= count;
        return cur;
    }

    /// Returns null for constructs that produce no node (comments, flag changes).
    fn parseAtom(p: *Parser) Error!?*const Node {
        const c = p.src[p.pos];
        switch (c) {
            '(' => return p.parseGroup(),
            '[' => {
                p.pos += 1;
                if (p.utf8) return try p.parseClassUtf8();
                return try p.node(.{ .set = try p.parseClass() });
            },
            '.' => {
                p.pos += 1;
                if (p.utf8) return try p.anyCharNode(p.flags.dot_all);
                return try p.node(.{ .any = p.flags.dot_all });
            },
            '^' => {
                p.pos += 1;
                return try p.node(.{ .assertion = if (p.flags.line_anchors) .line_start else .text_start });
            },
            '$' => {
                p.pos += 1;
                return try p.node(.{ .assertion = if (p.flags.line_anchors) .line_end else .text_end_or_final_newline });
            },
            '\\' => return p.parseEscape(),
            '*', '+', '?' => return p.fail(error.InvalidPattern, p.pos, "quantifier has nothing to repeat"),
            '{' => {
                // A valid quantifier here has nothing to repeat; otherwise literal.
                const save = p.pos;
                if (try p.tryQuantifier()) |_|
                    return p.fail(error.InvalidPattern, save, "quantifier has nothing to repeat");
                p.pos += 1;
                return try p.literal('{');
            },
            else => {
                if (p.utf8 and c >= 0x80) return try p.charNode(try p.readCp());
                p.pos += 1;
                return try p.literal(c);
            },
        }
    }

    // ---- UTF-8 mode ------------------------------------------------------

    /// Reads one character of the pattern (the cursor is on its first byte).
    fn readCp(p: *Parser) Error!u32 {
        const start = p.pos;
        const n = seqLen(p.src[p.pos]);
        if (n == 0 or p.pos + n > p.src.len) return p.fail(error.InvalidPattern, start, "the pattern is not valid UTF-8");
        const cp = std.unicode.utf8Decode(p.src[p.pos .. p.pos + n]) catch return p.fail(error.InvalidPattern, start, "the pattern is not valid UTF-8");
        p.pos += n;
        return cp;
    }

    /// A character as a node: a byte for ASCII, otherwise a group of its bytes (so a quantifier applies to all of them).
    fn charNode(p: *Parser, cp: u32) Error!*const Node {
        if (cp < 0x80) return p.literal(@intCast(cp));
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return p.fail(error.InvalidPattern, p.pos, "not a valid code point");
        const parts = try p.arena.alloc(*const Node, n);
        for (parts, buf[0..n]) |*part, b| part.* = try p.node(.{ .byte = b });
        const seq = try p.node(.{ .concat = parts });
        return p.node(.{ .group = .{ .sub = seq, .index = null } });
    }

    fn seqNode(p: *Parser, seq: []const ByteRange) Error!*const Node {
        const parts = try p.arena.alloc(*const Node, seq.len);
        for (parts, seq) |*part, r| {
            var s: ByteSet = .{};
            s.addRange(r.lo, r.hi);
            part.* = try p.node(.{ .set = s });
        }
        if (parts.len == 1) return parts[0];
        return p.node(.{ .concat = parts });
    }

    /// A class over characters: `ascii` for the bytes below 0x80, `ranges` for the code points above. Negation covers
    /// all characters.
    fn classNode(p: *Parser, ascii_in: ByteSet, ranges_in: []const Range, negate: bool) Error!*const Node {
        var ascii = asciiPart(ascii_in);
        var ranges = try mergeRanges(p.arena, ranges_in);
        if (negate) {
            ascii = invertAscii(ascii);
            ranges = try complementRanges(p.arena, ranges);
        }
        var alts: std.ArrayList(*const Node) = .empty;
        if (ascii.bits[0] != 0 or ascii.bits[1] != 0) try alts.append(p.arena, try p.node(.{ .set = ascii }));
        var seqs: std.ArrayList([]const ByteRange) = .empty;
        for (ranges) |r| try utf8Sequences(p.arena, @max(r.lo, 0x80), r.hi, &seqs);
        for (seqs.items) |seq| try alts.append(p.arena, try p.seqNode(seq));
        if (alts.items.len == 0) return p.node(.{ .set = .{} }); // matches nothing
        if (alts.items.len == 1) return alts.items[0];
        return p.node(.{ .alt = alts.items });
    }

    /// `.` over characters: any ASCII byte (not a newline unless `dot_all`) or any whole multi-byte character.
    fn anyCharNode(p: *Parser, dot_all: bool) Error!*const Node {
        var ascii: ByteSet = .{};
        ascii.addRange(0, 0x7F);
        if (!dot_all) ascii.bits[0] &= ~(@as(u64, 1) << '\n');
        return p.classNode(ascii, &.{.{ .lo = 0x80, .hi = max_cp }}, false);
    }

    /// `\d \w \s \h` and their capitals over characters: digits, spaces and hex digits are ASCII; every non-ASCII
    /// character counts as a word character, and so as a non-digit, non-space.
    fn classEscapeNode(p: *Parser, c: u8) Error!?*const Node {
        const base = p.classEscape(std.ascii.toLower(c)) orelse return null;
        const upper = std.ascii.isUpper(c);
        const word = std.ascii.toLower(c) == 'w';
        const nonascii = if (upper) !word else word;
        const ascii = if (upper) invertAscii(base) else asciiPart(base);
        if (nonascii) return try p.classNode(ascii, &.{.{ .lo = 0x80, .hi = max_cp }}, false);
        return try p.classNode(ascii, &.{}, false);
    }

    /// A class `[...]` over characters (the cursor is just past '[').
    fn parseClassUtf8(p: *Parser) Error!*const Node {
        const open = p.pos - 1;
        try p.enter();
        defer p.leave();
        var ascii: ByteSet = .{};
        var ranges: std.ArrayList(Range) = .empty;
        const negate = p.eat('^');
        var first = true;
        while (true) {
            const c = p.peek() orelse return p.fail(error.InvalidPattern, open, "unterminated character class");
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            if (c == '[') {
                if (p.startsWith("[:")) {
                    if (try p.posixClass()) |s| {
                        ascii.unionWith(asciiPart(s));
                        continue;
                    }
                }
                p.pos += 1;
                // A nested class: its characters join this one (a negated nested class is not supported over characters).
                const inner = p.pos;
                _ = inner;
                return p.fail(error.Unsupported, open, "nested character classes over characters");
            }
            if (c == '&' and p.startsWith("&&")) return p.fail(error.Unsupported, p.pos, "class intersection &&");
            const lo = (try p.classItemUtf8(&ascii, &ranges)) orelse continue;
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                const save = p.pos;
                p.pos += 1;
                if (p.peek().? == '[') {
                    p.pos = save;
                    p.addCp(&ascii, &ranges, lo, lo);
                    continue;
                }
                var scratch_ascii: ByteSet = .{};
                var scratch_ranges: std.ArrayList(Range) = .empty;
                const hi = (try p.classItemUtf8(&scratch_ascii, &scratch_ranges)) orelse {
                    p.addCp(&ascii, &ranges, lo, lo);
                    p.addCp(&ascii, &ranges, '-', '-');
                    ascii.unionWith(scratch_ascii);
                    try ranges.appendSlice(p.arena, scratch_ranges.items);
                    continue;
                };
                if (hi < lo) return p.fail(error.InvalidPattern, save, "character class range is reversed");
                p.addCp(&ascii, &ranges, lo, hi);
            } else p.addCp(&ascii, &ranges, lo, lo);
        }
        if (p.flags.ignore_case) ascii.addAsciiCaseCounterparts();
        return p.classNode(ascii, ranges.items, negate);
    }

    fn addCp(p: *Parser, ascii: *ByteSet, ranges: *std.ArrayList(Range), lo: u32, hi: u32) void {
        if (lo < 0x80) ascii.addRange(@intCast(lo), @intCast(@min(hi, 0x7F)));
        if (hi >= 0x80) ranges.append(p.arena, .{ .lo = @max(lo, 0x80), .hi = hi }) catch {};
    }

    /// One element of a class over characters: its code point, or null after adding a class escape (\d, \w, ...).
    fn classItemUtf8(p: *Parser, ascii: *ByteSet, ranges: *std.ArrayList(Range)) Error!?u32 {
        const c = p.src[p.pos];
        if (c != '\\' or p.dialect == .posix_ere) return try p.readCp();
        const at = p.pos;
        p.pos += 1;
        const e = p.peek() orelse return p.fail(error.InvalidPattern, at, "pattern ends with a backslash");
        p.pos += 1;
        if (p.classEscape(std.ascii.toLower(e))) |base| {
            const upper = std.ascii.isUpper(e);
            const word = std.ascii.toLower(e) == 'w';
            const nonascii = if (upper) !word else word;
            ascii.unionWith(if (upper) invertAscii(base) else asciiPart(base));
            if (nonascii) try ranges.append(p.arena, .{ .lo = 0x80, .hi = max_cp });
            return null;
        }
        if (e == 'b') return 0x08;
        if (e == 'p' or e == 'P') return p.fail(error.Unsupported, at, "Unicode property \\p{...}");
        if (try p.byteEscape(e, at)) |b| return b;
        return p.fail(error.InvalidPattern, at, "unknown escape sequence in class");
    }

    fn literal(p: *Parser, c: u8) Error!*const Node {
        if (p.flags.ignore_case and std.ascii.isAlphabetic(c)) {
            var s: ByteSet = .{};
            s.add(c);
            s.addAsciiCaseCounterparts();
            return p.node(.{ .set = s });
        }
        return p.node(.{ .byte = c });
    }

    fn parseGroup(p: *Parser) Error!?*const Node {
        const open = p.pos;
        p.pos += 1; // '('
        // Flags set inside a group end with it; `(?i)` alone is the exception
        // and keeps its effect until the enclosing group closes.
        const saved = p.flags;

        if (p.dialect == .posix_ere or !p.eat('?')) {
            p.group_count += 1;
            return p.finishGroup(open, .{ .capture = p.group_count }, saved);
        }
        const c = p.peek() orelse return p.fail(error.InvalidPattern, open, "unterminated group");
        switch (c) {
            ':' => {
                p.pos += 1;
                return p.finishGroup(open, .plain, saved);
            },
            '>' => {
                p.pos += 1;
                return p.finishGroup(open, .atomic, saved);
            },
            '=' => {
                p.pos += 1;
                return p.finishGroup(open, .{ .look = .{ .ahead = true, .negate = false } }, saved);
            },
            '!' => {
                p.pos += 1;
                return p.finishGroup(open, .{ .look = .{ .ahead = true, .negate = true } }, saved);
            },
            '#' => {
                while (p.peek()) |d| : (p.pos += 1) if (d == ')') break;
                if (!p.eat(')')) return p.fail(error.InvalidPattern, open, "unterminated comment");
                return null;
            },
            '<' => {
                if (p.startsWith("<=")) {
                    p.pos += 2;
                    return p.finishGroup(open, .{ .look = .{ .ahead = false, .negate = false } }, saved);
                }
                if (p.startsWith("<!")) {
                    p.pos += 2;
                    return p.finishGroup(open, .{ .look = .{ .ahead = false, .negate = true } }, saved);
                }
                p.pos += 1;
                return p.namedGroup(open, '>', saved);
            },
            '\'' => {
                p.pos += 1;
                return p.namedGroup(open, '\'', saved);
            },
            'P' => {
                p.pos += 1;
                if (!p.eat('<')) return p.fail(error.Unsupported, open, "(?P construct other than (?P<name>");
                return p.namedGroup(open, '>', saved);
            },
            '~' => return p.fail(error.Unsupported, open, "absent operator (?~...)"),
            '|' => return p.fail(error.Unsupported, open, "branch reset group (?|...)"),
            else => return p.parseFlagGroup(open, saved),
        }
    }

    fn namedGroup(p: *Parser, open: usize, close: u8, saved: Flags) Error!?*const Node {
        const start = p.pos;
        while (p.peek()) |d| : (p.pos += 1) {
            if (d == close) break;
            if (!(std.ascii.isAlphanumeric(d) or d == '_'))
                return p.fail(error.InvalidPattern, p.pos, "invalid character in group name");
        }
        if (p.pos == start or !p.eat(close))
            return p.fail(error.InvalidPattern, open, "malformed group name");
        const name = p.src[start .. p.pos - 1];
        p.group_count += 1;
        try p.names.append(p.arena, .{ .name = name, .index = p.group_count });
        return p.finishGroup(open, .{ .capture = p.group_count }, saved);
    }

    /// (?flags) or (?flags:subpattern). Flags: i m s x, `-` turns the rest off.
    fn parseFlagGroup(p: *Parser, open: usize, saved: Flags) Error!?*const Node {
        var on = true;
        var f = p.flags;
        while (true) {
            const c = p.peek() orelse return p.fail(error.InvalidPattern, open, "unterminated group");
            p.pos += 1;
            switch (c) {
                '-' => on = false,
                'i' => f.ignore_case = on,
                'x' => f.extended = on,
                // m and s swap meaning between the dialects.
                'm' => switch (p.dialect) {
                    .perl, .posix_ere => f.line_anchors = on,
                    .oniguruma => f.dot_all = on,
                },
                's' => switch (p.dialect) {
                    .perl, .posix_ere => f.dot_all = on,
                    .oniguruma => return p.fail(error.InvalidPattern, p.pos - 1, "unknown flag 's' in Oniguruma syntax"),
                },
                ')' => {
                    p.flags = f;
                    return null;
                },
                ':' => {
                    p.flags = f;
                    return p.finishGroup(open, .plain, saved);
                },
                else => return p.fail(error.Unsupported, p.pos - 1, "unsupported inline flag"),
            }
        }
    }

    const GroupKind = union(enum) {
        plain,
        capture: u32,
        atomic,
        look: struct { ahead: bool, negate: bool },
    };

    fn finishGroup(p: *Parser, open: usize, kind: GroupKind, saved: Flags) Error!*const Node {
        const sub = try p.parseAlt();
        p.flags = saved;
        if (!p.eat(')')) return p.fail(error.InvalidPattern, open, "unterminated group");
        return switch (kind) {
            .plain => p.node(.{ .group = .{ .sub = sub, .index = null } }),
            .capture => |i| p.node(.{ .group = .{ .sub = sub, .index = i } }),
            .atomic => p.node(.{ .atomic = sub }),
            .look => |l| p.node(.{ .look = .{ .sub = sub, .ahead = l.ahead, .negate = l.negate } }),
        };
    }

    // ---- escapes -------------------------------------------------------

    fn classEscape(p: *Parser, c: u8) ?ByteSet {
        var s: ByteSet = .{};
        switch (std.ascii.toLower(c)) {
            'd' => s.addRange('0', '9'),
            'w' => {
                s.addRange('a', 'z');
                s.addRange('A', 'Z');
                s.addRange('0', '9');
                s.add('_');
            },
            's' => {
                s.add(' ');
                s.addRange('\t', '\r');
            },
            'h' => switch (p.dialect) {
                .oniguruma => {
                    s.addRange('0', '9');
                    s.addRange('a', 'f');
                    s.addRange('A', 'F');
                },
                .perl, .posix_ere => {
                    s.add(' ');
                    s.add('\t');
                },
            },
            else => return null,
        }
        if (std.ascii.isUpper(c)) s.invert();
        return s;
    }

    /// A single-byte escape (after the backslash): \n \t \xHH \0oo and escaped
    /// punctuation. The cursor is just past the escape letter.
    fn byteEscape(p: *Parser, c: u8, at: usize) Error!?u32 {
        switch (c) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            'f' => return 0x0c,
            'v' => return 0x0b,
            'a' => return 0x07,
            'e' => return 0x1b,
            '0' => {
                var v: u32 = 0;
                var n: u8 = 0;
                while (n < 2) : (n += 1) {
                    const d = p.peek() orelse break;
                    if (d < '0' or d > '7') break;
                    v = v * 8 + (d - '0');
                    p.pos += 1;
                }
                return v;
            },
            'x' => {
                var digits: []const u8 = undefined;
                if (p.eat('{')) {
                    const s = p.pos;
                    while (p.peek()) |d| : (p.pos += 1) if (d == '}') break;
                    digits = p.src[s..p.pos];
                    if (!p.eat('}')) return p.fail(error.InvalidPattern, at, "unterminated \\x{...}");
                } else {
                    const s = p.pos;
                    while (p.pos - s < 2 and p.pos < p.src.len and std.ascii.isHex(p.src[p.pos])) p.pos += 1;
                    digits = p.src[s..p.pos];
                }
                const v = std.fmt.parseInt(u32, digits, 16) catch
                    return p.fail(error.InvalidPattern, at, "invalid hexadecimal escape");
                if (p.utf8) {
                    if (v > max_cp or (v >= 0xD800 and v <= 0xDFFF)) return p.fail(error.InvalidPattern, at, "not a valid code point");
                } else if (v > 0xff) return p.fail(error.Unsupported, at, "code point above 0xFF (needs the UTF-8 mode)");
                return v;
            },
            else => {
                if (std.ascii.isAlphanumeric(c)) return null;
                return c;
            },
        }
    }

    fn parseEscape(p: *Parser) Error!?*const Node {
        const at = p.pos;
        p.pos += 1; // backslash
        const c = p.peek() orelse return p.fail(error.InvalidPattern, at, "pattern ends with a backslash");
        p.pos += 1;

        if (p.dialect == .posix_ere) return p.posixEscape(c, at);
        if (p.utf8) {
            if (try p.classEscapeNode(c)) |n| return n;
        } else if (p.classEscape(c)) |s| return try p.node(.{ .set = s });
        switch (c) {
            'b' => return try p.node(.{ .assertion = .word_boundary }),
            'B' => return try p.node(.{ .assertion = .not_word_boundary }),
            'A' => return try p.node(.{ .assertion = .text_start }),
            'z' => return try p.node(.{ .assertion = .text_end }),
            'Z' => return try p.node(.{ .assertion = .text_end_or_final_newline }),
            'G' => return try p.node(.{ .assertion = .search_start }),
            'p', 'P' => return p.fail(error.Unsupported, at, "Unicode property \\p{...}"),
            'R', 'X', 'K', 'C' => return p.fail(error.Unsupported, at, "unsupported escape"),
            'E' => return null,
            'k' => {
                const open = p.peek() orelse return p.fail(error.InvalidPattern, at, "malformed \\k");
                const close: u8 = switch (open) {
                    '<' => '>',
                    '\'' => '\'',
                    else => return p.fail(error.InvalidPattern, at, "malformed \\k"),
                };
                p.pos += 1;
                const s = p.pos;
                while (p.peek()) |d| : (p.pos += 1) if (d == close) break;
                const name = p.src[s..p.pos];
                if (!p.eat(close)) return p.fail(error.InvalidPattern, at, "malformed \\k");
                for (p.names.items) |n| if (std.mem.eql(u8, n.name, name))
                    return try p.node(.{ .backref = .{ .index = n.index, .ignore_case = p.flags.ignore_case } });
                return p.fail(error.InvalidPattern, at, "reference to unknown group name");
            },
            '1'...'9' => {
                p.pos -= 1;
                const n = p.number().?;
                if (n > p.max_backref) {
                    p.max_backref = n;
                    p.backref_pos = at;
                }
                return try p.node(.{ .backref = .{ .index = n, .ignore_case = p.flags.ignore_case } });
            },
            else => {},
        }
        if (try p.byteEscape(c, at)) |b| return if (p.utf8) try p.charNode(b) else try p.literal(@intCast(b));
        return p.fail(error.InvalidPattern, at, "unknown escape sequence");
    }

    /// An escape in POSIX ERE (GNU flavour): word and space classes, word
    /// boundaries and back-references; anything else is the character itself.
    fn posixEscape(p: *Parser, c: u8, at: usize) Error!*const Node {
        switch (c) {
            'w', 'W', 's', 'S' => return if (p.utf8) (try p.classEscapeNode(c)).? else try p.node(.{ .set = p.classEscape(c).? }),
            'b' => return try p.node(.{ .assertion = .word_boundary }),
            'B' => return try p.node(.{ .assertion = .not_word_boundary }),
            '<', '>' => return p.fail(error.Unsupported, at, "word-start and word-end anchors \\< and \\>"),
            '1'...'9' => {
                const n: u32 = c - '0';
                if (n > p.max_backref) {
                    p.max_backref = n;
                    p.backref_pos = at;
                }
                return try p.node(.{ .backref = .{ .index = n, .ignore_case = p.flags.ignore_case } });
            },
            else => {
                if (p.utf8 and c >= 0x80) {
                    p.pos -= 1;
                    return try p.charNode(try p.readCp());
                }
                return try p.literal(c);
            },
        }
    }

    // ---- character classes ----------------------------------------------

    /// Cursor is just past '['. Consumes through the closing ']'.
    fn parseClass(p: *Parser) Error!ByteSet {
        const open = p.pos - 1;
        try p.enter();
        defer p.leave();
        var set: ByteSet = .{};
        const negate = p.eat('^');
        var first = true;
        while (true) {
            const c = p.peek() orelse return p.fail(error.InvalidPattern, open, "unterminated character class");
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            if (c == '[') {
                if (p.startsWith("[:")) {
                    if (try p.posixClass()) |s| {
                        set.unionWith(s);
                        continue;
                    }
                }
                p.pos += 1;
                set.unionWith(try p.parseClass());
                continue;
            }
            if (c == '&' and p.startsWith("&&"))
                return p.fail(error.Unsupported, p.pos, "class intersection &&");

            const lo = (try p.classItem(&set)) orelse continue;
            // Range?
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                const save = p.pos;
                p.pos += 1;
                const nxt = p.peek().?;
                if (nxt == '[') {
                    p.pos = save; // '-' followed by a nested class: literal '-'
                    set.add(lo);
                    continue;
                }
                var scratch: ByteSet = .{};
                const hi = (try p.classItem(&scratch)) orelse {
                    // Range to a class escape like [a-\d]: treat '-' literally.
                    set.add(lo);
                    set.add('-');
                    set.unionWith(scratch);
                    continue;
                };
                if (hi < lo) return p.fail(error.InvalidPattern, save, "character class range is reversed");
                set.addRange(lo, hi);
            } else set.add(lo);
        }
        if (p.flags.ignore_case) set.addAsciiCaseCounterparts();
        if (negate) set.invert();
        return set;
    }

    /// One element inside a class. Returns the byte for a single-byte item, or
    /// null after adding a multi-byte item (\d, \w, ...) straight into `set`.
    fn classItem(p: *Parser, set: *ByteSet) Error!?u8 {
        const c = p.src[p.pos];
        p.pos += 1;
        // In a POSIX bracket expression a backslash is an ordinary character.
        if (c != '\\' or p.dialect == .posix_ere) return c;
        const at = p.pos - 1;
        const e = p.peek() orelse return p.fail(error.InvalidPattern, at, "pattern ends with a backslash");
        p.pos += 1;
        if (p.classEscape(e)) |s| {
            set.unionWith(s);
            return null;
        }
        if (e == 'b') return 0x08; // \b inside a class is backspace
        if (e == 'p' or e == 'P') return p.fail(error.Unsupported, at, "Unicode property \\p{...}");
        if (try p.byteEscape(e, at)) |b| return @intCast(b);
        return p.fail(error.InvalidPattern, at, "unknown escape sequence in class");
    }

    /// At "[:". Returns the set for [:name:] / [:^name:], or null (cursor
    /// unmoved) when this is not a POSIX class, so the caller treats '[' as a
    /// nested class.
    fn posixClass(p: *Parser) Error!?ByteSet {
        const start = p.pos;
        const end = std.mem.indexOfPos(u8, p.src, start + 2, ":]") orelse return null;
        var name = p.src[start + 2 .. end];
        const neg = name.len > 0 and name[0] == '^';
        if (neg) name = name[1..];
        var s: ByteSet = .{};
        if (std.mem.eql(u8, name, "alpha")) {
            s.addRange('a', 'z');
            s.addRange('A', 'Z');
        } else if (std.mem.eql(u8, name, "digit")) {
            s.addRange('0', '9');
        } else if (std.mem.eql(u8, name, "alnum")) {
            s.addRange('a', 'z');
            s.addRange('A', 'Z');
            s.addRange('0', '9');
        } else if (std.mem.eql(u8, name, "upper")) {
            s.addRange('A', 'Z');
        } else if (std.mem.eql(u8, name, "lower")) {
            s.addRange('a', 'z');
        } else if (std.mem.eql(u8, name, "space")) {
            s.add(' ');
            s.addRange('\t', '\r');
        } else if (std.mem.eql(u8, name, "blank")) {
            s.add(' ');
            s.add('\t');
        } else if (std.mem.eql(u8, name, "punct")) {
            s.addRange('!', '/');
            s.addRange(':', '@');
            s.addRange('[', '`');
            s.addRange('{', '~');
        } else if (std.mem.eql(u8, name, "xdigit")) {
            s.addRange('0', '9');
            s.addRange('a', 'f');
            s.addRange('A', 'F');
        } else if (std.mem.eql(u8, name, "word")) {
            s.addRange('a', 'z');
            s.addRange('A', 'Z');
            s.addRange('0', '9');
            s.add('_');
        } else if (std.mem.eql(u8, name, "cntrl")) {
            s.addRange(0, 31);
            s.add(127);
        } else if (std.mem.eql(u8, name, "print")) {
            s.addRange(32, 126);
        } else if (std.mem.eql(u8, name, "graph")) {
            s.addRange(33, 126);
        } else if (std.mem.eql(u8, name, "ascii")) {
            s.addRange(0, 127);
        } else return p.fail(error.InvalidPattern, start, "unknown POSIX class name");
        p.pos = end + 2;
        if (neg) s.invert();
        return s;
    }
};

pub fn parse(
    arena: std.mem.Allocator,
    pattern: []const u8,
    dialect: Dialect,
    ignore_case: bool,
    limits: Limits,
    diag: *Diagnostic,
    utf8: bool,
) Error!Parsed {
    diag.* = .{};
    if (pattern.len > limits.max_pattern_len) {
        diag.* = .{ .pos = 0, .message = "pattern too long" };
        return error.LimitExceeded;
    }
    var p: Parser = .{
        .arena = arena,
        .src = pattern,
        .dialect = dialect,
        .limits = limits,
        .flags = .{ .ignore_case = ignore_case, .line_anchors = dialect == .oniguruma, .dot_all = dialect == .posix_ere },
        .diag = diag,
        .utf8 = utf8,
    };
    const root = try p.parseAlt();
    if (p.pos < pattern.len) return p.fail(error.InvalidPattern, p.pos, "unmatched ')'");
    if (p.max_backref > p.group_count)
        return p.fail(error.InvalidPattern, p.backref_pos, "reference to a group that does not exist");
    return .{ .root = root, .group_count = p.group_count, .names = p.names.items, .utf8 = utf8 };
}
