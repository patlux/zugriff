//! The calculator inside the palette: the result card above the app hits,
//! other readings of the task, the history behind `=`, the last calculation
//! that is still there when the palette opens again shortly after, and the
//! sheet for several pasted lines.
//!
//! Calculating happens while typing, synchronously and within `budget_ns`;
//! opening the palette never calculates anything.
const std = @import("std");
const Allocator = std.mem.Allocator;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("../core.zig");
const calc = core.calc;
const theme = @import("theme.zig");
const palette = @import("palette.zig");
const help_view = @import("help_view.zig");
const Palette = palette.Palette;
const log = std.log.scoped(.calc_view);

/// What one keystroke may spend on calculating, other readings included.
pub const budget_ns: u64 = 10 * std.time.ns_per_ms;
/// Opening the palette again within this time shows the last calculation.
pub const restore_window_ms: i64 = 90 * std.time.ms_per_s;
/// Calculations the history keeps; it lives in memory only.
const history_limit = 20;
/// Other readings shown below the card; more would push the app hits out.
const alternative_limit = 3;

const card_height: f32 = 140;
const format_row_height: f32 = 32;
const sheet_row_height: f32 = 34;
const sheet_total_height: f32 = 52;

pub const Format = enum {
    /// As shown: `4.166,70`.
    shown,
    /// The number for programs: `4166.70`.
    number,
    /// Task and result: `(1.299 + 89,90) × 3 = 4.166,70`.
    with_task,
};

/// A selectable calculator row.
const Row = union(enum) {
    card,
    alternative: usize,
    history: usize,
    line: usize,
    total,
};

/// A calculation kept after the palette closed with it.
const Entry = struct {
    arena: std.heap.ArenaAllocator,
    query: []const u8,
    task: []const u8,
    answer: calc.Answer,
    at_ms: i64,
};

