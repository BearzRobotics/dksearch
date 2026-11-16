//! Getting ZIM files from the Kiwix library: reading its catalogue (OPDS, an Atom feed), reading a
//! file's Metalink (which names the size, the SHA-256 and the mirrors), and downloading it safely.
//!
//! A download goes to `NAME.zim.part` in the chosen folder, can resume after an interruption, is
//! checked against the published SHA-256 and size before it gets its final name, and stops at
//! once when cancelled or when nothing arrives for a minute. Only `https` addresses are used
//! (tests may allow `http` to a local server), and a file the catalogue cannot give a checksum
//! for is refused. Nothing here runs unless the administrator asks for a download.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const xml = @import("xmlzig");
const build_options = @import("build_options");
const connector = @import("connector.zig");

const have_http = build_options.crawler;
const fetch = if (have_http) @import("connectors/crawl/fetch.zig") else struct {};
const cabundle = if (have_http) @import("connectors/crawl/cabundle.zig") else struct {};

pub const catalog_base = "https://library.kiwix.org/catalog/v2/entries";

// ---------------------------------------------------------------------- catalogue

pub const Entry = struct {
    title: []const u8 = "",
    summary: []const u8 = "",
    /// A three-letter language code as the catalogue writes it (`eng`).
    language: []const u8 = "",
    /// The book's name without the date and flavour (`wikipedia_en_ray-charles`).
    name: []const u8 = "",
    /// `maxi` (everything), `nopic` or `mini` (introductions), or empty.
    flavour: []const u8 = "",
    category: []const u8 = "",
    article_count: u64 = 0,
    /// When this version was made (`2026-10-31T00:00:00Z`).
    issued: []const u8 = "",
    /// Size in bytes.
    size: u64 = 0,
    /// The address of the Metalink, which names the file, its checksum and mirrors.
    meta4_url: []const u8 = "",

    /// The file name, from the Metalink address (`wikipedia_en_ray-charles_mini_2026-10.zim`).
    pub fn fileName(self: Entry) ?[]const u8 {
        const base = if (std.mem.lastIndexOfScalar(u8, self.meta4_url, '/')) |i| self.meta4_url[i + 1 ..] else self.meta4_url;
        if (!std.mem.endsWith(u8, base, ".zim.meta4")) return null;
        const name = base[0 .. base.len - ".meta4".len];
        return if (validFileName(name)) name else null;
    }
};

pub const Catalog = struct {
    /// How many entries match in all (the page holds some of them).
    total: u64,
    entries: []const Entry,
};

const ns_atom = "http://www.w3.org/2005/Atom";
const ns_dcterms = "http://purl.org/dc/terms/";
const ns_opensearch = "http://a9.com/-/spec/opensearch/1.1/";
const rel_acquisition = "http://opds-spec.org/acquisition/open-access";

pub const ParseError = error{ BadCatalog, OutOfMemory };

fn attrOf(attrs: []const xml.Attribute, name: []const u8) ?[]const u8 {
    for (attrs) |a| if (a.name.uri.len == 0 and std.mem.eql(u8, a.name.local, name)) return a.value;
    return null;
}

/// File names are what a catalogue gives, so they are checked: letters, digits, `.`, `-`, `_`, ending
/// in `.zim`, never a path.
pub fn validFileName(name: []const u8) bool {
    if (name.len < 5 or name.len > 200 or !std.mem.endsWith(u8, name, ".zim")) return false;
    if (name[0] == '.' or name[0] == '-') return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return false;
    return std.mem.indexOf(u8, name, "..") == null;
}

