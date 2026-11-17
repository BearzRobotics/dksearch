//! The settings of the configuration file outside the sources that the admin panel can change,
//! as data (like `optioninfo.zig` for sources): where each lives, what it means and what range it
//! has. The panel builds its Settings page from this table and turns the posted form into
//! `sourceedit.Setting` changes; the configuration loader still validates the result.
//!
//! Settings are read when the server starts: a saved change applies after a restart.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sourceedit = @import("sourceedit.zig");

pub const Type = enum { text, number, flag, choice };

pub const Field = struct {
    table: []const u8,
    key: []const u8,
    label: []const u8,
    type: Type,
    help: []const u8,
    /// The value that applies when the setting is not in the file.
    default: []const u8 = "",
    choices: []const []const u8 = &.{},
    min: i64 = 0,
    max: i64 = 0,
    placeholder: []const u8 = "",
};

pub const groups = [_]struct { title: []const u8, note: []const u8, fields: []const Field }{
    .{
        .title = "Search",
        .note = "How searches are read and limited. These apply to the public page and the API.",
        .fields = &.{
            .{ .table = "search", .key = "fuzzy", .label = "Typo tolerance", .type = .choice, .choices = &.{ "auto", "always", "off" }, .default = "auto", .help = "auto: a search with fewer than three results is repeated with words one typo away. always: allow typos in every search. off: exact words only." },
            .{ .table = "search", .key = "title_weight", .label = "Ranking: title weight", .type = .number, .min = 1, .max = 1000, .default = "10", .help = "How much a word in the title counts compared with the same word in the text (see body weight). 10 to 1 favours documents whose title matches." },
            .{ .table = "search", .key = "body_weight", .label = "Ranking: text weight", .type = .number, .min = 1, .max = 1000, .default = "1", .help = "The weight of a word found in the text. Raise it, or lower the title weight, if titles dominate too much." },
            .{ .table = "search", .key = "recency_boost", .label = "Ranking: newer first (%)", .type = .number, .min = 0, .max = 1000, .default = "0", .help = "Newer documents rank up to this many percent higher. 0 turns it off. A document's date is when it was modified or published, else when it was indexed." },
            .{ .table = "search", .key = "recency_half_life_days", .label = "Ranking: half-life (days)", .type = .number, .min = 1, .max = 36500, .default = "365", .help = "The newer-first boost halves for every this many days of age." },
            .{ .table = "search", .key = "stop_words_file", .label = "Stop words file", .type = .text, .placeholder = "/path/to/stopwords.txt", .help = "One word per line (or several, separated by spaces or commas); those words are left out of searches unless nothing else is left. Applied when the query is read, so no rebuild is needed. Empty: off." },
            .{ .table = "search", .key = "synonyms_file", .label = "Synonyms file", .type = .text, .placeholder = "/path/to/synonyms.txt", .help = "One group per line, members separated by commas (car, auto, automobile): a word of a search then also matches the others. Empty: off." },
            .{ .table = "search", .key = "retrieve_cache_mb", .label = "Retrieval cache (MiB)", .type = .number, .min = 0, .max = 65536, .default = "128", .help = "Memory for the passages of recently retrieved documents, so asking again about the same documents is fast. 0 turns it off. Applies at the next start." },
            .{ .table = "search", .key = "chunk_index_min_kb", .label = "Passage index: smallest document (KiB)", .type = .number, .min = 0, .max = 1048576, .default = "64", .help = "Documents with at least this much text also get their passages indexed, so retrieval can find a passage inside a very large document (a book). 0 turns it off. Applies to documents imported or rebuilt from now on." },
            .{ .table = "search", .key = "query_syntax", .label = "Query syntax", .type = .choice, .choices = &.{ "advanced", "simple" }, .default = "advanced", .help = "advanced: quotes, OR, NOT, filters such as ext:pdf, re:/pattern/. simple: every word is plain text." },
            .{ .table = "search", .key = "query_timeout_ms", .label = "Longest search (ms)", .type = .number, .min = 0, .max = 60000, .default = "5000", .help = "A search that runs longer is stopped with a message. 0 means no limit. Very common words on a very large index need this." },
            .{ .table = "search", .key = "regex", .label = "Regular expressions", .type = .flag, .default = "true", .help = "Offer re:/pattern/ searches on the public page and API." },
            .{ .table = "search", .key = "regex_max_pattern", .label = "Regex: longest pattern (bytes)", .type = .number, .min = 1, .max = 2000, .default = "200", .help = "" },
            .{ .table = "search", .key = "regex_max_candidates", .label = "Regex: documents checked", .type = .number, .min = 1, .max = 10000, .default = "200", .help = "How many documents a regex search reads, chosen by its words." },
            .{ .table = "search", .key = "regex_budget_ms", .label = "Regex: time budget (ms)", .type = .number, .min = 10, .max = 60000, .default = "500", .help = "" },
            .{ .table = "search", .key = "regex_max_steps", .label = "Regex: steps per document", .type = .number, .min = 1000, .max = 10000000, .default = "100000", .help = "Matching steps allowed on one document before it is given up on." },
            .{ .table = "search", .key = "regex_concurrency", .label = "Regex: searches at once", .type = .number, .min = 1, .max = 64, .default = "2", .help = "" },
        },
    },
    .{
        .title = "Public server",
        .note = "The search page and API. Changing the address or port moves the server; make sure you can still reach it.",
        .fields = &.{
            .{ .table = "server", .key = "address", .label = "Address", .type = .text, .placeholder = "127.0.0.1", .help = "The network address to listen on. 127.0.0.1 is this machine only." },
            .{ .table = "server", .key = "port", .label = "Port", .type = .number, .min = 1, .max = 65535, .help = "" },
            .{ .table = "server", .key = "max_connections", .label = "Most connections", .type = .number, .min = 1, .max = 65535, .default = "256", .help = "Extra connections are closed at once." },
            .{ .table = "server", .key = "request_timeout_ms", .label = "Time to send a request (ms)", .type = .number, .min = 100, .max = 600000, .default = "10000", .help = "Also how long an idle connection is kept." },
            .{ .table = "server", .key = "write_timeout_ms", .label = "Time to receive a response (ms)", .type = .number, .min = 100, .max = 600000, .default = "10000", .help = "" },
            .{ .table = "server", .key = "access_log", .label = "Access log", .type = .text, .placeholder = "stderr", .help = "stderr or a file path: one line per request (time, method, route label, status, time). Never queries or client details. Empty: no log." },
        },
    },
    .{
        .title = "Administration",
        .note = "This panel. Turning actions off makes it read-only, and then it cannot change anything, including this page.",
        .fields = &.{
            .{ .table = "admin", .key = "session_idle_minutes", .label = "Sign out after idle (minutes)", .type = .number, .min = 1, .max = 10080, .default = "30", .help = "" },
            .{ .table = "admin", .key = "session_max_hours", .label = "Longest session (hours)", .type = .number, .min = 1, .max = 720, .default = "8", .help = "" },
            .{ .table = "admin", .key = "cookie_secure", .label = "Secure cookie", .type = .flag, .default = "false", .help = "Turn on when a proxy serves this panel over HTTPS." },
            .{ .table = "admin", .key = "backup_dir", .label = "Backup folder", .type = .text, .placeholder = "/var/backups/dksearch", .help = "Where the Maintenance page may write backups. Empty: backups from here are off." },
        },
    },
};