pub const Calculator = struct {
    gpa: Allocator,
    /// Holds `current` and `sheet` until the next calculation.
    arena: std.heap.ArenaAllocator,
    /// The calculation the query stands for.
    current: ?calc.Calculation = null,
    /// The query `current` was calculated from.
    query: std.ArrayList(u8) = .empty,
    /// The query is `=` alone: the list shows the history.
    showing_history: bool = false,
    history: std.ArrayList(Entry) = .empty,
    /// When the palette last closed while it showed a result.
    closed_at: ?i64 = null,
    /// How long ago the restored calculation was closed, while it stands.
    restored_ms: ?i64 = null,
    /// Several pasted lines, calculated one by one.
    sheet: ?calc.Sheet = null,

    pub fn init(gpa: Allocator) Calculator {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(k: *Calculator) void {
        for (k.history.items) |*e| e.arena.deinit();
        k.history.deinit(k.gpa);
        k.query.deinit(k.gpa);
        k.arena.deinit();
        k.* = undefined;
    }

    pub fn clearView(k: *Calculator) void {
        k.current = null;
        k.sheet = null;
        k.query.clearRetainingCapacity();
        k.showing_history = false;
        k.restored_ms = null;
        _ = k.arena.reset(.retain_capacity);
    }

    fn alternatives(k: *const Calculator) []const calc.Alternative {
        const c = k.current orelse return &.{};
        return c.alternatives[0..@min(c.alternatives.len, alternative_limit)];
    }

    /// Selectable rows above the app hits.
    pub fn rowCount(k: *const Calculator) usize {
        if (k.showing_history) return k.history.items.len;
        if (k.sheet) |s| return s.lines.len + @intFromBool(s.total != null);
        const c = k.current orelse return 0;
        return if (c.answer() != null) 1 + k.alternatives().len else 0;
    }

    fn row(k: *const Calculator, selected: usize) ?Row {
        if (k.showing_history) return if (selected < k.history.items.len) .{ .history = selected } else null;
        if (k.sheet) |s| {
            if (selected < s.lines.len) return .{ .line = selected };
            if (selected == s.lines.len and s.total != null) return .total;
            return null;
        }
        if (selected >= k.rowCount()) return null;
        return if (selected == 0) .card else .{ .alternative = selected - 1 };
    }

    /// Whether app hits follow the calculator rows; the history and a sheet
    /// take their place.
    pub fn listsApps(k: *const Calculator) bool {
        return !k.showing_history and k.sheet == null;
    }

    /// Whether the body shows the calculator instead of the plain hit list.
    pub fn hasBody(k: *const Calculator) bool {
        return k.showing_history or k.current != null or k.sheet != null;
    }

    /// Calculates `raw`. True when the query is `=` alone and the list shows
    /// the history instead of a search.
    pub fn refresh(k: *Calculator, raw: []const u8) !bool {
        k.clearView();
        if (std.mem.eql(u8, core.text.trim(raw), "=")) {
            k.showing_history = true;
            return true;
        }
        k.current = try calc.calculate(k.arena.allocator(), raw, budget_ns);
        if (k.current != null) try k.query.appendSlice(k.gpa, raw);
        return false;
    }

    /// Calculates every pasted line.
    pub fn showSheet(k: *Calculator, lines: []const []const u8) !void {
        k.sheet = try calc.sheet(k.arena.allocator(), lines, budget_ns);
    }

    /// The palette is closing. A result on screen goes into the history and
    /// stays for `restore_window_ms`.
    pub fn closed(k: *Calculator, now_ms: i64) !void {
        const c = k.current orelse {
            k.closed_at = null;
            return;
        };
        const ans = c.answer() orelse {
            k.closed_at = null;
            return;
        };
        try k.record(c.task, ans, now_ms);
        k.closed_at = now_ms;
    }

    fn record(k: *Calculator, task: []const u8, ans: calc.Answer, now_ms: i64) !void {
        var entry: Entry = .{ .arena = .init(k.gpa), .query = "", .task = "", .answer = undefined, .at_ms = now_ms };
        errdefer entry.arena.deinit();
        const a = entry.arena.allocator();
        entry.query = try a.dupe(u8, k.query.items);
        entry.task = try a.dupe(u8, task);
        entry.answer = try ans.dupe(a);
        var i: usize = 0;
        while (i < k.history.items.len) {
            if (std.mem.eql(u8, k.history.items[i].task, entry.task)) {
                var old = k.history.orderedRemove(i);
                old.arena.deinit();
            } else i += 1;
        }
        try k.history.insert(k.gpa, 0, entry);
        while (k.history.items.len > history_limit) {
            var old = k.history.pop().?;
            old.arena.deinit();
        }
    }

    /// Whether the last calculation stays for this show: it closed less
    /// than `restore_window_ms` ago.
    pub fn restore(k: *Calculator, now_ms: i64) bool {
        const at = k.closed_at orelse return false;
        const since = now_ms - at;
        if (k.rowCount() == 0 or since > restore_window_ms) return false;
        k.restored_ms = since;
        return true;
    }
};

/// `↵` on a calculator row copies it. False when the selection is an app hit.
pub fn confirm(p: *Palette) !bool {
    if (p.calc.row(p.selected) != null) {
        _ = try copySelected(p, .shown);
        return true;
    }
    // An unfinished or failed task has nothing to copy.
    if (p.calc.current != null and p.results.len == 0) {
        p.beep();
        return true;
    }
    return false;
}

pub fn copySelected(p: *Palette, format: Format) !bool {
    const sel = selectedAnswer(p) orelse return false;
    const a = p.calc.arena.allocator();
    const text = switch (format) {
        .shown => sel.answer.text,
        .number => sel.answer.number,
        .with_task => if (p.calc.sheet) |s| try sheetTable(a, s) else try a.print(
            "{s} {s} {s}",
            .{ sel.task, sel.answer.relation(), sel.answer.text },
        ),
    };
    p.emit(.{ .copy = text });
    return true;
}

fn selectedAnswer(p: *Palette) ?struct { task: []const u8, answer: calc.Answer } {
    const k = &p.calc;
    return switch (k.row(p.selected) orelse return null) {
        .card => .{ .task = k.current.?.task, .answer = k.current.?.answer() orelse return null },
        .alternative => |i| .{ .task = k.alternatives()[i].task, .answer = k.alternatives()[i].answer },
        .history => |i| .{ .task = k.history.items[i].task, .answer = k.history.items[i].answer },
        .line => |i| .{ .task = k.sheet.?.lines[i].text, .answer = k.sheet.?.lines[i].answer orelse return null },
        .total => .{ .task = "Summe", .answer = k.sheet.?.total.? },
    };
}

/// `⌘↵` in the history puts the task back into the search field.
pub fn editHistoryEntry(p: *Palette) !bool {
    const r = p.calc.row(p.selected) orelse return false;
    if (r != .history) return false;
    const q = try p.gpa.dupe(u8, p.calc.history.items[r.history].query);
    defer p.gpa.free(q);
    try p.setQuery(q);
    return true;
}

/// Every line as `task<TAB>result`, then the sum: pastes as two columns
/// into Numbers or Excel.
fn sheetTable(a: Allocator, s: calc.Sheet) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s.lines, 0..) |line, i| {
        if (i > 0) try out.append(a, '\n');
        try out.print(a, "{s}\t{s}", .{ line.text, if (line.answer) |ans| ans.text else "" });
    }
    if (s.total) |total| try out.print(a, "\nSumme\t{s}", .{total.text});
    return out.toOwnedSlice(a);
}

