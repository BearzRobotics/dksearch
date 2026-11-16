//! Audio and video as searchable documents: the tags and technical details that
//! `ffprobe` reports, and the text of subtitle and lyrics files kept next to the media.
//!
//! This file only parses; running `ffprobe` is the connector's job. Nothing here
//! reads a media file itself, so a damaged file cannot reach this code.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { audio, video };

pub const Format = struct {
    ext: []const u8,
    content_type: []const u8,
    kind: Kind,
};

const formats = [_]Format{
    .{ .ext = "mp3", .content_type = "audio/mpeg", .kind = .audio },
    .{ .ext = "m4a", .content_type = "audio/mp4", .kind = .audio },
    .{ .ext = "m4b", .content_type = "audio/mp4", .kind = .audio },
    .{ .ext = "aac", .content_type = "audio/aac", .kind = .audio },
    .{ .ext = "ogg", .content_type = "audio/ogg", .kind = .audio },
    .{ .ext = "oga", .content_type = "audio/ogg", .kind = .audio },
    .{ .ext = "opus", .content_type = "audio/opus", .kind = .audio },
    .{ .ext = "flac", .content_type = "audio/flac", .kind = .audio },
    .{ .ext = "wav", .content_type = "audio/wav", .kind = .audio },
    .{ .ext = "wma", .content_type = "audio/x-ms-wma", .kind = .audio },
    .{ .ext = "mp4", .content_type = "video/mp4", .kind = .video },
    .{ .ext = "m4v", .content_type = "video/mp4", .kind = .video },
    .{ .ext = "mkv", .content_type = "video/x-matroska", .kind = .video },
    .{ .ext = "webm", .content_type = "video/webm", .kind = .video },
    .{ .ext = "mov", .content_type = "video/quicktime", .kind = .video },
    .{ .ext = "avi", .content_type = "video/x-msvideo", .kind = .video },
};

/// The extension of `path` without the dot (as written), or "".
pub fn extensionOf(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    return base[dot + 1 ..];
}

/// The audio or video format of a file name, by extension (case-insensitive).
pub fn formatOf(path: []const u8) ?Format {
    const ext = extensionOf(path);
    for (formats) |f| if (std.ascii.eqlIgnoreCase(ext, f.ext)) return f;
    return null;
}

pub const sidecar_exts = [_][]const u8{ "srt", "vtt", "lrc" };

