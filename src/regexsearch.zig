//! Regular-expression filtering of search results.
//!
//! The words of the query pick candidate documents through the index (fast, in
//! ranking order); this module then checks each candidate's stored text
//! against a regular expression and returns the ones that match, with a
//! snippet around the first match. A query therefore always needs at least one
//! word: the index narrows the field, the expression refines it, and nothing
//! ever scans the whole corpus.
//!
//! Because the pattern comes from whoever types the query (on the public
//! interface, anyone), everything is bounded (docs/decisions/0020):
//!
//! - pattern length, nesting depth, repeat counts and compiled size are capped
//!   when the pattern is compiled;
//! - each document is searched with a step budget and a stack cap, and a
//!   pattern that exhausts the budget on `max_complex` documents is refused as
//!   too complex rather than run further;
//! - at most `max_candidates` documents are examined, and only the first
//!   `max_text_bytes` of each, within a wall-clock `budget_ms` for the query;
//! - at most `concurrency` regex queries run at once; others wait up to
//!   `queue_ms` and then get `Busy`.
//!
//! The engine is the vendored regex-zig (bytewise, with a bounded backtracking
//! matcher). `.` and character classes therefore see bytes, not characters;
//! snippets are widened to character boundaries so they stay valid UTF-8.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const regex = @import("regex");
const search = @import("search.zig");
const storage = @import("storage.zig");

pub const Dialect = enum { perl, ere };

pub const Limits = struct {
    max_pattern_bytes: u32 = 200,
    max_candidates: u32 = 200,
    /// Backtracking steps per document.
    max_steps: u64 = 100_000,
    /// Wall-clock budget for the whole query.
    budget_ms: u32 = 500,
    /// Only this many bytes of each document are searched.
    max_text_bytes: usize = 1 << 20,
    /// Documents that may exhaust the step budget before the pattern is refused.
    max_complex: u32 = 3,
    max_repeat: u32 = 100,
    max_depth: u32 = 30,
    /// Bytes of context each side of a match in a snippet.
    context_bytes: u32 = 60,
    /// Regex queries running at once, and how long another waits for a turn.
    concurrency: u32 = 2,
    queue_ms: u32 = 250,

    /// Ten times the public limits, for the administration interface.
    pub const admin: Limits = .{
        .max_pattern_bytes = 2000,
        .max_candidates = 2000,
        .max_steps = 1_000_000,
        .budget_ms = 5000,
        .max_text_bytes = 8 << 20,
        .max_complex = 5,
        .max_repeat = 1000,
        .max_depth = 100,
        .concurrency = 4,
        .queue_ms = 1000,
    };
};

pub const Request = struct {
    pattern: []const u8,
    ignore_case: bool = false,
    dialect: Dialect = .perl,
};

pub const Error = error{
    /// The word part of the query has no searchable terms.
    EmptyQuery,
    InvalidQuery,
    /// The pattern is malformed or unsupported; see the diagnostic.
    InvalidPattern,
    /// Too many regex queries are running; try again shortly.
    Busy,
    /// The pattern ran out of steps on several documents.
    TooComplex,
    Io,
    OutOfMemory,
};

pub const PatternDiag = struct {
    message: []const u8 = "",
    pos: usize = 0,
};

pub const Result = struct {
    page: search.Page,
    /// Candidate documents whose text was checked.
    examined: u32,
    /// True if the candidate, time or size limits ended the search before
    /// every candidate was seen: there may be more matches.
    truncated: bool,
};

