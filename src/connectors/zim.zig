//! The ZIM connector: indexes the articles of a ZIM file, the offline-content
//! format of the Kiwix project (Wikipedia, Wiktionary, Stack Exchange, project
//! documentation and many other sites packaged as one file).
//!
//! It reads a file the administrator has already downloaded and never uses the
//! network. The reader is written here, on Zig's own xz and zstd decoders,
//! rather than on libzim (a large C++ library): the format is small, and an
//! archive from the internet is untrusted input that is better parsed by
//! bounds-checked code (docs/decisions/0025).
//!
//! What is indexed: entries of the content namespace (`C`; `A` in older
//! files) whose type is HTML or plain text. Redirects, images, scripts,
//! stylesheets and metadata are not documents. HTML is converted to text with
//! the same converter as feeds and crawled pages.
//!
//! Order of work: the directory is read once to find the content entries,
//! which are then handled cluster by cluster, so that each compressed cluster
//! (usually a megabyte or two holding many articles) is decompressed once and
//! not once per article. The resume position is the next cluster
//! (`cluster:N`), saved every few clusters.
//!
//! Options:
//!   path               required: the .zim file
//!   language           optional: language tag stored on each document
//!   url_base           optional: where the articles can be read, ending in "/"
//!                      (for example the address of a kiwix-serve: it is put
//!                      before the entry's path to make each result's link)
//!   max_article_bytes  optional: largest article text indexed, 1 to 67108864
//!                      (default 4194304); larger ones are refused
//!   max_cluster_bytes  optional: largest decompressed cluster accepted, 1 to
//!                      1073741824 (default 134217728)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");
const files = @import("files.zig");
const htmltext = @import("../htmltext.zig");

pub const kind = "zim";
pub const default_max_article_bytes: u32 = 4 * 1024 * 1024;
pub const hard_max_article_bytes: u32 = 64 * 1024 * 1024;
pub const default_max_cluster_bytes: u32 = 128 * 1024 * 1024;
pub const hard_max_cluster_bytes: u32 = 1 << 30;
const checkpoint_every_clusters = 8;
const header_len = 80;
const max_entry_read = 1100;
const max_url_len = 1000;
const zim_magic: u32 = 0x044D495A;
const allowed_options = [_][]const u8{ "path", "language", "url_base", "max_article_bytes", "max_cluster_bytes" };

fn key(buf: []u8, source: config.Source, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "source[{s}].{s}", .{ source.name, name }) catch name;
}

pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    for (source.options) |o| {
        var known = false;
        for (allowed_options) |k| {
            if (std.mem.eql(u8, k, o.key)) known = true;
        }
        if (!known) {
            diag.set("", key(&kbuf, source, o.key), "unknown option for kind \"zim\"", .{});
            return error.UnknownKey;
        }
    }
    switch (source.option("path") orelse {
        diag.set("", key(&kbuf, source, "path"), "is required for kind \"zim\"", .{});
        return error.InvalidValue;
    }) {
        .string => |p| if (p.len == 0) {
            diag.set("", key(&kbuf, source, "path"), "must not be empty", .{});
            return error.InvalidValue;
        },
        else => {
            diag.set("", key(&kbuf, source, "path"), "expected string", .{});
            return error.WrongType;
        },
    }
    if (source.option("language")) |v| switch (v) {
        .string => |l| if (!files.validLanguageTag(l)) {
            diag.set("", key(&kbuf, source, "language"), "must be a language tag such as \"en\" (letters, digits and '-', at most 35 characters)", .{});
            return error.InvalidValue;
        },
        else => {
            diag.set("", key(&kbuf, source, "language"), "expected string", .{});
            return error.WrongType;
        },
    };
    if (source.option("url_base")) |v| switch (v) {
        .string => |u| if (!(std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://")) or !std.mem.endsWith(u8, u, "/") or std.mem.indexOfAny(u8, u, " \t\r\n") != null) {
            diag.set("", key(&kbuf, source, "url_base"), "must start with http:// or https://, end in \"/\" and contain no spaces", .{});
            return error.InvalidValue;
        },
        else => {
            diag.set("", key(&kbuf, source, "url_base"), "expected string", .{});
            return error.WrongType;
        },
    };
    inline for (.{ .{ "max_article_bytes", hard_max_article_bytes }, .{ "max_cluster_bytes", hard_max_cluster_bytes } }) |opt| {
        if (source.option(opt[0])) |v| switch (v) {
            .integer => |n| if (n < 1 or n > opt[1]) {
                diag.set("", key(&kbuf, source, opt[0]), "must be between 1 and {d}, got {d}", .{ @as(u32, opt[1]), n });
                return error.InvalidValue;
            },
            else => {
                diag.set("", key(&kbuf, source, opt[0]), "expected integer", .{});
                return error.WrongType;
            },
        };
    }
}