pub fn headerLabel(p: *Palette, c: *ui.Context) ?[]const u8 {
    if (p.calc.sheet) |s| return c.print("{d} Zeilen", .{s.lines.len});
    if (p.calc.showing_history) return "Verlauf";
    return null;
}

/// The footer's label, drawn here, and its hints; null while an app hit is
/// selected.
pub fn footer(p: *Palette, c: *ui.Context, buf: *[6][]const u8) ?[]const []const u8 {
    const k = &p.calc;
    var label: []const u8 = undefined;
    var hints: []const []const u8 = undefined;
    if (k.showing_history) {
        const n = k.history.items.len;
        label = if (n == 1) "1 Rechnung" else c.print("{d} Rechnungen", .{n});
        hints = if (n == 0) &.{"esc Schließen"} else &.{ "↵ Kopieren", "⌘↵ Bearbeiten", "esc Schließen" };
    } else if (k.sheet) |s| {
        const shown = if (s.total) |t| t.shown(c.alloc()) catch "" else "";
        label = if (s.total != null) c.print(
            "{d} Zeilen, Summe {s}",
            .{ s.lines.len, shown },
        ) else c.print("{d} Zeilen, keine Summe", .{s.lines.len});
        const without = s.lines.len - s.counted;
        if (without > 0) label = c.print("{s} · {d} ohne Zahl", .{ label, without });
        hints = &.{ "↑↓ Zeile", "↵ Kopieren", "⇧↵ Als Tabelle", "esc Schließen" };
    } else {
        const calculation = k.current orelse return null;
        const on_calculation = k.row(p.selected) != null;
        if (!on_calculation and p.results.len > 0) return null;
        label = if (k.restored_ms) |since|
            c.print("Letzte Rechnung · {s}", .{ago(c, since)})
        else if (calculation.skipped.len == 1)
            "Eingefügt · 1 Wort übergangen"
        else if (calculation.skipped.len > 1)
            c.print("Eingefügt · {d} Wörter übergangen", .{calculation.skipped.len})
        else if (calculation.thousands_dot)
            "2 Lesarten"
        else if (calculation.conversion != null)
            "Einheiten"
        else
            "Rechner";
        if (help_view.origin(p)) |o| label = c.print("{s} · {s}", .{ label, o });
        if (on_calculation) {
            var n: usize = 0;
            const alts = k.alternatives();
            if (alts.len > 0) {
                const units = for (alts) |alt| {
                    if (alt.kind != .binary) break false;
                } else true;
                buf[n] = if (units) "↑↓ Einheit" else "↑↓ Lesart";
                n += 1;
            }
            for ([_][]const u8{ "↵ Kopieren", "⌥↵ Nur Zahl", "⇧↵ Mit Aufgabe", "esc Schließen" }) |h| {
                buf[n] = h;
                n += 1;
            }
            hints = buf[0..n];
        } else hints = &.{"esc Schließen"};
    }
    ui.text(c, label, .{ .size = 11, .color = theme.muted, .truncate = .ellipsis });
    return hints;
}

