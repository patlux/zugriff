//! The texts of the command line and the control socket, in German and in
//! English; the palette's own are in `ui/texts.zig`. Fields with `{s}`,
//! `{d}` or `{t}` are format strings for `std.fmt`.
const std = @import("std");
const core = @import("core.zig");
const Language = core.Language;

pub const Messages = struct {
    help: []const u8,
    /// `{s}`: the command, `{s}`: `help`.
    unknown_command: []const u8,
    /// `{t}`: the error.
    not_running: []const u8,
    already_running: []const u8,
    option_missing_value: []const u8,
    option_unknown: []const u8,
    option_invalid: []const u8,
    option_process_needs_time: []const u8,
    option_language: []const u8,
    /// `{d}` apps, `{d}` hits.
    apps_found: []const u8,
    /// `{d}`.
    emoji_total: []const u8,
    /// `{d}` emoji, `{d}` hits.
    emoji_found: []const u8,
    /// `{d}` from the cache, `{d}` rendered, `{d}` without an icon.
    icons_done: []const u8,
    calc_none: []const u8,
    /// `{s}` each.
    calc_task: []const u8,
    calc_skipped: []const u8,
    calc_result: []const u8,
    calc_copies: []const u8,
    /// `{t}`: the problem.
    calc_problem: []const u8,
    calc_also: []const u8,
    /// `{d}` µs.
    calc_time: []const u8,
    /// `{s}` version, `{d}` pid, `{s}` permission, `{s}` secure input.
    status: []const u8,
    permission_granted: []const u8,
    permission_missing: []const u8,
    on: []const u8,
    off: []const u8,
    /// `{s}` version, `{d}` pid, `{s}` the UI process's status.
    daemon_status: []const u8,
    ui_not_loaded: []const u8,
};

pub const de: Messages = .{
    .help =
    \\Zugriff — schnelle native Command Palette für macOS
    \\
    \\Befehle:
    \\  zugriff                        Palette starten (Cmd+Space, Ctrl+Cmd+Space)
    \\  zugriff run [--hotkey <spec>] [--emoji-hotkey <spec|none>]
    \\              [--unload-after <s|never>] [--unload-mode window|process]
    \\                                 Palette mit eigenen Hotkeys starten; mit --unload-after
    \\                                 wird sie nach so vielen Sekunden Ruhe entladen: das
    \\                                 Fenster (window: ~30 MB, Öffnen ~10 ms langsamer) oder
    \\                                 der UI-Prozess (process: ~10 MB, ~90 ms langsamer)
    \\  zugriff show                   Laufende Palette anzeigen
    \\  zugriff hide                   Laufende Palette ausblenden
    \\  zugriff toggle                 Laufende Palette umschalten
    \\  zugriff emoji                  Emoji-Auswahl anzeigen (Ctrl+Cmd+Space)
    \\  zugriff quit                   Laufende Palette beenden
    \\  zugriff status                 Version und Einfüge-Erlaubnis der laufenden Palette
    \\  zugriff apps [query]           Installierte Apps suchen (ohne UI)
    \\  zugriff emojis [suche]         Emoji suchen wie in der Palette (ohne UI)
    \\  zugriff icons                  App-Icons in den Cache rendern (ohne UI)
    \\  zugriff calc <aufgabe>         Aufgabe rechnen wie in der Palette (ohne UI)
    \\  zugriff --version              Version
    \\
    \\Jeder Befehl nimmt --language de|en; ohne die Option gilt die Sprache von macOS.
    \\Hotkey-Beispiele: cmd+space, ctrl+cmd+space, alt+space, ctrl+shift+space, cmd+k
    \\
    ,
    .unknown_command = "Unbekannter Befehl: {s}\n\n{s}",
    .not_running = "zugriff: Zugriff läuft nicht ({t}); starte ihn mit `zugriff`\n",
    .already_running = "Zugriff läuft bereits; Palette wird angezeigt.\n",
    .option_missing_value = "die Option braucht einen Wert",
    .option_unknown = "unbekannte Option für `run`",
    .option_invalid = "`--unload-after` erwartet Sekunden oder `never`, `--unload-mode` window oder process",
    .option_process_needs_time = "`--unload-mode process` braucht `--unload-after <sekunden>`",
    .option_language = "`--language` erwartet de oder en",
    .apps_found = "{d} Apps, {d} Treffer\n",
    .emoji_total = "{d} Emoji\n",
    .emoji_found = "{d} Emoji, {d} Treffer\n",
    .icons_done = "{d} Icons aus dem Cache, {d} neu gerendert, {d} ohne Icon\n",
    .calc_none = "Keine Rechnung: Zugriff sucht dafür Apps.\n",
    .calc_task = "Aufgabe:   {s}\n",
    .calc_skipped = "Übergangen: {s}\n",
    .calc_result = "Ergebnis:  {s}\n",
    .calc_copies = "Kopiert:   {s}  |  Nur Zahl: {s}\n",
    .calc_problem = "Kein Ergebnis: {t}\n",
    .calc_also = "Auch:      {s} {s} {s}\n",
    .calc_time = "Zeit:      {d} µs\n",
    .status = "Zugriff {s} (pid {d}); Bedienungshilfen: {s}; Eingabeschutz: {s}",
    .permission_granted = "erlaubt, ↵ fügt Emoji ein",
    .permission_missing = "fehlt, ↵ kopiert nur",
    .on = "an",
    .off = "aus",
    .daemon_status = "Zugriff {s} Daemon (pid {d}); {s}",
    .ui_not_loaded = "UI-Prozess nicht geladen",
};

