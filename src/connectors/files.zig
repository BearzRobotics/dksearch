//! The local-files connector: indexes plain-text (`.txt`) and Markdown
//! (`.md`) files under a directory the administrator names. It reads only
//! from the local filesystem and works fully offline.
//!
//! Safe by default, because file trees are untrusted input:
//!   * symbolic links are never followed (neither files nor directories);
//!   * hidden files and directories (names starting with ".") are skipped, so
//!     ".git" and similar are never walked;
//!   * files over `max_file_bytes`, not valid UTF-8, or containing NUL are
//!     refused, not truncated;
//!   * nothing is executed.
//!
//! Files are processed in sorted path order, so the last finished path is a
//! complete resume position.
//!
//! Options (all under the source's table in the configuration):
//!   path            required: the directory to index
//!   max_file_bytes  optional: largest file accepted, 1 to 67108864 (default 4194304)
//!   language        optional: language tag stored on every document, e.g. "en"

const std = @import("std");
const retrieve = @import("../retrieve.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");
const avmeta = @import("../avmeta.zig");
const htmltext = @import("../htmltext.zig");
const officetext = @import("../officetext.zig");
const ziparchive = @import("../ziparchive.zig");

pub const kind = "files";
pub const default_max_file_bytes: u32 = 4 * 1024 * 1024;
pub const hard_max_file_bytes: u32 = 64 * 1024 * 1024;
const checkpoint_every = 100;
const allowed_options = [_][]const u8{ "path", "max_file_bytes", "language", "serve_originals", "pdf_text", "pdf_workers", "max_pdf_bytes", "pdf_timeout_seconds", "media", "office", "html" };

/// Checks a source's options without touching the filesystem.
pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    for (source.options) |o| {
        var known = false;
        for (allowed_options) |k| {
            if (std.mem.eql(u8, k, o.key)) known = true;
        }
        if (!known) {
            diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].{s}", .{ source.name, o.key }) catch o.key, "unknown option for kind \"files\"", .{});
            return error.UnknownKey;
        }
    }
    const path_key = std.fmt.bufPrint(&kbuf, "source[{s}].path", .{source.name}) catch "path";
    const path_value = source.option("path") orelse {
        diag.set("", path_key, "is required for kind \"files\"", .{});
        return error.InvalidValue;
    };
    switch (path_value) {
        .string => |p| if (p.len == 0) {
            diag.set("", path_key, "must not be empty", .{});
            return error.InvalidValue;
        },
        else => {
            diag.set("", path_key, "expected string", .{});
            return error.WrongType;
        },
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
    inline for (.{ "serve_originals", "pdf_text", "media", "office", "html" }) |bool_key| {
        if (source.option(bool_key)) |v| switch (v) {
            .boolean => {},
            else => {
                diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}]." ++ bool_key, .{source.name}) catch bool_key, "expected true or false", .{});
                return error.WrongType;
            },
        };
    }
    inline for (.{ .{ "max_pdf_bytes", 1, max_pdf_file_bytes }, .{ "pdf_timeout_seconds", 1, 3600 } }) |opt| {
        if (source.option(opt[0])) |v| {
            const key = std.fmt.bufPrint(&kbuf, "source[{s}]." ++ opt[0], .{source.name}) catch opt[0];
            switch (v) {
                .integer => |n| if (n < opt[1] or n > opt[2]) {
                    diag.set("", key, "must be between {d} and {d}, got {d}", .{ @as(i64, opt[1]), @as(i64, opt[2]), n });
                    return error.InvalidValue;
                },
                else => {
                    diag.set("", key, "expected integer", .{});
                    return error.WrongType;
                },
            }
        }
    }
    if (source.option("pdf_workers")) |v| {
        const key = std.fmt.bufPrint(&kbuf, "source[{s}].pdf_workers", .{source.name}) catch "pdf_workers";
        switch (v) {
            .integer => |n| if (n < 1 or n > max_pdf_workers) {
                diag.set("", key, "must be between 1 and {d}, got {d}", .{ max_pdf_workers, n });
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
            .string => |l| if (!validLanguageTag(l)) {
                diag.set("", key, "must be a language tag such as \"en\" or \"pt-BR\" (letters, digits and '-', at most 35 characters)", .{});
                return error.InvalidValue;
            },
            else => {
                diag.set("", key, "expected string", .{});
                return error.WrongType;
            },
        }
    }
}

pub fn validLanguageTag(l: []const u8) bool {
    if (l.len == 0 or l.len > 35) return false;
    for (l) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    return true;
}

