//! What the index records about a document beyond its text, worked out from the
//! `Document`: host, path and extension of its URL, a coarse kind, and its
//! size. These are what filters (`ext:pdf`, `domain:example.org`, `type:image`)
//! test. Pure functions, no I/O.

const std = @import("std");
const doc = @import("document.zig");

pub const max_host = 253;
pub const max_path = 1024;
pub const max_ext = 8;

pub const Derived = struct {
    host_buf: [max_host]u8 = undefined,
    host_len: usize = 0,
    ext_buf: [max_ext]u8 = undefined,
    ext_len: usize = 0,
    /// The URL's path (borrowed from the document), or null.
    path: ?[]const u8 = null,
    kind: []const u8 = "other",
    size: ?i64 = null,

    pub fn host(self: *const Derived) ?[]const u8 {
        return if (self.host_len == 0) null else self.host_buf[0..self.host_len];
    }
    pub fn ext(self: *const Derived) ?[]const u8 {
        return if (self.ext_len == 0) null else self.ext_buf[0..self.ext_len];
    }
};

/// The groups of file types `type:` / `kind:` accept.
pub const kinds = [_][]const u8{ "page", "text", "markdown", "pdf", "image", "video", "audio", "document", "data", "other" };

pub fn derive(d: doc.Document) Derived {
    var out: Derived = .{};
    if (d.canonical_url) |url| split(&out, url);
    out.kind = kindOf(d.content_type, if (out.ext_len > 0) out.ext_buf[0..out.ext_len] else null);
    if (d.text orelse d.summary) |t| out.size = @intCast(t.len);
    // A connector that knows the size of the original file says so; that is the size people mean.
    for (d.extra) |e| if (std.mem.eql(u8, e.key, "file_size")) {
        if (std.fmt.parseInt(i64, e.value, 10)) |n| {
            if (n >= 0) out.size = n;
        } else |_| {}
    };
    return out;
}

/// Takes host, path and extension out of `url`: `scheme://user@host:port/path?query#frag`,
/// or a bare path.
fn split(out: *Derived, url: []const u8) void {
    var rest = url;
    var has_authority = false;
    if (std.mem.indexOf(u8, url, "://")) |i| {
        rest = url[i + 3 ..];
        has_authority = true;
    }
    var path_part: []const u8 = rest;
    if (has_authority) {
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        var authority = rest[0..end];
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
        // A port, but not the colons inside an IPv6 literal.
        if (authority.len > 0 and authority[0] != '[') {
            if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| authority = authority[0..colon];
        }
        if (authority.len > 0 and authority.len <= max_host) {
            out.host_len = authority.len;
            _ = std.ascii.lowerString(out.host_buf[0..authority.len], authority);
        }
        path_part = rest[end..];
    }
    const stop = std.mem.indexOfAny(u8, path_part, "?#") orelse path_part.len;
    const path = path_part[0..stop];
    if (path.len > 0 and path.len <= max_path) out.path = path;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const name = if (slash) |s| path[s + 1 ..] else path;
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        const e = name[dot + 1 ..];
        if (e.len >= 1 and e.len <= max_ext) {
            for (e) |b| if (!std.ascii.isAlphanumeric(b)) return;
            out.ext_len = e.len;
            _ = std.ascii.lowerString(out.ext_buf[0..e.len], e);
        }
    }
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// The coarse kind of a document from its media type, or from its extension
/// when the type says nothing useful.
pub fn kindOf(content_type: ?[]const u8, ext: ?[]const u8) []const u8 {
    if (content_type) |ct| {
        if (startsWithIgnoreCase(ct, "image/")) return "image";
        if (startsWithIgnoreCase(ct, "video/")) return "video";
        if (startsWithIgnoreCase(ct, "audio/")) return "audio";
        if (startsWithIgnoreCase(ct, "application/pdf")) return "pdf";
        if (std.ascii.findIgnoreCase(ct, "wordprocessingml") != null or std.ascii.findIgnoreCase(ct, "opendocument") != null or
            startsWithIgnoreCase(ct, "application/epub") or startsWithIgnoreCase(ct, "application/msword") or startsWithIgnoreCase(ct, "application/rtf")) return "document";
        if (startsWithIgnoreCase(ct, "text/html") or startsWithIgnoreCase(ct, "application/xhtml")) return "page";
        if (startsWithIgnoreCase(ct, "text/markdown")) return "markdown";
        if (startsWithIgnoreCase(ct, "application/json") or startsWithIgnoreCase(ct, "application/xml") or
            startsWithIgnoreCase(ct, "text/csv") or startsWithIgnoreCase(ct, "text/xml") or
            startsWithIgnoreCase(ct, "application/rss") or startsWithIgnoreCase(ct, "application/atom")) return "data";
        if (startsWithIgnoreCase(ct, "text/")) {
            // Plain text says little: a known extension can say more.
            if (ext) |e| {
                const by_ext = fromExt(e);
                if (!std.mem.eql(u8, by_ext, "other")) return by_ext;
            }
            return "text";
        }
    }
    if (ext) |e| return fromExt(e);
    return "other";
}

