//! The feeds connector (docs/decisions/0016): RSS 2.0, RSS 1.0 (RDF) and
//! Atom 1.0 files that the administrator has already downloaded. It never
//! uses the network; fetching feeds (for example with a scheduled `curl`
//! into a directory) is a separate step, so the connector cannot become a
//! crawler.
//!
//! `path` is one feed file or a directory of them (extensions `.xml`, `.rss`,
//! `.atom`, `.rdf`; hidden entries and symbolic links skipped), read in sorted
//! order. Each entry becomes a document. Entry bodies are usually HTML and are
//! converted to plain text.
//!
//! Options:
//!   path            required: a feed file, or a directory of feed files
//!   language        optional: language tag for every entry (default: the feed's own)
//!   max_file_bytes  optional: largest feed file accepted, 1 to 67108864 (default 16777216)
//!
//! A feed that cannot be parsed (not XML, truncated, a DOCTYPE) is counted as
//! rejected and the run goes on with the next file; entries with neither an id
//! nor a link, or with no text at all, are counted as rejected too. The resume
//! position is the last finished file name.
//!
//! The document id is the entry's id (`guid` or Atom `id`), or its link if it
//! has none; an id that is not URL-like is prefixed with the feed's link so
//! that two feeds using "1" and "2" do not collide. Re-fetching a feed into the
//! same file updates entries whose text changed and skips the rest.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const api = @import("../connector.zig");
const doc = @import("../document.zig");
const files = @import("files.zig");
const xml = @import("../xml.zig");
const htmltext = @import("feeds/htmltext.zig");
const dates = @import("feeds/dates.zig");

pub const kind = "feeds";
pub const default_max_file_bytes: u32 = 16 * 1024 * 1024;
pub const hard_max_file_bytes: u32 = 64 * 1024 * 1024;
const checkpoint_every = 20;
const max_depth = 48;
const small_cap = 4096;
const text_cap = 1024 * 1024;
const allowed_options = [_][]const u8{ "path", "language", "max_file_bytes" };
const extensions = [_][]const u8{ ".xml", ".rss", ".atom", ".rdf" };

pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    var kbuf: [128]u8 = undefined;
    for (source.options) |o| {
        var known = false;
        for (allowed_options) |k| {
            if (std.mem.eql(u8, k, o.key)) known = true;
        }
        if (!known) {
            diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].{s}", .{ source.name, o.key }) catch o.key, "unknown option for kind \"feeds\"", .{});
            return error.UnknownKey;
        }
    }
    const path_key = std.fmt.bufPrint(&kbuf, "source[{s}].path", .{source.name}) catch "path";
    switch (source.option("path") orelse {
        diag.set("", path_key, "is required for kind \"feeds\"", .{});
        return error.InvalidValue;
    }) {
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

pub const FeedsConnector = struct {
    gpa: Allocator,
    io: Io,
    name: []const u8,
    root: []const u8,
    language: ?[]const u8,
    max_file_bytes: u32,
    checkpoint_buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!FeedsConnector {
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
            .language = language,
            .max_file_bytes = @intCast(source.optionInt("max_file_bytes") orelse default_max_file_bytes),
        };
    }

    pub fn deinit(self: *FeedsConnector) void {
        self.gpa.free(self.name);
        self.gpa.free(self.root);
        if (self.language) |l| self.gpa.free(l);
        self.checkpoint_buf.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn connector(self: *FeedsConnector) api.Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run } };
    }

    fn info(_: *anyopaque) api.Info {
        return .{ .kind = kind, .requires_network = false, .resumable = true };
    }

    fn run(ptr: *anyopaque, sink: api.Sink, control: *api.Control, resume_from: ?[]const u8) api.RunError!api.Outcome {
        const self: *FeedsConnector = @ptrCast(@alignCast(ptr));
        const io = self.io;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // `path` is a directory of feeds or a single feed file.
        const st = Io.Dir.cwd().statFile(io, self.root, .{}) catch return error.InvalidSource;
        var dir: Io.Dir = undefined;
        var close_dir = false;
        var paths: [][]const u8 = undefined;
        if (st.kind == .directory) {
            dir = Io.Dir.cwd().openDir(io, self.root, .{ .iterate = true }) catch return error.InvalidSource;
            close_dir = true;
            paths = collect(arena, io, dir) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SourceFailed,
            };
        } else if (st.kind == .file) {
            const parent = std.fs.path.dirname(self.root) orelse ".";
            dir = Io.Dir.cwd().openDir(io, parent, .{}) catch return error.InvalidSource;
            close_dir = true;
            const one = arena.alloc([]const u8, 1) catch return error.OutOfMemory;
            one[0] = std.fs.path.basename(self.root);
            paths = one;
        } else return error.InvalidSource;
        defer if (close_dir) dir.close(io);
        std.mem.sort([]const u8, paths, {}, lessThan);

        // File contents live only while their file is parsed.
        var bytes_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer bytes_arena.deinit();
        const single = st.kind == .file;

        var done: ?[]const u8 = null;
        var since: u32 = 0;
        for (paths) |rel| {
            if (resume_from) |r| if (!std.mem.lessThan(u8, r, rel)) continue;
            if (control.isCancelled()) return self.stopped(done);

            _ = bytes_arena.reset(.free_all);
            switch (self.readFile(bytes_arena.allocator(), dir, rel, single)) {
                .out_of_memory => return error.OutOfMemory,
                .refused => _ = control.rejected.fetchAdd(1, .monotonic),
                .bytes => |data| {
                    switch (self.parseFeed(rel, data, sink, control)) {
                        .ok => {},
                        .bad_feed => _ = control.rejected.fetchAdd(1, .monotonic),
                        .stopped => return self.stopped(done),
                        .out_of_memory => return error.OutOfMemory,
                    }
                },
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

    fn stopped(self: *FeedsConnector, done: ?[]const u8) api.Outcome {
        const d = done orelse return .{ .interrupted = true };
        self.checkpoint_buf.clearRetainingCapacity();
        self.checkpoint_buf.appendSlice(self.gpa, d) catch return .{ .interrupted = true };
        return .{ .interrupted = true, .checkpoint = self.checkpoint_buf.items };
    }

    const Read = union(enum) { bytes: []const u8, refused, out_of_memory };

    /// `named` is true when the administrator named this very file as `path`,
    /// in which case a symbolic link is followed; files found while walking a
    /// directory are never links.
    fn readFile(self: *FeedsConnector, arena: Allocator, dir: Io.Dir, rel: []const u8, named: bool) Read {
        const st = dir.statFile(self.io, rel, .{ .follow_symlinks = named }) catch return .refused;
        if (st.kind != .file or st.size > self.max_file_bytes) return .refused;
        const data = dir.readFileAlloc(self.io, rel, arena, .limited(self.max_file_bytes + 1)) catch |e| switch (e) {
            error.OutOfMemory => return .out_of_memory,
            else => return .refused,
        };
        if (data.len > self.max_file_bytes) return .refused;
        return .{ .bytes = data };
    }

    const Parsed = enum { ok, bad_feed, stopped, out_of_memory };

    fn parseFeed(self: *FeedsConnector, rel: []const u8, data: []const u8, sink: api.Sink, control: *api.Control) Parsed {
        var file_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer file_arena.deinit();
        var entry_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer entry_arena.deinit();
        var h: FeedHandler = .{ .conn = self, .sink = sink, .control = control, .rel = rel, .file_arena = &file_arena, .entry_arena = &entry_arena };
        var parser: xml.Parser(FeedHandler) = undefined;
        parser.init(&h) catch return .out_of_memory;
        defer parser.deinit();
        parser.feed(data, true) catch |e| {
            if (h.fail) |f| return switch (f) {
                .stopped => .stopped,
                .out_of_memory => .out_of_memory,
                .too_deep => .bad_feed,
            };
            return switch (e) {
                error.OutOfMemory => .out_of_memory,
                else => .bad_feed,
            };
        };
        if (h.fail) |f| return switch (f) {
            .stopped => .stopped,
            .out_of_memory => .out_of_memory,
            .too_deep => .bad_feed,
        };
        return .ok;
    }
};

fn collect(arena: Allocator, io: Io, dir: Io.Dir) ![][]const u8 {
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.basename.len == 0 or entry.basename[0] == '.') continue;
        switch (entry.kind) {
            .directory => try walker.enter(io, entry),
            .file => for (extensions) |ext| {
                if (std.ascii.endsWithIgnoreCase(entry.path, ext)) {
                    try list.append(arena, try arena.dupe(u8, entry.path));
                    break;
                }
            },
            else => {},
        }
    }
    return list.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Fail = enum { stopped, out_of_memory, too_deep };

