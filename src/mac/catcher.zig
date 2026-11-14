//! The daemon's key catcher (`--unload-mode process`).
//!
//! A hot key starts the UI process, which takes about 100–300 ms until its
//! panel has the keyboard. Keys typed in that time would go to the app in
//! front. The daemon therefore puts this invisible, non-activating panel in
//! front at once: it takes the keys and keeps what they type, in order:
//! text, and ↵ (also with ⇧, ⌥, ⌘), ⎋, ⇥, ↑ and ↓ as one control byte each
//! (`Token`). When the UI process's panel has the keys, it asks for them
//! (`typed` on the control socket), types the text into its query and
//! presses the keys; then the catcher goes.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const sync = @import("../sync.zig");

/// Text that fits one socket line, with room to spare.
pub const max_bytes = 256;

const key_delete: u16 = 51;
const flag_shift: objc.NSUInteger = 1 << 17;
const flag_control: objc.NSUInteger = 1 << 18;
const flag_option: objc.NSUInteger = 1 << 19;
const flag_command: objc.NSUInteger = 1 << 20;

/// A key the catcher keeps besides text.
pub const Special = enum(u8) { enter = 1, escape = 2, tab = 3, up = 4, down = 5 };

pub const Mods = packed struct(u3) { shift: bool = false, option: bool = false, command: bool = false };

/// In the buffer, a special key is its `Special` byte, after a
/// `mods_prefix | mods` byte when modifiers were held. Text never has
/// control bytes (`printable`), so the two do not mix up.
const mods_prefix: u8 = 0x10;

fn special(code: u16) ?Special {
    return switch (code) {
        36, 76 => .enter, // Return, keypad Enter
        53 => .escape,
        48 => .tab,
        126 => .up,
        125 => .down,
        else => null,
    };
}

/// What `take` returned, piece by piece.
pub const Token = union(enum) {
    text: []const u8,
    key: struct { special: Special, mods: Mods },
};

pub const Tokens = struct {
    rest: []const u8,

    pub fn next(t: *Tokens) ?Token {
        if (t.rest.len == 0) return null;
        const b = t.rest[0];
        if (b >= mods_prefix and b < mods_prefix + 8 and t.rest.len >= 2) {
            const sp = std.enums.fromInt(Special, t.rest[1]) orelse return t.skip(2);
            t.rest = t.rest[2..];
            return .{ .key = .{ .special = sp, .mods = @bitCast(@as(u3, @intCast(b - mods_prefix))) } };
        }
        if (std.enums.fromInt(Special, b)) |sp| {
            t.rest = t.rest[1..];
            return .{ .key = .{ .special = sp, .mods = .{} } };
        }
        var end: usize = 0;
        while (end < t.rest.len and t.rest[end] >= 0x20) end += 1;
        if (end == 0) return t.skip(1);
        defer t.rest = t.rest[end..];
        return .{ .text = t.rest[0..end] };
    }

    fn skip(t: *Tokens, n: usize) ?Token {
        t.rest = t.rest[@min(n, t.rest.len)..];
        return t.next();
    }
};

pub fn tokens(typed: []const u8) Tokens {
    return .{ .rest = typed };
}

