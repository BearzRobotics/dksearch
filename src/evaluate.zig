//! Ranking evaluation: how well does the search put the documents a person
//! judged relevant near the top?
//!
//! The judgments are a JSON Lines text, one query per line:
//!
//!     {"query": "lighthouse keeper", "relevant": ["https://en.wikipedia.org/wiki/Lighthouse_keeper"]}
//!     {"query": "tide tables", "relevant": {"https://example.org/tides": 3, "https://example.org/moon": 1}}
//!
//! A line may also name results that are not wanted, `"irrelevant": ["https://..."]` (alone, or beside `relevant`), and
//! the feedback file of the results page (`feedback.jsonl`) is read too: its lines are
//!
//!     {"query": "tide tables", "url": "https://example.org/tides", "grade": 1}
//!
//! a grade of 1 and up is relevant, -1 is not wanted, 0 takes an earlier grade back; the last line for a query and
//! address wins. Lines with the same query are one query, so the golden file and the feedback file can be put together
//! (`cat golden.jsonl feedback.jsonl`).
//!
//! A relevant document is named by its URL or by its id (as the search API
//! shows it); a list means every document is equally relevant, an object gives
//! each a grade (1 and up, higher is better). Blank lines and lines starting
//! with `#` are skipped. For each query the search runs against the index
//! as it is, and the module reports precision and recall at k, the reciprocal
//! rank of the first relevant hit, normalised discounted cumulative gain at k,
//! and where each relevant document ranked (within the first 100).
//!
//! Deterministic: nothing here reads a clock or the network, and the order of
//! results is the search's own (score, then document id).

const std = @import("std");
const Allocator = std.mem.Allocator;
const search = @import("search.zig");

pub const max_k = search.max_limit;
pub const max_queries = 10_000;
pub const max_relevant_per_query = 1000;

pub const Relevant = struct {
    /// A URL, or a 32-character hexadecimal document id.
    key: []const u8,
    grade: u32,
};

pub const Judgment = struct {
    /// The line the query first appeared on.
    line: usize,
    query: []const u8,
    relevant: []const Relevant,
    /// Results that are not wanted (URLs or ids): the report counts how many are in the top k.
    irrelevant: []const []const u8 = &.{},
};

pub const ParseError = error{ OutOfMemory, BadJudgments };

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

/// One query while the lines are being read: the grades of its documents in the order they were first given
/// (1 and up relevant, -1 not wanted).
const Entry = struct {
    line: usize,
    query: []const u8,
    keys: std.ArrayList([]const u8) = .empty,
    grades: std.ArrayList(i32) = .empty,

    fn set(self: *Entry, arena: Allocator, key: []const u8, grade: i32) Allocator.Error!void {
        for (self.keys.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            if (grade == 0) {
                _ = self.keys.orderedRemove(i);
                _ = self.grades.orderedRemove(i);
            } else self.grades.items[i] = grade;
            return;
        };
        if (grade == 0) return;
        try self.keys.append(arena, key);
        try self.grades.append(arena, grade);
    }
};