const Field = enum { title, link, id, summary, content, published, updated, author, category, feed_title, feed_language, feed_link };

/// Follows a feed's structure and submits each entry as it ends.
const FeedHandler = struct {
    conn: *FeedsConnector,
    sink: api.Sink,
    control: *api.Control,
    rel: []const u8,
    file_arena: *std.heap.ArenaAllocator,
    entry_arena: *std.heap.ArenaAllocator,

    depth: u32 = 0,
    /// Depth of the direct children of the feed's channel (RSS) or root (Atom).
    feed_child_depth: u32 = 0,
    /// Inside the channel (RSS) or the feed root (Atom): feed-level fields
    /// are read only there, not from siblings such as RSS 1.0 `image`.
    in_channel: bool = false,
    in_entry: bool = false,
    entry_depth: u32 = 0,
    in_author: bool = false,
    capture: ?Field = null,
    capture_depth: u32 = 0,
    fail: ?Fail = null,

    feed_title: std.ArrayList(u8) = .empty,
    feed_language: std.ArrayList(u8) = .empty,
    feed_link: std.ArrayList(u8) = .empty,

    title: std.ArrayList(u8) = .empty,
    link: std.ArrayList(u8) = .empty,
    id: std.ArrayList(u8) = .empty,
    summary: std.ArrayList(u8) = .empty,
    content: std.ArrayList(u8) = .empty,
    published: std.ArrayList(u8) = .empty,
    updated: std.ArrayList(u8) = .empty,
    author: std.ArrayList(u8) = .empty,
    categories: std.ArrayList([]const u8) = .empty,
    /// Atom `type="text"` bodies are not HTML.
    summary_is_text: bool = false,
    content_is_text: bool = false,
    entry_count: u32 = 0,
    /// Text of the `<category>` element being read.
    scratch: std.ArrayList(u8) = .empty,
    /// The captured field reached its size cap: the rest of it is ignored, so
    /// a long field keeps its beginning rather than a spliced remainder.
    overflow: bool = false,

    const P = xml.Parser(FeedHandler);

    fn list(self: *FeedHandler, f: Field) *std.ArrayList(u8) {
        return switch (f) {
            .title => &self.title,
            .link => &self.link,
            .id => &self.id,
            .summary => &self.summary,
            .content => &self.content,
            .published => &self.published,
            .updated => &self.updated,
            .author => &self.author,
            .category => &self.title, // handled separately; never appended here
            .feed_title => &self.feed_title,
            .feed_language => &self.feed_language,
            .feed_link => &self.feed_link,
        };
    }

    fn arenaFor(self: *FeedHandler, f: Field) Allocator {
        return switch (f) {
            .feed_title, .feed_language, .feed_link => self.file_arena.allocator(),
            else => self.entry_arena.allocator(),
        };
    }

    fn eq(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn startElement(self: *FeedHandler, p: *P, name: []const u8, attrs: xml.Attrs) void {
        if (self.fail != null) return;
        self.depth += 1;
        if (self.depth > max_depth) return self.abort(p, .too_deep);

        // Inside a captured element (XHTML content has child elements): text
        // continues, with a line break at each nested element.
        if (self.capture) |f| {
            if ((f == .content or f == .summary) and self.list(f).items.len < text_cap) {
                self.list(f).append(self.arenaFor(f), '\n') catch return self.abort(p, .out_of_memory);
            }
            return;
        }

        if (!self.in_entry) {
            if (self.depth == 1) {
                self.feed_child_depth = if (eq(name, "feed")) 2 else 3; // rss/channel/x, rdf:RDF/channel/x
                self.in_channel = eq(name, "feed");
                if (attrs.get("xml:lang")) |l| self.setText(.feed_language, l); // Atom declares its language here
                return;
            }
            if (self.depth == 2 and self.feed_child_depth == 3) self.in_channel = eq(name, "channel");
            if (eq(name, "item") or eq(name, "entry")) return self.beginEntry();
            if (self.in_channel and self.depth == self.feed_child_depth) {
                if (eq(name, "title")) return self.start(.feed_title);
                if (eq(name, "language")) return self.start(.feed_language);
                if (eq(name, "link")) {
                    if (attrs.get("href")) |href| {
                        const rel = attrs.get("rel");
                        if (rel == null or eq(rel.?, "alternate")) self.setText(.feed_link, href);
                    } else self.start(.feed_link);
                }
            }
            return;
        }

        if (self.depth == self.entry_depth + 1) {
            if (eq(name, "title")) return self.start(.title);
            if (eq(name, "link")) {
                if (attrs.get("href")) |href| {
                    const rel = attrs.get("rel");
                    if (rel == null or eq(rel.?, "alternate")) self.setText(.link, href);
                } else self.start(.link);
                return;
            }
            if (eq(name, "guid") or eq(name, "id")) return self.start(.id);
            if (eq(name, "description") or eq(name, "summary")) {
                self.summary_is_text = if (attrs.get("type")) |t| eq(t, "text") else false;
                return self.start(.summary);
            }
            if (eq(name, "content:encoded") or eq(name, "content")) {
                self.content_is_text = if (attrs.get("type")) |t| eq(t, "text") else false;
                return self.start(.content);
            }
            if (eq(name, "pubDate") or eq(name, "published") or eq(name, "dc:date")) return self.start(.published);
            if (eq(name, "updated")) return self.start(.updated);
            if (eq(name, "dc:creator")) return self.start(.author);
            if (eq(name, "author")) {
                // Atom: <author><name>..</name></author>; RSS: <author>text</author>.
                if (self.feed_child_depth == 2) self.in_author = true else self.start(.author);
                return;
            }
            if (eq(name, "category")) {
                if (attrs.get("term")) |term| self.addCategory(term) else self.start(.category);
            }
            return;
        }
        if (self.in_author and self.depth == self.entry_depth + 2 and eq(name, "name")) self.start(.author);
    }

    fn start(self: *FeedHandler, f: Field) void {
        self.capture = f;
        self.capture_depth = self.depth;
        self.overflow = false;
        if (f == .category) self.scratch.clearRetainingCapacity() else self.list(f).clearRetainingCapacity();
    }

    /// For a field whose value comes from an attribute.
    fn setText(self: *FeedHandler, f: Field, value: []const u8) void {
        const l = self.list(f);
        l.clearRetainingCapacity();
        var n = @min(value.len, small_cap);
        while (n > 0 and n < value.len and (value[n] & 0xC0) == 0x80) n -= 1; // do not cut a character in half
        l.appendSlice(self.arenaFor(f), value[0..n]) catch {
            self.fail = .out_of_memory;
        };
    }

    fn addCategory(self: *FeedHandler, text: []const u8) void {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0 or t.len > 200 or self.categories.items.len >= 20) return;
        const a = self.entry_arena.allocator();
        const copy = a.dupe(u8, t) catch {
            self.fail = .out_of_memory;
            return;
        };
        self.categories.append(a, copy) catch {
            self.fail = .out_of_memory;
        };
    }

    fn beginEntry(self: *FeedHandler) void {
        _ = self.entry_arena.reset(.retain_capacity);
        self.title = .empty;
        self.link = .empty;
        self.id = .empty;
        self.summary = .empty;
        self.content = .empty;
        self.published = .empty;
        self.updated = .empty;
        self.author = .empty;
        self.categories = .empty;
        self.scratch = .empty;
        self.summary_is_text = false;
        self.content_is_text = false;
        self.in_entry = true;
        self.in_author = false;
        self.entry_depth = self.depth;
    }

    pub fn characters(self: *FeedHandler, p: *P, bytes: []const u8) void {
        _ = p;
        if (self.fail != null) return;
        const f = self.capture orelse return;
        const target = if (f == .category) &self.scratch else self.list(f);
        const cap: usize = if (f == .content or f == .summary) text_cap else small_cap;
        if (self.overflow) return;
        if (target.items.len + bytes.len > cap) {
            self.overflow = true; // an oversized field keeps its first part
            return;
        }
        target.appendSlice(self.arenaFor(f), bytes) catch {
            self.fail = .out_of_memory;
        };
    }

    pub fn endElement(self: *FeedHandler, p: *P, name: []const u8) void {
        if (self.fail != null) return;
        if (self.capture != null and self.depth == self.capture_depth) {
            if (self.capture == .category) self.addCategory(self.scratch.items);
            self.capture = null;
        }
        if (self.in_author and self.depth == self.entry_depth + 1 and eq(name, "author")) self.in_author = false;
        if (self.in_entry and self.depth == self.entry_depth) {
            self.in_entry = false;
            self.finishEntry(p);
        }
        self.depth -= 1;
    }

    fn abort(self: *FeedHandler, p: *P, why: Fail) void {
        self.fail = why;
        p.stop();
    }

    fn trimmed(l: std.ArrayList(u8)) []const u8 {
        return std.mem.trim(u8, l.items, " \t\r\n");
    }

    fn finishEntry(self: *FeedHandler, p: *P) void {
        if (self.control.isCancelled()) return self.abort(p, .stopped);
        const a = self.entry_arena.allocator();

        const raw_id = trimmed(self.id);
        const link = trimmed(self.link);
        const base_id = if (raw_id.len > 0) raw_id else link;
        if (base_id.len == 0) {
            _ = self.control.rejected.fetchAdd(1, .monotonic);
            return;
        }
        // An id that is not URL-like is only unique within its feed.
        const url_like = std.mem.indexOfAny(u8, base_id, ":/") != null;
        const feed_key = if (trimmed(self.feed_link).len > 0) trimmed(self.feed_link) else self.rel;
        const source_id = if (url_like)
            base_id
        else
            std.fmt.allocPrint(a, "{s}#{s}", .{ feed_key, base_id }) catch return self.abort(p, .out_of_memory);

        const title = (htmltext.toText(a, trimmed(self.title)) catch return self.abort(p, .out_of_memory));
        const title_one = collapse(a, title) catch return self.abort(p, .out_of_memory);

        // Body: the full content if there is one, else the summary, else the title.
        const body_raw = if (trimmed(self.content).len > 0) self.content.items else self.summary.items;
        const body_is_text = if (trimmed(self.content).len > 0) self.content_is_text else self.summary_is_text;
        var body: []const u8 = if (body_is_text) std.mem.trim(u8, body_raw, " \t\r\n") else (htmltext.toText(a, body_raw) catch return self.abort(p, .out_of_memory));
        if (body.len == 0) body = title_one;
        if (body.len == 0) {
            _ = self.control.rejected.fetchAdd(1, .monotonic);
            return;
        }

        const published = dates.parse(trimmed(self.published));
        const updated = dates.parse(trimmed(self.updated));
        const feed_title = collapse(a, trimmed(self.feed_title)) catch return self.abort(p, .out_of_memory);
        const lang_raw = trimmed(self.feed_language);
        const language: ?[]const u8 = self.conn.language orelse if (lang_raw.len > 0 and files.validLanguageTag(lang_raw)) lang_raw else null;

        var extra: std.ArrayList(doc.Extra) = .empty;
        if (self.categories.items.len > 0) {
            const joined = std.mem.join(a, "; ", self.categories.items) catch return self.abort(p, .out_of_memory);
            extra.append(a, .{ .key = "categories", .value = joined }) catch return self.abort(p, .out_of_memory);
        }
        if (feed_title.len > 0) extra.append(a, .{ .key = "feed_title", .value = feed_title }) catch return self.abort(p, .out_of_memory);
        extra.append(a, .{ .key = "feed_file", .value = self.rel }) catch return self.abort(p, .out_of_memory);

        const author = collapse(a, trimmed(self.author)) catch return self.abort(p, .out_of_memory);
        const d: doc.Document = .{
            .connector = self.conn.name,
            .source_id = source_id,
            .source_dataset = if (feed_title.len > 0) feed_title else null,
            .revision = if (trimmed(self.updated).len > 0) trimmed(self.updated) else null,
            .canonical_url = if (isHttp(link)) link else null,
            .title = if (title_one.len > 0) title_one else null,
            .text = body,
            .language = language,
            .content_type = "text/plain",
            .author = if (author.len > 0) author else null,
            .published_at = published,
            .modified_at = updated,
            .rights = .{
                .attribution = if (feed_title.len > 0) std.fmt.allocPrint(a, "From the feed \"{s}\"", .{feed_title}) catch return self.abort(p, .out_of_memory) else null,
                .access_notes = "Feed content belongs to its publisher; check the feed's terms before reuse.",
                .redistribution = .unknown,
            },
            .extra = extra.items,
        };
        self.sink.submit(d) catch |e| switch (e) {
            error.Rejected => {}, // the pipeline counts and reports it
            error.Stopped => return self.abort(p, .stopped),
            error.OutOfMemory => return self.abort(p, .out_of_memory),
        };
        _ = self.control.submitted.fetchAdd(1, .monotonic);
        self.entry_count += 1;
    }
};

