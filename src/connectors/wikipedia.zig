//! The Wikipedia dump connector (docs/decisions/0007 and 0011).
//!
//! Reads a MediaWiki XML export ("pages-articles" dump) that the
//! administrator has already downloaded, either bzip2-compressed (`.bz2`,
//! including the multistream form Wikipedia publishes) or as plain XML. It
//! never uses the network.
//!
//! Only real articles are indexed: pages in the main namespace that are not
//! redirects and have text. The wikitext is converted to plain text by
//! `wikipedia/wikitext.zig` (modest, "good enough for search").
//!
//! Options:
//!   dump              required: path of the dump (`.bz2` or `.xml`)
//!   language          optional: language tag stored on each document (default "en")
//!   url_base          optional: article URL prefix, ending in "/" (default
//!                     "https://<language>.wikipedia.org/wiki/")
//!   dataset_version   optional: label for the dump, e.g. its date "20260101"
//!   max_article_bytes optional: largest article text accepted, 1 to 67108864
//!                     (default 8388608); larger ones are refused
//!
//! Resuming: after each bzip2 stream (about 100 pages in Wikipedia's dumps)
//! or, for plain XML, every 100 pages, the position is saved as `bz2:OFFSET`
//! (where the next stream starts) or `xml:OFFSET` (just after a page). A
//! resumed run starts there. A single-stream `.bz2` cannot be entered in the
//! middle, so it always starts over (the pipeline skips unchanged pages).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");
const files = @import("files.zig");
const bz2 = @import("wikipedia/bz2.zig");
const xml = @import("../xml.zig");
const wikitext = @import("wikipedia/wikitext.zig");

pub const kind = "wikipedia";
pub const default_max_article_bytes: u32 = 8 * 1024 * 1024;
pub const hard_max_article_bytes: u32 = 64 * 1024 * 1024;
const checkpoint_every_pages = 100;
const read_chunk = 64 * 1024;
const max_depth = 64;
const small_field_cap = 4096;
const allowed_options = [_][]const u8{ "dump", "language", "url_base", "dataset_version", "max_article_bytes" };

pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    for (source.options) |o| {
        var known = false;
        for (allowed_options) |k| {
            if (std.mem.eql(u8, k, o.key)) known = true;
        }
        if (!known) {
            diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].{s}", .{ source.name, o.key }) catch o.key, "unknown option for kind \"wikipedia\"", .{});
            return error.UnknownKey;
        }
    }
    const dump_key = std.fmt.bufPrint(&kbuf, "source[{s}].dump", .{source.name}) catch "dump";
    switch (source.option("dump") orelse {
        diag.set("", dump_key, "is required for kind \"wikipedia\"", .{});
        return error.InvalidValue;
    }) {
        .string => |p| if (p.len == 0) {
            diag.set("", dump_key, "must not be empty", .{});
            return error.InvalidValue;
        },
        else => {
            diag.set("", dump_key, "expected string", .{});
            return error.WrongType;
        },
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
    if (source.option("url_base")) |v| {
        const key = std.fmt.bufPrint(&kbuf, "source[{s}].url_base", .{source.name}) catch "url_base";
        switch (v) {
            .string => |u| if (u.len > 200 or !(std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://")) or u[u.len - 1] != '/' or std.mem.indexOfAny(u8, u, " \t\r\n\x00") != null) {
                diag.set("", key, "must be an http or https URL prefix ending in \"/\" (at most 200 characters)", .{});
                return error.InvalidValue;
            },
            else => {
                diag.set("", key, "expected string", .{});
                return error.WrongType;
            },
        }
    }
    if (source.option("dataset_version")) |v| {
        const key = std.fmt.bufPrint(&kbuf, "source[{s}].dataset_version", .{source.name}) catch "dataset_version";
        switch (v) {
            .string => |l| if (l.len == 0 or l.len > 64) {
                diag.set("", key, "must be 1 to 64 characters", .{});
                return error.InvalidValue;
            },
            else => {
                diag.set("", key, "expected string", .{});
                return error.WrongType;
            },
        }
    }
    if (source.option("max_article_bytes")) |v| {
        const key = std.fmt.bufPrint(&kbuf, "source[{s}].max_article_bytes", .{source.name}) catch "max_article_bytes";
        switch (v) {
            .integer => |n| if (n < 1 or n > hard_max_article_bytes) {
                diag.set("", key, "must be between 1 and {d}, got {d}", .{ hard_max_article_bytes, n });
                return error.InvalidValue;
            },
            else => {
                diag.set("", key, "expected integer", .{});
                return error.WrongType;
            },
        }
    }
}

pub const WikipediaConnector = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    dump: []const u8,
    language: []const u8,
    url_base: []const u8,
    dataset_version: ?[]const u8,
    max_article_bytes: u32,
    /// Backs the checkpoint handed back in an `Outcome`.
    checkpoint_buf: [40]u8 = undefined,
    checkpoint_len: usize = 0,

    pub fn init(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!WikipediaConnector {
        const name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(name);
        const dump = try gpa.dupe(u8, source.optionString("dump").?);
        errdefer gpa.free(dump);
        const language = try gpa.dupe(u8, source.optionString("language") orelse "en");
        errdefer gpa.free(language);
        const url_base = if (source.optionString("url_base")) |u|
            try gpa.dupe(u8, u)
        else
            try std.fmt.allocPrint(gpa, "https://{s}.wikipedia.org/wiki/", .{language});
        errdefer gpa.free(url_base);
        const version = if (source.optionString("dataset_version")) |v| try gpa.dupe(u8, v) else null;
        return .{
            .gpa = gpa,
            .io = io,
            .name = name,
            .dump = dump,
            .language = language,
            .url_base = url_base,
            .dataset_version = version,
            .max_article_bytes = @intCast(source.optionInt("max_article_bytes") orelse default_max_article_bytes),
        };
    }

    pub fn deinit(self: *WikipediaConnector) void {
        self.gpa.free(self.name);
        self.gpa.free(self.dump);
        self.gpa.free(self.language);
        self.gpa.free(self.url_base);
        if (self.dataset_version) |v| self.gpa.free(v);
        self.* = undefined;
    }

    pub fn connector(self: *WikipediaConnector) api.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run } };
    }

    fn info(_: *anyopaque) api.Info {
        return .{ .kind = kind, .requires_network = false, .resumable = true };
    }

    fn setCheckpoint(self: *WikipediaConnector, tag: []const u8, offset: u64) []const u8 {
        const s = std.fmt.bufPrint(&self.checkpoint_buf, "{s}:{d}", .{ tag, offset }) catch unreachable;
        self.checkpoint_len = s.len;
        return s;
    }

    fn lastCheckpoint(self: *const WikipediaConnector) ?[]const u8 {
        return if (self.checkpoint_len == 0) null else self.checkpoint_buf[0..self.checkpoint_len];
    }

    fn run(ptr: *anyopaque, sink: api.Sink, control: *api.Control, resume_from: ?[]const u8) api.RunError!api.Outcome {
        const self: *WikipediaConnector = @ptrCast(@alignCast(ptr));
        self.checkpoint_len = 0;
        const io = self.io;
        const is_bz2 = std.ascii.endsWithIgnoreCase(self.dump, ".bz2");

        var start: u64 = 0;
        if (resume_from) |r| {
            const want = if (is_bz2) "bz2:" else "xml:";
            if (!std.mem.startsWith(u8, r, want)) return error.InvalidSource;
            start = std.fmt.parseInt(u64, r[want.len..], 10) catch return error.InvalidSource;
        }

        const file = Io.Dir.cwd().openFile(io, self.dump, .{}) catch return error.InvalidSource;
        defer file.close(io);
        const size = file.length(io) catch return error.InvalidSource;
        if (start > size) return error.InvalidSource;

        var page_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer page_arena.deinit();
        var h: PageHandler = .{
            .conn = self,
            .sink = sink,
            .control = control,
            .arena = &page_arena,
            .synthetic = if (start > 0) synthetic_root.len else 0,
            .start_offset = start,
            .xml_checkpoints = !is_bz2,
        };
        var parser: xml.Parser(PageHandler) = undefined;
        parser.init(&h) catch return error.OutOfMemory;
        defer parser.deinit();

        // A resumed run begins in the middle of the document: give the
        // parser the root element the real file opened earlier.
        if (start > 0) parser.feed(synthetic_root, false) catch return error.SourceFailed;

        const buf = self.gpa.alloc(u8, read_chunk) catch return error.OutOfMemory;
        defer self.gpa.free(buf);

        var dec: ?bz2.Decoder = null;
        defer if (dec) |*d| d.deinit();
        if (is_bz2) dec = bz2.Decoder.init(self.gpa, io, file, start) catch return error.OutOfMemory;
        var plain_pos: u64 = start;

        while (true) {
            const n: usize = if (dec) |*d| d.read(buf) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SourceFailed, // not bzip2, damaged or cut off
            } else blk: {
                var bufs = [_][]u8{buf};
                const got = file.readPositional(io, &bufs, plain_pos) catch return error.SourceFailed;
                plain_pos += got;
                break :blk got;
            };

            // For bzip2 only the decoder knows the real end: a stream can end
            // without a byte of output, which must not look like end of file.
            const final = if (dec) |*d| d.eof else n == 0;
            parser.feed(buf[0..n], final) catch |e| {
                if (h.fail) |f| return self.finish(f);
                return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    // Malformed XML, a DOCTYPE, or a truncated file.
                    else => error.SourceFailed,
                };
            };
            if (h.fail) |f| return self.finish(f);
            if (final) break;

            // A bzip2 stream just ended between pages: a clean place to resume.
            if (dec) |*d| if (d.takeBoundary()) |off| {
                if (h.depth == 1 and !h.in_page) {
                    const pos = self.setCheckpoint("bz2", off);
                    sink.checkpoint(pos) catch |e| switch (e) {
                        error.Stopped => return self.finish(.stopped),
                        else => return error.SourceFailed,
                    };
                }
            };
        }
        return .{};
    }

    fn finish(self: *WikipediaConnector, f: Fail) api.RunError!api.Outcome {
        return switch (f) {
            .out_of_memory => error.OutOfMemory,
            .too_deep => error.SourceFailed,
            .stopped, .cancelled => .{ .interrupted = true, .checkpoint = self.lastCheckpoint() },
        };
    }
};