pub const FilesConnector = struct {
    gpa: Allocator,
    io: Io,
    /// The source's name: becomes `Document.connector`, so two sources never
    /// share document ids even if they contain the same relative paths.
    name: []const u8,
    root: []const u8,
    max_file_bytes: u32,
    language: ?[]const u8,
    /// Index PDFs by running the external `pdftotext` program (`pdf_text = true`).
    pdf_text: bool,
    /// How many `pdftotext` programs run at once (`pdf_workers`).
    pdf_workers: u32,
    /// Largest PDF file accepted, and the time `pdftotext` is given for one (`max_pdf_bytes`, `pdf_timeout_seconds`).
    max_pdf_bytes: u64,
    pdf_timeout_s: u32,
    /// Text that was extracted ahead of time by the workers, by path (consumed in order).
    pdf_cache: std.StringHashMapUnmanaged(PdfResult) = .empty,
    /// Index audio and video through `ffprobe` and their subtitle or lyrics files (`media = true`).
    media: bool,
    /// Index Word (`docx`), OpenDocument text (`odt`) and `epub` files (`office = true`).
    office: bool,
    /// Index `.html` and `.htm` files as web pages (`html = true`).
    html: bool,
    /// Subtitle and lyrics files of this run, found next to their media (set by `run`).
    sidecars: SidecarMap = .empty,
    /// Backs the checkpoint handed back in an `Outcome`.
    checkpoint_buf: std.ArrayList(u8) = .empty,

    /// `source` must have passed `validate`. Strings are copied.
    pub fn init(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!FilesConnector {
        const name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(name);
        const root = try gpa.dupe(u8, source.optionString("path").?);
        errdefer gpa.free(root);
        const language = if (source.optionString("language")) |l| try gpa.dupe(u8, l) else null;
        return .{
            .gpa = gpa,
            .io = io,
            .name = name,
            .root = root,
            .max_file_bytes = @intCast(source.optionInt("max_file_bytes") orelse default_max_file_bytes),
            .language = language,
            .pdf_text = source.optionBool("pdf_text") orelse false,
            .media = source.optionBool("media") orelse false,
            .pdf_workers = @intCast(source.optionInt("pdf_workers") orelse default_pdf_workers),
            .max_pdf_bytes = @intCast(source.optionInt("max_pdf_bytes") orelse @as(i64, @intCast(default_max_pdf_bytes))),
            .pdf_timeout_s = @intCast(source.optionInt("pdf_timeout_seconds") orelse default_pdf_timeout_seconds),
            .office = source.optionBool("office") orelse false,
            .html = source.optionBool("html") orelse false,
        };
    }

    pub fn deinit(self: *FilesConnector) void {
        self.gpa.free(self.name);
        self.gpa.free(self.root);
        if (self.language) |l| self.gpa.free(l);
        self.checkpoint_buf.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn connector(self: *FilesConnector) api.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run, .exists = exists } };
    }

    /// An item is gone only if the root is readable and the file is not a
    /// regular file any more. Any other trouble is "unknown", never "gone".
    fn exists(ptr: *anyopaque, source_id: []const u8) api.Presence {
        const self: *FilesConnector = @ptrCast(@alignCast(ptr));
        const root = Io.Dir.cwd().statFile(self.io, self.root, .{}) catch return .unknown;
        if (root.kind != .directory) return .unknown;
        const path = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.root, source_id }) catch return .unknown;
        defer self.gpa.free(path);
        const st = Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return .gone,
            else => return .unknown,
        };
        return if (st.kind == .file) .present else .gone;
    }

    fn info(_: *anyopaque) api.Info {
        return .{ .kind = kind, .requires_network = false, .resumable = true };
    }

    fn run(ptr: *anyopaque, sink: api.Sink, control: *api.Control, resume_from: ?[]const u8) api.RunError!api.Outcome {
        const self: *FilesConnector = @ptrCast(@alignCast(ptr));
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const io = self.io;

        var dir = Io.Dir.cwd().openDir(io, self.root, .{ .iterate = true }) catch return error.InvalidSource;
        defer dir.close(io);
        if (self.media and !ffprobeWorks(self.gpa, io)) {
            std.debug.print("files source \"{s}\": media = true needs the ffprobe program (on Ubuntu: sudo apt install ffmpeg), and it could not be run\n", .{self.name});
            return error.SourceFailed;
        }
        if (self.pdf_text and !pdftotextWorks(self.gpa, io)) {
            std.debug.print("files source \"{s}\": pdf_text = true needs the pdftotext program (on Ubuntu: sudo apt install poppler-utils), and it could not be run\n", .{self.name});
            return error.SourceFailed;
        }

        const base_abs = Io.Dir.cwd().realPathFileAlloc(io, self.root, arena) catch return error.InvalidSource;
        self.sidecars = .empty;
        var sidecar_paths: std.ArrayList([]const u8) = .empty;
        const paths = collect(arena, io, dir, .{ .pdf = self.pdf_text, .media = self.media, .office = self.office, .html = self.html }, &sidecar_paths) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SourceFailed,
        };
        std.mem.sort([]const u8, paths, {}, lessThan);
        std.mem.sort([]const u8, sidecar_paths.items, {}, lessThan);
        for (sidecar_paths.items) |sp| self.addSidecar(arena, sp) catch return error.OutOfMemory;

        var done: ?[]const u8 = null; // last path fully handled
        var since_checkpoint: u32 = 0;
        // Each file gets its own scratch memory, released before the next one: a library of
        // tens of thousands of books must not keep all their text until the end of the run.
        var file_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer file_arena_state.deinit();
        defer self.clearPdfCache();
        for (paths, 0..) |rel, path_index| {
            _ = file_arena_state.reset(.retain_capacity);
            const file_arena = file_arena_state.allocator();
            control.setProgress(path_index, paths.len);
            if (resume_from) |r| if (!std.mem.lessThan(u8, r, rel)) continue; // already done

            if (control.isCancelled()) return self.stopped(done);

            // PDFs are extracted by several programs at once, a few files ahead of this one.
            if (self.pdf_text and self.pdf_workers > 1 and hasExtension(rel, ".pdf") and !self.pdf_cache.contains(rel)) {
                self.prefetchPdfs(arena, io, base_abs, paths, path_index, resume_from);
            }
            switch (self.readOne(file_arena, io, dir, base_abs, rel)) {
                .skip => {},
                .no_text => control.rejectAt(.no_text, rel),
                .refused => control.rejectAt(.unreadable, rel),
                .document => |d| {
                    sink.submit(d) catch |e| switch (e) {
                        error.Rejected => {}, // the pipeline counts and reports it
                        error.Stopped => return self.stopped(done),
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    _ = control.submitted.fetchAdd(1, .monotonic);
                },
                .out_of_memory => return error.OutOfMemory,
            }
            done = rel;
            since_checkpoint += 1;
            if (since_checkpoint >= checkpoint_every) {
                since_checkpoint = 0;
                sink.checkpoint(rel) catch |e| switch (e) {
                    error.Stopped => return self.stopped(done),
                    else => return error.SourceFailed,
                };
            }
        }
        return .{};
    }

    fn stopped(self: *FilesConnector, done: ?[]const u8) api.Outcome {
        const d = done orelse return .{ .interrupted = true };
        self.checkpoint_buf.clearRetainingCapacity();
        self.checkpoint_buf.appendSlice(self.gpa, d) catch return .{ .interrupted = true };
        return .{ .interrupted = true, .checkpoint = self.checkpoint_buf.items };
    }

    fn readMedia(self: *FilesConnector, arena: Allocator, io: Io, dir: Io.Dir, st: Io.File.Stat, base_abs: []const u8, rel: []const u8, fmt: avmeta.Format) Read {
        return readMediaImpl(self, arena, io, dir, st, base_abs, rel, fmt);
    }

    /// Remembers a subtitle or lyrics file under the name of the media it belongs to: `song.en.srt`
    /// and `song.srt` both belong to `song.mp3`.
    fn addSidecar(self: *FilesConnector, arena: Allocator, rel: []const u8) Allocator.Error!void {
        const ext_len = avmeta.extensionOf(rel).len + 1;
        var stem = rel[0 .. rel.len - ext_len];
        // A language code before the extension: `.en`, `.eng`, `.pt-BR`.
        if (std.mem.lastIndexOfScalar(u8, stem, '.')) |dot| {
            const tag = stem[dot + 1 ..];
            if (isLanguageCode(tag)) stem = stem[0..dot];
        }
        const key = try arena.dupe(u8, stem);
        const gop = try self.sidecars.getOrPut(arena, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, try arena.dupe(u8, rel));
    }

    fn clearPdfCache(self: *FilesConnector) void {
        var it = self.pdf_cache.iterator();
        while (it.next()) |e| {
            std.heap.page_allocator.free(e.value_ptr.stdout);
            self.gpa.free(e.key_ptr.*);
        }
        self.pdf_cache.deinit(self.gpa);
        self.pdf_cache = .empty;
    }

    /// Starts `pdftotext` on this PDF and the next few, all at once, and keeps what they print
    /// until each file's turn comes. Memory held is bounded by `pdf_workers` times the text limit.
    fn prefetchPdfs(self: *FilesConnector, arena: Allocator, io: Io, base_abs: []const u8, paths: []const []const u8, from: usize, resume_from: ?[]const u8) void {
        const workers: usize = self.pdf_workers;
        var jobs: [max_pdf_workers]PdfJob = undefined;
        var rels: [max_pdf_workers][]const u8 = undefined;
        var threads: [max_pdf_workers]?std.Thread = @splat(null);
        var n: usize = 0;
        var i = from;
        while (i < paths.len and n < workers and i < from + workers * 8) : (i += 1) {
            const rel = paths[i];
            if (!hasExtension(rel, ".pdf") or self.pdf_cache.contains(rel)) continue;
            if (resume_from) |r| if (!std.mem.lessThan(u8, r, rel)) continue;
            const abs = std.fmt.allocPrint(arena, "{s}/{s}", .{ base_abs, rel }) catch return;
            jobs[n] = .{ .io = io, .abs_path = abs, .max_out = self.max_file_bytes, .timeout_s = self.pdf_timeout_s };
            rels[n] = rel;
            n += 1;
        }
        for (0..n) |k| threads[k] = std.Thread.spawn(.{}, runPdfJob, .{&jobs[k]}) catch null;
        for (0..n) |k| {
            if (threads[k]) |t| t.join() else runPdfJob(&jobs[k]); // could not start a thread: do it here
        }
        for (0..n) |k| {
            const result = jobs[k].result orelse PdfResult{ .stdout = &.{}, .failed = true };
            const key = self.gpa.dupe(u8, rels[k]) catch {
                std.heap.page_allocator.free(result.stdout);
                continue;
            };
            self.pdf_cache.put(self.gpa, key, result) catch {
                self.gpa.free(key);
                std.heap.page_allocator.free(result.stdout);
            };
        }
    }

    fn readPdf(self: *FilesConnector, arena: Allocator, io: Io, st: Io.File.Stat, base_abs: []const u8, rel: []const u8) Read {
        return readPdfImpl(self, arena, io, st, base_abs, rel);
    }

    pub const Read = union(enum) {
        /// Nothing to index (an empty file, or the file vanished): not an error.
        skip,
        /// Present but unacceptable (too large, unreadable): counted as rejected.
        refused,
        /// A PDF with no text layer (a scan): counted and reported as "no_text".
        no_text,
        document: doc.Document,
        out_of_memory,
    };

    fn readOne(self: *FilesConnector, arena: Allocator, io: Io, dir: Io.Dir, base_abs: []const u8, rel: []const u8) Read {
        const st = dir.statFile(io, rel, .{ .follow_symlinks = false }) catch return .refused;
        if (st.kind != .file) return .refused; // replaced by a link or directory since listing
        if (hasExtension(rel, ".pdf")) return self.readPdf(arena, io, st, base_abs, rel);
        if (self.media) if (avmeta.formatOf(rel)) |fmt| return self.readMedia(arena, io, dir, st, base_abs, rel, fmt);
        if (self.office) if (officetext.kindOf(rel)) |office_kind| return readOfficeImpl(self, arena, io, dir, st, base_abs, rel, office_kind);
        if (self.html and (hasExtension(rel, ".html") or hasExtension(rel, ".htm"))) return readHtmlImpl(self, arena, io, dir, st, base_abs, rel);
        const is_md = hasExtension(rel, ".md");
        // Markdown from converters (Docling, ...) can carry its images inline as base64, which is most of the file
        // and no use to a reader or a search, so the size limit applies to what is left after they are removed.
        const read_limit: u32 = if (is_md) hard_max_file_bytes else self.max_file_bytes;
        if (st.size > read_limit) return .refused;
        if (st.size == 0) return .skip;

        var text: []const u8 = dir.readFileAlloc(io, rel, arena, .limited(@as(usize, read_limit) + 1)) catch |e| switch (e) {
            error.OutOfMemory => return .out_of_memory,
            else => return .refused,
        };
        if (text.len > read_limit) return .refused; // grew while reading
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return .refused;
        if (is_md) {
            text = retrieve.withoutInlineImages(arena, text) catch return .out_of_memory;
            if (text.len > self.max_file_bytes) return .refused;
            if (text.len == 0) return .skip;
        }

        const url = fileUrl(arena, base_abs, rel) catch return .out_of_memory;
        const mtime_s: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
        return .{ .document = .{
            .connector = self.name,
            .source_id = rel,
            .canonical_url = url,
            .title = titleOf(text, rel, is_md),
            .text = text,
            .language = self.language,
            .content_type = if (is_md) "text/markdown" else "text/plain",
            .modified_at = mtime_s,
        } };
    }
};

