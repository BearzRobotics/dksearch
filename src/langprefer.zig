//! Which language a person wants, and which pages are in another one (docs/decisions/0061). A site that has a page in
//! twenty languages would fill a results page with the same page in twenty languages, so pages in a language the browser
//! did not ask for (its `Accept-Language`) rank lower. They are not hidden: a page nobody translated stays, and a
//! person who reads Japanese says so in the browser.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The factor a page in another language has its score multiplied by.
pub const foreign_factor: f64 = 0.3;
pub const max_preferred = 5;

/// The primary language subtags of an `Accept-Language` header (`en-US,en;q=0.9,fr;q=0.5` -> `en`, `fr`), lower case,
/// two or three letters, in the order given, without repeats; `*` and a quality of 0 are left out. At most `max_preferred`.
pub fn parseAcceptLanguage(arena: Allocator, header: ?[]const u8) Allocator.Error![]const []const u8 {
    const h = header orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, h[0..@min(h.len, 400)], ',');
    while (parts.next()) |part_raw| {
        if (out.items.len >= max_preferred) break;
        var part = std.mem.trim(u8, part_raw, " \t");
        if (std.mem.indexOfScalar(u8, part, ';')) |semi| {
            const q = std.mem.trim(u8, part[semi + 1 ..], " \t");
            part = std.mem.trim(u8, part[0..semi], " \t");
            if (std.mem.startsWith(u8, q, "q=")) {
                const v = std.fmt.parseFloat(f64, q[2..]) catch 1.0;
                if (v <= 0) continue;
            }
        }
        const primary = part[0 .. std.mem.indexOfScalar(u8, part, '-') orelse part.len];
        if (primary.len < 2 or primary.len > 3) continue;
        var ok = true;
        for (primary) |ch| if (!std.ascii.isAlphabetic(ch)) {
            ok = false;
        };
        if (!ok) continue;
        const lower = try std.ascii.allocLowerString(arena, primary);
        var seen = false;
        for (out.items) |o| if (std.mem.eql(u8, o, lower)) {
            seen = true;
        };
        if (!seen) try out.append(arena, lower);
    }
    return out.items;
}