pub const ZimConnector = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    path: []const u8,
    language: ?[]const u8,
    url_base: ?[]const u8,
    max_article_bytes: u32,
    max_cluster_bytes: u32,
    checkpoint_buf: [32]u8 = undefined,
    checkpoint_len: usize = 0,

    pub fn init(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!ZimConnector {
        const name = try gpa.dupe(u8, source.name);
        errdefer gpa.free(name);
        const path = try gpa.dupe(u8, source.optionString("path").?);
        errdefer gpa.free(path);
        const language = if (source.optionString("language")) |l| try gpa.dupe(u8, l) else null;
        errdefer if (language) |l| gpa.free(l);
        const url_base = if (source.optionString("url_base")) |u| try gpa.dupe(u8, u) else null;
        return .{
            .gpa = gpa,
            .io = io,
            .name = name,
            .path = path,
            .language = language,
            .url_base = url_base,
            .max_article_bytes = @intCast(source.optionInt("max_article_bytes") orelse default_max_article_bytes),
            .max_cluster_bytes = @intCast(source.optionInt("max_cluster_bytes") orelse default_max_cluster_bytes),
        };
    }

    pub fn deinit(self: *ZimConnector) void {
        self.gpa.free(self.name);
        self.gpa.free(self.path);
        if (self.language) |l| self.gpa.free(l);
        if (self.url_base) |u| self.gpa.free(u);
        self.* = undefined;
    }

    pub fn connector(self: *ZimConnector) api.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run } };
    }

    fn info(_: *anyopaque) api.Info {
        return .{ .kind = kind, .requires_network = false, .resumable = true };
    }

    fn setCheckpoint(self: *ZimConnector, next_cluster: u32) []const u8 {
        const t = std.fmt.bufPrint(&self.checkpoint_buf, "cluster:{d}", .{next_cluster}) catch unreachable;
        self.checkpoint_len = t.len;
        return t;
    }

    fn stopped(self: *ZimConnector, next_cluster: u32) api.Outcome {
        if (next_cluster == 0) return .{ .interrupted = true };
        return .{ .interrupted = true, .checkpoint = self.setCheckpoint(next_cluster) };
    }

    fn run(ptr: *anyopaque, sink: api.Sink, control: *api.Control, resume_from: ?[]const u8) api.RunError!api.Outcome {
        const self: *ZimConnector = @ptrCast(@alignCast(ptr));
        var start_cluster: u32 = 0;
        if (resume_from) |r| {
            if (!std.mem.startsWith(u8, r, "cluster:")) return error.InvalidSource;
            start_cluster = std.fmt.parseInt(u32, r["cluster:".len..], 10) catch return error.InvalidSource;
        }

        var run_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer run_arena.deinit();
        const file = Io.Dir.cwd().openFile(self.io, self.path, .{}) catch return error.InvalidSource;
        defer file.close(self.io);
        var zim = Zim.open(run_arena.allocator(), self.io, file) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSource,
        };

        // 1. The directory: which entries are articles, and in which cluster.
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(self.gpa);
        var meta = Metadata{};
        zim.scanDirectory(self.gpa, run_arena.allocator(), &items, &meta, control) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Cancelled => return self.stopped(start_cluster),
            else => return error.SourceFailed,
        };
        std.mem.sort(Item, items.items, {}, itemLess);

        // 2. Cluster by cluster.
        var cluster_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer cluster_arena.deinit();
        var zstd_buf: ?[]u8 = null;
        defer if (zstd_buf) |b| self.gpa.free(b);

        var i: usize = 0;
        var since: u32 = 0;
        while (i < items.items.len) {
            const cluster = items.items[i].cluster;
            var j = i;
            while (j < items.items.len and items.items[j].cluster == cluster) j += 1;
            const group = items.items[i..j];
            i = j;
            if (cluster < start_cluster) continue;
            if (control.isCancelled()) return self.stopped(cluster);
            control.setProgress(cluster, zim.cluster_count);

            _ = cluster_arena.reset(.retain_capacity);
            const a = cluster_arena.allocator();
            const blobs = zim.loadCluster(a, self.gpa, &zstd_buf, cluster, self.max_cluster_bytes) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    for (group) |_| control.reject(.encoding);
                    continue;
                },
            };
            for (group) |item| {
                switch (try self.handleItem(a, &zim, &meta, blobs, item, sink, control)) {
                    .ok => {},
                    .stopped => return self.stopped(cluster),
                }
            }
            since += 1;
            if (since >= checkpoint_every_clusters) {
                since = 0;
                const pos = self.setCheckpoint(cluster + 1);
                sink.checkpoint(pos) catch |e| switch (e) {
                    error.Stopped => return self.stopped(cluster + 1),
                    else => return error.SourceFailed,
                };
            }
        }
        return .{};
    }

    const Handled = enum { ok, stopped };

    fn handleItem(self: *ZimConnector, a: Allocator, zim: *Zim, meta: *const Metadata, blobs: Blobs, item: Item, sink: api.Sink, control: *api.Control) error{OutOfMemory}!Handled {
        if (item.blob >= blobs.count) {
            control.reject(.limit);
            return .ok;
        }
        const raw = blobs.get(item.blob);
        if (raw.len == 0) return .ok;
        if (raw.len > self.max_article_bytes) {
            control.reject(.too_large);
            return .ok;
        }
        if (!std.unicode.utf8ValidateSlice(raw)) {
            control.reject(.encoding);
            return .ok;
        }
        var ebuf: [max_entry_read]u8 = undefined;
        const entry = (zim.readEntry(item.entry, &ebuf)) orelse {
            control.reject(.limit);
            return .ok;
        };
        const mime = zim.mimeOf(entry.mime);
        const is_html = std.mem.startsWith(u8, mime, "text/html") or std.mem.startsWith(u8, mime, "application/xhtml");
        const text = if (is_html) try htmltext.toText(a, raw) else std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0) {
            control.reject(.no_text);
            return .ok;
        }
        var title: ?[]const u8 = null;
        if (entry.title.len > 0) {
            title = entry.title;
        } else if (is_html) {
            title = try htmltext.titleOf(a, raw);
        }
        if (title == null) title = entry.url;

        const url: ?[]const u8 = if (self.url_base) |base| try urlFor(a, base, entry.url) else null;
        const d: doc.Document = .{
            .connector = self.name,
            .source_id = entry.url,
            .source_dataset = meta.title,
            .canonical_url = url,
            .title = title,
            .text = text,
            .language = self.language,
            .content_type = if (is_html) "text/html" else "text/plain",
            .rights = .{
                .attribution = if (meta.title) |t| try std.fmt.allocPrint(a, "From the ZIM file \"{s}\"", .{t}) else "From a ZIM file",
                .access_notes = "Content packaged by the Kiwix project from its original sources, which have their own licences (often CC BY-SA); check the file's metadata.",
                .redistribution = .unknown,
            },
        };
        sink.submit(d) catch |e| switch (e) {
            error.Rejected => return .ok, // the pipeline counts it
            error.Stopped => return .stopped,
            error.OutOfMemory => return error.OutOfMemory,
        };
        _ = control.submitted.fetchAdd(1, .monotonic);
        return .ok;
    }
};

