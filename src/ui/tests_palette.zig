//! The palette, driven like the panel is: keys, typing and paste, rendered
//! offscreen with ui.Tester. No window, no clipboard, no hot key.
const std = @import("std");
const testing = std.testing;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const S = ui.Shortcut;
const core = @import("../core.zig");
const theme = @import("theme.zig");
const palette_mod = @import("palette.zig");
const Palette = palette_mod.Palette;
const Event = palette_mod.Event;
const Item = core.Item;

pub const Recorded = union(enum) {
    dismiss,
    activate: core.Action,
    copy: []const u8,
    insert: []const u8,
    request_insert_permission,
    emoji_prefs: core.emoji.Prefs,
    help_seen,
    quit,
};

/// What the palette asked for, as the agent would see it.
pub const Fake = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(Recorded) = .empty,
    clipboard: ?[]const u8 = null,
    now: i64 = 1_000_000,
    beeps: usize = 0,

    fn emit(ctx: *anyopaque, e: Event) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        const a = f.arena.allocator();
        const r: Recorded = switch (e) {
            .dismiss => .dismiss,
            .activate => |act| .{ .activate = switch (act) {
                .launch_application => |s| .{ .launch_application = a.dupe(u8, s) catch unreachable },
                .open_path => |s| .{ .open_path = a.dupe(u8, s) catch unreachable },
                .open_url => |s| .{ .open_url = a.dupe(u8, s) catch unreachable },
                .reveal_path => |s| .{ .reveal_path = a.dupe(u8, s) catch unreachable },
                .open_emoji_picker => .open_emoji_picker,
                .open_help => .open_help,
            } },
            .copy => |t| .{ .copy = a.dupe(u8, t) catch unreachable },
            .insert => |t| .{ .insert = a.dupe(u8, t) catch unreachable },
            .request_insert_permission => .request_insert_permission,
            .emoji_prefs => |p| .{ .emoji_prefs = p },
            .help_seen => .help_seen,
            .quit => .quit,
        };
        f.events.append(a, r) catch unreachable;
    }

    fn readClipboard(ctx: *anyopaque, gpa: std.mem.Allocator) ?[]u8 {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        return gpa.dupe(u8, f.clipboard orelse return null) catch null;
    }

    fn nowMs(ctx: *anyopaque) i64 {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        return f.now;
    }

    fn beep(ctx: *anyopaque) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.beeps += 1;
    }

    pub fn host(f: *Fake) palette_mod.Host {
        return .{ .ctx = f, .emit = emit, .clipboard = readClipboard, .now_ms = nowMs, .beep = beep };
    }

    /// The events since the last call, then forgotten.
    pub fn take(f: *Fake) []const Recorded {
        const out = f.arena.allocator().dupe(Recorded, f.events.items) catch unreachable;
        f.events.clearRetainingCapacity();
        return out;
    }

    /// The text of the copies and insertions since the last call.
    pub fn output(f: *Fake) []const Recorded {
        var kept: std.ArrayList(Recorded) = .empty;
        for (f.take()) |e| switch (e) {
            .copy, .insert, .request_insert_permission => kept.append(f.arena.allocator(), e) catch unreachable,
            else => {},
        };
        return kept.items;
    }

    pub fn nextCopy(f: *Fake) ?[]const u8 {
        for (f.take()) |e| if (e == .copy) return e.copy;
        return null;
    }

    pub fn nextActivation(f: *Fake) ?core.Action {
        for (f.take()) |e| if (e == .activate) return e.activate;
        return null;
    }
};

/// What a test's calculation may take: far beyond any task of the tests.
pub const test_budget_ns: u64 = 5 * std.time.ns_per_s;