/// The list as written into a query (`en,fr`); null for none. Only letters and commas, so it is safe in SQL text.
pub fn csv(arena: Allocator, langs: []const []const u8) Allocator.Error!?[]const u8 {
    if (langs.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    for (langs, 0..) |l, i| {
        if (i > 0) try out.append(arena, ',');
        for (l) |ch| if (std.ascii.isAlphabetic(ch)) try out.append(arena, std.ascii.toLower(ch));
    }
    return out.items;
}

/// Languages a site puts first in the address of its translations (`/ja/docs`, `/zh-CN/`). Codes that are also common
/// words in an address (`it`, `is`, `no`, `id`, `he`, `to`...) are left out on purpose.
const path_languages = [_][]const u8{
    "ar", "bg", "bn", "ca", "cs", "da", "de", "el", "es", "et", "fa", "fi", "fr", "hi", "hr", "hu", "ja", "ko", "lt", "lv",
    "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sr", "sv", "th", "tr", "uk", "vi", "zh",
};

/// The language a path says by its first segment: `/ja/...` and `/zh-CN/...` say so; `/en/...` and `/en-US/...` say English.
/// Null when the first segment is not a language code.
pub fn languageOfPath(path: []const u8) ?[]const u8 {
    if (path.len < 3 or path[0] != '/') return null;
    const end = std.mem.indexOfAnyPos(u8, path, 1, "/?#") orelse path.len;
    const seg = path[1..end];
    const dash = std.mem.indexOfScalar(u8, seg, '-') orelse std.mem.indexOfScalar(u8, seg, '_');
    const primary = seg[0 .. dash orelse seg.len];
    if (dash) |d| {
        const region = seg[d + 1 ..];
        if (region.len < 2 or region.len > 4) return null;
        for (region) |ch| if (!std.ascii.isAlphabetic(ch)) return null;
    }
    if (primary.len != 2) return null;
    var lower: [2]u8 = undefined;
    for (primary, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
    if (std.mem.eql(u8, &lower, "en")) return "en";
    for (path_languages) |l| if (std.mem.eql(u8, l, &lower)) return l;
    return null;
}

/// Whether a page is in a language other than those preferred (`preferred` is `en,fr`): by the page's own language when it has
/// one, else by the first segment of its address. Unknown is not foreign. An empty list prefers nothing, so nothing is foreign.
pub fn foreign(language: ?[]const u8, path: ?[]const u8, preferred: []const u8) bool {
    if (preferred.len == 0) return false;
    var tag: ?[]const u8 = null;
    var buf: [3]u8 = undefined;
    if (language) |l| if (l.len >= 2) {
        const dash = std.mem.indexOfAny(u8, l, "-_") orelse l.len;
        if (dash >= 2 and dash <= 3) {
            for (l[0..dash], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
            tag = buf[0..dash];
        }
    };
    if (tag == null) if (path) |p| {
        tag = languageOfPath(p);
    };
    const t = tag orelse return false;
    var it = std.mem.splitScalar(u8, preferred, ',');
    while (it.next()) |want| if (std.mem.eql(u8, want, t)) return false;
    return true;
}

/// A guess at the language of a text from its script, for pages that do not say (no `lang`, no language in the address):
/// Chinese, Japanese (kana), Korean, Hebrew, Greek and Thai by name, and the scripts shared by several languages as
/// `und-Cyrl`, `und-Arab` and `und-Deva` ("undetermined, in this script"). Null when the text is mostly Latin letters, or
/// too short to tell: a Latin text could be any of dozens of languages and is left alone.
pub fn languageOfText(text: []const u8) ?[]const u8 {
    const Script = enum { latin, han, kana, hangul, cyrillic, arabic, hebrew, greek, thai, devanagari };
    var counts: [@backingInt(Script.devanagari) + 1]usize = @splat(0);
    const sample = text[0..@min(text.len, 6000)];
    var i: usize = 0;
    while (i < sample.len) {
        const b = sample[i];
        if (b < 0x80) {
            if (std.ascii.isAlphabetic(b)) counts[@backingInt(Script.latin)] += 1;
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            i += 1;
            continue;
        };
        if (i + n > sample.len) break;
        const cp = std.unicode.utf8Decode(sample[i .. i + n]) catch {
            i += 1;
            continue;
        };
        i += n;
        const script: ?Script = switch (cp) {
            0xC0...0x24F => .latin,
            0x4E00...0x9FFF, 0x3400...0x4DBF => .han,
            0x3040...0x30FF => .kana,
            0xAC00...0xD7AF, 0x1100...0x11FF => .hangul,
            0x0400...0x052F => .cyrillic,
            0x0600...0x06FF, 0x0750...0x077F => .arabic,
            0x0590...0x05FF => .hebrew,
            0x0370...0x03FF => .greek,
            0x0E00...0x0E7F => .thai,
            0x0900...0x097F => .devanagari,
            else => null,
        };
        if (script) |s| counts[@backingInt(s)] += 1;
    }
    var total: usize = 0;
    for (counts) |c| total += c;
    if (total < 20) return null;
    // Chinese and Japanese texts share the Han characters; kana says Japanese.
    const cjk = counts[@backingInt(Script.han)] + counts[@backingInt(Script.kana)];
    var best: Script = .latin;
    var best_count: usize = 0;
    for (counts, 0..) |c, k| {
        const s: Script = @fromBackingInt(@intCast(k));
        if (s == .latin) continue;
        const c_eff = if (s == .han or s == .kana) cjk else c;
        if (c_eff > best_count) {
            best_count = c_eff;
            best = s;
        }
    }
    if (best_count * 100 < total * 40) return null;
    return switch (best) {
        .han, .kana => if (counts[@backingInt(Script.kana)] * 10 >= counts[@backingInt(Script.han)]) "ja" else "zh",
        .hangul => "ko",
        .cyrillic => "und-Cyrl",
        .arabic => "und-Arab",
        .hebrew => "he",
        .greek => "el",
        .thai => "th",
        .devanagari => "und-Deva",
        .latin => null,
    };
}

const testing = std.testing;

test "Accept-Language gives the preferred primary languages in order" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const l = try parseAcceptLanguage(a, "en-US,en;q=0.9,fr;q=0.5,*;q=0.1,de;q=0,EN-gb");
    try testing.expectEqual(@as(usize, 2), l.len);
    try testing.expectEqualStrings("en", l[0]);
    try testing.expectEqualStrings("fr", l[1]);
    try testing.expectEqual(@as(usize, 0), (try parseAcceptLanguage(a, null)).len);
    try testing.expectEqual(@as(usize, 0), (try parseAcceptLanguage(a, "x, 12, toolonglanguage")).len);
    try testing.expectEqualStrings("en,fr", (try csv(a, l)).?);
    try testing.expect((try csv(a, &.{})) == null);
}

test "a path says its language by its first segment, and ordinary words are not languages" {
    try testing.expectEqualStrings("zh", languageOfPath("/zh-CN/docs/x").?);
    try testing.expectEqualStrings("ja", languageOfPath("/ja/").?);
    try testing.expectEqualStrings("pt", languageOfPath("/pt_BR/about").?);
    try testing.expectEqualStrings("en", languageOfPath("/en-US/docs").?);
    try testing.expect(languageOfPath("/it/news") == null and languageOfPath("/no/") == null and languageOfPath("/id/5") == null);
    try testing.expect(languageOfPath("/docs/ja/") == null and languageOfPath("/") == null and languageOfPath("/de-x/") == null);
    try testing.expect(languageOfPath("/blog") == null and languageOfPath("/zhx/") == null);
}

test "pages in another language than the preferred ones are foreign; unknown is not" {
    try testing.expect(foreign("zh-CN", null, "en"));
    try testing.expect(!foreign("en-GB", null, "en"));
    try testing.expect(!foreign("fr", "/ja/x", "en,fr")); // the page's own language wins over its address
    try testing.expect(foreign(null, "/ja/x", "en"));
    try testing.expect(!foreign(null, "/en/x", "en") and !foreign(null, "/docs/x", "en") and !foreign(null, null, "en"));
    try testing.expect(!foreign("ja", "/ja/", "")); // nothing preferred: nothing is foreign
}

test "the script of a text says its language when it is not Latin" {
    try testing.expectEqualStrings("zh", languageOfText("这是一个关于计算机操作系统和编程语言的页面，里面有很多文字内容可以阅读。").?);
    try testing.expectEqualStrings("ja", languageOfText("これはオペレーティングシステムとプログラミング言語についてのページです。たくさんの文章があります。").?);
    try testing.expectEqualStrings("ko", languageOfText("이것은 운영 체제와 프로그래밍 언어에 대한 페이지입니다. 읽을 수 있는 글이 많이 있습니다.").?);
    try testing.expectEqualStrings("und-Cyrl", languageOfText("Это страница об операционных системах и языках программирования, на ней много текста.").?);
    try testing.expectEqualStrings("und-Arab", languageOfText("هذه صفحة عن أنظمة التشغيل ولغات البرمجة وفيها الكثير من النصوص للقراءة.").?);
    // Latin text, a mostly Latin text with a few foreign words, and a text too short to tell are left alone.
    try testing.expect(languageOfText("This is a page about operating systems and programming languages, with plenty of text to read.") == null);
    try testing.expect(languageOfText("Un système d'exploitation, le noyau: ça évolue. 日本語 and русский appear once each in this long English-like text.") == null);
    try testing.expect(languageOfText("日本語") == null and languageOfText("") == null);
}
