//! A deliberately modest MediaWiki wikitext to plain text converter
//! (docs/decisions/0007, decision 7). It aims at text that searches well, not
//! at rendering faithfully:
//!
//!   * templates `{{...}}`, tables `{|...|}` and HTML comments are dropped;
//!   * `<ref>`, `<gallery>`, `<math>` and similar tags are dropped with their
//!     content; other tags are dropped and their content kept;
//!   * `[[target|label]]` becomes its label, `[[target]]` its target; file,
//!     image, category and media links are dropped;
//!   * `[http://url label]` becomes its label;
//!   * bold and italic quotes, list markers and heading marks are removed,
//!     keeping the text; common HTML entities are decoded;
//!   * from the first level-2 heading such as "References" or "External
//!     links" on, nothing is kept: those sections are lists of citations.
//!
//! It runs in time linear in the input, whatever the input: an opening
//! construct with no close is tried once and then treated as plain text, and
//! nesting depth is bounded. Output is valid UTF-8 whenever the input is,
//! because only ASCII structure is ever touched.

const std = @import("std");
const Allocator = std.mem.Allocator;

const max_depth = 8;

/// Tags removed together with everything inside them.
const dropped_tags = [_][]const u8{
    "ref",    "references", "gallery",  "math",    "timeline",     "imagemap",  "syntaxhighlight",
    "source", "score",      "mapframe", "maplink", "templatedata", "noinclude", "chem",
};

/// Level-2 headings after which the rest of the article is not kept.
const stop_headings = [_][]const u8{
    "references", "external links", "see also",  "notes", "further reading", "bibliography",
    "sources",    "footnotes",      "citations",
};

