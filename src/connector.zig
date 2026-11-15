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
        /// Optional. Receives a resume position a connector reports while it
        /// runs. The position must be valid for resuming *after every
        /// document submitted so far*: restarting a run from it must not skip
        /// any document that has not been submitted yet. A sink that
        /// persists it makes crash recovery lose at most the work since the
        /// last checkpoint. `Stopped` means it could not be saved, so the
        /// connector should stop. Only valid during the call.
        checkpoint: ?*const fn (ptr: *anyopaque, position: []const u8) Error!void = null,
    };

    pub fn submit(self: Sink, doc: Document) Error!void {
        return self.vtable.submit(self.ptr, doc);
    }

    /// Reports a resume position. A no-op if the sink does not keep them.
    pub fn checkpoint(self: Sink, position: []const u8) Error!void {
        if (self.vtable.checkpoint) |f| return f(self.ptr, position);
    }
};

/// Why a connector refused an item, for the connectors that can say. A
/// refusal without a reason is still counted in `Control.rejected`.
pub const Reason = enum {
    /// The site's robots.txt disallows the page, or could not be read.
    robots,
    /// Could not connect, or the connection broke or timed out.
    network,
    /// A TLS certificate that did not verify.
    certificate,
    /// An answer other than success (404, 500, ...), or a bad response.
    http_status,
    /// A media type that is not indexed (PDF, image, ...).
    wrong_type,
    /// Larger than the size cap.
    too_large,
    /// An encoding the connector does not understand.
    encoding,
    /// No text, or text the page asked not to be indexed (`noindex`).
    no_text,
    /// A redirect that was refused (loop, too long, other site, bad target).
    redirect,
    /// A limit of the run (pages, sites) was reached, or the URL is unusable.
    limit,
};

pub const reason_count = std.enums.values(Reason).len;

/// A count per `Reason`.
pub const ReasonCounts = [reason_count]u64;

/// "robots=3, network=1" for the non-zero counts; empty if there are none.
pub fn formatReasons(counts: ReasonCounts, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var first = true;
    for (std.enums.values(Reason), 0..) |r, i| {
        if (counts[i] > 0) {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.print("{s}={d}", .{ @tagName(r), counts[i] });
        }
    }
}

/// The inverse of `formatReasons`; entries it does not know are ignored.
pub fn parseReasons(text: []const u8) ReasonCounts {
    var counts: ReasonCounts = @splat(0);
    var it = std.mem.tokenizeAny(u8, text, ", ");
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const r = std.meta.stringToEnum(Reason, pair[0..eq]) orelse continue;
        counts[@backingInt(r)] = std.fmt.parseInt(u64, pair[eq + 1 ..], 10) catch continue;
    }
    return counts;
}

/// Cooperative control and progress, shared between the runner and a connector.
pub const Control = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    /// Documents the connector handed to the sink and the sink accepted.
    submitted: std.atomic.Value(u64) = .init(0),
    /// Items the connector itself refused before submitting them (too large,
    /// unreadable, malformed). Documents the *sink* rejects are not counted
    /// here: the sink counts those.
    rejected: std.atomic.Value(u64) = .init(0),
    /// How many of `rejected` had which reason (only those a connector gave).
    reasons: [reason_count]std.atomic.Value(u64) = @splat(.init(0)),
    /// See `setProgress`.
    progress_done: std.atomic.Value(u64) = .init(0),
    progress_total: std.atomic.Value(u64) = .init(0),

    /// Counts one refused item, with its reason.
    pub fn reject(self: *Control, why: Reason) void {
        _ = self.rejected.fetchAdd(1, .monotonic);
        _ = self.reasons[@backingInt(why)].fetchAdd(1, .monotonic);
    }

    /// How far along the run is, for display: `done` of `total` units (bytes,
    /// files, items: the connector chooses). A total of 0 means unknown.
    pub fn setProgress(self: *Control, done: u64, total: u64) void {
        self.progress_done.store(done, .monotonic);
        self.progress_total.store(total, .monotonic);
    }

    pub fn reasonCounts(self: *const Control) ReasonCounts {
        var out: ReasonCounts = undefined;
        for (&out, 0..) |*o, i| o.* = self.reasons[i].load(.monotonic);
        return out;
    }

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

/// Whether an item the pipeline holds is still in its source.
pub const Presence = enum {
    present,
    /// Certainly gone: the source is readable and the item is not in it.
    gone,
    /// Cannot tell (source unreadable, unsupported). Never treated as gone.
    unknown,
};

pub const Connector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        info: *const fn (ptr: *anyopaque) Info,
        /// Emit documents until the source is exhausted, `control` is
        /// cancelled, or the sink stops. Must check `control.isCancelled()`
        /// regularly. Should count accepted submits in `control.submitted`
        /// and items it refuses itself in `control.rejected`.
        run: *const fn (ptr: *anyopaque, sink: Sink, control: *Control, resume_from: ?[]const u8) RunError!Outcome,
        /// Optional: lets `import --prune` remove documents whose items left
        /// the source. Connectors without it never have anything pruned.
        exists: ?*const fn (ptr: *anyopaque, source_id: []const u8) Presence = null,
    };

    pub fn exists(self: Connector, source_id: []const u8) Presence {
        const f = self.vtable.exists orelse return .unknown;
        return f(self.ptr, source_id);
    }

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
                error.Rejected => continue, // the sink counts its own rejections
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

test "records the sink rejects do not stop the run" {
    var fx: FixtureConnector = .{ .items = &.{ "a", "bad", "c" } };
    var cs: CollectingSink = .{ .reject_id = "bad" };
    defer cs.seen.deinit(testing.allocator);
    var ctl: Control = .{};

    const out = try fx.connector().run(cs.sink(), &ctl, null);
    try testing.expect(!out.interrupted);
    try testing.expectEqual(@as(usize, 2), cs.seen.items.len);
    try testing.expectEqual(@as(u64, 2), ctl.submitted.load(.monotonic));
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
