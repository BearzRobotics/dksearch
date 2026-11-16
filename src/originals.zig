//! Serving the original files of a `files` source, so a result can be opened in the browser
//! (a PDF in the browser's own viewer, an image, a text file).
//!
//! Off unless a source says `serve_originals = true`. A file is only ever read from below the
//! source's own folder: its address (taken from the index, never from the request) is decoded,
//! resolved through symbolic links, and must lie inside the resolved folder.
//!
//! What is shown inline is limited to types that cannot run script on our origin: PDF (the
//! browser's viewer runs it in its own sandbox), common images, and plain text. HTML, SVG and
//! everything else is offered as a download, or as plain text, never as a page.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Root = struct {
    /// The source (connector) name.
    connector: []const u8,
    /// The folder the source reads, as configured.
    base: []const u8,
};

pub const Error = error{
    /// The source does not serve originals, or the address is not a local file.
    NotServed,
    NotFound,
    /// Resolves to somewhere outside the source's folder.
    Forbidden,
    TooLarge,
    Io,
    OutOfMemory,
};

pub const Served = struct {
    bytes: []const u8,
    content_type: []const u8,
    /// Shown in the browser; otherwise offered as a download.
    inline_view: bool,
    /// The file's name, for the download.
    filename: []const u8,
};

pub const Service = struct {
    io: Io,
    roots: []const Root,
    /// Largest file served, in bytes. A response is built in memory.
    max_bytes: u64 = 64 * 1024 * 1024,

    pub fn rootFor(self: *const Service, connector: []const u8) ?Root {
        for (self.roots) |r| if (std.mem.eql(u8, r.connector, connector)) return r;
        return null;
    }

    /// True if `connector` serves originals and `url` is a local file address.
    pub fn serves(self: *const Service, connector: []const u8, url: []const u8) bool {
        return self.rootFor(connector) != null and std.mem.startsWith(u8, url, "file://");
    }

    pub fn read(self: *const Service, arena: Allocator, connector: []const u8, url: []const u8) Error!Served {
        const root = self.rootFor(connector) orelse return error.NotServed;
        if (!std.mem.startsWith(u8, url, "file://")) return error.NotServed;
        const path = try decodePath(arena, url["file://".len..]);
        if (path.len == 0 or path[0] != '/') return error.NotServed;

        const dir = Io.Dir.cwd();
        const real_root = dir.realPathFileAlloc(self.io, root.base, arena) catch return error.NotFound;
        const real_file = dir.realPathFileAlloc(self.io, path, arena) catch return error.NotFound;
        if (!within(real_root, real_file)) return error.Forbidden;

        var file = dir.openFile(self.io, real_file, .{}) catch return error.NotFound;
        defer file.close(self.io);
        const st = file.stat(self.io) catch return error.Io;
        if (st.kind != .file) return error.NotFound;
        if (st.size > self.max_bytes) return error.TooLarge;
        var buf: [16 * 1024]u8 = undefined;
        var fr = file.reader(self.io, &buf);
        const bytes = fr.interface.allocRemaining(arena, .limited(self.max_bytes)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.TooLarge,
            error.ReadFailed => return error.Io,
        };
        const name = if (std.mem.lastIndexOfScalar(u8, real_file, '/')) |i| real_file[i + 1 ..] else real_file;
        const kind = classify(name);
        return .{ .bytes = bytes, .content_type = kind.content_type, .inline_view = kind.inline_view, .filename = name };
    }
};

/// True if `file` is `root` itself or below it (both already resolved).
pub fn within(root: []const u8, file: []const u8) bool {
    if (root.len == 0) return false;
    var r = root;
    while (r.len > 1 and r[r.len - 1] == '/') r = r[0 .. r.len - 1];
    if (std.mem.eql(u8, r, "/")) return file.len > 0 and file[0] == '/';
    if (!std.mem.startsWith(u8, file, r)) return false;
    return file.len == r.len or file[r.len] == '/';
}

/// Percent-decodes a path from a `file://` address.
fn decodePath(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(arena, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(arena, s[i]);
    }
    return out.items;
}

