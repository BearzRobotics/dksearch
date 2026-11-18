//! Safe search and who may turn it off (docs/decisions/0049).
//!
//! `[safe_search] enabled` makes safe search the default for visitors: documents of the domains on the safe-search list
//! are left out. A visitor unlocks it for their browser with a PIN, and a request with an API key marked adult is never
//! filtered. The PIN is stored only as an Argon2 hash in `safesearch-pin.toml` in the data directory (set with
//! `dksearch safesearch-pin`); an unlock is a random token in a cookie, remembered here for `unlock_hours`.
//! The banlist (`[filters]`) is not touched by any of this: it hides domains from everyone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const secrets = @import("secrets.zig");

pub const pin_file_name = "safesearch-pin.toml";
pub const cookie_name = "dks_adult";
pub const max_sessions = 256;
const token_hex_len = 64;
pub const min_pin_len = 4;

const Session = struct { token: [token_hex_len]u8, expires_ns: i96 };

pub const Result = union(enum) { ok: [token_hex_len]u8, wrong, throttled, not_set };

pub const Unlock = struct {
    gpa: Allocator,
    io: Io,
    pin: secrets.Secrets,
    hours: u32,
    mutex: Io.Mutex = .init,
    sessions: [max_sessions]?Session = @splat(null),
    /// Failed PIN attempts in the current window, and when the window ends (monotonic nanoseconds).
    failures: u32 = 0,
    window_end_ns: i96 = 0,

    /// Loads the PIN file from `dir` (a missing file means no PIN: nothing can be unlocked).
    pub fn init(gpa: Allocator, io: Io, dir: Io.Dir, hours: u32) secrets.Error!Unlock {
        const pin = try secrets.load(gpa, io, dir, pin_file_name);
        return .{ .gpa = gpa, .io = io, .pin = pin, .hours = hours };
    }

    pub fn deinit(self: *Unlock) void {
        self.pin.deinit(self.gpa);
    }

    pub fn hasPin(self: *const Unlock) bool {
        return self.pin.password_hash != null;
    }

    fn now(self: *const Unlock) i96 {
        return Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    /// Checks `pin`; on success returns the token to put in the cookie. After five wrong PINs in a minute further
    /// tries are refused (without being checked) until the minute is over.
    pub fn tryUnlock(self: *Unlock, pin: []const u8) Result {
        if (!self.hasPin()) return .not_set;
        const t = self.now();
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (t > self.window_end_ns) {
                self.failures = 0;
                self.window_end_ns = t + 60 * std.time.ns_per_s;
            }
            if (self.failures >= 5) return .throttled;
        }
        const ok = self.pin.verifyPassword(self.gpa, self.io, pin);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!ok) {
            self.failures += 1;
            return .wrong;
        }
        var raw: [32]u8 = undefined;
        self.io.randomSecure(&raw) catch return .wrong;
        var token: [token_hex_len]u8 = undefined;
        _ = std.fmt.bufPrint(&token, "{x}", .{&raw}) catch unreachable;
        std.crypto.secureZero(u8, &raw);
        const expires = t + @as(i96, self.hours) * 3600 * std.time.ns_per_s;
        var slot: usize = 0;
        var oldest: i96 = std.math.maxInt(i96);
        for (self.sessions, 0..) |s, i| {
            if (s == null or s.?.expires_ns < t) {
                slot = i;
                oldest = -1;
                break;
            }
            if (s.?.expires_ns < oldest) {
                oldest = s.?.expires_ns;
                slot = i;
            }
        }
        self.sessions[slot] = .{ .token = token, .expires_ns = expires };
        return .{ .ok = token };
    }

    /// Whether `cookie` (a request's Cookie header) carries a token that is still valid.
    pub fn unlocked(self: *Unlock, cookie: ?[]const u8) bool {
        const token = tokenIn(cookie) orelse return false;
        const t = self.now();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.sessions) |s| if (s) |ss| {
            if (ss.expires_ns >= t and std.crypto.timing_safe.eql([token_hex_len]u8, ss.token, token.*)) return true;
        };
        return false;
    }

    /// Sets a new PIN: stored (as a hash) in the PIN file of `dir`, used from now on, and every browser unlocked with
    /// the old one is locked again.
    pub fn setPin(self: *Unlock, dir: Io.Dir, pin: []const u8) secrets.Error!void {
        var fresh: secrets.Secrets = .{};
        defer fresh.deinit(self.gpa);
        try fresh.setPassword(self.gpa, self.io, pin);
        try secrets.save(self.io, dir, pin_file_name, fresh);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const old = self.pin.password_hash;
        self.pin.password_hash = fresh.password_hash;
        fresh.password_hash = null;
        if (old) |o| self.gpa.free(o);
        self.sessions = @splat(null);
        self.failures = 0;
    }

    /// Removes the PIN: nothing can be unlocked any more.
    pub fn removePin(self: *Unlock, dir: Io.Dir) void {
        dir.deleteFile(self.io, pin_file_name) catch {};
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pin.password_hash) |o| self.gpa.free(o);
        self.pin.password_hash = null;
        self.sessions = @splat(null);
    }

    /// Ends the unlock that `cookie` carries.
    pub fn lock(self: *Unlock, cookie: ?[]const u8) void {
        const token = tokenIn(cookie) orelse return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.sessions) |*s| if (s.*) |ss| {
            if (std.mem.eql(u8, &ss.token, token)) s.* = null;
        };
    }
};

