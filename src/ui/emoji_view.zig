//! The emoji picker inside the palette (design `zugriff-emoji.figcraft` of
//! the Rust version, E1 with E6 and the states Z1–Z6).
//!
//! It opens with its own hot key or with `:` typed into the app search.
//! Without a query the grid shows the recently used emoji and then every
//! group; typing filters by German and English names, keywords and
//! shortcodes. `↵` inserts into the app in front, `⌘↵` copies, `⇥` opens
//! the skin tones. The table is static data; entering the picker builds
//! the grid from it and never waits for anything.
const std = @import("std");
const Allocator = std.mem.Allocator;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("../core.zig");
const emoji = core.emoji;
const theme = @import("theme.zig");
const palette = @import("palette.zig");
const Palette = palette.Palette;
const log = std.log.scoped(.emoji_view);
const Tone = emoji.Tone;
const Group = emoji.Group;

pub const placeholder = "Emoji suchen …";
pub const columns = 12;
pub const cell_size: f32 = 48;
const cell_gap: f32 = 3;
const glyph_size: f32 = 28;
const section_height: f32 = 29;
const cells_height: f32 = cell_size + cell_gap;
const tones_height: f32 = cell_size + 12 + 2 + 4;
pub const category_bar_height: f32 = 37;
/// Recently used emoji `⌘1`–`⌘9` insert.
const quick_keys = 9;
const accent_border = theme.accent.alpha(0.6);

/// Whether `↵` can insert into the app in front. The agent checks this
/// after every show; until it answers, the picker assumes it can, and the
/// agent falls back to copying if it cannot.
pub const InsertSupport = enum {
    ready,
    /// The Accessibility permission is missing: synthetic `⌘V` is refused.
    needs_permission,
    /// Secure event input is on (a password field): macOS drops synthetic keys.
    secure_input,
};

/// How the picker was opened. Only an entry from the app search is left
/// with `⌫`.
const Entry = enum { hotkey, from_search };

pub const Cell = struct {
    /// Index for `emoji.get`.
    emoji: usize,
    /// The glyph shown and inserted, with the remembered skin tone.
    glyph: []const u8,
};

const Line = union(enum) {
    section: struct { title: []const u8, detail: ?[]const u8 },
    cells: struct { start: usize, end: usize },
    /// The skin tones of the selected cell, below its row.
    tones,

    fn height(l: Line) f32 {
        return switch (l) {
            .section => section_height,
            .cells => cells_height,
            .tones => tones_height,
        };
    }
};

/// A section of the grid without a query: the recent emoji or a group.
const Section = union(enum) {
    recent,
    group: Group,

    fn icon(s: Section) []const u8 {
        return switch (s) {
            .recent => "🕘",
            .group => |g| g.icon(),
        };
    }

    fn title(s: Section) []const u8 {
        return switch (s) {
            .recent => "Zuletzt verwendet",
            .group => |g| g.title(),
        };
    }
};

const PromptRow = enum { open_settings, copy_only };

/// The permission question (Z4) for one emoji.
const Prompt = struct {
    glyph: []const u8,
    /// The emoji came from the skin tones: its tone becomes the default.
    remember_tone: bool,
    row: PromptRow,
};

