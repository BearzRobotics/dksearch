//! The Block List Project's lists (https://github.com/blocklistproject/Lists, public domain / MIT), offered in the
//! administration interface as switches: each list can be downloaded and turned on or off. The files live in
//! `data_dir/lists/blocklistproject/NAME.txt`, the names of the lists in use in `data_dir/lists/blocklists.txt` (one per
//! line). A list in use makes its domains banned for everyone (not crawled, never shown), like any `blocklist_files`
//! entry, and the owner's `allow` list still takes domains out of it. Nothing is downloaded unless the administrator asks.

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

/// The names of the lists in use: lines of the enabled file that are names of the catalogue (the rest is ignored).
/// A missing file means none.
pub fn readEnabled(io: Io, arena: Allocator, data_dir: []const u8) Allocator.Error![]const []const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/lists/{s}", .{ std.mem.trimEnd(u8, data_dir, "/"), enabled_file });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (find(line)) |e| try out.append(arena, e.name);
    }
    return out.items;
}

pub fn isEnabled(enabled: []const []const u8, name: []const u8) bool {
    for (enabled) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

pub const WriteError = error{WriteFailed};

/// Saves the names in use (only catalogue names, in catalogue order).
pub fn writeEnabled(io: Io, arena: Allocator, data_dir: []const u8, names: []const []const u8) (Allocator.Error || WriteError)!void {
    const dir = try std.fmt.allocPrint(arena, "{s}/lists", .{std.mem.trimEnd(u8, data_dir, "/")});
    Io.Dir.cwd().createDirPath(io, dir) catch return error.WriteFailed;
    var text: std.ArrayList(u8) = .empty;
    for (catalog) |e| if (isEnabled(names, e.name)) {
        try text.appendSlice(arena, e.name);
        try text.append(arena, '\n');
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

test "the lists in use are saved in catalogue order, unknown names are dropped, and a missing file means none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const root = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".zig-cache", a);
    const dir = try std.fmt.allocPrint(a, "{s}/tmp/{s}", .{ root, tmp.sub_path });
    try testing.expectEqual(@as(usize, 0), (try readEnabled(testing.io, a, dir)).len);
    try writeEnabled(testing.io, a, dir, &.{ "ads", "evil", "phishing" });
    const got = try readEnabled(testing.io, a, dir);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("phishing", got[0]); // catalogue order
    try testing.expectEqualStrings("ads", got[1]);
    try testing.expect(isEnabled(got, "ads") and !isEnabled(got, "fraud"));
    try testing.expectEqualStrings("https://example.org/x/ads.txt", try url(a, "https://example.org/x/", "ads"));
}