/// `base` + the path, with every byte outside the URL-safe set percent-encoded
/// (a slash stays, so nested paths keep their shape).
fn urlFor(a: Allocator, base: []const u8, path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, base);
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~' or ch == '/') {
            try out.append(a, ch);
        } else {
            try out.append(a, '%');
            try out.append(a, hex[ch >> 4]);
            try out.append(a, hex[ch & 15]);
        }
    }
    return out.items;
}

const Item = struct { cluster: u32, blob: u32, entry: u32 };

fn itemLess(_: void, x: Item, y: Item) bool {
    if (x.cluster != y.cluster) return x.cluster < y.cluster;
    if (x.blob != y.blob) return x.blob < y.blob;
    return x.entry < y.entry;
}

/// The few metadata values worth recording on documents.
const Metadata = struct {
    title: ?[]const u8 = null,
};

const Entry = struct {
    mime: u16,
    namespace: u8,
    /// False for redirects, link targets and deleted entries.
    content: bool,
    cluster: u32,
    blob: u32,
    url: []const u8,
    title: []const u8,
};

/// The directory entry at the start of `buf` (as much of it as was read).
fn parseEntry(buf: []const u8) ?Entry {
    if (buf.len < 12) return null;
    const mime = std.mem.readInt(u16, buf[0..2], .little);
    const ns = buf[3];
    var e: Entry = .{ .mime = mime, .namespace = ns, .content = false, .cluster = 0, .blob = 0, .url = "", .title = "" };
    var url_at: usize = 0;
    if (mime == 0xFFFF) {
        url_at = 12; // redirect: index at 8
    } else if (mime == 0xFFFE or mime == 0xFFFD) {
        url_at = 8; // link target or deleted
    } else {
        if (buf.len < 16) return null;
        e.content = true;
        e.cluster = std.mem.readInt(u32, buf[8..12], .little);
        e.blob = std.mem.readInt(u32, buf[12..16], .little);
        url_at = 16;
    }
    if (url_at >= buf.len) return null;
    const url_end = std.mem.indexOfScalarPos(u8, buf, url_at, 0) orelse return null;
    if (url_end - url_at > max_url_len) return null;
    e.url = buf[url_at..url_end];
    const title_at = url_end + 1;
    if (title_at > buf.len) return null;
    const title_end = std.mem.indexOfScalarPos(u8, buf, title_at, 0) orelse buf.len;
    e.title = buf[title_at..title_end];
    return e;
}

