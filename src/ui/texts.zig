//! Every text the palette shows, in German and in English.
//!
//! One table per language with the same fields; a missing translation does
//! not compile. Fields with `{s}` or `{d}` are format strings: `print` and
//! `append` fill them, with the language known at compile time inside an
//! `inline else`, as `std.fmt` needs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const core = @import("../core.zig");
const Language = core.Language;

/// The title, explanation and example of one help topic.
pub const HelpTopic = struct { title: []const u8, subtitle: []const u8, example: []const u8 };

/// The number of help topics; `help_view.zig` gives each its glyph.
pub const help_topic_count = 7;

pub const Texts = struct {
    // The app search.
    search_placeholder: []const u8,
    open_in_browser: []const u8,
    loading_title: []const u8,
    loading_detail: []const u8,
    no_apps_title: []const u8,
    no_apps_detail: []const u8,
    no_hits_title: []const u8,
    /// `{s}`: the query.
    no_hits_detail: []const u8,
    hits_one: []const u8,
    /// `{d}`.
    hits: []const u8,
    apps_one: []const u8,
    /// `{d}`.
    apps: []const u8,
    hint_navigate: []const u8,
    hint_open: []const u8,
    hint_open_help: []const u8,
    hint_finder: []const u8,
    hint_close: []const u8,
    emoji_row_title: []const u8,
    emoji_row_subtitle: []const u8,

    // The help.
    help_topics: [help_topic_count]HelpTopic,
    help_title: []const u8,
    help_row_subtitle: []const u8,
    hint_try: []const u8,
    /// `{d}`: topics, `{s}`: version.
    help_footer: []const u8,
    help_origin: []const u8,
    help_tip: []const u8,

    // The emoji picker.
    emoji_placeholder: []const u8,
    emoji_recent: []const u8,
    /// `{s}`: the search.
    emoji_results: []const u8,
    /// `{d}`.
    emoji_count: []const u8,
    /// In the order of `core.emoji.Group.all`.
    emoji_groups: [9][]const u8,
    emoji_permission_needed: []const u8,
    hint_select: []const u8,
    hint_confirm: []const u8,
    hint_copy_cmd: []const u8,
    hint_back: []const u8,
    hint_tone: []const u8,
    hint_insert_remember: []const u8,
    hint_tab_back: []const u8,
    emoji_none: []const u8,
    secure_input: []const u8,
    hint_copy: []const u8,
    hint_tones: []const u8,
    hint_insert: []const u8,
    /// `{s}`: the search.
    emoji_empty: []const u8,
    emoji_empty_detail: []const u8,
    tones_hint: []const u8,
    prompt_title: []const u8,
    prompt_body: []const u8,
    prompt_settings: []const u8,
    /// `{s}`: the emoji.
    prompt_settings_detail: []const u8,
    prompt_copy_only: []const u8,
    /// `{s}`: the emoji.
    prompt_copy_detail: []const u8,

    // The calculator.
    total: []const u8,
    /// `{d}`.
    lines: []const u8,
    history: []const u8,
    calculations_one: []const u8,
    /// `{d}`.
    calculations: []const u8,
    hint_edit: []const u8,
    /// `{d}`: lines, `{s}`: the total.
    sheet_total: []const u8,
    /// `{d}`: lines.
    sheet_no_total: []const u8,
    /// `{s}`: the label so far, `{d}`: lines without a number.
    sheet_without: []const u8,
    hint_line: []const u8,
    hint_table: []const u8,
    /// `{s}`: how long ago.
    last_calculation: []const u8,
    pasted_one: []const u8,
    /// `{d}`: skipped words.
    pasted: []const u8,
    two_readings: []const u8,
    units: []const u8,
    calculator: []const u8,
    hint_unit: []const u8,
    hint_reading: []const u8,
    hint_number: []const u8,
    hint_with_task: []const u8,
    ago_now: []const u8,
    /// `{d}` each.
    ago_seconds: []const u8,
    ago_minutes: []const u8,
    ago_hours: []const u8,
    ago_day: []const u8,
    ago_days: []const u8,
    copy_as: []const u8,
    format_shown: []const u8,
    format_number: []const u8,
    format_with_task: []const u8,
    no_rates_note: []const u8,
    apps_section: []const u8,
    history_empty: []const u8,
    history_empty_detail: []const u8,
    history_title: []const u8,
    no_number: []const u8,
    /// `{s}` each: mean, largest, smallest.
    sheet_stats: []const u8,
    /// Between the last two skipped words.
    list_and: []const u8,
    /// `{s}`: one skipped word, quoted.
    quoted: []const u8,
    /// `{s}`: the skipped words.
    read_as_skipped: []const u8,
    /// The caption of a task with a number that reads two ways.
    ambiguous: []const u8,
    task: []const u8,
    /// `{d}`: digits.
    rounded_significant: []const u8,
    rounded_cents: []const u8,
    rounded_hundredths: []const u8,
    decimal_data: []const u8,
    result: []const u8,
    missing_number: []const u8,
    /// `{s}`: the sign or word before the gap.
    missing_number_after: []const u8,
    open_bracket: []const u8,
    missing_unit: []const u8,
    undefined_result: []const u8,
    division_by_zero: []const u8,
    not_real: []const u8,
    not_real_detail: []const u8,
    incompatible: []const u8,
    incompatible_detail: []const u8,
    no_rate: []const u8,
    no_rate_detail: []const u8,
    too_complex: []const u8,
    too_complex_detail: []const u8,
    unreadable: []const u8,
    unreadable_detail: []const u8,
    also_in: []const u8,
    other_reading: []const u8,
    also_possible: []const u8,
    surcharge_only: []const u8,
    discount_only: []const u8,
    surcharge_included: []const u8,
    discount_included: []const u8,
    /// `{s}`: the task in the other notation.
    other_notation: []const u8,
    /// `{s}`: binary unit, `{s}`: its bytes.
    binary: []const u8,
    /// How a gap after `von`/`of` names the word.
    word_of: []const u8,
};

