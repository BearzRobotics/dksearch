//! The dump connector (docs/decisions/0037): archives and data dumps that the administrator has already got on
//! disk. It never uses the network and executes nothing. One kind, four `format`s:
//!
//!   zip            the text, Markdown and HTML files inside ZIP archives (`.zip`)
//!   warc           the pages of web archives (`.warc`, `.warc.gz`: Common Crawl, Archive Team, wget `--warc-file`)
//!   stackexchange  a Stack Exchange data dump's `Posts.xml`: every question and every answer is a document
//!   reddit         Reddit submissions and comments as JSON lines (`.jsonl`, `.ndjson`, `.json`, `.zst`)
//!
//! `path` is one file or a directory searched for files of the format (sorted, hidden entries and symbolic links
//! skipped). Large files are read as a stream, never whole. The resume position is the last finished file, so a
//! restart repeats the file it was in (unchanged documents are skipped by the pipeline, so that only costs time).
//!
//! Options: path, format (required), language, max_file_bytes (largest text of one document), and per format
//! `site_url` (stackexchange: the site's address, for links), `subreddits`, `min_score`, `include_nsfw` (reddit)
//! and `zstd_window_mb` (reddit `.zst` files; dumps made with `--long` need a window of up to 2048).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");
const files = @import("files.zig");
const htmltext = @import("../htmltext.zig");
const ziparchive = @import("../ziparchive.zig");
const xmlzig = @import("xmlzig");
const dates = @import("feeds/dates.zig");

pub const kind = "dump";
pub const default_max_file_bytes: u32 = 4 * 1024 * 1024;
pub const hard_max_file_bytes: u32 = 64 * 1024 * 1024;
const checkpoint_every = 5;
const allowed_options = [_][]const u8{ "path", "format", "language", "max_file_bytes", "site_url", "subreddits", "min_score", "include_nsfw", "zstd_window_mb" };

pub const Format = enum {
    zip,
    warc,
    stackexchange,
    reddit,

    fn matches(self: Format, path: []const u8) bool {
        return switch (self) {
            .zip => std.ascii.endsWithIgnoreCase(path, ".zip"),
            .warc => std.ascii.endsWithIgnoreCase(path, ".warc") or std.ascii.endsWithIgnoreCase(path, ".warc.gz"),
            .stackexchange => std.mem.eql(u8, std.fs.path.basename(path), "Posts.xml"),
            .reddit => std.ascii.endsWithIgnoreCase(path, ".jsonl") or std.ascii.endsWithIgnoreCase(path, ".ndjson") or std.ascii.endsWithIgnoreCase(path, ".json") or std.ascii.endsWithIgnoreCase(path, ".zst"),
        };
    }
};

pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    for (source.options) |o| {
        var known = false;
        for (allowed_options) |k| {
            if (std.mem.eql(u8, k, o.key)) known = true;
        }
        if (!known) {
            diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].{s}", .{ source.name, o.key }) catch o.key, "unknown option for kind \"dump\"", .{});
            return error.UnknownKey;
        }
    }
    inline for (.{ "path", "format" }) |req| {
        const key = std.fmt.bufPrint(&kbuf, "source[{s}]." ++ req, .{source.name}) catch req;
        switch (source.option(req) orelse {
            diag.set("", key, "is required for kind \"dump\"", .{});
            return error.InvalidValue;
        }) {
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
    if (std.meta.stringToEnum(Format, source.optionString("format").?) == null) {
        diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].format", .{source.name}) catch "format", "must be \"zip\", \"warc\", \"stackexchange\" or \"reddit\"", .{});
        return error.InvalidValue;
    }
    inline for (.{ .{ "max_file_bytes", 1, hard_max_file_bytes }, .{ "zstd_window_mb", 1, 2048 }, .{ "min_score", -1_000_000, 100_000_000 } }) |opt| {
        if (source.option(opt[0])) |v| {
            const key = std.fmt.bufPrint(&kbuf, "source[{s}]." ++ opt[0], .{source.name}) catch opt[0];
            switch (v) {
                .integer => |n| if (n < opt[1] or n > opt[2]) {
                    diag.set("", key, "must be between {d} and {d}, got {d}", .{ opt[1], opt[2], n });
                    return error.InvalidValue;
                },
                else => {
                    diag.set("", key, "expected integer", .{});
                    return error.WrongType;
                },
            }
        }
    }
    if (source.option("include_nsfw")) |v| switch (v) {
        .boolean => {},
        else => {
            diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].include_nsfw", .{source.name}) catch "include_nsfw", "expected true or false", .{});
            return error.WrongType;
        },
    };
    inline for (.{ "language", "site_url", "subreddits" }) |skey| {
        if (source.option(skey)) |v| {
            const key = std.fmt.bufPrint(&kbuf, "source[{s}]." ++ skey, .{source.name}) catch skey;
            switch (v) {
                .string => |t| {
                    if (comptime std.mem.eql(u8, skey, "language")) {
                        if (!files.validLanguageTag(t)) {
                            diag.set("", key, "must be a language tag such as \"en\"", .{});
                            return error.InvalidValue;
                        }
                    } else if (comptime std.mem.eql(u8, skey, "site_url")) {
                        if (!(std.mem.startsWith(u8, t, "https://") or std.mem.startsWith(u8, t, "http://")) or std.mem.indexOfAny(u8, t, " \"'<>") != null) {
                            diag.set("", key, "must be an address such as \"https://cooking.stackexchange.com\"", .{});
                            return error.InvalidValue;
                        }
                    }
                },
                else => {
                    diag.set("", key, "expected string", .{});
                    return error.WrongType;
                },
            }
        }
    }
}

