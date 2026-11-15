//! robots.txt (RFC 9309), enough for a polite crawler.
//!
//! `parse` keeps only the rules that apply to one product token: the groups
//! that name it (compared case-insensitively) or, if none does, the `*`
//! groups. Matching follows the RFC: the longest matching pattern wins, and
//! `allow` wins a tie; `*` matches any run of characters and a trailing `$`
//! anchors the end. `crawl-delay` (not in the RFC, but widely used) is read as
//! whole seconds. Everything the parser does not understand is ignored.
//!
//! There is no Zig library for this format; the grammar is a handful of
//! `field: value` lines, so a small parser is the exception allowed for it
//! (docs/decisions/0018).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Larger files are cut here, as the RFC allows (parsers must handle at
/// least 500 KiB).
pub const max_bytes = 512 * 1024;

pub const Rule = struct {
    allow: bool,
    pattern: []const u8,
};

pub const Rules = struct {
    rules: []const Rule = &.{},
    /// Seconds asked for between requests, if the file says so.
    crawl_delay_s: ?u32 = null,

    /// Nothing is disallowed (used for a missing robots.txt).
    pub const allow_all: Rules = .{};
    /// Everything is disallowed (used when robots.txt cannot be fetched).
    pub const disallow_all: Rules = .{ .rules = &.{.{ .allow = false, .pattern = "/" }} };

    /// `target` is the path plus query, e.g. "/a/b?c=1".
    pub fn allowed(self: Rules, target: []const u8) bool {
        var best_len: usize = 0;
        var best_allow = true;
        var matched = false;
        for (self.rules) |r| {
            if (r.pattern.len == 0) continue; // "Disallow:" with no value allows everything
            if (!matches(r.pattern, target)) continue;
            if (!matched or r.pattern.len > best_len or (r.pattern.len == best_len and r.allow and !best_allow)) {
                matched = true;
                best_len = r.pattern.len;
                best_allow = r.allow;
            }
        }
        return best_allow;
    }
};

/// The first token of a user agent string: "dksearch/1.0 (+https://x)" is
/// "dksearch". This is what robots.txt groups are matched against.
pub fn productToken(user_agent: []const u8) []const u8 {
    var end: usize = 0;
    while (end < user_agent.len) : (end += 1) {
        const c = user_agent[end];
        if (c == '/' or c == ' ' or c == '(' or c == ';') break;
    }
    return user_agent[0..end];
}

pub fn parse(arena: Allocator, text_in: []const u8, token: []const u8) Allocator.Error!Rules {
    var text = text_in[0..@min(text_in.len, max_bytes)];
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];

    var specific: std.ArrayList(Rule) = .empty;
    var star: std.ArrayList(Rule) = .empty;
    var specific_delay: ?u32 = null;
    var star_delay: ?u32 = null;
    var any_specific = false;

    // The current group: which agents it names, and whether it has rules yet
    // (a user-agent line after a rule starts a new group).
    var in_specific = false;
    var in_star = false;
    var group_has_rules = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (std.mem.indexOfScalar(u8, line, '#')) |h| line = line[0..h];
        line = std.mem.trim(u8, line, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const field = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(field, "user-agent")) {
            if (group_has_rules) {
                in_specific = false;
                in_star = false;
                group_has_rules = false;
            }
            if (std.mem.eql(u8, value, "*")) {
                in_star = true;
            } else if (token.len > 0 and std.ascii.eqlIgnoreCase(value, token)) {
                in_specific = true;
                any_specific = true;
            }
        } else if (std.ascii.eqlIgnoreCase(field, "allow") or std.ascii.eqlIgnoreCase(field, "disallow")) {
            group_has_rules = true;
            const rule: Rule = .{ .allow = std.ascii.eqlIgnoreCase(field, "allow"), .pattern = try arena.dupe(u8, value) };
            if (in_specific) try specific.append(arena, rule);
            if (in_star) try star.append(arena, rule);
        } else if (std.ascii.eqlIgnoreCase(field, "crawl-delay")) {
            group_has_rules = true;
            const secs = parseDelay(value) orelse continue;
            if (in_specific) specific_delay = secs;
            if (in_star) star_delay = secs;
        }
    }
    if (any_specific) return .{ .rules = specific.items, .crawl_delay_s = specific_delay };
    return .{ .rules = star.items, .crawl_delay_s = star_delay };
}

/// Whole seconds; a fractional value is rounded up, anything unusable is null.
fn parseDelay(v: []const u8) ?u32 {
    const f = std.fmt.parseFloat(f64, v) catch return null;
    if (!(f >= 0) or f > 86400) return null;
    return @intFromFloat(@ceil(f));
}

