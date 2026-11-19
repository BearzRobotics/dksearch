//! The addresses of the entries of an RSS or Atom feed (docs/decisions/0058): what a crawler needs from a feed, which is
//! where the newest pages of a site are. Read with the SAX parser of the vendored XML library; nothing is fetched here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("../../xml.zig");

const Handler = struct {
    arena: Allocator,
    gpa: Allocator,
    urls: std.ArrayList([]const u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    in_entry: bool = false,
    in_link: bool = false,
    max: usize,
    const P = xml.Parser(Handler);

    fn local(name: []const u8) []const u8 {
        return if (std.mem.lastIndexOfScalar(u8, name, ':')) |i| name[i + 1 ..] else name;
    }

    fn add(self: *Handler, p: *P, url: []const u8) void {
        const v = std.mem.trim(u8, url, " \t\r\n");
        if (v.len == 0 or v.len > 2000 or self.urls.items.len >= self.max) return;
        const copy = self.arena.dupe(u8, v) catch return p.stop();
        self.urls.append(self.arena, copy) catch return p.stop();
    }

    pub fn startElement(self: *Handler, p: *P, name: []const u8, attrs: xml.Attrs) void {
        const n = local(name);
        if (std.mem.eql(u8, n, "item") or std.mem.eql(u8, n, "entry")) {
            self.in_entry = true;
        } else if (self.in_entry and std.mem.eql(u8, n, "link")) {
            if (attrs.get("href")) |href| {
                // Atom: the address is an attribute; the alternate link (the default) is the page.
                const rel = attrs.get("rel");
                if (rel == null or std.mem.eql(u8, rel.?, "alternate")) self.add(p, href);
            } else {
                // RSS: the address is the text of the element.
                self.in_link = true;
                self.text.clearRetainingCapacity();
            }
        }
    }

    pub fn characters(self: *Handler, p: *P, bytes: []const u8) void {
        if (!self.in_link) return;
        if (self.text.items.len + bytes.len > 4096) return;
        self.text.appendSlice(self.gpa, bytes) catch p.stop();
    }

    pub fn endElement(self: *Handler, p: *P, name: []const u8) void {
        const n = local(name);
        if (std.mem.eql(u8, n, "link") and self.in_link) {
            self.in_link = false;
            self.add(p, self.text.items);
        } else if (std.mem.eql(u8, n, "item") or std.mem.eql(u8, n, "entry")) {
            self.in_entry = false;
        }
    }
};

/// The addresses (as written in the feed: they may be relative) of at most `max` entries, in feed order. A feed that is
/// not well-formed gives what was read before the fault.
pub fn links(arena: Allocator, gpa: Allocator, body: []const u8, max: usize) Allocator.Error![]const []const u8 {
    var h: Handler = .{ .arena = arena, .gpa = gpa, .max = max };
    defer h.text.deinit(gpa);
    var parser: xml.Parser(Handler) = undefined;
    parser.init(gpa, &h) catch return error.OutOfMemory;
    defer parser.deinit();
    parser.feed(body, true) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Stopped, error.Malformed => {},
    };
    return h.urls.items;
}

const testing = std.testing;

test "the entries of an RSS feed and of an Atom feed, relative addresses as written, the rest ignored" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const rss =
        \\<?xml version="1.0"?><rss version="2.0"><channel><title>Blog</title><link>https://e.org/</link>
        \\<item><title>One</title><link>https://e.org/posts/one</link></item>
        \\<item><title>Two</title><link>/posts/two</link><guid>x</guid></item>
        \\</channel></rss>
    ;
    const got = try links(a, testing.allocator, rss, 10);
    try testing.expectEqual(@as(usize, 2), got.len); // the channel's own link is not an entry
    try testing.expectEqualStrings("https://e.org/posts/one", got[0]);
    try testing.expectEqualStrings("/posts/two", got[1]);
    const atom =
        \\<feed xmlns="http://www.w3.org/2005/Atom"><title>T</title><link href="https://e.org/"/>
        \\<entry><title>A</title><link rel="alternate" href="https://e.org/a"/><link rel="replies" href="https://e.org/a/comments"/></entry>
        \\<entry><title>B</title><link href="/b"/></entry></feed>
    ;
    const got2 = try links(a, testing.allocator, atom, 10);
    try testing.expectEqual(@as(usize, 2), got2.len);
    try testing.expectEqualStrings("https://e.org/a", got2[0]);
    try testing.expectEqualStrings("/b", got2[1]);
    // A limit, and a broken feed gives what came before the fault.
    try testing.expectEqual(@as(usize, 1), (try links(a, testing.allocator, rss, 1)).len);
    const broken = "<rss><channel><item><link>https://e.org/ok</link></item><item><link>https://e.org/cut";
    try testing.expectEqual(@as(usize, 1), (try links(a, testing.allocator, broken, 10)).len);
    try testing.expectEqual(@as(usize, 0), (try links(a, testing.allocator, "not xml at all", 10)).len);
}
