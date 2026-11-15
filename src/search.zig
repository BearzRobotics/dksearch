//! The query side of the index boundary.
//!
//! Backend-neutral: a `Searcher` takes a `Query` made of plain data and
//! returns a `Page` of hits. Callers (the HTTP API, the admin interface,
//! tests) never see a backend's query syntax or types.

const std = @import("std");
const Allocator = std.mem.Allocator;
const doc = @import("document.zig");

/// Bytes that bracket matched terms inside `Hit.snippet`. They are control
/// characters so that a frontend can HTML-escape the snippet first and only
/// then replace these with its own markup. A snippet taken from untrusted
/// text may itself contain them; treat the markers as hints, not as trusted
/// structure.
pub const match_start = "\x02";
pub const match_end = "\x03";

pub const max_query_bytes = 1024;
pub const default_limit = 10;
pub const max_limit = 100;
/// `offset + limit` may not exceed this: deep pagination is expensive.
pub const max_window = 10_000;

pub const Query = struct {
    /// What the user typed. Plain words are ANDed; "double quotes" make a
    /// phrase. Anything else (operators, punctuation, field names) is treated
    /// literally, never as query syntax.
    text: []const u8,
    /// Exact-match filters; null means any.
    language: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    connector: ?[]const u8 = null,
    /// Page size; 0 means `default_limit`. Larger than `max_limit` is an error.
    limit: u32 = 0,
    offset: u32 = 0,
};

pub const Hit = struct {
    id: doc.Id,
    connector: []const u8,
    url: ?[]const u8,
    title: ?[]const u8,
    /// Excerpt with matches bracketed by `match_start`/`match_end`.
    snippet: ?[]const u8,
    /// Higher is better. Only comparable within one result set.
    score: f64,
};

pub const Page = struct {
    hits: []const Hit,
    /// True if at least one more hit follows this page.
    has_more: bool,
};

pub const Error = error{
    /// The query has no searchable terms.
    EmptyQuery,
    /// Query too long, limit/offset out of range, or similar misuse.
    InvalidQuery,
    /// The search ran past its time limit (see `[search] query_timeout_ms`).
    /// Common words over a very large index can take seconds to rank.
    Timeout,
    Io,
    OutOfMemory,
};

pub const Searcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Results are allocated from `arena` and live as long as it does.
        /// Ordering is by descending score, ties broken by document id, so
        /// pages are stable for an unchanged index.
        search: *const fn (ptr: *anyopaque, arena: Allocator, q: Query) Error!Page,
    };

    pub fn search(self: Searcher, arena: Allocator, q: Query) Error!Page {
        return self.vtable.search(self.ptr, arena, q);
    }
};
