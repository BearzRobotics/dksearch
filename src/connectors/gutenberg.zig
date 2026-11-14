//! The Project Gutenberg connector (docs/decisions/0007).
//!
//! Reads the catalog CSV that Project Gutenberg publishes for bulk use, and
//! the book text files from a directory the administrator already has (a
//! download or a mirror). It never touches the network: fetching the catalog
//! and the books is a separate, explicit step, and the project's rules ask
//! automated users to use these feeds rather than crawl the website.
//!
//! Per catalog row of type "Text" that has a local file, one document is
//! emitted. The Project Gutenberg license header and footer around the book
//! are not indexed; the license is recorded as rights metadata instead.
//!
//! Options:
//!   catalog         required: path of the catalog CSV (pg_catalog.csv)
//!   books           required: directory holding the book files
//!   language        optional: only books in this language (e.g. "en")
//!   max_file_bytes  optional: largest book accepted, 1 to 67108864 (default 16777216)
//!
//! A book `N` is looked for as `pgN.txt`, `N-0.txt`, `N.txt`, `N.txt.utf8` and
//! `pgN.txt.utf8`, directly in `books` or in a subdirectory `N/` of it.
//! Catalog rows without a local file are skipped; that is normal when only a
//! part of the collection was downloaded. Files that are not valid UTF-8, are
//! too large or contain NUL are refused (counted as rejected), never converted
//! or truncated.
//!
//! The resume position is the number of catalog rows already handled, so a
//! resumed run needs the same catalog file. If the catalog was replaced,
//! delivery may repeat documents; the pipeline's duplicate detection makes
//! that harmless.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");
const csv = @import("../csv.zig");
const files = @import("files.zig");

pub const kind = "gutenberg";
pub const default_max_file_bytes: u32 = 16 * 1024 * 1024;
pub const hard_max_file_bytes: u32 = 64 * 1024 * 1024;
/// The full catalog is about twenty megabytes; this leaves generous room.
const max_catalog_bytes = 512 * 1024 * 1024;
const checkpoint_every = 100;
const allowed_options = [_][]const u8{ "catalog", "books", "language", "max_file_bytes" };

pub const license_url = "https://www.gutenberg.org/policy/license.html";

pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    for (source.options) |o| {
        var known = false;
        for (allowed_options) |k| {
            if (std.mem.eql(u8, k, o.key)) known = true;
        }
        if (!known) {
            diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].{s}", .{ source.name, o.key }) catch o.key, "unknown option for kind \"gutenberg\"", .{});
            return error.UnknownKey;
        }
    }
    for ([_][]const u8{ "catalog", "books" }) |name| {
        const key = std.fmt.bufPrint(&kbuf, "source[{s}].{s}", .{ source.name, name }) catch name;
        const v = source.option(name) orelse {
            diag.set("", key, "is required for kind \"gutenberg\"", .{});
            return error.InvalidValue;
        };
        switch (v) {
            .string => |p| if (p.len == 0) {
                diag.set("", key, "must not be empty", .{});
                return error.InvalidValue;
            },
            else => {
                diag.set("", key, "expected string", .{});
                return error.WrongType;
            },
        }
    }
    if (source.option("max_file_bytes")) |v| {
        const key = std.fmt.bufPrint(&kbuf, "source[{s}].max_file_bytes", .{source.name}) catch "max_file_bytes";
        switch (v) {
            .integer => |n| if (n < 1 or n > hard_max_file_bytes) {
                diag.set("", key, "must be between 1 and {d}, got {d}", .{ hard_max_file_bytes, n });
                return error.InvalidValue;
            },
            else => {
                diag.set("", key, "expected integer", .{});
                return error.WrongType;
            },
        }
    }
    if (source.option("language")) |v| {
        const key = std.fmt.bufPrint(&kbuf, "source[{s}].language", .{source.name}) catch "language";
        switch (v) {
            .string => |l| if (!files.validLanguageTag(l)) {
                diag.set("", key, "must be a language tag such as \"en\" (letters, digits and '-', at most 35 characters)", .{});
                return error.InvalidValue;
            },
            else => {
                diag.set("", key, "expected string", .{});
                return error.WrongType;
            },
        }
    }
}

