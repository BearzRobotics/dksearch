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

/// Typo tolerance for one search.
pub const Fuzzy = enum {
    /// Whatever the server is configured to do (`[search] fuzzy`).
    default,
    /// Plain words also match words one typo away, always.
    on,
    /// Exact words only.
    off,
};

/// Which property of a document a `Filter` tests.
pub const FilterField = enum {
    /// The connector (source) name.
    source,
    language,
    /// The media type: exact (`text/html`) or a family (`image/*`).
    mime,
    /// A group of file types: page, text, markdown, pdf, image, video, audio, data, other.
    kind,
    /// File extension without the dot, lower case.
    ext,
    /// Host of the document's URL; also matches its subdomains.
    domain,
    /// A prefix of the URL's path.
    path,
    /// Contains the text, ignoring case.
    author,
    /// Size of the text in bytes.
    size,
    /// When the document was last modified, as the source says (Unix seconds).
    modified,
    /// When it was created or published, as the source says.
    created,
    /// When it was added to the index.
    indexed,
    /// A tag attached to the document.
    tag,
    /// A custom field (`key`) containing the text.
    meta,
};

/// One condition a result must satisfy (or, negated, must not). A search has
/// a list of them and all must hold.
pub const Filter = struct {
    field: FilterField,
    negate: bool = false,
    /// The field name for `meta` filters.
    key: []const u8 = "",
    /// The value of the text fields.
    text: []const u8 = "",
    /// Inclusive limits of the numeric fields; null = open.
    min: ?i64 = null,
    max: ?i64 = null,
};

pub const Query = struct {
    /// Conditions on the documents, all of which must hold. Filters written in
    /// the query text itself (`ext:pdf`) are added to these.
    filters: []const Filter = &.{},
    fuzzy: Fuzzy = .default,
    /// What the user typed: words (ANDed), "phrases", and the query language of
    /// `queryparse.zig` (OR, NOT, parentheses, prefix*, word~, "a b"~5, +, -).
    /// Anything else (column filters, punctuation) is searched as plain text,
    /// never interpreted by the index.
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
    // What is known about the document, for display and for refining a search.
    language: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    modified_at: ?i64 = null,
    size: ?u64 = null,
    author: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    domain: ?[]const u8 = null,
};

pub const Page = struct {
    hits: []const Hit,
    /// True if at least one more hit follows this page.
    has_more: bool,
    /// How the query was understood, when it used the query language (AND, OR,
    /// NOT, grouping, prefix, fuzzy, proximity); null for plain words.
    interpreted: ?[]const u8 = null,
    /// True if these results include words one typo away from the ones typed
    /// (asked for, or tried because the exact words found nothing).
    fuzzy: bool = false,
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

/// A picture found by `ImageSearcher.near`: how many of the 64 hash bits differ
/// from the query picture's (0 = identical hash).
pub const ImageHit = struct {
    id: doc.Id,
    connector: []const u8,
    url: ?[]const u8,
    title: ?[]const u8,
    distance: u8,
};

pub const ImagePage = struct {
    hits: []const ImageHit,
};

/// Finds indexed pictures whose perceptual hash is close to a given one
/// (`image.zig`). Separate from `Searcher` because it asks a different question.
pub const ImageSearcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Pictures within `max_distance` bits of `hash`, nearest first, ties by
        /// id, at most `limit` of them. Allocated from `arena`.
        near: *const fn (ptr: *anyopaque, arena: Allocator, hash: u64, max_distance: u8, limit: u32) Error!ImagePage,
    };

    pub fn near(self: ImageSearcher, arena: Allocator, hash: u64, max_distance: u8, limit: u32) Error!ImagePage {
        return self.vtable.near(self.ptr, arena, hash, max_distance, limit);
    }
};
