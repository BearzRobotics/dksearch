//! The shared document model.
//!
//! Every connector normalizes its source material into a `Document`. Fields
//! that a source cannot supply are left null/empty rather than invented.
//! Strings are borrowed: a `Document` does not own its memory, and whoever
//! holds the backing storage (a connector's arena, a store read) controls
//! its lifetime. Source-specific metadata that has no common field goes in
//! `extra`.

const std = @import("std");

/// Seconds since the Unix epoch, UTC.
pub const Timestamp = i64;

/// Stable internal identifier: derived only from connector name and source
/// identifier, so re-importing the same item (or rebuilding an index) yields
/// the same id.
pub const Id = [16]u8;

/// SHA-256 of the main text, for duplicate and revision detection.
pub const ContentHash = [32]u8;

/// What the project may do with retained content. Defaults to the most
/// restrictive reading: do not assume public availability grants redistribution.
pub const Redistribution = enum {
    unknown,
    allowed,
    restricted,
    forbidden,
};

pub const Rights = struct {
    /// SPDX identifier when one applies (e.g. "CC-BY-SA-4.0"), else free text.
    license: ?[]const u8 = null,
    license_url: ?[]const u8 = null,
    /// Required attribution text, when the license demands it.
    attribution: ?[]const u8 = null,
    /// Item-level access or usage conditions that are not a license.
    access_notes: ?[]const u8 = null,
    redistribution: Redistribution = .unknown,
};

pub const Related = struct {
    /// Relation such as "link", "translation", "revision-of". Free text.
    kind: []const u8,
    /// Source-specific id or URL of the related item.
    target: []const u8,
};

pub const Extra = struct {
    key: []const u8,
    value: []const u8,
};

pub const Document = struct {
    // --- Identity and provenance (required) ---
    /// Name of the connector instance that produced this record.
    connector: []const u8,
    /// Identifier of the item within its source (page id, catalog number, ...).
    source_id: []const u8,

    // --- Provenance (optional) ---
    source_dataset: ?[]const u8 = null,
    dataset_version: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    canonical_url: ?[]const u8 = null,

    // --- Content ---
    title: ?[]const u8 = null,
    /// Main text. Null when content is held elsewhere and referenced.
    text: ?[]const u8 = null,
    /// Reference to retained content in a `ContentStore`, when `text` is null.
    content_ref: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    /// BCP 47 tag, e.g. "en".
    language: ?[]const u8 = null,
    /// Media type, e.g. "text/html".
    content_type: ?[]const u8 = null,
    author: ?[]const u8 = null,

    // --- Dates ---
    published_at: ?Timestamp = null,
    modified_at: ?Timestamp = null,
    acquired_at: ?Timestamp = null,

    rights: Rights = .{},
    related: []const Related = &.{},
    extra: []const Extra = &.{},

    pub const ValidationError = error{
        MissingConnector,
        MissingSourceId,
        /// Neither `text` nor `content_ref` is set; there is nothing to index.
        NoContent,
        /// A text field contains invalid UTF-8.
        InvalidUtf8,
        /// A string field contains a NUL byte.
        EmbeddedNul,
    };

    /// Checks the invariants the shared pipeline relies on. Connectors need
    /// not call this; the pipeline does, because records are untrusted input.
    pub fn validate(self: Document) ValidationError!void {
        if (self.connector.len == 0) return error.MissingConnector;
        if (self.source_id.len == 0) return error.MissingSourceId;
        const has_text = if (self.text) |t| t.len > 0 else false;
        const has_ref = if (self.content_ref) |r| r.len > 0 else false;
        if (!has_text and !has_ref) return error.NoContent;

        const checked = [_]?[]const u8{
            self.connector,           self.source_id,      self.source_dataset,     self.dataset_version,
            self.revision,            self.canonical_url,  self.title,              self.text,
            self.content_ref,         self.summary,        self.language,           self.content_type,
            self.author,              self.rights.license, self.rights.license_url, self.rights.attribution,
            self.rights.access_notes,
        };
        for (checked) |maybe| {
            const s = maybe orelse continue;
            if (std.mem.indexOfScalar(u8, s, 0) != null) return error.EmbeddedNul;
            if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
        }
    }

    /// Deep copy into `a`: every string and slice is duplicated, so the result
    /// outlives the original's backing memory. Typically `a` is an arena.
    pub fn clone(self: Document, a: std.mem.Allocator) std.mem.Allocator.Error!Document {
        var out = self;
        out.connector = try a.dupe(u8, self.connector);
        out.source_id = try a.dupe(u8, self.source_id);
        out.source_dataset = try dupeOpt(a, self.source_dataset);
        out.dataset_version = try dupeOpt(a, self.dataset_version);
        out.revision = try dupeOpt(a, self.revision);
        out.canonical_url = try dupeOpt(a, self.canonical_url);
        out.title = try dupeOpt(a, self.title);
        out.text = try dupeOpt(a, self.text);
        out.content_ref = try dupeOpt(a, self.content_ref);
        out.summary = try dupeOpt(a, self.summary);
        out.language = try dupeOpt(a, self.language);
        out.content_type = try dupeOpt(a, self.content_type);
        out.author = try dupeOpt(a, self.author);
        out.rights.license = try dupeOpt(a, self.rights.license);
        out.rights.license_url = try dupeOpt(a, self.rights.license_url);
        out.rights.attribution = try dupeOpt(a, self.rights.attribution);
        out.rights.access_notes = try dupeOpt(a, self.rights.access_notes);
        const rel = try a.alloc(Related, self.related.len);
        for (self.related, rel) |src, *dst| dst.* = .{ .kind = try a.dupe(u8, src.kind), .target = try a.dupe(u8, src.target) };
        out.related = rel;
        const ex = try a.alloc(Extra, self.extra.len);
        for (self.extra, ex) |src, *dst| dst.* = .{ .key = try a.dupe(u8, src.key), .value = try a.dupe(u8, src.value) };
        out.extra = ex;
        return out;
    }

    pub fn id(self: Document) Id {
        return idFromSource(self.connector, self.source_id);
    }

    /// Hash of `text`, or null when the content is only referenced.
    pub fn contentHash(self: Document) ?ContentHash {
        const t = self.text orelse return null;
        return hashContent(t);
    }
};

