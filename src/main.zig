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
/// Set by the administration interface's "Restart dksearch": the server stops cleanly, then starts again.
var restart_flag: std.atomic.Value(bool) = .init(false);
var restart_dummy: u8 = 0;

fn requestRestart(_: *anyopaque) void {
    restart_flag.store(true, .release);
    stop_control.requestStop();
}
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

/// Shown (on standard error) when no command is given.
const short_usage = "usage: dksearch COMMAND [options]\ntry: dksearch --help   (or: dksearch help start, dksearch help admin)\n";

const starter_config = @embedFile("assets/starter.toml");

/// Writes the commented starter configuration; never overwrites.
fn initCmd(io: Io, path: []const u8) u8 {
    const f = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .truncate = false }) catch |e| switch (e) {
        error.PathAlreadyExists => {
            err(io, "{s} already exists; init never overwrites. Choose another name: dksearch init OTHER.toml", .{path});
            return exit_failure;
        },
        else => {
            err(io, "cannot create {s}: {t}", .{ path, e });
            return exit_io;
        },
    };
    defer f.close(io);
    f.writePositionalAll(io, starter_config, 0) catch |e| {
        err(io, "cannot write {s}: {t}", .{ path, e });
        return exit_io;
    };
    out(io, "wrote {s}\n\nNext:\n  1. edit it to add a [[source]] to index\n  2. dksearch import --config {s} NAME\n  3. dksearch serve  --config {s}\n\nTo turn on the administration interface, follow the steps in the [admin] part of the file\nor run: dksearch help admin\n", .{ path, path, path });
    return exit_ok;
}