const pdf_timeout_seconds = 60;
pub const max_pdf_workers = 32;
/// Largest PDF accepted by default, and the most that can be asked for. `pdftotext` reads the file
/// itself, so this is not memory held here; it bounds how much work one file can cost.
pub const default_max_pdf_bytes: u64 = 512 * 1024 * 1024;
pub const max_pdf_file_bytes: i64 = 8 * 1024 * 1024 * 1024;
pub const default_pdf_timeout_seconds: u32 = 120;
pub const default_pdf_workers = 4;
/// Largest `docx`, `odt` or `epub` file opened (only its text parts are read, one at a time).
const hard_max_office_bytes: u64 = 512 * 1024 * 1024;

fn readOfficeImpl(self: *FilesConnector, arena: Allocator, io: Io, dir: Io.Dir, st: Io.File.Stat, base_abs: []const u8, rel: []const u8, office_kind: officetext.Kind) FilesConnector.Read {
    if (st.size == 0) return .skip;
    if (st.size > hard_max_office_bytes) return .refused;
    var file = dir.openFile(io, rel, .{}) catch return .refused;
    defer file.close(io);
    var archive: ziparchive.Archive = undefined;
    archive.open(arena, io, file) catch |e| return switch (e) {
        error.OutOfMemory => .out_of_memory,
        else => .refused, // not a zip (an old binary .doc, an encrypted file), or damaged
    };
    const got = officetext.extract(arena, &archive, office_kind, self.max_file_bytes) catch |e| return switch (e) {
        error.OutOfMemory => .out_of_memory,
        else => .refused, // too much text, damaged parts, or not the kind of document its name says
    };
    if (got.text.len == 0) return .no_text;
    if (!std.unicode.utf8ValidateSlice(got.text)) return .refused;
    const url = fileUrl(arena, base_abs, rel) catch return .out_of_memory;
    const mtime_s: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
    return .{ .document = .{
        .connector = self.name,
        .source_id = rel,
        .canonical_url = url,
        .title = got.title orelse titleOf(got.text, rel, false),
        .text = got.text,
        .language = got.language orelse self.language,
        .content_type = office_kind.contentType(),
        .author = got.author,
        .published_at = if (got.date) |d| avmeta.yearStart(d) else null,
        .modified_at = mtime_s,
        .extra = fileSizeExtra(arena, st.size) catch return .out_of_memory,
    } };
}

fn readHtmlImpl(self: *FilesConnector, arena: Allocator, io: Io, dir: Io.Dir, st: Io.File.Stat, base_abs: []const u8, rel: []const u8) FilesConnector.Read {
    if (st.size == 0) return .skip;
    if (st.size > self.max_file_bytes) return .refused;
    const raw = dir.readFileAlloc(io, rel, arena, .limited(self.max_file_bytes + 1)) catch |e| switch (e) {
        error.OutOfMemory => return .out_of_memory,
        else => return .refused,
    };
    if (raw.len > self.max_file_bytes) return .refused;
    if (!std.unicode.utf8ValidateSlice(raw) or std.mem.indexOfScalar(u8, raw, 0) != null) return .refused;
    const text = htmltext.toText(arena, raw) catch return .out_of_memory;
    if (text.len == 0) return .no_text;
    const title = htmltext.titleOf(arena, raw) catch return .out_of_memory;
    const url = fileUrl(arena, base_abs, rel) catch return .out_of_memory;
    const mtime_s: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
    return .{ .document = .{
        .connector = self.name,
        .source_id = rel,
        .canonical_url = url,
        .title = title orelse titleOf(text, rel, false),
        .text = text,
        .language = self.language,
        .content_type = "text/html",
        .modified_at = mtime_s,
        .extra = fileSizeExtra(arena, st.size) catch return .out_of_memory,
    } };
}
const media_timeout_seconds = 30;
/// The most subtitle or lyrics files read for one media file, and the largest of them.
const max_sidecars_per_media = 3;
const max_sidecar_bytes = 2 * 1024 * 1024;

const SidecarMap = std.StringHashMapUnmanaged(std.ArrayList([]const u8));

fn isLanguageCode(tag: []const u8) bool {
    if (tag.len < 2 or tag.len > 8) return false;
    for (tag) |c| if (!std.ascii.isAlphabetic(c) and c != '-') return false;
    return true;
}

/// True if the `ffprobe` program (ffmpeg) can be run.
fn ffprobeWorks(gpa: Allocator, io: Io) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "ffprobe", "-version" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return true;
}

/// The size of the original file, for the `size:` filter (the index would otherwise use the length of the text).
fn fileSizeExtra(arena: Allocator, size: u64) Allocator.Error![]const doc.Extra {
    const one = try arena.alloc(doc.Extra, 1);
    one[0] = .{ .key = "file_size", .value = try std.fmt.allocPrint(arena, "{d}", .{size}) };
    return one;
}

fn appendLine(arena: Allocator, text: *std.ArrayList(u8), label: []const u8, value: ?[]const u8) Allocator.Error!void {
    const v = value orelse return;
    try text.print(arena, "{s}: {s}\n", .{ label, v });
}

