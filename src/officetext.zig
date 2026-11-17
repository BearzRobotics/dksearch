//! The text and the details of office documents and ebooks: `docx` (Word), `odt` (OpenDocument
//! text), `xlsx` and `ods` (spreadsheets), `pptx` and `odp` (presentations) and `epub`. All three are ZIP files of XML parts; the XML is read with xml-zig, and an
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
const doc = @import("document.zig");

pub const Kind = enum {
    docx,
    odt,
    epub,
    xlsx,
    ods,
    pptx,
    odp,

    pub fn contentType(self: Kind) []const u8 {
        return switch (self) {
            .docx => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            .odt => "application/vnd.oasis.opendocument.text",
            .epub => "application/epub+zip",
            .xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            .ods => "application/vnd.oasis.opendocument.spreadsheet",
            .pptx => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            .odp => "application/vnd.oasis.opendocument.presentation",
        };
    }
};

pub fn kindOf(path: []const u8) ?Kind {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const ext = path[dot + 1 ..];
    inline for (.{ .{ "docx", Kind.docx }, .{ "odt", Kind.odt }, .{ "epub", Kind.epub }, .{ "xlsx", Kind.xlsx }, .{ "ods", Kind.ods }, .{ "pptx", Kind.pptx }, .{ "odp", Kind.odp } }) |p| {
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
    // The rest of what document programs and document management systems put in a file's properties.
    subject: ?[]const u8 = null,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
    last_modified_by: ?[]const u8 = null,
    /// The program that made the file, and the company and manager its properties name.
    application: ?[]const u8 = null,
    company: ?[]const u8 = null,
    manager: ?[]const u8 = null,
    /// Keywords or tags (split at commas and semicolons).
    keywords: []const []const u8 = &.{},
    /// Properties a person or a system added (SharePoint columns, DMS fields), as name and text.
    custom: []const Pair = &.{},

    pub const Pair = struct { name: []const u8, value: []const u8 };
};

const max_keywords = 50;
const max_custom = 100;

/// Adds the words of `list` (comma or semicolon separated) to `out.keywords`.
fn addKeywords(arena: Allocator, out: *Extracted, list: []const u8) Allocator.Error!void {
    var kw: std.ArrayList([]const u8) = .empty;
    try kw.appendSlice(arena, out.keywords);
    var it = std.mem.tokenizeAny(u8, list, ",;\n");
    while (it.next()) |raw| {
        const k = std.mem.trim(u8, raw, " \t\r");
        if (k.len == 0 or k.len > 200 or kw.items.len >= max_keywords) continue;
        try kw.append(arena, try arena.dupe(u8, k));
    }
    out.keywords = kw.items;
}

fn addCustom(arena: Allocator, out: *Extracted, name: []const u8, value: []const u8) Allocator.Error!void {
    const n = std.mem.trim(u8, name, " \t\r\n");
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (n.len == 0 or v.len == 0 or out.custom.len >= max_custom) return;
    var c: std.ArrayList(Extracted.Pair) = .empty;
    try c.appendSlice(arena, out.custom);
    try c.append(arena, .{ .name = try arena.dupe(u8, n), .value = try arena.dupe(u8, v[0..@min(v.len, 1000)]) });
    out.custom = c.items;
}

fn setOnce(arena: Allocator, slot: *?[]const u8, v: []const u8) Allocator.Error!void {
    if (slot.* == null) slot.* = try arena.dupe(u8, v[0..@min(v.len, 2000)]);
}

/// Largest XML part read.
const max_part_bytes = 64 * 1024 * 1024;
const max_chapters = 5000;

const ns_w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const ns_text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";
const ns_table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
const ns_draw = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0";
const ns_ss = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
const ns_a = "http://schemas.openxmlformats.org/drawingml/2006/main";
const max_sheets = 500;
const max_shared_strings = 4 * 1024 * 1024;
const ns_cp = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties";
const ns_extended = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties";
const ns_custom = "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties";
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
            readPackageProps(arena, archive, &out);
        },
        .odt, .ods, .odp => {
            try odtBody(arena, archive, &text, max_text_bytes, switch (kind) {
                .ods => .sheet,
                .odp => .slides,
                else => .text,
            });
            if (archive.has("meta.xml")) readOdtMeta(arena, archive, &out) catch {};
        },
        .xlsx => {
            try xlsxBody(arena, archive, &text, max_text_bytes);
            readPackageProps(arena, archive, &out);
        },
        .pptx => {
            try pptxBody(arena, archive, &text, max_text_bytes);
            readPackageProps(arena, archive, &out);
        },
        .epub => try epub(arena, archive, &text, &out, max_text_bytes),
    }
    out.text = try tidy(arena, text.items);
    return out;
}

