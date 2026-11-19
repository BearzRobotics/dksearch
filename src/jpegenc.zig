//! A small baseline JPEG encoder, for thumbnails (docs/decisions/0055). The picture libraries dksearch reads pictures with
//! cannot write them, and a thumbnail has to be small, so this writes the one kind of file a thumbnail needs: 8 bits,
//! YCbCr with the colour halved in both directions (4:2:0), the standard quantisation tables scaled by a quality, and
//! Huffman tables made for the picture itself (two passes), which makes the file a little smaller than the fixed tables do.
//! Every browser and viewer reads it. It never reads outside its input and its output grows only as it writes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ BadSize, OutOfMemory };

const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// The example quantisation tables of the JPEG standard (Annex K), in natural (row by row) order.
const base_luma = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};
const base_chroma = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

fn scaledTable(base: [64]u8, quality: u8) [64]u8 {
    const q: u32 = std.math.clamp(quality, 1, 100);
    const scale: u32 = if (q < 50) 5000 / q else 200 - q * 2;
    var out: [64]u8 = undefined;
    for (base, 0..) |b, i| {
        const v = (@as(u32, b) * scale + 50) / 100;
        out[i] = @intCast(std.math.clamp(v, 1, 255));
    }
    return out;
}

/// cos((2x+1) u pi / 16) / 2 (with the u = 0 row scaled by 1/sqrt 2), the one-dimensional transform of 8 values.
fn dctMatrix() [8][8]f32 {
    var m: [8][8]f32 = undefined;
    for (0..8) |u| {
        for (0..8) |x| {
            const c: f32 = if (u == 0) @as(f32, 1.0) / @sqrt(@as(f32, 2.0)) else 1.0;
            m[u][x] = 0.5 * c * @cos((2.0 * @as(f32, @floatFromInt(x)) + 1.0) * @as(f32, @floatFromInt(u)) * std.math.pi / 16.0);
        }
    }
    return m;
}

/// The quantised transform of one 8 x 8 block (values already shifted to be around 0), in zigzag order.
fn blockCoefficients(m: *const [8][8]f32, block: *const [64]f32, quant: *const [64]u8, out: *[64]i16) void {
    var tmp: [64]f32 = undefined;
    // Rows, then columns.
    for (0..8) |y| {
        for (0..8) |u| {
            var s: f32 = 0;
            for (0..8) |x| s += block[y * 8 + x] * m[u][x];
            tmp[y * 8 + u] = s;
        }
    }
    var natural: [64]i16 = undefined;
    for (0..8) |u| {
        for (0..8) |v| {
            var s: f32 = 0;
            for (0..8) |y| s += tmp[y * 8 + u] * m[v][y];
            const q: f32 = @floatFromInt(quant[v * 8 + u]);
            natural[v * 8 + u] = @intFromFloat(@round(s / q));
        }
    }
    for (0..64) |i| out[i] = natural[zigzag[i]];
}

fn category(v: i32) u5 {
    var a: u32 = @intCast(if (v < 0) -v else v);
    var n: u5 = 0;
    while (a != 0) : (a >>= 1) n += 1;
    return n;
}