pub const Picker = struct {
    entry: ?Entry = null,
    /// The search the cells were built for.
    query: std.ArrayList(u8) = .empty,
    /// "Treffer für „…“" and the count.
    title: std.ArrayList(u8) = .empty,
    detail: std.ArrayList(u8) = .empty,
    cells: std.ArrayList(Cell) = .empty,
    lines: std.ArrayList(Line) = .empty,
    /// The line of every cell.
    cell_lines: std.ArrayList(usize) = .empty,
    /// Sections and their first cell; only without a query.
    sections: std.ArrayList(struct { section: Section, start: usize }) = .empty,
    selected: usize = 0,
    /// The selected skin tone while the tones are open.
    tones: ?Tone = null,
    /// The emoji waiting for the Accessibility answer (Z4).
    prompt: ?Prompt = null,
    prefs: emoji.Prefs = .{},
    support: InsertSupport = .ready,
    /// The permission question was answered once; it does not come again in
    /// this session, and the agent decides at each `↵`.
    asked: bool = false,
    /// Where the next frame scrolls the grid.
    scroll: union(enum) { none, line_top: usize, reveal: usize } = .none,

    pub fn deinit(k: *Picker, gpa: Allocator) void {
        k.query.deinit(gpa);
        k.title.deinit(gpa);
        k.detail.deinit(gpa);
        k.cells.deinit(gpa);
        k.lines.deinit(gpa);
        k.cell_lines.deinit(gpa);
        k.sections.deinit(gpa);
        k.* = undefined;
    }

    pub fn active(k: *const Picker) bool {
        return k.entry != null;
    }

    pub fn selectedCell(k: *const Picker) ?Cell {
        return if (k.selected < k.cells.items.len) k.cells.items[k.selected] else null;
    }

    /// Rebuilds cells and lines for `query`; the first cell is selected.
    fn rebuild(k: *Picker, gpa: Allocator, query: []const u8) !void {
        k.query.clearRetainingCapacity();
        try k.query.appendSlice(gpa, query);
        k.cells.clearRetainingCapacity();
        k.lines.clearRetainingCapacity();
        k.sections.clearRetainingCapacity();
        k.selected = 0;
        k.tones = null;
        k.prompt = null;
        k.scroll = .{ .line_top = 0 };

        const search = searchOf(k.query.items);
        if (search.len == 0) {
            try k.buildBrowse(gpa);
        } else {
            const hits = try emoji.search(gpa, search, k.prefs.recentSlice());
            defer gpa.free(hits);
            if (hits.len > 0) {
                k.title.clearRetainingCapacity();
                try k.title.print(gpa, "Treffer für „{s}“", .{search});
                k.detail.clearRetainingCapacity();
                try k.detail.print(gpa, "{d} Emoji", .{hits.len});
                try k.lines.append(gpa, .{ .section = .{ .title = k.title.items, .detail = k.detail.items } });
                const start = k.cells.items.len;
                for (hits) |i| try k.cells.append(gpa, .{ .emoji = i, .glyph = emoji.get(i).withTone(k.prefs.tone) });
                try k.pushRows(gpa, start);
            }
        }
        try k.indexLines(gpa);
    }

    /// Without a query: the recent emoji, then every group.
    fn buildBrowse(k: *Picker, gpa: Allocator) !void {
        if (k.prefs.recent_len > 0) {
            try k.sections.append(gpa, .{ .section = .recent, .start = 0 });
            try k.lines.append(gpa, .{ .section = .{ .title = Section.title(.recent), .detail = "⌘1–9" } });
            for (k.prefs.recentSlice()) |glyph| {
                const f = emoji.find(glyph) orelse continue;
                try k.cells.append(gpa, .{ .emoji = f.index, .glyph = emoji.get(f.index).withTone(f.tone) });
            }
            try k.pushRows(gpa, 0);
        }
        for (Group.all) |group| {
            const start = k.cells.items.len;
            try k.sections.append(gpa, .{ .section = .{ .group = group }, .start = start });
            try k.lines.append(gpa, .{ .section = .{ .title = group.title(), .detail = null } });
            for (0..emoji.table_len) |i| if (emoji.groupOf(i) == group) {
                try k.cells.append(gpa, .{ .emoji = i, .glyph = emoji.get(i).withTone(k.prefs.tone) });
            };
            try k.pushRows(gpa, start);
        }
    }

    fn pushRows(k: *Picker, gpa: Allocator, start: usize) !void {
        var row = start;
        const end = k.cells.items.len;
        while (row < end) {
            const row_end = @min(row + columns, end);
            try k.lines.append(gpa, .{ .cells = .{ .start = row, .end = row_end } });
            row = row_end;
        }
    }

    fn indexLines(k: *Picker, gpa: Allocator) !void {
        try k.cell_lines.resize(gpa, k.cells.items.len);
        k.renumber();
    }

    /// Points each cell at its line again after a line came or went.
    fn renumber(k: *Picker) void {
        for (k.lines.items, 0..) |l, i| switch (l) {
            .cells => |r| for (r.start..r.end) |cell| {
                k.cell_lines.items[cell] = i;
            },
            else => {},
        };
    }

    /// The line and column of the selected cell.
    fn position(k: *const Picker) ?struct { line: usize, column: usize } {
        if (k.selected >= k.cell_lines.items.len) return null;
        const line = k.cell_lines.items[k.selected];
        return .{ .line = line, .column = k.selected - k.lines.items[line].cells.start };
    }

    /// The same column in the next row above or below, clamped to a
    /// shorter row; rows of other sections count too.
    fn verticalTarget(k: *const Picker, down: bool) ?usize {
        const pos = k.position() orelse return null;
        if (down) {
            for (k.lines.items[pos.line + 1 ..]) |l| if (l == .cells) return l.cells.start + @min(
                pos.column,
                l.cells.end - l.cells.start - 1,
            );
        } else {
            var i = pos.line;
            while (i > 0) {
                i -= 1;
                const l = k.lines.items[i];
                if (l == .cells) return l.cells.start + @min(pos.column, l.cells.end - l.cells.start - 1);
            }
        }
        return null;
    }

    fn sectionOf(k: *const Picker, cell: usize) ?usize {
        var found: ?usize = null;
        for (k.sections.items, 0..) |s, i| if (s.start <= cell) {
            found = i;
        };
        return found;
    }

    /// Scrolls so the section of the selected cell starts at the top.
    fn scrollSelectedSectionToTop(k: *Picker) void {
        const pos = k.position() orelse return;
        var top = pos.line;
        while (top > 0 and k.lines.items[top] != .section) top -= 1;
        k.scroll = .{ .line_top = top };
    }

    /// Keeps the selected row in view; the first row of a section brings
    /// its title along.
    fn revealSelected(k: *Picker) void {
        const pos = k.position() orelse return;
        const line = if (pos.line > 0 and k.lines.items[pos.line - 1] == .section) pos.line - 1 else pos.line;
        k.scroll = .{ .reveal = line };
    }

    fn openTones(k: *Picker, gpa: Allocator) !bool {
        const cell = k.selectedCell() orelse return false;
        if (!emoji.get(cell.emoji).hasTones()) return false;
        const pos = k.position() orelse return false;
        k.tones = if (emoji.find(cell.glyph)) |f| f.tone else k.prefs.tone;
        try k.lines.insert(gpa, pos.line + 1, .tones);
        k.renumber();
        k.scroll = .{ .reveal = pos.line + 1 };
        return true;
    }

    fn closeTones(k: *Picker) void {
        if (k.tones == null) return;
        k.tones = null;
        for (k.lines.items, 0..) |l, i| if (l == .tones) {
            _ = k.lines.orderedRemove(i);
            break;
        };
        k.renumber();
    }

    /// Remembers `glyph` as used, and its skin tone when `remember_tone`.
    fn record(k: *Picker, glyph: []const u8, remember_tone: bool) void {
        k.prefs.record(glyph);
        if (remember_tone) if (emoji.find(glyph)) |f| {
            k.prefs.tone = f.tone;
        };
    }
};

