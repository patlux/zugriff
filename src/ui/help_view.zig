//! The help inside the palette (design `design/figcraft/zugriff-hilfe.figcraft`:
//! H1 with the states Z1, Z3 and Z4, the search row of H2 and the hints of
//! H6).
//!
//! `?` as the whole query lists what Zugriff understands, one topic per
//! row with an example; `↵` puts the example into the search field, so the
//! palette shows at once what it does. `help` and `hilfe` are search words
//! in both languages ("help" finds Tips): they only bring up a "Hilfe" or
//! "Help" row above the apps. The topics are constant data in `texts.zig`;
//! nothing is loaded for them.
const std = @import("std");
const build_options = @import("build_options");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("../core.zig");
const theme = @import("theme.zig");
const texts = @import("texts.zig");
const palette = @import("palette.zig");
const Palette = palette.Palette;
const Language = core.Language;

/// The query that opens the help.
pub const query = "?";
/// The glyph of the Emoji topic, the same as on the "Emoji" search row.
const emoji_glyph = "😀";

pub const Topic = struct {
    /// The letter or symbol on the tile; `emoji_glyph` draws in colour.
    glyph: []const u8,
    title: []const u8,
    subtitle: []const u8,
    /// Shown at the end of the row.
    example: []const u8,
    /// Whether `↵` puts `example` into the search field. The keys topic
    /// shows key combinations, not a query.
    tryable: bool = true,
};

pub const topic_count = texts.help_topic_count;

/// The tile of each topic, in the order of `Texts.help_topics`.
const glyphs = [topic_count][]const u8{ "A", "/", "↗", "=", "≡", emoji_glyph, "⌘" };
/// The last topic, the keys, shows key combinations instead of a query.
const keys_topic = topic_count - 1;
/// The calculator's topic: its example follows the notation of the numbers.
const calc_topic = 3;

/// Topic `i` in the texts of `lang`, its example in the notation of `numbers`.
pub fn topic(lang: Language, numbers: Language, i: usize) Topic {
    const t = texts.of(lang).help_topics[i];
    return .{
        .glyph = glyphs[i],
        .title = t.title,
        .subtitle = t.subtitle,
        .example = if (i == calc_topic) texts.of(numbers).help_topics[i].example else t.example,
        .tryable = i != keys_topic,
    };
}

/// Every topic, as `topic` gives them.
pub fn topics(lang: Language, numbers: Language) [topic_count]Topic {
    var out: [topic_count]Topic = undefined;
    for (&out, 0..) |*t, i| t.* = topic(lang, numbers, i);
    return out;
}

/// The search row that `help` and `hilfe` bring up (H2).
pub fn command(lang: Language) core.Item {
    const t = texts.of(lang);
    return .{ .title = t.help_title, .subtitle = t.help_row_subtitle, .action = .open_help };
}

pub const State = struct {
    /// The help is on screen: the query is `?`.
    showing: bool = false,
    /// The example `↵` put into the search field, until the query changes;
    /// the footer then names where the query came from (Z1).
    example: ?[]const u8 = null,
    /// Whether the help was ever opened: the footer tip (H6) shows until
    /// then. Null until the agent read it in the background.
    seen: ?bool = null,
};

/// Whether `raw` opens the help: `?` alone, spaces around it aside. A `?`
/// later in the query (`12 * 4?`) is the calculator's, `:?` the emoji
/// picker's.
pub fn opens(raw: []const u8) bool {
    return std.mem.eql(u8, core.text.trim(raw), query);
}

/// Whether `raw` is one of the words that bring up the "Hilfe" row: the
/// whole query, in any case.
pub fn isHelpWord(raw: []const u8) bool {
    const t = core.text.trim(raw);
    return std.ascii.eqlIgnoreCase(t, "help") or std.ascii.eqlIgnoreCase(t, "hilfe");
}

/// Called by `Palette.refresh` before anything else: the example from the
/// help stays named only while it is the query.
pub fn forgetExample(p: *Palette, raw: []const u8) void {
    const e = p.help.example orelse return;
    if (!std.mem.eql(u8, e, raw)) p.help.example = null;
}

/// Shows the topics. The first time ever, the agent hears that the tip is
/// no longer needed.
pub fn show(p: *Palette) void {
    p.help.showing = true;
    p.selected = 0;
    if (p.help.seen != true) {
        p.help.seen = true;
        p.emit(.help_seen);
    }
}

/// `↵` on the "Hilfe" search row or a click on the hint: the field becomes `?`.
pub fn open(p: *Palette) !void {
    try p.setQuery(query);
}

/// Whether the agent's stored answer still shows the tip.
pub fn setSeen(p: *Palette, seen: bool) void {
    if (p.help.seen == true) return;
    p.help.seen = seen;
}

pub fn rowCount() usize {
    return topic_count;
}

/// `↵` on a topic: its example goes into the search field.
pub fn confirm(p: *Palette) !void {
    const t = topic(p.lang, p.numbers, @min(p.selected, topic_count - 1));
    if (!t.tryable) return p.beep();
    try p.setQuery(t.example);
    p.help.example = t.example;
}