const Blobs = struct {
    data: []const u8,
    /// Offsets of blob i are offs[i]..offs[i+1], `count` blobs.
    offsets: []const u64,
    count: u32,

    fn get(self: Blobs, i: u32) []const u8 {
        return self.data[self.offsets[i]..self.offsets[i + 1]];
    }
};

const Zim = struct {
    file: Io.File,
    io: Io,
    size: u64,
    entry_count: u32,
    cluster_count: u32,
    url_ptr_pos: u64,
    cluster_ptr_pos: u64,
    checksum_pos: u64,
    mimes: [][]const u8,

    const OpenError = error{ OutOfMemory, NotZim, Unsupported, Damaged, Io };

    fn open(a: Allocator, io: Io, file: Io.File) OpenError!Zim {
        const size = file.length(io) catch return error.Io;
        if (size < header_len) return error.NotZim;
        var h: [header_len]u8 = undefined;
        if ((preadAll(file, io, &h, 0) catch return error.Io) < header_len) return error.NotZim;
        if (std.mem.readInt(u32, h[0..4], .little) != zim_magic) return error.NotZim;
        const major = std.mem.readInt(u16, h[4..6], .little);
        if (major != 5 and major != 6) return error.Unsupported;
        var z: Zim = .{
            .file = file,
            .io = io,
            .size = size,
            .entry_count = std.mem.readInt(u32, h[24..28], .little),
            .cluster_count = std.mem.readInt(u32, h[28..32], .little),
            .url_ptr_pos = std.mem.readInt(u64, h[32..40], .little),
            .cluster_ptr_pos = std.mem.readInt(u64, h[48..56], .little),
            .checksum_pos = std.mem.readInt(u64, h[72..80], .little),
            .mimes = &.{},
        };
        const mime_pos = std.mem.readInt(u64, h[56..64], .little);
        // The pointer tables must lie inside the file.
        if (z.url_ptr_pos + 8 * @as(u64, z.entry_count) > size) return error.Damaged;
        if (z.cluster_ptr_pos + 8 * @as(u64, z.cluster_count) > size) return error.Damaged;
        if (mime_pos >= size) return error.Damaged;

        // The MIME type list: NUL-terminated names ending with an empty one.
        const want: usize = @intCast(@min(size - mime_pos, 64 * 1024));
        const buf = try a.alloc(u8, want);
        const got = preadAll(file, io, buf, mime_pos) catch return error.Io;
        var list: std.ArrayList([]const u8) = .empty;
        var at: usize = 0;
        while (at < got) {
            const end = std.mem.indexOfScalarPos(u8, buf[0..got], at, 0) orelse break;
            if (end == at) break;
            try list.append(a, buf[at..end]);
            at = end + 1;
            if (list.items.len > 4096) return error.Damaged;
        }
        z.mimes = list.items;
        return z;
    }

    fn mimeOf(self: *const Zim, idx: u16) []const u8 {
        return if (idx < self.mimes.len) self.mimes[idx] else "";
    }

    fn entryOffset(self: *const Zim, i: u32) ?u64 {
        var b: [8]u8 = undefined;
        const n = preadAll(self.file, self.io, &b, self.url_ptr_pos + 8 * @as(u64, i)) catch return null;
        if (n < 8) return null;
        const off = std.mem.readInt(u64, &b, .little);
        return if (off < self.size) off else null;
    }

    /// Entry `i`; the strings point into `buf`.
    fn readEntry(self: *const Zim, i: u32, buf: *[max_entry_read]u8) ?Entry {
        const off = self.entryOffset(i) orelse return null;
        const n = preadAll(self.file, self.io, buf, off) catch return null;
        return parseEntry(buf[0..n]);
    }

    const ScanError = error{ OutOfMemory, Cancelled, Io };

    /// Collects every article entry (as cluster, blob and entry number) and the
    /// metadata, reading the directory in order.
    fn scanDirectory(self: *const Zim, gpa: Allocator, keep: Allocator, items: *std.ArrayList(Item), meta: *Metadata, control: *api.Control) ScanError!void {
        var i: u32 = 0;
        var buf: [max_entry_read]u8 = undefined;
        while (i < self.entry_count) : (i += 1) {
            if (i % 4096 == 0) {
                if (control.isCancelled()) return error.Cancelled;
                control.setProgress(i, @as(u64, self.entry_count) * 2); // the scan is the first half of the work
            }
            const e = self.readEntry(i, &buf) orelse continue;
            if (!e.content) continue;
            const ns_new = e.namespace == 'C';
            const ns_old = e.namespace == 'A';
            if (e.namespace == 'M' and std.mem.eql(u8, e.url, "Title") and meta.title == null) {
                meta.title = self.readBlobText(gpa, keep, e) catch null;
                continue;
            }
            if (!ns_new and !ns_old) continue;
            const mime = self.mimeOf(e.mime);
            if (!(std.mem.startsWith(u8, mime, "text/html") or std.mem.startsWith(u8, mime, "application/xhtml") or std.mem.startsWith(u8, mime, "text/plain"))) continue;
            if (e.cluster >= self.cluster_count) continue;
            try items.append(gpa, .{ .cluster = e.cluster, .blob = e.blob, .entry = i });
        }
    }

    /// The text of a small metadata entry (its value is its blob), copied into `keep`.
    fn readBlobText(self: *const Zim, gpa: Allocator, keep: Allocator, e: Entry) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var zstd_buf: ?[]u8 = null;
        defer if (zstd_buf) |b| gpa.free(b);
        const blobs = try self.loadCluster(arena.allocator(), gpa, &zstd_buf, e.cluster, 1 << 20);
        if (e.blob >= blobs.count) return error.Damaged;
        const v = blobs.get(e.blob);
        if (v.len == 0 or v.len > 256) return error.Damaged;
        return keep.dupe(u8, v);
    }

    const LoadError = error{ OutOfMemory, Damaged, Unsupported, TooBig, Io };

    /// Reads and decompresses cluster `c` into `a`.
    fn loadCluster(self: *const Zim, a: Allocator, gpa: Allocator, zstd_buf: *?[]u8, c: u32, max_bytes: u32) LoadError!Blobs {
        if (c >= self.cluster_count) return error.Damaged;
        var pb: [16]u8 = undefined;
        const have = preadAll(self.file, self.io, pb[0..8], self.cluster_ptr_pos + 8 * @as(u64, c)) catch return error.Io;
        if (have < 8) return error.Damaged;
        const start = std.mem.readInt(u64, pb[0..8], .little);
        var end: u64 = self.checksum_pos;
        if (c + 1 < self.cluster_count) {
            const h2 = preadAll(self.file, self.io, pb[8..16], self.cluster_ptr_pos + 8 * @as(u64, c + 1)) catch return error.Io;
            if (h2 < 8) return error.Damaged;
            end = std.mem.readInt(u64, pb[8..16], .little);
        }
        if (end > self.size or end <= start + 1 or start >= self.size) return error.Damaged;
        const len = end - start;
        // A cluster's compressed form is never larger than its limit plus a little.
        if (len > @as(u64, max_bytes) + 1024) return error.TooBig;
        const raw = try a.alloc(u8, @intCast(len));
        const got = preadAll(self.file, self.io, raw, start) catch return error.Io;
        if (got != raw.len) return error.Damaged;

        const kind_byte = raw[0];
        const extended = (kind_byte & 0x10) != 0;
        const data: []const u8 = switch (kind_byte & 0x0F) {
            0, 1 => raw[1..],
            4 => blk: {
                var in: std.Io.Reader = .fixed(raw[1..]);
                // The decoder owns this (empty) buffer from here on and grows it with `gpa`.
                const initial = try gpa.alloc(u8, 0);
                var d = std.compress.xz.Decompress.init(&in, gpa, initial) catch {
                    gpa.free(initial);
                    return error.Damaged;
                };
                defer d.deinit();
                break :blk d.reader.allocRemaining(a, .limited(max_bytes)) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.StreamTooLong => return error.TooBig,
                    else => return error.Damaged,
                };
            },
            5 => blk: {
                const win = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;
                if (zstd_buf.* == null) zstd_buf.* = try gpa.alloc(u8, win);
                var in: std.Io.Reader = .fixed(raw[1..]);
                var d = std.compress.zstd.Decompress.init(&in, zstd_buf.*.?, .{});
                break :blk d.reader.allocRemaining(a, .limited(max_bytes)) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.StreamTooLong => return error.TooBig,
                    else => return error.Damaged,
                };
            },
            else => return error.Unsupported,
        };

        // The offset table: one more offset than there are blobs.
        const w: usize = if (extended) 8 else 4;
        if (data.len < w) return error.Damaged;
        const first = readOffset(data, 0, w);
        if (first < w or first % w != 0 or first > data.len) return error.Damaged;
        const count: usize = @intCast(first / w - 1);
        if (count == 0 or count > (1 << 24)) return error.Damaged;
        const offs = try a.alloc(u64, count + 1);
        var prev: u64 = first;
        for (0..count + 1) |k| {
            const o = readOffset(data, k * w, w);
            if (o < prev and k > 0) return error.Damaged;
            if (o > data.len) return error.Damaged;
            offs[k] = o;
            prev = o;
        }
        return .{ .data = data, .offsets = offs, .count = @intCast(count) };
    }
};

