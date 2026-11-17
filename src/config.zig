//! TOML configuration: loading, validation and defaults.
//!
//! Configuration is static, human-edited input. Operational state (queues,
//! job history, index metadata) does not belong here. Loading either returns
//! a fully validated `Config` or an error with a `Diagnostic`; nothing is
//! applied partially, so a failed reload leaves the caller's current `Config`
//! untouched.

const std = @import("std");
const toml = @import("toml");
const document = @import("document.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The file is not valid TOML (or exceeds parser limits).
    Syntax,
    /// A key is not recognised (usually a misspelling).
    UnknownKey,
    /// A key has the wrong TOML type.
    WrongType,
    /// A value is outside its supported range or set.
    InvalidValue,
    /// The file could not be opened or read, or exceeds `max_file_bytes`.
    Unreadable,
    OutOfMemory,
};

/// Configuration files larger than this are refused before parsing.
pub const max_file_bytes = 1 << 20;

/// Where and why loading failed. Fixed buffers, so it needs no allocation and
/// stays valid after the failed document is freed.
pub const Diagnostic = struct {
    source_buf: [256]u8 = undefined,
    source_len: usize = 0,
    key_buf: [128]u8 = undefined,
    key_len: usize = 0,
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,
    /// 1-based; 0 when unknown (only syntax errors carry a position).
    line: usize = 0,
    column: usize = 0,

    /// Records the file the problem was found in, for errors found by code
    /// that only sees parsed values (for example connector validation).
    pub fn setSource(self: *Diagnostic, src: []const u8) void {
        self.source_len = copyTrunc(&self.source_buf, src);
    }

    pub fn source(self: *const Diagnostic) []const u8 {
        return self.source_buf[0..self.source_len];
    }
    pub fn key(self: *const Diagnostic) []const u8 {
        return self.key_buf[0..self.key_len];
    }
    pub fn message(self: *const Diagnostic) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    /// `file:line:col: message` for syntax errors, `file: [key] message` otherwise.
    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.source_buf[0..self.source_len]);
        if (self.line != 0) try w.print(":{d}:{d}", .{ self.line, self.column });
        try w.writeAll(": ");
        if (self.key_len != 0) try w.print("{s}: ", .{self.key_buf[0..self.key_len]});
        try w.writeAll(self.message_buf[0..self.message_len]);
    }

    pub fn set(self: *Diagnostic, src: []const u8, key_path: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.source_len = copyTrunc(&self.source_buf, src);
        self.key_len = copyTrunc(&self.key_buf, key_path);
        const m = std.fmt.bufPrint(&self.message_buf, fmt, args) catch &self.message_buf;
        self.message_len = m.len;
    }
};

fn copyTrunc(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// A network listener. Admin defaults to loopback only (ai/AGENTS.md section 7).
pub const Listener = struct {
    address: []const u8,
    port: u16,
    /// Largest request head accepted, in bytes.
    max_header_bytes: u32 = 8192,
    /// Time allowed to receive a request head; also the keep-alive idle timeout.
    request_timeout_ms: u32 = 10_000,
    /// Time allowed to send a response.
    write_timeout_ms: u32 = 10_000,
    /// Simultaneous connections; extra ones are closed immediately.
    max_connections: u32 = 256,
    max_requests_per_connection: u32 = 100,
    /// On SIGINT/SIGTERM, how long requests already being handled may take
    /// to finish before the process stops.
    shutdown_grace_ms: u32 = 5_000,
    /// "stderr" or a file path: write one line per request (time, method,
    /// route label, status, duration, bytes; never queries or client
    /// details). Null, the default, writes no log (docs/decisions/0012).
    access_log: ?[]const u8 = null,
};

/// `unicode61` folds case and diacritics; `porter` also stems English words
/// ("running" matches "run"). Changing it needs `dksearch rebuild`.
pub const Tokenizer = enum { unicode61, porter };

/// Settings that exist only on the administration listener.
pub const AdminOptions = struct {
    /// Where the credential hashes live; null means `data_dir/admin-secrets.toml`.
    secrets_file: ?[]const u8 = null,
    session_idle_minutes: u32 = 30,
    session_max_hours: u32 = 8,
    /// Mark the session cookie `Secure` (set when a proxy serves HTTPS).
    cookie_secure: bool = false,
    /// Let the interface start and cancel imports (docs/decisions/0014).
    /// Off by default: the interface is then strictly read-only.
    actions: bool = false,
    /// A folder the interface may write backups into (a new subdirectory per
    /// backup). Null: backups from the interface are off.
    backup_dir: ?[]const u8 = null,
    /// A folder the interface may download ZIM files from the Kiwix library into. Null: downloads are off.
    zim_dir: ?[]const u8 = null,
};

/// An integer setting of a listener: its key, range, and where it lives.
const ListenerInt = struct {
    key: []const u8,
    min: i64,
    max: i64,
    field: []const u8,
};

const listener_ints = [_]ListenerInt{
    .{ .key = "max_header_bytes", .min = 1024, .max = 65536, .field = "max_header_bytes" },
    .{ .key = "request_timeout_ms", .min = 100, .max = 600_000, .field = "request_timeout_ms" },
    .{ .key = "write_timeout_ms", .min = 100, .max = 600_000, .field = "write_timeout_ms" },
    .{ .key = "max_connections", .min = 1, .max = 65535, .field = "max_connections" },
    .{ .key = "max_requests_per_connection", .min = 1, .max = 10_000, .field = "max_requests_per_connection" },
    .{ .key = "shutdown_grace_ms", .min = 0, .max = 600_000, .field = "shutdown_grace_ms" },
};

/// A value of a connector-specific setting. Only scalars are allowed, so a
/// source's whole configuration is flat and easy to validate.
pub const OptionValue = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
};

pub const Option = struct {
    key: []const u8,
    value: OptionValue,
};

/// One configured source: a connector instance. Sources are optional: a
/// configuration with none is complete and valid (docs/decisions/0007).
/// `name`, `kind`, `enabled` and `retain_text` are common to all; every other
/// key is a connector-specific option, validated by that connector.
/// A schedule as seconds: `hourly`, `daily`, `weekly`, or a number with `m`, `h` or `d` (`30m`, `6h`, `2d`),
/// between 10 minutes and a year. Null if it is not one of those.
pub fn parseInterval(text: []const u8) ?u32 {
    const t = std.mem.trim(u8, text, " \t");
    if (std.mem.eql(u8, t, "hourly")) return 3600;
    if (std.mem.eql(u8, t, "daily")) return 86400;
    if (std.mem.eql(u8, t, "weekly")) return 7 * 86400;
    if (t.len < 2) return null;
    const unit: u32 = switch (t[t.len - 1]) {
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => return null,
    };
    const n = std.fmt.parseInt(u32, t[0 .. t.len - 1], 10) catch return null;
    const secs = std.math.mul(u32, n, unit) catch return null;
    if (secs < 600 or secs > 365 * 86400) return null;
    return secs;
}

