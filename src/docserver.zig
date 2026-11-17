//! Opening a document's original file in a document server (OnlyOffice or Collabora Online / LibreOffice Online),
//! read-only, from the viewer page.
//!
//! dksearch does not run an editor. The viewer links to `/doc/ID/open`, which checks that the caller may see the
//! document and then either redirects the browser to Collabora (which fetches the file from dksearch over WOPI:
//! `/wopi/files/ID` and `/wopi/files/ID/contents`) or serves a small page that loads OnlyOffice's editor script and
//! points it at the file. The document server has no cookie or API key, so it is given a token: an HMAC over the
//! document id and an expiry, valid for one document and one hour, good only for reading that file.
//!
//! Nothing here does I/O; the handler supplies the clock and the random secret.

const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const doc = @import("document.zig");

pub const Kind = enum { onlyoffice, collabora };

pub const Settings = struct {
    kind: Kind,
    /// The document server as a browser reaches it, `http://host:port` (no trailing slash).
    url: []const u8,
    /// dksearch as the document server reaches it (it fetches the file from there), `http://host:port`.
    public_url: []const u8,
    /// OnlyOffice's JWT secret, when its server has JWT turned on (the default of its Docker image).
    jwt_secret: ?[]const u8 = null,
};

pub const token_ttl_seconds = 3600;

/// The settings with the secret that signs tokens (random, made at start: links stop working when the server
/// restarts, which is harmless) and a clock.
pub const Service = struct {
    settings: Settings,
    secret: [32]u8,
    io: std.Io,

    pub fn init(io: std.Io, settings: Settings) !Service {
        var s: Service = .{ .settings = settings, .secret = undefined, .io = io };
        io.randomSecure(&s.secret) catch return error.EntropyUnavailable;
        return s;
    }

    pub fn now(self: *const Service) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }
};

/// Formats the document server can show, by extension, with OnlyOffice's document type.
pub const Format = struct { ext: []const u8, doc_type: []const u8, mime: []const u8 };

pub const formats = [_]Format{
    .{ .ext = "docx", .doc_type = "word", .mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
    .{ .ext = "odt", .doc_type = "word", .mime = "application/vnd.oasis.opendocument.text" },
    .{ .ext = "doc", .doc_type = "word", .mime = "application/msword" },
    .{ .ext = "rtf", .doc_type = "word", .mime = "application/rtf" },
    .{ .ext = "xlsx", .doc_type = "cell", .mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
    .{ .ext = "ods", .doc_type = "cell", .mime = "application/vnd.oasis.opendocument.spreadsheet" },
    .{ .ext = "xls", .doc_type = "cell", .mime = "application/vnd.ms-excel" },
    .{ .ext = "csv", .doc_type = "cell", .mime = "text/csv" },
    .{ .ext = "pptx", .doc_type = "slide", .mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
    .{ .ext = "odp", .doc_type = "slide", .mime = "application/vnd.oasis.opendocument.presentation" },
    .{ .ext = "ppt", .doc_type = "slide", .mime = "application/vnd.ms-powerpoint" },
};

/// The format of a file name (by its extension, case-insensitive), or null if a document server is no use for it.
pub fn formatOf(name: []const u8) ?Format {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const ext = name[dot + 1 ..];
    for (formats) |f| if (std.ascii.eqlIgnoreCase(ext, f.ext)) return f;
    return null;
}

// ------------------------------------------------------------------ tokens

pub const token_len = 32 + 1 + 43; // base64url of id and expiry (24 bytes), a dot, base64url of the signature (32 bytes)

/// `<id><expiry>.<signature>`, all base64url: 24 bytes then 32 bytes.
pub fn makeToken(secret: *const [32]u8, id: doc.Id, expires: i64, out: *[token_len]u8) []const u8 {
    var body: [24]u8 = undefined;
    @memcpy(body[0..16], &id);
    std.mem.writeInt(i64, body[16..24], expires, .big);
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, &body, secret);
    const enc = std.base64.url_safe_no_pad;
    const a = enc.Encoder.encode(out[0..32], &body);
    out[a.len] = '.';
    const b = enc.Encoder.encode(out[a.len + 1 ..], &mac);
    return out[0 .. a.len + 1 + b.len];
}

/// The document id the token is for, if it is genuine and has not expired at `now`.
pub fn checkToken(secret: *const [32]u8, token: []const u8, now: i64) ?doc.Id {
    const dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    if (dot != 32 or token.len - dot - 1 != 43) return null;
    var body: [24]u8 = undefined;
    var mac: [32]u8 = undefined;
    const dec = std.base64.url_safe_no_pad.Decoder;
    dec.decode(&body, token[0..dot]) catch return null;
    dec.decode(&mac, token[dot + 1 ..]) catch return null;
    var want: [32]u8 = undefined;
    HmacSha256.create(&want, &body, secret);
    if (!std.crypto.timing_safe.eql([32]u8, want, mac)) return null;
    const expires = std.mem.readInt(i64, body[16..24], .big);
    if (now > expires) return null;
    return body[0..16].*;
}

// ------------------------------------------------------------------ Collabora (WOPI)

/// Where to send the browser for Collabora: its editor page, told where to fetch the file and with what token.
pub fn collaboraUrl(arena: Allocator, s: Settings, hex: []const u8, token: []const u8) Allocator.Error![]const u8 {
    var src: std.Io.Writer.Allocating = .init(arena);
    src.writer.print("{s}/wopi/files/{s}", .{ s.public_url, hex }) catch return error.OutOfMemory;
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.print("{s}/browser/dist/cool.html?WOPISrc=", .{s.url}) catch return error.OutOfMemory;
    writeEncoded(&out.writer, src.written()) catch return error.OutOfMemory;
    out.writer.print("&access_token={s}&permission=readonly", .{token}) catch return error.OutOfMemory;
    return out.written();
}

pub const CheckFileInfo = struct {
    BaseFileName: []const u8,
    Size: u64,
    OwnerId: []const u8 = "dksearch",
    UserId: []const u8 = "dksearch",
    UserFriendlyName: []const u8 = "dksearch",
    Version: []const u8,
    UserCanWrite: bool = false,
    ReadOnly: bool = true,
    UserCanNotWriteRelative: bool = true,
    DisablePrint: bool = false,
    DisableExport: bool = false,
};

// ------------------------------------------------------------------ OnlyOffice

fn writeEncoded(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |b| switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(b),
        else => try w.print("%{X:0>2}", .{b}),
    };
}

/// `payload` signed as a JWT (HS256), as OnlyOffice's server expects when it has a secret.
pub fn jwt(arena: Allocator, secret: []const u8, payload: []const u8) Allocator.Error![]const u8 {
    const enc = std.base64.url_safe_no_pad;
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const h = try arena.alloc(u8, enc.Encoder.calcSize(header.len));
    _ = enc.Encoder.encode(h, header);
    const p = try arena.alloc(u8, enc.Encoder.calcSize(payload.len));
    _ = enc.Encoder.encode(p, payload);
    const signing = try std.fmt.allocPrint(arena, "{s}.{s}", .{ h, p });
    var mac: [32]u8 = undefined;
    HmacSha256.create(&mac, signing, secret[0..]);
    const sig = try arena.alloc(u8, enc.Encoder.calcSize(mac.len));
    _ = enc.Encoder.encode(sig, &mac);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ signing, sig });
}

