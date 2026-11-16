//! The text and the details of office documents and ebooks: `docx` (Word), `odt` (OpenDocument
//! text) and `epub`. All three are ZIP files of XML parts; the XML is read with xml-zig, and an
//! EPUB's chapters (XHTML) with the same converter as web pages.
//!
//! Only text is taken. Images, styles, comments' authors, tracked deletions and field codes are
//! left out. A part that cannot be read (damaged XML) makes the document unreadable; it is
//! never half-trusted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xmlzig");
const ziparchive = @import("ziparchive.zig");
const htmltext = @import("htmltext.zig");

pub const Kind = enum {
    docx,
    odt,
    epub,

    pub fn contentType(self: Kind) []const u8 {
        return switch (self) {
            .docx => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            .odt => "application/vnd.oasis.opendocument.text",
            .epub => "application/epub+zip",
        };
    }
};

pub fn kindOf(path: []const u8) ?Kind {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const ext = path[dot + 1 ..];
    inline for (.{ .{ "docx", Kind.docx }, .{ "odt", Kind.odt }, .{ "epub", Kind.epub } }) |p| {
        if (std.ascii.eqlIgnoreCase(ext, p[0])) return p[1];
    }
    return null;
}

pub const Error = ziparchive.Error || error{Unreadable};

pub const Extracted = struct {
    text: []const u8,
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    language: ?[]const u8 = null,
    /// The date the document gives for itself, as written.
    date: ?[]const u8 = null,
};

/// Largest XML part read.
const max_part_bytes = 64 * 1024 * 1024;
const max_chapters = 5000;

const ns_w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const ns_text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
const ns_dc = "http://purl.org/dc/elements/1.1/";
const ns_dcterms = "http://purl.org/dc/terms/";
const ns_meta = "urn:oasis:names:tc:opendocument:xmlns:meta:1.0";
const ns_opf = "http://www.idpf.org/2007/opf";
const ns_container = "urn:oasis:names:tc:opendocument:xmlns:container";

const xml_options: xml.Options = .{ .doctype = .skip, .max_depth = 200, .max_attributes = 128, .max_token_bytes = 8 * 1024 * 1024 };

/// The text of the document and what it says about itself, allocated from `arena`. Fails with
/// `error.TooLarge` if the text would exceed `max_text_bytes`.
pub fn extract(arena: Allocator, archive: *ziparchive.Archive, kind: Kind, max_text_bytes: usize) Error!Extracted {
    var out: Extracted = .{ .text = "" };
    var text: std.ArrayList(u8) = .empty;
    switch (kind) {
        .docx => {
            try docxBody(arena, archive, "word/document.xml", &text, max_text_bytes);
            // Notes at the foot of pages and the end of the document belong to the text.
            for ([_][]const u8{ "word/footnotes.xml", "word/endnotes.xml" }) |part| {
                if (archive.has(part)) docxBody(arena, archive, part, &text, max_text_bytes) catch |e| if (e == error.TooLarge) return e;
            }
            if (archive.has("docProps/core.xml")) readCoreProps(arena, archive, &out) catch {};
        },
        .odt => {
            try odtBody(arena, archive, &text, max_text_bytes);
            if (archive.has("meta.xml")) readOdtMeta(arena, archive, &out) catch {};
        },
        .epub => try epub(arena, archive, &text, &out, max_text_bytes),
    }
    out.text = try tidy(arena, text.items);
    return out;
}

// ------------------------------------------------------------------- shared

fn append(arena: Allocator, text: *std.ArrayList(u8), max: usize, bytes: []const u8) Error!void {
    if (text.items.len + bytes.len > max) return error.TooLarge;
    try text.appendSlice(arena, bytes);
}

/// Trims, and turns three or more line breaks into two.
fn tidy(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var newlines: usize = 0;
    for (std.mem.trim(u8, text, " \t\r\n")) |b| {
        if (b == '\n') {
            newlines += 1;
            if (newlines > 2) continue;
        } else newlines = 0;
        try out.append(arena, b);
    }
    return out.items;
}