pub const Source = struct {
    /// Unique, 1-64 characters of [a-z0-9_-], starting with a letter or digit.
    /// Jobs and resume points are keyed by it, so renaming a source starts it afresh.
    name: []const u8,
    /// Connector type, e.g. "files".
    kind: []const u8,
    /// A disabled source stays in the file but is never run.
    enabled: bool = true,
    /// Keep the main text so the index can be rebuilt without reacquiring it.
    /// Turn off for sources whose terms forbid retention.
    retain_text: bool = true,
    /// When set, overrides the redistribution flag every document from this
    /// source gets from its connector. Null keeps the connector's own choice.
    rights: ?document.Redistribution = null,
    /// How much this source's results count in the ranking, in percent: 100 changes nothing, 150 ranks
    /// them half as high again, 50 halves them.
    boost: u32 = 100,
    /// How often the server imports this source by itself (`schedule = "daily"`, `"6h"`, `"30m"`): the
    /// text as written, and in seconds (0: never, import by hand or with a timer).
    schedule: ?[]const u8 = null,
    schedule_seconds: u32 = 0,
    options: []const Option = &.{},

    pub fn option(self: Source, key: []const u8) ?OptionValue {
        for (self.options) |o| if (std.mem.eql(u8, o.key, key)) return o.value;
        return null;
    }
    pub fn optionString(self: Source, key: []const u8) ?[]const u8 {
        return switch (self.option(key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }
    pub fn optionInt(self: Source, key: []const u8) ?i64 {
        return switch (self.option(key) orelse return null) {
            .integer => |n| n,
            else => null,
        };
    }
    pub fn optionBool(self: Source, key: []const u8) ?bool {
        return switch (self.option(key) orelse return null) {
            .boolean => |b| b,
            else => null,
        };
    }
};

/// The `[search]` table: regular-expression filtering of results
/// (docs/decisions/0020). The limits protect the server from expensive patterns.
pub const FuzzyMode = enum { off, auto, always };

pub const SearchSettings = struct {
    /// Longest a search may run, in milliseconds (0 = no limit). Common words
    /// over a very large index take seconds to rank; past this the search is
    /// stopped and answers "too broad" instead of tying up a connection.
    query_timeout_ms: u32 = 5000,
    /// Typo tolerance: "auto" retries an exact search that finds fewer than 3
    /// results with words one typo away; "always" expands every word; "off".
    fuzzy: FuzzyMode = .auto,
    /// How much a match in the title counts against one in the body when ranking.
    title_weight: u32 = 10,
    body_weight: u32 = 1,
    /// Newer documents rank higher by up to this many percent (0 = off), the boost halving for every
    /// `recency_half_life_days` of age.
    recency_boost: u32 = 0,
    recency_half_life_days: u32 = 365,
    /// Files of stop words and of synonym groups applied to searches (see the manual); null for none.
    chunk_index_min_kb: u32 = 64,
    /// Memory for the chunks of recently retrieved documents (MiB). 0 turns the cache off.
    retrieve_cache_mb: u32 = 128,
    /// How long a peer's good answer is reused for the same question (seconds). 0 turns it off.
    peer_cache_seconds: u32 = 30,
    stop_words_file: ?[]const u8 = null,
    synonyms_file: ?[]const u8 = null,
    /// "advanced": the query language (OR, NOT, grouping, prefix*, word~, "a b"~5, +, -);
    /// "simple": every word is plain text, as in earlier versions.
    advanced_syntax: bool = true,
    /// Offer the `regex` filter on the public interface and API.
    regex: bool = true,
    /// Longest pattern, in bytes.
    regex_max_pattern: u32 = 200,
    /// Most candidate documents whose text is checked per query.
    regex_max_candidates: u32 = 200,
    /// Wall-clock budget for one regex query.
    regex_budget_ms: u32 = 500,
    /// Backtracking steps allowed per document.
    regex_max_steps: u32 = 100_000,
    /// Regex queries that may run at once.
    regex_concurrency: u32 = 2,
};

/// A named group of sources.
pub const Collection = struct {
    /// 1-64 characters of [a-z0-9_-], like a source name (and in the same namespace for `source=`: a collection
    /// may not have the name of a source).
    name: []const u8,
    description: []const u8 = "",
    /// The names of the member sources (each must be a configured source).
    sources: []const []const u8,
};

/// Who may see what without an API key.
pub const Access = struct {
    /// The collections anyone can search without a key. Null (the default): every source. An empty list: nothing,
    /// so the API needs a key (the search page then finds nothing for visitors).
    anonymous_collections: ?[]const []const u8 = null,
};

/// Another dksearch node this one may ask (federated search). Configured by the operator, never discovered.
pub const Peer = struct {
    name: []const u8,
    /// Base address, `http://host:port` or `https://host`, without a path.
    url: []const u8,
    /// An API key issued by the peer (`dksearch api-key add`): inline, or read from `key_file` at start.
    key: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    enabled: bool = true,
    /// How long to wait for this peer's answer.
    timeout_ms: u32 = 1500,
};

pub const max_peers = 50;

/// A document server (OnlyOffice or Collabora) that office files can be opened in from the viewer.
pub const DocServer = struct {
    /// `onlyoffice` or `collabora`.
    kind: []const u8,
    url: []const u8,
    public_url: []const u8,
    jwt_secret: ?[]const u8 = null,
    jwt_secret_file: ?[]const u8 = null,
};

pub const max_collections = 200;
pub const max_collection_sources = 1000;

pub const Config = struct {
    arena: std.heap.ArenaAllocator,

    /// Public search interface and API.
    server: Listener,
    /// Administration interface; separate listener from `server`.
    admin: Listener,
    admin_options: AdminOptions = .{},
    /// How the search index splits and normalises text (docs/decisions/0013).
    tokenizer: Tokenizer = .unicode61,
    search: SearchSettings = .{},
    /// True if the file has an `[admin]` table: the administration interface
    /// is then served (and needs credentials, see docs/decisions/0012).
    admin_configured: bool,
    /// Directory for operational state, retained content and indexes.
    data_dir: []const u8,
    /// Configured sources; empty by default.
    sources: []const Source,
    /// Named groups of sources (`[[collection]]`): what a search can be limited to, and what an API key can see.
    collections: []const Collection = &.{},
    access: Access = .{},
    /// This node's name, shown beside results that come from it on another node.
    node_name: []const u8 = "",
    peers: []const Peer = &.{},
    docserver: ?DocServer = null,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const server_keys = [_][]const u8{
    "address",                     "port",
    "max_header_bytes",            "request_timeout_ms",
    "write_timeout_ms",            "max_connections",
    "max_requests_per_connection", "shutdown_grace_ms",
    "access_log",
};
const admin_keys = server_keys ++ [_][]const u8{ "secrets_file", "session_idle_minutes", "session_max_hours", "cookie_secure", "actions", "backup_dir", "zim_dir" };
const storage_keys = [_][]const u8{"data_dir"};
const index_keys = [_][]const u8{"tokenizer"};
const search_keys = [_][]const u8{ "fuzzy", "title_weight", "body_weight", "recency_boost", "recency_half_life_days", "stop_words_file", "synonyms_file", "chunk_index_min_kb", "retrieve_cache_mb", "peer_cache_seconds", "query_syntax", "query_timeout_ms", "regex", "regex_max_pattern", "regex_max_candidates", "regex_budget_ms", "regex_max_steps", "regex_concurrency" };
const top_keys = [_][]const u8{ "server", "admin", "storage", "index", "search", "source", "collection", "access", "node", "peer", "docserver" };

/// Parses and validates configuration text. `source_name` is only used in
/// diagnostics (normally the file path).
pub fn loadFromSlice(gpa: Allocator, source_name: []const u8, text: []const u8, diag: *Diagnostic) Error!Config {
    var tdiag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(gpa, text, .{}, &tdiag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.set(source_name, "", "{s}", .{tdiag.message});
            diag.line = tdiag.line;
            diag.column = tdiag.column;
            return error.Syntax;
        },
    };
    defer doc.deinit();
    return build(gpa, source_name, doc.root, diag);
}

/// Reads and validates the configuration file `path`, relative to `dir`. The
/// path is used verbatim in diagnostics. Nothing is applied on failure.
pub fn loadFile(gpa: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, diag: *Diagnostic) Error!Config {
    const text = dir.readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => {
            diag.set(path, "", "file is larger than {d} bytes", .{max_file_bytes});
            return error.Unreadable;
        },
        else => {
            diag.set(path, "", "cannot read file: {t}", .{e});
            return error.Unreadable;
        },
    };
    defer gpa.free(text);
    return loadFromSlice(gpa, path, text, diag);
}

fn build(gpa: Allocator, src: []const u8, root: *toml.Table, diag: *Diagnostic) Error!Config {
    try checkKeys(src, "", root, &top_keys, diag);

    var cfg: Config = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .server = .{ .address = "127.0.0.1", .port = 8080 },
        .admin = .{ .address = "127.0.0.1", .port = 8081 },
        .admin_configured = root.get("admin") != null,
        .data_dir = "data",
        .sources = &.{},
    };
    errdefer cfg.arena.deinit();
    const a = cfg.arena.allocator();

    cfg.server = try readListener(a, src, root, "server", &server_keys, cfg.server, diag);
    cfg.admin = try readListener(a, src, root, "admin", &admin_keys, cfg.admin, diag);
    if (try subTable(src, root, "admin", diag)) |t| {
        if (try str(src, "admin", t, "backup_dir", diag)) |bd| {
            if (bd.len == 0) {
                diag.set(src, "admin.backup_dir", "must not be empty (omit the key to turn backups from the interface off)", .{});
                return error.InvalidValue;
            }
            cfg.admin_options.backup_dir = try a.dupe(u8, bd);
        }
        if (try str(src, "admin", t, "zim_dir", diag)) |zd| {
            if (zd.len == 0) {
                diag.set(src, "admin.zim_dir", "must not be empty (omit the key to turn ZIM downloads off)", .{});
                return error.InvalidValue;
            }
            cfg.admin_options.zim_dir = try a.dupe(u8, zd);
        }
        if (try str(src, "admin", t, "secrets_file", diag)) |s| {
            if (s.len == 0) {
                diag.set(src, "admin.secrets_file", "must not be empty", .{});
                return error.InvalidValue;
            }
            cfg.admin_options.secrets_file = try a.dupe(u8, s);
        }
        if (try intIn(src, "admin", t, "session_idle_minutes", 1, 1440, diag)) |n| cfg.admin_options.session_idle_minutes = @intCast(n);
        if (try intIn(src, "admin", t, "session_max_hours", 1, 168, diag)) |n| cfg.admin_options.session_max_hours = @intCast(n);
        if (try optBool(src, "admin", t, "cookie_secure", diag)) |b| cfg.admin_options.cookie_secure = b;
        if (try optBool(src, "admin", t, "actions", diag)) |b| cfg.admin_options.actions = b;
    }

    if (try subTable(src, root, "storage", diag)) |t| {
        try checkKeys(src, "storage", t, &storage_keys, diag);
        if (try str(src, "storage", t, "data_dir", diag)) |s| {
            if (s.len == 0) {
                diag.set(src, "storage.data_dir", "must not be empty", .{});
                return error.InvalidValue;
            }
            cfg.data_dir = try a.dupe(u8, s);
        }
    }

    if (try subTable(src, root, "index", diag)) |t| {
        try checkKeys(src, "index", t, &index_keys, diag);
        if (try str(src, "index", t, "tokenizer", diag)) |s| {
            cfg.tokenizer = std.meta.stringToEnum(Tokenizer, s) orelse {
                diag.set(src, "index.tokenizer", "must be \"unicode61\" or \"porter\", got \"{s}\"", .{s});
                return error.InvalidValue;
            };
        }
    }

    if (try subTable(src, root, "search", diag)) |t| {
        try checkKeys(src, "search", t, &search_keys, diag);
        if (try str(src, "search", t, "fuzzy", diag)) |v| {
            cfg.search.fuzzy = std.meta.stringToEnum(FuzzyMode, v) orelse {
                diag.set(src, "search.fuzzy", "must be \"auto\", \"always\" or \"off\", got \"{s}\"", .{v});
                return error.InvalidValue;
            };
        }
        if (try str(src, "search", t, "query_syntax", diag)) |v| {
            if (std.mem.eql(u8, v, "advanced")) {
                cfg.search.advanced_syntax = true;
            } else if (std.mem.eql(u8, v, "simple")) {
                cfg.search.advanced_syntax = false;
            } else {
                diag.set(src, "search.query_syntax", "must be \"advanced\" or \"simple\", got \"{s}\"", .{v});
                return error.InvalidValue;
            }
        }
        if (try intIn(src, "search", t, "title_weight", 1, 1000, diag)) |n| cfg.search.title_weight = @intCast(n);
        if (try intIn(src, "search", t, "body_weight", 1, 1000, diag)) |n| cfg.search.body_weight = @intCast(n);
        inline for (.{ "stop_words_file", "synonyms_file" }) |key| {
            if (try str(src, "search", t, key, diag)) |v| {
                if (v.len == 0) {
                    diag.set(src, "search." ++ key, "must not be empty (omit the key to turn it off)", .{});
                    return error.InvalidValue;
                }
                @field(cfg.search, key) = try a.dupe(u8, v);
            }
        }
        if (try intIn(src, "search", t, "chunk_index_min_kb", 0, 1024 * 1024, diag)) |n| cfg.search.chunk_index_min_kb = @intCast(n);
        if (try intIn(src, "search", t, "retrieve_cache_mb", 0, 65536, diag)) |n| cfg.search.retrieve_cache_mb = @intCast(n);
        if (try intIn(src, "search", t, "peer_cache_seconds", 0, 3600, diag)) |n| cfg.search.peer_cache_seconds = @intCast(n);
        if (try intIn(src, "search", t, "recency_boost", 0, 1000, diag)) |n| cfg.search.recency_boost = @intCast(n);
        if (try intIn(src, "search", t, "recency_half_life_days", 1, 36500, diag)) |n| cfg.search.recency_half_life_days = @intCast(n);
        if (try intIn(src, "search", t, "query_timeout_ms", 0, 60_000, diag)) |n| cfg.search.query_timeout_ms = @intCast(n);
        if (try optBool(src, "search", t, "regex", diag)) |b| cfg.search.regex = b;
        if (try intIn(src, "search", t, "regex_max_pattern", 1, 2000, diag)) |n| cfg.search.regex_max_pattern = @intCast(n);
        if (try intIn(src, "search", t, "regex_max_candidates", 1, 10_000, diag)) |n| cfg.search.regex_max_candidates = @intCast(n);
        if (try intIn(src, "search", t, "regex_budget_ms", 10, 60_000, diag)) |n| cfg.search.regex_budget_ms = @intCast(n);
        if (try intIn(src, "search", t, "regex_max_steps", 1000, 10_000_000, diag)) |n| cfg.search.regex_max_steps = @intCast(n);
        if (try intIn(src, "search", t, "regex_concurrency", 1, 64, diag)) |n| cfg.search.regex_concurrency = @intCast(n);
    }

    cfg.sources = try readSources(a, src, root, diag);
    cfg.collections = try readCollections(a, src, root, cfg.sources, diag);
    if (try subTable(src, root, "node", diag)) |t| {
        try checkKeys(src, "node", t, &[_][]const u8{"name"}, diag);
        if (try str(src, "node", t, "name", diag)) |n| {
            if (n.len == 0 or n.len > 64 or std.mem.indexOfAny(u8, n, "<>&\"'\x00\r\n") != null) {
                diag.set(src, "node.name", "must be 1 to 64 characters without quotes, angle brackets or line breaks", .{});
                return error.InvalidValue;
            }
            cfg.node_name = try a.dupe(u8, n);
        }
    }
    cfg.docserver = try readDocServer(a, src, root, diag);
    cfg.peers = try readPeers(a, src, root, diag);
    if (cfg.peers.len > 0 and cfg.node_name.len == 0) {
        diag.set(src, "node.name", "is required when peers are configured (peers show this name beside the results they get from here)", .{});
        return error.InvalidValue;
    }
    if (try subTable(src, root, "access", diag)) |t| {
        try checkKeys(src, "access", t, &[_][]const u8{"anonymous_collections"}, diag);
        if (t.get("anonymous_collections")) |v| {
            const list = try stringList(a, src, "access.anonymous_collections", v, diag);
            for (list) |c| {
                var known = false;
                for (cfg.collections) |col| if (std.mem.eql(u8, col.name, c)) {
                    known = true;
                };
                if (!known) {
                    diag.set(src, "access.anonymous_collections", "names a collection that is not defined: \"{s}\"", .{c});
                    return error.InvalidValue;
                }
            }
            cfg.access.anonymous_collections = list;
        }
    }

    if (cfg.server.access_log) |sl| if (cfg.admin.access_log) |al| {
        if (std.mem.eql(u8, sl, al) and !std.mem.eql(u8, sl, "stderr")) {
            diag.set(src, "admin.access_log", "must differ from server.access_log (two logs cannot share one file)", .{});
            return error.InvalidValue;
        }
    };
    if (cfg.server.port == cfg.admin.port and std.mem.eql(u8, cfg.server.address, cfg.admin.address)) {
        diag.set(src, "admin", "admin and server must not share the same address and port", .{});
        return error.InvalidValue;
    }
    return cfg;
}