const Converter = struct {
    arena: Allocator,
    out: std.ArrayList(u8) = .empty,
    /// Set once a search for a closing delimiter failed: from then on that
    /// construct is plain text, which keeps the whole conversion linear.
    no_template_close: bool = false,
    no_link_close: bool = false,
    no_table_close: bool = false,
    stopped: bool = false,

    fn run(self: *Converter, src: []const u8, depth: u8, inline_only: bool) Allocator.Error!void {
        var i: usize = 0;
        while (i < src.len and !self.stopped) {
            const at_line_start = !inline_only and (i == 0 or src[i - 1] == '\n');
            if (at_line_start) {
                if (try self.lineStart(src, &i, depth)) continue;
            }
            const ch = src[i];
            switch (ch) {
                '<' => {
                    if (std.mem.startsWith(u8, src[i..], "<!--")) {
                        const end = std.mem.indexOfPos(u8, src, i + 4, "-->");
                        i = if (end) |e| e + 3 else src.len;
                        continue;
                    }
                    if (try self.tag(src, &i)) continue;
                },
                '{' => {
                    if (std.mem.startsWith(u8, src[i..], "{{") and !self.no_template_close) {
                        if (findClose(src, i + 2, "{{", "}}")) |end| {
                            i = end + 2;
                            continue;
                        }
                        self.no_template_close = true;
                    } else if (std.mem.startsWith(u8, src[i..], "{|") and !self.no_table_close) {
                        if (findTableClose(src, i + 2)) |end| {
                            i = end + 2;
                            continue;
                        }
                        self.no_table_close = true;
                    }
                },
                '[' => {
                    if (std.mem.startsWith(u8, src[i..], "[[") and !self.no_link_close) {
                        if (findClose(src, i + 2, "[[", "]]")) |end| {
                            try self.link(src[i + 2 .. end], depth);
                            i = end + 2;
                            continue;
                        }
                        self.no_link_close = true;
                    } else if (try self.externalLink(src, &i, depth)) continue;
                },
                '\'' => {
                    if (std.mem.startsWith(u8, src[i..], "''")) {
                        while (i < src.len and src[i] == '\'') i += 1;
                        continue;
                    }
                },
                '&' => if (try self.entity(src, &i)) continue,
                '_' => {
                    // Magic words such as __TOC__.
                    if (std.mem.startsWith(u8, src[i..], "__")) {
                        var j = i + 2;
                        while (j < src.len and (std.ascii.isUpper(src[j]))) j += 1;
                        if (j > i + 2 and std.mem.startsWith(u8, src[j..], "__")) {
                            i = j + 2;
                            continue;
                        }
                    }
                },
                else => {},
            }
            try self.out.append(self.arena, ch);
            i += 1;
        }
    }

    /// Handles headings, list markers and rules at the start of a line.
    /// Returns true if it consumed input.
    fn lineStart(self: *Converter, src: []const u8, i: *usize, depth: u8) Allocator.Error!bool {
        const start = i.*;
        const ch = src[start];
        if (ch == '=') {
            const nl = std.mem.indexOfScalarPos(u8, src, start, '\n') orelse src.len;
            const line = std.mem.trim(u8, src[start..nl], " \t\r");
            if (line.len >= 3 and line[line.len - 1] == '=') {
                var lead: usize = 0;
                while (lead < line.len and line[lead] == '=') lead += 1;
                var trail: usize = 0;
                while (trail < line.len - lead and line[line.len - 1 - trail] == '=') trail += 1;
                if (lead < line.len and trail > 0) {
                    const level = @min(lead, trail);
                    const text = std.mem.trim(u8, line[lead .. line.len - trail], " \t");
                    if (level == 2 and isStopHeading(text)) {
                        self.stopped = true;
                        return true;
                    }
                    try self.out.append(self.arena, '\n');
                    if (depth < max_depth) try self.run(text, depth + 1, true);
                    i.* = nl;
                    return true;
                }
            }
            return false;
        }
        if (ch == '*' or ch == '#' or ch == ':' or ch == ';') {
            var j = start;
            while (j < src.len and (src[j] == '*' or src[j] == '#' or src[j] == ':' or src[j] == ';')) j += 1;
            while (j < src.len and src[j] == ' ') j += 1;
            i.* = j;
            return true;
        }
        if (ch == '-' and std.mem.startsWith(u8, src[start..], "----")) {
            var j = start;
            while (j < src.len and src[j] == '-') j += 1;
            i.* = j;
            return true;
        }
        return false;
    }

    /// `<...>`: drops the tag, and its content for `dropped_tags`.
    fn tag(self: *Converter, src: []const u8, i: *usize) Allocator.Error!bool {
        const start = i.*;
        const limit = @min(src.len, start + 1024);
        const close = std.mem.indexOfScalarPos(u8, src[0..limit], start + 1, '>') orelse return false;
        var j = start + 1;
        const closing = j < close and src[j] == '/';
        if (closing) j += 1;
        const name_start = j;
        while (j < close and std.ascii.isAlphanumeric(src[j])) j += 1;
        const name = src[name_start..j];
        if (name.len == 0) return false; // "a < b" is just text

        const self_closing = src[close - 1] == '/';
        if (!closing and !self_closing) {
            for (dropped_tags) |d| {
                if (std.ascii.eqlIgnoreCase(name, d)) {
                    i.* = findEndTag(src, close + 1, name) orelse close + 1;
                    return true;
                }
            }
        }
        if (std.ascii.eqlIgnoreCase(name, "br")) try self.out.append(self.arena, '\n');
        i.* = close + 1;
        return true;
    }

    fn link(self: *Converter, inner: []const u8, depth: u8) Allocator.Error!void {
        var body = inner;
        if (body.len > 0 and body[0] == ':') body = body[1..];
        const pipe = std.mem.indexOfScalar(u8, body, '|');
        const target = std.mem.trim(u8, if (pipe) |p| body[0..p] else body, " \t\r\n");
        if (std.mem.indexOfScalar(u8, target, ':')) |colon| {
            const ns = target[0..colon];
            for ([_][]const u8{ "file", "image", "category", "media" }) |drop| {
                if (inner.len > 0 and inner[0] != ':' and std.ascii.eqlIgnoreCase(std.mem.trim(u8, ns, " "), drop)) return;
            }
        }
        const label = if (pipe) |p| std.mem.trim(u8, body[p + 1 ..], " \t\r\n") else "";
        if (label.len == 0) {
            // [[target]], or the "pipe trick" [[target|]]: show the target
            // without a leading namespace and without a #section.
            var shown = target;
            if (pipe != null) {
                if (std.mem.indexOfScalar(u8, shown, ':')) |k| shown = shown[k + 1 ..];
            }
            if (std.mem.indexOfScalar(u8, shown, '#')) |h| if (h > 0) {
                shown = shown[0..h];
            };
            // Through `run` so entities such as &nbsp; in the target are decoded.
            if (depth < max_depth) try self.run(shown, depth + 1, true) else try self.out.appendSlice(self.arena, shown);
        } else if (depth < max_depth) {
            try self.run(label, depth + 1, true);
        }
    }

    /// `[http://example.org label]` -> label.
    fn externalLink(self: *Converter, src: []const u8, i: *usize, depth: u8) Allocator.Error!bool {
        const start = i.*;
        const rest = src[start + 1 ..];
        if (!(std.mem.startsWith(u8, rest, "http://") or std.mem.startsWith(u8, rest, "https://") or std.mem.startsWith(u8, rest, "//"))) return false;
        const limit = @min(src.len, start + 2048);
        const close = std.mem.indexOfScalarPos(u8, src[0..limit], start + 1, ']') orelse return false;
        const nl = std.mem.indexOfScalarPos(u8, src[0..close], start + 1, '\n');
        if (nl != null) return false;
        const inner = src[start + 1 .. close];
        if (std.mem.indexOfScalar(u8, inner, ' ')) |sp| {
            if (depth < max_depth) try self.run(std.mem.trim(u8, inner[sp + 1 ..], " "), depth + 1, true);
        }
        i.* = close + 1;
        return true;
    }

    fn entity(self: *Converter, src: []const u8, i: *usize) Allocator.Error!bool {
        const start = i.*;
        const semi = std.mem.indexOfScalarPos(u8, src[0..@min(src.len, start + 12)], start + 1, ';') orelse return false;
        const name = src[start + 1 .. semi];
        const named = [_]struct { []const u8, []const u8 }{
            .{ "nbsp", " " },         .{ "amp", "&" },           .{ "lt", "<" },           .{ "gt", ">" },
            .{ "quot", "\"" },        .{ "apos", "'" },          .{ "ndash", "\u{2013}" }, .{ "mdash", "\u{2014}" },
            .{ "minus", "\u{2212}" }, .{ "hellip", "\u{2026}" }, .{ "times", "\u{00d7}" }, .{ "deg", "\u{00b0}" },
        };
        for (named) |n| {
            if (std.mem.eql(u8, name, n[0])) {
                try self.out.appendSlice(self.arena, n[1]);
                i.* = semi + 1;
                return true;
            }
        }
        if (name.len >= 2 and name[0] == '#') {
            const cp = (if (name[1] == 'x' or name[1] == 'X')
                std.fmt.parseInt(u21, name[2..], 16)
            else
                std.fmt.parseInt(u21, name[1..], 10)) catch return false;
            if (cp == 0 or !std.unicode.utf8ValidCodepoint(cp)) return false;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch return false;
            try self.out.appendSlice(self.arena, buf[0..n]);
            i.* = semi + 1;
            return true;
        }
        return false;
    }
};

