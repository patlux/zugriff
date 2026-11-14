//! Palette rows and what they do.
const std = @import("std");

/// What a palette row does when it is activated.
pub const Action = union(enum) {
    /// Launch an installed macOS application bundle.
    launch_application: []const u8,
    /// Open a file or folder with its default application.
    open_path: []const u8,
    /// Open a web address in the default browser.
    open_url: []const u8,
    /// Reveal a file or folder in Finder.
    reveal_path: []const u8,
    /// Switch the palette to the emoji picker: the search row "Emoji". The
    /// palette handles it itself; nothing is launched.
    open_emoji_picker,

    pub fn eql(a: Action, b: Action) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .launch_application => |p| std.mem.eql(u8, p, b.launch_application),
            .open_path => |p| std.mem.eql(u8, p, b.open_path),
            .open_url => |u| std.mem.eql(u8, u, b.open_url),
            .reveal_path => |p| std.mem.eql(u8, p, b.reveal_path),
            .open_emoji_picker => true,
        };
    }

    /// The file a row stands for, if it stands for one: what `⌘↵` reveals.
    pub fn path(a: Action) ?[]const u8 {
        return switch (a) {
            .launch_application, .open_path, .reveal_path => |p| p,
            .open_url, .open_emoji_picker => null,
        };
    }

    /// Rows that switch the palette instead of opening something.
    pub fn isCommand(a: Action) bool {
        return a == .open_emoji_picker;
    }

    fn dupe(a: Action, gpa: std.mem.Allocator) !Action {
        return switch (a) {
            .launch_application => |p| .{ .launch_application = try gpa.dupe(u8, p) },
            .open_path => |p| .{ .open_path = try gpa.dupe(u8, p) },
            .open_url => |u| .{ .open_url = try gpa.dupe(u8, u) },
            .reveal_path => |p| .{ .reveal_path = try gpa.dupe(u8, p) },
            .open_emoji_picker => .open_emoji_picker,
        };
    }
};

/// A rendered row icon: the PNG in the cache and its bytes.
pub const Icon = struct {
    path: []const u8,
    png: []const u8,
};

/// A single searchable palette row.
pub const Item = struct {
    /// Primary text, for example the application name.
    title: []const u8,
    /// Secondary text shown under the title.
    subtitle: []const u8 = "",
    /// Additional searchable strings, for example bundle identifiers.
    keywords: []const []const u8 = &.{},
    /// The row icon, once the platform cache has one; the palette draws a
    /// monogram tile while this is null.
    icon: ?Icon = null,
    action: Action,

    /// Equal rows: the same app, names, keywords and icon file.
    pub fn eql(a: Item, b: Item) bool {
        if (!std.mem.eql(u8, a.title, b.title) or !std.mem.eql(u8, a.subtitle, b.subtitle)) return false;
        if (a.keywords.len != b.keywords.len) return false;
        for (a.keywords, b.keywords) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        if ((a.icon == null) != (b.icon == null)) return false;
        if (a.icon) |ia| if (!std.mem.eql(u8, ia.path, b.icon.?.path)) return false;
        return a.action.eql(b.action);
    }

    /// A deep copy into `gpa` (an arena, usually).
    pub fn dupe(it: Item, gpa: std.mem.Allocator) !Item {
        const keywords = try gpa.alloc([]const u8, it.keywords.len);
        for (it.keywords, keywords) |k, *out| out.* = try gpa.dupe(u8, k);
        return .{
            .title = try gpa.dupe(u8, it.title),
            .subtitle = try gpa.dupe(u8, it.subtitle),
            .keywords = keywords,
            .icon = if (it.icon) |ic| .{ .path = try gpa.dupe(u8, ic.path), .png = try gpa.dupe(u8, ic.png) } else null,
            .action = try it.action.dupe(gpa),
        };
    }
};

test "actions compare by kind and target" {
    const a: Action = .{ .launch_application = "/Applications/Zed.app" };
    try std.testing.expect(a.eql(.{ .launch_application = "/Applications/Zed.app" }));
    try std.testing.expect(!a.eql(.{ .open_path = "/Applications/Zed.app" }));
    try std.testing.expect(!a.eql(.open_emoji_picker));
    try std.testing.expectEqualStrings("/Applications/Zed.app", a.path().?);
    try std.testing.expect((Action{ .open_url = "https://example.com" }).path() == null);
}