const synthetic_root = "<mediawiki>";

const Fail = enum { stopped, cancelled, out_of_memory, too_deep };

const Node = enum { other, page, revision, title, ns, page_id, rev_id, timestamp, text, redirect };

/// The Expat handler: follows the dump's structure and, at the end of each
/// page, converts and submits it.
const PageHandler = struct {
    conn: *WikipediaConnector,
    sink: api.Sink,
    control: *api.Control,
    arena: *std.heap.ArenaAllocator,
    /// Length of the synthetic root fed before the file's own bytes.
    synthetic: usize,
    start_offset: u64,
    xml_checkpoints: bool,

    depth: u32 = 0,
    stack: [max_depth + 1]Node = undefined,
    in_page: bool = false,
    current: ?Node = null,
    fail: ?Fail = null,
    pages_since_checkpoint: u32 = 0,

    // The page being read; strings live in `arena`, reset for each page.
    title: std.ArrayList(u8) = .empty,
    ns: std.ArrayList(u8) = .empty,
    page_id: std.ArrayList(u8) = .empty,
    rev_id: std.ArrayList(u8) = .empty,
    timestamp: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    redirect: bool = false,
    oversized: bool = false,
    broken: bool = false, // a field overflowed or memory ran out

    const P = xml.Parser(PageHandler);

    fn fieldList(self: *PageHandler, n: Node) ?*std.ArrayList(u8) {
        return switch (n) {
            .title => &self.title,
            .ns => &self.ns,
            .page_id => &self.page_id,
            .rev_id => &self.rev_id,
            .timestamp => &self.timestamp,
            .text => &self.text,
            else => null,
        };
    }

    pub fn startElement(self: *PageHandler, p: *P, name: []const u8, _: xml.Attrs) void {
        if (self.fail != null) return;
        self.depth += 1;
        if (self.depth > max_depth) {
            self.abort(p, .too_deep);
            return;
        }
        const parent: Node = if (self.depth >= 2) self.stack[self.depth - 1] else .other;
        var node: Node = .other;
        if (self.depth == 2 and std.mem.eql(u8, name, "page")) {
            node = .page;
            self.beginPage();
        } else if (parent == .page) {
            if (std.mem.eql(u8, name, "title")) node = .title //
            else if (std.mem.eql(u8, name, "ns")) node = .ns //
            else if (std.mem.eql(u8, name, "id")) node = .page_id //
            else if (std.mem.eql(u8, name, "redirect")) {
                node = .redirect;
                self.redirect = true;
            } else if (std.mem.eql(u8, name, "revision")) node = .revision;
        } else if (parent == .revision) {
            if (std.mem.eql(u8, name, "id")) node = .rev_id //
            else if (std.mem.eql(u8, name, "timestamp")) node = .timestamp //
            else if (std.mem.eql(u8, name, "text")) node = .text;
        }
        self.stack[self.depth] = node;
        // Only the last revision's fields are wanted; dumps hold one.
        if (node == .rev_id or node == .timestamp or node == .text) {
            if (self.fieldList(node)) |l| l.clearRetainingCapacity();
        }
        self.current = if (self.fieldList(node) != null) node else null;
    }

    pub fn endElement(self: *PageHandler, p: *P, _: []const u8) void {
        if (self.fail != null) return;
        const node = self.stack[self.depth];
        self.current = null;
        if (node == .page) self.finishPage(p);
        self.depth -= 1;
    }

    pub fn characters(self: *PageHandler, p: *P, bytes: []const u8) void {
        _ = p;
        if (self.fail != null) return;
        const cur = self.current orelse return;
        const list = self.fieldList(cur) orelse return;
        const cap: usize = if (cur == .text) self.conn.max_article_bytes else small_field_cap;
        if (list.items.len + bytes.len > cap) {
            if (cur == .text) self.oversized = true else self.broken = true;
            return;
        }
        list.appendSlice(self.arena.allocator(), bytes) catch {
            self.broken = true;
        };
    }

    fn abort(self: *PageHandler, p: *P, why: Fail) void {
        self.fail = why;
        p.stop();
    }

    fn beginPage(self: *PageHandler) void {
        _ = self.arena.reset(.retain_capacity);
        self.title = .empty;
        self.ns = .empty;
        self.page_id = .empty;
        self.rev_id = .empty;
        self.timestamp = .empty;
        self.text = .empty;
        self.redirect = false;
        self.oversized = false;
        self.broken = false;
        self.in_page = true;
    }

    fn finishPage(self: *PageHandler, p: *P) void {
        self.in_page = false;
        if (self.control.isCancelled()) return self.abort(p, .cancelled);

        if (!std.mem.eql(u8, self.ns.items, "0") or self.redirect) return self.pageDone(p);
        if (self.text.items.len == 0 and !self.oversized and !self.broken) return self.pageDone(p); // deleted text

        const id_ok = self.page_id.items.len > 0 and self.page_id.items.len <= 12 and allDigits(self.page_id.items);
        const title = std.mem.trim(u8, self.title.items, " \t\r\n");
        if (self.broken or self.oversized or !id_ok or title.len == 0 or title.len > 1024) {
            _ = self.control.rejected.fetchAdd(1, .monotonic);
            return self.pageDone(p);
        }

        const a = self.arena.allocator();
        const plain = wikitext.convert(a, self.text.items) catch return self.abort(p, .out_of_memory);
        if (plain.len == 0) return self.pageDone(p);
        const d = self.build(a, title, plain) catch return self.abort(p, .out_of_memory);
        self.sink.submit(d) catch |e| switch (e) {
            error.Rejected => {}, // the pipeline counts and reports it
            error.Stopped => return self.abort(p, .stopped),
            error.OutOfMemory => return self.abort(p, .out_of_memory),
        };
        _ = self.control.submitted.fetchAdd(1, .monotonic);
        self.pageDone(p);
    }

    /// Bookkeeping after every page, including skipped ones.
    fn pageDone(self: *PageHandler, p: *P) void {
        if (!self.xml_checkpoints) return;
        self.pages_since_checkpoint += 1;
        if (self.pages_since_checkpoint < checkpoint_every_pages) return;
        self.pages_since_checkpoint = 0;
        // Plain XML: the position just after this page's closing tag.
        const end: i64 = p.byteIndex() + p.byteCount();
        const file_off: u64 = self.start_offset + @as(u64, @intCast(end)) - self.synthetic;
        const pos = self.conn.setCheckpoint("xml", file_off);
        self.sink.checkpoint(pos) catch |e| switch (e) {
            error.Stopped => self.abort(p, .stopped),
            else => self.abort(p, .stopped),
        };
    }

    fn build(self: *PageHandler, a: Allocator, title: []const u8, plain: []const u8) Allocator.Error!doc.Document {
        const conn = self.conn;
        const enc = try encodeTitle(a, title);
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ conn.url_base, enc });
        const attribution = if (std.mem.endsWith(u8, conn.url_base, "/wiki/"))
            try std.fmt.allocPrint(a, "Wikipedia contributors, \"{s}\". Authors: {s}w/index.php?title={s}&action=history", .{ title, conn.url_base[0 .. conn.url_base.len - "wiki/".len], enc })
        else
            try std.fmt.allocPrint(a, "Wikipedia contributors, \"{s}\". Authors: see the page history of {s}", .{ title, url });
        const rev = std.mem.trim(u8, self.rev_id.items, " \t\r\n");
        return .{
            .connector = conn.name,
            .source_id = self.page_id.items,
            .source_dataset = "Wikipedia",
            .dataset_version = conn.dataset_version,
            .revision = if (rev.len > 0) rev else null,
            .canonical_url = url,
            .title = title,
            .text = plain,
            .language = conn.language,
            .content_type = "text/plain",
            .modified_at = parseTimestamp(std.mem.trim(u8, self.timestamp.items, " \t\r\n")),
            .rights = .{
                .license = "CC-BY-SA-4.0",
                .license_url = "https://creativecommons.org/licenses/by-sa/4.0/",
                .attribution = attribution,
                .access_notes = "CC BY-SA and, for older text, GFDL; see https://en.wikipedia.org/wiki/Wikipedia:Copyrights. Media are not included.",
                .redistribution = .allowed,
            },
        };
    }
};

