//! Emoji for the picker: the compiled-in table, the search over German and
//! English names, keywords and shortcodes, and the remembered preferences.
//!
//! The table comes from `scripts/emoji_data.py` and is static data in the
//! binary. Nothing is read, parsed or downloaded at run time, so the picker
//! has its emoji the moment the palette opens.
const std = @import("std");
const text = @import("text.zig");
const data = @import("emoji_data.zig");

/// Recently used emoji the preferences keep; two rows of the grid.
pub const recent_limit = 24;

/// The Unicode emoji groups, in the order the grid shows them.
pub const Group = enum {
    smileys,
    people,
    animals,
    food,
    travel,
    activities,
    objects,
    symbols,
    flags,

    pub const all = [_]Group{ .smileys, .people, .animals, .food, .travel, .activities, .objects, .symbols, .flags };

    pub fn title(g: Group) []const u8 {
        return switch (g) {
            .smileys => "Smileys & Gefühle",
            .people => "Menschen & Körper",
            .animals => "Tiere & Natur",
            .food => "Essen & Trinken",
            .travel => "Reisen & Orte",
            .activities => "Aktivitäten",
            .objects => "Objekte",
            .symbols => "Symbole",
            .flags => "Flaggen",
        };
    }

    /// The emoji that stands for the group in the category bar.
    pub fn icon(g: Group) []const u8 {
        return switch (g) {
            .smileys => "😀",
            .people => "👋",
            .animals => "🐻",
            .food => "🍔",
            .travel => "🚗",
            .activities => "⚽",
            .objects => "💡",
            .symbols => "❤️",
            .flags => "🏳️",
        };
    }
};

/// A skin tone: the default yellow or one of the five Fitzpatrick modifiers.
pub const Tone = enum(u8) {
    default,
    light,
    medium_light,
    medium,
    medium_dark,
    dark,

    pub const count = 6;

    pub fn index(t: Tone) usize {
        return @backingInt(t);
    }

    pub fn fromIndex(i: usize) ?Tone {
        if (i >= count) return null;
        return @fromBackingInt(@intCast(i));
    }
};

/// One emoji of the table.
pub const Emoji = struct {
    /// The fully-qualified sequence that gets inserted.
    glyph: []const u8,
    group: Group,
    /// German CLDR name, for example `Gesicht mit Freudentränen`.
    name: []const u8,
    /// The name lowercased and without umlauts, for searching.
    folded: []const u8,
    /// German keywords, folded like `folded`, separated by `|`.
    keywords: []const u8,
    /// English name, then English keywords, folded, separated by `|`.
    english: []const u8,
    /// gemoji shortcodes without colons, separated by `|`.
    codes: []const u8,
    /// The five skin-toned variants, light to dark.
    tones: ?[5][]const u8,

    /// Shortcodes such as `joy` for `:joy:`.
    pub fn shortcodes(e: Emoji) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, e.codes, '|');
    }

    pub fn hasTones(e: Emoji) bool {
        return e.tones != null;
    }

    /// The glyph in `tone`; emoji without skin tones ignore it.
    pub fn withTone(e: Emoji, tone: Tone) []const u8 {
        if (e.tones) |t| if (tone != .default) return t[tone.index() - 1];
        return e.glyph;
    }
};

/// Every emoji, in Unicode order (grouped like `Group.all`).
pub const all: []const Emoji = &data.table;

/// The table entry for `glyph` and the tone it carries. Recently used emoji
/// are stored as the glyph that was inserted, so a skin-toned variant maps
/// back to its base emoji here.
pub fn find(glyph: []const u8) ?struct { index: usize, tone: Tone } {
    for (all, 0..) |e, i| {
        if (std.mem.eql(u8, e.glyph, glyph)) return .{ .index = i, .tone = .default };
        if (e.tones) |tones| for (tones, 0..) |variant, t| {
            if (std.mem.eql(u8, variant, glyph)) return .{ .index = i, .tone = Tone.fromIndex(t + 1).? };
        };
    }
    return null;
}