fn readOffset(data: []const u8, at: usize, w: usize) u64 {
    return if (w == 8) std.mem.readInt(u64, data[at..][0..8], .little) else std.mem.readInt(u32, data[at..][0..4], .little);
}

/// Fills `buf` from `pos`, returning how many bytes were there.
fn preadAll(file: Io.File, io: Io, buf: []u8, pos: u64) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        var bufs = [_][]u8{buf[total..]};
        const n = try file.readPositional(io, &bufs, pos + total);
        if (n == 0) break;
        total += n;
    }
    return total;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const nettest = @import("nettest.zig");
const sample = @embedFile("testdata/zim/sample.zim");

fn zimSource(path: []const u8, extra: []const config.Option) !ZimConnector {
    var opts: std.ArrayList(config.Option) = .empty;
    defer opts.deinit(testing.allocator);
    try opts.append(testing.allocator, .{ .key = "path", .value = .{ .string = path } });
    for (extra) |e| try opts.append(testing.allocator, e);
    return ZimConnector.init(testing.allocator, testing.io, .{ .name = "kiwix", .kind = "zim", .options = opts.items });
}

fn writeSample(tmp: *testing.TmpDir, name: []const u8, bytes: []const u8, buf: []u8) ![]const u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "validate: path is required; options are checked" {
    var d: config.Diagnostic = .{};
    const ok = [_]config.Option{.{ .key = "path", .value = .{ .string = "x.zim" } }};
    try validate(.{ .name = "z", .kind = "zim", .options = &ok }, &d);
    try testing.expectError(error.InvalidValue, validate(.{ .name = "z", .kind = "zim" }, &d));
    try testing.expectEqualStrings("source[z].path", d.key());
    const bad_url = ok ++ [_]config.Option{.{ .key = "url_base", .value = .{ .string = "ftp://x/" } }};
    try testing.expectError(error.InvalidValue, validate(.{ .name = "z", .kind = "zim", .options = &bad_url }, &d));
    const unknown = ok ++ [_]config.Option{.{ .key = "dump", .value = .{ .string = "x" } }};
    try testing.expectError(error.UnknownKey, validate(.{ .name = "z", .kind = "zim", .options = &unknown }, &d));
    const huge = ok ++ [_]config.Option{.{ .key = "max_article_bytes", .value = .{ .integer = 1 << 40 } }};
    try testing.expectError(error.InvalidValue, validate(.{ .name = "z", .kind = "zim", .options = &huge }, &d));
}

