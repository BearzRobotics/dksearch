//! The Block List Project's lists (https://github.com/blocklistproject/Lists, public domain / MIT), offered in the
//! administration interface as switches: each list can be downloaded and turned on or off. The files live in
//! `data_dir/lists/blocklistproject/NAME.txt`, the names of the lists in use in `data_dir/lists/blocklists.txt` (one per
//! line, `NAME` for a ban or `NAME safe`). A banned list makes its domains banned for everyone (not crawled, never shown),
//! like any `blocklist_files` entry, and the owner's `allow` list still takes domains out of it. A `safe` list hides its
//! domains only while safe search is on (like the safe-search list: adults unlock them with the PIN or an adult key) and
//! does not stop them from being crawled. Nothing is downloaded unless the administrator asks.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_base = "https://raw.githubusercontent.com/blocklistproject/Lists/master";
pub const enabled_file = "blocklists.txt";
pub const folder = "blocklistproject";

pub const Entry = struct {
    name: []const u8,
    /// What its domains are.
    what: []const u8,
    /// Whether it blocks well-known sites that people use for content (so that turning it on is a real decision).
    big_sites: bool = false,
};

/// The lists of the project, in the order shown.
pub const catalog = [_]Entry{
    .{ .name = "phishing", .what = "Phishing sites" },
    .{ .name = "fraud", .what = "Fraud and deceptive sites" },
    .{ .name = "scam", .what = "Scam sites" },
    .{ .name = "abuse", .what = "Sites known for abuse (a wide list)" },
    .{ .name = "malware", .what = "Malware hosts (a very large list: it takes a lot of memory)" },
    .{ .name = "ransomware", .what = "Ransomware" },
    .{ .name = "ads", .what = "Advertising domains" },
    .{ .name = "tracking", .what = "Trackers and analytics" },
    .{ .name = "redirect", .what = "Redirect and click-farm domains" },
    .{ .name = "drugs", .what = "Drug sales" },
    .{ .name = "gambling", .what = "Gambling sites" },
    .{ .name = "piracy", .what = "Piracy sites" },
    .{ .name = "torrent", .what = "Torrent sites" },
    .{ .name = "crypto", .what = "Cryptocurrency mining and scams" },
    .{ .name = "vaping", .what = "Vaping shops" },
    .{ .name = "porn", .what = "Adult sites (banned for everyone; safe search hides adult sites only for those who have not unlocked it)", .big_sites = true },
    .{ .name = "basic", .what = "The project's general starter list", .big_sites = true },
    .{ .name = "adobe", .what = "Adobe's servers", .big_sites = true },
    .{ .name = "facebook", .what = "Facebook and its domains", .big_sites = true },
    .{ .name = "twitter", .what = "Twitter / X domains", .big_sites = true },
    .{ .name = "tiktok", .what = "TikTok domains", .big_sites = true },
    .{ .name = "whatsapp", .what = "WhatsApp domains", .big_sites = true },
    .{ .name = "youtube", .what = "YouTube domains", .big_sites = true },
    .{ .name = "smart-tv", .what = "Smart-TV telemetry", .big_sites = true },
};

pub fn find(name: []const u8) ?Entry {
    for (catalog) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

pub fn filePath(arena: Allocator, data_dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{s}/lists/{s}/{s}.txt", .{ std.mem.trimEnd(u8, data_dir, "/"), folder, name });
}

pub fn url(arena: Allocator, base: []const u8, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}.txt", .{ std.mem.trimEnd(u8, base, "/"), name });
}

/// What a list does when it is on.
pub const Mode = enum { off, ban, safe };

pub const Chosen = struct { name: []const u8, mode: Mode };