pub const DumpConnector = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    root: []const u8,
    format: Format,
    language: ?[]const u8,
    max_file_bytes: u32,
    site_url: ?[]const u8,
    /// Lower-case subreddit names to keep; empty: all.
    subreddits: []const []const u8,
    min_score: i64,
    include_nsfw: bool,
    zstd_window_mb: u32,
    checkpoint_buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!DumpConnector {
        const name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(name);
        const root = try gpa.dupe(u8, source.optionString("path").?);
        errdefer gpa.free(root);
        const language = if (source.optionString("language")) |l| try gpa.dupe(u8, l) else null;
        errdefer if (language) |l| gpa.free(l);
        const site_url = if (source.optionString("site_url")) |l| try gpa.dupe(u8, std.mem.trimEnd(u8, l, "/")) else null;
        errdefer if (site_url) |l| gpa.free(l);
        var subs: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (subs.items) |s| gpa.free(s);
            subs.deinit(gpa);
        }
        if (source.optionString("subreddits")) |list| {
            var it = std.mem.tokenizeAny(u8, list, ", \t");
            while (it.next()) |s| {
                const t = std.mem.trim(u8, s, "/");
                const t2 = if (std.ascii.startsWithIgnoreCase(t, "r/")) t[2..] else t;
                if (t2.len == 0) continue;
                const low = try gpa.alloc(u8, t2.len);
                for (low, t2) |*d, c| d.* = std.ascii.toLower(c);
                try subs.append(gpa, low);
            }
        }
        return .{
            .gpa = gpa,
            .io = io,
            .name = name,
            .root = root,
            .format = std.meta.stringToEnum(Format, source.optionString("format").?).?,
            .language = language,
            .max_file_bytes = @intCast(source.optionInt("max_file_bytes") orelse default_max_file_bytes),
            .site_url = site_url,
            .subreddits = try subs.toOwnedSlice(gpa),
            .min_score = source.optionInt("min_score") orelse std.math.minInt(i64),
            .include_nsfw = source.optionBool("include_nsfw") orelse false,
            .zstd_window_mb = @intCast(source.optionInt("zstd_window_mb") orelse 128),
        };
    }

    pub fn deinit(self: *DumpConnector) void {
        self.gpa.free(self.name);
        self.gpa.free(self.root);
        if (self.language) |l| self.gpa.free(l);
        if (self.site_url) |l| self.gpa.free(l);
        for (self.subreddits) |s| self.gpa.free(s);
        self.gpa.free(self.subreddits);
        self.checkpoint_buf.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn connector(self: *DumpConnector) api.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run } };
    }

    fn info(_: *anyopaque) api.Info {
        return .{ .kind = kind, .requires_network = false, .resumable = true };
    }

    fn run(ptr: *anyopaque, sink: api.Sink, control: *api.Control, resume_from: ?[]const u8) api.RunError!api.Outcome {
        const self: *DumpConnector = @ptrCast(@alignCast(ptr));
        const io = self.io;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const st = Io.Dir.cwd().statFile(io, self.root, .{}) catch return error.InvalidSource;
        var dir: Io.Dir = undefined;
        var paths: [][]const u8 = undefined;
        if (st.kind == .directory) {
            dir = Io.Dir.cwd().openDir(io, self.root, .{ .iterate = true }) catch return error.InvalidSource;
            paths = self.collect(arena, dir) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SourceFailed,
            };
        } else if (st.kind == .file) {
            dir = Io.Dir.cwd().openDir(io, std.fs.path.dirname(self.root) orelse ".", .{}) catch return error.InvalidSource;
            const one = arena.alloc([]const u8, 1) catch return error.OutOfMemory;
            one[0] = std.fs.path.basename(self.root);
            paths = one;
        } else return error.InvalidSource;
        defer dir.close(io);
        std.mem.sort([]const u8, paths, {}, lessThan);

        var done: ?[]const u8 = null;
        var since: u32 = 0;
        for (paths, 0..) |rel, i| {
            control.setProgress(i, paths.len);
            if (resume_from) |r| if (!std.mem.lessThan(u8, r, rel)) continue;
            if (control.isCancelled()) return self.stopped(done);
            var file_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer file_arena.deinit();
            const result = self.readFile(file_arena.allocator(), dir, rel, sink, control);
            switch (result) {
                .ok => {},
                .bad_file => control.rejectAt(.unreadable, rel),
                .stopped => return self.stopped(done),
                .out_of_memory => return error.OutOfMemory,
            }
            done = rel;
            since += 1;
            if (since >= checkpoint_every) {
                since = 0;
                sink.checkpoint(rel) catch |e| switch (e) {
                    error.Stopped => return self.stopped(done),
                    else => return error.SourceFailed,
                };
            }
        }
        return .{};
    }

    fn stopped(self: *DumpConnector, done: ?[]const u8) api.Outcome {
        const d = done orelse return .{ .interrupted = true };
        self.checkpoint_buf.clearRetainingCapacity();
        self.checkpoint_buf.appendSlice(self.gpa, d) catch return .{ .interrupted = true };
        return .{ .interrupted = true, .checkpoint = self.checkpoint_buf.items };
    }

    fn collect(self: *DumpConnector, arena: Allocator, dir: Io.Dir) ![][]const u8 {
        var walker = try dir.walkSelectively(arena);
        defer walker.deinit();
        var list: std.ArrayList([]const u8) = .empty;
        while (try walker.next(self.io)) |entry| {
            if (entry.basename.len == 0 or entry.basename[0] == '.') continue;
            switch (entry.kind) {
                .directory => try walker.enter(self.io, entry),
                .file => if (self.format.matches(entry.path)) try list.append(arena, try arena.dupe(u8, entry.path)),
                else => {},
            }
        }
        return list.items;
    }

    const FileResult = enum { ok, bad_file, stopped, out_of_memory };

    fn readFile(self: *DumpConnector, arena: Allocator, dir: Io.Dir, rel: []const u8, sink: api.Sink, control: *api.Control) FileResult {
        var ctx: Ctx = .{ .conn = self, .sink = sink, .control = control, .rel = rel, .file_arena = arena };
        const file = dir.openFile(self.io, rel, .{}) catch return .bad_file;
        defer file.close(self.io);
        return switch (self.format) {
            .zip => readZip(&ctx, file),
            .warc => readWarc(&ctx, file),
            .stackexchange => readStackExchange(&ctx, file),
            .reddit => readReddit(&ctx, file),
        };
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// What a format reader needs: where documents go, which file this is, and memory that lives as long as the file.
const Ctx = struct {
    conn: *DumpConnector,
    sink: api.Sink,
    control: *api.Control,
    rel: []const u8,
    file_arena: Allocator,

    /// Submits `d`. False if the run must stop; refusals by the pipeline are its own to count.
    fn submit(self: *Ctx, d: doc.Document) enum { ok, stopped, out_of_memory } {
        self.sink.submit(d) catch |e| switch (e) {
            error.Rejected => return .ok,
            error.Stopped => return .stopped,
            error.OutOfMemory => return .out_of_memory,
        };
        _ = self.control.submitted.fetchAdd(1, .monotonic);
        return .ok;
    }

    fn reject(self: *Ctx, why: api.Reason, what: []const u8) void {
        self.control.rejectAt(why, what); // counts it too
    }

    fn cancelled(self: *Ctx) bool {
        return self.control.isCancelled();
    }
};

fn rightsFor(a: Allocator, what: []const u8) doc.Rights {
    return .{
        .attribution = std.fmt.allocPrint(a, "From {s}", .{what}) catch null,
        .access_notes = "Content belongs to its authors and publishers; check the terms of the source before reuse.",
        .redistribution = .unknown,
    };
}

// ------------------------------------------------------------------------------------------------- zip

fn readZip(ctx: *Ctx, file: Io.File) DumpConnector.FileResult {
    const conn = ctx.conn;
    var archive: ziparchive.Archive = undefined;
    archive.open(ctx.file_arena, conn.io, file) catch |e| return if (e == error.OutOfMemory) .out_of_memory else .bad_file;
    for (archive.entries) |entry| {
        if (ctx.cancelled()) return .stopped;
        const is_html = std.ascii.endsWithIgnoreCase(entry.name, ".html") or std.ascii.endsWithIgnoreCase(entry.name, ".htm");
        const is_md = std.ascii.endsWithIgnoreCase(entry.name, ".md");
        if (!is_html and !is_md and !std.ascii.endsWithIgnoreCase(entry.name, ".txt")) continue;
        if (std.mem.indexOf(u8, entry.name, "__MACOSX/") != null or std.mem.startsWith(u8, std.fs.path.basename(entry.name), ".")) continue;
        var item = std.heap.ArenaAllocator.init(conn.gpa);
        defer item.deinit();
        const a = item.allocator();
        const bytes = archive.read(a, entry.name, conn.max_file_bytes) catch |e| switch (e) {
            error.OutOfMemory => return .out_of_memory,
            else => {
                ctx.reject(.unreadable, entry.name);
                continue;
            },
        };
        if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) {
            ctx.reject(.unreadable, entry.name);
            continue;
        }
        var title: ?[]const u8 = null;
        const text: []const u8 = if (is_html) blk: {
            title = htmltext.titleOf(a, bytes) catch return .out_of_memory;
            break :blk htmltext.toText(a, bytes) catch return .out_of_memory;
        } else bytes;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            ctx.reject(.no_text, entry.name);
            continue;
        }
        const id = std.fmt.allocPrint(a, "{s}!{s}", .{ ctx.rel, entry.name }) catch return .out_of_memory;
        const d: doc.Document = .{
            .connector = conn.name,
            .source_id = id,
            .title = title orelse files.titleOf(text, entry.name, is_md),
            .text = text,
            .language = conn.language,
            .content_type = if (is_html) "text/html" else if (is_md) "text/markdown" else "text/plain",
            .rights = rightsFor(a, ctx.rel),
        };
        switch (ctx.submit(d)) {
            .ok => {},
            .stopped => return .stopped,
            .out_of_memory => return .out_of_memory,
        }
    }
    return .ok;
}