pub const GutenbergConnector = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    catalog: []const u8,
    books: []const u8,
    language: ?[]const u8,
    max_file_bytes: u32,
    checkpoint_buf: [24]u8 = undefined,

    pub fn init(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!GutenbergConnector {
        const name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(name);
        const catalog = try gpa.dupe(u8, source.optionString("catalog").?);
        errdefer gpa.free(catalog);
        const books = try gpa.dupe(u8, source.optionString("books").?);
        errdefer gpa.free(books);
        const language = if (source.optionString("language")) |l| try gpa.dupe(u8, l) else null;
        return .{
            .gpa = gpa,
            .io = io,
            .name = name,
            .catalog = catalog,
            .books = books,
            .language = language,
            .max_file_bytes = @intCast(source.optionInt("max_file_bytes") orelse default_max_file_bytes),
        };
    }

    pub fn deinit(self: *GutenbergConnector) void {
        self.gpa.free(self.name);
        self.gpa.free(self.catalog);
        self.gpa.free(self.books);
        if (self.language) |l| self.gpa.free(l);
        self.* = undefined;
    }

    pub fn connector(self: *GutenbergConnector) api.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run, .exists = exists } };
    }

    /// A book is gone when none of its candidate files exists any more and
    /// the books directory itself is readable. (Rows that a changed
    /// `language` filter would now skip are not treated as gone.)
    fn exists(ptr: *anyopaque, source_id: []const u8) api.Presence {
        const self: *GutenbergConnector = @ptrCast(@alignCast(ptr));
        if (!validBookId(source_id)) return .unknown;
        const root = Io.Dir.cwd().statFile(self.io, self.books, .{}) catch return .unknown;
        if (root.kind != .directory) return .unknown;
        const names = [_][]const u8{ "pg{s}.txt", "{s}-0.txt", "{s}.txt", "{s}.txt.utf8", "pg{s}.txt.utf8" };
        var buf: [160]u8 = undefined;
        for ([_]bool{ false, true }) |in_subdir| {
            inline for (names) |pattern| {
                const file = std.fmt.bufPrint(buf[0..64], pattern, .{source_id}) catch return .unknown;
                const path = if (in_subdir)
                    std.fmt.bufPrint(buf[64..], "{s}/{s}/{s}", .{ self.books, source_id, file }) catch return .unknown
                else
                    std.fmt.bufPrint(buf[64..], "{s}/{s}", .{ self.books, file }) catch return .unknown;
                const st = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |e| switch (e) {
                    error.FileNotFound, error.NotDir => null,
                    else => return .unknown,
                };
                if (st) |x| if (x.kind == .file) return .present;
            }
        }
        return .gone;
    }

    fn info(_: *anyopaque) api.Info {
        return .{ .kind = kind, .requires_network = false, .resumable = true };
    }

    fn run(ptr: *anyopaque, sink: api.Sink, control: *api.Control, resume_from: ?[]const u8) api.RunError!api.Outcome {
        const self: *GutenbergConnector = @ptrCast(@alignCast(ptr));
        const io = self.io;
        // `whole` holds the catalog for the run; `row_arena` is reset per row.
        var whole_state = std.heap.ArenaAllocator.init(self.gpa);
        defer whole_state.deinit();
        var row_state = std.heap.ArenaAllocator.init(self.gpa);
        defer row_state.deinit();

        const skip_rows: u64 = if (resume_from) |r| std.fmt.parseInt(u64, r, 10) catch return error.InvalidSource else 0;

        var books = Io.Dir.cwd().openDir(io, self.books, .{}) catch return error.InvalidSource;
        defer books.close(io);
        const data = Io.Dir.cwd().readFileAlloc(io, self.catalog, whole_state.allocator(), .limited(max_catalog_bytes)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSource,
        };

        var reader = csv.Reader.init(data, .{});
        const header = (reader.next(row_state.allocator()) catch return error.InvalidSource) orelse return error.InvalidSource;
        const cols = Columns.find(header) orelse return error.InvalidSource;
        // The header slice lives in `row_state`; `Columns` holds only indices.

        var row_no: u64 = 0; // data rows handled so far
        while (true) {
            _ = row_state.reset(.retain_capacity);
            const arena = row_state.allocator();
            const row = (reader.next(arena) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SourceFailed, // a corrupt catalog is loud, not skipped
            }) orelse break;

            if (row_no < skip_rows) {
                row_no += 1;
                continue;
            }
            if (control.isCancelled()) return self.stopped(row_no);

            switch (self.handleRow(arena, io, books, cols, row)) {
                .skip => {},
                .refused => _ = control.rejected.fetchAdd(1, .monotonic),
                .document => |d| {
                    sink.submit(d) catch |e| switch (e) {
                        error.Rejected => {},
                        error.Stopped => return self.stopped(row_no),
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    _ = control.submitted.fetchAdd(1, .monotonic);
                },
                .out_of_memory => return error.OutOfMemory,
            }
            row_no += 1;
            if ((row_no - skip_rows) % checkpoint_every == 0) {
                const pos = std.fmt.bufPrint(&self.checkpoint_buf, "{d}", .{row_no}) catch unreachable;
                sink.checkpoint(pos) catch |e| switch (e) {
                    error.Stopped => return self.stopped(row_no),
                    else => return error.SourceFailed,
                };
            }
        }
        return .{};
    }

    /// `rows_done` rows are fully handled; the next run starts at that row.
    fn stopped(self: *GutenbergConnector, rows_done: u64) api.Outcome {
        const pos = std.fmt.bufPrint(&self.checkpoint_buf, "{d}", .{rows_done}) catch unreachable;
        return .{ .interrupted = true, .checkpoint = pos };
    }

    const Handled = union(enum) {
        skip,
        refused,
        document: doc.Document,
        out_of_memory,
    };

    fn handleRow(self: *GutenbergConnector, arena: Allocator, io: Io, books: Io.Dir, cols: Columns, row: []const []const u8) Handled {
        const id = cols.get(row, cols.id);
        const typ = cols.get(row, cols.typ);
        if (typ.len != 0 and !std.ascii.eqlIgnoreCase(typ, "Text")) return .skip;
        if (!validBookId(id)) return .refused; // also keeps the id safe to use in a path

        const languages = cols.get(row, cols.language);
        if (self.language) |want| if (!hasLanguage(languages, want)) return .skip;

        const raw = (self.findBook(arena, io, books, id) catch |e| switch (e) {
            error.OutOfMemory => return .out_of_memory,
            error.Refused => return .refused,
        }) orelse return .skip; // no local copy of this book

        if (!std.unicode.utf8ValidateSlice(raw) or std.mem.indexOfScalar(u8, raw, 0) != null) return .refused;
        const body = std.mem.trim(u8, stripBoilerplate(raw), " \t\r\n");
        if (body.len == 0) return .refused;

        const built = self.build(arena, id, cols, row, languages, body) catch return .out_of_memory;
        return .{ .document = built };
    }

    fn build(self: *GutenbergConnector, arena: Allocator, id: []const u8, cols: Columns, row: []const []const u8, languages: []const u8, body: []const u8) Allocator.Error!doc.Document {
        var extra: std.ArrayList(doc.Extra) = .empty;
        const pairs = [_]struct { []const u8, []const u8 }{
            .{ "subjects", cols.get(row, cols.subjects) },
            .{ "bookshelves", cols.get(row, cols.bookshelves) },
            .{ "locc", cols.get(row, cols.locc) },
            .{ "pg_issued", cols.get(row, cols.issued) },
        };
        for (pairs) |p| {
            const v = try oneLine(arena, p[1]);
            if (v.len > 0) try extra.append(arena, .{ .key = p[0], .value = v });
        }
        const all_languages = try oneLine(arena, languages);
        if (std.mem.indexOfScalar(u8, all_languages, ';') != null) try extra.append(arena, .{ .key = "languages", .value = all_languages });

        const title = try oneLine(arena, cols.get(row, cols.title));
        const author = try oneLine(arena, cols.get(row, cols.authors));
        const lang = firstLanguage(languages);
        return .{
            .connector = self.name,
            .source_id = id,
            .source_dataset = "Project Gutenberg",
            .canonical_url = try std.fmt.allocPrint(arena, "https://www.gutenberg.org/ebooks/{s}", .{id}),
            .title = if (title.len > 0) title else null,
            .text = body,
            .author = if (author.len > 0) author else null,
            .language = if (lang.len > 0 and files.validLanguageTag(lang)) lang else null,
            .content_type = "text/plain",
            .rights = .{
                .license = "Project Gutenberg License",
                .license_url = license_url,
                .attribution = try std.fmt.allocPrint(arena, "Project Gutenberg eBook #{s}", .{id}),
                .access_notes = "The Project Gutenberg name and trademark are subject to the license; the text of a book may be in the public domain only in some countries.",
                // Conservative until the license terms are modelled (ADR 0007).
                .redistribution = .restricted,
            },
            .extra = extra.items,
        };
    }

    const FindError = error{ OutOfMemory, Refused };

    /// The text of book `id`, null if no candidate file exists.
    fn findBook(self: *GutenbergConnector, arena: Allocator, io: Io, books: Io.Dir, id: []const u8) FindError!?[]const u8 {
        const names = [_][]const u8{ "pg{s}.txt", "{s}-0.txt", "{s}.txt", "{s}.txt.utf8", "pg{s}.txt.utf8" };
        for ([_]bool{ false, true }) |in_subdir| {
            inline for (names) |pattern| {
                const file = try std.fmt.allocPrint(arena, pattern, .{id});
                const path = if (in_subdir) try std.fmt.allocPrint(arena, "{s}/{s}", .{ id, file }) else file;
                if (try self.readCandidate(arena, io, books, path)) |text| return text;
            }
        }
        return null;
    }

    fn readCandidate(self: *GutenbergConnector, arena: Allocator, io: Io, books: Io.Dir, path: []const u8) FindError!?[]const u8 {
        const st = books.statFile(io, path, .{ .follow_symlinks = false }) catch return null; // not there
        if (st.kind != .file) return null; // links and directories are never read
        if (st.size > self.max_file_bytes) return error.Refused;
        const text = books.readFileAlloc(io, path, arena, .limited(self.max_file_bytes + 1)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Refused,
        };
        if (text.len > self.max_file_bytes) return error.Refused;
        return text;
    }
};

