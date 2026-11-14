//! `run --unload-after <s> --unload-mode process`: a small resident daemon
//! with the hot keys and the public control socket, and no window. The
//! palette runs in a UI process (`zugriff ui`, the agent in `agent.zig`)
//! the daemon starts on the first show; that process ends itself after the
//! idle time, so between uses only the daemon stays in memory. A show then
//! waits for the UI process to start (about 150 ms or more); keys typed in
//! that time are kept by the key catcher (`mac/catcher.zig`) and handed to
//! the UI process.
const std = @import("std");
const Allocator = std.mem.Allocator;
const nanoui = @import("nanoui");
const build_options = @import("build_options");
const control = @import("control.zig");
const sync = @import("sync.zig");
const agent = @import("agent.zig");
const Catcher = @import("mac/catcher.zig").Catcher;
const intelligence = @import("mac/intelligence.zig");

const log = std.log.scoped(.zugriff);

/// A UI process that has not asked for the typed keys after this long has
/// failed to start; the catcher goes so the keys reach the app in front.
const catch_timeout_ms = 3000;

pub const Daemon = struct {
    gpa: Allocator,
    io: std.Io,
    app: *nanoui.App,
    settings: agent.Settings,
    /// This binary, started again as the UI process.
    exe: []const u8,
    /// The UI process's private socket, next to the public one.
    ui_socket: []const u8,
    child: ?std.process.Child = null,
    server: ?control.Server = null,
    commands_mutex: sync.Mutex = .{},
    commands: std.ArrayList(control.Command) = .empty,
    catcher: Catcher = .{},
    /// When the catcher came to the front (`nowMs`).
    catch_started_ms: i64 = 0,

    pub fn run(gpa: Allocator, io: std.Io, home: ?[]const u8, init: std.process.Init, settings: agent.Settings) !void {
        const arena = init.arena.allocator();
        const socket = try control.socketPath(arena, home);
        if (control.isRunning(io, socket)) {
            _ = control.request(arena, io, socket, "show") catch |e| log.warn("show: {t}", .{e});
            std.debug.print("Zugriff läuft bereits; Palette wird angezeigt.\n", .{});
            return;
        }
        var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const exe_len = try std.process.executablePath(io, &exe_buf);

        intelligence.optOut();
        const app = try nanoui.App.create(
            init,
            .{ .name = "Zugriff", .quit_on_last_window_closed = false, .activation = .accessory },
        );
        defer app.destroy();
        const d = try gpa.create(Daemon);
        defer gpa.destroy(d);
        d.* = .{
            .gpa = gpa,
            .io = io,
            .app = app,
            .settings = settings,
            .exe = try arena.dupe(u8, exe_buf[0..exe_len]),
            .ui_socket = try uiSocketPath(arena, socket),
        };
        defer d.shutdown();

        agent.registerHotkeys(settings, d, palettePressed, emojiPressed);
        d.server = try control.Server.bind(
            io,
            socket,
            .{ .ctx = d, .command = commandFromSocket, .status = status, .typed = typed },
        );
        try d.server.?.spawn();
        log.info("Daemon bereit; die Palette startet beim ersten Aufruf", .{});
        try app.run();
        log.info("Zugriff beendet", .{});
    }

    fn shutdown(d: *Daemon) void {
        if (d.childRunning()) d.forward(.quit) catch |e| log.warn("UI-Prozess nicht beendet: {t}", .{e});
        if (d.server) |*s| s.unlink();
        d.commands.deinit(d.gpa);
    }

    fn palettePressed(ctx: *anyopaque) void {
        const d: *Daemon = @ptrCast(@alignCast(ctx));
        log.info("Hotkey: Palette", .{});
        d.handle(.toggle);
    }

    fn emojiPressed(ctx: *anyopaque) void {
        const d: *Daemon = @ptrCast(@alignCast(ctx));
        log.info("Hotkey: Emoji", .{});
        d.handle(.emoji);
    }

    /// From the socket's thread: queued for the main thread.
    fn commandFromSocket(ctx: *anyopaque, c: control.Command) void {
        const d: *Daemon = @ptrCast(@alignCast(ctx));
        d.commands_mutex.lock();
        d.commands.append(d.gpa, c) catch |e| log.warn("Befehl {t} verworfen: {t}", .{ c, e });
        d.commands_mutex.unlock();
        _ = nanoui.App.onMain(d, drainCommands);
    }

    fn drainCommands(ctx: ?*anyopaque) callconv(.c) void {
        const d: *Daemon = @ptrCast(@alignCast(ctx.?));
        while (true) {
            d.commands_mutex.lock();
            const next = if (d.commands.items.len > 0) d.commands.orderedRemove(0) else null;
            d.commands_mutex.unlock();
            const c = next orelse return;
            log.info("Befehl über Socket: {t}", .{c});
            d.handle(c);
        }
    }

    /// The daemon's line, then the UI process's when it runs.
    fn status(ctx: *anyopaque, buf: []u8) []const u8 {
        const d: *Daemon = @ptrCast(@alignCast(ctx));
        var answer_buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&answer_buf);
        const ui = control.request(fba.allocator(), d.io, d.ui_socket, "status") catch "UI-Prozess nicht geladen";
        return std.mem.print(buf, "Zugriff {s} Daemon (pid {d}); {s}", .{
            build_options.version,
            std.c.getpid(),
            ui,
        }) catch "Zugriff";
    }

    fn handle(d: *Daemon, c: control.Command) void {
        switch (c) {
            .quit => {
                log.info("beendet sich auf Befehl", .{});
                d.app.quit();
            },
            .hide => if (d.childRunning()) d.forward(.hide) catch |e| log.debug("hide: {t}", .{e}),
            .show, .toggle, .emoji => {
                if (d.forward(c)) |_| return else |_| {}
                // Started a moment ago and not listening yet: the hot key
                // again closes the palette once it is there, as ⎋ would.
                if (d.childRunning()) {
                    if (c != .show and d.catcher.isCatching()) {
                        d.catcher.cancel();
                        return log.info("UI-Prozess startet noch; {t} schließt sie gleich wieder", .{c});
                    }
                    return log.info("UI-Prozess startet noch; {t} übergangen", .{c});
                }
                // Nothing on screen: a toggle shows. Keys typed until the UI
                // process has the keyboard go to the catcher, not the app in front.
                d.catcher.begin();
                d.catch_started_ms = agent.nowMs(d);
                nanoui.App.after(catch_timeout_ms, d, endStaleCatch);
                d.spawn(if (c == .toggle) .show else c);
            },
        }
    }

    /// From the socket's thread: the UI process has the keyboard and takes
    /// the keys typed since the hot key; the catcher goes on the main thread.
    fn typed(ctx: *anyopaque, buf: []u8) []const u8 {
        const d: *Daemon = @ptrCast(@alignCast(ctx));
        const text = d.catcher.take(buf[1 .. buf.len - 1]);
        _ = nanoui.App.onMain(d, endCatch);
        log.info("an UI-Prozess übergeben: {d} getippte Bytes", .{text.len});
        buf[0] = '[';
        buf[text.len + 1] = ']';
        return buf[0 .. text.len + 2];
    }

    fn endCatch(ctx: ?*anyopaque) callconv(.c) void {
        const d: *Daemon = @ptrCast(@alignCast(ctx.?));
        d.catcher.end();
    }

    fn endStaleCatch(ctx: ?*anyopaque) callconv(.c) void {
        const d: *Daemon = @ptrCast(@alignCast(ctx.?));
        if (!d.catcher.isCatching() or agent.nowMs(d) - d.catch_started_ms < catch_timeout_ms) return;
        log.warn("UI-Prozess hat die getippten Tasten nicht abgeholt; Tastenfang beendet", .{});
        d.catcher.end();
    }

    fn forward(d: *Daemon, c: control.Command) !void {
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const started = agent.nowUs();
        _ = try control.request(fba.allocator(), d.io, d.ui_socket, @tagName(c));
        log.info("an UI-Prozess weitergereicht: {t} ({d} µs)", .{ c, agent.nowUs() - started });
    }

    /// Whether the UI process lives; collects it once it has ended.
    fn childRunning(d: *Daemon) bool {
        const child = d.child orelse return false;
        const pid = child.id orelse {
            d.child = null;
            return false;
        };
        var st: c_int = 0;
        if (std.c.waitpid(pid, &st, std.c.W.NOHANG) == 0) return true;
        log.info("UI-Prozess {d} ist beendet", .{pid});
        d.child = null;
        return false;
    }

    fn spawn(d: *Daemon, then: control.Command) void {
        var secs_buf: [16]u8 = undefined;
        const secs = std.mem.print(&secs_buf, "{d}", .{d.settings.unload_after_s orelse 0}) catch unreachable;
        const argv = [_][]const u8{
            d.exe,
            "ui",
            "--socket",
            d.ui_socket,
            "--unload-after",
            secs,
            "--then",
            @tagName(then),
        };
        const started_us = agent.nowUs();
        d.child = std.process.spawn(d.io, .{ .argv = &argv }) catch |e| {
            d.catcher.end();
            return log.err("UI-Prozess lässt sich nicht starten: {t}", .{e});
        };
        log.info("UI-Prozess gestartet (pid {d}) in {d} µs", .{ d.child.?.id.?, agent.nowUs() - started_us });
    }
};

/// `ui.sock` next to the public socket.
fn uiSocketPath(a: Allocator, socket: []const u8) ![]const u8 {
    const dir = std.Io.Dir.path.dirname(socket) orelse return error.NoDirectory;
    return a.print("{s}/ui.sock", .{dir});
}
