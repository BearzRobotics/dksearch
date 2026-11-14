//! Storage boundary definitions.
//!
//! SPEC section 10 separates retained content, document metadata, search
//! index files, operational state, and configuration/secrets. This file
//! defines the interfaces for the first two only; the index and operational
//! state get their own interfaces when their backends are chosen (SPEC
//! section 16, items 1-3). No concrete backend is named here.
//!
//! Neither store knows about the index. The index is derived data and must be
//! rebuildable by iterating these stores.

const std = @import("std");
const Allocator = std.mem.Allocator;
const doc = @import("document.zig");

pub const Error = error{
    NotFound,
    /// Stored data failed an integrity check.
    Corrupt,
    /// Storage is full or a quota was hit.
    NoSpace,
    /// Any other I/O failure; details belong in logs, not in this set.
    Io,
    OutOfMemory,
};

/// Retained source content, keyed by document id. Separate from metadata so
/// retention and deletion policy can differ per source.
pub const ContentStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Replaces any existing content for `id`. Must be atomic: after a
        /// crash the old or the new content is readable, never a mixture.
        put: *const fn (ptr: *anyopaque, id: doc.Id, bytes: []const u8) Error!void,
        /// Returns a copy owned by the caller (allocated with `gpa`).
        get: *const fn (ptr: *anyopaque, gpa: Allocator, id: doc.Id) Error![]u8,
        /// Deleting a missing id is not an error.
        delete: *const fn (ptr: *anyopaque, id: doc.Id) Error!void,
        /// Optional batching. `begin` opens a batch: writes made until
        /// `commit` may be buffered and become durable together, with one
        /// sync instead of one per write. A crash before `commit` loses the
        /// whole batch and nothing else. `rollback` abandons it. A store
        /// without these (null) simply writes through immediately.
        begin: ?*const fn (ptr: *anyopaque) Error!void = null,
        commit: ?*const fn (ptr: *anyopaque) Error!void = null,
        rollback: ?*const fn (ptr: *anyopaque) Error!void = null,
    };

    pub fn begin(self: ContentStore) Error!void {
        if (self.vtable.begin) |f| return f(self.ptr);
    }
    pub fn commit(self: ContentStore) Error!void {
        if (self.vtable.commit) |f| return f(self.ptr);
    }
    pub fn rollback(self: ContentStore) Error!void {
        if (self.vtable.rollback) |f| return f(self.ptr);
    }

    pub fn put(self: ContentStore, id: doc.Id, bytes: []const u8) Error!void {
        return self.vtable.put(self.ptr, id, bytes);
    }
    pub fn get(self: ContentStore, gpa: Allocator, id: doc.Id) Error![]u8 {
        return self.vtable.get(self.ptr, gpa, id);
    }
    pub fn delete(self: ContentStore, id: doc.Id) Error!void {
        return self.vtable.delete(self.ptr, id);
    }
};

/// What the store remembers about an imported document: everything except
/// the main text (which lives in the `ContentStore`). Together they are
/// enough to rebuild the index without reacquiring the source.
pub const Record = struct {
    id: doc.Id,
    content_hash: ?doc.ContentHash,
    acquired_at: ?doc.Timestamp,
    /// The document as imported, with `text` null. Used to rebuild the index.
    meta: doc.Document,
};

/// Called once per record by `DocumentStore.forEach`. The record and all
/// strings in it are only valid during the call.
pub const Visitor = struct {
    ptr: *anyopaque,
    visit: *const fn (ptr: *anyopaque, rec: Record) Error!void,
};

/// Document metadata and provenance records.
pub const DocumentStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Insert or replace the record for `rec.id`. Everything in `rec` is
        /// copied.
        upsert: *const fn (ptr: *anyopaque, rec: Record) Error!void,
        /// Returns null if the id is unknown. Strings in the result are valid
        /// until the next call on this store.
        find: *const fn (ptr: *anyopaque, id: doc.Id) Error!?Record,
        delete: *const fn (ptr: *anyopaque, id: doc.Id) Error!void,
        /// Visits every record once, in an unspecified but stable order. The
        /// store must not be modified during the visit. Stops at the first
        /// error returned by the visitor and returns it.
        for_each: *const fn (ptr: *anyopaque, visitor: Visitor) Error!void,
        /// Optional batching. `begin` opens a batch: writes made until
        /// `commit` may be buffered and become durable together, with one
        /// sync instead of one per write. A crash before `commit` loses the
        /// whole batch and nothing else. `rollback` abandons it. A store
        /// without these (null) simply writes through immediately.
        begin: ?*const fn (ptr: *anyopaque) Error!void = null,
        commit: ?*const fn (ptr: *anyopaque) Error!void = null,
        rollback: ?*const fn (ptr: *anyopaque) Error!void = null,
    };

    pub fn begin(self: DocumentStore) Error!void {
        if (self.vtable.begin) |f| return f(self.ptr);
    }
    pub fn commit(self: DocumentStore) Error!void {
        if (self.vtable.commit) |f| return f(self.ptr);
    }
    pub fn rollback(self: DocumentStore) Error!void {
        if (self.vtable.rollback) |f| return f(self.ptr);
    }

    pub fn upsert(self: DocumentStore, rec: Record) Error!void {
        return self.vtable.upsert(self.ptr, rec);
    }
    pub fn find(self: DocumentStore, id: doc.Id) Error!?Record {
        return self.vtable.find(self.ptr, id);
    }
    pub fn delete(self: DocumentStore, id: doc.Id) Error!void {
        return self.vtable.delete(self.ptr, id);
    }
    pub fn forEach(self: DocumentStore, visitor: Visitor) Error!void {
        return self.vtable.for_each(self.ptr, visitor);
    }
};

// Reference in-memory implementations and their tests live in memory.zig.