// ------------------------------------------------------------------------------------------------ warc

fn readWarc(ctx: *Ctx, file: Io.File) DumpConnector.FileResult {
    const conn = ctx.conn;
    const io_buf = conn.gpa.alloc(u8, 256 * 1024) catch return .out_of_memory;
    defer conn.gpa.free(io_buf);
    var fr = file.reader(conn.io, io_buf);
    if (!std.ascii.endsWithIgnoreCase(ctx.rel, ".gz")) return warcRecords(ctx, &fr.interface);
    // Web archives are written as one gzip member per record (or a few); each member is read to its end and the
    // next begins right after it.
    const win = conn.gpa.alloc(u8, std.compress.flate.max_window_len) catch return .out_of_memory;
    defer conn.gpa.free(win);
    while (true) {
        _ = fr.interface.peekByte() catch |e| return if (e == error.EndOfStream) .ok else .bad_file;
        var dec = std.compress.flate.Decompress.init(&fr.interface, .gzip, win);
        const r = warcRecords(ctx, &dec.reader);
        if (r != .ok) return r;
    }
}

/// Reads WARC records from `r` until it ends.
fn warcRecords(ctx: *Ctx, r: *Io.Reader) DumpConnector.FileResult {
    const conn = ctx.conn;
    while (true) {
        if (ctx.cancelled()) return .stopped;
        var rec = std.heap.ArenaAllocator.init(conn.gpa);
        defer rec.deinit();
        const a = rec.allocator();
        // The header: "WARC/1.0", then "Name: value" lines up to a blank line.
        var uri: ?[]const u8 = null;
        var wtype: []const u8 = "";
        var date: ?[]const u8 = null;
        var length: ?usize = null;
        var ctype: []const u8 = "";
        var first = true;
        while (true) {
            const line_opt = r.takeDelimiter('\n') catch |e| return if (e == error.StreamTooLong) .bad_file else .bad_file;
            const raw = line_opt orelse return if (first) .ok else .bad_file; // the end, between records
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (first) {
                if (line.len == 0) continue; // blank lines between records
                if (!std.mem.startsWith(u8, line, "WARC/")) return .bad_file;
                first = false;
                continue;
            }
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "WARC-Type")) wtype = a.dupe(u8, value) catch return .out_of_memory;
            if (std.ascii.eqlIgnoreCase(name, "WARC-Target-URI")) uri = a.dupe(u8, std.mem.trim(u8, value, "<>")) catch return .out_of_memory;
            if (std.ascii.eqlIgnoreCase(name, "WARC-Date")) date = a.dupe(u8, value) catch return .out_of_memory;
            if (std.ascii.eqlIgnoreCase(name, "Content-Type")) ctype = a.dupe(u8, value) catch return .out_of_memory;
            if (std.ascii.eqlIgnoreCase(name, "Content-Length")) length = std.fmt.parseInt(usize, value, 10) catch return .bad_file;
        }
        const n = length orelse return .bad_file;
        const want = std.ascii.eqlIgnoreCase(wtype, "response") and std.ascii.startsWithIgnoreCase(ctype, "application/http") and uri != null and n <= conn.max_file_bytes * 4;
        if (!want) {
            r.discardAll64(n) catch return .bad_file;
            continue;
        }
        const block = r.readAllocAll(a, n) catch |e| return if (e == error.OutOfMemory) .out_of_memory else .bad_file;
        switch (warcResponse(ctx, a, uri.?, date, block)) {
            .ok => {},
            .stopped => return .stopped,
            .out_of_memory => return .out_of_memory,
        }
    }
}

