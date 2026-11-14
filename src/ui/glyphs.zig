//! Colour emoji as pictures.
//!
//! nanoui's glyph atlas holds coverage masks, so text in it takes one
//! colour: an emoji would come out as a silhouette. The picker draws each
//! emoji with CoreText into a small picture instead, once per process, and
//! shows it with `ui.image`. Only the emoji in view are drawn.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

/// Side of a rendered emoji in pixels: 32 points on a Retina screen.
pub const pixels = 64;

const CfRef = *anyopaque;
extern "c" fn CFStringCreateWithBytes(
    alloc: ?*anyopaque,
    bytes: [*]const u8,
    len: isize,
    encoding: u32,
    external: bool,
) ?CfRef;
extern "c" fn CTFontCreateWithName(name: CfRef, size: f64, matrix: ?*const anyopaque) ?CfRef;
extern "c" fn CFDictionaryCreate(
    alloc: ?*anyopaque,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    n: isize,
    key_cb: *const anyopaque,
    value_cb: *const anyopaque,
) ?CfRef;
extern "c" fn CFAttributedStringCreate(alloc: ?*anyopaque, s: CfRef, attrs: CfRef) ?CfRef;
extern "c" fn CTLineCreateWithAttributedString(s: CfRef) ?CfRef;
extern "c" fn CTLineGetTypographicBounds(line: CfRef, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;
extern "c" fn CTLineDraw(line: CfRef, ctx: CfRef) void;
extern "c" fn CGColorSpaceCreateWithName(name: CfRef) ?CfRef;
extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    w: usize,
    h: usize,
    bpc: usize,
    bpr: usize,
    space: ?CfRef,
    info: u32,
) ?CfRef;
extern "c" fn CGContextSetTextPosition(ctx: CfRef, x: f64, y: f64) void;
extern "c" fn CGContextRelease(ctx: CfRef) void;
extern "c" fn CGColorSpaceRelease(space: CfRef) void;
extern "c" fn CFRelease(ref: CfRef) void;
const dictionary_key_callbacks = @extern(*const anyopaque, .{ .name = "kCFTypeDictionaryKeyCallBacks" });
const dictionary_value_callbacks = @extern(*const anyopaque, .{ .name = "kCFTypeDictionaryValueCallBacks" });
const font_attribute_name = @extern(*const CfRef, .{ .name = "kCTFontAttributeName" });
const srgb_name = @extern(*const CfRef, .{ .name = "kCGColorSpaceSRGB" });

const utf8_encoding: u32 = 0x08000100;
/// Premultiplied alpha first, 32-bit little endian: BGRA in memory.
const bgra_premultiplied: u32 = 2 | (2 << 12);

pub const Glyphs = struct {
    gpa: std.mem.Allocator,
    /// The pictures by glyph; a failed one is an empty slice.
    map: std.StringHashMapUnmanaged([]u8) = .empty,
    font: ?CfRef = null,

    pub fn init(gpa: std.mem.Allocator) Glyphs {
        return .{ .gpa = gpa };
    }

    pub fn deinit(g: *Glyphs) void {
        var it = g.map.iterator();
        while (it.next()) |e| {
            g.gpa.free(e.key_ptr.*);
            g.gpa.free(e.value_ptr.*);
        }
        g.map.deinit(g.gpa);
        if (g.font) |f| CFRelease(f);
        g.* = undefined;
    }

    /// The picture of `glyph`, drawn on first use; null when CoreText
    /// could not draw it.
    fn get(g: *Glyphs, glyph: []const u8) ?[]const u8 {
        if (g.map.get(glyph)) |px| return if (px.len > 0) px else null;
        const px: []u8 = g.render(glyph) catch &.{};
        const key = g.gpa.dupe(u8, glyph) catch return null;
        g.map.put(g.gpa, key, px) catch {
            g.gpa.free(key);
            g.gpa.free(px);
            return null;
        };
        return if (px.len > 0) px else null;
    }

    fn render(g: *Glyphs, glyph: []const u8) ![]u8 {
        const font = g.font orelse blk: {
            const name = CFStringCreateWithBytes(
                null,
                "Apple Color Emoji",
                17,
                utf8_encoding,
                false,
            ) orelse return error.NoFont;
            defer CFRelease(name);
            g.font = CTFontCreateWithName(name, pixels * 0.8, null) orelse return error.NoFont;
            break :blk g.font.?;
        };
        const s = CFStringCreateWithBytes(
            null,
            glyph.ptr,
            @intCast(glyph.len),
            utf8_encoding,
            false,
        ) orelse return error.NoString;
        defer CFRelease(s);
        const keys = [_]?*const anyopaque{font_attribute_name.*};
        const values = [_]?*const anyopaque{font};
        const attrs = CFDictionaryCreate(
            null,
            &keys,
            &values,
            1,
            dictionary_key_callbacks,
            dictionary_value_callbacks,
        ) orelse return error.NoAttributes;
        defer CFRelease(attrs);
        const attributed = CFAttributedStringCreate(null, s, attrs) orelse return error.NoString;
        defer CFRelease(attributed);
        const line = CTLineCreateWithAttributedString(attributed) orelse return error.NoLine;
        defer CFRelease(line);
        var ascent: f64 = 0;
        var descent: f64 = 0;
        const width = CTLineGetTypographicBounds(line, &ascent, &descent, null);

        const px = try g.gpa.alloc(u8, pixels * pixels * 4);
        errdefer g.gpa.free(px);
        @memset(px, 0);
        const space = CGColorSpaceCreateWithName(srgb_name.*) orelse return error.NoColorSpace;
        defer CGColorSpaceRelease(space);
        const ctx = CGBitmapContextCreate(px.ptr, pixels, pixels, 8, pixels * 4, space, bgra_premultiplied) orelse
            return error.NoContext;
        defer CGContextRelease(ctx);
        const side: f64 = pixels;
        CGContextSetTextPosition(ctx, (side - width) / 2, (side - (ascent + descent)) / 2 + descent);
        CTLineDraw(line, ctx);
        return px;
    }

    /// `glyph` in colour, `size` points square; plain text if it cannot be drawn.
    pub fn draw(g: *Glyphs, c: *ui.Context, glyph: []const u8, size: f32) void {
        const px = g.get(glyph) orelse return ui.text(c, glyph, .{ .size = size });
        _ = ui.image(c, .{
            .key = glyph,
            .source = .{ .pixels = .{ .bgra = px, .width = pixels, .height = pixels } },
            .box = .{ .w = size, .h = size },
            .radius = 0,
        });
    }
};

test "an emoji comes out in colour" {
    var g: Glyphs = .init(std.testing.allocator);
    defer g.deinit();
    const px = g.get("🍔") orelse return error.NotDrawn;
    // Some pixel is neither transparent nor grey.
    var coloured = false;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        const b = px[i];
        const gr = px[i + 1];
        const r = px[i + 2];
        if (px[i + 3] > 0 and (r != gr or gr != b)) coloured = true;
    }
    try std.testing.expect(coloured);
}