fn readMediaImpl(self: *FilesConnector, arena: Allocator, io: Io, dir: Io.Dir, st: Io.File.Stat, base_abs: []const u8, rel: []const u8, fmt: avmeta.Format) FilesConnector.Read {
    if (st.size == 0) return .skip;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ base_abs, rel }) catch return .out_of_memory;
    const result = std.process.run(arena, io, .{
        .argv = &.{ "ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(media_timeout_seconds), .clock = .awake } },
    }) catch |e| switch (e) {
        error.OutOfMemory => return .out_of_memory,
        else => return .refused,
    };
    if (!result.term.success()) return .refused; // not readable as media
    const info = avmeta.parseProbe(arena, result.stdout) catch |e| switch (e) {
        error.OutOfMemory => return .out_of_memory,
        error.BadProbe => return .refused,
    };

    const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    const stem_name = base[0 .. base.len - avmeta.extensionOf(base).len - 1];
    const title = info.title orelse stem_name;

    // The text that makes the file findable: its tags, its name and whatever words come with it.
    var text: std.ArrayList(u8) = .empty;
    mediaText(arena, &text, info, stem_name, fmt, dir, io, self, rel) catch return .out_of_memory;

    var extras: std.ArrayList(doc.Extra) = .empty;
    mediaExtras(arena, &extras, info, st.size) catch return .out_of_memory;

    const url = fileUrl(arena, base_abs, rel) catch return .out_of_memory;
    const mtime_s: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
    return .{ .document = .{
        .connector = self.name,
        .source_id = rel,
        .canonical_url = url,
        .title = title,
        .text = text.items,
        .language = self.language,
        .content_type = fmt.content_type,
        .author = info.artist orelse info.album_artist,
        .published_at = if (info.date) |d| avmeta.yearStart(d) else null,
        .modified_at = mtime_s,
        .extra = extras.items,
    } };
}

fn mediaText(arena: Allocator, text: *std.ArrayList(u8), info: avmeta.Info, stem_name: []const u8, fmt: avmeta.Format, dir: Io.Dir, io: Io, self: *FilesConnector, rel: []const u8) Allocator.Error!void {
    try appendLine(arena, text, "Title", info.title orelse stem_name);
    try appendLine(arena, text, "Artist", info.artist);
    try appendLine(arena, text, "Album artist", info.album_artist);
    try appendLine(arena, text, "Album", info.album);
    try appendLine(arena, text, "Composer", info.composer);
    try appendLine(arena, text, "Genre", info.genre);
    try appendLine(arena, text, "Date", info.date);
    try appendLine(arena, text, "Track", info.track);
    try appendLine(arena, text, "Comment", info.comment);
    try text.print(arena, "{s}", .{if (fmt.kind == .audio) "Kind: audio" else "Kind: video"});
    if (info.duration_seconds) |d| try text.print(arena, ", duration {s}", .{try avmeta.formatDuration(arena, d)});
    try text.append(arena, '\n');
    if (info.lyrics) |l| try text.print(arena, "\nLyrics:\n{s}\n", .{l});

    // Subtitle and lyrics files next to it.
    const ext_len = avmeta.extensionOf(rel).len + 1;
    const stem = rel[0 .. rel.len - ext_len];
    const found = self.sidecars.get(stem) orelse return;
    for (found.items, 0..) |sp, n| {
        if (n >= max_sidecars_per_media) break;
        const bytes = dir.readFileAlloc(io, sp, arena, .limited(max_sidecar_bytes)) catch continue;
        if (!std.unicode.utf8ValidateSlice(bytes)) continue;
        const words = try avmeta.sidecarText(arena, bytes, avmeta.extensionOf(sp));
        if (words.len == 0) continue;
        const label = if (std.ascii.eqlIgnoreCase(avmeta.extensionOf(sp), "lrc")) "Lyrics" else "Subtitles";
        try text.print(arena, "\n{s}:\n{s}", .{ label, words });
    }
}

fn mediaExtras(arena: Allocator, extras: *std.ArrayList(doc.Extra), info: avmeta.Info, file_size: u64) Allocator.Error!void {
    const strings = [_]struct { []const u8, ?[]const u8 }{
        .{ "artist", info.artist },           .{ "album", info.album }, .{ "genre", info.genre },
        .{ "composer", info.composer },       .{ "track", info.track }, .{ "audio_codec", info.audio_codec },
        .{ "video_codec", info.video_codec },
    };
    for (strings) |kv| if (kv[1]) |v| if (v.len <= 256) try extras.append(arena, .{ .key = kv[0], .value = v });
    if (info.date) |d| if (d.len >= 4) try extras.append(arena, .{ .key = "year", .value = d[0..4] });
    if (info.duration_seconds) |d| try extras.append(arena, .{ .key = "duration_seconds", .value = try std.fmt.allocPrint(arena, "{d}", .{d}) });
    if (info.bit_rate_kbps) |b| try extras.append(arena, .{ .key = "bitrate_kbps", .value = try std.fmt.allocPrint(arena, "{d}", .{b}) });
    if (info.width != null and info.height != null) try extras.append(arena, .{ .key = "resolution", .value = try std.fmt.allocPrint(arena, "{d}x{d}", .{ info.width.?, info.height.? }) });
    try extras.append(arena, .{ .key = "file_size", .value = try std.fmt.allocPrint(arena, "{d}", .{file_size}) });
}

pub const PdfResult = struct {
    /// What `pdftotext` printed (owned by the page allocator), or empty.
    stdout: []u8,
    /// The program failed or ran over its limits.
    failed: bool = false,
};

const PdfJob = struct {
    io: Io,
    abs_path: []const u8,
    max_out: u32,
    timeout_s: u32,
    result: ?PdfResult = null,
};

/// Runs `pdftotext` for one file (in a worker thread). The output belongs to the page allocator,
/// which is safe to use from any thread.
fn runPdfJob(job: *PdfJob) void {
    const pa = std.heap.page_allocator;
    const r = std.process.run(pa, job.io, .{
        .argv = &.{ "pdftotext", "-enc", "UTF-8", "-layout", "-q", job.abs_path, "-" },
        .stdout_limit = .limited(job.max_out + 1),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(job.timeout_s), .clock = .awake } },
    }) catch return;
    pa.free(r.stderr);
    if (!r.term.success() or r.stdout.len > job.max_out) {
        pa.free(r.stdout);
        return;
    }
    job.result = .{ .stdout = r.stdout };
}

/// True if the `pdftotext` program (poppler-utils) can be run.
fn pdftotextWorks(gpa: Allocator, io: Io) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "pdftotext", "-v" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return true; // `pdftotext -v` prints its version and some builds exit non-zero; it ran
}

fn readPdfImpl(self: *FilesConnector, arena: Allocator, io: Io, st: Io.File.Stat, base_abs: []const u8, rel: []const u8) FilesConnector.Read {
    if (st.size > self.max_pdf_bytes) return .refused;
    if (st.size == 0) return .skip;
    // Output prepared ahead of time by the workers, or run the program now.
    var stdout: []const u8 = undefined;
    var owned_by_page_allocator = false;
    if (self.pdf_cache.fetchRemove(rel)) |kv| {
        self.gpa.free(kv.key);
        if (kv.value.failed) return .refused;
        stdout = kv.value.stdout;
        owned_by_page_allocator = true;
    } else {
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ base_abs, rel }) catch return .out_of_memory;
        const result = std.process.run(arena, io, .{
            .argv = &.{ "pdftotext", "-enc", "UTF-8", "-layout", "-q", path, "-" },
            .stdout_limit = .limited(self.max_file_bytes + 1),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(self.pdf_timeout_s), .clock = .awake } },
        }) catch |e| switch (e) {
            error.OutOfMemory => return .out_of_memory,
            else => return .refused, // too much text, a timeout, or the program could not run
        };
        if (!result.term.success()) return .refused; // damaged, encrypted, or not a PDF
        if (result.stdout.len > self.max_file_bytes) return .refused;
        stdout = result.stdout;
    }
    defer if (owned_by_page_allocator) std.heap.page_allocator.free(@constCast(stdout));
    // The text is copied below, so the buffer can be released as soon as this function returns.
    // Page breaks (form feeds) become blank lines; anything else that is not text is dropped.
    var text: std.ArrayList(u8) = .empty;
    for (stdout) |b| switch (b) {
        0x0C => text.appendSlice(arena, "\n\n") catch return .out_of_memory,
        0 => {},
        else => text.append(arena, b) catch return .out_of_memory,
    };
    const trimmed = std.mem.trim(u8, text.items, " \t\r\n");
    if (trimmed.len == 0) return .no_text;
    if (!std.unicode.utf8ValidateSlice(trimmed)) return .refused;
    const url = fileUrl(arena, base_abs, rel) catch return .out_of_memory;
    const mtime_s: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
    return .{ .document = .{
        .connector = self.name,
        .source_id = rel,
        .canonical_url = url,
        .title = titleOf(trimmed, rel, false),
        .text = trimmed,
        .language = self.language,
        .content_type = "application/pdf",
        .modified_at = mtime_s,
        .extra = fileSizeExtra(arena, st.size) catch return .out_of_memory,
    } };
}