/// Parses the judgments text. On `BadJudgments`, `diag` says which line and why.
pub fn parseJudgments(arena: Allocator, text: []const u8, diag: *Diagnostic) ParseError![]const Judgment {
    var entries: std.ArrayList(Entry) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
            diag.* = .{ .line = line_no, .message = "not valid JSON" };
            return error.BadJudgments;
        };
        const obj = switch (v) {
            .object => |o| o,
            else => {
                diag.* = .{ .line = line_no, .message = "expected a JSON object" };
                return error.BadJudgments;
            },
        };
        const q = switch (obj.get("query") orelse {
            diag.* = .{ .line = line_no, .message = "missing \"query\"" };
            return error.BadJudgments;
        }) {
            .string => |s| s,
            else => {
                diag.* = .{ .line = line_no, .message = "\"query\" must be a string" };
                return error.BadJudgments;
            },
        };
        if (q.len == 0 or q.len > search.max_query_bytes) {
            diag.* = .{ .line = line_no, .message = "\"query\" is empty or too long" };
            return error.BadJudgments;
        }
        const at = if (index.get(q)) |i| i else blk: {
            if (entries.items.len >= max_queries) {
                diag.* = .{ .line = line_no, .message = "too many queries" };
                return error.BadJudgments;
            }
            try entries.append(arena, .{ .line = line_no, .query = q });
            try index.put(arena, q, entries.items.len - 1);
            break :blk entries.items.len - 1;
        };
        const e = &entries.items[at];

        // A line of the feedback file: one address and one grade.
        if (obj.get("url")) |u| {
            const url = switch (u) {
                .string => |x| x,
                else => {
                    diag.* = .{ .line = line_no, .message = "\"url\" must be a string" };
                    return error.BadJudgments;
                },
            };
            const g: i32 = switch (obj.get("grade") orelse std.json.Value{ .integer = 1 }) {
                .integer => |n| if (n >= -1 and n <= 100) @intCast(n) else {
                    diag.* = .{ .line = line_no, .message = "\"grade\" must be an integer from -1 to 100" };
                    return error.BadJudgments;
                },
                else => {
                    diag.* = .{ .line = line_no, .message = "\"grade\" must be an integer from -1 to 100" };
                    return error.BadJudgments;
                },
            };
            if (url.len == 0 or url.len > 2000) {
                diag.* = .{ .line = line_no, .message = "\"url\" is empty or too long" };
                return error.BadJudgments;
            }
            try e.set(arena, url, g);
            continue;
        }

        const rel_v = obj.get("relevant");
        const irr_v = obj.get("irrelevant");
        if (rel_v == null and irr_v == null) {
            diag.* = .{ .line = line_no, .message = "missing \"relevant\"" };
            return error.BadJudgments;
        }
        if (rel_v) |rv| {
            var count: usize = 0;
            switch (rv) {
                .array => |arr| for (arr.items) |item| {
                    const key = switch (item) {
                        .string => |x| x,
                        else => {
                            diag.* = .{ .line = line_no, .message = "\"relevant\" entries must be strings" };
                            return error.BadJudgments;
                        },
                    };
                    try e.set(arena, key, 1);
                    count += 1;
                },
                .object => |o| {
                    var it = o.iterator();
                    while (it.next()) |entry| {
                        const g: i32 = switch (entry.value_ptr.*) {
                            .integer => |n| if (n >= 1 and n <= 100) @intCast(n) else {
                                diag.* = .{ .line = line_no, .message = "grades must be integers from 1 to 100" };
                                return error.BadJudgments;
                            },
                            else => {
                                diag.* = .{ .line = line_no, .message = "grades must be integers from 1 to 100" };
                                return error.BadJudgments;
                            },
                        };
                        try e.set(arena, entry.key_ptr.*, g);
                        count += 1;
                    }
                },
                else => {
                    diag.* = .{ .line = line_no, .message = "\"relevant\" must be a list or an object" };
                    return error.BadJudgments;
                },
            }
            if (count == 0 or count > max_relevant_per_query) {
                diag.* = .{ .line = line_no, .message = "needs between 1 and 1000 relevant documents" };
                return error.BadJudgments;
            }
        }
        if (irr_v) |iv| switch (iv) {
            .array => |arr| {
                if (arr.items.len > max_relevant_per_query) {
                    diag.* = .{ .line = line_no, .message = "at most 1000 irrelevant documents" };
                    return error.BadJudgments;
                }
                for (arr.items) |item| switch (item) {
                    .string => |x| try e.set(arena, x, -1),
                    else => {
                        diag.* = .{ .line = line_no, .message = "\"irrelevant\" entries must be strings" };
                        return error.BadJudgments;
                    },
                };
            },
            else => {
                diag.* = .{ .line = line_no, .message = "\"irrelevant\" must be a list" };
                return error.BadJudgments;
            },
        };
    }
    var out: std.ArrayList(Judgment) = .empty;
    for (entries.items) |e| {
        var rel: std.ArrayList(Relevant) = .empty;
        var irr: std.ArrayList([]const u8) = .empty;
        for (e.keys.items, e.grades.items) |k, g| {
            if (g > 0) try rel.append(arena, .{ .key = k, .grade = @intCast(g) }) else try irr.append(arena, k);
        }
        if (rel.items.len == 0 and irr.items.len == 0) continue; // everything was taken back
        try out.append(arena, .{ .line = e.line, .query = e.query, .relevant = rel.items, .irrelevant = irr.items });
    }
    if (out.items.len == 0) {
        diag.* = .{ .line = 0, .message = "no queries" };
        return error.BadJudgments;
    }
    return out.items;
}