const Columns = struct {
    id: ?usize,
    typ: ?usize,
    issued: ?usize,
    title: ?usize,
    language: ?usize,
    authors: ?usize,
    subjects: ?usize,
    locc: ?usize,
    bookshelves: ?usize,

    /// Null if the header lacks the columns the connector cannot work without.
    fn find(header: []const []const u8) ?Columns {
        var c: Columns = .{ .id = null, .typ = null, .issued = null, .title = null, .language = null, .authors = null, .subjects = null, .locc = null, .bookshelves = null };
        for (header, 0..) |h, i| {
            const n = std.mem.trim(u8, h, " \t");
            if (std.ascii.eqlIgnoreCase(n, "Text#")) c.id = i;
            if (std.ascii.eqlIgnoreCase(n, "Type")) c.typ = i;
            if (std.ascii.eqlIgnoreCase(n, "Issued")) c.issued = i;
            if (std.ascii.eqlIgnoreCase(n, "Title")) c.title = i;
            if (std.ascii.eqlIgnoreCase(n, "Language")) c.language = i;
            if (std.ascii.eqlIgnoreCase(n, "Authors")) c.authors = i;
            if (std.ascii.eqlIgnoreCase(n, "Subjects")) c.subjects = i;
            if (std.ascii.eqlIgnoreCase(n, "LoCC")) c.locc = i;
            if (std.ascii.eqlIgnoreCase(n, "Bookshelves")) c.bookshelves = i;
        }
        if (c.id == null or c.title == null) return null;
        return c;
    }

    fn get(_: Columns, row: []const []const u8, col: ?usize) []const u8 {
        const i = col orelse return "";
        if (i >= row.len) return "";
        return std.mem.trim(u8, row[i], " \t");
    }
};