/// Reads one page of the OPDS catalogue.
pub fn parseCatalog(arena: Allocator, bytes: []const u8) ParseError!Catalog {
    var src: Io.Reader = .fixed(bytes);
    var rd = xml.Reader.init(arena, &src, .{ .doctype = .reject, .max_token_bytes = 1024 * 1024 }, null);
    defer rd.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    var total: u64 = 0;
    var cur: Entry = .{};
    var in_entry = false;
    var in_person: u32 = 0; // inside author or publisher, whose `name` is not the book's
    const Field = enum { none, title, summary, language, name, flavour, category, article_count, issued, total };
    var field: Field = .none;
    while (true) {
        const ev = rd.next() catch return error.BadCatalog;
        switch (ev) {
            .start_element => |s| {
                field = .none;
                if (s.name.is(ns_atom, "entry")) {
                    in_entry = true;
                    cur = .{};
                } else if (!in_entry) {
                    // The feed's default namespace is Atom, so the count may be in either.
                    if (s.name.is(ns_opensearch, "totalResults") or s.name.is(ns_atom, "totalResults")) field = .total;
                } else if (s.name.is(ns_atom, "author") or s.name.is(ns_atom, "publisher")) {
                    in_person += 1;
                } else if (in_person == 0) {
                    if (s.name.is(ns_atom, "title")) field = .title else if (s.name.is(ns_atom, "summary")) field = .summary else if (s.name.is(ns_atom, "language")) field = .language else if (s.name.is(ns_atom, "name")) field = .name else if (s.name.is(ns_atom, "flavour")) field = .flavour else if (s.name.is(ns_atom, "category")) field = .category else if (s.name.is(ns_atom, "articleCount")) field = .article_count else if (s.name.is(ns_dcterms, "issued")) field = .issued else if (s.name.is(ns_atom, "link")) {
                        const rel = attrOf(s.attributes, "rel") orelse "";
                        if (std.mem.eql(u8, rel, rel_acquisition)) {
                            if (attrOf(s.attributes, "href")) |h| cur.meta4_url = try arena.dupe(u8, h);
                            if (attrOf(s.attributes, "length")) |l| cur.size = std.fmt.parseInt(u64, l, 10) catch 0;
                        }
                    }
                }
            },
            .end_element => |e| {
                field = .none;
                if (e.name.is(ns_atom, "entry")) {
                    in_entry = false;
                    // Only what can be downloaded is useful here.
                    if (cur.meta4_url.len > 0 and cur.fileName() != null) try entries.append(arena, cur);
                } else if (e.name.is(ns_atom, "author") or e.name.is(ns_atom, "publisher")) {
                    if (in_person > 0) in_person -= 1;
                }
            },
            .text => |t| {
                const v = std.mem.trim(u8, t, " \t\r\n");
                if (v.len == 0) continue;
                switch (field) {
                    .none => {},
                    .total => total = std.fmt.parseInt(u64, v, 10) catch 0,
                    .title => cur.title = try arena.dupe(u8, v),
                    .summary => cur.summary = try arena.dupe(u8, v),
                    .language => cur.language = try arena.dupe(u8, v),
                    .name => cur.name = try arena.dupe(u8, v),
                    .flavour => cur.flavour = try arena.dupe(u8, v),
                    .category => cur.category = try arena.dupe(u8, v),
                    .article_count => cur.article_count = std.fmt.parseInt(u64, v, 10) catch 0,
                    .issued => cur.issued = try arena.dupe(u8, v),
                }
            },
            .end_of_document => break,
            else => {},
        }
    }
    return .{ .total = total, .entries = entries.items };
}

// ---------------------------------------------------------------------- metalink

pub const Metalink = struct {
    file_name: []const u8,
    size: u64,
    sha256: [32]u8,
    /// Mirrors, best first.
    urls: []const []const u8,
};

const ns_metalink = "urn:ietf:params:xml:ns:metalink";