test "reads articles from xz, plain and zstd clusters; skips redirects, images and metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const path = try writeSample(&tmp, "sample.zim", sample, &pb);
    var conn = try zimSource(path, &.{
        .{ .key = "url_base", .value = .{ .string = "http://localhost:8080/content/sample_sea/" } },
        .{ .key = "language", .value = .{ .string = "en" } },
    });
    defer conn.deinit();
    var got: nettest.Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    const out = try conn.connector().run(got.sink(), &ctl, null);
    try testing.expect(!out.interrupted);

    // Lighthouse, Harbour, Zeppelin (xz cluster) and notes.txt (plain cluster); not the PNG,
    // the redirect, or the metadata entries.
    try testing.expectEqual(@as(usize, 4), got.ids.items.len);
    try testing.expectEqual(@as(u64, 4), ctl.submitted.load(.monotonic));
    var found: [4]bool = @splat(false);
    for (got.ids.items, got.titles.items, got.texts.items) |id, title, text| {
        if (std.mem.eql(u8, id, "Lighthouse")) {
            found[0] = true;
            try testing.expectEqualStrings("Lighthouse", title);
            try testing.expect(std.mem.indexOf(u8, text, "polished the lens") != null);
            try testing.expect(std.mem.indexOf(u8, text, "wick & polished") != null); // entities decoded
            try testing.expect(std.mem.indexOf(u8, text, "ignored") == null); // script removed
        } else if (std.mem.eql(u8, id, "Harbour")) {
            found[1] = true;
            try testing.expectEqualStrings("Harbour", title); // from the page's <title>
        } else if (std.mem.eql(u8, id, "Zeppelin")) {
            found[2] = true;
            try testing.expectEqualStrings("Zeppelin (airship)", title); // the entry's own title wins
            try testing.expect(std.mem.indexOf(u8, text, "Caf\u{e9} menus") != null);
        } else if (std.mem.eql(u8, id, "notes.txt")) {
            found[3] = true;
            try testing.expectEqualStrings("Tide notes", title);
            try testing.expect(std.mem.indexOf(u8, text, "Spring tides") != null);
        }
    }
    for (found) |f| try testing.expect(f);
}

