//! Global hot keys through Carbon: the only system-wide shortcut mechanism
//! on macOS that needs no Accessibility permission.
const std = @import("std");

pub const Error = error{ Invalid, HandlerFailed, Taken, TooMany };

/// Carbon's modifier bits.
pub const cmd: u32 = 1 << 8;
pub const shift: u32 = 1 << 9;
pub const option: u32 = 1 << 11;
pub const control: u32 = 1 << 12;

/// A key by its position on the keyboard (macOS's virtual key code, which
/// Carbon takes whatever the layout) with modifiers.
pub const Spec = struct {
    code: u32,
    mods: u32,
};

/// Reads `cmd+space`, `ctrl+cmd+space`, `alt+k`: modifiers and one key,
/// joined with `+`, in any case.
pub fn parse(spec: []const u8) Error!Spec {
    var mods: u32 = 0;
    var key: ?u32 = null;
    var parts = std.mem.splitScalar(u8, spec, '+');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " ");
        if (part.len == 0) continue;
        var lower_buf: [16]u8 = undefined;
        if (part.len > lower_buf.len) return error.Invalid;
        const lower = std.ascii.lowerString(&lower_buf, part);
        if (oneOf(lower, &.{ "cmd", "command", "meta", "super" })) {
            mods |= cmd;
        } else if (oneOf(lower, &.{ "alt", "opt", "option" })) {
            mods |= option;
        } else if (oneOf(lower, &.{ "ctrl", "control" })) {
            mods |= control;
        } else if (std.mem.eql(u8, lower, "shift")) {
            mods |= shift;
        } else {
            if (key != null) return error.Invalid;
            key = keyCode(lower) orelse return error.Invalid;
        }
    }
    return .{ .code = key orelse return error.Invalid, .mods = mods };
}

fn oneOf(s: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, s, n)) return true;
    return false;
}

/// kVK_* codes: the ANSI positions, also on German keyboards.
fn keyCode(name: []const u8) ?u32 {
    const named = [_]struct { []const u8, u32 }{
        .{ "space", 0x31 },  .{ "enter", 0x24 },       .{ "return", 0x24 },       .{ "tab", 0x30 },
        .{ "escape", 0x35 }, .{ "esc", 0x35 },         .{ "comma", 0x2B },        .{ "period", 0x2F },
        .{ "dot", 0x2F },    .{ "slash", 0x2C },       .{ "backslash", 0x2A },    .{ "semicolon", 0x29 },
        .{ "quote", 0x27 },  .{ "backquote", 0x32 },   .{ "grave", 0x32 },        .{ "minus", 0x1B },
        .{ "equal", 0x18 },  .{ "bracketleft", 0x21 }, .{ "bracketright", 0x1E }, .{ "arrowup", 0x7E },
        .{ "up", 0x7E },     .{ "arrowdown", 0x7D },   .{ "down", 0x7D },         .{ "arrowleft", 0x7B },
        .{ "left", 0x7B },   .{ "arrowright", 0x7C },  .{ "right", 0x7C },        .{ "f1", 0x7A },
        .{ "f2", 0x78 },     .{ "f3", 0x63 },          .{ "f4", 0x76 },           .{ "f5", 0x60 },
        .{ "f6", 0x61 },     .{ "f7", 0x62 },          .{ "f8", 0x64 },           .{ "f9", 0x65 },
        .{ "f10", 0x6D },    .{ "f11", 0x67 },         .{ "f12", 0x6F },
    };
    for (named) |n| if (std.mem.eql(u8, name, n[0])) return n[1];
    if (name.len != 1) return null;
    const letters = "asdfhgzxcv\x00bqweryt123465=97-80]ou[ip\x00lj'k;\\,/nm.";
    // The table above is the ANSI order: a=0x00, s=0x01, … m=0x2E, .=0x2F.
    for (letters, 0..) |ch, code| if (ch != 0 and ch == name[0]) return @intCast(code);
    return null;
}