/// The properties as tags and fields the index can filter on: each keyword a `tag` (`tag:budget`), and `subject`,
/// `category`, `description`, `last_modified_by`, `application`, `company`, `manager` and the custom properties
/// (name lower-cased, spaces as `_`) as fields.
pub fn metadataExtras(arena: Allocator, got: Extracted, out: *std.ArrayList(doc.Extra)) Allocator.Error!void {
    for (got.keywords) |k| try out.append(arena, .{ .key = "tag", .value = k });
    const fixed = [_]struct { []const u8, ?[]const u8 }{
        .{ "subject", got.subject },
        .{ "category", got.category },
        .{ "description", got.description },
        .{ "last_modified_by", got.last_modified_by },
        .{ "application", got.application },
        .{ "company", got.company },
        .{ "manager", got.manager },
    };
    for (fixed) |f| if (f[1]) |v| try out.append(arena, .{ .key = f[0], .value = v[0..@min(v.len, 256)] });
    for (got.custom) |c| {
        const key = try arena.alloc(u8, @min(c.name.len, 32));
        for (key, c.name[0..key.len]) |*d, ch| d.* = if (std.ascii.isAlphanumeric(ch) or ch == '-') std.ascii.toLower(ch) else '_';
        try out.append(arena, .{ .key = key, .value = c.value[0..@min(c.value.len, 256)] });
    }
}

/// The text with the words of the properties that describe the content (subject, keywords, description, category)
/// added at the end as short lines, so that a search for them finds the file even when its body does not say them.
pub fn withMetadataText(arena: Allocator, got: Extracted) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, got.text);
    var wrote = false;
    const lines = [_]struct { []const u8, ?[]const u8 }{ .{ "Subject", got.subject }, .{ "Category", got.category }, .{ "Description", got.description } };
    for (lines) |l| if (l[1]) |v| {
        if (!wrote) try out.appendSlice(arena, "\n\n");
        wrote = true;
        try out.print(arena, "{s}: {s}\n", .{ l[0], v });
    };
    if (got.keywords.len > 0) {
        if (!wrote) try out.appendSlice(arena, "\n\n");
        try out.appendSlice(arena, "Keywords: ");
        for (got.keywords, 0..) |k, i| {
            if (i > 0) try out.appendSlice(arena, ", ");
            try out.appendSlice(arena, k);
        }
        try out.append(arena, '\n');
    }
    return out.items;
}

// ------------------------------------------------------------------- shared

/// Core, application and custom properties of an Office Open XML package; a part that cannot be read is left out.
fn readPackageProps(arena: Allocator, archive: *ziparchive.Archive, out: *Extracted) void {
    if (archive.has("docProps/core.xml")) readCoreProps(arena, archive, out) catch {};
    if (archive.has("docProps/app.xml")) readAppProps(arena, archive, out) catch {};
    if (archive.has("docProps/custom.xml")) readCustomProps(arena, archive, out) catch {};
}

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
    var field: enum { none, title, creator, modified, created, subject, description, keywords, category, last_modified_by } = .none;
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                field = .none;
                if (s.name.is(ns_dc, "title")) field = .title else if (s.name.is(ns_dc, "creator")) field = .creator else if (s.name.is(ns_dcterms, "modified")) field = .modified else if (s.name.is(ns_dcterms, "created")) field = .created else if (s.name.is(ns_dc, "subject")) field = .subject else if (s.name.is(ns_dc, "description")) field = .description else if (s.name.is(ns_cp, "keywords")) field = .keywords else if (s.name.is(ns_cp, "category")) field = .category else if (s.name.is(ns_cp, "lastModifiedBy")) field = .last_modified_by;
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
                    .subject => try setOnce(arena, &out.subject, v),
                    .description => try setOnce(arena, &out.description, v),
                    .keywords => try addKeywords(arena, out, v),
                    .category => try setOnce(arena, &out.category, v),
                    .last_modified_by => try setOnce(arena, &out.last_modified_by, v),
                    .none => {},
                }
            },
            .end_of_document => break,
            else => {},
        }
    }
}

