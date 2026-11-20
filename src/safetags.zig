//! Safe search by the tags of a page (docs/decisions/0076). The domain lists decide by site; this decides by what a page says
//! about itself, with the tags the crawler read (ADR 0074). A tag is evidence, not proof: one strong tag, or two weak ones, of
//! a category that is active in the chosen mode hides the page; one weak tag does not. The categories are a TOML file
//! (`assets/safe_tags.toml` is the default; `[safe_search] tags_file` replaces it) so a new tag needs no release.
//!
//! The result is a piece of SQL added to a search while safe search is on. Tags are compared in a compact form (lower case, only
//! letters and digits), so "Rope Bunny", "rope_bunny" and "#RopeBunny" are one tag; nothing is matched by pattern.

const std = @import("std");
const toml = @import("toml");
const Allocator = std.mem.Allocator;

pub const default_text = @embedFile("assets/safe_tags.toml");

pub const Mode = enum { off, moderate, strict };

pub const Level = enum { moderate, strict };

pub const Category = struct {
    name: []const u8,
    level: Level,
    /// One of these tags hides a page.
    strong: []const []const u8,
    /// Two of these (together across the active categories) hide it.
    weak: []const []const u8,
};

pub const Error = error{ OutOfMemory, Malformed };

/// A tag in its compact form: lower case, letters, digits and non-ASCII bytes only; null when nothing is left or it is long.
pub fn compact(arena: Allocator, tag: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (tag) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(arena, std.ascii.toLower(c));
        } else if (c >= 0x80) try out.append(arena, c);
    }
    if (out.items.len == 0 or out.items.len > 60) return null;
    return out.items;
}

fn stringArray(arena: Allocator, t: *const toml.Table, key: []const u8) Error![]const []const u8 {
    const v = t.get(key) orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        else => return error.Malformed,
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items.items) |item| switch (item) {
        .string => |s| if (try compact(arena, s)) |c| try out.append(arena, c),
        else => return error.Malformed,
    };
    return out.items;
}

/// The categories of a TOML text (`[[category]]` tables with `name`, `level`, `strong` and `weak`).
pub fn parse(arena: Allocator, text: []const u8) Error![]const Category {
    var d: toml.Diagnostic = .{};
    var doc = toml.Document.parse(arena, text, .{}, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    defer doc.deinit();
    const v = doc.root.get("category") orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        else => return error.Malformed,
    };
    var out: std.ArrayList(Category) = .empty;
    for (arr.items.items) |item| {
        const t = switch (item) {
            .table => |tb| tb,
            else => return error.Malformed,
        };
        const name = t.getString("name") orelse return error.Malformed;
        const level: Level = if (t.getString("level")) |l|
            (if (std.mem.eql(u8, l, "strict")) .strict else if (std.mem.eql(u8, l, "moderate")) .moderate else return error.Malformed)
        else
            .moderate;
        try out.append(arena, .{ .name = try arena.dupe(u8, name), .level = level, .strong = try dupeAll(arena, try stringArray(arena, t, "strong")), .weak = try dupeAll(arena, try stringArray(arena, t, "weak")) });
    }
    return out.items;
}

// The document's arena is the caller's arena, so its strings live as long as the result; the copy keeps that explicit.
fn dupeAll(arena: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |s, *d| d.* = try arena.dupe(u8, s);
    return out;
}

fn active(c: Category, mode: Mode, off: []const []const u8) bool {
    switch (mode) {
        .off => return false,
        .moderate => if (c.level != .moderate) return false,
        .strict => {},
    }
    for (off) |n| if (std.ascii.eqlIgnoreCase(n, c.name)) return false;
    return true;
}

fn sqlList(arena: Allocator, out: *std.ArrayList(u8), words: []const []const u8) Allocator.Error!void {
    for (words, 0..) |w, i| {
        if (i > 0) try out.append(arena, ',');
        try out.append(arena, '\'');
        for (w) |c| {
            if (c == '\'') try out.append(arena, '\'');
            try out.append(arena, c);
        }
        try out.append(arena, '\'');
    }
}

