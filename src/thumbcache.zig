//! The thumbnail cache (docs/decisions/0055): small JPEG copies of pictures for the gallery, made the first time a
//! picture is shown and kept in a folder up to a size the owner sets. Off unless `[images] thumbnails = true`.
//!
//! A thumbnail is named by the document it belongs to (`dir/ab/cd/ID.jpg`, the first four hex digits of the id as two
//! folder levels, so a million files do not sit in one folder). The cache knows its total size (measured once, then
//! kept); when a new thumbnail takes it over the limit the oldest are deleted until it is 10% under. Only the small copy
//! is kept: never the original, which for pictures of the web is fetched, shrunk and dropped.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const image = @import("image.zig");
const jpegenc = @import("jpegenc.zig");
const exif = @import("exif.zig");
const doc = @import("document.zig");

pub const Settings = struct {
    /// The folder the thumbnails live in (made when the first one is stored).
    dir: []const u8,
    /// The most the folder may hold, in bytes.
    max_bytes: u64,
    /// The longer side of a thumbnail, in pixels.
    px: u32 = 320,
    /// JPEG quality, 1 to 100.
    quality: u8 = 75,
};

pub const Error = error{ NotAPicture, TooLarge, Unsupported, Busy, OutOfMemory };

/// How many thumbnails are made at once (decoding a large picture takes memory and time).
pub const max_concurrent: u32 = 2;

pub const Stats = struct { files: u64, bytes: u64 };

pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    settings: Settings,
    mutex: Io.Mutex = .init,
    /// The folder's size and file count, once measured (the first store or look at the stats), then kept up to date.
    measured: bool = false,
    total: u64 = 0,
    files: u64 = 0,
    evicting: bool = false,
    busy: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: Allocator, io: Io, settings: Settings) Cache {
        return .{ .gpa = gpa, .io = io, .settings = settings };
    }

    fn pathOf(self: *const Cache, arena: Allocator, id: doc.Id) Allocator.Error![]u8 {
        const hex = std.fmt.bytesToHex(id, .lower);
        return std.fmt.allocPrint(arena, "{s}/{s}/{s}/{s}.jpg", .{ std.mem.trimEnd(u8, self.settings.dir, "/"), hex[0..2], hex[2..4], &hex });
    }

    /// The stored thumbnail of document `id`, or null.
    pub fn get(self: *Cache, arena: Allocator, id: doc.Id) ?[]const u8 {
        const path = self.pathOf(arena, id) catch return null;
        return Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(4 * 1024 * 1024)) catch null;
    }

    /// Keeps `bytes` as the thumbnail of `id`. A failure to write is not an error for the visitor: the thumbnail is just
    /// made again next time.
    pub fn put(self: *Cache, arena: Allocator, id: doc.Id, bytes: []const u8) void {
        self.ensureMeasured(arena);
        const path = self.pathOf(arena, id) catch return;
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
        Io.Dir.cwd().createDirPath(self.io, path[0..slash]) catch return;
        const tmp = std.fmt.allocPrint(arena, "{s}.part", .{path}) catch return;
        {
            const f = Io.Dir.cwd().createFile(self.io, tmp, .{ .truncate = true }) catch return;
            defer f.close(self.io);
            f.writePositionalAll(self.io, bytes, 0) catch {
                Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
                return;
            };
        }
        Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, self.io) catch {
            Io.Dir.cwd().deleteFile(self.io, tmp) catch {};
            return;
        };
        var over = false;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.total += bytes.len;
            self.files += 1;
            if (self.total > self.settings.max_bytes and !self.evicting) {
                self.evicting = true;
                over = true;
            }
        }
        if (over) self.evict(arena);
    }

    /// Measures the folder once (a walk over all its files).
    fn ensureMeasured(self: *Cache, arena: Allocator) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.measured) return;
        const s = self.scan(arena, null);
        self.total = s.bytes;
        self.files = s.files;
        self.measured = true;
    }

    const Old = struct { mtime: i96, size: u64, path: []const u8 };

    /// Walks the folder: totals, and (when `list` is given) every file with its age.
    fn scan(self: *Cache, arena: Allocator, list: ?*std.ArrayList(Old)) Stats {
        var out: Stats = .{ .files = 0, .bytes = 0 };
        var dir = Io.Dir.cwd().openDir(self.io, self.settings.dir, .{ .iterate = true }) catch return out;
        defer dir.close(self.io);
        var walker = dir.walk(arena) catch return out;
        defer walker.deinit();
        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".jpg")) continue;
            const st = dir.statFile(self.io, entry.path, .{}) catch continue;
            out.files += 1;
            out.bytes += st.size;
            if (list) |l| {
                const p = arena.dupe(u8, entry.path) catch continue;
                l.append(arena, .{ .mtime = st.mtime.nanoseconds, .size = st.size, .path = p }) catch continue;
            }
        }
        return out;
    }

    fn olderFirst(_: void, a: Old, b: Old) bool {
        return a.mtime < b.mtime;
    }

    /// Deletes the oldest thumbnails until the folder is 10% under its limit.
    fn evict(self: *Cache, arena: Allocator) void {
        defer {
            self.mutex.lockUncancelable(self.io);
            self.evicting = false;
            self.mutex.unlock(self.io);
        }
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        _ = arena;
        var list: std.ArrayList(Old) = .empty;
        const s = self.scan(a, &list);
        std.mem.sort(Old, list.items, {}, olderFirst);
        const target = self.settings.max_bytes / 10 * 9;
        var total = s.bytes;
        var files = s.files;
        var dir = Io.Dir.cwd().openDir(self.io, self.settings.dir, .{}) catch return;
        defer dir.close(self.io);
        for (list.items) |o| {
            if (total <= target) break;
            dir.deleteFile(self.io, o.path) catch continue;
            total -|= o.size;
            files -|= 1;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.total = total;
        self.files = files;
        self.measured = true;
    }

    /// What the folder holds now (measured on the first call).
    pub fn stats(self: *Cache, arena: Allocator) Stats {
        self.ensureMeasured(arena);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .files = self.files, .bytes = self.total };
    }

    /// Deletes every thumbnail. Returns how many there were.
    pub fn clear(self: *Cache) u64 {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        var list: std.ArrayList(Old) = .empty;
        const s = self.scan(a, &list);
        var dir = Io.Dir.cwd().openDir(self.io, self.settings.dir, .{}) catch return 0;
        defer dir.close(self.io);
        for (list.items) |o| dir.deleteFile(self.io, o.path) catch {};
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.total = 0;
        self.files = 0;
        self.measured = true;
        return s.files;
    }

    /// Makes the thumbnail of the picture in `original` (JPEG, PNG, GIF, WebP or BMP): decoded, turned upright by its EXIF
    /// orientation, reduced and written as a JPEG. At most `max_concurrent` run at once; more get `error.Busy`.
    pub fn make(self: *Cache, gpa: Allocator, original: []const u8) Error![]u8 {
        if (self.busy.fetchAdd(1, .acq_rel) >= max_concurrent) {
            _ = self.busy.fetchSub(1, .acq_rel);
            return error.Busy;
        }
        defer _ = self.busy.fetchSub(1, .acq_rel);
        if (!image.available) return error.Unsupported;
        const d = image.decodeRgb(original) catch |e| return switch (e) {
            error.TooLarge => error.TooLarge,
            error.Unsupported => error.Unsupported,
            error.OutOfMemory => error.OutOfMemory,
            error.NotAnImage => error.NotAPicture,
        };
        defer d.deinit();
        const small = jpegenc.scaleDown(gpa, d.pixels, d.width, d.height, self.settings.px) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.BadSize => error.NotAPicture,
        };
        defer gpa.free(small.pixels);
        const orientation: u16 = if (exif.read(original)) |ex| (ex.orientation orelse 1) else 1;
        const upright = try turn(gpa, small, orientation);
        defer if (upright.owned) gpa.free(upright.pixels);
        return jpegenc.encodeRgb(gpa, upright.pixels, upright.width, upright.height, self.settings.quality) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.BadSize => error.NotAPicture,
        };
    }
};

const Turned = struct { pixels: []const u8, width: u32, height: u32, owned: bool };

/// The picture turned upright for EXIF orientation 1 to 8 (anything else leaves it as it is).
fn turn(gpa: Allocator, s: jpegenc.Scaled, orientation: u16) Allocator.Error!Turned {
    if (orientation < 2 or orientation > 8) return .{ .pixels = s.pixels, .width = s.width, .height = s.height, .owned = false };
    const w = s.width;
    const h = s.height;
    const swap = orientation >= 5;
    const ow: u32 = if (swap) h else w;
    const oh: u32 = if (swap) w else h;
    const out = try gpa.alloc(u8, @as(usize, ow) * oh * 3);
    for (0..oh) |y| {
        for (0..ow) |x| {
            const sx: usize, const sy: usize = switch (orientation) {
                2 => .{ w - 1 - x, y },
                3 => .{ w - 1 - x, h - 1 - y },
                4 => .{ x, h - 1 - y },
                5 => .{ y, x },
                6 => .{ y, h - 1 - x },
                7 => .{ w - 1 - y, h - 1 - x },
                else => .{ w - 1 - y, x },
            };
            const si = (sy * w + sx) * 3;
            const oi = (y * ow + x) * 3;
            out[oi] = s.pixels[si];
            out[oi + 1] = s.pixels[si + 1];
            out[oi + 2] = s.pixels[si + 2];
        }
    }
    return .{ .pixels = out, .width = ow, .height = oh, .owned = true };
}

