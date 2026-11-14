//! The registry of bundled connectors: maps a source's `kind` to the code
//! that validates and runs it.
//!
//! Connectors are optional (docs/decisions/0007): with no `[[source]]` in the
//! configuration none of this runs, and nothing here is needed to serve
//! search. Bundled connectors use the same `Connector` interface as any other
//! and receive no private access to the pipeline or stores.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const api = @import("connector.zig");

pub const files = @import("connectors/files.zig");
pub const gutenberg = @import("connectors/gutenberg.zig");

/// Every kind this build knows, for help text and error messages.
pub const kinds = [_][]const u8{ files.kind, gutenberg.kind };

/// A connector instance of any bundled kind.
pub const Instance = union(enum) {
    files: files.FilesConnector,
    gutenberg: gutenberg.GutenbergConnector,

    pub fn deinit(self: *Instance) void {
        switch (self.*) {
            inline else => |*c| c.deinit(),
        }
    }

    pub fn connector(self: *Instance) api.Connector {
        return switch (self.*) {
            inline else => |*c| c.connector(),
        };
    }
};

/// Checks one source: its kind is known and its options are valid for that
/// kind. Touches nothing outside memory, so it is safe in `check-config`.
pub fn validate(source: config.Source, diag: *config.Diagnostic) config.Error!void {
    if (std.mem.eql(u8, source.kind, files.kind)) return files.validate(source, diag);
    if (std.mem.eql(u8, source.kind, gutenberg.kind)) return gutenberg.validate(source, diag);
    var kbuf: [128]u8 = undefined;
    diag.set("", std.fmt.bufPrint(&kbuf, "source[{s}].kind", .{source.name}) catch "kind", "unknown connector kind \"{s}\" (this build has: files, gutenberg)", .{source.kind});
    return error.InvalidValue;
}

/// Validates every source (enabled or not, so a typo in a disabled source is
/// still caught) and returns the first problem. The file name is filled in
/// by the caller.
pub fn validateAll(sources: []const config.Source, diag: *config.Diagnostic) config.Error!void {
    for (sources) |s| try validate(s, diag);
}

/// Builds a connector for `source`, which must have passed `validate`.
pub fn create(gpa: Allocator, io: Io, source: config.Source) Allocator.Error!Instance {
    if (std.mem.eql(u8, source.kind, files.kind)) return .{ .files = try files.FilesConnector.init(gpa, io, source) };
    if (std.mem.eql(u8, source.kind, gutenberg.kind)) return .{ .gutenberg = try gutenberg.GutenbergConnector.init(gpa, io, source) };
    unreachable; // `validate` rejects unknown kinds
}

const testing = std.testing;

test "unknown kinds are reported with the source name" {
    var d: config.Diagnostic = .{};
    const s: config.Source = .{ .name = "mystery", .kind = "carrier-pigeon" };
    try testing.expectError(error.InvalidValue, validate(s, &d));
    try testing.expectEqualStrings("source[mystery].kind", d.key());
    try testing.expect(std.mem.indexOf(u8, d.message(), "carrier-pigeon") != null);
}

test "validateAll accepts no sources, and checks disabled ones too" {
    var d: config.Diagnostic = .{};
    try validateAll(&.{}, &d);
    const bad: config.Source = .{ .name = "off", .kind = "files", .enabled = false }; // no path
    try testing.expectError(error.InvalidValue, validateAll(&.{bad}, &d));
}

test "create builds a runnable connector" {
    const s: config.Source = .{ .name = "n", .kind = "files", .options = &.{.{ .key = "path", .value = .{ .string = "." } }} };
    var d: config.Diagnostic = .{};
    try validate(s, &d);
    var inst = try create(testing.allocator, testing.io, s);
    defer inst.deinit();
    try testing.expectEqualStrings("files", inst.connector().info().kind);
    try testing.expect(!inst.connector().info().requires_network);
}