pub const QueryResult = struct {
    query: []const u8,
    /// The search itself failed (for example, no searchable terms).
    failed: bool = false,
    relevant_total: u32,
    /// Relevant documents among the first k hits.
    found_in_k: u32 = 0,
    precision: f64 = 0,
    recall: f64 = 0,
    /// 1 / rank of the first relevant hit within k, else 0.
    reciprocal_rank: f64 = 0,
    ndcg: f64 = 0,
    /// Results that were marked not wanted, among the first k hits.
    bad_in_k: u32 = 0,
    /// For each judged document, in the order given: its 1-based rank among
    /// the first 100 hits, or null.
    ranks: []const ?u32,
    keys: []const []const u8,
};

pub const Summary = struct {
    queries: usize = 0,
    /// Queries that have a relevant document (the means are over these; a query with only "not wanted" results has none).
    judged: usize = 0,
    /// Results marked not wanted that were found among the first k, over all queries.
    bad_in_k: u32 = 0,
    /// Results marked not wanted, over all queries.
    marked_bad: u32 = 0,
    failed: usize = 0,
    mean_precision: f64 = 0,
    mean_recall: f64 = 0,
    mrr: f64 = 0,
    mean_ndcg: f64 = 0,
};

pub const Report = struct {
    k: u32,
    results: []const QueryResult,
    summary: Summary,
};

pub const EvalError = error{ OutOfMemory, InvalidK };

/// How the search is asked: like a person's search on the page, so the numbers say what they would see.
pub const Options = struct {
    /// The languages the reader prefers (`Accept-Language`): other languages rank lower.
    prefer_languages: []const []const u8 = &.{},
    /// At most this many results from one domain (`[search] per_domain`).
    per_domain: u32 = 3,
};

pub fn evaluate(arena: Allocator, searcher: search.Searcher, judgments: []const Judgment, k: u32) EvalError!Report {
    return evaluateWith(arena, searcher, judgments, k, .{});
}

