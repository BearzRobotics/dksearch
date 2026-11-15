//! Server-rendered HTML for the public search page.
//!
//! No JavaScript. Every dynamic string goes through `writeEscaped`, and a
//! result URL becomes a link only if its scheme is http or https.

const std = @import("std");
const Writer = std.Io.Writer;
const dk = @import("dksearch");
const query = @import("query.zig");

pub const style_css = @embedFile("assets/style.css");

pub fn writeEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |b| switch (b) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(b),
    };
}

/// True only for absolute http(s) URLs. Blocks `javascript:`, `data:` and
/// everything else from becoming a link.
pub fn isLinkable(url: []const u8) bool {
    return startsWithIgnoreCase(url, "http://") or startsWithIgnoreCase(url, "https://");
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Writes a snippet: HTML-escaped, with the engine's match markers turned
/// into <mark>. Markers are only honoured in a balanced way, and other
/// control bytes are dropped, so untrusted text cannot unbalance the markup.
pub fn writeSnippet(w: *Writer, snippet: []const u8) Writer.Error!void {
    var open = false;
    for (snippet) |b| {
        if (std.mem.eql(u8, &.{b}, dk.search.match_start)) {
            if (!open) {
                try w.writeAll("<mark>");
                open = true;
            }
        } else if (std.mem.eql(u8, &.{b}, dk.search.match_end)) {
            if (open) {
                try w.writeAll("</mark>");
                open = false;
            }
        } else if (b < 0x20 and b != '\t' and b != '\n') {
            continue;
        } else {
            try writeEscaped(w, &.{b});
        }
    }
    if (open) try w.writeAll("</mark>");
}

pub const Form = struct {
    q: []const u8 = "",
    language: []const u8 = "",
    connector: []const u8 = "",
};

pub fn writeHead(w: *Writer, title: []const u8) Writer.Error!void {
    try w.writeAll("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>");
    try writeEscaped(w, title);
    try w.writeAll("</title><link rel=\"stylesheet\" href=\"/assets/style.css\"></head>\n");
}

fn writeForm(w: *Writer, f: Form) Writer.Error!void {
    try w.writeAll("<form class=\"search\" action=\"/search\" method=\"get\" role=\"search\">" ++
        "<input type=\"search\" name=\"q\" maxlength=\"1024\" aria-label=\"Search\" autofocus value=\"");
    try writeEscaped(w, f.q);
    try w.writeAll("\"><button type=\"submit\">Search</button>");
    const open = if (f.language.len > 0 or f.connector.len > 0) " open" else "";
    try w.print("<details{s}><summary>Filters</summary><label>Language <input name=\"language\" maxlength=\"64\" value=\"", .{open});
    try writeEscaped(w, f.language);
    try w.writeAll("\"></label><label>Source <input name=\"connector\" maxlength=\"64\" value=\"");
    try writeEscaped(w, f.connector);
    try w.writeAll("\"></label></details></form>\n");
}

pub fn writeHome(w: *Writer, notice: ?[]const u8) Writer.Error!void {
    try writeHead(w, "dksearch");
    try w.writeAll("<body class=\"home\"><main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1>\n");
    try writeForm(w, .{});
    if (notice) |n| {
        try w.writeAll("<p class=\"error\" role=\"alert\">");
        try writeEscaped(w, n);
        try w.writeAll("</p>");
    }
    try w.writeAll("</main></body></html>\n");
}

pub fn writeResults(w: *Writer, f: Form, page: dk.search.Page, offset: u32, page_size: u32) Writer.Error!void {
    try writeHead(w, if (f.q.len > 0) f.q else "dksearch");
    try w.writeAll("<body><main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1>\n");
    try writeForm(w, f);

    if (page.hits.len == 0) {
        try w.writeAll("<p class=\"notice\">No results for &ldquo;");
        try writeEscaped(w, f.q);
        try w.writeAll("&rdquo;.</p>");
    } else {
        try w.writeAll("<ol class=\"results\" start=\"");
        try w.print("{d}", .{offset + 1});
        try w.writeAll("\">\n");
        for (page.hits) |h| try writeHit(w, h);
        try w.writeAll("</ol>\n");
    }

    if (offset > 0 or page.has_more) {
        try w.writeAll("<nav class=\"pager\" aria-label=\"Pages\"><span>");
        if (offset > 0) try writePagerLink(w, f, offset -| page_size, "&larr; Previous");
        try w.writeAll("</span><span>");
        if (page.has_more) try writePagerLink(w, f, offset + page_size, "Next &rarr;");
        try w.writeAll("</span></nav>\n");
    }
    try w.writeAll("</main></body></html>\n");
}

fn writeHit(w: *Writer, h: dk.search.Hit) Writer.Error!void {
    try w.writeAll("<li>");
    const label = h.title orelse h.url orelse "(untitled)";
    if (h.url) |u| if (isLinkable(u)) {
        try w.writeAll("<a class=\"title\" href=\"");
        try writeEscaped(w, u);
        try w.writeAll("\" rel=\"noopener noreferrer\">");
        try writeEscaped(w, label);
        try w.writeAll("</a>");
        try w.writeAll("<div class=\"url\">");
        try writeEscaped(w, u);
        try w.writeAll("</div>");
        return finishHit(w, h);
    };
    try w.writeAll("<span class=\"title\">");
    try writeEscaped(w, label);
    try w.writeAll("</span>");
    if (h.url) |u| {
        try w.writeAll("<div class=\"url\">");
        try writeEscaped(w, u);
        try w.writeAll("</div>");
    }
    try finishHit(w, h);
}

fn finishHit(w: *Writer, h: dk.search.Hit) Writer.Error!void {
    if (h.snippet) |s| if (s.len > 0) {
        try w.writeAll("<p class=\"snippet\">");
        try writeSnippet(w, s);
        try w.writeAll("</p>");
    };
    try w.writeAll("<div class=\"source\">");
    try writeEscaped(w, h.connector);
    try w.writeAll("</div></li>\n");
}

fn writePagerLink(w: *Writer, f: Form, offset: u32, label_html: []const u8) Writer.Error!void {
    try w.writeAll("<a href=\"/search?q=");
    try query.writeEncoded(w, f.q);
    if (f.language.len > 0) {
        try w.writeAll("&amp;language=");
        try query.writeEncoded(w, f.language);
    }
    if (f.connector.len > 0) {
        try w.writeAll("&amp;connector=");
        try query.writeEncoded(w, f.connector);
    }
    if (offset > 0) try w.print("&amp;offset={d}", .{offset});
    try w.writeAll("\">");
    try w.writeAll(label_html);
    try w.writeAll("</a>");
}

pub fn writeError(w: *Writer, status_text: []const u8, message: []const u8) Writer.Error!void {
    try writeHead(w, status_text);
    try w.writeAll("<body><main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1><p class=\"error\">");
    try writeEscaped(w, message);
    try w.writeAll("</p><p><a href=\"/\">Back to search</a></p></main></body></html>\n");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn render(comptime f: anytype, args: anytype) ![]u8 {
    var aw: Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

test "escaping covers the five HTML-significant characters" {
    const out = try render(writeEscaped, .{"<a href=\"x\" onclick='y'>&</a>"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;&lt;/a&gt;", out);
}

test "only http and https URLs are linkable" {
    try testing.expect(isLinkable("http://example.org/"));
    try testing.expect(isLinkable("HTTPS://example.org/"));
    try testing.expect(!isLinkable("javascript:alert(1)"));
    try testing.expect(!isLinkable("data:text/html,<script>"));
    try testing.expect(!isLinkable("//example.org/"));
    try testing.expect(!isLinkable(" https://example.org/"));
    try testing.expect(!isLinkable("ftp://example.org/"));
    try testing.expect(!isLinkable(""));
}

test "snippet: markers become mark tags, everything else is escaped" {
    const out = try render(writeSnippet, .{"a <b>\x02hit\x03</b> & more"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a &lt;b&gt;<mark>hit</mark>&lt;/b&gt; &amp; more", out);
}

test "snippet: stray, nested and unclosed markers stay balanced; controls dropped" {
    const out = try render(writeSnippet, .{"\x03x\x02a\x02b\x03\x03y\x02z\x01w"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x<mark>ab</mark>y<mark>zw</mark>", out);
}

test "results page: escapes titles, only links safe URLs, shows pager" {
    const hits = [_]dk.search.Hit{
        .{ .id = undefined, .connector = "wiki<script>", .url = "https://e.org/?a=1&b=2", .title = "T <i>1</i>", .snippet = "x \x02y\x03", .score = 1 },
        .{ .id = undefined, .connector = "c", .url = "javascript:alert(1)", .title = "Bad", .snippet = null, .score = 0.5 },
    };
    const page: dk.search.Page = .{ .hits = &hits, .has_more = true };
    const out = try render(writeResults, .{ Form{ .q = "a \"b\" <c>", .language = "en" }, page, @as(u32, 10), @as(u32, 10) });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "T &lt;i&gt;1&lt;/i&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wiki&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "href=\"https://e.org/?a=1&amp;b=2\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "href=\"javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<script") == null);
    try testing.expect(std.mem.indexOf(u8, out, "value=\"a &quot;b&quot; &lt;c&gt;\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<mark>y</mark>") != null);
    // Pager: previous goes to offset 0 (no offset param), next to offset 20.
    try testing.expect(std.mem.indexOf(u8, out, "href=\"/search?q=a%20%22b%22%20%3Cc%3E&amp;language=en\">&larr; Previous") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&amp;offset=20\">Next") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<ol class=\"results\" start=\"11\">") != null);
}

test "empty results page and home page" {
    const none: dk.search.Page = .{ .hits = &.{}, .has_more = false };
    const out = try render(writeResults, .{ Form{ .q = "zzz" }, none, @as(u32, 0), @as(u32, 10) });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "No results for &ldquo;zzz&rdquo;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "class=\"pager\"") == null);

    const home = try render(writeHome, .{@as(?[]const u8, "Bad <query>")});
    defer testing.allocator.free(home);
    try testing.expect(std.mem.indexOf(u8, home, "Bad &lt;query&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, home, "action=\"/search\"") != null);
}
