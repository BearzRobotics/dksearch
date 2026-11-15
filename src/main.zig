//! dksearch command-line entry point. See docs/manpages/dksearch.1.md.
//!
//! Thin by design: parse arguments, load configuration, wire the core to the
//! HTTP adapter and the optional connectors, and run. No search or ingestion
//! logic lives here.

const std = @import("std");
const Io = std.Io;
const dk = @import("dksearch");
const dkhttp = @import("dksearch_http");
const build_options = @import("build_options");

/// Stop request shared with the signal handler. A handler has no context
/// argument, so these have to be globals; setting them is async-signal-safe.
var stop_control: dkhttp.server.Control = .{};
var import_control: dk.connector.Control = .{};
/// Used by `now`, which the pipeline calls without an `Io`.
var clock_io: Io = undefined;

fn onServeSignal(_: std.posix.SIG) callconv(.c) void {
    stop_control.requestStop();
}

fn onImportSignal(_: std.posix.SIG) callconv(.c) void {
    import_control.cancel();
}

fn installSignalHandlers(handler: std.posix.Sigaction.handler_fn) void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn now() dk.document.Timestamp {
    return @intCast(@divFloor(Io.Clock.real.now(clock_io).nanoseconds, std.time.ns_per_s));
}

const exit_ok = 0;
const exit_failure = 1;
const exit_usage = 2;
const exit_config = 3;
const exit_io = 4;

const usage =
    \\usage: dksearch [-h | --help] [-V | --version]
    \\       dksearch serve [--config FILE]
    \\       dksearch import --config FILE (SOURCE | --all)
    \\       dksearch import --config FILE (SOURCE | --all) [--prune]
    \\       dksearch remove --config FILE SOURCE [--yes]
    \\       dksearch rebuild [--config FILE]
    \\       dksearch check [--config FILE]
    \\       dksearch admin-token [--config FILE]
    \\       dksearch admin-password [--config FILE]
    \\       dksearch backup [--config FILE] DIR
    \\       dksearch check-config FILE
    \\
;

fn out(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch {};
}

fn err(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print("dksearch: " ++ fmt ++ "\n", args) catch return;
    w.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    clock_io = init.io;
    const code = run(init);
    std.process.exit(code);
}