/// The pictures are left out and a page that is in the index twice (two sources) counts once, as on the results page.
pub fn evaluateWith(arena: Allocator, searcher: search.Searcher, judgments: []const Judgment, k: u32, opts: Options) EvalError!Report {
    if (k < 1 or k > max_k) return error.InvalidK;
    var results: std.ArrayList(QueryResult) = .empty;
    var sum: Summary = .{};
    for (judgments) |j| {
        sum.marked_bad += @intCast(j.irrelevant.len);
        var r: QueryResult = .{
            .query = j.query,
            .relevant_total = @intCast(j.relevant.len),
            .ranks = try arena.alloc(?u32, j.relevant.len),
            .keys = try arena.alloc([]const u8, j.relevant.len),
        };
        const ranks: []?u32 = @constCast(r.ranks);
        const keys: [][]const u8 = @constCast(r.keys);
        for (j.relevant, 0..) |rel, i| {
            ranks[i] = null;
            keys[i] = rel.key;
        }
        const no_pictures = [_]search.Filter{.{ .field = .kind, .negate = true, .text = "image" }};
        const page = searcher.search(arena, .{ .text = j.query, .limit = max_k, .filters = &no_pictures, .per_domain = opts.per_domain, .prefer_languages = opts.prefer_languages }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                r.failed = true;
                sum.failed += 1;
                sum.queries += 1;
                if (j.relevant.len > 0) sum.judged += 1;
                try results.append(arena, r);
                continue;
            },
        };

        // Which judged document (if any) is each hit, and at what rank.
        var gains: std.ArrayList(u32) = .empty; // grade of each hit within k, 0 if unjudged
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var shown: usize = 0;
        for (page.hits) |h| {
            if (h.url) |u| {
                if ((try seen.getOrPut(arena, u)).found_existing) continue;
            }
            defer shown += 1;
            const idhex = std.fmt.bytesToHex(h.id, .lower);
            var grade: u32 = 0;
            for (j.relevant, 0..) |rel, i| {
                const hit_match = (h.url != null and std.mem.eql(u8, h.url.?, rel.key)) or std.ascii.eqlIgnoreCase(&idhex, rel.key);
                if (hit_match) {
                    if (ranks[i] == null) ranks[i] = @intCast(shown + 1);
                    grade = @max(grade, rel.grade);
                }
            }
            if (shown < k) {
                try gains.append(arena, grade);
                for (j.irrelevant) |bad| {
                    if ((h.url != null and std.mem.eql(u8, h.url.?, bad)) or std.ascii.eqlIgnoreCase(&idhex, bad)) {
                        r.bad_in_k += 1;
                        break;
                    }
                }
            }
        }
        sum.bad_in_k += r.bad_in_k;
        if (j.relevant.len == 0) {
            // Only results that are not wanted were marked: nothing to score, only the count of those that came up.
            sum.queries += 1;
            try results.append(arena, r);
            continue;
        }

        var dcg: f64 = 0;
        for (gains.items, 0..) |g, pos| {
            if (g > 0) {
                r.found_in_k += 1;
                if (r.reciprocal_rank == 0) r.reciprocal_rank = 1.0 / @as(f64, @floatFromInt(pos + 1));
            }
            dcg += gain(g) / std.math.log2(@as(f64, @floatFromInt(pos + 2)));
        }
        // The best possible: the judged grades, highest first.
        const sorted = try arena.alloc(u32, j.relevant.len);
        for (j.relevant, 0..) |rel, i| sorted[i] = rel.grade;
        std.mem.sort(u32, sorted, {}, std.sort.desc(u32));
        var ideal: f64 = 0;
        for (sorted[0..@min(sorted.len, k)], 0..) |g, pos| ideal += gain(g) / std.math.log2(@as(f64, @floatFromInt(pos + 2)));

        const kf: f64 = @floatFromInt(k);
        r.precision = @as(f64, @floatFromInt(r.found_in_k)) / kf;
        r.recall = @as(f64, @floatFromInt(r.found_in_k)) / @as(f64, @floatFromInt(j.relevant.len));
        r.ndcg = if (ideal > 0) dcg / ideal else 0;

        sum.queries += 1;
        sum.judged += 1;
        sum.mean_precision += r.precision;
        sum.mean_recall += r.recall;
        sum.mrr += r.reciprocal_rank;
        sum.mean_ndcg += r.ndcg;
        try results.append(arena, r);
    }
    // A failed query scores zero in every mean (it found nothing).
    if (sum.judged > 0) {
        const n: f64 = @floatFromInt(sum.judged);
        sum.mean_precision /= n;
        sum.mean_recall /= n;
        sum.mrr /= n;
        sum.mean_ndcg /= n;
    }
    return .{ .k = k, .results = results.items, .summary = sum };
}

fn gain(grade: u32) f64 {
    // 2^grade - 1, the usual graded gain; grades are at most 100, so cap the
    // exponent to stay finite.
    if (grade == 0) return 0;
    return std.math.pow(f64, 2, @floatFromInt(@min(grade, 30))) - 1;
}