/// Paths (relative, '/'-separated) of every eligible file under `dir`.
const Wanted = struct { pdf: bool, media: bool, office: bool, html: bool };

fn collect(arena: Allocator, io: Io, dir: Io.Dir, want: Wanted, sidecars: *std.ArrayList([]const u8)) !([][]const u8) {
    const pdf = want.pdf;
    const media = want.media;
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.basename.len == 0 or entry.basename[0] == '.') continue; // hidden: skipped, not entered
        switch (entry.kind) {
            .directory => try walker.enter(io, entry),
            .file => {
                const wanted = hasExtension(entry.path, ".txt") or hasExtension(entry.path, ".md") or
                    (pdf and hasExtension(entry.path, ".pdf")) or (media and avmeta.formatOf(entry.path) != null) or
                    (want.office and officetext.kindOf(entry.path) != null) or
                    (want.html and (hasExtension(entry.path, ".html") or hasExtension(entry.path, ".htm")));
                if (wanted) {
                    try list.append(arena, try arena.dupe(u8, entry.path));
                } else if (media and avmeta.isSidecar(entry.path)) {
                    // Not a document of its own: its text goes with the media file it sits next to.
                    try sidecars.append(arena, try arena.dupe(u8, entry.path));
                }
            },
            else => {}, // symlinks, devices, sockets, ...: never followed or read
        }
    }
    return list.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
    return path.len >= ext.len and std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext);
}

/// The first Markdown "# heading", else the file name without its extension.
fn titleOf(text: []const u8, rel: []const u8, is_md: bool) []const u8 {
    if (is_md) {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var seen: usize = 0;
        while (lines.next()) |line| : (seen += 1) {
            if (seen > 50) break; // only look near the top
            const t = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, t, "# ")) {
                const title = std.mem.trim(u8, t[2..], " \t");
                if (title.len > 0) return title;
            }
        }
    }
    const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    return base[0..dot];
}

/// `file:///abs/base/rel`, percent-encoding everything but unreserved
/// characters and '/'.
fn fileUrl(arena: Allocator, base_abs: []const u8, rel: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "file://");
    for ([_][]const u8{ base_abs, "/", rel }) |part| {
        for (part) |b| switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try out.append(arena, b),
            else => try out.print(arena, "%{X:0>2}", .{b}),
        };
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const runner = @import("../runner.zig");
const memory = @import("../memory.zig");
const index_sqlite = @import("../index_sqlite.zig");
const pipeline = @import("../pipeline.zig");
const state_sqlite = @import("../state_sqlite.zig");

fn src(opts: []const config.Option) config.Source {
    return .{ .name = "notes", .kind = "files", .options = opts };
}

test "validate: pdf_text and serve_originals are booleans" {
    var d: config.Diagnostic = .{};
    try validate(src(&.{ .{ .key = "path", .value = .{ .string = "/x" } }, .{ .key = "pdf_text", .value = .{ .boolean = true } }, .{ .key = "serve_originals", .value = .{ .boolean = false } } }), &d);
    try testing.expectError(error.WrongType, validate(src(&.{ .{ .key = "path", .value = .{ .string = "/x" } }, .{ .key = "pdf_text", .value = .{ .string = "yes" } } }), &d));
    try testing.expectError(error.WrongType, validate(src(&.{
        .{ .key = "path", .value = .{ .string = "/x" } },
        .{ .key = "serve_originals", .value = .{ .integer = 1 } },
    }), &d));
}

test "validate: path is required; unknown and mistyped options are named" {
    var d: config.Diagnostic = .{};
    try validate(src(&.{.{ .key = "path", .value = .{ .string = "/x" } }}), &d);
    try validate(src(&.{
        .{ .key = "path", .value = .{ .string = "/x" } },
        .{ .key = "max_file_bytes", .value = .{ .integer = 1000 } },
        .{ .key = "language", .value = .{ .string = "pt-BR" } },
    }), &d);

    try testing.expectError(error.InvalidValue, validate(src(&.{}), &d));
    try testing.expectEqualStrings("source[notes].path", d.key());
    try testing.expectError(error.InvalidValue, validate(src(&.{.{ .key = "path", .value = .{ .string = "" } }}), &d));
    try testing.expectError(error.WrongType, validate(src(&.{.{ .key = "path", .value = .{ .integer = 3 } }}), &d));
    try testing.expectError(error.UnknownKey, validate(src(&.{
        .{ .key = "path", .value = .{ .string = "/x" } },
        .{ .key = "pth", .value = .{ .string = "/y" } },
    }), &d));
    try testing.expectEqualStrings("source[notes].pth", d.key());
    try testing.expectError(error.InvalidValue, validate(src(&.{
        .{ .key = "path", .value = .{ .string = "/x" } },
        .{ .key = "max_file_bytes", .value = .{ .integer = 0 } },
    }), &d));
    try testing.expectError(error.InvalidValue, validate(src(&.{
        .{ .key = "path", .value = .{ .string = "/x" } },
        .{ .key = "max_file_bytes", .value = .{ .integer = hard_max_file_bytes + 1 } },
    }), &d));
    try testing.expectError(error.InvalidValue, validate(src(&.{
        .{ .key = "path", .value = .{ .string = "/x" } },
        .{ .key = "language", .value = .{ .string = "en US" } },
    }), &d));
}

test "titles and URLs" {
    try testing.expectEqualStrings("Hello World", titleOf("intro\n\n# Hello World \nbody", "a/b.md", true));
    try testing.expectEqualStrings("b", titleOf("no heading here", "a/b.md", true));
    try testing.expectEqualStrings("notes", titleOf("# Not used for txt", "notes.txt", false));
    try testing.expectEqualStrings("README", titleOf("", "README.MD", true));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("file:///home/me/my%20notes/a%23b.txt", try fileUrl(arena.allocator(), "/home/me/my notes", "a#b.txt"));
}

/// Builds the fixture tree used by the end-to-end tests.
fn makeTree(tmp: *testing.TmpDir) !void {
    const io = testing.io;
    const d = tmp.dir;
    try d.createDirPath(io, "sub/deeper");
    try d.createDirPath(io, ".git");
    try d.createDirPath(io, ".hidden_dir");
    try d.writeFile(io, .{ .sub_path = "a.txt", .data = "The quick brown fox jumps over the lazy dog." });
    try d.writeFile(io, .{ .sub_path = "b.md", .data = "# Fox Facts\n\nFoxes are omnivorous mammals." });
    try d.writeFile(io, .{ .sub_path = "sub/c.TXT", .data = "Upper-case extension, café ünïcode text about otters." });
    try d.writeFile(io, .{ .sub_path = "sub/deeper/d.txt", .data = "Deeply nested file mentioning badgers." });
    try d.writeFile(io, .{ .sub_path = "sub/.secret.txt", .data = "hidden file with secretword" });
    try d.writeFile(io, .{ .sub_path = ".git/config.txt", .data = "inside dot-git with secretword" });
    try d.writeFile(io, .{ .sub_path = ".hidden_dir/x.txt", .data = "inside hidden dir with secretword" });
    try d.writeFile(io, .{ .sub_path = "notes.pdf", .data = "not a text file, secretword" });
    try d.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });
    try d.writeFile(io, .{ .sub_path = "binary.txt", .data = "bad \xff\xfe bytes" });
    try d.writeFile(io, .{ .sub_path = "nul.txt", .data = "has a \x00 nul" });
    var big: [3000]u8 = undefined;
    @memset(&big, 'x');
    try d.writeFile(io, .{ .sub_path = "big.txt", .data = &big });
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

