//! Editing the `[[source]]` tables of a configuration file.
//!
//! The file is parsed with the TOML library, changed through its document
//! model (so every value is escaped properly and comments elsewhere in the
//! file are kept), written back to text, and that text is validated as a whole
//! (syntax, every setting, every source's options) before anything is written
//! to disk. `writeFile` then replaces the file atomically and keeps the
//! previous version as `FILE.bak`.
//!
//! Only sources are edited here; every other setting is changed by hand and
//! takes effect at the next start (docs/decisions/0022).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const toml = @import("toml");
const config = @import("config.zig");
const connectors = @import("connectors.zig");

/// What the edit form collects for one source.
pub const Spec = struct {
    name: []const u8,
    kind: []const u8,
    enabled: bool = true,
    retain_text: bool = true,
    /// "unknown", "allowed", "restricted" or "forbidden"; null keeps the connector's default.
    rights: ?[]const u8 = null,
    /// Ranking boost in percent (100 = none).
    boost: u32 = 100,
    /// Let peers with a key copy this source's text.
    share: bool = false,
    /// How often to import by itself ("daily", "6h", ...); empty or null: never.
    schedule: ?[]const u8 = null,
    /// The connector's options as TOML, one `key = value` per line.
    options: []const u8 = "",
};

pub const Edit = union(enum) {
    /// Add a source (`original` null) or replace the source named `original`.
    save: struct { original: ?[]const u8, spec: Spec },
    delete: []const u8,
    set_enabled: struct { name: []const u8, enabled: bool },
};

pub const Error = error{
    OutOfMemory,
    /// The edit cannot be made; see `Problem.message`.
    Invalid,
};

/// One setting of a table other than the sources (`[search]`, `[server]`, `[admin]`): set to a
/// value, or (`value` null) removed so that its default applies again.
pub const Setting = struct {
    table: []const u8,
    key: []const u8,
    value: ?union(enum) { string: []const u8, integer: i64, boolean: bool } = null,
};

/// Why an edit was refused, in words for the person who asked.
pub const Problem = struct {
    buf: [400]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Problem) []const u8 {
        return self.buf[0..self.len];
    }
    fn set(self: *Problem, comptime fmt: []const u8, args: anytype) Error {
        self.len = if (std.fmt.bufPrint(&self.buf, fmt, args)) |w| w.len else |_| self.buf.len;
        return error.Invalid;
    }
};

const reserved = [_][]const u8{ "name", "kind", "enabled", "retain_text", "rights", "boost", "schedule", "share" };