/// A fixed-width table, then the means, then the judged documents that did not
/// make the top k with their rank (or "not in the first 100").
pub fn writeText(w: *std.Io.Writer, rep: Report) std.Io.Writer.Error!void {
    try w.print("{s:<40} {s:>6} {s:>6} {s:>6} {s:>7} {s:>6}\n", .{ "query", "P@k", "R@k", "RR", "nDCG@k", "Bad@k" });
    for (rep.results) |r| {
        var qb: [40]u8 = undefined;
        const q = shortQuery(&qb, r.query);
        if (r.failed) {
            try w.print("{s:<40} search failed\n", .{q});
        } else {
            if (r.relevant_total == 0) {
                try w.print("{s:<40} {s:>6} {s:>6} {s:>6} {s:>7} {d:>6}\n", .{ q, "-", "-", "-", "-", r.bad_in_k });
            } else {
                try w.print("{s:<40} {d:>6.2} {d:>6.2} {d:>6.2} {d:>7.2} {d:>6}\n", .{ q, r.precision, r.recall, r.reciprocal_rank, r.ndcg, r.bad_in_k });
            }
        }
    }
    const s = rep.summary;
    try w.print("\nk = {d}; {d} queries ({d} failed)\n", .{ rep.k, s.queries, s.failed });
    if (s.marked_bad > 0) try w.print("results marked not wanted: {d}, of which {d} came up in the top k\n", .{ s.marked_bad, s.bad_in_k });
    try w.print("mean precision@k {d:.3}   mean recall@k {d:.3}   MRR {d:.3}   mean nDCG@k {d:.3}\n", .{ s.mean_precision, s.mean_recall, s.mrr, s.mean_ndcg });
    var header = false;
    for (rep.results) |r| {
        for (r.ranks, r.keys) |rk, key| {
            if (rk) |n| if (n <= rep.k) continue;
            if (!header) {
                try w.writeAll("\nJudged documents outside the top k:\n");
                header = true;
            }
            if (rk) |n| {
                try w.print("  {s}: {s} ranks {d}\n", .{ r.query, key, n });
            } else {
                try w.print("  {s}: {s} not in the first {d}\n", .{ r.query, key, max_k });
            }
        }
    }
}

fn shortQuery(buf: *[40]u8, q: []const u8) []const u8 {
    if (q.len <= buf.len) return q;
    var n: usize = buf.len - 3;
    while (n > 0 and (q[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(buf[0..n], q[0..n]);
    @memcpy(buf[n .. n + 3], "...");
    return buf[0 .. n + 3];
}

/// The report as one JSON object.
pub fn writeJson(w: *std.Io.Writer, rep: Report) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("k");
    try s.write(rep.k);
    try s.objectField("queries");
    try s.write(rep.summary.queries);
    try s.objectField("failed");
    try s.write(rep.summary.failed);
    try s.objectField("judged");
    try s.write(rep.summary.judged);
    try s.objectField("marked_bad");
    try s.write(rep.summary.marked_bad);
    try s.objectField("bad_in_k");
    try s.write(rep.summary.bad_in_k);
    try s.objectField("mean_precision");
    try s.write(rep.summary.mean_precision);
    try s.objectField("mean_recall");
    try s.write(rep.summary.mean_recall);
    try s.objectField("mrr");
    try s.write(rep.summary.mrr);
    try s.objectField("mean_ndcg");
    try s.write(rep.summary.mean_ndcg);
    try s.objectField("results");
    try s.beginArray();
    for (rep.results) |r| {
        try s.beginObject();
        try s.objectField("query");
        try s.write(r.query);
        try s.objectField("failed");
        try s.write(r.failed);
        try s.objectField("relevant");
        try s.write(r.relevant_total);
        try s.objectField("found_in_k");
        try s.write(r.found_in_k);
        try s.objectField("bad_in_k");
        try s.write(r.bad_in_k);
        try s.objectField("precision");
        try s.write(r.precision);
        try s.objectField("recall");
        try s.write(r.recall);
        try s.objectField("reciprocal_rank");
        try s.write(r.reciprocal_rank);
        try s.objectField("ndcg");
        try s.write(r.ndcg);
        try s.objectField("ranks");
        try s.beginObject();
        for (r.keys, r.ranks) |key, rk| {
            try s.objectField(key);
            try s.write(rk);
        }
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try w.writeByte('\n');
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const doc = @import("document.zig");

/// A searcher that returns a fixed list of URLs for any query, or fails for
/// the query "fail".
const Fake = struct {
    urls: []const []const u8,
    fn doSearch(ptr: *anyopaque, arena: Allocator, q: search.Query) search.Error!search.Page {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, q.text, "fail")) return error.EmptyQuery;
        const hits = try arena.alloc(search.Hit, self.urls.len);
        for (self.urls, hits, 0..) |u, *h, i| {
            h.* = .{ .id = doc.idFromSource("t", u), .connector = "t", .url = u, .title = null, .snippet = null, .score = 100 - @as(f64, @floatFromInt(i)) };
        }
        return .{ .hits = hits, .has_more = false };
    }
    fn searcher(self: *Fake) search.Searcher {
        return .{ .ptr = self, .vtable = &.{ .search = doSearch } };
    }
};

test "judgments parse, with lists, grades, comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const j = try parseJudgments(arena.allocator(),
        \\# a comment
        \\{"query": "a b", "relevant": ["u1", "u2"]}
        \\
        \\{"query": "c", "relevant": {"u3": 3, "u4": 1}}
    , &d);
    try testing.expectEqual(@as(usize, 2), j.len);
    try testing.expectEqual(@as(usize, 2), j[0].relevant.len);
    try testing.expectEqual(@as(u32, 1), j[0].relevant[0].grade);
    try testing.expectEqual(@as(u32, 3), j[1].relevant[0].grade);
    try testing.expectEqual(@as(usize, 2), j[0].line);
    try testing.expectEqual(@as(usize, 4), j[1].line);
}

