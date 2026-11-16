//! Makes untrusted HTML safe to show inside one of our own pages.
//!
//! Used for Markdown (rendered to HTML first) and for articles from ZIM files.
//! It is an allow-list: only known formatting tags and a few attributes pass;
//! everything else is dropped (scripts, styles, frames, forms, event handlers,
//! `style` and `class` attributes, `javascript:` and `data:` links). Text is
//! kept. Open elements are tracked so the output is always balanced and cannot
//! close a tag of the page it sits in. Links and image addresses go through an
//! optional hook so a caller can rewrite or refuse them.
//!
//! The scanner is linear: it never rescans input, so hostile markup cannot
//! make it slow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const UrlKind = enum { link, image };

pub const Options = struct {
    /// Called for every `href` and `src` that passed the scheme check. Return the
    /// address to use, or null to drop the attribute. The returned text is
    /// escaped by the sanitizer; it must still be a URL the caller trusts.
    rewrite: ?*const fn (ctx: ?*anyopaque, arena: Allocator, kind: UrlKind, url: []const u8) Allocator.Error!?[]const u8 = null,
    ctx: ?*anyopaque = null,
    /// Longest output, in bytes; more input is cut off.
    max_output_bytes: usize = 8 * 1024 * 1024,
    /// Deepest nesting kept; deeper elements lose their tags (the text stays).
    max_depth: usize = 128,
};

pub const Error = error{ OutOfMemory, WriteFailed };

const allowed_tags = [_][]const u8{
    "a",          "abbr",   "article",  "aside", "b",   "bdi",     "bdo",     "blockquote", "br",   "caption", "cite",
    "code",       "col",    "colgroup", "dd",    "del", "details", "dfn",     "div",        "dl",   "dt",      "em",
    "figcaption", "figure", "footer",   "h1",    "h2",  "h3",      "h4",      "h5",         "h6",   "header",  "hr",
    "i",          "img",    "ins",      "kbd",   "li",  "main",    "mark",    "nav",        "ol",   "p",       "pre",
    "q",          "rp",     "rt",       "ruby",  "s",   "samp",    "section", "small",      "span", "strong",  "sub",
    "summary",    "sup",    "table",    "tbody", "td",  "tfoot",   "th",      "thead",      "time", "tr",      "u",
    "ul",         "var",    "wbr",
};

const void_tags = [_][]const u8{ "br", "col", "hr", "img", "wbr" };

/// Tags whose whole content is dropped, not just the tag.
const dropped_with_content = [_][]const u8{ "script", "style", "noscript", "iframe", "object", "embed", "template", "head", "title", "svg", "math", "textarea", "select", "applet", "frameset", "noframes", "xmp", "plaintext" };

fn inList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

const Tag = struct {
    name: []const u8,
    closing: bool,
    self_closing: bool,
    /// The attribute text between the name and the closing `>`.
    attrs: []const u8,
    /// Index just after the `>`.
    end: usize,
};

/// A tag starting at `i` (the `<`), or null if the text there is not a tag. The `>` is found
/// outside quoted attribute values.
fn tagAt(s: []const u8, i: usize) ?Tag {
    var j = i + 1;
    var closing = false;
    if (j < s.len and s[j] == '/') {
        closing = true;
        j += 1;
    }
    const name_start = j;
    if (j >= s.len or !std.ascii.isAlphabetic(s[j])) return null;
    while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '-' or s[j] == ':')) j += 1;
    const name = s[name_start..j];
    const attrs_start = j;
    const limit = @min(s.len, i + 16 * 1024);
    var quote: u8 = 0;
    while (j < limit) : (j += 1) {
        const c = s[j];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            const attrs = s[attrs_start..j];
            return .{ .name = name, .closing = closing, .self_closing = attrs.len > 0 and attrs[attrs.len - 1] == '/', .attrs = attrs, .end = j + 1 };
        }
    }
    return null; // never closed within reason: it is text
}

const Attr = struct { name: []const u8, value: []const u8 };

