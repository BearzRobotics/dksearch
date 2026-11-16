//! Reading articles, images and pages straight out of a ZIM file at request time, so the
//! viewer can show them (`/zim/<source>/<path>`) with their images and links working.
//!
//! Nothing is kept open or cached between requests: each request opens the file, finds the
//! entry by binary search of the file's own sorted directory, decompresses the one cluster that
//! holds it, and closes the file. A ZIM file is untrusted input; every read is bounds-checked by
//! the same reader the connector uses (docs/decisions/0025).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zim_mod = @import("connectors/zim.zig");

pub const Archive = struct {
    /// The source (connector) name.
    connector: []const u8,
    /// The `.zim` file, as configured.
    path: []const u8,
};

pub const Error = error{
    /// No such source, or it does not serve its articles.
    NotServed,
    NotFound,
    /// A type that is not shown (stylesheets, scripts, anything unknown).
    Unsupported,
    TooLarge,
    Io,
    OutOfMemory,
};

pub const Fetched = struct {
    bytes: []const u8,
    mime: []const u8,
    /// The entry's title, or its path.
    title: []const u8,
    /// The path of the entry actually read (after redirects), as stored in the file.
    path: []const u8,
};

/// Largest decompressed cluster read for one request.
const max_cluster_bytes: u32 = 64 * 1024 * 1024;
const max_redirects = 8;

pub const Service = struct {
    io: Io,
    gpa: Allocator,
    archives: []const Archive,

    pub fn has(self: *const Service, connector: []const u8) bool {
        for (self.archives) |a| if (std.mem.eql(u8, a.connector, connector)) return true;
        return false;
    }

    pub fn fetch(self: *const Service, arena: Allocator, connector: []const u8, path: []const u8) Error!Fetched {
        var archive: ?Archive = null;
        for (self.archives) |a| if (std.mem.eql(u8, a.connector, connector)) {
            archive = a;
        };
        const arch = archive orelse return error.NotServed;
        if (path.len == 0 or path.len > 1000 or std.mem.indexOfScalar(u8, path, 0) != null) return error.NotFound;

        var file = Io.Dir.cwd().openFile(self.io, arch.path, .{}) catch return error.NotFound;
        defer file.close(self.io);
        const zim = zim_mod.Zim.open(arena, self.io, file) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Io,
        };

        var idx = findPath(&zim, path) orelse return error.NotFound;
        var buf: [zim_mod.max_entry_read]u8 = undefined;
        var hops: usize = 0;
        while (true) {
            const e = zim.readEntry(idx, &buf) orelse return error.NotFound;
            if (e.content) {
                const mime = try arena.dupe(u8, zim.mimeOf(e.mime));
                if (!served(mime)) return error.Unsupported;
                const entry_path = try arena.dupe(u8, e.url);
                const title = if (e.title.len > 0) try arena.dupe(u8, e.title) else entry_path;
                const bytes = zim.readContent(arena, self.gpa, e, max_cluster_bytes) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.TooBig => error.TooLarge,
                    else => error.Io,
                };
                return .{ .bytes = bytes, .mime = mime, .title = title, .path = try pathWithNamespace(arena, e.namespace, entry_path) };
            }
            // A redirect: follow it (a bounded number of times).
            if (e.mime != 0xFFFF) return error.NotFound;
            hops += 1;
            if (hops > max_redirects) return error.NotFound;
            idx = e.redirect;
        }
    }
};

/// The entry for `path`: the content namespace first, then the older article namespace, then a
/// leading `A/` or `I/` as an explicit namespace (`I/logo.png` in an old file).
fn findPath(zim: *const zim_mod.Zim, path: []const u8) ?u32 {
    if (zim.find('C', path)) |i| return i;
    if (zim.find('A', path)) |i| return i;
    // Only the old article and image namespaces; metadata and other namespaces are not pages.
    if (path.len > 2 and path[1] == '/' and (path[0] == 'A' or path[0] == 'I')) return zim.find(path[0], path[2..]);
    return null;
}

