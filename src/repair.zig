//! Brings the stored documents of crawl sources up to date with what the crawler does now (docs/decisions/0071). Old
//! documents keep what they had when they were stored: a title with `&bull;` in it, an address with `./` or a tracking
//! parameter in it (which the crawler now tidies, so the same page is fetched again under the tidy address and the index
//! has it twice), no language. Nothing is fetched: it works on the records, the retained texts and the index.
//!
//! Phase one only looks (a pass over the records, nothing is modified) and plans the fixes; `dry_run` stops there. Phase two
//! applies them in batches, in the order the importer commits (content, index, records), so a crash loses a batch and nothing
//! else, and running it again finishes the job.
//!
//! - Titles: HTML entities are decoded.
//! - Addresses: a document whose address (its source id, for a page) is not tidy is *merged* into the document at the tidy
//!   address if there is one (the untidy one is removed), else *moved* to the tidy address (a new id, the same text and
//!   record, the old one removed).
//! - Language: a page without one gets it from the first part of its address (`/ja/...`), else from the script of its text
//!   (Chinese, Japanese, Korean, Cyrillic, Arabic...); Latin text is left alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const doc = @import("document.zig");
const storage = @import("storage.zig");
const indexer = @import("indexer.zig");
const htmltext = @import("htmltext.zig");
const langprefer = @import("langprefer.zig");
const frontier = @import("connectors/crawl/frontier.zig");

pub const Error = indexer.Error || storage.Error;

pub const Options = struct {
    /// Plan and count, change nothing.
    dry_run: bool = false,
    /// The names of the crawl sources: only their documents are looked at.
    crawl_sources: []const []const u8 = &.{},
};

pub const Stats = struct {
    examined: u64 = 0,
    /// Planned by the first phase.
    titles_planned: u64 = 0,
    untidy_planned: u64 = 0,
    languages_planned: u64 = 0,
    /// Done by the second.
    titles: u64 = 0,
    languages: u64 = 0,
    merged: u64 = 0,
    moved: u64 = 0,
    /// Left as they were because their text is not retained or could not be read.
    skipped: u64 = 0,
};

const Fix = struct {
    id: doc.Id,
    title: ?[]const u8 = null,
    language: ?[]const u8 = null,
    tidy: ?[]const u8 = null,
};

fn isCrawl(names: []const []const u8, connector: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, connector)) return true;
    return false;
}