const Step = enum { ok, stopped, out_of_memory };

/// One archived HTTP response: an answer of 200 with HTML or plain text becomes a document.
fn warcResponse(ctx: *Ctx, a: Allocator, uri: []const u8, date: ?[]const u8, block: []const u8) Step {
    const conn = ctx.conn;
    const split = std.mem.indexOf(u8, block, "\r\n\r\n") orelse {
        ctx.reject(.http_status, uri);
        return .ok;
    };
    const head = block[0..split];
    var body: []const u8 = block[split + 4 ..];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return .ok;
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts.next();
    const status = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch 0;
    if (status != 200) {
        ctx.reject(.http_status, uri);
        return .ok;
    }
    var media: []const u8 = "";
    var charset_utf8 = true;
    var chunked = false;
    var gzip = false;
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        const name = l[0..colon];
        const value = std.mem.trim(u8, l[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            const semi = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
            media = std.mem.trim(u8, value[0..semi], " ");
            if (std.ascii.findIgnoreCase(value, "charset=") != null and std.ascii.findIgnoreCase(value, "utf-8") == null) charset_utf8 = false;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.findIgnoreCase(value, "chunked") != null) {
            chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "content-encoding")) {
            if (std.ascii.eqlIgnoreCase(value, "gzip") or std.ascii.eqlIgnoreCase(value, "x-gzip")) gzip = true else if (!std.ascii.eqlIgnoreCase(value, "identity")) {
                ctx.reject(.encoding, uri);
                return .ok;
            }
        }
    }
    const is_html = media.len == 0 or std.ascii.eqlIgnoreCase(media, "text/html") or std.ascii.eqlIgnoreCase(media, "application/xhtml+xml");
    if (!is_html and !std.ascii.eqlIgnoreCase(media, "text/plain")) {
        ctx.reject(.wrong_type, uri);
        return .ok;
    }
    if (chunked) body = dechunk(a, body) catch |e| {
        if (e == error.OutOfMemory) return .out_of_memory;
        ctx.reject(.http_status, uri);
        return .ok;
    };
    if (gzip) {
        var src: Io.Reader = .fixed(body);
        const win = a.alloc(u8, std.compress.flate.max_window_len) catch return .out_of_memory;
        var dec = std.compress.flate.Decompress.init(&src, .gzip, win);
        body = dec.reader.allocRemaining(a, .limited(conn.max_file_bytes * 4)) catch {
            ctx.reject(.encoding, uri);
            return .ok;
        };
    }
    if (!charset_utf8 or !std.unicode.utf8ValidateSlice(body)) {
        ctx.reject(.encoding, uri);
        return .ok;
    }
    const text: []const u8 = if (is_html) htmltext.toText(a, body) catch return .out_of_memory else std.mem.trim(u8, body, " \t\r\n");
    if (text.len == 0 or text.len > conn.max_file_bytes) {
        ctx.reject(if (text.len == 0) .no_text else .too_large, uri);
        return .ok;
    }
    const title: ?[]const u8 = if (is_html) (htmltext.titleOf(a, body) catch return .out_of_memory) else null;
    const host_start = if (std.mem.indexOf(u8, uri, "://")) |i| i + 3 else 0;
    const host_end = std.mem.indexOfAnyPos(u8, uri, host_start, "/?#") orelse uri.len;
    const d: doc.Document = .{
        .connector = conn.name,
        .source_id = uri,
        .canonical_url = uri,
        .source_dataset = uri[host_start..host_end],
        .title = title,
        .text = text,
        .language = conn.language,
        .content_type = if (is_html) "text/html" else "text/plain",
        .modified_at = if (date) |dt| dates.parse(dt) else null,
        .rights = rightsFor(a, "a web archive"),
    };
    return switch (ctx.submit(d)) {
        .ok => .ok,
        .stopped => .stopped,
        .out_of_memory => .out_of_memory,
    };
}

