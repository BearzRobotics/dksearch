//! Date parsing for feeds: RFC 822 / 2822 (RSS `pubDate`) and ISO 8601 /
//! RFC 3339 (Atom `updated`, Dublin Core `dc:date`). Both return seconds
//! since the Unix epoch, or null when the text is not a date. Feeds in the
//! wild are sloppy, so the parsers accept common variants and reject the rest
//! rather than guess.

const std = @import("std");

fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn daysInMonth(year: i64, month: u8) u8 {
    const leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (leap) 29 else 28,
    };
}

fn build(year: i64, month: u8, day: u8, hour: u8, min: u8, sec: u8, offset_min: i64) ?i64 {
    if (month < 1 or month > 12 or year < 1 or year > 9999) return null;
    if (day < 1 or day > daysInMonth(year, month) or hour > 23 or min > 59 or sec > 60) return null;
    return daysFromCivil(year, month, day) * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + sec - offset_min * 60;
}

/// "2003-12-13T18:30:02Z", "2003-12-13T18:30:02.25+01:00", "2003-12-13 18:30:02Z"
/// or a plain date "2003-12-13" (taken as midnight UTC).
pub fn parseIso(text: []const u8) ?i64 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (s.len == 10) return build(year, month, day, 0, 0, 0, 0);
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return null;
    if (s.len < 16 or s[13] != ':') return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const min = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    var i: usize = 16;
    var sec: u8 = 0;
    if (i < s.len and s[i] == ':') {
        if (s.len < i + 3) return null;
        sec = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 10) catch return null;
        i += 3;
        if (i < s.len and s[i] == '.') { // fraction of a second: ignored
            i += 1;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        }
    }
    var offset: i64 = 0;
    if (i < s.len) {
        const z = s[i];
        if (z == 'Z' or z == 'z') {
            if (i + 1 != s.len) return null;
        } else if (z == '+' or z == '-') {
            const rest = s[i + 1 ..];
            const hh, const mm = switch (rest.len) {
                5 => .{ rest[0..2], rest[3..5] }, // +01:00
                4 => .{ rest[0..2], rest[2..4] }, // +0100
                2 => .{ rest[0..2], "00" }, // +01
                else => return null,
            };
            const h = std.fmt.parseInt(i64, hh, 10) catch return null;
            const m = std.fmt.parseInt(i64, mm, 10) catch return null;
            if (h > 23 or m > 59) return null;
            offset = (h * 60 + m) * (if (z == '-') @as(i64, -1) else 1);
        } else return null;
    }
    return build(year, month, day, hour, min, sec, offset);
}

const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };

/// "Tue, 10 Jun 2003 04:00:00 GMT", "10 Jun 2003 04:00 +0200", two-digit years
/// (00-49 mean 2000-2049, 50-99 mean 1950-1999), and the usual zone names.
pub fn parseRfc822(text: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,");
    var tok = it.next() orelse return null;
    // An optional day name.
    if (tok.len >= 3 and !std.ascii.isDigit(tok[0])) tok = it.next() orelse return null;
    const day = std.fmt.parseInt(u8, tok, 10) catch return null;
    const mon_tok = it.next() orelse return null;
    if (mon_tok.len < 3) return null;
    var month: u8 = 0;
    for (months, 1..) |m, n| if (std.ascii.eqlIgnoreCase(mon_tok[0..3], m)) {
        month = @intCast(n);
    };
    if (month == 0) return null;
    const year_tok = it.next() orelse return null;
    var year = std.fmt.parseInt(i64, year_tok, 10) catch return null;
    if (year_tok.len <= 2) year += if (year < 50) 2000 else 1900;
    if (year_tok.len == 3) year += 1900;
    const time_tok = it.next() orelse return null;
    var parts = std.mem.splitScalar(u8, time_tok, ':');
    const hour = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    const min = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    const sec: u8 = if (parts.next()) |sp| (std.fmt.parseInt(u8, sp, 10) catch return null) else 0;
    var offset: i64 = 0;
    if (it.next()) |zone| {
        if (zone[0] == '+' or zone[0] == '-') {
            if (zone.len != 5) return null;
            const h = std.fmt.parseInt(i64, zone[1..3], 10) catch return null;
            const m = std.fmt.parseInt(i64, zone[3..5], 10) catch return null;
            if (h > 23 or m > 59) return null;
            offset = (h * 60 + m) * (if (zone[0] == '-') @as(i64, -1) else 1);
        } else {
            const zones = [_]struct { []const u8, i64 }{
                .{ "GMT", 0 },    .{ "UT", 0 },     .{ "UTC", 0 },    .{ "Z", 0 },
                .{ "EST", -300 }, .{ "EDT", -240 }, .{ "CST", -360 }, .{ "CDT", -300 },
                .{ "MST", -420 }, .{ "MDT", -360 }, .{ "PST", -480 }, .{ "PDT", -420 },
            };
            var found = false;
            for (zones) |z| if (std.ascii.eqlIgnoreCase(zone, z[0])) {
                offset = z[1];
                found = true;
            };
            if (!found) return null;
        }
    }
    return build(year, month, day, hour, min, sec, offset);
}

