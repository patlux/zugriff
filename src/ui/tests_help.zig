//! The help (`?`, `help`, `hilfe`), driven like the panel is and rendered
//! offscreen with ui.Tester.
const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const theme = @import("theme.zig");
const help_view = @import("help_view.zig");
const tests_palette = @import("tests_palette.zig");
const Harness = tests_palette.Harness;
const Apps = tests_palette.Apps;

fn selectTopic(h: *Harness, title: []const u8) !void {
    for (help_view.topics, 0..) |t, i| if (std.mem.eql(u8, t.title, title)) {
        for (0..i) |_| h.down();
        return;
    };
    return error.NoTopic;
}

test "a question mark lists the topics with their examples" {
    const apps = Apps.init(&.{ "Safari", "Zed" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    h.typeText("?");
    try testing.expect(h.palette.help.showing);
    try testing.expectEqual(@as(usize, 0), h.palette.resultCount());
    for (help_view.topics) |t| {
        try testing.expect(h.t.hasText(t.title));
        try testing.expect(h.t.hasText(t.example));
    }
    try testing.expect(h.t.hasText("Hilfe · 7 Themen · Version " ++ build_options.version));
    try testing.expect(h.t.hasText("↵ Ausprobieren"));
    // All seven rows fit above the footer, no scrolling.
    const last = h.t.findText("Tasten") orelse return error.NoRow;
    try testing.expect(last.y + last.h < 420 - theme.footer_height);
    // ⌫ goes back to the apps.
    h.key(.backspace);
    try testing.expect(!h.palette.help.showing);
    try testing.expectEqual(@as(usize, 2), h.palette.resultCount());
}

test "enter tries the example and the footer names where it came from" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.typeText("?");
    try selectTopic(&h, "Rechnen");
    h.enter();
    try testing.expectEqualStrings("1.299 € + 19 %", h.query());
    try testing.expect(!h.palette.help.showing);
    try testing.expect(h.t.hasText("1.545,81 €"));
    try testing.expect(h.t.containsText("· aus der Hilfe"));
    h.enter();
    try testing.expectEqualStrings("1.545,81 €", h.fake.nextCopy().?);
    // Changing the task drops the origin.
    h.typeText(" + 1");
    try testing.expect(h.t.hasText("1.546,81 €"));
    try testing.expect(!h.t.containsText("aus der Hilfe"));
}

test "the examples do what their topic says" {
    const apps = Apps.init(&.{ "Safari", "Zed" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();

    h.typeText("?");
    h.enter();
    try testing.expectEqualStrings("saf", h.query());
    try testing.expect(h.t.containsText("aus der Hilfe"));
    h.enter();
    try testing.expectEqualStrings("/Applications/Safari.app", h.fake.nextActivation().?.launch_application);

    h.clear();
    h.typeText("?");
    try selectTopic(&h, "Adresse öffnen");
    h.enter();
    h.enter();
    try testing.expectEqualStrings("https://ziglang.org", h.fake.nextActivation().?.open_url);

    h.clear();
    h.typeText("?");
    try selectTopic(&h, "Emoji einfügen");
    h.enter();
    try testing.expect(h.palette.showingEmoji());
    try testing.expectEqualStrings("herz", h.query());
}

test "the keys topic has nothing to try" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.typeText("?");
    try selectTopic(&h, "Tasten");
    try testing.expect(!h.t.hasText("↵ Ausprobieren"));
    h.enter();
    try testing.expectEqualStrings("?", h.query());
    try testing.expect(h.fake.beeps >= 1);
}

test "help and hilfe bring the help row first, other words do not" {
    const apps = Apps.init(&.{ "Help Viewer", "Zed" });
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    for ([_][]const u8{ "help", "Hilfe" }) |word| {
        h.typeText(word);
        const first = h.palette.catalog.items[h.palette.results[0].index];
        try testing.expectEqualStrings("Hilfe", first.title);
        try testing.expectEqual(@as(usize, 0), h.palette.selected);
        h.clear();
    }
    for ([_][]const u8{ "hi", "helper", "hilfen" }) |word| {
        h.typeText(word);
        for (h.palette.results) |hit| try testing.expect(h.palette.catalog.items[hit.index].action != .open_help);
        h.clear();
    }
    h.typeText("help");
    try testing.expectEqual(@as(usize, 2), h.palette.resultCount());
    try testing.expect(h.t.hasText("↵ Hilfe öffnen"));
    h.enter();
    try testing.expect(h.fake.nextActivation() == null);
    try testing.expectEqualStrings("?", h.query());
    try testing.expect(h.palette.help.showing);
}

test "a question mark elsewhere is not the help" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    h.typeText(":?");
    try testing.expect(h.palette.showingEmoji());
    try testing.expect(!h.palette.help.showing);
    h.key(.escape);
    _ = h.fake.take();
    try h.palette.reset();
    h.t.frame();
    h.typeText("12 * 4?");
    try testing.expect(!h.palette.help.showing);
    h.enter();
    try testing.expectEqualStrings("48", h.fake.nextCopy().?);
}

test "the empty search hints at the help, a click opens it" {
    const apps = Apps.init(&.{"Zed"});
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    h.t.frame();
    const hint = h.t.findText("Hilfe") orelse return error.NoHint;
    try testing.expect(hint.y < theme.header_height);
    h.typeText("z");
    try testing.expect(!h.t.hasText("Hilfe"));
    h.clear();
    try h.t.clickText("Hilfe");
    try testing.expectEqualStrings("?", h.query());
    try testing.expect(h.palette.help.showing);
}

test "the footer tip shows until the help was opened once" {
    const apps = Apps.init(&.{"Zed"});
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    const tip = "Tipp: ? zeigt, was Zugriff kann";
    // Unknown until the agent read the marker: no tip.
    h.t.frame();
    try testing.expect(!h.t.hasText(tip));
    h.palette.setHelpSeen(false);
    h.t.frame();
    try testing.expect(h.t.hasText(tip));
    h.typeText("z");
    try testing.expect(!h.t.hasText(tip));
    h.clear();
    h.typeText("?");
    var seen: usize = 0;
    for (h.fake.take()) |e| if (e == .help_seen) {
        seen += 1;
    };
    try testing.expectEqual(@as(usize, 1), seen);
    h.clear();
    try testing.expect(!h.t.hasText(tip));
    // Opening it again tells nobody; a late answer from disk changes nothing.
    h.palette.setHelpSeen(false);
    h.typeText("?");
    for (h.fake.take()) |e| try testing.expect(e != .help_seen);
    h.clear();
    try testing.expect(!h.t.hasText(tip));
}

test "the footer keeps its place with and without the tip" {
    const apps = Apps.init(&.{"Zed"});
    defer apps.deinit();
    var h: Harness = undefined;
    try h.init(apps.items);
    defer h.deinit();
    h.t.frame();
    const count = h.t.findText("1 Apps") orelse return error.NoCount;
    h.palette.setHelpSeen(false);
    h.t.frame();
    const tip = h.t.findText("Tipp: ? zeigt, was Zugriff kann") orelse return error.NoTip;
    try testing.expectEqual(count.y, tip.y);
    try testing.expectEqual(count.h, tip.h);
}