pub fn isSidecar(path: []const u8) bool {
    const ext = extensionOf(path);
    for (sidecar_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// What ffprobe knows about one file. Strings are allocated from the arena given to `parseProbe`.
pub const Info = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    composer: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    /// The `date` tag as written (a year, or a full date).
    date: ?[]const u8 = null,
    track: ?[]const u8 = null,
    duration_seconds: ?u64 = null,
    bit_rate_kbps: ?u64 = null,
    audio_codec: ?[]const u8 = null,
    video_codec: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    /// A lyrics tag, if the file carries its lyrics.
    lyrics: ?[]const u8 = null,
};

const max_value_bytes = 4096;

fn tagString(arena: Allocator, obj: std.json.ObjectMap, names: []const []const u8) Allocator.Error!?[]const u8 {
    // Tag names are case-insensitive and differ between formats (TITLE, Title, title).
    var it = obj.iterator();
    while (it.next()) |e| {
        for (names) |n| if (std.ascii.eqlIgnoreCase(e.key_ptr.*, n)) {
            if (e.value_ptr.* != .string) continue;
            const t = std.mem.trim(u8, e.value_ptr.string, " \t\r\n\x00");
            if (t.len == 0 or !std.unicode.utf8ValidateSlice(t)) continue;
            return try arena.dupe(u8, t[0..@min(t.len, max_value_bytes)]);
        };
    }
    return null;
}

fn numberOf(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Reads the JSON of `ffprobe -print_format json -show_format -show_streams`.
pub fn parseProbe(arena: Allocator, json: []const u8) (Allocator.Error || error{BadProbe})!Info {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadProbe,
    };
    if (parsed != .object) return error.BadProbe;
    var info: Info = .{};

    if (parsed.object.get("format")) |fmt| if (fmt == .object) {
        if (fmt.object.get("duration")) |d| if (numberOf(d)) |secs| {
            if (secs >= 0 and secs < 1e9) info.duration_seconds = @intFromFloat(@round(secs));
        };
        if (fmt.object.get("bit_rate")) |b| if (numberOf(b)) |bps| {
            if (bps >= 0 and bps < 1e12) info.bit_rate_kbps = @intFromFloat(@round(bps / 1000));
        };
        if (fmt.object.get("tags")) |t| if (t == .object) try readTags(arena, &info, t.object);
    };

    if (parsed.object.get("streams")) |streams| if (streams == .array) {
        for (streams.array.items) |s| {
            if (s != .object) continue;
            const kind = if (s.object.get("codec_type")) |k| (if (k == .string) k.string else "") else "";
            const codec: ?[]const u8 = if (s.object.get("codec_name")) |c| (if (c == .string) try arena.dupe(u8, c.string[0..@min(c.string.len, 32)]) else null) else null;
            if (std.mem.eql(u8, kind, "audio") and info.audio_codec == null) info.audio_codec = codec;
            if (std.mem.eql(u8, kind, "video") and info.video_codec == null) {
                // Cover art in an audio file shows up as a video stream; it has no frame rate worth knowing,
                // but treating it as video would mislabel music, so only a real stream (not attached art) counts.
                const attached = if (s.object.get("disposition")) |d| (if (d == .object) (if (d.object.get("attached_pic")) |a| (numberOf(a) orelse 0) > 0 else false) else false) else false;
                if (attached) continue;
                info.video_codec = codec;
                if (s.object.get("width")) |w| if (numberOf(w)) |n| {
                    if (n > 0 and n < 100000) info.width = @intFromFloat(n);
                };
                if (s.object.get("height")) |h| if (numberOf(h)) |n| {
                    if (n > 0 and n < 100000) info.height = @intFromFloat(n);
                };
            }
            // Some containers keep the tags on the stream.
            if (s.object.get("tags")) |t| if (t == .object) try readTags(arena, &info, t.object);
        }
    };
    return info;
}

fn readTags(arena: Allocator, info: *Info, tags: std.json.ObjectMap) Allocator.Error!void {
    if (info.title == null) info.title = try tagString(arena, tags, &.{"title"});
    if (info.artist == null) info.artist = try tagString(arena, tags, &.{ "artist", "author", "performer" });
    if (info.album == null) info.album = try tagString(arena, tags, &.{"album"});
    if (info.album_artist == null) info.album_artist = try tagString(arena, tags, &.{ "album_artist", "albumartist" });
    if (info.genre == null) info.genre = try tagString(arena, tags, &.{"genre"});
    if (info.composer == null) info.composer = try tagString(arena, tags, &.{"composer"});
    if (info.comment == null) info.comment = try tagString(arena, tags, &.{ "comment", "description" });
    if (info.date == null) info.date = try tagString(arena, tags, &.{ "date", "year", "creation_time" });
    if (info.track == null) info.track = try tagString(arena, tags, &.{"track"});
    if (info.lyrics == null) info.lyrics = try tagString(arena, tags, &.{ "lyrics", "unsyncedlyrics", "lyrics-eng" });
}

/// Unix time of the start of the year in a `date` tag (`1975`, `1975-03-01`, `1975-03-01T10:00:00Z`), or null.
pub fn yearStart(date: []const u8) ?i64 {
    if (date.len < 4) return null;
    for (date[0..4]) |c| if (!std.ascii.isDigit(c)) return null;
    const y = std.fmt.parseInt(i64, date[0..4], 10) catch return null;
    if (y < 1900 or y > 2200) return null;
    // Days from 1970-01-01 to January 1 of year y (proleptic Gregorian).
    const yy = y - 1;
    const days = yy * 365 + @divFloor(yy, 4) - @divFloor(yy, 100) + @divFloor(yy, 400) - (1969 * 365 + @divFloor(1969, 4) - @divFloor(1969, 100) + @divFloor(1969, 400));
    return days * 86400;
}

/// "3:25" or "1:02:03" for a duration in seconds.
pub fn formatDuration(arena: Allocator, secs: u64) Allocator.Error![]const u8 {
    const h = secs / 3600;
    const m = (secs % 3600) / 60;
    const s = secs % 60;
    if (h > 0) return std.fmt.allocPrint(arena, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s });
    return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{ m, s });
}

