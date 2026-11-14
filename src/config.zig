//! TOML configuration: loading, validation and defaults.
//!
//! Configuration is static, human-edited input. Operational state (queues,
//! job history, index metadata) does not belong here. Loading either returns
//! a fully validated `Config` or an error with a `Diagnostic`; nothing is
//! applied partially, so a failed reload leaves the caller's current `Config`
//! untouched.

const std = @import("std");
const toml = @import("toml");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The file is not valid TOML (or exceeds parser limits).
    Syntax,
    /// A key is not recognised (usually a misspelling).
    UnknownKey,
    /// A key has the wrong TOML type.
    WrongType,
    /// A value is outside its supported range or set.
    InvalidValue,
    /// The file could not be opened or read, or exceeds `max_file_bytes`.
    Unreadable,
    OutOfMemory,
};

/// Configuration files larger than this are refused before parsing.
pub const max_file_bytes = 1 << 20;

/// Where and why loading failed. Fixed buffers, so it needs no allocation and
/// stays valid after the failed document is freed.
pub const Diagnostic = struct {
    source_buf: [256]u8 = undefined,
    source_len: usize = 0,
    key_buf: [128]u8 = undefined,
    key_len: usize = 0,
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,
    /// 1-based; 0 when unknown (only syntax errors carry a position).
    line: usize = 0,
    column: usize = 0,

    pub fn source(self: *const Diagnostic) []const u8 {
        return self.source_buf[0..self.source_len];
    }
    pub fn key(self: *const Diagnostic) []const u8 {
        return self.key_buf[0..self.key_len];
    }
    pub fn message(self: *const Diagnostic) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    /// `file:line:col: message` for syntax errors, `file: [key] message` otherwise.
    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.source_buf[0..self.source_len]);
        if (self.line != 0) try w.print(":{d}:{d}", .{ self.line, self.column });
        try w.writeAll(": ");
        if (self.key_len != 0) try w.print("{s}: ", .{self.key_buf[0..self.key_len]});
        try w.writeAll(self.message_buf[0..self.message_len]);
    }

    fn set(self: *Diagnostic, src: []const u8, key_path: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.source_len = copyTrunc(&self.source_buf, src);
        self.key_len = copyTrunc(&self.key_buf, key_path);
        const m = std.fmt.bufPrint(&self.message_buf, fmt, args) catch &self.message_buf;
        self.message_len = m.len;
    }
};

fn copyTrunc(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// A network listener. Admin defaults to loopback only (ai/AGENTS.md section 7).
pub const Listener = struct {
    address: []const u8,
    port: u16,
    /// Largest request head accepted, in bytes.
    max_header_bytes: u32 = 8192,
    /// Time allowed to receive a request head; also the keep-alive idle timeout.
    request_timeout_ms: u32 = 10_000,
    /// Time allowed to send a response.
    write_timeout_ms: u32 = 10_000,
    /// Simultaneous connections; extra ones are closed immediately.
    max_connections: u32 = 256,
    max_requests_per_connection: u32 = 100,
    /// On SIGINT/SIGTERM, how long requests already being handled may take
    /// to finish before the process stops.
    shutdown_grace_ms: u32 = 5_000,
};

/// An integer setting of a listener: its key, range, and where it lives.
const ListenerInt = struct {
    key: []const u8,
    min: i64,
    max: i64,
    field: []const u8,
};

const listener_ints = [_]ListenerInt{
    .{ .key = "max_header_bytes", .min = 1024, .max = 65536, .field = "max_header_bytes" },
    .{ .key = "request_timeout_ms", .min = 100, .max = 600_000, .field = "request_timeout_ms" },
    .{ .key = "write_timeout_ms", .min = 100, .max = 600_000, .field = "write_timeout_ms" },
    .{ .key = "max_connections", .min = 1, .max = 65535, .field = "max_connections" },
    .{ .key = "max_requests_per_connection", .min = 1, .max = 10_000, .field = "max_requests_per_connection" },
    .{ .key = "shutdown_grace_ms", .min = 0, .max = 600_000, .field = "shutdown_grace_ms" },
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,

    /// Public search interface and API.
    server: Listener,
    /// Administration interface; separate listener from `server`.
    admin: Listener,
    /// True if the file has an `[admin]` table. Lets the program say that the
    /// administration interface is not served yet only when someone asked.
    admin_configured: bool,
    /// Directory for operational state, retained content and indexes.
    data_dir: []const u8,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const server_keys = [_][]const u8{
    "address",                     "port",
    "max_header_bytes",            "request_timeout_ms",
    "write_timeout_ms",            "max_connections",
    "max_requests_per_connection", "shutdown_grace_ms",
};
const storage_keys = [_][]const u8{"data_dir"};
const top_keys = [_][]const u8{ "server", "admin", "storage" };

/// Parses and validates configuration text. `source_name` is only used in
/// diagnostics (normally the file path).
pub fn loadFromSlice(gpa: Allocator, source_name: []const u8, text: []const u8, diag: *Diagnostic) Error!Config {
    var tdiag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(gpa, text, .{}, &tdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.set(source_name, "", "{s}", .{tdiag.message});
            diag.line = tdiag.line;
            diag.column = tdiag.column;
            return error.Syntax;
        },
    };
    defer doc.deinit();
    return build(gpa, source_name, doc.root, diag);
}

/// Reads and validates the configuration file `path`, relative to `dir`. The
/// path is used verbatim in diagnostics. Nothing is applied on failure.
pub fn loadFile(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, diag: *Diagnostic) Error!Config {
    const text = dir.readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => {
            diag.set(path, "", "file is larger than {d} bytes", .{max_file_bytes});
            return error.Unreadable;
        },
        else => {
            diag.set(path, "", "cannot read file: {t}", .{e});
            return error.Unreadable;
        },
    };
    defer gpa.free(text);
    return loadFromSlice(gpa, path, text, diag);
}

