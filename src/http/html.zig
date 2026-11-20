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
pub const search_js = @embedFile("assets/search.js");
pub const search_js_version = assetVersion(search_js);

/// The script that makes the search box multi-line; loaded at the end of the pages that have the box.
const search_script = "<script src=\"/assets/search.js?v=" ++ search_js_version ++ "\" defer></script>\n";

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

/// A source offered in the Source drop-down.
pub const SourceChoice = struct { name: []const u8, kind: []const u8, docs: ?u64 = null };

/// A collection offered next to the sources.
pub const CollectionChoice = struct { name: []const u8, description: []const u8 = "" };

fn kindLabel(kind: []const u8) []const u8 {
    const labels = [_][2][]const u8{
        .{ "files", "Local files" },
        .{ "gutenberg", "Project Gutenberg" },
        .{ "wikipedia", "Wikipedia" },
        .{ "zim", "ZIM files" },
        .{ "dump", "Archives and dumps" },
        .{ "peer", "Copies of a peer's source" },
        .{ "feeds", "Feeds" },
        .{ "crawl", "Web crawls" },
        .{ "archive", "Internet Archive" },
    };
    for (labels) |l| if (std.mem.eql(u8, l[0], kind)) return l[1];
    return kind;
}

pub const Form = struct {
    q: []const u8 = "",
    /// The owner is signed in and feedback is kept: the results carry good and bad buttons (added by search.js).
    feedback: bool = false,
    /// Show the gallery through the thumbnail cache (`/thumb`) instead of the originals.
    gallery_thumbs: bool = false,
    login: LoginNote = .none,
    language: []const u8 = "",
    /// The sources ticked in the Source list: names, or `kind:NAME` for every source of a kind. Empty means
    /// all sources.
    picked: []const []const u8 = &.{},
    /// Regular-expression filter; the field is only shown when `regex_enabled`.
    regex: []const u8 = "",
    regex_ignore_case: bool = false,
    regex_enabled: bool = false,
    /// A message about the regex filter (bad pattern, too busy, ...).
    regex_notice: ?[]const u8 = null,
    /// The searcher asked for exact spelling (`fuzzy=0`); kept when paging.
    exact_only: bool = false,
    /// The sources this server has, for the Source drop-down (grouped by kind).
    sources: []const SourceChoice = &.{},
    /// Collections (named groups of sources) the caller may search.
    collections: []const CollectionChoice = &.{},
    /// The chosen order (`newest`, ...); empty for best match first.
    sort: []const u8 = "",
    /// Peers (other nodes) this server can ask: names, for the "Also ask peers" box. Empty: no box.
    peer_names: []const []const u8 = &.{},
    /// The box was ticked.
    peers_on: bool = false,
    /// What each peer did for this search, shown above the results.
    peer_notes: []const PeerNote = &.{},
    /// The default collection that this search was limited to (the visitor picked nothing), with the link back to everything.
    default_note: ?[]const u8 = null,
    /// The visitor asked for every source although a default collection is set (`sources=all`); kept when paging.
    all_sources: bool = false,
    /// Other search engines the visitor can open with these words (opt-in fallback; nothing is sent by this server).
    fallback_links: []const FallbackLink = &.{},
    /// Web results this server asked for from the providers, and who answered; shown below the local results.
    external: []const dk.fallback.External = &.{},
    external_notes: []const []const u8 = &.{},
    /// The AI answer for this search (`answer=1`), its sources, or why there is none; and whether the box is offered.
    answer: ?AnswerBlock = null,
    answer_note: ?[]const u8 = null,
    /// A spelling of the query that does find something, offered when it found nothing.
    did_you_mean: ?[]const u8 = null,
    /// Excerpts shown per result (1 to 5); kept by the page links.
    snippets: u8 = 1,
    /// The Images button was used: only pictures, as a gallery. `gallery_ok` says per result whether the picture itself can
    /// be shown (its original is served); `page_size` is the number of results a page holds.
    images: bool = false,
    gallery_ok: []const bool = &.{},
    page_size: u32 = 10,
    /// What to say about safe search (nothing when it is not in use on this server).
    safe_note: SafeNote = .none,
    /// Search by meaning: offered when the server has an embedding model; ticked when this search used it; and what to
    /// tell the visitor about how the results were ordered.
    semantic_offered: bool = false,
    semantic_checked: bool = false,
    semantic_text: ?[]const u8 = null,
    answers_offered: bool = false,
    answer_checked: bool = false,
    /// Where to go to ask the providers (`web=1`) when that is not done by itself; null: not offered.
    web_href: ?[]const u8 = null,
    web_names: []const u8 = "",
};

pub const FallbackLink = struct { label: []const u8, href: []const u8 };

pub const AnswerSource = struct { n: u32, title: []const u8, href: []const u8, source: []const u8 };
pub const AnswerBlock = struct { text: []const u8, model: []const u8, sources: []const AnswerSource };