fn run(init: std.process.Init) u8 {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next(); // program name
    const first = args.next() orelse {
        Io.File.stderr().writeStreamingAll(io, usage) catch {};
        return exit_usage;
    };

    if (eq(first, "-h") or eq(first, "--help")) {
        out(io, "{s}", .{usage});
        return exit_ok;
    }
    if (eq(first, "-V") or eq(first, "--version")) {
        out(io, "dksearch {s}\n", .{build_options.version});
        return exit_ok;
    }

    if (eq(first, "check-config")) {
        const path = args.next() orelse return usageError(io, "check-config needs a FILE");
        if (args.next() != null) return usageError(io, "check-config takes exactly one FILE");
        var diag: dk.config.Diagnostic = .{};
        var cfg = loadAndValidate(gpa, io, path, &diag) catch |e| return configFailure(io, e, &diag);
        const n = cfg.sources.len;
        cfg.deinit();
        out(io, "{s}: ok ({d} source{s})\n", .{ path, n, if (n == 1) "" else "s" });
        return exit_ok;
    }

    if (eq(first, "admin-token") or eq(first, "admin-password")) {
        var config_path: ?[]const u8 = null;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else {
                err(io, "unknown option for {s}: {s}", .{ first, a });
                return exit_usage;
            }
        }
        return adminCredentialCmd(io, gpa, config_path, eq(first, "admin-token"));
    }

    if (eq(first, "check") or eq(first, "backup")) {
        var config_path: ?[]const u8 = null;
        var dir: ?[]const u8 = null;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else if (std.mem.startsWith(u8, a, "-")) {
                err(io, "unknown option for {s}: {s}", .{ first, a });
                return exit_usage;
            } else if (eq(first, "backup") and dir == null) {
                dir = a;
            } else {
                return usageError(io, "too many arguments");
            }
        }
        if (eq(first, "check")) return checkCmd(io, gpa, config_path);
        return backupCmd(io, gpa, config_path, dir orelse return usageError(io, "backup needs a destination DIR"));
    }

    if (eq(first, "serve") or eq(first, "rebuild")) {
        var config_path: ?[]const u8 = null;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else {
                err(io, "unknown option for {s}: {s}", .{ first, a });
                return exit_usage;
            }
        }
        return if (eq(first, "serve")) serve(io, gpa, config_path) else rebuildCmd(io, gpa, config_path);
    }

    if (eq(first, "remove")) {
        var config_path: ?[]const u8 = null;
        var source: ?[]const u8 = null;
        var yes = false;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else if (eq(a, "--yes")) {
                yes = true;
            } else if (std.mem.startsWith(u8, a, "-")) {
                err(io, "unknown option for remove: {s}", .{a});
                return exit_usage;
            } else if (source == null) {
                source = a;
            } else {
                return usageError(io, "remove takes one SOURCE");
            }
        }
        if (config_path == null) return usageError(io, "remove needs --config FILE (it names the data directory)");
        return removeCmd(io, gpa, config_path.?, source orelse return usageError(io, "remove needs a SOURCE name"), yes);
    }

    if (eq(first, "import")) {
        var config_path: ?[]const u8 = null;
        var source: ?[]const u8 = null;
        var all = false;
        var prune = false;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else if (eq(a, "--all")) {
                all = true;
            } else if (eq(a, "--prune")) {
                prune = true;
            } else if (std.mem.startsWith(u8, a, "-")) {
                err(io, "unknown option for import: {s}", .{a});
                return exit_usage;
            } else if (source == null) {
                source = a;
            } else {
                return usageError(io, "import takes one SOURCE, or --all");
            }
        }
        if (config_path == null) return usageError(io, "import needs --config FILE (sources are defined there)");
        if (all == (source != null)) return usageError(io, "import needs exactly one of SOURCE or --all");
        return importCmd(io, gpa, config_path.?, source, all, prune);
    }

    err(io, "unknown command: {s}", .{first});
    Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return exit_usage;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usageError(io: Io, msg: []const u8) u8 {
    err(io, "{s}", .{msg});
    Io.File.stderr().writeStreamingAll(io, usage) catch {};
    return exit_usage;
}

fn configFailure(io: Io, e: dk.config.Error, diag: *const dk.config.Diagnostic) u8 {
    return switch (e) {
        error.OutOfMemory => blk: {
            err(io, "out of memory", .{});
            break :blk exit_io;
        },
        error.Unreadable => blk: {
            err(io, "{f}", .{diag.*});
            break :blk exit_io;
        },
        else => blk: {
            err(io, "{f}", .{diag.*});
            break :blk exit_config;
        },
    };
}

/// Loads the file and validates everything that can be checked without
/// touching the outside world, including every source's connector options.
fn loadAndValidate(gpa: std.mem.Allocator, io: Io, path: []const u8, diag: *dk.config.Diagnostic) dk.config.Error!dk.config.Config {
    var cfg = try dk.config.loadFile(gpa, io, Io.Dir.cwd(), path, diag);
    errdefer cfg.deinit();
    dk.connectors.validateAll(cfg.sources, diag) catch |e| {
        diag.setSource(path);
        return e;
    };
    return cfg;
}

fn loadForRun(gpa: std.mem.Allocator, io: Io, config_path: ?[]const u8, diag: *dk.config.Diagnostic) dk.config.Error!dk.config.Config {
    if (config_path) |p| return loadAndValidate(gpa, io, p, diag);
    return dk.config.loadFromSlice(gpa, "(built-in defaults)", "", diag);
}

/// The three databases under `data_dir`.
const Paths = struct {
    index: [:0]const u8,
    state: [:0]const u8,
    content: [:0]const u8,

    fn make(arena: std.mem.Allocator, data_dir: []const u8) !Paths {
        return .{
            .index = try std.fmt.allocPrintSentinel(arena, "{s}/index.db", .{data_dir}, 0),
            .state = try std.fmt.allocPrintSentinel(arena, "{s}/state.db", .{data_dir}, 0),
            .content = try std.fmt.allocPrintSentinel(arena, "{s}/content.db", .{data_dir}, 0),
        };
    }
};

