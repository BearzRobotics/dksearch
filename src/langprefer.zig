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

const Latin = enum(u4) { en, fr, de, es, it, pt, nl, sv, da, pl, tr, id, cs, fi };

/// The commonest words of each language that are not also the commonest of another (a few are shared: the words of a text
/// are counted against every list). Lower case; a text is read as running words, so single letters are included where a
/// language has them.
const stopword_lists = [_]struct { Latin, []const u8 }{
    .{ .en, "the of and to in is that for it with as was on are this be by at or from have not you we they which an can but all will has their there been more when who one if also its about into than what your said do were so out up other time these may such only most over new would some them could first any use after our then like many just now how" },
    .{ .fr, "le la les des du de un une et est en pour dans que qui pas sur au aux avec ce cette ces sont nous vous il elle ils ne plus par ou se son sa ses leur être avoir fait comme mais tout aussi très entre sans sous cet où dont ainsi été peut ont" },
    .{ .de, "der die das und ist nicht ein eine zu von mit den dem auf für sich auch es wir sie im bei wird oder aus nach als wie werden sind einen einer eines dass kann nur noch dieser diese über zum zur durch haben hat wenn aber ich du er" },
    .{ .es, "el la los las de que y en un una es por con para no se del al su como más pero este esta estos son fue sus también entre sobre ser tiene han muy sin hay donde cuando todo porque" },
    .{ .it, "il lo la le gli di che e è un una per con non sono del della nel nella dei delle anche come più ma questo questa essere stato hanno tra fra dal alla sul loro quando tutti ogni molto" },
    .{ .pt, "o a os as de que e é um uma para com não em do da dos das no na por mais se mas como foi são também seu sua pelo pela entre sobre muito ainda quando todos" },
    .{ .nl, "de het een en van is dat op te in niet voor met zijn ook aan er maar om dit als bij naar door meer worden wordt heeft kan uit nog wel dan hun deze over" },
    .{ .sv, "och att det som en är på av för med den har inte ett till om de vi från kan eller ska vara blir också mycket alla sig" },
    .{ .da, "og i det at en er som på af for med til ikke den har de et var vi fra kan eller skal være også meget alle sig" },
    .{ .pl, "nie się w na i z do że to jest jak ale po co dla przez od tak być który która które może został tylko już oraz jego jej ich ten ta te" },
    .{ .tr, "ve bir bu için ile da de çok gibi daha olarak en ne var ama kadar sonra olan her şey ise" },
    .{ .id, "yang dan di ini itu dengan untuk dari pada tidak adalah akan atau dalam juga oleh kita saya ke karena sebagai" },
    .{ .cs, "a je se na že to v s z do nebo jako pro které který byl být jsou má jeho její ale také tak" },
    .{ .fi, "ja on ei että se oli mutta kun kuin joka tai vain myös ovat sen sekä" },
};

/// word -> the languages whose list has it (a bit each).
const word_masks = blk: {
    @setEvalBranchQuota(2_000_000);
    var entries: [stopword_lists.len * 80]struct { []const u8, u16 } = undefined;
    var n: usize = 0;
    for (stopword_lists) |sl| {
        var it = std.mem.tokenizeScalar(u8, sl[1], ' ');
        while (it.next()) |w| {
            const bit: u16 = 1 << @backingInt(sl[0]);
            var found = false;
            for (entries[0..n]) |*e| if (std.mem.eql(u8, e[0], w)) {
                e[1] |= bit;
                found = true;
            };
            if (!found) {
                entries[n] = .{ w, bit };
                n += 1;
            }
        }
    }
    break :blk std.StaticStringMap(u16).initComptime(entries[0..n].*);
};

