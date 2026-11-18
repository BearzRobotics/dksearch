//! Downloading a domain list on request (docs/decisions/0048): `dksearch fetch-banlist` fetches one list from an address
//! the owner names, checks that it is a list of domains or hashes of domains, and replaces the file atomically. Nothing
//! is downloaded unless the owner runs it, and nothing is bundled: a published list (such as a service's list of banned
//! domains) stays the publisher's, fetched from them each time.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const domainlist = @import("domainlist.zig");

const have_http = build_options.crawler;
const fetch = if (have_http) @import("connectors/crawl/fetch.zig") else struct {};

pub const Error = error{ NotAvailable, BadAddress, Unreachable, Refused, NotAList, TooLarge, WriteFailed, OutOfMemory };

pub const max_bytes: usize = 64 * 1024 * 1024;

pub const Stats = struct { lines: usize = 0, hashes: usize = 0, domains: usize = 0, other: usize = 0 };

/// What a downloaded text is made of: hashes (32 hex digits), domains, comments and blanks, and anything else.
pub fn analyze(text: []const u8) Stats {
    var st: Stats = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        st.lines += 1;
        const d = domainlist.entryOf(line) orelse {
            st.other += 1;
            continue;
        };
        if (d.len == 32 and std.mem.indexOfNone(u8, d, "0123456789abcdefABCDEF") == null) {
            st.hashes += 1;
        } else if (looksLikeDomain(d)) {
            st.domains += 1;
        } else st.other += 1;
    }
    return st;
}

fn looksLikeDomain(d: []const u8) bool {
    if (d.len < 3 or d.len > 253 or std.mem.indexOfScalar(u8, d, '.') == null) return false;
    for (d) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c >= 0x80)) return false;
    return true;
}

/// A page of HTML or an error message is not a list: at least one entry, and under 1 in 100 lines unusable.
pub fn acceptable(st: Stats) bool {
    const good = st.hashes + st.domains;
    return good > 0 and st.other * 100 <= st.lines;
}

pub const Result = struct { stats: Stats, bytes: usize };

/// Fetches `url` (https, unless `allow_http`), follows up to three redirects, checks the text and replaces `out_path`.
pub fn download(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, out_path: []const u8, allow_http: bool) Error!Result {
    if (!have_http) return error.NotAvailable;
    if (!(std.mem.startsWith(u8, url, "https://") or (allow_http and std.mem.startsWith(u8, url, "http://")))) return error.BadAddress;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var current = url;
    var hops: u32 = 0;
    const body = while (true) : (hops += 1) {
        const resp = fetch.get(&client, arena, .{
            .url = current,
            .user_agent = "dksearch-list-fetch/0.1",
            .accept = "text/plain, */*",
            .max_body_bytes = max_bytes,
        }, .fromSeconds(180)) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooLarge => error.TooLarge,
            else => error.Unreachable,
        };
        if (resp.status >= 300 and resp.status < 400) {
            const loc = resp.location orelse return error.Refused;
            if (hops >= 3) return error.Refused;
            current = try resolve(arena, current, loc);
            if (!(std.mem.startsWith(u8, current, "https://") or (allow_http and std.mem.startsWith(u8, current, "http://")))) return error.Refused;
            continue;
        }
        if (resp.status != 200) return error.Refused;
        break resp.body;
    };
    const st = analyze(body);
    if (!acceptable(st)) return error.NotAList;
    writeAtomic(io, arena, out_path, body) catch return error.WriteFailed;
    return .{ .stats = st, .bytes = body.len };
}

fn resolve(arena: Allocator, base: []const u8, loc: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, loc, "://") != null) return arena.dupe(u8, loc);
    const at = std.mem.indexOf(u8, base, "://") orelse return arena.dupe(u8, loc);
    const origin_end = std.mem.indexOfScalarPos(u8, base, at + 3, '/') orelse base.len;
    if (loc.len > 0 and loc[0] == '/') return std.fmt.allocPrint(arena, "{s}{s}", .{ base[0..origin_end], loc });
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base[0..origin_end], loc });
}