fn prepareDataDir(io: Io, data_dir: []const u8) bool {
    Io.Dir.cwd().createDirPath(io, data_dir) catch |e| {
        err(io, "cannot create data_dir {s}: {t}", .{ data_dir, e });
        return false;
    };
    return true;
}

fn openIndex(io: Io, path: [:0]const u8) ?dk.index_sqlite.SqliteIndex {
    return dk.index_sqlite.SqliteIndex.open(path, .{}) catch |e| {
        switch (e) {
            error.SchemaMismatch => err(io, "{s} was written by an incompatible version; delete it and run `dksearch rebuild`", .{path}),
            else => err(io, "cannot open index {s}: {t}", .{ path, e }),
        }
        return null;
    };
}

fn openState(io: Io, gpa: std.mem.Allocator, path: [:0]const u8) ?dk.state_sqlite.SqliteStateStore {
    return dk.state_sqlite.SqliteStateStore.open(gpa, path, false) catch |e| {
        switch (e) {
            error.NewerSchema => err(io, "{s} was written by a newer version of dksearch; refusing to open it", .{path}),
            error.MigrationFailed => err(io, "upgrading {s} failed and was rolled back; a backup of the old file is next to it", .{path}),
            else => err(io, "cannot open {s}: {t}", .{ path, e }),
        }
        return null;
    };
}

fn openContent(io: Io, gpa: std.mem.Allocator, path: [:0]const u8) ?dk.content_sqlite.SqliteContentStore {
    return dk.content_sqlite.SqliteContentStore.open(gpa, path, false) catch |e| {
        switch (e) {
            error.NewerSchema => err(io, "{s} was written by a newer version of dksearch; refusing to open it", .{path}),
            error.MigrationFailed => err(io, "upgrading {s} failed and was rolled back; a backup of the old file is next to it", .{path}),
            else => err(io, "cannot open {s}: {t}", .{ path, e }),
        }
        return null;
    };
}

/// Where the admin credential hashes live.
fn secretsPath(arena: std.mem.Allocator, cfg: dk.config.Config) ![]const u8 {
    return cfg.admin_options.secrets_file orelse try std.fmt.allocPrint(arena, "{s}/admin-secrets.toml", .{cfg.data_dir});
}

fn secretsProblem(io: Io, path: []const u8, e: dk.secrets.Error) void {
    switch (e) {
        error.InsecurePermissions => err(io, "{s} can be read by other users; run `chmod 600 {s}` (or create new credentials, which rewrites it safely)", .{ path, path }),
        error.Malformed => err(io, "{s} is not a valid credentials file; fix or delete it and create credentials again", .{path}),
        error.OutOfMemory => err(io, "out of memory", .{}),
        else => err(io, "cannot read {s}: {t}", .{ path, e }),
    }
}

/// Reads a password. On a terminal it is read without echo and asked twice;
/// otherwise one line is read from standard input. Never from an argument.
fn readPassword(io: Io, gpa: std.mem.Allocator) ?[]u8 {
    const stdin = Io.File.stdin();
    const tty = stdin.isTty(io) catch false;
    var restore: ?std.posix.termios = null;
    if (tty) {
        if (std.posix.tcgetattr(stdin.handle)) |orig| {
            var raw = orig;
            raw.lflag.ECHO = false;
            std.posix.tcsetattr(stdin.handle, .FLUSH, raw) catch {};
            restore = orig;
        } else |_| {}
    }
    defer if (restore) |orig| std.posix.tcsetattr(stdin.handle, .FLUSH, orig) catch {};

    const first = readLine(io, gpa, if (tty) "New password: " else null) orelse return null;
    if (tty) {
        const second = readLine(io, gpa, "Repeat password: ") orelse {
            std.crypto.secureZero(u8, first);
            gpa.free(first);
            return null;
        };
        defer {
            std.crypto.secureZero(u8, second);
            gpa.free(second);
        }
        if (!std.mem.eql(u8, first, second)) {
            std.crypto.secureZero(u8, first);
            gpa.free(first);
            err(io, "the passwords do not match; nothing was changed", .{});
            return null;
        }
    }
    return first;
}