fn helpCmd(io: Io, topic: ?[]const u8) u8 {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &buf);
    const t = topic orelse {
        dk.help.writeOverview(&w.interface) catch return exit_io;
        w.interface.flush() catch {};
        return exit_ok;
    };
    const known = dk.help.writeTopic(&w.interface, t) catch return exit_io;
    w.interface.flush() catch {};
    if (!known) {
        err(io, "no help for \"{s}\"; `dksearch help` lists the commands and topics", .{t});
        return exit_usage;
    }
    return exit_ok;
}

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
    const argv0: []const u8 = args.next() orelse "dksearch"; // program name, as it was started: a restart runs it again
    const first = args.next() orelse {
        Io.File.stderr().writeStreamingAll(io, short_usage) catch {};
        return exit_usage;
    };

    if (eq(first, "-h") or eq(first, "--help")) return helpCmd(io, null);
    if (eq(first, "help")) return helpCmd(io, args.next());
    // `dksearch COMMAND --help` shows that command's help instead of running it.
    if (dk.help.find(first) != null) {
        var scan = init.minimal.args.iterate();
        _ = scan.next();
        _ = scan.next();
        while (scan.next()) |a| if (eq(a, "-h") or eq(a, "--help")) return helpCmd(io, first);
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

    if (eq(first, "owner-password")) {
        var config_path: ?[]const u8 = null;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else {
                err(io, "unknown option for owner-password: {s}", .{a});
                return exit_usage;
            }
        }
        return ownerPasswordCmd(io, gpa, config_path);
    }

    if (eq(first, "safesearch-pin")) {
        var config_path: ?[]const u8 = null;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else {
                err(io, "unknown option for safesearch-pin: {s}", .{a});
                return exit_usage;
            }
        }
        return safeSearchPinCmd(io, gpa, config_path);
    }

    if (eq(first, "api-key")) return apiKeyCmd(io, gpa, &args);
    if (eq(first, "models")) return modelsCmd(io, gpa, &args);
    if (eq(first, "fetch-banlist")) return fetchBanlistCmd(io, gpa, &args);
    if (eq(first, "find-image")) return findImageCmd(io, gpa, &args);
    if (eq(first, "export")) return exportCmd(io, gpa, &args);
    if (eq(first, "node-key")) {
        var config_path: ?[]const u8 = null;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else {
                err(io, "unknown option for node-key: {s}", .{a});
                return exit_usage;
            }
        }
        return nodeKeyCmd(io, gpa, config_path);
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

    if (eq(first, "restore")) {
        var config_path: ?[]const u8 = null;
        var dir: ?[]const u8 = null;
        var rebuild_index = true;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else if (eq(a, "--no-index")) {
                rebuild_index = false;
            } else if (std.mem.startsWith(u8, a, "-")) {
                err(io, "unknown option for restore: {s}", .{a});
                return exit_usage;
            } else if (dir == null) {
                dir = a;
            } else {
                return usageError(io, "too many arguments");
            }
        }
        return restoreCmd(io, gpa, config_path, dir orelse return usageError(io, "restore needs the backup DIR"), rebuild_index);
    }

    if (eq(first, "serve") or eq(first, "rebuild") or eq(first, "embed")) {
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
        if (eq(first, "serve")) {
            const code = serve(io, gpa, config_path);
            // The administration interface asked for a restart: everything is closed now, so run the program again.
            if (restart_flag.load(.acquire)) restartSelf(io, argv0, config_path);
            return code;
        }
        return if (eq(first, "embed")) embedCmd(io, gpa, config_path) else if (eq(first, "embed")) embedCmd(io, gpa, config_path) else rebuildCmd(io, gpa, config_path);
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

    if (eq(first, "init")) {
        const path = args.next() orelse "dksearch.toml";
        if (args.next() != null) return usageError(io, "init takes at most one FILE");
        return initCmd(io, path);
    }

    if (eq(first, "eval")) {
        var config_path: ?[]const u8 = null;
        var file: ?[]const u8 = null;
        var k: u32 = 10;
        var json = false;
        var language: []const u8 = "en";
        while (args.next()) |a| {
            if (eq(a, "--language")) {
                language = args.next() orelse return usageError(io, "--language needs a language code such as en (or none)");
            } else if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else if (eq(a, "-k")) {
                const v = args.next() orelse return usageError(io, "-k needs a number");
                k = std.fmt.parseInt(u32, v, 10) catch return usageError(io, "-k needs a number from 1 to 100");
            } else if (eq(a, "--json")) {
                json = true;
            } else if (std.mem.startsWith(u8, a, "-")) {
                err(io, "unknown option for eval: {s}", .{a});
                return exit_usage;
            } else if (file == null) {
                file = a;
            } else {
                return usageError(io, "too many arguments");
            }
        }
        return evalCmd(io, gpa, config_path, file orelse return usageError(io, "eval needs a JUDGMENTS file"), k, json, language);
    }

    err(io, "unknown command: {s}", .{first});
    Io.File.stderr().writeStreamingAll(io, short_usage) catch {};
    return exit_usage;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usageError(io: Io, msg: []const u8) u8 {
    err(io, "{s}", .{msg});
    Io.File.stderr().writeStreamingAll(io, "try: dksearch help COMMAND (or dksearch --help)\n") catch {};
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

fn openIndex(io: Io, path: [:0]const u8, cfg: *const dk.config.Config, retokenize: bool) ?dk.index_sqlite.SqliteIndex {
    const tokenizer = cfg.tokenizer;
    const tk: dk.index_sqlite.Tokenizer = switch (tokenizer) {
        .unicode61 => .unicode61,
        .porter => .porter,
    };
    return dk.index_sqlite.SqliteIndex.open(path, .{ .tokenizer = tk, .retokenize = retokenize, .chunk_min_bytes = cfg.search.chunk_index_min_kb * 1024 }) catch |e| {
        switch (e) {
            error.TokenizerMismatch => err(io, "{s} was built with a different tokenizer than index.tokenizer = \"{s}\" asks for; run `dksearch rebuild` to recreate it", .{ path, @tagName(tokenizer) }),
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
        error.InsecurePermissions => err(io, "{s} can be read by other users; run `chmod 600 {s}` (or delete it and create new credentials)", .{ path, path }),
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
            raw.lflag.ISIG = false; // Ctrl-C arrives as a byte, so echo is always restored
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
        if (byte[0] == 0x03) { // Ctrl-C at the prompt (signals are off while reading)
            std.crypto.secureZero(u8, line.items);
            line.deinit(gpa);
            if (prompt != null) Io.File.stderr().writeStreamingAll(io, "\n") catch {};
            return null;
        }
        line.append(gpa, byte[0]) catch return null;
    }
    if (prompt != null) Io.File.stderr().writeStreamingAll(io, "\n") catch {};
    if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') _ = line.pop();
    return line.toOwnedSlice(gpa) catch null;
}

/// `dksearch api-key add NAME (--all | --collection C ...) | list | remove NAME_OR_ID` [--config FILE].
/// `dksearch models list | pull NAME [--yes] | remove NAME [--yes]`: the models of the Ollama server (found at
/// `[ollama] url` or the default address). Pulling and removing change what is on disk, so they need `--yes`.
/// `dksearch find-image FILE`: the indexed pictures that look like the picture in FILE.
fn findImageCmd(io: Io, gpa: std.mem.Allocator, args: anytype) u8 {
    var config_path: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var distance: u8 = 10;
    var limit: u32 = 20;
    while (args.next()) |a| {
        if (eq(a, "--config")) {
            config_path = args.next() orelse return usageError(io, "--config needs a FILE");
        } else if (std.mem.startsWith(u8, a, "--config=")) {
            config_path = a["--config=".len..];
        } else if (eq(a, "--distance")) {
            distance = std.fmt.parseInt(u8, args.next() orelse "", 10) catch return usageError(io, "--distance needs a number of bits, 0 to 32");
            if (distance > 32) return usageError(io, "--distance needs a number of bits, 0 to 32");
        } else if (eq(a, "--limit")) {
            limit = std.fmt.parseInt(u32, args.next() orelse "", 10) catch return usageError(io, "--limit needs a number, 1 to 100");
            if (limit == 0 or limit > 100) return usageError(io, "--limit needs a number, 1 to 100");
        } else if (std.mem.startsWith(u8, a, "-")) {
            err(io, "unknown option for find-image: {s}", .{a});
            return exit_usage;
        } else if (file == null) {
            file = a;
        } else return usageError(io, "find-image takes one picture FILE");
    }
    const path = file orelse return usageError(io, "find-image needs a picture FILE");
    if (!dk.image.available) {
        err(io, "this build cannot read pictures (built without -Dmedia)", .{});
        return exit_failure;
    }
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(dk.image.max_bytes)) catch |e| {
        err(io, "cannot read {s}: {t}", .{ path, e });
        return exit_io;
    };
    const hash = dk.image.dhash(arena, bytes) catch |e| {
        err(io, "{s}: {s}", .{ path, switch (e) {
            error.TooLarge => "the picture is too large to read",
            error.OutOfMemory => "out of memory",
            else => "not a picture this build can read (JPEG, PNG, GIF, WebP or BMP)",
        } });
        return exit_failure;
    };
    const paths = Paths.make(arena, cfg.data_dir) catch return exit_io;
    var index = dk.index_sqlite.SqliteIndex.openReadOnly(paths.index) catch |e| {
        err(io, "cannot open the index {s}: {t}", .{ paths.index, e });
        return exit_io;
    };
    defer index.close();
    const page = index.imageSearcher().near(arena, hash, distance, limit) catch |e| {
        err(io, "the search failed: {t}", .{e});
        return exit_failure;
    };
    err(io, "fingerprint {s}; pictures within {d} of 64 bits:", .{ dk.image.toHex(hash), distance });
    if (page.hits.len == 0) {
        out(io, "no picture in the index looks like it\n", .{});
        return exit_ok;
    }
    for (page.hits) |h| out(io, "{d}\t{s}\t{s}\t{s}\n", .{ h.distance, h.connector, h.url orelse "-", h.title orelse "-" });
    return exit_ok;
}

/// `dksearch export --source NAME ... --out FILE`: the documents of some sources, with their texts, in a file that a
/// `dump` source with `format = "export"` reads on another machine. Documents of banned domains are left out.
fn exportCmd(io: Io, gpa: std.mem.Allocator, args: anytype) u8 {
    var config_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var force = false;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    while (args.next()) |a| {
        if (eq(a, "--config")) {
            config_path = args.next() orelse return usageError(io, "--config needs a FILE");
        } else if (std.mem.startsWith(u8, a, "--config=")) {
            config_path = a["--config=".len..];
        } else if (eq(a, "--source")) {
            names.append(gpa, args.next() orelse return usageError(io, "--source needs a NAME")) catch return exit_failure;
        } else if (eq(a, "--out")) {
            out_path = args.next() orelse return usageError(io, "--out needs a FILE");
        } else if (eq(a, "--force")) {
            force = true;
        } else {
            err(io, "unknown option for export: {s}", .{a});
            return exit_usage;
        }
    }
    const target = out_path orelse return usageError(io, "export needs --out FILE (named ...dksearch.jsonl)");
    if (names.items.len == 0) return usageError(io, "export needs at least one --source NAME");
    if (!std.ascii.endsWithIgnoreCase(target, dk.exportfile.suffix)) {
        err(io, "the file must be named ...{s}, so that a dump source finds it", .{dk.exportfile.suffix});
        return exit_usage;
    }
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    for (names.items) |n| {
        var known = false;
        for (cfg.sources) |s| {
            if (std.mem.eql(u8, s.name, n)) known = true;
        }
        if (!known) {
            err(io, "there is no source named {s} in the configuration", .{n});
            return exit_usage;
        }
    }
    if (!force) {
        if (Io.Dir.cwd().access(io, target, .{})) |_| {
            err(io, "{s} exists; use --force to replace it", .{target});
            return exit_usage;
        } else |_| {}
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = Paths.make(arena, cfg.data_dir) catch return exit_io;
    var index = dk.index_sqlite.SqliteIndex.openReadOnly(paths.index) catch |e| {
        err(io, "cannot open the index {s}: {t}", .{ paths.index, e });
        return exit_io;
    };
    defer index.close();
    var content = openContent(io, gpa, paths.content) orelse return exit_io;
    defer content.close();
    // Banned domains are never exported: the index leaves their documents out when it knows the lists.
    var lists = buildDomainLists(io, arena, cfg, false, config_path) orelse return exit_failure;
    index.setDomains(&lists);
    const searcher = index.searcher();
    const store = content.store();

    const part = std.fmt.allocPrint(arena, "{s}.part", .{target}) catch return exit_failure;
    const file = Io.Dir.cwd().createFile(io, part, .{ .truncate = true }) catch |e| {
        err(io, "cannot write {s}: {t}", .{ part, e });
        return exit_io;
    };
    var offset: u64 = 0;
    var written: u64 = 0;
    var skipped: u64 = 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (names.items) |name| {
        var redistribution: []const u8 = "unknown";
        for (cfg.sources) |s| {
            if (std.mem.eql(u8, s.name, name)) {
                if (s.rights) |r| redistribution = @tagName(r);
            }
        }
        var cursor: i64 = 0;
        var in_source: u64 = 0;
        while (true) {
            var page_arena = std.heap.ArenaAllocator.init(gpa);
            defer page_arena.deinit();
            const pa = page_arena.allocator();
            const rows = searcher.exportPage(pa, name, cursor, 200) catch |e| {
                err(io, "reading {s} failed: {t}", .{ name, e });
                file.close(io);
                return exit_failure;
            };
            if (rows.len == 0) break;
            for (rows) |row| {
                cursor = row.cursor;
                const text = store.get(pa, row.id) catch {
                    skipped += 1; // no retained text: nothing to copy
                    continue;
                };
                if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
                    skipped += 1;
                    continue;
                }
                const line = dk.exportfile.encode(pa, .{
                    .id = std.fmt.bytesToHex(row.id, .lower)[0..],
                    .source = name,
                    .url = row.url,
                    .title = row.title,
                    .text = text,
                    .language = row.language,
                    .content_type = row.content_type,
                    .modified_at = row.modified_at,
                    .published_at = row.published_at,
                    .author = row.author,
                    .redistribution = redistribution,
                }) catch return exit_failure;
                buf.appendSlice(gpa, line) catch return exit_failure;
                buf.append(gpa, '\n') catch return exit_failure;
                written += 1;
                in_source += 1;
                if (buf.items.len >= 1024 * 1024) {
                    file.writePositionalAll(io, buf.items, offset) catch |e| {
                        err(io, "cannot write {s}: {t}", .{ part, e });
                        file.close(io);
                        return exit_io;
                    };
                    offset += buf.items.len;
                    buf.clearRetainingCapacity();
                }
            }
        }
        err(io, "{s}: {d} documents", .{ name, in_source });
    }
    if (buf.items.len > 0) {
        file.writePositionalAll(io, buf.items, offset) catch |e| {
            err(io, "cannot write {s}: {t}", .{ part, e });
            file.close(io);
            return exit_io;
        };
        offset += buf.items.len;
    }
    file.close(io);
    Io.Dir.cwd().rename(part, Io.Dir.cwd(), target, io) catch |e| {
        err(io, "cannot name the finished file {s}: {t}", .{ target, e });
        return exit_io;
    };
    out(io, "wrote {s}: {d} documents, {d} bytes ({d} without a retained text left out)\n", .{ target, written, offset, skipped });
    return exit_ok;
}

fn fetchBanlistCmd(io: Io, gpa: std.mem.Allocator, args: anytype) u8 {
    var url: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var yes = false;
    while (args.next()) |a| {
        if (eq(a, "--url")) {
            url = args.next() orelse return usageError(io, "--url needs an ADDRESS");
        } else if (std.mem.startsWith(u8, a, "--url=")) {
            url = a["--url=".len..];
        } else if (eq(a, "--out")) {
            out_path = args.next() orelse return usageError(io, "--out needs a FILE");
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            out_path = a["--out=".len..];
        } else if (eq(a, "--yes") or eq(a, "-y")) {
            yes = true;
        } else {
            err(io, "unknown option for fetch-banlist: {s}", .{a});
            return exit_usage;
        }
    }
    const u = url orelse return usageError(io, "fetch-banlist needs --url ADDRESS");
    const o = out_path orelse return usageError(io, "fetch-banlist needs --out FILE");
    if (!yes) {
        err(io, "this downloads {s} and replaces {s}; run it again with --yes to do it", .{ u, o });
        return exit_usage;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const r = dk.listfetch.download(io, gpa, arena_state.allocator(), u, o, false) catch |e| {
        switch (e) {
            error.BadAddress => err(io, "the address must start with https://", .{}),
            error.NotAvailable => err(io, "this build has no network support", .{}),
            error.NotAList => err(io, "what came back is not a list of domains or hashes (nothing was changed)", .{}),
            error.Refused => err(io, "the server refused or redirected somewhere unusable (nothing was changed)", .{}),
            error.Unreachable => err(io, "could not fetch {s} (nothing was changed)", .{u}),
            error.TooLarge => err(io, "the list is larger than {d} MiB (nothing was changed)", .{dk.listfetch.max_bytes / (1024 * 1024)}),
            error.WriteFailed => err(io, "could not write {s}", .{o}),
            error.OutOfMemory => err(io, "out of memory", .{}),
        }
        return exit_failure;
    };
    out(io, "wrote {s}: {d} hashes, {d} domains, {d} bytes\n", .{ o, r.stats.hashes, r.stats.domains, r.bytes });
    return exit_ok;
}

fn modelsCmd(io: Io, gpa: std.mem.Allocator, args: anytype) u8 {
    const sub_cmd = args.next() orelse return usageError(io, "models needs list, pull or remove");
    var config_path: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var yes = false;
    while (args.next()) |a| {
        if (eq(a, "--config")) {
            config_path = args.next() orelse return usageError(io, "--config needs a FILE");
        } else if (std.mem.startsWith(u8, a, "--config=")) {
            config_path = a["--config=".len..];
        } else if (eq(a, "--yes") or eq(a, "-y")) {
            yes = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            err(io, "unknown option for models: {s}", .{a});
            return exit_usage;
        } else if (name == null) {
            name = a;
        } else return usageError(io, "models takes one NAME");
    }
    var url: []const u8 = dk.ollama.default_url;
    var diag: dk.config.Diagnostic = .{};
    var cfg_opt: ?dk.config.Config = if (config_path != null) (loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag)) else null;
    defer if (cfg_opt) |*c| c.deinit();
    if (cfg_opt) |c| if (c.ollama) |o| {
        url = o.url;
    };
    const client = dk.ollama.Client.init(gpa, io, url) catch return exit_io;
    defer client.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (client.version(arena)) |v| out(io, "Ollama {s} at {s}\n", .{ v, url }) else {
        err(io, "no Ollama answers at {s} (is it running? set [ollama] url if it is elsewhere)", .{url});
        return exit_failure;
    }
    if (eq(sub_cmd, "list")) {
        const models = client.list(arena) catch |e| {
            err(io, "cannot list the models: {t}", .{e});
            return exit_failure;
        };
        if (models.len == 0) out(io, "no models yet; `dksearch models pull NAME --yes` downloads one\n", .{});
        for (models) |m| out(io, "{s}  {d} MiB  {s} {s} {s}\n", .{ m.name, m.size / (1024 * 1024), m.family, m.parameters, m.quantization });
        return exit_ok;
    }
    const model = name orelse return usageError(io, "models pull and remove need a model NAME");
    if (!dk.ollama.validModelName(model)) return usageError(io, "that is not a model name (letters, digits and . _ - : /)");
    if (eq(sub_cmd, "pull")) {
        if (!yes) {
            err(io, "this downloads the model {s} into Ollama (often 1 to 10 GB, from Ollama's library); run it again with --yes to do it", .{model});
            return exit_usage;
        }
        out(io, "pulling {s} (this can take a long while)...\n", .{model});
        client.pull(arena, model, null) catch |e| {
            err(io, "pulling {s} failed: {t}", .{ model, e });
            return exit_failure;
        };
        out(io, "done: {s}\n", .{model});
        return exit_ok;
    }
    if (eq(sub_cmd, "remove")) {
        if (!yes) {
            err(io, "this deletes the model {s} from Ollama; run it again with --yes to do it", .{model});
            return exit_usage;
        }
        client.remove(arena, model) catch |e| {
            err(io, "removing {s} failed: {t}", .{ model, e });
            return exit_failure;
        };
        out(io, "removed {s}\n", .{model});
        return exit_ok;
    }
    return usageError(io, "models needs list, pull or remove");
}

/// `dksearch node-key`: makes this node's identity (an Ed25519 key pair in data_dir/node-identity.toml) if there is none,
/// and prints the node id. Running it again changes nothing.
fn nodeKeyCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ cfg.data_dir, dk.identity.file_name }) catch return exit_io;
    var made = false;
    const existing = dk.identity.Identity.load(arena, io, Io.Dir.cwd(), path) catch |e| {
        err(io, "cannot use {s}: {t}", .{ path, e });
        return exit_io;
    };
    var id = existing orelse blk: {
        const fresh = dk.identity.Identity.generate(io);
        fresh.save(arena, io, Io.Dir.cwd(), path) catch |e| {
            err(io, "cannot write {s}: {t}", .{ path, e });
            return exit_io;
        };
        made = true;
        break :blk fresh;
    };
    var buf: [dk.identity.id_len]u8 = undefined;
    out(io, "{s}\n", .{id.idText(&buf)});
    if (made) err(io, "made the node identity in {s} (keep it secret, mode 0600); give the id above to the owners of peers that should recognise this node, and restart the server to use it", .{path}) else err(io, "this node already has an identity ({s})", .{path});
    return exit_ok;
}