fn readPart(arena: Allocator, archive: *ziparchive.Archive, name: []const u8) Error![]u8 {
    return archive.read(arena, name, max_part_bytes) catch |e| switch (e) {
        error.NotFound => error.Unreadable,
        else => |other| other,
    };
}

fn xmlReader(arena: Allocator, bytes: []const u8, src: *std.Io.Reader) xml.Reader {
    src.* = .fixed(bytes);
    return xml.Reader.init(arena, src, xml_options, null);
}

fn attr(attrs: []const xml.Attribute, ns: []const u8, local: []const u8) ?[]const u8 {
    for (attrs) |a| if (a.name.is(ns, local)) return a.value;
    return null;
}

// --------------------------------------------------------------------- docx

fn docxBody(arena: Allocator, archive: *ziparchive.Archive, part: []const u8, text: *std.ArrayList(u8), max: usize) Error!void {
    const bytes = try readPart(arena, archive, part);
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var in_t = false;
    var cell_depth: u32 = 0;
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                if (!std.mem.eql(u8, s.name.uri, ns_w)) continue;
                if (std.mem.eql(u8, s.name.local, "t")) in_t = true else if (std.mem.eql(u8, s.name.local, "tab")) try append(arena, text, max, "\t") else if (std.mem.eql(u8, s.name.local, "br") or std.mem.eql(u8, s.name.local, "cr")) try append(arena, text, max, "\n") else if (std.mem.eql(u8, s.name.local, "tc")) cell_depth += 1;
            },
            .end_element => |e| {
                if (!std.mem.eql(u8, e.name.uri, ns_w)) continue;
                if (std.mem.eql(u8, e.name.local, "t")) {
                    in_t = false;
                } else if (std.mem.eql(u8, e.name.local, "p")) {
                    try append(arena, text, max, if (cell_depth > 0) "\t" else "\n");
                } else if (std.mem.eql(u8, e.name.local, "tc")) {
                    if (cell_depth > 0) cell_depth -= 1;
                } else if (std.mem.eql(u8, e.name.local, "tr")) {
                    // The last cell's tab ends the row.
                    if (text.items.len > 0 and text.items[text.items.len - 1] == '\t') text.items[text.items.len - 1] = '\n' else try append(arena, text, max, "\n");
                }
            },
            .text, .cdata => |t| if (in_t) try append(arena, text, max, t),
            .end_of_document => break,
            else => {},
        }
    }
}

/// `dc:title`, `dc:creator` and a modified or created date from the package's core properties.
fn readCoreProps(arena: Allocator, archive: *ziparchive.Archive, out: *Extracted) Error!void {
    const bytes = try readPart(arena, archive, "docProps/core.xml");
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var field: enum { none, title, creator, modified, created } = .none;
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                field = .none;
                if (s.name.is(ns_dc, "title")) field = .title else if (s.name.is(ns_dc, "creator")) field = .creator else if (s.name.is(ns_dcterms, "modified")) field = .modified else if (s.name.is(ns_dcterms, "created")) field = .created;
            },
            .end_element => field = .none,
            .text => |t| {
                const v = std.mem.trim(u8, t, " \t\r\n");
                if (v.len == 0) continue;
                switch (field) {
                    .title => if (out.title == null) {
                        out.title = try arena.dupe(u8, v);
                    },
                    .creator => if (out.author == null) {
                        out.author = try arena.dupe(u8, v);
                    },
                    .modified => out.date = try arena.dupe(u8, v),
                    .created => if (out.date == null) {
                        out.date = try arena.dupe(u8, v);
                    },
                    .none => {},
                }
            },
            .end_of_document => break,
            else => {},
        }
    }
}

// ---------------------------------------------------------------------- odt

