//! Admin credentials: a bearer token and/or a password, stored only as hashes
//! in a permission-restricted TOML file (docs/decisions/0012).
//!
//! The file holds at most two keys:
//!   token_hash    = "sha256:<64 hex digits>"
//!   password_hash = "$argon2id$v=19$m=...,t=...,p=...$salt$hash"
//! Nothing here ever writes or logs a plaintext secret except `newToken`,
//! which returns the token once for the caller to print.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const toml = @import("toml");
const argon2 = std.crypto.pwhash.argon2;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{
    /// The file exists but cannot be read.
    Unreadable,
    /// Not valid TOML, an unknown key, or a malformed value.
    Malformed,
    /// Group or others can read the file; it is refused until fixed.
    InsecurePermissions,
    /// Writing the file failed.
    WriteFailed,
    EntropyUnavailable,
    OutOfMemory,
};

pub const max_file_bytes = 4096;
pub const max_password_bytes = 1024;
pub const token_prefix = "dks_";
const argon_params = argon2.Params.owasp_2id;

pub const Secrets = struct {
    token_hash: ?[32]u8 = null,
    /// PHC string, owned (see `deinit`).
    password_hash: ?[]u8 = null,

    pub fn deinit(self: *Secrets, gpa: Allocator) void {
        if (self.password_hash) |p| gpa.free(p);
        self.* = .{};
    }

    /// True if at least one credential is set.
    pub fn any(self: Secrets) bool {
        return self.token_hash != null or self.password_hash != null;
    }

    /// Constant-time check of a presented bearer token.
    pub fn verifyToken(self: Secrets, presented: []const u8) bool {
        const want = self.token_hash orelse return false;
        var got: [32]u8 = undefined;
        Sha256.hash(presented, &got, .{});
        return std.crypto.timing_safe.eql([32]u8, want, got);
    }

    /// Checks a password against the stored Argon2id hash (slow on purpose).
    pub fn verifyPassword(self: Secrets, gpa: Allocator, io: Io, presented: []const u8) bool {
        const stored = self.password_hash orelse return false;
        if (presented.len == 0 or presented.len > max_password_bytes) return false;
        argon2.strVerify(stored, presented, .{ .allocator = gpa }, io) catch return false;
        return true;
    }

    /// Replaces the token hash with the hash of a new random token and
    /// returns that token (the only time it exists in plaintext).
    pub fn newToken(self: *Secrets, io: Io, out: *[token_len]u8) Error![]const u8 {
        var raw: [32]u8 = undefined;
        io.randomSecure(&raw) catch return error.EntropyUnavailable;
        defer std.crypto.secureZero(u8, &raw);
        const enc = std.base64.url_safe_no_pad.Encoder;
        @memcpy(out[0..token_prefix.len], token_prefix);
        _ = enc.encode(out[token_prefix.len..], &raw);
        Sha256.hash(out, &self.token_hash.?, .{});
        return out;
    }

    /// Replaces the password hash. `password` must be 1 to 1024 bytes.
    pub fn setPassword(self: *Secrets, gpa: Allocator, io: Io, password: []const u8) Error!void {
        if (password.len == 0 or password.len > max_password_bytes) return error.Malformed;
        var buf: [128]u8 = undefined; // a PHC string for these parameters is about 100 bytes
        const phc = argon2.strHash(password, .{ .allocator = gpa, .params = argon_params }, &buf, io) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        const owned = try gpa.dupe(u8, phc);
        if (self.password_hash) |old| gpa.free(old);
        self.password_hash = owned;
    }
};

/// Length of a token: the prefix plus 32 bytes in base64url without padding.
pub const token_len = token_prefix.len + 43;

/// Loads the file at `path` (relative to `dir`). A missing file is an empty
/// `Secrets`, not an error. A file that others can read is refused.
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!Secrets {
    return (try loadFingerprinted(gpa, io, dir, path)).secrets;
}

pub const Loaded = struct {
    secrets: Secrets,
    /// SHA-256 of the file's text. It changes whenever a credential does, so
    /// a session made under an older file can be told apart and dropped.
    fingerprint: [32]u8,
};