/// The search in a query: without the colons around it.
fn searchOf(query: []const u8) []const u8 {
    return std.mem.trim(u8, std.mem.trim(u8, core.text.trim(query), ":"), " ");
}

pub fn showing(p: *const Palette) bool {
    return p.emoji.active();
}

/// Opens the picker on its own (the emoji hot key): an empty query, the
/// recent emoji first. Builds the grid from static data only.
pub fn showFromHotkey(p: *Palette) !void {
    p.calc.clearView();
    p.query.clear();
    p.query.focus();
    enter(p, .hotkey);
    try p.emoji.rebuild(p.gpa, "");
    p.seen.clearRetainingCapacity();
}

/// The remembered skin tone and recent emoji, read in the background.
pub fn setPrefs(p: *Palette, prefs: emoji.Prefs) !void {
    p.emoji.prefs = prefs;
    if (p.emoji.active() and searchOf(p.emoji.query.items).len == 0) try p.emoji.rebuild(p.gpa, "");
}

/// Whether `↵` can insert into the app in front, checked after a show.
pub fn setSupport(p: *Palette, support: InsertSupport) void {
    p.emoji.support = support;
}

fn enter(p: *Palette, entry: Entry) void {
    p.emoji.entry = entry;
    if (p.direct) |*d| d.deinit();
    p.direct = null;
    p.setResults(&.{});
    p.placeholder = placeholder;
    p.accepts_blocks = false;
}