fn odtBody(arena: Allocator, archive: *ziparchive.Archive, text: *std.ArrayList(u8), max: usize) Error!void {
    const bytes = try readPart(arena, archive, "content.xml");
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var in_paragraph: u32 = 0; // inside text:p or text:h: only there is character data text
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                if (!std.mem.eql(u8, s.name.uri, ns_text)) continue;
                if (std.mem.eql(u8, s.name.local, "p") or std.mem.eql(u8, s.name.local, "h")) {
                    in_paragraph += 1;
                } else if (std.mem.eql(u8, s.name.local, "s")) {
                    const n = if (attr(s.attributes, ns_text, "c")) |c| (std.fmt.parseInt(usize, c, 10) catch 1) else 1;
                    var i: usize = 0;
                    while (i < @min(n, 1000)) : (i += 1) try append(arena, text, max, " ");
                } else if (std.mem.eql(u8, s.name.local, "tab")) {
                    try append(arena, text, max, "\t");
                } else if (std.mem.eql(u8, s.name.local, "line-break")) {
                    try append(arena, text, max, "\n");
                }
            },
            .end_element => |e| {
                if (!std.mem.eql(u8, e.name.uri, ns_text)) continue;
                if (std.mem.eql(u8, e.name.local, "p") or std.mem.eql(u8, e.name.local, "h")) {
                    if (in_paragraph > 0) in_paragraph -= 1;
                    try append(arena, text, max, "\n");
                }
            },
            .text, .cdata => |t| if (in_paragraph > 0) try append(arena, text, max, t),
            .end_of_document => break,
            else => {},
        }
    }
}

fn readOdtMeta(arena: Allocator, archive: *ziparchive.Archive, out: *Extracted) Error!void {
    const bytes = try readPart(arena, archive, "meta.xml");
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var field: enum { none, title, creator, initial, date, created } = .none;
    var initial: ?[]const u8 = null;
    var created: ?[]const u8 = null;
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                field = .none;
                if (s.name.is(ns_dc, "title")) field = .title else if (s.name.is(ns_dc, "creator")) field = .creator else if (s.name.is(ns_meta, "initial-creator")) field = .initial else if (s.name.is(ns_dc, "date")) field = .date else if (s.name.is(ns_meta, "creation-date")) field = .created;
            },
            .end_element => field = .none,
            .text => |t| {
                const v = std.mem.trim(u8, t, " \t\r\n");
                if (v.len == 0) continue;
                switch (field) {
                    .title => if (out.title == null) {
                        out.title = try arena.dupe(u8, v);
                    },
                    .creator => if (out.author == null) {
                        out.author = try arena.dupe(u8, v);
                    },
                    .initial => initial = try arena.dupe(u8, v),
                    .date => out.date = try arena.dupe(u8, v),
                    .created => created = try arena.dupe(u8, v),
                    .none => {},
                }
            },
            .end_of_document => break,
            else => {},
        }
    }
    if (out.author == null) out.author = initial;
    if (out.date == null) out.date = created;
}

// --------------------------------------------------------------------- epub

const Item = struct { id: []const u8, href: []const u8, media: []const u8 };