/// The body of a chunked transfer (`size\r\n data \r\n ... 0\r\n\r\n`).
fn dechunk(a: Allocator, body: []const u8) error{ OutOfMemory, BadChunk }![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (true) {
        const eol = std.mem.indexOfPos(u8, body, i, "\r\n") orelse return error.BadChunk;
        const size_text = std.mem.trim(u8, body[i..eol], " \t");
        const semi = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
        const size = std.fmt.parseInt(usize, size_text[0..semi], 16) catch return error.BadChunk;
        i = eol + 2;
        if (size == 0) return out.items;
        if (i + size > body.len) return error.BadChunk;
        try out.appendSlice(a, body[i .. i + size]);
        i += size + 2;
        if (i > body.len) return error.BadChunk;
    }
}

// -------------------------------------------------------------------------------------- stack exchange

const max_row_depth = 8;

/// A row of Posts.xml, decoded.
const Post = struct {
    id: u32,
    kind: u8,
    parent: u32,
    accepted: u32,
    score: i64,
    created: ?[]const u8,
    body: []const u8,
    title: []const u8,
    tags: []const u8,
    owner: []const u8,
};

fn attrOf(attrs: anytype, name: []const u8) []const u8 {
    for (attrs) |a| if (std.mem.eql(u8, a.name.qualified, name)) return a.value;
    return "";
}

fn readPost(attrs: anytype) ?Post {
    const id = std.fmt.parseInt(u32, attrOf(attrs, "Id"), 10) catch return null;
    const kind_n = std.fmt.parseInt(u8, attrOf(attrs, "PostTypeId"), 10) catch 0;
    return .{
        .id = id,
        .kind = kind_n,
        .parent = std.fmt.parseInt(u32, attrOf(attrs, "ParentId"), 10) catch 0,
        .accepted = std.fmt.parseInt(u32, attrOf(attrs, "AcceptedAnswerId"), 10) catch 0,
        .score = std.fmt.parseInt(i64, attrOf(attrs, "Score"), 10) catch 0,
        .created = if (attrOf(attrs, "CreationDate").len > 0) attrOf(attrs, "CreationDate") else null,
        .body = attrOf(attrs, "Body"),
        .title = attrOf(attrs, "Title"),
        .tags = attrOf(attrs, "Tags"),
        .owner = attrOf(attrs, "OwnerDisplayName"),
    };
}

fn readStackExchange(ctx: *Ctx, file: Io.File) DumpConnector.FileResult {
    const conn = ctx.conn;
    const buf = conn.gpa.alloc(u8, 256 * 1024) catch return .out_of_memory;
    defer conn.gpa.free(buf);
    // The site is named by the directory the dump was unpacked in (`cooking.stackexchange.com/Posts.xml`).
    const dir_name = if (std.fs.path.dirname(ctx.rel)) |d| std.fs.path.basename(d) else "";
    const site: []const u8 = if (conn.site_url) |s| s else if (std.mem.indexOfScalar(u8, dir_name, '.') != null) std.fmt.allocPrint(ctx.file_arena, "https://{s}", .{dir_name}) catch return .out_of_memory else "";

    // First pass: the title of every question and which answers were accepted, so that an answer can say what it
    // answers (its own row has no title).
    var titles: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    var accepted: std.AutoHashMapUnmanaged(u32, void) = .empty;
    {
        var fr = file.reader(conn.io, buf);
        var rd = xmlzig.Reader.init(conn.gpa, &fr.interface, .{ .namespaces = false, .doctype = .reject, .max_depth = max_row_depth, .max_token_bytes = 64 * 1024 * 1024 }, null);
        defer rd.deinit();
        while (true) {
            if (ctx.cancelled()) return .stopped;
            const ev = rd.next() catch |e| return if (e == error.OutOfMemory) .out_of_memory else .bad_file;
            switch (ev) {
                .start_element => |s| if (std.mem.eql(u8, s.name.qualified, "row")) {
                    const p = readPost(s.attributes) orelse continue;
                    if (p.kind == 1) {
                        const t = ctx.file_arena.dupe(u8, p.title) catch return .out_of_memory;
                        titles.put(ctx.file_arena, p.id, t) catch return .out_of_memory;
                        if (p.accepted != 0) accepted.put(ctx.file_arena, p.accepted, {}) catch return .out_of_memory;
                    }
                },
                .end_of_document => break,
                else => {},
            }
        }
    }
    var fr = file.reader(conn.io, buf);
    var rd = xmlzig.Reader.init(conn.gpa, &fr.interface, .{ .namespaces = false, .doctype = .reject, .max_depth = max_row_depth, .max_token_bytes = 64 * 1024 * 1024 }, null);
    defer rd.deinit();
    while (true) {
        if (ctx.cancelled()) return .stopped;
        const ev = rd.next() catch |e| return if (e == error.OutOfMemory) .out_of_memory else .bad_file;
        switch (ev) {
            .start_element => |s| if (std.mem.eql(u8, s.name.qualified, "row")) {
                const p = readPost(s.attributes) orelse continue;
                if (p.kind != 1 and p.kind != 2) continue;
                if (p.score < conn.min_score) continue;
                var item = std.heap.ArenaAllocator.init(conn.gpa);
                defer item.deinit();
                switch (stackExchangePost(ctx, item.allocator(), p, site, &titles, &accepted)) {
                    .ok => {},
                    .stopped => return .stopped,
                    .out_of_memory => return .out_of_memory,
                }
            },
            .end_of_document => break,
            else => {},
        }
    }
    return .ok;
}