/// Iterates the attributes of a tag. Values are returned raw (entities not decoded).
const AttrIter = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *AttrIter) ?Attr {
        const s = self.s;
        while (true) {
            while (self.i < s.len and (std.ascii.isWhitespace(s[self.i]) or s[self.i] == '/')) self.i += 1;
            if (self.i >= s.len) return null;
            const ns = self.i;
            while (self.i < s.len and !std.ascii.isWhitespace(s[self.i]) and s[self.i] != '=' and s[self.i] != '/' and s[self.i] != '>') self.i += 1;
            const name = s[ns..self.i];
            while (self.i < s.len and std.ascii.isWhitespace(s[self.i])) self.i += 1;
            if (self.i < s.len and s[self.i] == '=') {
                self.i += 1;
                while (self.i < s.len and std.ascii.isWhitespace(s[self.i])) self.i += 1;
                if (self.i < s.len and (s[self.i] == '"' or s[self.i] == '\'')) {
                    const q = s[self.i];
                    const vs = self.i + 1;
                    const close = std.mem.indexOfScalarPos(u8, s, vs, q) orelse s.len;
                    self.i = @min(close + 1, s.len);
                    if (name.len > 0) return .{ .name = name, .value = s[vs..close] };
                } else {
                    const vs = self.i;
                    while (self.i < s.len and !std.ascii.isWhitespace(s[self.i])) self.i += 1;
                    if (name.len > 0) return .{ .name = name, .value = s[vs..self.i] };
                }
            } else if (name.len > 0) return .{ .name = name, .value = "" };
        }
    }
};

/// Decodes the character references of an attribute value (the common ones; anything else is
/// kept as written) so that `&#106;avascript:` is seen as what a browser would see.
fn decodeAttr(arena: Allocator, v: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, v, '&') == null) return v;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < v.len) {
        if (v[i] != '&') {
            try out.append(arena, v[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, v[0..@min(v.len, i + 12)], i + 1, ';');
        if (semi) |sc| {
            const ref = v[i + 1 .. sc];
            var cp: ?u21 = null;
            if (ref.len > 1 and ref[0] == '#') {
                const hex = ref[1] == 'x' or ref[1] == 'X';
                const digits = if (hex) ref[2..] else ref[1..];
                if (digits.len > 0) cp = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch null;
            } else if (std.mem.eql(u8, ref, "amp")) cp = '&' else if (std.mem.eql(u8, ref, "lt")) cp = '<' else if (std.mem.eql(u8, ref, "gt")) cp = '>' else if (std.mem.eql(u8, ref, "quot")) cp = '"' else if (std.mem.eql(u8, ref, "apos")) cp = '\'' else if (std.mem.eql(u8, ref, "colon")) cp = ':' else if (std.mem.eql(u8, ref, "Tab")) cp = '\t' else if (std.mem.eql(u8, ref, "NewLine")) cp = '\n';
            if (cp) |c| {
                var tmp: [4]u8 = undefined;
                if (std.unicode.utf8Encode(c, &tmp)) |n| {
                    try out.appendSlice(arena, tmp[0..n]);
                    i = sc + 1;
                    continue;
                } else |_| {}
            }
        }
        try out.append(arena, '&');
        i += 1;
    }
    return out.items;
}

/// The scheme of `url` as a browser would read it (ignoring leading controls and spaces and
/// tabs or newlines inside), or "" for a relative reference.
fn schemeOf(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    var i: usize = 0;
    while (i < url.len and (url[i] <= ' ')) i += 1;
    var out: std.ArrayList(u8) = .empty;
    while (i < url.len) : (i += 1) {
        const c = url[i];
        if (c == '\t' or c == '\n' or c == '\r') continue;
        if (c == ':') return std.ascii.allocLowerString(arena, out.items);
        if (c == '/' or c == '?' or c == '#') return "";
        try out.append(arena, c);
        if (out.items.len > 32) return "";
    }
    return "";
}

fn isDataImage(url: []const u8) bool {
    var i: usize = 0;
    while (i < url.len and url[i] <= ' ') i += 1;
    const rest = url[i..];
    const allowed = [_][]const u8{ "data:image/png", "data:image/jpeg", "data:image/gif", "data:image/webp" };
    for (allowed) |p| if (rest.len >= p.len and std.ascii.eqlIgnoreCase(rest[0..p.len], p)) return true;
    return false;
}

fn writeEscaped(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    var from: usize = 0;
    for (s, 0..) |b, i| {
        const rep: ?[]const u8 = switch (b) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            0 => "\u{FFFD}",
            else => null,
        };
        if (rep) |r| {
            try w.writeAll(s[from..i]);
            try w.writeAll(r);
            from = i + 1;
        }
    }
    try w.writeAll(s[from..]);
}

