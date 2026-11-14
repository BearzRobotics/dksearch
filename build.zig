//! dksearch build script. `zig build test` runs all tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml");

    // Vendored SQLite (public domain). The header is translated to a Zig
    // module and the amalgamation is compiled into it. Compile-time options:
    //   FTS5                  full-text index backend (ADR 0003)
    //   OMIT_LOAD_EXTENSION   never load native code at runtime
    //   DQS=0                 double-quoted strings are identifiers only
    //   OMIT_DEPRECATED       drop deprecated interfaces
    //   OMIT_SHARED_CACHE     not used; shared cache is discouraged
    const sqlite_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite/sqlite3.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const sqlite = sqlite_c.createModule();
    sqlite.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_SHARED_CACHE",
        },
    });

    // The core library. It must stay independent of HTTP, the web UI and
    // individual connectors (ai/AGENTS.md section 3).
    const core = b.addModule("dksearch", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "toml", .module = toml },
            .{ .name = "sqlite_c", .module = sqlite },
        },
    });

    // The HTTP adapter: a separate module that imports the core.
    const http = b.addModule("dksearch_http", .{
        .root_source_file = b.path("src/http/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "dksearch", .module = core }},
    });

    // The command-line program.
    const zon = @import("build.zig.zon");
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    const exe = b.addExecutable(.{
        .name = "dksearch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dksearch", .module = core },
                .{ .name = "dksearch_http", .module = http },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");
    const unit = b.addTest(.{ .root_module = core });
    test_step.dependOn(&b.addRunArtifact(unit).step);
    const http_unit = b.addTest(.{ .root_module = http });
    test_step.dependOn(&b.addRunArtifact(http_unit).step);
}