// Scores of one query token against one emoji; the best field wins.
const name_exact: u32 = 1000;
/// A typed shortcode is deliberate: `:joy:` means 😂, not the joystick.
const code_exact: u32 = 900;
/// The name starts with the token as a whole word: `herz` in `Herz mit Pfeil`.
const name_first_word: u32 = 850;
/// Another word of the name is the token: `herz` in `rotes Herz`.
const name_word_exact: u32 = 800;
/// Whole words beat word starts: `lachen` is a keyword of 😂 and only the
/// start of `lachendes` in 🥲's name.
const keyword_exact: u32 = 700;
const name_prefix: u32 = 650;
const name_word: u32 = 550;
const keyword_prefix: u32 = 500;
const code_prefix: u32 = 450;
const keyword_word: u32 = 400;
const english_exact: u32 = 350;
const english_prefix: u32 = 300;
const english_word: u32 = 250;
const name_infix: u32 = 100;
/// Shorter tokens find too much inside words.
const infix_min_chars = 3;

const word_separators = " -_:,";

/// Searches the table; indices into `all`, best first. The caller frees.
///
/// Every whitespace-separated token has to match a German name or keyword,
/// a shortcode, or an English name or keyword. Colons around the query
/// (`:joy:`) are ignored. Ties go to the more recently used emoji (`recent`,
/// glyphs most recent first), then to Unicode order. An empty query returns
/// nothing: the grid shows the groups instead.
pub fn search(gpa: std.mem.Allocator, query: []const u8, recent: []const []const u8) ![]usize {
    var tokens: std.ArrayList([]u8) = .empty;
    defer {
        for (tokens.items) |t| gpa.free(t);
        tokens.deinit(gpa);
    }
    var words = text.words(query);
    while (words.next()) |word| {
        const folded = try text.foldAlloc(gpa, std.mem.trim(u8, word, ":"));
        if (folded.len == 0) {
            gpa.free(folded);
            continue;
        }
        try tokens.append(gpa, folded);
    }
    if (tokens.items.len == 0) return gpa.alloc(usize, 0);

    const Hit = struct { index: usize, score: u32, recency: usize };
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);
    for (all, 0..) |e, i| {
        var total: u32 = 0;
        const matched = for (tokens.items) |t| {
            total += score(e, t) orelse break false;
        } else true;
        if (matched) try hits.append(gpa, .{ .index = i, .score = total, .recency = recency(e, recent) });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            if (a.recency != b.recency) return a.recency < b.recency;
            return a.index < b.index;
        }
    }.lt);
    const out = try gpa.alloc(usize, hits.items.len);
    for (hits.items, out) |h, *o| o.* = h.index;
    return out;
}

fn recency(e: Emoji, recent: []const []const u8) usize {
    for (recent, 0..) |glyph, i| {
        if (std.mem.eql(u8, glyph, e.glyph)) return i;
        if (e.tones) |tones| for (tones) |v| if (std.mem.eql(u8, v, glyph)) return i;
    }
    return std.math.maxInt(usize);
}

fn score(e: Emoji, token: []const u8) ?u32 {
    var best: ?u32 = null;
    const offer = struct {
        fn f(b: *?u32, s: u32) void {
            b.* = if (b.*) |x| @max(x, s) else s;
        }
    }.f;

    var name_words = std.mem.splitAny(u8, e.folded, word_separators);
    const first = name_words.first();
    if (std.mem.eql(u8, e.folded, token)) {
        offer(&best, name_exact);
    } else if (std.mem.eql(u8, first, token)) {
        offer(&best, name_first_word);
    } else if (anyWord(e.folded, token, .exact)) {
        offer(&best, name_word_exact);
    } else if (std.mem.startsWith(u8, e.folded, token)) {
        offer(&best, name_prefix);
    } else if (anyWord(e.folded, token, .prefix)) {
        offer(&best, name_word);
    } else if (text.countCodepoints(token) >= infix_min_chars and std.mem.find(u8, e.folded, token) != null) {
        offer(&best, name_infix);
    }

    var keywords = std.mem.tokenizeScalar(u8, e.keywords, '|');
    while (keywords.next()) |k| {
        if (std.mem.eql(u8, k, token)) {
            offer(&best, keyword_exact);
        } else if (std.mem.startsWith(u8, k, token)) {
            offer(&best, keyword_prefix);
        } else if (wordStartsWith(k, token)) {
            offer(&best, keyword_word);
        }
    }

    var codes = e.shortcodes();
    while (codes.next()) |code| {
        if (std.mem.eql(u8, code, token)) {
            offer(&best, code_exact);
        } else if (std.mem.startsWith(u8, code, token) or wordStartsWith(code, token)) {
            offer(&best, code_prefix);
        }
    }

    var english = std.mem.tokenizeScalar(u8, e.english, '|');
    while (english.next()) |en| {
        if (std.mem.eql(u8, en, token)) {
            offer(&best, english_exact);
        } else if (std.mem.startsWith(u8, en, token)) {
            offer(&best, english_prefix);
        } else if (wordStartsWith(en, token)) {
            offer(&best, english_word);
        }
    }
    return best;
}