pub fn leave(p: *Palette) void {
    if (p.emoji.entry == null) return;
    p.emoji.entry = null;
    p.emoji.prompt = null;
    p.emoji.tones = null;
    p.placeholder = palette.search_placeholder;
    p.accepts_blocks = true;
}

/// Searches the picker while it is open, or opens it for a query that
/// starts with `:`. False when the app search should handle `raw`.
pub fn refresh(p: *Palette, raw: []const u8) !bool {
    if (!p.emoji.active()) {
        if (!std.mem.startsWith(u8, raw, ":")) return false;
        enter(p, .from_search);
        const rest = try p.gpa.dupe(u8, raw[1..]);
        defer p.gpa.free(rest);
        try p.emoji.rebuild(p.gpa, rest);
        p.query.set(rest);
        p.seen.clearRetainingCapacity();
        try p.seen.appendSlice(p.gpa, rest);
        return true;
    }
    try p.emoji.rebuild(p.gpa, raw);
    return true;
}

/// `↵` on the "Emoji" row of the app search: the picker with an empty
/// query, left again with `⌫`.
pub fn openFromSearch(p: *Palette) !void {
    p.calc.clearView();
    enter(p, .from_search);
    try p.emoji.rebuild(p.gpa, "");
    p.query.clear();
    p.seen.clearRetainingCapacity();
}

/// `⌫` in the empty field: back to the app search when the picker was
/// opened from it.
pub fn backspace(p: *Palette) !void {
    if (p.emoji.entry == .from_search) {
        leave(p);
        try p.refresh();
    } else p.beep();
}

/// `↑`/`↓`: the same column one row up or down, or the prompt rows.
pub fn vertical(p: *Palette, down: bool) void {
    const k = &p.emoji;
    if (k.prompt) |*prompt| {
        prompt.row = if (down) .copy_only else .open_settings;
        return;
    }
    k.closeTones();
    if (k.verticalTarget(down)) |target| {
        k.selected = target;
        k.revealSelected();
    }
}

/// `←`/`→`: the previous or next cell, or the previous or next tone.
pub fn step(p: *Palette, forward: bool) void {
    const k = &p.emoji;
    if (k.tones) |tone| {
        const i = tone.index();
        k.tones = Tone.fromIndex(if (forward) @min(i + 1, Tone.count - 1) else i -| 1);
        return;
    }
    if (forward) {
        if (k.selected + 1 < k.cells.items.len) k.selected += 1 else return;
    } else {
        if (k.selected == 0) return;
        k.selected -= 1;
    }
    k.revealSelected();
}

