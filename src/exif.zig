//! A small, bounds-checked reader for the EXIF metadata of photographs: the
//! description, camera, date, software, artist, copyright, lens, orientation
//! and GPS position. Nothing else in the file is interpreted.
//!
//! Why not a library: EXIF is read from images nobody here vetted (indexed
//! folders, crawled pages, uploads), and the C libraries for it are large and
//! have a history of memory-safety bugs; this reader is a few hundred lines in
//! a language with bounds checks, handles the dozen tags we use, and ignores
//! the rest (maker notes, thumbnails, tags of other IFDs). It is an exception
//! to the rule of using libraries for established formats, recorded in
//! docs/decisions/0023.
//!
//! Every offset and length is checked against the data before use, the number
//! of directory entries read is capped, strings are capped, and nothing is
//! allocated except by the caller.

const std = @import("std");

pub const Exif = struct {
    description: ?[]const u8 = null,
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    software: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    lens: ?[]const u8 = null,
    /// "2026:11:15 14:30:00" as written by the camera.
    taken: ?[]const u8 = null,
    orientation: ?u16 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,

    pub fn isEmpty(self: Exif) bool {
        return self.description == null and self.make == null and self.model == null and self.software == null and
            self.artist == null and self.copyright == null and self.lens == null and self.taken == null and
            self.orientation == null and self.latitude == null;
    }
};

const max_string = 256;
const max_entries = 256;

/// The EXIF block of a JPEG, PNG or WebP file, or null if there is none.
/// All strings in the result point into `file`.
pub fn read(file: []const u8) ?Exif {
    const tiff = findTiff(file) orelse return null;
    return parseTiff(tiff);
}

/// The TIFF structure that holds the EXIF directories, from whichever
/// container the file uses.
fn findTiff(file: []const u8) ?[]const u8 {
    if (file.len >= 4 and file[0] == 0xFF and file[1] == 0xD8) return findInJpeg(file);
    if (file.len >= 8 and std.mem.eql(u8, file[0..8], "\x89PNG\r\n\x1a\n")) return findInPng(file);
    if (file.len >= 12 and std.mem.eql(u8, file[0..4], "RIFF") and std.mem.eql(u8, file[8..12], "WEBP")) return findInWebp(file);
    return null;
}

fn be16(b: []const u8, at: usize) ?u16 {
    if (at + 2 > b.len) return null;
    return std.mem.readInt(u16, b[at..][0..2], .big);
}

