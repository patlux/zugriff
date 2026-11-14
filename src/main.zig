//! Zugriff — a fast native command palette for macOS, in Zig on nanoui.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const core = @import("core.zig");
const agent = @import("agent.zig");
const control = @import("control.zig");
const apps = @import("mac/apps.zig");
const icons = @import("mac/icons.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const help =
    \\Zugriff — schnelle native Command Palette für macOS
    \\
    \\Befehle:
    \\  zugriff-zig                    Palette starten (Cmd+Space, Ctrl+Cmd+Space)
    \\  zugriff-zig run [--hotkey <spec>] [--emoji-hotkey <spec|none>] [--unload-after <s|never>]
    \\                                 Palette mit eigenen Hotkeys starten; mit --unload-after
    \\                                 wird sie nach so vielen Sekunden Ruhe entladen (weniger
    \\                                 RAM, das nächste Öffnen dauert etwas länger)
    \\  zugriff-zig show               Laufende Palette anzeigen
    \\  zugriff-zig hide               Laufende Palette ausblenden
    \\  zugriff-zig toggle             Laufende Palette umschalten
    \\  zugriff-zig emoji              Emoji-Auswahl anzeigen (Ctrl+Cmd+Space)
    \\  zugriff-zig quit               Laufende Palette beenden
    \\  zugriff-zig status             Version und Einfüge-Erlaubnis der laufenden Palette
    \\  zugriff-zig apps [query]       Installierte Apps suchen (ohne UI)
    \\  zugriff-zig emojis [suche]     Emoji suchen wie in der Palette (ohne UI)
    \\  zugriff-zig icons              App-Icons in den Cache rendern (ohne UI)
    \\  zugriff-zig calc <aufgabe>     Aufgabe rechnen wie in der Palette (ohne UI)
    \\  zugriff-zig --version          Version
    \\
    \\Hotkey-Beispiele: cmd+space, ctrl+cmd+space, alt+space, ctrl+shift+space, cmd+k
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const home = init.environ_map.get("HOME");
    const all_args = try init.minimal.args.toSlice(arena);
    // nanoui's own flags (`--nanoui-snapshot=…`) belong to the agent.
    var args: std.ArrayList([]const u8) = .empty;
    for (all_args[1..]) |arg| if (!std.mem.startsWith(u8, arg, "--nanoui-")) try args.append(arena, arg);

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};

    const command = if (args.items.len > 0) args.items[0] else "run";
    const rest = if (args.items.len > 0) args.items[1..] else args.items;
    if (std.mem.eql(u8, command, "run")) {
        const keys = parseRun(rest) catch |e| {
            std.debug.print("zugriff-zig: {s}\n", .{switch (e) {
                error.MissingValue => "die Option braucht einen Wert",
                error.UnknownOption => "unbekannte Option für `run`",
                error.InvalidValue => "`--unload-after` erwartet Sekunden oder `never`",
            }});
            std.process.exit(1);
        };
        // The agent stays resident: outside Debug it allocates with malloc,
        // which packs small blocks and returns freed pages, instead of the
        // checking allocator ReleaseSafe gets by default.
        var resident = init;
        if (builtin.mode != .debug) resident.gpa = std.heap.c_allocator;
        return agent.Agent.run(resident.gpa, io, home, resident, keys);
    }
    if (control.Command.parse(command) != null or std.mem.eql(u8, command, "status")) {
        const socket = try control.socketPath(arena, home);
        const answer = control.request(arena, io, socket, command) catch |e| {
            std.debug.print("zugriff-zig: Zugriff läuft nicht ({t}); starte ihn mit `zugriff-zig`\n", .{e});
            std.process.exit(1);
        };
        if (std.mem.eql(u8, command, "status")) try out.print("{s}\n", .{answer});
        return;
    }
    if (std.mem.eql(u8, command, "apps")) return listApps(arena, io, home, out, try std.mem.join(arena, " ", rest));
    if (std.mem.eql(u8, command, "emojis")) return listEmoji(arena, out, try std.mem.join(arena, " ", rest));
    if (std.mem.eql(u8, command, "icons")) return warmIcons(arena, io, home, out);
    if (std.mem.eql(u8, command, "calc")) return printCalculation(arena, out, try std.mem.join(arena, " ", rest));
    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        return out.print("zugriff {s}\n", .{build_options.version});
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        return out.writeAll(help);
    }
    std.debug.print("Unbekannter Befehl: {s}\n\n{s}", .{ command, help });
    std.process.exit(1);
}

fn parseRun(args: []const []const u8) error{ MissingValue, UnknownOption, InvalidValue }!agent.Settings {
    var keys: agent.Settings = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--hotkey")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            keys.palette = args[i];
        } else if (std.mem.eql(u8, arg, "--emoji-hotkey")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            keys.emoji = if (std.mem.eql(u8, args[i], "none")) null else args[i];
        } else if (std.mem.eql(u8, arg, "--unload-after")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            keys.unload_after_s = if (std.mem.eql(u8, args[i], "never"))
                null
            else
                std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidValue;
        } else return error.UnknownOption;
    }
    return keys;
}