const testing = std.testing;

fn tinyPicture(gpa: Allocator, w: u32, h: u32) ![]u8 {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 3);
    for (0..h) |y| for (0..w) |x| {
        const p = (y * w + x) * 3;
        px[p] = @intCast(x * 255 / @max(w - 1, 1));
        px[p + 1] = @intCast(y * 255 / @max(h - 1, 1));
        px[p + 2] = 90;
    };
    return px;
}

test "orientations turn the picture upright: corners land where they should" {
    // A 3 x 2 picture whose pixels are 1..6 in the red channel.
    var px: [18]u8 = undefined;
    for (0..6) |i| {
        px[i * 3] = @intCast(i + 1);
        px[i * 3 + 1] = 0;
        px[i * 3 + 2] = 0;
    }
    const s: jpegenc.Scaled = .{ .pixels = &px, .width = 3, .height = 2 };
    // 1 2 3
    // 4 5 6
    const flipped = try turn(testing.allocator, s, 2);
    defer testing.allocator.free(flipped.pixels);
    try testing.expectEqual(@as(u8, 3), flipped.pixels[0]); // top-left is the old top-right
    const cw = try turn(testing.allocator, s, 6); // rotate 90 clockwise: 4 1 / 5 2 / 6 3
    defer testing.allocator.free(cw.pixels);
    try testing.expect(cw.width == 2 and cw.height == 3);
    try testing.expectEqual(@as(u8, 4), cw.pixels[0]);
    try testing.expectEqual(@as(u8, 1), cw.pixels[3]);
    try testing.expectEqual(@as(u8, 6), cw.pixels[6 * 3 - 6]);
    const ccw = try turn(testing.allocator, s, 8); // rotate 90 counter-clockwise: 3 6 / 2 5 / 1 4
    defer testing.allocator.free(ccw.pixels);
    try testing.expectEqual(@as(u8, 3), ccw.pixels[0]);
    try testing.expectEqual(@as(u8, 6), ccw.pixels[3]);
    const upright = try turn(testing.allocator, s, 1);
    try testing.expect(!upright.owned and upright.pixels.ptr == s.pixels.ptr);
}

test "a thumbnail is made from a picture, stored under its id, read back, and the oldest go when the folder is over its limit" {
    if (!image.available) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const root = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".zig-cache", a);
    const dir = try std.fmt.allocPrint(a, "{s}/tmp/{s}/thumbs", .{ root, tmp.sub_path });
    // A bigger picture, as the JPEG the encoder writes (so no test file is needed).
    const px = try tinyPicture(testing.allocator, 640, 480);
    defer testing.allocator.free(px);
    const original = try jpegenc.encodeRgb(testing.allocator, px, 640, 480, 85);
    defer testing.allocator.free(original);
    var cache = Cache.init(testing.allocator, testing.io, .{ .dir = dir, .max_bytes = 1 << 30, .px = 100, .quality = 70 });
    const thumb = try cache.make(testing.allocator, original);
    defer testing.allocator.free(thumb);
    try testing.expect(thumb.len < original.len);
    const info = try image.info(thumb);
    try testing.expect(info.width == 100 and info.height == 75);
    const id: doc.Id = @splat(0xab);
    try testing.expect(cache.get(a, id) == null);
    cache.put(a, id, thumb);
    const got = cache.get(a, id).?;
    try testing.expectEqualSlices(u8, thumb, got);
    const st = cache.stats(a);
    try testing.expectEqual(@as(u64, 1), st.files);
    try testing.expectEqual(@as(u64, thumb.len), st.bytes);
    // Not a picture, and too many at once.
    try testing.expectError(error.NotAPicture, cache.make(testing.allocator, "this is not a picture at all"));
    cache.busy.store(max_concurrent, .monotonic);
    try testing.expectError(error.Busy, cache.make(testing.allocator, original));
    cache.busy.store(0, .monotonic);
    // A small limit: storing more removes the oldest, and the folder ends under the limit.
    var small = Cache.init(testing.allocator, testing.io, .{ .dir = dir, .max_bytes = thumb.len * 3, .px = 100 });
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        const other: doc.Id = @splat(i);
        small.put(a, other, thumb);
    }
    const after = small.stats(a);
    try testing.expect(after.bytes <= thumb.len * 3 and after.files >= 1);
    // Clearing removes the rest.
    try testing.expect(small.clear() >= 1);
    try testing.expectEqual(@as(u64, 0), small.stats(a).files);
}