fn epub(arena: Allocator, archive: *ziparchive.Archive, text: *std.ArrayList(u8), out: *Extracted, max: usize) Error!void {
    // META-INF/container.xml names the package file.
    const container = try readPart(arena, archive, "META-INF/container.xml");
    var src1: std.Io.Reader = undefined;
    var rd1 = xmlReader(arena, container, &src1);
    defer rd1.deinit();
    var opf_path: ?[]const u8 = null;
    while (true) {
        const ev = rd1.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| if (s.name.is(ns_container, "rootfile") and opf_path == null) {
                if (attr(s.attributes, "", "full-path")) |p| opf_path = try arena.dupe(u8, p);
            },
            .end_of_document => break,
            else => {},
        }
    }
    const opf = opf_path orelse return error.Unreadable;

    const opf_bytes = try readPart(arena, archive, opf);
    var src2: std.Io.Reader = undefined;
    var rd2 = xmlReader(arena, opf_bytes, &src2);
    defer rd2.deinit();
    var items: std.ArrayList(Item) = .empty;
    var spine: std.ArrayList([]const u8) = .empty;
    var field: enum { none, title, creator, language, date } = .none;
    while (true) {
        const ev = rd2.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                field = .none;
                if (s.name.is(ns_dc, "title")) field = .title else if (s.name.is(ns_dc, "creator")) field = .creator else if (s.name.is(ns_dc, "language")) field = .language else if (s.name.is(ns_dc, "date")) field = .date else if (s.name.is(ns_opf, "item")) {
                    if (items.items.len < 20000) if (attr(s.attributes, "", "id")) |id| if (attr(s.attributes, "", "href")) |href| {
                        try items.append(arena, .{ .id = try arena.dupe(u8, id), .href = try arena.dupe(u8, href), .media = try arena.dupe(u8, attr(s.attributes, "", "media-type") orelse "") });
                    };
                } else if (s.name.is(ns_opf, "itemref")) {
                    if (spine.items.len < max_chapters) if (attr(s.attributes, "", "idref")) |r| try spine.append(arena, try arena.dupe(u8, r));
                }
            },
            .end_element => field = .none,
            .text => |t| {
                const v = std.mem.trim(u8, t, " \t\r\n");
                if (v.len == 0) continue;
                switch (field) {
                    .title => if (out.title == null) {
                        out.title = try arena.dupe(u8, v);
                    },
                    .creator => if (out.author == null) {
                        out.author = try arena.dupe(u8, v);
                    },
                    .language => if (out.language == null) {
                        out.language = try arena.dupe(u8, v);
                    },
                    .date => if (out.date == null) {
                        out.date = try arena.dupe(u8, v);
                    },
                    .none => {},
                }
            },
            .end_of_document => break,
            else => {},
        }
    }

    // The chapters, in reading order.
    const dir = if (std.mem.lastIndexOfScalar(u8, opf, '/')) |i| opf[0 .. i + 1] else "";
    for (spine.items) |idref| {
        const item = for (items.items) |it| {
            if (std.mem.eql(u8, it.id, idref)) break it;
        } else continue;
        const is_html = std.mem.startsWith(u8, item.media, "application/xhtml") or std.mem.startsWith(u8, item.media, "text/html");
        if (!is_html) continue;
        const path = (try resolvePath(arena, dir, item.href)) orelse continue;
        const html = archive.read(arena, path, 16 * 1024 * 1024) catch |e| switch (e) {
            error.NotFound => continue,
            else => |other| return other,
        };
        const chapter = try htmltext.toText(arena, html);
        if (chapter.len == 0) continue;
        if (text.items.len > 0) try append(arena, text, max, "\n\n");
        try append(arena, text, max, chapter);
    }
}