/// `Application`, `Company` and `Manager` from `docProps/app.xml`.
fn readAppProps(arena: Allocator, archive: *ziparchive.Archive, out: *Extracted) Error!void {
    const bytes = try readPart(arena, archive, "docProps/app.xml");
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var field: enum { none, application, company, manager } = .none;
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                field = .none;
                if (s.name.is(ns_extended, "Application")) field = .application else if (s.name.is(ns_extended, "Company")) field = .company else if (s.name.is(ns_extended, "Manager")) field = .manager;
            },
            .end_element => field = .none,
            .text => |t| {
                const v = std.mem.trim(u8, t, " \t\r\n");
                if (v.len == 0) continue;
                switch (field) {
                    .application => try setOnce(arena, &out.application, v),
                    .company => try setOnce(arena, &out.company, v),
                    .manager => try setOnce(arena, &out.manager, v),
                    .none => {},
                }
            },
            .end_of_document => break,
            else => {},
        }
    }
}

/// Properties added by people and systems: `docProps/custom.xml`, one `property` per field with a typed value.
fn readCustomProps(arena: Allocator, archive: *ziparchive.Archive, out: *Extracted) Error!void {
    const bytes = try readPart(arena, archive, "docProps/custom.xml");
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var name: ?[]const u8 = null;
    var depth: u32 = 0; // inside a property
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                if (depth == 0 and s.name.is(ns_custom, "property")) {
                    name = if (attr(s.attributes, "", "name")) |n| try arena.dupe(u8, n) else null;
                    depth = 1;
                } else if (depth > 0) depth += 1;
            },
            .end_element => if (depth > 0) {
                depth -= 1;
                if (depth == 0) name = null;
            },
            .text => |t| if (depth > 1) if (name) |n| try addCustom(arena, out, n, t),
            .end_of_document => break,
            else => {},
        }
    }
}

// ---------------------------------------------------------------------- odt

const OdMode = enum { text, sheet, slides };

fn odtBody(arena: Allocator, archive: *ziparchive.Archive, text: *std.ArrayList(u8), max: usize, mode: OdMode) Error!void {
    const bytes = try readPart(arena, archive, "content.xml");
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var in_paragraph: u32 = 0; // inside text:p or text:h: only there is character data text
    var cell_start: usize = 0; // where the current spreadsheet cell's text began
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                if (mode == .sheet and std.mem.eql(u8, s.name.uri, ns_table)) {
                    if (std.mem.eql(u8, s.name.local, "table")) {
                        // A sheet's name is worth finding by.
                        if (attr(s.attributes, ns_table, "name")) |n| {
                            try append(arena, text, max, n);
                            try append(arena, text, max, "\n");
                        }
                    } else if (std.mem.eql(u8, s.name.local, "table-cell") or std.mem.eql(u8, s.name.local, "covered-table-cell")) cell_start = text.items.len;
                    continue;
                }
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
                if (mode == .sheet and std.mem.eql(u8, e.name.uri, ns_table)) {
                    if (std.mem.eql(u8, e.name.local, "table-cell")) {
                        // Cells are separated by a tab; empty ones leave nothing.
                        while (text.items.len > cell_start and (text.items[text.items.len - 1] == ' ' or text.items[text.items.len - 1] == '\n')) _ = text.pop();
                        if (text.items.len > cell_start) try append(arena, text, max, "\t");
                    } else if (std.mem.eql(u8, e.name.local, "table-row")) {
                        if (text.items.len > 0 and text.items[text.items.len - 1] == '\t') text.items[text.items.len - 1] = '\n';
                    }
                    continue;
                }
                if (mode == .slides and std.mem.eql(u8, e.name.uri, ns_draw) and std.mem.eql(u8, e.name.local, "page")) {
                    try append(arena, text, max, "\n");
                    continue;
                }
                if (!std.mem.eql(u8, e.name.uri, ns_text)) continue;
                if (std.mem.eql(u8, e.name.local, "p") or std.mem.eql(u8, e.name.local, "h")) {
                    if (in_paragraph > 0) in_paragraph -= 1;
                    // Within a spreadsheet cell, paragraphs run on; the cell ends with a tab.
                    try append(arena, text, max, if (mode == .sheet) " " else "\n");
                }
            },
            .text, .cdata => |t| if (in_paragraph > 0) try append(arena, text, max, t),
            .end_of_document => break,
            else => {},
        }
    }
}

