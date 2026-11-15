//! The list of configured sources, shared by the parts of a running server
//! that read it (the job manager and the administration interface) and
//! replaceable while it runs, so that editing sources from the interface takes
//! effect without a restart.
//!
//! A replacement keeps the earlier configurations alive until `deinit`, so a
//! slice obtained from `snapshot` stays valid for as long as its holder needs
//! it (an import already running keeps using the source it started with).
//! Edits are rare, so the memory kept is small.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    current: []const config.Source,
    /// Every configuration that was ever current and was loaded through
    /// `replace` (the first one belongs to the caller of `init`).
    held: std.ArrayList(*config.Config) = .empty,

    /// `initial` must outlive the store.
    pub fn init(gpa: Allocator, io: Io, initial: []const config.Source) Store {
        return .{ .gpa = gpa, .io = io, .current = initial };
    }

    pub fn deinit(self: *Store) void {
        for (self.held.items) |c| {
            c.deinit();
            self.gpa.destroy(c);
        }
        self.held.deinit(self.gpa);
        self.* = undefined;
    }

    /// The current sources. Valid until `deinit`.
    pub fn snapshot(self: *Store) []const config.Source {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.current;
    }

    /// Makes the sources of `cfg` current and takes ownership of it.
    pub fn replace(self: *Store, cfg: config.Config) Allocator.Error!void {
        const boxed = try self.gpa.create(config.Config);
        errdefer self.gpa.destroy(boxed);
        boxed.* = cfg;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.held.append(self.gpa, boxed);
        self.current = boxed.sources;
    }
};

const testing = std.testing;

test "snapshots stay valid across replacements" {
    var d: config.Diagnostic = .{};
    var store = Store.init(testing.allocator, testing.io, &.{});
    defer store.deinit();
    const before = store.snapshot();
    try testing.expectEqual(@as(usize, 0), before.len);

    try store.replace(try config.loadFromSlice(testing.allocator, "t", "[[source]]\nname = \"a\"\nkind = \"files\"\npath = \"/x\"\n", &d));
    const one = store.snapshot();
    try store.replace(try config.loadFromSlice(testing.allocator, "t", "[[source]]\nname = \"b\"\nkind = \"files\"\npath = \"/y\"\n", &d));
    const two = store.snapshot();
    try testing.expectEqualStrings("a", one[0].name); // the older snapshot is still readable
    try testing.expectEqualStrings("b", two[0].name);
}
