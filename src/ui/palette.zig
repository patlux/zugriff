//! The launcher view: a search field, the ranked results and the selection,
//! with the calculator (`calc_view.zig`) and the emoji picker
//! (`emoji_view.zig`) in the same panel.
//!
//! The palette owns the query, the rows and what is selected. It never
//! launches, copies or hides anything itself: it emits an `Event`, and the
//! agent (or a test) decides.
const std = @import("std");
const Allocator = std.mem.Allocator;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("../core.zig");
const theme = @import("theme.zig");
const calc_view = @import("calc_view.zig");
const emoji_view = @import("emoji_view.zig");
const Glyphs = @import("glyphs.zig").Glyphs;

/// The picture atlas starts at 512² (1 MB) instead of nanoui's 2048²
/// (16 MB); nanoui doubles it when one frame needs more, as the emoji grid
/// does. Set before the window's first picture is packed, also in a window
/// made again after an unload. Decoded copies beyond 4 MB are dropped; they
/// come back on demand.
fn limitPictures(c: *ui.Context) void {
    const im = &c.text.images;
    if (im.generation != 0) return;
    im.side = 512;
    im.limits.decoded_bytes = 4 * 1024 * 1024;
}

/// Emoji pictures cached while the palette is open (16 KB each): at most
/// `glyphs_max`, trimmed to `glyphs_kept`; `glyphs_kept_closed` stay while
/// it is closed. A dropped one costs about 0,15 ms to draw again.
const glyphs_max = 256;
const glyphs_kept = 192;
const glyphs_kept_closed = 96;
const Action = core.Action;
const Item = core.Item;
const Catalog = core.Catalog;
const SearchHit = core.SearchHit;
const S = ui.Shortcut;
/// nanoui's plain keys (`input.key`), as tests and hosts without an input method send them.
const Key = @typeInfo(@FieldType(@FieldType(ui.Context, "input"), "key")).optional.child;

pub const search_placeholder = "Apps suchen …";
const search_icon = @embedFile("assets/search.svg");
/// The glyph on the tile of the "Emoji" row.
const emoji_command_glyph = "😀";
/// Shown between the lines of a pasted block.
const block_separator = " ⏎ ";

pub const InsertSupport = emoji_view.InsertSupport;

pub const Event = union(enum) {
    dismiss,
    activate: Action,
    /// Put this text on the clipboard and close: a result or an emoji.
    copy: []const u8,
    /// Close and insert this text into the app in front: an emoji.
    insert: []const u8,
    /// Ask macOS for the Accessibility permission that inserting needs.
    request_insert_permission,
    /// The emoji preferences changed; persist them.
    emoji_prefs: core.emoji.Prefs,
    quit,
};

/// What the palette asks of whoever shows it: the agent, or a test.
pub const Host = struct {
    ctx: *anyopaque,
    /// Strings in the event are valid during the call.
    emit: *const fn (ctx: *anyopaque, e: Event) void,
    /// The clipboard's text for ⌘V, owned by the caller; null for none.
    clipboard: *const fn (ctx: *anyopaque, gpa: Allocator) ?[]u8,
    /// A monotonic clock in milliseconds.
    now_ms: *const fn (ctx: *anyopaque) i64,
    beep: *const fn (ctx: *anyopaque) void,
};

/// Where the next frame scrolls the list.
const Reveal = enum { none, top, selected };

