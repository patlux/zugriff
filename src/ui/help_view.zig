//! The help inside the palette (design `design/figcraft/zugriff-hilfe.figcraft`:
//! H1 with the states Z1, Z3 and Z4, the search row of H2 and the hints of
//! H6).
//!
//! `?` as the whole query lists what Zugriff understands, one topic per
//! row with an example; `↵` puts the example into the search field, so the
//! palette shows at once what it does. `help` and `hilfe` are search words
//! too ("help" finds Tips): they only bring up a "Hilfe" row above the apps.
//! The topics are constant data; nothing is loaded for them.
const std = @import("std");
const build_options = @import("build_options");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("../core.zig");
const theme = @import("theme.zig");
const palette = @import("palette.zig");
const Palette = palette.Palette;

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

pub const topics = [_]Topic{
    .{
        .glyph = "A",
        .title = "Apps starten",
        .subtitle = "Namen oder Teil davon tippen · ↵ startet, ⌘↵ zeigt im Finder",
        .example = "saf",
    },
    .{
        .glyph = "/",
        .title = "Datei oder Ordner öffnen",
        .subtitle = "Pfad mit / oder ~/ am Anfang · ↵ öffnet",
        .example = "~/Downloads",
    },
    .{
        .glyph = "↗",
        .title = "Adresse öffnen",
        .subtitle = "http:// oder https:// · ↵ öffnet im Browser",
        .example = "https://ziglang.org",
    },
    .{
        .glyph = "=",
        .title = "Rechnen",
        .subtitle = "Aufgabe tippen oder einfügen · ↵ kopiert, ⌥↵ nur die Zahl",
        .example = "1.299 € + 19 %",
    },
    .{
        .glyph = "≡",
        .title = "Letzte Rechnungen",
        .subtitle = "= allein zeigt die Rechnungen dieser Sitzung",
        .example = "=",
    },
    .{
        .glyph = emoji_glyph,
        .title = "Emoji einfügen",
        .subtitle = ": am Anfang oder ⌃⌘Leertaste · ⇥ Hauttöne",
        .example = ":herz",
    },
    .{
        .glyph = "⌘",
        .title = "Tasten",
        .subtitle = "↑↓ wählen, ↵ ausführen, esc schließt",
        .example = "⌘↵ ⌥↵ ⇧↵",
        .tryable = false,
    },
};

/// The search row that `help` and `hilfe` bring up (H2).
pub const command: core.Item = .{
    .title = "Hilfe",
    .subtitle = "Was Zugriff kann · auch mit ? oder hilfe",
    .action = .open_help,
};

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
    return topics.len;
}

/// `↵` on a topic: its example goes into the search field.
pub fn confirm(p: *Palette) !void {
    const topic = topics[@min(p.selected, topics.len - 1)];
    if (!topic.tryable) return p.beep();
    try p.setQuery(topic.example);
    p.help.example = topic.example;
}

fn activate(p: *Palette, index: usize) !void {
    p.selected = index;
    try confirm(p);
}

pub fn body(p: *Palette, c: *ui.Context) !void {
    const list = ui.div(c).column().wFull();
    defer list.end();
    for (topics, 0..) |topic, i| try topicRow(p, c, topic, i);
}

fn topicRow(p: *Palette, c: *ui.Context, topic: Topic, index: usize) !void {
    const selected = p.selected == index;
    const row = ui.div(c).row().wFull().h(theme.row_height).px(16).gap(12).itemsCenter().control();
    defer row.end();
    if (selected) _ = row.bg(theme.selection) else _ = row.hover(theme.surface);
    if (row.clicked()) try activate(p, index);
    if (std.mem.eql(u8, topic.glyph, emoji_glyph))
        palette.commandTile(p, c, topic.glyph)
    else
        symbolTile(c, topic.glyph, false);
    {
        const col = ui.div(c).column().grow().minW(0).gap(1);
        defer col.end();
        ui.text(c, topic.title, .{ .size = 14.5, .line_height = 18, .color = theme.text, .truncate = .ellipsis });
        ui.text(c, topic.subtitle, .{ .size = 11, .line_height = 14, .color = theme.muted, .truncate = .ellipsis });
    }
    ui.text(c, topic.example, .{ .size = 12, .line_height = 16, .color = theme.muted });
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
pub fn footer(p: *Palette, c: *ui.Context) []const []const u8 {
    ui.text(c, footer_label, .{ .size = 11, .color = theme.muted, .truncate = .ellipsis });
    if (!topics[@min(p.selected, topics.len - 1)].tryable) return &.{ "↑↓ Navigieren", "esc Schließen" };
    return &.{ "↑↓ Navigieren", "↵ Ausprobieren", "esc Schließen" };
}

/// The topics and the version of the running binary.
pub const footer_label = std.fmt.comptimePrint(
    "Hilfe · {d} Themen · Version {s}",
    .{ topics.len, build_options.version },
);

/// What the footer adds to its label while the query is an example from
/// the help (Z1).
pub fn origin(p: *const Palette) ?[]const u8 {
    return if (p.help.example != null) "aus der Hilfe" else null;
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
    ui.text(c, "Hilfe", .{ .size = 11, .line_height = 16, .color = theme.placeholder });
}

/// The footer tip of the empty app search, until the help was opened once (H6).
pub fn tip(p: *const Palette) ?[]const u8 {
    if (p.help.seen != false) return null;
    if (core.text.trim(p.text()).len != 0 or p.direct != null) return null;
    return "Tipp: ? zeigt, was Zugriff kann";
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
