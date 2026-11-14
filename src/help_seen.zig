//! Whether the help was ever opened: an empty marker file,
//! `~/Library/Application Support/zugriff/help-seen`. Until it exists the
//! empty app search shows a tip about `?` in its footer.
//!
//! Reading happens with the emoji preferences after the hot keys are
//! registered, writing once on a short background thread; neither touches
//! the opening path.
const std = @import("std");
const files = @import("files.zig");

const log = std.log.scoped(.help_seen);

pub fn path(a: std.mem.Allocator, home: ?[]const u8) !?[]const u8 {
    const h = home orelse return null;
    if (h.len == 0) return null;
    const file = try a.print("{s}/Library/Application Support/zugriff/help-seen", .{h});
    return file;
}

/// Whether the marker exists. An unreadable folder counts as seen: the tip
/// is a hint, and a hint that never goes away would be worse than none.
pub fn load(io: std.Io, file: []const u8) bool {
    std.Io.Dir.cwd().access(io, file, .{}) catch |e| {
        if (e == error.FileNotFound) return false;
        log.err("Hilfe-Merker nicht lesbar: {t}", .{e});
    };
    return true;
}

pub fn mark(io: std.Io, file: []const u8) !void {
    if (std.Io.Dir.path.dirname(file)) |dir| try files.ensureDir(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "" });
}

/// Writes the marker on its own thread; the agent does not wait for it.
pub fn markInBackground(io: std.Io, file: []const u8) void {
    const t = std.Thread.spawn(.{}, markLogged, .{ io, file }) catch |e| {
        log.err("Hilfe-Merker: kein Thread: {t}", .{e});
        return;
    };
    t.detach();
}

fn markLogged(io: std.Io, file: []const u8) void {
    mark(io, file) catch |e| log.err("Hilfe-Merker nicht gespeichert: {t}", .{e});
}

test "the marker is missing, then written, then seen" {
    const io = std.testing.io;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.mem.print(&buf, "/tmp/zugriff-help-seen-{d}/help-seen", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, std.Io.Dir.path.dirname(file).?) catch {};
    try std.testing.expect(!load(io, file));
    try mark(io, file);
    try std.testing.expect(load(io, file));
}
