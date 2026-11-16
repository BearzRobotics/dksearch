//! What each kind of source accepts, as data: the key, a label, the kind of value, its range and
//! default, and one line of help. The admin panel builds its form fields from this and turns the
//! posted fields back into the `key = value` lines of the configuration file; the connectors
//! still validate everything on save, so this table only has to describe, not enforce.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Type = enum { text, path, number, flag };

pub const Option = struct {
    key: []const u8,
    label: []const u8,
    type: Type,
    help: []const u8,
    required: bool = false,
    /// What happens when it is left out (shown as a hint).
    default: []const u8 = "",
    placeholder: []const u8 = "",
    min: i64 = 0,
    max: i64 = 0,
    /// A flag that is on unless the file says otherwise.
    default_on: bool = false,
};

const lang = Option{ .key = "language", .label = "Language", .type = .text, .help = "A language tag such as en or pt-BR, stored on every document.", .placeholder = "en" };
const delay = Option{ .key = "delay_ms", .label = "Delay between requests (ms)", .type = .number, .min = 100, .max = 3600000, .default = "1000", .help = "Least time between two requests to the same site. Be gentle." };
const timeout = Option{ .key = "timeout_seconds", .label = "Request timeout (seconds)", .type = .number, .min = 1, .max = 300, .default = "30", .help = "How long one request may take." };
const ca = Option{ .key = "ca_bundle", .label = "Certificates", .type = .text, .default = "builtin", .placeholder = "builtin", .help = "builtin, system, or the path of a PEM file: which certificates HTTPS sites are checked against." };
const user_agent = Option{ .key = "user_agent", .label = "User agent", .type = .text, .required = true, .placeholder = "mysearch/1.0 (+https://example.org/about)", .help = "Who you are, so site owners can reach you: a product name and a way to contact you. There is no default." };

const files = [_]Option{
    .{ .key = "path", .label = "Folder", .type = .path, .required = true, .placeholder = "/home/me/notes", .help = "The folder to index, including its subfolders." },
    .{ .key = "pdf_text", .label = "Also index PDFs", .type = .flag, .help = "Needs the pdftotext program (Ubuntu: sudo apt install poppler-utils). Reads the text layer only; scans are skipped." },
    .{ .key = "pdf_workers", .label = "PDF workers", .type = .number, .min = 1, .max = 32, .default = "4", .help = "How many pdftotext programs run at once. Raise it for a big library." },
    .{ .key = "office", .label = "Also index Word, OpenDocument and EPUB files", .type = .flag, .help = "docx, odt and epub, by their text and their own title and author. No outside program needed." },
    .{ .key = "html", .label = "Also index HTML files", .type = .flag, .help = "html and htm files as web pages (UTF-8 only)." },
    .{ .key = "media", .label = "Also index audio and video", .type = .flag, .help = "By their tags, with subtitle and lyrics files next to them. Needs the ffprobe program (Ubuntu: sudo apt install ffmpeg)." },
    .{ .key = "serve_originals", .label = "Let results open the original files", .type = .flag, .help = "PDFs and images open in the browser from this server. Only for folders anyone who can reach the search page may read. Read at server start." },
    .{ .key = "max_file_bytes", .label = "Largest file or text (bytes)", .type = .number, .min = 1, .max = 67108864, .default = "4194304", .help = "Larger files are skipped, never cut. Raise it for long books." },
    lang,
};

const gutenberg = [_]Option{
    .{ .key = "catalog", .label = "Catalog file", .type = .path, .required = true, .placeholder = "/data/pg_catalog.csv", .help = "The Project Gutenberg catalog CSV." },
    .{ .key = "books", .label = "Books folder", .type = .path, .required = true, .placeholder = "/data/books", .help = "The folder holding the book text files." },
    .{ .key = "language", .label = "Only this language", .type = .text, .placeholder = "en", .help = "Only import books in this language. Empty means all." },
    .{ .key = "max_file_bytes", .label = "Largest book (bytes)", .type = .number, .min = 1, .max = 67108864, .default = "16777216", .help = "Larger books are refused, never cut." },
};