/// `vor 12 s`, `vor 3 Min.`, `vor 2 Std.`, `vor 1 Tag`.
pub fn ago(c: *ui.Context, since_ms: i64) []const u8 {
    const s = @divTrunc(@max(0, since_ms), std.time.ms_per_s);
    if (s < 5) return "gerade eben";
    if (s < 60) return c.print("vor {d} s", .{s});
    if (s < 3600) return c.print("vor {d} Min.", .{@divTrunc(s, 60)});
    if (s < 86400) return c.print("vor {d} Std.", .{@divTrunc(s, 3600)});
    if (s < 172800) return "vor 1 Tag";
    return c.print("vor {d} Tagen", .{@divTrunc(s, 86400)});
}

/// The card, the other readings or the copy formats, and the app hits below.
pub fn body(p: *Palette, c: *ui.Context) !void {
    if (p.calc.showing_history) return historyBody(p, c);
    if (p.calc.sheet != null) return sheetBody(p, c);
    const calculation = p.calc.current orelse return p.hitList(c);

    {
        const pad = ui.div(c).wFull().px(10).pt(10).pb(6);
        defer pad.end();
        card(p, c, calculation, p.calc.row(p.selected) != null and p.selected == 0);
    }

    const alts = p.calc.alternatives();
    if (alts.len > 0) {
        section(c, alternativesTitle(alts));
        for (alts, 0..) |alt, i| {
            const symbol = switch (alt.kind) {
                .share, .before => "%",
                .decimal_point => "=",
                .binary => "≈",
            };
            if (calculatorRow(
                c,
                p.selected == i + 1,
                symbol,
                try alt.answer.shown(c.alloc()),
                alternativeSubtitle(c, alt),
            )) {
                p.selected = i + 1;
                _ = try copySelected(p, .shown);
            }
        }
    } else if (calculation.answer()) |ans| {
        if (p.results.len == 0) {
            section(c, "Kopieren als");
            formatRow(c, ans.text, "Ergebnis wie angezeigt", "↵");
            formatRow(c, ans.number, "nur die Zahl, mit Dezimalpunkt", "⌥↵");
            formatRow(
                c,
                c.print("{s} {s} {s}", .{ calculation.task, ans.relation(), ans.text }),
                "mit Aufgabe",
                "⇧↵",
            );
        }
    } else if (calculation.outcome.problem == .no_rates) {
        const note = ui.div(c).wFull().px(20).pt(8);
        defer note.end();
        ui.text(
            c,
            "Zugriff rechnet nur lokal und lädt keine Wechselkurse. Ohne Umrechnung rechnet es " ++
                "mit der Währung als Etikett: 100 € × 3 ergibt 300 €.",
            .{ .size = 12, .line_height = 18, .color = theme.muted, .wrap = true },
        );
    }

    if (p.results.len > 0) {
        section(c, "Apps");
        const hits = ui.div(c).column().wFull().grow().minW(0);
        defer hits.end();
        p.hitList(c);
    }
}