// ------------------------------------------------------------ subtitles and lyrics

/// The spoken or sung text of a `.srt`, `.vtt` or `.lrc` file, without cue numbers, timestamps, styling or tags.
pub fn sidecarText(arena: Allocator, bytes: []const u8, ext: []const u8) Allocator.Error![]const u8 {
    var data = bytes;
    if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data = data[3..];
    var out: std.ArrayList(u8) = .empty;
    var last: []const u8 = "";
    var in_note = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    const is_lrc = std.ascii.eqlIgnoreCase(ext, "lrc");
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            in_note = false;
            continue;
        }
        if (is_lrc) {
            line = lrcLine(line);
        } else {
            if (in_note) continue;
            if (std.mem.startsWith(u8, line, "WEBVTT")) continue;
            if (std.mem.startsWith(u8, line, "NOTE") or std.mem.startsWith(u8, line, "STYLE") or std.mem.startsWith(u8, line, "REGION")) {
                in_note = true;
                continue;
            }
            if (std.mem.indexOf(u8, line, "-->") != null) continue; // a cue's timing line
            if (allDigits(line)) continue; // a cue number
        }
        if (line.len == 0) continue;
        // Tags such as <i>, <c.yellow>, {\an8}.
        const clean = try stripTags(arena, line);
        const text = std.mem.trim(u8, clean, " \t");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, last)) continue; // a repeated line (karaoke, doubled cues)
        last = text;
        try out.appendSlice(arena, text);
        try out.append(arena, '\n');
    }
    return out.items;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0 or s.len > 8) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The lyric text of an LRC line: leading `[mm:ss.xx]` time tags are dropped, and metadata lines
/// (`[ar:Artist]`, `[ti:Title]`) are dropped entirely.
fn lrcLine(line: []const u8) []const u8 {
    var rest = line;
    var saw_time = false;
    while (rest.len > 0 and rest[0] == '[') {
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return rest;
        const inner = rest[1..close];
        const is_time = inner.len > 0 and std.ascii.isDigit(inner[0]);
        if (!is_time and !saw_time) return ""; // a metadata tag
        if (!is_time) break;
        saw_time = true;
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " ");
    }
    return rest;
}

fn stripTags(arena: Allocator, line: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, line, "<{") == null) return line;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '<' or c == '{') {
            const close_ch: u8 = if (c == '<') '>' else '}';
            if (std.mem.indexOfScalarPos(u8, line, i + 1, close_ch)) |e| {
                // Only drop what looks like a tag: `<i>`, `</b>`, `<c.yellow>`, `{\an8}`.
                const inner = line[i + 1 .. e];
                const looks_like_tag = inner.len > 0 and (std.ascii.isAlphabetic(inner[0]) or inner[0] == '/' or inner[0] == '\\');
                if (looks_like_tag and e - i <= 64) {
                    i = e + 1;
                    continue;
                }
            }
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.items;
}

const testing = std.testing;

test "formats by extension" {
    try testing.expectEqualStrings("audio/mpeg", formatOf("a/b/Song.MP3").?.content_type);
    try testing.expect(formatOf("x.m4a").?.kind == .audio);
    try testing.expect(formatOf("x.mp4").?.kind == .video);
    try testing.expect(formatOf("x.txt") == null);
    try testing.expect(formatOf("noext") == null);
    try testing.expect(isSidecar("a/b.SRT"));
    try testing.expect(!isSidecar("a/b.mp3"));
}

