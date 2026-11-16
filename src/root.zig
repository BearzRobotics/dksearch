//! dksearch core library. Independent of HTTP, the web UI and connectors.
//! See docs/decisions/0002-core-module-layout.md.

pub const config = @import("config.zig");
pub const document = @import("document.zig");
pub const connector = @import("connector.zig");
pub const storage = @import("storage.zig");
pub const indexer = @import("indexer.zig");
pub const memory = @import("memory.zig");
pub const pipeline = @import("pipeline.zig");
pub const search = @import("search.zig");
pub const evaluate = @import("evaluate.zig");
pub const image = @import("image.zig");
pub const queryparse = @import("queryparse.zig");
pub const docmeta = @import("docmeta.zig");
pub const originals = @import("originals.zig");
pub const avmeta = @import("avmeta.zig");
pub const render = @import("render.zig");
pub const zimserve = @import("zimserve.zig");
/// A tiny ZIM file for tests of the HTTP layer.
pub const zim_sample = @import("connectors/zim.zig").sample;
pub const htmlsafe = @import("htmlsafe.zig");
pub const exif = @import("exif.zig");
pub const sourcestore = @import("sourcestore.zig");
pub const sourceedit = @import("sourceedit.zig");
pub const regexsearch = @import("regexsearch.zig");
pub const help = @import("help.zig");
pub const rebuild = @import("rebuild.zig");
pub const index_sqlite = @import("index_sqlite.zig");
pub const content_sqlite = @import("content_sqlite.zig");
pub const state_sqlite = @import("state_sqlite.zig");
pub const runner = @import("runner.zig");
pub const connectors = @import("connectors.zig");
pub const maintenance = @import("maintenance.zig");
pub const secrets = @import("secrets.zig");
pub const jobs = @import("jobs.zig");
// src/sqlite.zig (raw C API) is internal to index_sqlite.zig and not exported.

test {
    _ = config;
    _ = document;
    _ = connector;
    _ = storage;
    _ = indexer;
    _ = memory;
    _ = pipeline;
    _ = search;
    _ = evaluate;
    _ = image;
    _ = queryparse;
    _ = docmeta;
    _ = originals;
    _ = avmeta;
    _ = render;
    _ = zimserve;
    _ = htmlsafe;
    _ = exif;
    _ = sourcestore;
    _ = sourceedit;
    _ = regexsearch;
    _ = help;
    _ = rebuild;
    _ = index_sqlite;
    _ = content_sqlite;
    _ = state_sqlite;
    _ = runner;
    _ = connectors;
    _ = maintenance;
    _ = secrets;
    _ = jobs;
    _ = connectors.zim;
    if (connectors.have_wikipedia) _ = connectors.wikipedia;
    if (connectors.have_feeds) _ = connectors.feeds;
    _ = @import("htmltext.zig");
    if (connectors.have_crawler) _ = connectors.crawl;
    if (connectors.have_crawler) _ = connectors.archive;
    _ = @import("sqlite.zig");
}

test "the vendored xml-zig library is available" {
    const std = @import("std");
    const xmlzig = @import("xmlzig");
    var doc = try xmlzig.Document.parse(std.testing.allocator, "<a><!--kept--><b x='1'>text</b></a>", .{}, null);
    defer doc.deinit();
    try std.testing.expectEqualStrings("1", doc.root.child("b").?.attr("x").?);
}
