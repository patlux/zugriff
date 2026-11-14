//! Small file helpers the agent needs in several places.
const std = @import("std");

/// Creates `dir` and its parents unless it exists already. A path that
/// exists through a symlink (`/tmp`) counts as existing.
pub fn ensureDir(io: std.Io, dir: []const u8) !void {
    std.Io.Dir.cwd().access(io, dir, .{}) catch return std.Io.Dir.cwd().createDirPath(io, dir);
}

test "an existing directory behind a symlink is fine" {
    try ensureDir(std.testing.io, "/tmp");
}
