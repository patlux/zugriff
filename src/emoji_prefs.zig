//! The emoji picker's preferences on disk: the skin tone and the recently
//! used emoji, nothing else. The file and its format are the Rust
//! version's, `~/Library/Application Support/zugriff/emoji.txt`.
//!
//! Reading happens once after the hot keys are registered, writing on one
//! background thread in the order the changes came; neither touches the
//! opening path.
const std = @import("std");
const Prefs = @import("core.zig").emoji.Prefs;
const sync = @import("sync.zig");
const files = @import("files.zig");

const log = std.log.scoped(.emoji_prefs);

pub fn path(a: std.mem.Allocator, home: ?[]const u8) !?[]const u8 {
    const h = home orelse return null;
    if (h.len == 0) return null;
    const file = try a.print("{s}/Library/Application Support/zugriff/emoji.txt", .{h});
    return file;
}

/// Reads the preferences; a missing or unreadable file means defaults.
pub fn load(io: std.Io, file: []const u8) Prefs {
    var buf: [4096]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, file, &buf) catch |e| {
        if (e != error.FileNotFound) log.err("Emoji-Einstellungen nicht lesbar: {t}", .{e});
        return .{};
    };
    return Prefs.parse(content);
}

pub fn save(io: std.Io, file: []const u8, prefs: *const Prefs) !void {
    if (std.Io.Dir.path.dirname(file)) |dir| try files.ensureDir(io, dir);
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try prefs.write(&w);
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = try std.mem.print(&tmp_buf, "{s}.tmp", .{file});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = w.buffered() });
    try std.Io.Dir.renameAbsolute(tmp, file, io);
}

/// Writes preferences on a background thread; only the newest state of a
/// burst is written.
pub const Writer = struct {
    io: std.Io,
    file: []const u8,
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    next: ?Prefs = null,
    stopping: bool = false,
    thread: ?std.Thread = null,

    pub fn start(w: *Writer) !void {
        w.thread = try std.Thread.spawn(.{}, run, .{w});
    }

    /// Writes what is still pending, then ends the thread and waits for it.
    pub fn stop(w: *Writer) void {
        w.mutex.lock();
        w.stopping = true;
        w.mutex.unlock();
        w.cond.signal();
        if (w.thread) |t| t.join();
        w.thread = null;
    }

    pub fn put(w: *Writer, prefs: Prefs) void {
        w.mutex.lock();
        w.next = prefs;
        w.mutex.unlock();
        w.cond.signal();
    }

    fn run(w: *Writer) void {
        while (true) {
            w.mutex.lock();
            while (w.next == null and !w.stopping) w.cond.wait(&w.mutex);
            const prefs = w.next orelse {
                w.mutex.unlock();
                return;
            };
            w.next = null;
            w.mutex.unlock();
            save(w.io, w.file, &prefs) catch |e| log.err("Emoji-Einstellungen nicht gespeichert: {t}", .{e});
        }
    }
};

test "preferences survive a save and a load" {
    const io = std.testing.io;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.mem.print(&buf, "/tmp/zugriff-prefs-{d}/emoji.txt", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, std.Io.Dir.path.dirname(file).?) catch {};
    var prefs: Prefs = .{ .tone = .medium };
    prefs.record("🎉");
    try save(io, file, &prefs);
    const back = load(io, file);
    try std.testing.expect(back.eql(&prefs));
    const missing = load(io, "/tmp/zugriff-does-not-exist/emoji.txt");
    try std.testing.expectEqual(@as(usize, 0), missing.recent_len);
}

test "stopping the writer still writes the last change" {
    const io = std.testing.io;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const file = try std.mem.print(&buf, "/tmp/zugriff-writer-{d}/emoji.txt", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, std.Io.Dir.path.dirname(file).?) catch {};
    var w: Writer = .{ .io = io, .file = file };
    try w.start();
    var prefs: Prefs = .{ .tone = .dark };
    prefs.record("👍");
    w.put(prefs);
    w.stop();
    const back = load(io, file);
    try std.testing.expect(back.eql(&prefs));
}
