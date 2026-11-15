//! Reading images and computing a perceptual hash for "search by image".
//!
//! Decoding uses the vendored Wuffs (docs/decisions/0023): decoders generated
//! from a memory-safe language, which matters because images come from files
//! nobody here wrote (indexed folders, crawled pages, uploads). JPEG, PNG,
//! GIF, WebP and BMP are read; anything else is not an image to us.
//!
//! The hash is a difference hash (dHash): the picture is reduced to a 9x8
//! grid of average brightness values and each bit says whether a cell is
//! brighter than its right-hand neighbour. Copies of the same picture that
//! were resized, recompressed or slightly recoloured give hashes that differ
//! in only a few of the 64 bits, while unrelated pictures differ in about
//! half of them. It finds near-duplicates, not "pictures of dogs".

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const c = if (build_options.media) @import("wuffs_c") else struct {};

/// Whether this build can decode images (`-Dmedia`).
pub const available = build_options.media;

/// Pictures larger than this many pixels are refused before any decoding, so
/// a small file cannot make the decoder allocate a huge canvas.
pub const max_pixels: u64 = 50_000_000;
/// Files larger than this are not read as images.
pub const max_bytes: usize = 64 * 1024 * 1024;

pub const Info = struct {
    width: u32,
    height: u32,
};

pub const Error = error{
    /// Not an image this build reads, or damaged.
    NotAnImage,
    /// Larger than `max_pixels` or `max_bytes`.
    TooLarge,
    /// This build has no image support.
    Unsupported,
    OutOfMemory,
};

/// Width and height from the file's header, without decoding the picture.
pub fn info(bytes: []const u8) Error!Info {
    if (!available) return error.Unsupported;
    if (bytes.len == 0) return error.NotAnImage;
    if (bytes.len > max_bytes or bytes.len > std.math.maxInt(c_int)) return error.TooLarge;
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    if (c.stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp) == 0) return error.NotAnImage;
    if (w <= 0 or h <= 0) return error.NotAnImage;
    const pixels = @as(u64, @intCast(w)) * @as(u64, @intCast(h));
    if (pixels > max_pixels) return error.TooLarge;
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

/// The 64-bit difference hash of the picture.
pub fn dhash(gpa: Allocator, bytes: []const u8) Error!u64 {
    const inf = try info(bytes);
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const px = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 1) orelse return error.NotAnImage;
    defer c.stbi_image_free(px);
    // The decoder must agree with the header; never trust one to size the other.
    if (w != inf.width or h != inf.height) return error.NotAnImage;
    const len = @as(usize, inf.width) * inf.height;
    return hashGray(gpa, px[0..len], inf.width, inf.height);
}

/// dHash of an 8-bit grayscale picture of `width` x `height` pixels.
pub fn hashGray(gpa: Allocator, gray: []const u8, width: u32, height: u32) Allocator.Error!u64 {
    std.debug.assert(gray.len == @as(usize, width) * height);
    const cols = 9;
    const rows = 8;
    var cells: [rows][cols]u32 = undefined;
    // Each cell is the average of a box of the picture (area averaging, so
    // reducing a big picture does not alias and tiny ones still fill every cell).
    for (0..rows) |cy| {
        const y0: u32 = @intCast(@as(u64, cy) * height / rows);
        var y1: u32 = @intCast(@as(u64, cy + 1) * height / rows);
        if (y1 <= y0) y1 = @min(y0 + 1, height);
        for (0..cols) |cx| {
            const x0: u32 = @intCast(@as(u64, cx) * width / cols);
            var x1: u32 = @intCast(@as(u64, cx + 1) * width / cols);
            if (x1 <= x0) x1 = @min(x0 + 1, width);
            var sum: u64 = 0;
            var n: u64 = 0;
            var y = y0;
            while (y < y1) : (y += 1) {
                const row = gray[@as(usize, y) * width ..][0..width];
                for (row[x0..x1]) |v| sum += v;
                n += x1 - x0;
            }
            // Scaled by 256 so that small differences between cells survive integer division.
            cells[cy][cx] = if (n == 0) 0 else @intCast(sum * 256 / n);
        }
    }
    _ = gpa;
    var bits: u64 = 0;
    for (0..rows) |cy| {
        for (0..8) |cx| {
            bits <<= 1;
            if (cells[cy][cx] > cells[cy][cx + 1]) bits |= 1;
        }
    }
    return bits;
}

/// How many of the 64 bits differ.
pub fn distance(a: u64, b: u64) u7 {
    return @popCount(a ^ b);
}

/// 16 lower-case hexadecimal digits, for storing the hash as text.
pub fn toHex(h: u64) [16]u8 {
    return std.fmt.bytesToHex(std.mem.toBytes(std.mem.nativeToBig(u64, h)), .lower);
}

