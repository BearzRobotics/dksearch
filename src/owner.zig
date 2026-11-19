//! The owner's sign-in (docs/decisions/0054): one password, set in the administration interface or with
//! `dksearch owner-password`, stored only as an Argon2 hash in `owner-login.toml` in the data directory. A browser that
//! signs in at /login gets the complete view (every source, safe search lifted), like an API key made with `--all --adult`.
//!
//! The sign-in is a cookie that carries an expiry and an HMAC of it, keyed by the stored hash. Nothing is remembered on the
//! server: a restart does not sign anyone out, and changing or removing the password signs every browser out at once. A
//! cookie cannot be revoked before it expires except by changing the password. Wrong passwords are throttled (five a minute).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const secrets = @import("secrets.zig");
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const file_name = "owner-login.toml";
pub const cookie_name = "dks_owner";
pub const min_password_len = 8;
pub const max_password_len = 128;

pub const Result = union(enum) {
    /// The cookie's value and how long it lasts (seconds).
    ok: struct { value: [value_len]u8, max_age: u32 },
    wrong,
    throttled,
    not_set,
};

/// `<expiry as 10 decimal digits>.<64 hex digits of the HMAC>`.
const value_len = 10 + 1 + 64;

pub const OwnerLogin = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    secret: secrets.Secrets,
    days: u32,
    mutex: Io.Mutex = .init,
    failures: u32 = 0,
    window_end_ns: i96 = 0,
    checked_ns: i96 = 0,

    /// Loads the password file from `dir` (a missing file means there is no owner sign-in).
    pub fn init(gpa: Allocator, io: Io, dir: Io.Dir, days: u32) secrets.Error!OwnerLogin {
        const secret = try secrets.load(gpa, io, dir, file_name);
        return .{ .gpa = gpa, .io = io, .dir = dir, .secret = secret, .days = days, .checked_ns = Io.Timestamp.now(io, .awake).nanoseconds };
    }

    pub fn deinit(self: *OwnerLogin) void {
        self.secret.deinit(self.gpa);
    }

    fn mono(self: *const OwnerLogin) i96 {
        return Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    fn wall(self: *const OwnerLogin) i64 {
        return Io.Clock.real.now(self.io).toSeconds();
    }

    /// Re-reads the file at most every two seconds, so a password set by the command while the server runs is picked up.
    fn refresh(self: *OwnerLogin) void {
        const t = self.mono();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (t - self.checked_ns < 2 * std.time.ns_per_s) return;
        self.checked_ns = t;
        var fresh = secrets.load(self.gpa, self.io, self.dir, file_name) catch return;
        const same = if (fresh.password_hash) |f|
            (if (self.secret.password_hash) |o| std.mem.eql(u8, f, o) else false)
        else
            self.secret.password_hash == null;
        if (same) {
            fresh.deinit(self.gpa);
            return;
        }
        self.secret.deinit(self.gpa);
        self.secret = fresh;
        self.failures = 0;
    }

    pub fn hasPassword(self: *OwnerLogin) bool {
        self.refresh();
        return self.secret.password_hash != null;
    }

    fn sign(hash: []const u8, expiry: i64, out: *[value_len]u8) void {
        var key: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(hash, &key, .{});
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "owner:{d}", .{expiry}) catch unreachable;
        var mac: [32]u8 = undefined;
        Hmac.create(&mac, msg, &key);
        _ = std.fmt.bufPrint(out, "{d:0>10}.{x}", .{ @as(u64, @intCast(expiry)), &mac }) catch unreachable;
    }

    /// Checks `password`; on success returns the cookie's value. After five wrong passwords in a minute further tries are
    /// refused (without being checked) until the minute is over.
    pub fn tryLogin(self: *OwnerLogin, password: []const u8) Result {
        if (!self.hasPassword()) return .not_set;
        const t = self.mono();
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (t > self.window_end_ns) {
                self.failures = 0;
                self.window_end_ns = t + 60 * std.time.ns_per_s;
            }
            if (self.failures >= 5) return .throttled;
        }
        const ok = self.secret.verifyPassword(self.gpa, self.io, password);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!ok) {
            self.failures += 1;
            return .wrong;
        }
        const max_age: u32 = self.days * 86400;
        const expiry = self.wall() + max_age;
        var v: [value_len]u8 = undefined;
        sign(self.secret.password_hash.?, expiry, &v);
        return .{ .ok = .{ .value = v, .max_age = max_age } };
    }

    /// Whether the Cookie header carries a sign-in that is still valid for the password in force.
    pub fn valid(self: *OwnerLogin, cookie: ?[]const u8) bool {
        const header = cookie orelse return false;
        if (!self.hasPassword()) return false;
        var value: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, header, ';');
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len == cookie_name.len + 1 + value_len and std.mem.startsWith(u8, p, cookie_name) and p[cookie_name.len] == '=') value = p[cookie_name.len + 1 ..];
        }
        const v = value orelse return false;
        const expiry = std.fmt.parseInt(i64, v[0..10], 10) catch return false;
        if (expiry < self.wall()) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const hash = self.secret.password_hash orelse return false;
        var want: [value_len]u8 = undefined;
        sign(hash, expiry, &want);
        return std.crypto.timing_safe.eql([value_len]u8, want, v[0..value_len].*);
    }

    /// Sets the password: stored (as a hash) in the file, used from now on; every browser signed in with the old one is
    /// signed out (its cookie no longer matches).
    pub fn setPassword(self: *OwnerLogin, password: []const u8) secrets.Error!void {
        var fresh: secrets.Secrets = .{};
        defer fresh.deinit(self.gpa);
        try fresh.setPassword(self.gpa, self.io, password);
        try secrets.save(self.io, self.dir, file_name, fresh);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const old = self.secret.password_hash;
        self.secret.password_hash = fresh.password_hash;
        fresh.password_hash = null;
        if (old) |o| self.gpa.free(o);
        self.failures = 0;
    }

    /// Removes the password: nobody can sign in, and every cookie stops working.
    pub fn removePassword(self: *OwnerLogin) void {
        self.dir.deleteFile(self.io, file_name) catch {};
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.secret.password_hash) |o| self.gpa.free(o);
        self.secret.password_hash = null;
    }
};