// ---------------------------------------------------------------- xlsx, pptx

fn lessNatural(_: void, x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return x.len < y.len; // slide2 before slide10
    return std.mem.lessThan(u8, x, y);
}

/// Names of the parts `dir/<prefix>N.xml` (directly in `dir`), in number order.
fn numbered(arena: Allocator, archive: *ziparchive.Archive, dir: []const u8, prefix: []const u8, limit: usize) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (archive.entries) |e| {
        if (!std.mem.startsWith(u8, e.name, dir) or !std.mem.endsWith(u8, e.name, ".xml")) continue;
        const rest = e.name[dir.len .. e.name.len - 4];
        if (!std.mem.startsWith(u8, rest, prefix) or rest.len == prefix.len) continue;
        if (std.mem.indexOfNone(u8, rest[prefix.len..], "0123456789") != null) continue;
        if (names.items.len >= limit) break;
        try names.append(arena, e.name);
    }
    std.mem.sort([]const u8, names.items, {}, lessNatural);
    return names.items;
}

/// Spreadsheet text: the strings of each sheet's cells (shared strings are looked up), numbers as written, rows on
/// lines and cells separated by tabs; sheet names first when the workbook lists them in the same number.
fn xlsxBody(arena: Allocator, archive: *ziparchive.Archive, text: *std.ArrayList(u8), max: usize) Error!void {
    var shared: std.ArrayList([]const u8) = .empty;
    if (archive.has("xl/sharedStrings.xml")) {
        const bytes = try readPart(arena, archive, "xl/sharedStrings.xml");
        var src: std.Io.Reader = undefined;
        var rd = xmlReader(arena, bytes, &src);
        defer rd.deinit();
        var cur: std.ArrayList(u8) = .empty;
        var in_t = false;
        var in_phonetic: u32 = 0; // furigana runs are not the cell's text
        while (true) {
            const ev = rd.next() catch return error.Unreadable;
            switch (ev) {
                .start_element => |s| {
                    if (!std.mem.eql(u8, s.name.uri, ns_ss)) continue;
                    if (std.mem.eql(u8, s.name.local, "t")) in_t = true else if (std.mem.eql(u8, s.name.local, "rPh")) in_phonetic += 1 else if (std.mem.eql(u8, s.name.local, "si")) cur = .empty;
                },
                .end_element => |e| {
                    if (!std.mem.eql(u8, e.name.uri, ns_ss)) continue;
                    if (std.mem.eql(u8, e.name.local, "t")) in_t = false else if (std.mem.eql(u8, e.name.local, "rPh")) {
                        if (in_phonetic > 0) in_phonetic -= 1;
                    } else if (std.mem.eql(u8, e.name.local, "si")) {
                        if (shared.items.len >= max_shared_strings) return error.TooLarge;
                        try shared.append(arena, cur.items);
                    }
                },
                .text, .cdata => |t| if (in_t and in_phonetic == 0) {
                    if (cur.items.len + t.len > max) return error.TooLarge;
                    try cur.appendSlice(arena, t);
                },
                .end_of_document => break,
                else => {},
            }
        }
    }
    const sheets = try numbered(arena, archive, "xl/worksheets/", "sheet", max_sheets);
    var names: std.ArrayList([]const u8) = .empty;
    if (archive.has("xl/workbook.xml")) names = sheetNames(arena, archive) catch .empty;
    for (sheets, 0..) |part, i| {
        if (names.items.len == sheets.len) {
            try append(arena, text, max, names.items[i]);
            try append(arena, text, max, "\n");
        }
        try xlsxSheet(arena, archive, part, shared.items, text, max);
    }
}