fn isStopHeading(text: []const u8) bool {
    for (stop_headings) |h| if (std.ascii.eqlIgnoreCase(text, h)) return true;
    return false;
}

/// Index of the delimiter that closes the construct opened just before
/// `start`, counting nested openers; null if there is none.
fn findClose(s: []const u8, start: usize, open: []const u8, close: []const u8) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i + 1 < s.len) {
        if (std.mem.startsWith(u8, s[i..], close)) {
            depth -= 1;
            if (depth == 0) return i;
            i += close.len;
        } else if (std.mem.startsWith(u8, s[i..], open)) {
            depth += 1;
            i += open.len;
        } else i += 1;
    }
    return null;
}

/// Index of the `|}` that closes the table opened just before `start`.
/// Like MediaWiki, only `{|` and `|}` at the start of a line count, so a
/// template argument list ending in `|}}` inside a table does not close it;
/// templates inside a table are skipped as a whole.
fn findTableClose(s: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    // Move to the start of the next line.
    while (i < s.len) {
        const nl = std.mem.indexOfScalarPos(u8, s, i, '\n') orelse return null;
        i = nl + 1;
        var j = i;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
        if (std.mem.startsWith(u8, s[j..], "|}")) {
            depth -= 1;
            if (depth == 0) return j;
        } else if (std.mem.startsWith(u8, s[j..], "{|")) {
            depth += 1;
        }
    }
    return null;
}