fn pathOf(url: []const u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[sep + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[slash..];
}

const Plan = struct {
    gpa: Allocator,
    arena: Allocator,
    content: storage.ContentStore,
    opts: Options,
    fixes: std.ArrayList(Fix) = .empty,
    stats: Stats = .{},
    failure: ?Error = null,

    fn visit(ptr: *anyopaque, rec: storage.Record) storage.Error!void {
        const self: *Plan = @ptrCast(@alignCast(ptr));
        self.stats.examined += 1;
        const m = rec.meta;
        if (!isCrawl(self.opts.crawl_sources, m.connector)) return;
        var fix: Fix = .{ .id = rec.id };
        var any = false;
        if (m.title) |t| if (std.mem.indexOfScalar(u8, t, '&') != null and std.mem.indexOfScalar(u8, t, ';') != null) {
            const decoded = htmltext.decodeEntities(self.arena, t) catch return error.OutOfMemory;
            if (!std.mem.eql(u8, decoded, t)) {
                fix.title = decoded;
                any = true;
                self.stats.titles_planned += 1;
            }
        };
        if (m.canonical_url) |u| if (std.mem.eql(u8, u, m.source_id) and (std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://"))) {
            const t = frontier.tidy(self.arena, u) catch return error.OutOfMemory;
            if (!std.mem.eql(u8, t, u)) {
                fix.tidy = t;
                any = true;
                self.stats.untidy_planned += 1;
            }
        };
        const is_page = if (m.content_type) |ct| std.ascii.startsWithIgnoreCase(ct, "text/html") else false;
        if (m.language == null and is_page) {
            var lang: ?[]const u8 = null;
            if (m.canonical_url) |u| if (pathOf(u)) |p| {
                lang = langprefer.languageOfPath(p);
            };
            if (lang == null) {
                if (self.content.get(self.gpa, rec.id)) |text| {
                    defer self.gpa.free(text);
                    lang = langprefer.languageOfText(text);
                } else |_| {}
            }
            if (lang) |l| {
                fix.language = l;
                any = true;
                self.stats.languages_planned += 1;
            }
        }
        if (any) self.fixes.append(self.arena, fix) catch return error.OutOfMemory;
    }
};

pub fn run(gpa: Allocator, index: indexer.Indexer, content: storage.ContentStore, docs: storage.DocumentStore, opts: Options) Error!Stats {
    var plan_arena = std.heap.ArenaAllocator.init(gpa);
    defer plan_arena.deinit();
    var plan: Plan = .{ .gpa = gpa, .arena = plan_arena.allocator(), .content = content, .opts = opts };
    try docs.forEach(.{ .ptr = &plan, .visit = Plan.visit });
    var stats = plan.stats;
    if (opts.dry_run or plan.fixes.items.len == 0) return stats;

    const batch = 200;
    var in_batch = false;
    errdefer if (in_batch) {
        docs.rollback() catch {};
        index.rollback() catch {};
        content.rollback() catch {};
    };
    for (plan.fixes.items, 0..) |fix, n| {
        if (!in_batch) {
            try content.begin();
            try index.begin();
            try docs.begin();
            in_batch = true;
        }
        try apply(gpa, index, content, docs, fix, &stats);
        if ((n + 1) % batch == 0) {
            try content.commit();
            try index.commit();
            try docs.commit();
            in_batch = false;
        }
    }
    if (in_batch) {
        try content.commit();
        try index.commit();
        try docs.commit();
        in_batch = false;
    }
    return stats;
}

fn removeDocument(index: indexer.Indexer, content: storage.ContentStore, docs: storage.DocumentStore, id: doc.Id) Error!void {
    try index.remove(id);
    content.delete(id) catch |e| switch (e) {
        error.NotFound => {},
        else => return e,
    };
    try docs.delete(id);
}

fn apply(gpa: Allocator, index: indexer.Indexer, content: storage.ContentStore, docs: storage.DocumentStore, fix: Fix, stats: *Stats) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rec = (try docs.find(fix.id)) orelse return;
    var meta = rec.meta.clone(a) catch return error.OutOfMemory;
    const content_hash = rec.content_hash;
    const acquired_at = rec.acquired_at;
    if (fix.title) |t| meta.title = t;
    if (fix.language) |l| meta.language = l;

    // Without its text a document can be neither moved nor put into the index again: it is left as it is.
    const text = content.get(a, fix.id) catch {
        stats.skipped += 1;
        return;
    };

    var id = fix.id;
    if (fix.tidy) |t| {
        const new_id = doc.idFromSource(meta.connector, t);
        if (!std.mem.eql(u8, &new_id, &fix.id)) {
            if ((try docs.find(new_id)) != null) {
                // The page is already there under its tidy address: this is the duplicate.
                try removeDocument(index, content, docs, fix.id);
                stats.merged += 1;
                return;
            }
            meta.source_id = t;
            meta.canonical_url = t;
            id = new_id;
        }
    }
    try content.put(id, text);
    var d = meta;
    d.text = text;
    try index.add(id, d);
    try docs.upsert(.{ .id = id, .content_hash = content_hash, .acquired_at = acquired_at, .meta = meta });
    if (!std.mem.eql(u8, &id, &fix.id)) {
        try removeDocument(index, content, docs, fix.id);
        stats.moved += 1;
    }
    if (fix.title != null) stats.titles += 1;
    if (fix.language != null) stats.languages += 1;
}

const testing = std.testing;
const memory = @import("memory.zig");
const index_sqlite = @import("index_sqlite.zig");

const Fixture = struct {
    mem_docs: memory.MemoryDocumentStore,
    mem_content: memory.MemoryContentStore,
    idx: index_sqlite.SqliteIndex,

    fn init(f: *Fixture) !void {
        f.mem_docs = memory.MemoryDocumentStore.init(testing.allocator);
        f.mem_content = memory.MemoryContentStore.init(testing.allocator);
        f.idx = try index_sqlite.SqliteIndex.open(":memory:", .{ .sync = .off });
    }

    fn deinit(f: *Fixture) void {
        f.idx.close();
        f.mem_content.deinit();
        f.mem_docs.deinit();
    }

    fn add(f: *Fixture, connector: []const u8, url: []const u8, title: ?[]const u8, language: ?[]const u8, text: []const u8) !doc.Id {
        const d: doc.Document = .{ .connector = connector, .source_id = url, .canonical_url = url, .title = title, .language = language, .content_type = "text/html", .text = text };
        const id = d.id();
        try f.mem_content.store().put(id, text);
        try f.idx.indexer().add(id, d);
        var meta = d;
        meta.text = null;
        try f.mem_docs.store().upsert(.{ .id = id, .content_hash = d.contentHash(), .acquired_at = null, .meta = meta });
        return id;
    }

    fn found(f: *Fixture, a: Allocator, words: []const u8) !usize {
        return (try f.idx.searcher().search(a, .{ .text = words })).hits.len;
    }

    fn run(f: *Fixture, dry: bool) !Stats {
        return run_(testing.allocator, f.idx.indexer(), f.mem_content.store(), f.mem_docs.store(), .{ .dry_run = dry, .crawl_sources = &.{"web"} });
    }
};
const run_ = run;

test "titles are decoded, untidy addresses merged or moved, languages set; a dry run changes nothing; other sources are left alone" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // 1: a title with an entity. 2 and 3: the same page, untidy and tidy. 4: untidy with no twin. 5: Japanese by its address,
    // 6: Chinese by its script, 7: English text (no language is guessed). 8: another source, untouched.
    const id1 = try f.add("web", "https://e.org/a", "Home &bull; Library", "en", "alpha text");
    const id2 = try f.add("web", "https://e.org/./features/", "Features", "en", "beta text beta");
    _ = try f.add("web", "https://e.org/features/", "Features", "en", "beta text beta");
    const id4 = try f.add("web", "https://e.org/x//y?utm_source=z", "Untidy", "en", "gamma text");
    const id5 = try f.add("web", "https://e.org/ja/page", "Ja", null, "delta text");
    const id6 = try f.add("web", "https://e.org/p6", "Zh", null, "这是一个关于计算机操作系统和编程语言的页面，里面有很多文字内容可以阅读。");
    const id7 = try f.add("web", "https://e.org/p7", "En", null, "This is a page about operating systems and programming languages, with plenty of text to read.");
    const id8 = try f.add("other", "https://e.org/./o", "Other &amp; more", null, "omega text");
    // A dry run counts and changes nothing.
    const dry = try f.run(true);
    try testing.expectEqual(@as(u64, 1), dry.titles_planned);
    try testing.expectEqual(@as(u64, 2), dry.untidy_planned);
    try testing.expectEqual(@as(u64, 2), dry.languages_planned);
    try testing.expectEqual(@as(usize, 8), f.mem_docs.count());
    try testing.expect(try f.mem_docs.store().find(id2) != null);
    // The real run.
    const s = try f.run(false);
    try testing.expectEqual(@as(u64, 1), s.merged);
    try testing.expectEqual(@as(u64, 1), s.moved);
    try testing.expectEqual(@as(u64, 1), s.titles);
    try testing.expectEqual(@as(u64, 2), s.languages);
    try testing.expectEqual(@as(u64, 0), s.skipped);
    // The title is decoded, in the record and in the index (the word is found in the title).
    try testing.expectEqualStrings("Home \u{2022} Library", (try f.mem_docs.store().find(id1)).?.meta.title.?);
    // The duplicate is gone and the page is once in the index; the other is moved to its tidy address and found there.
    try testing.expect(try f.mem_docs.store().find(id2) == null);
    try testing.expectEqual(@as(usize, 1), try f.found(a, "beta"));
    try testing.expect(try f.mem_docs.store().find(id4) == null);
    const moved = (try f.mem_docs.store().find(doc.idFromSource("web", "https://e.org/x/y"))).?;
    try testing.expectEqualStrings("https://e.org/x/y", moved.meta.canonical_url.?);
    try testing.expectEqual(@as(usize, 1), try f.found(a, "gamma"));
    // Languages by address and by script; English is left without one.
    try testing.expectEqualStrings("ja", (try f.mem_docs.store().find(id5)).?.meta.language.?);
    try testing.expectEqualStrings("zh", (try f.mem_docs.store().find(id6)).?.meta.language.?);
    try testing.expect((try f.mem_docs.store().find(id7)).?.meta.language == null);
    // Another source is not touched.
    try testing.expectEqualStrings("Other &amp; more", (try f.mem_docs.store().find(id8)).?.meta.title.?);
    // Running it again finds nothing more to do.
    const again = try f.run(false);
    try testing.expectEqual(@as(u64, 0), again.titles_planned + again.untidy_planned);
}