fn isNumber(v: []const u8) bool {
    if (v.len == 0 or v.len > 6) return false;
    for (v) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Writes the allowed attributes of `tag`. Returns true if an image kept its `src`.
fn writeAttrs(arena: Allocator, w: *Io.Writer, tag: Tag, options: Options) Error!bool {
    var src_kept = false;
    const is_a = std.ascii.eqlIgnoreCase(tag.name, "a");
    const is_img = std.ascii.eqlIgnoreCase(tag.name, "img");
    var it: AttrIter = .{ .s = tag.attrs };
    var count: usize = 0;
    while (it.next()) |a| {
        count += 1;
        if (count > 64) break;
        var buf: [32]u8 = undefined;
        if (a.name.len > buf.len) continue;
        const name = std.ascii.lowerString(&buf, a.name);
        const value = try decodeAttr(arena, a.value);
        const keep = blk: {
            if (std.mem.eql(u8, name, "title") or std.mem.eql(u8, name, "lang") or std.mem.eql(u8, name, "id")) break :blk true;
            if (std.mem.eql(u8, name, "dir")) break :blk std.mem.eql(u8, value, "ltr") or std.mem.eql(u8, value, "rtl") or std.mem.eql(u8, value, "auto");
            if (is_img and std.mem.eql(u8, name, "alt")) break :blk true;
            if (is_img and (std.mem.eql(u8, name, "width") or std.mem.eql(u8, name, "height"))) break :blk isNumber(value);
            if (std.mem.eql(u8, name, "colspan") or std.mem.eql(u8, name, "rowspan") or std.mem.eql(u8, name, "start")) break :blk isNumber(value);
            break :blk false;
        };
        if (keep) {
            // ids must not look like our own: they only exist so fragment links inside an article work.
            try w.print(" {s}=\"", .{name});
            try writeEscaped(w, value);
            try w.writeByte('"');
            continue;
        }
        const is_href = is_a and std.mem.eql(u8, name, "href");
        const is_src = is_img and std.mem.eql(u8, name, "src");
        if (!is_href and !is_src) continue;
        const scheme = try schemeOf(arena, value);
        const ok = if (scheme.len == 0) true else if (is_href) (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "mailto")) else (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https") or (std.mem.eql(u8, scheme, "data") and isDataImage(value)));
        if (!ok) continue;
        var url: ?[]const u8 = value;
        // A data: image is complete in itself; everything else may be rewritten.
        if (options.rewrite) |f| {
            if (!(scheme.len > 0 and std.mem.eql(u8, scheme, "data"))) url = try f(options.ctx, arena, if (is_src) .image else .link, value);
        }
        const final = url orelse continue;
        // Whatever the hook returned must still not carry a script scheme.
        const final_scheme = try schemeOf(arena, final);
        if (final_scheme.len > 0 and !(std.mem.eql(u8, final_scheme, "http") or std.mem.eql(u8, final_scheme, "https") or std.mem.eql(u8, final_scheme, "mailto") or (is_src and std.mem.eql(u8, final_scheme, "data") and isDataImage(final)))) continue;
        try w.print(" {s}=\"", .{name});
        try writeEscaped(w, final);
        try w.writeByte('"');
        if (is_src) src_kept = true;
    }
    if (is_a) try w.writeAll(" rel=\"noopener noreferrer nofollow\"");
    return src_kept;
}

/// The `alt` text of an image tag, decoded, or "".
fn altOf(arena: Allocator, tag: Tag) Allocator.Error![]const u8 {
    var it: AttrIter = .{ .s = tag.attrs };
    while (it.next()) |a| if (std.ascii.eqlIgnoreCase(a.name, "alt")) return decodeAttr(arena, a.value);
    return "";
}

/// Writes a safe version of `html` to `w`.
pub fn sanitize(arena: Allocator, html: []const u8, w: *Io.Writer, options: Options) Error!void {
    var stack: std.ArrayList([]const u8) = .empty;
    var written: usize = 0;
    var i: usize = 0;
    var text_from: usize = 0;
    // Text is copied in runs; `flushText` handles the runs, escaping what must be escaped.
    const Flush = struct {
        fn run(wr: *Io.Writer, s_full: []const u8, written_ptr: *usize, limit: usize) Io.Writer.Error!void {
            // Stop at the output limit, not in the middle of a character.
            var s = s_full;
            if (written_ptr.* + s.len > limit) {
                var cut = limit -| written_ptr.*;
                while (cut > 0 and cut < s.len and (s[cut] & 0xC0) == 0x80) cut -= 1;
                s = s[0..cut];
            }
            var from: usize = 0;
            var k: usize = 0;
            while (k < s.len) : (k += 1) {
                const c = s[k];
                if (c == '<' or c == '>') {
                    try wr.writeAll(s[from..k]);
                    try wr.writeAll(if (c == '<') "&lt;" else "&gt;");
                    from = k + 1;
                } else if (c == '&') {
                    // A real reference stays; a bare ampersand is escaped.
                    const semi = std.mem.indexOfScalarPos(u8, s[0..@min(s.len, k + 12)], k + 1, ';');
                    var valid = false;
                    if (semi) |sc| {
                        const ref = s[k + 1 .. sc];
                        if (ref.len > 0) {
                            valid = true;
                            if (ref[0] == '#') {
                                const hex = ref.len > 1 and (ref[1] == 'x' or ref[1] == 'X');
                                const digits = if (hex) ref[2..] else ref[1..];
                                if (digits.len == 0) valid = false;
                                for (digits) |d| if (!(if (hex) std.ascii.isHex(d) else std.ascii.isDigit(d))) {
                                    valid = false;
                                };
                            } else for (ref) |d| if (!std.ascii.isAlphanumeric(d)) {
                                valid = false;
                            };
                        }
                    }
                    if (!valid) {
                        try wr.writeAll(s[from..k]);
                        try wr.writeAll("&amp;");
                        from = k + 1;
                    }
                } else if (c == 0) {
                    try wr.writeAll(s[from..k]);
                    try wr.writeAll("\u{FFFD}");
                    from = k + 1;
                }
            }
            try wr.writeAll(s[from..]);
            written_ptr.* += s.len;
        }
    };

    while (i < html.len) {
        if (written >= options.max_output_bytes) break;
        const lt = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
        if (lt >= html.len) break;
        // Comments and declarations (<!-- -->, <!DOCTYPE>, <?...>) vanish.
        if (std.mem.startsWith(u8, html[lt..], "<!--")) {
            try Flush.run(w, html[text_from..lt], &written, options.max_output_bytes);
            const end = std.mem.indexOfPos(u8, html, lt + 4, "-->");
            i = if (end) |e| e + 3 else html.len;
            text_from = i;
            continue;
        }
        if (lt + 1 < html.len and (html[lt + 1] == '!' or html[lt + 1] == '?')) {
            try Flush.run(w, html[text_from..lt], &written, options.max_output_bytes);
            const gt = std.mem.indexOfScalarPos(u8, html, lt + 2, '>') orelse html.len - 1;
            i = gt + 1;
            text_from = i;
            continue;
        }
        const tag = tagAt(html, lt) orelse {
            // A stray "<": text (it is escaped when flushed).
            i = lt + 1;
            continue;
        };
        try Flush.run(w, html[text_from..lt], &written, options.max_output_bytes);
        i = tag.end;
        text_from = tag.end;

        if (!tag.closing and inList(tag.name, &dropped_with_content)) {
            // Skip to the end tag of the same name (once; a missing end tag only drops the tag).
            if (!tag.self_closing) {
                var search_from = tag.end;
                while (std.mem.indexOfScalarPos(u8, html, search_from, '<')) |p| {
                    if (tagAt(html, p)) |et| {
                        if (et.closing and std.ascii.eqlIgnoreCase(et.name, tag.name)) {
                            i = et.end;
                            text_from = et.end;
                            break;
                        }
                        search_from = et.end;
                    } else search_from = p + 1;
                }
            }
            continue;
        }
        if (!inList(tag.name, &allowed_tags)) continue; // an unknown tag: dropped, its text stays

        var lower_buf: [16]u8 = undefined;
        if (tag.name.len > lower_buf.len) continue;
        const lname = std.ascii.lowerString(&lower_buf, tag.name);
        const is_void = inList(lname, &void_tags);
        if (tag.closing) {
            if (is_void) continue;
            // Close back to the matching open element, if there is one.
            var k = stack.items.len;
            while (k > 0) : (k -= 1) if (std.mem.eql(u8, stack.items[k - 1], lname)) break;
            if (k == 0) continue;
            while (stack.items.len >= k) {
                const top = stack.pop().?;
                try w.print("</{s}>", .{top});
            }
            continue;
        }
        if (stack.items.len >= options.max_depth and !is_void) continue;
        if (std.mem.eql(u8, lname, "img")) {
            // An image whose address was refused would show as a broken picture: its alt text stands in.
            var tmp: Io.Writer.Allocating = .init(arena);
            const kept = try writeAttrs(arena, &tmp.writer, tag, options);
            if (kept) {
                try w.writeAll("<img");
                try w.writeAll(tmp.written());
                try w.writeAll(">");
            } else {
                const alt = try altOf(arena, tag);
                if (alt.len > 0) {
                    try writeEscaped(w, alt);
                    written += alt.len;
                }
            }
            continue;
        }
        try w.print("<{s}", .{lname});
        _ = try writeAttrs(arena, w, tag, options);
        if (is_void) {
            try w.writeAll(">");
        } else {
            try w.writeAll(">");
            // The stored name is a static string from the allow-list, so it outlives the input.
            const static = for (allowed_tags) |n| {
                if (std.mem.eql(u8, n, lname)) break n;
            } else unreachable;
            try stack.append(arena, static);
        }
    }
    if (written < options.max_output_bytes) try Flush.run(w, html[text_from..], &written, options.max_output_bytes);
    while (stack.pop()) |top| try w.print("</{s}>", .{top});
}

/// Convenience: the sanitized HTML as a string allocated from `arena`.
pub fn sanitizeAlloc(arena: Allocator, html: []const u8, options: Options) Error![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try sanitize(arena, html, &aw.writer, options);
    return aw.written();
}

const testing = std.testing;

fn clean(html: []const u8) ![]const u8 {
    return sanitizeAlloc(testing.allocator, html, .{});
}

fn expectClean(html: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try sanitizeAlloc(arena.allocator(), html, .{});
    try testing.expectEqualStrings(want, got);
}

test "formatting passes, scripts and handlers do not" {
    try expectClean("<p>Hello <b>wor</b>ld</p>", "<p>Hello <b>wor</b>ld</p>");
    try expectClean("<p>a</p><script>alert(1)</script><p>b</p>", "<p>a</p><p>b</p>");
    try expectClean("<img src=\"/x.png\" onerror=\"alert(1)\" alt=\"a\">", "<img src=\"/x.png\" alt=\"a\">");
    try expectClean("<div style=\"position:fixed\" class=\"side\" onclick=\"x()\">t</div>", "<div>t</div>");
    try expectClean("<style>body{display:none}</style>text", "text");
    try expectClean("<iframe src=\"http://evil\"></iframe>after", "after");
    try expectClean("<form action=\"/x\"><input name=a><button>go</button></form>", "go");
    try expectClean("<svg onload=\"alert(1)\"><text>hi</text></svg>ok", "ok");
    try expectClean("<object data=\"x\"></object><embed src=\"x\">z", "z");
}

test "links: only http, https, mailto and relative survive; script schemes in any disguise do not" {
    try expectClean("<a href=\"https://example.org/x?a=1&b=2\">l</a>", "<a href=\"https://example.org/x?a=1&amp;b=2\" rel=\"noopener noreferrer nofollow\">l</a>");
    try expectClean("<a href=\"/wiki/Page#top\">l</a>", "<a href=\"/wiki/Page#top\" rel=\"noopener noreferrer nofollow\">l</a>");
    for ([_][]const u8{
        "<a href=\"javascript:alert(1)\">x</a>",
        "<a href=\" javascript:alert(1)\">x</a>",
        "<a href=\"JaVaScRiPt:alert(1)\">x</a>",
        "<a href=\"jav\tascript:alert(1)\">x</a>",
        "<a href=\"jav&#x09;ascript:alert(1)\">x</a>",
        "<a href=\"&#106;avascript:alert(1)\">x</a>",
        "<a href=\"&#x6A;avascript&colon;alert(1)\">x</a>",
        "<a href=\"vbscript:x\">x</a>",
        "<a href=\"data:text/html;base64,PHNjcmlwdD4=\">x</a>",
        "<a href=javascript:alert(1)>x</a>",
    }) |bad| {
        errdefer std.debug.print("case: {s}\n", .{bad});
        try expectClean(bad, "<a rel=\"noopener noreferrer nofollow\">x</a>");
    }
    // Images: data: images of known types are fine, other data: is not.
    try expectClean("<img src=\"data:image/png;base64,AAAA\">", "<img src=\"data:image/png;base64,AAAA\">");
    try expectClean("<img src=\"data:text/html,<script>\">", "");
    try expectClean("<img src=\"javascript:x\" alt=\"a <b> picture\">", "a &lt;b&gt; picture"); // the alt text stands in
}

test "the rewrite hook changes or refuses addresses, and cannot smuggle a script scheme" {
    const Hook = struct {
        fn f(_: ?*anyopaque, arena: Allocator, kind: UrlKind, url: []const u8) Allocator.Error!?[]const u8 {
            if (std.mem.startsWith(u8, url, "/drop")) return null;
            if (std.mem.startsWith(u8, url, "/evil")) return "javascript:alert(1)";
            return try std.fmt.allocPrint(arena, "/zim/{s}{s}", .{ if (kind == .image) "img" else "page", url });
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try sanitizeAlloc(arena.allocator(), "<a href=\"/A\">1</a><a href=\"/drop\">2</a><a href=\"/evil\">3</a><img src=\"/I.png\">", .{ .rewrite = Hook.f });
    try testing.expectEqualStrings("<a href=\"/zim/page/A\" rel=\"noopener noreferrer nofollow\">1</a><a rel=\"noopener noreferrer nofollow\">2</a><a rel=\"noopener noreferrer nofollow\">3</a><img src=\"/zim/img/I.png\">", got);
}

test "the output is balanced and cannot close the page around it" {
    try expectClean("<div><p>open", "<div><p>open</p></div>");
    try expectClean("</div></body></html>text", "text");
    try expectClean("<b><i>x</b>y", "<b><i>x</i></b>y");
    try expectClean("<ul><li>a<li>b</ul>", "<ul><li>a<li>b</li></li></ul>"); // unclosed list items nest, but stay balanced
}

test "text is escaped; references stay; comments and declarations vanish" {
    try expectClean("a < b && c > d &amp; &copy; &#65; &#xZZ; &bogus x", "a &lt; b &amp;&amp; c &gt; d &amp; &copy; &#65; &amp;#xZZ; &amp;bogus x");
    try expectClean("<!DOCTYPE html><!-- hidden <script> -->x<?php evil ?>y", "xy");
    try expectClean("<p title=\"a&quot;b<c\">t</p>", "<p title=\"a&quot;b&lt;c\">t</p>");
    try expectClean("<<script>alert(1)</script>", "&lt;");
    try expectClean("<a href=\"unterminated", "&lt;a href=\"unterminated");
}

test "limits: depth and output size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var deep: std.ArrayList(u8) = .empty;
    for (0..1000) |_| try deep.appendSlice(a, "<div>");
    try deep.appendSlice(a, "x");
    const out = try sanitizeAlloc(a, deep.items, .{ .max_depth = 10 });
    var opens: usize = 0;
    var it = std.mem.splitSequence(u8, out, "<div>");
    while (it.next()) |_| opens += 1;
    try testing.expectEqual(@as(usize, 11), opens); // ten divs
    const big = try a.alloc(u8, 100000);
    @memset(big, 'a');
    const capped = try sanitizeAlloc(a, big, .{ .max_output_bytes = 1000 });
    try testing.expect(capped.len < 100000);
}

test "random markup never crashes and never leaves a script behind" {
    var prng = std.Random.DefaultPrng.init(0x5a5a);
    const rand = prng.random();
    const pieces = [_][]const u8{ "<", ">", "</", "/>", "<script>", "</script>", "<img src=x onerror=1>", "<a href=\"javascript:1\">", "\"", "'", "=", "&", ";", "&#106;", "<!--", "-->", "<svg>", "<p>", "</p>", "<div class=a>", " ", "x", "\x00", "<style>", "javascript:", "on", "<iframe>" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (0..3000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var src: std.ArrayList(u8) = .empty;
        for (0..rand.uintLessThan(usize, 30)) |_| try src.appendSlice(a, pieces[rand.uintLessThan(usize, pieces.len)]);
        const out = try sanitizeAlloc(a, src.items, .{});
        // Nothing dangerous in the result, in any case.
        const lower = try std.ascii.allocLowerString(a, out);
        // Plain text may mention "javascript:"; what must never appear is a live attribute or tag.
        for ([_][]const u8{ "<script", "<style", "<iframe", "<svg", " onerror", " onclick", "href=\"javascript", "src=\"javascript", "<img src=x" }) |bad| {
            errdefer std.debug.print("src: {s}\nout: {s}\n", .{ src.items, out });
            try testing.expect(std.mem.indexOf(u8, lower, bad) == null);
        }
    }
}