fn stackExchangePost(ctx: *Ctx, a: Allocator, p: Post, site: []const u8, titles: *const std.AutoHashMapUnmanaged(u32, []const u8), accepted: *const std.AutoHashMapUnmanaged(u32, void)) Step {
    const conn = ctx.conn;
    const body = htmltext.toText(a, p.body) catch return .out_of_memory;
    const is_question = p.kind == 1;
    const question_title: []const u8 = if (is_question) p.title else (titles.get(p.parent) orelse "");
    if (std.mem.trim(u8, body, " \t\r\n").len == 0 and question_title.len == 0) return .ok;
    if (body.len > conn.max_file_bytes) {
        ctx.reject(.too_large, question_title);
        return .ok;
    }
    var extras: std.ArrayList(doc.Extra) = .empty;
    // Tags: `<a><b>` in older dumps, `|a|b|` in newer ones.
    var tag_it = std.mem.tokenizeAny(u8, p.tags, "<>|");
    while (tag_it.next()) |t| extras.append(a, .{ .key = "tag", .value = a.dupe(u8, t) catch return .out_of_memory }) catch return .out_of_memory;
    extras.append(a, .{ .key = "score", .value = std.fmt.allocPrint(a, "{d}", .{p.score}) catch return .out_of_memory }) catch return .out_of_memory;
    extras.append(a, .{ .key = "post_type", .value = if (is_question) "question" else "answer" }) catch return .out_of_memory;
    if (!is_question and accepted.contains(p.id)) extras.append(a, .{ .key = "accepted", .value = "yes" }) catch return .out_of_memory;
    const id = std.fmt.allocPrint(a, "{s}{s}{d}", .{ ctx.rel, if (is_question) "#q" else "#a", p.id }) catch return .out_of_memory;
    const title: []const u8 = if (is_question) p.title else std.fmt.allocPrint(a, "Answer: {s}", .{if (question_title.len > 0) question_title else "(question not in this dump)"}) catch return .out_of_memory;
    // For a question, its title is part of what is searched.
    const text: []const u8 = if (is_question and p.title.len > 0) std.fmt.allocPrint(a, "{s}\n\n{s}", .{ p.title, body }) catch return .out_of_memory else body;
    const d: doc.Document = .{
        .connector = conn.name,
        .source_id = id,
        .canonical_url = if (site.len > 0) std.fmt.allocPrint(a, "{s}/{s}/{d}", .{ site, if (is_question) "q" else "a", p.id }) catch return .out_of_memory else null,
        .title = title,
        .text = text,
        .language = conn.language,
        .content_type = "text/html",
        .author = if (p.owner.len > 0) p.owner else null,
        .published_at = if (p.created) |c| dates.parse(c) else null,
        .rights = .{
            .license = "CC-BY-SA-4.0",
            .attribution = std.fmt.allocPrint(a, "Stack Exchange contributors{s}{s}", .{ if (site.len > 0) ", " else "", site }) catch return .out_of_memory,
            .access_notes = "Stack Exchange content is licensed under Creative Commons BY-SA; attribution and the same license are required for reuse.",
            .redistribution = .allowed,
        },
        .extra = extras.items,
    };
    return switch (ctx.submit(d)) {
        .ok => .ok,
        .stopped => .stopped,
        .out_of_memory => .out_of_memory,
    };
}

// ---------------------------------------------------------------------------------------------- reddit

fn readReddit(ctx: *Ctx, file: Io.File) DumpConnector.FileResult {
    const conn = ctx.conn;
    const line_cap: usize = 8 * 1024 * 1024;
    const raw_buf = conn.gpa.alloc(u8, 256 * 1024) catch return .out_of_memory;
    defer conn.gpa.free(raw_buf);
    var fr = file.reader(conn.io, raw_buf);
    var r: *Io.Reader = &fr.interface;
    var zbuf: []u8 = &.{};
    defer if (zbuf.len > 0) conn.gpa.free(zbuf);
    var zdec: std.compress.zstd.Decompress = undefined;
    const line_buf = conn.gpa.alloc(u8, line_cap) catch return .out_of_memory;
    defer conn.gpa.free(line_buf);
    var lines: Io.Reader = undefined;
    if (std.ascii.endsWithIgnoreCase(ctx.rel, ".zst")) {
        const window: u32 = conn.zstd_window_mb * 1024 * 1024;
        zbuf = conn.gpa.alloc(u8, @as(usize, window) + std.compress.zstd.block_size_max) catch return .out_of_memory;
        zdec = std.compress.zstd.Decompress.init(r, zbuf, .{ .window_len = window });
        r = &zdec.reader;
    }
    // Lines are taken through a reader with a buffer as large as the longest line accepted.
    var limited = LineReader{ .src = r, .buf = line_buf };
    _ = &lines;
    var n_lines: u64 = 0;
    while (true) {
        if (n_lines % 256 == 0 and ctx.cancelled()) return .stopped;
        n_lines += 1;
        const line = limited.next() catch |e| switch (e) {
            error.TooLong => continue,
            error.Broken => return .bad_file,
        } orelse return .ok;
        if (line.len < 2) continue;
        var item = std.heap.ArenaAllocator.init(conn.gpa);
        defer item.deinit();
        switch (redditLine(ctx, item.allocator(), line)) {
            .ok => {},
            .stopped => return .stopped,
            .out_of_memory => return .out_of_memory,
        }
    }
}

/// Lines of at most `buf.len` bytes from a reader; a longer line is skipped whole.
const LineReader = struct {
    src: *Io.Reader,
    buf: []u8,

    const Err = error{ TooLong, Broken };

    fn next(self: *LineReader) Err!?[]const u8 {
        var n: usize = 0;
        var too_long = false;
        while (true) {
            const b = self.src.takeByte() catch |e| switch (e) {
                error.EndOfStream => {
                    if (too_long) return error.TooLong;
                    if (n == 0) return null;
                    return self.buf[0..n];
                },
                error.ReadFailed => return error.Broken,
            };
            if (b == '\n') {
                if (too_long) return error.TooLong;
                return self.buf[0..n];
            }
            if (n < self.buf.len) {
                self.buf[n] = b;
                n += 1;
            } else too_long = true;
        }
    }
};