/// `⌥←`/`⌥→`: the first cell of the previous or next section.
pub fn jumpSection(p: *Palette, forward: bool) void {
    const k = &p.emoji;
    const current = k.sectionOf(k.selected) orelse return;
    const target = if (forward)
        current + 1
    else if (k.sections.items[current].start < k.selected)
        // Back to the start of the current section first.
        current
    else if (current == 0) return else current - 1;
    if (target >= k.sections.items.len) return;
    jumpToCell(p, k.sections.items[target].start);
}

/// Selects the first cell of a section (category bar, `⌥←`/`⌥→`).
fn jumpToCell(p: *Palette, cell: usize) void {
    const k = &p.emoji;
    k.closeTones();
    k.prompt = null;
    k.selected = cell;
    k.scrollSelectedSectionToTop();
}

fn selectCell(p: *Palette, cell: usize) void {
    const k = &p.emoji;
    k.closeTones();
    k.prompt = null;
    k.selected = cell;
    k.revealSelected();
}

pub fn toggleTones(p: *Palette) void {
    const k = &p.emoji;
    if (k.tones != null) return k.closeTones();
    if (!(k.openTones(p.gpa) catch false)) p.beep();
}

/// Escape closes the open tones or the prompt before it closes the palette.
pub fn escape(p: *Palette) bool {
    const k = &p.emoji;
    if (k.tones != null) {
        k.closeTones();
        return true;
    }
    if (k.prompt != null) {
        k.prompt = null;
        return true;
    }
    return false;
}

/// `⌘1`–`⌘9` insert the recent emoji. Returns whether it took the key.
pub fn quickKey(p: *Palette, number: u21) bool {
    const k = &p.emoji;
    if (!k.active() or number < 1 or number > quick_keys) return false;
    const recent = k.prefs.recentSlice();
    if (number > recent.len) return false;
    const f = emoji.find(recent[number - 1]) orelse return false;
    insert(p, emoji.get(f.index).withTone(f.tone), false);
    return true;
}

/// `↵`: insert the selected emoji, the chosen tone, or answer the prompt.
pub fn confirm(p: *Palette) void {
    const k = &p.emoji;
    if (k.prompt) |prompt| return answerPrompt(p, prompt, prompt.row);
    const cell = k.selectedCell() orelse return p.beep();
    if (k.tones) |tone| {
        insert(p, emoji.get(cell.emoji).withTone(tone), true);
    } else insert(p, cell.glyph, false);
}

/// `⌘↵`: copy instead of inserting.
pub fn copy(p: *Palette) void {
    const k = &p.emoji;
    if (k.prompt) |prompt| return answerPrompt(p, prompt, .copy_only);
    const cell = k.selectedCell() orelse return p.beep();
    const glyph = if (k.tones) |tone| emoji.get(cell.emoji).withTone(tone) else cell.glyph;
    k.record(glyph, k.tones != null);
    p.emit(.{ .emoji_prefs = k.prefs });
    p.emit(.{ .copy = glyph });
}

fn insert(p: *Palette, glyph: []const u8, remember_tone: bool) void {
    const k = &p.emoji;
    const inserts = switch (k.support) {
        .ready => true,
        .secure_input => false,
        .needs_permission => if (!k.asked) {
            k.closeTones();
            k.prompt = .{ .glyph = glyph, .remember_tone = remember_tone, .row = .open_settings };
            return;
        } else
        // Asked once already: the agent checks the permission again at this
        // moment and copies if it is still missing, so a permission granted
        // since the last opening takes effect at once.
        true,
    };
    k.record(glyph, remember_tone);
    p.emit(.{ .emoji_prefs = k.prefs });
    p.emit(if (inserts) .{ .insert = glyph } else .{ .copy = glyph });
}

fn answerPrompt(p: *Palette, prompt: Prompt, row: PromptRow) void {
    const k = &p.emoji;
    k.asked = true;
    k.prompt = null;
    k.record(prompt.glyph, prompt.remember_tone);
    p.emit(.{ .emoji_prefs = k.prefs });
    // Either way the emoji lands on the clipboard, so it is not lost while
    // the user looks at System Settings.
    p.emit(.{ .copy = prompt.glyph });
    if (row == .open_settings) p.emit(.request_insert_permission);
}