pub fn parseMetalink(arena: Allocator, bytes: []const u8) ParseError!Metalink {
    var src: Io.Reader = .fixed(bytes);
    var rd = xml.Reader.init(arena, &src, .{ .doctype = .reject, .max_token_bytes = 1024 * 1024 }, null);
    defer rd.deinit();
    var name: ?[]const u8 = null;
    var size: ?u64 = null;
    var sha: ?[32]u8 = null;
    const Url = struct { priority: u32, url: []const u8 };
    var urls: std.ArrayList(Url) = .empty;
    const Field = enum { none, size, sha256, url };
    var field: Field = .none;
    var url_priority: u32 = 1000;
    var in_pieces = false;
    while (true) {
        const ev = rd.next() catch return error.BadCatalog;
        switch (ev) {
            .start_element => |s| {
                field = .none;
                if (s.name.is(ns_metalink, "file")) {
                    if (name == null) if (attrOf(s.attributes, "name")) |n| {
                        name = try arena.dupe(u8, n);
                    };
                } else if (s.name.is(ns_metalink, "pieces")) {
                    in_pieces = true;
                } else if (!in_pieces and s.name.is(ns_metalink, "size")) {
                    field = .size;
                } else if (!in_pieces and s.name.is(ns_metalink, "hash")) {
                    if (attrOf(s.attributes, "type")) |t| if (std.ascii.eqlIgnoreCase(t, "sha-256")) {
                        field = .sha256;
                    };
                } else if (s.name.is(ns_metalink, "url")) {
                    field = .url;
                    url_priority = if (attrOf(s.attributes, "priority")) |p| (std.fmt.parseInt(u32, p, 10) catch 1000) else 1000;
                }
            },
            .end_element => |e| {
                field = .none;
                if (e.name.is(ns_metalink, "pieces")) in_pieces = false;
            },
            .text => |t| {
                const v = std.mem.trim(u8, t, " \t\r\n");
                if (v.len == 0) continue;
                switch (field) {
                    .none => {},
                    .size => size = std.fmt.parseInt(u64, v, 10) catch null,
                    .sha256 => {
                        if (v.len == 64) {
                            var out: [32]u8 = undefined;
                            if (std.fmt.hexToBytes(&out, v)) |_| sha = out else |_| {}
                        }
                    },
                    .url => if (urls.items.len < 64) try urls.append(arena, .{ .priority = url_priority, .url = try arena.dupe(u8, v) }),
                }
            },
            .end_of_document => break,
            else => {},
        }
    }
    std.mem.sort(Url, urls.items, {}, struct {
        fn lt(_: void, a: Url, b: Url) bool {
            return a.priority < b.priority;
        }
    }.lt);
    const out_urls = try arena.alloc([]const u8, urls.items.len);
    for (urls.items, out_urls) |u, *o| o.* = u.url;
    return .{
        .file_name = name orelse return error.BadCatalog,
        .size = size orelse return error.BadCatalog,
        // A file without a published checksum cannot be verified, so it is not offered.
        .sha256 = sha orelse return error.BadCatalog,
        .urls = out_urls,
    };
}

// ---------------------------------------------------------------------- downloading

pub const Error = error{
    /// Built without network support.
    NotAvailable,
    /// The catalogue's answer cannot be used (no checksum, a different name or size).
    BadCatalog,
    BadName,
    /// The file is already there.
    Exists,
    Network,
    Tls,
    /// The downloaded file does not match the published checksum or size.
    Checksum,
    Cancelled,
    /// Nothing arrived for too long.
    Stalled,
    TooManyRedirects,
    /// The server refused (not found, forbidden, ...).
    Refused,
    Io,
    OutOfMemory,
};

pub const Options = struct {
    user_agent: []const u8 = "dksearch-zim-downloader/0.1 (a personal search index; https://github.com/BearzRobotics/dksearch)",
    /// Allow `http://` addresses. Only for tests against a local server.
    allow_http: bool = false,
    /// Give up when nothing has arrived for this long.
    stall_seconds: u32 = 60,
    max_redirects: u32 = 5,
};

pub const Request = struct {
    /// The Metalink address from the catalogue.
    meta4_url: []const u8,
    /// The folder to put the file in (it must exist).
    dest_dir: []const u8,
    /// The file name the catalogue gave (checked against the Metalink).
    file_name: []const u8,
    /// The size the catalogue gave, or 0 if unknown (checked against the Metalink).
    size: u64 = 0,
};

fn schemeOk(url: []const u8, options: Options) bool {
    if (std.mem.startsWith(u8, url, "https://")) return true;
    return options.allow_http and std.mem.startsWith(u8, url, "http://");
}

