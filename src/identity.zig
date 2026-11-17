//! Node identity (docs/decisions/0040): an Ed25519 key pair per node. The public key is the node's id
//! (`dkn_` and 43 characters), the secret seed stays in `data_dir/node-identity.toml` (mode 0600).
//!
//! What it is for, and what it is not for: it lets two configured nodes recognise each other by key instead of by a
//! shared secret alone. A request to a peer carries four headers (`dk-node`, `dk-time`, `dk-nonce`, `dk-sig`); the
//! signature covers the method, the target, the host the request is addressed to, the time and a fresh nonce, so
//! it cannot be replayed to another node, on another path or later. An API key can be *bound* to a node id: it
//! then works only with a valid signature of that node, so a leaked key is useless without the secret. A peer can
//! be *pinned* to a node id: its answers must carry a signature over the request's nonce and its own body, so an
//! impostor at the same address cannot feed results. Nothing here discovers nodes or decides whom to trust:
//! that stays with the operator, who configures peers and keys by hand.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const toml = @import("toml");

pub const id_prefix = "dkn_";
pub const id_len = id_prefix.len + 43;
pub const file_name = "node-identity.toml";
/// How far a request's time may be from ours.
pub const max_skew_seconds: i64 = 300;
const b64 = std.base64.url_safe_no_pad;

pub const Error = error{ Unreadable, Malformed, InsecurePermissions, WriteFailed, OutOfMemory };

pub const Identity = struct {
    kp: Ed25519.KeyPair,

    pub fn generate(io: Io) Identity {
        return .{ .kp = Ed25519.KeyPair.generate(io) };
    }

    pub fn publicKey(self: *const Identity) [32]u8 {
        return self.kp.public_key.toBytes();
    }

    /// `dkn_...`, the node's id.
    pub fn idText(self: *const Identity, out: *[id_len]u8) []const u8 {
        return formatId(self.publicKey(), out);
    }

    pub fn sign(self: *const Identity, msg: []const u8) [64]u8 {
        const sig = self.kp.sign(msg, null) catch unreachable; // only for a key pair that does not match, which `load` rules out
        return sig.toBytes();
    }

    /// Reads the identity from `path` under `dir`; a file others can read is refused.
    pub fn load(arena: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!?Identity {
        const file = dir.openFile(io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return error.Unreadable,
        };
        defer file.close(io);
        const st = file.stat(io) catch return error.Unreadable;
        if (@hasDecl(@TypeOf(st.permissions), "toMode")) {
            if (st.permissions.toMode() & 0o077 != 0) return error.InsecurePermissions;
        }
        if (st.size > 4096) return error.Malformed;
        const buf = try arena.alloc(u8, @intCast(st.size));
        const n = file.readPositionalAll(io, buf, 0) catch return error.Unreadable;
        defer std.crypto.secureZero(u8, buf);
        var doc = toml.Document.parse(arena, buf[0..n], .{ .max_bytes = 4096 }, null) catch return error.Malformed;
        defer doc.deinit();
        const seed_text = doc.root.getString("seed") orelse return error.Malformed;
        if (seed_text.len != 43) return error.Malformed;
        var seed: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        b64.Decoder.decode(&seed, seed_text) catch return error.Malformed;
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return error.Malformed;
        return .{ .kp = kp };
    }

    /// Writes the identity (mode 0600, replacing the file atomically).
    pub fn save(self: *const Identity, arena: Allocator, io: Io, dir: Io.Dir, path: []const u8) Error!void {
        var seed = self.kp.secret_key.seed();
        defer std.crypto.secureZero(u8, &seed);
        var enc: [43]u8 = undefined;
        _ = b64.Encoder.encode(&enc, &seed);
        var id_buf: [id_len]u8 = undefined;
        const text = try std.fmt.allocPrint(arena, "# dksearch node identity. SECRET: whoever has this file can speak as this node. Keep it mode 0600 and out of backups you share.\n# Node id (public): {s}\nseed = \"{s}\"\n", .{ self.idText(&id_buf), enc });
        defer std.crypto.secureZero(u8, @constCast(text));
        var rnd: [4]u8 = undefined;
        io.random(&rnd);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&name_buf, "{s}.{x}.tmp", .{ path, rnd }) catch return error.WriteFailed;
        {
            const f = dir.createFile(io, tmp, .{ .truncate = true, .permissions = Io.File.Permissions.fromMode(0o600) }) catch return error.WriteFailed;
            defer f.close(io);
            f.setPermissions(io, Io.File.Permissions.fromMode(0o600)) catch return error.WriteFailed;
            f.writePositionalAll(io, text, 0) catch return error.WriteFailed;
            f.sync(io) catch return error.WriteFailed;
        }
        dir.rename(tmp, dir, path, io) catch return error.WriteFailed;
    }
};

