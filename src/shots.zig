//! The palette's states as pictures, rendered offscreen (`zig build shots`):
//! the app list, the calculator, a sheet, the history, the emoji grid and
//! the help.
//! No window opens. The app list holds apps every Mac has, with the icons
//! AppKit draws for them; the icon cache stays untouched.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const S = ui.Shortcut;
const core = @import("core.zig");
const theme = @import("ui/theme.zig");
const palette_mod = @import("ui/palette.zig");
const Palette = palette_mod.Palette;
const icons = @import("mac/icons.zig");

const Host = struct {
    clipboard: []const u8 = "",
    now: i64 = 1_000_000,

    fn emit(_: *anyopaque, _: palette_mod.Event) void {}
    fn readClipboard(ctx: *anyopaque, gpa: std.mem.Allocator) ?[]u8 {
        const h: *Host = @ptrCast(@alignCast(ctx));
        return gpa.dupe(u8, h.clipboard) catch null;
    }
    fn nowMs(ctx: *anyopaque) i64 {
        const h: *Host = @ptrCast(@alignCast(ctx));
        return h.now;
    }
    fn beep(_: *anyopaque) void {}
};

const SampleApp = struct { title: []const u8, path: []const u8 };

/// Apps that come with macOS, sorted by name as the scan sorts them.
const sample_apps = [_]SampleApp{
    .{ .title = "Calculator", .path = "/System/Applications/Calculator.app" },
    .{ .title = "Calendar", .path = "/System/Applications/Calendar.app" },
    .{ .title = "Finder", .path = "/System/Library/CoreServices/Finder.app" },
    .{ .title = "Mail", .path = "/System/Applications/Mail.app" },
    .{ .title = "Maps", .path = "/System/Applications/Maps.app" },
    .{ .title = "Music", .path = "/System/Applications/Music.app" },
    .{ .title = "Notes", .path = "/System/Applications/Notes.app" },
    .{ .title = "Photos", .path = "/System/Applications/Photos.app" },
    .{ .title = "Safari", .path = "/Applications/Safari.app" },
    .{ .title = "Shortcuts", .path = "/System/Applications/Shortcuts.app" },
    .{ .title = "System Settings", .path = "/System/Applications/System Settings.app" },
    .{ .title = "Terminal", .path = "/System/Applications/Utilities/Terminal.app" },
};

/// The app's icon as AppKit draws it, kept in memory. An app this Mac lacks
/// keeps its monogram tile.
fn appIcon(a: std.mem.Allocator, io: std.Io, app: []const u8) ?core.Icon {
    std.Io.Dir.cwd().access(io, app, .{}) catch return null;
    const png = icons.renderPng(a, io, app) catch return null;
    return .{ .path = app, .png = png };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_dir = if (args.len > 1) args[1] else "zig-out/shots";
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var items: [sample_apps.len]core.Item = undefined;
    for (sample_apps, &items) |app, *it| it.* = .{
        .title = app.title,
        .subtitle = std.Io.Dir.path.dirname(app.path) orelse "/",
        .icon = appIcon(init.arena.allocator(), io, app.path),
        .action = .{ .launch_application = app.path },
    };

    const Shot = struct { name: []const u8, steps: []const Step };
    const shots = [_]Shot{
        .{ .name = "01-apps", .steps = &.{} },
        .{ .name = "02-search", .steps = &.{.{ .type = "s" }} },
        .{ .name = "03-calc", .steps = &.{.{ .type = "(1.299 + 89,90) × 3" }} },
        .{ .name = "04-calc-pasted", .steps = &.{.{ .paste = "Netto 1.299,00 € zzgl. 19 % MwSt." }} },
        .{ .name = "05-calc-units", .steps = &.{.{ .type = "2,4 GB in MB" }} },
        .{ .name = "06-calc-unfinished", .steps = &.{.{ .type = "(1.299 + 89,90) ×" }} },
        .{
            .name = "07-sheet",
            .steps = &.{.{ .paste = "Hotel 3 × 129,00\nBahn 2 × 89,90\nEssen 146,35\n" ++
                "Taxi 38,50 − 10 %\nTrinkgeld" }},
        },
        .{ .name = "08-emoji", .steps = &.{.emoji} },
        .{ .name = "09-emoji-search", .steps = &.{ .emoji, .{ .type = "daumen" } } },
        .{
            .name = "10-emoji-tones",
            .steps = &.{ .emoji, .{ .type = "daumen hoch" }, .{ .chord = .{ .key = S.tab } } },
        },
        .{ .name = "11-empty", .steps = &.{.{ .type = "xylofon" }} },
        .{ .name = "12-direct", .steps = &.{.{ .type = "https://example.com" }} },
        .{ .name = "13-help", .steps = &.{ .{ .type = "?" }, down, down, down } },
        .{ .name = "14-help-word", .steps = &.{.{ .type = "help" }} },
        .{
            .name = "15-help-tried",
            .steps = &.{ .{ .type = "?" }, down, down, down, .enter },
        },
        .{ .name = "16-help-tip", .steps = &.{.help_tip} },
    };

    for (shots) |shot| {
        var host: Host = .{};
        var p: Palette = .init(
            gpa,
            io,
            init.environ_map.get("HOME"),
            .{
                .ctx = &host,
                .emit = Host.emit,
                .clipboard = Host.readClipboard,
                .now_ms = Host.nowMs,
                .beep = Host.beep,
            },
        );
        defer p.deinit();
        _ = try p.setCatalog(&items);
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&p, Palette.view), .{ .width = 640, .height = 420, .theme = theme.window });
        defer t.deinit();
        for (shot.steps) |step| switch (step) {
            .type => |s| t.typeText(s),
            .paste => |s| {
                host.clipboard = s;
                _ = t.shortcut(.{ .key = 'v', .cmd = true });
            },
            .chord => |c| _ = t.shortcut(c),
            .emoji => {
                try p.showEmoji();
                t.frame();
            },
            .enter => t.key(.enter),
            .help_tip => {
                p.setHelpSeen(false);
                t.frame();
            },
        };
        t.settle(1);
        const path = try init.arena.allocator().print("{s}/{s}.png", .{ out_dir, shot.name });
        try t.screenshot(path);
        std.debug.print("{s}\n", .{path});
    }
}

const Step = union(enum) {
    type: []const u8,
    paste: []const u8,
    chord: S,
    emoji,
    enter,
    /// The help was never opened: the footer tip shows.
    help_tip,
};

const down: Step = .{ .chord = .{ .key = S.down } };
