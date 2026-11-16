//! dksearch build script. `zig build test` runs all tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
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
    // (bzip2 for the dump's compression, Expat for its XML) and feeds (Expat).
    // `-Dwikipedia=false` and `-Dfeeds=false` leave them out; a library that no
    // enabled connector needs is not compiled or linked at all (docs/decisions/
    // 0007, 0011, 0016). Windows is not supported yet.
    const target_os = target.result.os.tag;
    const supported = target_os != .windows;
    const want_wikipedia = b.option(bool, "wikipedia", "Build the Wikipedia connector with vendored bzip2 and Expat (default: on, except on Windows)") orelse supported;
    const want_feeds = b.option(bool, "feeds", "Build the RSS/Atom feeds connector with vendored Expat (default: on, except on Windows)") orelse supported;
    if ((want_wikipedia or want_feeds) and !supported) @panic("the Wikipedia and feeds connectors are not supported on Windows yet; pass -Dwikipedia=false -Dfeeds=false");
    // The web crawler uses Zig's standard HTTP and TLS client (no C library)
    // and the bundled Mozilla CA file (docs/decisions/0018).
    const want_crawler = b.option(bool, "crawler", "Build the web crawler connector with the bundled CA certificates (default: on, except on Windows)") orelse supported;
    if (want_crawler and !supported) @panic("the crawler connector is not supported on Windows yet; pass -Dcrawler=false");
    // Image decoding (search by image) uses the vendored Wuffs, compiled only
    // with the image modules (docs/decisions/0023).
    const want_media = b.option(bool, "media", "Build image decoding (search by image) with vendored Wuffs (default: on, except on Windows)") orelse supported;
    if (want_media and !supported) @panic("image support is not supported on Windows yet; pass -Dmedia=false");
    // The crawler reads sitemaps with Expat too.
    const need_expat = want_wikipedia or want_feeds or want_crawler;

    const bz2_c: ?*std.Build.Module = if (want_wikipedia) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("vendor/bzip2_c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        tc.addIncludePath(b.path("vendor/bzip2"));
        const m = tc.createModule();
        m.addCSourceFiles(.{
            .root = b.path("vendor/bzip2"),
            .files = &.{ "blocksort.c", "bzlib.c", "compress.c", "crctable.c", "decompress.c", "huffman.c", "randtable.c" },
            .flags = &.{"-D_FILE_OFFSET_BITS=64"},
        });
        m.addIncludePath(b.path("vendor/bzip2"));
        break :blk m;
    } else null;

    const expat_c: ?*std.Build.Module = if (need_expat) blk: {
        const tc = b.addTranslateC(.{
            .root_source_file = b.path("vendor/expat_c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        tc.addIncludePath(b.path("vendor/expat"));
        const m = tc.createModule();
        // Expat salts its hash tables with system entropy; which source to
        // use depends on the target. XML_GE=0 (no entity expansion) and no DTD
        // support are set in vendor/expat/expat_config.h.
        const little = target.result.cpu.arch.endian() == .little;
        const entropy_flags: []const []const u8 = if (target_os == .linux)
            &.{ "-DHAVE_GETRANDOM", "-DXML_DEV_URANDOM" }
        else
            &.{"-DHAVE_ARC4RANDOM_BUF"};
        const entropy_files: []const []const u8 = if (target_os == .linux)
            &.{ "random_getrandom.c", "random_dev_urandom.c" }
        else
            &.{"random_arc4random_buf.c"};
        const byte_order: []const u8 = if (little) "-DBYTEORDER=1234" else "-DBYTEORDER=4321";
        const expat_flags = std.mem.concat(b.allocator, []const u8, &.{ &.{ "-DHAVE_EXPAT_CONFIG_H", byte_order }, entropy_flags }) catch @panic("out of memory");
        m.addCSourceFiles(.{
            .root = b.path("vendor/expat"),
            .files = &.{ "xcs.c", "xmlparse.c", "xmlrole.c", "xmltok.c" },
            .flags = expat_flags,
        });
        m.addCSourceFiles(.{
            .root = b.path("vendor/expat"),
            .files = entropy_files,
            .flags = expat_flags,
        });
        m.addIncludePath(b.path("vendor/expat"));
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
    core_options.addOption(bool, "xml", need_expat);

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
    if (expat_c) |m| core.addImport("expat_c", m);

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