const Huff = struct {
    bits: [17]u8 = @splat(0), // bits[l] = how many codes are l bits long (l = 1..16)
    vals: [256]u8 = @splat(0), // the symbols, shortest codes first
    n: usize = 0,
    code: [256]u16 = @splat(0),
    size: [256]u8 = @splat(0),

    /// A table for the symbol counts `counts` (the method of Annex K.2 of the standard: lengths from a Huffman tree, cut
    /// to 16 bits, one code point kept back so that no code is all ones).
    fn make(counts: *const [256]u32) Huff {
        var freq: [257]u64 = undefined;
        for (counts, 0..) |c, i| freq[i] = c;
        freq[256] = 1; // the reserved symbol
        var codesize: [257]u32 = @splat(0);
        var others: [257]i32 = @splat(-1);
        while (true) {
            var c1: i32 = -1;
            var v: u64 = std.math.maxInt(u64);
            for (freq, 0..) |f, i| {
                if (f != 0 and f <= v) {
                    v = f;
                    c1 = @intCast(i);
                }
            }
            var c2: i32 = -1;
            v = std.math.maxInt(u64);
            for (freq, 0..) |f, i| {
                if (f != 0 and f <= v and @as(i32, @intCast(i)) != c1) {
                    v = f;
                    c2 = @intCast(i);
                }
            }
            if (c2 < 0) break;
            freq[@intCast(c1)] += freq[@intCast(c2)];
            freq[@intCast(c2)] = 0;
            var k: i32 = c1;
            codesize[@intCast(k)] += 1;
            while (others[@intCast(k)] >= 0) {
                k = others[@intCast(k)];
                codesize[@intCast(k)] += 1;
            }
            others[@intCast(k)] = c2;
            k = c2;
            codesize[@intCast(k)] += 1;
            while (others[@intCast(k)] >= 0) {
                k = others[@intCast(k)];
                codesize[@intCast(k)] += 1;
            }
        }
        var counts_by_len: [33]u32 = @splat(0);
        for (codesize) |s| if (s > 0) {
            counts_by_len[@min(s, 32)] += 1;
        };
        // No code longer than 16 bits.
        var i: usize = 32;
        while (i > 16) : (i -= 1) {
            while (counts_by_len[i] > 0) {
                var j: usize = i - 2;
                while (counts_by_len[j] == 0) j -= 1;
                counts_by_len[i] -= 2;
                counts_by_len[i - 1] += 1;
                counts_by_len[j + 1] += 2;
                counts_by_len[j] -= 1;
            }
        }
        // Take the reserved symbol's code point back.
        i = 16;
        while (counts_by_len[i] == 0) i -= 1;
        counts_by_len[i] -= 1;
        var h: Huff = .{};
        for (1..17) |l| h.bits[l] = @intCast(counts_by_len[l]);
        // Symbols by code length, then by value.
        var n: usize = 0;
        for (1..33) |l| {
            for (0..256) |sym| {
                if (codesize[sym] == l) {
                    h.vals[n] = @intCast(sym);
                    n += 1;
                }
            }
        }
        h.n = n;
        // The codes themselves.
        var code: u32 = 0;
        var k: usize = 0;
        for (1..17) |l| {
            var c: u32 = 0;
            while (c < h.bits[l]) : (c += 1) {
                h.code[h.vals[k]] = @intCast(code);
                h.size[h.vals[k]] = @intCast(l);
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
        return h;
    }
};

const BitWriter = struct {
    out: *std.ArrayList(u8),
    gpa: Allocator,
    acc: u32 = 0,
    nbits: u5 = 0,

    fn put(self: *BitWriter, code: u32, size: u5) Allocator.Error!void {
        if (size == 0) return;
        self.acc = (self.acc << size) | (code & ((@as(u32, 1) << size) - 1));
        self.nbits += size;
        while (self.nbits >= 8) {
            const b: u8 = @intCast((self.acc >> (self.nbits - 8)) & 0xff);
            try self.out.append(self.gpa, b);
            if (b == 0xff) try self.out.append(self.gpa, 0); // a 0xFF inside the data is followed by a zero
            self.nbits -= 8;
        }
    }

    fn flush(self: *BitWriter) Allocator.Error!void {
        if (self.nbits > 0) try self.put(0x7f, 8 - self.nbits); // pad with ones
    }
};

/// One quantised block and which tables it uses.
const Block = struct { coef: [64]i16, chroma: bool };

fn tally(blocks: []const Block, dc_prev: *[3]i32, comp: []const u8, dc: *[2][256]u32, ac: *[2][256]u32) void {
    @memset(dc_prev, 0);
    for (blocks, comp) |b, ci| {
        const t: usize = if (b.chroma) 1 else 0;
        const diff = @as(i32, b.coef[0]) - dc_prev[ci];
        dc_prev[ci] = b.coef[0];
        dc[t][category(diff)] += 1;
        var run: u32 = 0;
        var k: usize = 1;
        while (k < 64) : (k += 1) {
            const v = b.coef[k];
            if (v == 0) {
                run += 1;
                continue;
            }
            while (run > 15) : (run -= 16) ac[t][0xf0] += 1;
            ac[t][(run << 4) | category(v)] += 1;
            run = 0;
        }
        if (run > 0) ac[t][0x00] += 1;
    }
}

/// Encodes `width` x `height` pixels of 3 bytes (red, green, blue) as a JPEG file. `quality` is 1 to 100 (75 is a good
/// thumbnail). The caller frees the result with `gpa`.
pub fn encodeRgb(gpa: Allocator, rgb: []const u8, width: u32, height: u32, quality: u8) Error![]u8 {
    if (width == 0 or height == 0 or width > 65535 or height > 65535) return error.BadSize;
    if (rgb.len != @as(usize, width) * height * 3) return error.BadSize;
    const w: usize = width;
    const h: usize = height;
    const mcu_w = (w + 15) / 16;
    const mcu_h = (h + 15) / 16;
    const pw = mcu_w * 16;
    const ph = mcu_h * 16;

    // Planes: luma at full size, colour halved, edges repeated to fill the last blocks.
    const luma = try gpa.alloc(f32, pw * ph);
    defer gpa.free(luma);
    const cw = pw / 2;
    const ch = ph / 2;
    const cb = try gpa.alloc(f32, cw * ch);
    defer gpa.free(cb);
    const cr = try gpa.alloc(f32, cw * ch);
    defer gpa.free(cr);
    @memset(cb, 0);
    @memset(cr, 0);
    for (0..ph) |y| {
        const sy = @min(y, h - 1);
        for (0..pw) |x| {
            const sx = @min(x, w - 1);
            const p = (sy * w + sx) * 3;
            const r: f32 = @floatFromInt(rgb[p]);
            const g: f32 = @floatFromInt(rgb[p + 1]);
            const b: f32 = @floatFromInt(rgb[p + 2]);
            luma[y * pw + x] = 0.299 * r + 0.587 * g + 0.114 * b - 128.0;
            const ci = (y / 2) * cw + (x / 2);
            cb[ci] += (-0.168736 * r - 0.331264 * g + 0.5 * b) * 0.25;
            cr[ci] += (0.5 * r - 0.418688 * g - 0.081312 * b) * 0.25;
        }
    }

    const qy = scaledTable(base_luma, quality);
    const qc = scaledTable(base_chroma, quality);
    const m = dctMatrix();
    const nblocks = mcu_w * mcu_h * 6;
    const blocks = try gpa.alloc(Block, nblocks);
    defer gpa.free(blocks);
    const comps = try gpa.alloc(u8, nblocks);
    defer gpa.free(comps);
    var bi: usize = 0;
    var tile: [64]f32 = undefined;
    for (0..mcu_h) |my| {
        for (0..mcu_w) |mx| {
            // Four luma blocks, then Cb, then Cr.
            for (0..4) |k| {
                const bx = mx * 16 + (k % 2) * 8;
                const by = my * 16 + (k / 2) * 8;
                for (0..8) |y| for (0..8) |x| {
                    tile[y * 8 + x] = luma[(by + y) * pw + bx + x];
                };
                blockCoefficients(&m, &tile, &qy, &blocks[bi].coef);
                blocks[bi].chroma = false;
                comps[bi] = 0;
                bi += 1;
            }
            inline for (.{ cb, cr }, 0..) |plane, ci| {
                const bx = mx * 8;
                const by = my * 8;
                for (0..8) |y| for (0..8) |x| {
                    tile[y * 8 + x] = plane[(by + y) * cw + bx + x];
                };
                blockCoefficients(&m, &tile, &qc, &blocks[bi].coef);
                blocks[bi].chroma = true;
                comps[bi] = @intCast(ci + 1);
                bi += 1;
            }
        }
    }

    // Pass one: how often each symbol is used; the Huffman tables follow from that.
    var dc_counts: [2][256]u32 = @splat(@splat(0));
    var ac_counts: [2][256]u32 = @splat(@splat(0));
    var dc_prev: [3]i32 = undefined;
    tally(blocks, &dc_prev, comps, &dc_counts, &ac_counts);
    const dc_tab = [2]Huff{ Huff.make(&dc_counts[0]), Huff.make(&dc_counts[1]) };
    const ac_tab = [2]Huff{ Huff.make(&ac_counts[0]), Huff.make(&ac_counts[1]) };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // Headers.
    try out.appendSlice(gpa, &.{ 0xff, 0xd8 }); // SOI
    try out.appendSlice(gpa, &.{ 0xff, 0xe0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0 }); // JFIF 1.1, no density
    inline for (.{ .{ 0, qy }, .{ 1, qc } }) |t| {
        try out.appendSlice(gpa, &.{ 0xff, 0xdb, 0, 67, t[0] });
        for (0..64) |i| try out.append(gpa, t[1][zigzag[i]]);
    }
    try out.appendSlice(gpa, &.{ 0xff, 0xc0, 0, 17, 8 });
    try out.appendSlice(gpa, &.{ @intCast(h >> 8), @intCast(h & 0xff), @intCast(w >> 8), @intCast(w & 0xff), 3 });
    try out.appendSlice(gpa, &.{ 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1 }); // Y 2x2 (table 0), Cb and Cr 1x1 (table 1)
    inline for (.{ .{ 0x00, &dc_tab[0] }, .{ 0x01, &dc_tab[1] }, .{ 0x10, &ac_tab[0] }, .{ 0x11, &ac_tab[1] } }) |t| {
        const hf: *const Huff = t[1];
        try out.appendSlice(gpa, &.{ 0xff, 0xc4 });
        const len: u16 = @intCast(2 + 1 + 16 + hf.n);
        try out.appendSlice(gpa, &.{ @intCast(len >> 8), @intCast(len & 0xff), t[0] });
        try out.appendSlice(gpa, hf.bits[1..17]);
        try out.appendSlice(gpa, hf.vals[0..hf.n]);
    }
    try out.appendSlice(gpa, &.{ 0xff, 0xda, 0, 12, 3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0 });

    // Pass two: the picture itself.
    var bw: BitWriter = .{ .out = &out, .gpa = gpa };
    @memset(&dc_prev, 0);
    for (blocks, comps) |b, ci| {
        const t: usize = if (b.chroma) 1 else 0;
        const diff = @as(i32, b.coef[0]) - dc_prev[ci];
        dc_prev[ci] = b.coef[0];
        const cat = category(diff);
        try bw.put(dc_tab[t].code[cat], @intCast(dc_tab[t].size[cat]));
        if (cat > 0) try bw.put(@bitCast(if (diff < 0) diff + (@as(i32, 1) << cat) - 1 else diff), cat);
        var run: u32 = 0;
        var k: usize = 1;
        while (k < 64) : (k += 1) {
            const v: i32 = b.coef[k];
            if (v == 0) {
                run += 1;
                continue;
            }
            while (run > 15) : (run -= 16) try bw.put(ac_tab[t].code[0xf0], @intCast(ac_tab[t].size[0xf0]));
            const c = category(v);
            const sym: usize = (run << 4) | c;
            try bw.put(ac_tab[t].code[sym], @intCast(ac_tab[t].size[sym]));
            try bw.put(@bitCast(if (v < 0) v + (@as(i32, 1) << c) - 1 else v), c);
            run = 0;
        }
        if (run > 0) try bw.put(ac_tab[t].code[0x00], @intCast(ac_tab[t].size[0x00]));
    }
    try bw.flush();
    try out.appendSlice(gpa, &.{ 0xff, 0xd9 }); // EOI
    return out.toOwnedSlice(gpa);
}

/// A picture reduced so that its longer side is at most `max_side` (never enlarged), each new pixel the average of the
/// box of the old ones it covers. The caller frees `pixels` with `gpa`.
pub const Scaled = struct { pixels: []u8, width: u32, height: u32 };

pub fn scaleDown(gpa: Allocator, rgb: []const u8, width: u32, height: u32, max_side: u32) Error!Scaled {
    if (width == 0 or height == 0 or rgb.len != @as(usize, width) * height * 3 or max_side == 0) return error.BadSize;
    const longer = @max(width, height);
    if (longer <= max_side) return .{ .pixels = try gpa.dupe(u8, rgb), .width = width, .height = height };
    const tw: u32 = @max(1, @as(u32, @intCast(@as(u64, width) * max_side / longer)));
    const th: u32 = @max(1, @as(u32, @intCast(@as(u64, height) * max_side / longer)));
    const out = try gpa.alloc(u8, @as(usize, tw) * th * 3);
    errdefer gpa.free(out);
    for (0..th) |ty| {
        const y0: usize = @intCast(@as(u64, ty) * height / th);
        const y1: usize = @max(y0 + 1, @as(usize, @intCast(@as(u64, ty + 1) * height / th)));
        for (0..tw) |tx| {
            const x0: usize = @intCast(@as(u64, tx) * width / tw);
            const x1: usize = @max(x0 + 1, @as(usize, @intCast(@as(u64, tx + 1) * width / tw)));
            var sum = [3]u64{ 0, 0, 0 };
            for (y0..y1) |y| {
                for (x0..x1) |x| {
                    const p = (y * width + x) * 3;
                    sum[0] += rgb[p];
                    sum[1] += rgb[p + 1];
                    sum[2] += rgb[p + 2];
                }
            }
            const n: u64 = (y1 - y0) * (x1 - x0);
            const o = (ty * tw + tx) * 3;
            out[o] = @intCast(sum[0] / n);
            out[o + 1] = @intCast(sum[1] / n);
            out[o + 2] = @intCast(sum[2] / n);
        }
    }
    return .{ .pixels = out, .width = tw, .height = th };
}

const testing = std.testing;
const image = @import("image.zig");

/// A smooth picture with a sharp edge and some colour, to compare after a round trip.
fn testPicture(gpa: Allocator, w: u32, h: u32) ![]u8 {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 3);
    for (0..h) |y| {
        for (0..w) |x| {
            const p = (y * w + x) * 3;
            const edge = x > w / 2;
            px[p] = @intCast((x * 255 / @max(w - 1, 1)) % 256);
            px[p + 1] = @intCast((y * 255 / @max(h - 1, 1)) % 256);
            px[p + 2] = if (edge) 200 else 40;
        }
    }
    return px;
}

test "the encoder's output is a JPEG that the decoder reads back as nearly the same picture, at odd sizes too" {
    if (!image.available) return error.SkipZigTest;
    for ([_][2]u32{ .{ 64, 48 }, .{ 17, 33 }, .{ 1, 1 }, .{ 320, 200 }, .{ 9, 300 } }) |dim| {
        const px = try testPicture(testing.allocator, dim[0], dim[1]);
        defer testing.allocator.free(px);
        const jpg = try encodeRgb(testing.allocator, px, dim[0], dim[1], 90);
        defer testing.allocator.free(jpg);
        try testing.expect(jpg.len > 100 and jpg[0] == 0xff and jpg[1] == 0xd8 and jpg[jpg.len - 2] == 0xff and jpg[jpg.len - 1] == 0xd9);
        const info = try image.info(jpg);
        try testing.expectEqual(dim[0], info.width);
        try testing.expectEqual(dim[1], info.height);
        const back = try image.decodeRgb(jpg);
        defer back.deinit();
        try testing.expectEqual(px.len, back.pixels.len);
        var total: u64 = 0;
        for (px, back.pixels) |a, b| total += if (a > b) a - b else b - a;
        const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(px.len));
        // Colour is halved in resolution and the edge is sharp, so some difference is normal (most of a very narrow
        // picture is edge); a broken encoder is far off. (Checked against another decoder: Pillow reads these files
        // with the same errors.)
        const limit: f64 = if (dim[0] >= 64) 3.0 else 12.0;
        try testing.expect(mean < limit);
    }
}