/// `href` (percent-encoded, relative to the package file's folder `dir`) as a path in the archive.
fn resolvePath(arena: Allocator, dir: []const u8, href: []const u8) Allocator.Error!?[]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const path = if (std.mem.indexOfAny(u8, href, "#?")) |e| href[0..e] else href;
    while (i < path.len) : (i += 1) {
        if (path[i] == '%' and i + 2 < path.len) {
            if (std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16)) |b| {
                try decoded.append(arena, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try decoded.append(arena, path[i]);
    }
    var segments: std.ArrayList([]const u8) = .empty;
    var base = std.mem.splitScalar(u8, dir, '/');
    while (base.next()) |s| if (s.len > 0) try segments.append(arena, s);
    var it = std.mem.splitScalar(u8, decoded.items, '/');
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

const testing = std.testing;

fn openFixture(tmp: *testing.TmpDir, name: []const u8, bytes: []const u8, ar: *ziparchive.Archive, arena: Allocator) !std.Io.File {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    const file = try tmp.dir.openFile(testing.io, name, .{});
    try ar.open(arena, testing.io, file);
    return file;
}

test "file kinds" {
    try testing.expect(kindOf("a/B.DOCX").? == .docx);
    try testing.expect(kindOf("x.odt").? == .odt);
    try testing.expect(kindOf("x.epub").? == .epub);
    try testing.expect(kindOf("x.doc") == null);
    try testing.expect(kindOf("noext") == null);
}

test "a Word document: paragraphs, tabs, breaks and tables; no deleted text or field codes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ar: ziparchive.Archive = undefined;
    const file = try openFixture(&tmp, "s.docx", @embedFile("testdata/office/sample.docx"), &ar, a);
    defer file.close(testing.io);
    const got = try extract(a, &ar, .docx, 1 << 20);
    try testing.expectEqualStrings("Tides at the harbour\nSpring tides follow the new moon\tand fishing boats wait.\nFirst line\nsecond line\n\ncell one\tcell two", got.text);
    try testing.expectEqualStrings("Harbour Report", got.title.?);
    try testing.expectEqualStrings("Ada Quill", got.author.?);
    try testing.expectEqualStrings("2026-03-04T10:00:00Z", got.date.?);
    try testing.expect(std.mem.indexOf(u8, got.text, "removed words") == null);
    try testing.expect(std.mem.indexOf(u8, got.text, "PAGE") == null);
    try testing.expectError(error.TooLarge, extract(a, &ar, .docx, 20));
}

test "an OpenDocument text: headings, spaces, tabs, line breaks, lists, and the title" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ar: ziparchive.Archive = undefined;
    const file = try openFixture(&tmp, "s.odt", @embedFile("testdata/office/sample.odt"), &ar, a);
    defer file.close(testing.io);
    const got = try extract(a, &ar, .odt, 1 << 20);
    try testing.expectEqualStrings("Keeping the lantern lit\nTrim the wick   and polish the lens.\tDone.\nNext line.\nan item in a list", got.text);
    try testing.expectEqualStrings("Lantern Notes", got.title.?);
    try testing.expectEqualStrings("Bo Reed", got.author.?);
    try testing.expectEqualStrings("2026-02-03T04:05:06", got.date.?);
}

test "an EPUB: chapters in reading order, with the book's details" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ar: ziparchive.Archive = undefined;
    const file = try openFixture(&tmp, "s.epub", @embedFile("testdata/office/sample.epub"), &ar, a);
    defer file.close(testing.io);
    const got = try extract(a, &ar, .epub, 1 << 20);
    try testing.expectEqualStrings("Chapter one\nThe lighthouse stands on the cape.\n\nChapter two\nZeppelins crossed the bay & the harbour.", got.text); // the manifest lists chapter two first; the spine decides
    try testing.expectEqualStrings("The Sea Almanac", got.title.?);
    try testing.expectEqualStrings("C. Marlowe", got.author.?);
    try testing.expectEqualStrings("en", got.language.?);
    try testing.expectEqualStrings("1901-05-06", got.date.?);
}

test "a zip that is not that kind of document is Unreadable, never a crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ar: ziparchive.Archive = undefined;
    const file = try openFixture(&tmp, "s.docx", @embedFile("testdata/office/sample.docx"), &ar, a);
    defer file.close(testing.io);
    try testing.expectError(error.Unreadable, extract(a, &ar, .odt, 1 << 20));
    try testing.expectError(error.Unreadable, extract(a, &ar, .epub, 1 << 20));
}

test "resolving chapter paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("OEBPS/text/one.xhtml", (try resolvePath(a, "OEBPS/", "text/one.xhtml")).?);
    try testing.expectEqualStrings("OEBPS/a b.xhtml", (try resolvePath(a, "OEBPS/", "a%20b.xhtml#frag")).?);
    try testing.expectEqualStrings("x.xhtml", (try resolvePath(a, "OEBPS/", "../x.xhtml")).?);
    try testing.expect((try resolvePath(a, "", "../x.xhtml")) == null);
    try testing.expect((try resolvePath(a, "", "")) == null);
}