/// Fetches a small document (a catalogue page or a Metalink) following redirects.
pub fn fetchText(gpa: Allocator, io: Io, arena: Allocator, url: []const u8, max_bytes: usize, options: Options) Error![]const u8 {
    if (!have_http) return error.NotAvailable;
    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    cabundle.load(&client.ca_bundle, gpa, io, .builtin) catch return error.Tls;
    client.now = Io.Clock.real.now(io);
    var current = url;
    var hops: u32 = 0;
    while (true) {
        if (!schemeOk(current, options)) return error.BadCatalog;
        const r = fetch.get(&client, arena, .{ .url = current, .user_agent = options.user_agent, .accept = "application/atom+xml, application/metalink4+xml, */*", .max_body_bytes = max_bytes }, .{ .nanoseconds = 30 * std.time.ns_per_s }) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Tls => error.Tls,
            error.Canceled => error.Cancelled,
            error.TooLarge => error.BadCatalog,
            else => error.Network,
        };
        if (r.status >= 300 and r.status < 400) {
            hops += 1;
            if (hops > options.max_redirects) return error.TooManyRedirects;
            current = resolveLocation(arena, current, r.location orelse return error.BadCatalog) catch return error.OutOfMemory;
            continue;
        }
        if (r.status != 200) return error.Refused;
        return r.body;
    }
}

/// `location` against `base` (an absolute address or an absolute path).
fn resolveLocation(arena: Allocator, base: []const u8, location: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, location, "://") != null) return arena.dupe(u8, location);
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return arena.dupe(u8, location)) + 3;
    const host_end = std.mem.indexOfScalarPos(u8, base, scheme_end, '/') orelse base.len;
    if (location.len > 0 and location[0] == '/') return std.fmt.allocPrint(arena, "{s}{s}", .{ base[0..host_end], location });
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base[0..host_end], location });
}

const Activity = struct { last_ns: std.atomic.Value(i64) = .init(0) };

fn nowNs(io: Io) i64 {
    return @intCast(Io.Timestamp.now(io, .awake).nanoseconds);
}

const Task = union(enum) {
    done: Error!u64,
    watch: Error,
};