test "a lower quality makes a smaller file; bad sizes are refused" {
    const px = try testPicture(testing.allocator, 160, 120);
    defer testing.allocator.free(px);
    const hi = try encodeRgb(testing.allocator, px, 160, 120, 90);
    defer testing.allocator.free(hi);
    const lo = try encodeRgb(testing.allocator, px, 160, 120, 40);
    defer testing.allocator.free(lo);
    try testing.expect(lo.len < hi.len);
    try testing.expectError(error.BadSize, encodeRgb(testing.allocator, px, 0, 120, 75));
    try testing.expectError(error.BadSize, encodeRgb(testing.allocator, px[0..10], 160, 120, 75));
}

test "scaleDown keeps the proportions, never enlarges, and averages" {
    const px = try testPicture(testing.allocator, 400, 200);
    defer testing.allocator.free(px);
    const s = try scaleDown(testing.allocator, px, 400, 200, 100);
    defer testing.allocator.free(s.pixels);
    try testing.expectEqual(@as(u32, 100), s.width);
    try testing.expectEqual(@as(u32, 50), s.height);
    const same = try scaleDown(testing.allocator, px, 400, 200, 1000);
    defer testing.allocator.free(same.pixels);
    try testing.expect(same.width == 400 and same.height == 200 and std.mem.eql(u8, same.pixels, px));
    // A flat picture stays flat.
    const flat = try testing.allocator.alloc(u8, 30 * 30 * 3);
    defer testing.allocator.free(flat);
    @memset(flat, 77);
    const f = try scaleDown(testing.allocator, flat, 30, 30, 7);
    defer testing.allocator.free(f.pixels);
    for (f.pixels) |v| try testing.expectEqual(@as(u8, 77), v);
}