/// The footer: the selected emoji with name and shortcode, and the keys.
pub fn footer(p: *Palette, c: *ui.Context, buf: *[6][]const u8) []const []const u8 {
    const k = &p.emoji;
    if (k.prompt != null) {
        footerText(c, "Einfügen braucht eine Erlaubnis", theme.muted);
        return &.{ "↑↓ Auswahl", "↵ Bestätigen", "⌘↵ Kopieren", "esc Zurück" };
    }
    if (k.tones != null) {
        selectedLabel(p, c);
        return &.{ "←→ Hautton", "↵ Einfügen und merken", "⇥ Zurück" };
    }
    const cell = k.selectedCell() orelse {
        footerText(c, "0 Emoji", theme.muted);
        return &.{"esc Schließen"};
    };
    if (k.support == .secure_input) {
        footerText(c, "Eingabeschutz aktiv (Passwortfeld vorn): ↵ kopiert nur", theme.accent);
        return &.{ "↵ Kopieren", "esc Schließen" };
    }
    var n: usize = 0;
    if (emoji.get(cell.emoji).hasTones()) {
        buf[n] = "⇥ Hauttöne";
        n += 1;
    }
    for ([_][]const u8{ "↵ Einfügen", "⌘↵ Kopieren", "esc Schließen" }) |h| {
        buf[n] = h;
        n += 1;
    }
    selectedLabel(p, c);
    return buf[0..n];
}

fn footerText(c: *ui.Context, s: []const u8, color: ui.Color) void {
    ui.text(c, s, .{ .size = 11, .color = color, .truncate = .ellipsis });
}

fn selectedLabel(p: *Palette, c: *ui.Context) void {
    const k = &p.emoji;
    const cell = k.selectedCell() orelse return;
    const entry = emoji.get(cell.emoji);
    const glyph = if (k.tones) |tone| entry.withTone(tone) else cell.glyph;
    var codes: std.ArrayList(u8) = .empty;
    var it = entry.shortcodes();
    // Shortcodes are a hint; a full frame arena just shortens the list.
    while (it.next()) |code| codes.print(
        c.alloc(),
        "{s}:{s}:",
        .{ if (codes.items.len > 0) " " else "", code },
    ) catch break;
    const row = ui.div(c).row().gap(6).itemsCenter().minW(0).grow().clip();
    defer row.end();
    p.glyphs.draw(c, glyph, 16);
    ui.text(c, entry.name, .{ .size = 11, .color = theme.text });
    ui.text(c, codes.items, .{ .size = 11, .color = theme.placeholder, .truncate = .ellipsis });
}

/// The grid, or the permission prompt, or the empty state.
pub fn body(p: *Palette, c: *ui.Context) !void {
    const k = &p.emoji;
    if (k.prompt) |prompt| return promptBody(p, c, prompt);
    if (k.cells.items.len == 0) {
        const box = ui.div(c).column().sizeFull().center().gap(6);
        defer box.end();
        ui.text(
            c,
            c.print("Kein Emoji für „{s}“", .{searchOf(k.query.items)}),
            .{ .size = 15, .color = theme.text },
        );
        ui.text(c, "⌫ ändert die Suche, esc schließt.", .{ .size = 12, .color = theme.muted });
        return;
    }
    if (k.sections.items.len > 0) categoryBar(p, c);
    grid(p, c);
}