test "the zstd cluster is read (it holds only metadata and an image: nothing indexed from it)" {
    // The sample's zstd cluster holds the metadata blobs; reading it must work and not crash.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const path = try writeSample(&tmp, "sample.zim", sample, &pb);
    const file = try Io.Dir.cwd().openFile(testing.io, path, .{});
    defer file.close(testing.io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var z = try Zim.open(arena.allocator(), testing.io, file);
    var zbuf: ?[]u8 = null;
    defer if (zbuf) |b| testing.allocator.free(b);
    const blobs = try z.loadCluster(arena.allocator(), testing.allocator, &zbuf, 2, 1 << 20);
    try testing.expectEqual(@as(u32, 3), blobs.count);
    try testing.expectEqualStrings("Sample Sea Library", blobs.get(0));
    try testing.expectEqualStrings("eng", blobs.get(1));
}

test "the library name from the metadata is recorded as the dataset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const path = try writeSample(&tmp, "sample.zim", sample, &pb);
    var conn = try zimSource(path, &.{});
    defer conn.deinit();
    const Spy = struct {
        saw_dataset: bool = false,
        saw_url: bool = false,
        fn submit(ptr: *anyopaque, d: doc.Document) api.Sink.Error!void {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            if (d.source_dataset != null and std.mem.eql(u8, d.source_dataset.?, "Sample Sea Library")) s.saw_dataset = true;
            if (d.canonical_url != null) s.saw_url = true;
        }
    };
    var spy: Spy = .{};
    var ctl: api.Control = .{};
    _ = try conn.connector().run(.{ .ptr = &spy, .vtable = &.{ .submit = Spy.submit } }, &ctl, null);
    try testing.expect(spy.saw_dataset);
    try testing.expect(!spy.saw_url); // no url_base configured: no links
}