pub const Catcher = struct {
    panel: ?objc.Object = null,
    mutex: sync.Mutex = .{},
    buf: [max_bytes]u8 = undefined,
    len: usize = 0,
    /// In front and keeping keys, until `take`.
    catching: bool = false,

    /// Main thread: an empty buffer, and the panel in front with the keys.
    pub fn begin(c: *Catcher) void {
        c.mutex.lock();
        c.len = 0;
        c.catching = true;
        c.mutex.unlock();
        const p = c.panel orelse c.make();
        objc.msg(void, p, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
    }

    /// Any thread: the text typed since `begin`, copied into `out`; the
    /// catcher keeps no more keys. Call `end` on the main thread after.
    pub fn take(c: *Catcher, out: []u8) []const u8 {
        c.mutex.lock();
        defer c.mutex.unlock();
        c.catching = false;
        const n = @min(c.len, out.len);
        @memcpy(out[0..n], c.buf[0..n]);
        c.len = 0;
        return out[0..n];
    }

    /// Main thread: the panel goes.
    pub fn end(c: *Catcher) void {
        c.mutex.lock();
        c.catching = false;
        c.mutex.unlock();
        if (c.panel) |p| objc.msg(void, p, "orderOut:", .{@as(?objc.Object, null)});
    }

    /// Any thread: the hot key again while the UI process starts: it closes
    /// the palette as soon as it is there, like ⎋.
    pub fn cancel(c: *Catcher) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (c.catching) c.push(.escape, .{});
    }

    pub fn isCatching(c: *Catcher) bool {
        c.mutex.lock();
        defer c.mutex.unlock();
        return c.catching;
    }

    /// A key the panel got: printable text and the `Special` keys are kept,
    /// ⌫ takes back the last one, the rest (⌘ and ⌃ chords, ←, →) is dropped.
    fn key(c: *Catcher, code: u16, flags: objc.NSUInteger, chars: []const u8) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (!c.catching) return;
        if (code == key_delete) {
            c.len = lastTokenStart(c.buf[0..c.len]);
            return;
        }
        if (special(code)) |sp| {
            if (flags & flag_control != 0) return;
            return c.push(sp, .{
                .shift = flags & flag_shift != 0,
                .option = flags & flag_option != 0,
                .command = flags & flag_command != 0,
            });
        }
        if (flags & (flag_command | flag_control) != 0) return;
        if (!printable(chars) or c.len + chars.len > c.buf.len) return;
        @memcpy(c.buf[c.len..][0..chars.len], chars);
        c.len += chars.len;
    }

    /// With the mutex held.
    fn push(c: *Catcher, sp: Special, mods: Mods) void {
        const plain = @as(u3, @bitCast(mods)) == 0;
        const need: usize = if (plain) 1 else 2;
        if (c.len + need > c.buf.len) return;
        if (!plain) {
            c.buf[c.len] = mods_prefix + @as(u8, @as(u3, @bitCast(mods)));
            c.len += 1;
        }
        c.buf[c.len] = @backingInt(sp);
        c.len += 1;
    }

    fn make(c: *Catcher) objc.Object {
        const cls = objc.defineClass(.{ .name = "ZugriffKeyCatcher", .superclass = "NSPanel", .methods = &.{
            .{ .name = "canBecomeKeyWindow", .imp = &yes, .types = "B@:" },
            .{ .name = "keyDown:", .imp = &keyDown, .types = "v@:@" },
        } });
        const rect: objc.CGRect = .{ .size = .{ .width = 1, .height = 1 } };
        const nonactivating: objc.NSUInteger = 1 << 7; // borderless otherwise
        const raw = objc.msg(objc.Object, cls, "alloc", .{});
        const p = objc.msg(objc.Object, raw, "initWithContentRect:styleMask:backing:defer:", .{
            rect, nonactivating, @as(objc.NSUInteger, 2), objc.NO,
        });
        objc.setZig(p, c);
        // Invisible: one transparent point without a shadow, no clicks.
        objc.msg(void, p, "setOpaque:", .{objc.NO});
        objc.msg(void, p, "setBackgroundColor:", .{objc.msg(objc.Object, objc.class("NSColor"), "clearColor", .{})});
        objc.msg(void, p, "setHasShadow:", .{objc.NO});
        objc.msg(void, p, "setIgnoresMouseEvents:", .{objc.YES});
        objc.msg(void, p, "setReleasedWhenClosed:", .{objc.NO});
        objc.msg(void, p, "setHidesOnDeactivate:", .{objc.NO});
        objc.msg(void, p, "setLevel:", .{@as(objc.NSInteger, 25)}); // NSStatusWindowLevel
        // CanJoinAllSpaces | FullScreenAuxiliary | Transient | IgnoresCycle
        const behavior: objc.NSUInteger = (1 << 0) | (1 << 8) | (1 << 3) | (1 << 6);
        objc.msg(void, p, "setCollectionBehavior:", .{behavior});
        // As the palette: the app in front stays active (private, guarded).
        if (objc.msg(objc.BOOL, p, "respondsToSelector:", .{objc.sel("_setPreventsActivation:")}))
            objc.msg(void, p, "_setPreventsActivation:", .{objc.YES});
        c.panel = p;
        return p;
    }
};

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) bool {
    return true;
}