/// The editor configuration OnlyOffice's script is given, as JSON (without the signature).
pub fn onlyofficeConfig(arena: Allocator, s: Settings, hex: []const u8, token: []const u8, name: []const u8, format: Format, version: []const u8) Allocator.Error![]const u8 {
    const file_url = try std.fmt.allocPrint(arena, "{s}/wopi/files/{s}/contents?access_token={s}", .{ s.public_url, hex, token });
    // The key identifies this version of this file to the server's cache: a changed file must get a new one.
    const key = try std.fmt.allocPrint(arena, "{s}-{s}", .{ hex[0..@min(hex.len, 20)], version });
    const cfg = .{
        .document = .{
            .fileType = format.ext,
            .key = key,
            .title = name,
            .url = file_url,
            .permissions = .{ .edit = false, .download = true, .print = true, .copy = true, .comment = false },
        },
        .documentType = format.doc_type,
        .editorConfig = .{ .mode = "view", .lang = "en", .user = .{ .id = "dksearch", .name = "dksearch" }, .customization = .{ .compactHeader = true, .forcesave = false } },
        .width = "100%",
        .height = "100%",
    };
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(cfg, .{})});
}

/// The page that starts OnlyOffice's viewer. `script` is what to put in the inline script; the page's policy lets
/// that one script (by hash), the document server's script and frame, and nothing else, run.
pub const EditorPage = struct { html: []const u8, csp: []const u8 };

pub fn onlyofficePage(arena: Allocator, s: Settings, config_json: []const u8, title: []const u8) Allocator.Error!EditorPage {
    // The configuration is JSON in a script: keep it from ending the script or opening a comment.
    var safe: std.ArrayList(u8) = .empty;
    for (config_json) |b| switch (b) {
        '<' => try safe.appendSlice(arena, "\\u003c"),
        '>' => try safe.appendSlice(arena, "\\u003e"),
        '&' => try safe.appendSlice(arena, "\\u0026"),
        else => try safe.append(arena, b),
    };
    var signed: []const u8 = safe.items;
    if (s.jwt_secret) |secret| {
        // The signed token is part of the configuration; the unsigned fields stay for the script's own use.
        const token = try jwt(arena, secret, config_json);
        signed = try std.fmt.allocPrint(arena, "{s},\"token\":\"{s}\"}}", .{ safe.items[0 .. safe.items.len - 1], token });
    }
    const script = try std.fmt.allocPrint(arena, "new DocsAPI.DocEditor(\"editor\", {s});", .{signed});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &digest, .{});
    var b64: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &digest);
    var page: std.Io.Writer.Allocating = .init(arena);
    page.writer.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>") catch return error.OutOfMemory;
    writeText(&page.writer, title) catch return error.OutOfMemory;
    page.writer.print("</title><style>html,body,#editor{{height:100%;margin:0}}</style></head><body><div id=\"editor\"></div><script src=\"{s}/web-apps/apps/api/documents/api.js\"></script><script>{s}</script></body></html>\n", .{ s.url, script }) catch return error.OutOfMemory;
    const policy = try std.fmt.allocPrint(arena, "default-src 'none'; script-src {s} 'sha256-{s}'; frame-src {s}; connect-src {s}; img-src {s} data:; style-src 'unsafe-inline'; base-uri 'none'", .{ s.url, b64, s.url, s.url, s.url });
    return .{ .html = page.written(), .csp = policy };
}