fn allDigits(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// "Café Société" -> "Caf%C3%A9_Soci%C3%A9t%C3%A9": spaces become underscores,
/// everything but unreserved characters and a few path-safe ones is
/// percent-encoded.
fn encodeTitle(a: Allocator, title: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (title) |b| switch (b) {
        ' ' => try out.append(a, '_'),
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', ':', '(', ')', ',', '!', '*', '\'', ';', '@', '$' => try out.append(a, b),
        else => try out.print(a, "%{X:0>2}", .{b}),
    };
    return out.items;
}

/// "2024-03-05T10:20:30Z" as seconds since the Unix epoch, or null.
fn parseTimestamp(s: []const u8) ?i64 {
    if (s.len != 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const min = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const sec = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or min > 59 or sec > 60) return null;
    // Days from civil (Howard Hinnant's algorithm).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + sec;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const runner = @import("../runner.zig");
const memory = @import("../memory.zig");
const index_sqlite = @import("../index_sqlite.zig");
const pipeline = @import("../pipeline.zig");
const state_sqlite = @import("../state_sqlite.zig");

const fx_xml = @embedFile("testdata/wikipedia/dump.xml");
const fx_bz2 = @embedFile("testdata/wikipedia/dump.xml.bz2");

fn src(opts: []const config.Option) config.Source {
    return .{ .name = "wiki", .kind = "wikipedia", .options = opts };
}

test "validate: dump is required; options are checked" {
    var d: config.Diagnostic = .{};
    const ok = [_]config.Option{.{ .key = "dump", .value = .{ .string = "d.xml.bz2" } }};
    try validate(src(&ok), &d);
    try validate(src(&(ok ++ [_]config.Option{
        .{ .key = "language", .value = .{ .string = "en" } },
        .{ .key = "url_base", .value = .{ .string = "https://en.wikipedia.org/wiki/" } },
        .{ .key = "dataset_version", .value = .{ .string = "20260101" } },
        .{ .key = "max_article_bytes", .value = .{ .integer = 1000 } },
    })), &d);
    try testing.expectError(error.InvalidValue, validate(src(&.{}), &d));
    try testing.expectEqualStrings("source[wiki].dump", d.key());
    try testing.expectError(error.WrongType, validate(src(&.{.{ .key = "dump", .value = .{ .integer = 1 } }}), &d));
    try testing.expectError(error.UnknownKey, validate(src(&(ok ++ [_]config.Option{.{ .key = "path", .value = .{ .string = "x" } }})), &d));
    for ([_][]const u8{ "ftp://x/", "https://x/no-slash", "", "https://x/ y/" }) |bad| {
        try testing.expectError(error.InvalidValue, validate(src(&(ok ++ [_]config.Option{.{ .key = "url_base", .value = .{ .string = bad } }})), &d));
    }
    try testing.expectError(error.InvalidValue, validate(src(&(ok ++ [_]config.Option{.{ .key = "max_article_bytes", .value = .{ .integer = 0 } }})), &d));
}

test "timestamps and title encoding" {
    try testing.expectEqual(@as(?i64, 0), parseTimestamp("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1709634030), parseTimestamp("2024-03-05T10:20:30Z"));
    try testing.expectEqual(@as(?i64, 951782400), parseTimestamp("2000-02-29T00:00:00Z"));
    try testing.expect(parseTimestamp("2024-13-05T10:20:30Z") == null);
    try testing.expect(parseTimestamp("yesterday") == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Caf%C3%A9_Soci%C3%A9t%C3%A9_(Paris)", try encodeTitle(arena.allocator(), "Café Société (Paris)"));
    try testing.expectEqualStrings("A%3FB%23C%25", try encodeTitle(arena.allocator(), "A?B#C%"));
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

/// Writes `data` as `name` in a fresh temp dir and returns a source for it.
fn dumpSource(tmp: *testing.TmpDir, name: []const u8, data: []const u8, buf: []u8, extra: []const config.Option) !config.Source {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    const path = try std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    const opts = try testing.allocator.alloc(config.Option, extra.len + 1);
    opts[0] = .{ .key = "dump", .value = .{ .string = path } };
    @memcpy(opts[1..], extra);
    return .{ .name = "wiki", .kind = "wikipedia", .options = opts };
}

fn importAll(e: *E2e, source: config.Source) !runner.Result {
    var wc = try WikipediaConnector.init(testing.allocator, testing.io, source);
    defer wc.deinit();
    var ctl: api.Control = .{};
    return runner.runImport(e.arena.allocator(), &e.state, &e.pipe, wc.connector(), "wiki", &ctl, E2e.now);
}

fn checkImported(e: *E2e, r: runner.Result) !void {
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    // 101, 104 and 105 are articles; 102 is a redirect and 103 a talk page.
    try testing.expectEqual(@as(u64, 3), r.submitted);
    try testing.expectEqual(@as(u64, 3), try e.idx.count());
    try testing.expectEqual(@as(usize, 1), try e.hits("lighthouse"));
    try testing.expectEqual(@as(usize, 1), try e.hits("rhubarb"));
    try testing.expectEqual(@as(usize, 1), try e.hits("otters"));
    try testing.expectEqual(@as(usize, 0), try e.hits("talkpageword"));
    // Templates, references, tables, files and the references section are gone.
    for ([_][]const u8{ "infoboxdata", "refcitation", "tablecell", "referencesection", "caption" }) |w| {
        try testing.expectEqual(@as(usize, 0), try e.hits(w));
    }
}

test "imports a bzip2 multistream dump" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const source = try dumpSource(&tmp, "dump.xml.bz2", fx_bz2, &pb, &.{});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    try checkImported(&e, try importAll(&e, source));
}

test "imports the same dump as plain XML" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const source = try dumpSource(&tmp, "dump.xml", fx_xml, &pb, &.{});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    try checkImported(&e, try importAll(&e, source));
}

test "document fields: provenance, URL, rights, converted text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const source = try dumpSource(&tmp, "dump.xml.bz2", fx_bz2, &pb, &.{.{ .key = "dataset_version", .value = .{ .string = "20260101" } }});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    _ = try importAll(&e, source);

    const rec = (try e.docs.store().find(doc.idFromSource("wiki", "101"))).?;
    const m = rec.meta;
    try testing.expectEqualStrings("Quartz Lighthouse", m.title.?);
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Quartz_Lighthouse", m.canonical_url.?);
    try testing.expectEqualStrings("Wikipedia", m.source_dataset.?);
    try testing.expectEqualStrings("20260101", m.dataset_version.?);
    try testing.expectEqualStrings("9001", m.revision.?);
    try testing.expectEqualStrings("en", m.language.?);
    try testing.expectEqual(@as(?i64, 1709634030), m.modified_at);
    try testing.expectEqualStrings("CC-BY-SA-4.0", m.rights.license.?);
    try testing.expect(std.mem.indexOf(u8, m.rights.attribution.?, "https://en.wikipedia.org/w/index.php?title=Quartz_Lighthouse&action=history") != null);
    try testing.expectEqual(doc.Redistribution.allowed, m.rights.redistribution);

    const kept = try e.content.store().get(testing.allocator, rec.id);
    defer testing.allocator.free(kept);
    try testing.expect(std.mem.startsWith(u8, kept, "The Quartz Lighthouse is a lighthouse on the coast."));
    try testing.expect(std.mem.indexOf(u8, kept, "built in \u{a0}1850") == null); // &nbsp; became a plain space
    try testing.expect(std.mem.indexOf(u8, kept, "built in  1850") == null);
    try testing.expect(std.mem.indexOf(u8, kept, "built in 1850 \u{2013} the keeper") != null);

    // XML entities and non-ASCII titles.
    const rb = try e.content.store().get(testing.allocator, doc.idFromSource("wiki", "104"));
    defer testing.allocator.free(rb);
    try testing.expectEqualStrings("Rhubarb needs deep soil & patience; x < y > z.", rb);
    const cafe = (try e.docs.store().find(doc.idFromSource("wiki", "105"))).?;
    try testing.expectEqualStrings("https://en.wikipedia.org/wiki/Caf%C3%A9_Soci%C3%A9t%C3%A9_(Paris)", cafe.meta.canonical_url.?);
}

/// Cancels the run after `n` documents reached the pipeline.
const CancelAfter = struct {
    inner: api.Sink,
    control: *api.Control,
    n: u32,
    seen: u32 = 0,
    fn submit(ptr: *anyopaque, d: doc.Document) api.Sink.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.inner.submit(d);
        self.seen += 1;
        if (self.seen == self.n) self.control.cancel();
    }
    fn sink(self: *@This()) api.Sink {
        return .{ .ptr = self, .vtable = &.{ .submit = submit } };
    }
};

test "bzip2: cancel, then resume at the next stream" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const source = try dumpSource(&tmp, "dump.xml.bz2", fx_bz2, &pb, &.{});
    defer testing.allocator.free(source.options);
    var wc = try WikipediaConnector.init(testing.allocator, testing.io, source);
    defer wc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();

    var ctl: api.Control = .{};
    var cs: CancelAfter = .{ .inner = e.pipe.sink(), .control = &ctl, .n = 2 }; // pages 101 and 104
    const out = try wc.connector().run(cs.sink(), &ctl, null);
    try testing.expect(out.interrupted);
    // Streams 1 and 2 were finished; the next run starts at stream 3.
    try testing.expect(std.mem.startsWith(u8, out.checkpoint.?, "bz2:"));
    try testing.expectEqual(@as(u64, 2), try e.idx.count());

    var saved: [40]u8 = undefined;
    const pos = try std.fmt.bufPrint(&saved, "{s}", .{out.checkpoint.?});
    var ctl2: api.Control = .{};
    const rest = try wc.connector().run(e.pipe.sink(), &ctl2, pos);
    try testing.expect(!rest.interrupted);
    try testing.expectEqual(@as(u64, 3), try e.idx.count());
    try testing.expectEqual(@as(u64, 0), e.pipe.stats.unchanged); // resumed, not repeated
    try testing.expectEqual(@as(usize, 1), try e.hits("otters"));
}

test "a position of the wrong kind or beyond the file is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const source = try dumpSource(&tmp, "dump.xml.bz2", fx_bz2, &pb, &.{});
    defer testing.allocator.free(source.options);
    var wc = try WikipediaConnector.init(testing.allocator, testing.io, source);
    defer wc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    try testing.expectError(error.InvalidSource, wc.connector().run(e.pipe.sink(), &ctl, "xml:5"));
    try testing.expectError(error.InvalidSource, wc.connector().run(e.pipe.sink(), &ctl, "bz2:99999999"));
    try testing.expectError(error.InvalidSource, wc.connector().run(e.pipe.sink(), &ctl, "bz2:abc"));
}