pub const Palette = struct {
    gpa: Allocator,
    io: std.Io,
    home: ?[]const u8,
    host: Host,
    query: ui.TextBuffer = .{},
    /// The text the rows were computed for.
    seen: std.ArrayList(u8) = .empty,
    placeholder: []const u8 = search_placeholder,
    /// Lines pasted as one block; the field then only previews them.
    block: ?[][]u8 = null,
    /// Whether a paste with several lines becomes a block (the calculator
    /// adds them up) or one line (the emoji search).
    accepts_blocks: bool = true,
    /// The installed apps, with the icons rendered so far, and the commands.
    catalog: Catalog,
    /// The row a typed path or web address stands for; it replaces the
    /// search results while the query names exactly one target.
    direct: ?Catalog = null,
    results: []SearchHit = &.{},
    selected: usize = 0,
    reveal: Reveal = .none,
    loading: bool = true,
    calc: calc_view.Calculator,
    emoji: emoji_view.Picker = .{},
    /// Colour emoji, drawn once each.
    glyphs: Glyphs,
    /// For the strings of one frame's direct target detection.
    scratch: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, io: std.Io, home: ?[]const u8, host: Host) Palette {
        var p: Palette = .{
            .gpa = gpa,
            .io = io,
            .home = home,
            .host = host,
            .catalog = .empty(gpa),
            .calc = .init(gpa),
            .glyphs = .init(gpa),
            .scratch = .init(gpa),
        };
        p.query.focus();
        return p;
    }

    pub fn deinit(p: *Palette) void {
        p.query.deinit();
        p.seen.deinit(p.gpa);
        p.freeBlock();
        p.catalog.deinit();
        if (p.direct) |*d| d.deinit();
        p.gpa.free(p.results);
        p.calc.deinit();
        p.emoji.deinit(p.gpa);
        p.glyphs.deinit();
        p.scratch.deinit();
        p.* = undefined;
    }

    pub fn emit(p: *Palette, e: Event) void {
        p.host.emit(p.host.ctx, e);
    }

    pub fn beep(p: *Palette) void {
        p.host.beep(p.host.ctx);
    }

    pub fn now(p: *Palette) i64 {
        return p.host.now_ms(p.host.ctx);
    }

    pub fn text(p: *const Palette) []const u8 {
        return p.query.text();
    }

    // The agent's side.

    /// Takes the app list from a background scan; it is copied.
    ///
    /// The first list ends the loading state and applies the query typed so
    /// far. Later lists come from the rescan on every show; they replace the
    /// rows only when apps came, went or changed, and then keep the query,
    /// the calculator and the selected app. Returns whether anything changed.
    pub fn setCatalog(p: *Palette, apps: []const Item) !bool {
        var next = try withCommands(p.gpa, apps);
        errdefer next.deinit();
        if (p.loading) {
            p.loading = false;
            p.catalog.deinit();
            p.catalog = next;
            try p.refresh();
            return true;
        }
        if (p.catalog.sameItems(next)) {
            next.deinit();
            return false;
        }
        try p.replaceAppRows(next);
        return true;
    }

    /// Searches a newer app list with the query on screen. Unlike typing,
    /// this leaves the calculator, a typed target and the selected app
    /// alone: the list may arrive while the user is about to press Enter.
    fn replaceAppRows(p: *Palette, next: Catalog) !void {
        const kept: ?Action = if (p.selectedItem()) |it| it.action else null;
        var old = p.catalog;
        p.catalog = next;
        defer old.deinit();
        // A typed target, the history, a sheet and the emoji picker list no apps.
        if (p.direct != null or !p.calc.listsApps() or p.emoji.active()) return;

        const query = try core.Query.init(p.gpa, p.text());
        defer query.deinit(p.gpa);
        p.setResults(try p.search(query));
        // A selected calculator row stays where it is.
        const offset = p.hitOffset();
        if (p.selected >= offset) {
            p.selected = offset;
            if (kept) |action| for (p.results, 0..) |hit, i| {
                if (p.catalog.items[hit.index].action.eql(action)) {
                    p.selected = offset + i;
                    break;
                }
            };
        }
        p.reveal = .selected;
    }

    /// Attaches a rendered icon to its app, by bundle path, unless the app
    /// has one already. The icons go into the app list itself, so the next
    /// show keeps them. Returns whether a row changed.
    pub fn setIcon(p: *Palette, app: []const u8, icon: core.Icon) !bool {
        for (p.catalog.items, 0..) |it, i| {
            if (it.icon != null) continue;
            switch (it.action) {
                .launch_application => |path| if (std.mem.eql(u8, path, app)) {
                    try p.catalog.setIcon(i, icon);
                    return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// App bundles that still use their monogram tile, in catalog order;
    /// the slice is the caller's, the paths stay the catalog's.
    pub fn pendingIcons(p: *const Palette, gpa: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (p.catalog.items) |it| if (it.icon == null) switch (it.action) {
            .launch_application => |path| try out.append(gpa, path),
            else => {},
        };
        return out.toOwnedSlice(gpa);
    }

    pub fn resultCount(p: *const Palette) usize {
        return p.results.len;
    }

    /// Clears the query, resets the selection, and scrolls back to the top.
    pub fn reset(p: *Palette) !void {
        emoji_view.leave(p);
        p.calc.clearView();
        p.freeBlock();
        p.query.clear();
        try p.refresh();
        p.selected = 0;
        p.reveal = .top;
    }

    /// The panel was closed to free memory; its window and caches go.
    pub fn unloaded(p: *Palette) void {
        p.glyphs.trim(0);
    }

    /// The panel is closing. A result on screen goes into the history.
    pub fn closed(p: *Palette, now_ms: i64) !void {
        // The emoji the next open shows first are among the recent ones.
        p.glyphs.trim(glyphs_kept_closed);
        try p.calc.closed(now_ms);
    }

    /// Gets the palette ready to show: a fresh search, or the last
    /// calculation if it closed a moment ago. Neither calculates anything.
    pub fn prepareShow(p: *Palette, now_ms: i64) !void {
        p.query.focus();
        if (!p.calc.restore(now_ms)) return p.reset();
        p.selected = 0;
        // Typing replaces the task, an arrow key keeps it to calculate on.
        p.query.want_selection = .{ 0, p.text().len };
    }

    pub const showEmoji = emoji_view.showFromHotkey;
    pub const showingEmoji = emoji_view.showing;
    pub const setEmojiPrefs = emoji_view.setPrefs;
    pub const setInsertSupport = emoji_view.setSupport;

    // State.

    /// Replaces the query and puts the caret at its end, as a completion
    /// does; the rows follow.
    pub fn setQuery(p: *Palette, s: []const u8) !void {
        const copy = try p.gpa.dupe(u8, s);
        defer p.gpa.free(copy);
        p.freeBlock();
        p.query.set(copy);
        try p.refresh();
    }

    fn freeBlock(p: *Palette) void {
        const lines = p.block orelse return;
        for (lines) |l| p.gpa.free(l);
        p.gpa.free(lines);
        p.block = null;
    }

    pub fn setResults(p: *Palette, hits: []SearchHit) void {
        p.gpa.free(p.results);
        p.results = hits;
    }

    /// Recomputes the rows for the query in the field.
    pub fn refresh(p: *Palette) !void {
        p.seen.clearRetainingCapacity();
        try p.seen.appendSlice(p.gpa, p.text());
        const raw = p.seen.items;
        p.calc.clearView();

        // The emoji picker, open or opened by a leading `:`.
        if (try emoji_view.refresh(p, raw)) return;

        // Several pasted lines are a sheet: each line on its own, then the sum.
        if (p.block) |lines| {
            p.clearDirect();
            p.setResults(&.{});
            try p.calc.showSheet(lines);
            p.selected = p.calc.rowCount() -| 1;
            p.reveal = .selected;
            return;
        }

        // A path or link names one row; searching the apps for it would only
        // add noise.
        _ = p.scratch.reset(.retain_capacity);
        if (try core.DirectTarget.detect(p.scratch.allocator(), p.io, p.home, raw)) |target| {
            try p.showDirect(target);
            return;
        }
        p.clearDirect();

        // `=` alone lists the last calculations instead of searching.
        if (try p.calc.refresh(raw)) {
            p.setResults(&.{});
        } else {
            const query = try core.Query.init(p.gpa, raw);
            defer query.deinit(p.gpa);
            p.setResults(try p.search(query));
        }
        p.selected = 0;
        p.reveal = .top;
    }

    fn clearDirect(p: *Palette) void {
        if (p.direct) |*d| d.deinit();
        p.direct = null;
    }

    fn showDirect(p: *Palette, target: core.DirectTarget) !void {
        const it: Item = switch (target) {
            .path => |path| .{
                .title = std.Io.Dir.path.basename(path),
                .subtitle = path,
                .action = .{ .open_path = path },
            },
            .url => |url| .{ .title = url, .subtitle = "Im Browser öffnen", .action = .{ .open_url = url } },
        };
        p.clearDirect();
        p.direct = try Catalog.init(p.gpa, &.{it});
        const hits = try p.gpa.alloc(SearchHit, 1);
        hits[0] = .{ .index = 0, .score = 0 };
        p.setResults(hits);
        p.selected = 0;
        p.reveal = .top;
    }

    /// Searches the apps and commands. Commands only answer a query: the
    /// empty search lists the apps alone.
    fn search(p: *Palette, query: core.Query) ![]SearchHit {
        const hits = try p.catalog.search(p.gpa, query);
        if (!query.isEmpty()) return hits;
        var n: usize = 0;
        for (hits) |h| if (!p.catalog.items[h.index].action.isCommand()) {
            hits[n] = h;
            n += 1;
        };
        return p.gpa.realloc(hits, n);
    }

    /// The rows the selection points into: the direct target while one is
    /// typed, otherwise the app list.
    pub fn visibleCatalog(p: *const Palette) *const Catalog {
        return if (p.direct) |*d| d else &p.catalog;
    }

    /// Rows before the first app hit: the calculator's.
    pub fn hitOffset(p: *const Palette) usize {
        return p.calc.rowCount();
    }

    fn rowCount(p: *const Palette) usize {
        return p.hitOffset() + p.results.len;
    }

    fn selectedItem(p: *const Palette) ?Item {
        const i = std.math.sub(usize, p.selected, p.hitOffset()) catch return null;
        if (i >= p.results.len) return null;
        return p.visibleCatalog().items[p.results[i].index];
    }

    // Keys.

    fn moveUp(p: *Palette) void {
        if (p.emoji.active()) return emoji_view.vertical(p, false);
        if (p.selected == 0) return;
        p.selected -= 1;
        p.reveal = .selected;
    }

    fn moveDown(p: *Palette) void {
        if (p.emoji.active()) return emoji_view.vertical(p, true);
        if (p.selected + 1 >= p.rowCount()) return;
        p.selected += 1;
        p.reveal = .selected;
    }

    fn confirm(p: *Palette, with_task: bool) !void {
        if (p.emoji.active()) return emoji_view.confirm(p);
        if (with_task) {
            if (!try calc_view.copySelected(p, .with_task)) p.beep();
            return;
        }
        if (!try calc_view.confirm(p)) p.activateSelected();
    }

    fn revealSelected(p: *Palette) !void {
        if (p.emoji.active()) return emoji_view.copy(p);
        if (try calc_view.editHistoryEntry(p)) return;
        const it = p.selectedItem() orelse return;
        // A web address and a command have nothing to reveal in Finder.
        const path = it.action.path() orelse return;
        p.emit(.{ .activate = .{ .reveal_path = path } });
    }

    fn escape(p: *Palette) void {
        if (!emoji_view.escape(p)) p.emit(.dismiss);
    }

    fn backspaceOnEmpty(p: *Palette) !void {
        if (p.emoji.active()) return emoji_view.backspace(p);
        p.beep();
    }

    fn activateSelected(p: *Palette) void {
        const it = p.selectedItem() orelse return;
        if (it.action == .open_emoji_picker) return emoji_view.openFromSearch(p) catch p.beep();
        p.emit(.{ .activate = it.action });
    }

    fn activate(p: *Palette, result: usize) void {
        p.selected = result + p.hitOffset();
        p.activateSelected();
    }

    /// Offered key combinations and plain keys, before the field sees them.
    fn keys(p: *Palette, c: *ui.Context) !void {
        if (c.input.shortcut) |s| {
            if (try p.shortcut(c, s)) {
                _ = c.shortcut(s);
                return;
            }
        }
        if (c.input.key) |k| if (try p.key(c, k)) {
            c.input.key = null;
            c.changed = true;
        };
        try p.ops(c);
        // Typing or ⌫ dissolves a pasted block instead of editing its preview.
        if (p.block != null and (c.input.chars.len > 0 or hasTextOp(c))) {
            p.freeBlock();
            p.query.clear();
        }
    }

    fn shortcut(p: *Palette, c: *ui.Context, s: S) !bool {
        // Escape closes whatever modifiers are still held from the hot key.
        if (s.key == S.escape) {
            p.escape();
            return true;
        }
        const plain = !s.cmd and !s.ctrl and !s.alt and !s.shift;
        if (s.cmd and !s.ctrl and !s.alt and !s.shift) {
            switch (s.key) {
                'q' => {
                    p.emit(.quit);
                    return true;
                },
                S.enter => {
                    try p.revealSelected();
                    return true;
                },
                'v' => return p.paste(c),
                '1'...'9' => return emoji_view.quickKey(p, s.key - '0'),
                else => {},
            }
        }
        if ((plain and s.key == S.up) or (s.ctrl and !s.cmd and !s.alt and s.key == 'p')) {
            p.moveUp();
            return true;
        }
        if ((plain and s.key == S.down) or (s.ctrl and !s.cmd and !s.alt and s.key == 'n')) {
            p.moveDown();
            return true;
        }
        if (s.alt and !s.cmd and !s.ctrl and !s.shift) switch (s.key) {
            S.enter => {
                if (!try calc_view.copySelected(p, .number)) p.beep();
                return true;
            },
            S.left, S.right => {
                if (!p.emoji.active()) return false;
                emoji_view.jumpSection(p, s.key == S.right);
                return true;
            },
            else => {},
        };
        if (plain and s.key == S.tab) {
            if (!p.emoji.active()) return true;
            emoji_view.toggleTones(p);
            return true;
        }
        if (!s.cmd and !s.ctrl and !s.alt and s.shift and s.key == S.enter) {
            try p.confirm(true);
            return true;
        }
        return false;
    }

    /// Keys as tests and other hosts without an input method send them.
    fn key(p: *Palette, c: *ui.Context, k: Key) !bool {
        const mods = c.input.cmd or c.input.ctrl or c.input.alt;
        switch (k) {
            .escape => p.escape(),
            .enter => {
                if (c.input.cmd) try p.revealSelected() else if (c.input.alt) {
                    if (!try calc_view.copySelected(p, .number)) p.beep();
                } else try p.confirm(c.input.shift);
            },
            .up => p.moveUp(),
            .down => p.moveDown(),
            .tab => if (p.emoji.active()) emoji_view.toggleTones(p),
            .left, .right => {
                if (!p.emoji.active() or c.input.shift) return false;
                if (c.input.alt) emoji_view.jumpSection(p, k == .right) else if (!mods) emoji_view.step(
                    p,
                    k == .right,
                ) else return false;
            },
            .backspace => {
                if (p.text().len > 0 or p.block != null) return false;
                try p.backspaceOnEmpty();
            },
            else => return false,
        }
        return true;
    }

    /// The input method's commands: Return, ← and → in the emoji grid, ⌫ in
    /// an empty field.
    fn ops(p: *Palette, c: *ui.Context) !void {
        if (c.input.ops.len == 0) return;
        var kept: std.ArrayList(ui.TextOp) = .empty;
        var changed = false;
        for (c.input.ops) |op| {
            const taken = switch (op) {
                .command => |cmd| switch (cmd) {
                    .insert_newline, .insert_line_break => blk: {
                        try p.confirm(c.input.shift);
                        break :blk true;
                    },
                    .move_left, .move_right => blk: {
                        if (!p.emoji.active()) break :blk false;
                        emoji_view.step(p, cmd == .move_right);
                        break :blk true;
                    },
                    .delete_backward => blk: {
                        if (p.text().len > 0 or p.block != null) break :blk false;
                        try p.backspaceOnEmpty();
                        break :blk true;
                    },
                    else => false,
                },
                else => false,
            };
            if (taken) changed = true else try kept.append(c.alloc(), op);
        }
        if (changed) {
            c.input.ops = kept.items;
            c.changed = true;
        }
    }

    fn hasTextOp(c: *ui.Context) bool {
        for (c.input.ops) |op| switch (op) {
            .insert, .set_marked => return true,
            .command => |cmd| if (cmd == .delete_backward or cmd == .delete_forward) return true,
            else => {},
        };
        if (c.input.key) |k| if (k == .backspace or k == .delete) return true;
        return false;
    }

    /// ⌘V: several lines become a block, one line goes into the field.
    fn paste(p: *Palette, c: *ui.Context) !bool {
        const raw = p.host.clipboard(p.host.ctx, p.gpa) orelse return true;
        defer p.gpa.free(raw);
        var lines: std.ArrayList([]u8) = .empty;
        defer {
            for (lines.items) |l| p.gpa.free(l);
            lines.deinit(p.gpa);
        }
        var it = std.mem.splitAny(u8, raw, "\r\n");
        while (it.next()) |line| {
            const t = core.text.trim(line);
            if (t.len > 0) try lines.append(p.gpa, try p.gpa.dupe(u8, t));
        }
        if (p.accepts_blocks and lines.items.len > 1) {
            const preview = try std.mem.join(p.gpa, block_separator, lines.items);
            defer p.gpa.free(preview);
            p.freeBlock();
            p.query.set(preview);
            p.block = try lines.toOwnedSlice(p.gpa);
            try p.refresh();
            return true;
        }
        // One line: typed into the field at the caret, as a paste would be.
        const joined = try std.mem.join(c.alloc(), " ", lines.items);
        const op = try c.alloc().alloc(ui.TextOp, 1);
        op[0] = .{ .insert = joined };
        c.input.ops = op;
        return true;
    }

    // The view.

    pub fn view(p: *Palette, c: *ui.Context) void {
        p.build(c) catch |e| std.log.err("Palette: {t}", .{e});
    }

    fn build(p: *Palette, c: *ui.Context) !void {
        // Between frames: nanoui painted the last one, this one draws nothing yet.
        if (p.glyphs.count() > glyphs_max) p.glyphs.trim(glyphs_kept);
        limitPictures(c);
        try p.keys(c);
        const root = ui.div(c).column().sizeFull().bg(theme.background);
        defer root.end();
        try p.header(c);
        try p.body(c);
        p.footer(c);
    }

    fn header(p: *Palette, c: *ui.Context) !void {
        const bar = ui.div(c).row().wFull().h(theme.header_height).px(16).gap(12).itemsCenter().bg(theme.surface);
        {
            defer bar.end();
            _ = ui.svg(c, .{ .key = "zugriff.search", .bytes = search_icon, .size = 18, .color = theme.muted });
            if (p.headerLabel(c)) |label| {
                const chip = ui.div(c).px(8).py(3).rounded(6).bg(theme.selection_overlay);
                defer chip.end();
                ui.text(c, label, .{ .size = 13, .color = theme.accent });
            }
            ui.key(c, "zugriff.query");
            _ = ui.textField(c, &p.query, .{
                .placeholder = p.placeholder,
                .placeholder_color = theme.placeholder,
                .color = theme.text,
                .caret_color = theme.accent,
                .size = 18,
                .width = .fill,
                .bare = true,
            });
            if (!std.mem.eql(u8, p.seen.items, p.text())) {
                try p.refresh();
                c.changed = true;
            }
        }
        ui.div(c).wFull().h(1).bg(theme.border).end();
    }

    fn headerLabel(p: *Palette, c: *ui.Context) ?[]const u8 {
        if (p.emoji.active()) return "Emoji";
        return calc_view.headerLabel(p, c);
    }

    fn body(p: *Palette, c: *ui.Context) !void {
        const box = ui.div(c).column().wFull().grow().clip();
        defer box.end();
        if (p.emoji.active()) return emoji_view.body(p, c);
        if (p.calc.hasBody()) return calc_view.body(p, c);
        if (p.results.len == 0) return p.emptyState(c);
        p.hitList(c);
    }

    /// The app hits, virtualized: only the rows in view are built.
    pub fn hitList(p: *Palette, c: *ui.Context) void {
        const list_id = c.peekId(null);
        var scroll_to: ?f32 = null;
        switch (p.reveal) {
            .none => {},
            .top => scroll_to = 0,
            .selected => if (std.math.sub(usize, p.selected, p.hitOffset()) catch null) |i| {
                const top = @as(f32, @floatFromInt(i)) * theme.row_height;
                const offset = c.scroll.get(list_id) orelse 0;
                const view_h = if (c.rects.get(list_id)) |r| r.h else 4 * theme.row_height;
                const bottom = top + theme.row_height;
                if (top < offset) scroll_to = top else if (bottom > offset + view_h) scroll_to = bottom - view_h;
            },
        }
        p.reveal = .none;
        var rows = ui.list(c, .{ .count = p.results.len, .row_height = theme.row_height, .scroll_to = scroll_to });
        while (rows.next()) |i| p.hitRow(c, i);
        rows.end();
    }

    fn hitRow(p: *Palette, c: *ui.Context, index: usize) void {
        const it = p.visibleCatalog().items[p.results[index].index];
        const selected = p.selected == index + p.hitOffset();
        const row = ui.div(c).row().wFull().h(theme.row_height).px(16).gap(12).itemsCenter().control();
        defer row.end();
        if (selected) _ = row.bg(theme.selection) else _ = row.hover(theme.surface);
        if (row.clicked()) p.activate(index);
        if (it.action.isCommand()) commandTile(p, c, emoji_command_glyph) else iconTile(c, it);
        {
            const col = ui.div(c).column().grow().minW(0).gap(1);
            defer col.end();
            ui.text(c, it.title, .{ .size = 14.5, .line_height = 18, .color = theme.text, .truncate = .ellipsis });
            ui.text(c, it.subtitle, .{ .size = 11, .line_height = 14, .color = theme.muted, .truncate = .ellipsis });
        }
        if (selected) selectionBar(c, 16, 11);
    }

    fn emptyState(p: *Palette, c: *ui.Context) void {
        const box = ui.div(c).column().sizeFull().center().gap(4);
        defer box.end();
        if (p.loading) {
            ui.text(c, "Apps werden geladen …", .{ .size = 14, .color = theme.text });
            ui.text(c, "Die installierten Programme erscheinen gleich.", .{ .size = 12, .color = theme.muted });
        } else if (core.text.trim(p.text()).len == 0) {
            ui.text(c, "Keine Apps gefunden", .{ .size = 14, .color = theme.text });
            ui.text(c, "Die App-Liste ist leer.", .{ .size = 12, .color = theme.muted });
        } else {
            ui.text(c, "Keine Treffer", .{ .size = 14, .color = theme.text });
            ui.text(c, c.print("Nichts gefunden für „{s}“", .{p.text()}), .{ .size = 12, .color = theme.muted });
        }
    }

    fn footer(p: *Palette, c: *ui.Context) void {
        ui.div(c).wFull().h(1).bg(theme.border).end();
        const bar = ui.div(c).row().wFull().h(theme.footer_height).px(16).gap(12)
            .itemsCenter().justifyBetween().bg(theme.surface);
        defer bar.end();
        var hints_buf: [6][]const u8 = undefined;
        var hints: []const []const u8 = undefined;
        if (p.emoji.active()) {
            hints = emoji_view.footer(p, c, &hints_buf);
        } else if (calc_view.footer(p, c, &hints_buf)) |h| {
            hints = h;
        } else {
            ui.text(c, p.countLabel(c), .{ .size = 11, .color = theme.muted, .truncate = .ellipsis });
            hints = p.searchHints(&hints_buf);
        }
        const row = ui.div(c).row().gap(14).itemsCenter();
        defer row.end();
        for (hints) |h| ui.text(c, h, .{ .size = 11, .color = theme.muted });
    }

    fn countLabel(p: *Palette, c: *ui.Context) []const u8 {
        if (p.direct != null) return c.print("{d} Treffer", .{p.results.len});
        if (p.loading) return "Apps werden geladen …";
        if (core.text.trim(p.text()).len == 0) return c.print("{d} Apps", .{p.results.len});
        return c.print("{d} Treffer", .{p.results.len});
    }

    fn searchHints(p: *Palette, buf: *[6][]const u8) []const []const u8 {
        var n: usize = 0;
        buf[n] = "↑↓ Navigieren";
        n += 1;
        buf[n] = "↵ Öffnen";
        n += 1;
        // A direct row replaces the app list, so the footer may only
        // advertise what the selection can actually do.
        if (p.direct != null) if (p.selectedItem()) |it| if (it.action.path() != null) {
            buf[n] = "⌘↵ Finder";
            n += 1;
        };
        buf[n] = "esc Schließen";
        n += 1;
        return buf[0..n];
    }
};

/// The app list plus the palette's own commands, found by typing their name.
fn withCommands(gpa: Allocator, apps: []const Item) !Catalog {
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(gpa);
    for (apps) |it| if (!it.action.isCommand()) try items.append(gpa, it);
    try items.append(gpa, .{
        .title = "Emoji",
        .subtitle = "Emoji suchen und einfügen · ⌃⌘Leertaste",
        .keywords = &.{ "emoji", "emojis", "smiley", "smileys", "emoticon", "symbole" },
        .action = .open_emoji_picker,
    });
    return Catalog.init(gpa, items.items);
}

/// The 2-point accent bar at the left edge of a selected row; `pad_x` is
/// the row's own padding, which an absolute child starts after.
pub fn selectionBar(c: *ui.Context, pad_x: f32, inset: f32) void {
    ui.div(c).absolute().offset(-pad_x, inset).w(2).h(theme.row_height - 2 * inset).rounded(1).bg(theme.accent).end();
}

pub fn commandTile(p: *Palette, c: *ui.Context, glyph: []const u8) void {
    const tile = ui.div(c).size(theme.row_icon_size, theme.row_icon_size).rounded(7).bg(theme.surface).center();
    defer tile.end();
    p.glyphs.draw(c, glyph, 18);
}

fn iconTile(c: *ui.Context, it: Item) void {
    if (it.icon) |icon| {
        const box = ui.div(c).size(theme.row_icon_size, theme.row_icon_size).center();
        defer box.end();
        // An unreadable PNG falls back to the monogram.
        if (ui.image(
            c,
            .{
                .key = icon.path,
                .bytes = icon.png,
                .box = .{ .w = theme.row_icon_size, .h = theme.row_icon_size },
                .radius = 0,
            },
        )) return;
        return monogramText(c, it.title);
    }
    monogram(c, it.title);
}

fn monogram(c: *ui.Context, title: []const u8) void {
    const tile = ui.div(c).size(theme.row_icon_size, theme.row_icon_size).rounded(7).bg(monogramTint(title)).center();
    defer tile.end();
    monogramText(c, title);
}

fn monogramText(c: *ui.Context, title: []const u8) void {
    var it = core.text.iterate(title);
    _ = it.next();
    ui.text(c, title[0..it.offset()], .{ .size = 13, .weight = .semibold, .color = theme.text });
}

fn monogramTint(title: []const u8) ui.Color {
    var hash: u32 = 2_166_136_261;
    for (title) |b| {
        hash ^= b;
        hash *%= 16_777_619;
    }
    return theme.monogram_tints[hash % theme.monogram_tints.len];
}