/// The answer above the results: text only (never markup), labelled, with the passages it was made from.
fn writeAnswer(w: *Writer, f: Form) Writer.Error!void {
    if (f.answer_note) |n| {
        try w.writeAll("<p class=\"muted small\">");
        try writeEscaped(w, n);
        try w.writeAll("</p>\n");
    }
    const a = f.answer orelse return;
    try w.writeAll("<section class=\"answer\" aria-label=\"AI answer\"><h2>Answer</h2><p class=\"muted small\">Written by a language model (");
    try writeEscaped(w, a.model);
    try w.writeAll(") on this machine from the passages below. It can be wrong: check the sources.</p><p>");
    var lines = std.mem.splitScalar(u8, a.text, '\n');
    var first = true;
    while (lines.next()) |l| {
        if (!first) try w.writeAll("<br>");
        first = false;
        try writeEscaped(w, l);
    }
    try w.writeAll("</p><ol class=\"answer-sources\">");
    for (a.sources) |s| {
        try w.print("<li value=\"{d}\"><a href=\"", .{s.n});
        try writeEscaped(w, s.href);
        try w.writeAll("\">");
        try writeEscaped(w, s.title);
        try w.writeAll("</a> <span class=\"muted small\">");
        try writeEscaped(w, s.source);
        try w.writeAll("</span></li>");
    }
    try w.writeAll("</ol></section>\n");
}

/// `12345` as `12,345`.
pub fn writeCount(w: *Writer, n: u64) Writer.Error!void {
    var buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    for (digits, 0..) |c, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(c);
    }
}

pub const SourceRow = struct { name: []const u8, kind: []const u8, docs: ?u64, last_added: ?i64, collections: []const []const u8 };

/// The page that lists the sources the visitor may search, with what each holds. No script.
pub fn writeSourcesPage(w: *Writer, rows: []const SourceRow, now: i64) Writer.Error!void {
    try writeHead(w, "Sources");
    try w.writeAll("<body>");
    try writeSidePanel(w, false, .none);
    try w.writeAll("<main class=\"results-page\"><div class=\"head\"><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1></div><h2>Sources</h2>");
    if (rows.len == 0) {
        try w.writeAll("<p class=\"notice\">No sources are available here.</p>");
    } else {
        try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>Source</th><th>Kind</th><th>Documents</th><th>Last added</th><th>In collections</th><th></th></tr></thead><tbody>");
        for (rows) |r| {
            try w.writeAll("<tr><td><strong>");
            try writeEscaped(w, r.name);
            try w.writeAll("</strong></td><td>");
            try writeEscaped(w, kindLabel(r.kind));
            try w.writeAll("</td><td>");
            if (r.docs) |n| try writeCount(w, n) else try w.writeAll("<span class=\"muted\">?</span>");
            try w.writeAll("</td><td>");
            if (r.last_added) |t| {
                try writeDate(w, t);
                if (now > t) {
                    try w.writeAll(" <small class=\"muted\">(");
                    const days = @divFloor(now - t, 86400);
                    if (days == 0) try w.writeAll("today") else try w.print("{d} d ago", .{days});
                    try w.writeAll(")</small>");
                }
            } else try w.writeAll("<span class=\"muted\">&ndash;</span>");
            try w.writeAll("</td><td>");
            for (r.collections, 0..) |c, i| {
                if (i > 0) try w.writeAll(", ");
                try writeEscaped(w, c);
            }
            try w.writeAll("</td><td><a href=\"/search?q=source%3A");
            try query.writeEncoded(w, r.name);
            try w.writeAll("\">Search it</a></td></tr>");
        }
        try w.writeAll("</tbody></table></div>");
    }
    try w.writeAll("</main></body></html>\n");
}

pub const PeerNote = struct { name: []const u8, text: []const u8, ok: bool };

pub fn writeHead(w: *Writer, title: []const u8) Writer.Error!void {
    try w.writeAll("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>");
    try writeEscaped(w, title);
    try w.writeAll("</title><link rel=\"stylesheet\" href=\"/assets/style.css?v=" ++ style_version ++ "\"></head>\n");
}

fn isPicked(picked: []const []const u8, value: []const u8) bool {
    for (picked) |p| if (std.mem.eql(u8, p, value)) return true;
    return false;
}

