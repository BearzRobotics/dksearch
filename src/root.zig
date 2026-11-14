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
pub const rebuild = @import("rebuild.zig");
pub const index_sqlite = @import("index_sqlite.zig");
pub const content_sqlite = @import("content_sqlite.zig");
pub const state_sqlite = @import("state_sqlite.zig");
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
    _ = rebuild;
    _ = index_sqlite;
    _ = content_sqlite;
    _ = state_sqlite;
    _ = @import("sqlite.zig");
}
