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
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");

pub const kind = "files";
pub const default_max_file_bytes: u32 = 4 * 1024 * 1024;
pub const hard_max_file_bytes: u32 = 64 * 1024 * 1024;
const checkpoint_every = 100;
const allowed_options = [_][]const u8{ "path", "max_file_bytes", "language", "serve_originals" };

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
    if (source.option("serve_originals")) |v| switch (v) {
        .boolean => {},
        else => {
            diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].serve_originals", .{source.name}) catch "serve_originals", "expected true or false", .{});
            return error.WrongType;
        },
    };
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

        const base_abs = Io.Dir.cwd().realPathFileAlloc(io, self.root, arena) catch return error.InvalidSource;
        const paths = collect(arena, io, dir) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SourceFailed,
        };
        std.mem.sort([]const u8, paths, {}, lessThan);

        var done: ?[]const u8 = null; // last path fully handled
        var since_checkpoint: u32 = 0;
        for (paths, 0..) |rel, path_index| {
            control.setProgress(path_index, paths.len);
            if (resume_from) |r| if (!std.mem.lessThan(u8, r, rel)) continue; // already done

            if (control.isCancelled()) return self.stopped(done);

            switch (self.readOne(arena, io, dir, base_abs, rel)) {
                .skip => {},
                .refused => _ = control.rejected.fetchAdd(1, .monotonic),
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

    const Read = union(enum) {
        /// Nothing to index (an empty file, or the file vanished): not an error.
        skip,
        /// Present but unacceptable (too large, unreadable): counted as rejected.
        refused,
        document: doc.Document,
        out_of_memory,
    };

    fn readOne(self: *FilesConnector, arena: Allocator, io: Io, dir: Io.Dir, base_abs: []const u8, rel: []const u8) Read {
        const st = dir.statFile(io, rel, .{ .follow_symlinks = false }) catch return .refused;
        if (st.kind != .file) return .refused; // replaced by a link or directory since listing
        if (st.size > self.max_file_bytes) return .refused;
        if (st.size == 0) return .skip;

        const text = dir.readFileAlloc(io, rel, arena, .limited(self.max_file_bytes + 1)) catch |e| switch (e) {
            error.OutOfMemory => return .out_of_memory,
            else => return .refused,
        };
        if (text.len > self.max_file_bytes) return .refused; // grew while reading
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return .refused;

        const is_md = hasExtension(rel, ".md");
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

/// Paths (relative, '/'-separated) of every eligible file under `dir`.
fn collect(arena: Allocator, io: Io, dir: Io.Dir) !([][]const u8) {
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.basename.len == 0 or entry.basename[0] == '.') continue; // hidden: skipped, not entered
        switch (entry.kind) {
            .directory => try walker.enter(io, entry),
            .file => if (hasExtension(entry.path, ".txt") or hasExtension(entry.path, ".md")) {
                try list.append(arena, try arena.dupe(u8, entry.path));
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