fn treeSource(tmp: *testing.TmpDir, buf: []u8, extra: []const config.Option) !config.Source {
    const path = try std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const opts = try testing.allocator.alloc(config.Option, extra.len + 1);
    opts[0] = .{ .key = "path", .value = .{ .string = path } };
    @memcpy(opts[1..], extra);
    return .{ .name = "notes", .kind = "files", .options = opts };
}

test "indexes eligible files only, and skips everything it must not read" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeTree(&tmp);
    var pb: [200]u8 = undefined;
    const source = try treeSource(&tmp, &pb, &.{
        .{ .key = "max_file_bytes", .value = .{ .integer = 2000 } },
        .{ .key = "language", .value = .{ .string = "en" } },
    });
    defer testing.allocator.free(source.options);

    var fc = try FilesConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};

    const r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl, E2e.now);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    // a.txt, b.md, sub/c.TXT, sub/deeper/d.txt are indexed.
    try testing.expectEqual(@as(u64, 4), r.submitted);
    // Refused by the connector itself: binary.txt (invalid UTF-8), nul.txt (NUL
    // byte) and big.txt (over max_file_bytes). empty.txt is skipped silently.
    try testing.expectEqual(@as(u64, 3), r.rejected);
    try testing.expectEqual(@as(u64, 4), try e.idx.count());

    try testing.expectEqual(@as(usize, 2), try e.hits("fox")); // a.txt, and b.md ("Fox Facts")
    // Never indexed: hidden files/dirs, other extensions, oversized, empty.
    try testing.expectEqual(@as(usize, 0), try e.hits("secretword"));
    try testing.expectEqual(@as(usize, 1), try e.hits("badgers"));
    try testing.expectEqual(@as(usize, 1), try e.hits("café")); // non-ASCII text intact
    try testing.expectEqual(@as(usize, 1), try e.hits("otters"));
}

test "document fields: source name, relative id, title, type, language, file URL" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeTree(&tmp);
    var pb: [200]u8 = undefined;
    const source = try treeSource(&tmp, &pb, &.{.{ .key = "language", .value = .{ .string = "en" } }});
    defer testing.allocator.free(source.options);
    var fc = try FilesConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl, E2e.now);

    const page = try e.idx.searcher().search(e.arena.allocator(), .{ .text = "omnivorous" });
    try testing.expectEqual(@as(usize, 1), page.hits.len);
    try testing.expectEqualStrings("notes", page.hits[0].connector);
    try testing.expectEqualStrings("Fox Facts", page.hits[0].title.?);
    try testing.expect(std.mem.startsWith(u8, page.hits[0].url.?, "file:///"));
    try testing.expect(std.mem.endsWith(u8, page.hits[0].url.?, "/b.md"));

    const rec = (try e.docs.store().find(doc.idFromSource("notes", "b.md"))).?;
    try testing.expectEqualStrings("text/markdown", rec.meta.content_type.?);
    try testing.expectEqualStrings("en", rec.meta.language.?);
    try testing.expect(rec.meta.modified_at != null);
    // The text itself was retained for rebuilds.
    const kept = try e.content.store().get(testing.allocator, rec.id);
    defer testing.allocator.free(kept);
    try testing.expect(std.mem.indexOf(u8, kept, "omnivorous") != null);
}

test "symbolic links are never followed" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try outside.dir.writeFile(testing.io, .{ .sub_path = "private.txt", .data = "linkedsecret outside the tree" });
    try outside.dir.createDirPath(testing.io, "dir");
    try outside.dir.writeFile(testing.io, .{ .sub_path = "dir/inner.txt", .data = "linkedsecret inner" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.txt", .data = "an ordinary file" });

    var tb: [300]u8 = undefined;
    const file_target = try std.fmt.bufPrint(&tb, "../{s}/private.txt", .{outside.sub_path});
    tmp.dir.symLink(testing.io, file_target, "link-file.txt", .{}) catch return error.SkipZigTest;
    var tb2: [300]u8 = undefined;
    const dir_target = try std.fmt.bufPrint(&tb2, "../{s}/dir", .{outside.sub_path});
    tmp.dir.symLink(testing.io, dir_target, "link-dir", .{ .is_directory = true }) catch return error.SkipZigTest;

    var pb: [200]u8 = undefined;
    const source = try treeSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var fc = try FilesConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    const r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl, E2e.now);
    try testing.expectEqual(@as(u64, 1), r.submitted);
    try testing.expectEqual(@as(usize, 0), try e.hits("linkedsecret"));
    try testing.expectEqual(@as(usize, 1), try e.hits("ordinary"));
}

test "a missing directory fails the job cleanly; re-running updates only what changed" {
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};

    const missing: config.Source = .{ .name = "gone", .kind = "files", .options = &.{.{ .key = "path", .value = .{ .string = ".zig-cache/tmp/definitely-not-here" } }} };
    var fc0 = try FilesConnector.init(testing.allocator, testing.io, missing);
    defer fc0.deinit();
    const r0 = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc0.connector(), "gone", &ctl, E2e.now);
    try testing.expectEqual(state_sqlite.JobState.failed, r0.state);
    try testing.expectEqualStrings("InvalidSource", r0.failure.?);

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one.txt", .data = "original wording" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "two.txt", .data = "second file" });
    var pb: [200]u8 = undefined;
    const source = try treeSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var fc = try FilesConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();

    var ctl1: api.Control = .{};
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl1, E2e.now);
    try testing.expectEqual(@as(u64, 2), e.pipe.stats.added);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one.txt", .data = "revised wording" });
    var ctl2: api.Control = .{};
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl2, E2e.now);
    try testing.expectEqual(@as(u64, 1), e.pipe.stats.updated);
    try testing.expectEqual(@as(u64, 1), e.pipe.stats.unchanged);
    try testing.expectEqual(@as(usize, 0), try e.hits("original"));
    try testing.expectEqual(@as(usize, 1), try e.hits("revised"));
}

test "cancel mid-run, then resume from the last finished path" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt" }) |n| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = n, .data = n });
    }
    var pb: [200]u8 = undefined;
    const source = try treeSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var fc = try FilesConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();

    // A sink that cancels the run after two documents.
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
    const out = try fc.connector().run(cs.sink(), &ctl, null);
    try testing.expect(out.interrupted);
    try testing.expectEqualStrings("b.txt", out.checkpoint.?);
    try testing.expectEqual(@as(u64, 2), try e.idx.count());

    var ctl2: api.Control = .{};
    const rest = try fc.connector().run(e.pipe.sink(), &ctl2, out.checkpoint);
    try testing.expect(!rest.interrupted);
    try testing.expectEqual(@as(u64, 4), try e.idx.count());
    try testing.expectEqual(@as(u64, 0), e.pipe.stats.unchanged); // nothing delivered twice
}

