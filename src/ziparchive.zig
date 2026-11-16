//! Reading parts out of a ZIP file (the container of `docx`, `odt` and `epub`), safely.
//!
//! A document from outside is untrusted, so: only the central directory is trusted for names
//! and sizes, names with `..`, absolute paths or backslashes are dropped by the standard
//! library, a part is only read if its declared size is within the caller's limit and its
//! compression ratio is believable (a few kilobytes cannot become gigabytes), and nothing is
//! ever written to disk: parts are read into memory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    /// Not a ZIP file, or an unsupported kind (multi-disk).
    NotZip,
    Damaged,
    /// A compression method other than stored and deflate.
    Unsupported,
    /// A part larger than the limit, or compressed suspiciously well.
    TooLarge,
    NotFound,
    Io,
    OutOfMemory,
};

const max_entries = 20000;
const max_name_bytes = 1024;
/// A part over this size that shrank by more than this factor is refused.
const max_ratio = 1000;
const ratio_checked_above = 1024 * 1024;

pub const Entry = struct {
    name: []const u8,
    zip: std.zip.Iterator.Entry,
};

pub const Archive = struct {
    io: Io,
    reader: Io.File.Reader,
    buf: [8192]u8 = undefined,
    entries: []Entry = &.{},

    /// Opens the archive in place (the reader points into this struct, so it must not move).
    pub fn open(self: *Archive, arena: Allocator, io: Io, file: Io.File) Error!void {
        self.io = io;
        self.reader = file.reader(io, &self.buf);
        var it = std.zip.Iterator.init(&self.reader) catch |e| return switch (e) {
            error.ReadFailed => error.Io,
            else => error.NotZip, // not a zip, or a kind (multi-disk) we do not read
        };
        var list: std.ArrayList(Entry) = .empty;
        var name_buf: [max_name_bytes]u8 = undefined;
        while (it.next() catch |e| return switch (e) {
            error.ReadFailed => error.Io,
            else => error.Damaged,
        }) |entry| {
            if (list.items.len >= max_entries) return error.TooLarge;
            if (entry.filename_len == 0 or entry.filename_len > max_name_bytes) continue;
            const name = entry.getFilename(&self.reader, &name_buf, .{}) catch |e| switch (e) {
                // A name that is unsafe (`..`, absolute, backslashes) or a method we cannot read: not offered.
                error.ReadFailed => return error.Io,
                else => continue,
            };
            if (name[name.len - 1] == '/') continue; // a folder
            try list.append(arena, .{ .name = try arena.dupe(u8, name), .zip = entry });
        }
        self.entries = list.items;
    }

    pub fn has(self: *const Archive, name: []const u8) bool {
        for (self.entries) |e| if (std.mem.eql(u8, e.name, name)) return true;
        return false;
    }

    /// The bytes of the part `name`, allocated from `arena`.
    pub fn read(self: *Archive, arena: Allocator, name: []const u8, max_bytes: u64) Error![]u8 {
        var found: ?Entry = null;
        for (self.entries) |e| if (std.mem.eql(u8, e.name, name)) {
            found = e;
            break;
        };
        const entry = found orelse return error.NotFound;
        const size = entry.zip.uncompressed_size;
        if (size > max_bytes) return error.TooLarge;
        if (size > ratio_checked_above and entry.zip.compressed_size > 0 and size / entry.zip.compressed_size > max_ratio) return error.TooLarge;
        var out: Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        entry.zip.extractTo(&self.reader, &out.writer) catch |e| return switch (e) {
            error.WriteFailed => error.OutOfMemory, // the in-memory writer only fails when memory is out
            error.ReadFailed => error.Io,
            error.UnsupportedCompressionMethod => error.Unsupported,
            else => error.Damaged,
        };
        const bytes = out.written();
        if (bytes.len > max_bytes) return error.TooLarge;
        return bytes;
    }
};

const testing = std.testing;

fn writeTmp(tmp: *testing.TmpDir, name: []const u8, bytes: []const u8) !Io.File {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    return tmp.dir.openFile(testing.io, name, .{});
}

test "reads stored and deflated parts of a real zip, refuses what it must" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try writeTmp(&tmp, "a.docx", @embedFile("testdata/office/sample.docx"));
    defer file.close(testing.io);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ar: Archive = undefined;
    try ar.open(a, testing.io, file);
    try testing.expect(ar.has("word/document.xml"));
    try testing.expect(ar.has("[Content_Types].xml")); // stored
    try testing.expect(!ar.has("nope.xml"));
    const doc = try ar.read(a, "word/document.xml", 1 << 20); // deflated
    try testing.expect(std.mem.indexOf(u8, doc, "Tides at the harbour") != null);
    const ct = try ar.read(a, "[Content_Types].xml", 1 << 20);
    try testing.expect(std.mem.startsWith(u8, ct, "<?xml"));
    try testing.expectError(error.NotFound, ar.read(a, "nope.xml", 1 << 20));
    try testing.expectError(error.TooLarge, ar.read(a, "word/document.xml", 10)); // over the caller's limit
}

test "something that is not a zip, and a damaged zip, are errors and not crashes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f1 = try writeTmp(&tmp, "text.zip", "this is plain text, not an archive at all");
    defer f1.close(testing.io);
    var ar1: Archive = undefined;
    try testing.expectError(error.NotZip, ar1.open(a, testing.io, f1));
    // The real archive with its tail cut off, and with bytes flipped everywhere.
    const real = @embedFile("testdata/office/sample.docx");
    var f2 = try writeTmp(&tmp, "cut.zip", real[0 .. real.len - 30]);
    defer f2.close(testing.io);
    var ar2: Archive = undefined;
    try testing.expect(std.meta.isError(ar2.open(a, testing.io, f2)));
    var prng = std.Random.DefaultPrng.init(0x7a69);
    const rand = prng.random();
    var buf: [real.len]u8 = undefined;
    for (0..60) |i| {
        _ = i;
        @memcpy(&buf, real);
        for (0..1 + rand.uintLessThan(usize, 6)) |_| buf[rand.uintLessThan(usize, buf.len)] = rand.int(u8);
        var f3 = try writeTmp(&tmp, "mut.zip", &buf);
        defer f3.close(testing.io);
        var ar3: Archive = undefined;
        ar3.open(a, testing.io, f3) catch continue;
        for (ar3.entries) |e| _ = ar3.read(a, e.name, 1 << 20) catch {};
    }
}