fn card(p: *Palette, c: *ui.Context, calculation: calc.Calculation, selected: bool) void {
    const a = c.alloc();
    var result: []const u8 = undefined;
    var result_color: ui.Color = theme.text;
    var result_caption: []const u8 = undefined;
    switch (calculation.outcome) {
        .answer => |ans| {
            result = ans.shown(a) catch ans.text;
            result_caption = resultCaption(calculation, ans);
        },
        .problem => |problem| {
            const t = problemText(c, problem);
            result = t.text;
            result_caption = t.caption;
            result_color = if (t.warns) theme.warning else theme.placeholder;
        },
    }
    const ok = calculation.outcome == .answer;
    const result_chars = core.text.countCodepoints(result);
    const stacked = result_chars > 16 or core.text.countCodepoints(calculation.task) > 26;
    const result_size: f32 = if (stacked) 22 else if (result_chars > 10) 24 else 30;
    const box = ui.div(c).wFull().h(card_height).rounded(10).borderW(1).px(20).control();
    defer box.end();
    _ = if (selected)
        box.bg(theme.selection).border(theme.accent_border)
    else
        box.bg(theme.surface).border(theme.border);
    if (ok and box.clicked()) {
        p.selected = 0;
        if (copySelected(p, .shown)) |_| {} else |_| p.beep();
    }
    const caption_color = if (selected) theme.muted else theme.placeholder;
    const task_style: ui.TextStyle = .{
        .size = if (stacked) 15 else 19,
        .line_height = if (stacked) 20 else 26,
        .weight = .medium,
        .color = if (stacked) theme.muted else theme.text,
        .truncate = .ellipsis,
    };
    const result_style: ui.TextStyle = .{
        .size = if (ok) result_size else 22,
        .line_height = result_size * 1.3,
        .weight = if (ok) .semibold else .medium,
        .color = result_color,
        .truncate = .ellipsis,
    };
    const caption_style: ui.TextStyle = .{
        .size = 11,
        .line_height = 14,
        .color = theme.placeholder,
        .truncate = .ellipsis,
    };

    if (stacked) {
        _ = box.column().center().gap(4);
        ui.text(c, calculation.task, task_style);
        ui.text(c, taskCaption(c, calculation), caption_style);
        ui.div(c).h(6).end();
        ui.text(c, result, result_style);
        var cs = caption_style;
        cs.color = caption_color;
        ui.text(c, result_caption, cs);
        return;
    }
    _ = box.row().itemsCenter().gap(12);
    {
        const half = ui.div(c).column().grow().minW(0).itemsCenter().gap(6);
        defer half.end();
        ui.text(c, calculation.task, task_style);
        ui.text(c, taskCaption(c, calculation), caption_style);
    }
    {
        const arrow = ui.div(c).size(30, 30).rounded(15).bg(theme.surface).center();
        defer arrow.end();
        ui.text(c, "→", .{ .size = 14, .color = theme.muted });
    }
    {
        const half = ui.div(c).column().grow().minW(0).itemsCenter().gap(4);
        defer half.end();
        ui.text(c, result, result_style);
        var cs = caption_style;
        cs.color = caption_color;
        ui.text(c, result_caption, cs);
    }
}

fn historyBody(p: *Palette, c: *ui.Context) !void {
    const k = &p.calc;
    if (k.history.items.len == 0) {
        const box = ui.div(c).column().sizeFull().center().gap(4);
        defer box.end();
        ui.text(c, "Noch keine Rechnungen", .{ .size = 14, .color = theme.text });
        ui.text(
            c,
            "Ergebnisse dieser Sitzung erscheinen hier; sie liegen nur im Speicher.",
            .{ .size = 12, .color = theme.muted },
        );
        return;
    }
    const list = ui.div(c).column().wFull().grow().scrollY();
    defer list.end();
    section(c, "Zuletzt gerechnet");
    const now = p.now();
    for (k.history.items, 0..) |entry, i| {
        const subtitle = c.print("{s} · {s}", .{ entry.task, ago(c, now - entry.at_ms) });
        if (calculatorRow(c, p.selected == i, "=", try entry.answer.shown(c.alloc()), subtitle)) {
            p.selected = i;
            _ = try copySelected(p, .shown);
        }
    }
}