fn sheetNames(arena: Allocator, archive: *ziparchive.Archive) Error!std.ArrayList([]const u8) {
    const bytes = try readPart(arena, archive, "xl/workbook.xml");
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| if (std.mem.eql(u8, s.name.uri, ns_ss) and std.mem.eql(u8, s.name.local, "sheet")) {
                if (attr(s.attributes, "", "name")) |n| try out.append(arena, try arena.dupe(u8, n));
            },
            .end_of_document => break,
            else => {},
        }
    }
    return out;
}

fn xlsxSheet(arena: Allocator, archive: *ziparchive.Archive, part: []const u8, shared: []const []const u8, text: *std.ArrayList(u8), max: usize) Error!void {
    const bytes = try readPart(arena, archive, part);
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    const Ty = enum { number, shared, text, boolean, skip };
    var ty: Ty = .number;
    var in_v = false;
    var in_t = false; // inline string text
    var value: std.ArrayList(u8) = .empty;
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                if (!std.mem.eql(u8, s.name.uri, ns_ss)) continue;
                if (std.mem.eql(u8, s.name.local, "c")) {
                    value.clearRetainingCapacity();
                    const t = attr(s.attributes, "", "t") orelse "n";
                    ty = if (std.mem.eql(u8, t, "s")) .shared else if (std.mem.eql(u8, t, "str") or std.mem.eql(u8, t, "inlineStr")) .text else if (std.mem.eql(u8, t, "b")) .boolean else if (std.mem.eql(u8, t, "e")) .skip else .number;
                } else if (std.mem.eql(u8, s.name.local, "v")) in_v = true else if (std.mem.eql(u8, s.name.local, "t")) in_t = true;
            },
            .end_element => |e| {
                if (!std.mem.eql(u8, e.name.uri, ns_ss)) continue;
                if (std.mem.eql(u8, e.name.local, "v")) in_v = false else if (std.mem.eql(u8, e.name.local, "t")) in_t = false else if (std.mem.eql(u8, e.name.local, "c")) {
                    const cell: []const u8 = switch (ty) {
                        .shared => blk: {
                            const i = std.fmt.parseInt(usize, std.mem.trim(u8, value.items, " "), 10) catch break :blk "";
                            break :blk if (i < shared.len) shared[i] else "";
                        },
                        .boolean => if (std.mem.eql(u8, std.mem.trim(u8, value.items, " "), "1")) "TRUE" else "FALSE",
                        .skip => "",
                        else => value.items,
                    };
                    if (cell.len > 0) {
                        try append(arena, text, max, cell);
                        try append(arena, text, max, "\t");
                    }
                } else if (std.mem.eql(u8, e.name.local, "row")) {
                    if (text.items.len > 0 and text.items[text.items.len - 1] == '\t') text.items[text.items.len - 1] = '\n';
                }
            },
            .text, .cdata => |t| if (in_v or in_t) {
                if (value.items.len + t.len > max) return error.TooLarge;
                try value.appendSlice(arena, t);
            },
            .end_of_document => break,
            else => {},
        }
    }
}

/// Presentation text: each slide's text in order, paragraphs on lines, then the speaker notes.
fn pptxBody(arena: Allocator, archive: *ziparchive.Archive, text: *std.ArrayList(u8), max: usize) Error!void {
    const slides = try numbered(arena, archive, "ppt/slides/", "slide", max_sheets * 10);
    for (slides) |part| try pptxSlide(arena, archive, part, text, max);
    const notes = try numbered(arena, archive, "ppt/notesSlides/", "notesSlide", max_sheets * 10);
    for (notes) |part| try pptxSlide(arena, archive, part, text, max);
}