test "prune removes only documents whose files are gone" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "keep.txt", .data = "keeper words" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "drop.txt", .data = "dropword here" });
    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/deep.txt", .data = "deepword here" });
    var pb: [200]u8 = undefined;
    const source = try treeSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var fc = try FilesConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl, E2e.now);
    try testing.expectEqual(@as(u64, 3), try e.idx.count());

    try tmp.dir.deleteFile(testing.io, "drop.txt");
    try tmp.dir.deleteTree(testing.io, "sub");
    var ctl2: api.Control = .{};
    const r = try runner.pruneSource(e.arena.allocator(), &e.pipe, fc.connector(), "notes", &ctl2);
    try testing.expect(r.complete);
    try testing.expectEqual(@as(u64, 2), r.removed);
    try testing.expectEqual(@as(u64, 1), try e.idx.count());
    try testing.expectEqual(@as(usize, 0), try e.hits("dropword"));
    try testing.expectEqual(@as(usize, 0), try e.hits("deepword"));
    try testing.expectEqual(@as(usize, 1), try e.hits("keeper"));
    try testing.expectEqual(@as(usize, 1), e.docs.count());
    try testing.expectEqual(@as(usize, 1), e.content.count()); // retained text removed too
}

test "prune never removes anything when the source cannot be read" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "alpha text" });
    var pb: [200]u8 = undefined;
    const source = try treeSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var fc = try FilesConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl, E2e.now);
    tmp.cleanup(); // the whole directory vanishes, like an unmounted disk

    var ctl2: api.Control = .{};
    const r = try runner.pruneSource(e.arena.allocator(), &e.pipe, fc.connector(), "notes", &ctl2);
    try testing.expectEqual(@as(u64, 0), r.removed);
    try testing.expectEqual(@as(u64, 1), try e.idx.count());
}

test "removeSource deletes one source everywhere and forgets its history" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "alpha words" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.txt", .data = "beta words" });
    var pb: [200]u8 = undefined;
    const source = try treeSource(&tmp, &pb, &.{});
    defer testing.allocator.free(source.options);
    var fc = try FilesConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();

    var tmp2 = testing.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();
    try tmp2.dir.writeFile(testing.io, .{ .sub_path = "c.txt", .data = "gamma words" });
    var pb2: [200]u8 = undefined;
    var source2 = try treeSource(&tmp2, &pb2, &.{});
    defer testing.allocator.free(source2.options);
    source2.name = "other";
    var fc2 = try FilesConnector.init(testing.allocator, testing.io, source2);
    defer fc2.deinit();

    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl, E2e.now);
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc2.connector(), "other", &ctl, E2e.now);
    try testing.expectEqual(@as(u64, 3), try e.idx.count());
    try testing.expectEqual(@as(u64, 2), try e.docs.store().countOf("notes"));

    var ctl2: api.Control = .{};
    const r = try runner.removeSource(e.arena.allocator(), &e.state, &e.pipe, "notes", &ctl2);
    try testing.expect(r.complete);
    try testing.expectEqual(@as(u64, 2), r.removed);
    try testing.expectEqual(@as(u64, 1), try e.idx.count());
    try testing.expectEqual(@as(usize, 0), try e.hits("alpha"));
    try testing.expectEqual(@as(usize, 1), try e.hits("gamma")); // the other source is untouched
    try testing.expectEqual(@as(u64, 0), try e.docs.store().countOf("notes"));
    try testing.expectEqual(@as(u64, 1), try e.docs.store().countOf("other"));
    try testing.expectEqual(@as(usize, 1), e.content.count());
    try testing.expect((try e.state.getJob(e.arena.allocator(), 1)) == null); // history forgotten
    try testing.expect((try e.state.getJob(e.arena.allocator(), 2)) != null);

    // Removing again is a no-op; the source can be imported afresh.
    const again = try runner.removeSource(e.arena.allocator(), &e.state, &e.pipe, "notes", &ctl2);
    try testing.expectEqual(@as(u64, 0), again.removed);
    var ctl3: api.Control = .{};
    _ = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl3, E2e.now);
    try testing.expectEqual(@as(u64, 3), try e.idx.count());
}

test "removeSource stops when cancelled and can be repeated" {
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    try e.pipe.submit(.{ .connector = "s", .source_id = "1", .text = "one" });
    var ctl: api.Control = .{};
    ctl.cancel();
    const r = try runner.removeSource(e.arena.allocator(), &e.state, &e.pipe, "s", &ctl);
    try testing.expect(!r.complete);
    try testing.expectEqual(@as(u64, 1), try e.idx.count());
    var ctl2: api.Control = .{};
    const r2 = try runner.removeSource(e.arena.allocator(), &e.state, &e.pipe, "s", &ctl2);
    try testing.expect(r2.complete);
    try testing.expectEqual(@as(u64, 0), try e.idx.count());
}

/// A WAV file of `samples` samples of silence: a valid media file that needs no tools to make.
fn silentWav(arena: Allocator, samples: u32) ![]u8 {
    const data_len: u32 = samples * 2;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "RIFF");
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u32, 36 + data_len)));
    try out.appendSlice(arena, "WAVEfmt ");
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u32, 16)));
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u16, 1))); // PCM
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u16, 1))); // mono
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u32, 8000)));
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u32, 16000)));
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u16, 2)));
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u16, 16)));
    try out.appendSlice(arena, "data");
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u32, data_len)));
    try out.appendNTimes(arena, 0, data_len);
    return out.items;
}

test "media = true: audio is found by its name, with its subtitle or lyrics text, and file size is the file's" {
    if (!ffprobeWorks(testing.allocator, testing.io)) return error.SkipZigTest; // the program is optional
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const wav = try silentWav(arena.allocator(), 16000); // two seconds
    try tmp.dir.createDirPath(testing.io, "talks");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "talks/Evening Lecture.wav", .data = wav });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "talks/Evening Lecture.en.srt", .data = "1\n00:00:01,000 --> 00:00:02,000\nThe lighthouse keeper spoke softly\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "talks/Evening Lecture.lrc", .data = "[ar:Someone]\n[00:01.00]a lantern verse\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "talks/broken.mp3", .data = "this is not audio at all" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "talks/readme.txt", .data = "plain words" });

    var pb: [200]u8 = undefined;
    const off = try treeSource(&tmp, &pb, &.{});
    defer testing.allocator.free(off.options);
    var fc_off = try FilesConnector.init(testing.allocator, testing.io, off);
    defer fc_off.deinit();
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};
    // Without the option the media files are not touched.
    const r0 = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc_off.connector(), "notes", &ctl, E2e.now);
    try testing.expectEqual(@as(u64, 1), r0.submitted);

    var pb2: [200]u8 = undefined;
    const on = try treeSource(&tmp, &pb2, &.{.{ .key = "media", .value = .{ .boolean = true } }});
    defer testing.allocator.free(on.options);
    var fc = try FilesConnector.init(testing.allocator, testing.io, on);
    defer fc.deinit();
    const r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl, E2e.now);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    // The WAV is indexed (and readme.txt is offered again, unchanged); the file that is not audio
    // is refused; the subtitle files are not documents.
    try testing.expectEqual(@as(u64, 2), r.submitted);
    try testing.expectEqual(@as(u64, 1), r.rejected);
    try testing.expectEqual(@as(u64, 2), try e.idx.count()); // readme.txt and the WAV

    try testing.expectEqual(@as(usize, 1), try e.hits("evening lecture")); // by name
    try testing.expectEqual(@as(usize, 1), try e.hits("lighthouse keeper")); // by its subtitles
    try testing.expectEqual(@as(usize, 1), try e.hits("lantern")); // by its lyrics file
    try testing.expectEqual(@as(usize, 0), try e.hits("Someone")); // LRC metadata lines are not text

    const page = try e.idx.searcher().search(e.arena.allocator(), .{ .text = "evening" });
    try testing.expectEqual(@as(usize, 1), page.hits.len);
    try testing.expectEqualStrings("audio", page.hits[0].kind.?);
    try testing.expectEqualStrings("audio/wav", page.hits[0].content_type.?);
    try testing.expectEqual(@as(?u64, wav.len), page.hits[0].size); // the file's size, not the text's
}