/// The unlock token in a Cookie header, if there is one of the right shape.
pub fn tokenIn(cookie: ?[]const u8) ?*const [token_hex_len]u8 {
    const header = cookie orelse return null;
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len == cookie_name.len + 1 + token_hex_len and std.mem.startsWith(u8, p, cookie_name) and p[cookie_name.len] == '=') {
            return p[cookie_name.len + 1 ..][0..token_hex_len];
        }
    }
    return null;
}

const testing = std.testing;

fn testUnlock(tmp: *testing.TmpDir, pin: ?[]const u8) !Unlock {
    if (pin) |p| {
        var s: secrets.Secrets = .{};
        defer s.deinit(testing.allocator);
        try s.setPassword(testing.allocator, testing.io, p);
        try secrets.save(testing.io, tmp.dir, pin_file_name, s);
    }
    return Unlock.init(testing.allocator, testing.io, tmp.dir, 8);
}

test "a PIN unlocks a browser; a wrong one does not, and too many wrong ones are refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = try testUnlock(&tmp, "4321");
    defer u.deinit();
    try testing.expect(u.hasPin());
    try testing.expect(u.tryUnlock("1111") == .wrong);
    const ok = u.tryUnlock("4321");
    try testing.expect(ok == .ok);
    var cookie_buf: [100]u8 = undefined;
    const cookie = try std.fmt.bufPrint(&cookie_buf, "other=1; {s}={s}", .{ cookie_name, &ok.ok });
    try testing.expect(u.unlocked(cookie));
    try testing.expect(!u.unlocked("dks_adult=0000000000000000000000000000000000000000000000000000000000000000"));
    try testing.expect(!u.unlocked("dks_adult=short"));
    try testing.expect(!u.unlocked(null));
    u.lock(cookie);
    try testing.expect(!u.unlocked(cookie));
    // Four more wrong tries (five in all) and the right PIN is refused too until the minute is over.
    for (0..4) |_| try testing.expect(u.tryUnlock("2222") == .wrong);
    try testing.expect(u.tryUnlock("4321") == .throttled);
}

test "with no PIN set nothing can be unlocked" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = try testUnlock(&tmp, null);
    defer u.deinit();
    try testing.expect(!u.hasPin());
    try testing.expect(u.tryUnlock("1234") == .not_set);
}

test "the PIN can be changed and removed while running; unlocks made with the old one end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var u = try testUnlock(&tmp, "4321");
    defer u.deinit();
    const first = u.tryUnlock("4321");
    var cb: [100]u8 = undefined;
    const cookie = try std.fmt.bufPrint(&cb, "{s}={s}", .{ cookie_name, &first.ok });
    try testing.expect(u.unlocked(cookie));
    try u.setPin(tmp.dir, "9999");
    try testing.expect(!u.unlocked(cookie)); // locked again
    try testing.expect(u.tryUnlock("4321") == .wrong);
    try testing.expect(u.tryUnlock("9999") == .ok);
    // The file holds the new hash: a fresh Unlock reads it.
    var again = try Unlock.init(testing.allocator, testing.io, tmp.dir, 8);
    defer again.deinit();
    try testing.expect(again.tryUnlock("9999") == .ok);
    u.removePin(tmp.dir);
    try testing.expect(!u.hasPin());
    try testing.expect(u.tryUnlock("9999") == .not_set);
    var gone = try Unlock.init(testing.allocator, testing.io, tmp.dir, 8);
    defer gone.deinit();
    try testing.expect(!gone.hasPin());
}