fn apiKeyCmd(io: Io, gpa: std.mem.Allocator, args: anytype) u8 {
    const sub_cmd = args.next() orelse return usageError(io, "api-key needs add, list or remove");
    var config_path: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var all = false;
    var rate: u32 = 0;
    var bound_node: ?[]const u8 = null;
    var adult = false;
    var colls: std.ArrayList([]const u8) = .empty;
    defer colls.deinit(gpa);
    while (args.next()) |a| {
        if (eq(a, "--config")) {
            config_path = args.next() orelse return usageError(io, "--config needs a FILE");
        } else if (std.mem.startsWith(u8, a, "--config=")) {
            config_path = a["--config=".len..];
        } else if (eq(a, "--adult")) {
            adult = true;
        } else if (eq(a, "--node")) {
            bound_node = args.next() orelse return usageError(io, "--node needs a node id (dkn_...)");
        } else if (eq(a, "--rate")) {
            const r = args.next() orelse return usageError(io, "--rate needs a number of requests per minute");
            rate = std.fmt.parseInt(u32, r, 10) catch return usageError(io, "--rate must be a whole number of requests per minute (0: no limit)");
        } else if (eq(a, "--all")) {
            all = true;
        } else if (eq(a, "--collection") or eq(a, "-c")) {
            const c = args.next() orelse return usageError(io, "--collection needs a NAME");
            colls.append(gpa, c) catch return exit_io;
        } else if (std.mem.startsWith(u8, a, "--collection=")) {
            colls.append(gpa, a["--collection=".len..]) catch return exit_io;
        } else if (std.mem.startsWith(u8, a, "-")) {
            err(io, "unknown option for api-key: {s}", .{a});
            return exit_usage;
        } else if (name == null) {
            name = a;
        } else {
            return usageError(io, "api-key takes one NAME");
        }
    }
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ cfg.data_dir, dk.access.file_name }) catch return exit_io;
    const keys = dk.access.load(arena, io, Io.Dir.cwd(), path) catch |e| {
        err(io, "cannot read {s}: {t}", .{ path, e });
        return exit_io;
    };

    if (eq(sub_cmd, "list")) {
        if (keys.len == 0) out(io, "no API keys\n", .{});
        for (keys) |k| {
            out(io, "{s}  {s}  collections: ", .{ k.id, k.name });
            for (k.collections, 0..) |c, i| out(io, "{s}{s}", .{ if (i > 0) "," else "", if (eq(c, dk.access.all_marker)) "ALL" else c });
            if (k.rate > 0) out(io, "  limit: {d}/min", .{k.rate});
            if (k.node) |n| out(io, "  bound to node {s}", .{n});
            if (k.adult) out(io, "  adult (no safe search)", .{});
            out(io, "\n", .{});
        }
        return exit_ok;
    }
    if (eq(sub_cmd, "remove")) {
        const which = name orelse return usageError(io, "api-key remove needs a NAME or ID");
        const left = (dk.access.remove(arena, keys, which) catch return exit_io) orelse {
            err(io, "no API key named or numbered {s}", .{which});
            return exit_failure;
        };
        dk.access.save(arena, io, Io.Dir.cwd(), path, left) catch |e| {
            err(io, "cannot write {s}: {t}", .{ path, e });
            return exit_io;
        };
        out(io, "removed; it stops working within a second on a running server\n", .{});
        return exit_ok;
    }
    if (eq(sub_cmd, "add")) {
        const key_name = name orelse return usageError(io, "api-key add needs a NAME");
        if (!all and colls.items.len == 0) return usageError(io, "api-key add needs --all or at least one --collection NAME");
        if (all and colls.items.len > 0) return usageError(io, "give --all or --collection, not both");
        for (colls.items) |c| {
            var known = false;
            for (cfg.collections) |col| if (eq(col.name, c)) {
                known = true;
            };
            if (!known) {
                err(io, "there is no collection named {s} in the configuration", .{c});
                return exit_usage;
            }
        }
        const chosen: []const []const u8 = if (all) &.{dk.access.all_marker} else colls.items;
        var tok: [dk.access.token_len]u8 = undefined;
        const made_at: i64 = Io.Clock.real.now(io).toSeconds();
        const updated = dk.access.addBound(arena, io, keys, key_name, chosen, made_at, rate, bound_node, &tok) catch |e| {
            switch (e) {
                error.Duplicate => err(io, "a key named {s} already exists", .{key_name}),
                error.BadName => err(io, "the name must be 1 to 64 printable characters without quotes", .{}),
                else => err(io, "cannot make the key: {t}", .{e}),
            }
            return exit_usage;
        };
        const to_save = if (adult) (dk.access.withAdult(arena, updated, key_name) catch return exit_io) else updated;
        dk.access.save(arena, io, Io.Dir.cwd(), path, to_save) catch |e| {
            err(io, "cannot write {s}: {t}", .{ path, e });
            return exit_io;
        };
        out(io, "{s}\n", .{tok});
        err(io, "key {s} written (as a hash) to {s}. This is the only time the key is shown. Send it as: Authorization: Bearer KEY", .{ key_name, path });
        return exit_ok;
    }
    return usageError(io, "api-key needs add, list or remove");
}