/// Paths in links are relative to the entry that holds them; in the content namespace the stored
/// path is already the full path, in older files a namespace letter belongs in front of it.
fn pathWithNamespace(arena: Allocator, ns: u8, path: []const u8) Allocator.Error![]const u8 {
    if (ns == 'C') return path;
    return std.fmt.allocPrint(arena, "{c}/{s}", .{ ns, path });
}

/// What the viewer shows from a ZIM: pages, pictures and plain text. Stylesheets and scripts are
/// never served (the sanitizer drops the markup that would load them).
pub fn served(mime: []const u8) bool {
    return isHtml(mime) or isImage(mime) or std.mem.startsWith(u8, mime, "text/plain");
}

pub fn isHtml(mime: []const u8) bool {
    return std.mem.startsWith(u8, mime, "text/html") or std.mem.startsWith(u8, mime, "application/xhtml");
}

pub fn isImage(mime: []const u8) bool {
    const types = [_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/svg+xml", "image/x-icon", "image/vnd.microsoft.icon" };
    for (types) |t| if (std.mem.startsWith(u8, mime, t)) return true;
    return false;
}

// ---------------------------------------------------------------- addresses

/// Percent-decodes a URL path (a `+` stays a plus). Null if an escape is malformed.
pub fn decodePath(arena: Allocator, s: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return null;
            const b = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
            try out.append(arena, b);
            i += 2;
        } else try out.append(arena, s[i]);
    }
    return out.items;
}

/// `rel` (a link or image address from the entry at `entry_path`) as a path within the ZIM, or
/// null if it leaves the archive (`../` above the top) or is not a plain path.
pub fn resolve(arena: Allocator, entry_path: []const u8, rel: []const u8) Allocator.Error!?[]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    if (rel.len == 0) return null;
    if (rel[0] != '/') {
        // Relative to the folder of the entry.
        var base = std.mem.splitScalar(u8, entry_path, '/');
        var parts: std.ArrayList([]const u8) = .empty;
        while (base.next()) |p| try parts.append(arena, p);
        if (parts.items.len > 0) _ = parts.pop(); // the entry's own name
        try segments.appendSlice(arena, parts.items);
    }
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len == 0) return null;
            _ = segments.pop();
            continue;
        }
        try segments.append(arena, seg);
    }
    if (segments.items.len == 0) return null;
    return try std.mem.join(arena, "/", segments.items);
}

/// Percent-encodes a path for a URL, keeping `/`.
pub fn encodePath(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~' or ch == '/') {
            try out.append(arena, ch);
        } else {
            try out.append(arena, '%');
            try out.append(arena, hex[ch >> 4]);
            try out.append(arena, hex[ch & 15]);
        }
    }
    return out.items;
}

/// The sanitizer's address hook for an article: links and images that point inside the ZIM become
/// `/zim/<source>/<path>` addresses; addresses to other sites stay as they are; anything else goes.
pub const LinkContext = struct {
    connector: []const u8,
    entry_path: []const u8,
};