pub const Service = struct {
    io: Io,
    content: storage.ContentStore,
    limits: Limits,
    permits: Io.Semaphore,

    pub fn init(io: Io, content: storage.ContentStore, limits: Limits) Service {
        return .{ .io = io, .content = content, .limits = limits, .permits = .{ .permits = @max(limits.concurrency, 1) } };
    }

    /// Runs the word query `q` through `searcher` and keeps the candidates
    /// whose text matches `req`. `q.limit` and `q.offset` count matches.
    pub fn run(self: *Service, arena: Allocator, searcher: search.Searcher, q: search.Query, req: Request, diag: *PatternDiag) Error!Result {
        const lim = self.limits;
        if (req.pattern.len == 0) {
            diag.* = .{ .message = "the pattern is empty" };
            return error.InvalidPattern;
        }
        if (req.pattern.len > lim.max_pattern_bytes) {
            diag.* = .{ .message = "the pattern is too long" };
            return error.InvalidPattern;
        }
        if (std.mem.indexOfScalar(u8, req.pattern, 0) != null) {
            diag.* = .{ .message = "the pattern contains a NUL byte" };
            return error.InvalidPattern;
        }
        const want: u32 = if (q.limit == 0) search_default_limit else q.limit;
        if (want > search.max_limit) return error.InvalidQuery;

        // A turn: bounded concurrency keeps one pattern-heavy crowd from
        // taking every CPU away from ordinary searches.
        self.permits.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(lim.queue_ms), .clock = .awake } }) catch return error.Busy;
        defer self.permits.post(self.io);

        const started = Io.Timestamp.now(self.io, .awake);
        const budget_ns: i96 = @as(i96, lim.budget_ms) * std.time.ns_per_ms;

        var rd: regex.Diagnostic = .{};
        var re = regex.Regex.compile(arena, req.pattern, .{
            .dialect = switch (req.dialect) {
                .perl => .perl,
                .ere => .posix_ere,
            },
            .ignore_case = req.ignore_case,
            .limits = .{
                .max_pattern_len = lim.max_pattern_bytes,
                .max_depth = lim.max_depth,
                .max_repeat = lim.max_repeat,
                .max_program_len = 20_000,
                .max_steps = lim.max_steps,
                .max_stack = 64 * 1024,
            },
        }, &rd) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern, error.Unsupported, error.LimitExceeded => {
                diag.* = .{ .message = rd.message, .pos = rd.pos };
                return error.InvalidPattern;
            },
        };
        var matcher = re.searcher(arena) catch return error.OutOfMemory;
        defer matcher.deinit();

        var hits: std.ArrayList(search.Hit) = .empty;
        var matches_seen: u64 = 0;
        var examined: u32 = 0;
        var complex: u32 = 0;
        var truncated = false;
        var fetched: u32 = 0; // candidates asked of the index so far
        var index_has_more = true;
        const batch: u32 = 50;

        scan: while (index_has_more) {
            if (fetched >= lim.max_candidates) {
                truncated = true;
                break;
            }
            var bq = q;
            bq.offset = fetched;
            bq.limit = @min(batch, lim.max_candidates - fetched);
            const page = searcher.search(arena, bq) catch |e| switch (e) {
                error.EmptyQuery => return error.EmptyQuery,
                error.InvalidQuery => return error.InvalidQuery,
                error.Io => return error.Io,
                error.OutOfMemory => return error.OutOfMemory,
            };
            index_has_more = page.has_more;
            fetched += @intCast(page.hits.len);
            if (page.hits.len == 0) break;

            for (page.hits) |h| {
                if (started.durationTo(Io.Timestamp.now(self.io, .awake)).nanoseconds > budget_ns) {
                    truncated = true;
                    break :scan;
                }
                var doc_arena = std.heap.ArenaAllocator.init(arena);
                defer doc_arena.deinit();
                const text_full = self.content.get(doc_arena.allocator(), h.id) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Missing, damaged or unreadable text: this document cannot match.
                    else => continue,
                };
                examined += 1;
                const text = text_full[0..@min(text_full.len, lim.max_text_bytes)];
                if (text.len < text_full.len) truncated = true;

                const found = matcher.find(text, 0) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.StepLimitExceeded, error.StackLimitExceeded => {
                        complex += 1;
                        if (complex >= lim.max_complex) {
                            diag.* = .{ .message = "the pattern is too complex for the documents it was tried on" };
                            return error.TooComplex;
                        }
                        continue;
                    },
                };
                const m = found orelse continue;
                matches_seen += 1;
                if (matches_seen <= q.offset) continue;
                var hit = h;
                hit.snippet = try snippet(arena, text, m.start(), m.end(), lim.context_bytes);
                try hits.append(arena, hit);
                if (hits.items.len > want) break :scan;
            }
        }

        const more = hits.items.len > want or truncated;
        if (hits.items.len > want) hits.items.len = want;
        return .{ .page = .{ .hits = hits.items, .has_more = more }, .examined = examined, .truncated = truncated };
    }
};