/// Catalog numbers are plain decimal, at most nine digits.
fn validBookId(id: []const u8) bool {
    if (id.len == 0 or id.len > 9) return false;
    for (id) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// The language column is "en" or "en; fr".
fn hasLanguage(languages: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, languages, ';');
    while (it.next()) |l| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l, " \t"), want)) return true;
    }
    return false;
}

fn firstLanguage(languages: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, languages, ';');
    return std.mem.trim(u8, it.first(), " \t");
}

/// Collapses runs of whitespace (catalog titles may contain line breaks) to
/// single spaces.
fn oneLine(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    for (s) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            pending_space = out.items.len > 0;
            continue;
        }
        if (pending_space) try out.append(arena, ' ');
        pending_space = false;
        try out.append(arena, ch);
    }
    return out.items;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn isMarker(line: []const u8, word: []const u8) bool {
    var t = std.mem.trim(u8, line, " \t\r\xEF\xBB\xBF");
    if (!std.mem.startsWith(u8, t, "***")) return false;
    t = std.mem.trimStart(u8, t[3..], " \t");
    return std.ascii.startsWithIgnoreCase(t, word) and containsIgnoreCase(t, "GUTENBERG");
}

/// The book itself: what lies between the "*** START OF ... PROJECT
/// GUTENBERG ..." and "*** END OF ..." lines, which hold the license header
/// and footer. Without a start marker the text begins at the start (very old
/// files have none); without an end marker it runs to the end.
fn stripBoilerplate(text: []const u8) []const u8 {
    var start: usize = 0;
    var found_start = false;
    var pos: usize = 0;
    var end: usize = text.len;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n');
        const line_end = nl orelse text.len;
        const line = text[pos..line_end];
        const next = if (nl) |n| n + 1 else text.len;
        if (!found_start) {
            if (isMarker(line, "START OF")) {
                found_start = true;
                start = next;
            }
        } else if (isMarker(line, "END OF")) {
            end = pos;
            break;
        }
        pos = next;
    }
    return text[start..end];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const runner = @import("../runner.zig");