fn jsonString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (obj.get(key) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @as(i64, @intFromFloat(f)) else null,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// One line of a Reddit dump: a submission (has `title`) or a comment (has `body`).
fn redditLine(ctx: *Ctx, a: Allocator, line: []const u8) Step {
    const conn = ctx.conn;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch return .ok; // not JSON: skipped
    const obj = switch (root) {
        .object => |o| o,
        else => return .ok,
    };
    const subreddit = jsonString(obj, "subreddit");
    if (conn.subreddits.len > 0) {
        var keep = false;
        for (conn.subreddits) |s| if (std.ascii.eqlIgnoreCase(s, subreddit)) {
            keep = true;
        };
        if (!keep) return .ok;
    }
    const score = jsonInt(obj, "score") orelse 0;
    if (score < conn.min_score) return .ok;
    if (!conn.include_nsfw) if (obj.get("over_18")) |v| switch (v) {
        .bool => |b| if (b) return .ok,
        else => {},
    };
    const id = jsonString(obj, "id");
    if (id.len == 0 or id.len > 32) return .ok;
    const author = jsonString(obj, "author");
    const is_submission = obj.get("title") != null and obj.get("body") == null;
    const title_raw = jsonString(obj, "title");
    const body_raw = if (is_submission) jsonString(obj, "selftext") else jsonString(obj, "body");
    const removed = std.mem.eql(u8, body_raw, "[removed]") or std.mem.eql(u8, body_raw, "[deleted]");
    const body = if (removed) "" else body_raw;
    if (is_submission) {
        if (title_raw.len == 0) return .ok;
    } else if (body.len == 0) return .ok;
    if (body.len > conn.max_file_bytes) return .ok;
    const url_text = jsonString(obj, "url");
    const text: []const u8 = if (is_submission) blk: {
        if (body.len > 0) break :blk std.fmt.allocPrint(a, "{s}\n\n{s}", .{ title_raw, body }) catch return .out_of_memory;
        if (url_text.len > 0 and (std.mem.startsWith(u8, url_text, "http://") or std.mem.startsWith(u8, url_text, "https://"))) break :blk std.fmt.allocPrint(a, "{s}\n\n{s}", .{ title_raw, url_text }) catch return .out_of_memory;
        break :blk title_raw;
    } else body;
    const title: []const u8 = if (is_submission) title_raw else blk: {
        var end: usize = @min(body.len, 80);
        while (end < body.len and end > 0 and (body[end] & 0xC0) == 0x80) end -= 1;
        break :blk std.fmt.allocPrint(a, "r/{s}: {s}{s}", .{ subreddit, std.mem.trim(u8, body[0..end], " \n\r\t"), if (end < body.len) "…" else "" }) catch return .out_of_memory;
    };
    var extras: std.ArrayList(doc.Extra) = .empty;
    if (subreddit.len > 0 and subreddit.len <= 64) {
        const low = a.alloc(u8, subreddit.len) catch return .out_of_memory;
        for (low, subreddit) |*d, c| d.* = std.ascii.toLower(c);
        extras.append(a, .{ .key = "tag", .value = low }) catch return .out_of_memory;
        extras.append(a, .{ .key = "subreddit", .value = low }) catch return .out_of_memory;
    }
    extras.append(a, .{ .key = "score", .value = std.fmt.allocPrint(a, "{d}", .{score}) catch return .out_of_memory }) catch return .out_of_memory;
    extras.append(a, .{ .key = "post_type", .value = if (is_submission) "submission" else "comment" }) catch return .out_of_memory;
    const permalink = jsonString(obj, "permalink");
    const d: doc.Document = .{
        .connector = conn.name,
        .source_id = std.fmt.allocPrint(a, "{s}_{s}", .{ if (is_submission) "t3" else "t1", id }) catch return .out_of_memory,
        .canonical_url = if (permalink.len > 0 and permalink[0] == '/' and permalink.len < 500) std.fmt.allocPrint(a, "https://www.reddit.com{s}", .{permalink}) catch return .out_of_memory else null,
        .title = title,
        .text = text,
        .language = conn.language,
        .content_type = "text/plain",
        .author = if (author.len > 0 and !std.mem.eql(u8, author, "[deleted]")) author else null,
        .published_at = jsonInt(obj, "created_utc"),
        .rights = .{
            .attribution = "Reddit users",
            .access_notes = "Reddit content belongs to its authors and is subject to Reddit's terms; check them before reuse.",
            .redistribution = .unknown,
        },
        .extra = extras.items,
    };
    return switch (ctx.submit(d)) {
        .ok => .ok,
        .stopped => .stopped,
        .out_of_memory => .out_of_memory,
    };
}

// -------------------------------------------------------------------------------------------------- tests

const testing = std.testing;
const nettest = @import("nettest.zig");
const runner = @import("../runner.zig");
const state_sqlite = @import("../state_sqlite.zig");

fn testSource(path: []const u8, format: []const u8, extra: []const config.Option) !config.Source {
    const opts = try testing.allocator.alloc(config.Option, extra.len + 2);
    opts[0] = .{ .key = "path", .value = .{ .string = path } };
    opts[1] = .{ .key = "format", .value = .{ .string = format } };
    @memcpy(opts[2..], extra);
    return .{ .name = "dumps", .kind = "dump", .options = opts };
}

fn runAll(tmp: *testing.TmpDir, name: []const u8, format: []const u8, extra: []const config.Option, bytes: []const u8) !nettest.Collect {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    var pb: [200]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    const source = try testSource(path, format, extra);
    defer testing.allocator.free(source.options);
    var conn = try DumpConnector.init(testing.allocator, testing.io, source);
    defer conn.deinit();
    var got: nettest.Collect = .{};
    var ctl: api.Control = .{};
    const out = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expect(!out.interrupted);
    return got;
}

fn count(got: *const nettest.Collect, id_part: []const u8) usize {
    var n: usize = 0;
    for (got.ids.items) |i| if (std.mem.indexOf(u8, i, id_part) != null) {
        n += 1;
    };
    return n;
}

test "zip: text, Markdown and HTML files inside the archive, named by archive and entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var got = try runAll(&tmp, "pack.zip", "zip", &.{}, @embedFile("../testdata/dump/sample.zip"));
    defer got.deinit();
    try testing.expectEqual(@as(usize, 3), got.ids.items.len); // the picture is not text
    try testing.expectEqual(@as(usize, 1), count(&got, "pack.zip!notes/harbour.txt"));
    var found_title = false;
    for (got.titles.items, got.texts.items) |t, x| {
        if (std.mem.eql(u8, t, "Gull Page")) {
            found_title = true;
            try testing.expectEqualStrings("Gulls over the rocks", x);
        }
        if (std.mem.indexOf(u8, x, "Trim the wick") != null) try testing.expectEqualStrings("Lantern Guide", t);
    }
    try testing.expect(found_title);
}