/// A palette with its tester and fake host, at the panel's size.
pub const Harness = struct {
    fake: Fake,
    palette: Palette,
    t: ui.Tester,

    pub fn init(h: *Harness, apps: []const Item) !void {
        return h.initIn(apps, .de);
    }

    /// A palette that speaks `lang`.
    pub fn initIn(h: *Harness, apps: []const Item, lang: core.Language) !void {
        h.fake = .{ .arena = .init(testing.allocator) };
        const home = std.mem.span(std.c.getenv("HOME").?);
        h.palette = .init(testing.allocator, testing.io, home, .both(lang), h.fake.host());
        // The palette's 10 ms are for a person typing; under a loaded test
        // run they would drop results at random.
        h.palette.calc.budget_ns = test_budget_ns;
        _ = try h.palette.setCatalog(apps);
        try h.t.init(
            testing.allocator,
            .init(&h.palette, Palette.view),
            .{ .width = 640, .height = 420, .theme = theme.window },
        );
    }

    pub fn deinit(h: *Harness) void {
        h.t.deinit();
        h.palette.deinit();
        h.fake.arena.deinit();
        h.* = undefined;
    }

    pub fn typeText(h: *Harness, s: []const u8) void {
        h.t.typeText(s);
    }

    pub fn key(h: *Harness, k: anytype) void {
        h.t.key(k);
    }

    pub fn chord(h: *Harness, s: S) void {
        _ = h.t.shortcut(s);
    }

    pub fn enter(h: *Harness) void {
        h.t.key(.enter);
    }

    pub fn down(h: *Harness) void {
        h.chord(.{ .key = S.down });
    }

    pub fn up(h: *Harness) void {
        h.chord(.{ .key = S.up });
    }

    /// Empties the field, as ⌘A ⌫ does.
    pub fn clear(h: *Harness) void {
        h.t.textOps(&.{.{ .command = .select_all }});
        h.t.key(.backspace);
    }

    pub fn paste(h: *Harness, s: []const u8) void {
        h.fake.clipboard = s;
        h.chord(.{ .key = 'v', .cmd = true });
    }

    pub fn query(h: *Harness) []const u8 {
        return h.palette.text();
    }

    /// Closes, lets `seconds` pass, and shows the palette again.
    pub fn reopenAfter(h: *Harness, seconds: i64) !void {
        try h.palette.closed(h.fake.now);
        h.fake.now += seconds * std.time.ms_per_s;
        try h.palette.prepareShow(h.fake.now);
        h.t.frame();
    }
};

pub fn app(title: []const u8) Item {
    return .{
        .title = title,
        .subtitle = "/Applications",
        .action = .{ .launch_application = testing.allocator.print(
            "/Applications/{s}.app",
            .{title},
        ) catch unreachable },
    };
}

/// Apps whose paths live until the test frees them.
pub const Apps = struct {
    items: []Item,

    pub fn init(titles: []const []const u8) Apps {
        const items = testing.allocator.alloc(Item, titles.len) catch unreachable;
        for (titles, items) |t, *it| it.* = app(t);
        return .{ .items = items };
    }

    pub fn deinit(a: Apps) void {
        for (a.items) |it| testing.allocator.free(it.action.launch_application);
        testing.allocator.free(a.items);
    }
};

fn expectLaunch(action: ?core.Action, title: []const u8) !void {
    var buf: [256]u8 = undefined;
    const want = try std.mem.print(&buf, "/Applications/{s}.app", .{title});
    try testing.expectEqualStrings(want, (action orelse return error.NoActivation).launch_application);
}