const source_common_keys = [_][]const u8{ "name", "kind", "enabled", "retain_text", "rights", "boost", "schedule" };

/// An array of strings, copied into `a`.
fn stringList(a: Allocator, src: []const u8, key: []const u8, v: toml.Value, diag: *Diagnostic) Error![]const []const u8 {
    const arr = switch (v) {
        .array => |x| x,
        else => {
            diag.set(src, key, "expected an array of strings, got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
    const out = try a.alloc([]const u8, arr.items.items.len);
    for (arr.items.items, out) |item, *o| switch (item) {
        .string => |s| o.* = try a.dupe(u8, s),
        else => {
            diag.set(src, key, "expected an array of strings, got an item of type {s}", .{item.typeName()});
            return error.WrongType;
        },
    };
    return out;
}

/// A base address `http://host[:port]` or `https://host[:port]` without a path or credentials, trailing slashes removed.
fn baseAddress(a: Allocator, src: []const u8, key: []const u8, text: []const u8, diag: *Diagnostic) Error![]const u8 {
    const url = std.mem.trimEnd(u8, text, "/");
    const has_scheme = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
    const rest = if (has_scheme) url[std.mem.indexOf(u8, url, "://").? + 3 ..] else "";
    if (!has_scheme or rest.len == 0 or std.mem.indexOfAny(u8, rest, "/?#@ \"'<>") != null) {
        diag.set(src, key, "must look like http://host:port or https://host (no path, no credentials), got \"{s}\"", .{text});
        return error.InvalidValue;
    }
    return a.dupe(u8, url);
}

fn readDocServer(a: Allocator, src: []const u8, root: *toml.Table, diag: *Diagnostic) Error!?DocServer {
    const t = (try subTable(src, root, "docserver", diag)) orelse return null;
    try checkKeys(src, "docserver", t, &[_][]const u8{ "kind", "url", "public_url", "jwt_secret", "jwt_secret_file" }, diag);
    const kind = try reqStr(src, "docserver", t, "kind", diag);
    if (!std.mem.eql(u8, kind, "onlyoffice") and !std.mem.eql(u8, kind, "collabora")) {
        diag.set(src, "docserver.kind", "must be \"onlyoffice\" or \"collabora\", got \"{s}\"", .{kind});
        return error.InvalidValue;
    }
    var d: DocServer = .{
        .kind = try a.dupe(u8, kind),
        .url = try baseAddress(a, src, "docserver.url", try reqStr(src, "docserver", t, "url", diag), diag),
        .public_url = try baseAddress(a, src, "docserver.public_url", try reqStr(src, "docserver", t, "public_url", diag), diag),
    };
    if (try str(src, "docserver", t, "jwt_secret", diag)) |s| d.jwt_secret = try a.dupe(u8, s);
    if (try str(src, "docserver", t, "jwt_secret_file", diag)) |s| d.jwt_secret_file = try a.dupe(u8, s);
    if (d.jwt_secret != null and d.jwt_secret_file != null) {
        diag.set(src, "docserver.jwt_secret", "give either jwt_secret or jwt_secret_file, not both", .{});
        return error.InvalidValue;
    }
    if (d.jwt_secret != null or d.jwt_secret_file != null) if (std.mem.eql(u8, kind, "collabora")) {
        diag.set(src, "docserver.jwt_secret", "only applies to OnlyOffice (Collabora is given a token in the address)", .{});
        return error.InvalidValue;
    };
    return d;
}

fn readPeers(a: Allocator, src: []const u8, root: *toml.Table, diag: *Diagnostic) Error![]const Peer {
    const v = root.get("peer") orelse return &.{};
    const arr = switch (v) {
        .array => |x| x,
        else => {
            diag.set(src, "peer", "expected an array of tables ([[peer]]), got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
    if (arr.items.items.len > max_peers) {
        diag.set(src, "peer", "at most {d} peers", .{max_peers});
        return error.InvalidValue;
    }
    var out = try a.alloc(Peer, arr.items.items.len);
    var kbuf: [96]u8 = undefined;
    var nbuf: [128]u8 = undefined;
    for (arr.items.items, 0..) |item, i| {
        const where = std.fmt.bufPrint(&kbuf, "peer[{d}]", .{i}) catch "peer";
        const t = switch (item) {
            .table => |x| x,
            else => {
                diag.set(src, where, "expected a table, got {s}", .{item.typeName()});
                return error.WrongType;
            },
        };
        try checkKeys(src, where, t, &[_][]const u8{ "name", "url", "key", "key_file", "enabled", "timeout_ms" }, diag);
        const name = try reqStr(src, where, t, "name", diag);
        if (!validSourceName(name)) {
            diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.name", .{where}) catch "peer.name", "must be 1-64 characters of a-z, 0-9, '_' or '-', starting with a letter or digit, got \"{s}\"", .{name});
            return error.InvalidValue;
        }
        for (out[0..i]) |prev| if (std.mem.eql(u8, prev.name, name)) {
            diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.name", .{where}) catch "peer.name", "duplicate peer name \"{s}\"", .{name});
            return error.InvalidValue;
        };
        var url = std.mem.trimEnd(u8, try reqStr(src, where, t, "url", diag), "/");
        const has_scheme = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
        const rest = if (has_scheme) url[std.mem.indexOf(u8, url, "://").? + 3 ..] else "";
        if (!has_scheme or rest.len == 0 or std.mem.indexOfAny(u8, rest, "/?#@ ") != null) {
            diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.url", .{where}) catch "peer.url", "must look like http://host:port or https://host (no path, no credentials), got \"{s}\"", .{url});
            return error.InvalidValue;
        }
        url = try a.dupe(u8, url);
        var p: Peer = .{ .name = try a.dupe(u8, name), .url = url };
        if (try str(src, where, t, "key", diag)) |k| p.key = try a.dupe(u8, k);
        if (try str(src, where, t, "key_file", diag)) |k| p.key_file = try a.dupe(u8, k);
        if (p.key != null and p.key_file != null) {
            diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.key", .{where}) catch "peer.key", "give either key or key_file, not both", .{});
            return error.InvalidValue;
        }
        if (try optBool(src, where, t, "enabled", diag)) |b| p.enabled = b;
        if (try intIn(src, where, t, "timeout_ms", 100, 30000, diag)) |n| p.timeout_ms = @intCast(n);
        out[i] = p;
    }
    return out;
}

fn readCollections(a: Allocator, src: []const u8, root: *toml.Table, sources: []const Source, diag: *Diagnostic) Error![]const Collection {
    const v = root.get("collection") orelse return &.{};
    const arr = switch (v) {
        .array => |x| x,
        else => {
            diag.set(src, "collection", "expected an array of tables ([[collection]]), got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
    if (arr.items.items.len > max_collections) {
        diag.set(src, "collection", "at most {d} collections", .{max_collections});
        return error.InvalidValue;
    }
    var out = try a.alloc(Collection, arr.items.items.len);
    var kbuf: [96]u8 = undefined;
    for (arr.items.items, 0..) |item, i| {
        const t = switch (item) {
            .table => |x| x,
            else => {
                diag.set(src, std.fmt.bufPrint(&kbuf, "collection[{d}]", .{i}) catch "collection", "expected a table, got {s}", .{item.typeName()});
                return error.WrongType;
            },
        };
        const where = std.fmt.bufPrint(&kbuf, "collection[{d}]", .{i}) catch "collection";
        try checkKeys(src, where, t, &[_][]const u8{ "name", "description", "sources" }, diag);
        const name = try reqStr(src, where, t, "name", diag);
        var nbuf: [128]u8 = undefined;
        if (!validSourceName(name)) {
            diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.name", .{where}) catch "collection.name", "must be 1-64 characters of a-z, 0-9, '_' or '-', starting with a letter or digit, got \"{s}\"", .{name});
            return error.InvalidValue;
        }
        for (out[0..i]) |prev| if (std.mem.eql(u8, prev.name, name)) {
            diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.name", .{where}) catch "collection.name", "duplicate collection name \"{s}\"", .{name});
            return error.InvalidValue;
        };
        for (sources) |s| if (std.mem.eql(u8, s.name, name)) {
            diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.name", .{where}) catch "collection.name", "\"{s}\" is also the name of a source; a collection needs its own name", .{name});
            return error.InvalidValue;
        };
        const members_v = t.get("sources") orelse {
            diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.sources", .{where}) catch "collection.sources", "is required", .{});
            return error.InvalidValue;
        };
        const members = try stringList(a, src, std.fmt.bufPrint(&nbuf, "{s}.sources", .{where}) catch "collection.sources", members_v, diag);
        if (members.len == 0 or members.len > max_collection_sources) {
            diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.sources", .{where}) catch "collection.sources", "needs 1 to {d} sources", .{max_collection_sources});
            return error.InvalidValue;
        }
        for (members) |m| {
            var known = false;
            for (sources) |s| if (std.mem.eql(u8, s.name, m)) {
                known = true;
            };
            if (!known) {
                diag.set(src, std.fmt.bufPrint(&nbuf, "{s}.sources", .{where}) catch "collection.sources", "names a source that is not configured: \"{s}\"", .{m});
                return error.InvalidValue;
            }
        }
        const desc = if (try str(src, where, t, "description", diag)) |d| try a.dupe(u8, d) else "";
        out[i] = .{ .name = try a.dupe(u8, name), .description = desc, .sources = members };
    }
    return out;
}

pub fn validSourceName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name, 0..) |ch, i| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or (i > 0 and (ch == '_' or ch == '-'));
        if (!ok) return false;
    }
    return true;
}

fn readSources(a: Allocator, src: []const u8, root: *toml.Table, diag: *Diagnostic) Error![]const Source {
    const v = root.get("source") orelse return &.{};
    const arr = switch (v) {
        .array => |x| x,
        else => {
            diag.set(src, "source", "expected an array of tables ([[source]]), got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
    var out = try a.alloc(Source, arr.items.items.len);
    var kbuf: [96]u8 = undefined;
    for (arr.items.items, 0..) |item, i| {
        const t = switch (item) {
            .table => |x| x,
            else => {
                diag.set(src, std.fmt.bufPrint(&kbuf, "source[{d}]", .{i}) catch "source", "expected a table, got {s}", .{item.typeName()});
                return error.WrongType;
            },
        };
        const where = std.fmt.bufPrint(&kbuf, "source[{d}]", .{i}) catch "source";

        const name = (try reqStr(src, where, t, "name", diag));
        if (!validSourceName(name)) {
            diag.set(src, std.fmt.bufPrint(&kbuf, "source[{d}].name", .{i}) catch "source.name", "must be 1-64 characters of a-z, 0-9, '_' or '-', starting with a letter or digit, got \"{s}\"", .{name});
            return error.InvalidValue;
        }
        for (out[0..i]) |prev| if (std.mem.eql(u8, prev.name, name)) {
            diag.set(src, std.fmt.bufPrint(&kbuf, "source[{d}].name", .{i}) catch "source.name", "duplicate source name \"{s}\"", .{name});
            return error.InvalidValue;
        };
        const kind = try reqStr(src, where, t, "kind", diag);
        if (kind.len == 0) {
            diag.set(src, std.fmt.bufPrint(&kbuf, "source[{d}].kind", .{i}) catch "source.kind", "must not be empty", .{});
            return error.InvalidValue;
        }

        var s: Source = .{ .name = try a.dupe(u8, name), .kind = try a.dupe(u8, kind) };
        if (try optBool(src, where, t, "enabled", diag)) |b| s.enabled = b;
        if (try optBool(src, where, t, "retain_text", diag)) |b| s.retain_text = b;
        if (try intIn(src, where, t, "boost", 1, 1000, diag)) |n| s.boost = @intCast(n);
        if (try str(src, where, t, "schedule", diag)) |sv| {
            s.schedule_seconds = parseInterval(sv) orelse {
                diag.set(src, std.fmt.bufPrint(&kbuf, "source[{d}].schedule", .{i}) catch "source.schedule", "must be hourly, daily, weekly, or a number with m, h or d (30m, 6h, 2d; at least 10 minutes), got \"{s}\"", .{sv});
                return error.InvalidValue;
            };
            s.schedule = try a.dupe(u8, sv);
        }
        if (try str(src, where, t, "rights", diag)) |rv| {
            s.rights = std.meta.stringToEnum(document.Redistribution, rv) orelse {
                diag.set(src, std.fmt.bufPrint(&kbuf, "source[{d}].rights", .{i}) catch "source.rights", "must be \"unknown\", \"allowed\", \"restricted\" or \"forbidden\", got \"{s}\"", .{rv});
                return error.InvalidValue;
            };
        }

        var opts: std.ArrayList(Option) = .empty;
        var it = t.entries.iterator();
        outer: while (it.next()) |e| {
            for (source_common_keys) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue :outer;
            const value: OptionValue = switch (e.value_ptr.*) {
                .string => |x| .{ .string = try a.dupe(u8, x) },
                .integer => |x| .{ .integer = x },
                .boolean => |x| .{ .boolean = x },
                else => |other| {
                    diag.set(src, std.fmt.bufPrint(&kbuf, "source[{d}].{s}", .{ i, e.key_ptr.* }) catch "source", "unsupported type {s} (use a string, integer or boolean)", .{other.typeName()});
                    return error.WrongType;
                },
            };
            try opts.append(a, .{ .key = try a.dupe(u8, e.key_ptr.*), .value = value });
        }
        s.options = opts.items;
        out[i] = s;
    }
    return out;
}

fn reqStr(src: []const u8, where: []const u8, t: *toml.Table, key: []const u8, diag: *Diagnostic) Error![]const u8 {
    var kbuf: [128]u8 = undefined;
    const kp = std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ where, key }) catch key;
    const v = t.get(key) orelse {
        diag.set(src, kp, "is required", .{});
        return error.InvalidValue;
    };
    return switch (v) {
        .string => |s| s,
        else => {
            diag.set(src, kp, "expected string, got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
}

fn optBool(src: []const u8, where: []const u8, t: *toml.Table, key: []const u8, diag: *Diagnostic) Error!?bool {
    const v = t.get(key) orelse return null;
    return switch (v) {
        .boolean => |b| b,
        else => {
            var kbuf: [128]u8 = undefined;
            diag.set(src, std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ where, key }) catch key, "expected boolean, got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
}

fn readListener(a: Allocator, src: []const u8, root: *toml.Table, name: []const u8, keys: []const []const u8, def: Listener, diag: *Diagnostic) Error!Listener {
    var out = def;
    out.address = try a.dupe(u8, def.address);
    const t = (try subTable(src, root, name, diag)) orelse return out;
    try checkKeys(src, name, t, keys, diag);

    var kbuf: [96]u8 = undefined;
    if (try str(src, name, t, "access_log", diag)) |s| {
        if (s.len == 0) {
            diag.set(src, std.fmt.bufPrint(&kbuf, "{s}.access_log", .{name}) catch name, "must not be empty (omit the key for no log)", .{});
            return error.InvalidValue;
        }
        out.access_log = try a.dupe(u8, s);
    }
    if (try str(src, name, t, "address", diag)) |s| {
        if (s.len == 0) {
            diag.set(src, std.fmt.bufPrint(&kbuf, "{s}.address", .{name}) catch name, "must not be empty", .{});
            return error.InvalidValue;
        }
        // Literals only: resolving names would make startup depend on DNS.
        _ = std.Io.net.IpAddress.parse(s, 1) catch {
            diag.set(src, std.fmt.bufPrint(&kbuf, "{s}.address", .{name}) catch name, "must be an IPv4 or IPv6 address literal, got \"{s}\"", .{s});
            return error.InvalidValue;
        };
        a.free(out.address);
        out.address = try a.dupe(u8, s);
    }
    if (try intIn(src, name, t, "port", 1, 65535, diag)) |n| out.port = @intCast(n);
    inline for (listener_ints) |li| {
        if (try intIn(src, name, t, li.key, li.min, li.max, diag)) |n| @field(out, li.field) = @intCast(n);
    }
    return out;
}

/// Reads an optional integer key and checks it lies in [min, max].
fn intIn(src: []const u8, section: []const u8, t: *toml.Table, key: []const u8, min: i64, max: i64, diag: *Diagnostic) Error!?i64 {
    const v = t.get(key) orelse return null;
    var kbuf: [96]u8 = undefined;
    const kp = std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ section, key }) catch key;
    switch (v) {
        .integer => |n| {
            if (n < min or n > max) {
                diag.set(src, kp, "must be between {d} and {d}, got {d}", .{ min, max, n });
                return error.InvalidValue;
            }
            return n;
        },
        else => {
            diag.set(src, kp, "expected integer, got {s}", .{v.typeName()});
            return error.WrongType;
        },
    }
}

fn subTable(src: []const u8, t: *toml.Table, name: []const u8, diag: *Diagnostic) Error!?*toml.Table {
    const v = t.get(name) orelse return null;
    return switch (v) {
        .table => |x| x,
        else => {
            diag.set(src, name, "expected table, got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
}

fn str(src: []const u8, section: []const u8, t: *toml.Table, name: []const u8, diag: *Diagnostic) Error!?[]const u8 {
    const v = t.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => {
            var kbuf: [128]u8 = undefined;
            diag.set(src, std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ section, name }) catch name, "expected string, got {s}", .{v.typeName()});
            return error.WrongType;
        },
    };
}

/// Rejects keys not in `allowed`, so a misspelled setting is an error instead
/// of being silently ignored.
fn checkKeys(src: []const u8, path: []const u8, t: *toml.Table, allowed: []const []const u8, diag: *Diagnostic) Error!void {
    var it = t.entries.iterator();
    outer: while (it.next()) |e| {
        for (allowed) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue :outer;
        var kbuf: [128]u8 = undefined;
        const full = if (path.len == 0)
            e.key_ptr.*
        else
            std.fmt.bufPrint(&kbuf, "{s}.{s}", .{ path, e.key_ptr.* }) catch e.key_ptr.*;
        diag.set(src, full, "unknown key", .{});
        return error.UnknownKey;
    }
}

const testing = std.testing;

test "empty config yields safe defaults" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer c.deinit();
    try testing.expectEqualStrings("127.0.0.1", c.server.address);
    try testing.expectEqual(@as(u16, 8080), c.server.port);
    try testing.expectEqualStrings("127.0.0.1", c.admin.address);
    try testing.expectEqual(@as(u16, 8081), c.admin.port);
    try testing.expectEqualStrings("data", c.data_dir);
}

test "values override defaults" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml",
        \\[server]
        \\address = "0.0.0.0"
        \\port = 9000
        \\[storage]
        \\data_dir = "/var/lib/dksearch"
    , &d);
    defer c.deinit();
    try testing.expectEqualStrings("0.0.0.0", c.server.address);
    try testing.expectEqual(@as(u16, 9000), c.server.port);
    try testing.expectEqualStrings("/var/lib/dksearch", c.data_dir);
    try testing.expectEqual(@as(u16, 8081), c.admin.port);
}

test "misspelled key is rejected with its path" {
    var d: Diagnostic = .{};
    try testing.expectError(error.UnknownKey, loadFromSlice(testing.allocator, "t.toml",
        \\[server]
        \\adress = "0.0.0.0"
    , &d));
    try testing.expectEqualStrings("server.adress", d.key());
    try testing.expectEqualStrings("t.toml", d.source());
}

test "unknown top-level key is rejected" {
    var d: Diagnostic = .{};
    try testing.expectError(error.UnknownKey, loadFromSlice(testing.allocator, "t.toml", "serverr = 1", &d));
    try testing.expectEqualStrings("serverr", d.key());
}

test "wrong type and out-of-range port" {
    var d: Diagnostic = .{};
    try testing.expectError(error.WrongType, loadFromSlice(testing.allocator, "t.toml", "[server]\nport = \"80\"", &d));
    try testing.expectEqualStrings("server.port", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\nport = 70000", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\nport = 0", &d));
    try testing.expectError(error.WrongType, loadFromSlice(testing.allocator, "t.toml", "server = 3", &d));
}

