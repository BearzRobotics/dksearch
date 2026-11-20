//! The Docs page of the administration interface: the manual and the API reference, one section at a time, from the
//! same Markdown files that become the manual pages (docs/manpages), so there is one copy of the documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const dk = @import("dksearch");
const manpages = @import("manpages");
const html = @import("html.zig");

pub const Book = struct { key: []const u8, title: []const u8, text: []const u8 };

pub const books = [_]Book{
    .{ .key = "manual", .title = "Manual", .text = manpages.manual },
    .{ .key = "api", .title = "HTTP API", .text = manpages.api },
};

pub const Section = struct { title: []const u8, body: []const u8 };

fn isHeading(line: []const u8) bool {
    if (line.len < 3 or line.len > 60) return false;
    var letters: usize = 0;
    for (line) |ch| {
        if (std.ascii.isUpper(ch)) letters += 1 else if (ch != ' ' and ch != ',' and ch != '&' and ch != '-') return false;
    }
    return letters >= 3;
}

/// The title of a heading line, or null. A heading is `# TITLE` (a Markdown heading with the title in capitals, the layout
/// of the manual pages: digits and punctuation are allowed, a lower-case letter is not, so `# a comment` is not one and an
/// indented line, as in a code block, never is) or a line of capitals on its own (the older layout).
fn headingTitle(line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "# ")) {
        const t = std.mem.trim(u8, line[2..], " ");
        if (t.len == 0 or t.len > 60) return null;
        var capitals: usize = 0;
        for (t) |ch| {
            if (std.ascii.isLower(ch)) return null;
            if (std.ascii.isUpper(ch)) capitals += 1;
        }
        return if (capitals >= 3) t else null;
    }
    return if (isHeading(line)) line else null;
}

/// The sections of a manual page: a heading (see `headingTitle`), after a blank line, starts one. Text before the first
/// heading (the `%` title lines) is dropped.
pub fn sections(arena: Allocator, text: []const u8) Allocator.Error![]const Section {
    var out: std.ArrayList(Section) = .empty;
    var title: ?[]const u8 = null;
    var body_start: usize = 0;
    var pos: usize = 0;
    var prev_blank = true;
    while (pos < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..end];
        const next = @min(end + 1, text.len);
        if (prev_blank and !std.mem.startsWith(u8, line, "%")) if (headingTitle(line)) |found| {
            if (title) |t| try out.append(arena, .{ .title = t, .body = std.mem.trim(u8, text[body_start..pos], "\n") });
            title = found;
            body_start = next;
        };
        prev_blank = line.len == 0;
        pos = next;
    }
    if (title) |t| try out.append(arena, .{ .title = t, .body = std.mem.trim(u8, text[body_start..], "\n") });
    return out.items;
}

/// "SEMANTIC SEARCH" reads better as "Semantic search".
fn nice(arena: Allocator, t: []const u8) Allocator.Error![]const u8 {
    const out = try arena.dupe(u8, t);
    for (out, 0..) |*ch, i| ch.* = if (i == 0) ch.* else std.ascii.toLower(ch.*);
    return out;
}

fn findBook(key: []const u8) Book {
    for (books) |b| if (std.mem.eql(u8, b.key, key)) return b;
    return books[0];
}

/// The page body: a contents list of the chosen book and the chosen section (the first by default).
pub fn write(arena: Allocator, w: *Io.Writer, book_key: []const u8, section: ?usize) !void {
    const book = findBook(book_key);
    const secs = try sections(arena, book.text);
    const chosen = if (section) |s| @min(s, secs.len -| 1) else 0;
    try w.writeAll("<h1>Documentation</h1><p class=\"muted\">The same text as the manual pages (<code>man dksearch</code>). ");
    for (books, 0..) |b, i| {
        if (i > 0) try w.writeAll(" &middot; ");
        if (std.mem.eql(u8, b.key, book.key)) {
            try w.writeAll("<strong>");
            try html.writeEscaped(w, b.title);
            try w.writeAll("</strong>");
        } else {
            try w.print("<a href=\"/docs?book={s}\">", .{b.key});
            try html.writeEscaped(w, b.title);
            try w.writeAll("</a>");
        }
    }
    try w.writeAll("</p><div class=\"docs\"><nav class=\"docs-nav\" aria-label=\"Sections\"><ul>");
    for (secs, 0..) |s, i| {
        try w.print("<li><a href=\"/docs?book={s}&amp;s={d}\"", .{ book.key, i });
        if (i == chosen) try w.writeAll(" aria-current=\"page\"");
        try w.writeAll(">");
        try html.writeEscaped(w, try nice(arena, s.title));
        try w.writeAll("</a></li>");
    }
    try w.writeAll("</ul></nav><article class=\"docs-body\">");
    if (secs.len > 0) {
        try w.writeAll("<h2>");
        try html.writeEscaped(w, try nice(arena, secs[chosen].title));
        try w.writeAll("</h2>");
        const rendered = dk.render.markdown(arena, secs[chosen].body, null) catch "<p class=\"muted\">This section could not be shown.</p>";
        try w.writeAll(rendered);
    }
    try w.writeAll("</article></div>");
}

const testing = std.testing;

test "the manuals split into their sections and each renders" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for (books) |b| {
        const secs = try sections(a, b.text);
        try testing.expect(secs.len >= 10);
        try testing.expectEqualStrings("NAME", secs[0].title);
        for (secs) |s| try testing.expect(s.title.len > 0 and s.title.len <= 60);
    }
    const man = try sections(a, books[0].text);
    var found = false;
    for (man) |s| if (std.mem.eql(u8, s.title, "OLLAMA, MODELS AND WRITTEN ANSWERS") and std.mem.indexOf(u8, s.body, "dksearch models") != null) {
        found = true;
    };
    try testing.expect(found);
    // The layout of the manual pages: `# TITLE` after a blank line (digits allowed), not a lower-case one, not an indented one.
    const hashed = try sections(a, "# NAME\n\nx\n\n# TOR AND I2P\n\ny\n\n# Not a heading\n\n    # nor this, in code\n\n# SEE ALSO\nz\n");
    try testing.expectEqual(@as(usize, 3), hashed.len);
    try testing.expectEqualStrings("NAME", hashed[0].title);
    try testing.expectEqualStrings("TOR AND I2P", hashed[1].title);
    try testing.expect(std.mem.indexOf(u8, hashed[1].body, "# Not a heading") != null and std.mem.indexOf(u8, hashed[1].body, "# nor this") != null);
    try testing.expectEqualStrings("z", hashed[2].body);
    // A small text: headings after blank lines only.
    const tiny = try sections(a, "% T\n\nNAME\nx\n\nSEE ALSO\ny\nNOT HEADING\n");
    try testing.expectEqual(@as(usize, 2), tiny.len);
    try testing.expectEqualStrings("x", tiny[0].body);
    try testing.expect(std.mem.indexOf(u8, tiny[1].body, "NOT HEADING") != null);
}

test "the page lists the sections, shows the chosen one and switches books" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    try write(a, &aw.writer, "manual", 2);
    const page = aw.written();
    try testing.expect(std.mem.indexOf(u8, page, "href=\"/docs?book=api\"") != null);
    try testing.expect(std.mem.indexOf(u8, page, "aria-current=\"page\"") != null);
    try testing.expect(std.mem.indexOf(u8, page, "<script") == null);
    var aw2: Io.Writer.Allocating = .init(a);
    try write(a, &aw2.writer, "nonsense", 9999); // unknown book and a section past the end are tolerated
    try testing.expect(aw2.written().len > 100);
}