fn be32(b: []const u8, at: usize) ?u32 {
    if (at + 4 > b.len) return null;
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

fn le32(b: []const u8, at: usize) ?u32 {
    if (at + 4 > b.len) return null;
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn findInJpeg(file: []const u8) ?[]const u8 {
    var i: usize = 2;
    // Walk the marker segments until the image data starts; EXIF is in APP1.
    var segments: u32 = 0;
    while (i + 4 <= file.len and segments < 64) : (segments += 1) {
        if (file[i] != 0xFF) return null;
        const marker = file[i + 1];
        if (marker == 0xFF) { // padding
            i += 1;
            continue;
        }
        if (marker == 0xD9 or marker == 0xDA) return null; // end of image / start of scan
        const len = be16(file, i + 2) orelse return null;
        if (len < 2) return null;
        const body_start = i + 4;
        const body_end = i + 2 + len;
        if (body_end > file.len) return null;
        if (marker == 0xE1 and body_end - body_start >= 6 and std.mem.eql(u8, file[body_start..][0..6], "Exif\x00\x00")) {
            return file[body_start + 6 .. body_end];
        }
        i = body_end;
    }
    return null;
}

fn findInPng(file: []const u8) ?[]const u8 {
    var i: usize = 8;
    var chunks: u32 = 0;
    while (i + 12 <= file.len and chunks < 4096) : (chunks += 1) {
        const len = be32(file, i) orelse return null;
        const kind = file[i + 4 .. i + 8];
        const data_start = i + 8;
        const data_end = data_start + @as(u64, len);
        if (data_end + 4 > file.len) return null;
        if (std.mem.eql(u8, kind, "eXIf")) return file[data_start..@intCast(data_end)];
        if (std.mem.eql(u8, kind, "IDAT")) return null; // metadata chunks come first
        i = @intCast(data_end + 4);
    }
    return null;
}

fn findInWebp(file: []const u8) ?[]const u8 {
    var i: usize = 12;
    var chunks: u32 = 0;
    while (i + 8 <= file.len and chunks < 4096) : (chunks += 1) {
        const kind = file[i .. i + 4];
        const len = le32(file, i + 4) orelse return null;
        const start = i + 8;
        const end = start + @as(u64, len);
        if (end > file.len) return null;
        if (std.mem.eql(u8, kind, "EXIF")) {
            const body = file[start..@intCast(end)];
            // Some writers keep the "Exif\0\0" prefix JPEG uses.
            return if (body.len >= 6 and std.mem.eql(u8, body[0..6], "Exif\x00\x00")) body[6..] else body;
        }
        i = @intCast(end + (len & 1)); // chunks are padded to even sizes
    }
    return null;
}

const Tiff = struct {
    data: []const u8,
    big: bool,

    fn u16at(self: Tiff, at: usize) ?u16 {
        if (at + 2 > self.data.len) return null;
        return std.mem.readInt(u16, self.data[at..][0..2], if (self.big) .big else .little);
    }
    fn u32at(self: Tiff, at: usize) ?u32 {
        if (at + 4 > self.data.len) return null;
        return std.mem.readInt(u32, self.data[at..][0..4], if (self.big) .big else .little);
    }
};

const Entry = struct {
    tag: u16,
    kind: u16,
    count: u32,
    /// Where the value's bytes are in the TIFF data (inline in the entry when
    /// it fits in four bytes), already checked to lie inside it.
    value_at: usize,
};

fn typeSize(kind: u16) usize {
    return switch (kind) {
        1, 2, 6, 7 => 1, // byte, ascii, sbyte, undefined
        3, 8 => 2, // short
        4, 9, 11 => 4, // long, slong, float
        5, 10, 12 => 8, // rational, srational, double
        else => 0,
    };
}

/// Entry `i` of the directory at `ifd`, or null if it is malformed.
fn entryAt(t: Tiff, ifd: usize, i: usize) ?Entry {
    const at = ifd + 2 + i * 12;
    const tag = t.u16at(at) orelse return null;
    const kind = t.u16at(at + 2) orelse return null;
    const count = t.u32at(at + 4) orelse return null;
    const size = typeSize(kind);
    if (size == 0) return null;
    const total = @as(u64, count) * size;
    var value_at: usize = at + 8;
    if (total > 4) {
        const off = t.u32at(at + 8) orelse return null;
        if (@as(u64, off) + total > t.data.len) return null;
        value_at = off;
    } else if (at + 8 + total > t.data.len) return null;
    return .{ .tag = tag, .kind = kind, .count = count, .value_at = value_at };
}

fn entryCount(t: Tiff, ifd: usize) ?usize {
    const n = t.u16at(ifd) orelse return null;
    if (n > max_entries) return null;
    if (ifd + 2 + @as(usize, n) * 12 > t.data.len) return null;
    return n;
}

/// An ASCII value, cut at its first NUL, trimmed and capped.
fn ascii(t: Tiff, e: Entry) ?[]const u8 {
    if (e.kind != 2 and e.kind != 7) return null;
    const len = @min(e.count, max_string);
    var s = t.data[e.value_at..][0..len];
    if (std.mem.indexOfScalar(u8, s, 0)) |z| s = s[0..z];
    s = std.mem.trim(u8, s, " \t\r\n");
    return if (s.len == 0) null else s;
}

fn rational(t: Tiff, at: usize) ?f64 {
    const num = t.u32at(at) orelse return null;
    const den = t.u32at(at + 4) orelse return null;
    if (den == 0) return null;
    return @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

/// Degrees, minutes and seconds (three rationals) as decimal degrees.
fn dms(t: Tiff, e: Entry) ?f64 {
    if (e.kind != 5 or e.count != 3) return null;
    const d = rational(t, e.value_at) orelse return null;
    const m = rational(t, e.value_at + 8) orelse return null;
    const s = rational(t, e.value_at + 16) orelse return null;
    const v = d + m / 60.0 + s / 3600.0;
    return if (std.math.isFinite(v)) v else null;
}

fn parseTiff(data: []const u8) ?Exif {
    if (data.len < 8) return null;
    const big = if (std.mem.eql(u8, data[0..2], "MM")) true else if (std.mem.eql(u8, data[0..2], "II")) false else return null;
    const t: Tiff = .{ .data = data, .big = big };
    if ((t.u16at(2) orelse return null) != 42) return null;
    const ifd0: usize = t.u32at(4) orelse return null;

    var out: Exif = .{};
    var exif_ifd: ?usize = null;
    var gps_ifd: ?usize = null;

    if (entryCount(t, ifd0)) |n| for (0..n) |i| {
        const e = entryAt(t, ifd0, i) orelse continue;
        switch (e.tag) {
            0x010E => out.description = ascii(t, e),
            0x010F => out.make = ascii(t, e),
            0x0110 => out.model = ascii(t, e),
            0x0112 => if (e.kind == 3 and e.count == 1) {
                out.orientation = t.u16at(e.value_at);
            },
            0x0131 => out.software = ascii(t, e),
            0x0132 => if (out.taken == null) {
                out.taken = ascii(t, e);
            },
            0x013B => out.artist = ascii(t, e),
            0x8298 => out.copyright = ascii(t, e),
            0x8769 => if (e.kind == 4 and e.count == 1) {
                exif_ifd = if (t.u32at(e.value_at)) |v| @as(usize, v) else null;
            },
            0x8825 => if (e.kind == 4 and e.count == 1) {
                gps_ifd = if (t.u32at(e.value_at)) |v| @as(usize, v) else null;
            },
            else => {},
        }
    };

    if (exif_ifd) |ifd| if (entryCount(t, ifd)) |n| for (0..n) |i| {
        const e = entryAt(t, ifd, i) orelse continue;
        switch (e.tag) {
            0x9003 => if (ascii(t, e)) |s| {
                out.taken = s; // the moment of capture beats the file's modification time
            },
            0xA434 => out.lens = ascii(t, e),
            else => {},
        }
    };

    if (gps_ifd) |ifd| if (entryCount(t, ifd)) |n| {
        var lat_ref: u8 = 0;
        var lon_ref: u8 = 0;
        var lat: ?f64 = null;
        var lon: ?f64 = null;
        for (0..n) |i| {
            const e = entryAt(t, ifd, i) orelse continue;
            switch (e.tag) {
                1 => if (ascii(t, e)) |s| {
                    lat_ref = s[0];
                },
                2 => lat = dms(t, e),
                3 => if (ascii(t, e)) |s| {
                    lon_ref = s[0];
                },
                4 => lon = dms(t, e),
                else => {},
            }
        }
        if (lat != null and lon != null and lat.? <= 90 and lon.? <= 180) {
            out.latitude = if (lat_ref == 'S') -lat.? else lat.?;
            out.longitude = if (lon_ref == 'W') -lon.? else lon.?;
        }
    };
    return if (out.isEmpty()) null else out;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const jpg_full = @embedFile("testdata/media/exif_full.jpg");
const jpg_plain = @embedFile("testdata/media/photo.jpg");
const png_exif = @embedFile("testdata/media/exif.png");
const webp_exif = @embedFile("testdata/media/exif.webp");

test "a JPEG's camera, date, description and position are read" {
    const e = read(jpg_full).?;
    try testing.expectEqualStrings("A lighthouse at dusk", e.description.?);
    try testing.expectEqualStrings("ACME", e.make.?);
    try testing.expectEqualStrings("Cam 3000", e.model.?);
    try testing.expectEqualStrings("2026:11:15 14:30:00", e.taken.?);
    try testing.expectEqualStrings("Jo Photographer", e.artist.?);
    try testing.expectEqual(@as(?u16, 6), e.orientation);
    try testing.expectApproxEqAbs(@as(f64, 59.9139), e.latitude.?, 0.001); // 59 54 50 N
    try testing.expectApproxEqAbs(@as(f64, -10.7522), e.longitude.?, 0.001); // 10 45 8 W
}

test "PNG and WebP containers carry EXIF too; a picture without it has none" {
    try testing.expectEqualStrings("ACME", read(png_exif).?.make.?);
    try testing.expectEqualStrings("ACME", read(webp_exif).?.make.?);
    try testing.expect(read(jpg_plain) == null);
    try testing.expect(read("not an image") == null);
    try testing.expect(read("") == null);
}

test "big-endian EXIF is read the same way" {
    // A hand-built TIFF: "MM", IFD0 with Make = "BE" inline.
    const tiff = "MM\x00\x2a\x00\x00\x00\x08" ++ "\x00\x01" ++ "\x01\x0f\x00\x02\x00\x00\x00\x03BE\x00\x00" ++ "\x00\x00\x00\x00";
    const e = parseTiff(tiff).?;
    try testing.expectEqualStrings("BE", e.make.?);
}

test "lying offsets, counts and loops are refused, never followed" {
    // IFD0 pointing past the end, an entry whose value is out of range, and an
    // IFD pointer that points back at IFD0 (no recursion is done, so no loop).
    try testing.expect(parseTiff("II\x2a\x00\xff\xff\xff\x7f") == null);
    const bad_value = "II\x2a\x00\x08\x00\x00\x00" ++ "\x01\x00" ++ "\x0f\x01\x02\x00\xff\xff\xff\x00\x00\x01\x00\x00" ++ "\x00\x00\x00\x00";
    try testing.expect(parseTiff(bad_value) == null);
    const self_ref = "II\x2a\x00\x08\x00\x00\x00" ++ "\x02\x00" ++ "\x69\x87\x04\x00\x01\x00\x00\x00\x08\x00\x00\x00" ++ "\x0f\x01\x02\x00\x02\x00\x00\x00Xy\x00\x00" ++ "\x00\x00\x00\x00";
    try testing.expectEqualStrings("Xy", parseTiff(self_ref).?.make.?);
}

test "damaged EXIF never crashes the reader" {
    var prng = std.Random.DefaultPrng.init(0xe71f);
    const rnd = prng.random();
    var buf: [16 * 1024]u8 = undefined;
    for ([_][]const u8{ jpg_full, png_exif, webp_exif }) |orig| {
        for (0..400) |round| {
            const copy = buf[0..orig.len];
            @memcpy(copy, orig);
            var len = copy.len;
            if (round % 5 == 0) {
                len = rnd.uintLessThan(usize, copy.len) + 1;
            } else {
                for (0..1 + rnd.uintLessThan(usize, 8)) |_| copy[rnd.uintLessThan(usize, copy.len)] = rnd.int(u8);
            }
            _ = read(copy[0..len]);
        }
    }
    // And pure noise with an EXIF-looking header.
    for (0..2000) |_| {
        var noise: [256]u8 = undefined;
        rnd.bytes(&noise);
        @memcpy(noise[0..8], "II\x2a\x00\x08\x00\x00\x00");
        _ = parseTiff(&noise);
        _ = parseTiff(noise[0..rnd.uintLessThan(usize, 256)]);
    }
}