fn isHttp(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
}

/// Replaces every run of whitespace, including line breaks, with one space.
fn collapse(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending = false;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            pending = out.items.len > 0;
            continue;
        }
        if (pending) try out.append(a, ' ');
        pending = false;
        try out.append(a, c);
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

const fx_rss = @embedFile("testdata/feeds/rss.xml");
const fx_atom = @embedFile("testdata/feeds/atom.xml");

fn src(opts: []const config.Option) config.Source {
    return .{ .name = "feeds", .kind = "feeds", .options = opts };
}

test "validate: path is required; options are checked" {
    var d: config.Diagnostic = .{};
    const ok = [_]config.Option{.{ .key = "path", .value = .{ .string = "f" } }};
    try validate(src(&ok), &d);
    try validate(src(&(ok ++ [_]config.Option{
        .{ .key = "language", .value = .{ .string = "en" } },
        .{ .key = "max_file_bytes", .value = .{ .integer = 100 } },
    })), &d);
    try testing.expectError(error.InvalidValue, validate(src(&.{}), &d));
    try testing.expectEqualStrings("source[feeds].path", d.key());
    try testing.expectError(error.WrongType, validate(src(&.{.{ .key = "path", .value = .{ .integer = 1 } }}), &d));
    try testing.expectError(error.UnknownKey, validate(src(&(ok ++ [_]config.Option{.{ .key = "url", .value = .{ .string = "x" } }})), &d));
    try testing.expectError(error.InvalidValue, validate(src(&(ok ++ [_]config.Option{.{ .key = "language", .value = .{ .string = "e n" } }})), &d));
    try testing.expectError(error.InvalidValue, validate(src(&(ok ++ [_]config.Option{.{ .key = "max_file_bytes", .value = .{ .integer = 0 } }})), &d));
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

fn feedSource(tmp: *testing.TmpDir, buf: []u8, sub: []const u8, extra: []const config.Option) !config.Source {
    const path = if (sub.len == 0)
        try std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path})
    else
        try std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, sub });
    const opts = try testing.allocator.alloc(config.Option, extra.len + 1);
    opts[0] = .{ .key = "path", .value = .{ .string = path } };
    @memcpy(opts[1..], extra);
    return .{ .name = "feeds", .kind = "feeds", .options = opts };
}