/// The SQL (` AND NOT (...)`, for a query on `docs d`) that leaves out the pages the active categories describe; empty when
/// there is nothing to leave out. `off` names categories to skip.
pub fn clause(arena: Allocator, categories: []const Category, mode: Mode, off: []const []const u8) Allocator.Error![]const u8 {
    var strong: std.ArrayList([]const u8) = .empty;
    var weak: std.ArrayList([]const u8) = .empty;
    for (categories) |c| {
        if (!active(c, mode, off)) continue;
        try strong.appendSlice(arena, c.strong);
        try weak.appendSlice(arena, c.weak);
    }
    if (strong.items.len == 0 and weak.items.len == 0) return "";
    const form = "replace(replace(replace(replace(lower(m.value), ' ', ''), '-', ''), '_', ''), '#', '')";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, " AND NOT (");
    if (strong.items.len > 0) {
        try out.print(arena, "EXISTS (SELECT 1 FROM doc_meta m WHERE m.doc = d.rowid AND m.key = 'tag' AND {s} IN (", .{form});
        try sqlList(arena, &out, strong.items);
        try out.appendSlice(arena, "))");
    }
    if (weak.items.len > 0) {
        if (strong.items.len > 0) try out.appendSlice(arena, " OR ");
        try out.print(arena, "(SELECT count(*) FROM doc_meta m WHERE m.doc = d.rowid AND m.key = 'tag' AND {s} IN (", .{form});
        try sqlList(arena, &out, weak.items);
        try out.appendSlice(arena, ")) >= 2");
    }
    try out.append(arena, ')');
    return out.items;
}

/// Loads the categories from `text`, and builds the clause for `mode`.
pub fn build(arena: Allocator, text: []const u8, mode: Mode, off: []const []const u8) Error![]const u8 {
    return clause(arena, try parse(arena, text), mode, off);
}

const testing = std.testing;

test "the shipped list parses, has every category, and keeps medical and educational tags out" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cats = try parse(a, default_text);
    try testing.expect(cats.len >= 5);
    var seen_strict = false;
    for (cats) |c| {
        if (c.level == .strict) seen_strict = true;
        for ([_][]const u8{ "sexeducation", "sexualhealth", "reproductivehealth", "anatomy", "figuredrawing", "artisticnude", "naturism", "breastfeeding", "medical", "health", "art" }) |ok| {
            for (c.strong) |s| try testing.expect(!std.mem.eql(u8, s, ok));
            for (c.weak) |s| try testing.expect(!std.mem.eql(u8, s, ok));
        }
    }
    try testing.expect(seen_strict);
}

test "tags are compared in a compact form" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("ropebunny", (try compact(a, "#Rope_Bunny")).?);
    try testing.expectEqualStrings("ropebunny", (try compact(a, "rope bunny")).?);
    try testing.expectEqualStrings("xray", (try compact(a, "X-ray")).?);
    try testing.expect((try compact(a, "---")) == null);
}

test "modes pick the categories, and a category can be switched off" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\[[category]]
        \\name = "explicit"
        \\strong = ["Porn"]
        \\weak = ["nude"]
        \\[[category]]
        \\name = "suggestive"
        \\level = "strict"
        \\weak = ["bikini"]
    ;
    try testing.expectEqualStrings("", try build(a, text, .off, &.{}));
    const moderate = try build(a, text, .moderate, &.{});
    try testing.expect(std.mem.indexOf(u8, moderate, "'porn'") != null and std.mem.indexOf(u8, moderate, "'nude'") != null);
    try testing.expect(std.mem.indexOf(u8, moderate, "bikini") == null);
    const strict = try build(a, text, .strict, &.{});
    try testing.expect(std.mem.indexOf(u8, strict, "'bikini'") != null);
    const skipped = try build(a, text, .strict, &.{"EXPLICIT"});
    try testing.expect(std.mem.indexOf(u8, skipped, "porn") == null and std.mem.indexOf(u8, skipped, "'bikini'") != null);
    try testing.expectError(error.Malformed, parse(a, "[[category]]\nlevel = \"loud\"\nname = \"x\""));
    try testing.expectError(error.Malformed, parse(a, "category = 3"));
}
