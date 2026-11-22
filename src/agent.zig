//! The resident agent: the panel, the hot keys, the control socket, the
//! app scan, the icons and what the palette's events do.
//!
//! Opening contract (AGENTS.md): panel and hot keys first; content work
//! starts only after the palette can open. Do not move app discovery into
//! the start path. With `--unload-after` the panel is closed after that
//! long unused and made again by the next show; that is opt-in. With
//! `--unload-mode process` this agent is the UI process `daemon.zig`
//! starts: no hot keys, a private socket, and it ends instead.
const std = @import("std");
const Allocator = std.mem.Allocator;
const nanoui = @import("nanoui");
const build_options = @import("build_options");
const core = @import("core.zig");
const ui_palette = @import("ui/palette.zig");
const theme = @import("ui/theme.zig");
const control = @import("control.zig");
const messages = @import("messages.zig");
const app_scan = @import("app_scan.zig");
const emoji_prefs = @import("emoji_prefs.zig");
const help_seen = @import("help_seen.zig");
const sync = @import("sync.zig");
const apps = @import("mac/apps.zig");
const icons = @import("mac/icons.zig");
const hotkey = @import("mac/hotkey.zig");
const insert = @import("mac/insert.zig");
const launch = @import("mac/launch.zig");
const panel = @import("mac/panel.zig");
const catcher = @import("mac/catcher.zig");
const intelligence = @import("mac/intelligence.zig");
const Palette = ui_palette.Palette;
const InsertSupport = ui_palette.InsertSupport;

const log = std.log.scoped(.zugriff);

pub const Settings = struct {
    /// The palette's texts and emoji names, and the calculator's notation;
    /// `main` sets it from `--language` or from macOS.
    locale: core.Locale = .both(.en),
    /// `--language`, which the daemon hands on to the UI process.
    chosen_language: ?core.Language = null,
    palette: []const u8 = "cmd+space",
    /// The macOS character viewer's shortcut; null: no emoji hot key.
    emoji: ?[]const u8 = "ctrl+cmd+space",
    /// Seconds the hidden panel stays before it is closed to free its
    /// memory; null: it stays (the next show is then a single frame).
    unload_after_s: ?u32 = null,
    /// What goes after `unload_after_s`: the window, or the whole UI
    /// process (a small daemon keeps the hot keys, `daemon.zig`).
    unload_mode: UnloadMode = .window,
    /// The UI process's own: its private socket instead of the public one,
    /// no hot keys (the daemon has them) and the command it was started for.
    socket: ?[]const u8 = null,
    hotkeys: bool = true,
    then: ?control.Command = null,
};