const memory = @import("../memory.zig");
const index_sqlite = @import("../index_sqlite.zig");
const pipeline = @import("../pipeline.zig");
const state_sqlite = @import("../state_sqlite.zig");

const fx_catalog = @embedFile("testdata/gutenberg/catalog.csv");
const fx_1001 = @embedFile("testdata/gutenberg/pg1001.txt");
const fx_1002 = @embedFile("testdata/gutenberg/1002-0.txt");
const fx_1004 = @embedFile("testdata/gutenberg/1004.txt");
const fx_1006 = @embedFile("testdata/gutenberg/1006.txt.utf8");

fn src(opts: []const config.Option) config.Source {
    return .{ .name = "pg", .kind = "gutenberg", .options = opts };
}

test "validate: both paths are required; options are checked" {
    var d: config.Diagnostic = .{};
    const ok = [_]config.Option{
        .{ .key = "catalog", .value = .{ .string = "c.csv" } },
        .{ .key = "books", .value = .{ .string = "b" } },
    };
    try validate(src(&ok), &d);
    try validate(src(&(ok ++ [_]config.Option{
        .{ .key = "language", .value = .{ .string = "en" } },
        .{ .key = "max_file_bytes", .value = .{ .integer = 100 } },
    })), &d);

    try testing.expectError(error.InvalidValue, validate(src(&.{}), &d));
    try testing.expectEqualStrings("source[pg].catalog", d.key());
    try testing.expectError(error.InvalidValue, validate(src(ok[0..1]), &d));
    try testing.expectEqualStrings("source[pg].books", d.key());
    try testing.expectError(error.WrongType, validate(src(&.{ .{ .key = "catalog", .value = .{ .integer = 1 } }, ok[1] }), &d));
    try testing.expectError(error.UnknownKey, validate(src(&(ok ++ [_]config.Option{.{ .key = "path", .value = .{ .string = "x" } }})), &d));
    try testing.expectError(error.InvalidValue, validate(src(&(ok ++ [_]config.Option{.{ .key = "language", .value = .{ .string = "e n" } }})), &d));
    try testing.expectError(error.InvalidValue, validate(src(&(ok ++ [_]config.Option{.{ .key = "max_file_bytes", .value = .{ .integer = 0 } }})), &d));
}

test "stripBoilerplate keeps only the book" {
    const got = stripBoilerplate("header text\n*** START OF THE PROJECT GUTENBERG EBOOK X ***\nline one\nline two\n*** END OF THE PROJECT GUTENBERG EBOOK X ***\nfooter\n");
    try testing.expectEqualStrings("line one\nline two\n", got);
    // CRLF, no space after the asterisks, lower case, and the old "THIS" wording.
    try testing.expectEqualStrings("body\r\n", stripBoilerplate("***START OF THIS PROJECT GUTENBERG EBOOK X***\r\nbody\r\n*** end of this project gutenberg ebook x ***\r\nfooter"));
    // No end marker: to the end. No start marker: from the start.
    try testing.expectEqualStrings("tail\n", stripBoilerplate("*** START OF THE PROJECT GUTENBERG EBOOK X ***\ntail\n"));
    try testing.expectEqualStrings("whole text\n", stripBoilerplate("whole text\n"));
    // A footer marker before any start marker does not truncate the text.
    try testing.expectEqualStrings("a\n*** END OF THE PROJECT GUTENBERG EBOOK X ***\nb\n", stripBoilerplate("a\n*** END OF THE PROJECT GUTENBERG EBOOK X ***\nb\n"));
    // Other asterisk lines are not markers.
    try testing.expectEqualStrings("*** START OF CHAPTER ***\n", stripBoilerplate("*** START OF CHAPTER ***\n"));
}

test "small helpers" {
    try testing.expect(validBookId("1342"));
    try testing.expect(!validBookId(""));
    try testing.expect(!validBookId("12a"));
    try testing.expect(!validBookId("../1"));
    try testing.expect(!validBookId("1234567890"));
    try testing.expect(hasLanguage("en; fr", "fr"));
    try testing.expect(hasLanguage("EN", "en"));
    try testing.expect(!hasLanguage("en; fr", "f"));
    try testing.expectEqualStrings("en", firstLanguage("en; fr"));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("A Title, a Comma and Break", try oneLine(arena.allocator(), "  A Title, a Comma\r\nand   Break \n"));
}