test "plain XML: checkpoint after pages and resume from it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Enough pages to cross the checkpoint interval.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, "<mediawiki>\n");
    for (0..250) |i| {
        try big.print(testing.allocator, "<page><title>T{d}</title><ns>0</ns><id>{d}</id><revision><id>{d}</id><timestamp>2024-01-01T00:00:00Z</timestamp><text>Body of page number {d} wordx{d}.</text></revision></page>\n", .{ i, i + 1, i + 5000, i, i });
    }
    try big.appendSlice(testing.allocator, "</mediawiki>\n");
    var pb: [200]u8 = undefined;
    const source = try dumpSource(&tmp, "big.xml", big.items, &pb, &.{});
    defer testing.allocator.free(source.options);
    var wc = try WikipediaConnector.init(testing.allocator, testing.io, source);
    defer wc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();

    var ctl: api.Control = .{};
    var cs: CancelAfter = .{ .inner = e.pipe.sink(), .control = &ctl, .n = 150 };
    const out = try wc.connector().run(cs.sink(), &ctl, null);
    try testing.expect(out.interrupted);
    try testing.expect(std.mem.startsWith(u8, out.checkpoint.?, "xml:"));
    var saved: [40]u8 = undefined;
    const pos = try std.fmt.bufPrint(&saved, "{s}", .{out.checkpoint.?});

    var ctl2: api.Control = .{};
    const rest = try wc.connector().run(e.pipe.sink(), &ctl2, pos);
    try testing.expect(!rest.interrupted);
    try testing.expectEqual(@as(u64, 250), try e.idx.count());
    // Pages between the saved position and where the first run stopped were
    // delivered twice, which duplicate detection makes harmless.
    try testing.expect(e.pipe.stats.unchanged < 100);
    try testing.expectEqual(@as(usize, 1), try e.hits("wordx249"));
}

