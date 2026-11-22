//! The palette in English: the same states as the German tests, with the
//! English texts and none of the German ones. Rendered offscreen with
//! ui.Tester.
const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const help_view = @import("help_view.zig");
const tests_palette = @import("tests_palette.zig");
const Harness = tests_palette.Harness;
const Apps = tests_palette.Apps;

/// Words of the German interface that no English frame may show.
const german_words = [_][]const u8{
    "Schließen",
    "Öffnen",
    "öffnen",
    "Treffer",
    "suchen",
    "Suchen",
    "Rechner",
    "Ergebnis",
    "Hilfe",
    "Kopieren",
    "Einfügen",
    "Zeile",
    "Summe",
    "Aufgabe",
    "Lesart",
    "Verlauf",
    "Tipp",
    "Navigieren",
    "gerundet",
    "Rechnung",
    "Wörter",
    "Themen",
};

/// Fails when a text of the last frame contains a German word.
fn expectNoGerman(h: *Harness) !void {
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| for (german_words) |w| if (std.mem.find(u8, tx.str, w) != null) {
            std.debug.print("German text in the English palette: {s}\n", .{tx.str});
            return error.GermanText;
        },
        else => {},
    };
}

fn english(h: *Harness, apps: Apps) !void {
    try h.initIn(apps.items, .en);
    h.t.frame();
}

test "the empty search and its footer speak English" {
    const apps = Apps.init(&.{ "Safari", "Zed" });
    defer apps.deinit();
    var h: Harness = undefined;
    try english(&h, apps);
    defer h.deinit();
    try testing.expect(h.t.hasText("2 apps"));
    try testing.expect(h.t.hasText("↑↓ Navigate"));
    try testing.expect(h.t.hasText("↵ Open"));
    try testing.expect(h.t.hasText("esc Close"));
    try testing.expect(h.t.hasText("Help"));
    try expectNoGerman(&h);

    h.palette.setHelpSeen(false);
    h.t.frame();
    try testing.expect(h.t.hasText("Tip: ? shows what Zugriff can do"));

    h.typeText("zzz");
    h.t.frame();
    try testing.expect(h.t.hasText("No results"));
    try testing.expect(h.t.hasText("Nothing found for “zzz”"));
    try expectNoGerman(&h);
}

test "help and hilfe bring up the English help row" {
    const apps = Apps.init(&.{"Zed"});
    defer apps.deinit();
    var h: Harness = undefined;
    try english(&h, apps);
    defer h.deinit();
    for ([_][]const u8{ "help", "hilfe" }) |word| {
        h.clear();
        h.typeText(word);
        h.t.frame();
        try testing.expect(h.t.hasText("What Zugriff can do · also with ? or help"));
        try testing.expect(h.t.hasText("↵ Open help"));
        try expectNoGerman(&h);
    }
}

test "the help lists English topics and tries their examples" {
    const apps = Apps.init(&.{"Zed"});
    defer apps.deinit();
    var h: Harness = undefined;
    try english(&h, apps);
    defer h.deinit();
    h.typeText("?");
    h.t.frame();
    for (help_view.topics(.en, .en)) |t| try testing.expect(h.t.hasText(t.title));
    try testing.expect(h.t.hasText("Help · 7 topics · version " ++ build_options.version));
    try testing.expect(h.t.hasText("↵ Try it"));
    try expectNoGerman(&h);

    // The calculator topic is the fourth.
    for (0..3) |_| h.down();
    h.enter();
    h.t.frame();
    try testing.expectEqualStrings("$1,299 + 19%", h.query());
    try testing.expect(h.t.containsText("from the help"));
}