/// The lists in use and what each does: lines of the file that start with a name of the catalogue, `NAME` (ban) or
/// `NAME safe` (the rest of the line is ignored). A missing file means none.
pub fn readChosen(io: Io, arena: Allocator, data_dir: []const u8) Allocator.Error![]const Chosen {
    const path = try std.fmt.allocPrint(arena, "{s}/lists/{s}", .{ std.mem.trimEnd(u8, data_dir, "/"), enabled_file });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return &.{};
    var out: std.ArrayList(Chosen) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const name = parts.next() orelse continue;
        const e = find(name) orelse continue;
        const mode: Mode = if (parts.next()) |m| (if (std.mem.eql(u8, m, "safe")) .safe else .ban) else .ban;
        try out.append(arena, .{ .name = e.name, .mode = mode });
    }
    return out.items;
}

/// What the list `name` does among `chosen` (off when it is not there).
pub fn modeOf(chosen: []const Chosen, name: []const u8) Mode {
    for (chosen) |c| if (std.mem.eql(u8, c.name, name)) return c.mode;
    return .off;
}

pub const WriteError = error{WriteFailed};

/// Saves the choice (only catalogue names, in catalogue order; lists that are off are not written).
pub fn writeChosen(io: Io, arena: Allocator, data_dir: []const u8, chosen: []const Chosen) (Allocator.Error || WriteError)!void {
    const dir = try std.fmt.allocPrint(arena, "{s}/lists", .{std.mem.trimEnd(u8, data_dir, "/")});
    Io.Dir.cwd().createDirPath(io, dir) catch return error.WriteFailed;
    var text: std.ArrayList(u8) = .empty;
    for (catalog) |e| switch (modeOf(chosen, e.name)) {
        .off => {},
        .ban => {
            try text.appendSlice(arena, e.name);
            try text.append(arena, '\n');
        },
        .safe => {
            try text.appendSlice(arena, e.name);
            try text.appendSlice(arena, " safe\n");
        },
    };
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, enabled_file });
    const tmp = try std.fmt.allocPrint(arena, "{s}.new", .{path});
    {
        const f = Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true }) catch return error.WriteFailed;
        defer f.close(io);
        f.writePositionalAll(io, text.items, 0) catch return error.WriteFailed;
    }
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io) catch return error.WriteFailed;
}

const testing = std.testing;

test "the catalogue has unique plain names" {
    for (catalog, 0..) |e, i| {
        for (e.name) |c| try testing.expect(std.ascii.isLower(c) or c == '-');
        for (catalog[i + 1 ..]) |o| try testing.expect(!std.mem.eql(u8, e.name, o.name));
    }
    try testing.expect(find("phishing") != null and find("nonsense") == null);
}

test "the lists in use are saved in catalogue order with their mode, unknown names are dropped, and a missing file means none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const root = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".zig-cache", a);
    const dir = try std.fmt.allocPrint(a, "{s}/tmp/{s}", .{ root, tmp.sub_path });
    try testing.expectEqual(@as(usize, 0), (try readChosen(testing.io, a, dir)).len);
    try writeChosen(testing.io, a, dir, &.{ .{ .name = "ads", .mode = .ban }, .{ .name = "evil", .mode = .ban }, .{ .name = "porn", .mode = .safe }, .{ .name = "phishing", .mode = .ban }, .{ .name = "drugs", .mode = .off } });
    const got = try readChosen(testing.io, a, dir);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("phishing", got[0].name); // catalogue order
    try testing.expectEqualStrings("ads", got[1].name);
    try testing.expectEqualStrings("porn", got[2].name);
    try testing.expect(modeOf(got, "ads") == .ban and modeOf(got, "porn") == .safe and modeOf(got, "fraud") == .off and modeOf(got, "drugs") == .off);
    // An old file (a name per line) means ban.
    const raw = try Io.Dir.cwd().readFileAlloc(testing.io, try std.fmt.allocPrint(a, "{s}/lists/{s}", .{ dir, enabled_file }), a, .limited(1000));
    try testing.expectEqualStrings("phishing\nads\nporn safe\n", raw);
    try testing.expectEqualStrings("https://example.org/x/ads.txt", try url(a, "https://example.org/x/", "ads"));
}