/// Applies `edit` to the configuration text and returns the new text (caller
/// frees it). The result has been validated as a whole configuration.
pub fn apply(gpa: Allocator, text: []const u8, edit: Edit, problem: *Problem) Error![]u8 {
    var tdiag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(gpa, text, .{}, &tdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("the configuration file has a syntax error (line {d}: {s}) and cannot be edited here; fix it by hand first", .{ tdiag.line, tdiag.message }),
    };
    defer doc.deinit();
    const a = doc.allocator();

    // The array of [[source]] tables, created if the file has none.
    const array: *toml.Array = blk: {
        if (doc.root.getPtr("source")) |v| switch (v.*) {
            .array => |arr| {
                if (!arr.is_table_array) return problem.set("this file defines its sources in a form the editor cannot change (not [[source]] tables); edit it by hand", .{});
                break :blk arr;
            },
            else => return problem.set("`source` in this file is not a list of [[source]] tables; edit it by hand", .{}),
        };
        const arr = try a.create(toml.Array);
        arr.* = .{ .is_table_array = true };
        try doc.root.entries.put(a, try doc.dupe("source"), .{ .array = arr });
        break :blk arr;
    };

    switch (edit) {
        .delete => |name| {
            const i = indexOf(array, name) orelse return problem.set("there is no source named \"{s}\"", .{name});
            _ = array.items.orderedRemove(i);
        },
        .set_enabled => |se| {
            const i = indexOf(array, se.name) orelse return problem.set("there is no source named \"{s}\"", .{se.name});
            const t = array.items.items[i].table;
            if (se.enabled) {
                _ = t.entries.orderedRemove("enabled");
            } else {
                try t.entries.put(a, try doc.dupe("enabled"), .{ .boolean = false });
            }
        },
        .save => |sv| {
            const spec = sv.spec;
            if (!config.validSourceName(spec.name)) return problem.set("the name must be 1-64 characters of a-z, 0-9, '-' and '_', starting with a letter or digit", .{});
            if (spec.kind.len == 0) return problem.set("choose a kind", .{});
            const existing = if (sv.original) |o| (indexOf(array, o) orelse return problem.set("there is no source named \"{s}\"", .{o})) else null;
            if (indexOf(array, spec.name)) |same| {
                if (existing == null or existing.? != same) return problem.set("a source named \"{s}\" already exists", .{spec.name});
            }
            const t: *toml.Table = if (existing) |i| blk: {
                const old = array.items.items[i].table;
                old.entries.clearRetainingCapacity();
                old.key_comments.clearRetainingCapacity();
                break :blk old;
            } else blk: {
                const nt = try a.create(toml.Table);
                nt.* = .{ .kind = .explicit };
                try array.items.append(a, .{ .table = nt });
                break :blk nt;
            };
            try t.entries.put(a, try doc.dupe("name"), .{ .string = try doc.dupe(spec.name) });
            try t.entries.put(a, try doc.dupe("kind"), .{ .string = try doc.dupe(spec.kind) });
            if (!spec.enabled) try t.entries.put(a, try doc.dupe("enabled"), .{ .boolean = false });
            if (!spec.retain_text) try t.entries.put(a, try doc.dupe("retain_text"), .{ .boolean = false });
            if (spec.schedule) |sc| if (sc.len > 0) try t.entries.put(a, try doc.dupe("schedule"), .{ .string = try doc.dupe(sc) });
            if (spec.boost != 100) try t.entries.put(a, try doc.dupe("boost"), .{ .integer = @intCast(spec.boost) });
            if (spec.share) try t.entries.put(a, try doc.dupe("share"), .{ .boolean = true });
            if (spec.rights) |r| if (r.len > 0) try t.entries.put(a, try doc.dupe("rights"), .{ .string = try doc.dupe(r) });

            // The options: TOML text, scalars only, none of the fields above.
            var odiag: toml.Diagnostic = .{};
            var opts = toml.Document.parse(gpa, spec.options, .{ .max_bytes = 16 * 1024, .max_depth = 4 }, &odiag) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return problem.set("the options are not valid TOML (line {d}: {s}); write one `key = value` per line, text in double quotes", .{ odiag.line, odiag.message }),
            };
            defer opts.deinit();
            var it = opts.root.entries.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                for (reserved) |r| if (std.mem.eql(u8, key, r)) return problem.set("\"{s}\" is set with its own field, not in the options", .{key});
                const v: toml.Value = switch (e.value_ptr.*) {
                    .string => |s| .{ .string = try doc.dupe(s) },
                    .integer => |n| .{ .integer = n },
                    .boolean => |b| .{ .boolean = b },
                    else => return problem.set("option \"{s}\": only text, whole numbers and true/false are allowed", .{key}),
                };
                try t.entries.put(a, try doc.dupe(key), v);
            }
        },
    }

    // An array left empty would write nothing; drop the key so the file stays tidy.
    if (array.items.items.len == 0) _ = doc.root.entries.orderedRemove("source");

    const out = doc.toOwnedString(gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("the new configuration could not be written", .{}),
    };
    errdefer gpa.free(out);
    try validate(gpa, out, problem);
    return out;
}

/// What the Add-a-peer form collects.
pub const PeerSpec = struct {
    name: []const u8,
    url: []const u8,
    /// The file the peer's key is read from; null keeps what the peer has (a key given inline stays too).
    key_file: ?[]const u8 = null,
    timeout_ms: u32 = 1500,
    enabled: bool = true,
};

pub const PeerEdit = union(enum) {
    /// Add a peer (`original` null) or replace the peer named `original`.
    save: struct { original: ?[]const u8, spec: PeerSpec },
    delete: []const u8,
    set_enabled: struct { name: []const u8, enabled: bool },
};