test "a typed app name opens the app" {
    const apps = Apps.init(&.{ "Zed", "Zoom" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    try testing.expectEqual(@as(usize, 2), h.palette.resultCount());
    h.typeText("zed");
    try testing.expectEqualStrings("zed", h.query());
    try testing.expectEqual(@as(usize, 1), h.palette.resultCount());
    h.enter();
    try expectLaunch(h.fake.nextActivation(), "Zed");
}

test "keys typed before the panel had the keyboard join the query" {
    const apps = Apps.init(&.{ "Zoom", "Zotero" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    try h.palette.typeAhead("zot");
    h.t.frame();
    h.typeText("e");
    try testing.expectEqualStrings("zote", h.palette.text());
    h.enter();
    try expectLaunch(h.fake.nextActivation(), "Zotero");
}

test "enter and escape pressed before the panel had the keyboard still act" {
    const apps = Apps.init(&.{ "Zoom", "Zotero" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    // No frame between the typed text and ↵: the press searches first.
    try h.palette.typeAhead("zo");
    try h.palette.pressAhead(.down, .{});
    try h.palette.pressAhead(.enter, .{});
    try expectLaunch(h.fake.nextActivation(), "Zotero");
    try h.palette.pressAhead(.escape, .{});
    try testing.expect(h.fake.take()[0] == .dismiss);
}

test "the arrows choose the app" {
    const apps = Apps.init(&.{ "Zoom", "Zotero" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    h.typeText("zo");
    h.down();
    h.enter();
    try expectLaunch(h.fake.nextActivation(), "Zotero");
    h.up();
    h.chord(.{ .key = 'n', .ctrl = true });
    h.chord(.{ .key = 'p', .ctrl = true });
    h.enter();
    try expectLaunch(h.fake.nextActivation(), "Zoom");
}

test "escape closes whatever modifiers are held" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.chord(.{ .key = S.escape, .shift = true });
    try testing.expect(h.fake.take()[0] == .dismiss);
    h.chord(.{ .key = S.escape });
    try testing.expect(h.fake.take()[0] == .dismiss);
    h.chord(.{ .key = 'q', .cmd = true });
    try testing.expect(h.fake.take()[0] == .quit);
}

test "tab and path-like queries stay in the app list" {
    const apps = Apps.init(&.{"Zed"});
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    h.chord(.{ .key = S.tab });
    try testing.expectEqualStrings("", h.query());
    h.typeText("~/gibt-es-nicht");
    try testing.expectEqual(@as(usize, 0), h.palette.resultCount());
    h.clear();
    h.typeText("zed");
    h.enter();
    try expectLaunch(h.fake.nextActivation(), "Zed");
}

test "the emoji row answers its names and opens the picker" {
    const apps = Apps.init(&.{ "Zed", "Zoom" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    for ([_][]const u8{ "emo", "smiley" }) |q| {
        h.typeText(q);
        const first = h.palette.catalog.items[h.palette.results[0].index];
        try testing.expectEqualStrings("Emoji", first.title);
        h.clear();
    }
    h.typeText("emoji");
    try testing.expectEqual(@as(usize, 1), h.palette.resultCount());
    h.enter();
    try testing.expect(h.palette.showingEmoji());
    try testing.expectEqualStrings("", h.query());
    try testing.expect(h.fake.nextActivation() == null);
    h.key(.backspace);
    try testing.expect(!h.palette.showingEmoji());
}

test "the empty search lists no commands" {
    const apps = Apps.init(&.{ "Zed", "Zoom" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    try testing.expectEqual(@as(usize, 2), h.palette.resultCount());
    const pending = try h.palette.pendingIcons(testing.allocator);
    defer testing.allocator.free(pending);
    try testing.expectEqual(@as(usize, 2), pending.len);
}

test "a typed path opens the file and can be revealed" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    const dir = "/tmp/zugriff-palette-path";
    try std.Io.Dir.cwd().createDirPath(testing.io, "/private" ++ dir);
    defer std.Io.Dir.cwd().deleteTree(testing.io, "/private" ++ dir) catch {};
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = dir ++ "/notiz.txt", .data = "zugriff" });
    h.typeText(dir ++ "/notiz.txt");
    try testing.expect(h.t.hasText("notiz.txt"));
    h.chord(.{ .key = S.enter, .cmd = true });
    try testing.expectEqualStrings(dir ++ "/notiz.txt", h.fake.nextActivation().?.reveal_path);
    h.enter();
    try testing.expectEqualStrings(dir ++ "/notiz.txt", h.fake.nextActivation().?.open_path);
}

test "a typed web address opens the browser and cannot be revealed" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.typeText("https://example.com/zugriff");
    h.chord(.{ .key = S.enter, .cmd = true });
    try testing.expect(h.fake.nextActivation() == null);
    h.enter();
    try testing.expectEqualStrings("https://example.com/zugriff", h.fake.nextActivation().?.open_url);
}

test "a newer app list keeps the query and the selection" {
    const first = Apps.init(&.{ "Zoom", "Zotero" });
    defer first.deinit();
    const second = Apps.init(&.{ "Zed", "Zoho Mail", "Zoom", "Zotero" });
    defer second.deinit();
    var h: Harness = undefined;
    try h.init(first.items);
    defer h.deinit();
    h.typeText("zo");
    h.down();
    try testing.expect(try h.palette.setCatalog(second.items));
    h.t.frame();
    try testing.expectEqual(@as(usize, 3), h.palette.resultCount());
    h.enter();
    try expectLaunch(h.fake.nextActivation(), "Zotero");
}

test "the same app list changes nothing" {
    const apps = Apps.init(&.{ "Zoom", "Zotero" });
    defer apps.deinit();
    const again = Apps.init(&.{ "Zoom", "Zotero" });
    defer again.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    h.typeText("zo");
    h.down();
    try testing.expect(!try h.palette.setCatalog(again.items));
    h.enter();
    try expectLaunch(h.fake.nextActivation(), "Zotero");
}

test "a newer app list leaves the calculation alone" {
    const apps = Apps.init(&.{"Zoom"});
    defer apps.deinit();
    const more = Apps.init(&.{ "Zed", "Zoom" });
    defer more.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    h.typeText("80 + 19 %");
    try testing.expect(try h.palette.setCatalog(more.items));
    h.enter();
    try testing.expectEqualStrings("95,2", h.fake.nextCopy().?);
}

test "rendered icons stay and find their app after a newer list" {
    const apps = Apps.init(&.{ "Arc", "Zed" });
    defer apps.deinit();
    const more = Apps.init(&.{ "Arc", "Bear", "Zed" });
    defer more.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    const pending = try h.palette.pendingIcons(testing.allocator);
    defer testing.allocator.free(pending);
    const zed = try testing.allocator.dupe(u8, pending[1]);
    defer testing.allocator.free(zed);
    try testing.expect(try h.palette.setIcon(zed, .{ .path = "/tmp/zed.png", .png = "png" }));
    try h.reopenAfter(1);
    const still = try h.palette.pendingIcons(testing.allocator);
    defer testing.allocator.free(still);
    try testing.expectEqual(@as(usize, 1), still.len);
    try testing.expectEqualStrings("/Applications/Arc.app", still[0]);

    _ = try h.palette.setCatalog(more.items);
    var icons: [3]?[]const u8 = undefined;
    var n: usize = 0;
    for (h.palette.catalog.items) |it| if (!it.action.isCommand()) {
        icons[n] = if (it.icon) |i| i.path else null;
        n += 1;
    };
    // The newer list has no icons of its own: Zed's comes again from the
    // cache in the agent; here the palette asks for it.
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(try h.palette.setIcon(zed, .{ .path = "/tmp/zed.png", .png = "png" }));
    try testing.expectEqualStrings("/tmp/zed.png", h.palette.catalog.items[2].icon.?.path);
    try testing.expect(h.palette.catalog.items[1].icon == null);
}

test "a typed task copies its result in three formats" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.typeText("(1.299 + 89,90) × 3");
    h.enter();
    try testing.expectEqualStrings("4.166,70", h.fake.nextCopy().?);
    h.chord(.{ .key = S.enter, .alt = true });
    try testing.expectEqualStrings("4166.70", h.fake.nextCopy().?);
    h.chord(.{ .key = S.enter, .shift = true });
    try testing.expectEqualStrings("(1.299 + 89,90) × 3 = 4.166,70", h.fake.nextCopy().?);
}

test "a pasted task offers the other percent readings" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.paste("Netto 1.299,00 € zzgl. 19 % MwSt.");
    try testing.expectEqualStrings("Netto 1.299,00 € zzgl. 19 % MwSt.", h.query());
    h.enter();
    try testing.expectEqualStrings("1.545,81 €", h.fake.nextCopy().?);
    h.down();
    h.enter();
    try testing.expectEqualStrings("246,81 €", h.fake.nextCopy().?);
    h.down();
    h.chord(.{ .key = S.enter, .shift = true });
    try testing.expectEqualStrings("1.299,00 € / 1,19 ≈ 1.091,60 €", h.fake.nextCopy().?);
}

test "an unfinished task copies nothing" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.typeText("(1.299 + 89,90) ×");
    h.enter();
    h.chord(.{ .key = S.enter, .alt = true });
    try testing.expect(h.fake.nextCopy() == null);
    try testing.expect(h.fake.beeps >= 1);
    try testing.expect(h.t.containsText("es fehlt eine Zahl nach ×"));
}

test "a search term still searches apps" {
    const apps = Apps.init(&.{ "App 0", "App 1", "App 2" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    h.typeText("App 1");
    try testing.expectEqual(@as(usize, 0), h.palette.hitOffset());
    h.enter();
    try expectLaunch(h.fake.nextActivation(), "App 1");
}

test "reopening shortly shows the last calculation" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.typeText("12 * 3");
    try h.reopenAfter(10);
    try testing.expectEqualStrings("12 * 3", h.query());
    try testing.expect(h.t.containsText("Letzte Rechnung"));
    h.enter();
    try testing.expectEqualStrings("36", h.fake.nextCopy().?);
    // The whole task is selected: typing replaces it.
    h.typeText("5");
    try testing.expectEqualStrings("5", h.query());
    h.typeText(" + 5");
    try h.reopenAfter(91);
    try testing.expectEqualStrings("", h.query());
}

test "the history copies and edits earlier tasks" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.typeText("(1.299 + 89,90) × 3");
    try h.reopenAfter(600);
    try testing.expectEqualStrings("", h.query());
    h.typeText("=");
    try testing.expectEqual(@as(usize, 1), h.palette.hitOffset());
    try testing.expect(h.t.hasText("Verlauf"));
    h.enter();
    try testing.expectEqualStrings("4.166,70", h.fake.nextCopy().?);
    h.chord(.{ .key = S.enter, .cmd = true });
    try testing.expectEqualStrings("(1.299 + 89,90) × 3", h.query());
}

test "pasted lines add up and copy as a table" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.paste("Hotel 3 × 129,00\nBahn 2 × 89,90\n\nEssen 146,35\nTaxi 38,50 − 10 %\n");
    try testing.expect(h.t.hasText("4 Zeilen"));
    try testing.expect(h.t.hasText("Summe"));
    h.enter();
    try testing.expectEqualStrings("747,80", h.fake.nextCopy().?);
    h.up();
    h.enter();
    try testing.expectEqualStrings("34,65", h.fake.nextCopy().?);
    h.chord(.{ .key = S.enter, .shift = true });
    try testing.expectEqualStrings(
        "Hotel 3 × 129,00\t387,00\nBahn 2 × 89,90\t179,80\nEssen 146,35\t146,35\n" ++
            "Taxi 38,50 − 10 %\t34,65\nSumme\t747,80",
        h.fake.nextCopy().?,
    );
    // Typing dissolves the block instead of editing its preview.
    h.typeText("7");
    try testing.expectEqualStrings("7", h.query());
    try testing.expectEqual(@as(usize, 0), h.palette.hitOffset());
}

test "the result card fits the palette" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.typeText("(1.299 + 89,90) × 3");
    const result = h.t.findText("4.166,70") orelse return error.NoResult;
    try testing.expect(result.y > theme.header_height);
    try testing.expect(result.y + result.h < 420 - theme.footer_height);
    const format = h.t.findText("mit Aufgabe") orelse return error.NoFormats;
    try testing.expect(format.y + format.h < 420 - theme.footer_height);
}