fn watchTask(io: Io, control: *connector.Control, activity: *Activity, stall_seconds: u32) Error {
    while (true) {
        io.sleep(.{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch return error.Cancelled;
        if (control.isCancelled()) return error.Cancelled;
        if (nowNs(io) - activity.last_ns.load(.monotonic) > @as(i64, stall_seconds) * std.time.ns_per_s) return error.Stalled;
    }
}

/// Downloads the file named by `req`. Returns the final path (allocated from `arena`).
pub fn download(gpa: Allocator, io: Io, arena: Allocator, req: Request, control: *connector.Control, options: Options) Error![]const u8 {
    if (!have_http) return error.NotAvailable;
    if (!validFileName(req.file_name)) return error.BadName;
    if (!schemeOk(req.meta4_url, options)) return error.BadCatalog;
    const final = std.fmt.allocPrint(arena, "{s}/{s}", .{ req.dest_dir, req.file_name }) catch return error.OutOfMemory;
    const part = std.fmt.allocPrint(arena, "{s}/{s}.part", .{ req.dest_dir, req.file_name }) catch return error.OutOfMemory;
    if (Io.Dir.cwd().access(io, final, .{})) |_| return error.Exists else |_| {}

    // What the catalogue says must agree with the Metalink, which carries the checksum.
    const meta_bytes = try fetchText(gpa, io, arena, req.meta4_url, 1024 * 1024, options);
    const meta = parseMetalink(arena, meta_bytes) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadCatalog => error.BadCatalog,
    };
    if (!std.mem.eql(u8, meta.file_name, req.file_name)) return error.BadCatalog;
    if (req.size != 0 and meta.size != req.size) return error.BadCatalog;
    if (meta.urls.len == 0) return error.BadCatalog;

    control.setProgress(0, meta.size);
    var last_err: Error = error.Network;
    var tried: usize = 0;
    for (meta.urls) |mirror| {
        if (!schemeOk(mirror, options)) continue;
        if (tried >= 4) break; // a few mirrors, not all of them
        tried += 1;
        if (control.isCancelled()) return error.Cancelled;
        var activity: Activity = .{};
        activity.last_ns.store(nowNs(io), .monotonic);
        var buffer: [2]Task = undefined;
        var select: Io.Select(Task) = .init(io, &buffer);
        select.concurrent(.done, attempt, .{ gpa, io, arena, mirror, part, meta, control, &activity, options }) catch return error.Network;
        select.concurrent(.watch, watchTask, .{ io, control, &activity, options.stall_seconds }) catch {
            select.cancelDiscard();
            return error.Network;
        };
        const first = select.await() catch {
            select.cancelDiscard();
            return error.Cancelled;
        };
        select.cancelDiscard();
        switch (first) {
            .watch => |e| return e, // cancelled or stalled: the partial file stays for resuming
            .done => |r| if (r) |_| {
                Io.Dir.cwd().rename(part, Io.Dir.cwd(), final, io) catch return error.Io;
                return final;
            } else |e| {
                last_err = e;
                // A wrong checksum is the file's fault, not the mirror's: do not try another with the same bytes
                // kept; remove the partial file so the next attempt starts clean.
                if (e == error.Checksum) {
                    Io.Dir.cwd().deleteFile(io, part) catch {};
                    return e;
                }
                if (e == error.Cancelled or e == error.OutOfMemory or e == error.Io) return e;
            },
        }
    }
    return last_err;
}

/// One attempt from one mirror: resumes a partial file, verifies, and returns the number of bytes.
fn attempt(gpa: Allocator, io: Io, arena: Allocator, start_url: []const u8, part: []const u8, meta: Metalink, control: *connector.Control, activity: *Activity, options: Options) Error!u64 {
    var file = Io.Dir.cwd().createFile(io, part, .{ .truncate = false, .read = true }) catch return error.Io;
    defer file.close(io);
    var have = file.length(io) catch return error.Io;
    if (have > meta.size) {
        file.setLength(io, 0) catch return error.Io;
        have = 0;
    }

    var client: http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    cabundle.load(&client.ca_bundle, gpa, io, .builtin) catch return error.Tls;
    client.now = Io.Clock.real.now(io);

    var current = start_url;
    var hops: u32 = 0;
    while (true) {
        if (!schemeOk(current, options)) return error.BadCatalog;
        const uri = std.Uri.parse(current) catch return error.BadCatalog;
        const range: ?[]const u8 = if (have > 0) (std.fmt.allocPrint(arena, "bytes={d}-", .{have}) catch return error.OutOfMemory) else null;
        var extra_buf: [1]http.Header = undefined;
        const extra: []const http.Header = if (range) |rg| blk: {
            extra_buf[0] = .{ .name = "range", .value = rg };
            break :blk extra_buf[0..1];
        } else &.{};
        var request = client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{ .user_agent = .{ .override = options.user_agent } },
            .extra_headers = extra,
        }) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Cancelled,
            else => error.Network,
        };
        defer request.deinit();
        request.sendBodiless() catch return error.Network;
        var redirect_buffer: [0]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch |e| return switch (e) {
            error.Canceled => error.Cancelled,
            else => error.Network,
        };
        const status: u16 = @backingInt(response.head.status);
        if (status >= 300 and status < 400) {
            hops += 1;
            if (hops > options.max_redirects) return error.TooManyRedirects;
            const loc = response.head.location orelse return error.BadCatalog;
            current = resolveLocation(arena, current, loc) catch return error.OutOfMemory;
            continue;
        }
        if (status == 416) { // the partial file is not usable: start again from nothing
            file.setLength(io, 0) catch return error.Io;
            have = 0;
            continue;
        }
        if (status != 200 and status != 206) return error.Refused;
        // A server that ignored the Range header sends the whole file again.
        if (status == 200 and have > 0) {
            file.setLength(io, 0) catch return error.Io;
            have = 0;
        }

        // The checksum covers the whole file, so what is already there is read through it first.
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        {
            var pos: u64 = 0;
            var rbuf: [64 * 1024]u8 = undefined;
            while (pos < have) {
                var bufs = [_][]u8{rbuf[0..@intCast(@min(rbuf.len, have - pos))]};
                const n = file.readPositional(io, &bufs, pos) catch return error.Io;
                if (n == 0) return error.Io;
                hasher.update(rbuf[0..n]);
                pos += n;
            }
        }

        var transfer: [64]u8 = undefined;
        const body = response.reader(&transfer);
        var chunk: [64 * 1024]u8 = undefined;
        var done = have;
        while (true) {
            const n = body.readSliceShort(&chunk) catch return error.Network;
            if (n == 0) break;
            if (done + n > meta.size) return error.Checksum; // more than the file can be
            file.writePositionalAll(io, chunk[0..n], done) catch return error.Io;
            hasher.update(chunk[0..n]);
            done += n;
            control.setProgress(done, meta.size);
            activity.last_ns.store(nowNs(io), .monotonic);
        }
        if (done != meta.size) return error.Network; // cut short: the partial file stays for a retry
        file.sync(io) catch return error.Io;
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        if (!std.mem.eql(u8, &digest, &meta.sha256)) return error.Checksum;
        return done;
    }
}