/// Index just after `</name>` (case-insensitive), searching from `from`.
fn findEndTag(s: []const u8, from: usize, name: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, s, i, '<')) |lt| {
        if (lt + 2 + name.len <= s.len and s[lt + 1] == '/' and std.ascii.eqlIgnoreCase(s[lt + 2 .. lt + 2 + name.len], name)) {
            const gt = std.mem.indexOfScalarPos(u8, s, lt, '>') orelse return null;
            return gt + 1;
        }
        i = lt + 1;
    }
    return null;
}

/// Converts `src` to plain text in memory from `arena`.
pub fn convert(arena: Allocator, src: []const u8) Allocator.Error![]const u8 {
    var c: Converter = .{ .arena = arena };
    try c.run(src, 0, false);
    return tidy(arena, c.out.items);
}

/// Trims lines, collapses runs of spaces and of blank lines, and trims the end.
fn tidy(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var blank_run: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) {
            blank_run += 1;
            continue;
        }
        if (out.items.len > 0) try out.appendSlice(arena, if (blank_run > 0) "\n\n" else "\n");
        blank_run = 0;
        var prev_space = false;
        for (line) |ch| {
            const sp = ch == ' ' or ch == '\t';
            if (sp and prev_space) continue;
            try out.append(arena, if (sp) ' ' else ch);
            prev_space = sp;
        }
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectConv(src: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try convert(arena.allocator(), src);
    try testing.expectEqualStrings(want, got);
}

test "links keep their label or target; special links are dropped" {
    try expectConv("A [[lighthouse]] and [[Rhubarb|the plant]].", "A lighthouse and the plant.");
    try expectConv("See [[Foo#Bar|baz]] and [[Foo#Bar]] and [[:Category:Things]].", "See baz and Foo and Category:Things.");
    try expectConv("x [[File:Pic.jpg|thumb|A [[nested]] caption]] y [[Category:Stuff]] z", "x y z");
    try expectConv("[[Wikipedia:Style|]] and [[Help:Contents|]]", "Style and Contents");
}

test "templates, tables, comments and refs are removed" {
    try expectConv("Start {{Infobox|a={{nested|b}}|c=d}} end.", "Start end.");
    try expectConv("Before\n{|\n|-\n| cell {{x}}\n|}\nAfter", "Before\n\nAfter");
    try expectConv("a<!-- hidden\nmulti-line -->b", "ab");
    try expectConv("Fact.<ref name=a>Source {{cite}}</ref> More.<ref name=b/> End.", "Fact. More. End.");
    try expectConv("x<math>a^2+b^2</math>y<gallery>\nFile:a.jpg\n</gallery>z", "xyz");
}

test "bare link targets decode entities; tables ignore |} inside templates" {
    try expectConv("[[Pope Leo&nbsp;III]] crowned him.", "Pope Leo III crowned him.");
    // From a real article: a family-tree template ends in `|}}` inside a table.
    try expectConv("Before\n{|\n{{tree chart | | |F|~|J|}}\n{{tree chart/end}}\n|}\nAfter [[x]]", "Before\n\nAfter x");
    // Nested tables, and a table with no close stays plain text.
    try expectConv("a\n{|\n| x\n{|\n| y\n|}\n|}\nb", "a\n\nb");
    try expectConv("a\n{|\n| never closed", "a\n{|\n| never closed");
}

test "formatting marks are removed, text is kept" {
    try expectConv("'''Bold''' and ''italic'' and '''''both'''''.", "Bold and italic and both.");
    try expectConv("It's fine, don't worry.", "It's fine, don't worry.");
    try expectConv("* one\n* two\n** nested\n# three\n: indented", "one\ntwo\nnested\nthree\nindented");
    try expectConv("<b>bold</b> a<br />b <span class=\"x\">span</span>", "bold a\nb span");
    try expectConv("a < b and c > d", "a < b and c > d");
    try expectConv("Text __TOC__ more __NOTOC__", "Text more");
}

