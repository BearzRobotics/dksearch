//! The registry of bundled connectors: maps a source's `kind` to the code
//! that validates and runs it.
//!
//! Connectors are optional (docs/decisions/0007): with no `[[source]]` in the
//! configuration none of this runs, and nothing here is needed to serve
//! search. Bundled connectors use the same `Connector` interface as any other
//! and receive no private access to the pipeline or stores.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const api = @import("connector.zig");
const build_options = @import("build_options");

pub const files = @import("connectors/files.zig");
pub const gutenberg = @import("connectors/gutenberg.zig");
pub const zim = @import("connectors/zim.zig");
pub const dump = @import("connectors/dump.zig");
/// Present only in builds with `-Dwikipedia` (the default); see build.zig.
pub const have_wikipedia = build_options.wikipedia;
pub const wikipedia = if (have_wikipedia) @import("connectors/wikipedia.zig") else struct {};
/// Present only in builds with `-Dfeeds` (the default).
pub const have_feeds = build_options.feeds;
pub const feeds = if (have_feeds) @import("connectors/feeds.zig") else struct {};
/// Present only in builds with `-Dcrawler` (the default).
pub const have_crawler = build_options.crawler;
pub const crawl = if (have_crawler) @import("connectors/crawl.zig") else struct {};
/// The Internet Archive metadata connector shares the crawler's HTTP client.
pub const archive = if (have_crawler) @import("connectors/archive.zig") else struct {};
/// Copies a shared source of another dksearch node (network, like the crawler).
pub const peer = if (have_crawler) @import("connectors/peer.zig") else struct {};

/// Every kind this build knows, for help text and error messages.
pub const kinds = blk: {
    var k: []const []const u8 = &.{ files.kind, gutenberg.kind, zim.kind, dump.kind };
    if (have_wikipedia) k = k ++ &[_][]const u8{wikipedia.kind};
    if (have_feeds) k = k ++ &[_][]const u8{feeds.kind};
    if (have_crawler) k = k ++ &[_][]const u8{ crawl.kind, archive.kind, peer.kind };
    break :blk k;
};

/// "files, gutenberg, wikipedia", for messages.
pub const kinds_text = blk: {
    var t: []const u8 = "files, gutenberg, zim, dump";
    if (have_wikipedia) t = t ++ ", wikipedia";
    if (have_feeds) t = t ++ ", feeds";
    if (have_crawler) t = t ++ ", crawl, archive, peer";
    break :blk t;
};

/// Stands in for a connector that this build leaves out; never created.
const Absent = struct {
    pub fn deinit(_: *Absent) void {}
    pub fn connector(_: *Absent) api.Connector {
        unreachable;
    }
};

/// A connector instance of any bundled kind.
pub const Instance = union(enum) {
    files: files.FilesConnector,
    gutenberg: gutenberg.GutenbergConnector,
    zim: zim.ZimConnector,
    dump: dump.DumpConnector,
    wikipedia: if (have_wikipedia) wikipedia.WikipediaConnector else Absent,
    feeds: if (have_feeds) feeds.FeedsConnector else Absent,
    crawl: if (have_crawler) crawl.CrawlConnector else Absent,
    archive: if (have_crawler) archive.ArchiveConnector else Absent,
    peer: if (have_crawler) peer.PeerConnector else Absent,

    pub fn deinit(self: *Instance) void {
        switch (self.*) {
            inline else => |*c| c.deinit(),
        }
    }

    pub fn connector(self: *Instance) api.Connector {
        return switch (self.*) {
            inline else => |*c| c.connector(),
        };
    }
};