const Kind = struct { content_type: []const u8, inline_view: bool };

fn classify(name: []const u8) Kind {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .{ .content_type = "application/octet-stream", .inline_view = false };
    var buf: [12]u8 = undefined;
    const ext_raw = name[dot + 1 ..];
    if (ext_raw.len == 0 or ext_raw.len > buf.len) return .{ .content_type = "application/octet-stream", .inline_view = false };
    const ext = std.ascii.lowerString(&buf, ext_raw);
    const table = [_]struct { []const u8, []const u8, bool }{
        .{ "pdf", "application/pdf", true },
        .{ "png", "image/png", true },
        .{ "jpg", "image/jpeg", true },
        .{ "jpeg", "image/jpeg", true },
        .{ "gif", "image/gif", true },
        .{ "webp", "image/webp", true },
        .{ "bmp", "image/bmp", true },
        // Text is shown as plain text, whatever it claims to be (Markdown, HTML and so on),
        // so nothing in it can act as a page of ours.
        .{ "txt", "text/plain; charset=utf-8", true },
        .{ "md", "text/plain; charset=utf-8", true },
        .{ "markdown", "text/plain; charset=utf-8", true },
        .{ "log", "text/plain; charset=utf-8", true },
        .{ "csv", "text/plain; charset=utf-8", true },
        .{ "json", "text/plain; charset=utf-8", true },
        .{ "xml", "text/plain; charset=utf-8", true },
        .{ "html", "text/plain; charset=utf-8", true },
        .{ "htm", "text/plain; charset=utf-8", true },
        .{ "rst", "text/plain; charset=utf-8", true },
        .{ "org", "text/plain; charset=utf-8", true },
        .{ "toml", "text/plain; charset=utf-8", true },
        .{ "yaml", "text/plain; charset=utf-8", true },
        .{ "yml", "text/plain; charset=utf-8", true },
    };
    for (table) |row| if (std.mem.eql(u8, ext, row[0])) return .{ .content_type = row[1], .inline_view = row[2] };
    return .{ .content_type = "application/octet-stream", .inline_view = false };
}

/// A `content-disposition` value for `name`: the name is reduced to safe characters, with the
/// full name in the RFC 6266 `filename*` form.
pub fn dispositionFor(arena: Allocator, inline_view: bool, name: []const u8) Allocator.Error![]const u8 {
    var ascii: std.ArrayList(u8) = .empty;
    var pct: std.ArrayList(u8) = .empty;
    for (name) |b| {
        const plain = std.ascii.isAlphanumeric(b) or b == '.' or b == '-' or b == '_';
        try ascii.append(arena, if (plain) b else '_');
        if (plain) try pct.append(arena, b) else try pct.print(arena, "%{X:0>2}", .{b});
    }
    return std.fmt.allocPrint(arena, "{s}; filename=\"{s}\"; filename*=UTF-8''{s}", .{ if (inline_view) "inline" else "attachment", ascii.items, pct.items });
}

const testing = std.testing;

test "within: only the folder itself and what is below it" {
    try testing.expect(within("/home/me/notes", "/home/me/notes/a.pdf"));
    try testing.expect(within("/home/me/notes/", "/home/me/notes/sub/a.pdf"));
    try testing.expect(within("/home/me/notes", "/home/me/notes"));
    try testing.expect(!within("/home/me/notes", "/home/me/notes2/a.pdf")); // a sibling that shares a prefix
    try testing.expect(!within("/home/me/notes", "/home/me/other/a.pdf"));
    try testing.expect(!within("/home/me/notes", "/home/me"));
    try testing.expect(!within("", "/x"));
    try testing.expect(within("/", "/etc/passwd")); // the root folder is the whole file system: only if configured so
}

test "decoding a file address" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/home/me/my notes/a#b.txt", try decodePath(arena.allocator(), "/home/me/my%20notes/a%23b.txt"));
    try testing.expectEqualStrings("/a%zz/b%", try decodePath(arena.allocator(), "/a%zz/b%"));
}