fn runAll(e: *E2e, source: config.Source) !runner.Result {
    var fc = try FeedsConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();
    var ctl: api.Control = .{};
    return runner.runImport(e.arena.allocator(), &e.state, &e.pipe, fc.connector(), "feeds", &ctl, E2e.now);
}

fn makeFeeds(tmp: *testing.TmpDir) !void {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "rss.xml", .data = fx_rss });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "atom.xml", .data = fx_atom });
}

test "a directory of feeds: RSS and Atom entries become documents" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeFeeds(&tmp);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "not a feed" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".hidden.xml", .data = fx_rss });
    var pb: [200]u8 = undefined;
    const source = try feedSource(&tmp, &pb, "", &.{});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();

    const r = try runAll(&e, source);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    // RSS: lamp, fog, "no body" (title becomes the text) = 3, and one entry with
    // neither id nor link is refused. Atom: three entries.
    try testing.expectEqual(@as(u64, 6), r.submitted);
    try testing.expectEqual(@as(u64, 1), r.rejected);
    try testing.expectEqual(@as(u64, 6), try e.idx.count());

    // Bodies are plain text: tags, scripts and entities gone; content beats summary.
    try testing.expectEqual(@as(usize, 1), try e.hits("brilliant"));
    try testing.expectEqual(@as(usize, 1), try e.hits("foghornword"));
    try testing.expectEqual(@as(usize, 0), try e.hits("evil"));
    try testing.expectEqual(@as(usize, 0), try e.hits("summary")); // fog's summary is replaced by its content
    try testing.expectEqual(@as(usize, 1), try e.hits("xhtmlword"));
    try testing.expectEqual(@as(usize, 1), try e.hits("gardien"));
    try testing.expectEqual(@as(usize, 1), try e.hits("goélands"));
    try testing.expectEqual(@as(usize, 1), try e.hits("markup")); // the type="text" body, kept as written
}