/// `dksearch safesearch-pin`: sets the PIN that unlocks safe search in a browser (stored as a hash).
fn safeSearchPinCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const path = std.fmt.allocPrint(arena_state.allocator(), "{s}/{s}", .{ cfg.data_dir, dk.safesearch.pin_file_name }) catch return exit_io;
    var s = dk.secrets.load(gpa, io, Io.Dir.cwd(), path) catch |e| {
        secretsProblem(io, path, e);
        return exit_io;
    };
    defer s.deinit(gpa);
    const pin = readPassword(io, gpa) orelse {
        err(io, "no PIN was read; nothing was changed", .{});
        return exit_usage;
    };
    defer {
        std.crypto.secureZero(u8, pin);
        gpa.free(pin);
    }
    if (pin.len < dk.safesearch.min_pin_len or !std.unicode.utf8ValidateSlice(pin)) {
        err(io, "the PIN must be at least {d} characters; nothing was changed", .{dk.safesearch.min_pin_len});
        return exit_usage;
    }
    s.setPassword(gpa, io, pin) catch |e| {
        err(io, "cannot set the PIN: {t}", .{e});
        return exit_usage;
    };
    dk.secrets.save(io, Io.Dir.cwd(), path, s) catch |e| {
        err(io, "cannot write {s}: {t}", .{ path, e });
        return exit_io;
    };
    err(io, "PIN hash written to {s}; browsers already unlocked stay unlocked until their time is up (restart the server to end them)", .{path});
    if (!cfg.safe_search.enabled) err(io, "note: safe search is not turned on ([safe_search] enabled = true), so the PIN has no effect yet", .{});
    return exit_ok;
}

