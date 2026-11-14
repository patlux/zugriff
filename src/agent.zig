//! The resident agent: the panel, the hot keys, the control socket, the
//! app scan, the icons and what the palette's events do.
//!
//! Opening contract (AGENTS.md): panel and hot keys first; content work
//! starts only after the palette can open. Do not move app discovery into
//! the start path.
const std = @import("std");
const Allocator = std.mem.Allocator;
const nanoui = @import("nanoui");
const build_options = @import("build_options");
const core = @import("core.zig");
const ui_palette = @import("ui/palette.zig");
const theme = @import("ui/theme.zig");
const control = @import("control.zig");
const app_scan = @import("app_scan.zig");
const emoji_prefs = @import("emoji_prefs.zig");
const sync = @import("sync.zig");
const apps = @import("mac/apps.zig");
const icons = @import("mac/icons.zig");
const hotkey = @import("mac/hotkey.zig");
const insert = @import("mac/insert.zig");
const launch = @import("mac/launch.zig");
const panel = @import("mac/panel.zig");
const Palette = ui_palette.Palette;
const InsertSupport = ui_palette.InsertSupport;

const log = std.log.scoped(.zugriff);

pub const Hotkeys = struct {
    palette: []const u8 = "cmd+space",
    /// The macOS character viewer's shortcut; null: no emoji hot key.
    emoji: ?[]const u8 = "ctrl+cmd+space",
};

/// After the panel is ordered out, the app in front needs a moment to get
/// the keyboard back before `⌘V` arrives.
const paste_delay_ms = 50;
/// How long the inserted text stays on the pasteboard before the previous
/// content returns; slow apps read the pasteboard after the key event.
const restore_delay_ms = 600;
/// Icons rendered per main-thread turn: at about 2 ms per icon, six keep
/// the blocking work below one frame, so the palette keeps reacting.
const icons_per_batch = 6;
const icon_batch_pause_ms = 2;
/// Icon cache files older than this are removed after the first scan.
const icon_max_age_s = 30 * 24 * 60 * 60;

const View = enum { apps, emoji };

/// Events the palette emitted during a frame, done after it.
const Deferred = union(enum) {
    dismiss,
    activate: core.Action,
    copy: []u8,
    insert: []u8,
    request_insert_permission,
    quit,
};