/// The sources as tick boxes grouped by kind (works without JavaScript). Ticking a kind's "All" box means
/// every source of that kind, now and later. Nothing ticked searches everything.
fn writeSourcePicker(w: *Writer, f: Form) Writer.Error!void {
    if (f.sources.len == 0 and f.picked.len == 0 and f.collections.len == 0) return;
    try w.writeAll("<fieldset class=\"sources\"><legend>Sources <small>(none ticked: all)</small></legend>");
    if (f.collections.len > 0) {
        try w.writeAll("<div class=\"srcgroup\"><strong>Collections</strong>");
        for (f.collections) |col| {
            var buf: [80]u8 = undefined;
            const value = std.fmt.bufPrint(&buf, "collection:{s}", .{col.name}) catch continue;
            try w.writeAll("<label class=\"check\"");
            if (col.description.len > 0) {
                try w.writeAll(" title=\"");
                try writeEscaped(w, col.description);
                try w.writeAll("\"");
            }
            try w.writeAll("><input type=\"checkbox\" name=\"source\" value=\"");
            try writeEscaped(w, value);
            try w.writeAll(if (isPicked(f.picked, value)) "\" checked> " else "\"> ");
            try writeEscaped(w, col.name);
            try w.writeAll("</label>");
        }
        try w.writeAll("</div>");
    }
    var i: usize = 0;
    while (i < f.sources.len) {
        const kind = f.sources[i].kind;
        var end = i;
        while (end < f.sources.len and std.mem.eql(u8, f.sources[end].kind, kind)) end += 1;
        var kind_value_buf: [80]u8 = undefined;
        const kind_value = std.fmt.bufPrint(&kind_value_buf, "kind:{s}", .{kind}) catch "kind:";
        const whole_kind = isPicked(f.picked, kind_value);
        try w.writeAll("<div class=\"srcgroup\"><strong>");
        try writeEscaped(w, kindLabel(kind));
        try w.writeAll("</strong>");
        if (end - i > 1) {
            try w.writeAll("<label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"");
            try writeEscaped(w, kind_value);
            try w.writeAll(if (whole_kind) "\" checked> all of these</label>" else "\"> all of these</label>");
        }
        for (f.sources[i..end]) |src| {
            try w.writeAll("<label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"");
            try writeEscaped(w, src.name);
            try w.writeAll(if (whole_kind or isPicked(f.picked, src.name)) "\" checked> " else "\"> ");
            try writeEscaped(w, src.name);
            if (src.docs) |n| {
                try w.writeAll(" <small class=\"muted\">(");
                try writeCount(w, n);
                try w.writeAll(")</small>");
            }
            try w.writeAll("</label>");
        }
        try w.writeAll("</div>");
        i = end;
    }
    // A choice that is not in the list (a source since removed, or typed into the address) stays ticked, so it
    // is visible and can be unticked.
    for (f.picked) |p| {
        var known = false;
        if (std.mem.startsWith(u8, p, "collection:")) {
            for (f.collections) |col| if (std.mem.eql(u8, col.name, p["collection:".len..])) {
                known = true;
            };
            if (known) continue;
        }
        const is_kind = std.mem.startsWith(u8, p, "kind:");
        for (f.sources) |src| {
            if (if (is_kind) std.mem.eql(u8, src.kind, p["kind:".len..]) else std.mem.eql(u8, src.name, p)) known = true;
        }
        if (known) continue;
        try w.writeAll("<div class=\"srcgroup\"><strong>Not configured</strong><label class=\"check\"><input type=\"checkbox\" name=\"source\" value=\"");
        try writeEscaped(w, p);
        try w.writeAll("\" checked> ");
        try writeEscaped(w, p);
        try w.writeAll("</label></div>");
    }
    try w.writeAll("</fieldset>");
}

fn writeSourceParams(w: *Writer, picked: []const []const u8) Writer.Error!void {
    for (picked) |p| {
        try w.writeAll("&amp;source=");
        try query.writeEncoded(w, p);
    }
}

fn writeForm(w: *Writer, f: Form) Writer.Error!void {
    try w.writeAll("<form class=\"search\" action=\"/search\" method=\"get\" role=\"search\">" ++
        "<input type=\"search\" name=\"q\" maxlength=\"1024\" aria-label=\"Search\" autofocus value=\"");
    try writeEscaped(w, f.q);
    try w.writeAll("\"><button type=\"submit\">Search</button><button type=\"submit\" name=\"images\" value=\"1\" class=\"secondary\">Images</button>");
    const open = if (f.language.len > 0 or f.picked.len > 0 or f.sort.len > 0 or f.peers_on) " open" else "";
    try w.writeAll("<div class=\"filterrow\">");
    try w.print("<details{s}><summary><span>Filters</span></summary><label>Language <input name=\"language\" maxlength=\"64\" value=\"", .{open});
    try writeEscaped(w, f.language);
    try w.writeAll("\"></label>");
    try writeSourcePicker(w, f);
    if (f.peer_names.len > 0) {
        try w.print("<label class=\"check\"><input type=\"checkbox\" name=\"peers\" value=\"1\"{s}> Also ask peers (", .{if (f.peers_on) " checked" else ""});
        for (f.peer_names, 0..) |n, i| {
            if (i > 0) try w.writeAll(", ");
            try writeEscaped(w, n);
        }
        try w.writeAll(")</label>");
    }
    if (f.semantic_offered) try w.print("<label class=\"check\"><input type=\"checkbox\" name=\"semantic\" value=\"1\"{s}> Also search by meaning (AI)</label>", .{if (f.semantic_checked) " checked" else ""});
    if (f.answers_offered) try w.print("<label class=\"check\"><input type=\"checkbox\" name=\"answer\" value=\"1\"{s}> Also write an answer with the local AI model (slower)</label>", .{if (f.answer_checked) " checked" else ""});
    try w.writeAll("<label>Order <select name=\"sort\">");
    const orders = [_][2][]const u8{ .{ "", "Best match" }, .{ "newest", "Newest" }, .{ "oldest", "Oldest" }, .{ "largest", "Largest" }, .{ "smallest", "Smallest" }, .{ "title", "Title" } };
    for (orders) |o| {
        try w.print("<option value=\"{s}\"{s}>{s}</option>", .{ o[0], if (std.mem.eql(u8, o[0], f.sort)) " selected" else "", o[1] });
    }
    try w.writeAll("</select></label>");
    try w.writeAll("<label>Excerpts <select name=\"snippets\">");
    for ([_]u8{ 1, 2, 3, 5 }) |n| try w.print("<option value=\"{d}\"{s}>{d}</option>", .{ n, if (n == f.snippets) " selected" else "", n });
    try w.writeAll("</select></label>");
    try w.writeAll("</details>");
    try writeSafeNote(w, f.safe_note);
    try w.writeAll("</div></form>\n");
    try writeSafeForms(w, f.safe_note);
    if (f.regex_notice) |n| {
        try w.writeAll("<p class=\"error\" role=\"alert\">");
        try writeEscaped(w, n);
        try w.writeAll("</p>\n");
    }
}

/// The left panel: the search syntax at a glance, with links to the full guides.
fn writeSidePanel(w: *Writer, regex_enabled: bool, login: LoginNote) Writer.Error!void {
    try w.writeAll("<input type=\"checkbox\" id=\"sidetoggle\" class=\"sidetoggle\" aria-label=\"Show search tips\"><label for=\"sidetoggle\" class=\"burger\" title=\"Search tips\">&#9776;</label><label for=\"sidetoggle\" class=\"scrim\"></label>");
    try w.writeAll("<aside class=\"side\" aria-label=\"Search tips\"><h2>Search tips</h2>");
    try w.writeAll("<h3>Words</h3><dl><dt><code>\"exact phrase\"</code></dt><dd>words together, in order</dd>" ++
        "<dt><code>a OR b</code></dt><dd>either word</dd>" ++
        "<dt><code>a -b</code></dt><dd>a, but not b</dd>" ++
        "<dt><code>comp*</code></dt><dd>words starting with comp</dd>" ++
        "<dt><code>word~</code></dt><dd>allow typos (up to two for longer words)</dd>" ++
        "<dt><code>title:word</code></dt><dd>only in the title</dd></dl>");
    try w.writeAll("<h3>Filters</h3><dl><dt><code>ext:pdf</code></dt><dd>file extension</dd>" ++
        "<dt><code>type:image</code></dt><dd>page, text, pdf, document, image, video, audio&hellip;</dd>" ++
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
    try w.writeAll("<p class=\"small\"><a href=\"/sources\">Sources</a> &middot; <a href=\"/help/search\">Full guide</a>");
    if (regex_enabled) try w.writeAll(" &middot; <a href=\"/help/regex\">Regex guide</a>");
    try w.writeAll("</p>");
    _ = login; // the Login button is in the page header
    try w.writeAll("</aside>\n");
}

pub fn writeHome(w: *Writer, notice: ?[]const u8) Writer.Error!void {
    return writeHomeWith(w, notice, false);
}

/// The home page; `regex_enabled` adds the regex filter to the form.
pub fn writeHomeWith(w: *Writer, notice: ?[]const u8, regex_enabled: bool) Writer.Error!void {
    return writeHomeForm(w, notice, .{ .regex_enabled = regex_enabled });
}

/// The home page with a prepared form (the source list and so on).
/// Safe search as the visitor meets it: on (with a way to unlock when the server has a PIN), or off in this browser.
pub const SafeNote = enum { none, on_unlockable, on, unlocked };

/// What the side panel offers about signing in with an API key.
pub const LoginNote = enum { none, offered, signed_in };

/// The Login button at the top right of the search pages, or Logout when signed in.
fn writeLoginButton(w: *Writer, login: LoginNote) Writer.Error!void {
    switch (login) {
        .none => {},
        .offered => try w.writeAll("<div class=\"loginbtn\"><a href=\"/login\">Login</a></div>\n"),
        .signed_in => try w.writeAll("<form class=\"loginbtn\" action=\"/logout\" method=\"post\"><button type=\"submit\">Logout</button></form>\n"),
    }
}

/// The safe-search state, on the line of the Filters switch at the right (inside the search form, so its fields name the
/// separate forms below with `form=`: a form cannot hold another form).
fn writeSafeNote(w: *Writer, note: SafeNote) Writer.Error!void {
    switch (note) {
        .none => {},
        .on => try w.writeAll("<div class=\"safenote muted small\">Safe search is on.</div>"),
        .on_unlockable => try w.writeAll("<div class=\"safenote muted small\"><span>Safe search is on.</span> <label>PIN <input form=\"unlockform\" type=\"password\" name=\"pin\" inputmode=\"numeric\" autocomplete=\"off\" size=\"6\" aria-label=\"PIN to unlock safe search\"></label> <button form=\"unlockform\" type=\"submit\" class=\"secondary\">Unlock</button></div>"),
        .unlocked => try w.writeAll("<div class=\"safenote muted small\"><span>Safe search is off in this browser.</span> <button form=\"lockform\" type=\"submit\" class=\"secondary\">Turn it back on</button></div>"),
    }
}

/// The forms the safe-search controls belong to (empty: their fields are inside the search form).
fn writeSafeForms(w: *Writer, note: SafeNote) Writer.Error!void {
    switch (note) {
        .on_unlockable => try w.writeAll("<form id=\"unlockform\" action=\"/unlock\" method=\"post\"></form>\n"),
        .unlocked => try w.writeAll("<form id=\"lockform\" action=\"/lock\" method=\"post\"></form>\n"),
        else => {},
    }
}

pub fn writeHomeForm(w: *Writer, notice: ?[]const u8, form: Form) Writer.Error!void {
    const regex_enabled = form.regex_enabled;
    try writeHead(w, "dksearch");
    try w.writeAll("<body class=\"home\">");
    try writeLoginButton(w, form.login);
    try writeSidePanel(w, regex_enabled, form.login);
    try w.writeAll("<main><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1>\n");
    try writeForm(w, form);
    if (notice) |n| {
        try w.writeAll("<p class=\"error\" role=\"alert\">");
        try writeEscaped(w, n);
        try w.writeAll("</p>");
    }
    try w.writeAll(search_script);
    try w.writeAll("</main></body></html>\n");
}

pub fn writeResults(w: *Writer, f: Form, page: dk.search.Page, offset: u32, page_size: u32) Writer.Error!void {
    try writeHead(w, if (f.q.len > 0) f.q else "dksearch");
    try w.writeAll("<body>");
    try writeLoginButton(w, f.login);
    try writeSidePanel(w, f.regex_enabled, f.login);
    // The gallery uses the width of the window (the text results keep a reading width).
    try w.writeAll(if (f.images) "<main class=\"results-page gallery-page\">" else "<main class=\"results-page\">");
    try w.writeAll("<div class=\"head\"><h1 class=\"brand\"><a href=\"/\">dksearch</a></h1>");
    try writeForm(w, f);
    try w.writeAll("</div>\n");
    if (f.semantic_text) |t| {
        try w.writeAll("<p class=\"muted small\">");
        try writeEscaped(w, t);
        try w.writeAll("</p>\n");
    }
    try writeInterpretation(w, f, page, offset);
    try writeAnswer(w, f);
    if (f.default_note) |name| {
        try w.writeAll("<p class=\"muted small\">Searching only <strong>");
        try writeEscaped(w, name);
        try w.writeAll("</strong> (the default). <a href=\"/search?q=");
        try query.writeEncoded(w, f.q);
        try w.writeAll("&amp;sources=all\">Search all sources</a></p>\n");
    }
    if (f.peer_notes.len > 0) {
        try w.writeAll("<p class=\"muted small\">Peers: ");
        for (f.peer_notes, 0..) |n, i| {
            if (i > 0) try w.writeAll("; ");
            try w.writeAll("<strong>");
            try writeEscaped(w, n.name);
            try w.writeAll("</strong> ");
            try writeEscaped(w, n.text);
        }
        try w.writeAll("</p>\n");
    }

    if (page.hits.len == 0) {
        try w.writeAll("<p class=\"notice\">No results for &ldquo;");
        try writeEscaped(w, f.q);
        try w.writeAll("&rdquo;.</p>");
        if (f.did_you_mean) |d| {
            try w.writeAll("<p class=\"notice\">Did you mean <a href=\"/search?q=");
            try query.writeEncoded(w, d);
            try w.writeAll("\"><strong>");
            try writeEscaped(w, d);
            try w.writeAll("</strong></a>?</p>");
        }
    } else if (f.images) {
        try writeGallery(w, f, page.hits);
    } else {
        try w.writeAll("<ol class=\"results\" start=\"");
        try w.print("{d}", .{offset + 1});
        try w.writeAll("\"");
        if (f.feedback) {
            try w.writeAll(" data-feedback=\"1\" data-q=\"");
            try writeEscaped(w, f.q);
            try w.writeAll("\"");
        }
        try w.writeAll(">\n");
        for (page.hits) |h| try writeHit(w, h);
        try w.writeAll("</ol>\n");
    }

    try writeFallback(w, f);
    if (f.feedback and f.q.len > 0 and !f.images) {
        try w.writeAll("<details class=\"suggest\"><summary>A site missing from these results?</summary><form class=\"suggest\" data-q=\"");
        try writeEscaped(w, f.q);
        try w.writeAll("\"><input type=\"url\" name=\"url\" placeholder=\"https://example.org/\" required maxlength=\"2000\" aria-label=\"Address of the site\"> <button type=\"submit\">Suggest this site</button> <span class=\"msg\" role=\"status\"></span></form><p class=\"hint\">It is added to the sites to crawl and kept as a good answer for this search.</p></details>\n");
    }
    if (offset > 0 or page.has_more) {
        try w.writeAll("<nav class=\"pager\" aria-label=\"Pages\"><span>");
        if (offset > 0) try writePagerLink(w, f, offset -| page_size, "&larr; Previous");
        try w.writeAll("</span><span class=\"pages\">");
        try writePageNumbers(w, f, offset, page_size);
        try w.writeAll("</span><span>");
        if (page.has_more) try writePagerLink(w, f, offset + page_size, "Next &rarr;");
        try w.writeAll("</span></nav>\n");
    }
    try w.writeAll(search_script);
    try w.writeAll("</main></body></html>\n");
}

/// The opt-in fallback: a way to ask the providers, their results (labelled external), and links to other engines.
fn writeFallback(w: *Writer, f: Form) Writer.Error!void {
    if (f.web_href) |href| {
        try w.writeAll("<p class=\"muted small\"><a href=\"");
        try writeEscaped(w, href);
        try w.writeAll("\">Also search the web through ");
        try writeEscaped(w, f.web_names);
        try w.writeAll("</a> (your words are sent to that service)</p>\n");
    }
    if (f.external.len > 0) {
        try w.writeAll("<h2 class=\"external-heading\">From the web</h2><p class=\"muted small\">Results from other services, asked for by this server with your words; they are not part of this index and not ranked with it.</p><ol class=\"results external\">\n");
        for (f.external) |e| {
            try w.writeAll("<li><a class=\"title\" href=\"");
            try writeEscaped(w, e.url);
            try w.writeAll("\" rel=\"noopener noreferrer nofollow\">");
            try writeEscaped(w, e.title);
            try w.writeAll("</a><div class=\"url\">");
            try writeEscaped(w, e.url);
            try w.writeAll("</div>");
            if (e.snippet) |s| {
                try w.writeAll("<p class=\"snippet\">");
                try writeEscaped(w, s);
                try w.writeAll("</p>");
            }
            try w.writeAll("<div class=\"source\">via ");
            try writeEscaped(w, e.provider);
            try w.writeAll(" &middot; external</div></li>\n");
        }
        try w.writeAll("</ol>\n");
    }
    for (f.external_notes) |n| {
        try w.writeAll("<p class=\"muted small\">");
        try writeEscaped(w, n);
        try w.writeAll("</p>\n");
    }
    if (f.fallback_links.len > 0) {
        try w.writeAll("<p class=\"muted small\">Search elsewhere: ");
        for (f.fallback_links, 0..) |l, i| {
            if (i > 0) try w.writeAll(" &middot; ");
            try w.writeAll("<a href=\"");
            try writeEscaped(w, l.href);
            try w.writeAll("\" rel=\"noopener noreferrer nofollow\">");
            try writeEscaped(w, l.label);
            try w.writeAll("</a>");
        }
        try w.writeAll("</p>\n");
    }
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
        try writeSourceParams(w, f.picked);
        if (f.regex.len > 0) {
            try w.writeAll("&amp;regex=");
            try query.writeEncoded(w, f.regex);
        }
        try w.writeAll("&amp;fuzzy=0\">Search exactly as typed</a></p>\n");
    }
    if (page.ignored.len > 0) {
        try w.writeAll("<p class=\"muted small\">Left out as too common to help: ");
        for (page.ignored, 0..) |word, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll("<code>");
            try writeEscaped(w, word);
            try w.writeAll("</code>");
        }
        try w.writeAll(" (they appear in a large share of all documents). Put words in quotes to require them.</p>\n");
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
    if (h.url) |u| if (h.remote_view == null and std.mem.startsWith(u8, u, "zim://")) {
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
    try w.writeAll("<a class=\"title\" href=\"");
    try writeViewHref(w, h);
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

/// Pictures as a grid: the picture itself from this server when its original is served (the browser scales it; nothing is
/// stored or resized here), otherwise the file name; each links to the document page.
fn writeGallery(w: *Writer, f: Form, hits: []const dk.search.Hit) Writer.Error!void {
    try w.writeAll("<ul class=\"gallery\">\n");
    for (hits, 0..) |h, i| {
        const label = h.title orelse h.url orelse "(untitled)";
        try w.writeAll("<li><a href=\"");
        try writeViewHref(w, h);
        try w.writeAll("\" title=\"");
        try writeEscaped(w, label);
        try w.writeAll("\">");
        if (i < f.gallery_ok.len and f.gallery_ok[i]) {
            try w.writeAll("<img loading=\"lazy\" decoding=\"async\" alt=\"");
            try writeEscaped(w, label);
            try w.writeAll("\" src=\"");
            try writeViewHref(w, h);
            // A small copy from the thumbnail cache when there is one; else a picture of a file is shown from the file,
            // one of the web through the relay.
            if (f.gallery_thumbs) {
                try w.writeAll("/thumb\">");
            } else try w.writeAll(if (h.url) |u| (if (std.mem.startsWith(u8, u, "file://")) "/file\">" else "/image\">") else "/file\">");
        } else try w.writeAll("<span class=\"nopic\">no preview</span>");
        try w.writeAll("<span class=\"cap\">");
        try writeEscaped(w, label);
        try w.writeAll("</span></a></li>\n");
    }
    try w.writeAll("</ul>\n");
}

fn finishHit(w: *Writer, h: dk.search.Hit) Writer.Error!void {
    if (h.snippet) |s| if (s.len > 0) {
        try w.writeAll("<p class=\"snippet\">");
        try writeSnippet(w, s);
        try w.writeAll("</p>");
    };
    for (h.more_snippets) |m| {
        try w.writeAll("<p class=\"snippet more\">");
        try writeSnippet(w, m);
        try w.writeAll("</p>");
    }
    try w.writeAll("<div class=\"source\">");
    if (dk.domainlist.hiddenNetworkOf(h.url)) |net| {
        try w.writeAll(if (std.mem.eql(u8, net, "onion")) "<span class=\"badge\" title=\"A Tor onion address: it opens only in Tor Browser or another Tor-enabled browser\">Tor</span> " else "<span class=\"badge\" title=\"An I2P address: it opens only through an I2P router\">I2P</span> ");
    }
    if (h.node) |n| {
        try w.writeAll("<strong>");
        try writeEscaped(w, n);
        try w.writeAll("</strong> &middot; ");
    }
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
    try w.writeAll(" &middot; <a href=\"");
    try writeViewHref(w, h);
    try w.writeAll("\">Stored text</a>");
    if (h.same_in.len > 0) {
        try w.writeAll(" &middot; same text in ");
        for (h.same_in, 0..) |n, i| {
            if (i > 0) try w.writeAll(", ");
            try writeEscaped(w, n);
        }
    }
    if (h.also_on.len > 0) {
        try w.writeAll(" &middot; also on ");
        for (h.also_on, 0..) |n, i| {
            if (i > 0) try w.writeAll(", ");
            try writeEscaped(w, n);
        }
    }
    try w.writeAll("</div></li>\n");
}

/// The page of the stored document: here, or on the peer that has it.
fn writeViewHref(w: *Writer, h: dk.search.Hit) Writer.Error!void {
    if (h.remote_view) |v| return writeEscaped(w, v);
    try w.writeAll("/doc/");
    try writeIdHex(w, h.id);
}

fn writeIdHex(w: *Writer, id: dk.document.Id) Writer.Error!void {
    const hex = std.fmt.bytesToHex(id, .lower);
    try w.writeAll(&hex);
}

/// `1.5 MB`, `300 B`: sizes people read.
pub fn writeSize(w: *Writer, n: u64) Writer.Error!void {
    if (n < 1024) return w.print("{d} B", .{n});
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    v /= 1024;
    while (v >= 1024 and i + 1 < units.len) : (i += 1) v /= 1024;
    try w.print("{d:.1} {s}", .{ v, units[i] });
}

/// A Unix time as `2026-11-16` (UTC).
pub fn writeDate(w: *Writer, secs: i64) Writer.Error!void {
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

pub fn writeDocument(w: *Writer, h: dk.search.Hit, text: ?[]const u8, cut: bool, open_links: []const OpenLink, rendered: ?[]const u8, is_markdown: bool, similar: []const dk.search.Hit) Writer.Error!void {
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
    if (open_links.len > 0) {
        try w.writeAll("<p>");
        for (open_links, 0..) |l, i| {
            if (i > 0) try w.writeAll(" ");
            try w.writeAll("<a class=\"button\" href=\"");
            try writeEscaped(w, l.href);
            try w.writeAll("\">");
            try writeEscaped(w, l.label);
            try w.writeAll("</a>");
        }
        try w.writeAll("</p>\n");
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
    if (similar.len > 0) {
        try w.writeAll("<section class=\"similar\"><h3>Similar documents</h3><ul>");
        for (similar) |s| {
            try w.writeAll("<li><a href=\"");
            try writeViewHref(w, s);
            try w.writeAll("\">");
            try writeEscaped(w, s.title orelse s.url orelse "(untitled)");
            try w.writeAll("</a> <span class=\"muted\">");
            try writeEscaped(w, s.connector);
            try w.writeAll("</span></li>");
        }
        try w.writeAll("</ul></section>");
    }
    try w.writeAll("<p><a href=\"/\">&larr; New search</a></p></main></body></html>\n");
}

fn metaRow(w: *Writer, name: []const u8, value: []const u8) Writer.Error!void {
    try w.print("<dt>{s}</dt><dd>", .{name});
    try writeEscaped(w, value);
    try w.writeAll("</dd>");
}

/// "Page 4" with the pages before it as links (the first, then the last eight before this one), so a reader can see how
/// far they have gone and step back to any of them. The pages after this one are not known: only "Next".
fn writePageNumbers(w: *Writer, f: Form, offset: u32, page_size: u32) Writer.Error!void {
    if (page_size == 0) return;
    const current: u32 = offset / page_size + 1;
    try w.writeAll("Page ");
    const first_shown: u32 = if (current > 9) current - 8 else 1;
    if (first_shown > 1) {
        try writePagerLink(w, f, 0, "1");
        try w.writeAll(" &hellip; ");
    }
    var p: u32 = first_shown;
    while (p < current) : (p += 1) {
        var label: [12]u8 = undefined;
        try writePagerLink(w, f, (p - 1) * page_size, std.fmt.bufPrint(&label, "{d}", .{p}) catch "");
        try w.writeAll(" ");
    }
    try w.print("<strong aria-current=\"page\">{d}</strong>", .{current});
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
    try writeSourceParams(w, f.picked);
    if (f.all_sources) try w.writeAll("&amp;sources=all");
    if (f.regex.len > 0) {
        try w.writeAll("&amp;regex=");
        try query.writeEncoded(w, f.regex);
        if (f.regex_ignore_case) try w.writeAll("&amp;regex_flags=i");
    }
    if (f.exact_only) try w.writeAll("&amp;fuzzy=0");
    if (f.snippets > 1) try w.print("&amp;snippets={d}", .{f.snippets});
    if (f.semantic_checked) try w.writeAll("&amp;semantic=1");
    if (f.images) try w.writeAll("&amp;images=1");
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
        .{ "compositor~", "the word, or a word of the index a typo or two away from it" },
        .{ "\"window manager\"~5", "the two words within five words of each other, in any order" },
    };
    for (rows) |r| try w.print("<tr><td><code>{s}</code></td><td>{s}</td></tr>", .{ r[0], r[1] });
    try w.writeAll("</tbody></table></div>\n");
    try w.writeAll("<h3>Filters: narrow by what kind of document it is</h3><p>Write them in the search box next to your words. Put a minus in front to leave matching documents out. A search made only of filters (<code>ext:pdf</code>) lists the matches, newest first.</p>\n");
    try w.writeAll("<div class=\"tablewrap\"><table class=\"data\"><thead><tr><th>You type</th><th>It means</th></tr></thead><tbody>");
    const filter_rows = [_][2][]const u8{
        .{ "ext:pdf", "files with that extension (also <code>-ext:pdf</code> to leave them out)" },
        .{ "type:image", "a kind of document: page, text, markdown, pdf, document, image, video, audio, data, other" },
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
    try w.writeAll("<h3>You do not have to spell everything right</h3><p>If a search finds fewer than three results, dksearch automatically tries again with words of the index that are a typo away (a letter missing, extra, wrong or swapped; two typos for words of six letters or more) and tells you it did, with a link to search exactly as typed. Short words (three letters or fewer) are never guessed at. To force it for one word, write <code>word~</code>, or <code>word~1</code> or <code>word~2</code> to say how many typos to allow.</p>\n");
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
    try w.writeAll("</tbody></table></div>\n<h3>Limits to know about</h3><ul><li>The pattern is matched on characters: <code>.</code> is one letter such as &eacute;, <code>[&agrave;-&yuml;]</code> is a range of letters and <code>\\w</code> includes letters outside ASCII. Unicode properties such as <code>\\p{L}</code> are not available, and case-insensitive matching only folds ASCII letters.</li><li>A pattern that takes too long on the documents it is tried on is refused with an explanation: make it simpler, for example avoid nesting <code>(a+)+</code>.</li><li>The pattern is part of the query, so the words and filters next to it can still use quotes, OR, NOT and so on (see <a href=\"/help/search\">search tips</a>).</li></ul><p><a href=\"/\">&larr; Back to search</a></p></main></body></html>\n");
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
    // The one script on the page is our own search.js; nothing from a title or snippet becomes a tag.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "<script"));
    try testing.expect(std.mem.indexOf(u8, out, "<script src=\"/assets/search.js?v=") != null);
    try testing.expect(std.mem.indexOf(u8, out, "value=\"a &quot;b&quot; &lt;c&gt;\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<mark>y</mark>") != null);
    // Pager: previous goes to offset 0 (no offset param), next to offset 20.
    try testing.expect(std.mem.indexOf(u8, out, "href=\"/search?q=a%20%22b%22%20%3Cc%3E&amp;language=en\">&larr; Previous") != null);
    try testing.expect(std.mem.indexOf(u8, out, "&amp;offset=20\">Next") != null);
    // "Page 2" with page 1 as a link, and the current page not a link.
    try testing.expect(std.mem.indexOf(u8, out, "Page <a href=\"/search?q=a%20%22b%22%20%3Cc%3E&amp;language=en\">1</a> <strong aria-current=\"page\">2</strong>") != null);
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