test "damaged, truncated and hostile dumps fail the job and write nothing wrong" {
    const Case = struct { name: []const u8, data: []const u8 };
    const cases = [_]Case{
        .{ .name = "cut.xml.bz2", .data = fx_bz2[0 .. fx_bz2.len - 20] },
        .{ .name = "garbage.xml.bz2", .data = "this is not bzip2 data at all" },
        .{ .name = "cut.xml", .data = fx_xml[0 .. fx_xml.len / 2] },
        .{ .name = "doctype.xml", .data = "<?xml version=\"1.0\"?><!DOCTYPE mediawiki [<!ENTITY x \"y\">]><mediawiki><page><title>T</title><ns>0</ns><id>1</id><revision><id>2</id><text>&x;</text></revision></page></mediawiki>" },
        .{ .name = "notxml.xml", .data = "plain text, not xml" },
    };
    for (cases) |cs| {
        // A fresh state each time: a failed run saves a resume position.
        var e: E2e = undefined;
        try e.init();
        defer e.deinit();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var pb: [200]u8 = undefined;
        const source = try dumpSource(&tmp, cs.name, cs.data, &pb, &.{});
        defer testing.allocator.free(source.options);
        const r = try importAll(&e, source);
        try testing.expectEqual(state_sqlite.JobState.failed, r.state);
        try testing.expectEqualStrings("SourceFailed", r.failure.?);
        // A refused DOCTYPE means nothing from that document is indexed.
        if (std.mem.eql(u8, cs.name, "doctype.xml")) try testing.expectEqual(@as(u64, 0), try e.idx.count());
    }
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing: config.Source = .{ .name = "wiki", .kind = "wikipedia", .options = &.{.{ .key = "dump", .value = .{ .string = ".zig-cache/tmp/nope.xml" } }} };
    const r = try importAll(&e, missing);
    try testing.expectEqualStrings("InvalidSource", r.failure.?);
}