pub fn loadFingerprinted(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!Loaded {
    const file = dir.openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return .{ .secrets = .{}, .fingerprint = @splat(0) },
        else => return error.Unreadable,
    };
    defer file.close(io);
    const st = file.stat(io) catch return error.Unreadable;
    if (@hasDecl(@TypeOf(st.permissions), "toMode")) {
        if (st.permissions.toMode() & 0o077 != 0) return error.InsecurePermissions;
    }
    if (st.size > max_file_bytes) return error.Malformed;
    var buf: [max_file_bytes]u8 = undefined;
    const n = file.readPositionalAll(io, buf[0..@intCast(st.size)], 0) catch return error.Unreadable;
    var fp: [32]u8 = undefined;
    Sha256.hash(buf[0..n], &fp, .{});
    return .{ .secrets = try parse(gpa, buf[0..n]), .fingerprint = fp };
}

pub fn parse(gpa: Allocator, text: []const u8) Error!Secrets {
    var tdiag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(gpa, text, .{}, &tdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    defer doc.deinit();
    var s: Secrets = .{};
    errdefer s.deinit(gpa);
    var it = doc.root.entries.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const value = switch (e.value_ptr.*) {
            .string => |v| v,
            else => return error.Malformed,
        };
        if (std.mem.eql(u8, key, "token_hash")) {
            const prefix = "sha256:";
            if (!std.mem.startsWith(u8, value, prefix)) return error.Malformed;
            const hex = value[prefix.len..]; // not trimStart: that strips a character set, eating leading hex digits like 5 or a
            if (hex.len != 64) return error.Malformed;
            var h: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&h, hex) catch return error.Malformed;
            s.token_hash = h;
        } else if (std.mem.eql(u8, key, "password_hash")) {
            if (!std.mem.startsWith(u8, value, "$argon2id$") or value.len > 256) return error.Malformed;
            s.password_hash = try gpa.dupe(u8, value);
        } else return error.Malformed;
    }
    return s;
}

/// Writes `s` to `path` (relative to `dir`) with mode 0600, via a temporary
/// file and a rename, so a crash never leaves a half-written file.
pub fn save(io: Io, dir: Io.Dir, path: []const u8, s: Secrets) Error!void {
    var tmp_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_name_buf, "{s}.tmp", .{path}) catch return error.WriteFailed;

    var body: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&body);
    w.writeAll("# dksearch admin credentials (hashes only). Written by `dksearch admin-token` and `dksearch admin-password`.\n") catch return error.WriteFailed;
    if (s.token_hash) |h| w.print("token_hash = \"sha256:{x}\"\n", .{h}) catch return error.WriteFailed;
    if (s.password_hash) |p| w.print("password_hash = \"{s}\"\n", .{p}) catch return error.WriteFailed;

    {
        const f = dir.createFile(io, tmp, .{
            .truncate = true,
            .permissions = Io.File.Permissions.fromMode(0o600),
        }) catch return error.WriteFailed;
        defer f.close(io);
        // The mode given at creation is reduced by the umask but never widened.
        f.setPermissions(io, Io.File.Permissions.fromMode(0o600)) catch return error.WriteFailed;
        f.writePositionalAll(io, w.buffered(), 0) catch return error.WriteFailed;
        f.sync(io) catch return error.WriteFailed;
    }
    dir.rename(tmp, dir, path, io) catch return error.WriteFailed;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "a new token verifies, others do not, and only its hash is stored" {
    var s: Secrets = .{};
    defer s.deinit(testing.allocator);
    s.token_hash = @splat(0);
    var buf: [token_len]u8 = undefined;
    const tok = try s.newToken(testing.io, &buf);
    try testing.expect(std.mem.startsWith(u8, tok, token_prefix));
    try testing.expectEqual(@as(usize, token_len), tok.len);
    try testing.expect(s.verifyToken(tok));
    try testing.expect(!s.verifyToken("dks_wrong"));
    try testing.expect(!s.verifyToken(""));
    var buf2: [token_len]u8 = undefined;
    const tok2 = try s.newToken(testing.io, &buf2);
    try testing.expect(!std.mem.eql(u8, tok, tok2)); // random
    try testing.expect(!s.verifyToken(tok)); // rotated away
    try testing.expect(s.verifyToken(tok2));
    try testing.expect(!(Secrets{}).verifyToken(tok2)); // nothing configured
}