fn build(gpa: Allocator, src: []const u8, root: *toml.Table, diag: *Diagnostic) Error!Config {
    try checkKeys(src, "", root, &top_keys, diag);

    var cfg: Config = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .server = .{ .address = "127.0.0.1", .port = 8080 },
        .admin = .{ .address = "127.0.0.1", .port = 8081 },
        .admin_configured = root.get("admin") != null,
        .data_dir = "data",
    };
    errdefer cfg.arena.deinit();
    const a = cfg.arena.allocator();

    cfg.server = try readListener(a, src, root, "server", cfg.server, diag);
    cfg.admin = try readListener(a, src, root, "admin", cfg.admin, diag);

    if (try subTable(src, root, "storage", diag)) |t| {
        try checkKeys(src, "storage", t, &storage_keys, diag);
        if (try str(src, "storage", t, "data_dir", diag)) |s| {
            if (s.len == 0) {
                diag.set(src, "storage.data_dir", "must not be empty", .{});
                return error.InvalidValue;
            }
            cfg.data_dir = try a.dupe(u8, s);
        }
    }

    if (cfg.server.port == cfg.admin.port and std.mem.eql(u8, cfg.server.address, cfg.admin.address)) {
        diag.set(src, "admin", "admin and server must not share the same address and port", .{});
        return error.InvalidValue;
    }
    return cfg;
}

fn readListener(a: Allocator, src: []const u8, root: *toml.Table, name: []const u8, def: Listener, diag: *Diagnostic) Error!Listener {
    var out = def;
    out.address = try a.dupe(u8, def.address);
    const t = (try subTable(src, root, name, diag)) orelse return out;
    try checkKeys(src, name, t, &server_keys, diag);

    var kbuf: [96]u8 = undefined;
    if (try str(src, name, t, "address", diag)) |s| {
        if (s.len == 0) {
            diag.set(src, std.fmt.bufPrint(&kbuf, "{s}.address", .{name}) catch name, "must not be empty", .{});
            return error.InvalidValue;
        }
        // Literals only: resolving names would make startup depend on DNS.
        _ = std.Io.net.IpAddress.parse(s, 1) catch {
            diag.set(src, std.fmt.bufPrint(&kbuf, "{s}.address", .{name}) catch name, "must be an IPv4 or IPv6 address literal, got \"{s}\"", .{s});
            return error.InvalidValue;
        };
        a.free(out.address);
        out.address = try a.dupe(u8, s);
    }
    if (try intIn(src, name, t, "port", 1, 65535, diag)) |n| out.port = @intCast(n);
    inline for (listener_ints) |li| {
        if (try intIn(src, name, t, li.key, li.min, li.max, diag)) |n| @field(out, li.field) = @intCast(n);
    }
    return out;
}