const search_default_limit = search.default_limit;
const max_marked_match = 200;

/// A one-line excerpt around [start, end), the match bracketed by the search
/// markers. Control characters (including the markers themselves, which the
/// text may contain) become spaces; the cut points are moved to character
/// boundaries so the result is valid UTF-8 whenever `text` is.
fn snippet(arena: Allocator, text: []const u8, start_in: usize, end_in: usize, context: u32) Allocator.Error![]const u8 {
    var start = snapBack(text, start_in);
    var end = snapFwd(text, @max(end_in, start_in));
    if (end - start > max_marked_match) end = snapBack(text, start + max_marked_match);
    if (end < start) end = start;
    const from = snapBack(text, start -| context);
    const to = snapFwd(text, @min(text.len, end + context));
    _ = &start;

    var out: std.ArrayList(u8) = .empty;
    if (from > 0) try out.appendSlice(arena, "\u{2026}");
    try appendClean(arena, &out, text[from..start]);
    try out.appendSlice(arena, search.match_start);
    try appendClean(arena, &out, text[start..end]);
    try out.appendSlice(arena, search.match_end);
    try appendClean(arena, &out, text[end..to]);
    if (to < text.len) try out.appendSlice(arena, "\u{2026}");
    return out.items;
}

fn appendClean(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    var last_space = out.items.len == 0 or out.items[out.items.len - 1] == ' ';
    for (s) |b| {
        if (b < 0x20 or b == 0x7f) {
            if (!last_space) try out.append(arena, ' ');
            last_space = true;
        } else {
            try out.append(arena, b);
            last_space = b == ' ';
        }
    }
}