test "syntax error carries position" {
    var d: Diagnostic = .{};
    try testing.expectError(error.Syntax, loadFromSlice(testing.allocator, "t.toml", "a = \n", &d));
    try testing.expect(d.line >= 1);
}

test "admin must not collide with server" {
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[admin]\nport = 8080", &d));
}

test "empty data_dir rejected" {
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[storage]\ndata_dir = \"\"", &d));
}

test "diagnostic formatting" {
    var d: Diagnostic = .{};
    _ = loadFromSlice(testing.allocator, "t.toml", "[server]\nbogus = 1", &d) catch {};
    var buf: [256]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{d});
    try testing.expectEqualStrings("t.toml: server.bogus: unknown key", s);
}

test "loadFile reads a file and reports its path in diagnostics" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ok.toml", .data = "[server]\nport = 9100\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad.toml", .data = "[server]\nprot = 1\n" });

    var d: Diagnostic = .{};
    var c = try loadFile(testing.allocator, testing.io, tmp.dir, "ok.toml", &d);
    defer c.deinit();
    try testing.expectEqual(@as(u16, 9100), c.server.port);

    try testing.expectError(error.UnknownKey, loadFile(testing.allocator, testing.io, tmp.dir, "bad.toml", &d));
    try testing.expectEqualStrings("bad.toml", d.source());
    try testing.expectEqualStrings("server.prot", d.key());
}