/// Checks one source: its kind is known and its options are valid for that
/// kind. Touches nothing outside memory, so it is safe in `check-config`.
pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    if (std.mem.eql(u8, source.kind, files.kind)) return files.validate(source, diag);
    if (std.mem.eql(u8, source.kind, gutenberg.kind)) return gutenberg.validate(source, diag);
    if (std.mem.eql(u8, source.kind, zim.kind)) return zim.validate(source, diag);
    if (std.mem.eql(u8, source.kind, dump.kind)) return dump.validate(source, diag);
    if (have_wikipedia and std.mem.eql(u8, source.kind, "wikipedia")) return wikipedia.validate(source, diag);
    if (have_feeds and std.mem.eql(u8, source.kind, "feeds")) return feeds.validate(source, diag);
    if (have_crawler and std.mem.eql(u8, source.kind, "crawl")) return crawl.validate(source, diag);
    if (have_crawler and std.mem.eql(u8, source.kind, "archive")) return archive.validate(source, diag);
    if (have_crawler and std.mem.eql(u8, source.kind, "peer")) return peer.validate(source, diag);
    var kbuf: [128]u8 = undefined;
    diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].kind", .{source.name}) catch "kind", "unknown connector kind \"{s}\" (this build has: {s})", .{ source.kind, kinds_text });
    return error.InvalidValue;
}

/// Validates every source (enabled or not, so a typo in a disabled source is
/// still caught) and returns the first problem. The file name is filled in
/// by the caller.
pub fn validateAll(sources: []const config.Source, diag: *config.Diagnostic) config.Error!void {
    for (sources) |s| try validate(s, diag);
}

/// Builds a connector for `source`, which must have passed `validate`.
pub fn create(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!Instance {
    if (std.mem.eql(u8, source.kind, files.kind)) return .{ .files = try files.FilesConnector.init(gpa, io, source) };
    if (std.mem.eql(u8, source.kind, gutenberg.kind)) return .{ .gutenberg = try gutenberg.GutenbergConnector.init(gpa, io, source) };
    if (std.mem.eql(u8, source.kind, zim.kind)) return .{ .zim = try zim.ZimConnector.init(gpa, io, source) };
    if (std.mem.eql(u8, source.kind, dump.kind)) return .{ .dump = try dump.DumpConnector.init(gpa, io, source) };
    if (have_wikipedia and std.mem.eql(u8, source.kind, "wikipedia")) return .{ .wikipedia = try wikipedia.WikipediaConnector.init(gpa, io, source) };
    if (have_feeds and std.mem.eql(u8, source.kind, "feeds")) return .{ .feeds = try feeds.FeedsConnector.init(gpa, io, source) };
    if (have_crawler and std.mem.eql(u8, source.kind, "crawl")) return .{ .crawl = try crawl.CrawlConnector.init(gpa, io, source) };
    if (have_crawler and std.mem.eql(u8, source.kind, "archive")) return .{ .archive = try archive.ArchiveConnector.init(gpa, io, source) };
    if (have_crawler and std.mem.eql(u8, source.kind, "peer")) return .{ .peer = try peer.PeerConnector.init(gpa, io, source) };
    unreachable; // `validate` rejects unknown kinds
}

const testing = std.testing;

test "unknown kinds are reported with the source name" {
    var d: config.Diagnostic = .{};
    const s: config.Source = .{ .name = "mystery", .kind = "carrier-pigeon" };
    try testing.expectError(error.InvalidValue, validate(s, &d));
    try testing.expectEqualStrings("source[mystery].kind", d.key());
    try testing.expect(std.mem.indexOf(u8, d.message(), "carrier-pigeon") != null);
}

test "validateAll accepts no sources, and checks disabled ones too" {
    var d: config.Diagnostic = .{};
    try validateAll(&.{}, &d);
    const bad: config.Source = .{ .name = "off", .kind = "files", .enabled = false }; // no path
    try testing.expectError(error.InvalidValue, validateAll(&.{bad}, &d));
}

test "create builds a runnable connector" {
    const s: config.Source = .{ .name = "n", .kind = "files", .options = &.{.{ .key = "path", .value = .{ .string = "." } }} };
    var d: config.Diagnostic = .{};
    try validate(s, &d);
    var inst = try create(testing.allocator, testing.io, s);
    defer inst.deinit();
    try testing.expectEqualStrings("files", inst.connector().info().kind);
    try testing.expect(!inst.connector().info().requires_network);
}