fn snapBack(text: []const u8, i_in: usize) usize {
    var i = @min(i_in, text.len);
    while (i > 0 and i < text.len and (text[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

fn snapFwd(text: []const u8, i_in: usize) usize {
    var i = @min(i_in, text.len);
    while (i < text.len and (text[i] & 0xC0) == 0x80) i += 1;
    return i;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const x201: []const u8 = &@as([201]u8, @splat('x'));
const x100: []const u8 = &@as([100]u8, @splat('x'));
const a40: []const u8 = &@as([40]u8, @splat('a'));
const doc = @import("document.zig");
const memory = @import("memory.zig");

/// Candidates in a fixed order, honouring offset and limit.
const FakeIndex = struct {
    ids: []const doc.Id,
    fn doSearch(ptr: *anyopaque, arena: Allocator, q: search.Query) search.Error!search.Page {
        const self: *FakeIndex = @ptrCast(@alignCast(ptr));
        if (q.text.len == 0) return error.EmptyQuery;
        const limit: usize = if (q.limit == 0) search.default_limit else q.limit;
        const from = @min(q.offset, self.ids.len);
        const to = @min(from + limit, self.ids.len);
        const hits = try arena.alloc(search.Hit, to - from);
        for (self.ids[from..to], hits, from..) |id, *h, i| {
            h.* = .{ .id = id, .connector = "t", .url = null, .title = null, .snippet = null, .score = 100 - @as(f64, @floatFromInt(i)) };
        }
        return .{ .hits = hits, .has_more = to < self.ids.len };
    }
    fn searcher(self: *FakeIndex) search.Searcher {
        return .{ .ptr = self, .vtable = &.{ .search = doSearch } };
    }
};

const Fixture = struct {
    store: memory.MemoryContentStore,
    ids: std.ArrayList(doc.Id) = .empty,
    index: FakeIndex = undefined,

    fn init() Fixture {
        return .{ .store = memory.MemoryContentStore.init(testing.allocator) };
    }
    fn deinit(f: *Fixture) void {
        f.store.deinit();
        f.ids.deinit(testing.allocator);
    }
    fn add(f: *Fixture, name: []const u8, text: []const u8) !void {
        const id = doc.idFromSource("t", name);
        try f.store.store().put(id, text);
        try f.ids.append(testing.allocator, id);
    }
    fn service(f: *Fixture, limits: Limits) Service {
        f.index = .{ .ids = f.ids.items };
        return Service.init(testing.io, f.store.store(), limits);
    }
};

test "the regex keeps matching candidates and marks the match" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("a", "The order number is 123-456 and more words follow");
    try f.add("b", "No digits in this one at all");
    try f.add("c", "Another 99-100 order");
    var svc = f.service(.{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: PatternDiag = .{};
    const r = try svc.run(arena.allocator(), f.index.searcher(), .{ .text = "order" }, .{ .pattern = "\\d+-\\d+" }, &diag);
    try testing.expectEqual(@as(usize, 2), r.page.hits.len);
    try testing.expect(!r.page.has_more);
    try testing.expectEqual(@as(u32, 3), r.examined);
    try testing.expect(std.mem.indexOf(u8, r.page.hits[0].snippet.?, "\x02123-456\x03") != null);
    try testing.expect(std.mem.indexOf(u8, r.page.hits[1].snippet.?, "\x0299-100\x03") != null);
}

test "case-insensitive flag, POSIX ERE dialect and paging by match" {
    var f = Fixture.init();
    defer f.deinit();
    for (0..5) |i| {
        var nb: [8]u8 = undefined;
        var tb: [40]u8 = undefined;
        try f.add(try std.fmt.bufPrint(&nb, "d{d}", .{i}), try std.fmt.bufPrint(&tb, "Report {d} says HELLO world", .{i}));
    }
    try f.add("z", "nothing here");
    var svc = f.service(.{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: PatternDiag = .{};
    const a = arena.allocator();
    const none = try svc.run(a, f.index.searcher(), .{ .text = "report" }, .{ .pattern = "hello" }, &diag);
    try testing.expectEqual(@as(usize, 0), none.page.hits.len);
    const some = try svc.run(a, f.index.searcher(), .{ .text = "report" }, .{ .pattern = "hello", .ignore_case = true, .dialect = .ere }, &diag);
    try testing.expectEqual(@as(usize, 5), some.page.hits.len);
    // Page of two, then the next page.
    const p1 = try svc.run(a, f.index.searcher(), .{ .text = "report", .limit = 2 }, .{ .pattern = "HELLO" }, &diag);
    try testing.expectEqual(@as(usize, 2), p1.page.hits.len);
    try testing.expect(p1.page.has_more);
    const p3 = try svc.run(a, f.index.searcher(), .{ .text = "report", .limit = 2, .offset = 4 }, .{ .pattern = "HELLO" }, &diag);
    try testing.expectEqual(@as(usize, 1), p3.page.hits.len);
    try testing.expect(!p3.page.has_more);
}

test "bad patterns are refused with a reason" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("a", "text");
    var svc = f.service(.{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: PatternDiag = .{};
    const q: search.Query = .{ .text = "text" };
    for ([_][]const u8{ "(unclosed", "a{2,1}", "\\p{L}", x201, "" }) |p| {
        try testing.expectError(error.InvalidPattern, svc.run(arena.allocator(), f.index.searcher(), q, .{ .pattern = p }, &diag));
        try testing.expect(diag.message.len > 0);
    }
    // No words: the index has nothing to narrow with.
    try testing.expectError(error.EmptyQuery, svc.run(arena.allocator(), f.index.searcher(), .{ .text = "" }, .{ .pattern = "a" }, &diag));
}

test "a catastrophic pattern is cut off and refused, quickly" {
    var f = Fixture.init();
    defer f.deinit();
    const hay = a40 ++ "b";
    try f.add("1", hay);
    try f.add("2", hay);
    var svc = f.service(.{ .max_complex = 2, .max_steps = 50_000 });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: PatternDiag = .{};
    const t0 = Io.Timestamp.now(testing.io, .awake);
    try testing.expectError(error.TooComplex, svc.run(arena.allocator(), f.index.searcher(), .{ .text = "a" }, .{ .pattern = "(a+)+$" }, &diag));
    const took_ms = @divTrunc(t0.durationTo(Io.Timestamp.now(testing.io, .awake)).nanoseconds, std.time.ns_per_ms);
    try testing.expect(took_ms < 2000);
}

test "the candidate cap and the size cap end a search with truncated set" {
    var f = Fixture.init();
    defer f.deinit();
    for (0..10) |i| {
        var nb: [8]u8 = undefined;
        try f.add(try std.fmt.bufPrint(&nb, "d{d}", .{i}), "word needle");
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: PatternDiag = .{};
    var svc = f.service(.{ .max_candidates = 3 });
    const r = try svc.run(arena.allocator(), f.index.searcher(), .{ .text = "word", .limit = 10 }, .{ .pattern = "needle" }, &diag);
    try testing.expectEqual(@as(usize, 3), r.page.hits.len);
    try testing.expect(r.truncated and r.page.has_more);

    // Only the first bytes of a document are searched.
    var f2 = Fixture.init();
    defer f2.deinit();
    try f2.add("long", "word " ++ x100 ++ " needle");
    var svc2 = f2.service(.{ .max_text_bytes = 50 });
    const r2 = try svc2.run(arena.allocator(), f2.index.searcher(), .{ .text = "word" }, .{ .pattern = "needle" }, &diag);
    try testing.expectEqual(@as(usize, 0), r2.page.hits.len);
    try testing.expect(r2.truncated);
}

test "snippets stay valid UTF-8 when the engine splits a character" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("u", "caf\u{e9} cr\u{e8}me br\u{fb}l\u{e9}e \u{4e2d}\u{6587} text with control\x02chars\x03 and\nnewlines");
    var svc = f.service(.{ .context_bytes = 5 });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: PatternDiag = .{};
    // "." matches one byte, so the match can end inside a character.
    for ([_][]const u8{ "caf.", "r.", "\\xC3", "cont.ol", "nl|newl" }) |p| {
        const r = try svc.run(arena.allocator(), f.index.searcher(), .{ .text = "caf" }, .{ .pattern = p }, &diag);
        for (r.page.hits) |h| {
            try testing.expect(std.unicode.utf8ValidateSlice(h.snippet.?));
            try testing.expect(std.mem.indexOfScalar(u8, h.snippet.?, '\n') == null);
        }
    }
}

test "a busy service says so instead of queueing forever" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add("a", "word needle");
    var svc = f.service(.{ .concurrency = 1, .queue_ms = 20 });
    svc.permits.waitUncancelable(testing.io); // another query holds the only turn
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: PatternDiag = .{};
    try testing.expectError(error.Busy, svc.run(arena.allocator(), f.index.searcher(), .{ .text = "word" }, .{ .pattern = "needle" }, &diag));
    svc.permits.post(testing.io);
    const r = try svc.run(arena.allocator(), f.index.searcher(), .{ .text = "word" }, .{ .pattern = "needle" }, &diag);
    try testing.expectEqual(@as(usize, 1), r.page.hits.len);
}

test "random patterns and texts never crash and stay within bounds" {
    var f = Fixture.init();
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(0x7e9e);
    const rnd = prng.random();
    for (0..6) |i| {
        var nb: [8]u8 = undefined;
        var tb: [120]u8 = undefined;
        for (&tb) |*b| b.* = "ab c\n(|)*+?[]\\.d1 \xC3\xA9"[rnd.uintLessThan(usize, 17)];
        try f.add(try std.fmt.bufPrint(&nb, "r{d}", .{i}), &tb);
    }
    var svc = f.service(.{ .max_steps = 20_000, .budget_ms = 2000 });
    var pat: [24]u8 = undefined;
    for (0..300) |_| {
        for (&pat) |*b| b.* = "ab(|)*+?[]\\.d1^$ {2}"[rnd.uintLessThan(usize, 20)];
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var diag: PatternDiag = .{};
        _ = svc.run(arena.allocator(), f.index.searcher(), .{ .text = "a" }, .{ .pattern = pat[0 .. rnd.uintLessThan(usize, pat.len) + 1] }, &diag) catch {};
    }
}