fn readLine(io: Io, gpa: std.mem.Allocator, prompt: ?[]const u8) ?[]u8 {
    if (prompt) |p| {
        Io.File.stderr().writeStreamingAll(io, p) catch {};
    }
    var line: std.ArrayList(u8) = .empty;
    var byte: [1]u8 = undefined;
    while (line.items.len <= dk.secrets.max_password_bytes) {
        var bufs = [_][]u8{&byte};
        const n = Io.File.stdin().readStreaming(io, &bufs) catch break;
        if (n == 0) break;
        if (byte[0] == '\n') break;
        line.append(gpa, byte[0]) catch return null;
    }
    if (prompt != null) Io.File.stderr().writeStreamingAll(io, "\n") catch {};
    if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') _ = line.pop();
    return line.toOwnedSlice(gpa) catch null;
}

fn adminCredentialCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8, want_token: bool) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const path = secretsPath(arena_state.allocator(), cfg) catch return exit_io;
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;

    var s = dk.secrets.load(gpa, io, Io.Dir.cwd(), path) catch |e| {
        secretsProblem(io, path, e);
        return exit_io;
    };
    defer s.deinit(gpa);

    if (want_token) {
        var buf: [dk.secrets.token_len]u8 = undefined;
        s.token_hash = @splat(0);
        const token = s.newToken(io, &buf) catch |e| {
            err(io, "cannot create a token: {t}", .{e});
            return exit_io;
        };
        dk.secrets.save(io, Io.Dir.cwd(), path, s) catch |e| {
            err(io, "cannot write {s}: {t}", .{ path, e });
            return exit_io;
        };
        out(io, "{s}\n", .{token});
        err(io, "new admin token written (as a hash) to {s}. This is the only time it is shown; any earlier token no longer works. Send it as: Authorization: Bearer TOKEN", .{path});
    } else {
        const password = readPassword(io, gpa) orelse {
            err(io, "no password was read; nothing was changed", .{});
            return exit_usage;
        };
        defer {
            std.crypto.secureZero(u8, password);
            gpa.free(password);
        }
        s.setPassword(gpa, io, password) catch |e| {
            err(io, "cannot set the password: {t} (it must be 1 to {d} bytes)", .{ e, dk.secrets.max_password_bytes });
            return exit_usage;
        };
        dk.secrets.save(io, Io.Dir.cwd(), path, s) catch |e| {
            err(io, "cannot write {s}: {t}", .{ path, e });
            return exit_io;
        };
        err(io, "admin password hash written to {s}; existing sessions are signed out", .{path});
    }
    return exit_ok;
}

fn adminServeTask(
    gpa: std.mem.Allocator,
    io: Io,
    listener: *Io.net.Server,
    app: *dkhttp.admin.App,
    access_log: ?*dkhttp.server.AccessLog,
    limits: dkhttp.server.Limits,
    stats: *dkhttp.server.Stats,
) Io.Cancelable!void {
    dkhttp.server.serveWith(gpa, io, listener, app.dispatcher(), access_log, limits, stats, &stop_control) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => err(io, "admin server stopped: {t}", .{e}),
    };
}