fn categoryBar(p: *Palette, c: *ui.Context) void {
    const k = &p.emoji;
    const current = k.sectionOf(k.selected);
    {
        const bar = ui.div(c).row().wFull().h(category_bar_height).px(12).gap(4).itemsCenter();
        defer bar.end();
        for (k.sections.items, 0..) |s, i| {
            const tab = ui.div(c).size(30, 28).rounded(6).center().control();
            defer tab.end();
            if (current == i) _ = tab.bg(theme.selection) else _ = tab.hover(theme.surface);
            if (tab.clicked()) jumpToCell(p, s.start);
            p.glyphs.draw(c, s.section.icon(), 18);
        }
        ui.spacer(c);
        ui.text(
            c,
            if (current) |i| k.sections.items[i].section.title() else "",
            .{ .size = 11, .color = theme.placeholder },
        );
        ui.text(c, "⌥←→", .{ .size = 11, .color = theme.muted });
    }
    ui.div(c).wFull().h(1).bg(theme.border).end();
}

/// The lines in view of a scrolling box, with room for those above and
/// below: the whole table is 170 rows of twelve.
fn grid(p: *Palette, c: *ui.Context) void {
    const k = &p.emoji;
    const id = c.peekId(null);
    const view_h = if (c.rects.get(id)) |r| r.h else 260;
    var offset = c.scroll.get(id) orelse 0;
    var tops: std.ArrayList(f32) = .empty;
    var y: f32 = 0;
    for (k.lines.items) |l| {
        tops.append(c.alloc(), y) catch return;
        y += l.height();
    }
    const total = y;
    switch (k.scroll) {
        .none => {},
        .line_top => |line| offset = tops.items[@min(line, tops.items.len - 1)],
        .reveal => |line| if (line < tops.items.len) {
            const top = tops.items[line];
            const end_line = if (line + 1 < k.lines.items.len and k.lines.items[line] == .section) line + 1 else line;
            const bottom = tops.items[end_line] + k.lines.items[end_line].height();
            if (top < offset) offset = top else if (bottom > offset + view_h) offset = bottom - view_h;
        },
    }
    k.scroll = .none;
    offset = std.math.clamp(offset, 0, @max(0, total - view_h));
    c.scroll.put(c.gpa, id, offset) catch |e| log.warn("Emoji-Raster: Scrollposition verloren: {t}", .{e});

    const box = ui.div(c).column().wFull().grow().scrollY();
    defer box.end();
    var first: usize = 0;
    while (first + 1 < tops.items.len and tops.items[first + 1] <= offset) first += 1;
    if (tops.items[first] > 0) ui.div(c).wFull().h(tops.items[first]).end();
    var i = first;
    while (i < k.lines.items.len and tops.items[i] < offset + view_h) : (i += 1) {
        ui.keyInt(c, i);
        lineView(p, c, k.lines.items[i]);
    }
    if (i < k.lines.items.len) ui.div(c).wFull().h(total - tops.items[i]).end();
}

fn lineView(p: *Palette, c: *ui.Context, l: Line) void {
    switch (l) {
        .section => |s| {
            const row = ui.div(c).row().wFull().h(section_height).px(16).pt(10).justifyBetween();
            defer row.end();
            ui.text(c, s.title, .{ .size = 11, .line_height = 15, .color = theme.placeholder, .truncate = .ellipsis });
            if (s.detail) |d| ui.text(c, d, .{ .size = 11, .line_height = 15, .color = theme.placeholder });
        },
        .cells => |r| {
            const row = ui.div(c).row().wFull().h(cells_height).px(12).gap(cell_gap);
            defer row.end();
            for (r.start..r.end) |i| cellView(p, c, i);
        },
        .tones => tonesView(p, c),
    }
}

fn cellView(p: *Palette, c: *ui.Context, index: usize) void {
    const k = &p.emoji;
    const cell = k.cells.items[index];
    const entry = emoji.get(cell.emoji);
    const selected = index == k.selected;
    const box = ui.div(c).size(cell_size, cell_size).rounded(8).center().control();
    defer box.end();
    if (selected) _ = box.bg(theme.selection_overlay).border(accent_border) else _ = box.hover(theme.surface);
    if (box.clicked()) {
        selectCell(p, index);
        confirm(p);
    }
    p.glyphs.draw(c, cell.glyph, glyph_size + 4);
    if (entry.hasTones()) ui.div(c).absolute().offset(
        cell_size - 9,
        cell_size - 9,
    ).size(5, 5).rounded(3).bg(theme.placeholder).end();
}

