//! The trust anchors the crawler verifies HTTPS servers against.
//!
//! By default the Mozilla root store bundled in `vendor/cacert` (embedded in
//! the binary, so no system store or network is needed); a source may choose
//! the operating system's store or a PEM file of its own.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;
const build_options = @import("build_options");

/// The embedded Mozilla bundle (PEM).
pub const builtin_pem: []const u8 = if (build_options.crawler) @embedFile("cacert_pem") else "";

pub const Error = Allocator.Error || Io.File.OpenError || Bundle.AddCertsFromFileError || Bundle.RescanError || error{BadPem};

pub const Choice = union(enum) {
    builtin,
    system,
    file: []const u8,
};

/// Fills `bundle` (which must be empty) from `choice`. Expired certificates
/// are left out, as the standard library does for every source.
pub fn load(bundle: *Bundle, gpa: Allocator, io: Io, choice: Choice) Error!void {
    const now = Io.Clock.real.now(io);
    switch (choice) {
        .builtin => try addPem(bundle, gpa, builtin_pem, now.toSeconds()),
        .system => try bundle.rescan(gpa, io, now),
        .file => |path| {
            try bundle.addCertsFromFilePath(gpa, io, now, Io.Dir.cwd(), path);
            if (bundle.map.count() == 0) return error.BadPem;
        },
    }
}

/// Adds every `-----BEGIN CERTIFICATE-----` block of `pem`.
pub fn addPem(bundle: *Bundle, gpa: Allocator, pem: []const u8, now_sec: i64) Error!void {
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    try bundle.bytes.ensureUnusedCapacity(gpa, pem.len / 4 * 3 + 8);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, pem, at, begin)) |b| {
        const start = b + begin.len;
        const stop = std.mem.indexOfPos(u8, pem, start, end) orelse return error.BadPem;
        at = stop + end.len;
        const encoded = std.mem.trim(u8, pem[start..stop], " \t\r\n");
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.ensureUnusedCapacity(gpa, encoded.len / 4 * 3 + 8);
        const dest = bundle.bytes.allocatedSlice()[decoded_start..];
        const n = decoder.decode(dest, encoded) catch return error.BadPem;
        bundle.bytes.items.len += n;
        try bundle.parseCert(gpa, decoded_start, now_sec);
    }
}

const testing = std.testing;

test "the bundled store loads and holds well-known roots" {
    if (!build_options.crawler) return error.SkipZigTest;
    var b: Bundle = .empty;
    defer b.deinit(testing.allocator);
    try load(&b, testing.allocator, testing.io, .builtin);
    // 118 certificates at bundling time; some may expire, none should be lost wholesale.
    try testing.expect(b.map.count() > 100);
}

test "garbage is rejected, an empty file yields no anchors" {
    var b: Bundle = .empty;
    defer b.deinit(testing.allocator);
    try testing.expectError(error.BadPem, addPem(&b, testing.allocator, "-----BEGIN CERTIFICATE-----\nAAAA", 0));
    try testing.expectError(error.BadPem, addPem(&b, testing.allocator, "-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----", 0));
    try addPem(&b, testing.allocator, "no certificates here", 0);
    try testing.expectEqual(@as(u32, 0), b.map.count());
}
