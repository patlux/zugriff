//! The palette's colours and sizes.
//!
//! A deliberately fixed warm dark surface: the palette opens over any app.
//! The values come from the warm dark Vicinae theme the Rust version
//! took over. The window is not opaque: AppKit blurs what is behind it and
//! these surfaces paint over that blur with a fixed transparency. Text does
//! not: it owns its contrast.
const ui = @import("nanoui").ui;
const Color = ui.Color;

pub const header_height: f32 = 62;
pub const footer_height: f32 = 36;
pub const row_height: f32 = 44;
/// Edge length of the icon or monogram tile at the start of a row.
pub const row_icon_size: f32 = 26;

fn rgba(v: u32) Color {
    return Color.hex(@intCast(v >> 8)).alpha(@as(f32, @floatFromInt(v & 0xff)) / 255);
}

/// #101116 at 62 %: the warm base stays dark, the blur shows through as
/// movement and colour rather than as a readable picture.
pub const background = rgba(0x1011169e);
/// A light wash instead of a second dark surface.
pub const surface = rgba(0xffffff0d);
pub const border = rgba(0xffffff1a);
pub const text = Color.hex(0xece7df);
pub const muted = Color.hex(0xb8afa6);
pub const placeholder = Color.hex(0x7c7480);
pub const accent = Color.hex(0xf0b35a);
pub const selection = rgba(0xffffff17);
/// Costly or blocked states, always paired with words.
pub const warning = Color.hex(0xee8b6f);
pub const selection_overlay = rgba(0xf0b35a2e);
pub const accent_border = accent.alpha(0.3);

/// Dark tints for the letter tile that stands in for an application icon.
pub const monogram_tints = [_]Color{
    .hex(0x2a2d39), .hex(0x342c26), .hex(0x2b322c), .hex(0x33283a),
    .hex(0x2c313b), .hex(0x3a2f2b), .hex(0x27323a), .hex(0x35322a),
};

/// The window's theme: nanoui's widgets in these colours, and a clear
/// root, so the palette's own background is the only one over the blur.
pub const window: ui.Theme = blk: {
    var t = ui.Theme.dark_theme;
    t.background = Color.transparent;
    t.surface = surface;
    t.surface_hover = selection;
    t.text = text;
    t.muted = muted;
    t.border = border;
    t.accent = accent;
    t.accent_text = Color.hex(0x101116);
    break :blk t;
};

const std = @import("std");

test "surfaces let the backdrop through and text stays opaque" {
    for ([_]Color{ background, surface, border, selection }) |c| {
        try std.testing.expect(c.a < 1 and c.a > 0);
    }
    for ([_]Color{ text, muted, placeholder, accent, warning }) |c| {
        try std.testing.expectEqual(@as(f32, 1), c.a);
    }
}