const E2e = struct {
    state: state_sqlite.SqliteStateStore,
    content: memory.MemoryContentStore,
    docs: memory.MemoryDocumentStore,
    idx: index_sqlite.SqliteIndex,
    pipe: pipeline.Pipeline,
    arena: std.heap.ArenaAllocator,

    fn init(e: *E2e) !void {
        e.state = try state_sqlite.SqliteStateStore.open(testing.allocator, ":memory:", true);
        e.content = .init(testing.allocator);
        e.docs = .init(testing.allocator);
        e.idx = try index_sqlite.SqliteIndex.open(":memory:", .{});
        e.pipe = .init(e.content.store(), e.docs.store(), e.idx.indexer(), .{ .now = now });
        e.arena = .init(testing.allocator);
    }
    fn deinit(e: *E2e) void {
        e.arena.deinit();
        e.idx.close();
        e.docs.deinit();
        e.content.deinit();
        e.state.close();
    }
    fn now() doc.Timestamp {
        return 5;
    }
    fn hits(e: *E2e, q: []const u8) !usize {
        return (try e.idx.searcher().search(e.arena.allocator(), .{ .text = q })).hits.len;
    }
};

/// Lays out the fixture: books under several naming schemes, a Latin-1 file
/// (1007), and no file at all for 1005.
fn makeCollection(tmp: *testing.TmpDir) !void {
    const io = testing.io;
    const d = tmp.dir;
    try d.writeFile(io, .{ .sub_path = "catalog.csv", .data = fx_catalog });
    try d.createDirPath(io, "books/1002");
    try d.writeFile(io, .{ .sub_path = "books/pg1001.txt", .data = fx_1001 });
    try d.writeFile(io, .{ .sub_path = "books/1002/1002-0.txt", .data = fx_1002 }); // in a subdirectory
    try d.writeFile(io, .{ .sub_path = "books/1004.txt", .data = fx_1004 });
    try d.writeFile(io, .{ .sub_path = "books/1006.txt.utf8", .data = fx_1006 });
    try d.writeFile(io, .{ .sub_path = "books/1007.txt", .data = "caf\xe9 in Latin-1" });
}

fn collectionSource(tmp: *testing.TmpDir, buf: []u8, extra: []const config.Option) !config.Source {
    const catalog = try std.fmt.bufPrint(buf[0..100], ".zig-cache/tmp/{s}/catalog.csv", .{tmp.sub_path});
    const books = try std.fmt.bufPrint(buf[100..], ".zig-cache/tmp/{s}/books", .{tmp.sub_path});
    const opts = try testing.allocator.alloc(config.Option, extra.len + 2);
    opts[0] = .{ .key = "catalog", .value = .{ .string = catalog } };
    opts[1] = .{ .key = "books", .value = .{ .string = books } };
    @memcpy(opts[2..], extra);
    return .{ .name = "pg", .kind = "gutenberg", .options = opts };
}

test "imports the fixture collection: what is indexed, skipped and refused" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeCollection(&tmp);
    var pb: [300]u8 = undefined;
    const source = try collectionSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var gc = try GutenbergConnector.init(testing.allocator, testing.io, source);
    defer gc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};

    const r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, gc.connector(), "pg", &ctl, E2e.now);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    // 1001, 1002, 1004, 1006 are indexed. 1003 is not text, 1005 has no file
    // (both skipped silently). 1007 is not UTF-8 and "abc" is not a number
    // (both refused).
    try testing.expectEqual(@as(u64, 4), r.submitted);
    try testing.expectEqual(@as(u64, 2), r.rejected);
    try testing.expectEqual(@as(u64, 4), try e.idx.count());

    try testing.expectEqual(@as(usize, 1), try e.hits("cormorants"));
    try testing.expectEqual(@as(usize, 1), try e.hits("rhubarb"));
    try testing.expectEqual(@as(usize, 1), try e.hits("tulipes"));
    try testing.expectEqual(@as(usize, 1), try e.hits("aqueducts"));
    // The title is searchable too, including one that spans lines in the CSV.
    try testing.expectEqual(@as(usize, 1), try e.hits("lighthouse"));
    try testing.expectEqual(@as(usize, 1), try e.hits("quotes"));
    // License header and footer text is not indexed.
    try testing.expectEqual(@as(usize, 0), try e.hits("licenseboilerplate"));
    try testing.expectEqual(@as(usize, 0), try e.hits("replace")); // from the footer
}