test "office = true and html = true: Word, OpenDocument, EPUB and HTML files are found by their text" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "lib");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib/report.docx", .data = @embedFile("../testdata/office/sample.docx") });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib/notes.odt", .data = @embedFile("../testdata/office/sample.odt") });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib/almanac.epub", .data = @embedFile("../testdata/office/sample.epub") });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib/page.html", .data = "<html><head><title>Cape Page</title><script>var x=1</script></head><body><h1>Cape</h1><p>Gannets nest on the cape.</p></body></html>" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib/old.docx", .data = "this is not a zip file, as an old binary document is not" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib/readme.txt", .data = "plain words" });

    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    var ctl: api.Control = .{};

    var pb0: [200]u8 = undefined;
    const off = try treeSource(&tmp, &pb0, &.{});
    defer testing.allocator.free(off.options);
    var fc_off = try FilesConnector.init(testing.allocator, testing.io, off);
    defer fc_off.deinit();
    const r0 = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc_off.connector(), "notes", &ctl, E2e.now);
    try testing.expectEqual(@as(u64, 1), r0.submitted); // only readme.txt

    var pb: [200]u8 = undefined;
    const on = try treeSource(&tmp, &pb, &.{ .{ .key = "office", .value = .{ .boolean = true } }, .{ .key = "html", .value = .{ .boolean = true } } });
    defer testing.allocator.free(on.options);
    var fc = try FilesConnector.init(testing.allocator, testing.io, on);
    defer fc.deinit();
    const r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl, E2e.now);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    try testing.expectEqual(@as(u64, 5), r.submitted); // readme again, the four documents
    try testing.expectEqual(@as(u64, 1), r.rejected); // old.docx is not a zip
    try testing.expectEqual(@as(u64, 5), try e.idx.count());

    try testing.expectEqual(@as(usize, 1), try e.hits("spring tides")); // the Word document
    try testing.expectEqual(@as(usize, 1), try e.hits("lantern")); // the OpenDocument text
    try testing.expectEqual(@as(usize, 1), try e.hits("zeppelins")); // the second chapter of the EPUB
    try testing.expectEqual(@as(usize, 1), try e.hits("gannets")); // the HTML page
    try testing.expectEqual(@as(usize, 0), try e.hits("removed")); // tracked deletions are not text
    try testing.expectEqual(@as(usize, 0), try e.hits("alert")); // a script is not text

    const page = try e.idx.searcher().search(e.arena.allocator(), .{ .text = "tides" });
    try testing.expectEqual(@as(usize, 1), page.hits.len);
    try testing.expectEqualStrings("Harbour Report", page.hits[0].title.?); // from the document's own properties
    try testing.expectEqualStrings("document", page.hits[0].kind.?);
    try testing.expectEqualStrings("Ada Quill", page.hits[0].author.?);
    const html_hit = try e.idx.searcher().search(e.arena.allocator(), .{ .text = "cape" });
    var found_html = false;
    for (html_hit.hits) |h| if (std.mem.eql(u8, h.title.?, "Cape Page") and std.mem.eql(u8, h.kind.?, "page")) {
        found_html = true;
    };
    try testing.expect(found_html);
}

/// A one-page PDF with `text` on it, built by hand (the cross-reference table needs the offsets).
fn minimalPdf(arena: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var offsets: [5]usize = undefined;
    try out.appendSlice(arena, "%PDF-1.4\n");
    const stream = try std.fmt.allocPrint(arena, "BT /F1 18 Tf 72 700 Td ({s}) Tj ET", .{text});
    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        try std.fmt.allocPrint(arena, "<< /Length {d} >>\nstream\n{s}\nendstream", .{ stream.len, stream }),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    };
    for (objs, 0..) |o, i| {
        offsets[i] = out.items.len;
        try out.print(arena, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, o });
    }
    const xref = out.items.len;
    try out.print(arena, "xref\n0 6\n0000000000 65535 f \n", .{});
    for (offsets) |o| try out.print(arena, "{d:0>10} 00000 n \n", .{o});
    try out.print(arena, "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{xref});
    return out.items;
}

test "pdf_text with several workers finds every PDF, refuses the broken one, and matches one worker" {
    if (!pdftotextWorks(testing.allocator, testing.io)) return error.SkipZigTest; // the program is optional
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_]i64{ 1, 4 }) |workers| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        for (0..11) |i| {
            const name = try std.fmt.allocPrint(arena.allocator(), "book{d:0>2}.pdf", .{i});
            const body = try minimalPdf(arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "chapter about lighthouse{d}", .{i}));
            try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = body });
        }
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.pdf", .data = "%PDF-1.4 this is not a real pdf" });
        var pb: [200]u8 = undefined;
        const source = try treeSource(&tmp, &pb, &.{
            .{ .key = "pdf_text", .value = .{ .boolean = true } },
            .{ .key = "pdf_workers", .value = .{ .integer = workers } },
        });
        defer testing.allocator.free(source.options);
        var fc = try FilesConnector.init(testing.allocator, testing.io, source);
        defer fc.deinit();
        var e: E2e = undefined;
        try e.init();
        defer e.deinit();
        var ctl: api.Control = .{};
        const r = try runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "notes", &ctl, E2e.now);
        try testing.expectEqual(state_sqlite.JobState.completed, r.state);
        try testing.expectEqual(@as(u64, 11), r.submitted);
        try testing.expectEqual(@as(u64, 1), r.rejected);
        try testing.expectEqual(@as(u64, 11), try e.idx.count());
        try testing.expectEqual(@as(usize, 1), try e.hits("lighthouse7"));
        try testing.expectEqual(@as(usize, 1), try e.hits("lighthouse10"));
        try testing.expectEqual(@as(u32, 0), fc.pdf_cache.count()); // nothing is left over
    }
}

test "max_pdf_bytes and pdf_timeout_seconds are numbers in range" {
    var d: config.Diagnostic = .{};
    const base = config.Option{ .key = "path", .value = .{ .string = "/x" } };
    try validate(src(&.{ base, .{ .key = "max_pdf_bytes", .value = .{ .integer = 1_000_000_000 } }, .{ .key = "pdf_timeout_seconds", .value = .{ .integer = 600 } } }), &d);
    try testing.expectError(error.InvalidValue, validate(src(&.{ base, .{ .key = "max_pdf_bytes", .value = .{ .integer = 0 } } }), &d));
    try testing.expectError(error.InvalidValue, validate(src(&.{ base, .{ .key = "max_pdf_bytes", .value = .{ .integer = 9_000_000_000 } } }), &d));
    try testing.expectError(error.InvalidValue, validate(src(&.{ base, .{ .key = "pdf_timeout_seconds", .value = .{ .integer = 7200 } } }), &d));
    try testing.expectError(error.WrongType, validate(src(&.{ base, .{ .key = "max_pdf_bytes", .value = .{ .string = "big" } } }), &d));
}

test "pdf_workers is a number from 1 to 32" {
    var d: config.Diagnostic = .{};
    try validate(src(&.{ .{ .key = "path", .value = .{ .string = "/x" } }, .{ .key = "pdf_workers", .value = .{ .integer = 8 } } }), &d);
    try testing.expectError(error.InvalidValue, validate(src(&.{ .{ .key = "path", .value = .{ .string = "/x" } }, .{ .key = "pdf_workers", .value = .{ .integer = 0 } } }), &d));
    try testing.expectError(error.InvalidValue, validate(src(&.{ .{ .key = "path", .value = .{ .string = "/x" } }, .{ .key = "pdf_workers", .value = .{ .integer = 99 } } }), &d));
    try testing.expectError(error.WrongType, validate(src(&.{ .{ .key = "path", .value = .{ .string = "/x" } }, .{ .key = "pdf_workers", .value = .{ .string = "4" } } }), &d));
}