test "document fields: ids, links, dates, authors, language, categories" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeFeeds(&tmp);
    var pb: [200]u8 = undefined;
    const source = try feedSource(&tmp, &pb, "", &.{});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    _ = try runAll(&e, source);

    // RSS entry with a URL guid, a link, pubDate, dc:creator and categories.
    const lamp = (try e.docs.store().find(doc.idFromSource("feeds", "https://example.org/log/lamp"))).?.meta;
    try testing.expectEqualStrings("New & improved lamp", lamp.title.?);
    try testing.expectEqualStrings("https://example.org/log/lamp", lamp.canonical_url.?);
    try testing.expectEqualStrings("Alice Example", lamp.author.?);
    try testing.expectEqualStrings("en-gb", lamp.language.?);
    try testing.expectEqual(@as(?i64, 1055217600), lamp.published_at);
    try testing.expectEqualStrings("The Example Harbour Log", lamp.source_dataset.?);
    try testing.expectEqual(doc.Redistribution.unknown, lamp.rights.redistribution);
    var cats: ?[]const u8 = null;
    for (lamp.extra) |x| if (std.mem.eql(u8, x.key, "categories")) {
        cats = x.value;
    };
    try testing.expectEqualStrings("lighthouses; engineering", cats.?);

    // A bare guid is prefixed with the feed's link, so feeds cannot collide.
    const fog = (try e.docs.store().find(doc.idFromSource("feeds", "https://example.org/log/#fog-2003-06"))).?.meta;
    try testing.expectEqual(@as(?i64, 1055316600), fog.published_at); // +0200 applied

    // Atom: alternate link (not enclosure), author name, offsets, category term, language.
    const phare = (try e.docs.store().find(doc.idFromSource("feeds", "urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a"))).?.meta;
    try testing.expectEqualStrings("Le phare est réparé", phare.title.?); // escaped HTML in the title
    try testing.expectEqualStrings("https://example.net/phare", phare.canonical_url.?);
    try testing.expectEqualStrings("Bob Auteur", phare.author.?);
    try testing.expectEqualStrings("fr", phare.language.?);
    try testing.expectEqual(@as(?i64, 1071212400), phare.published_at); // 08:00 +01:00
    try testing.expectEqual(@as(?i64, 1071340202), phare.modified_at);
    // An id without ':' or '/' is prefixed; Atom's feed link is the alternate one.
    const plain = (try e.docs.store().find(doc.idFromSource("feeds", "https://example.net/#plain-1"))).?.meta;
    try testing.expect(plain.canonical_url == null); // no link in that entry
}