pub const UnloadMode = enum { window, process };

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
/// A show within this long of the last scan request does not ask again.
const rescan_gap_ms = 2000;

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
    settings: Settings = .{},
    /// The panel; null while unloaded (`--unload-after`).
    window: ?*nanoui.Window = null,
    /// When the hidden panel may be closed (`nowMs`).
    unload_due_ms: i64 = 0,
    /// When the last show began (`nowUs`), until the panel has the keys.
    show_started_us: ?i64 = null,
    /// When the last app scan was asked for (`nowMs`).
    scan_asked_ms: ?i64 = null,
    /// A UI process the daemon started (`--unload-mode process`): the
    /// daemon's socket, where the keys typed during the start wait until
    /// the panel has the keyboard.
    daemon_socket: ?[]const u8 = null,
    /// Typed-ahead keys from the first ↵, ⎋, ⇥, ↑ or ↓ on, held until the
    /// first app list is in: ↵ before it would find no app.
    ahead: [catcher.max_bytes]u8 = undefined,
    ahead_len: usize = 0,
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
    /// The marker that the help was opened once, and what reading it found.
    help_seen_file: ?[]const u8 = null,
    help_seen_loaded: ?bool = null,
    server: ?control.Server = null,
    staged: ?insert.Staged = null,

    pub fn run(gpa: Allocator, io: std.Io, home: ?[]const u8, init: std.process.Init, settings: Settings) !void {
        const socket = settings.socket orelse try control.socketPath(init.arena.allocator(), home);
        if (control.isRunning(io, socket)) {
            _ = control.request(init.arena.allocator(), io, socket, "show") catch |e| log.warn("show: {t}", .{e});
            std.debug.print("{s}", .{messages.of(settings.locale.language).already_running});
            return;
        }

        intelligence.optOut();
        const app = try nanoui.App.create(
            init,
            .{ .name = "Zugriff", .quit_on_last_window_closed = false, .activation = .accessory },
        );
        defer app.destroy();
        log.info("App angelegt", .{});
        // The first show asks for the Accessibility permission; ask now, aside.
        insert.prefetchTrust();
        const agent = try gpa.create(Agent);
        defer gpa.destroy(agent);
        agent.* = .{ .gpa = gpa, .io = io, .home = home, .app = app, .settings = settings };
        agent.palette = .init(
            gpa,
            io,
            home,
            settings.locale,
            .{ .ctx = agent, .emit = emitted, .clipboard = readClipboard, .now_ms = nowMs, .beep = beep },
        );
        defer agent.palette.deinit();
        defer agent.shutdown();

        // Window and hot keys first.
        _ = try agent.openWindow();
        log.info("Fenster angelegt", .{});
        if (!app.flags.hidden) {
            if (settings.hotkeys) registerHotkeys(settings, agent, togglePressed, emojiPressed);
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
        agent.requestScan();
        // The command the daemon started this UI process for, at once: the
        // panel shows while the scan runs and the run loop starts.
        if (settings.then) |c| {
            if (settings.socket != null) agent.daemon_socket = try control.socketPath(init.arena.allocator(), home);
            agent.handle(c);
        } else agent.scheduleUnload();
        const prefs_file = try emoji_prefs.path(init.arena.allocator(), home);
        agent.help_seen_file = try help_seen.path(init.arena.allocator(), home);
        if (prefs_file) |file| {
            agent.prefs_writer = .{ .io = io, .file = file };
            try agent.prefs_writer.?.start();
        }
        if (prefs_file != null or agent.help_seen_file != null) {
            const t = try std.Thread.spawn(.{}, loadPrefs, .{ agent, prefs_file });
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

    /// The panel, made if it was unloaded.
    fn openWindow(a: *Agent) !*nanoui.Window {
        if (a.window) |w| return w;
        const w = try a.app.newWindow(panel.options(
            .init(&a.palette, Palette.view),
            theme.window,
            a,
            keyChanged,
            windowClosed,
        ));
        panel.configure(w);
        a.window = w;
        return w;
    }

    /// nanoui frees the window after this; the next show makes a new one.
    fn windowClosed(ctx: *anyopaque, w: *nanoui.Window) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (a.window == w) a.window = null;
    }

    fn redraw(a: *Agent) void {
        if (a.window) |w| w.redraw();
    }

    fn focused(a: *Agent) bool {
        const w = a.window orelse return false;
        return a.visible and w.isFocused();
    }

    /// With `--unload-after`: closes the panel once it has stayed hidden
    /// that long. A show in between moves the moment on.
    fn scheduleUnload(a: *Agent) void {
        const s = a.settings.unload_after_s orelse return;
        const ms = @as(u64, s) * std.time.ms_per_s;
        a.unload_due_ms = nowMs(a) + @as(i64, @intCast(ms));
        switch (a.settings.unload_mode) {
            .window => log.info("Ruhezeit beginnt: Fenster wird in {d} s entladen", .{s}),
            .process => log.info("Ruhezeit beginnt: UI-Prozess endet in {d} s", .{s}),
        }
        nanoui.App.after(ms, a, unloadIfIdle);
    }

    fn unloadIfIdle(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Agent = @ptrCast(@alignCast(ctx.?));
        if (a.visible or nowMs(a) < a.unload_due_ms) return;
        if (a.settings.unload_mode == .process) {
            log.info("UI-Prozess beendet sich; der nächste Aufruf startet ihn neu", .{});
            return a.app.quit();
        }
        const w = a.window orelse return;
        a.palette.unloaded();
        w.close();
        log.info("Palette entladen; der nächste Aufruf legt sie neu an", .{});
    }

    fn takeTypedAhead(a: *Agent, socket: []const u8) void {
        a.daemon_socket = null;
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const answer = control.request(fba.allocator(), a.io, socket, control.typed_request) catch |e|
            return log.warn("getippte Tasten nicht abgeholt: {t}", .{e});
        if (answer.len < 2 or answer[0] != '[' or answer[answer.len - 1] != ']')
            return log.warn("getippte Tasten unlesbar", .{});
        const typed = answer[1 .. answer.len - 1];
        if (typed.len == 0) return;
        log.info("vor dem Start getippt: {d} Bytes", .{typed.len});
        a.playTyped(typed);
        a.redraw();
    }

    /// Types the text into the query and presses the keys, in order; from
    /// the first key on it waits for the first app list (`ahead`).
    fn playTyped(a: *Agent, typed: []const u8) void {
        var it = catcher.tokens(typed);
        while (true) {
            const rest = it.rest;
            const token = it.next() orelse break;
            switch (token) {
                .text => |t| a.palette.typeAhead(t) catch |e|
                    return log.warn("getippte Tasten nicht übernommen: {t}", .{e}),
                .key => |k| {
                    if (a.first_list) {
                        @memcpy(a.ahead[0..rest.len], rest);
                        a.ahead_len = rest.len;
                        return log.info("getippte Tasten warten auf die App-Liste", .{});
                    }
                    const key: ui_palette.Pressed = switch (k.special) {
                        .enter => .enter,
                        .escape => .escape,
                        .tab => .tab,
                        .up => .up,
                        .down => .down,
                    };
                    const mods: ui_palette.Mods = .{
                        .shift = k.mods.shift,
                        .alt = k.mods.option,
                        .cmd = k.mods.command,
                    };
                    a.palette.pressAhead(key, mods) catch |e| return log.warn("getippte Taste {t}: {t}", .{ key, e });
                    log.info("getippte Taste abgespielt: {t}", .{key});
                },
            }
        }
    }

    /// Asks the scan thread for a fresh app list, unless one was asked for
    /// a moment ago (a UI process that starts and shows at once).
    fn requestScan(a: *Agent) void {
        const now = nowMs(a);
        if (a.scan_asked_ms) |t| if (now - t < rescan_gap_ms) return;
        a.scan_asked_ms = now;
        a.scanner.rescan();
    }

    fn togglePressed(ctx: *anyopaque) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        log.info("Hotkey: Palette", .{});
        a.handle(.toggle);
    }

    fn emojiPressed(ctx: *anyopaque) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        log.info("Hotkey: Emoji", .{});
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
            const c = next orelse return;
            log.info("Befehl über Socket: {t}", .{c});
            a.handle(c);
        }
    }

    fn status(ctx: *anyopaque, buf: []u8) []const u8 {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        const lang = a.settings.locale.language;
        const m = messages.of(lang);
        return messages.bufPrint(buf, lang, "status", .{
            build_options.version,
            std.c.getpid(),
            if (insert.isTrusted()) m.permission_granted else m.permission_missing,
            if (insert.secureInputActive()) m.on else m.off,
        }) catch "Zugriff";
    }

    fn handle(a: *Agent, c: control.Command) void {
        switch (c) {
            .show => a.show(.apps),
            .hide => a.hide("Befehl"),
            .toggle => if (a.focused()) a.hide("Umschalten") else a.show(.apps),
            .emoji => if (a.focused() and a.palette.showingEmoji()) a.hide("Umschalten") else a.show(.emoji),
            .quit => {
                log.info("beendet sich auf Befehl", .{});
                a.app.quit();
            },
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
        // `:` opens the emoji picker from the app search too, so every show asks.
        // Before the panel draws: its first frame shows the right note.
        const support: InsertSupport = if (!insert.isTrusted())
            .needs_permission
        else if (insert.secureInputActive())
            .secure_input
        else
            .ready;
        a.palette.setInsertSupport(support);
        const made = a.window == null;
        const start_us = nowUs();
        const w = a.openWindow() catch |e| return log.err("Palette lässt sich nicht anlegen: {t}", .{e});
        if (made) {
            log.info("zeigt {t}: Fenster neu angelegt in {d} µs", .{ view, nowUs() - start_us });
        } else log.info("zeigt {t}", .{view});
        a.show_started_us = start_us;
        panel.show(w);
        a.visible = true;
        // The icons the palette shows are wanted now; later shows have them.
        if (!a.icons_wanted) {
            a.icons_wanted = true;
            a.queuePendingIcons();
        }
        // The list on screen stays until the scan answers; typing never waits.
        a.requestScan();
        // Also after `panel.show` drew: restarting the display link there
        // drops nanoui's request for the frames that follow (the emoji
        // pictures load over several frames), and this asks for them again.
        w.redraw();
    }

    fn hide(a: *Agent, why: []const u8) void {
        if (a.visible) log.info("versteckt ({s})", .{why});
        // Only a real close counts; `zugriff hide` on a hidden palette must
        // not keep the last calculation alive.
        if (a.visible) a.palette.closed(nowMs(a)) catch |e| log.warn("Schließen: {t}", .{e});
        a.visible = false;
        if (a.window) |w| panel.hide(w);
        a.scheduleUnload();
    }

    /// The panel became or stopped being the key window. nanoui hides the
    /// popover when it loses the keys (a click elsewhere); that is a close.
    fn keyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (w.isFocused()) {
            // The first time after a show: the panel is on screen and typing goes to it.
            if (a.show_started_us) |t|
                log.info("Palette vorne mit Tastatur nach {d} ms", .{@divTrunc(nowUs() - t, 1000)});
            a.show_started_us = null;
            // Keys typed later come here; those before wait at the daemon.
            // They go into the query before the queued key events run.
            if (a.daemon_socket) |socket| a.takeTypedAhead(socket);
            return;
        }
        if (!a.visible) return;
        log.info("versteckt (Fokus verloren)", .{});
        a.palette.closed(nowMs(a)) catch |e| log.warn("Schließen: {t}", .{e});
        a.visible = false;
        panel.release(w);
        a.scheduleUnload();
    }

    // The palette's events, done after the frame that emitted them.

    fn emitted(ctx: *anyopaque, e: ui_palette.Event) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        const d: Deferred = switch (e) {
            .emoji_prefs => |p| {
                if (a.prefs_writer) |*w| w.put(p);
                return;
            },
            .help_seen => {
                if (a.help_seen_file) |file| help_seen.markInBackground(a.io, file);
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
            .dismiss => a.hide("Escape"),
            .activate => |action| {
                a.hide("Aktion");
                logAction(action);
                launch.perform(action);
                freeAction(a.gpa, action);
            },
            .copy => |t| {
                defer a.gpa.free(t);
                nanoui.clipboard.writeText(t);
                log.info("kopiert: {d} Bytes", .{t.len});
                a.hide("kopiert");
            },
            .insert => |t| {
                defer a.gpa.free(t);
                a.hide("Einfügen");
                a.insertText(t);
            },
            .request_insert_permission => {
                a.hide("Erlaubnis");
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
        const started = nowUs();
        const list = apps.discover(a.gpa, a.io, a.home) catch |e| {
            log.err("App-Suche fehlgeschlagen: {t}", .{e});
            return null;
        };
        log.info("App-Suche: {d} Apps in {d} ms", .{ list.items.len, @divTrunc(nowUs() - started, 1000) });
        return list;
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
            if (a.ahead_len > 0) {
                var held: [catcher.max_bytes]u8 = undefined;
                const n = a.ahead_len;
                @memcpy(held[0..n], a.ahead[0..n]);
                a.ahead_len = 0;
                a.playTyped(held[0..n]);
            }
            log.info("installierte Apps geladen: {d}, ohne Icon {d}", .{ list.items.len, missing.len });
            const t = std.Thread.spawn(.{}, pruneIcons, .{a}) catch null;
            if (t) |th| th.detach();
        } else if (changed) {
            log.info("App-Liste aktualisiert: {d}, ohne Icon {d}", .{ list.items.len, missing.len });
        } else return;
        // A resident agent that never opens the palette does not pay for the
        // icons; once it opened, new apps get theirs at once.
        if (a.icons_wanted) a.queuePendingIcons();
        a.redraw();
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
        if (any) a.redraw();
        if (a.icon_queue.items.len > 0) {
            nanoui.App.after(icon_batch_pause_ms, a, iconBatch);
        } else {
            a.icon_pass_running = false;
            log.info("App-Icons geladen", .{});
        }
    }

    // The emoji preferences and the help marker.

    fn loadPrefs(a: *Agent, file: ?[]const u8) void {
        if (file) |f| a.prefs_loaded = emoji_prefs.load(a.io, f);
        if (a.help_seen_file) |f| a.help_seen_loaded = help_seen.load(a.io, f);
        _ = nanoui.App.onMain(a, takePrefs);
    }

    fn takePrefs(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Agent = @ptrCast(@alignCast(ctx.?));
        if (a.prefs_loaded) |prefs| a.palette.setEmojiPrefs(prefs) catch |e| log.warn("Emoji-Einstellungen: {t}", .{e});
        if (a.help_seen_loaded) |seen| a.palette.setHelpSeen(seen);
        a.redraw();
    }

    // The palette's host.

    fn readClipboard(_: *anyopaque, gpa: Allocator) ?[]u8 {
        return nanoui.clipboard.readText(gpa) catch null;
    }

    fn beep(_: *anyopaque) void {
        nanoui.shell.beep();
    }
};