test "warc: archived pages with status 200 and text, plain and gzip with several members" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var plain = try runAll(&tmp, "web.warc", "warc", &.{}, @embedFile("../testdata/dump/sample.warc"));
    defer plain.deinit();
    // The harbour page and the chunked text page; the 404 and the request are not documents.
    try testing.expectEqual(@as(usize, 2), plain.ids.items.len);
    try testing.expectEqualStrings("https://example.org/harbour", plain.ids.items[0]);
    try testing.expectEqualStrings("Archived Harbour", plain.titles.items[0]);
    try testing.expectEqualStrings("The ferry leaves at dawn", plain.texts.items[0]);
    try testing.expectEqualStrings("hello chunky", plain.texts.items[1]);
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    var gz = try runAll(&tmp2, "web.warc.gz", "warc", &.{}, @embedFile("../testdata/dump/sample.warc.gz"));
    defer gz.deinit();
    try testing.expectEqual(@as(usize, 2), gz.ids.items.len); // both members were read
    try testing.expectEqualStrings("hello chunky", gz.texts.items[1]);
}

test "stackexchange: questions with tags, answers that name their question, accepted answers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "cooking.stackexchange.com");
    var got = try runAll(&tmp, "cooking.stackexchange.com/Posts.xml", "stackexchange", &.{}, @embedFile("../testdata/dump/Posts.xml"));
    defer got.deinit();
    // Two questions and two answers; the wiki excerpt (type 3) is not a post.
    try testing.expectEqual(@as(usize, 4), got.ids.items.len);
    try testing.expectEqual(@as(usize, 1), count(&got, "#q1"));
    var answers: usize = 0;
    for (got.titles.items) |t| if (std.mem.startsWith(u8, t, "Answer: Keeping a lantern lit")) {
        answers += 1;
    };
    try testing.expectEqual(@as(usize, 2), answers);
    // A minimum score leaves out the spam question.
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    var kept = try runAll(&tmp2, "Posts.xml", "stackexchange", &.{.{ .key = "min_score", .value = .{ .integer = 0 } }}, @embedFile("../testdata/dump/Posts.xml"));
    defer kept.deinit();
    try testing.expectEqual(@as(usize, 3), kept.ids.items.len);
}

test "reddit: submissions and comments, deleted and adult posts left out, filters, plain and zstd" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var got = try runAll(&tmp, "posts.jsonl", "reddit", &.{}, @embedFile("../testdata/dump/sample.jsonl"));
    defer got.deinit();
    // abc, def, jkl, pqr: the removed comment and the adult post are out.
    try testing.expectEqual(@as(usize, 4), got.ids.items.len);
    try testing.expectEqual(@as(usize, 1), count(&got, "t3_abc"));
    try testing.expectEqualStrings("Best oil for a hurricane lamp", got.titles.items[0]);
    try testing.expect(std.mem.startsWith(u8, got.titles.items[1], "r/Lanterns: Lamp oil works fine"));
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    var filtered = try runAll(&tmp2, "posts.jsonl", "reddit", &.{ .{ .key = "subreddits", .value = .{ .string = "r/lanterns" } }, .{ .key = "min_score", .value = .{ .integer = 1 } }, .{ .key = "include_nsfw", .value = .{ .boolean = true } } }, @embedFile("../testdata/dump/sample.jsonl"));
    defer filtered.deinit();
    try testing.expectEqual(@as(usize, 3), filtered.ids.items.len); // abc, def, and the adult post; not the other subreddit
    var tmp3 = testing.tmpDir(.{});
    defer tmp3.cleanup();
    var z = try runAll(&tmp3, "posts.jsonl.zst", "reddit", &.{.{ .key = "zstd_window_mb", .value = .{ .integer = 8 } }}, @embedFile("../testdata/dump/sample.jsonl.zst"));
    defer z.deinit();
    try testing.expectEqual(@as(usize, 4), z.ids.items.len);
}

test "the source is validated" {
    var d: config.Diagnostic = .{};
    const good = try testSource("/x", "warc", &.{});
    defer testing.allocator.free(good.options);
    try validate(good, &d);
    const bad_format = try testSource("/x", "tar", &.{});
    defer testing.allocator.free(bad_format.options);
    try testing.expectError(error.InvalidValue, validate(bad_format, &d));
    const bad_site = try testSource("/x", "stackexchange", &.{.{ .key = "site_url", .value = .{ .string = "ftp://x" } }});
    defer testing.allocator.free(bad_site.options);
    try testing.expectError(error.InvalidValue, validate(bad_site, &d));
    const bad_opt = try testSource("/x", "zip", &.{.{ .key = "nope", .value = .{ .boolean = true } }});
    defer testing.allocator.free(bad_opt.options);
    try testing.expectError(error.UnknownKey, validate(bad_opt, &d));
}