fn fromExt(e: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "html", "page" },    .{ "htm", "page" },          .{ "xhtml", "page" },
        .{ "md", "markdown" },  .{ "markdown", "markdown" }, .{ "txt", "text" },
        .{ "text", "text" },    .{ "rst", "text" },          .{ "org", "text" },
        .{ "pdf", "pdf" },      .{ "docx", "document" },     .{ "doc", "document" },
        .{ "odt", "document" }, .{ "epub", "document" },     .{ "rtf", "document" },
        .{ "jpg", "image" },    .{ "jpeg", "image" },        .{ "png", "image" },
        .{ "gif", "image" },    .{ "webp", "image" },        .{ "bmp", "image" },
        .{ "svg", "image" },    .{ "tif", "image" },         .{ "tiff", "image" },
        .{ "avif", "image" },   .{ "mp4", "video" },         .{ "mkv", "video" },
        .{ "webm", "video" },   .{ "avi", "video" },         .{ "mov", "video" },
        .{ "mp3", "audio" },    .{ "flac", "audio" },        .{ "ogg", "audio" },
        .{ "wav", "audio" },    .{ "m4a", "audio" },         .{ "opus", "audio" },
        .{ "json", "data" },    .{ "xml", "data" },          .{ "csv", "data" },
        .{ "tsv", "data" },     .{ "yaml", "data" },         .{ "yml", "data" },
        .{ "toml", "data" },
    };
    for (table) |row| if (std.ascii.eqlIgnoreCase(e, row[0])) return row[1];
    return "other";
}

const testing = std.testing;

fn derived(url: ?[]const u8, content_type: ?[]const u8, text: ?[]const u8) Derived {
    return derive(.{ .connector = "c", .source_id = "s", .canonical_url = url, .content_type = content_type, .text = text });
}

test "host, path and extension from URLs" {
    const a = derived("https://User:pw@Docs.Example.ORG:8443/a/b/Report.PDF?x=1#top", null, "hello");
    try testing.expectEqualStrings("docs.example.org", a.host().?);
    try testing.expectEqualStrings("/a/b/Report.PDF", a.path.?);
    try testing.expectEqualStrings("pdf", a.ext().?);
    try testing.expectEqualStrings("pdf", a.kind);
    try testing.expectEqual(@as(?i64, 5), a.size);

    const f = derived("file:///home/x/notes.md", "text/plain", null);
    try testing.expect(f.host() == null);
    try testing.expectEqualStrings("/home/x/notes.md", f.path.?);
    try testing.expectEqualStrings("markdown", f.kind); // the extension refines plain text

    const bare = derived("/srv/files/data.tar.gz", null, null);
    try testing.expectEqualStrings("gz", bare.ext().?);
    try testing.expectEqualStrings("other", bare.kind);

    const none = derived("https://example.org", null, null);
    try testing.expectEqualStrings("example.org", none.host().?);
    try testing.expect(none.path == null);
    try testing.expect(none.ext() == null);

    const v6 = derived("http://[::1]:8080/x", null, null);
    try testing.expect(v6.host() != null); // an IPv6 literal is kept whole, brackets included
}

test "office documents and ebooks are documents" {
    try testing.expectEqualStrings("document", kindOf("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx"));
    try testing.expectEqualStrings("document", kindOf("application/vnd.oasis.opendocument.text", null));
    try testing.expectEqualStrings("document", kindOf("application/epub+zip", "epub"));
    try testing.expectEqualStrings("document", kindOf(null, "odt"));
}

test "kinds from media types" {
    try testing.expectEqualStrings("image", kindOf("image/png", null));
    try testing.expectEqualStrings("page", kindOf("text/html; charset=utf-8", null));
    try testing.expectEqualStrings("text", kindOf("text/plain", null));
    try testing.expectEqualStrings("data", kindOf("application/json", "json"));
    try testing.expectEqualStrings("video", kindOf(null, "mkv"));
    try testing.expectEqualStrings("other", kindOf("application/octet-stream", "bin"));
}

test "odd input never crashes" {
    for ([_][]const u8{ "", "://", "http://", "http://@", "http://:/", "a.", ".b", "x/.", "http://h/a.b/", "http://h/a..b" }) |u| {
        const d = derived(u, null, null);
        _ = d.host();
        _ = d.ext();
    }
}