test "loadFile: missing and oversized files are Unreadable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var d: Diagnostic = .{};
    try testing.expectError(error.Unreadable, loadFile(testing.allocator, testing.io, tmp.dir, "nope.toml", &d));
    try testing.expectEqualStrings("nope.toml", d.source());

    const big = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, '#');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.toml", .data = big });
    try testing.expectError(error.Unreadable, loadFile(testing.allocator, testing.io, tmp.dir, "big.toml", &d));
}

test "listener limits have safe defaults and can be overridden" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    try testing.expectEqual(@as(u32, 8192), c.server.max_header_bytes);
    try testing.expectEqual(@as(u32, 10_000), c.server.request_timeout_ms);
    try testing.expectEqual(@as(u32, 256), c.server.max_connections);
    c.deinit();

    var c2 = try loadFromSlice(testing.allocator, "t.toml",
        \\[server]
        \\max_connections = 8
        \\request_timeout_ms = 2500
        \\max_header_bytes = 4096
        \\write_timeout_ms = 3000
        \\max_requests_per_connection = 5
        \\[admin]
        \\max_connections = 2
    , &d);
    defer c2.deinit();
    try testing.expectEqual(@as(u32, 8), c2.server.max_connections);
    try testing.expectEqual(@as(u32, 2500), c2.server.request_timeout_ms);
    try testing.expectEqual(@as(u32, 4096), c2.server.max_header_bytes);
    try testing.expectEqual(@as(u32, 3000), c2.server.write_timeout_ms);
    try testing.expectEqual(@as(u32, 5), c2.server.max_requests_per_connection);
    try testing.expectEqual(@as(u32, 5_000), c2.server.shutdown_grace_ms);
    try testing.expectEqual(@as(u32, 2), c2.admin.max_connections);
    try testing.expectEqual(@as(u32, 8192), c2.admin.max_header_bytes); // untouched keys keep defaults
}