fn serve(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();

    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const paths = Paths.make(arena_state.allocator(), cfg.data_dir) catch {
        err(io, "out of memory", .{});
        return exit_io;
    };
    var index = openIndex(io, paths.index) orelse return exit_io;
    defer index.close();

    // Validated as a literal at load time, so this cannot fail.
    const address = Io.net.IpAddress.parse(cfg.server.address, cfg.server.port) catch unreachable;
    var listener = dkhttp.server.listen(io, address) catch |e| {
        err(io, "cannot listen on {s}:{d}: {t}", .{ cfg.server.address, cfg.server.port, e });
        return exit_io;
    };
    defer listener.deinit(io);

    err(io, "serving search on http://{f}/ (index: {s})", .{ listener.socket.address, paths.index });

    const limits: dkhttp.server.Limits = .{
        .max_header_bytes = cfg.server.max_header_bytes,
        .request_head_timeout_ms = cfg.server.request_timeout_ms,
        .write_timeout_ms = cfg.server.write_timeout_ms,
        .max_connections = cfg.server.max_connections,
        .max_requests_per_connection = cfg.server.max_requests_per_connection,
        .shutdown_grace_ms = cfg.server.shutdown_grace_ms,
    };
    var stats: dkhttp.server.Stats = .{};
    var admin_stats: dkhttp.server.Stats = .{};

    var public_log: ?dkhttp.server.AccessLog = null;
    defer if (public_log) |*l| l.close();
    if (cfg.server.access_log) |dest| {
        public_log = dkhttp.server.AccessLog.open(io, dest) catch |e| {
            err(io, "cannot open the access log {s}: {t}", .{ dest, e });
            return exit_io;
        };
    }

    // The administration interface: only with credentials (docs/decisions/0012).
    var admin_listener: ?Io.net.Server = null;
    defer if (admin_listener) |*l| l.deinit(io);
    var admin_log: ?dkhttp.server.AccessLog = null;
    defer if (admin_log) |*l| l.close();
    var admin_app: dkhttp.admin.App = undefined;
    var group: Io.Group = .init;
    defer group.cancel(io);
    if (cfg.admin_configured) admin: {
        const spath = secretsPath(arena_state.allocator(), cfg) catch return exit_io;
        var creds = dk.secrets.load(gpa, io, Io.Dir.cwd(), spath) catch |e| {
            secretsProblem(io, spath, e);
            err(io, "the administration interface was not started", .{});
            break :admin;
        };
        defer creds.deinit(gpa);
        if (!creds.any()) {
            err(io, "the administration interface was not started: {s} has no credentials. Create one with `dksearch admin-token` or `dksearch admin-password`", .{spath});
            break :admin;
        }
        const a_address = Io.net.IpAddress.parse(cfg.admin.address, cfg.admin.port) catch unreachable;
        admin_listener = dkhttp.server.listen(io, a_address) catch |e| {
            err(io, "cannot listen for administration on {s}:{d}: {t}; the administration interface was not started", .{ cfg.admin.address, cfg.admin.port, e });
            break :admin;
        };
        if (cfg.admin.access_log) |dest| {
            admin_log = dkhttp.server.AccessLog.open(io, dest) catch |e| {
                err(io, "cannot open the admin access log {s}: {t}; the administration interface was not started", .{ dest, e });
                admin_listener.?.deinit(io);
                admin_listener = null;
                break :admin;
            };
        }
        admin_app = dkhttp.admin.App.init(gpa, io, .{
            .index_path = paths.index,
            .state_path = paths.state,
            .content_path = paths.content,
            .secrets_path = spath,
            .sources = cfg.sources,
            .version = build_options.version,
            .session_idle_ms = @as(u64, cfg.admin_options.session_idle_minutes) * 60 * 1000,
            .session_max_ms = @as(u64, cfg.admin_options.session_max_hours) * 60 * 60 * 1000,
            .cookie_secure = cfg.admin_options.cookie_secure,
            .public_stats = &stats,
            .admin_stats = &admin_stats,
        });
        const admin_limits: dkhttp.server.Limits = .{
            .max_header_bytes = cfg.admin.max_header_bytes,
            .request_head_timeout_ms = cfg.admin.request_timeout_ms,
            .write_timeout_ms = cfg.admin.write_timeout_ms,
            .max_connections = cfg.admin.max_connections,
            .max_requests_per_connection = cfg.admin.max_requests_per_connection,
            .max_body_bytes = 4096,
            .shutdown_grace_ms = cfg.admin.shutdown_grace_ms,
        };
        group.concurrent(io, adminServeTask, .{ gpa, io, &admin_listener.?, &admin_app, if (admin_log) |*l| l else null, admin_limits, &admin_stats }) catch {
            err(io, "cannot start the administration server (no concurrency available)", .{});
            admin_listener.?.deinit(io);
            admin_listener = null;
            break :admin;
        };
        err(io, "serving administration on http://{f}/ (sign in with the token or password; read-only)", .{admin_listener.?.socket.address});
    }

    installSignalHandlers(onServeSignal);
    var result: u8 = exit_ok;
    dkhttp.server.servePublic(gpa, io, &listener, index.searcher(), if (public_log) |*l| l else null, limits, &stats, &stop_control) catch |e| {
        err(io, "server stopped: {t}", .{e});
        result = exit_failure;
    };
    // Stop the admin listener too (when the public server failed on its own).
    stop_control.requestStop();
    group.await(io) catch {};
    err(io, "stopped", .{});
    return result;
}

