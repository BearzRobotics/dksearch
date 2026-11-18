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
    /// A collection: any source that belongs to it (`collection:books`). Needs `Query.collections`.
    collection,
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

/// How results are ordered.
pub const Sort = enum {
    /// Best match first (the default).
    relevance,
    /// Most recently modified first (documents without a date last).
    newest,
    oldest,
    /// Largest file first.
    largest,
    smallest,
    /// By title, A to Z.
    title,
};

pub const Query = struct {
    /// Conditions in the query language's own spelling (`ext:pdf`, `-domain:example.org`,
    /// `size:>1mb`, `modified:7d`), for callers that take them as separate parameters.
    filter_strings: []const []const u8 = &.{},
    sort: Sort = .relevance,
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
    /// How much each source counts, in percent (sources not named count 100). Set by the server from the
    /// sources' `boost` settings.
    boosts: []const SourceBoost = &.{},
    /// The sources the caller may see (null: all). Applied to every result, whatever else the query says; set by
    /// the server from the API key (or the anonymous access setting), never from the request itself.
    scope: ?[]const []const u8 = null,
    /// What `collection:` names mean, for the filter of that name.
    collections: []const CollectionDef = &.{},
    /// Fill `Hit.explain` with the parts of each score.
    explain: bool = false,
    /// Continue after this result of a relevance-ordered search (the `next_cursor` of the previous page) instead of
    /// at `offset`: stable when the index changes, and not limited by `max_window` (but by `max_cursor_window`).
    after: ?Cursor = null,
    /// At most this many results from one domain (0: no limit), keeping the best of each; for a relevance-ordered
    /// search of words. Paging and counts follow the limited list.
    per_domain: u32 = 0,
};

/// How many results a cursor can walk through.
pub const max_cursor_window = 100_000;

/// A place in a relevance-ordered result list: the score and id of the last result seen. Written as 48 hex digits
/// (the score's 8 bytes, then the id), which the caller treats as opaque.
pub const Cursor = struct {
    score: f64,
    id: doc.Id,

    pub fn format(self: Cursor, buf: *[48]u8) []const u8 {
        const bits: u64 = @bitCast(self.score);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, bits, .big);
        _ = std.fmt.bufPrint(buf, "{x}{x}", .{ &bytes, &self.id }) catch unreachable;
        return buf;
    }

    pub fn parse(text: []const u8) ?Cursor {
        if (text.len != 48) return null;
        var raw: [24]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw, text) catch return null;
        const score: f64 = @bitCast(std.mem.readInt(u64, raw[0..8], .big));
        if (std.math.isNan(score) or std.math.isInf(score)) return null;
        return .{ .score = score, .id = raw[8..24].* };
    }
};

pub const SourceBoost = struct { source: []const u8, percent: u32 };

/// A named group of sources.
pub const CollectionDef = struct { name: []const u8, sources: []const []const u8 };

/// The parts of a score: `score` = `text` x `source` x `recency`. `text` is the weighted text match; `title` and
/// `body` are how well the title and the text match on their own (not weighted, and not additive: the search
/// engine weighs the word counts before it saturates them, so the two do not add up to `text`).
pub const Explain = struct {
    text: f64,
    title: f64,
    body: f64,
    source: f64,
    recency: f64,
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
    /// When the source says it was created or published, and when it was added here.
    /// Filled by `Searcher.info`, not by `search`.
    published_at: ?i64 = null,
    indexed_at: ?i64 = null,
    explain: ?Explain = null,
    /// The name of the peer node this result came from; null for this node's own results.
    node: ?[]const u8 = null,
    /// Where the document's page is, on the node that has it (an absolute address; only for results of peers).
    remote_view: ?[]const u8 = null,
    /// Other nodes that returned the same document (merged into this one result).
    also_on: []const []const u8 = &.{},
    /// A node-independent identity (32 hex digits): the same page or the same text has the same one on every node.
    /// Filled by the HTTP layer, not by `search`.
    ident: ?[]const u8 = null,
    /// Sources (other than this result's) that hold the same text, when results are grouped.
    same_in: []const []const u8 = &.{},
    /// Further excerpts of the document (`snippets=N`), taken from its stored text; markers like `snippet`.
    more_snippets: []const []const u8 = &.{},
};