pub fn formatId(public: [32]u8, out: *[id_len]u8) []const u8 {
    @memcpy(out[0..id_prefix.len], id_prefix);
    _ = b64.Encoder.encode(out[id_prefix.len..], &public);
    return out[0..id_len];
}

/// The public key a `dkn_...` id stands for, or null if it is not well formed.
pub fn parseId(text: []const u8) ?[32]u8 {
    if (text.len != id_len or !std.mem.startsWith(u8, text, id_prefix)) return null;
    var out: [32]u8 = undefined;
    b64.Decoder.decode(&out, text[id_prefix.len..]) catch return null;
    _ = Ed25519.PublicKey.fromBytes(out) catch return null;
    return out;
}

// ------------------------------------------------------------------------------------------ signed requests

/// The four headers of a signed request, as written.
pub const Signed = struct {
    /// The sender's node id.
    node: []const u8,
    /// Unix time in seconds, decimal.
    time: []const u8,
    /// 22 characters of fresh randomness.
    nonce: []const u8,
    /// base64url of the 64-byte signature.
    sig: []const u8,
};

/// What a request signature covers. `host` is the authority the request is addressed to (`host:port`, lower case).
pub fn requestMessage(arena: Allocator, method: []const u8, target: []const u8, host: []const u8, time: []const u8, nonce: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "dksearch-v1 request\n{s}\n{s}\n{s}\n{s}\n{s}", .{ method, target, host, time, nonce });
}

/// What a response signature covers: the nonce of the request it answers, its status and the hash of its body.
pub fn responseMessage(arena: Allocator, nonce: []const u8, status: u16, body: []const u8) Allocator.Error![]const u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(body, &digest, .{});
    return std.fmt.allocPrint(arena, "dksearch-v1 response\n{s}\n{d}\n{x}", .{ nonce, status, &digest });
}

pub const Headers = struct { node: []const u8, time: []const u8, nonce: []const u8, sig: []const u8 };

/// Headers for a request this node sends.
pub fn signRequest(arena: Allocator, io: Io, id: *const Identity, method: []const u8, target: []const u8, host: []const u8) Allocator.Error!Headers {
    var id_buf: [id_len]u8 = undefined;
    const node = try arena.dupe(u8, id.idText(&id_buf));
    const now = Io.Clock.real.now(io).toSeconds();
    const time = try std.fmt.allocPrint(arena, "{d}", .{now});
    var raw: [16]u8 = undefined;
    io.random(&raw);
    const nonce = try arena.alloc(u8, 22);
    _ = b64.Encoder.encode(nonce, &raw);
    const msg = try requestMessage(arena, method, target, host, time, nonce);
    const sig = id.sign(msg);
    const sig_text = try arena.alloc(u8, 86);
    _ = b64.Encoder.encode(sig_text, &sig);
    return .{ .node = node, .time = time, .nonce = nonce, .sig = sig_text };
}

/// Remembers the nonces seen lately, so that a signed request cannot be played twice within the window.
pub const Replay = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    seen: std.StringHashMapUnmanaged(i64) = .empty,

    const max_entries = 100_000;

    pub fn init(gpa: Allocator, io: Io) Replay {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Replay) void {
        var it = self.seen.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.seen.deinit(self.gpa);
    }

    /// True if `nonce` (of a request made at `time`) has not been seen; remembers it. False for a repeat.
    pub fn fresh(self: *Replay, nonce: []const u8, time: i64, now: i64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Forget what is too old to be accepted anyway (cheaply: only when the table has grown).
        if (self.seen.count() > 1024) self.sweep(now);
        if (self.seen.count() >= max_entries) return false; // overload: refuse rather than forget
        const gop = self.seen.getOrPut(self.gpa, nonce) catch return false;
        if (gop.found_existing) return false;
        gop.key_ptr.* = self.gpa.dupe(u8, nonce) catch {
            _ = self.seen.remove(nonce);
            return false;
        };
        gop.value_ptr.* = time;
        return true;
    }

    fn sweep(self: *Replay, now: i64) void {
        var drop: std.ArrayList([]const u8) = .empty;
        defer drop.deinit(self.gpa);
        var it = self.seen.iterator();
        while (it.next()) |e| if (now - e.value_ptr.* > 2 * max_skew_seconds) drop.append(self.gpa, e.key_ptr.*) catch return;
        for (drop.items) |k| if (self.seen.fetchRemove(k)) |kv| self.gpa.free(kv.key);
    }
};