fn tonesView(p: *Palette, c: *ui.Context) void {
    const k = &p.emoji;
    const cell = k.selectedCell() orelse return;
    const entry = emoji.get(cell.emoji);
    const chosen = k.tones orelse .default;
    const outer = ui.div(c).wFull().px(10).pb(4);
    defer outer.end();
    const row = ui.div(c).row().wFull().itemsCenter().gap(cell_gap).px(12).py(6).rounded(10)
        .bg(theme.surface).border(theme.border);
    defer row.end();
    for (0..Tone.count) |i| {
        const tone = Tone.fromIndex(i).?;
        const variant = ui.div(c).size(cell_size, cell_size).rounded(8).center().control();
        defer variant.end();
        if (tone == chosen) _ = variant.bg(theme.selection_overlay).border(accent_border);
        if (variant.clicked()) {
            k.tones = tone;
            confirm(p);
        }
        p.glyphs.draw(c, entry.withTone(tone), glyph_size + 4);
    }
    ui.spacer(c);
    ui.text(c, "←→ wählen · ↵ einfügen und merken", .{ .size = 11, .color = theme.muted });
}

fn promptBody(p: *Palette, c: *ui.Context, prompt: Prompt) void {
    {
        const pad = ui.div(c).wFull().px(10).pt(10).pb(6);
        defer pad.end();
        const card = ui.div(c).column().wFull().gap(8).px(18).py(16).rounded(10)
            .bg(theme.selection).border(accent_border);
        defer card.end();
        ui.text(
            c,
            "Zum Einfügen braucht Zugriff die Bedienungshilfen",
            .{ .size = 15, .line_height = 20, .color = theme.text },
        );
        ui.text(
            c,
            "Zugriff legt das Emoji in die Zwischenablage, gibt den Fokus an die App davor zurück, " ++
                "sendet ⌘V und stellt die Zwischenablage danach wieder her. Tastendrücke an andere Apps " ++
                "erlaubt macOS nur mit dieser Erlaubnis. Ohne sie kopiert ↵ nur.",
            .{ .size = 12, .line_height = 18, .color = theme.muted, .wrap = true },
        );
    }
    const rows = [_]struct { PromptRow, []const u8, []const u8, []const u8, []const u8 }{
        .{ .open_settings, "⚙️", "Systemeinstellungen öffnen", c.print(
            "Datenschutz & Sicherheit › Bedienungshilfen › Zugriff · {s} wird kopiert",
            .{prompt.glyph},
        ), "↵" },
        .{ .copy_only, "📋", "Nur kopieren", c.print(
            "{s} liegt dann in der Zwischenablage, ⌘V fügt ein",
            .{prompt.glyph},
        ), "⌘↵" },
    };
    for (rows) |r| {
        const selected = r[0] == prompt.row;
        const row = ui.div(c).row().wFull().h(theme.row_height).px(16).gap(12).itemsCenter().control();
        defer row.end();
        if (selected) _ = row.bg(theme.selection) else _ = row.hover(theme.surface);
        if (row.clicked()) answerPrompt(p, prompt, r[0]);
        palette.commandTile(p, c, r[1]);
        {
            const col = ui.div(c).column().grow().minW(0).gap(1);
            defer col.end();
            ui.text(c, r[2], .{ .size = 14.5, .line_height = 18, .color = theme.text, .truncate = .ellipsis });
            ui.text(c, r[3], .{ .size = 11, .line_height = 14, .color = theme.muted, .truncate = .ellipsis });
        }
        ui.text(c, r[4], .{ .size = 11, .color = theme.muted });
        if (selected) palette.selectionBar(c, 16, 11);
    }
}