test "oversized articles are refused, not truncated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const source = try dumpSource(&tmp, "dump.xml", fx_xml, &pb, &.{.{ .key = "max_article_bytes", .value = .{ .integer = 200 } }});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    const r = try importAll(&e, source);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    // Only page 101 is over 200 bytes.
    try testing.expectEqual(@as(u64, 2), r.submitted);
    try testing.expectEqual(@as(u64, 1), r.rejected);
    try testing.expectEqual(@as(usize, 0), try e.hits("lighthouse"));
    try testing.expectEqual(@as(usize, 1), try e.hits("rhubarb"));
}

test "bzip2 decoder: boundaries are reported once per stream" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d.bz2", .data = fx_bz2 });
    const file = try tmp.dir.openFile(testing.io, "d.bz2", .{});
    defer file.close(testing.io);
    var dec = try bz2.Decoder.init(testing.allocator, testing.io, file, 0);
    defer dec.deinit();
    var buf: [100]u8 = undefined; // small, to force many reads per stream
    var total: usize = 0;
    var boundaries: u32 = 0;
    var last: u64 = 0;
    while (true) {
        const n = try dec.read(&buf);
        total += n;
        if (dec.takeBoundary()) |b| {
            boundaries += 1;
            last = b;
        }
        if (dec.eof) break;
    }
    try testing.expectEqual(fx_xml.len, total);
    try testing.expectEqual(@as(u32, 3), boundaries);
    try testing.expectEqual(@as(u64, fx_bz2.len), last);
}