const testing = std.testing;

test "the catalogue page: entries with their sizes and file names, and the total" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cat = try parseCatalog(arena.allocator(), @embedFile("testdata/kiwix/catalog.xml"));
    try testing.expectEqual(@as(u64, 3), cat.total);
    try testing.expectEqual(@as(usize, 2), cat.entries.len);
    const e = cat.entries[0];
    try testing.expectEqualStrings("Ray Charles", e.title);
    try testing.expectEqualStrings("eng", e.language);
    try testing.expectEqualStrings("maxi", e.flavour);
    try testing.expectEqualStrings("wikipedia", e.category);
    try testing.expectEqualStrings("wikipedia_en_ray-charles", e.name); // not the author's name
    try testing.expectEqual(@as(u64, 25572), e.article_count);
    try testing.expectEqual(@as(u64, 29887488), e.size);
    try testing.expectEqualStrings("2026-10-31T00:00:00Z", e.issued);
    try testing.expectEqualStrings("wikipedia_en_ray-charles_maxi_2026-10.zim", e.fileName().?);
    try testing.expectEqualStrings("mini", cat.entries[1].flavour);
}

test "bad or hostile catalogue pages are errors, and entries with unusable file names are left out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BadCatalog, parseCatalog(a, "not xml"));
    try testing.expectError(error.BadCatalog, parseCatalog(a, "<!DOCTYPE x [<!ENTITY e \"v\">]><feed/>"));
    const bad_name = parseCatalog(a,
        \\<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>x</title>
        \\<link rel="http://opds-spec.org/acquisition/open-access" href="https://h/zim/a b.zim.meta4" length="5"/></entry>
        \\<entry><title>y</title><link rel="http://opds-spec.org/acquisition/open-access" href="https://h/zim/ok_2026-01.zim.meta4" length="5"/></entry></feed>
    );
    const cat = try bad_name;
    try testing.expectEqual(@as(usize, 1), cat.entries.len);
    try testing.expectEqualStrings("ok_2026-01.zim", cat.entries[0].fileName().?);
    try testing.expect(validFileName("a_b-c.2026-01.zim"));
    for ([_][]const u8{ "", ".zim", "../a.zim", "a/b.zim", "a b.zim", "a.zip", ".hidden.zim", "-x.zim", "a..b.zim" }) |bad| try testing.expect(!validFileName(bad));
}

