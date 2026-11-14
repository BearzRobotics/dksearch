//! The connector interface.
//!
//! A connector acquires source material, parses it, and emits normalized
//! `Document` records to a `Sink`. It never sees the index, the stores or the
//! HTTP layer; the shared ingestion pipeline owns the Sink and decides what
//! happens to each record (validation, dedup, storage, indexing).

const std = @import("std");
const Document = @import("document.zig").Document;

/// Receives documents from a connector. The pipeline implements this.
pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{
        /// The pipeline rejected this record; the connector should record it
        /// as a failure and may continue.
        Rejected,
        /// The pipeline cannot accept more (shutting down, storage full).
        /// The connector should stop and report a checkpoint if it can.
        Stopped,
        OutOfMemory,
    };

    pub const VTable = struct {
        /// The Document and everything it points to is only valid for the
        /// duration of the call; the sink copies what it keeps.
        submit: *const fn (ptr: *anyopaque, doc: Document) Error!void,
    };

    pub fn submit(self: Sink, doc: Document) Error!void {
        return self.vtable.submit(self.ptr, doc);
    }
};

/// Cooperative control and progress, shared between the runner and a connector.
pub const Control = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    submitted: std.atomic.Value(u64) = .init(0),
    rejected: std.atomic.Value(u64) = .init(0),

    pub fn cancel(self: *Control) void {
        self.cancelled.store(true, .release);
    }
    pub fn isCancelled(self: *const Control) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const Info = struct {
    /// Connector type, e.g. "gutenberg", "wikipedia-dump", "sitemap".
    kind: []const u8,
    /// True if it cannot run without internet access. Such connectors must
    /// fail with `error.Offline` and never block the rest of the system.
    requires_network: bool,
    /// True if `run` honors `resume_from` and reports `checkpoint`.
    resumable: bool,
};

pub const RunError = error{
    /// A network-requiring connector has no network. Not a defect.
    Offline,
    /// The connector's configuration or inputs are unusable.
    InvalidSource,
    /// The source returned data the connector could not parse at all.
    SourceFailed,
    OutOfMemory,
};

pub const Outcome = struct {
    /// True if the run stopped early because `Control.cancel` was called or
    /// the sink returned `Stopped`.
    interrupted: bool = false,
    /// Opaque position to pass as `resume_from` next time. Borrowed from the
    /// connector and valid until its next call. Null if not resumable or done.
    checkpoint: ?[]const u8 = null,
};