test "headings keep their text; reference-like sections end the article" {
    try expectConv("Intro.\n\n== History ==\nThe past.\n=== Early ===\nEarlier.\n", "Intro.\n\nHistory\nThe past.\n\nEarly\nEarlier.");
    try expectConv("Body.\n== See also ==\n* [[Other]]\n== References ==\n{{reflist}}\n", "Body.");
    try expectConv("Body.\n== External links ==\n* [http://x.org X]\n", "Body.");
    // Only level 2 stops; the word elsewhere is ordinary text.
    try expectConv("A note on references.\n=== Notes ===\nkept", "A note on references.\n\nNotes\nkept");
}

test "external links, entities and character references" {
    try expectConv("See [http://example.org the site] or [http://example.org] or [https://a.b/c label two].", "See the site or or label two.");
    try expectConv("5&nbsp;km &ndash; 6 &amp; 7 &lt;ok&gt; &#8212; &#x41;", "5 km \u{2013} 6 & 7 <ok> \u{2014} A");
    try expectConv("not &an entity; &#0; &#xD800; &", "not &an entity; &#0; &#xD800; &");
}

test "unicode text is preserved byte for byte" {
    try expectConv("Café [[Société générale|Société]] \u{4e2d}\u{6587} ☃", "Café Société \u{4e2d}\u{6587} ☃");
}

test "unclosed constructs are plain text, and cost stays linear" {
    try expectConv("a {{ never closed", "a {{ never closed");
    try expectConv("a [[ never closed", "a [[ never closed");
    try expectConv("a <ref>never closed", "a never closed"); // the stray tag goes, the text stays
    // Hostile input: many openers, no closers. Must finish quickly.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = 200_000;
    const evil = try arena.allocator().alloc(u8, n * 2);
    for (0..n) |k| {
        evil[2 * k] = '{';
        evil[2 * k + 1] = '{';
    }
    _ = try convert(arena.allocator(), evil);
    const evil2 = try arena.allocator().alloc(u8, n * 2);
    for (0..n) |k| {
        evil2[2 * k] = '[';
        evil2[2 * k + 1] = '[';
    }
    _ = try convert(arena.allocator(), evil2);
}

test "deep nesting is bounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    for (0..2000) |_| try buf.appendSlice(arena.allocator(), "[[a|");
    try buf.appendSlice(arena.allocator(), "deep");
    for (0..2000) |_| try buf.appendSlice(arena.allocator(), "]]");
    const out = try convert(arena.allocator(), buf.items);
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "blank lines and spaces are tidied" {
    try expectConv("  a   b  \n\n\n\n  c\n", "a b\n\nc");
    try expectConv("", "");
    try expectConv("{{only a template}}", "");
}

test "random markup soup: no crash, valid UTF-8, bounded output" {
    var prng = std.Random.DefaultPrng.init(0x77e1);
    const rnd = prng.random();
    const pieces = [_][]const u8{
        "[[",   "]]",      "{{",  "}}", "{|",          "|}",           "|",    "<ref>", "</ref>",    "<ref name=x/>", "<!--",    "-->",              "<",            ">",
        "==",   "=",       "'''", "''", "*",           "#",            ":",    ";",     "&nbsp;",    "&#x41;",        "&#0;",    "&",                "[http://a b]", "[",
        "]",    "__TOC__", "\n",  " ",  "caf\xc3\xa9", "\xe4\xb8\xad", "word", "File:", "Category:", "<math>",        "</math>", "== References ==", "<gallery>",    "</gallery>",
        "----",
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for (0..4000) |_| {
        _ = arena_state.reset(.retain_capacity);
        var src: std.ArrayList(u8) = .empty;
        const n = rnd.uintLessThan(usize, 60);
        for (0..n) |_| src.appendSlice(arena_state.allocator(), pieces[rnd.uintLessThan(usize, pieces.len)]) catch unreachable;
        const out = try convert(arena_state.allocator(), src.items);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
        try testing.expect(out.len <= src.items.len + 8);
        try testing.expect(std.mem.indexOfScalar(u8, out, 0) == null);
    }
}