test "the Metalink: size, SHA-256 and mirrors in priority order; piece hashes are not the file's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try parseMetalink(arena.allocator(), @embedFile("testdata/kiwix/sample.meta4"));
    try testing.expectEqualStrings("wikipedia_en_ray-charles_mini_2026-10.zim", m.file_name);
    try testing.expectEqual(@as(u64, 26229009), m.size);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{m.sha256}) catch unreachable;
    try testing.expectEqualStrings("ad37a9355a356b12cc4f2e339fcd15940dd93099de0c2851b6a25cc5b9c33c31", &hex);
    try testing.expect(m.urls.len >= 3);
    try testing.expect(std.mem.startsWith(u8, m.urls[0], "https://"));
    // Without a SHA-256 there is nothing to verify against: refused.
    try testing.expectError(error.BadCatalog, parseMetalink(arena.allocator(), "<metalink xmlns=\"urn:ietf:params:xml:ns:metalink\"><file name=\"a.zim\"><size>5</size><url>https://x/a.zim</url></file></metalink>"));
}

test "locations are resolved against the address that redirected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https://b.example/y.zim", try resolveLocation(a, "https://a.example/x.zim", "https://b.example/y.zim"));
    try testing.expectEqualStrings("https://a.example/z/y.zim", try resolveLocation(a, "https://a.example/x.zim", "/z/y.zim"));
}

const nettest = @import("connectors/nettest.zig");

fn filler(a: Allocator, pattern: []const u8, times: usize) ![]const u8 {
    const out = try a.alloc(u8, pattern.len * times);
    for (0..times) |i| @memcpy(out[i * pattern.len ..][0..pattern.len], pattern);
    return out;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{d}) catch unreachable;
    return out;
}

fn metalinkFor(arena: Allocator, name: []const u8, body: []const u8, sha: []const u8, port: u16) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\<?xml version="1.0"?><metalink xmlns="urn:ietf:params:xml:ns:metalink"><file name="{s}"><size>{d}</size>
        \\<hash type="sha-256">{s}</hash><pieces length="4" type="sha-1"><hash>00</hash></pieces>
        \\<url priority="1">http://127.0.0.1:{d}/mirror1/{s}</url><url priority="2">http://127.0.0.1:{d}/mirror2/{s}</url></file></metalink>
    , .{ name, body.len, sha, port, name, port, name });
}

test "a download is verified, kept under its own name, and the partial file is gone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try filler(a, "pretend this is a ZIM file ", 3000);
    var server: nettest.TestServer = undefined;
    try server.open();
    const sha = sha256Hex(content);
    const meta = try metalinkFor(a, "t_2026-01.zim", content, &sha, server.port);
    try server.serve(&.{
        .{ .path = "/t_2026-01.zim.meta4", .body = meta, .content_type = "application/metalink4+xml" },
        .{ .path = "/mirror1/t_2026-01.zim", .body = content, .content_type = "application/x-zim" },
    });
    defer server.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var url_buf: [64]u8 = undefined;
    var ctl: connector.Control = .{};
    const path = try download(testing.allocator, testing.io, a, .{
        .meta4_url = server.url(&url_buf, "/t_2026-01.zim.meta4"),
        .dest_dir = dir,
        .file_name = "t_2026-01.zim",
        .size = content.len,
    }, &ctl, .{ .allow_http = true });
    try testing.expect(std.mem.endsWith(u8, path, "/t_2026-01.zim"));
    const got = try tmp.dir.readFileAlloc(testing.io, "t_2026-01.zim", a, .limited(1 << 20));
    try testing.expectEqualStrings(content, got);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "t_2026-01.zim.part", .{}));
    try testing.expectEqual(@as(u64, content.len), ctl.progress_done.load(.monotonic));
    // The file is there now: a second download is refused rather than overwriting it.
    try testing.expectError(error.Exists, download(testing.allocator, testing.io, a, .{ .meta4_url = server.url(&url_buf, "/t_2026-01.zim.meta4"), .dest_dir = dir, .file_name = "t_2026-01.zim" }, &ctl, .{ .allow_http = true }));
}

