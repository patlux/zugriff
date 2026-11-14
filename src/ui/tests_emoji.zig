//! The emoji grid with the mouse: a click inserts, a right-click or a long
//! press opens the skin tones. Rendered offscreen with ui.Tester.
const std = @import("std");
const testing = std.testing;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("../core.zig");
const emoji_view = @import("emoji_view.zig");
const tests_palette = @import("tests_palette.zig");
const Harness = tests_palette.Harness;

/// The emoji picker searched for `query`.
fn openPicker(h: *Harness, query: []const u8) !void {
    try h.palette.showEmoji();
    h.t.frame();
    h.typeText(query);
}

/// The middle of the grid's first cell: the top-left box of a cell's size.
fn firstCell(h: *Harness) !ui.Point {
    var best: ?ui.Rect = null;
    var it = h.t.ctx.rects.valueIterator();
    while (it.next()) |r| {
        if (r.w != emoji_view.cell_size or r.h != emoji_view.cell_size) continue;
        if (best == null or r.y < best.?.y or (r.y == best.?.y and r.x < best.?.x)) best = r.*;
    }
    const r = best orelse return error.NoCell;
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

fn firstGlyph(h: *Harness) []const u8 {
    return h.palette.emoji.cells.items[0].glyph;
}

fn expectInserted(h: *Harness, glyph: []const u8) !void {
    const out = h.fake.output();
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings(glyph, out[0].insert);
}

test "a click on a cell inserts the emoji" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    try openPicker(&h, "daumen hoch");
    const at = try firstCell(&h);
    h.t.click(at.x, at.y);
    try expectInserted(&h, firstGlyph(&h));
    try testing.expect(h.palette.emoji.tones == null);
}

test "a right-click opens the skin tones and closes them again" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    try openPicker(&h, "daumen hoch");
    try testing.expect(core.emoji.get(h.palette.emoji.cells.items[0].emoji).hasTones());
    const at = try firstCell(&h);
    h.t.rightClick(at.x, at.y);
    try testing.expect(h.palette.emoji.tones != null);
    try testing.expectEqual(@as(usize, 0), h.palette.emoji.selected);
    try testing.expectEqual(@as(usize, 0), h.fake.output().len);
    h.t.rightClick(at.x, at.y);
    try testing.expect(h.palette.emoji.tones == null);
    try testing.expectEqual(@as(usize, 0), h.fake.output().len);
}

test "a long press opens the skin tones without inserting" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    try openPicker(&h, "daumen hoch");
    const at = try firstCell(&h);
    h.t.down(at.x, at.y);
    h.t.advance(emoji_view.long_press_delay / 2);
    try testing.expect(h.palette.emoji.tones == null);
    h.t.advance(emoji_view.long_press_delay);
    try testing.expect(h.palette.emoji.tones != null);
    h.t.up();
    try testing.expect(h.palette.emoji.tones != null);
    try testing.expectEqual(@as(usize, 0), h.fake.output().len);
    // The next click is a click again.
    h.t.click(at.x, at.y);
    try expectInserted(&h, firstGlyph(&h));
}

test "a long press on an emoji without skin tones inserts on release" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    try openPicker(&h, "herz");
    try testing.expect(!core.emoji.get(h.palette.emoji.cells.items[0].emoji).hasTones());
    const at = try firstCell(&h);
    h.t.down(at.x, at.y);
    h.t.advance(emoji_view.long_press_delay * 2);
    try testing.expect(h.palette.emoji.tones == null);
    try testing.expectEqual(@as(usize, 0), h.fake.beeps);
    h.t.up();
    try expectInserted(&h, firstGlyph(&h));
}

test "a right-click on an emoji without skin tones only selects it" {
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    try openPicker(&h, "herz");
    const at = try firstCell(&h);
    h.t.rightClick(at.x, at.y);
    try testing.expect(h.palette.emoji.tones == null);
    try testing.expectEqual(@as(usize, 1), h.fake.beeps);
    try testing.expectEqual(@as(usize, 0), h.fake.output().len);
}
