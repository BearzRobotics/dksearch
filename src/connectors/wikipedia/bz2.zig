//! A streaming bzip2 decoder over a file, built on the vendored libbz2.
//!
//! Handles files made of several bzip2 streams back to back (the form
//! Wikipedia's "multistream" dumps use), and reports where each stream ended
//! so a reader can save a position that starts a clean new stream later.
//! Memory use is fixed: one input buffer, plus libbz2's own state.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("wiki_c");

pub const Error = error{
    /// Not bzip2, damaged, or cut off.
    Corrupt,
    /// Reading the file failed.
    Io,
    OutOfMemory,
};

const in_size = 64 * 1024;

pub const Decoder = struct {
    gpa: Allocator,
    io: Io,
    file: Io.File,
    /// Offset in `file` of the next byte to fetch into `in`.
    next_fetch: u64,
    in: []u8,
    in_len: usize = 0,
    /// Input consumed so far, as an offset in `in`.
    in_pos: usize = 0,
    file_done: bool = false,
    strm: c.bz_stream = undefined,
    active: bool = false,
    /// Set when a stream finished: the file offset where the next one starts.
    boundary: ?u64 = null,

    /// Starts decoding at `offset`, which must be the start of a bzip2 stream.
    pub fn init(gpa: Allocator, io: Io, file: Io.File, offset: u64) Allocator.Error!Decoder {
        return .{ .gpa = gpa, .io = io, .file = file, .next_fetch = offset, .in = try gpa.alloc(u8, in_size) };
    }

    pub fn deinit(self: *Decoder) void {
        if (self.active) _ = c.BZ2_bzDecompressEnd(&self.strm);
        self.gpa.free(self.in);
        self.* = undefined;
    }

    /// File offset of the first byte not yet consumed by the decoder.
    fn consumedOffset(self: *const Decoder) u64 {
        return self.next_fetch - (self.in_len - self.in_pos);
    }

    /// If a stream ended during the last `read`, its end offset (once).
    pub fn takeBoundary(self: *Decoder) ?u64 {
        const b = self.boundary;
        self.boundary = null;
        return b;
    }

    fn fill(self: *Decoder) Error!void {
        if (self.file_done) return;
        var bufs = [_][]u8{self.in};
        const n = self.file.readPositional(self.io, &bufs, self.next_fetch) catch return error.Io;
        if (n == 0) {
            self.file_done = true;
            return;
        }
        self.next_fetch += n;
        self.in_len = n;
        self.in_pos = 0;
    }

    /// Decompressed bytes, 0 at the clean end of the file. Never returns
    /// bytes of two streams in one call.
    pub fn read(self: *Decoder, out: []u8) Error!usize {
        std.debug.assert(out.len > 0);
        while (true) {
            if (self.in_pos >= self.in_len) {
                try self.fill();
                if (self.in_pos >= self.in_len) {
                    // End of file. Fine between streams, an error inside one.
                    return if (self.active) error.Corrupt else 0;
                }
            }
            if (!self.active) {
                self.strm = std.mem.zeroes(c.bz_stream);
                if (c.BZ2_bzDecompressInit(&self.strm, 0, 0) != c.BZ_OK) return error.OutOfMemory;
                self.active = true;
            }
            self.strm.next_in = @ptrCast(self.in.ptr + self.in_pos);
            self.strm.avail_in = @intCast(self.in_len - self.in_pos);
            self.strm.next_out = @ptrCast(out.ptr);
            self.strm.avail_out = @intCast(@min(out.len, std.math.maxInt(c_uint)));
            const out_before = self.strm.avail_out;
            const rc = c.BZ2_bzDecompress(&self.strm);
            self.in_pos = self.in_len - self.strm.avail_in;
            const produced: usize = out_before - self.strm.avail_out;
            switch (rc) {
                c.BZ_OK => if (produced > 0) return produced,
                c.BZ_STREAM_END => {
                    _ = c.BZ2_bzDecompressEnd(&self.strm);
                    self.active = false;
                    self.boundary = self.consumedOffset();
                    return produced;
                },
                c.BZ_MEM_ERROR => return error.OutOfMemory,
                else => return error.Corrupt,
            }
        }
    }
};

// The decoder is tested against real bzip2 files (single and multi-stream)
// in ../wikipedia.zig, where the committed fixtures live.