const wikipedia = [_]Option{
    .{ .key = "dump", .label = "Dump file", .type = .path, .required = true, .placeholder = "/data/enwiki-latest-pages-articles-multistream.xml.bz2", .help = "A .bz2 or plain .xml Wikipedia dump." },
    .{ .key = "dataset_version", .label = "Dump label", .type = .text, .placeholder = "enwiki-20260101", .help = "A label for the dump, such as its date, stored on each document." },
    .{ .key = "language", .label = "Language", .type = .text, .default = "en", .placeholder = "en", .help = "Language tag stored on each article." },
    .{ .key = "url_base", .label = "Article address prefix", .type = .text, .placeholder = "https://en.wikipedia.org/wiki/", .help = "Where articles can be read; must start with http:// or https:// and end in /." },
    .{ .key = "max_article_bytes", .label = "Largest article (bytes)", .type = .number, .min = 1, .max = 67108864, .default = "8388608", .help = "Larger articles are refused." },
};

const zim = [_]Option{
    .{ .key = "path", .label = "ZIM file", .type = .path, .required = true, .placeholder = "/data/wikipedia_en_all_maxi.zim", .help = "A .zim file from the Kiwix project (format 5 or 6)." },
    .{ .key = "serve_articles", .label = "Show articles from the file", .type = .flag, .default_on = true, .help = "Results open the article itself, with its pictures and links, from this server. Read at server start." },
    .{ .key = "url_base", .label = "Kiwix server address", .type = .text, .placeholder = "http://localhost:8080/content/wikipedia_en_all_maxi/", .help = "Optional: link results to a Kiwix server instead (must start with http:// or https:// and end in /)." },
    lang,
    .{ .key = "max_article_bytes", .label = "Largest article (bytes)", .type = .number, .min = 1, .max = 67108864, .default = "4194304", .help = "Larger articles are skipped." },
    .{ .key = "max_cluster_bytes", .label = "Largest cluster (bytes)", .type = .number, .min = 1, .max = 1073741824, .default = "134217728", .help = "Largest decompressed block accepted." },
};

const feeds = [_]Option{
    .{ .key = "path", .label = "Feed file or folder", .type = .path, .required = true, .placeholder = "/srv/feeds", .help = "An RSS or Atom file, or a folder of them (fetch them yourself, for example with a scheduled curl)." },
    .{ .key = "language", .label = "Language", .type = .text, .placeholder = "en", .help = "Overrides the language a feed declares." },
    .{ .key = "max_file_bytes", .label = "Largest feed file (bytes)", .type = .number, .min = 1, .max = 67108864, .default = "16777216", .help = "Larger files are refused." },
};

const crawl = [_]Option{
    .{ .key = "seeds_file", .label = "Seeds file", .type = .path, .required = true, .placeholder = "/etc/dksearch/seeds.txt", .help = "A text file with one address per line (or: sitemap ADDRESS)." },
    user_agent,
    .{ .key = "max_depth", .label = "Link depth", .type = .number, .min = 0, .max = 10, .default = "3", .help = "How many links deep to follow from each address. 0 fetches only the listed pages." },
    .{ .key = "max_pages", .label = "Most pages per run", .type = .number, .min = 1, .max = 1000000, .default = "1000", .help = "The run ends normally when this is reached; raise it to crawl more." },
    delay,
    .{ .key = "follow_external", .label = "Follow links to other sites", .type = .flag, .help = "Each new site gets its own robots.txt check and delay." },
    .{ .key = "allow_private_addresses", .label = "Allow private and local addresses", .type = .flag, .help = "Only with the option above; seeds you list yourself are always fetched." },
    .{ .key = "max_hosts", .label = "Most other sites per run", .type = .number, .min = 1, .max = 100000, .default = "100", .help = "Sites found by following links; sites you list are not counted." },
    .{ .key = "max_page_bytes", .label = "Largest page (bytes)", .type = .number, .min = 1, .max = 33554432, .default = "2097152", .help = "Larger pages are skipped." },
    timeout,
    ca,
    lang,
};

const archive = [_]Option{
    .{ .key = "query", .label = "Search query", .type = .text, .required = true, .placeholder = "collection:gutenberg AND mediatype:texts", .help = "Any Internet Archive search, as on archive.org's advanced search." },
    user_agent,
    .{ .key = "max_items", .label = "Most items per run", .type = .number, .min = 1, .max = 100000000, .default = "10000", .help = "A safety limit: some collections hold millions of items." },
    .{ .key = "count", .label = "Items per request", .type = .number, .min = 1000, .max = 10000, .default = "1000", .help = "At least 1000: smaller pages returned wrong results." },
    delay,
    timeout,
    .{ .key = "base_url", .label = "Service address", .type = .text, .default = "https://archive.org", .placeholder = "https://archive.org", .help = "For a mirror; no trailing slash." },
    ca,
    lang,
};