/// Whether a word of `s` (any, the first included) is or starts with `token`.
fn anyWord(s: []const u8, token: []const u8, how: enum { exact, prefix }) bool {
    var it = std.mem.splitAny(u8, s, word_separators);
    while (it.next()) |w| switch (how) {
        .exact => if (std.mem.eql(u8, w, token)) return true,
        .prefix => if (std.mem.startsWith(u8, w, token)) return true,
    };
    return false;
}

/// Whether a word inside `s` (after a space, `-`, `_`, `:` or `,`) starts
/// with `token`.
fn wordStartsWith(s: []const u8, token: []const u8) bool {
    var it = std.mem.splitAny(u8, s, word_separators);
    _ = it.first();
    while (it.next()) |w| if (std.mem.startsWith(u8, w, token)) return true;
    return false;
}

/// What the picker remembers between runs: the skin tone and the recently
/// used emoji. Nothing else, in particular no text from other apps.
pub const Prefs = struct {
    tone: Tone = .default,
    /// Inserted or copied glyphs, most recent first. They point into the
    /// static table, so a `Prefs` owns no memory.
    recent: [recent_limit][]const u8 = undefined,
    recent_len: usize = 0,

    pub fn recentSlice(p: *const Prefs) []const []const u8 {
        return p.recent[0..p.recent_len];
    }

    /// Reads the text form written by `write`. Unknown lines and glyphs
    /// that are not in the table are skipped, so an older or damaged file
    /// never fails the picker.
    pub fn parse(s: []const u8) Prefs {
        var p: Prefs = .{};
        var lines = std.mem.splitScalar(u8, s, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "tone=")) {
                const n = std.fmt.parseInt(usize, line[5..], 10) catch 0;
                p.tone = Tone.fromIndex(n) orelse .default;
            } else if (std.mem.startsWith(u8, line, "recent=")) {
                const glyph = staticGlyph(line[7..]) orelse continue;
                if (p.contains(glyph) or p.recent_len >= recent_limit) continue;
                p.recent[p.recent_len] = glyph;
                p.recent_len += 1;
            }
        }
        return p;
    }

    pub fn write(p: *const Prefs, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("tone={d}\n", .{p.tone.index()});
        for (p.recentSlice()) |glyph| try w.print("recent={s}\n", .{glyph});
    }

    fn contains(p: *const Prefs, glyph: []const u8) bool {
        for (p.recentSlice()) |g| if (std.mem.eql(u8, g, glyph)) return true;
        return false;
    }

    /// Moves `glyph` to the front of the recently used emoji. Glyphs that
    /// are not in the table are ignored.
    pub fn record(p: *Prefs, glyph_in: []const u8) void {
        const glyph = staticGlyph(glyph_in) orelse return;
        var kept: usize = 0;
        for (p.recentSlice()) |g| {
            if (std.mem.eql(u8, g, glyph)) continue;
            p.recent[kept] = g;
            kept += 1;
        }
        const len = @min(kept, recent_limit - 1);
        @memmove(p.recent[1 .. len + 1], p.recent[0..len]);
        p.recent[0] = glyph;
        p.recent_len = len + 1;
    }

    pub fn eql(a: *const Prefs, b: *const Prefs) bool {
        if (a.tone != b.tone or a.recent_len != b.recent_len) return false;
        for (a.recentSlice(), b.recentSlice()) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }
};

/// The table's own copy of `glyph`, so it outlives the text it came from.
fn staticGlyph(glyph: []const u8) ?[]const u8 {
    const f = find(glyph) orelse return null;
    return all[f.index].withTone(f.tone);
}

const testing = std.testing;

fn glyphs(query: []const u8) ![]const []const u8 {
    const hits = try search(testing.allocator, query, &.{});
    defer testing.allocator.free(hits);
    const out = try testing.allocator.alloc([]const u8, hits.len);
    for (hits, out) |h, *o| o.* = all[h].glyph;
    return out;
}

fn position(list: []const []const u8, glyph: []const u8) ?usize {
    for (list, 0..) |g, i| if (std.mem.eql(u8, g, glyph)) return i;
    return null;
}