pub const de: Texts = .{
    .search_placeholder = "Apps suchen …",
    .open_in_browser = "Im Browser öffnen",
    .loading_title = "Apps werden geladen …",
    .loading_detail = "Die installierten Programme erscheinen gleich.",
    .no_apps_title = "Keine Apps gefunden",
    .no_apps_detail = "Die App-Liste ist leer.",
    .no_hits_title = "Keine Treffer",
    .no_hits_detail = "Nichts gefunden für „{s}“",
    .hits_one = "1 Treffer",
    .hits = "{d} Treffer",
    .apps_one = "1 App",
    .apps = "{d} Apps",
    .hint_navigate = "↑↓ Navigieren",
    .hint_open = "↵ Öffnen",
    .hint_open_help = "↵ Hilfe öffnen",
    .hint_finder = "⌘↵ Finder",
    .hint_close = "esc Schließen",
    .emoji_row_title = "Emoji",
    .emoji_row_subtitle = "Emoji suchen und einfügen · ⌃⌘Leertaste",

    .help_topics = .{
        .{
            .title = "Apps starten",
            .subtitle = "Namen oder Teil davon tippen · ↵ startet, ⌘↵ zeigt im Finder",
            .example = "saf",
        },
        .{
            .title = "Datei oder Ordner öffnen",
            .subtitle = "Pfad mit / oder ~/ am Anfang · ↵ öffnet",
            .example = "~/Downloads",
        },
        .{
            .title = "Adresse öffnen",
            .subtitle = "http:// oder https:// · ↵ öffnet im Browser",
            .example = "https://ziglang.org",
        },
        .{
            .title = "Rechnen",
            .subtitle = "Aufgabe tippen oder einfügen · ↵ kopiert, ⌥↵ nur die Zahl",
            .example = "1.299 € + 19 %",
        },
        .{
            .title = "Letzte Rechnungen",
            .subtitle = "= allein zeigt die Rechnungen dieser Sitzung",
            .example = "=",
        },
        .{
            .title = "Emoji einfügen",
            .subtitle = ": am Anfang oder ⌃⌘Leertaste · ⇥ Hauttöne",
            .example = ":herz",
        },
        .{
            .title = "Tasten",
            .subtitle = "↑↓ wählen, ↵ ausführen, esc schließt",
            .example = "⌘↵ ⌥↵ ⇧↵",
        },
    },
    .help_title = "Hilfe",
    .help_row_subtitle = "Was Zugriff kann · auch mit ? oder hilfe",
    .hint_try = "↵ Ausprobieren",
    .help_footer = "Hilfe · {d} Themen · Version {s}",
    .help_origin = "aus der Hilfe",
    .help_tip = "Tipp: ? zeigt, was Zugriff kann",

    .emoji_placeholder = "Emoji suchen …",
    .emoji_recent = "Zuletzt verwendet",
    .emoji_results = "Treffer für „{s}“",
    .emoji_count = "{d} Emoji",
    .emoji_groups = .{
        "Smileys & Gefühle",
        "Menschen & Körper",
        "Tiere & Natur",
        "Essen & Trinken",
        "Reisen & Orte",
        "Aktivitäten",
        "Objekte",
        "Symbole",
        "Flaggen",
    },
    .emoji_permission_needed = "Einfügen braucht eine Erlaubnis",
    .hint_select = "↑↓ Auswahl",
    .hint_confirm = "↵ Bestätigen",
    .hint_copy_cmd = "⌘↵ Kopieren",
    .hint_back = "esc Zurück",
    .hint_tone = "←→ Hautton",
    .hint_insert_remember = "↵ Einfügen und merken",
    .hint_tab_back = "⇥ Zurück",
    .emoji_none = "0 Emoji",
    .secure_input = "Eingabeschutz aktiv (Passwortfeld vorn): ↵ kopiert nur",
    .hint_copy = "↵ Kopieren",
    .hint_tones = "⇥ Hauttöne",
    .hint_insert = "↵ Einfügen",
    .emoji_empty = "Kein Emoji für „{s}“",
    .emoji_empty_detail = "⌫ ändert die Suche, esc schließt.",
    .tones_hint = "←→ wählen · ↵ einfügen und merken",
    .prompt_title = "Zum Einfügen braucht Zugriff die Bedienungshilfen",
    .prompt_body = "Zugriff legt das Emoji in die Zwischenablage, gibt den Fokus an die App davor zurück, " ++
        "sendet ⌘V und stellt die Zwischenablage danach wieder her. Tastendrücke an andere Apps " ++
        "erlaubt macOS nur mit dieser Erlaubnis. Ohne sie kopiert ↵ nur.",
    .prompt_settings = "Systemeinstellungen öffnen",
    .prompt_settings_detail = "Datenschutz & Sicherheit › Bedienungshilfen › Zugriff · {s} wird kopiert",
    .prompt_copy_only = "Nur kopieren",
    .prompt_copy_detail = "{s} liegt dann in der Zwischenablage, ⌘V fügt ein",

    .total = "Summe",
    .lines = "{d} Zeilen",
    .history = "Verlauf",
    .calculations_one = "1 Rechnung",
    .calculations = "{d} Rechnungen",
    .hint_edit = "⌘↵ Bearbeiten",
    .sheet_total = "{d} Zeilen, Summe {s}",
    .sheet_no_total = "{d} Zeilen, keine Summe",
    .sheet_without = "{s} · {d} ohne Zahl",
    .hint_line = "↑↓ Zeile",
    .hint_table = "⇧↵ Als Tabelle",
    .last_calculation = "Letzte Rechnung · {s}",
    .pasted_one = "Eingefügt · 1 Wort übergangen",
    .pasted = "Eingefügt · {d} Wörter übergangen",
    .two_readings = "2 Lesarten",
    .units = "Einheiten",
    .calculator = "Rechner",
    .hint_unit = "↑↓ Einheit",
    .hint_reading = "↑↓ Lesart",
    .hint_number = "⌥↵ Nur Zahl",
    .hint_with_task = "⇧↵ Mit Aufgabe",
    .ago_now = "gerade eben",
    .ago_seconds = "vor {d} s",
    .ago_minutes = "vor {d} Min.",
    .ago_hours = "vor {d} Std.",
    .ago_day = "vor 1 Tag",
    .ago_days = "vor {d} Tagen",
    .copy_as = "Kopieren als",
    .format_shown = "Ergebnis wie angezeigt",
    .format_number = "nur die Zahl, mit Dezimalpunkt",
    .format_with_task = "mit Aufgabe",
    .no_rates_note = "Zugriff rechnet nur lokal und lädt keine Wechselkurse. Ohne Umrechnung rechnet es " ++
        "mit der Währung als Etikett: 100 € × 3 ergibt 300 €.",
    .apps_section = "Apps",
    .history_empty = "Noch keine Rechnungen",
    .history_empty_detail = "Ergebnisse dieser Sitzung erscheinen hier; sie liegen nur im Speicher.",
    .history_title = "Zuletzt gerechnet",
    .no_number = "ohne Zahl",
    .sheet_stats = "Mittel {s} · größte {s} · kleinste {s}",
    .list_and = " und ",
    .quoted = "„{s}“",
    .read_as_skipped = "gelesen als · {s} übergangen",
    .ambiguous = "Punkt trennt Tausender, deutsch",
    .task = "Aufgabe",
    .rounded_significant = "auf {d} gültige Stellen gerundet",
    .rounded_cents = "auf Cent gerundet",
    .rounded_hundredths = "auf zwei Nachkommastellen gerundet",
    .decimal_data = "dezimal, wie der Finder zählt",
    .result = "Ergebnis",
    .missing_number = "es fehlt eine Zahl",
    .missing_number_after = "es fehlt eine Zahl nach {s}",
    .open_bracket = "eine Klammer ist noch offen",
    .missing_unit = "es fehlt die Einheit nach „in“",
    .undefined_result = "nicht definiert",
    .division_by_zero = "Division durch null",
    .not_real = "keine reelle Zahl",
    .not_real_detail = "zum Beispiel die Wurzel einer negativen Zahl",
    .incompatible = "passt nicht",
    .incompatible_detail = "die Einheiten lassen sich nicht ineinander umrechnen",
    .no_rate = "kein Kurs",
    .no_rate_detail = "Kurse bräuchten das Netz",
    .too_complex = "zu aufwendig",
    .too_complex_detail = "die Rechnung dauert länger, als die Palette wartet",
    .unreadable = "nicht lesbar",
    .unreadable_detail = "Zugriff versteht diese Aufgabe nicht",
    .also_in = "Auch in",
    .other_reading = "Andere Lesart",
    .also_possible = "Auch möglich",
    .surcharge_only = "nur der Aufschlag",
    .discount_only = "nur der Abzug",
    .surcharge_included = "wenn der Aufschlag schon drin ist",
    .discount_included = "wenn der Abzug schon abgezogen ist",
    .other_notation = "gelesen als {s} · Punkt als Dezimalzeichen, englisch",
    .binary = "binär · 1 {s} = {s} Byte",
    .word_of = "von",
};