pub const Verdict = enum { ok, malformed, bad_time, bad_signature, replayed };

/// Checks the headers of a request received at `now`: well formed, recent, the signature right for `method`,
/// `target` and `host`, and the nonce not seen before. On `ok` the sender's public key is in `public_out`.
pub fn verifyRequest(arena: Allocator, s: Signed, method: []const u8, target: []const u8, host: []const u8, now: i64, replay: *Replay, public_out: *[32]u8) Verdict {
    const pk = parseId(s.node) orelse return .malformed;
    const time = std.fmt.parseInt(i64, s.time, 10) catch return .malformed;
    if (s.nonce.len != 22 or s.sig.len != 86) return .malformed;
    if (@abs(now - time) > @as(u64, @intCast(max_skew_seconds))) return .bad_time;
    var sig_bytes: [64]u8 = undefined;
    b64.Decoder.decode(&sig_bytes, s.sig) catch return .malformed;
    const msg = requestMessage(arena, method, target, host, s.time, s.nonce) catch return .malformed;
    const public = Ed25519.PublicKey.fromBytes(pk) catch return .malformed;
    Ed25519.Signature.fromBytes(sig_bytes).verifyStrict(msg, public) catch return .bad_signature;
    // Only a request that is genuine is remembered: unsigned noise must not fill the table.
    if (!replay.fresh(s.nonce, time, now)) return .replayed;
    public_out.* = pk;
    return .ok;
}

/// True if `sig` (base64url) is the signature of `node` over the response to the request with `nonce`.
pub fn verifyResponse(arena: Allocator, node: [32]u8, sig_text: []const u8, nonce: []const u8, status: u16, body: []const u8) bool {
    if (sig_text.len != 86) return false;
    var sig_bytes: [64]u8 = undefined;
    b64.Decoder.decode(&sig_bytes, sig_text) catch return false;
    const msg = responseMessage(arena, nonce, status, body) catch return false;
    const public = Ed25519.PublicKey.fromBytes(node) catch return false;
    Ed25519.Signature.fromBytes(sig_bytes).verifyStrict(msg, public) catch return false;
    return true;
}

/// The signature of this node over the response `status` and `body` to a request with `nonce`, as header text.
pub fn signResponse(arena: Allocator, id: *const Identity, nonce: []const u8, status: u16, body: []const u8) Allocator.Error![]const u8 {
    const msg = try responseMessage(arena, nonce, status, body);
    const sig = id.sign(msg);
    const out = try arena.alloc(u8, 86);
    _ = b64.Encoder.encode(out, &sig);
    return out;
}

const testing = std.testing;

test "an id round-trips, and ids that are not keys are refused" {
    const id = Identity.generate(testing.io);
    var buf: [id_len]u8 = undefined;
    const text = id.idText(&buf);
    try testing.expect(std.mem.startsWith(u8, text, "dkn_"));
    try testing.expectEqualSlices(u8, &id.publicKey(), &parseId(text).?);
    try testing.expect(parseId("dkn_short") == null);
    try testing.expect(parseId("xxx_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") == null);
    var bad: [id_len]u8 = undefined;
    @memcpy(&bad, text);
    bad[id_len - 1] = '!';
    try testing.expect(parseId(&bad) == null);
}

test "the identity is kept in a file only its owner can read, and read back as the same key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expect((try Identity.load(a, testing.io, tmp.dir, file_name)) == null);
    const id = Identity.generate(testing.io);
    try id.save(a, testing.io, tmp.dir, file_name);
    const back = (try Identity.load(a, testing.io, tmp.dir, file_name)).?;
    try testing.expectEqualSlices(u8, &id.publicKey(), &back.publicKey());
    const st = try (try tmp.dir.openFile(testing.io, file_name, .{})).stat(testing.io);
    if (@hasDecl(@TypeOf(st.permissions), "toMode")) try testing.expectEqual(@as(u32, 0), st.permissions.toMode() & 0o077);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.toml", .data = "seed = \"short\"\n" });
    if (@hasDecl(@TypeOf(st.permissions), "toMode")) {
        const bf = try tmp.dir.openFile(testing.io, "bad.toml", .{});
        defer bf.close(testing.io);
        try bf.setPermissions(testing.io, Io.File.Permissions.fromMode(0o600));
    }
    try testing.expectError(error.Malformed, Identity.load(a, testing.io, tmp.dir, "bad.toml"));
    if (@hasDecl(@TypeOf(st.permissions), "toMode")) {
        const f = try tmp.dir.openFile(testing.io, file_name, .{});
        defer f.close(testing.io);
        try f.setPermissions(testing.io, Io.File.Permissions.fromMode(0o644));
        try testing.expectError(error.InsecurePermissions, Identity.load(a, testing.io, tmp.dir, file_name));
    }
}