test "listener limits are range-checked with the key in the message" {
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\nmax_connections = 0", &d));
    try testing.expectEqualStrings("server.max_connections", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\nmax_header_bytes = 10", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[admin]\nrequest_timeout_ms = 99999999", &d));
    try testing.expectError(error.WrongType, loadFromSlice(testing.allocator, "t.toml", "[server]\nmax_connections = \"many\"", &d));
    try testing.expectError(error.UnknownKey, loadFromSlice(testing.allocator, "t.toml", "[server]\nmax_connection = 5", &d));
}

test "listener address must be an IP literal" {
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\naddress = \"localhost\"", &d));
    try testing.expectEqualStrings("server.address", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[admin]\naddress = \"999.1.1.1\"", &d));
    var c = try loadFromSlice(testing.allocator, "t.toml", "[server]\naddress = \"::1\"\n[admin]\naddress = \"127.0.0.2\"", &d);
    defer c.deinit();
    try testing.expectEqualStrings("::1", c.server.address);
}

test "admin_configured reflects the presence of an [admin] table" {
    var d: Diagnostic = .{};
    var a = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer a.deinit();
    try testing.expect(!a.admin_configured);
    var b = try loadFromSlice(testing.allocator, "t.toml", "[admin]\nport = 9001", &d);
    defer b.deinit();
    try testing.expect(b.admin_configured);
}

test "no sources is a complete, valid configuration" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.sources.len);
}