/// The options of a kind, in the order the form shows them.
pub fn forKind(kind: []const u8) []const Option {
    if (std.mem.eql(u8, kind, "files")) return &files;
    if (std.mem.eql(u8, kind, "gutenberg")) return &gutenberg;
    if (std.mem.eql(u8, kind, "wikipedia")) return &wikipedia;
    if (std.mem.eql(u8, kind, "zim")) return &zim;
    if (std.mem.eql(u8, kind, "feeds")) return &feeds;
    if (std.mem.eql(u8, kind, "crawl")) return &crawl;
    if (std.mem.eql(u8, kind, "archive")) return &archive;
    return &.{};
}

/// The current values of a kind's options, found in `options_text` (`key = value` lines), and the
/// lines it holds for keys the table does not know (kept as they are).
pub const Split = struct {
    /// One entry per option of the kind: its value as text (a flag is "true" or "false"), or null.
    values: []const ?[]const u8,
    /// Lines for unknown keys, to show in the "other settings" box.
    rest: []const u8,
};

pub fn split(arena: Allocator, kind: []const u8, options_text: []const u8) Allocator.Error!Split {
    const opts = forKind(kind);
    const values = try arena.alloc(?[]const u8, opts.len);
    @memset(values, null);
    var rest: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, options_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue; // notes are dropped: the fields explain themselves
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try rest.print(arena, "{s}\n", .{line});
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var matched = false;
        for (opts, 0..) |o, i| if (std.mem.eql(u8, o.key, key)) {
            values[i] = try valueText(arena, std.mem.trim(u8, line[eq + 1 ..], " \t"));
            matched = true;
            break;
        };
        if (!matched) try rest.print(arena, "{s}\n", .{line});
    }
    return .{ .values = values, .rest = std.mem.trim(u8, rest.items, "\n") };
}

/// The text of a TOML scalar: a string without its quotes (escapes undone), or the token itself.
fn valueText(arena: Allocator, v: []const u8) Allocator.Error![]const u8 {
    if (v.len >= 2 and v[0] == '"') {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < v.len) : (i += 1) {
            const c = v[i];
            if (c == '"') break;
            if (c == '\\' and i + 1 < v.len) {
                i += 1;
                try out.append(arena, switch (v[i]) {
                    'n' => '\n',
                    't' => '\t',
                    else => v[i],
                });
            } else try out.append(arena, c);
        }
        return out.items;
    }
    if (v.len >= 2 and v[0] == '\'') {
        const end = std.mem.indexOfScalarPos(u8, v, 1, '\'') orelse v.len;
        return v[1..end];
    }
    // A bare token ends at a space or a note.
    const end = std.mem.indexOfAny(u8, v, " \t#") orelse v.len;
    return v[0..end];
}