fn keyDown(self: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const c = objc.getZig(Catcher, self) orelse return;
    const code = objc.msg(u16, event, "keyCode", .{});
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{});
    const chars = objc.fromNSString(objc.msg(?objc.Object, event, "characters", .{}));
    c.key(code, flags, chars);
}

/// Text a user means to type: no control characters and none of the
/// private-use characters AppKit gives function and arrow keys.
fn printable(chars: []const u8) bool {
    if (chars.len == 0) return false;
    const view = std.unicode.Utf8View.init(chars) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or cp == 0x7f) return false;
        if (cp >= 0xf700 and cp <= 0xf8ff) return false;
    }
    return true;
}

/// Where the last UTF-8 character or special key of `s` starts (0 for an
/// empty `s`).
fn lastTokenStart(s: []const u8) usize {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] & 0xc0 != 0x80) break;
    }
    if (i > 0 and s[i] < 0x20 and s[i - 1] >= mods_prefix and s[i - 1] < mods_prefix + 8) i -= 1;
    return i;
}

test "the catcher keeps text, takes back with delete and drops chords" {
    var c: Catcher = .{ .catching = true };
    c.key(4, 0, "h");
    c.key(14, 0, "e");
    c.key(15, 0, "r");
    c.key(16, 0, "z");
    c.key(key_delete, 0, "\x7f");
    c.key(15, 0, "ä");
    c.key(9, flag_command, "v");
    c.key(123, 0, "\u{f702}");
    var out: [max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("herä", c.take(&out));
    // After `take` it keeps nothing more.
    c.key(4, 0, "x");
    try std.testing.expectEqualStrings("", c.take(&out));
}

test "special keys come back in order, with their modifiers" {
    var c: Catcher = .{ .catching = true };
    c.key(1, 0, "s");
    c.key(125, 0, "\u{f701}");
    c.key(36, flag_command, "\r");
    c.key(0, 0, "a");
    c.key(53, 0, "\x1b");
    c.key(36, flag_control, "\r"); // ⌃↵ is dropped
    var out: [max_bytes]u8 = undefined;
    var it = tokens(c.take(&out));
    try std.testing.expectEqualStrings("s", it.next().?.text);
    try std.testing.expectEqual(Special.down, it.next().?.key.special);
    const enter = it.next().?.key;
    try std.testing.expectEqual(Special.enter, enter.special);
    try std.testing.expect(enter.mods.command and !enter.mods.shift);
    try std.testing.expectEqualStrings("a", it.next().?.text);
    try std.testing.expectEqual(Special.escape, it.next().?.key.special);
    try std.testing.expect(it.next() == null);
}

test "delete takes back a whole character or special key" {
    try std.testing.expectEqual(@as(usize, 2), lastTokenStart("ab€"));
    try std.testing.expectEqual(@as(usize, 0), lastTokenStart(""));
    try std.testing.expectEqual(@as(usize, 1), lastTokenStart("a" ++ [_]u8{ mods_prefix + 4, 1 }));
    try std.testing.expectEqual(@as(usize, 1), lastTokenStart("a" ++ [_]u8{2}));
}

test "a second hot key during the start closes the palette" {
    var c: Catcher = .{ .catching = true };
    c.key(4, 0, "h");
    c.cancel();
    var out: [max_bytes]u8 = undefined;
    var it = tokens(c.take(&out));
    try std.testing.expectEqualStrings("h", it.next().?.text);
    try std.testing.expectEqual(Special.escape, it.next().?.key.special);
}