test "bad judgments say which line is wrong" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const cases = [_]struct { text: []const u8, line: usize }{
        .{ .text = "{\"query\":\"x\",\"relevant\":[\"u\"]}\nnot json", .line = 2 },
        .{ .text = "[1]", .line = 1 },
        .{ .text = "{\"relevant\":[\"u\"]}", .line = 1 },
        .{ .text = "{\"query\":\"x\"}", .line = 1 },
        .{ .text = "{\"query\":\"x\",\"relevant\":[]}", .line = 1 },
        .{ .text = "{\"query\":\"x\",\"relevant\":[3]}", .line = 1 },
        .{ .text = "{\"query\":\"x\",\"relevant\":{\"u\":0}}", .line = 1 },
        .{ .text = "{\"query\":\"\",\"relevant\":[\"u\"]}", .line = 1 },
        .{ .text = "\n\n", .line = 0 },
    };
    for (cases) |c| {
        try testing.expectError(error.BadJudgments, parseJudgments(arena.allocator(), c.text, &d));
        try testing.expectEqual(c.line, d.line);
    }
}

test "metrics for a known ranking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .urls = &.{ "x1", "r1", "x2", "r2", "x3", "x4" } };
    var d: Diagnostic = .{};
    const j = try parseJudgments(a,
        \\{"query": "q", "relevant": ["r1", "r2", "r3"]}
        \\{"query": "fail", "relevant": ["r1"]}
        \\{"query": "q2", "relevant": {"r2": 3, "r1": 1}}
    , &d);
    const rep = try evaluate(a, fake.searcher(), j, 4);

    const r0 = rep.results[0];
    try testing.expectEqual(@as(u32, 2), r0.found_in_k); // r1 at 2, r2 at 4
    try testing.expectApproxEqAbs(@as(f64, 0.5), r0.precision, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), r0.recall, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), r0.reciprocal_rank, 1e-9);
    // DCG = 1/log2(3) + 1/log2(5); ideal = 1/log2(2) + 1/log2(3) + 1/log2(4).
    const dcg = 1.0 / std.math.log2(3.0) + 1.0 / std.math.log2(5.0);
    const ideal = 1.0 + 1.0 / std.math.log2(3.0) + 0.5;
    try testing.expectApproxEqAbs(dcg / ideal, r0.ndcg, 1e-9);
    try testing.expectEqual(@as(?u32, 2), r0.ranks[0]);
    try testing.expectEqual(@as(?u32, 4), r0.ranks[1]);
    try testing.expectEqual(@as(?u32, null), r0.ranks[2]);

    try testing.expect(rep.results[1].failed);
    try testing.expectEqual(@as(usize, 1), rep.summary.failed);
    try testing.expectEqual(@as(usize, 3), rep.summary.queries);

    // Graded: r2 (grade 3) at rank 4, r1 (grade 1) at rank 2.
    const r2 = rep.results[2];
    const g_dcg = 1.0 / std.math.log2(3.0) + 7.0 / std.math.log2(5.0);
    const g_ideal = 7.0 + 1.0 / std.math.log2(3.0);
    try testing.expectApproxEqAbs(g_dcg / g_ideal, r2.ndcg, 1e-9);

    // The mean counts the failed query as zero.
    try testing.expectApproxEqAbs((0.5 + 0 + 0.5) / 3.0, rep.summary.mrr, 1e-9);
}

