//! dksearch build script. `zig build test` runs all tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // Manual pages (Markdown, read by dkman and dkde-help): share/man/manN/NAME.N.md.
    // The section N is the number in the file name.
    if (b.option(bool, "man", "Install the manual pages (default: on)") orelse true) {
        const pages = [_][]const u8{ "dksearch.1.md", "dksearch-api.7.md" };
        for (pages) |page| {
            const stem = page[0 .. page.len - ".md".len];
            const section = stem[std.mem.lastIndexOfScalar(u8, stem, '.').? + 1 ..];
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                b.path(b.fmt("docs/manpages/{s}", .{page})),
                .{ .custom = b.fmt("share/man/man{s}", .{section}) },
                page,
            ).step);
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const toml = b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml");
    const regex = b.dependency("regex", .{ .target = target, .optimize = optimize }).module("regex");
    const xml = b.dependency("xml", .{ .target = target, .optimize = optimize }).module("xml");
    const md = b.dependency("md", .{ .target = target, .optimize = optimize }).module("md");

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
    // `zig build test --fuzz` instruments the Zig code it fuzzes; the C libraries are not what is being fuzzed (and their
    // comparison tracing has no runtime to link to).
    sqlite.fuzz = false;
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

    // Optional XML-based connectors and the C libraries they need: Wikipedia
    // (bzip2 for the dump's compression) and feeds. Both read XML with the vendored xml-zig.
    // `-Dwikipedia=false` and `-Dfeeds=false` leave them out; a library that no
    // enabled connector needs is not compiled or linked at all (docs/decisions/
    // 0007, 0011, 0016). Windows is not supported yet.
    const target_os = target.result.os.tag;
    const supported = target_os != .windows;
    const want_wikipedia = b.option(bool, "wikipedia", "Build the Wikipedia connector with vendored bzip2 (default: on, except on Windows)") orelse supported;
    const want_feeds = b.option(bool, "feeds", "Build the RSS/Atom feeds connector (default: on, except on Windows)") orelse supported;
    if ((want_wikipedia or want_feeds) and !supported) @panic("the Wikipedia and feeds connectors are not supported on Windows yet; pass -Dwikipedia=false -Dfeeds=false");
    // The web crawler uses Zig's standard HTTP and TLS client (no C library)
    // and the bundled Mozilla CA file (docs/decisions/0018).
    const want_crawler = b.option(bool, "crawler", "Build the web crawler connector with the bundled CA certificates (default: on, except on Windows)") orelse supported;
    if (want_crawler and !supported) @panic("the crawler connector is not supported on Windows yet; pass -Dcrawler=false");
    // Image decoding (search by image) uses the vendored Wuffs, compiled only
    // with the image modules (docs/decisions/0023).
    const want_media = b.option(bool, "media", "Build image decoding (search by image) with vendored Wuffs (default: on, except on Windows)") orelse supported;
    if (want_media and !supported) @panic("image support is not supported on Windows yet; pass -Dmedia=false");

    const bz2_c: ?*std.Build.Module = if (want_wikipedia) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("vendor/bzip2_c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        tc.addIncludePath(b.path("vendor/bzip2"));
        const m = tc.createModule();
        m.fuzz = false;
        m.addCSourceFiles(.{
            .root = b.path("vendor/bzip2"),
            .files = &.{ "blocksort.c", "bzlib.c", "compress.c", "crctable.c", "decompress.c", "huffman.c", "randtable.c" },
            .flags = &.{"-D_FILE_OFFSET_BITS=64"},
        });
        m.addIncludePath(b.path("vendor/bzip2"));
        break :blk m;
    } else null;

    const wuffs_c: ?*std.Build.Module = if (want_media) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("vendor/wuffs_c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const m = tc.createModule();
        m.fuzz = false;
        m.addCSourceFiles(.{
            .root = b.path("vendor/wuffs"),
            .files = &.{"impl.c"},
            // Generated code in its own style: silence style warnings only.
            .flags = &.{"-w"},
        });
        m.addIncludePath(b.path("vendor/wuffs"));
        break :blk m;
    } else null;

    const core_options = b.addOptions();
    core_options.addOption(bool, "wikipedia", want_wikipedia);
    core_options.addOption(bool, "feeds", want_feeds);
    core_options.addOption(bool, "crawler", want_crawler);
    core_options.addOption(bool, "media", want_media);

    // The core library: search, storage and ingestion, plus the bundled
    // connectors behind the one connector interface. The search, storage and
    // pipeline code does not depend on any connector, and nothing here
    // depends on HTTP or the web UI (ai/AGENTS.md section 3).
    const core = b.addModule("dksearch", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "toml", .module = toml },
            .{ .name = "regex", .module = regex },
            .{ .name = "xmlzig", .module = xml },
            .{ .name = "mdzig", .module = md },
            .{ .name = "sqlite_c", .module = sqlite },
            .{ .name = "build_options", .module = core_options.createModule() },
        },
    });
    if (want_crawler) core.addAnonymousImport("cacert_pem", .{ .root_source_file = b.path("vendor/cacert/cacert.pem") });
    if (wuffs_c) |m| core.addImport("wuffs_c", m);
    if (bz2_c) |m| core.addImport("bz2_c", m);

    // The HTTP adapter: a separate module that imports the core.
    const http = b.addModule("dksearch_http", .{
        .root_source_file = b.path("src/http/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dksearch", .module = core },
            .{ .name = "manpages", .module = b.createModule(.{ .root_source_file = b.path("docs/manpages/embed.zig") }) },
        },
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
    // The tests alone do not compile the command-line program (a test build analyses only what a test reaches), so a mistake
    // in main.zig used to pass them: building the program is part of testing.
    test_step.dependOn(&exe.step);
    const unit = b.addTest(.{ .root_module = core });
    test_step.dependOn(&b.addRunArtifact(unit).step);
    const http_unit = b.addTest(.{ .root_module = http });
    test_step.dependOn(&b.addRunArtifact(http_unit).step);
}