/// The language of a running text of Latin letters, from how many of its words are the commonest words of each language
/// (`en`, `fr`, `de`, `es`, `it`, `pt`, `nl`, `sv`, `da`, `pl`, `tr`, `id`, `cs`, `fi`). Conservative: null unless the text
/// has at least 30 words, the best language has at least 15% of them and clearly more than the second.
pub fn guessLatin(text: []const u8) ?[]const u8 {
    var hits: [stopword_lists.len]u32 = @splat(0);
    var tokens: u32 = 0;
    const sample = text[0..@min(text.len, 4000)];
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var too_long = false;
    var i: usize = 0;
    while (i <= sample.len) : (i += 1) {
        const c: u8 = if (i < sample.len) sample[i] else ' ';
        if (std.ascii.isAlphabetic(c) or c >= 0x80) {
            if (len < buf.len) {
                buf[len] = std.ascii.toLower(c);
                len += 1;
            } else too_long = true;
        } else if (len > 0) {
            tokens += 1;
            if (!too_long) if (word_masks.get(buf[0..len])) |mask| {
                for (&hits, 0..) |*h, k| if (mask & (@as(u16, 1) << @intCast(k)) != 0) {
                    h.* += 1;
                };
            };
            len = 0;
            too_long = false;
        }
    }
    if (tokens < 30) return null;
    var best: usize = 0;
    for (hits, 0..) |h, k| if (h > hits[best]) {
        best = k;
    };
    var second: u32 = 0;
    for (hits, 0..) |h, k| if (k != best and h > second) {
        second = h;
    };
    if (hits[best] * 100 < tokens * 15) return null;
    if (hits[best] * 10 < second * 14) return null;
    return @tagName(@as(Latin, @fromBackingInt(@intCast(best))));
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
    if (best_count * 100 < total * 40) return latinOtherThanEnglish(text);
    return switch (best) {
        .han, .kana => if (counts[@backingInt(Script.kana)] * 10 >= counts[@backingInt(Script.han)]) "ja" else "zh",
        .hangul => "ko",
        .cyrillic => "und-Cyrl",
        .arabic => "und-Arab",
        .hebrew => "he",
        .greek => "el",
        .thai => "th",
        .devanagari => "und-Deva",
        .latin => latinOtherThanEnglish(text),
    };
}

/// A language other than English found by `guessLatin`; English is not stated (a page with no language is read as English).
fn latinOtherThanEnglish(text: []const u8) ?[]const u8 {
    const g = guessLatin(text) orelse return null;
    return if (std.mem.eql(u8, g, "en")) null else g;
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

test "Latin-script texts: the language is found from the commonest words, and English is not stated" {
    const fr = "Le système d'exploitation est un logiciel qui permet de gérer les ressources de l'ordinateur et de faire fonctionner les programmes que nous utilisons tous les jours pour travailler dans de bonnes conditions avec une grande rapidité.";
    const de = "Das Betriebssystem ist ein Programm, das die Hardware eines Computers verwaltet und es den Anwendungen ermöglicht, die wir jeden Tag nutzen, mit dem Rechner zu arbeiten, ohne dass wir uns um die Details kümmern müssen.";
    const es = "El sistema operativo es un programa que gestiona los recursos del ordenador y permite que las aplicaciones que usamos todos los días funcionen con una gran rapidez y sin que tengamos que preocuparnos por los detalles del equipo.";
    const nl = "Het besturingssysteem is een programma dat de hardware van een computer beheert en het mogelijk maakt dat de toepassingen die we elke dag gebruiken met het apparaat kunnen werken zonder dat we ons om de details hoeven te bekommeren.";
    const en = "The operating system is a program that manages the resources of the computer and makes it possible for the applications that we use every day to work with the machine without having to worry about the details of the hardware.";
    try testing.expectEqualStrings("fr", guessLatin(fr).?);
    try testing.expectEqualStrings("de", guessLatin(de).?);
    try testing.expectEqualStrings("es", guessLatin(es).?);
    try testing.expectEqualStrings("nl", guessLatin(nl).?);
    try testing.expectEqualStrings("en", guessLatin(en).?);
    // languageOfText states the others and leaves English unsaid.
    try testing.expectEqualStrings("fr", languageOfText(fr).?);
    try testing.expect(languageOfText(en) == null);
    // Too short, no words of any list, or code: nothing is guessed.
    try testing.expect(guessLatin("Bonjour le monde") == null and guessLatin("") == null);
    try testing.expect(guessLatin("int main(void) { return printf(\"%d\", x1 + y2 * z3); } struct foo bar baz qux quux corge grault garply waldo fred plugh xyzzy thud") == null);
}
