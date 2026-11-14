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
    \\       dksearch rebuild [--config FILE]
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

    if (eq(first, "import")) {
        var config_path: ?[]const u8 = null;
        var source: ?[]const u8 = null;
        var all = false;
        while (args.next()) |a| {
            if (eq(a, "--config")) {
                config_path = args.next() orelse return usageError(io, "--config needs a FILE");
            } else if (std.mem.startsWith(u8, a, "--config=")) {
                config_path = a["--config=".len..];
            } else if (eq(a, "--all")) {
                all = true;
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
        return importCmd(io, gpa, config_path.?, source, all);
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
    installSignalHandlers(onServeSignal);
    dkhttp.server.serve(gpa, io, &listener, index.searcher(), limits, &stats, &stop_control) catch |e| {
        err(io, "server stopped: {t}", .{e});
        return exit_failure;
    };
    err(io, "stopped", .{});
    return exit_ok;
}

fn rebuildCmd(io: Io, gpa: std.mem.Allocator, config_path: ?[]const u8) u8 {
    var diag: dk.config.Diagnostic = .{};
    var cfg = loadForRun(gpa, io, config_path, &diag) catch |e| return configFailure(io, e, &diag);
    defer cfg.deinit();
    if (!prepareDataDir(io, cfg.data_dir)) return exit_io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const paths = Paths.make(arena_state.allocator(), cfg.data_dir) catch return exit_io;

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

fn importCmd(io: Io, gpa: std.mem.Allocator, config_path: []const u8, one: ?[]const u8, all: bool) u8 {
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
    }
    return worst;
}