/// `dksearch owner-password`: sets the password the owner logs in with on the search page (stored only as a hash).
fn ownerPasswordCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const path = std.fmt.allocPrint(arena_state.allocator(), "{s}/{s}", .{ cfg.data_dir, dk.owner.file_name }) catch return exit_io;
    var s = dk.secrets.load(gpa, io, Io.Dir.cwd(), path) catch |e| {
        secretsProblem(io, path, e);
        return exit_io;
    };
    defer s.deinit(gpa);
    const pw = readPassword(io, gpa) orelse {
        err(io, "no password was read; nothing was changed", .{});
        return exit_usage;
    };
    defer {
        std.crypto.secureZero(u8, pw);
        gpa.free(pw);
    }
    if (pw.len < dk.owner.min_password_len or pw.len > dk.owner.max_password_len or !std.unicode.utf8ValidateSlice(pw)) {
        err(io, "the password must be {d} to {d} characters; nothing was changed", .{ dk.owner.min_password_len, dk.owner.max_password_len });
        return exit_usage;
    }
    s.setPassword(gpa, io, pw) catch |e| {
        err(io, "cannot set the password: {t}", .{e});
        return exit_usage;
    };
    dk.secrets.save(io, Io.Dir.cwd(), path, s) catch |e| {
        err(io, "cannot write {s}: {t}", .{ path, e });
        return exit_io;
    };
    err(io, "owner password hash written to {s}; a running server uses it within a few seconds, and every browser logged in with the old one is logged out", .{path});
    return exit_ok;
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
        if (!std.unicode.utf8ValidateSlice(password)) {
            err(io, "the password must be valid UTF-8 (the sign-in form sends UTF-8); nothing was changed", .{});
            return exit_usage;
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

fn logLine(io: Io, text: []const u8) void {
    err(io, "{s}", .{text});
}

fn schedulerTask(gpa: std.mem.Allocator, io: Io, manager: *dk.jobs.Manager, state_path: [:0]const u8) Io.Cancelable!void {
    dk.scheduler.run(gpa, io, manager, state_path, &stop_control.stop, logLine);
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

/// The public limits for regex queries, from the `[search]` table.
fn publicRegexLimits(s: dk.config.SearchSettings) dk.regexsearch.Limits {
    return .{
        .max_pattern_bytes = s.regex_max_pattern,
        .max_candidates = s.regex_max_candidates,
        .budget_ms = s.regex_budget_ms,
        .max_steps = s.regex_max_steps,
        .concurrency = s.regex_concurrency,
    };
}

/// Ten times the public limits (within the configurable maxima), for the
/// administration interface's query-testing page.
fn adminRegexLimits(s: dk.config.SearchSettings) dk.regexsearch.Limits {
    var l = publicRegexLimits(s);
    l.max_pattern_bytes = @min(l.max_pattern_bytes * 10, 2000);
    l.max_candidates = @min(l.max_candidates * 10, 10_000);
    l.budget_ms = @min(l.budget_ms * 10, 60_000);
    l.max_steps = @min(l.max_steps * 10, 10_000_000);
    l.max_text_bytes = 8 << 20;
    l.max_repeat = 1000;
    l.max_depth = 100;
    l.concurrency = 4;
    l.queue_ms = 1000;
    return l;
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
    var index = openIndex(io, paths.index, &cfg, false) orelse return exit_io;
    defer index.close();

    // An older state.db is brought up to date now (a quick, idempotent step), because the
    // administration pages read it without writing.
    if (Io.Dir.cwd().access(io, paths.state, .{})) |_| {
        if (openState(io, gpa, paths.state)) |st| {
            var s = st;
            s.close();
        } else return exit_io;
    } else |_| {}

    // Searches run on several read-only connections so that concurrent
    // requests are answered in parallel (one connection would serialise
    // them). If they cannot be opened, the single connection is used.
    var pool: ?dk.index_sqlite.SearchPool = null;
    defer if (pool) |*p| p.close();
    {
        const cpus = std.Thread.getCpuCount() catch 4;
        pool = dk.index_sqlite.SearchPool.open(gpa, io, paths.index, std.math.clamp(cpus, 2, 8)) catch |e| blk: {
            err(io, "note: cannot open parallel search connections ({t}); searches will run one at a time", .{e});
            break :blk null;
        };
    }
    // A search that runs too long is stopped, so the client gets an answer
    // before the connection's own deadline cuts it off.
    if (pool) |*p| p.setQueryTimeout(cfg.search.query_timeout_ms);
    index.setQueryTimeout(io, cfg.search.query_timeout_ms);
    const fuzzy_mode: dk.index_sqlite.FuzzyMode = switch (cfg.search.fuzzy) {
        .off => .off,
        .auto => .auto,
        .always => .always,
    };
    // Stop words and synonyms: read once now; an unreadable or malformed file stops the server rather than
    // silently searching without it.
    var lexicon_arena = std.heap.ArenaAllocator.init(gpa);
    defer lexicon_arena.deinit();
    var lexicon: dk.lexicon.Lexicon = .{};
    inline for (.{ "stop_words_file", "synonyms_file" }) |key| {
        if (@field(cfg.search, key)) |path| {
            const text = Io.Dir.cwd().readFileAlloc(io, path, lexicon_arena.allocator(), .limited(4 * 1024 * 1024)) catch |e| {
                err(io, "cannot read search.{s} {s}: {t}", .{ key, path, e });
                return exit_config;
            };
            var problem: dk.lexicon.Problem = .{};
            (if (comptime std.mem.eql(u8, key, "stop_words_file"))
                dk.lexicon.addStopWords(lexicon_arena.allocator(), &lexicon, text, &problem)
            else
                dk.lexicon.addSynonyms(lexicon_arena.allocator(), &lexicon, text, &problem)) catch |e| {
                switch (e) {
                    error.BadLine => err(io, "search.{s} {s}: line {d} is not usable (a synonym group needs at least two comma-separated members, without quotes)", .{ key, path, problem.line }),
                    error.TooMany => err(io, "search.{s} {s} has too many entries", .{ key, path }),
                    error.OutOfMemory => err(io, "out of memory", .{}),
                }
                return exit_config;
            };
        }
    }
    const lexicon_ptr: ?*const dk.lexicon.Lexicon = if (lexicon.isEmpty()) null else &lexicon;
    if (pool) |*p| p.setLexicon(lexicon_ptr);
    index.setLexicon(lexicon_ptr);
    // Domain lists: the blocklist, the demotion list and, with safe search on, the ban lists. Read once now; an
    // unreadable file stops the server rather than silently showing what was meant to be hidden.
    var lists_arena = std.heap.ArenaAllocator.init(gpa);
    defer lists_arena.deinit();
    var domain_lists = buildDomainLists(io, lists_arena.allocator(), cfg, true, config_path) orelse return exit_config;
    const lists_ptr: ?*const dk.domainlist.Lists = if (domain_lists.blocked.isEmpty() and domain_lists.demoted.isEmpty() and domain_lists.safe.isEmpty()) null else &domain_lists;
    if (pool) |*p| p.setDomains(lists_ptr);
    index.setDomains(lists_ptr);
    dk.domainlist.global = lists_ptr;
    defer dk.domainlist.global = null;
    // The relay that shows pictures of the web in the gallery without storing them (`[images] remote`).
    var image_relay: dk.imagerelay.Relay = .{ .gpa = gpa, .io = io, .max_bytes = @as(usize, cfg.images.relay_max_mb) * 1024 * 1024, .max_concurrent = cfg.images.relay_concurrency };
    // The thumbnail cache of the gallery (`[images] thumbnails`): small JPEG copies, kept up to a size.
    var thumb_cache: ?dk.thumbcache.Cache = null;
    const thumb_dir: []const u8 = if (cfg.images.thumbnails) (cfg.images.thumbnail_dir orelse (std.fmt.allocPrint(gpa, "{s}/thumbs", .{cfg.data_dir}) catch return exit_io)) else "";
    defer if (cfg.images.thumbnails and cfg.images.thumbnail_dir == null) gpa.free(thumb_dir);
    if (cfg.images.thumbnails) {
        thumb_cache = dk.thumbcache.Cache.init(gpa, io, .{ .dir = thumb_dir, .max_bytes = @as(u64, cfg.images.thumbnail_cache_mb) * 1024 * 1024, .px = cfg.images.thumbnail_px, .quality = @intCast(cfg.images.thumbnail_quality) });
        err(io, "thumbnails: on, kept in {s} up to {d} MiB ({d} pixels, quality {d})", .{ thumb_dir, cfg.images.thumbnail_cache_mb, cfg.images.thumbnail_px, cfg.images.thumbnail_quality });
    }
    // Safe search: on for visitors by default; a PIN (set with `dksearch safesearch-pin`) unlocks a browser.
    var unlock_state: ?dk.safesearch.Unlock = null;
    defer if (unlock_state) |*u| u.deinit();
    if (cfg.safe_search.enabled) {
        var dd = Io.Dir.cwd().openDir(io, cfg.data_dir, .{}) catch null;
        if (dd) |*d| {
            // The directory stays open for the life of the server: the PIN file is looked at again while it runs.
            unlock_state = dk.safesearch.Unlock.init(gpa, io, d.*, cfg.safe_search.unlock_hours) catch |e| blk: {
                err(io, "cannot read the safe-search PIN file ({t}); safe search cannot be unlocked", .{e});
                d.close(io);
                break :blk null;
            };
        }
        if (unlock_state) |*u| err(io, "safe search PIN: {s}", .{if (u.hasPin()) "set (visitors can unlock at /unlock)" else "not set (run `dksearch safesearch-pin`); safe search cannot be unlocked"});
    }
    // The owner's password sign-in (`dksearch owner-password`, or the Access page of the administration interface).
    var owner_state: ?dk.owner.OwnerLogin = null;
    defer if (owner_state) |*o| o.deinit();
    {
        var od = Io.Dir.cwd().openDir(io, cfg.data_dir, .{}) catch null;
        if (od) |*d| {
            owner_state = dk.owner.OwnerLogin.init(gpa, io, d.*, cfg.access.owner_login_days) catch |e| blk: {
                err(io, "cannot read the owner password file ({t}); the owner cannot log in", .{e});
                d.close(io);
                break :blk null;
            };
        }
        if (owner_state) |*o| err(io, "owner login: {s}", .{if (o.hasPassword()) "a password is set (the Login button is on the search page)" else "no password yet (run `dksearch owner-password`, or set one on the Access page)"});
    }
    // The owner's marks on results (feedback.jsonl in the data directory): offered on the main search page to the owner signed in.
    var feedback_store: ?dk.feedback.Store = if (owner_state) |*o| dk.feedback.Store.init(io, o.dir) else null;
    if (pool) |*p| {
        p.setFuzzyMode(fuzzy_mode);
        p.setCommonPercent(cfg.search.common_word_percent);
        p.setWordForms(cfg.search.word_forms);
        p.setSimpleSyntax(!cfg.search.advanced_syntax);
        p.setWeights(cfg.search.title_weight, cfg.search.body_weight);
        p.setRecency(cfg.search.recency_boost, cfg.search.recency_half_life_days);
    }
    index.setWeights(cfg.search.title_weight, cfg.search.body_weight);
    index.setRecency(cfg.search.recency_boost, cfg.search.recency_half_life_days);
    index.setFuzzyMode(fuzzy_mode);
    index.setCommonPercent(cfg.search.common_word_percent);
    index.setWordForms(cfg.search.word_forms);
    index.setSimpleSyntax(!cfg.search.advanced_syntax);
    const searcher = if (pool) |*p| p.searcher() else index.searcher();

    // The document viewer and regular-expression filtering read the stored texts through
    // their own read-only connections. Without a content.db (nothing imported yet) neither is
    // offered; with `[search] regex = false` only the viewer is.
    var content_pool: ?dk.content_sqlite.ContentPool = null;
    defer if (content_pool) |*p| p.close();
    var regex_service: ?dk.regexsearch.Service = null;
    var admin_regex_service: ?dk.regexsearch.Service = null;
    if (Io.Dir.cwd().access(io, paths.content, .{})) |_| {
        if (dk.content_sqlite.ContentPool.open(gpa, io, paths.content, @max(cfg.search.regex_concurrency, 2))) |p| {
            content_pool = p;
            if (cfg.search.regex) {
                regex_service = dk.regexsearch.Service.init(io, content_pool.?.store(), publicRegexLimits(cfg.search));
                admin_regex_service = dk.regexsearch.Service.init(io, content_pool.?.store(), adminRegexLimits(cfg.search));
            }
        } else |e| {
            err(io, "note: the document viewer and the regex filter are off: cannot open {s} for reading ({t})", .{ paths.content, e });
        }
    } else |_| {
        err(io, "note: the document viewer and the regex filter are off until something has been imported ({s} does not exist yet); restart after the first import", .{paths.content});
    }

    // Original files are served only from `files` sources that say `serve_originals = true`.
    var origin_roots: std.ArrayList(dk.originals.Root) = .empty;
    defer origin_roots.deinit(gpa);
    for (cfg.sources) |src| {
        if (!std.mem.eql(u8, src.kind, "files") or !src.enabled) continue;
        if (!(src.optionBool("serve_originals") orelse false)) continue;
        const base = src.optionString("path") orelse continue;
        origin_roots.append(gpa, .{ .connector = src.name, .base = base }) catch break;
    }
    // ZIM files are shown from the file itself unless a source says `serve_articles = false`.
    var zim_archives: std.ArrayList(dk.zimserve.Archive) = .empty;
    defer zim_archives.deinit(gpa);
    for (cfg.sources) |src| {
        if (!std.mem.eql(u8, src.kind, "zim") or !src.enabled) continue;
        if (!(src.optionBool("serve_articles") orelse true)) continue;
        const zpath = src.optionString("path") orelse continue;
        zim_archives.append(gpa, .{ .connector = src.name, .path = zpath }) catch break;
    }
    var zim_service: ?dk.zimserve.Service = if (zim_archives.items.len > 0) .{ .io = io, .gpa = gpa, .archives = zim_archives.items } else null;
    var originals_service: ?dk.originals.Service = if (origin_roots.items.len > 0) .{ .io = io, .roots = origin_roots.items } else null;
    if (originals_service != null) err(io, "note: original files are served for {d} source(s) (serve_originals = true)", .{origin_roots.items.len});

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
        .max_body_bytes = dkhttp.server.public_form_body_bytes, // the safe-search PIN form
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
    // The sources, shared so that editing them in the interface takes effect at once.
    var source_store = dk.sourcestore.Store.init(gpa, io, cfg.sources);
    var key_store = dk.access.KeyStore.init(gpa, io, cfg.data_dir);
    defer key_store.deinit();
    var peer_service: ?*dk.peers.Service = null;
    if (cfg.peers.len > 0) {
        peer_service = dk.peers.Service.init(gpa, io, cfg.node_name, cfg.peers) catch |e| {
            std.debug.print("dksearch: cannot set up peers: {t}\n", .{e});
            return 1;
        };
    }
    defer if (peer_service) |p| p.deinit();
    // This node's identity, if one was made with `dksearch node-key`: it signs requests to peers and answers to callers.
    var node_identity: ?dk.identity.Identity = null;
    var node_id_buf: [dk.identity.id_len]u8 = undefined;
    var node_id_text: ?[]const u8 = null;
    {
        const ipath = std.fmt.allocPrint(arena_state.allocator(), "{s}/{s}", .{ cfg.data_dir, dk.identity.file_name }) catch return exit_io;
        node_identity = dk.identity.Identity.load(arena_state.allocator(), io, Io.Dir.cwd(), ipath) catch |e| {
            err(io, "cannot use the node identity {s}: {t} (it must be readable only by you; `dksearch node-key` makes one)", .{ ipath, e });
            return exit_io;
        };
        if (node_identity) |*id| node_id_text = id.idText(&node_id_buf);
    }
    var replay = dk.identity.Replay.init(gpa, io);
    defer replay.deinit();
    if (node_identity) |*id| if (peer_service) |p| {
        p.identity = id;
    };
    if (peer_service) |p| p.cache_ttl_seconds = cfg.search.peer_cache_seconds;
    defer source_store.deinit();
    var job_manager: dk.jobs.Manager = undefined;
    var job_manager_ready = false;
    defer if (job_manager_ready) job_manager.deinit();
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
        if (cfg.admin_options.actions) {
            // The embedding server and the vectors file, for the Make vectors button.
            const vec_path_for_jobs = std.fmt.allocPrintSentinel(lists_arena.allocator(), "{s}/vectors.db", .{cfg.data_dir}, 0) catch {
                err(io, "out of memory", .{});
                return exit_io;
            };
            const embed_settings_for_jobs: dk.embed.Settings = if (cfg.embeddings) |ec| .{
                .url = ec.url,
                .api = if (std.mem.eql(u8, ec.api, "openai")) .openai else .ollama,
                .model = ec.model,
                .timeout_ms = ec.timeout_ms,
                .max_chars = ec.max_chars,
                .batch = ec.batch,
            } else .{ .url = "", .model = "" };
            job_manager = dk.jobs.Manager.init(gpa, io, .{
                .store = &source_store,
                .data_dir = cfg.data_dir,
                .index_path = paths.index,
                .state_path = paths.state,
                .content_path = paths.content,
                .tokenizer = switch (cfg.tokenizer) {
                    .unicode61 => .unicode61,
                    .porter => .porter,
                },
                .sources = cfg.sources,
                .backup_dir = cfg.admin_options.backup_dir,
                .zim_dir = cfg.admin_options.zim_dir,
                .config_path = config_path,
                .ollama_url = if (cfg.ollama) |o| o.url else dk.ollama.default_url,
                .embeddings = if (cfg.embeddings != null) .{ .settings = embed_settings_for_jobs, .vectors_path = vec_path_for_jobs } else null,
                .chunk_min_bytes = cfg.search.chunk_index_min_kb * 1024,
            });
            job_manager_ready = true;
        }
        admin_app = dkhttp.admin.App.init(gpa, io, .{
            .store = &source_store,
            .config_path = config_path,
            .restart = .{ .ctx = &restart_dummy, .request = requestRestart },
            .jobs = if (job_manager_ready) &job_manager else null,
            .searcher = searcher,
            .regex = if (admin_regex_service) |*r| r else null,
            .tokenizer = @tagName(cfg.tokenizer),
            .title_weight = cfg.search.title_weight,
            .body_weight = cfg.search.body_weight,
            .peers = peer_service,
            .ollama_url = if (cfg.ollama) |o| o.url else dk.ollama.default_url,
            .embeddings_model = if (cfg.embeddings) |e| e.model else null,
            .answers_model = if (cfg.answers.enabled) cfg.answers.model else null,
            .node_name = cfg.node_name,
            .node_id = node_id_text,
            .data_dir = cfg.data_dir,
            .image_searcher = if (pool) |*p| p.imageSearcher() else index.imageSearcher(),
            .lists = lists_ptr,
            .unlock = if (unlock_state != null) &unlock_state.? else null,
            .owner = if (owner_state != null) &owner_state.? else null,
            .thumbs = if (thumb_cache != null) &thumb_cache.? else null,
            .safe_enabled = cfg.safe_search.enabled,
            .safe_unlock_hours = cfg.safe_search.unlock_hours,
            .collections = cfg.collections,
            .anonymous_collections = cfg.access.anonymous_collections,
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
            // The login forms are tiny; the Find by image upload is a picture.
            .max_body_bytes = 12 * 1024 * 1024,
            .shutdown_grace_ms = cfg.admin.shutdown_grace_ms,
        };
        if (job_manager_ready) {
            group.concurrent(io, schedulerTask, .{ gpa, io, &job_manager, paths.state }) catch err(io, "scheduled imports are off (no concurrency available)", .{});
        }
        group.concurrent(io, adminServeTask, .{ gpa, io, &admin_listener.?, &admin_app, if (admin_log) |*l| l else null, admin_limits, &admin_stats }) catch {
            err(io, "cannot start the administration server (no concurrency available)", .{});
            admin_listener.?.deinit(io);
            admin_listener = null;
            break :admin;
        };
        err(io, "serving administration on http://{f}/ (sign in with the token or password; {s})", .{ admin_listener.?.socket.address, if (job_manager_ready) "imports can be started and cancelled" else "read-only" });
    }

    installSignalHandlers(onServeSignal);
    var result: u8 = exit_ok;
    var doc_service: ?dk.docserver.Service = null;
    if (cfg.docserver) |d| {
        var secret: ?[]const u8 = d.jwt_secret;
        if (d.jwt_secret_file) |path| {
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch |e| {
                std.debug.print("dksearch: docserver.jwt_secret_file {s} cannot be read: {t}\n", .{ path, e });
                return 1;
            };
            secret = std.mem.trim(u8, text, " \t\r\n"); // kept for the life of the server
        }
        doc_service = dk.docserver.Service.init(io, .{
            .kind = if (std.mem.eql(u8, d.kind, "collabora")) .collabora else .onlyoffice,
            .url = d.url,
            .public_url = d.public_url,
            .jwt_secret = secret,
        }) catch |e| {
            std.debug.print("dksearch: cannot set up the document server links: {t}\n", .{e});
            return 1;
        };
    }
    var embed_client: ?*dk.embed.Client = null;
    var embed_service: dk.embed.Service = undefined;
    var vector_holder: ?dk.vindex.Holder = null;
    defer if (vector_holder) |*h| h.deinit();
    if (cfg.embeddings) |ec| {
        const vec_path = std.fmt.allocPrintSentinel(arena_state.allocator(), "{s}/vectors.db", .{cfg.data_dir}, 0) catch return exit_io;
        embed_client = dk.embed.Client.init(gpa, io, .{
            .url = ec.url,
            .api = if (std.mem.eql(u8, ec.api, "openai")) .openai else .ollama,
            .model = ec.model,
            .timeout_ms = ec.timeout_ms,
            .max_chars = ec.max_chars,
            .batch = ec.batch,
        }) catch return exit_io;
        embed_service = .{ .client = embed_client.?, .vectors_path = vec_path };
        if (ec.index_mb > 0) {
            vector_holder = dk.vindex.Holder.init(gpa, io, vec_path, ec.model, @as(usize, ec.index_mb) * 1024 * 1024);
            embed_service.holder = &vector_holder.?;
        }
    }
    defer if (embed_client) |c| c.deinit();
    // Other search engines as a fallback: only with `[fallback] enabled = true`.
    var fallback_service: ?*dk.fallback.Service = null;
    var fallback_settings: dk.fallback.Settings = .{ .engines = &.{} };
    var fallback_on = false;
    if (cfg.fallback.enabled) {
        const fa = arena_state.allocator();
        var engines: std.ArrayList(dk.fallback.Engine) = .empty;
        for (cfg.fallback.engines) |name| {
            var found: ?dk.fallback.Engine = null;
            for (cfg.fallback.custom) |c| if (std.mem.eql(u8, c.name, name)) {
                found = .{ .name = c.name, .label = c.label, .url = c.url };
            };
            if (found == null) found = dk.fallback.builtin(name);
            if (found) |e| engines.append(fa, e) catch return exit_io;
        }
        if (cfg.fallback.providers.len > 0) {
            const provs = fa.alloc(dk.fallback.Provider, cfg.fallback.providers.len) catch return exit_io;
            for (cfg.fallback.providers, provs) |p, *o| o.* = .{
                .name = p.name,
                .kind = std.meta.stringToEnum(dk.fallback.ProviderKind, p.kind).?,
                .url = p.url,
                .key = p.key,
                .key_file = p.key_file,
                .timeout_ms = p.timeout_ms,
                .count = p.count,
            };
            fallback_service = dk.fallback.Service.init(gpa, io, provs, cfg.fallback.max_per_minute) catch return exit_io;
        }
        fallback_settings = .{ .engines = engines.items, .min_results = cfg.fallback.min_results, .auto = cfg.fallback.auto, .service = fallback_service };
        fallback_on = true;
        out(io, "note: fallback to other search engines is ON: the visitors' words can be sent to {d} service(s) (see [fallback])\n", .{cfg.fallback.providers.len});
    }
    defer if (fallback_service) |s| s.deinit();
    // The optional AI answer: a model in Ollama, only with `[answers] enabled = true`.
    var ollama_client: ?*dk.ollama.Client = null;
    var answer_service: dk.answer.Service = undefined;
    if (cfg.answers.enabled) {
        ollama_client = dk.ollama.Client.init(gpa, io, if (cfg.ollama) |o| o.url else dk.ollama.default_url) catch return exit_io;
        answer_service = .{ .client = ollama_client.?, .model = cfg.answers.model, .passages = cfg.answers.passages, .max_chars = cfg.answers.max_chars, .timeout_s = cfg.answers.timeout_s, .max_per_minute = cfg.answers.max_per_minute, .io = io };
    }
    defer if (ollama_client) |c| c.deinit();
    var source_stats = dk.sourcestats.Cache.init(gpa, io);
    defer source_stats.deinit();
    var retrieve_cache = dk.retrievecache.Cache.init(gpa, io, @as(usize, cfg.search.retrieve_cache_mb) * 1024 * 1024);
    defer retrieve_cache.deinit();
    dkhttp.server.servePublic(gpa, io, &listener, searcher, .{ .owner = if (owner_state != null) &owner_state.? else null, .feedback = if (feedback_store != null) &feedback_store.? else null, .thumbs = if (thumb_cache != null) &thumb_cache.? else null, .cookie_secure = cfg.access.cookie_secure, .relay = if (cfg.images.remote) &image_relay else null, .trusted_first = cfg.search.trusted_first, .trusted_min_boost = cfg.search.trusted_min_boost, .safe_default = cfg.safe_search.enabled, .unlock = if (unlock_state != null) &unlock_state.? else null, .per_domain = cfg.search.per_domain, .lists = lists_ptr, .answers = if (ollama_client != null) &answer_service else null, .fallback = if (fallback_on) &fallback_settings else null, .identity = if (node_identity) |*id| id else null, .replay = if (node_identity != null) &replay else null, .embed = if (embed_client != null) &embed_service else null, .source_stats = &source_stats, .default_collection = cfg.search.default_collection, .docserver = if (doc_service) |*d| d else null, .peers = peer_service, .retrieve_cache = if (cfg.search.retrieve_cache_mb > 0) &retrieve_cache else null, .collections = cfg.collections, .anonymous = cfg.access.anonymous_collections, .keys = &key_store, .regex = if (regex_service) |*r| r else null, .content = if (content_pool) |*p| p.store() else null, .originals = if (originals_service) |*o| o else null, .zims = if (zim_service) |*z| z else null, .sources = &source_store }, if (public_log) |*l| l else null, limits, &stats, &stop_control) catch |e| {
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
/// Runs the program again as `dksearch serve [--config FILE]`, in place of this process (same process id, same
/// working directory). `argv0` is how it was started, so a new binary put in the same place is the one that runs.
/// Returns only when that failed.
fn restartSelf(io: Io, argv0: []const u8, config_path: ?[]const u8) void {
    err(io, "restarting", .{});
    var argv: [4][]const u8 = .{ argv0, "serve", "--config", config_path orelse "" };
    const n: usize = if (config_path != null) 4 else 2;
    const e = std.process.replace(io, .{ .argv = argv[0..n] });
    err(io, "cannot restart ({t}); start dksearch again by hand", .{e});
}

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

/// `dksearch embed`: makes the vectors for semantic search from the retained texts, asking the embedding server of
/// `[embeddings]`. Documents that have a vector for the model are skipped, so it can be stopped and run again.
fn embedCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    const ec = cfg.embeddings orelse {
        err(io, "there is no [embeddings] table in the configuration; add url and model (see `man dksearch`, SEMANTIC SEARCH)", .{});
        return exit_usage;
    };
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = Paths.make(arena, cfg.data_dir) catch return exit_io;
    const vec_path = std.fmt.allocPrintSentinel(arena, "{s}/vectors.db", .{cfg.data_dir}, 0) catch return exit_io;

    var state = openState(io, gpa, paths.state) orelse return exit_io;
    defer state.close();
    var content = openContent(io, gpa, paths.content) orelse return exit_io;
    defer content.close();
    var store = dk.embed.Store.open(vec_path) catch |e| {
        err(io, "cannot open {s}: {t}", .{ vec_path, e });
        return exit_io;
    };
    defer store.close();
    const settings: dk.embed.Settings = .{
        .url = ec.url,
        .api = if (std.mem.eql(u8, ec.api, "openai")) .openai else .ollama,
        .model = ec.model,
        .timeout_ms = ec.timeout_ms,
        .max_chars = ec.max_chars,
        .batch = ec.batch,
    };
    const client = dk.embed.Client.init(gpa, io, settings) catch return exit_io;
    defer client.deinit();

    io_global = io;
    out(io, "making vectors with {s} at {s}\n", .{ settings.model, settings.url });
    const result = dk.embedjob.run(.{
        .gpa = gpa,
        .io = io,
        .client = client,
        .store = &store,
        .settings = settings,
        .documents = state.documents(),
        .content = content.store(),
        .on_batch = struct {
            fn say(_: ?*anyopaque, made: u64) void {
                out(io_global.?, "  {d} vectors made\n", .{made});
            }
        }.say,
    });
    if (result.failed) |f| {
        err(io, "the embedding server failed ({t}); {d} vectors were saved, run `embed` again to continue", .{ f, result.made });
        return exit_failure;
    }
    out(io, "done: {d} vectors made, {d} documents skipped (already done, or no retained text); {d} in the store for this model\n", .{ result.made, result.skipped, store.count(settings.model) });
    return exit_ok;
}

var io_global: ?Io = null;

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
    var index = openIndex(io, paths.index, &cfg, true) orelse return exit_io;
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

fn evalCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8, judgments_path: []const u8, k: u32, json: bool, language: []const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const paths = Paths.make(a, cfg.data_dir) catch return exit_io;

    const text = Io.Dir.cwd().readFileAlloc(io, judgments_path, a, .limited(16 * 1024 * 1024)) catch |e| {
        err(io, "cannot read {s}: {t}", .{ judgments_path, e });
        return exit_io;
    };
    var jd: dk.evaluate.Diagnostic = .{};
    const judgments = dk.evaluate.parseJudgments(a, text, &jd) catch |e| switch (e) {
        error.OutOfMemory => {
            err(io, "out of memory", .{});
            return exit_io;
        },
        error.BadJudgments => {
            if (jd.line > 0) {
                err(io, "{s}:{d}: {s}", .{ judgments_path, jd.line, jd.message });
            } else {
                err(io, "{s}: {s}", .{ judgments_path, jd.message });
            }
            return exit_failure;
        },
    };

    // Read-only use of the index, as `serve` does; evaluating never writes.
    Io.Dir.cwd().access(io, paths.index, .{}) catch {
        err(io, "{s} does not exist: import something first (or run `dksearch rebuild`)", .{paths.index});
        return exit_io;
    };
    var index = openIndex(io, paths.index, &cfg, false) orelse return exit_io;
    defer index.close();
    // The search settings of the configuration, as `serve` applies them, so the numbers are those of the running search.
    index.setWeights(cfg.search.title_weight, cfg.search.body_weight);
    index.setRecency(cfg.search.recency_boost, cfg.search.recency_half_life_days);
    index.setFuzzyMode(switch (cfg.search.fuzzy) {
        .off => .off,
        .auto => .auto,
        .always => .always,
    });
    index.setCommonPercent(cfg.search.common_word_percent);
    index.setWordForms(cfg.search.word_forms);
    index.setSimpleSyntax(!cfg.search.advanced_syntax);
    const prefer: []const []const u8 = if (eq(language, "none")) &.{} else (dk.langprefer.parseAcceptLanguage(a, language) catch &.{});
    const report = dk.evaluate.evaluateWith(a, index.searcher(), judgments, k, .{ .prefer_languages = prefer, .per_domain = cfg.search.per_domain }) catch |e| switch (e) {
        error.InvalidK => return usageError(io, "-k must be from 1 to 100"),
        error.OutOfMemory => {
            err(io, "out of memory", .{});
            return exit_io;
        },
    };
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &buf);
    (if (json) dk.evaluate.writeJson(&w.interface, report) else dk.evaluate.writeText(&w.interface, report)) catch return exit_io;
    w.interface.flush() catch return exit_io;
    return exit_ok;
}

fn restoreCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8, backup_dir: []const u8, rebuild_index: bool) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dest = Paths.make(a, cfg.data_dir) catch return exit_io;
    const from = Paths.make(a, backup_dir) catch return exit_io;

    // The backup must be there and sound before anything is written.
    for ([_][:0]const u8{ from.state, from.content }) |p| {
        Io.Dir.cwd().access(io, p, .{}) catch {
            err(io, "{s} does not exist; {s} is not a backup made by `dksearch backup`", .{ p, backup_dir });
            return exit_io;
        };
    }
    const report = dk.maintenance.check(gpa, io, .{ .index = from.index, .state = from.state, .content = from.content }) catch return exit_io;
    if (!report.healthy() or report.state != .ok or report.content != .ok) {
        err(io, "the backup in {s} is damaged or unreadable (run `dksearch check` on it by pointing data_dir at it); nothing was restored", .{backup_dir});
        return exit_failure;
    }

    // Restoring never overwrites: the target must have none of the three files.
    for ([_][:0]const u8{ dest.state, dest.content, dest.index }) |p| {
        if (Io.Dir.cwd().access(io, p, .{})) |_| {
            err(io, "{s} already exists; restore never overwrites. Move it away (or point data_dir at an empty directory) first", .{p});
            return exit_failure;
        } else |_| {}
    }
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    {
        const lock = lockWriters(io, cfg.data_dir, "restore") orelse return exit_io;
        defer lock.release(io);
        // content.db first, state.db last: a data directory with a state.db is complete.
        const pairs = [_][2][:0]const u8{ .{ from.content, dest.content }, .{ from.state, dest.state } };
        for (pairs) |pair| {
            dk.maintenance.restoreFile(io, pair[0], pair[1], true) catch |e| {
                err(io, "restoring {s} failed: {t}. Nothing half-written is left under that name; fix the cause and run restore again", .{ pair[1], e });
                return exit_io;
            };
            out(io, "{s} -> {s}\n", .{ pair[0], pair[1] });
        }
    }
    out(io, "restored {d} documents ({d} retained texts)\n", .{ report.documents, report.texts });
    if (!rebuild_index) {
        out(io, "index.db was not created: run `dksearch rebuild` before serving searches\n", .{});
        return exit_ok;
    }
    return rebuildCmd(io, gpa, config_path);
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
    var index = openIndex(io, paths.index, &cfg, false) orelse return exit_io;
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

