//! dksearch command-line entry point. See docs/manpages/dksearch.1.md.
//!
//! Thin by design: parse arguments, load configuration, wire the core to the
//! HTTP adapter, and run. No search logic lives here.

const std = @import("std");
const Io = std.Io;
const dk = @import("dksearch");
const dkhttp = @import("dksearch_http");
const build_options = @import("build_options");

/// Stop request shared with the signal handler. A handler has no context
/// argument, so this has to be a global; setting it is async-signal-safe.
var stop_control: dkhttp.server.Control = .{};

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    stop_control.requestStop();
}

fn installSignalHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

const exit_ok = 0;
const exit_failure = 1;
const exit_usage = 2;
const exit_config = 3;
const exit_io = 4;

const usage =
    \\usage: dksearch [-h | --help] [-V | --version]
    \\       dksearch serve [--config FILE]
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
        var cfg = dk.config.loadFile(gpa, io, Io.Dir.cwd(), path, &diag) catch |e| return configFailure(io, e, &diag);
        cfg.deinit();
        out(io, "{s}: ok\n", .{path});
        return exit_ok;
    }

    if (eq(first, "serve")) {
        var config_path: ?[]const u8 = null;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else {
                err(io, "unknown option for serve: {s}", .{a});
                return exit_usage;
            }
        }
        return serve(io, gpa, config_path);
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

fn serve(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = (if (config_path) |p|
        dk.config.loadFile(gpa, io, Io.Dir.cwd(), p, &diag)
    else
        dk.config.loadFromSlice(gpa, "(built-in defaults)", "", &diag)) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();

    Io.Dir.cwd().createDirPath(io, cfg.data_dir) catch |e| {
        err(io, "cannot create data_dir {s}: {t}", .{ cfg.data_dir, e });
        return exit_io;
    };
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/index.db", .{cfg.data_dir}, 0) catch {
        err(io, "storage.data_dir is too long", .{});
        return exit_config;
    };
    var index = dk.index_sqlite.SqliteIndex.open(index_path, .{}) catch |e| {
        switch (e) {
            error.SchemaMismatch => err(io, "{s} was written by an incompatible version; delete it and rebuild the index", .{index_path}),
            else => err(io, "cannot open index {s}: {t}", .{ index_path, e }),
        }
        return exit_io;
    };
    defer index.close();

    // Validated as a literal at load time, so this cannot fail.
    const address = Io.net.IpAddress.parse(cfg.server.address, cfg.server.port) catch unreachable;
    var listener = dkhttp.server.listen(io, address) catch |e| {
        err(io, "cannot listen on {s}:{d}: {t}", .{ cfg.server.address, cfg.server.port, e });
        return exit_io;
    };
    defer listener.deinit(io);

    err(io, "serving search on http://{f}/ (index: {s})", .{ listener.socket.address, index_path });
    if (cfg.admin_configured) err(io, "note: the administration interface is not implemented yet; [admin] is validated but not served", .{});

    const limits: dkhttp.server.Limits = .{
        .max_header_bytes = cfg.server.max_header_bytes,
        .request_head_timeout_ms = cfg.server.request_timeout_ms,
        .write_timeout_ms = cfg.server.write_timeout_ms,
        .max_connections = cfg.server.max_connections,
        .max_requests_per_connection = cfg.server.max_requests_per_connection,
        .shutdown_grace_ms = cfg.server.shutdown_grace_ms,
    };
    var stats: dkhttp.server.Stats = .{};
    installSignalHandlers();
    dkhttp.server.serve(gpa, io, &listener, index.searcher(), limits, &stats, &stop_control) catch |e| {
        err(io, "server stopped: {t}", .{e});
        return exit_failure;
    };
    err(io, "stopped", .{});
    return exit_ok;
}