/// Takes the data directory's writer lock, or explains why not.
fn lockWriters(io: Io, data_dir: []const u8, what: []const u8) ?dk.maintenance.WriterLock {
    var dir = Io.Dir.cwd().openDir(io, data_dir, .{}) catch |e| {
        err(io, "cannot open data_dir {s}: {t}", .{ data_dir, e });
        return null;
    };
    defer dir.close(io);
    return dk.maintenance.WriterLock.acquire(io, dir, "write.lock") catch |e| {
        switch (e) {
            error.Busy => err(io, "another import or rebuild is already running on {s}; {s} was not started", .{ data_dir, what }),
            error.Io => err(io, "cannot lock {s}/write.lock", .{data_dir}),
        }
        return null;
    };
}

fn rebuildCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const paths = Paths.make(arena_state.allocator(), cfg.data_dir) catch return exit_io;
    const lock = lockWriters(io, cfg.data_dir, "rebuild") orelse return exit_io;
    defer lock.release(io);

    var state = openState(io, gpa, paths.state) orelse return exit_io;
    defer state.close();
    var content = openContent(io, gpa, paths.content) orelse return exit_io;
    defer content.close();
    var index = openIndex(io, paths.index) orelse return exit_io;
    defer index.close();

    const stats = dk.rebuild.rebuild(gpa, index.indexer(), content.store(), state.documents()) catch |e| {
        err(io, "rebuild failed: {t}. The index may be partial; run rebuild again", .{e});
        return exit_io;
    };
    out(io, "index rebuilt: {d} documents indexed, {d} without retained text (skipped), {d} unreadable\n", .{ stats.reindexed, stats.unrecoverable, stats.failed });
    return exit_ok;
}

fn word(f: dk.maintenance.FileState) []const u8 {
    return switch (f) {
        .absent => "absent (not created yet)",
        .ok => "ok",
        .damaged => "DAMAGED",
        .newer_version => "written by a newer version of dksearch; not touched",
        .needs_upgrade => "older format; any other command upgrades it first",
        .unreadable => "UNREADABLE (cannot be opened; check permissions and the disk)",
    };
}

fn checkCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const paths = Paths.make(arena_state.allocator(), cfg.data_dir) catch return exit_io;

    const r = dk.maintenance.check(gpa, io, .{ .index = paths.index, .state = paths.state, .content = paths.content }) catch {
        err(io, "out of memory", .{});
        return exit_io;
    };
    out(io, "state.db    {s} ({d} documents)\n", .{ word(r.state), r.documents });
    out(io, "content.db  {s} ({d} retained texts)\n", .{ word(r.content), r.texts });
    if (r.indexed) |n| {
        out(io, "index.db    {s} ({d} documents)\n", .{ word(r.index), n });
    } else {
        out(io, "index.db    {s}\n", .{word(r.index)});
    }
    if (r.cross_checked) {
        out(io, "texts verified against their records: {d} corrupt, {d} records without retained text, {d} unreferenced texts\n", .{ r.corrupt_texts, r.without_text, r.orphan_texts });
    } else {
        out(io, "texts not verified (needs state.db and content.db both readable)\n", .{});
    }
    // Advice, never failures: none of these is damage.
    if (r.cross_checked and r.index != .damaged and (r.index == .absent or (r.indexed orelse r.documents) != r.documents)) {
        out(io, "note: the index does not match the document records; `dksearch rebuild` recreates it\n", .{});
    }
    if (r.orphan_texts > 0) out(io, "note: unreferenced texts are leftovers of interrupted imports and are harmless\n", .{});
    if (r.index == .damaged) out(io, "note: the index is derived data; delete index.db and run `dksearch rebuild`\n", .{});
    if (r.state == .damaged or r.content == .damaged or r.corrupt_texts > 0) {
        out(io, "problem: stored data is damaged. Restore state.db and content.db from a backup (see `dksearch backup`), then re-import or rebuild\n", .{});
    }
    if (r.healthy()) {
        out(io, "ok\n", .{});
        return exit_ok;
    }
    return exit_failure;
}