/// Applies `edit` to the `[[peer]]` tables of the configuration text, like `apply` does for sources: the result is
/// validated as a whole (so a peer without a `[node] name`, a bad address, a duplicate name are refused with the
/// reason) and comments elsewhere are kept. A key written inline in the file is kept when a peer is saved.
pub fn applyPeer(gpa: Allocator, text: []const u8, edit: PeerEdit, problem: *Problem) Error![]u8 {
    var tdiag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(gpa, text, .{}, &tdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("the configuration file has a syntax error (line {d}: {s}) and cannot be edited here; fix it by hand first", .{ tdiag.line, tdiag.message }),
    };
    defer doc.deinit();
    const a = doc.allocator();
    const array: *toml.Array = blk: {
        if (doc.root.getPtr("peer")) |v| switch (v.*) {
            .array => |arr| {
                if (!arr.is_table_array) return problem.set("this file defines its peers in a form the editor cannot change (not [[peer]] tables); edit it by hand", .{});
                break :blk arr;
            },
            else => return problem.set("`peer` in this file is not a list of [[peer]] tables; edit it by hand", .{}),
        };
        const arr = try a.create(toml.Array);
        arr.* = .{ .is_table_array = true };
        try doc.root.entries.put(a, try doc.dupe("peer"), .{ .array = arr });
        break :blk arr;
    };
    switch (edit) {
        .delete => |name| {
            const i = indexOf(array, name) orelse return problem.set("there is no peer named \"{s}\"", .{name});
            _ = array.items.orderedRemove(i);
        },
        .set_enabled => |se| {
            const i = indexOf(array, se.name) orelse return problem.set("there is no peer named \"{s}\"", .{se.name});
            const t = array.items.items[i].table;
            if (se.enabled) {
                _ = t.entries.orderedRemove("enabled");
            } else {
                try t.entries.put(a, try doc.dupe("enabled"), .{ .boolean = false });
            }
        },
        .save => |sv| {
            const spec = sv.spec;
            if (!config.validSourceName(spec.name)) return problem.set("the name must be 1-64 characters of a-z, 0-9, '-' and '_', starting with a letter or digit", .{});
            const existing = if (sv.original) |o| (indexOf(array, o) orelse return problem.set("there is no peer named \"{s}\"", .{o})) else null;
            if (indexOf(array, spec.name)) |same| {
                if (existing == null or existing.? != same) return problem.set("a peer named \"{s}\" already exists", .{spec.name});
            }
            // What a saved peer keeps from before: an inline key and a key file (unless a new key file is given).
            var keep_key: ?toml.Value = null;
            var keep_key_file: ?toml.Value = null;
            const t: *toml.Table = if (existing) |i| blk: {
                const old = array.items.items[i].table;
                keep_key = old.get("key");
                keep_key_file = old.get("key_file");
                old.entries.clearRetainingCapacity();
                old.key_comments.clearRetainingCapacity();
                break :blk old;
            } else blk: {
                const nt = try a.create(toml.Table);
                nt.* = .{ .kind = .explicit };
                try array.items.append(a, .{ .table = nt });
                break :blk nt;
            };
            try t.entries.put(a, try doc.dupe("name"), .{ .string = try doc.dupe(spec.name) });
            try t.entries.put(a, try doc.dupe("url"), .{ .string = try doc.dupe(spec.url) });
            if (spec.key_file) |kf| {
                if (kf.len > 0) try t.entries.put(a, try doc.dupe("key_file"), .{ .string = try doc.dupe(kf) });
            } else {
                if (keep_key) |k| try t.entries.put(a, try doc.dupe("key"), k);
                if (keep_key_file) |k| try t.entries.put(a, try doc.dupe("key_file"), k);
            }
            if (spec.timeout_ms != 1500) try t.entries.put(a, try doc.dupe("timeout_ms"), .{ .integer = @intCast(spec.timeout_ms) });
            if (!spec.enabled) try t.entries.put(a, try doc.dupe("enabled"), .{ .boolean = false });
        },
    }
    if (array.items.items.len == 0) _ = doc.root.entries.orderedRemove("peer");
    const out = doc.toOwnedString(gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("the new configuration could not be written", .{}),
    };
    errdefer gpa.free(out);
    try validate(gpa, out, problem);
    return out;
}

/// What the Add-a-collection form collects.
pub const CollectionSpec = struct {
    name: []const u8,
    description: []const u8 = "",
    sources: []const []const u8,
};

pub const CollectionEdit = union(enum) {
    /// Add a collection (`original` null) or replace the one named `original`.
    save: struct { original: ?[]const u8, spec: CollectionSpec },
    delete: []const u8,
};