test "types: what may be shown and what is only a download" {
    try testing.expect(classify("report.PDF").inline_view);
    try testing.expectEqualStrings("application/pdf", classify("report.PDF").content_type);
    try testing.expectEqualStrings("image/png", classify("a.png").content_type);
    // Markup is text, never a page.
    try testing.expectEqualStrings("text/plain; charset=utf-8", classify("page.html").content_type);
    try testing.expectEqualStrings("text/plain; charset=utf-8", classify("x.md").content_type);
    // SVG can carry script: a download. So can anything unknown.
    try testing.expect(!classify("logo.svg").inline_view);
    try testing.expect(!classify("doc.docx").inline_view);
    try testing.expect(!classify("noext").inline_view);
    try testing.expect(!classify("trailing.").inline_view);
}

test "content-disposition names are safe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try dispositionFor(arena.allocator(), true, "my \"file\"\r\nX: y.pdf");
    try testing.expectEqualStrings("inline; filename=\"my__file___X__y.pdf\"; filename*=UTF-8''my%20%22file%22%0D%0AX%3A%20y.pdf", v);
    try testing.expect(std.mem.indexOfAny(u8, v, "\r\n") == null);
}

fn makeTree(tmp: *testing.TmpDir) !void {
    try tmp.dir.createDirPath(testing.io, "notes/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes/a.pdf", .data = "%PDF-1.4 fake" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes/sub/b.txt", .data = "hello" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes/big.bin", .data = "0123456789" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "secret.txt", .data = "outside" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes2.txt", .data = "sibling" });
    try tmp.dir.symLink(testing.io, "../secret.txt", "notes/link.txt", .{});
}

test "reads files below the folder; refuses everything else" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeTree(&tmp);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const abs = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const base = try std.fmt.allocPrint(a, "{s}/notes", .{abs});
    const roots = [_]Root{.{ .connector = "notes", .base = base }};
    const svc: Service = .{ .io = testing.io, .roots = &roots, .max_bytes = 100 };

    const pdf = try svc.read(a, "notes", try std.fmt.allocPrint(a, "file://{s}/a.pdf", .{base}));
    try testing.expectEqualStrings("%PDF-1.4 fake", pdf.bytes);
    try testing.expectEqualStrings("application/pdf", pdf.content_type);
    try testing.expect(pdf.inline_view);
    try testing.expectEqualStrings("a.pdf", pdf.filename);
    const txt = try svc.read(a, "notes", try std.fmt.allocPrint(a, "file://{s}/sub/b.txt", .{base}));
    try testing.expectEqualStrings("hello", txt.bytes);

    // Outside the folder, by path, by `..`, through a symbolic link, and a sibling with the same prefix.
    for ([_][]const u8{ "{s}/../secret.txt", "{s}/sub/../../secret.txt", "{s}/link.txt", "{s}2.txt" }) |pat| {
        const u = try std.fmt.allocPrint(a, "file://{s}", .{try std.mem.replaceOwned(u8, a, pat, "{s}", base)});
        errdefer std.debug.print("url: {s}\n", .{u});
        if (svc.read(a, "notes", u)) |_| return error.TestUnexpectedResult else |e| try testing.expect(e == error.Forbidden or e == error.NotFound);
    }
    // Not served: another source, a web address, a missing file.
    try testing.expectError(error.NotServed, svc.read(a, "other", "file:///etc/passwd"));
    try testing.expectError(error.NotServed, svc.read(a, "notes", "https://example.org/a.pdf"));
    try testing.expectError(error.NotFound, svc.read(a, "notes", try std.fmt.allocPrint(a, "file://{s}/nope.pdf", .{base})));
    try testing.expectError(error.NotFound, svc.read(a, "notes", try std.fmt.allocPrint(a, "file://{s}/sub", .{base}))); // a directory
    // Too big.
    const small: Service = .{ .io = testing.io, .roots = &roots, .max_bytes = 5 };
    try testing.expectError(error.TooLarge, small.read(a, "notes", try std.fmt.allocPrint(a, "file://{s}/big.bin", .{base})));
}
