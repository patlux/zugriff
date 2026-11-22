//! The languages Zugriff speaks: German and English.
//!
//! A `Locale` holds two of them, as macOS keeps two settings
//! (`mac/locale.zig`): the language of the texts and emoji names follows the
//! first preferred language (German for German, English for every other
//! one), the notation of the calculator's numbers follows the region's
//! decimal separator (a comma: German, `1.299,50`; a point: English,
//! `1,299.50`). `--language` sets both.
const std = @import("std");

/// What the palette speaks and how it writes numbers.
pub const Locale = struct {
    /// The texts and the emoji names.
    language: Language,
    /// How the calculator reads and writes numbers.
    numbers: Language,

    /// Texts and numbers in `l`.
    pub fn both(l: Language) Locale {
        return .{ .language = l, .numbers = l };
    }
};

pub const Language = enum {
    de,
    en,

    /// `de` or `en`, also spelled out (`deutsch`, `german`, `english`,
    /// `englisch`), in any case.
    pub fn parse(s: []const u8) ?Language {
        const names = [_]struct { []const u8, Language }{
            .{ "de", .de },
            .{ "deutsch", .de },
            .{ "german", .de },
            .{ "en", .en },
            .{ "english", .en },
            .{ "englisch", .en },
        };
        for (names) |n| if (std.ascii.eqlIgnoreCase(s, n[0])) return n[1];
        return null;
    }

    /// The language for a macOS language tag such as `de-DE`, `de_AT`,
    /// `en-US` or `fr`: German for German, English for everything else.
    pub fn fromTag(tag: []const u8) Language {
        if (tag.len < 2 or !std.ascii.eqlIgnoreCase(tag[0..2], "de")) return .en;
        if (tag.len > 2 and tag[2] != '-' and tag[2] != '_') return .en;
        return .de;
    }

    /// The code `parse` reads back: `de`, `en`.
    pub fn code(l: Language) []const u8 {
        return @tagName(l);
    }

    /// The notation of a region with this decimal separator: German for a
    /// comma, English for anything else.
    pub fn fromDecimalSeparator(separator: []const u8) Language {
        return if (std.mem.eql(u8, separator, ",")) .de else .en;
    }
};

test "reads the codes and names of both languages" {
    try std.testing.expectEqual(Language.de, Language.parse("de").?);
    try std.testing.expectEqual(Language.de, Language.parse("Deutsch").?);
    try std.testing.expectEqual(Language.en, Language.parse("EN").?);
    try std.testing.expectEqual(Language.en, Language.parse("english").?);
    try std.testing.expect(Language.parse("fr") == null);
    try std.testing.expect(Language.parse("") == null);
    try std.testing.expectEqualStrings("en", Language.en.code());
}

test "a decimal comma writes numbers the German way" {
    try std.testing.expectEqual(Language.de, Language.fromDecimalSeparator(","));
    try std.testing.expectEqual(Language.en, Language.fromDecimalSeparator("."));
    try std.testing.expectEqual(Language.en, Language.fromDecimalSeparator(""));
    const l = Locale.both(.de);
    try std.testing.expectEqual(Language.de, l.numbers);
}

test "German for German tags, English for every other one" {
    for ([_][]const u8{ "de", "de-DE", "de-AT", "de_CH", "DE-de" }) |t| {
        try std.testing.expectEqual(Language.de, Language.fromTag(t));
    }
    for ([_][]const u8{ "en", "en-US", "fr-FR", "nl", "dev", "", "d" }) |t| {
        try std.testing.expectEqual(Language.en, Language.fromTag(t));
    }
}