test "urlFor encodes unsafe bytes and keeps slashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("http://x/c/A%20b%C3%A9/d.html", try urlFor(arena.allocator(), "http://x/c/", "A b\u{e9}/d.html"));
}

test "resume continues after the saved cluster, and cancel reports one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    const path = try writeSample(&tmp, "sample.zim", sample, &pb);
    var conn = try zimSource(path, &.{});
    defer conn.deinit();
    var got: nettest.Collect = .{};
    defer got.deinit();
    var ctl: api.Control = .{};
    // From cluster 1 on: only notes.txt (cluster 1) is left; the xz cluster 0 is done.
    _ = try conn.connector().run(got.sink(), &ctl, "cluster:1");
    try testing.expectEqual(@as(usize, 1), got.ids.items.len);
    try testing.expectEqualStrings("notes.txt", got.ids.items[0]);
    try testing.expectError(error.InvalidSource, conn.connector().run(got.sink(), &ctl, "bz2:5"));
    var ctl2: api.Control = .{};
    ctl2.cancel();
    const out = try conn.connector().run(got.sink(), &ctl2, null);
    try testing.expect(out.interrupted);
}

test "files that are not ZIM, truncated or damaged fail cleanly and never crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [200]u8 = undefined;
    var got: nettest.Collect = .{};
    defer got.deinit();

    // Not a ZIM at all; a missing file; an empty one.
    for ([_][]const u8{ "plainly not a zim file", "" }) |bytes| {
        const p = try writeSample(&tmp, "bad.zim", bytes, &pb);
        var conn = try zimSource(p, &.{});
        defer conn.deinit();
        var ctl: api.Control = .{};
        try testing.expectError(error.InvalidSource, conn.connector().run(got.sink(), &ctl, null));
    }
    {
        var conn = try zimSource("/nonexistent/x.zim", &.{});
        defer conn.deinit();
        var ctl: api.Control = .{};
        try testing.expectError(error.InvalidSource, conn.connector().run(got.sink(), &ctl, null));
    }

    // Truncated and randomly damaged copies of a real one: any outcome but a crash.
    var prng = std.Random.DefaultPrng.init(0x21a);
    const rnd = prng.random();
    var copy: [sample.len]u8 = undefined;
    for (0..300) |round| {
        @memcpy(&copy, sample);
        var len: usize = copy.len;
        if (round % 4 == 0) {
            len = rnd.uintLessThan(usize, copy.len);
        } else {
            for (0..1 + rnd.uintLessThan(usize, 8)) |_| copy[rnd.uintLessThan(usize, copy.len)] = rnd.int(u8);
        }
        const p = try writeSample(&tmp, "dmg.zim", copy[0..len], &pb);
        var conn = try zimSource(p, &.{});
        defer conn.deinit();
        var g: nettest.Collect = .{};
        defer g.deinit();
        var ctl: api.Control = .{};
        if (conn.connector().run(g.sink(), &ctl, null)) |_| {} else |_| {}
    }
}