test "document fields: provenance, metadata, rights" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeCollection(&tmp);
    var pb: [300]u8 = undefined;
    const source = try collectionSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var gc = try GutenbergConnector.init(testing.allocator, testing.io, source);
    defer gc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, gc.connector(), "pg", &ctl, E2e.now);

    const rec1 = (try e.docs.store().find(doc.idFromSource("pg", "1001"))).?;
    const m = rec1.meta;
    try testing.expectEqualStrings("The Lighthouse Keeper's Almanac", m.title.?);
    try testing.expectEqualStrings("Example, Alice, 1801-1870", m.author.?);
    try testing.expectEqualStrings("en", m.language.?);
    try testing.expectEqualStrings("https://www.gutenberg.org/ebooks/1001", m.canonical_url.?);
    try testing.expectEqualStrings("Project Gutenberg", m.source_dataset.?);
    try testing.expectEqualStrings("Project Gutenberg License", m.rights.license.?);
    try testing.expectEqualStrings(license_url, m.rights.license_url.?);
    try testing.expectEqualStrings("Project Gutenberg eBook #1001", m.rights.attribution.?);
    try testing.expectEqual(doc.Redistribution.restricted, m.rights.redistribution);
    var subjects: ?[]const u8 = null;
    for (m.extra) |x| if (std.mem.eql(u8, x.key, "subjects")) {
        subjects = x.value;
    };
    try testing.expectEqualStrings("Lighthouses -- Fiction; Sea stories", subjects.?);

    // The multi-line, multi-language row: title on one line, first language
    // as the language, all languages kept.
    const rec2 = (try e.docs.store().find(doc.idFromSource("pg", "1002"))).?;
    try testing.expectEqualStrings("A Title with \"Quotes\", a Comma and a Line Break", rec2.meta.title.?);
    try testing.expectEqualStrings("en", rec2.meta.language.?);
    var langs: ?[]const u8 = null;
    for (rec2.meta.extra) |x| if (std.mem.eql(u8, x.key, "languages")) {
        langs = x.value;
    };
    try testing.expectEqualStrings("en; fr", langs.?);

    // The retained text is the book only.
    const kept = try e.content.store().get(testing.allocator, rec1.id);
    defer testing.allocator.free(kept);
    try testing.expect(std.mem.startsWith(u8, kept, "CHAPTER I"));
    try testing.expect(std.mem.indexOf(u8, kept, "END OF THE PROJECT") == null);
}

test "language option keeps only matching books" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeCollection(&tmp);
    var pb: [300]u8 = undefined;
    const source = try collectionSource(&tmp, &pb, &.{.{ .key = "language", .value = .{ .string = "fr" } }});
    defer testing.allocator.free(source.options);
    var gc = try GutenbergConnector.init(testing.allocator, testing.io, source);
    defer gc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    const r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, gc.connector(), "pg", &ctl, E2e.now);
    // 1002 lists "en; fr" and 1004 is "fr".
    try testing.expectEqual(@as(u64, 2), r.submitted);
    try testing.expectEqual(@as(usize, 1), try e.hits("tulipes"));
    try testing.expectEqual(@as(usize, 0), try e.hits("cormorants"));
}

test "symbolic links in the books directory are not read" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try outside.dir.writeFile(testing.io, .{ .sub_path = "secret.txt", .data = "linkedsecret" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "catalog.csv", .data = "Text#,Type,Title\n1001,Text,Linked\n" });
    try tmp.dir.createDirPath(testing.io, "books");
    var tb: [300]u8 = undefined;
    const target = try std.fmt.bufPrint(&tb, "../../{s}/secret.txt", .{outside.sub_path});
    tmp.dir.symLink(testing.io, target, "books/pg1001.txt", .{}) catch return error.SkipZigTest;

    var pb: [300]u8 = undefined;
    const source = try collectionSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var gc = try GutenbergConnector.init(testing.allocator, testing.io, source);
    defer gc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    const r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, gc.connector(), "pg", &ctl, E2e.now);
    try testing.expectEqual(@as(u64, 0), r.submitted);
    try testing.expectEqual(@as(usize, 0), try e.hits("linkedsecret"));
}