/// Applies `edit` to the `[[collection]]` tables of the configuration text, validated as a whole (unknown sources,
/// a name that is a source's, a collection still named in `[access]`, ... are refused with the reason).
pub fn applyCollection(gpa: Allocator, text: []const u8, edit: CollectionEdit, problem: *Problem) Error![]u8 {
    var tdiag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(gpa, text, .{}, &tdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("the configuration file has a syntax error (line {d}: {s}) and cannot be edited here; fix it by hand first", .{ tdiag.line, tdiag.message }),
    };
    defer doc.deinit();
    const a = doc.allocator();
    const array: *toml.Array = blk: {
        if (doc.root.getPtr("collection")) |v| switch (v.*) {
            .array => |arr| {
                if (!arr.is_table_array) return problem.set("this file defines its collections in a form the editor cannot change (not [[collection]] tables); edit it by hand", .{});
                break :blk arr;
            },
            else => return problem.set("`collection` in this file is not a list of [[collection]] tables; edit it by hand", .{}),
        };
        const arr = try a.create(toml.Array);
        arr.* = .{ .is_table_array = true };
        try doc.root.entries.put(a, try doc.dupe("collection"), .{ .array = arr });
        break :blk arr;
    };
    switch (edit) {
        .delete => |name| {
            const i = indexOf(array, name) orelse return problem.set("there is no collection named \"{s}\"", .{name});
            _ = array.items.orderedRemove(i);
        },
        .save => |sv| {
            const spec = sv.spec;
            if (!config.validSourceName(spec.name)) return problem.set("the name must be 1-64 characters of a-z, 0-9, '-' and '_', starting with a letter or digit", .{});
            if (spec.sources.len == 0) return problem.set("tick at least one source", .{});
            const existing = if (sv.original) |o| (indexOf(array, o) orelse return problem.set("there is no collection named \"{s}\"", .{o})) else null;
            if (indexOf(array, spec.name)) |same| {
                if (existing == null or existing.? != same) return problem.set("a collection named \"{s}\" already exists", .{spec.name});
            }
            const t: *toml.Table = if (existing) |i| blk: {
                const old = array.items.items[i].table;
                old.entries.clearRetainingCapacity();
                old.key_comments.clearRetainingCapacity();
                break :blk old;
            } else blk: {
                const nt = try a.create(toml.Table);
                nt.* = .{ .kind = .explicit };
                try array.items.append(a, .{ .table = nt });
                break :blk nt;
            };
            try t.entries.put(a, try doc.dupe("name"), .{ .string = try doc.dupe(spec.name) });
            if (spec.description.len > 0) try t.entries.put(a, try doc.dupe("description"), .{ .string = try doc.dupe(spec.description) });
            const list = try a.create(toml.Array);
            list.* = .{};
            for (spec.sources) |s| try list.items.append(a, .{ .string = try doc.dupe(s) });
            try t.entries.put(a, try doc.dupe("sources"), .{ .array = list });
        },
    }
    if (array.items.items.len == 0) _ = doc.root.entries.orderedRemove("collection");
    const out = doc.toOwnedString(gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("the new configuration could not be written", .{}),
    };
    errdefer gpa.free(out);
    try validate(gpa, out, problem);
    return out;
}

/// Applies changes to settings (outside the `[[source]]` tables) and returns the new configuration
/// text, validated as a whole like `apply`. Comments elsewhere in the file are kept.
pub fn applySettings(gpa: Allocator, text: []const u8, changes: []const Setting, problem: *Problem) Error![]u8 {
    var tdiag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(gpa, text, .{}, &tdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("the configuration file has a syntax error (line {d}: {s}) and cannot be edited here; fix it by hand first", .{ tdiag.line, tdiag.message }),
    };
    defer doc.deinit();
    for (changes) |c| {
        if (c.value) |v| {
            const value: toml.Value = switch (v) {
                .string => |sv| .{ .string = try doc.dupe(sv) },
                .integer => |n| .{ .integer = n },
                .boolean => |b| .{ .boolean = b },
            };
            doc.set(&.{ c.table, c.key }, value) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotATable => return problem.set("`{s}` in this file is not a table; edit it by hand", .{c.table}),
            };
        } else if (doc.root.getTable(c.table)) |t| {
            _ = t.remove(c.key);
            if (t.count() == 0) _ = doc.root.remove(c.table);
        }
    }
    const out = doc.toOwnedString(gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("the new configuration could not be written", .{}),
    };
    errdefer gpa.free(out);
    try validate(gpa, out, problem);
    return out;
}

/// The current value of `table.key` in the configuration text, as text (a string without quotes, a
/// number, "true" or "false"), or null if it is not set.
pub fn settingText(arena: Allocator, text: []const u8, table: []const u8, key: []const u8) Allocator.Error!?[]const u8 {
    var doc = toml.Document.parse(arena, text, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer doc.deinit();
    const t = doc.root.getTable(table) orelse return null;
    const v = t.get(key) orelse return null;
    return switch (v) {
        .string => |sv| try arena.dupe(u8, sv),
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .boolean => |b| if (b) "true" else "false",
        else => null,
    };
}

fn indexOf(array: *const toml.Array, name: []const u8) ?usize {
    for (array.items.items, 0..) |v, i| switch (v) {
        .table => |t| if (t.getString("name")) |n| if (std.mem.eql(u8, n, name)) return i,
        else => {},
    };
    return null;
}

/// The whole text must load as a configuration and every source must be valid
/// for its kind, exactly as at startup.
pub fn validate(gpa: Allocator, text: []const u8, problem: *Problem) Error!void {
    var d: config.Diagnostic = .{};
    var cfg = config.loadFromSlice(gpa, "the configuration", text, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("{s}{s}{s}", .{ d.key(), if (d.key().len > 0) ": " else "", d.message() }),
    };
    defer cfg.deinit();
    connectors.validateAll(cfg.sources, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return problem.set("{s}{s}{s}", .{ d.key(), if (d.key().len > 0) ": " else "", d.message() }),
    };
}

/// The connector options of `source` as editable TOML text, one per line.
pub fn optionsText(gpa: Allocator, source: config.Source) Allocator.Error![]u8 {
    var doc = try toml.Document.init(gpa);
    defer doc.deinit();
    const a = doc.allocator();
    for (source.options) |o| {
        const v: toml.Value = switch (o.value) {
            .string => |s| .{ .string = try doc.dupe(s) },
            .integer => |n| .{ .integer = n },
            .boolean => |b| .{ .boolean = b },
        };
        try doc.root.entries.put(a, try doc.dupe(o.key), v);
    }
    return doc.toOwnedString(gpa) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => try gpa.dupe(u8, ""),
    };
}