fn writeAtomic(io: Io, arena: Allocator, path: []const u8, data: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const tmp = try std.fmt.allocPrint(arena, "{s}.new", .{path});
    {
        const f = try cwd.createFile(io, tmp, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, data, 0);
    }
    cwd.rename(tmp, cwd, path, io) catch |e| {
        cwd.deleteFile(io, tmp) catch {};
        return e;
    };
}

const testing = std.testing;

test "a list of hashes or domains is accepted; a web page or an error is not" {
    const hashes = "# banned\n0123456789abcdef0123456789abcdef\nFEDCBA9876543210FEDCBA9876543210\n\n";
    const a = analyze(hashes);
    try testing.expectEqual(@as(usize, 2), a.hashes);
    try testing.expect(acceptable(a));
    const domains = analyze("0.0.0.0 bad.example\n||worse.example^\nplain.example\n");
    try testing.expectEqual(@as(usize, 3), domains.domains);
    try testing.expect(acceptable(domains));
    try testing.expect(!acceptable(analyze("<!doctype html>\n<html><body>Not found</body></html>\n")));
    try testing.expect(!acceptable(analyze("")));
    try testing.expect(!acceptable(analyze("# only comments\n")));
    // One stray line in a long list is tolerated; a tenth of them is not.
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    for (0..150) |i| try w.print("{x:0>32}\n", .{i});
    try w.writeAll("what is this\n");
    try testing.expect(acceptable(analyze(w.buffered())));
    try testing.expect(!acceptable(analyze("a.example\nnot a domain at all\nneither is this\n")));
}

test "relative redirects are resolved against the address" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expectEqualStrings("https://x.example/blacklist/banned/", try resolve(a, "https://x.example/banned/", "/blacklist/banned/"));
    try testing.expectEqualStrings("https://y.example/z", try resolve(a, "https://x.example/banned/", "https://y.example/z"));
    try testing.expectEqualStrings("https://x.example/list", try resolve(a, "https://x.example/banned", "list"));
}

const nettest = @import("connectors/nettest.zig");

test "download: follows a redirect, checks the list and replaces the file; refuses junk and https-less addresses" {
    if (!have_http) return error.SkipZigTest;
    var srv: nettest.TestServer = undefined;
    try srv.start(&.{
        .{ .path = "/banned", .status = 301, .location = "/blacklist/banned/" },
        .{ .path = "/blacklist/banned/", .content_type = "text/plain", .body = "0123456789abcdef0123456789abcdef\nfedcba9876543210fedcba9876543210\n" },
        .{ .path = "/page", .body = "<html><body>hello</body></html>" },
        .{ .path = "/gone", .status = 404, .body = "x" },
    });
    defer srv.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const out = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ban.txt", .{tmp.sub_path});
    var ub: [96]u8 = undefined;
    const base = try std.fmt.bufPrint(&ub, "http://127.0.0.1:{d}", .{srv.port});
    // A plain-http address is refused unless the test allows it.
    try testing.expectError(error.BadAddress, download(testing.io, testing.allocator, a, try std.fmt.allocPrint(a, "{s}/banned", .{base}), out, false));
    const got = try download(testing.io, testing.allocator, a, try std.fmt.allocPrint(a, "{s}/banned", .{base}), out, true);
    try testing.expectEqual(@as(usize, 2), got.stats.hashes);
    const text = try tmp.dir.readFileAlloc(testing.io, "ban.txt", a, .limited(4096));
    try testing.expect(std.mem.startsWith(u8, text, "0123456789abcdef"));
    // Junk and errors leave the existing file alone.
    try testing.expectError(error.NotAList, download(testing.io, testing.allocator, a, try std.fmt.allocPrint(a, "{s}/page", .{base}), out, true));
    try testing.expectError(error.Refused, download(testing.io, testing.allocator, a, try std.fmt.allocPrint(a, "{s}/gone", .{base}), out, true));
    const still = try tmp.dir.readFileAlloc(testing.io, "ban.txt", a, .limited(4096));
    try testing.expectEqualStrings(text, still);
    // Nothing listening: unreachable, not a hang.
    try testing.expectError(error.Unreachable, download(testing.io, testing.allocator, a, "http://127.0.0.1:1/x", out, true));
}