test "a single file works, the language option overrides, and updates replace" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one.rss", .data = fx_rss });
    var pb: [200]u8 = undefined;
    const source = try feedSource(&tmp, &pb, "one.rss", &.{.{ .key = "language", .value = .{ .string = "de" } }});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    const r = try runAll(&e, source);
    try testing.expectEqual(@as(u64, 3), r.submitted);
    const lamp = (try e.docs.store().find(doc.idFromSource("feeds", "https://example.org/log/lamp"))).?.meta;
    try testing.expectEqualStrings("de", lamp.language.?);

    // The feed is fetched again with one entry changed: only that one is written.
    const changed = try std.mem.replaceOwned(u8, testing.allocator, fx_rss, "brilliant", "dazzling");
    defer testing.allocator.free(changed);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one.rss", .data = changed });
    _ = try runAll(&e, source);
    try testing.expectEqual(@as(u64, 1), e.pipe.stats.updated);
    try testing.expectEqual(@as(usize, 0), try e.hits("brilliant"));
    try testing.expectEqual(@as(usize, 1), try e.hits("dazzling"));
}

test "bad feeds are counted and skipped; the rest of the directory still imports" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a-bad.xml", .data = "<rss><channel><item><title>cut off" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b-text.xml", .data = "this is not xml at all" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c-doctype.xml", .data = "<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY x \"y\">]><rss><channel><item><title>t</title><guid>g</guid><description>&x;</description></item></channel></rss>" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d-good.xml", .data = fx_atom });
    var pb: [200]u8 = undefined;
    const source = try feedSource(&tmp, &pb, "", &.{});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    const r = try runAll(&e, source);
    try testing.expectEqual(state_sqlite.JobState.completed, r.state);
    try testing.expectEqual(@as(u64, 3), r.submitted); // only the good Atom feed
    try testing.expectEqual(@as(u64, 3), r.rejected); // three unusable files
    try testing.expectEqual(@as(u64, 3), try e.idx.count());
}