pub const en: Texts = .{
    .search_placeholder = "Search apps …",
    .open_in_browser = "Open in the browser",
    .loading_title = "Loading apps …",
    .loading_detail = "The installed apps appear in a moment.",
    .no_apps_title = "No apps found",
    .no_apps_detail = "The app list is empty.",
    .no_hits_title = "No results",
    .no_hits_detail = "Nothing found for “{s}”",
    .hits_one = "1 result",
    .hits = "{d} results",
    .apps_one = "1 app",
    .apps = "{d} apps",
    .hint_navigate = "↑↓ Navigate",
    .hint_open = "↵ Open",
    .hint_open_help = "↵ Open help",
    .hint_finder = "⌘↵ Finder",
    .hint_close = "esc Close",
    .emoji_row_title = "Emoji",
    .emoji_row_subtitle = "Search and insert emoji · ⌃⌘Space",

    .help_topics = .{
        .{
            .title = "Open apps",
            .subtitle = "Type a name or part of it · ↵ opens, ⌘↵ shows in Finder",
            .example = "saf",
        },
        .{
            .title = "Open a file or folder",
            .subtitle = "A path that starts with / or ~/ · ↵ opens",
            .example = "~/Downloads",
        },
        .{
            .title = "Open a web address",
            .subtitle = "http:// or https:// · ↵ opens in the browser",
            .example = "https://ziglang.org",
        },
        .{
            .title = "Calculate",
            .subtitle = "Type or paste a task · ↵ copies, ⌥↵ the number only",
            .example = "$1,299 + 19%",
        },
        .{
            .title = "Recent calculations",
            .subtitle = "= alone shows the calculations of this session",
            .example = "=",
        },
        .{
            .title = "Insert emoji",
            .subtitle = ": at the start or ⌃⌘Space · ⇥ skin tones",
            .example = ":heart",
        },
        .{
            .title = "Keys",
            .subtitle = "↑↓ select, ↵ run, esc closes",
            .example = "⌘↵ ⌥↵ ⇧↵",
        },
    },
    .help_title = "Help",
    .help_row_subtitle = "What Zugriff can do · also with ? or help",
    .hint_try = "↵ Try it",
    .help_footer = "Help · {d} topics · version {s}",
    .help_origin = "from the help",
    .help_tip = "Tip: ? shows what Zugriff can do",

    .emoji_placeholder = "Search emoji …",
    .emoji_recent = "Recently used",
    .emoji_results = "Results for “{s}”",
    .emoji_count = "{d} emoji",
    .emoji_groups = .{
        "Smileys & Emotion",
        "People & Body",
        "Animals & Nature",
        "Food & Drink",
        "Travel & Places",
        "Activities",
        "Objects",
        "Symbols",
        "Flags",
    },
    .emoji_permission_needed = "Inserting needs a permission",
    .hint_select = "↑↓ Select",
    .hint_confirm = "↵ Confirm",
    .hint_copy_cmd = "⌘↵ Copy",
    .hint_back = "esc Back",
    .hint_tone = "←→ Skin tone",
    .hint_insert_remember = "↵ Insert and remember",
    .hint_tab_back = "⇥ Back",
    .emoji_none = "0 emoji",
    .secure_input = "Secure input is on (a password field is in front): ↵ only copies",
    .hint_copy = "↵ Copy",
    .hint_tones = "⇥ Skin tones",
    .hint_insert = "↵ Insert",
    .emoji_empty = "No emoji for “{s}”",
    .emoji_empty_detail = "⌫ changes the search, esc closes.",
    .tones_hint = "←→ choose · ↵ insert and remember",
    .prompt_title = "To insert, Zugriff needs Accessibility access",
    .prompt_body = "Zugriff puts the emoji on the clipboard, gives the focus back to the app in front, " ++
        "sends ⌘V and then restores the clipboard. macOS lets an app send key presses to other apps " ++
        "only with this permission. Without it, ↵ only copies.",
    .prompt_settings = "Open System Settings",
    .prompt_settings_detail = "Privacy & Security › Accessibility › Zugriff · {s} is copied",
    .prompt_copy_only = "Copy only",
    .prompt_copy_detail = "{s} is then on the clipboard, ⌘V pastes it",

    .total = "Total",
    .lines = "{d} lines",
    .history = "History",
    .calculations_one = "1 calculation",
    .calculations = "{d} calculations",
    .hint_edit = "⌘↵ Edit",
    .sheet_total = "{d} lines, total {s}",
    .sheet_no_total = "{d} lines, no total",
    .sheet_without = "{s} · {d} without a number",
    .hint_line = "↑↓ Line",
    .hint_table = "⇧↵ As a table",
    .last_calculation = "Last calculation · {s}",
    .pasted_one = "Pasted · 1 word skipped",
    .pasted = "Pasted · {d} words skipped",
    .two_readings = "2 readings",
    .units = "Units",
    .calculator = "Calculator",
    .hint_unit = "↑↓ Unit",
    .hint_reading = "↑↓ Reading",
    .hint_number = "⌥↵ Number only",
    .hint_with_task = "⇧↵ With task",
    .ago_now = "just now",
    .ago_seconds = "{d} s ago",
    .ago_minutes = "{d} min ago",
    .ago_hours = "{d} h ago",
    .ago_day = "1 day ago",
    .ago_days = "{d} days ago",
    .copy_as = "Copy as",
    .format_shown = "result as shown",
    .format_number = "number only, with a decimal point",
    .format_with_task = "with the task",
    .no_rates_note = "Zugriff calculates only locally and loads no exchange rates. Without a conversion " ++
        "it keeps the currency as a label: €100 × 3 gives €300.",
    .apps_section = "Apps",
    .history_empty = "No calculations yet",
    .history_empty_detail = "Results of this session appear here; they stay in memory only.",
    .history_title = "Recently calculated",
    .no_number = "no number",
    .sheet_stats = "mean {s} · largest {s} · smallest {s}",
    .list_and = " and ",
    .quoted = "“{s}”",
    .read_as_skipped = "read as · {s} skipped",
    .ambiguous = "read the English way",
    .task = "Task",
    .rounded_significant = "rounded to {d} significant digits",
    .rounded_cents = "rounded to cents",
    .rounded_hundredths = "rounded to two decimals",
    .decimal_data = "decimal, as Finder counts",
    .result = "Result",
    .missing_number = "a number is missing",
    .missing_number_after = "a number is missing after {s}",
    .open_bracket = "a bracket is still open",
    .missing_unit = "the unit after “in” is missing",
    .undefined_result = "undefined",
    .division_by_zero = "division by zero",
    .not_real = "not a real number",
    .not_real_detail = "such as the square root of a negative number",
    .incompatible = "does not convert",
    .incompatible_detail = "these units do not convert into each other",
    .no_rate = "no rate",
    .no_rate_detail = "rates would need the network",
    .too_complex = "too complex",
    .too_complex_detail = "the calculation takes longer than the palette waits",
    .unreadable = "unreadable",
    .unreadable_detail = "Zugriff does not understand this task",
    .also_in = "Also in",
    .other_reading = "Other reading",
    .also_possible = "Also possible",
    .surcharge_only = "the surcharge alone",
    .discount_only = "the discount alone",
    .surcharge_included = "if the surcharge is already included",
    .discount_included = "if the discount is already taken off",
    .other_notation = "read as {s} · the German way",
    .binary = "binary · 1 {s} = {s} bytes",
    .word_of = "of",
};