fn listApps(a: std.mem.Allocator, io: std.Io, home: ?[]const u8, out: *std.Io.Writer, query_text: []const u8) !void {
    var list = try apps.discover(a, io, home);
    defer list.deinit();
    var catalog = try core.Catalog.init(a, list.items);
    defer catalog.deinit();
    const query = try core.Query.init(a, query_text);
    const hits = try catalog.search(a, query);
    try out.print("{d} Apps, {d} Treffer\n", .{ catalog.len(), hits.len });
    for (hits[0..@min(hits.len, 50)]) |hit| {
        const it = catalog.items[hit.index];
        try out.print("{s:>8}  {s:<34}  {s}\n", .{ try a.print("{d}", .{hit.score}), it.title, it.subtitle });
    }
}

/// Searches the emoji like the picker and prints the best hits.
fn listEmoji(a: std.mem.Allocator, out: *std.Io.Writer, query: []const u8) !void {
    const count = core.emoji.table_len;
    if (core.text.trim(query).len == 0) return out.print("{d} Emoji\n", .{count});
    const hits = try core.emoji.search(a, query, &.{});
    try out.print("{d} Emoji, {d} Treffer\n", .{ count, hits.len });
    for (hits[0..@min(hits.len, 30)]) |i| {
        const e = core.emoji.get(i);
        try out.print("{s}  {s:<44} ", .{ e.glyph, e.name });
        var codes = e.shortcodes();
        while (codes.next()) |code| try out.print(":{s}: ", .{code});
        try out.writeAll("\n");
    }
}

/// Renders every app icon into the cache without starting the palette: the
/// AppKit work the palette does after it became visible, ahead of time.
fn warmIcons(a: std.mem.Allocator, io: std.Io, home: ?[]const u8, out: *std.Io.Writer) !void {
    var list = try apps.discover(a, io, home);
    defer list.deinit();
    var reused: usize = 0;
    var rendered: usize = 0;
    var missing: usize = 0;
    for (list.items) |it| switch (it.action) {
        .launch_application => |path| {
            if (it.icon != null) {
                reused += 1;
                continue;
            }
            if (icons.render(a, io, home, path)) |_| {
                rendered += 1;
            } else |_| missing += 1;
        },
        else => {},
    };
    try out.print("{d} Icons aus dem Cache, {d} neu gerendert, {d} ohne Icon\n", .{ reused, rendered, missing });
}

/// Calculates like the palette and prints the reading, the result, the
/// other readings and the time it took.
fn printCalculation(a: std.mem.Allocator, out: *std.Io.Writer, task: []const u8) !void {
    const started = agent.nowUs();
    const calculation = try core.calc.calculate(a, task, 500 * std.time.ns_per_ms);
    const elapsed = agent.nowUs() - started;
    const c = calculation orelse return out.writeAll("Keine Rechnung: Zugriff sucht dafür Apps.\n");
    try out.print("Aufgabe:   {s}\n", .{c.task});
    if (c.skipped.len > 0) try out.print("Übergangen: {s}\n", .{try std.mem.join(a, ", ", c.skipped)});
    switch (c.outcome) {
        .answer => |ans| {
            try out.print("Ergebnis:  {s}\n", .{try ans.shown(a)});
            try out.print("Kopiert:   {s}  |  Nur Zahl: {s}\n", .{ ans.text, ans.number });
        },
        .problem => |p| try out.print("Kein Ergebnis: {t}\n", .{p}),
    }
    for (c.alternatives) |alt| try out.print(
        "Auch:      {s} {s} {s}\n",
        .{ alt.task, alt.answer.relation(), alt.answer.text },
    );
    try out.print("Zeit:      {d} µs\n", .{elapsed});
}

test {
    _ = parseRun;
}

test "run takes its hot keys" {
    const keys = try parseRun(&.{ "--hotkey", "alt+space", "--emoji-hotkey", "none" });
    try std.testing.expectEqualStrings("alt+space", keys.palette);
    try std.testing.expect(keys.emoji == null);
    try std.testing.expectError(error.MissingValue, parseRun(&.{"--hotkey"}));
    try std.testing.expectError(error.UnknownOption, parseRun(&.{"--fast"}));
}

test "run takes how long the hidden palette stays loaded" {
    try std.testing.expect((try parseRun(&.{})).unload_after_s == null);
    try std.testing.expectEqual(@as(?u32, 90), (try parseRun(&.{ "--unload-after", "90" })).unload_after_s);
    try std.testing.expect((try parseRun(&.{ "--unload-after", "never" })).unload_after_s == null);
    try std.testing.expectError(error.InvalidValue, parseRun(&.{ "--unload-after", "bald" }));
    try std.testing.expectError(error.MissingValue, parseRun(&.{"--unload-after"}));
}