fn dupeOpt(a: std.mem.Allocator, s: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    return if (s) |x| try a.dupe(u8, x) else null;
}

/// Deterministic id: SHA-256 over `connector 0x00 source_id`, truncated to 16
/// bytes. The separator prevents ("ab","c") colliding with ("a","bc").
pub fn idFromSource(connector: []const u8, source_id: []const u8) Id {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(connector);
    h.update(&.{0});
    h.update(source_id);
    var full: [32]u8 = undefined;
    h.final(&full);
    return full[0..16].*;
}

pub fn hashContent(bytes: []const u8) ContentHash {
    var out: ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

const testing = std.testing;

test "id is deterministic and separator-safe" {
    const a = idFromSource("gutenberg", "1342");
    try testing.expectEqual(a, idFromSource("gutenberg", "1342"));
    try testing.expect(!std.mem.eql(u8, &a, &idFromSource("gutenberg", "1343")));
    try testing.expect(!std.mem.eql(u8, &idFromSource("ab", "c"), &idFromSource("a", "bc")));
}

test "content hash differs for different text" {
    const d1: Document = .{ .connector = "c", .source_id = "1", .text = "alpha" };
    const d2: Document = .{ .connector = "c", .source_id = "1", .text = "beta" };
    try testing.expect(!std.mem.eql(u8, &d1.contentHash().?, &d2.contentHash().?));
    const ref_only: Document = .{ .connector = "c", .source_id = "1", .content_ref = "r" };
    try testing.expect(ref_only.contentHash() == null);
}

test "validate accepts minimal records" {
    try (Document{ .connector = "c", .source_id = "1", .text = "hello" }).validate();
    try (Document{ .connector = "c", .source_id = "1", .content_ref = "ref" }).validate();
}

test "validate rejects missing identity and content" {
    try testing.expectError(error.MissingConnector, (Document{ .connector = "", .source_id = "1", .text = "x" }).validate());
    try testing.expectError(error.MissingSourceId, (Document{ .connector = "c", .source_id = "", .text = "x" }).validate());
    try testing.expectError(error.NoContent, (Document{ .connector = "c", .source_id = "1" }).validate());
    try testing.expectError(error.NoContent, (Document{ .connector = "c", .source_id = "1", .text = "" }).validate());
}

test "validate rejects invalid UTF-8 and NUL in any text field" {
    try testing.expectError(error.InvalidUtf8, (Document{ .connector = "c", .source_id = "1", .text = "\xff\xfe" }).validate());
    try testing.expectError(error.EmbeddedNul, (Document{ .connector = "c", .source_id = "1", .text = "ok", .title = "a\x00b" }).validate());
    try testing.expectError(error.InvalidUtf8, (Document{ .connector = "c", .source_id = "1", .text = "ok", .rights = .{ .attribution = "\xc0" } }).validate());
}

test "rights default to not redistributable-by-assumption" {
    const d: Document = .{ .connector = "c", .source_id = "1", .text = "x" };
    try testing.expectEqual(Redistribution.unknown, d.rights.redistribution);
}

test "clone copies every string so the original can go away" {
    var buf = [_]u8{ 'a', 'b' };
    const rel = [_]Related{.{ .kind = "link", .target = "x" }};
    const ex = [_]Extra{.{ .key = "k", .value = "v" }};
    const original: Document = .{
        .connector = "c",
        .source_id = &buf,
        .title = "T",
        .text = "body",
        .rights = .{ .license = "MIT", .redistribution = .allowed },
        .related = &rel,
        .extra = &ex,
        .published_at = 5,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const copy = try original.clone(arena.allocator());
    buf[0] = 'Z';
    try testing.expectEqualStrings("ab", copy.source_id);
    try testing.expectEqualStrings("MIT", copy.rights.license.?);
    try testing.expectEqual(Redistribution.allowed, copy.rights.redistribution);
    try testing.expectEqualStrings("x", copy.related[0].target);
    try testing.expectEqualStrings("v", copy.extra[0].value);
    try testing.expectEqual(@as(?Timestamp, 5), copy.published_at);
    try testing.expect(copy.source_id.ptr != original.source_id.ptr);
}
