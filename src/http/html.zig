//! Server-rendered HTML for the public search page.
//!
//! No JavaScript. Every dynamic string goes through `writeEscaped`, and a
//! result URL becomes a link only if its scheme is http or https.

const std = @import("std");
const Writer = std.Io.Writer;
const dk = @import("dksearch");
const query = @import("query.zig");

pub const style_css = @embedFile("assets/style.css");

/// A short fingerprint of an embedded asset, put in its address (`style.css?v=…`) so a browser
/// that cached an older copy fetches the new one as soon as the content changes.
pub fn assetVersion(comptime content: []const u8) []const u8 {
    @setEvalBranchQuota(content.len * 20 + 1000);
    const h = std.hash.Fnv1a_64.hash(content);
    return std.fmt.comptimePrint("{x}", .{@as(u32, @truncate(h ^ (h >> 32)))});
}

pub const style_version = assetVersion(style_css);

pub fn writeEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |b| switch (b) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(b),
    };
}

/// True only for absolute http(s) URLs. Blocks `javascript:`, `data:` and
/// everything else from becoming a link.
pub fn isLinkable(url: []const u8) bool {
    return startsWithIgnoreCase(url, "http://") or startsWithIgnoreCase(url, "https://");
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Writes a snippet: HTML-escaped, with the engine's match markers turned
/// into <mark>. Markers are only honoured in a balanced way, and other
/// control bytes are dropped, so untrusted text cannot unbalance the markup.
pub fn writeSnippet(w: *Writer, snippet: []const u8) Writer.Error!void {
    var open = false;
    for (snippet) |b| {
        if (std.mem.eql(u8, &.{b}, dk.search.match_start)) {
            if (!open) {
                try w.writeAll("<mark>");
                open = true;
            }
        } else if (std.mem.eql(u8, &.{b}, dk.search.match_end)) {
            if (open) {
                try w.writeAll("</mark>");
                open = false;
            }
        } else if (b < 0x20 and b != '\t' and b != '\n') {
            continue;
        } else {
            try writeEscaped(w, &.{b});
        }
    }
    if (open) try w.writeAll("</mark>");
}

pub const Form = struct {
    q: []const u8 = "",
    language: []const u8 = "",
    connector: []const u8 = "",
    /// Regular-expression filter; the field is only shown when `regex_enabled`.
    regex: []const u8 = "",
    regex_ignore_case: bool = false,
    regex_enabled: bool = false,
    /// A message about the regex filter (bad pattern, too busy, ...).
    regex_notice: ?[]const u8 = null,
    /// The searcher asked for exact spelling (`fuzzy=0`); kept when paging.
    exact_only: bool = false,
    /// Names of the sources this server has, for the Source drop-down.
    sources: []const []const u8 = &.{},
    /// The chosen order (`newest`, ...); empty for best match first.
    sort: []const u8 = "",
};

pub fn writeHead(w: *Writer, title: []const u8) Writer.Error!void {
    try w.writeAll("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>");
    try writeEscaped(w, title);
    try w.writeAll("</title><link rel=\"stylesheet\" href=\"/assets/style.css?v=" ++ style_version ++ "\"></head>\n");
}

fn writeForm(w: *Writer, f: Form) Writer.Error!void {
    try w.writeAll("<form class=\"search\" action=\"/search\" method=\"get\" role=\"search\">" ++
        "<input type=\"search\" name=\"q\" maxlength=\"1024\" aria-label=\"Search\" autofocus value=\"");
    try writeEscaped(w, f.q);
    try w.writeAll("\"><button type=\"submit\">Search</button>");
    const open = if (f.language.len > 0 or f.connector.len > 0 or f.sort.len > 0) " open" else "";
    try w.print("<details{s}><summary><span>Filters</span><a class=\"tips\" href=\"/help/search\">Search tips</a></summary><label>Language <input name=\"language\" maxlength=\"64\" value=\"", .{open});
    try writeEscaped(w, f.language);
    try w.writeAll("\"></label><label>Source <select name=\"connector\"><option value=\"\">All sources</option>");
    var listed = false;
    for (f.sources) |name| {
        const selected = std.mem.eql(u8, name, f.connector);
        if (selected) listed = true;
        try w.writeAll("<option value=\"");
        try writeEscaped(w, name);
        try w.writeAll(if (selected) "\" selected>" else "\">");
        try writeEscaped(w, name);
        try w.writeAll("</option>");
    }
    // A source named in the address but not in the list (removed, or typed by hand) stays selected.
    if (f.connector.len > 0 and !listed) {
        try w.writeAll("<option value=\"");
        try writeEscaped(w, f.connector);
        try w.writeAll("\" selected>");
        try writeEscaped(w, f.connector);
        try w.writeAll("</option>");
    }
    try w.writeAll("</select></label><label>Order <select name=\"sort\">");
    const orders = [_][2][]const u8{ .{ "", "Best match" }, .{ "newest", "Newest" }, .{ "oldest", "Oldest" }, .{ "largest", "Largest" }, .{ "smallest", "Smallest" }, .{ "title", "Title" } };
    for (orders) |o| {
        try w.print("<option value=\"{s}\"{s}>{s}</option>", .{ o[0], if (std.mem.eql(u8, o[0], f.sort)) " selected" else "", o[1] });
    }
    try w.writeAll("</select></label>");
    try w.writeAll("</details></form>\n");
    if (f.regex_notice) |n| {
        try w.writeAll("<p class=\"error\" role=\"alert\">");
        try writeEscaped(w, n);
        try w.writeAll("</p>\n");
    }
}

/// The left panel: the search syntax at a glance, with links to the full guides.
fn writeSidePanel(w: *Writer, regex_enabled: bool) Writer.Error!void {
    try w.writeAll("<input type=\"checkbox\" id=\"sidetoggle\" class=\"sidetoggle\" aria-label=\"Show search tips\"><label for=\"sidetoggle\" class=\"burger\" title=\"Search tips\">&#9776;</label><label for=\"sidetoggle\" class=\"scrim\"></label>");
    try w.writeAll("<aside class=\"side\" aria-label=\"Search tips\"><h2>Search tips</h2>");
    try w.writeAll("<h3>Words</h3><dl><dt><code>\"exact phrase\"</code></dt><dd>words together, in order</dd>" ++
        "<dt><code>a OR b</code></dt><dd>either word</dd>" ++
        "<dt><code>a -b</code></dt><dd>a, but not b</dd>" ++
        "<dt><code>comp*</code></dt><dd>words starting with comp</dd>" ++
        "<dt><code>word~</code></dt><dd>allow one typo</dd>" ++
        "<dt><code>title:word</code></dt><dd>only in the title</dd></dl>");
    try w.writeAll("<h3>Filters</h3><dl><dt><code>ext:pdf</code></dt><dd>file extension</dd>" ++
        "<dt><code>type:image</code></dt><dd>page, text, pdf, image, video, audio&hellip;</dd>" ++
        "<dt><code>site:example.org</code></dt><dd>one website</dd>" ++
        "<dt><code>size:&gt;1mb</code></dt><dd>bigger or smaller</dd>" ++
        "<dt><code>modified:7d</code></dt><dd>changed in the last 7 days</dd>" ++
        "<dt><code>modified:&gt;2026-01-01</code></dt><dd>changed after a date</dd>" ++
        "<dt><code>lang:en</code></dt><dd>language</dd>" ++
        "<dt><code>source:name</code></dt><dd>one source</dd>" ++
        "<dt><code>-ext:pdf</code></dt><dd>a minus leaves them out</dd></dl>");
    if (regex_enabled) try w.writeAll("<h3>Regular expressions</h3><dl><dt><code>re:/\\d{3}-\\d{4}/</code></dt><dd>keep results whose text matches the pattern</dd>" ++
        "<dt><code>re:/colou?r/i</code></dt><dd>the <code>i</code> ignores case</dd>" ++
        "<dt><code>-re:/draft/</code></dt><dd>leave out those that match</dd></dl><p class=\"small\">Use it together with at least one word.</p>");
    try w.writeAll("<p class=\"small\"><a href=\"/help/search\">Full guide</a>");
    if (regex_enabled) try w.writeAll(" &middot; <a href=\"/help/regex\">Regex guide</a>");
    try w.writeAll("</p></aside>\n");
}

pub fn writeHome(w: *Writer, notice: ?[]const u8) Writer.Error!void {
    return writeHomeWith(w, notice, false);
}

/// The home page; `regex_enabled` adds the regex filter to the form.
pub fn writeHomeWith(w: *Writer, notice: ?[]const u8, regex_enabled: bool) Writer.Error!void {
    return writeHomeForm(w, notice, .{ .regex_enabled = regex_enabled });
}

/// The home page with a prepared form (the source list and so on).
pub fn writeHomeForm(w: *Writer, notice: ?[]const u8, form: Form) Writer.Error!void {
    const regex_enabled = form.regex_enabled;
    try writeHead(w, "dksearch");
    try w.writeAll("<body class=\"home\">");
    try writeSidePanel(w, regex_enabled);
    try w.writeAll("<main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1>\n");
    try writeForm(w, form);
    if (notice) |n| {
        try w.writeAll("<p class=\"error\" role=\"alert\">");
        try writeEscaped(w, n);
        try w.writeAll("</p>");
    }
    try w.writeAll("</main></body></html>\n");
}

pub fn writeResults(w: *Writer, f: Form, page: dk.search.Page, offset: u32, page_size: u32) Writer.Error!void {
    try writeHead(w, if (f.q.len > 0) f.q else "dksearch");
    try w.writeAll("<body>");
    try writeSidePanel(w, f.regex_enabled);
    try w.writeAll("<main class=\"results-page\"><div class=\"head\"><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1>");
    try writeForm(w, f);
    try w.writeAll("</div>\n");
    try writeInterpretation(w, f, page, offset);

    if (page.hits.len == 0) {
        try w.writeAll("<p class=\"notice\">No results for &ldquo;");
        try writeEscaped(w, f.q);
        try w.writeAll("&rdquo;.</p>");
    } else {
        try w.writeAll("<ol class=\"results\" start=\"");
        try w.print("{d}", .{offset + 1});
        try w.writeAll("\">\n");
        for (page.hits) |h| try writeHit(w, h);
        try w.writeAll("</ol>\n");
    }

    if (offset > 0 or page.has_more) {
        try w.writeAll("<nav class=\"pager\" aria-label=\"Pages\"><span>");
        if (offset > 0) try writePagerLink(w, f, offset -| page_size, "&larr; Previous");
        try w.writeAll("</span><span>");
        if (page.has_more) try writePagerLink(w, f, offset + page_size, "Next &rarr;");
        try w.writeAll("</span></nav>\n");
    }
    try w.writeAll("</main></body></html>\n");
}

/// How the query was read, and whether similar spellings were included.
fn writeInterpretation(w: *Writer, f: Form, page: dk.search.Page, offset: u32) Writer.Error!void {
    if (page.fuzzy) {
        try w.writeAll("<p class=\"notice\">Showing results that include similar spellings of your words. ");
        // Offer the strict search back, keeping the rest of the query.
        try w.writeAll("<a href=\"/search?q=");
        try query.writeEncoded(w, f.q);
        if (f.sort.len > 0) {
            try w.writeAll("&amp;sort=");
            try query.writeEncoded(w, f.sort);
        }
        if (f.language.len > 0) {
            try w.writeAll("&amp;language=");
            try query.writeEncoded(w, f.language);
        }
        if (f.connector.len > 0) {
            try w.writeAll("&amp;connector=");
            try query.writeEncoded(w, f.connector);
        }
        if (f.regex.len > 0) {
            try w.writeAll("&amp;regex=");
            try query.writeEncoded(w, f.regex);
        }
        try w.writeAll("&amp;fuzzy=0\">Search exactly as typed</a></p>\n");
    }
    if (page.interpreted) |text| {
        try w.writeAll("<p class=\"muted small\">Searching for: <code>");
        try writeEscaped(w, text);
        try w.writeAll("</code> <a href=\"/help/search\">how this works</a></p>\n");
    }
    _ = offset;
}

fn writeHit(w: *Writer, h: dk.search.Hit) Writer.Error!void {
    try w.writeAll("<li>");
    const label = h.title orelse h.url orelse "(untitled)";
    if (h.url) |u| if (std.mem.startsWith(u8, u, "zim://")) {
        // An article of a ZIM file: it opens from the file (see handler.zimPage).
        try w.writeAll("<a class=\"title\" href=\"/zim/");
        try writeEscaped(w, u["zim://".len..]);
        try w.writeAll("\">");
        try writeEscaped(w, label);
        try w.writeAll("</a><div class=\"url\">");
        try writeEscaped(w, u);
        try w.writeAll("</div>");
        return finishHit(w, h);
    };
    if (h.url) |u| if (isLinkable(u)) {
        try w.writeAll("<a class=\"title\" href=\"");
        try writeEscaped(w, u);
        try w.writeAll("\" rel=\"noopener noreferrer\">");
        try writeEscaped(w, label);
        try w.writeAll("</a>");
        try w.writeAll("<div class=\"url\">");
        try writeEscaped(w, u);
        try w.writeAll("</div>");
        return finishHit(w, h);
    };
    // An address a browser cannot open (a file on the server, for instance): the title opens the viewer.
    try w.writeAll("<a class=\"title\" href=\"/doc/");
    try writeIdHex(w, h.id);
    try w.writeAll("\">");
    try writeEscaped(w, label);
    try w.writeAll("</a>");
    if (h.url) |u| {
        try w.writeAll("<div class=\"url\">");
        try writeEscaped(w, u);
        try w.writeAll("</div>");
    }
    try finishHit(w, h);
}

fn finishHit(w: *Writer, h: dk.search.Hit) Writer.Error!void {
    if (h.snippet) |s| if (s.len > 0) {
        try w.writeAll("<p class=\"snippet\">");
        try writeSnippet(w, s);
        try w.writeAll("</p>");
    };
    try w.writeAll("<div class=\"source\">");
    try writeEscaped(w, h.connector);
    if (h.kind) |k| {
        try w.writeAll(" &middot; ");
        try writeEscaped(w, k);
    }
    if (h.size) |n| {
        try w.writeAll(" &middot; ");
        try writeSize(w, n);
    }
    if (h.modified_at) |t| {
        try w.writeAll(" &middot; ");
        try writeDate(w, t);
    }
    try w.writeAll(" &middot; <a href=\"/doc/");
    try writeIdHex(w, h.id);
    try w.writeAll("\">Stored text</a></div></li>\n");
}

fn writeIdHex(w: *Writer, id: dk.document.Id) Writer.Error!void {
    const hex = std.fmt.bytesToHex(id, .lower);
    try w.writeAll(&hex);
}

/// `1.5 MB`, `300 B`: sizes people read.
fn writeSize(w: *Writer, n: u64) Writer.Error!void {
    if (n < 1024) return w.print("{d} B", .{n});
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    v /= 1024;
    while (v >= 1024 and i + 1 < units.len) : (i += 1) v /= 1024;
    try w.print("{d:.1} {s}", .{ v, units[i] });
}

/// A Unix time as `2026-11-16` (UTC).
fn writeDate(w: *Writer, secs: i64) Writer.Error!void {
    const days = @divFloor(secs, 86400);
    // Civil-from-days (Howard Hinnant's algorithm).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@max(y, 0))), @as(u64, @intCast(m)), @as(u64, @intCast(d)) }); // unsigned, so no "+" is printed
}

/// The viewer page for one document: what is known about it and its stored text.
pub const OpenLink = struct { href: []const u8, label: []const u8 };

/// One line at the top of the viewer pages: the name and a search box.
fn writeTopBar(w: *Writer) Writer.Error!void {
    try w.writeAll("<header class=\"topbar\"><a class=\"brand\" href=\"/\">dksearch</a>" ++
        "<form class=\"search\" action=\"/search\" method=\"get\" role=\"search\">" ++
        "<input type=\"search\" name=\"q\" maxlength=\"1024\" aria-label=\"Search\" placeholder=\"Search\">" ++
        "<button type=\"submit\">Search</button></form></header>\n");
}

/// A page from a ZIM file. `body` was made safe by the sanitizer.
pub fn writeArticle(w: *Writer, title: []const u8, source: []const u8, body: []const u8) Writer.Error!void {
    try writeHead(w, title);
    try w.writeAll("<body>");
    try writeTopBar(w);
    try w.writeAll("<main class=\"docpage\"><h2 class=\"doctitle\">");
    try writeEscaped(w, title);
    try w.writeAll("</h2>\n<p class=\"muted small\">From the ZIM source <a href=\"/search?q=*&amp;connector=");
    try query.writeEncoded(w, source);
    try w.writeAll("\">");
    try writeEscaped(w, source);
    try w.writeAll("</a></p>\n<div class=\"doctext rendered article\">");
    try w.writeAll(body);
    try w.writeAll("</div>\n<p><a href=\"/\">&larr; New search</a></p></main></body></html>\n");
}

pub fn writeDocument(w: *Writer, h: dk.search.Hit, text: ?[]const u8, cut: bool, open_link: ?OpenLink, rendered: ?[]const u8, is_markdown: bool) Writer.Error!void {
    try writeHead(w, h.title orelse h.url orelse "Document");
    try w.writeAll("<body>");
    try writeTopBar(w);
    try w.writeAll("<main class=\"docpage\"><h2 class=\"doctitle\">");
    try writeEscaped(w, h.title orelse h.url orelse "(untitled)");
    try w.writeAll("</h2>\n<dl class=\"meta\">");
    try metaRow(w, "Source", h.connector);
    if (h.url) |u| {
        try w.writeAll("<dt>Address</dt><dd>");
        if (isLinkable(u)) {
            try w.writeAll("<a href=\"");
            try writeEscaped(w, u);
            try w.writeAll("\" rel=\"noopener noreferrer\">");
            try writeEscaped(w, u);
            try w.writeAll("</a>");
        } else try writeEscaped(w, u);
        try w.writeAll("</dd>");
    }
    if (h.kind) |k| try metaRow(w, "Kind", k);
    if (h.content_type) |ct| try metaRow(w, "Type", ct);
    if (h.language) |l| try metaRow(w, "Language", l);
    if (h.author) |a| try metaRow(w, "Author", a);
    if (h.size) |n| {
        try w.writeAll("<dt>Size</dt><dd>");
        try writeSize(w, n);
        try w.writeAll("</dd>");
    }
    inline for (.{ .{ "Modified", h.modified_at }, .{ "Published", h.published_at }, .{ "Added", h.indexed_at } }) |row| {
        if (row[1]) |t| {
            try w.print("<dt>{s}</dt><dd>", .{row[0]});
            try writeDate(w, t);
            try w.writeAll("</dd>");
        }
    }
    try w.writeAll("</dl>\n");
    if (open_link) |l| {
        try w.writeAll("<p><a class=\"button\" href=\"");
        try writeEscaped(w, l.href);
        try w.writeAll("\">");
        try writeEscaped(w, l.label);
        try w.writeAll("</a></p>\n");
    }
    if (rendered) |html_body| {
        // `html_body` was made safe by the sanitizer.
        try w.writeAll("<h3>Document</h3>\n<div class=\"doctext rendered\">");
        try w.writeAll(html_body);
        try w.writeAll("</div>\n<p class=\"muted small\"><a href=\"/doc/");
        try writeIdHex(w, h.id);
        try w.writeAll("?view=text\">Show the plain text</a></p>\n");
        if (cut) try w.writeAll("<p class=\"muted small\">Only the beginning is shown.</p>\n");
    } else if (text) |t| {
        try w.writeAll("<h3>Stored text</h3>\n<pre class=\"doctext\">");
        try writeEscaped(w, t);
        try w.writeAll("</pre>\n");
        if (is_markdown) {
            try w.writeAll("<p class=\"muted small\"><a href=\"/doc/");
            try writeIdHex(w, h.id);
            try w.writeAll("\">Show it formatted</a></p>\n");
        }
        if (cut) try w.writeAll("<p class=\"muted small\">Only the beginning is shown.</p>\n");
    } else {
        try w.writeAll("<p class=\"notice\">The text of this document is not stored on this server (the source may be set to keep only what it needs for searching), so only what is known about it is shown.</p>\n");
    }
    try w.writeAll("<p><a href=\"/\">&larr; New search</a></p></main></body></html>\n");
}

fn metaRow(w: *Writer, name: []const u8, value: []const u8) Writer.Error!void {
    try w.print("<dt>{s}</dt><dd>", .{name});
    try writeEscaped(w, value);
    try w.writeAll("</dd>");
}

fn writePagerLink(w: *Writer, f: Form, offset: u32, label_html: []const u8) Writer.Error!void {
    try w.writeAll("<a href=\"/search?q=");
    try query.writeEncoded(w, f.q);
    if (f.sort.len > 0) {
        try w.writeAll("&amp;sort=");
        try query.writeEncoded(w, f.sort);
    }
    if (f.language.len > 0) {
        try w.writeAll("&amp;language=");
        try query.writeEncoded(w, f.language);
    }
    if (f.connector.len > 0) {
        try w.writeAll("&amp;connector=");
        try query.writeEncoded(w, f.connector);
    }
    if (f.regex.len > 0) {
        try w.writeAll("&amp;regex=");
        try query.writeEncoded(w, f.regex);
        if (f.regex_ignore_case) try w.writeAll("&amp;regex_flags=i");
    }
    if (f.exact_only) try w.writeAll("&amp;fuzzy=0");
    if (offset > 0) try w.print("&amp;offset={d}", .{offset});
    try w.writeAll("\">");
    try w.writeAll(label_html);
    try w.writeAll("</a>");
}

/// The search tips page: the query language, typo tolerance, examples.
pub fn writeHelpSearch(w: *Writer, regex_enabled: bool) Writer.Error!void {
    try writeHead(w, "Search tips - dksearch");
    try w.writeAll("<body><main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1><h2>Search tips</h2>\n");
    try w.writeAll("<p>Just type words: results contain all of them, best matches first, and a title match counts more than a match in the text. Capitalised <code>AND</code>, <code>OR</code> and <code>NOT</code> and a few symbols let you say more.</p>\n");
    try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>You type</th><th>It means</th></tr></thead><tbody>");
    const rows = [_][2][]const u8{
        .{ "\"kernel module\"", "the exact phrase" },
        .{ "linux wayland", "both words (AND is the default)" },
        .{ "linux AND wayland", "both words, spelled out" },
        .{ "linux OR bsd", "either word" },
        .{ "linux NOT android", "linux, but not android" },
        .{ "linux -android", "the same, with a minus in front of the word to leave out" },
        .{ "+linux", "linux must be there (already the default; allowed for habit)" },
        .{ "(linux OR bsd) AND kernel", "grouping with parentheses" },
        .{ "comp*", "words that start with comp: compositor, compiler, computer&hellip;" },
        .{ "compositor~", "the word, or any word one typo away from it" },
        .{ "\"window manager\"~5", "the two words within five words of each other, in any order" },
    };
    for (rows) |r| try w.print("<tr><td><code>{s}</code></td><td>{s}</td></tr>", .{ r[0], r[1] });
    try w.writeAll("</tbody></table></div>\n");
    try w.writeAll("<h3>Filters: narrow by what kind of document it is</h3><p>Write them in the search box next to your words. Put a minus in front to leave matching documents out. A search made only of filters (<code>ext:pdf</code>) lists the matches, newest first.</p>\n");
    try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>You type</th><th>It means</th></tr></thead><tbody>");
    const filter_rows = [_][2][]const u8{
        .{ "ext:pdf", "files with that extension (also <code>-ext:pdf</code> to leave them out)" },
        .{ "type:image", "a kind of document: page, text, markdown, pdf, image, video, audio, data, other" },
        .{ "mime:text/*", "a media type, exactly (<code>mime:application/pdf</code>) or a whole family (<code>mime:image/*</code>)" },
        .{ "source:notes", "documents from the source with that name" },
        .{ "lang:en", "documents in that language (<code>en</code> also finds <code>en-US</code>)" },
        .{ "site:example.org", "from that website, including its subdomains (<code>domain:</code> and <code>host:</code> work too)" },
        .{ "path:/docs/", "whose address starts with that path" },
        .{ "author:\"Jo Smith\"", "the author contains that text (quote values that have spaces)" },
        .{ "tag:linux", "documents carrying that tag; <code>meta.camera:acme</code> tests any other field a source provides" },
        .{ "size:&gt;1mb", "bigger than one megabyte; also <code>&lt;10k</code>, <code>&gt;=1gb</code> or <code>10k..2mb</code> (units b, k, m, g)" },
        .{ "modified:&gt;2026-01-01", "changed after that day; also <code>2026</code>, <code>2026-03</code>, <code>2026-03-15</code> or a range <code>2025-06..2025-12</code>" },
        .{ "modified:7d", "changed in the last 7 days (<code>d</code> days, <code>w</code> weeks, <code>m</code> months, <code>y</code> years)" },
        .{ "created:2025", "published in that year (what the source says); <code>indexed:</code> is when it was added here" },
        .{ "title:kernel", "the word must be in the title; <code>body:kernel</code> in the text; <code>title:(linux OR bsd)</code> works for a group" },
    };
    for (filter_rows) |r| try w.print("<tr><td><code>{s}</code></td><td>{s}</td></tr>", .{ r[0], r[1] });
    try w.writeAll("</tbody></table></div>\n<p>Several filters must all hold, except that the same filter written twice means either (<code>ext:pdf ext:md</code> finds PDFs and Markdown). A filter that does not make sense (<code>size:big</code>) is searched as ordinary text. Documents indexed before filters existed have no type, size or dates until they are imported again or the index is rebuilt.</p>\n");
    try w.writeAll("<h3>You do not have to spell everything right</h3><p>If a search finds fewer than three results, dksearch automatically tries again with words that are one typo away (a letter missing, extra, wrong or swapped) and tells you it did, with a link to search exactly as typed. Short words (three letters or fewer) are never guessed at. To force it for one word, write <code>word~</code>.</p>\n");
    try w.writeAll("<h3>Good to know</h3><ul><li><code>AND</code>, <code>OR</code> and <code>NOT</code> only count as operators in capital letters; <code>and</code> or <code>or</code> in lower case are ordinary words. To search for the word itself, put it in quotes: <code>\"OR\"</code>.</li><li>A search with only excluded words (<code>-android</code>) has nothing to look for: add a word you do want.</li><li>When your query used these features, the results page shows how it was read (&ldquo;Searching for: &hellip;&rdquo;).</li>");
    if (regex_enabled) try w.writeAll("<li>For patterns that words cannot express (codes, dates, phone numbers), see <a href=\"/help/regex\">regular expressions</a>.</li>");
    try w.writeAll("</ul><p><a href=\"/\">&larr; Back to search</a></p></main></body></html>\n");
}

/// How the regex filter works, with the limits this server applies.
pub fn writeHelpRegex(w: *Writer, limits: ?dk.regexsearch.Limits) Writer.Error!void {
    try writeHead(w, "Regular expressions - dksearch");
    try w.writeAll("<body><main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1><h2>Regular expressions</h2>\n");
    try w.writeAll("<p>A regular expression (&ldquo;regex&rdquo;) describes a pattern of text, such as &ldquo;three digits, a dash, four digits&rdquo;. Use one when words cannot say what you are looking for: part numbers, dates, phone numbers, spellings like <code>colou?r</code>.</p>\n");
    try w.writeAll("<h3>How to write one</h3><p>Type it in the search box between slashes after <code>re:</code>, together with your words and any filters: <code>invoice ext:pdf re:/INV-\\d{6}/</code>. Put <code>i</code> after the closing slash to ignore case (<code>re:/colou?r/i</code>). A minus in front, <code>-re:/draft/</code>, keeps only the documents that do <em>not</em> match. To match a slash, write <code>\\/</code>. One pattern per search.</p>\n");
    try w.writeAll("<h3>How a regex search works</h3><ol><li><strong>Your words choose the documents.</strong> Type at least one word in the search box. dksearch finds the documents that contain your words, best matches first, using its index. This is what keeps it fast.</li><li><strong>Then the regex checks their text.</strong> Each of those documents is read and tested against your pattern. Only the ones that contain a match are kept, and the match is highlighted in the result.</li><li><strong>It stops at a limit.</strong> To keep the server responsive it checks a limited number of documents; if it stopped early, the results may be incomplete, so make the words more specific.</li></ol>\n");
    if (limits) |l| try w.print("<p class=\"muted\">On this server: patterns up to {d} characters, up to {d} documents checked, about {d} ms in total, and at most {d} regex searches at once.</p>\n", .{ l.max_pattern_bytes, l.max_candidates, l.budget_ms, l.concurrency });
    try w.writeAll("<h3>The pattern language</h3><div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Write</th><th>Matches</th></tr></thead><tbody>");
    const rows = [_][2][]const u8{
        .{ "abc", "exactly abc" },
        .{ ".", "any one character (but not a line break)" },
        .{ "\\d &nbsp; \\w &nbsp; \\s", "a digit; a letter, digit or underscore; a space or tab" },
        .{ "[a-z] &nbsp; [^0-9]", "one letter from a to z; one character that is not a digit" },
        .{ "x* &nbsp; x+ &nbsp; x?", "zero or more; one or more; zero or one x" },
        .{ "x{3} &nbsp; x{2,4}", "exactly three; two to four x" },
        .{ "cat|dog", "cat or dog" },
        .{ "(ab)+", "ab, abab, ababab&hellip; (parentheses group)" },
        .{ "^ &nbsp; $", "the start; the end of a line" },
        .{ "\\b", "a word boundary, so <code>\\bcat\\b</code> finds cat but not concatenate" },
        .{ "(?i)", "at the start: ignore upper and lower case (or tick &ldquo;ignore case&rdquo;)" },
        .{ ".*?", "as little as possible (the &ldquo;lazy&rdquo; form of .*)" },
        .{ "\\. &nbsp; \\( &nbsp; \\\\", "a literal dot, parenthesis or backslash: put \\ in front of a symbol to mean the symbol itself" },
    };
    for (rows) |r| try w.print("<tr><td><code>{s}</code></td><td>{s}</td></tr>", .{ r[0], r[1] });
    try w.writeAll("</tbody></table></div>\n<h3>Examples</h3><div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Pattern</th><th>Finds</th></tr></thead><tbody>");
    const ex = [_][2][]const u8{
        .{ "\\d{3}-\\d{4}", "a phone-style number such as 555-0142" },
        .{ "\\b(18|19|20)\\d\\d\\b", "a year from 1800 to 2099" },
        .{ "colou?r", "color or colour" },
        .{ "\\w+@\\w+\\.\\w+", "something shaped like an email address" },
        .{ "v\\d+\\.\\d+(\\.\\d+)?", "a version number such as v2.4 or v2.4.1" },
        .{ "\\b[A-Z]{2,}\\b", "an ALL-CAPS word of two or more letters" },
    };
    for (ex) |r| try w.print("<tr><td><code>{s}</code></td><td>{s}</td></tr>", .{ r[0], r[1] });
    try w.writeAll("</tbody></table></div>\n<h3>Limits to know about</h3><ul><li>The pattern is matched on bytes, not characters, so <code>.</code> matches one byte of a character like &eacute; and Unicode classes such as <code>\\p{L}</code> are not available.</li><li>A pattern that takes too long on the documents it is tried on is refused with an explanation: make it simpler, for example avoid nesting <code>(a+)+</code>.</li><li>The pattern is part of the query, so the words and filters next to it can still use quotes, OR, NOT and so on (see <a href=\"/help/search\">search tips</a>).</li></ul><p><a href=\"/\">&larr; Back to search</a></p></main></body></html>\n");
}

pub fn writeError(w: *Writer, status_text: []const u8, message: []const u8) Writer.Error!void {
    try writeHead(w, status_text);
    try w.writeAll("<body><main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1><p class=\"error\">");
    try writeEscaped(w, message);
    try w.writeAll("</p><p><a href=\"/\">Back to search</a></p></main></body></html>\n");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn render(comptime f: anytype, args: anytype) ![]u8 {
    var aw: Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

test "escaping covers the five HTML-significant characters" {
    const out = try render(writeEscaped, .{"<a href=\"x\" onclick='y'>&</a>"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;&lt;/a&gt;", out);
}

test "only http and https URLs are linkable" {
    try testing.expect(isLinkable("http://example.org/"));
    try testing.expect(isLinkable("HTTPS://example.org/"));
    try testing.expect(!isLinkable("javascript:alert(1)"));
    try testing.expect(!isLinkable("data:text/html,<script>"));
    try testing.expect(!isLinkable("//example.org/"));
    try testing.expect(!isLinkable(" https://example.org/"));
    try testing.expect(!isLinkable("ftp://example.org/"));
    try testing.expect(!isLinkable(""));
}

test "snippet: markers become mark tags, everything else is escaped" {
    const out = try render(writeSnippet, .{"a <b>\x02hit\x03</b> & more"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a &lt;b&gt;<mark>hit</mark>&lt;/b&gt; &amp; more", out);
}

test "snippet: stray, nested and unclosed markers stay balanced; controls dropped" {
    const out = try render(writeSnippet, .{"\x03x\x02a\x02b\x03\x03y\x02z\x01w"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x<mark>ab</mark>y<mark>zw</mark>", out);
}

test "results page: escapes titles, only links safe URLs, shows pager" {
    const hits = [_]dk.search.Hit{
        .{ .id = undefined, .connector = "wiki<script>", .url = "https://e.org/?a=1&b=2", .title = "T <i>1</i>", .snippet = "x \x02y\x03", .score = 1 },
        .{ .id = undefined, .connector = "c", .url = "javascript:alert(1)", .title = "Bad", .snippet = null, .score = 0.5 },
    };
    const page: dk.search.Page = .{ .hits = &hits, .has_more = true };
    const out = try render(writeResults, .{ Form{ .q = "a \"b\" <c>", .language = "en" }, page, @as(u32, 10), @as(u32, 10) });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "T &lt;i&gt;1&lt;/i&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wiki&lt;script&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "href=\"https://e.org/?a=1&amp;b=2\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "href=\"javascript:") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<script") == null);
    try testing.expect(std.mem.indexOf(u8, out, "value=\"a &quot;b&quot; &lt;c&gt;\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<mark>y</mark>") != null);
    // Pager: previous goes to offset 0 (no offset param), next to offset 20.
    try testing.expect(std.mem.indexOf(u8, out, "href=\"/search?q=a%20%22b%22%20%3Cc%3E&amp;language=en\">&larr; Previous") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&amp;offset=20\">Next") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<ol class=\"results\" start=\"11\">") != null);
}

test "empty results page and home page" {
    const none: dk.search.Page = .{ .hits = &.{}, .has_more = false };
    const out = try render(writeResults, .{ Form{ .q = "zzz" }, none, @as(u32, 0), @as(u32, 10) });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "No results for &ldquo;zzz&rdquo;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "class=\"pager\"") == null);

    const home = try render(writeHome, .{@as(?[]const u8, "Bad <query>")});
    defer testing.allocator.free(home);
    try testing.expect(std.mem.indexOf(u8, home, "Bad &lt;query&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, home, "action=\"/search\"") != null);
}