fn pptxSlide(arena: Allocator, archive: *ziparchive.Archive, part: []const u8, text: *std.ArrayList(u8), max: usize) Error!void {
    const bytes = try readPart(arena, archive, part);
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var in_t = false;
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| if (std.mem.eql(u8, s.name.uri, ns_a)) {
                if (std.mem.eql(u8, s.name.local, "t")) in_t = true else if (std.mem.eql(u8, s.name.local, "br")) try append(arena, text, max, "\n");
            },
            .end_element => |e| if (std.mem.eql(u8, e.name.uri, ns_a)) {
                if (std.mem.eql(u8, e.name.local, "t")) in_t = false else if (std.mem.eql(u8, e.name.local, "p")) try append(arena, text, max, "\n");
            },
            .text, .cdata => |t| if (in_t) try append(arena, text, max, t),
            .end_of_document => break,
            else => {},
        }
    }
    try append(arena, text, max, "\n");
}

fn readOdtMeta(arena: Allocator, archive: *ziparchive.Archive, out: *Extracted) Error!void {
    const bytes = try readPart(arena, archive, "meta.xml");
    var src: std.Io.Reader = undefined;
    var rd = xmlReader(arena, bytes, &src);
    defer rd.deinit();
    var field: enum { none, title, creator, initial, date, created, subject, description, keyword, generator, user } = .none;
    var user_name: ?[]const u8 = null;
    var initial: ?[]const u8 = null;
    var created: ?[]const u8 = null;
    while (true) {
        const ev = rd.next() catch return error.Unreadable;
        switch (ev) {
            .start_element => |s| {
                field = .none;
                if (s.name.is(ns_dc, "title")) field = .title else if (s.name.is(ns_dc, "creator")) field = .creator else if (s.name.is(ns_meta, "initial-creator")) field = .initial else if (s.name.is(ns_dc, "date")) field = .date else if (s.name.is(ns_meta, "creation-date")) field = .created else if (s.name.is(ns_dc, "subject")) field = .subject else if (s.name.is(ns_dc, "description")) field = .description else if (s.name.is(ns_meta, "keyword")) field = .keyword else if (s.name.is(ns_meta, "generator")) field = .generator else if (s.name.is(ns_meta, "user-defined")) {
                    field = .user;
                    user_name = if (attr(s.attributes, ns_meta, "name")) |n| try arena.dupe(u8, n) else null;
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
                    .initial => initial = try arena.dupe(u8, v),
                    .date => out.date = try arena.dupe(u8, v),
                    .created => created = try arena.dupe(u8, v),
                    .subject => try setOnce(arena, &out.subject, v),
                    .description => try setOnce(arena, &out.description, v),
                    .keyword => try addKeywords(arena, out, v),
                    .generator => try setOnce(arena, &out.application, v),
                    .user => if (user_name) |n| try addCustom(arena, out, n, v),
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

test "spreadsheets: sheet names, cell text and numbers, rows on lines (xlsx and ods made by LibreOffice)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ar: ziparchive.Archive = undefined;
    const file = try openFixture(&tmp, "s.xlsx", @embedFile("testdata/office/sample.xlsx"), &ar, a);
    defer file.close(testing.io);
    const got = try extract(a, &ar, .xlsx, 1 << 20);
    try testing.expectEqualStrings("prices\nitem\tprice\nmjolnir\t42\ngungnir\t77", got.text);
    var ar2: ziparchive.Archive = undefined;
    const file2 = try openFixture(&tmp, "s.ods", @embedFile("testdata/office/sample.ods"), &ar2, a);
    defer file2.close(testing.io);
    const ods = try extract(a, &ar2, .ods, 1 << 20);
    try testing.expect(std.mem.indexOf(u8, ods.text, "item\tprice\nmjolnir\t42\ngungnir\t77") != null);
    try testing.expectError(error.TooLarge, extract(a, &ar2, .ods, 10));
}

test "presentations: slides in order, paragraphs on lines (pptx and odp made by LibreOffice)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ar: ziparchive.Archive = undefined;
    const file = try openFixture(&tmp, "s.pptx", @embedFile("testdata/office/sample.pptx"), &ar, a);
    defer file.close(testing.io);
    const got = try extract(a, &ar, .pptx, 1 << 20);
    const first = std.mem.indexOf(u8, got.text, "narwhals").?;
    const second = std.mem.indexOf(u8, got.text, "platypus").?;
    try testing.expect(first < second);
    try testing.expect(std.mem.indexOf(u8, got.text, "platypus\nand a second paragraph") != null);
    var ar2: ziparchive.Archive = undefined;
    const file2 = try openFixture(&tmp, "s.odp", @embedFile("testdata/office/sample.odp"), &ar2, a);
    defer file2.close(testing.io);
    const odp = try extract(a, &ar2, .odp, 1 << 20);
    try testing.expect(std.mem.indexOf(u8, odp.text, "narwhals").? < std.mem.indexOf(u8, odp.text, "platypus").?);
    try testing.expect(std.mem.indexOf(u8, odp.text, "platypus\nand a second paragraph") != null);
}

test "document properties: subject, keywords, description, category, who, which program, custom fields (docx and odt)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ar: ziparchive.Archive = undefined;
    const file = try openFixture(&tmp, "s.docx", @embedFile("testdata/office/sample.docx"), &ar, a);
    defer file.close(testing.io);
    const got = try extract(a, &ar, .docx, 1 << 20);
    try testing.expectEqualStrings("Tide tables", got.subject.?);
    try testing.expectEqualStrings("Notes on spring tides", got.description.?);
    try testing.expectEqualStrings("Reports", got.category.?);
    try testing.expectEqualStrings("Cy Marsh", got.last_modified_by.?);
    try testing.expectEqualStrings("Imaginary Writer", got.application.?);
    try testing.expectEqualStrings("Harbour Board", got.company.?);
    try testing.expectEqualStrings("Di Park", got.manager.?);
    try testing.expectEqual(@as(usize, 3), got.keywords.len);
    try testing.expectEqualStrings("boats", got.keywords[2]);
    try testing.expectEqual(@as(usize, 2), got.custom.len);
    try testing.expectEqualStrings("Project Code", got.custom[0].name);
    try testing.expectEqualStrings("HB-7", got.custom[0].value);
    try testing.expectEqualStrings("12", got.custom[1].value);

    var extras: std.ArrayList(doc.Extra) = .empty;
    try metadataExtras(a, got, &extras);
    var tags: usize = 0;
    var project: ?[]const u8 = null;
    for (extras.items) |e| {
        if (std.mem.eql(u8, e.key, "tag")) tags += 1;
        if (std.mem.eql(u8, e.key, "project_code")) project = e.value;
    }
    try testing.expectEqual(@as(usize, 3), tags);
    try testing.expectEqualStrings("HB-7", project.?);
    const full = try withMetadataText(a, got);
    try testing.expect(std.mem.startsWith(u8, full, got.text));
    try testing.expect(std.mem.indexOf(u8, full, "Subject: Tide tables\n") != null);
    try testing.expect(std.mem.indexOf(u8, full, "Keywords: harbour, tides, boats\n") != null);

    var ar2: ziparchive.Archive = undefined;
    const file2 = try openFixture(&tmp, "s.odt", @embedFile("testdata/office/sample.odt"), &ar2, a);
    defer file2.close(testing.io);
    const odt = try extract(a, &ar2, .odt, 1 << 20);
    try testing.expectEqualStrings("Lamps", odt.subject.?);
    try testing.expectEqualStrings("How to keep a lantern", odt.description.?);
    try testing.expectEqual(@as(usize, 2), odt.keywords.len);
    try testing.expectEqualStrings("Imaginary Writer/1.0", odt.application.?);
    try testing.expectEqualStrings("LN-3", odt.custom[0].value);
    // A document without properties has none of this and its text is unchanged.
    const plain: Extracted = .{ .text = "just text" };
    try testing.expectEqualStrings("just text", try withMetadataText(a, plain));
}