pub const WriteError = error{ OutOfMemory, Io };

/// Replaces the file at `path` with `text`, atomically, keeping the previous
/// contents as `path.bak` and the previous permissions.
pub fn writeFile(io: Io, gpa: Allocator, path: []const u8, text: []const u8) WriteError!void {
    const cwd = Io.Dir.cwd();
    const old = cwd.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Io,
    };
    defer gpa.free(old);
    const mode = (cwd.statFile(io, path, .{}) catch return error.Io).permissions;

    const bak = std.fmt.allocPrint(gpa, "{s}.bak", .{path}) catch return error.OutOfMemory;
    defer gpa.free(bak);
    const tmp = std.fmt.allocPrint(gpa, "{s}.new", .{path}) catch return error.OutOfMemory;
    defer gpa.free(tmp);

    try replaceWith(io, bak, old, mode);
    try replaceWith(io, tmp, text, mode);
    cwd.rename(tmp, cwd, path, io) catch {
        cwd.deleteFile(io, tmp) catch {};
        return error.Io;
    };
}

fn replaceWith(io: Io, path: []const u8, data: []const u8, mode: Io.File.Permissions) WriteError!void {
    const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .permissions = mode }) catch return error.Io;
    defer f.close(io);
    f.setPermissions(io, mode) catch {};
    f.writePositionalAll(io, data, 0) catch return error.Io;
    f.sync(io) catch return error.Io;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const base =
    \\# my search
    \\[storage]
    \\data_dir = "data"   # keep it here
    \\
    \\# notes
    \\[[source]]
    \\name = "notes"
    \\kind = "files"
    \\path = "/home/me/notes"
    \\
;

test "add, update, toggle and delete a source; other comments survive" {
    var p: Problem = .{};
    const added = try apply(testing.allocator, base, .{ .save = .{ .original = null, .spec = .{
        .name = "feeds1",
        .kind = "feeds",
        .options = "path = \"/srv/feeds\"\nmax_file_bytes = 1000000\n",
        .rights = "restricted",
        .boost = 150,
        .schedule = "daily",
    } } }, &p);
    defer testing.allocator.free(added);
    try testing.expect(std.mem.indexOf(u8, added, "# my search") != null);
    try testing.expect(std.mem.indexOf(u8, added, "# keep it here") != null);
    try testing.expect(std.mem.indexOf(u8, added, "name = \"feeds1\"") != null);
    try testing.expect(std.mem.indexOf(u8, added, "rights = \"restricted\"") != null);
    try testing.expect(std.mem.indexOf(u8, added, "boost = 150") != null);
    try testing.expect(std.mem.indexOf(u8, added, "schedule = \"daily\"") != null);
    try testing.expect(std.mem.indexOf(u8, added, "max_file_bytes = 1000000") != null);

    const updated = try apply(testing.allocator, added, .{ .save = .{ .original = "feeds1", .spec = .{
        .name = "news",
        .kind = "feeds",
        .retain_text = false,
        .options = "path = \"/srv/news\"",
    } } }, &p);
    defer testing.allocator.free(updated);
    try testing.expect(std.mem.indexOf(u8, updated, "name = \"news\"") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "feeds1") == null);
    try testing.expect(std.mem.indexOf(u8, updated, "retain_text = false") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "# notes") != null); // the other source's comment is intact

    const off = try apply(testing.allocator, updated, .{ .set_enabled = .{ .name = "news", .enabled = false } }, &p);
    defer testing.allocator.free(off);
    try testing.expect(std.mem.indexOf(u8, off, "enabled = false") != null);
    const on = try apply(testing.allocator, off, .{ .set_enabled = .{ .name = "news", .enabled = true } }, &p);
    defer testing.allocator.free(on);
    try testing.expect(std.mem.indexOf(u8, on, "enabled") == null);

    const gone = try apply(testing.allocator, on, .{ .delete = "notes" }, &p);
    defer testing.allocator.free(gone);
    try testing.expect(std.mem.indexOf(u8, gone, "notes") == null or std.mem.indexOf(u8, gone, "# notes") != null);
    try testing.expect(std.mem.indexOf(u8, gone, "name = \"news\"") != null);
    const none = try apply(testing.allocator, gone, .{ .delete = "news" }, &p);
    defer testing.allocator.free(none);
    try testing.expect(std.mem.indexOf(u8, none, "[[source]]") == null);
    try testing.expect(std.mem.indexOf(u8, none, "data_dir") != null);
}