test "ffprobe output: tags, duration, codecs, cover art is not video" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info = try parseProbe(a,
        \\{"streams":[
        \\  {"codec_type":"audio","codec_name":"mp3"},
        \\  {"codec_type":"video","codec_name":"mjpeg","width":500,"height":500,"disposition":{"attached_pic":1}}
        \\ ],
        \\ "format":{"duration":"205.481","bit_rate":"128000","tags":{"TITLE":"Stella by Starlight","Artist":"Miles  ","album":"Quintet","date":"1958-03-04","genre":"Jazz","track":"3/9","comment":""}}}
    );
    try testing.expectEqualStrings("Stella by Starlight", info.title.?);
    try testing.expectEqualStrings("Miles", info.artist.?);
    try testing.expectEqualStrings("Jazz", info.genre.?);
    try testing.expect(info.comment == null); // empty
    try testing.expectEqual(@as(?u64, 205), info.duration_seconds);
    try testing.expectEqual(@as(?u64, 128), info.bit_rate_kbps);
    try testing.expectEqualStrings("mp3", info.audio_codec.?);
    try testing.expect(info.video_codec == null);
    try testing.expectEqualStrings("3:25", try formatDuration(a, 205));
    try testing.expectEqualStrings("1:02:03", try formatDuration(a, 3723));

    const video = try parseProbe(a,
        \\{"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080},{"codec_type":"audio","codec_name":"aac"}],
        \\ "format":{"duration":3600.2,"tags":{"title":"Lecture 1"}}}
    );
    try testing.expectEqualStrings("h264", video.video_codec.?);
    try testing.expectEqual(@as(?u32, 1920), video.width);
    try testing.expectEqual(@as(?u64, 3600), video.duration_seconds);
}

test "ffprobe output that is wrong never crashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "[]", "{", "null", "{\"format\":3}", "{\"streams\":{\"a\":1}}", "{\"format\":{\"duration\":\"abc\",\"tags\":[1]}}", "{\"streams\":[1,null,{\"codec_type\":5}]}" }) |bad| {
        _ = parseProbe(a, bad) catch |e| try testing.expect(e == error.BadProbe);
    }
    const huge = try parseProbe(a, "{\"format\":{\"duration\":1e30,\"bit_rate\":-5}}");
    try testing.expect(huge.duration_seconds == null and huge.bit_rate_kbps == null);
}

test "dates" {
    try testing.expectEqual(@as(?i64, 0), yearStart("1970"));
    try testing.expectEqual(@as(?i64, 1_262_304_000), yearStart("2010-06-30"));
    try testing.expectEqual(@as(?i64, -86400 * 365), yearStart("1969"));
    try testing.expect(yearStart("") == null);
    try testing.expect(yearStart("abcd") == null);
    try testing.expect(yearStart("1800") == null);
}

test "SRT and WebVTT: only the words remain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const srt = "\xEF\xBB\xBF1\r\n00:00:01,000 --> 00:00:03,000\r\n<i>Hello</i> there\r\n\r\n2\r\n00:00:03,500 --> 00:00:05,000\r\n{\\an8}Second line\r\nSecond line\r\n\r\n3\r\n00:00:06,000 --> 00:00:07,000\r\n5 < 6 and 7 > 3\r\n";
    try testing.expectEqualStrings("Hello there\nSecond line\n5 < 6 and 7 > 3\n", try sidecarText(a, srt, "srt"));
    const vtt = "WEBVTT\n\nNOTE a comment\nthat spans lines\n\nSTYLE\n::cue { color: red }\n\n00:00:01.000 --> 00:00:02.000 align:start\n<c.yellow>Welcome</c> back\n\ncue-id\n00:00:02.500 --> 00:00:04.000\nto the show\n";
    try testing.expectEqualStrings("Welcome back\ncue-id\nto the show\n", try sidecarText(a, vtt, "vtt"));
}

test "LRC lyrics: time tags and metadata lines go" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lrc = "[ar:Some Artist]\n[ti:Some Song]\n[00:12.00]First line\n[00:15.50][01:20.00]Chorus line\n[00:20.00]\nplain line\n";
    try testing.expectEqualStrings("First line\nChorus line\nplain line\n", try sidecarText(a, lrc, "LRC"));
}

test "odd sidecar input never crashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "\n\n\n", "<", "{", "[", "[00:01", "-->", "<<<<>>>>", "{\\", "\xff\xfe" }) |s| {
        for ([_][]const u8{ "srt", "vtt", "lrc" }) |e| _ = try sidecarText(a, s, e);
    }
}