test "passwords: hashed, verified, never stored in plaintext" {
    var s: Secrets = .{};
    defer s.deinit(testing.allocator);
    try s.setPassword(testing.allocator, testing.io, "correct horse battery staple");
    try testing.expect(std.mem.startsWith(u8, s.password_hash.?, "$argon2id$"));
    try testing.expect(std.mem.indexOf(u8, s.password_hash.?, "horse") == null);
    try testing.expect(s.verifyPassword(testing.allocator, testing.io, "correct horse battery staple"));
    try testing.expect(!s.verifyPassword(testing.allocator, testing.io, "correct horse battery stapler"));
    try testing.expect(!s.verifyPassword(testing.allocator, testing.io, ""));
    try testing.expectError(error.Malformed, s.setPassword(testing.allocator, testing.io, ""));
    // A second hash of the same password differs (random salt).
    const first = try testing.allocator.dupe(u8, s.password_hash.?);
    defer testing.allocator.free(first);
    try s.setPassword(testing.allocator, testing.io, "correct horse battery staple");
    try testing.expect(!std.mem.eql(u8, first, s.password_hash.?));
}

test "save and load round-trip; the file is private; loose permissions are refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s: Secrets = .{};
    defer s.deinit(testing.allocator);
    s.token_hash = @splat(0);
    var buf: [token_len]u8 = undefined;
    const tok = try s.newToken(testing.io, &buf);
    try s.setPassword(testing.allocator, testing.io, "pw");
    try save(testing.io, tmp.dir, "admin.toml", s);

    const st = try tmp.dir.statFile(testing.io, "admin.toml", .{});
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(st.permissions.toMode())) & 0o077);
    const text = try tmp.dir.readFileAlloc(testing.io, "admin.toml", testing.allocator, .limited(4096));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, tok) == null); // no plaintext token
    try testing.expect(std.mem.indexOf(u8, text, "\"pw\"") == null);

    var back = try load(testing.allocator, testing.io, tmp.dir, "admin.toml");
    defer back.deinit(testing.allocator);
    try testing.expect(back.verifyToken(tok));
    try testing.expect(back.verifyPassword(testing.allocator, testing.io, "pw"));

    // Loosen the mode: refused.
    const f = try tmp.dir.openFile(testing.io, "admin.toml", .{});
    try f.setPermissions(testing.io, Io.File.Permissions.fromMode(0o644));
    f.close(testing.io);
    try testing.expectError(error.InsecurePermissions, load(testing.allocator, testing.io, tmp.dir, "admin.toml"));
}

test "a missing file is empty; malformed files are refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var none = try load(testing.allocator, testing.io, tmp.dir, "nope.toml");
    defer none.deinit(testing.allocator);
    try testing.expect(!none.any());

    const bad = [_][]const u8{
        "token_hash = \"abc\"",
        "token_hash = \"sha256:zz\"",
        "password_hash = \"plaintext\"",
        "token_hash = 5",
        "extra = \"x\"",
        "not toml at all [[[",
    };
    for (bad) |text| try testing.expectError(error.Malformed, parse(testing.allocator, text));
    var ok = try parse(testing.allocator, "");
    defer ok.deinit(testing.allocator);
    try testing.expect(!ok.any());
}

test "token hashes that start with characters of the prefix survive a round trip" {
    // Regression: the prefix was once removed with trimStart, which strips a
    // set of characters, so hashes starting with s, h, a, 2, 5, 6 or : lost digits.
    const tail = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde"; // 63 digits
    for ("a256") |c| {
        var text_buf: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf, "token_hash = \"sha256:{c}{s}\"", .{ c, tail });
        var s = try parse(testing.allocator, text);
        defer s.deinit(testing.allocator);
        try testing.expect(s.token_hash != null);
        var want: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&want, text[text.len - 65 .. text.len - 1]);
        try testing.expectEqualSlices(u8, &want, &s.token_hash.?);
    }
}

test "every generated token survives save and load" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..40) |_| {
        var s: Secrets = .{};
        defer s.deinit(testing.allocator);
        s.token_hash = @splat(0);
        var buf: [token_len]u8 = undefined;
        const tok = try s.newToken(testing.io, &buf);
        try save(testing.io, tmp.dir, "a.toml", s);
        var back = try load(testing.allocator, testing.io, tmp.dir, "a.toml");
        defer back.deinit(testing.allocator);
        try testing.expect(back.verifyToken(tok));
    }
}
