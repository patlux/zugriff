//! Every test of the project, in one binary: `zig build test`.
test {
    _ = @import("core/text.zig");
    _ = @import("core/language.zig");
    _ = @import("core/item.zig");
    _ = @import("core/query.zig");
    _ = @import("core/matcher.zig");
    _ = @import("core/catalog.zig");
    _ = @import("core/direct.zig");
    _ = @import("core/emoji.zig");
    _ = @import("core/calc.zig");
    _ = @import("sync.zig");
    _ = @import("files.zig");
    _ = @import("app_scan.zig");
    _ = @import("control.zig");
    _ = @import("emoji_prefs.zig");
    _ = @import("help_seen.zig");
    _ = @import("mac/apps.zig");
    _ = @import("mac/icons.zig");
    _ = @import("mac/hotkey.zig");
    _ = @import("mac/launch.zig");
    _ = @import("mac/panel.zig");
    _ = @import("mac/insert.zig");
    _ = @import("mac/catcher.zig");
    _ = @import("mac/intelligence.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/glyphs.zig");
    _ = @import("ui/tests_palette.zig");
    _ = @import("ui/tests_emoji.zig");
    _ = @import("ui/help_view.zig");
    _ = @import("ui/tests_help.zig");
    _ = @import("ui/tests_language.zig");
    _ = @import("ui/texts.zig");
    _ = @import("messages.zig");
    _ = @import("daemon.zig");
    _ = @import("logging.zig");
    _ = @import("main.zig");
}