fn isNumber(s: []const u8) bool {
    if (s.len == 0 or s.len > 18) return false;
    var i: usize = 0;
    if (s[0] == '-') i = 1;
    if (i >= s.len) return false;
    for (s[i..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn writeString(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(arena, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n', '\r', '\t' => try out.append(arena, ' '),
        else => if (c >= 0x20 and c != 0x7f) try out.append(arena, c),
    };
    try out.append(arena, '"');
}

/// The `key = value` lines for the posted fields of `kind` (each named `opt_KEY` in `params`, which
/// needs a `get(name)`), then `more`. Empty fields are left out (the connector's default applies).
/// A number that is not a number is written as text, so that saving reports it by name.
pub fn compose(arena: Allocator, kind: []const u8, params: anytype, more: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (forKind(kind)) |o| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "opt_{s}", .{o.key}) catch continue;
        const posted = params.get(name);
        switch (o.type) {
            .flag => {
                const on = posted != null;
                if (on and !o.default_on) try out.print(arena, "{s} = true\n", .{o.key}) else if (!on and o.default_on) try out.print(arena, "{s} = false\n", .{o.key});
            },
            .number => {
                const v = std.mem.trim(u8, posted orelse "", " \t\r\n");
                if (v.len == 0) continue;
                if (isNumber(v)) {
                    try out.print(arena, "{s} = {s}\n", .{ o.key, v });
                } else {
                    try out.print(arena, "{s} = ", .{o.key});
                    try writeString(arena, &out, v);
                    try out.append(arena, '\n');
                }
            },
            .text, .path => {
                const v = std.mem.trim(u8, posted orelse "", " \t\r\n");
                if (v.len == 0) continue;
                try out.print(arena, "{s} = ", .{o.key});
                try writeString(arena, &out, v);
                try out.append(arena, '\n');
            },
        }
    }
    const extra = std.mem.trim(u8, more, " \t\r\n");
    if (extra.len > 0) {
        try out.appendSlice(arena, extra);
        try out.append(arena, '\n');
    }
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

test "every kind has fields, every key appears once, and required ones are marked" {
    for ([_][]const u8{ "files", "gutenberg", "wikipedia", "zim", "feeds", "crawl", "archive" }) |k| {
        const opts = forKind(k);
        try testing.expect(opts.len >= 3);
        var required: usize = 0;
        for (opts, 0..) |o, i| {
            if (o.required) required += 1;
            for (opts[0..i]) |p| try testing.expect(!std.mem.eql(u8, p.key, o.key));
            if (o.type == .number) try testing.expect(o.max >= o.min and o.max > 0);
        }
        try testing.expect(required >= 1);
    }
    try testing.expectEqual(@as(usize, 0), forKind("nonsense").len);
}

test "posted fields become option lines: text escaped, numbers typed, flags on or off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params: FakeParams = .{ .pairs = &.{
        .{ "opt_path", "/home/me/my \"notes\"" },
        .{ "opt_pdf_text", "1" },
        .{ "opt_max_file_bytes", " 8388608 " },
        .{ "opt_pdf_workers", "lots" },
        .{ "opt_language", "" },
    } };
    const text = try compose(a, "files", params, "future_option = 5\n");
    try testing.expectEqualStrings("path = \"/home/me/my \\\"notes\\\"\"\npdf_text = true\npdf_workers = \"lots\"\nmax_file_bytes = 8388608\nfuture_option = 5\n", text);
    // A flag that is on by default is written only when turned off.
    try testing.expectEqualStrings("path = \"/x.zim\"\nserve_articles = false\n", try compose(a, "zim", FakeParams{ .pairs = &.{.{ "opt_path", "/x.zim" }} }, ""));
    try testing.expectEqualStrings("path = \"/x.zim\"\n", try compose(a, "zim", FakeParams{ .pairs = &.{ .{ "opt_path", "/x.zim" }, .{ "opt_serve_articles", "1" } } }, ""));
    // Line breaks cannot start a new setting.
    const evil = try compose(a, "files", FakeParams{ .pairs = &.{.{ "opt_path", "/x\nretain_text = false" }} }, "");
    try testing.expectEqualStrings("path = \"/x retain_text = false\"\n", evil);
}

test "existing options fill the fields; what the table does not know is kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try split(a, "files",
        \\path = "/home/me/notes"   # the folder
        \\# pdf_text = true
        \\pdf_text = true
        \\max_file_bytes = 8388608
        \\language = 'en'
        \\mystery = "x y"
        \\
    );
    const opts = forKind("files");
    for (opts, s.values) |o, v| {
        if (std.mem.eql(u8, o.key, "path")) try testing.expectEqualStrings("/home/me/notes", v.?);
        if (std.mem.eql(u8, o.key, "pdf_text")) try testing.expectEqualStrings("true", v.?);
        if (std.mem.eql(u8, o.key, "max_file_bytes")) try testing.expectEqualStrings("8388608", v.?);
        if (std.mem.eql(u8, o.key, "language")) try testing.expectEqualStrings("en", v.?);
        if (std.mem.eql(u8, o.key, "office")) try testing.expect(v == null);
    }
    try testing.expectEqualStrings("mystery = \"x y\"", s.rest);
    // And composing what was split gives back the same settings.
    const back = try compose(a, "files", FakeParams{ .pairs = &.{ .{ "opt_path", "/home/me/notes" }, .{ "opt_pdf_text", "1" }, .{ "opt_max_file_bytes", "8388608" }, .{ "opt_language", "en" } } }, s.rest);
    try testing.expectEqualStrings("path = \"/home/me/notes\"\npdf_text = true\nmax_file_bytes = 8388608\nlanguage = \"en\"\nmystery = \"x y\"\n", back);
}