/// `pattern` against the start of `target`: `*` is any run, a final `$`
/// anchors the end. Iterative with one backtrack point per `*`, so hostile
/// patterns cannot take exponential time.
fn matches(pattern_in: []const u8, target: []const u8) bool {
    var pattern = pattern_in;
    var anchored = false;
    if (pattern.len > 0 and pattern[pattern.len - 1] == '$') {
        anchored = true;
        pattern = pattern[0 .. pattern.len - 1];
    }
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (true) {
        if (p == pattern.len) {
            if (!anchored or t == target.len) return true;
        } else if (pattern[p] == '*') {
            star_p = p;
            star_t = t;
            p += 1;
            continue;
        } else if (t < target.len and pattern[p] == target[t]) {
            p += 1;
            t += 1;
            continue;
        }
        // Mismatch (or an anchored pattern that stopped early): widen the last `*`.
        const sp = star_p orelse return false;
        if (star_t >= target.len) return false;
        star_t += 1;
        p = sp + 1;
        t = star_t;
    }
}

const testing = std.testing;

fn rulesFor(arena: Allocator, text: []const u8) !Rules {
    return parse(arena, text, "dksearch");
}

test "longest match wins and allow wins a tie" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try rulesFor(arena.allocator(),
        \\User-agent: *
        \\Disallow: /private/
        \\Allow: /private/open/
        \\Disallow: /tie
        \\Allow: /tie
    );
    try testing.expect(r.allowed("/"));
    try testing.expect(!r.allowed("/private/x"));
    try testing.expect(r.allowed("/private/open/x"));
    try testing.expect(r.allowed("/tie"));
}

test "wildcards and end anchors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try rulesFor(arena.allocator(),
        \\User-agent: *
        \\Disallow: /*.pdf$
        \\Disallow: /a*b*c
        \\Disallow: /search?
    );
    try testing.expect(!r.allowed("/doc/file.pdf"));
    try testing.expect(r.allowed("/doc/file.pdf?x=1"));
    try testing.expect(!r.allowed("/aXXbYYc"));
    try testing.expect(r.allowed("/aXXbYY"));
    try testing.expect(!r.allowed("/search?q=1"));
    try testing.expect(r.allowed("/search"));
}

test "a named group replaces the star group; names are case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text =
        \\User-agent: *
        \\Disallow: /
        \\
        \\User-agent: DKSearch
        \\User-agent: other
        \\Disallow: /secret
        \\Crawl-delay: 2.5
    ;
    const r = try rulesFor(arena.allocator(), text);
    try testing.expect(r.allowed("/open"));
    try testing.expect(!r.allowed("/secret/x"));
    try testing.expectEqual(@as(?u32, 3), r.crawl_delay_s);
    const other = try parse(arena.allocator(), text, "unknownbot");
    try testing.expect(!other.allowed("/open"));
}

test "empty disallow, comments, BOM, odd lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try rulesFor(arena.allocator(), "\xEF\xBB\xBFUser-agent: * # everyone\r\nDisallow:\r\nnonsense without colon\r\nSitemap: http://x/s.xml\r\n");
    try testing.expect(r.allowed("/anything"));
    try testing.expect(Rules.allow_all.allowed("/x"));
    try testing.expect(!Rules.disallow_all.allowed("/x"));
}

test "a user-agent line after a rule starts a new group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try rulesFor(arena.allocator(),
        \\User-agent: a
        \\Disallow: /a
        \\User-agent: *
        \\Disallow: /star
    );
    try testing.expect(!r.allowed("/star"));
    try testing.expect(r.allowed("/a"));
}

test "product token" {
    try testing.expectEqualStrings("dksearch", productToken("dksearch/1.0 (+https://example.org/bot)"));
    try testing.expectEqualStrings("MyBot", productToken("MyBot"));
    try testing.expectEqualStrings("", productToken("(odd)"));
}

test "hostile patterns finish quickly and never crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try rulesFor(arena.allocator(), "User-agent: *\nDisallow: /*a*a*a*a*a*a*a*a*a*a*a*a*b$\n");
    const target: []const u8 = "/" ++ &@as([4000]u8, @splat('a'));
    try testing.expect(r.allowed(target));
    var prng = std.Random.DefaultPrng.init(7);
    var buf: [200]u8 = undefined;
    for (0..300) |_| {
        for (&buf) |*b| b.* = "ab*$/:\n# Uu"[prng.random().uintLessThan(usize, 11)];
        const x = try rulesFor(arena.allocator(), &buf);
        _ = x.allowed("/ab/ba");
    }
}