test "refused edits say why and produce nothing" {
    var p: Problem = .{};
    const cases = [_]struct { edit: Edit, why: []const u8 }{
        .{ .edit = .{ .save = .{ .original = null, .spec = .{ .name = "notes", .kind = "files", .options = "path = \"/x\"" } } }, .why = "already exists" },
        .{ .edit = .{ .save = .{ .original = null, .spec = .{ .name = "Bad Name", .kind = "files" } } }, .why = "name must be" },
        .{ .edit = .{ .save = .{ .original = null, .spec = .{ .name = "x", .kind = "carrier-pigeon" } } }, .why = "unknown connector kind" },
        .{ .edit = .{ .save = .{ .original = null, .spec = .{ .name = "x", .kind = "files", .options = "path = [1, 2]" } } }, .why = "only text, whole numbers" },
        .{ .edit = .{ .save = .{ .original = null, .spec = .{ .name = "x", .kind = "files", .options = "name = \"y\"\npath = \"/x\"" } } }, .why = "own field" },
        .{ .edit = .{ .save = .{ .original = null, .spec = .{ .name = "x", .kind = "files", .options = "this is not toml" } } }, .why = "not valid TOML" },
        .{ .edit = .{ .save = .{ .original = null, .spec = .{ .name = "x", .kind = "files", .options = "path = \"/x\"\nbogus = 1" } } }, .why = "unknown option" },
        .{ .edit = .{ .save = .{ .original = null, .spec = .{ .name = "x", .kind = "files" } } }, .why = "required" }, // no path
        .{ .edit = .{ .save = .{ .original = null, .spec = .{ .name = "x", .kind = "files", .rights = "free", .options = "path = \"/x\"" } } }, .why = "rights" },
        .{ .edit = .{ .delete = "ghost" }, .why = "no source named" },
        .{ .edit = .{ .save = .{ .original = "ghost", .spec = .{ .name = "z", .kind = "files", .options = "path = \"/x\"" } } }, .why = "no source named" },
    };
    for (cases) |c| {
        errdefer std.debug.print("case wanted: {s}; got: {s}\n", .{ c.why, p.message() });
        try testing.expectError(error.Invalid, apply(testing.allocator, base, c.edit, &p));
        try testing.expect(std.mem.indexOf(u8, p.message(), c.why) != null);
    }
    // A file that is not valid TOML is never rewritten.
    try testing.expectError(error.Invalid, apply(testing.allocator, "[storage\n", .{ .delete = "x" }, &p));
    try testing.expect(std.mem.indexOf(u8, p.message(), "syntax error") != null);
}

test "values with quotes and newlines cannot break out of the file" {
    var p: Problem = .{};
    const out = try apply(testing.allocator, "", .{ .save = .{ .original = null, .spec = .{
        .name = "evil",
        .kind = "files",
        .options = "path = \"/tmp/x\\\"\\n[admin]\\nactions = true\"",
    } } }, &p);
    defer testing.allocator.free(out);
    // It is one string value, and the result still loads with no admin table.
    var d: config.Diagnostic = .{};
    var cfg = try config.loadFromSlice(testing.allocator, "t", out, &d);
    defer cfg.deinit();
    try testing.expect(!cfg.admin_configured);
    try testing.expectEqual(@as(usize, 1), cfg.sources.len);
    try testing.expect(std.mem.indexOf(u8, cfg.sources[0].optionString("path").?, "[admin]") != null);
}

test "options round-trip through their text form" {
    var p: Problem = .{};
    const text = try apply(testing.allocator, "", .{ .save = .{ .original = null, .spec = .{ .name = "w", .kind = "files", .options = "path = \"/a b\"\nmax_file_bytes = 5\nlanguage = \"en\"" } } }, &p);
    defer testing.allocator.free(text);
    var d: config.Diagnostic = .{};
    var cfg = try config.loadFromSlice(testing.allocator, "t", text, &d);
    defer cfg.deinit();
    const shown = try optionsText(testing.allocator, cfg.sources[0]);
    defer testing.allocator.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "path = \"/a b\"") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "max_file_bytes = 5") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "language = \"en\"") != null);
}