test "oversized books are refused, not truncated" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeCollection(&tmp);
    var pb: [300]u8 = undefined;
    const source = try collectionSource(&tmp, &pb, &.{.{ .key = "max_file_bytes", .value = .{ .integer = 200 } }});
    defer testing.allocator.free(source.options);
    var gc = try GutenbergConnector.init(testing.allocator, testing.io, source);
    defer gc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    const r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, gc.connector(), "pg", &ctl, E2e.now);
    // pg1001.txt is over 200 bytes; the others are small.
    try testing.expectEqual(@as(usize, 0), try e.hits("cormorants"));
    try testing.expect(r.rejected >= 1);
    try testing.expectEqual(@as(usize, 1), try e.hits("rhubarb"));
}

test "a bad catalog fails the job; a missing one too" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "books");
    var pb: [300]u8 = undefined;
    const source = try collectionSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var gc = try GutenbergConnector.init(testing.allocator, testing.io, source);
    defer gc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();

    var ctl: api.Control = .{};
    var r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, gc.connector(), "pg", &ctl, E2e.now);
    try testing.expectEqual(state_sqlite.JobState.failed, r.state); // no catalog file
    try testing.expectEqualStrings("InvalidSource", r.failure.?);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "catalog.csv", .data = "Name,Other\nx,y\n" });
    r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, gc.connector(), "pg", &ctl, E2e.now);
    try testing.expectEqualStrings("InvalidSource", r.failure.?); // no Text# / Title columns

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "catalog.csv", .data = "Text#,Title\n1,\"never closed\n" });
    r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, gc.connector(), "pg", &ctl, E2e.now);
    try testing.expectEqualStrings("SourceFailed", r.failure.?); // malformed row
}

test "cancel mid-run, then resume at the next catalog row" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "books");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "catalog.csv", .data = "Text#,Type,Title,Language\n1,Text,One,en\n2,Text,Two,en\n3,Text,Three,en\n4,Text,Four,en\n" });
    for ([_][]const u8{ "1", "2", "3", "4" }) |n| {
        var nb: [40]u8 = undefined;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&nb, "books/{s}.txt", .{n}), .data = "text of book" });
    }
    var pb: [300]u8 = undefined;
    const source = try collectionSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var gc = try GutenbergConnector.init(testing.allocator, testing.io, source);
    defer gc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();

    const Cancelling = struct {
        inner: api.Sink,
        control: *api.Control,
        n: u32 = 0,
        fn submit(ptr: *anyopaque, d: doc.Document) api.Sink.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try self.inner.submit(d);
            self.n += 1;
            if (self.n == 2) self.control.cancel();
        }
        fn sink(self: *@This()) api.Sink {
            return .{ .ptr = self, .vtable = &.{ .submit = submit } };
        }
    };
    var ctl: api.Control = .{};
    var cs: Cancelling = .{ .inner = e.pipe.sink(), .control = &ctl };
    const out = try gc.connector().run(cs.sink(), &ctl, null);
    try testing.expect(out.interrupted);
    try testing.expectEqualStrings("2", out.checkpoint.?);
    try testing.expectEqual(@as(u64, 2), try e.idx.count());

    var ctl2: api.Control = .{};
    const rest = try gc.connector().run(e.pipe.sink(), &ctl2, out.checkpoint);
    try testing.expect(!rest.interrupted);
    try testing.expectEqual(@as(u64, 4), try e.idx.count());
    try testing.expectEqual(@as(u64, 0), e.pipe.stats.unchanged);

    var ctl3: api.Control = .{};
    try testing.expectError(error.InvalidSource, gc.connector().run(e.pipe.sink(), &ctl3, "not a number"));
}

test "prune removes books whose files were deleted, not books still present" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeCollection(&tmp);
    var pb: [300]u8 = undefined;
    const source = try collectionSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var gc = try GutenbergConnector.init(testing.allocator, testing.io, source);
    defer gc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, gc.connector(), "pg", &ctl, E2e.now);
    try testing.expectEqual(@as(u64, 4), try e.idx.count());

    try tmp.dir.deleteFile(testing.io, "books/1004.txt");
    try tmp.dir.deleteTree(testing.io, "books/1002"); // the subdirectory layout
    var ctl2: api.Control = .{};
    const r = try runner.pruneSource(e.arena.allocator(), &e.pipe, gc.connector(), "pg", &ctl2);
    try testing.expectEqual(@as(u64, 2), r.removed);
    try testing.expectEqual(@as(usize, 0), try e.hits("tulipes"));
    try testing.expectEqual(@as(usize, 1), try e.hits("cormorants"));
    try testing.expectEqual(@as(usize, 1), try e.hits("aqueducts"));
}
