//! Single-instance control socket.
//!
//! The palette is a resident agent. Commands arrive from the global hot keys
//! or from the `zugriff` CLI over this Unix socket, so a second launch
//! controls the running instance instead of starting a duplicate. The
//! protocol is the Rust version's: one line in, one line out.
const std = @import("std");
const log = std.log.scoped(.control);
const net = std.Io.net;
const files = @import("files.zig");

pub const Command = enum {
    show,
    hide,
    toggle,
    /// Show the emoji picker, or hide it when it is in front.
    emoji,
    quit,

    pub fn parse(line: []const u8) ?Command {
        return std.meta.stringToEnum(Command, line);
    }
};

/// Answered by the listener thread itself, not the main thread: the status
/// must also come when the main thread is busy.
const status_request = "status";
/// From the UI process to the daemon (`--unload-mode process`): the keys
/// typed while the UI process started, as one line of text.
pub const typed_request = "typed";

/// `~/Library/Application Support/zugriff/control.sock`.
pub fn socketPath(a: std.mem.Allocator, home: ?[]const u8) ![]const u8 {
    return a.print("{s}/Library/Application Support/zugriff/control.sock", .{home orelse "/tmp"});
}

pub fn isRunning(io: std.Io, path: []const u8) bool {
    const addr = net.UnixAddress.init(path) catch return false;
    const stream = addr.connect(io) catch return false;
    stream.close(io);
    return true;
}

/// Sends `line` to the running agent and returns its answer, in `a`.
pub fn request(a: std.mem.Allocator, io: std.Io, path: []const u8, line: []const u8) ![]const u8 {
    const addr = try net.UnixAddress.init(path);
    const stream = try addr.connect(io);
    defer stream.close(io);
    var wbuf: [128]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("{s}\n", .{line});
    try w.interface.flush();
    var rbuf: [512]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const answer = (r.interface.takeDelimiter('\n') catch |e| switch (e) {
        error.StreamTooLong => return error.AnswerTooLong,
        else => |other| return other,
    }) orelse "";
    return a.dupe(u8, std.mem.trim(u8, answer, " \r\n"));
}

/// Where the listener hands what it receives. Both run on its thread.
pub const Handler = struct {
    ctx: *anyopaque,
    /// A command for the main thread: the handler queues it there.
    command: *const fn (ctx: *anyopaque, c: Command) void,
    /// The status line, written into `buf`.
    status: *const fn (ctx: *anyopaque, buf: []u8) []const u8,
    /// The daemon's typed-ahead text, written into `buf`; null elsewhere.
    typed: ?*const fn (ctx: *anyopaque, buf: []u8) []const u8 = null,
};

pub const Server = struct {
    io: std.Io,
    path: []const u8,
    server: net.Server,
    handler: Handler,

    /// Binds the socket; fails when another instance owns it.
    pub fn bind(io: std.Io, path: []const u8, handler: Handler) !Server {
        if (std.Io.Dir.path.dirname(path)) |dir| try files.ensureDir(io, dir);
        if (isRunning(io, path)) return error.AlreadyRunning;
        // The previous process might have exited without removing its socket.
        std.Io.Dir.deleteFileAbsolute(io, path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        const addr = try net.UnixAddress.init(path);
        return .{ .io = io, .path = path, .server = try addr.listen(io, .{}), .handler = handler };
    }

    /// Serves connections on a thread of its own, for the agent's lifetime.
    pub fn spawn(s: *Server) !void {
        const t = try std.Thread.spawn(.{}, serve, .{s});
        t.detach();
    }

    /// Removes the socket file when the agent ends, so no stale socket stays
    /// behind. The listener thread ends with the process.
    pub fn unlink(s: *Server) void {
        std.Io.Dir.deleteFileAbsolute(s.io, s.path) catch |e| log.warn("Socket nicht entfernt: {t}", .{e});
    }

    fn serve(s: *Server) void {
        while (true) {
            const stream = s.server.accept(s.io) catch continue;
            s.answer(stream);
            stream.close(s.io);
        }
    }

    fn answer(s: *Server, stream: net.Stream) void {
        var rbuf: [128]u8 = undefined;
        var r = stream.reader(s.io, &rbuf);
        const raw = (r.interface.takeDelimiter('\n') catch return) orelse return;
        const line = std.mem.trim(u8, raw, " \r\n");
        var status_buf: [512]u8 = undefined;
        const response = if (Command.parse(line)) |c| blk: {
            s.handler.command(s.handler.ctx, c);
            break :blk "ok";
        } else if (std.mem.eql(u8, line, status_request))
            s.handler.status(s.handler.ctx, &status_buf)
        else if (std.mem.eql(u8, line, typed_request) and s.handler.typed != null)
            s.handler.typed.?(s.handler.ctx, &status_buf)
        else
            "unknown command";
        var wbuf: [512]u8 = undefined;
        var w = stream.writer(s.io, &wbuf);
        w.interface.print("{s}\n", .{response}) catch return;
        w.interface.flush() catch return;
    }
};

const testing = std.testing;

test "commands round-trip over the socket" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try a.print("/tmp/zugriff-control-{d}.sock", .{std.c.getpid()});
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    const Seen = struct {
        const Self = @This();
        last: std.atomic.Value(u8) = .init(255),
        fn command(ctx: *anyopaque, c: Command) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.last.store(@backingInt(c), .release);
        }
        fn status(_: *anyopaque, buf: []u8) []const u8 {
            return std.mem.print(buf, "Zugriff test", .{}) catch "";
        }
    };
    var seen: Seen = .{};
    var server = try Server.bind(io, path, .{ .ctx = &seen, .command = Seen.command, .status = Seen.status });
    try server.spawn();

    try testing.expect(isRunning(io, path));
    try testing.expectError(error.AlreadyRunning, Server.bind(io, path, server.handler));
    try testing.expectEqualStrings("ok", try request(a, io, path, "emoji"));
    try testing.expectEqual(@as(u8, @backingInt(Command.emoji)), seen.last.load(.acquire));
    try testing.expectEqualStrings("Zugriff test", try request(a, io, path, "status"));
    try testing.expectEqualStrings("unknown command", try request(a, io, path, "dance"));
}