/// Reads the domain lists named by `[filters]` and (when on) `[safe_search]` into `la`: the blocklist, the demotion list
/// and the ban lists. An unreadable file is an error, so that what was meant to be hidden is not shown.
fn buildDomainLists(io: Io, la: std.mem.Allocator, cfg: dk.config.Config, announce: bool, config_path: ?[]const u8) ?dk.domainlist.Lists {
    var lists: dk.domainlist.Lists = .{ .demote_percent = cfg.filters.demote_percent };
    var failed: []const u8 = "";
    // List files named with `ban` and `list` are relative to the folder of the configuration file.
    const base: ?[]const u8 = if (config_path) |p| (std.fs.path.dirname(p) orelse ".") else null;
    var ban_one: [1][]const u8 = undefined;
    var list_one: [1][]const u8 = undefined;
    const ban_files: []const []const u8 = if (cfg.filters.ban) |b| blk: {
        ban_one[0] = b;
        break :blk ban_one[0..1];
    } else &.{};
    const safe_files: []const []const u8 = if (cfg.safe_search.list) |l| blk: {
        list_one[0] = l;
        break :blk list_one[0..1];
    } else &.{};
    const loads = [_]struct { set: *dk.domainlist.Set, entries: []const []const u8, files: []const []const u8, relative: bool, on: bool }{
        .{ .set = &lists.blocked, .entries = cfg.filters.blocklist, .files = cfg.filters.blocklist_files, .relative = false, .on = true },
        .{ .set = &lists.blocked, .entries = &.{}, .files = ban_files, .relative = true, .on = true },
        .{ .set = &lists.demoted, .entries = cfg.filters.demote, .files = cfg.filters.demote_files, .relative = false, .on = true },
        .{ .set = &lists.safe, .entries = cfg.safe_search.ban, .files = cfg.safe_search.ban_files, .relative = false, .on = cfg.safe_search.enabled },
        .{ .set = &lists.safe, .entries = &.{}, .files = safe_files, .relative = true, .on = cfg.safe_search.enabled },
    };
    // The Block List Project lists switched on in the administration interface (downloaded to data_dir/lists/blocklistproject/).
    {
        var enabled_arena = std.heap.ArenaAllocator.init(la);
        defer enabled_arena.deinit();
        const chosen = dk.blocklists.readChosen(io, enabled_arena.allocator(), cfg.data_dir) catch &.{};
        for (chosen) |c| {
            // A list that hides (rather than bans) only matters while safe search is on.
            if (c.mode == .safe and !cfg.safe_search.enabled) continue;
            const path = dk.blocklists.filePath(enabled_arena.allocator(), cfg.data_dir, c.name) catch return null;
            const target = if (c.mode == .safe) &lists.safe else &lists.blocked;
            dk.domainlist.loadIfPresent(io, la, target, path, &failed) catch |e| {
                err(io, "cannot read the domain list {s}: {t}", .{ path, e });
                return null;
            };
        }
    }
    var allowed_out: usize = 0;
    for (loads, 0..) |l, li| {
        if (!l.on) continue;
        // Right after the lists of other people (the first load) the owner's allow list takes its domains out again.
        if (li == 1) for (cfg.filters.allow) |d| {
            allowed_out += lists.blocked.removeUnder(la, d) catch {
                err(io, "out of memory", .{});
                return null;
            };
            // The lists of other people that only hide are corrected the same way (the owner's own safesearch.toml is
            // loaded after this and is not touched).
            allowed_out += lists.safe.removeUnder(la, d) catch {
                err(io, "out of memory", .{});
                return null;
            };
        };
        for (l.entries) |e| _ = l.set.add(la, e) catch {
            err(io, "out of memory", .{});
            return null;
        };
        dk.domainlist.loadFilesFrom(io, la, l.set, l.files, if (l.relative) base else null, &failed) catch |e| {
            err(io, "cannot read the domain list {s}: {t}", .{ failed, e });
            return null;
        };
    }
    // The lists edited in the administration interface (data_dir/lists/), when they exist.
    const managed = [_]struct { name: []const u8, set: *dk.domainlist.Set, on: bool }{
        .{ .name = "ban.txt", .set = &lists.blocked, .on = true },
        .{ .name = "safesearch.txt", .set = &lists.safe, .on = cfg.safe_search.enabled },
        .{ .name = "demote.txt", .set = &lists.demoted, .on = true },
    };
    for (managed) |m| {
        if (!m.on) continue;
        const path = std.fmt.allocPrint(la, "{s}/lists/{s}", .{ cfg.data_dir, m.name }) catch return null;
        dk.domainlist.loadIfPresent(io, la, m.set, path, &failed) catch |e| {
            err(io, "cannot read the domain list {s}: {t}", .{ path, e });
            return null;
        };
    }
    if (announce) {
        if (cfg.filters.allow.len > 0) err(io, "allow list: {d} domains kept out of the blocklists ({d} entries removed)", .{ cfg.filters.allow.len, allowed_out });
        if (cfg.safe_search.enabled) err(io, "safe search is on for visitors: {d} domains hidden unless unlocked; {d} banned for everyone ({d} demoted)", .{ lists.safe.count(), lists.blocked.count(), lists.demoted.count() }) else if (!lists.blocked.isEmpty() or !lists.demoted.isEmpty()) err(io, "domain lists: {d} blocked, {d} demoted", .{ lists.blocked.count(), lists.demoted.count() });
    }
    return lists;
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
    // The ban lists keep a crawl away from banned sites (they are not contacted at all).
    var import_lists = buildDomainLists(io, arena_state.allocator(), cfg, false, config_path) orelse return exit_config;
    dk.domainlist.global = if (import_lists.blocked.isEmpty()) null else &import_lists;
    defer dk.domainlist.global = null;
    const paths = Paths.make(arena_state.allocator(), cfg.data_dir) catch return exit_io;
    const lock = lockWriters(io, cfg.data_dir, "import") orelse return exit_io;
    defer lock.release(io);

    var state = openState(io, gpa, paths.state) orelse return exit_io;
    defer state.close();
    var content = openContent(io, gpa, paths.content) orelse return exit_io;
    defer content.close();
    var index = openIndex(io, paths.index, &cfg, false) orelse return exit_io;
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
            .rights_override = source.rights,
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
        {
            var rb: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&rb);
            dk.connector.formatReasons(r.reasons, &w) catch {};
            if (w.end > 0) out(io, "{s}: skipped because: {s}\n", .{ source.name, rb[0..w.end] });
        }
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