fn sheetBody(p: *Palette, c: *ui.Context) !void {
    const s = p.calc.sheet.?;
    {
        const lines_id = c.peekId(null);
        if (p.selected < s.lines.len) {
            const top = @as(f32, @floatFromInt(p.selected)) * sheet_row_height;
            const offset = c.scroll.get(lines_id) orelse 0;
            const view_h = if (c.rects.get(lines_id)) |r| r.h else 4 * sheet_row_height;
            if (top < offset) {
                c.scroll.put(c.gpa, lines_id, top) catch |e| log.warn("Tabelle: Scrollposition verloren: {t}", .{e});
            } else if (top + sheet_row_height > offset + view_h) {
                c.scroll.put(c.gpa, lines_id, top + sheet_row_height - view_h) catch |e|
                    log.warn("Tabelle: Scrollposition verloren: {t}", .{e});
            }
        }
        const lines = ui.div(c).column().wFull().grow().py(6).scrollY();
        defer lines.end();
        for (s.lines, 0..) |line, i| {
            const row = ui.div(c).row().wFull().h(sheet_row_height).px(18).gap(14).itemsCenter().control();
            defer row.end();
            const selected = p.selected == i;
            if (selected) _ = row.bg(theme.selection) else _ = row.hover(theme.surface);
            if (row.clicked()) {
                p.selected = i;
                _ = try copySelected(p, .shown);
            }
            {
                const num = ui.div(c).w(16).row().justifyEnd();
                defer num.end();
                ui.text(c, c.print("{d}", .{i + 1}), .{ .size = 11, .color = theme.placeholder });
            }
            {
                const t = ui.div(c).grow().minW(0);
                defer t.end();
                ui.text(c, line.text, .{ .size = 13, .color = theme.text, .truncate = .ellipsis });
            }
            if (line.answer) |ans| {
                ui.text(c, try ans.shown(c.alloc()), .{ .size = 13, .weight = .medium, .color = theme.text });
            } else ui.text(c, "ohne Zahl", .{ .size = 13, .weight = .medium, .color = theme.placeholder });
            if (selected) palette.selectionBar(c, 18, 6);
        }
    }
    const total = s.total orelse return;
    const a = c.alloc();
    const index = s.lines.len;
    ui.div(c).wFull().h(1).bg(theme.border).end();
    const row = ui.div(c).row().wFull().h(sheet_total_height).px(18).gap(12).itemsCenter().control();
    defer row.end();
    const selected = p.selected == index;
    if (selected) _ = row.bg(theme.selection);
    if (row.clicked()) {
        p.selected = index;
        _ = try copySelected(p, .shown);
    }
    {
        const col = ui.div(c).column().grow().minW(0).gap(1);
        defer col.end();
        ui.text(c, "Summe", .{ .size = 14.5, .line_height = 18, .weight = .semibold, .color = theme.text });
        const shownOf = struct {
            fn f(al: Allocator, ans: ?calc.Answer) []const u8 {
                const x = ans orelse return "";
                return x.shown(al) catch x.text;
            }
        }.f;
        const detail = c.print(
            "Mittel {s} · größte {s} · kleinste {s}",
            .{ shownOf(a, s.mean), shownOf(a, s.largest), shownOf(a, s.smallest) },
        );
        ui.text(c, detail, .{ .size = 11, .line_height = 14, .color = theme.muted, .truncate = .ellipsis });
    }
    ui.text(c, try total.shown(a), .{ .size = 22, .line_height = 28, .weight = .semibold, .color = theme.text });
    if (selected) palette.selectionBar(c, 18, 15);
}

fn taskCaption(c: *ui.Context, calculation: calc.Calculation) []const u8 {
    const skipped = calculation.skipped;
    if (skipped.len > 0) {
        var list: std.ArrayList(u8) = .empty;
        const a = c.alloc();
        for (skipped, 0..) |word, i| {
            const sep = if (i == 0) "" else if (i == skipped.len - 1) " und " else ", ";
            list.print(a, "{s}„{s}“", .{ sep, word }) catch return "";
        }
        return c.print("gelesen als · {s} übergangen", .{list.items});
    }
    if (calculation.thousands_dot) return "Punkt trennt Tausender, deutsch";
    return "Aufgabe";
}

fn resultCaption(calculation: calc.Calculation, ans: calc.Answer) []const u8 {
    if (ans.rounding) |r| return switch (r) {
        .significant => std.fmt.comptimePrint("auf {d} gültige Stellen gerundet", .{calc.significant_digits}),
        .cents => "auf Cent gerundet",
        .hundredths => "auf zwei Nachkommastellen gerundet",
    };
    if (calculation.conversion == .decimal_data) return "dezimal, wie der Finder zählt";
    return "Ergebnis";
}

/// Text, caption and whether the warning colour applies. Unfinished tasks
/// stay calm: nothing is wrong while typing.
fn problemText(c: *ui.Context, problem: calc.Problem) struct { text: []const u8, caption: []const u8, warns: bool } {
    return switch (problem) {
        .incomplete => |gap| switch (gap) {
            .number => |after| .{
                .text = "…",
                .caption = if (after.len == 0) "es fehlt eine Zahl" else c.print(
                    "es fehlt eine Zahl nach {s}",
                    .{after},
                ),
                .warns = false,
            },
            .closing_parenthesis => .{ .text = "…", .caption = "eine Klammer ist noch offen", .warns = false },
            .unit => .{ .text = "…", .caption = "es fehlt die Einheit nach „in“", .warns = false },
        },
        .division_by_zero => .{ .text = "nicht definiert", .caption = "Division durch null", .warns = true },
        .not_real => .{
            .text = "keine reelle Zahl",
            .caption = "zum Beispiel die Wurzel einer negativen Zahl",
            .warns = true,
        },
        .incompatible => .{
            .text = "passt nicht",
            .caption = "die Einheiten lassen sich nicht ineinander umrechnen",
            .warns = true,
        },
        .no_rates => .{ .text = "kein Kurs", .caption = "Kurse bräuchten das Netz", .warns = false },
        .too_slow => .{
            .text = "zu aufwendig",
            .caption = "die Rechnung dauert länger, als die Palette wartet",
            .warns = false,
        },
        .unreadable => .{ .text = "nicht lesbar", .caption = "Zugriff versteht diese Aufgabe nicht", .warns = false },
    };
}

