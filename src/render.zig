//! Turning stored text into HTML that is safe to show in the viewer page.
//!
//! Markdown goes through `md-zig` and then the allow-list sanitizer in `htmlsafe.zig`, so even
//! raw HTML inside a Markdown file cannot add script, styles, frames or forms to our page. Links
//! to other sites stay; links relative to the file and all images are dropped (the page's content
//! security policy would block remote images anyway, and relative addresses mean nothing here).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const md = @import("mdzig");
const htmlsafe = @import("htmlsafe.zig");

/// Largest Markdown rendered, in bytes.
pub const max_markdown_bytes = 1024 * 1024;

fn rewrite(_: ?*anyopaque, _: Allocator, kind: htmlsafe.UrlKind, url: []const u8) Allocator.Error!?[]const u8 {
    if (kind == .image) return null;
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '#') return trimmed; // a link within the page
    if (std.mem.indexOf(u8, trimmed, "://") != null or std.ascii.startsWithIgnoreCase(trimmed, "mailto:")) return trimmed;
    return null; // relative to a file we do not serve
}

pub const Error = error{ OutOfMemory, TooLarge };

/// Safe HTML for a Markdown document, allocated from `arena`.
pub fn markdown(arena: Allocator, text: []const u8) Error![]const u8 {
    if (text.len > max_markdown_bytes) return error.TooLarge;
    var doc = md.Document.parse(arena, text, .{
        .max_bytes = max_markdown_bytes,
        .extensions = .{ .tables = true, .strikethrough = true, .task_lists = true, .autolinks = true, .tagfilter = true, .footnotes = true, .front_matter = true, .definition_lists = true },
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TooLarge, // too large, a line too long, or nested too deeply
    };
    defer doc.deinit();
    var raw: Io.Writer.Allocating = .init(arena);
    doc.writeHtml(arena, &raw.writer) catch return error.OutOfMemory;
    return htmlsafe.sanitizeAlloc(arena, raw.written(), .{ .rewrite = rewrite }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.OutOfMemory,
    };
}

const testing = std.testing;

fn expectContains(hay: []const u8, needle: []const u8) !void {
    errdefer std.debug.print("missing: {s}\nin: {s}\n", .{ needle, hay });
    try testing.expect(std.mem.indexOf(u8, hay, needle) != null);
}

test "Markdown renders headings, lists, code, tables and links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try markdown(arena.allocator(),
        \\# Title
        \\
        \\Some *emphasis*, **strong**, `code` and a [site](https://example.org/a?b=1&c=2).
        \\
        \\- one
        \\- two
        \\
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\
        \\```
        \\let x = 1 < 2;
        \\```
    );
    for ([_][]const u8{ "<h1>Title</h1>", "<em>emphasis</em>", "<strong>strong</strong>", "<code>code</code>", "<li>one</li>", "<table>", "<td>1</td>", "<pre>", "&lt; 2", "href=\"https://example.org/a?b=1&amp;c=2\"" }) |n| try expectContains(out, n);
}

test "Markdown cannot bring script, handlers, frames, styles or local links into the page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try markdown(arena.allocator(),
        \\<script>alert(1)</script>
        \\
        \\<img src="x" onerror="alert(1)">
        \\
        \\<iframe src="http://evil.example"></iframe>
        \\
        \\<div style="position:fixed" class="side">overlay</div>
        \\
        \\[bad](javascript:alert(1)) [local](other.md) [frag](#top) [ok](http://example.org)
        \\
        \\![picture](pic.png) ![remote](http://example.org/p.png)
    );
    const lower = try std.ascii.allocLowerString(arena.allocator(), out);
    // Markup that is shown as visible text (md-zig escapes some raw tags) is fine; live markup is not.
    for ([_][]const u8{ "<script", "<iframe", "<img", " style=\"", " class=\"", " onerror=\"", "href=\"javascript:" }) |bad| {
        errdefer std.debug.print("found {s} in: {s}\n", .{ bad, out });
        try testing.expect(std.mem.indexOf(u8, lower, bad) == null);
    }
    try expectContains(out, "overlay"); // the text stays
    try expectContains(out, "picture"); // an image that cannot be shown leaves its alt text
    try expectContains(out, "href=\"#top\"");
    try expectContains(out, "href=\"http://example.org\"");
    try testing.expect(std.mem.indexOf(u8, out, "other.md") == null); // the link text stays, the address does not
}

test "too large Markdown is refused, and hostile input is only text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const big = try a.alloc(u8, max_markdown_bytes + 1);
    @memset(big, 'a');
    try testing.expectError(error.TooLarge, markdown(a, big));
    var nested: std.ArrayList(u8) = .empty;
    for (0..5000) |_| try nested.appendSlice(a, "> ");
    try nested.appendSlice(a, "deep");
    _ = markdown(a, nested.items) catch |e| try testing.expect(e == error.TooLarge);
}
