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
    if (connectors.have_wikipedia) _ = connectors.wikipedia;
    if (connectors.have_feeds) _ = connectors.feeds;
    _ = @import("htmltext.zig");
    if (connectors.have_crawler) _ = connectors.crawl;
    if (connectors.have_crawler) _ = connectors.archive;
    _ = @import("sqlite.zig");
}