pub fn fromHex(text: []const u8) ?u64 {
    if (text.len != 16) return null;
    return std.fmt.parseInt(u64, text, 16) catch null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const fx = struct {
    const png = @embedFile("testdata/media/photo.png");
    const jpg = @embedFile("testdata/media/photo.jpg");
    const gif = @embedFile("testdata/media/photo.gif");
    const webp = @embedFile("testdata/media/photo.webp");
    const bmp = @embedFile("testdata/media/photo.bmp");
    const big = @embedFile("testdata/media/photo_big.png");
    const bright = @embedFile("testdata/media/photo_bright.jpg");
    const other = @embedFile("testdata/media/other.png");
    const huge = @embedFile("testdata/media/huge.png");
};

test "every supported format is read, with its size" {
    if (!available) return error.SkipZigTest;
    for ([_][]const u8{ fx.png, fx.jpg, fx.gif, fx.webp, fx.bmp }) |bytes| {
        const i = try info(bytes);
        try testing.expectEqual(@as(u32, 96), i.width);
        try testing.expectEqual(@as(u32, 72), i.height);
    }
    const b = try info(fx.big);
    try testing.expectEqual(@as(u32, 384), b.width);
}

test "copies of one picture hash close together, other pictures far apart" {
    if (!available) return error.SkipZigTest;
    const base = try dhash(testing.allocator, fx.png);
    // Same picture in other formats, scaled up four times, brightened and recompressed.
    for ([_][]const u8{ fx.jpg, fx.gif, fx.webp, fx.bmp, fx.big, fx.bright }) |bytes| {
        const h = try dhash(testing.allocator, bytes);
        errdefer std.debug.print("distance {d}\n", .{distance(base, h)});
        try testing.expect(distance(base, h) <= 8);
    }
    // A different picture is about half the bits away.
    const o = try dhash(testing.allocator, fx.other);
    try testing.expect(distance(base, o) >= 16);
    try testing.expectEqual(@as(u7, 0), distance(base, base));
}

test "hashing is deterministic and the hex form round-trips" {
    if (!available) return error.SkipZigTest;
    const a = try dhash(testing.allocator, fx.png);
    const b = try dhash(testing.allocator, fx.png);
    try testing.expectEqual(a, b);
    const hex = toHex(a);
    try testing.expectEqual(@as(?u64, a), fromHex(&hex));
    try testing.expectEqual(@as(?u64, null), fromHex("xyz"));
    try testing.expectEqual(@as(?u64, null), fromHex("zzzzzzzzzzzzzzzz"));
}

test "not-images, empty input and oversized pictures are refused" {
    if (!available) return error.SkipZigTest;
    try testing.expectError(error.NotAnImage, dhash(testing.allocator, "plain text, not a picture"));
    try testing.expectError(error.NotAnImage, dhash(testing.allocator, ""));
    try testing.expectError(error.NotAnImage, dhash(testing.allocator, fx.png[0 .. fx.png.len / 2]));
    try testing.expectError(error.TooLarge, dhash(testing.allocator, fx.huge)); // 3.6 gigapixels claimed
    try testing.expectError(error.NotAnImage, info("GIF89a"));
}

test "damaged pictures never crash the decoder" {
    if (!available) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0x1a6e);
    const rnd = prng.random();
    var buf: [32 * 1024]u8 = undefined;
    for ([_][]const u8{ fx.png, fx.jpg, fx.gif, fx.webp, fx.bmp }) |orig| {
        for (0..120) |round| {
            const copy = buf[0..orig.len];
            @memcpy(copy, orig);
            var len = copy.len;
            if (round % 4 == 0) {
                len = rnd.uintLessThan(usize, copy.len) + 1; // truncated
            } else {
                for (0..1 + rnd.uintLessThan(usize, 6)) |_| copy[rnd.uintLessThan(usize, copy.len)] = rnd.int(u8);
            }
            if (dhash(testing.allocator, copy[0..len])) |_| {} else |_| {}
        }
    }
}

test "tiny and flat pictures still hash" {
    // A 1x1 picture and a uniform one: no cell is brighter than its neighbour.
    try testing.expectEqual(@as(u64, 0), try hashGray(testing.allocator, &.{200}, 1, 1));
    var flat: [20 * 20]u8 = @splat(77);
    try testing.expectEqual(@as(u64, 0), try hashGray(testing.allocator, &flat, 20, 20));
    // A left-to-right gradient: every cell is brighter than the next, so all bits are 1.
    var grad: [90 * 8]u8 = undefined;
    for (0..8) |y| for (0..90) |x| {
        grad[y * 90 + x] = @intCast(255 - x * 2);
    };
    try testing.expectEqual(~@as(u64, 0), try hashGray(testing.allocator, &grad, 90, 8));
}