fn paramName(arena: Allocator, f: Field) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "s_{s}_{s}", .{ f.table, f.key });
}

fn isNumber(s: []const u8) bool {
    if (s.len == 0 or s.len > 18) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The changes the posted form asks for (`s_TABLE_KEY` for each field, in `params` with `get`):
/// a field left empty, or at its default, is removed from the file so the default applies; a
/// check box that is absent is "off". A number that is not a number is passed on as text, so
/// that saving refuses it by name.
pub fn changes(arena: Allocator, params: anytype) Allocator.Error![]const sourceedit.Setting {
    var out: std.ArrayList(sourceedit.Setting) = .empty;
    for (groups) |g| for (g.fields) |f| {
        const name = try paramName(arena, f);
        const posted = params.get(name);
        const raw = std.mem.trim(u8, posted orelse "", " \t\r\n");
        switch (f.type) {
            .flag => {
                const on = posted != null;
                const default_on = std.mem.eql(u8, f.default, "true");
                if (on == default_on) {
                    try out.append(arena, .{ .table = f.table, .key = f.key });
                } else try out.append(arena, .{ .table = f.table, .key = f.key, .value = .{ .boolean = on } });
            },
            .number => {
                if (raw.len == 0 or std.mem.eql(u8, raw, f.default)) {
                    try out.append(arena, .{ .table = f.table, .key = f.key });
                } else if (isNumber(raw)) {
                    try out.append(arena, .{ .table = f.table, .key = f.key, .value = .{ .integer = std.fmt.parseInt(i64, raw, 10) catch 0 } });
                } else try out.append(arena, .{ .table = f.table, .key = f.key, .value = .{ .string = raw } });
            },
            .text, .choice => {
                if (raw.len == 0 or (f.default.len > 0 and std.mem.eql(u8, raw, f.default))) {
                    try out.append(arena, .{ .table = f.table, .key = f.key });
                } else try out.append(arena, .{ .table = f.table, .key = f.key, .value = .{ .string = raw } });
            },
        }
    };
    return out.items;
}

const testing = std.testing;

const FakeParams = struct {
    pairs: []const [2][]const u8,
    pub fn get(self: FakeParams, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "the table is well formed" {
    var seen: usize = 0;
    for (groups) |g| for (g.fields, 0..) |f, i| {
        seen += 1;
        for (g.fields[0..i]) |p| try testing.expect(!std.mem.eql(u8, p.key, f.key) or !std.mem.eql(u8, p.table, f.table));
        if (f.type == .number) try testing.expect(f.max > f.min);
        if (f.type == .choice) try testing.expect(f.choices.len >= 2);
    };
    try testing.expect(seen >= 15);
}

test "posted settings become changes: defaults are removed, flags are on or off, bad numbers are passed on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try changes(a, FakeParams{
        .pairs = &.{
            .{ "s_search_fuzzy", "off" },
            .{ "s_search_query_syntax", "advanced" }, // the default
            .{ "s_search_query_timeout_ms", "8000" },
            .{ "s_search_regex_budget_ms", "soon" },
            .{ "s_search_regex", "1" }, // on, which is the default
            .{ "s_admin_cookie_secure", "1" },
            .{ "s_server_address", " 0.0.0.0 " },
        },
    });
    var checked: usize = 0;
    for (got) |c| {
        if (std.mem.eql(u8, c.key, "fuzzy")) {
            try testing.expectEqualStrings("off", c.value.?.string);
            checked += 1;
        }
        if (std.mem.eql(u8, c.key, "query_syntax")) {
            try testing.expect(c.value == null);
            checked += 1;
        }
        if (std.mem.eql(u8, c.key, "query_timeout_ms")) {
            try testing.expectEqual(@as(i64, 8000), c.value.?.integer);
            checked += 1;
        }
        if (std.mem.eql(u8, c.key, "regex_budget_ms")) {
            try testing.expectEqualStrings("soon", c.value.?.string);
            checked += 1;
        }
        if (std.mem.eql(u8, c.key, "regex")) {
            try testing.expect(c.value == null);
            checked += 1;
        }
        if (std.mem.eql(u8, c.key, "cookie_secure")) {
            try testing.expect(c.value.?.boolean);
            checked += 1;
        }
        if (std.mem.eql(u8, c.key, "address")) {
            try testing.expectEqualStrings("0.0.0.0", c.value.?.string);
            checked += 1;
        }
        if (std.mem.eql(u8, c.key, "port")) try testing.expect(c.value == null); // left empty
    }
    try testing.expectEqual(@as(usize, 7), checked);
}