pub const Connector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        info: *const fn (ptr: *anyopaque) Info,
        /// Emit documents until the source is exhausted, `control` is
        /// cancelled, or the sink stops. Must check `control.isCancelled()`
        /// regularly. Must count each submit in `control`.
        run: *const fn (ptr: *anyopaque, sink: Sink, control: *Control, resume_from: ?[]const u8) RunError!Outcome,
    };

    pub fn info(self: Connector) Info {
        return self.vtable.info(self.ptr);
    }

    pub fn run(self: Connector, sink: Sink, control: *Control, resume_from: ?[]const u8) RunError!Outcome {
        return self.vtable.run(self.ptr, sink, control, resume_from);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Fixture connector: emits `items` in order, one document each.
const FixtureConnector = struct {
    items: []const []const u8,
    position_buf: [20]u8 = undefined,

    fn info(_: *anyopaque) Info {
        return .{ .kind = "fixture", .requires_network = false, .resumable = true };
    }

    fn run(ptr: *anyopaque, sink: Sink, control: *Control, resume_from: ?[]const u8) RunError!Outcome {
        const self: *FixtureConnector = @ptrCast(@alignCast(ptr));
        var i: usize = 0;
        if (resume_from) |r| i = std.fmt.parseInt(usize, r, 10) catch return error.InvalidSource;
        while (i < self.items.len) : (i += 1) {
            if (control.isCancelled()) return self.interrupted(i);
            sink.submit(.{ .connector = "fixture", .source_id = self.items[i], .text = self.items[i] }) catch |e| switch (e) {
                error.Rejected => {
                    _ = control.rejected.fetchAdd(1, .monotonic);
                    continue;
                },
                error.Stopped => return self.interrupted(i),
                error.OutOfMemory => return error.OutOfMemory,
            };
            _ = control.submitted.fetchAdd(1, .monotonic);
        }
        return .{};
    }

    fn interrupted(self: *FixtureConnector, at: usize) Outcome {
        const s = std.fmt.bufPrint(&self.position_buf, "{d}", .{at}) catch unreachable;
        return .{ .interrupted = true, .checkpoint = s };
    }

    fn connector(self: *FixtureConnector) Connector {
        return .{ .ptr = self, .vtable = &.{ .info = info, .run = run } };
    }
};

/// Test sink: records source ids; optionally cancels after N or rejects one.
const CollectingSink = struct {
    seen: std.ArrayList([]const u8) = .empty,
    control: ?*Control = null,
    cancel_after: usize = std.math.maxInt(usize),
    reject_id: ?[]const u8 = null,

    fn submit(ptr: *anyopaque, doc: Document) Sink.Error!void {
        const self: *CollectingSink = @ptrCast(@alignCast(ptr));
        if (self.reject_id) |r| if (std.mem.eql(u8, r, doc.source_id)) return error.Rejected;
        try self.seen.append(testing.allocator, doc.source_id);
        if (self.seen.items.len >= self.cancel_after) self.control.?.cancel();
    }

    fn sink(self: *CollectingSink) Sink {
        return .{ .ptr = self, .vtable = &.{ .submit = submit } };
    }
};

test "connector emits all documents to the sink" {
    var fx: FixtureConnector = .{ .items = &.{ "a", "b", "c" } };
    var cs: CollectingSink = .{};
    defer cs.seen.deinit(testing.allocator);
    var ctl: Control = .{};

    const c = fx.connector();
    try testing.expect(!c.info().requires_network);
    const out = try c.run(cs.sink(), &ctl, null);

    try testing.expect(!out.interrupted);
    try testing.expectEqual(@as(usize, 3), cs.seen.items.len);
    try testing.expectEqual(@as(u64, 3), ctl.submitted.load(.monotonic));
}

test "rejected records are counted and do not stop the run" {
    var fx: FixtureConnector = .{ .items = &.{ "a", "bad", "c" } };
    var cs: CollectingSink = .{ .reject_id = "bad" };
    defer cs.seen.deinit(testing.allocator);
    var ctl: Control = .{};

    const out = try fx.connector().run(cs.sink(), &ctl, null);
    try testing.expect(!out.interrupted);
    try testing.expectEqual(@as(usize, 2), cs.seen.items.len);
    try testing.expectEqual(@as(u64, 1), ctl.rejected.load(.monotonic));
}

test "cancellation yields a checkpoint and the run resumes where it stopped" {
    var fx: FixtureConnector = .{ .items = &.{ "a", "b", "c", "d" } };
    var cs: CollectingSink = .{ .cancel_after = 2 };
    defer cs.seen.deinit(testing.allocator);
    var ctl: Control = .{};
    cs.control = &ctl;

    const first = try fx.connector().run(cs.sink(), &ctl, null);
    try testing.expect(first.interrupted);
    try testing.expectEqual(@as(usize, 2), cs.seen.items.len);

    var ctl2: Control = .{};
    cs.cancel_after = std.math.maxInt(usize);
    const second = try fx.connector().run(cs.sink(), &ctl2, first.checkpoint);
    try testing.expect(!second.interrupted);
    try testing.expectEqual(@as(usize, 4), cs.seen.items.len);
    try testing.expectEqualStrings("c", cs.seen.items[2]);
}

test "bad checkpoint is an InvalidSource error" {
    var fx: FixtureConnector = .{ .items = &.{"a"} };
    var cs: CollectingSink = .{};
    defer cs.seen.deinit(testing.allocator);
    var ctl: Control = .{};
    try testing.expectError(error.InvalidSource, fx.connector().run(cs.sink(), &ctl, "not-a-number"));
}