test "sources: common keys, defaults and connector options" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml",
        \\[[source]]
        \\name = "my-notes"
        \\kind = "files"
        \\path = "/home/me/notes"
        \\max_file_bytes = 1048576
        \\follow = false
        \\
        \\[[source]]
        \\name = "books_2"
        \\kind = "gutenberg"
        \\enabled = false
        \\retain_text = false
        \\rights = "forbidden"
    , &d);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.sources.len);

    const a = c.sources[0];
    try testing.expectEqualStrings("my-notes", a.name);
    try testing.expectEqualStrings("files", a.kind);
    try testing.expect(a.enabled);
    try testing.expect(a.retain_text);
    try testing.expectEqualStrings("/home/me/notes", a.optionString("path").?);
    try testing.expectEqual(@as(?i64, 1048576), a.optionInt("max_file_bytes"));
    try testing.expectEqual(@as(?bool, false), a.optionBool("follow"));
    try testing.expect(a.option("name") == null); // common keys are not options
    try testing.expect(a.optionString("max_file_bytes") == null); // wrong-type lookup is null

    const b = c.sources[1];
    try testing.expect(!b.enabled);
    try testing.expect(!b.retain_text);
    try testing.expectEqual(@as(?document.Redistribution, .forbidden), b.rights);
    try testing.expectEqual(@as(?document.Redistribution, null), a.rights);
    try testing.expectEqual(@as(usize, 0), b.options.len);
}

test "collections and the anonymous access setting are read and checked" {
    var d: Diagnostic = .{};
    const base = "[[source]]\nname = \"a\"\nkind = \"files\"\n[[source]]\nname = \"b\"\nkind = \"files\"\n";
    var c = try loadFromSlice(testing.allocator, "t.toml", base ++ "[[collection]]\nname = \"mine\"\ndescription = \"my stuff\"\nsources = [\"a\", \"b\"]\n[access]\nanonymous_collections = [\"mine\"]\n", &d);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.collections.len);
    try testing.expectEqualStrings("mine", c.collections[0].name);
    try testing.expectEqualStrings("my stuff", c.collections[0].description);
    try testing.expectEqual(@as(usize, 2), c.collections[0].sources.len);
    try testing.expectEqual(@as(usize, 1), c.access.anonymous_collections.?.len);
    // No access table: everyone sees everything.
    var plain = try loadFromSlice(testing.allocator, "t.toml", base, &d);
    defer plain.deinit();
    try testing.expect(plain.access.anonymous_collections == null);
    try testing.expectEqual(@as(usize, 0), plain.collections.len);
    // An empty list is allowed (nothing without a key).
    var none = try loadFromSlice(testing.allocator, "t.toml", base ++ "[[collection]]\nname = \"mine\"\nsources = [\"a\"]\n[access]\nanonymous_collections = []\n", &d);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.access.anonymous_collections.?.len);
    // Mistakes are named: unknown source, a collection named like a source, duplicates, an unknown collection.
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", base ++ "[[collection]]\nname = \"x\"\nsources = [\"nope\"]\n", &d));
    try testing.expectEqualStrings("collection[0].sources", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", base ++ "[[collection]]\nname = \"a\"\nsources = [\"b\"]\n", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", base ++ "[[collection]]\nname = \"x\"\nsources = [\"a\"]\n[[collection]]\nname = \"x\"\nsources = [\"b\"]\n", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", base ++ "[access]\nanonymous_collections = [\"ghost\"]\n", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", base ++ "[[collection]]\nname = \"x\"\nsources = []\n", &d));
}

test "a document server is read and checked" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "[docserver]\nkind = \"onlyoffice\"\nurl = \"http://127.0.0.1:8090/\"\npublic_url = \"http://172.17.0.1:8080\"\njwt_secret = \"s\"\n", &d);
    defer c.deinit();
    try testing.expectEqualStrings("onlyoffice", c.docserver.?.kind);
    try testing.expectEqualStrings("http://127.0.0.1:8090", c.docserver.?.url);
    try testing.expectEqualStrings("s", c.docserver.?.jwt_secret.?);
    var none = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer none.deinit();
    try testing.expect(none.docserver == null);
    const bad = [_][]const u8{
        "[docserver]\nkind = \"word\"\nurl = \"http://h\"\npublic_url = \"http://p\"\n",
        "[docserver]\nkind = \"collabora\"\nurl = \"http://h/path\"\npublic_url = \"http://p\"\n",
        "[docserver]\nkind = \"collabora\"\nurl = \"http://h\"\n",
        "[docserver]\nkind = \"collabora\"\nurl = \"http://h\"\npublic_url = \"http://p\"\njwt_secret = \"x\"\n",
        "[docserver]\nkind = \"onlyoffice\"\nurl = \"http://h\"\npublic_url = \"http://p\"\njwt_secret = \"x\"\njwt_secret_file = \"y\"\n",
    };
    for (bad) |text| try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", text, &d));
}

test "the node name and peers are read and checked" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "[node]\nname = \"home\"\n[[peer]]\nname = \"office\"\nurl = \"https://search.example.org/\"\nkey_file = \"office.key\"\ntimeout_ms = 800\n[[peer]]\nname = \"lan\"\nurl = \"http://192.168.1.5:8080\"\nkey = \"dkk_x\"\nenabled = false\n", &d);
    defer c.deinit();
    try testing.expectEqualStrings("home", c.node_name);
    try testing.expectEqual(@as(usize, 2), c.peers.len);
    try testing.expectEqualStrings("https://search.example.org", c.peers[0].url);
    try testing.expectEqualStrings("office.key", c.peers[0].key_file.?);
    try testing.expectEqual(@as(u32, 800), c.peers[0].timeout_ms);
    try testing.expect(!c.peers[1].enabled);
    try testing.expectEqual(@as(u32, 1500), c.peers[1].timeout_ms);
    var none = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.peers.len);
    const bad = [_][]const u8{
        "[[peer]]\nname = \"a\"\nurl = \"http://h:1\"\n", // no node name
        "[node]\nname = \"n\"\n[[peer]]\nname = \"a\"\nurl = \"ftp://h\"\n",
        "[node]\nname = \"n\"\n[[peer]]\nname = \"a\"\nurl = \"http://u:p@h\"\n",
        "[node]\nname = \"n\"\n[[peer]]\nname = \"a\"\nurl = \"http://h/path\"\n",
        "[node]\nname = \"n\"\n[[peer]]\nname = \"a\"\nurl = \"http://h\"\nkey = \"x\"\nkey_file = \"y\"\n",
        "[node]\nname = \"n\"\n[[peer]]\nname = \"a\"\nurl = \"http://h\"\n[[peer]]\nname = \"a\"\nurl = \"http://i\"\n",
        "[node]\nname = \"<b>\"\n",
        "[node]\nname = \"n\"\n[[peer]]\nname = \"a\"\nurl = \"http://h\"\ntimeout_ms = 5\n",
    };
    for (bad) |text| try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", text, &d));
}

test "ranking settings and a source's boost are read and checked" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "[search]\ntitle_weight = 5\nbody_weight = 2\nrecency_boost = 30\nrecency_half_life_days = 90\n[[source]]\nname = \"a\"\nkind = \"files\"\nboost = 150\n[[source]]\nname = \"b\"\nkind = \"files\"", &d);
    defer c.deinit();
    try testing.expectEqual(@as(u32, 5), c.search.title_weight);
    try testing.expectEqual(@as(u32, 2), c.search.body_weight);
    try testing.expectEqual(@as(u32, 30), c.search.recency_boost);
    try testing.expectEqual(@as(u32, 90), c.search.recency_half_life_days);
    try testing.expectEqual(@as(u32, 150), c.sources[0].boost);
    try testing.expectEqual(@as(u32, 100), c.sources[1].boost);
    try testing.expectEqual(@as(u32, 0), c.sources[1].schedule_seconds);
    var d2: Diagnostic = .{};
    var sc = try loadFromSlice(testing.allocator, "t.toml", "[[source]]\nname = \"a\"\nkind = \"files\"\nschedule = \"6h\"", &d2);
    defer sc.deinit();
    try testing.expectEqual(@as(u32, 21600), sc.sources[0].schedule_seconds);
    try testing.expectEqualStrings("6h", sc.sources[0].schedule.?);
    try testing.expect(sc.sources[0].option("schedule") == null);
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[[source]]\nname = \"a\"\nkind = \"files\"\nschedule = \"often\"", &d2));
    try testing.expectEqualStrings("source[0].schedule", d2.key());
    try testing.expect(c.sources[0].option("boost") == null);
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[[source]]\nname = \"a\"\nkind = \"files\"\nboost = 0", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[search]\ntitle_weight = 0", &d));
}