test "writeFile replaces atomically and keeps a backup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.toml", .data = "old = 1\n" });
    var pb: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}/c.toml", .{tmp.sub_path});
    try writeFile(testing.io, testing.allocator, path, "new = 2\n");
    const now = try tmp.dir.readFileAlloc(testing.io, "c.toml", testing.allocator, .limited(100));
    defer testing.allocator.free(now);
    const bak = try tmp.dir.readFileAlloc(testing.io, "c.toml.bak", testing.allocator, .limited(100));
    defer testing.allocator.free(bak);
    try testing.expectEqualStrings("new = 2\n", now);
    try testing.expectEqualStrings("old = 1\n", bak);
    _ = tmp.dir.statFile(testing.io, "c.toml.new", .{}) catch |e| {
        try testing.expect(e == error.FileNotFound);
        return;
    };
    return error.TestUnexpectedResult; // the temporary file must be gone
}

test "settings are set, changed and removed; the rest of the file survives; bad values are refused" {
    var problem: Problem = .{};
    const original =
        \\# my config
        \\[storage]
        \\data_dir = "/var/lib/dksearch"
        \\
        \\[search]
        \\fuzzy = "off"
        \\
        \\[[source]]
        \\name = "notes"
        \\kind = "files"
        \\path = "/home/me/notes"
        \\
    ;
    const out = try applySettings(testing.allocator, original, &.{
        .{ .table = "search", .key = "fuzzy", .value = .{ .string = "auto" } },
        .{ .table = "search", .key = "query_timeout_ms", .value = .{ .integer = 8000 } },
        .{ .table = "admin", .key = "cookie_secure", .value = .{ .boolean = true } },
    }, &problem);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# my config") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fuzzy = \"auto\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "query_timeout_ms = 8000") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cookie_secure = true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "name = \"notes\"") != null);
    // Removing the last setting of a table removes the table.
    const back = try applySettings(testing.allocator, out, &.{
        .{ .table = "admin", .key = "cookie_secure" },
        .{ .table = "search", .key = "query_timeout_ms" },
    }, &problem);
    defer testing.allocator.free(back);
    try testing.expect(std.mem.indexOf(u8, back, "[admin]") == null);
    try testing.expect(std.mem.indexOf(u8, back, "query_timeout_ms") == null);
    try testing.expect(std.mem.indexOf(u8, back, "fuzzy") != null);
    // What the configuration would not accept is refused, with the setting named, and nothing is returned.
    try testing.expectError(error.Invalid, applySettings(testing.allocator, original, &.{.{ .table = "search", .key = "fuzzy", .value = .{ .string = "sometimes" } }}, &problem));
    try testing.expect(std.mem.indexOf(u8, problem.message(), "fuzzy") != null);
    try testing.expectError(error.Invalid, applySettings(testing.allocator, original, &.{.{ .table = "search", .key = "query_timeout_ms", .value = .{ .integer = 999999 } }}, &problem));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("off", (try settingText(arena.allocator(), original, "search", "fuzzy")).?);
    try testing.expect((try settingText(arena.allocator(), original, "search", "nothing")) == null);
}