/// What an activated row does, for the log.
fn logAction(action: core.Action) void {
    switch (action) {
        .open_url => |u| log.info("öffnet Adresse {s}", .{u}),
        else => if (action.path()) |p| log.info("{t}: {s}", .{ action, p }) else log.info("{t}", .{action}),
    }
}

/// The palette and emoji hot keys of `keys`, calling `on_palette` and
/// `on_emoji` with `ctx`; the agent's and the daemon's.
pub fn registerHotkeys(
    keys: Settings,
    ctx: *anyopaque,
    on_palette: *const fn (*anyopaque) void,
    on_emoji: *const fn (*anyopaque) void,
) void {
    const bindings = [_]struct { ?[]const u8, *const fn (*anyopaque) void }{
        .{ keys.palette, on_palette },
        .{ keys.emoji, on_emoji },
    };
    for (bindings) |b| {
        const spec_text = b[0] orelse continue;
        const spec = hotkey.parse(spec_text) catch {
            log.err("ungültiger Hotkey {s}", .{spec_text});
            continue;
        };
        hotkey.register(spec, .{ .ctx = ctx, .func = b[1] }) catch |e| {
            log.err("globaler Hotkey {s} konnte nicht registriert werden: {t}", .{ spec_text, e });
            continue;
        };
        log.info("global hotkey registered: {s}", .{spec_text});
    }
}

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
        .open_help => .open_help,
    };
}

fn freeAction(gpa: Allocator, action: core.Action) void {
    switch (action) {
        .launch_application, .open_path, .open_url, .reveal_path => |s| gpa.free(s),
        .open_emoji_picker, .open_help => {},
    }
}

/// Microseconds of the monotonic clock, for timing.
pub fn nowUs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.us_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_us);
}