fn asSigned(h: Headers) Signed {
    return .{ .node = h.node, .time = h.time, .nonce = h.nonce, .sig = h.sig };
}

test "a signed request verifies once, for that method, target and host, and not after its time or twice" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const id = Identity.generate(testing.io);
    var replay = Replay.init(testing.allocator, testing.io);
    defer replay.deinit();
    const now = Io.Clock.real.now(testing.io).toSeconds();
    var pk: [32]u8 = undefined;
    const h = try signRequest(a, testing.io, &id, "GET", "/api/v1/search?q=odin", "peer.example.org:8080");
    const s = asSigned(h);
    try testing.expectEqual(Verdict.bad_signature, verifyRequest(a, s, "GET", "/api/v1/search?q=thor", "peer.example.org:8080", now, &replay, &pk)); // other path
    try testing.expectEqual(Verdict.bad_signature, verifyRequest(a, s, "GET", "/api/v1/search?q=odin", "other.example.org", now, &replay, &pk)); // other host
    try testing.expectEqual(Verdict.bad_signature, verifyRequest(a, s, "POST", "/api/v1/search?q=odin", "peer.example.org:8080", now, &replay, &pk));
    try testing.expectEqual(Verdict.ok, verifyRequest(a, s, "GET", "/api/v1/search?q=odin", "peer.example.org:8080", now, &replay, &pk));
    try testing.expectEqualSlices(u8, &id.publicKey(), &pk);
    try testing.expectEqual(Verdict.replayed, verifyRequest(a, s, "GET", "/api/v1/search?q=odin", "peer.example.org:8080", now, &replay, &pk));
    // Too old or from the future.
    const h2 = try signRequest(a, testing.io, &id, "GET", "/x", "h");
    try testing.expectEqual(Verdict.bad_time, verifyRequest(a, asSigned(h2), "GET", "/x", "h", now + 1000, &replay, &pk));
    try testing.expectEqual(Verdict.bad_time, verifyRequest(a, asSigned(h2), "GET", "/x", "h", now - 1000, &replay, &pk));
    // Another node's signature under this node's name does not verify, and nonsense is malformed.
    const other = Identity.generate(testing.io);
    var forged = try signRequest(a, testing.io, &other, "GET", "/y", "h");
    forged.node = h2.node;
    try testing.expectEqual(Verdict.bad_signature, verifyRequest(a, asSigned(forged), "GET", "/y", "h", now, &replay, &pk));
    try testing.expectEqual(Verdict.malformed, verifyRequest(a, .{ .node = "nope", .time = "1", .nonce = "x", .sig = "y" }, "GET", "/", "h", now, &replay, &pk));
}

test "a response is signed over the request's nonce, status and body" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const id = Identity.generate(testing.io);
    const sig = try signResponse(a, &id, "nonce-nonce-nonce-nonce", 200, "{\"hits\":[]}");
    try testing.expect(verifyResponse(a, id.publicKey(), sig, "nonce-nonce-nonce-nonce", 200, "{\"hits\":[]}"));
    try testing.expect(!verifyResponse(a, id.publicKey(), sig, "nonce-nonce-nonce-nonce", 200, "{\"hits\":[1]}")); // altered body
    try testing.expect(!verifyResponse(a, id.publicKey(), sig, "other-nonce-other-nonce", 200, "{\"hits\":[]}")); // another request's answer
    try testing.expect(!verifyResponse(a, id.publicKey(), sig, "nonce-nonce-nonce-nonce", 404, "{\"hits\":[]}"));
    const other = Identity.generate(testing.io);
    try testing.expect(!verifyResponse(a, other.publicKey(), sig, "nonce-nonce-nonce-nonce", 200, "{\"hits\":[]}")); // another node
}