fn activate(p: *Palette, index: usize) !void {
    p.selected = index;
    try confirm(p);
}

pub fn body(p: *Palette, c: *ui.Context) !void {
    const list = ui.div(c).column().wFull();
    defer list.end();
    for (0..topic_count) |i| try topicRow(p, c, topic(p.lang, p.numbers, i), i);
}

fn topicRow(p: *Palette, c: *ui.Context, t: Topic, index: usize) !void {
    const selected = p.selected == index;
    const row = ui.div(c).row().wFull().h(theme.row_height).px(16).gap(12).itemsCenter().control();
    defer row.end();
    if (selected) _ = row.bg(theme.selection) else _ = row.hover(theme.surface);
    if (row.clicked()) try activate(p, index);
    if (std.mem.eql(u8, t.glyph, emoji_glyph))
        palette.commandTile(p, c, t.glyph)
    else
        symbolTile(c, t.glyph, false);
    {
        const col = ui.div(c).column().grow().minW(0).gap(1);
        defer col.end();
        ui.text(c, t.title, .{ .size = 14.5, .line_height = 18, .color = theme.text, .truncate = .ellipsis });
        ui.text(c, t.subtitle, .{ .size = 11, .line_height = 14, .color = theme.muted, .truncate = .ellipsis });
    }
    ui.text(c, t.example, .{ .size = 12, .line_height = 16, .color = theme.muted });
    if (selected) palette.selectionBar(c, 16, 11);
}

/// A letter or symbol on a row tile; `accent` for the "Hilfe" row.
pub fn symbolTile(c: *ui.Context, glyph: []const u8, accent: bool) void {
    const tile = ui.div(c).size(theme.row_icon_size, theme.row_icon_size).rounded(7)
        .bg(if (accent) theme.selection_overlay else theme.surface).center();
    defer tile.end();
    ui.text(c, glyph, .{
        .size = if (accent) 14 else 13,
        .weight = if (accent) .bold else .semibold,
        .color = if (accent) theme.accent else theme.text,
    });
}

/// The footer's label, drawn here, and its hints.
pub fn footer(p: *Palette, c: *ui.Context, buf: *[6][]const u8) []const []const u8 {
    const t = texts.of(p.lang);
    ui.text(c, footerLabel(p.lang), .{ .size = 11, .color = theme.muted, .truncate = .ellipsis });
    buf[0] = t.hint_navigate;
    if (!topic(p.lang, p.numbers, @min(p.selected, topic_count - 1)).tryable) {
        buf[1] = t.hint_close;
        return buf[0..2];
    }
    buf[1] = t.hint_try;
    buf[2] = t.hint_close;
    return buf[0..3];
}

/// The topics and the version of the running binary.
pub fn footerLabel(lang: Language) []const u8 {
    return switch (lang) {
        inline else => |l| std.fmt.comptimePrint(
            texts.comptimeOf(l).help_footer,
            .{ topic_count, build_options.version },
        ),
    };
}

/// What the footer adds to its label while the query is an example from
/// the help (Z1).
pub fn origin(p: *const Palette) ?[]const u8 {
    return if (p.help.example != null) texts.of(p.lang).help_origin else null;
}

/// Whether the header shows the quiet `? Hilfe` (H6): only over the empty
/// app search.
pub fn showsHint(p: *const Palette) bool {
    return p.text().len == 0 and p.block == null and !p.emoji.active();
}

/// `? Hilfe` at the right of the header; a click opens the help.
pub fn hint(p: *Palette, c: *ui.Context) !void {
    const box = ui.div(c).row().gap(6).itemsCenter().control();
    defer box.end();
    if (box.clicked()) try open(p);
    {
        const key = ui.div(c).px(6).py(1).rounded(5).bg(theme.surface).border(theme.border).borderW(1);
        defer key.end();
        ui.text(c, query, .{ .size = 11, .line_height = 16, .weight = .medium, .color = theme.muted });
    }
    ui.text(c, texts.of(p.lang).help_title, .{ .size = 11, .line_height = 16, .color = theme.placeholder });
}

/// The footer tip of the empty app search, until the help was opened once (H6).
pub fn tip(p: *const Palette) ?[]const u8 {
    if (p.help.seen != false) return null;
    if (core.text.trim(p.text()).len != 0 or p.direct != null) return null;
    return texts.of(p.lang).help_tip;
}

test "only a lone question mark opens the help" {
    try std.testing.expect(opens("?"));
    try std.testing.expect(opens(" ? "));
    try std.testing.expect(!opens("12 * 4?"));
    try std.testing.expect(!opens(":?"));
    try std.testing.expect(!opens("??"));
}

test "help and hilfe are whole words in any case" {
    for ([_][]const u8{ "help", "Hilfe", "HELP", " hilfe " }) |w| try std.testing.expect(isHelpWord(w));
    for ([_][]const u8{ "hi", "helper", "hilfen", "help me" }) |w| try std.testing.expect(!isHelpWord(w));
}