pub fn rewriteLink(ctx_ptr: ?*anyopaque, arena: Allocator, kind: @import("htmlsafe.zig").UrlKind, url_in: []const u8) Allocator.Error!?[]const u8 {
    const ctx: *const LinkContext = @ptrCast(@alignCast(ctx_ptr.?));
    const url = std.mem.trim(u8, url_in, " \t\r\n");
    if (url.len == 0) return null;
    // A scheme means another site (the sanitizer already limited which); images from other sites are not loaded.
    const colon = std.mem.indexOfScalar(u8, url, ':');
    const first_sep = std.mem.indexOfAny(u8, url, "/?#");
    const has_scheme = colon != null and (first_sep == null or colon.? < first_sep.?);
    if (has_scheme) return if (kind == .link) url else null;
    if (std.mem.startsWith(u8, url, "//")) return null; // protocol-relative: another site
    if (url[0] == '#') return url;
    // Split off a fragment and a query (the query means nothing inside a ZIM).
    var path_part = url;
    var fragment: []const u8 = "";
    if (std.mem.indexOfScalar(u8, path_part, '#')) |h| {
        fragment = path_part[h..];
        path_part = path_part[0..h];
    }
    if (std.mem.indexOfScalar(u8, path_part, '?')) |q| path_part = path_part[0..q];
    const decoded = (try decodePath(arena, path_part)) orelse return null;
    const resolved = (try resolve(arena, ctx.entry_path, decoded)) orelse return null;
    const encoded = try encodePath(arena, resolved);
    return try std.fmt.allocPrint(arena, "/zim/{s}/{s}{s}", .{ ctx.connector, encoded, fragment });
}

const testing = std.testing;

test "resolving links against the entry that holds them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("A/Other", (try resolve(a, "A/Page", "Other")).?);
    try testing.expectEqualStrings("A/sub/x", (try resolve(a, "A/Page", "./sub/x")).?);
    try testing.expectEqualStrings("I/pic.png", (try resolve(a, "A/Page", "../I/pic.png")).?);
    try testing.expectEqualStrings("Other", (try resolve(a, "Page", "Other")).?);
    try testing.expectEqualStrings("A/Top", (try resolve(a, "A/Deep/Er/Page", "/A/Top")).?);
    try testing.expect((try resolve(a, "Page", "../x")) == null); // leaves the archive
    try testing.expect((try resolve(a, "A/Page", "../../x")) == null);
    try testing.expect((try resolve(a, "A/Page", "")) == null);
    try testing.expect((try resolve(a, "A/Page", "..")) == null);
}

test "path decoding and encoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("A/Caf\u{e9} (x)", (try decodePath(a, "A/Caf%C3%A9%20(x)")).?);
    try testing.expectEqualStrings("a+b", (try decodePath(a, "a+b")).?);
    try testing.expect((try decodePath(a, "bad%")) == null);
    try testing.expect((try decodePath(a, "bad%zz")) == null);
    try testing.expectEqualStrings("A/Caf%C3%A9%20%28x%29", try encodePath(a, "A/Caf\u{e9} (x)"));
}

test "link rewriting keeps other sites, drops foreign images, and points the rest back here" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx: LinkContext = .{ .connector = "knots", .entry_path = "A/Bowline" };
    const hook = struct {
        fn at(c: *const LinkContext, arena_: Allocator, kind: @import("htmlsafe.zig").UrlKind, url: []const u8) !?[]const u8 {
            return rewriteLink(@constCast(c), arena_, kind, url);
        }
    }.at;
    const L = @import("htmlsafe.zig").UrlKind.link;
    const I = @import("htmlsafe.zig").UrlKind.image;
    try testing.expectEqualStrings("/zim/knots/A/Sheet_bend", (try hook(&ctx, a, L, "Sheet_bend")).?);
    try testing.expectEqualStrings("/zim/knots/A/Sheet_bend#history", (try hook(&ctx, a, L, "Sheet_bend?x=1#history")).?);
    try testing.expectEqualStrings("/zim/knots/I/x.png", (try hook(&ctx, a, I, "../I/x.png")).?);
    try testing.expectEqualStrings("#top", (try hook(&ctx, a, L, "#top")).?);
    try testing.expectEqualStrings("https://example.org/x", (try hook(&ctx, a, L, "https://example.org/x")).?);
    try testing.expect((try hook(&ctx, a, I, "https://example.org/p.png")) == null);
    try testing.expect((try hook(&ctx, a, L, "//evil.example/x")) == null);
    try testing.expect((try hook(&ctx, a, L, "../../../x")) == null);
    try testing.expect((try hook(&ctx, a, L, "")) == null);
}
