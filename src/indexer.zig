//! The indexer boundary.
//!
//! The index is derived data: it can always be rebuilt from the content and
//! document stores. The backend is still undecided (SPEC section 16), so this
//! file only defines what the ingestion pipeline needs from one.

const std = @import("std");
const doc = @import("document.zig");

pub const Error = error{
    /// The index is full or a quota was hit.
    NoSpace,
    /// Any other index failure; details belong in logs.
    Io,
    /// An integrity check failed. The index is derived data: rebuild it.
    Corrupt,
    OutOfMemory,
};

pub const Indexer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Index `d` under `id`, replacing any earlier entry for `id`. `d` is
        /// only valid for the call; the indexer copies what it keeps.
        add: *const fn (ptr: *anyopaque, id: doc.Id, d: doc.Document) Error!void,
        /// Removing an id that is not indexed is not an error.
        remove: *const fn (ptr: *anyopaque, id: doc.Id) Error!void,
        /// Drop every entry. Used before a rebuild.
        clear: *const fn (ptr: *anyopaque) Error!void,
        /// Verify the index's internal consistency; `error.Corrupt` if not.
        check: *const fn (ptr: *anyopaque) Error!void,
        /// Optional batching, with the same meaning as on the stores
        /// (`storage.ContentStore`): changes between `begin` and `commit`
        /// become durable together; null means write-through.
        begin: ?*const fn (ptr: *anyopaque) Error!void = null,
        commit: ?*const fn (ptr: *anyopaque) Error!void = null,
        rollback: ?*const fn (ptr: *anyopaque) Error!void = null,
    };

    pub fn begin(self: Indexer) Error!void {
        if (self.vtable.begin) |f| return f(self.ptr);
    }
    pub fn commit(self: Indexer) Error!void {
        if (self.vtable.commit) |f| return f(self.ptr);
    }
    pub fn rollback(self: Indexer) Error!void {
        if (self.vtable.rollback) |f| return f(self.ptr);
    }

    pub fn add(self: Indexer, id: doc.Id, d: doc.Document) Error!void {
        return self.vtable.add(self.ptr, id, d);
    }
    pub fn remove(self: Indexer, id: doc.Id) Error!void {
        return self.vtable.remove(self.ptr, id);
    }
    pub fn clear(self: Indexer) Error!void {
        return self.vtable.clear(self.ptr);
    }
    pub fn check(self: Indexer) Error!void {
        return self.vtable.check(self.ptr);
    }
};