fn backupCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8, dest_dir: []const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const paths = Paths.make(a, cfg.data_dir) catch return exit_io;
    const dests = Paths.make(a, dest_dir) catch return exit_io;

    // Both must exist, and neither destination may: a backup never overwrites.
    for ([_][:0]const u8{ paths.state, paths.content }) |p| {
        Io.Dir.cwd().access(io, p, .{}) catch {
            err(io, "{s} does not exist; nothing to back up", .{p});
            return exit_io;
        };
    }
    for ([_][:0]const u8{ dests.state, dests.content }) |p| {
        if (Io.Dir.cwd().access(io, p, .{})) |_| {
            err(io, "{s} already exists; backups never overwrite. Use a new directory", .{p});
            return exit_io;
        } else |_| {}
    }
    Io.Dir.cwd().createDirPath(io, dest_dir) catch |e| {
        err(io, "cannot create {s}: {t}", .{ dest_dir, e });
        return exit_io;
    };

    // state.db first, then content.db: an import writes content before the
    // records that refer to it, so a content snapshot taken later always
    // contains every text the earlier state snapshot refers to.
    const pairs = [_][2][:0]const u8{ .{ paths.state, dests.state }, .{ paths.content, dests.content } };
    for (pairs) |pair| {
        dk.maintenance.backupFile(pair[0], pair[1], true) catch |e| {
            err(io, "backup of {s} failed: {t}. Remove any partial file in {s} before retrying", .{ pair[0], e, dest_dir });
            return exit_io;
        };
        out(io, "{s} -> {s}\n", .{ pair[0], pair[1] });
    }
    out(io, "backup complete and verified. index.db is not backed up: `dksearch rebuild` recreates it\n", .{});
    return exit_ok;
}

fn removeCmd(io: Io, gpa: std.mem.Allocator, config_path: []const u8, source: []const u8, yes: bool) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadAndValidate(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    // The source need not be in the configuration: removing a source you
    // already deleted from the file is the common case.
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const paths = Paths.make(arena_state.allocator(), cfg.data_dir) catch return exit_io;
    const lock = lockWriters(io, cfg.data_dir, "remove") orelse return exit_io;
    defer lock.release(io);

    var state = openState(io, gpa, paths.state) orelse return exit_io;
    defer state.close();
    var content = openContent(io, gpa, paths.content) orelse return exit_io;
    defer content.close();
    var index = openIndex(io, paths.index) orelse return exit_io;
    defer index.close();

    const n = state.documents().countOf(source) catch |e| {
        err(io, "cannot read the document records: {t}", .{e});
        return exit_io;
    };
    if (!yes) {
        out(io, "source \"{s}\" has {d} document{s}. Nothing was removed; run again with --yes to remove them from the index, the retained text and the records (this cannot be undone; re-import restores them from the source)\n", .{ source, n, if (n == 1) "" else "s" });
        return exit_ok;
    }
    installSignalHandlers(onImportSignal);
    var pipe = dk.pipeline.Pipeline.init(content.store(), state.documents(), index.indexer(), .{ .now = now });
    var result_arena = std.heap.ArenaAllocator.init(gpa);
    defer result_arena.deinit();
    const r = dk.runner.removeSource(result_arena.allocator(), &state, &pipe, source, &import_control) catch |e| {
        err(io, "removal failed: {t}. Run it again to finish", .{e});
        return exit_io;
    };
    out(io, "{s}: removed {d} of {d} document{s}{s}\n", .{ source, r.removed, n, if (n == 1) "" else "s", if (r.complete) "" else " (stopped early; run again to finish)" });
    return if (r.complete) exit_ok else exit_failure;
}