test "a wrong checksum is refused and nothing is kept; a stale partial file is replaced; names must agree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = "the real bytes of the file ";
    var server: nettest.TestServer = undefined;
    try server.open();
    const wrong_sha = sha256Hex("something else");
    const bad_meta = try metalinkFor(a, "bad_2026-01.zim", content, &wrong_sha, server.port);
    const good_sha = sha256Hex(content);
    const good_meta = try metalinkFor(a, "good_2026-01.zim", content, &good_sha, server.port);
    const size_meta = try metalinkFor(a, "size_2026-01.zim", content, &good_sha, server.port);
    try server.serve(&.{
        .{ .path = "/size_2026-01.zim.meta4", .body = size_meta },
        .{ .path = "/bad_2026-01.zim.meta4", .body = bad_meta },
        .{ .path = "/mirror1/bad_2026-01.zim", .body = content },
        .{ .path = "/good_2026-01.zim.meta4", .body = good_meta },
        // This server does not understand Range and sends everything again.
        .{ .path = "/mirror1/good_2026-01.zim", .body = content },
    });
    defer server.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var url_buf: [64]u8 = undefined;
    var ctl: connector.Control = .{};
    try testing.expectError(error.Checksum, download(testing.allocator, testing.io, a, .{ .meta4_url = server.url(&url_buf, "/bad_2026-01.zim.meta4"), .dest_dir = dir, .file_name = "bad_2026-01.zim" }, &ctl, .{ .allow_http = true }));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "bad_2026-01.zim", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "bad_2026-01.zim.part", .{}));

    // An older, different partial file is not trusted: the whole file is fetched and verified.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "good_2026-01.zim.part", .data = "garbage that is not a prefix" });
    const path = try download(testing.allocator, testing.io, a, .{ .meta4_url = server.url(&url_buf, "/good_2026-01.zim.meta4"), .dest_dir = dir, .file_name = "good_2026-01.zim", .size = content.len }, &ctl, .{ .allow_http = true });
    try testing.expect(path.len > 0);
    try testing.expectEqualStrings(content, try tmp.dir.readFileAlloc(testing.io, "good_2026-01.zim", a, .limited(1 << 20)));

    // The catalogue and the Metalink must name the same file and size; names must be plain.
    try testing.expectError(error.BadCatalog, download(testing.allocator, testing.io, a, .{ .meta4_url = server.url(&url_buf, "/good_2026-01.zim.meta4"), .dest_dir = dir, .file_name = "other_2026-01.zim" }, &ctl, .{ .allow_http = true }));
    try testing.expectError(error.BadCatalog, download(testing.allocator, testing.io, a, .{ .meta4_url = server.url(&url_buf, "/size_2026-01.zim.meta4"), .dest_dir = dir, .file_name = "size_2026-01.zim", .size = 1 }, &ctl, .{ .allow_http = true }));
    try testing.expectError(error.BadName, download(testing.allocator, testing.io, a, .{ .meta4_url = "https://x/a.meta4", .dest_dir = dir, .file_name = "../evil.zim" }, &ctl, .{}));
    // Plain http is refused unless a test allows it.
    try testing.expectError(error.BadCatalog, download(testing.allocator, testing.io, a, .{ .meta4_url = "http://127.0.0.1:1/a.zim.meta4", .dest_dir = dir, .file_name = "a.zim" }, &ctl, .{}));
}

test "a cancelled download stops at once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = try filler(a, "bytes ", 1000);
    var server: nettest.TestServer = undefined;
    try server.open();
    const sha = sha256Hex(content);
    const meta = try metalinkFor(a, "c_2026-01.zim", content, &sha, server.port);
    try server.serve(&.{
        .{ .path = "/c_2026-01.zim.meta4", .body = meta },
        .{ .path = "/mirror1/c_2026-01.zim", .body = content },
    });
    defer server.stop();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var url_buf: [64]u8 = undefined;
    var ctl: connector.Control = .{};
    ctl.cancel();
    try testing.expectError(error.Cancelled, download(testing.allocator, testing.io, a, .{ .meta4_url = server.url(&url_buf, "/c_2026-01.zim.meta4"), .dest_dir = dir, .file_name = "c_2026-01.zim" }, &ctl, .{ .allow_http = true }));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "c_2026-01.zim", .{}));
}