test "peers are added, kept when saved again, switched, removed, and refused with the reason" {
    var problem: Problem = .{};
    const a = testing.allocator;
    // A peer needs a node name.
    try testing.expectError(error.Invalid, applyPeer(a, "", .{ .save = .{ .original = null, .spec = .{ .name = "office", .url = "https://s.example.org" } } }, &problem));
    try testing.expect(std.mem.indexOf(u8, problem.message(), "node.name") != null);
    const node_cfg = "# my config\n[node]\nname = \"home\"\n";
    const one = try applyPeer(a, node_cfg, .{ .save = .{ .original = null, .spec = .{ .name = "office", .url = "https://s.example.org", .key_file = "/etc/office.key", .timeout_ms = 800 } } }, &problem);
    defer a.free(one);
    try testing.expect(std.mem.indexOf(u8, one, "# my config") != null);
    try testing.expect(std.mem.indexOf(u8, one, "key_file = \"/etc/office.key\"") != null);
    try testing.expect(std.mem.indexOf(u8, one, "timeout_ms = 800") != null);
    // A second peer, a duplicate name refused, a bad address refused.
    const two = try applyPeer(a, one, .{ .save = .{ .original = null, .spec = .{ .name = "lan", .url = "http://192.168.1.5:8080" } } }, &problem);
    defer a.free(two);
    try testing.expectError(error.Invalid, applyPeer(a, two, .{ .save = .{ .original = null, .spec = .{ .name = "lan", .url = "http://x:1" } } }, &problem));
    try testing.expect(std.mem.indexOf(u8, problem.message(), "already exists") != null);
    try testing.expectError(error.Invalid, applyPeer(a, two, .{ .save = .{ .original = null, .spec = .{ .name = "bad", .url = "ftp://x" } } }, &problem));
    // Saving again keeps the key file; a new one replaces it; an inline key stays.
    const again = try applyPeer(a, two, .{ .save = .{ .original = "office", .spec = .{ .name = "office", .url = "https://s2.example.org" } } }, &problem);
    defer a.free(again);
    try testing.expect(std.mem.indexOf(u8, again, "s2.example.org") != null and std.mem.indexOf(u8, again, "key_file = \"/etc/office.key\"") != null);
    const inline_key = "[node]\nname = \"h\"\n[[peer]]\nname = \"p\"\nurl = \"http://h:1\"\nkey = \"dkk_secret\"\n";
    const kept = try applyPeer(a, inline_key, .{ .save = .{ .original = "p", .spec = .{ .name = "p", .url = "http://h:2" } } }, &problem);
    defer a.free(kept);
    try testing.expect(std.mem.indexOf(u8, kept, "key = \"dkk_secret\"") != null);
    // Off, on, removed (and the empty array goes).
    const off = try applyPeer(a, two, .{ .set_enabled = .{ .name = "lan", .enabled = false } }, &problem);
    defer a.free(off);
    try testing.expect(std.mem.indexOf(u8, off, "enabled = false") != null);
    const on = try applyPeer(a, off, .{ .set_enabled = .{ .name = "lan", .enabled = true } }, &problem);
    defer a.free(on);
    try testing.expect(std.mem.indexOf(u8, on, "enabled") == null);
    const gone = try applyPeer(a, one, .{ .delete = "office" }, &problem);
    defer a.free(gone);
    try testing.expect(std.mem.indexOf(u8, gone, "peer") == null);
    try testing.expectError(error.Invalid, applyPeer(a, one, .{ .delete = "nobody" }, &problem));
}

test "collections are added, replaced, removed, and refused with the reason" {
    var problem: Problem = .{};
    const a = testing.allocator;
    const cfg = "# c\n[[source]]\nname = \"a\"\nkind = \"files\"\npath = \"/tmp\"\n[[source]]\nname = \"b\"\nkind = \"files\"\npath = \"/tmp\"\n";
    const one = try applyCollection(a, cfg, .{ .save = .{ .original = null, .spec = .{ .name = "mine", .description = "my stuff", .sources = &.{ "a", "b" } } } }, &problem);
    defer a.free(one);
    try testing.expect(std.mem.indexOf(u8, one, "# c") != null);
    try testing.expect(std.mem.indexOf(u8, one, "description = \"my stuff\"") != null);
    try testing.expect(std.mem.indexOf(u8, one, "sources = [\"a\", \"b\"]") != null);
    try testing.expectError(error.Invalid, applyCollection(a, one, .{ .save = .{ .original = null, .spec = .{ .name = "mine", .sources = &.{"a"} } } }, &problem));
    try testing.expect(std.mem.indexOf(u8, problem.message(), "already exists") != null);
    try testing.expectError(error.Invalid, applyCollection(a, one, .{ .save = .{ .original = null, .spec = .{ .name = "x", .sources = &.{"ghost"} } } }, &problem));
    try testing.expect(std.mem.indexOf(u8, problem.message(), "ghost") != null);
    try testing.expectError(error.Invalid, applyCollection(a, one, .{ .save = .{ .original = null, .spec = .{ .name = "a", .sources = &.{"a"} } } }, &problem)); // a source's name
    try testing.expectError(error.Invalid, applyCollection(a, one, .{ .save = .{ .original = null, .spec = .{ .name = "none", .sources = &.{} } } }, &problem));
    const changed = try applyCollection(a, one, .{ .save = .{ .original = "mine", .spec = .{ .name = "mine", .sources = &.{"a"} } } }, &problem);
    defer a.free(changed);
    try testing.expect(std.mem.indexOf(u8, changed, "sources = [\"a\"]") != null and std.mem.indexOf(u8, changed, "my stuff") == null);
    // Still named in [access]: refused, with the reason; free again once that is changed.
    const guarded = try std.fmt.allocPrint(a, "{s}[access]\nanonymous_collections = [\"mine\"]\n", .{one});
    defer a.free(guarded);
    try testing.expectError(error.Invalid, applyCollection(a, guarded, .{ .delete = "mine" }, &problem));
    try testing.expect(std.mem.indexOf(u8, problem.message(), "anonymous_collections") != null);
    const gone = try applyCollection(a, one, .{ .delete = "mine" }, &problem);
    defer a.free(gone);
    try testing.expect(std.mem.indexOf(u8, gone, "collection") == null);
}
