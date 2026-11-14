//! The daemon's key catcher (`--unload-mode process`).
//!
//! A hot key starts the UI process, which takes about 100–300 ms until its
//! panel has the keyboard. Keys typed in that time would go to the app in
//! front. The daemon therefore puts this invisible, non-activating panel in
//! front at once: it takes the keys and keeps the text they type. When the
//! UI process's panel has the keys, it asks for the text (`typed` on the
//! control socket) and puts it into its query; then the catcher goes.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const sync = @import("../sync.zig");

/// Text that fits one socket line, with room to spare.
pub const max_bytes = 256;

const key_delete: u16 = 51;
const flag_control: objc.NSUInteger = 1 << 18;
const flag_command: objc.NSUInteger = 1 << 20;

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

    pub fn isCatching(c: *Catcher) bool {
        c.mutex.lock();
        defer c.mutex.unlock();
        return c.catching;
    }

    /// A key the panel got: printable text is kept, ⌫ takes back the last
    /// character, the rest (⌘ and ⌃ chords, ↵, ⎋, arrows) is dropped.
    fn key(c: *Catcher, code: u16, flags: objc.NSUInteger, chars: []const u8) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (!c.catching) return;
        if (code == key_delete) {
            c.len = lastCharStart(c.buf[0..c.len]);
            return;
        }
        if (flags & (flag_command | flag_control) != 0) return;
        if (!printable(chars) or c.len + chars.len > c.buf.len) return;
        @memcpy(c.buf[c.len..][0..chars.len], chars);
        c.len += chars.len;
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

/// Where the last UTF-8 character of `s` starts (0 for an empty `s`).
fn lastCharStart(s: []const u8) usize {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] & 0xc0 != 0x80) return i;
    }
    return 0;
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
    c.key(36, 0, "\r");
    c.key(123, 0, "\u{f702}");
    var out: [max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("herä", c.take(&out));
    // After `take` it keeps nothing more.
    c.key(4, 0, "x");
    try std.testing.expectEqualStrings("", c.take(&out));
}

test "delete takes back a whole multi-byte character" {
    try std.testing.expectEqual(@as(usize, 2), lastCharStart("ab€"));
    try std.testing.expectEqual(@as(usize, 0), lastCharStart(""));
}