fn importCmd(io: Io, gpa: std.mem.Allocator, config_path: []const u8, one: ?[]const u8, all: bool, prune: bool) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadAndValidate(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();

    // Pick the sources to run.
    var selected: std.ArrayList(dk.config.Source) = .empty;
    defer selected.deinit(gpa);
    if (one) |name| {
        const s = for (cfg.sources) |s| {
            if (eq(s.name, name)) break s;
        } else {
            err(io, "no source named \"{s}\" in {s}", .{ name, config_path });
            return exit_usage;
        };
        if (!s.enabled) {
            err(io, "source \"{s}\" is disabled in {s}; set enabled = true to run it", .{ name, config_path });
            return exit_usage;
        }
        selected.append(gpa, s) catch return exit_io;
    } else if (all) {
        for (cfg.sources) |s| if (s.enabled) selected.append(gpa, s) catch return exit_io;
        if (selected.items.len == 0) {
            out(io, "no enabled sources in {s}; nothing to import\n", .{config_path});
            return exit_ok;
        }
    }

    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const paths = Paths.make(arena_state.allocator(), cfg.data_dir) catch return exit_io;
    const lock = lockWriters(io, cfg.data_dir, "import") orelse return exit_io;
    defer lock.release(io);

    var state = openState(io, gpa, paths.state) orelse return exit_io;
    defer state.close();
    var content = openContent(io, gpa, paths.content) orelse return exit_io;
    defer content.close();
    var index = openIndex(io, paths.index) orelse return exit_io;
    defer index.close();
    if (state.recovered_jobs > 0) err(io, "note: {d} earlier import(s) did not finish; they resume from their last checkpoint", .{state.recovered_jobs});

    installSignalHandlers(onImportSignal);

    var worst: u8 = exit_ok;
    for (selected.items) |source| {
        if (import_control.isCancelled()) break;
        var inst = dk.connectors.create(gpa, io, source) catch {
            err(io, "out of memory", .{});
            return exit_io;
        };
        defer inst.deinit();

        var pipe = dk.pipeline.Pipeline.init(content.store(), state.documents(), index.indexer(), .{
            .retain_text = source.retain_text,
            .now = now,
        });
        var result_arena = std.heap.ArenaAllocator.init(gpa);
        defer result_arena.deinit();

        const r = dk.runner.runImport(result_arena.allocator(), &state, &pipe, inst.connector(), source.name, &import_control, now) catch |e| {
            err(io, "{s}: import could not be recorded: {t}", .{ source.name, e });
            return exit_io;
        };
        out(io, "{s}: {t}, {d} imported ({d} added, {d} updated, {d} unchanged), {d} skipped (job {d})\n", .{
            source.name,
            r.state,
            r.submitted,
            pipe.stats.added,
            pipe.stats.updated,
            pipe.stats.unchanged,
            r.rejected,
            r.job_id,
        });
        if (r.failure) |why| err(io, "{s}: {s}", .{ source.name, why });
        if (r.state != .completed) worst = exit_failure;
        if (prune) {
            if (r.state != .completed) {
                err(io, "{s}: not pruning, because the import did not complete", .{source.name});
            } else {
                const p = dk.runner.pruneSource(result_arena.allocator(), &pipe, inst.connector(), source.name, &import_control) catch |e| {
                    err(io, "{s}: pruning failed: {t}", .{ source.name, e });
                    return exit_io;
                };
                out(io, "{s}: pruned {d} document{s} no longer in the source{s}\n", .{ source.name, p.removed, if (p.removed == 1) "" else "s", if (p.complete) "" else " (stopped early)" });
                if (!p.complete) worst = exit_failure;
            }
        }
    }
    return worst;
}