const testing = std.testing;

fn cookieOf(buf: []u8, v: [value_len]u8) []const u8 {
    return std.fmt.bufPrint(buf, "a=b; {s}={s}", .{ cookie_name, &v }) catch unreachable;
}

test "a password signs a browser in; a wrong one does not and too many are refused; the cookie follows the password" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var o = try OwnerLogin.init(testing.allocator, testing.io, tmp.dir, 30);
    defer o.deinit();
    try testing.expect(!o.hasPassword());
    try testing.expect(o.tryLogin("whatever1") == .not_set);
    try o.setPassword("correct horse");
    try testing.expect(o.hasPassword());
    var buf: [200]u8 = undefined;
    const good = o.tryLogin("correct horse");
    try testing.expect(good == .ok);
    try testing.expectEqual(@as(u32, 30 * 86400), good.ok.max_age);
    const cookie = cookieOf(&buf, good.ok.value);
    try testing.expect(o.valid(cookie));
    try testing.expect(!o.valid(null) and !o.valid("a=b") and !o.valid("dks_owner=short"));
    // A tampered cookie, an expired one and one for another password do not work.
    var bad = good.ok.value;
    bad[bad.len - 1] = if (bad[bad.len - 1] == '0') '1' else '0';
    var buf2: [200]u8 = undefined;
    try testing.expect(!o.valid(cookieOf(&buf2, bad)));
    var expired: [value_len]u8 = undefined;
    OwnerLogin.sign("some hash", 1000, &expired);
    try testing.expect(!o.valid(cookieOf(&buf2, expired)));
    try o.setPassword("another password");
    try testing.expect(!o.valid(cookie)); // the old password's cookie is dead
    try testing.expect(o.tryLogin("correct horse") == .wrong);
    // Five wrong tries in a minute and the sixth is refused even with the right password.
    var i: u32 = 0;
    while (i < 4) : (i += 1) try testing.expect(o.tryLogin("nope nope") == .wrong);
    try testing.expect(o.tryLogin("another password") == .throttled);
    // Removing the password ends everything.
    o.removePassword();
    try testing.expect(!o.hasPassword() and o.tryLogin("another password") == .not_set);
}

test "a password set by another process while the server runs is picked up, and sessions survive a restart" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var o = try OwnerLogin.init(testing.allocator, testing.io, tmp.dir, 7);
    defer o.deinit();
    try testing.expect(!o.hasPassword());
    var other: secrets.Secrets = .{};
    defer other.deinit(testing.allocator);
    try other.setPassword(testing.allocator, testing.io, "set by the command");
    try secrets.save(testing.io, tmp.dir, file_name, other);
    o.checked_ns = 0;
    try testing.expect(o.hasPassword());
    const got = o.tryLogin("set by the command");
    try testing.expect(got == .ok);
    var buf: [200]u8 = undefined;
    const cookie = cookieOf(&buf, got.ok.value);
    // A new process reading the same file accepts the same cookie.
    var again = try OwnerLogin.init(testing.allocator, testing.io, tmp.dir, 7);
    defer again.deinit();
    try testing.expect(again.valid(cookie));
}