/// The texts in `lang`.
pub fn of(lang: Language) *const Texts {
    return switch (lang) {
        .de => &de,
        .en => &en,
    };
}

/// The texts in `lang` as a compile-time value, for format strings.
pub fn comptimeOf(comptime lang: Language) Texts {
    return switch (lang) {
        .de => de,
        .en => en,
    };
}

/// The format string `field` in `lang`, filled with `args`, in the frame's arena.
pub fn print(c: *ui.Context, lang: Language, comptime field: []const u8, args: anytype) []const u8 {
    return switch (lang) {
        inline else => |l| c.print(@field(comptime comptimeOf(l), field), args),
    };
}

/// The format string `field` in `lang`, filled with `args`, at the end of `list`.
pub fn append(list: *std.ArrayList(u8), comptime field: []const u8, a: Allocator, lang: Language, args: anytype) !void {
    return switch (lang) {
        inline else => |l| list.print(a, @field(comptime comptimeOf(l), field), args),
    };
}

/// `one` for a count of 1, else the format string `many` with `n`.
pub fn count(c: *ui.Context, lang: Language, n: usize, comptime one: []const u8, comptime many: []const u8) []const u8 {
    if (n == 1) return @field(of(lang).*, one);
    return print(c, lang, many, .{n});
}

test "both languages fill the same format strings" {
    // Every format field takes the same arguments in both tables; a mismatch
    // fails to compile here rather than at the first frame that shows it.
    var buf: [256]u8 = undefined;
    inline for (.{ de, en }) |t| {
        _ = try std.mem.print(&buf, t.no_hits_detail, .{"x"});
        _ = try std.mem.print(&buf, t.help_footer, .{ 7, "0.0.0" });
        _ = try std.mem.print(&buf, t.sheet_total, .{ 2, "3" });
        _ = try std.mem.print(&buf, t.sheet_without, .{ "x", 1 });
        _ = try std.mem.print(&buf, t.sheet_stats, .{ "1", "2", "3" });
        _ = try std.mem.print(&buf, t.binary, .{ "MiB", "1" });
        _ = try std.mem.print(&buf, t.rounded_significant, .{12});
    }
}
