//! Making the vectors of semantic search (docs/decisions/0038): every document that has retained text and no vector yet
//! for the configured model is sent, a batch at a time, to the embedding server, and its vector is stored. Run by
//! `dksearch embed` and by the *Make vectors* button of the administration interface. It reads the document records
//! and the stored texts and writes only `vectors.db`, and it can be stopped and run again: what is done is kept.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const doc = @import("document.zig");
const embed = @import("embed.zig");
const storage = @import("storage.zig");
const connector = @import("connector.zig");

pub const Deps = struct {
    gpa: Allocator,
    io: Io,
    client: *embed.Client,
    store: *embed.Store,
    settings: embed.Settings,
    documents: storage.DocumentStore,
    content: storage.ContentStore,
    /// For cancelling and for the count of vectors made so far (shown while it runs); null for none.
    control: ?*connector.Control = null,
    /// Told after each batch with the number of vectors made so far (the command prints it).
    on_batch: ?*const fn (ctx: ?*anyopaque, made: u64) void = null,
    ctx: ?*anyopaque = null,
};

pub const Result = struct {
    made: u64 = 0,
    skipped: u64 = 0,
    failed: ?embed.Error = null,
    cancelled: bool = false,
};

const Work = struct {
    d: Deps,
    batch_arena: std.heap.ArenaAllocator,
    ids: std.ArrayList(doc.Id) = .empty,
    texts: std.ArrayList([]const u8) = .empty,
    res: Result = .{},

    fn visit(ptr: *anyopaque, rec: storage.Record) storage.Error!void {
        const self: *Work = @ptrCast(@alignCast(ptr));
        if (self.d.control) |c| if (c.isCancelled()) {
            self.res.cancelled = true;
            return error.Io;
        };
        if (self.d.store.has(rec.id, self.d.settings.vectorKey())) {
            self.res.skipped += 1;
            return;
        }
        const a = self.batch_arena.allocator();
        const text = self.d.content.get(self.d.gpa, rec.id) catch {
            self.res.skipped += 1; // no retained text
            return;
        };
        defer self.d.gpa.free(text);
        const t = self.d.settings.documentText(a, rec.meta.title, text) catch return error.OutOfMemory;
        if (std.mem.trim(u8, t, " \t\r\n").len == 0) return;
        self.ids.append(a, rec.id) catch return error.OutOfMemory;
        self.texts.append(a, t) catch return error.OutOfMemory;
        if (self.ids.items.len >= self.d.settings.batch) self.flush() catch return error.Io;
    }

    fn flush(self: *Work) !void {
        if (self.ids.items.len == 0) return;
        const a = self.batch_arena.allocator();
        const vecs = self.d.client.embed(a, self.texts.items) catch |e| {
            self.res.failed = e;
            return error.EmbedFailed;
        };
        for (self.ids.items, vecs) |id, v| self.d.store.put(id, self.d.settings.vectorKey(), v) catch return error.EmbedFailed;
        self.res.made += self.ids.items.len;
        if (self.d.control) |c| c.submitted.store(self.res.made, .monotonic);
        if (self.d.on_batch) |f| f(self.d.ctx, self.res.made);
        _ = self.batch_arena.reset(.retain_capacity);
        self.ids = .empty;
        self.texts = .empty;
    }
};

/// Makes the missing vectors. Returns what was done; a failure of the embedding server stops it with `failed` set
/// (what was made is kept), and `cancelled` says it was stopped on request.
pub fn run(d: Deps) Result {
    var work: Work = .{ .d = d, .batch_arena = .init(d.gpa) };
    defer work.batch_arena.deinit();
    d.documents.forEach(.{ .ptr = &work, .visit = Work.visit }) catch return work.res;
    work.flush() catch {};
    return work.res;
}

const testing = std.testing;
const memory = @import("memory.zig");

const nettest = @import("connectors/nettest.zig");
const build_options = @import("build_options");

test "the missing vectors are made, what is there is skipped, a failing server stops it and a stop request is honoured" {
    if (!build_options.crawler) return error.SkipZigTest;
    var srv: nettest.TestServer = undefined;
    try srv.start(&.{.{ .path = "/api/embed", .content_type = "application/json", .body = "{\"embeddings\":[[3,4]]}" }});
    defer srv.stop();
    var ub: [64]u8 = undefined;
    const url = srv.url(&ub, "");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const vec_path = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/vectors.db", .{tmp.sub_path}, 0);
    var store = try embed.Store.open(vec_path);
    defer store.close();
    var docs = memory.MemoryDocumentStore.init(testing.allocator);
    defer docs.deinit();
    var content = memory.MemoryContentStore.init(testing.allocator);
    defer content.deinit();
    for (0..4) |i| {
        var sid: [4]u8 = undefined;
        const d: doc.Document = .{ .connector = "t", .source_id = try std.fmt.bufPrint(&sid, "{d}", .{i}), .title = "t" };
        const id = d.id();
        try docs.store().upsert(.{ .id = id, .content_hash = null, .acquired_at = null, .meta = d });
        if (i != 3) try content.store().put(id, "some text of the document"); // the last one has no retained text
    }
    const settings: embed.Settings = .{ .url = url, .model = "m", .timeout_ms = 2000, .batch = 1 };
    const client = try embed.Client.init(testing.allocator, testing.io, settings);
    defer client.deinit();
    var ctl: connector.Control = .{};
    const first = run(.{ .gpa = testing.allocator, .io = testing.io, .client = client, .store = &store, .settings = settings, .documents = docs.store(), .content = content.store(), .control = &ctl });
    try testing.expectEqual(@as(u64, 3), first.made);
    try testing.expect(first.failed == null and !first.cancelled);
    try testing.expectEqual(@as(u64, 3), ctl.submitted.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), store.count("m"));
    // Run again: everything is there, nothing is asked.
    const again = run(.{ .gpa = testing.allocator, .io = testing.io, .client = client, .store = &store, .settings = settings, .documents = docs.store(), .content = content.store() });
    try testing.expectEqual(@as(u64, 0), again.made);
    // A model of another name starts afresh, and stops on a request to cancel.
    var other = settings;
    other.model = "n";
    const c2 = try embed.Client.init(testing.allocator, testing.io, other);
    defer c2.deinit();
    var stop: connector.Control = .{};
    stop.cancel();
    const stopped = run(.{ .gpa = testing.allocator, .io = testing.io, .client = c2, .store = &store, .settings = other, .documents = docs.store(), .content = content.store(), .control = &stop });
    try testing.expect(stopped.cancelled and stopped.made == 0);
    // A server that is not there fails it, and says so.
    var down = other;
    down.url = "http://127.0.0.1:1";
    down.timeout_ms = 300;
    const c3 = try embed.Client.init(testing.allocator, testing.io, down);
    defer c3.deinit();
    const failed = run(.{ .gpa = testing.allocator, .io = testing.io, .client = c3, .store = &store, .settings = down, .documents = docs.store(), .content = content.store() });
    try testing.expect(failed.failed != null and failed.made == 0);
}