test "the calculator's frame speaks English" {
    var h: Harness = undefined;
    try h.initIn(&.{}, .en);
    defer h.deinit();
    h.typeText("12 * 3");
    h.t.frame();
    try testing.expect(h.t.hasText("Calculator"));
    try testing.expect(h.t.hasText("Task"));
    try testing.expect(h.t.hasText("Result"));
    try testing.expect(h.t.hasText("Copy as"));
    try testing.expect(h.t.hasText("⌥↵ Number only"));
    try expectNoGerman(&h);

    try h.reopenAfter(10);
    try testing.expect(h.t.containsText("Last calculation · 10 s ago"));
    h.clear();
    h.typeText("=");
    h.t.frame();
    try testing.expect(h.t.hasText("History"));
    try testing.expect(h.t.hasText("1 calculation"));
    try testing.expect(h.t.hasText("Recently calculated"));
    try expectNoGerman(&h);

    h.clear();
    h.typeText("1 / 0");
    h.t.frame();
    try testing.expect(h.t.hasText("undefined"));
    try testing.expect(h.t.hasText("division by zero"));
}

test "a pasted sheet speaks English" {
    var h: Harness = undefined;
    try h.initIn(&.{}, .en);
    defer h.deinit();
    h.paste("Hotel 3 * 129\nTaxi 38\nTip");
    h.t.frame();
    try testing.expect(h.t.hasText("3 lines"));
    try testing.expect(h.t.hasText("Total"));
    try testing.expect(h.t.hasText("no number"));
    try testing.expect(h.t.containsText("3 lines, total"));
    try testing.expect(h.t.containsText("1 without a number"));
    try expectNoGerman(&h);
}

test "the English calculator writes English numbers and units" {
    var h: Harness = undefined;
    try h.initIn(&.{}, .en);
    defer h.deinit();
    h.typeText("1,299.50 * 2");
    h.t.frame();
    try testing.expect(h.t.hasText("1,299.50 × 2"));
    try testing.expect(h.t.hasText("2,599.00"));
    h.enter();
    try testing.expectEqualStrings("2,599.00", h.fake.nextCopy().?);

    h.clear();
    h.typeText("2 weeks in days");
    h.t.frame();
    try testing.expect(h.t.hasText("14 days"));
    try testing.expect(h.t.hasText("Units"));
    try expectNoGerman(&h);
}

test "a number that reads two ways names both readings in English" {
    var h: Harness = undefined;
    try h.initIn(&.{}, .en);
    defer h.deinit();
    h.typeText("1,250 × 4");
    h.t.frame();
    try testing.expect(h.t.hasText("5,000"));
    try testing.expect(h.t.hasText("comma separates thousands, English"));
    try testing.expect(h.t.hasText("Other reading"));
    try testing.expect(h.t.hasText("read as 1.250 × 4 · comma as decimal point, German"));
    try testing.expect(h.t.hasText("2 readings"));
    try expectNoGerman(&h);
}

test "English texts with German numbers, as on a Mac in English with a German region" {
    var h: Harness = undefined;
    try h.initLocale(&.{}, .{ .language = .en, .numbers = .de });
    defer h.deinit();
    h.typeText("?");
    h.t.frame();
    try testing.expect(h.t.hasText("1.299 € + 19 %"));
    h.clear();
    h.typeText("1.250 × 4");
    h.t.frame();
    try testing.expect(h.t.hasText("5.000"));
    try testing.expect(h.t.hasText("dot separates thousands, German"));
    try testing.expect(h.t.hasText("read as 1,250 × 4 · dot as decimal point, English"));
}

test "the emoji picker names groups and emoji in English" {
    var h: Harness = undefined;
    try h.initIn(&.{}, .en);
    defer h.deinit();
    try h.palette.showEmoji();
    h.t.frame();
    try testing.expect(h.t.hasText("Smileys & Emotion"));
    try testing.expect(h.t.hasText("grinning face"));
    try testing.expect(h.t.hasText("↵ Insert"));
    try expectNoGerman(&h);

    h.typeText("heart");
    h.t.frame();
    try testing.expect(h.t.hasText("Results for “heart”"));
    try testing.expectEqualStrings("❤️", h.palette.emoji.cells.items[0].glyph);
    try testing.expect(h.t.hasText("red heart"));

    h.clear();
    h.typeText("qqqq");
    h.t.frame();
    try testing.expect(h.t.hasText("No emoji for “qqqq”"));
    try expectNoGerman(&h);
}