/// A passage found in the chunk index: the document, the position of the chunk among that document's chunks (as
/// `retrieve.chunk` numbers them with `index_chunk_chars` and `index_chunk_overlap`) and a score.
pub const ChunkHit = struct { id: doc.Id, index: u32, score: f64 };

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

/// One document of a source as listed for export to a peer (without its text, which is in the content store).
pub const ExportRow = struct {
    /// Position in the source's listing: the next page continues after it.
    cursor: i64,
    id: doc.Id,
    url: ?[]const u8,
    title: ?[]const u8,
    language: ?[]const u8,
    content_type: ?[]const u8,
    modified_at: ?i64,
    published_at: ?i64,
    author: ?[]const u8,
};

/// What the index holds for one source.
pub const SourceStat = struct { name: []const u8, docs: u64, last_added: ?i64 = null };

pub const WordKind = enum { prefix, spelling };

pub const Searcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Results are allocated from `arena` and live as long as it does.
        /// Ordering is by descending score, ties broken by document id, so
        /// pages are stable for an unchanged index.
        search: *const fn (ptr: *anyopaque, arena: Allocator, q: Query) Error!Page,
        /// What the index knows about one document (null if it is not there). Optional.
        info: ?*const fn (ptr: *anyopaque, arena: Allocator, id: doc.Id) Error!?Hit = null,
        /// The best passages of large documents, from the chunk index (see `ChunkHit`). Optional.
        search_chunks: ?*const fn (ptr: *anyopaque, arena: Allocator, q: Query, limit: u32) Error![]const ChunkHit = null,
        /// How many documents each source has and when the last one was added. Optional.
        source_stats: ?*const fn (ptr: *anyopaque, arena: Allocator) Error![]const SourceStat = null,
        /// The documents of one source after a position, in a stable order. Optional.
        /// Words of the vocabulary: those that start with a prefix, or those a few edits from a word. Optional.
        /// How many documents contain each word (0 for one that is not in the index). Optional.
        doc_freq: ?*const fn (ptr: *anyopaque, arena: Allocator, words: []const []const u8) Error![]const u32 = null,
        words: ?*const fn (ptr: *anyopaque, arena: Allocator, word: []const u8, kind: WordKind, limit: u32) Error![]const []const u8 = null,
        export_page: ?*const fn (ptr: *anyopaque, arena: Allocator, connector: []const u8, after: i64, limit: u32) Error![]const ExportRow = null,
    };

    /// How many documents contain each of `words` (empty if the index cannot say).
    pub fn docFreq(self: Searcher, arena: Allocator, words_in: []const []const u8) Error![]const u32 {
        const f = self.vtable.doc_freq orelse return &.{};
        return f(self.ptr, arena, words_in);
    }

    /// Words of the index that start with `prefix` (most common first) or that are within the usual number of edits of
    /// `prefix` taken as a whole word (closest first). Empty if the index cannot say.
    pub fn words(self: Searcher, arena: Allocator, word: []const u8, kind: WordKind, limit: u32) Error![]const []const u8 {
        const f = self.vtable.words orelse return &.{};
        return f(self.ptr, arena, word, kind, limit);
    }

    /// A page of the documents of `connector` after the cursor `after` (0: from the start); empty if the index cannot say.
    pub fn exportPage(self: Searcher, arena: Allocator, connector: []const u8, after: i64, limit: u32) Error![]const ExportRow {
        const f = self.vtable.export_page orelse return &.{};
        return f(self.ptr, arena, connector, after, limit);
    }

    /// Documents per source (empty if the index cannot say).
    pub fn sourceStats(self: Searcher, arena: Allocator) Error![]const SourceStat {
        const f = self.vtable.source_stats orelse return &.{};
        return f(self.ptr, arena);
    }

    /// Passages of large documents that match `q` (its words, conditions and source choice), best first. Empty
    /// when the index has no chunk index or nothing matches.
    pub fn searchChunks(self: Searcher, arena: Allocator, q: Query, limit: u32) Error![]const ChunkHit {
        const f = self.vtable.search_chunks orelse return &.{};
        return f(self.ptr, arena, q, limit);
    }

    /// What the index records about document `id`, or null if it has none (or cannot say).
    pub fn info(self: Searcher, arena: Allocator, id: doc.Id) Error!?Hit {
        const f = self.vtable.info orelse return null;
        return f(self.ptr, arena, id);
    }

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