/// Tries RFC 822 first (RSS), then ISO 8601 (Atom).
pub fn parse(text: []const u8) ?i64 {
    return parseRfc822(text) orelse parseIso(text);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "ISO 8601 and RFC 3339" {
    try testing.expectEqual(@as(?i64, 1071340202), parseIso("2003-12-13T18:30:02Z"));
    try testing.expectEqual(@as(?i64, 1071340202), parseIso("2003-12-13T18:30:02.25Z"));
    try testing.expectEqual(@as(?i64, 1071340202), parseIso("2003-12-13T19:30:02+01:00"));
    try testing.expectEqual(@as(?i64, 1071340202), parseIso("2003-12-13T13:30:02-0500"));
    try testing.expectEqual(@as(?i64, 1071340202), parseIso("2003-12-13 18:30:02Z"));
    try testing.expectEqual(@as(?i64, 1071273600), parseIso("2003-12-13"));
    try testing.expectEqual(@as(?i64, 1071340200), parseIso("2003-12-13T18:30Z"));
    try testing.expectEqual(@as(?i64, 951782400), parseIso("2000-02-29T00:00:00Z"));
}

test "ISO 8601 rejects what is not a date" {
    for ([_][]const u8{ "", "yesterday", "2003-13-01", "2003-02-30", "2003-12-13T25:00:00Z", "2003-12-13T18:30:02X", "2003/12/13", "2003-12-13T18:30:02+1", "2003-12-13T18" }) |bad| {
        try testing.expect(parseIso(bad) == null);
    }
}

test "RFC 822" {
    try testing.expectEqual(@as(?i64, 1055217600), parseRfc822("Tue, 10 Jun 2003 04:00:00 GMT"));
    try testing.expectEqual(@as(?i64, 1055217600), parseRfc822("10 Jun 2003 06:00:00 +0200"));
    try testing.expectEqual(@as(?i64, 1055217600), parseRfc822("Tue, 10 Jun 2003 00:00:00 EDT"));
    try testing.expectEqual(@as(?i64, 1055217600), parseRfc822("Tue, 10 Jun 03 04:00:00 UTC")); // two-digit year
    try testing.expectEqual(@as(?i64, 1055217540), parseRfc822("Tue, 10 Jun 2003 03:59 GMT")); // no seconds
    try testing.expectEqual(@as(?i64, 1055217600), parseRfc822("Tue, 10 Jun 2003 04:00:00")); // no zone: UTC
}

test "RFC 822 rejects what is not a date" {
    for ([_][]const u8{ "", "Tue, 31 Foo 2003 04:00:00 GMT", "Tue, 32 Jun 2003 04:00:00 GMT", "Tue, 10 Jun 2003 25:00:00 GMT", "Tue, 10 Jun 2003 04:00:00 XYZ", "2003-12-13T18:30:02Z" }) |bad| {
        try testing.expect(parseRfc822(bad) == null);
    }
}

test "parse tries both" {
    try testing.expectEqual(@as(?i64, 1055217600), parse("Tue, 10 Jun 2003 04:00:00 GMT"));
    try testing.expectEqual(@as(?i64, 1071340202), parse("2003-12-13T18:30:02Z"));
    try testing.expect(parse("soon") == null);
}