fn writeText(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |b| switch (b) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(b),
    };
}

const testing = std.testing;

test "formats are recognised by extension" {
    try testing.expectEqualStrings("word", formatOf("a/b.DOCX").?.doc_type);
    try testing.expectEqualStrings("cell", formatOf("x.ods").?.doc_type);
    try testing.expectEqualStrings("slide", formatOf("x.pptx").?.doc_type);
    try testing.expect(formatOf("x.pdf") == null);
    try testing.expect(formatOf("noext") == null);
}

test "a token is for one document and expires, and cannot be altered" {
    const secret: [32]u8 = @splat(7);
    const other: [32]u8 = @splat(8);
    var id: doc.Id = @splat(0);
    id[3] = 9;
    var buf: [token_len]u8 = undefined;
    const t = makeToken(&secret, id, 1000, &buf);
    try testing.expectEqual(@as(usize, token_len), t.len);
    try testing.expectEqualSlices(u8, &id, &checkToken(&secret, t, 999).?);
    try testing.expectEqualSlices(u8, &id, &checkToken(&secret, t, 1000).?);
    try testing.expect(checkToken(&secret, t, 1001) == null); // expired
    try testing.expect(checkToken(&other, t, 10) == null); // another server's secret
    var forged: [token_len]u8 = undefined;
    @memcpy(&forged, t);
    forged[0] = if (forged[0] == 'A') 'B' else 'A'; // another document id
    try testing.expect(checkToken(&secret, &forged, 10) == null);
    try testing.expect(checkToken(&secret, "", 10) == null);
    try testing.expect(checkToken(&secret, "abc.def", 10) == null);
}

test "Collabora gets its editor address with the file's WOPI address and the token" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const s: Settings = .{ .kind = .collabora, .url = "http://127.0.0.1:9980", .public_url = "http://172.17.0.1:8080" };
    const u = try collaboraUrl(ar.allocator(), s, "00ff", "tok.en");
    try testing.expectEqualStrings("http://127.0.0.1:9980/browser/dist/cool.html?WOPISrc=http%3A%2F%2F172.17.0.1%3A8080%2Fwopi%2Ffiles%2F00ff&access_token=tok.en&permission=readonly", u);
}

test "OnlyOffice's page: the script is the only inline one allowed, file names cannot break out, and a JWT is added when asked" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var s: Settings = .{ .kind = .onlyoffice, .url = "http://127.0.0.1:8090", .public_url = "http://172.17.0.1:8080" };
    const cfg = try onlyofficeConfig(a, s, "00112233445566778899aabbccddeeff", "T.T", "</script><b>x</b>.docx", formatOf("x.docx").?, "1700000000");
    try testing.expect(std.mem.indexOf(u8, cfg, "\"mode\":\"view\"") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "\"edit\":false") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "/wopi/files/00112233445566778899aabbccddeeff/contents?access_token=T.T") != null);
    const page = try onlyofficePage(a, s, cfg, "</title><script>");
    try testing.expect(std.mem.indexOf(u8, page.html, "</script><b>") == null);
    try testing.expect(std.mem.indexOf(u8, page.html, "<script>alert") == null);
    try testing.expect(std.mem.indexOf(u8, page.html, "&lt;/title&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, page.csp, "script-src http://127.0.0.1:8090 'sha256-") != null);
    try testing.expect(std.mem.indexOf(u8, page.html, "\"token\"") == null);
    s.jwt_secret = "secret";
    const signed = try onlyofficePage(a, s, cfg, "t");
    try testing.expect(std.mem.indexOf(u8, signed.html, ",\"token\":\"ey") != null);
    // The JWT is three base64url parts that verify with the secret.
    const j = try jwt(a, "secret", "{\"a\":1}");
    var parts = std.mem.splitScalar(u8, j, '.');
    _ = parts.next();
    _ = parts.next();
    try testing.expect(parts.next() != null);
    try testing.expectEqualStrings("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhIjoxfQ.", j[0 .. j.len - 43]);
}