test "the table is complete and grouped in order" {
    try testing.expect(all.len > 1800);
    var last: usize = 0;
    for (all) |e| {
        const p = @backingInt(e.group);
        try testing.expect(p >= last);
        last = p;
        try testing.expect(e.name.len > 0);
    }
    for (Group.all) |g| {
        const found = for (all) |e| {
            if (e.group == g) break true;
        } else false;
        try testing.expect(found);
    }
}

test "German names and keywords find emoji" {
    const a = try glyphs("daumen hoch");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("👍", a[0]);
    const b = try glyphs("lachen");
    defer testing.allocator.free(b);
    try testing.expect(position(b, "😂") != null);
    const c = try glyphs("rotes herz");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("❤️", c[0]);
    const d = try glyphs("konfetti");
    defer testing.allocator.free(d);
    try testing.expect(position(d, "🎉") != null);
}

test "umlauts are optional" {
    const a = try glyphs("freudentranen");
    defer testing.allocator.free(a);
    const b = try glyphs("Freudentränen");
    defer testing.allocator.free(b);
    try testing.expect(position(a, "😂") != null);
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expectEqualStrings(x, y);
}

test "shortcodes and English names work too" {
    const a = try glyphs(":joy:");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("😂", a[0]);
    const b = try glyphs(":thumbsup");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("👍", b[0]);
    const c = try glyphs("thumbs");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("👍", c[0]);
    try testing.expectEqualStrings("👎", c[1]);
    const d = try glyphs("party");
    defer testing.allocator.free(d);
    try testing.expect(position(d, "🎉") != null);
}

test "names beat keywords and whole words beat word starts" {
    const hearts = try glyphs("herz");
    defer testing.allocator.free(hearts);
    try testing.expect(position(hearts, "❤️").? < position(hearts, "😍").?);
    try testing.expectEqualStrings("♥️", hearts[0]);
    try testing.expect(position(hearts[0..12], "❤️") != null);
    const laughing = try glyphs("lachen");
    defer testing.allocator.free(laughing);
    try testing.expect(position(laughing, "😂").? < position(laughing, "🥲").?);
}

test "every token has to match; short tokens stay out of words" {
    const a = try glyphs("daumen runter");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("👎", a[0]);
    for ([_][]const u8{ "daumen xylofon", "xylofon", "   " }) |q| {
        const none = try glyphs(q);
        defer testing.allocator.free(none);
        try testing.expectEqual(@as(usize, 0), none.len);
    }
    const ra = try glyphs("ra");
    defer testing.allocator.free(ra);
    try testing.expect(position(ra, "😂") == null);
}

test "recently used emoji win ties" {
    const plain = try glyphs("daumen");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("👍", plain[0]);
    try testing.expectEqualStrings("👎", plain[1]);
    const recent = try search(testing.allocator, "daumen", &.{"👎🏽"});
    defer testing.allocator.free(recent);
    try testing.expectEqualStrings("👎", all[recent[0]].glyph);
}

test "skin tones map both ways" {
    const f = find("👍🏽").?;
    try testing.expectEqualStrings("👍", all[f.index].glyph);
    try testing.expectEqual(Tone.medium, f.tone);
    try testing.expectEqualStrings("👍🏽", all[f.index].withTone(.medium));
    try testing.expectEqualStrings("👍", all[f.index].withTone(.default));
    const heart = find("❤️").?;
    try testing.expect(!all[heart.index].hasTones());
    try testing.expectEqualStrings("❤️", all[heart.index].withTone(.dark));
}

test "prefs round-trip and skip garbage" {
    var p: Prefs = .{ .tone = .medium_dark };
    p.record("👍");
    p.record("😂");
    p.record("👍");
    try testing.expectEqual(@as(usize, 2), p.recent_len);
    try testing.expectEqualStrings("👍", p.recent[0]);
    try testing.expectEqualStrings("😂", p.recent[1]);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try p.write(&w);
    const back = Prefs.parse(w.buffered());
    try testing.expect(back.eql(&p));

    const damaged = Prefs.parse("tone=9\nrecent=kein emoji\nrecent=🎉\nunbekannt\n");
    try testing.expectEqual(Tone.default, damaged.tone);
    try testing.expectEqual(@as(usize, 1), damaged.recent_len);
    try testing.expectEqualStrings("🎉", damaged.recent[0]);
}

test "the recent list is bounded" {
    var p: Prefs = .{};
    for (all[0 .. recent_limit + 5]) |e| p.record(e.glyph);
    try testing.expectEqual(@as(usize, recent_limit), p.recent_len);
    try testing.expectEqualStrings(all[recent_limit + 4].glyph, p.recent[0]);
}