pub const Agent = struct {
    gpa: Allocator,
    io: std.Io,
    home: ?[]const u8,
    app: *nanoui.App,
    window: *nanoui.Window = undefined,
    palette: Palette = undefined,
    visible: bool = false,
    /// The first show wants the icons that are not cached yet.
    icons_wanted: bool = false,
    /// Apps whose icons are still to be rendered, owned.
    icon_queue: std.ArrayList([]u8) = .empty,
    icon_pass_running: bool = false,
    scanner: app_scan.Scanner(apps.List) = undefined,
    scanning: bool = false,
    /// The newest app list from the scan thread, for the main thread.
    inbox_mutex: sync.Mutex = .{},
    inbox: ?apps.List = null,
    first_list: bool = true,
    commands_mutex: sync.Mutex = .{},
    commands: std.ArrayList(control.Command) = .empty,
    deferred: std.ArrayList(Deferred) = .empty,
    deferred_scheduled: bool = false,
    prefs_writer: ?emoji_prefs.Writer = null,
    prefs_loaded: ?core.emoji.Prefs = null,
    server: ?control.Server = null,
    staged: ?insert.Staged = null,

    pub fn run(gpa: Allocator, io: std.Io, home: ?[]const u8, init: std.process.Init, keys: Hotkeys) !void {
        const socket = try control.socketPath(init.arena.allocator(), home);
        if (control.isRunning(io, socket)) {
            _ = control.request(init.arena.allocator(), io, socket, "show") catch |e| log.warn("show: {t}", .{e});
            std.debug.print("Zugriff läuft bereits; Palette wird angezeigt.\n", .{});
            return;
        }

        const app = try nanoui.App.create(
            init,
            .{ .name = "Zugriff", .quit_on_last_window_closed = false, .activation = .accessory },
        );
        defer app.destroy();
        const agent = try gpa.create(Agent);
        defer gpa.destroy(agent);
        agent.* = .{ .gpa = gpa, .io = io, .home = home, .app = app };
        agent.palette = .init(
            gpa,
            io,
            home,
            .{ .ctx = agent, .emit = emitted, .clipboard = readClipboard, .now_ms = nowMs, .beep = beep },
        );
        defer agent.palette.deinit();
        defer agent.shutdown();

        // Window and hot keys first.
        agent.window = try app.newWindow(panel.options(
            .init(&agent.palette, Palette.view),
            theme.window,
            agent,
            keyChanged,
        ));
        panel.configure(agent.window);
        log.info("panel configured", .{});
        if (!app.flags.hidden) {
            agent.registerHotkeys(keys);
            agent.server = try control.Server.bind(
                io,
                socket,
                .{ .ctx = agent, .command = commandFromSocket, .status = status },
            );
            try agent.server.?.spawn();
        }

        // Content next, off the main thread.
        agent.scanner = .{ .ctx = agent, .scan = scan, .deliver = delivered };
        try agent.scanner.start();
        agent.scanning = true;
        agent.scanner.rescan();
        const prefs_file = try emoji_prefs.path(init.arena.allocator(), home);
        if (prefs_file) |file| {
            agent.prefs_writer = .{ .io = io, .file = file };
            try agent.prefs_writer.?.start();
            const t = try std.Thread.spawn(.{}, loadPrefs, .{ agent, file });
            t.detach();
        }
        try app.run();
        log.info("Zugriff beendet", .{});
    }

    /// After the run loop: background work ends, the last preferences are
    /// written, the clipboard gets its old items back and the socket goes.
    fn shutdown(a: *Agent) void {
        if (a.scanning) a.scanner.stop();
        if (a.prefs_writer) |*w| w.stop();
        if (a.server) |*s| s.unlink();
        if (a.staged) |s| _ = s.restore();
        if (a.inbox) |*list| list.deinit();
        for (a.icon_queue.items) |path| a.gpa.free(path);
        a.icon_queue.deinit(a.gpa);
        a.commands.deinit(a.gpa);
        for (a.deferred.items) |d| switch (d) {
            .activate => |action| freeAction(a.gpa, action),
            .copy, .insert => |t| a.gpa.free(t),
            else => {},
        };
        a.deferred.deinit(a.gpa);
    }

    fn registerHotkeys(a: *Agent, keys: Hotkeys) void {
        const bindings = [_]struct { ?[]const u8, *const fn (*anyopaque) void }{
            .{ keys.palette, togglePressed },
            .{ keys.emoji, emojiPressed },
        };
        for (bindings) |b| {
            const spec_text = b[0] orelse continue;
            const spec = hotkey.parse(spec_text) catch {
                log.err("ungültiger Hotkey {s}", .{spec_text});
                continue;
            };
            hotkey.register(spec, .{ .ctx = a, .func = b[1] }) catch |e| {
                log.err("globaler Hotkey {s} konnte nicht registriert werden: {t}", .{ spec_text, e });
                continue;
            };
            log.info("global hotkey registered: {s}", .{spec_text});
        }
    }

    fn togglePressed(ctx: *anyopaque) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        a.handle(.toggle);
    }

    fn emojiPressed(ctx: *anyopaque) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        a.handle(.emoji);
    }

    /// From the socket's thread: queued for the main thread.
    fn commandFromSocket(ctx: *anyopaque, c: control.Command) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        a.commands_mutex.lock();
        a.commands.append(a.gpa, c) catch |e| log.warn("Befehl {t} verworfen: {t}", .{ c, e });
        a.commands_mutex.unlock();
        _ = nanoui.App.onMain(a, drainCommands);
    }

    fn drainCommands(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Agent = @ptrCast(@alignCast(ctx.?));
        while (true) {
            a.commands_mutex.lock();
            const next = if (a.commands.items.len > 0) a.commands.orderedRemove(0) else null;
            a.commands_mutex.unlock();
            a.handle(next orelse return);
        }
    }

    fn status(_: *anyopaque, buf: []u8) []const u8 {
        return std.mem.print(buf, "Zugriff {s} (pid {d}); Bedienungshilfen: {s}; Eingabeschutz: {s}", .{
            build_options.version,
            std.c.getpid(),
            if (insert.isTrusted()) "erlaubt, ↵ fügt Emoji ein" else "fehlt, ↵ kopiert nur",
            if (insert.secureInputActive()) "an" else "aus",
        }) catch "Zugriff";
    }

    fn handle(a: *Agent, c: control.Command) void {
        log.debug("command {t}", .{c});
        switch (c) {
            .show => a.show(.apps),
            .hide => a.hide(),
            .toggle => if (a.visible and a.window.isFocused()) a.hide() else a.show(.apps),
            .emoji => if (a.visible and a.window.isFocused() and a.palette.showingEmoji()) a.hide() else a.show(.emoji),
            .quit => a.app.quit(),
        }
    }

    // Never activate the app here: the panel is non-activating, so it becomes
    // the key window while the app in front stays active.
    fn show(a: *Agent, view: View) void {
        // A fresh search, the calculation closed a moment ago, or the emoji
        // grid from static data; none waits for anything.
        const ready = switch (view) {
            .apps => a.palette.prepareShow(nowMs(a)),
            .emoji => a.palette.showEmoji(),
        };
        ready catch |e| log.err("Palette nicht bereit: {t}", .{e});
        panel.show(a.window);
        a.visible = true;
        // The icons the palette shows are wanted now; later shows have them.
        if (!a.icons_wanted) {
            a.icons_wanted = true;
            a.queuePendingIcons();
        }
        // The list on screen stays until the scan answers; typing never waits.
        a.scanner.rescan();
        // `:` opens the emoji picker from the app search too, so every show asks.
        const support: InsertSupport = if (!insert.isTrusted())
            .needs_permission
        else if (insert.secureInputActive())
            .secure_input
        else
            .ready;
        a.palette.setInsertSupport(support);
        a.window.redraw();
    }

    fn hide(a: *Agent) void {
        // Only a real close counts; `zugriff hide` on a hidden palette must
        // not keep the last calculation alive.
        if (a.visible) a.palette.closed(nowMs(a)) catch |e| log.warn("Schließen: {t}", .{e});
        a.visible = false;
        panel.hide(a.window);
    }

    /// The panel became or stopped being the key window. nanoui hides the
    /// popover when it loses the keys (a click elsewhere); that is a close.
    fn keyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (w.isFocused() or !a.visible) return;
        a.palette.closed(nowMs(a)) catch |e| log.warn("Schließen: {t}", .{e});
        a.visible = false;
    }

    // The palette's events, done after the frame that emitted them.

    fn emitted(ctx: *anyopaque, e: ui_palette.Event) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        const d: Deferred = switch (e) {
            .emoji_prefs => |p| {
                if (a.prefs_writer) |*w| w.put(p);
                return;
            },
            .dismiss => .dismiss,
            .activate => |action| .{ .activate = dupeAction(a.gpa, action) catch return },
            .copy => |t| .{ .copy = a.gpa.dupe(u8, t) catch return },
            .insert => |t| .{ .insert = a.gpa.dupe(u8, t) catch return },
            .request_insert_permission => .request_insert_permission,
            .quit => .quit,
        };
        a.deferred.append(a.gpa, d) catch return;
        if (!a.deferred_scheduled) {
            a.deferred_scheduled = true;
            nanoui.App.soon(a, runDeferred);
        }
    }

    fn runDeferred(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Agent = @ptrCast(@alignCast(ctx.?));
        a.deferred_scheduled = false;
        const items = a.deferred.toOwnedSlice(a.gpa) catch return;
        defer a.gpa.free(items);
        for (items) |d| switch (d) {
            .dismiss => a.hide(),
            .activate => |action| {
                a.hide();
                launch.perform(action);
                freeAction(a.gpa, action);
            },
            .copy => |t| {
                defer a.gpa.free(t);
                nanoui.clipboard.writeText(t);
                a.hide();
            },
            .insert => |t| {
                defer a.gpa.free(t);
                a.hide();
                a.insertText(t);
            },
            .request_insert_permission => {
                a.hide();
                log.info("Bedienungshilfen-Erlaubnis angefragt", .{});
                insert.requestTrust();
            },
            .quit => a.app.quit(),
        };
    }

    /// Inserts `text` into the app in front, or copies it when macOS would
    /// drop the synthetic `⌘V`.
    fn insertText(a: *Agent, text: []const u8) void {
        if (!insert.isTrusted()) {
            log.info("Einfügen ohne Bedienungshilfen-Erlaubnis: Emoji nur kopiert", .{});
            return nanoui.clipboard.writeText(text);
        }
        if (insert.secureInputActive()) {
            log.info("Eingabeschutz aktiv: Emoji nur kopiert", .{});
            return nanoui.clipboard.writeText(text);
        }
        if (a.staged) |old| {
            _ = old.restore();
            a.staged = null;
        }
        a.staged = insert.stage(text);
        nanoui.App.after(paste_delay_ms, a, paste);
    }

    fn paste(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Agent = @ptrCast(@alignCast(ctx.?));
        insert.postPaste() catch |e| {
            // The text stays on the pasteboard: copied instead of inserted.
            log.err("Emoji nicht eingefügt, es liegt in der Zwischenablage: {t}", .{e});
            if (a.staged) |s| s.discard();
            a.staged = null;
            return;
        };
        log.info("Emoji eingefügt: ⌘V gesendet", .{});
        nanoui.App.after(restore_delay_ms, a, restorePasteboard);
    }

    fn restorePasteboard(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Agent = @ptrCast(@alignCast(ctx.?));
        const s = a.staged orelse return;
        a.staged = null;
        log.info("Zwischenablage nach dem Einfügen wiederhergestellt: {}", .{s.restore()});
    }

    // The app list.

    fn scan(ctx: *anyopaque) ?apps.List {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        return apps.discover(a.gpa, a.io, a.home) catch |e| {
            log.err("App-Suche fehlgeschlagen: {t}", .{e});
            return null;
        };
    }

    /// On the scan thread: the newest list waits for the main thread.
    fn delivered(ctx: *anyopaque, list: apps.List) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        a.inbox_mutex.lock();
        if (a.inbox) |*old| old.deinit();
        a.inbox = list;
        a.inbox_mutex.unlock();
        _ = nanoui.App.onMain(a, takeList);
    }

    fn takeList(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Agent = @ptrCast(@alignCast(ctx.?));
        a.inbox_mutex.lock();
        var list = a.inbox orelse {
            a.inbox_mutex.unlock();
            return;
        };
        a.inbox = null;
        a.inbox_mutex.unlock();
        defer list.deinit();
        a.withCachedIcons(&list);
        const changed = a.palette.setCatalog(list.items) catch |e| {
            log.err("App-Liste nicht übernommen: {t}", .{e});
            return;
        };
        const missing = a.palette.pendingIcons(a.gpa) catch &.{};
        defer a.gpa.free(missing);
        if (a.first_list) {
            a.first_list = false;
            log.info("installierte Apps geladen: {d}, ohne Icon {d}", .{ list.items.len, missing.len });
            const t = std.Thread.spawn(.{}, pruneIcons, .{a}) catch null;
            if (t) |th| th.detach();
        } else if (changed) {
            log.info("App-Liste aktualisiert: {d}, ohne Icon {d}", .{ list.items.len, missing.len });
        } else return;
        // A resident agent that never opens the palette does not pay for the
        // icons; once it opened, new apps get theirs at once.
        if (a.icons_wanted) a.queuePendingIcons();
        a.window.redraw();
    }

    /// Looks again for icons the scan reported missing: they may have been
    /// rendered while it ran. File system only.
    fn withCachedIcons(a: *Agent, list: *apps.List) void {
        const al = list.arena.allocator();
        for (list.items) |*it| if (it.icon == null) switch (it.action) {
            .launch_application => |path| it.icon = icons.cached(al, a.io, a.home, path) catch null,
            else => {},
        };
    }

    fn pruneIcons(a: *Agent) void {
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const removed = icons.pruneCache(arena.allocator(), a.io, a.home, icon_max_age_s) catch 0;
        if (removed > 0) log.debug("Icon-Cache aufgeräumt: {d}", .{removed});
    }

    fn queuePendingIcons(a: *Agent) void {
        const pending = a.palette.pendingIcons(a.gpa) catch return;
        defer a.gpa.free(pending);
        for (pending) |path| {
            const known = for (a.icon_queue.items) |q| {
                if (std.mem.eql(u8, q, path)) break true;
            } else false;
            if (known) continue;
            const owned = a.gpa.dupe(u8, path) catch continue;
            a.icon_queue.append(a.gpa, owned) catch a.gpa.free(owned);
        }
        if (a.icon_queue.items.len > 0 and !a.icon_pass_running) {
            a.icon_pass_running = true;
            nanoui.App.after(0, a, iconBatch);
        }
    }

    /// Renders a few icons on the main thread (AppKit), then yields so the
    /// palette keeps drawing and reacting while the rest follow.
    fn iconBatch(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Agent = @ptrCast(@alignCast(ctx.?));
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        var n: usize = 0;
        var any = false;
        while (n < icons_per_batch and a.icon_queue.items.len > 0) : (n += 1) {
            const path = a.icon_queue.orderedRemove(0);
            defer a.gpa.free(path);
            const icon = icons.render(arena.allocator(), a.io, a.home, path) catch |e| {
                log.debug("kein App-Icon für {s}: {t}", .{ path, e });
                continue;
            };
            any = (a.palette.setIcon(path, icon) catch false) or any;
        }
        if (any) a.window.redraw();
        if (a.icon_queue.items.len > 0) {
            nanoui.App.after(icon_batch_pause_ms, a, iconBatch);
        } else {
            a.icon_pass_running = false;
            log.info("App-Icons geladen", .{});
        }
    }

    // The emoji preferences.

    fn loadPrefs(a: *Agent, file: []const u8) void {
        a.prefs_loaded = emoji_prefs.load(a.io, file);
        _ = nanoui.App.onMain(a, takePrefs);
    }

    fn takePrefs(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Agent = @ptrCast(@alignCast(ctx.?));
        const prefs = a.prefs_loaded orelse return;
        a.palette.setEmojiPrefs(prefs) catch |e| log.warn("Emoji-Einstellungen: {t}", .{e});
        a.window.redraw();
    }

    // The palette's host.

    fn readClipboard(_: *anyopaque, gpa: Allocator) ?[]u8 {
        return nanoui.clipboard.readText(gpa) catch null;
    }

    fn beep(_: *anyopaque) void {
        nanoui.shell.beep();
    }
};

pub fn nowMs(_: *anyopaque) i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn dupeAction(gpa: Allocator, action: core.Action) !core.Action {
    return switch (action) {
        .launch_application => |p| .{ .launch_application = try gpa.dupe(u8, p) },
        .open_path => |p| .{ .open_path = try gpa.dupe(u8, p) },
        .open_url => |u| .{ .open_url = try gpa.dupe(u8, u) },
        .reveal_path => |p| .{ .reveal_path = try gpa.dupe(u8, p) },
        .open_emoji_picker => .open_emoji_picker,
    };
}

fn freeAction(gpa: Allocator, action: core.Action) void {
    switch (action) {
        .launch_application, .open_path, .open_url, .reveal_path => |s| gpa.free(s),
        .open_emoji_picker => {},
    }
}

/// Microseconds of the monotonic clock, for timing.
pub fn nowUs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.us_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_us);
}