test "bzip2 decoder: a stream ending exactly at the end of the output buffer is not the end of the file" {
    // A real dump failed once, after 112,946 articles, because a stream's
    // last byte fell exactly at the end of the read buffer: the decoder then
    // reported the stream end with no bytes, which looked like end of file.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d.bz2", .data = fx_bz2 });
    const file = try tmp.dir.openFile(testing.io, "d.bz2", .{});
    defer file.close(testing.io);
    var storage: [fx_xml.len + 2]u8 = undefined;
    for (1..storage.len + 1) |size| {
        var dec = try bz2.Decoder.init(testing.allocator, testing.io, file, 0);
        defer dec.deinit();
        var total: usize = 0;
        while (true) {
            const n = try dec.read(storage[0..size]);
            total += n;
            if (dec.eof) break;
        }
        try testing.expectEqual(fx_xml.len, total);
    }
}

test "bzip2 decoder: corrupted and truncated copies of a real file never crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var prng = std.Random.DefaultPrng.init(0xb21b);
    const rnd = prng.random();
    var copy: [fx_bz2.len]u8 = undefined;
    for (0..60) |round| {
        @memcpy(&copy, fx_bz2);
        var len: usize = copy.len;
        if (round % 3 == 0) {
            len = rnd.uintLessThan(usize, copy.len); // truncate
        } else {
            for (0..1 + rnd.uintLessThan(usize, 4)) |_| {
                copy[rnd.uintLessThan(usize, copy.len)] ^= @as(u8, 1) << @as(u3, @intCast(rnd.uintLessThan(u8, 8)));
            }
        }
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "x.bz2", .data = copy[0..len] });
        const file = try tmp.dir.openFile(testing.io, "x.bz2", .{});
        defer file.close(testing.io);
        var dec = try bz2.Decoder.init(testing.allocator, testing.io, file, 0);
        defer dec.deinit();
        var buf: [256]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = dec.read(&buf) catch break; // an error is the expected outcome for damage
            if (dec.eof) break;
            total += n;
            if (total > 100 * fx_xml.len) return error.TestUnexpectedResult; // output stays bounded
        }
    }
}

test "xml parser: random mutations of the fixture fail cleanly or parse" {
    var prng = std.Random.DefaultPrng.init(0x4d71);
    const rnd = prng.random();
    var buf: [fx_xml.len]u8 = undefined;
    for (0..40) |_| {
        @memcpy(&buf, fx_xml);
        for (0..1 + rnd.uintLessThan(usize, 6)) |_| buf[rnd.uintLessThan(usize, buf.len)] = rnd.int(u8);
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var e: E2e = undefined;
        try e.init();
        defer e.deinit();
        var pb: [200]u8 = undefined;
        const source = try dumpSource(&tmp, "m.xml", &buf, &pb, &.{});
        defer testing.allocator.free(source.options);
        const r = try importAll(&e, source);
        // Either it parsed (some pages may be refused) or the job failed; never a crash.
        try testing.expect(r.state == .completed or r.state == .failed);
    }
}