/// Reads an optional integer key and checks it lies in [min, max].
fn intIn(src: []const u8, section: []const u8, t: *toml.Table, key: []const u8, min: i64, max: i64, diag: *Diagnostic) Error!?i64 {
    const v = t.get(key) orelse return null;
    var kbuf: [96]u8 = undefined;
    const kp = std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ section, key }) catch key;
    switch (v) {
        .integer => |n| {
            if (n < min or n > max) {
                diag.set(src, kp, "must be between {d} and {d}, got {d}", .{ min, max, n });
                return error.InvalidValue;
            }
            return n;
        },
        else => {
            diag.set(src, kp, "expected integer, got {s}", .{v.typeName()});
            return error.WrongType;
        },
    }
}

fn subTable(src: []const u8, t: *toml.Table, name: []const u8, diag: *Diagnostic) Error!?*toml.Table {
    const v = t.get(name) orelse return null;
    return switch (v) {
        .table => |x| x,
        else => {
            diag.set(src, name, "expected table, got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
}

fn str(src: []const u8, section: []const u8, t: *toml.Table, name: []const u8, diag: *Diagnostic) Error!?[]const u8 {
    const v = t.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => {
            var kbuf: [128]u8 = undefined;
            diag.set(src, std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ section, name }) catch name, "expected string, got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
}

/// Rejects keys not in `allowed`, so a misspelled setting is an error instead
/// of being silently ignored.
fn checkKeys(src: []const u8, path: []const u8, t: *toml.Table, allowed: []const []const u8, diag: *Diagnostic) Error!void {
    var it = t.entries.iterator();
    outer: while (it.next()) |e| {
        for (allowed) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue :outer;
        var kbuf: [128]u8 = undefined;
        const full = if (path.len == 0)
            e.key_ptr.*
        else
            std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ path, e.key_ptr.* }) catch e.key_ptr.*;
        diag.set(src, full, "unknown key", .{});
        return error.UnknownKey;
    }
}

const testing = std.testing;

test "empty config yields safe defaults" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer c.deinit();
    try testing.expectEqualStrings("127.0.0.1", c.server.address);
    try testing.expectEqual(@as(u16, 8080), c.server.port);
    try testing.expectEqualStrings("127.0.0.1", c.admin.address);
    try testing.expectEqual(@as(u16, 8081), c.admin.port);
    try testing.expectEqualStrings("data", c.data_dir);
}

test "values override defaults" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml",
        \\[server]
        \\address = "0.0.0.0"
        \\port = 9000
        \\[storage]
        \\data_dir = "/var/lib/dksearch"
    , &d);
    defer c.deinit();
    try testing.expectEqualStrings("0.0.0.0", c.server.address);
    try testing.expectEqual(@as(u16, 9000), c.server.port);
    try testing.expectEqualStrings("/var/lib/dksearch", c.data_dir);
    try testing.expectEqual(@as(u16, 8081), c.admin.port);
}

test "misspelled key is rejected with its path" {
    var d: Diagnostic = .{};
    try testing.expectError(error.UnknownKey, loadFromSlice(testing.allocator, "t.toml",
        \\[server]
        \\adress = "0.0.0.0"
    , &d));
    try testing.expectEqualStrings("server.adress", d.key());
    try testing.expectEqualStrings("t.toml", d.source());
}

test "unknown top-level key is rejected" {
    var d: Diagnostic = .{};
    try testing.expectError(error.UnknownKey, loadFromSlice(testing.allocator, "t.toml", "serverr = 1", &d));
    try testing.expectEqualStrings("serverr", d.key());
}

test "wrong type and out-of-range port" {
    var d: Diagnostic = .{};
    try testing.expectError(error.WrongType, loadFromSlice(testing.allocator, "t.toml", "[server]\nport = \"80\"", &d));
    try testing.expectEqualStrings("server.port", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\nport = 70000", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\nport = 0", &d));
    try testing.expectError(error.WrongType, loadFromSlice(testing.allocator, "t.toml", "server = 3", &d));
}

test "syntax error carries position" {
    var d: Diagnostic = .{};
    try testing.expectError(error.Syntax, loadFromSlice(testing.allocator, "t.toml", "a = \n", &d));
    try testing.expect(d.line >= 1);
}

test "admin must not collide with server" {
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[admin]\nport = 8080", &d));
}