const EventTypeSpec = extern struct { class: u32, kind: u32 };
const HotKeyId = extern struct { signature: u32, id: u32 };
const Handler = *const fn (call: ?*anyopaque, event: ?*anyopaque, user: ?*anyopaque) callconv(.c) i32;

extern "c" fn GetApplicationEventTarget() ?*anyopaque;
extern "c" fn InstallEventHandler(
    target: ?*anyopaque,
    handler: Handler,
    count: u32,
    list: [*]const EventTypeSpec,
    user: ?*anyopaque,
    out: ?*?*anyopaque,
) i32;
extern "c" fn RegisterEventHotKey(
    key_code: u32,
    modifiers: u32,
    id: HotKeyId,
    target: ?*anyopaque,
    options: u32,
    out: *?*anyopaque,
) i32;
extern "c" fn GetEventParameter(
    event: ?*anyopaque,
    name: u32,
    desired: u32,
    actual: ?*u32,
    size: usize,
    actual_size: ?*usize,
    data: ?*anyopaque,
) i32;

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// Called on the main thread when its hot key is pressed.
pub const Pressed = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void };

var handlers: [4]?Pressed = @splat(null);
var installed = false;

fn handle(_: ?*anyopaque, event: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
    var id: HotKeyId = undefined;
    const status = GetEventParameter(event, fourcc("----"), fourcc("hkid"), null, @sizeOf(HotKeyId), null, &id);
    if (status != 0 or id.signature != fourcc("zgrf") or id.id >= handlers.len) return 0;
    if (handlers[id.id]) |h| h.func(h.ctx);
    return 0;
}

/// Calls `on` each time `spec` is pressed, from any app. Carbon grants a
/// key even when another app holds it already; the other app may then win.
pub fn register(spec: Spec, on: Pressed) Error!void {
    if (!installed) {
        const types = [_]EventTypeSpec{.{ .class = fourcc("keyb"), .kind = 5 }}; // kEventHotKeyPressed
        if (InstallEventHandler(
            GetApplicationEventTarget(),
            &handle,
            1,
            &types,
            null,
            null,
        ) != 0) return error.HandlerFailed;
        installed = true;
    }
    const slot = for (handlers, 0..) |h, i| {
        if (h == null) break i;
    } else return error.TooMany;
    var ref: ?*anyopaque = null;
    const id: HotKeyId = .{ .signature = fourcc("zgrf"), .id = @intCast(slot) };
    if (RegisterEventHotKey(spec.code, spec.mods, id, GetApplicationEventTarget(), 0, &ref) != 0) return error.Taken;
    handlers[slot] = on;
}

const testing = std.testing;

test "parses command space and the emoji hot key" {
    const palette = try parse("cmd+space");
    try testing.expectEqual(@as(u32, 0x31), palette.code);
    try testing.expectEqual(cmd, palette.mods);
    const emoji = try parse("ctrl+cmd+space");
    try testing.expectEqual(cmd | control, emoji.mods);
    try testing.expect(emoji.mods != palette.mods);
}

test "letters and digits are positions" {
    const k = try parse("Alt+K");
    try testing.expectEqual(@as(u32, 0x28), k.code);
    try testing.expectEqual(option, k.mods);
    try testing.expectEqual(@as(u32, 0x00), (try parse("cmd+a")).code);
    try testing.expectEqual(@as(u32, 0x2E), (try parse("cmd+m")).code);
    try testing.expectEqual(@as(u32, 0x1D), (try parse("cmd+0")).code);
    try testing.expectEqual(@as(u32, 0x09), (try parse("cmd+v")).code);
}

test "rejects incomplete specs" {
    try testing.expectError(error.Invalid, parse("cmd+"));
    try testing.expectError(error.Invalid, parse("space+space"));
    try testing.expectError(error.Invalid, parse("hyper+space"));
}