test "ids match like urls, and the report prints" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .urls = &.{ "x1", "target" } };
    const id = std.fmt.bytesToHex(doc.idFromSource("t", "target"), .lower);
    const text = try std.fmt.allocPrint(a, "{{\"query\": \"q\", \"relevant\": [\"{s}\", \"gone\"]}}", .{id});
    var d: Diagnostic = .{};
    const j = try parseJudgments(a, text, &d);
    const rep = try evaluate(a, fake.searcher(), j, 10);
    try testing.expectEqual(@as(u32, 1), rep.results[0].found_in_k);
    try testing.expectEqual(@as(?u32, 2), rep.results[0].ranks[0]);
    try testing.expectEqual(@as(?u32, null), rep.results[0].ranks[1]);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeText(&w, rep);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "mean precision@k 0.100") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "gone not in the first 100") != null);
    var w2: std.Io.Writer = .fixed(&buf);
    try writeJson(&w2, rep);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, w2.buffered(), .{});
    try testing.expectEqual(@as(i64, 1), parsed.object.get("queries").?.integer);
    try testing.expectError(error.InvalidK, evaluate(a, fake.searcher(), j, 0));
    try testing.expectError(error.InvalidK, evaluate(a, fake.searcher(), j, 101));
}

test "feedback lines, not-wanted results and repeated queries are merged into one judgment per query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    const j = try parseJudgments(a,
        \\{"query": "q", "relevant": ["good"]}
        \\{"query": "q", "url": "bad", "grade": -1, "time": 5}
        \\{"query": "q", "url": "wrong-click", "grade": 1}
        \\{"query": "q", "url": "wrong-click", "grade": 0}
        \\{"query": "q", "url": "good", "grade": 3}
        \\{"query": "only bad", "irrelevant": ["x", "y"]}
        \\{"query": "taken back", "url": "z", "grade": 1}
        \\{"query": "taken back", "url": "z", "grade": 0}
    , &d);
    try testing.expectEqual(@as(usize, 2), j.len); // "taken back" is gone
    try testing.expectEqualStrings("q", j[0].query);
    try testing.expectEqual(@as(usize, 1), j[0].relevant.len);
    try testing.expectEqual(@as(u32, 3), j[0].relevant[0].grade); // the last grade wins
    try testing.expectEqual(@as(usize, 1), j[0].irrelevant.len);
    try testing.expectEqualStrings("bad", j[0].irrelevant[0]);
    try testing.expectEqual(@as(usize, 0), j[1].relevant.len);
    try testing.expectEqual(@as(usize, 2), j[1].irrelevant.len);
    try testing.expectEqual(@as(usize, 1), j[0].line);
    var bad: Diagnostic = .{};
    try testing.expectError(error.BadJudgments, parseJudgments(a, "{\"query\":\"q\",\"url\":\"u\",\"grade\":7.5}", &bad));
    try testing.expectError(error.BadJudgments, parseJudgments(a, "{\"query\":\"q\",\"url\":\"u\",\"grade\":-5}", &bad));
}

test "results marked not wanted are counted in the top k, and a query with only those has no scores" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .urls = &.{ "x1", "x2", "target" } };
    var d: Diagnostic = .{};
    const j = try parseJudgments(a,
        \\{"query": "q", "relevant": ["target"], "irrelevant": ["x1", "gone"]}
        \\{"query": "p", "irrelevant": ["x2", "x3"]}
    , &d);
    const rep = try evaluate(a, fake.searcher(), j, 10);
    try testing.expectEqual(@as(u32, 1), rep.results[0].bad_in_k);
    try testing.expectEqual(@as(u32, 1), rep.results[1].bad_in_k);
    try testing.expectEqual(@as(usize, 2), rep.summary.queries);
    try testing.expectEqual(@as(usize, 1), rep.summary.judged);
    try testing.expectEqual(@as(u32, 4), rep.summary.marked_bad);
    try testing.expectEqual(@as(u32, 2), rep.summary.bad_in_k);
    try testing.expect(rep.summary.mrr > 0.3 and rep.summary.mrr < 0.34); // the means are over the judged query only
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeText(&w, rep);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "results marked not wanted: 4, of which 2 came up in the top k") != null);
}