test "empty data_dir rejected" {
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[storage]\ndata_dir = \"\"", &d));
}

test "diagnostic formatting" {
    var d: Diagnostic = .{};
    _ = loadFromSlice(testing.allocator, "t.toml", "[server]\nbogus = 1", &d) catch {};
    var buf: [256]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{d});
    try testing.expectEqualStrings("t.toml: server.bogus: unknown key", s);
}

test "loadFile reads a file and reports its path in diagnostics" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ok.toml", .data = "[server]\nport = 9100\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.toml", .data = "[server]\nprot = 1\n" });

    var d: Diagnostic = .{};
    var c = try loadFile(testing.allocator, testing.io, tmp.dir, "ok.toml", &d);
    defer c.deinit();
    try testing.expectEqual(@as(u16, 9100), c.server.port);

    try testing.expectError(error.UnknownKey, loadFile(testing.allocator, testing.io, tmp.dir, "bad.toml", &d));
    try testing.expectEqualStrings("bad.toml", d.source());
    try testing.expectEqualStrings("server.prot", d.key());
}

test "loadFile: missing and oversized files are Unreadable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var d: Diagnostic = .{};
    try testing.expectError(error.Unreadable, loadFile(testing.allocator, testing.io, tmp.dir, "nope.toml", &d));
    try testing.expectEqualStrings("nope.toml", d.source());

    const big = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, '#');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.toml", .data = big });
    try testing.expectError(error.Unreadable, loadFile(testing.allocator, testing.io, tmp.dir, "big.toml", &d));
}

test "listener limits have safe defaults and can be overridden" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    try testing.expectEqual(@as(u32, 8192), c.server.max_header_bytes);
    try testing.expectEqual(@as(u32, 10_000), c.server.request_timeout_ms);
    try testing.expectEqual(@as(u32, 256), c.server.max_connections);
    c.deinit();

    var c2 = try loadFromSlice(testing.allocator, "t.toml",
        \\[server]
        \\max_connections = 8
        \\request_timeout_ms = 2500
        \\max_header_bytes = 4096
        \\write_timeout_ms = 3000
        \\max_requests_per_connection = 5
        \\[admin]
        \\max_connections = 2
    , &d);
    defer c2.deinit();
    try testing.expectEqual(@as(u32, 8), c2.server.max_connections);
    try testing.expectEqual(@as(u32, 2500), c2.server.request_timeout_ms);
    try testing.expectEqual(@as(u32, 4096), c2.server.max_header_bytes);
    try testing.expectEqual(@as(u32, 3000), c2.server.write_timeout_ms);
    try testing.expectEqual(@as(u32, 5), c2.server.max_requests_per_connection);
    try testing.expectEqual(@as(u32, 5_000), c2.server.shutdown_grace_ms);
    try testing.expectEqual(@as(u32, 2), c2.admin.max_connections);
    try testing.expectEqual(@as(u32, 8192), c2.admin.max_header_bytes); // untouched keys keep defaults
}

test "listener limits are range-checked with the key in the message" {
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\nmax_connections = 0", &d));
    try testing.expectEqualStrings("server.max_connections", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\nmax_header_bytes = 10", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[admin]\nrequest_timeout_ms = 99999999", &d));
    try testing.expectError(error.WrongType, loadFromSlice(testing.allocator, "t.toml", "[server]\nmax_connections = \"many\"", &d));
    try testing.expectError(error.UnknownKey, loadFromSlice(testing.allocator, "t.toml", "[server]\nmax_connection = 5", &d));
}

test "listener address must be an IP literal" {
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\naddress = \"localhost\"", &d));
    try testing.expectEqualStrings("server.address", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[admin]\naddress = \"999.1.1.1\"", &d));
    var c = try loadFromSlice(testing.allocator, "t.toml", "[server]\naddress = \"::1\"\n[admin]\naddress = \"127.0.0.2\"", &d);
    defer c.deinit();
    try testing.expectEqualStrings("::1", c.server.address);
}

test "admin_configured reflects the presence of an [admin] table" {
    var d: Diagnostic = .{};
    var a = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer a.deinit();
    try testing.expect(!a.admin_configured);
    var b = try loadFromSlice(testing.allocator, "t.toml", "[admin]\nport = 9001", &d);
    defer b.deinit();
    try testing.expect(b.admin_configured);
}