fn alternativesTitle(alts: []const calc.Alternative) []const u8 {
    var binary = true;
    var decimal_point = true;
    for (alts) |alt| {
        binary = binary and alt.kind == .binary;
        decimal_point = decimal_point and alt.kind == .decimal_point;
    }
    if (binary) return "Auch in";
    if (decimal_point) return "Andere Lesart";
    return "Auch möglich";
}

fn alternativeSubtitle(c: *ui.Context, alt: calc.Alternative) []const u8 {
    const task = alt.task;
    return switch (alt.kind) {
        .share => |surcharge| c.print("{s} · {s}", .{ task, if (surcharge) "nur der Aufschlag" else "nur der Abzug" }),
        .before => |surcharge| c.print(
            "{s} · {s}",
            .{ task, if (surcharge) "wenn der Aufschlag schon drin ist" else "wenn der Abzug schon abgezogen ist" },
        ),
        .decimal_point => c.print("gelesen als {s} · Punkt als Dezimalzeichen, englisch", .{task}),
        .binary => |unit| c.print("binär · 1 {s} = {s} Byte", .{ unit, binaryBytes(unit) }),
    };
}

fn binaryBytes(unit: []const u8) []const u8 {
    if (std.mem.eql(u8, unit, "KiB")) return "1.024";
    if (std.mem.eql(u8, unit, "MiB")) return "1.048.576";
    if (std.mem.eql(u8, unit, "GiB")) return "1.073.741.824";
    return "1.099.511.627.776";
}

pub fn section(c: *ui.Context, title: []const u8) void {
    const box = ui.div(c).wFull().px(16).pt(8).pb(2);
    defer box.end();
    ui.text(c, title, .{ .size = 11, .color = theme.placeholder });
}

fn formatRow(c: *ui.Context, value: []const u8, label: []const u8, key: []const u8) void {
    const row = ui.div(c).row().wFull().h(format_row_height).px(16).gap(12).itemsCenter();
    defer row.end();
    {
        const v = ui.div(c).grow().minW(0);
        defer v.end();
        ui.text(c, value, .{ .size = 13, .color = theme.text, .truncate = .ellipsis });
    }
    ui.text(c, label, .{ .size = 11, .color = theme.placeholder });
    const k = ui.div(c).w(22).row().justifyEnd();
    defer k.end();
    ui.text(c, key, .{ .size = 11, .weight = .medium, .color = theme.muted });
}

/// A 44 px row like an app hit, with a symbol tile instead of an icon.
/// True when it was clicked.
fn calculatorRow(c: *ui.Context, selected: bool, symbol: []const u8, title: []const u8, subtitle: []const u8) bool {
    const row = ui.div(c).row().wFull().h(theme.row_height).px(16).gap(12).itemsCenter().control();
    defer row.end();
    if (selected) _ = row.bg(theme.selection) else _ = row.hover(theme.surface);
    const clicked = row.clicked();
    {
        const tile = ui.div(c).size(theme.row_icon_size, theme.row_icon_size).rounded(7).center();
        defer tile.end();
        _ = tile.bg(if (selected) theme.selection_overlay else theme.surface);
        ui.text(c, symbol, .{ .size = 15, .weight = .semibold, .color = if (selected) theme.accent else theme.muted });
    }
    {
        const col = ui.div(c).column().grow().minW(0).gap(1);
        defer col.end();
        ui.text(c, title, .{ .size = 14.5, .line_height = 18, .color = theme.text, .truncate = .ellipsis });
        ui.text(c, subtitle, .{ .size = 11, .line_height = 14, .color = theme.muted, .truncate = .ellipsis });
    }
    if (selected) palette.selectionBar(c, 16, 11);
    return clicked;
}