test "search table: regex settings are read and checked" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "[search]\nregex = false\nregex_max_pattern = 50\nregex_budget_ms = 100\nregex_concurrency = 1", &d);
    defer c.deinit();
    try testing.expect(!c.search.regex);
    try testing.expectEqual(@as(u32, 50), c.search.regex_max_pattern);
    try testing.expectEqual(@as(u32, 100), c.search.regex_budget_ms);
    try testing.expectEqual(@as(u32, 1), c.search.regex_concurrency);
    try testing.expectEqual(@as(u32, 200), c.search.regex_max_candidates); // default
    var def = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer def.deinit();
    try testing.expect(def.search.regex); // on by default, with strict limits
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[search]\nregex_max_candidates = 0", &d));
    try testing.expectEqualStrings("search.regex_max_candidates", d.key());
    try testing.expectError(error.UnknownKey, loadFromSlice(testing.allocator, "t.toml", "[search]\nregexx = true", &d));
    try testing.expectError(error.WrongType, loadFromSlice(testing.allocator, "t.toml", "[search]\nregex = \"yes\"", &d));
}

test "sources: invalid entries are rejected with the entry and key in the message" {
    var d: Diagnostic = .{};
    const T = testing.allocator;
    try testing.expectError(error.InvalidValue, loadFromSlice(T, "t.toml", "[[source]]\nkind = \"files\"", &d));
    try testing.expectEqualStrings("source[0].name", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(T, "t.toml", "[[source]]\nname = \"a\"\nkind = \"files\"\nrights = \"free\"", &d));
    try testing.expectEqualStrings("source[0].rights", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(T, "t.toml", "[[source]]\nname = \"x\"", &d));
    try testing.expectEqualStrings("source[0].kind", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(T, "t.toml", "[[source]]\nname = \"Bad Name\"\nkind = \"files\"", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(T, "t.toml", "[[source]]\nname = \"-lead\"\nkind = \"files\"", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(T, "t.toml", "[[source]]\nname = \"\"\nkind = \"files\"", &d));
    try testing.expectError(error.WrongType, loadFromSlice(T, "t.toml", "[[source]]\nname = 5\nkind = \"files\"", &d));
    try testing.expectError(error.WrongType, loadFromSlice(T, "t.toml", "[[source]]\nname = \"a\"\nkind = \"files\"\nenabled = \"yes\"", &d));
    try testing.expectEqualStrings("source[0].enabled", d.key());
    try testing.expectError(error.WrongType, loadFromSlice(T, "t.toml", "[[source]]\nname = \"a\"\nkind = \"files\"\npaths = [\"x\"]", &d));
    try testing.expectEqualStrings("source[0].paths", d.key());
    try testing.expectError(error.WrongType, loadFromSlice(T, "t.toml", "[source]\nname = \"a\"", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(T, "t.toml",
        \\[[source]]
        \\name = "dup"
        \\kind = "files"
        \\[[source]]
        \\name = "dup"
        \\kind = "files"
    , &d));
    try testing.expectEqualStrings("source[1].name", d.key());
}

test "admin and access log settings" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer c.deinit();
    try testing.expect(c.server.access_log == null);
    try testing.expect(c.admin.access_log == null);
    try testing.expectEqual(@as(u32, 30), c.admin_options.session_idle_minutes);
    try testing.expectEqual(@as(u32, 8), c.admin_options.session_max_hours);
    try testing.expect(!c.admin_options.cookie_secure);
    try testing.expect(!c.admin_options.actions);
    try testing.expect(c.admin_options.secrets_file == null);

    var c2 = try loadFromSlice(testing.allocator, "t.toml",
        \\[server]
        \\access_log = "stderr"
        \\[admin]
        \\access_log = "/var/log/dk-admin.log"
        \\secrets_file = "/etc/dksearch/secrets.toml"
        \\session_idle_minutes = 5
        \\session_max_hours = 2
        \\cookie_secure = true
        \\actions = true
    , &d);
    defer c2.deinit();
    try testing.expectEqualStrings("stderr", c2.server.access_log.?);
    try testing.expectEqualStrings("/var/log/dk-admin.log", c2.admin.access_log.?);
    try testing.expectEqualStrings("/etc/dksearch/secrets.toml", c2.admin_options.secrets_file.?);
    try testing.expectEqual(@as(u32, 5), c2.admin_options.session_idle_minutes);
    try testing.expect(c2.admin_options.cookie_secure);
    try testing.expect(c2.admin_options.actions);

    // These keys exist only on [admin]; bad values are named.
    try testing.expectError(error.UnknownKey, loadFromSlice(testing.allocator, "t.toml", "[server]\ncookie_secure = true", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\naccess_log = \"/x.log\"\n[admin]\naccess_log = \"/x.log\"", &d));
    try testing.expectEqualStrings("admin.access_log", d.key());
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[admin]\nsession_idle_minutes = 0", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[admin]\nsession_max_hours = 1000", &d));
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[server]\naccess_log = \"\"", &d));
    try testing.expectError(error.WrongType, loadFromSlice(testing.allocator, "t.toml", "[admin]\ncookie_secure = \"yes\"", &d));
}

test "index.tokenizer" {
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "t.toml", "", &d);
    defer c.deinit();
    try testing.expectEqual(Tokenizer.unicode61, c.tokenizer);
    var p = try loadFromSlice(testing.allocator, "t.toml", "[index]\ntokenizer = \"porter\"", &d);
    defer p.deinit();
    try testing.expectEqual(Tokenizer.porter, p.tokenizer);
    try testing.expectError(error.InvalidValue, loadFromSlice(testing.allocator, "t.toml", "[index]\ntokenizer = \"stemmer\"", &d));
    try testing.expectEqualStrings("index.tokenizer", d.key());
    try testing.expectError(error.UnknownKey, loadFromSlice(testing.allocator, "t.toml", "[index]\nstem = true", &d));
}

test "random mutations of a valid configuration never crash the loader" {
    const base =
        \\[server]
        \\address = "127.0.0.1"
        \\port = 8080
        \\[admin]
        \\port = 8081
        \\actions = true
        \\[storage]
        \\data_dir = "data"
        \\[index]
        \\tokenizer = "porter"
        \\[[source]]
        \\name = "notes"
        \\kind = "files"
        \\path = "/tmp/x"
    ;
    var prng = std.Random.DefaultPrng.init(0x7041);
    const rnd = prng.random();
    const inserts = "=\"[]{},.#\n ab1";
    var buf: [base.len + 8]u8 = undefined;
    for (0..3000) |_| {
        @memcpy(buf[0..base.len], base);
        var len: usize = base.len;
        for (0..1 + rnd.uintLessThan(usize, 5)) |_| {
            switch (rnd.uintLessThan(u8, 3)) {
                0 => buf[rnd.uintLessThan(usize, len)] = rnd.int(u8), // overwrite
                1 => { // delete
                    const at = rnd.uintLessThan(usize, len);
                    std.mem.copyForwards(u8, buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
                else => if (len < buf.len) { // insert
                    const at = rnd.uintLessThan(usize, len);
                    std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = inserts[rnd.uintLessThan(usize, inserts.len)];
                    len += 1;
                },
            }
        }
        var d: Diagnostic = .{};
        if (loadFromSlice(testing.allocator, "fuzz.toml", buf[0..len], &d)) |c| {
            var cfg = c;
            cfg.deinit();
        } else |_| {}
    }
}

test "the starter configuration loads, and the admin interface is off until uncommented" {
    const starter = @embedFile("assets/starter.toml");
    var d: Diagnostic = .{};
    var c = try loadFromSlice(testing.allocator, "starter.toml", starter, &d);
    defer c.deinit();
    try testing.expect(!c.admin_configured); // off by default: the block is commented out
    try testing.expectEqual(@as(usize, 0), c.sources.len);
    // Removing the '#' from the [admin] block (and nothing else) makes it valid and on.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var it = std.mem.splitScalar(u8, starter, '\n');
    while (it.next()) |line| {
        const on = std.mem.startsWith(u8, line, "#[admin]") or std.mem.startsWith(u8, line, "#address = \"127.0.0.1\"") or std.mem.startsWith(u8, line, "#port = 8081") or std.mem.startsWith(u8, line, "#actions = true");
        try buf.appendSlice(testing.allocator, if (on) line[1..] else line);
        try buf.append(testing.allocator, '\n');
    }
    var c2 = try loadFromSlice(testing.allocator, "starter-admin.toml", buf.items, &d);
    defer c2.deinit();
    try testing.expect(c2.admin_configured);
    try testing.expectEqual(@as(u16, 8081), c2.admin.port);
    try testing.expect(c2.admin_options.actions);
}