pub const en: Messages = .{
    .help =
    \\Zugriff — a fast, native command palette for macOS
    \\
    \\Commands:
    \\  zugriff                        Start the palette (Cmd+Space, Ctrl+Cmd+Space)
    \\  zugriff run [--hotkey <spec>] [--emoji-hotkey <spec|none>]
    \\              [--unload-after <s|never>] [--unload-mode window|process]
    \\                                 Start the palette with your own hot keys; with --unload-after
    \\                                 it is unloaded after that many idle seconds: the
    \\                                 window (window: ~30 MB, opening ~10 ms slower) or
    \\                                 the UI process (process: ~10 MB, ~90 ms slower)
    \\  zugriff show                   Show the running palette
    \\  zugriff hide                   Hide the running palette
    \\  zugriff toggle                 Show or hide the running palette
    \\  zugriff emoji                  Show the emoji picker (Ctrl+Cmd+Space)
    \\  zugriff quit                   Quit the running palette
    \\  zugriff status                 Version and insert permission of the running palette
    \\  zugriff apps [query]           Search the installed apps (no UI)
    \\  zugriff emojis [query]         Search emoji as the palette does (no UI)
    \\  zugriff icons                  Render the app icons into the cache (no UI)
    \\  zugriff calc <task>            Calculate a task as the palette does (no UI)
    \\  zugriff --version              Version
    \\
    \\Every command takes --language de|en; without it, the language of macOS applies.
    \\Hot key examples: cmd+space, ctrl+cmd+space, alt+space, ctrl+shift+space, cmd+k
    \\
    ,
    .unknown_command = "Unknown command: {s}\n\n{s}",
    .not_running = "zugriff: Zugriff is not running ({t}); start it with `zugriff`\n",
    .already_running = "Zugriff is already running; showing the palette.\n",
    .option_missing_value = "the option needs a value",
    .option_unknown = "unknown option for `run`",
    .option_invalid = "`--unload-after` takes seconds or `never`, `--unload-mode` window or process",
    .option_process_needs_time = "`--unload-mode process` needs `--unload-after <seconds>`",
    .option_language = "`--language` takes de or en",
    .apps_found = "{d} apps, {d} results\n",
    .emoji_total = "{d} emoji\n",
    .emoji_found = "{d} emoji, {d} results\n",
    .icons_done = "{d} icons from the cache, {d} rendered, {d} without an icon\n",
    .calc_none = "No calculation: Zugriff searches apps for this.\n",
    .calc_task = "Task:      {s}\n",
    .calc_skipped = "Skipped:   {s}\n",
    .calc_result = "Result:    {s}\n",
    .calc_copies = "Copies:    {s}  |  number only: {s}\n",
    .calc_problem = "No result: {t}\n",
    .calc_also = "Also:      {s} {s} {s}\n",
    .calc_time = "Time:      {d} µs\n",
    .status = "Zugriff {s} (pid {d}); Accessibility: {s}; secure input: {s}",
    .permission_granted = "granted, ↵ inserts emoji",
    .permission_missing = "missing, ↵ only copies",
    .on = "on",
    .off = "off",
    .daemon_status = "Zugriff {s} daemon (pid {d}); {s}",
    .ui_not_loaded = "UI process not loaded",
};

/// The messages in `lang`.
pub fn of(lang: Language) *const Messages {
    return switch (lang) {
        .de => &de,
        .en => &en,
    };
}

/// The messages in `lang` as a compile-time value, for format strings.
pub fn comptimeOf(comptime lang: Language) Messages {
    return switch (lang) {
        .de => de,
        .en => en,
    };
}

/// Writes the format string `field` in `lang` with `args` to `out`.
pub fn print(out: *std.Io.Writer, lang: Language, comptime field: []const u8, args: anytype) !void {
    return switch (lang) {
        inline else => |l| out.print(@field(comptime comptimeOf(l), field), args),
    };
}

/// The format string `field` in `lang` with `args`, in `buf`.
pub fn bufPrint(buf: []u8, lang: Language, comptime field: []const u8, args: anytype) ![]u8 {
    return switch (lang) {
        inline else => |l| std.mem.print(buf, @field(comptime comptimeOf(l), field), args),
    };
}

/// The format string `field` in `lang` with `args`, on standard error.
pub fn debugPrint(lang: Language, comptime field: []const u8, args: anytype) void {
    switch (lang) {
        inline else => |l| std.debug.print(@field(comptime comptimeOf(l), field), args),
    }
}

test "both languages fill the same format strings" {
    var buf: [512]u8 = undefined;
    for ([_]Language{ .de, .en }) |lang| {
        _ = try bufPrint(&buf, lang, "status", .{ "1.0.0", 42, "x", "y" });
        _ = try bufPrint(&buf, lang, "daemon_status", .{ "1.0.0", 42, "z" });
        _ = try bufPrint(&buf, lang, "apps_found", .{ 1, 2 });
        _ = try bufPrint(&buf, lang, "icons_done", .{ 1, 2, 3 });
        _ = try bufPrint(&buf, lang, "calc_copies", .{ "1", "2" });
        _ = try bufPrint(&buf, lang, "calc_also", .{ "1", "=", "2" });
        _ = try bufPrint(&buf, lang, "unknown_command", .{ "x", "help" });
    }
    try std.testing.expect(std.mem.find(u8, en.help, "--language") != null);
}