test "oversized feed files are refused; a missing path fails the job" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeFeeds(&tmp);
    var pb: [200]u8 = undefined;
    const source = try feedSource(&tmp, &pb, "", &.{.{ .key = "max_file_bytes", .value = .{ .integer = 1500 } }});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    const r = try runAll(&e, source);
    try testing.expect(r.rejected >= 1);

    var e2: E2e = undefined;
    try e2.init();
    defer e2.deinit();
    const missing: config.Source = .{ .name = "feeds", .kind = "feeds", .options = &.{.{ .key = "path", .value = .{ .string = ".zig-cache/tmp/nowhere-at-all" } }} };
    const r2 = try runAll(&e2, missing);
    try testing.expectEqualStrings("InvalidSource", r2.failure.?);
}

test "cancel and resume at the next file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeFeeds(&tmp);
    var pb: [200]u8 = undefined;
    const source = try feedSource(&tmp, &pb, "", &.{});
    defer testing.allocator.free(source.options);
    var fc = try FeedsConnector.init(testing.allocator, testing.io, source);
    defer fc.deinit();
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
            if (self.n == 3) self.control.cancel(); // after the three Atom entries of atom.xml
        }
        fn sink(self: *@This()) api.Sink {
            return .{ .ptr = self, .vtable = &.{ .submit = submit } };
        }
    };
    var ctl: api.Control = .{};
    var cs: Cancelling = .{ .inner = e.pipe.sink(), .control = &ctl };
    const out = try fc.connector().run(cs.sink(), &ctl, null);
    try testing.expect(out.interrupted);
    try testing.expectEqualStrings("atom.xml", out.checkpoint.?); // sorted: atom.xml first, finished
    try testing.expectEqual(@as(u64, 3), try e.idx.count());

    var ctl2: api.Control = .{};
    const rest = try fc.connector().run(e.pipe.sink(), &ctl2, out.checkpoint);
    try testing.expect(!rest.interrupted);
    try testing.expectEqual(@as(u64, 6), try e.idx.count());
    try testing.expectEqual(@as(u64, 0), e.pipe.stats.unchanged);
}

test "random mutations of a real-shaped feed never crash the connector" {
    var prng = std.Random.DefaultPrng.init(0xfeed);
    const rnd = prng.random();
    var buf: [fx_atom.len]u8 = undefined;
    for (0..30) |_| {
        @memcpy(&buf, fx_atom);
        for (0..1 + rnd.uintLessThan(usize, 6)) |_| buf[rnd.uintLessThan(usize, buf.len)] = rnd.int(u8);
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "m.xml", .data = &buf });
        var pb: [200]u8 = undefined;
        const source = try feedSource(&tmp, &pb, "", &.{});
        defer testing.allocator.free(source.options);
        var e: E2e = undefined;
        try e.init();
        defer e.deinit();
        const r = try runAll(&e, source);
        try testing.expect(r.state == .completed);
    }
}

test "RSS 1.0: siblings of the channel do not overwrite the feed title; long ids keep valid UTF-8" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const rdf =
        \\<?xml version="1.0"?>
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
        \\<channel><title>Real Title</title><link>https://example.org/</link></channel>
        \\<image><title>Logo</title><link>https://example.org/logo</link></image>
        \\<item><title>One</title><link>https://example.org/one</link><description>rdfbody</description></item>
        \\<textinput><title>Search</title><link>https://example.org/cgi</link></textinput>
        \\</rdf:RDF>
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "r.rdf", .data = rdf });
    var pb: [200]u8 = undefined;
    const source = try feedSource(&tmp, &pb, "", &.{});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    const r = try runAll(&e, source);
    try testing.expectEqual(@as(u64, 1), r.submitted);
    const rec = (try e.docs.store().find(doc.idFromSource("feeds", "https://example.org/one"))).?.meta;
    try testing.expectEqualStrings("Real Title", rec.source_dataset.?);
}

test "a symlink named as the path is followed; one over-long text field keeps its start" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.xml", .data = fx_rss });
    tmp.dir.symLink(testing.io, "real.xml", "current.xml", .{}) catch return error.SkipZigTest;
    var pb: [200]u8 = undefined;
    const source = try feedSource(&tmp, &pb, "current.xml", &.{});
    defer testing.allocator.free(source.options);
    var e: E2e = undefined;
    try e.init();
    defer e.deinit();
    const r = try runAll(&e, source);
    try testing.expectEqual(@as(u64, 3), r.submitted);
}
