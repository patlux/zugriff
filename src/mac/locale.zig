//! The user's language and number notation, from macOS: the first of the
//! preferred languages and the decimal separator of the region (System
//! Settings › General › Language & Region). Reading them is a user-defaults
//! lookup, cheap enough for the start path.
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const core = @import("../core.zig");

/// The language of the texts and the notation of the numbers.
pub fn current() core.Locale {
    const pool = objc.Pool.push();
    defer pool.pop();
    return .{ .language = preferredLanguage(), .numbers = regionNotation() };
}

/// German when the first preferred language is German, English otherwise.
fn preferredLanguage() core.Language {
    const languages = objc.msg(?objc.Object, objc.class("NSLocale"), "preferredLanguages", .{}) orelse return .en;
    const first = objc.msg(?objc.Object, languages, "firstObject", .{}) orelse return .en;
    return core.Language.fromTag(objc.fromNSString(first));
}

/// German when the region writes a decimal comma, English otherwise.
fn regionNotation() core.Language {
    const locale = objc.msg(?objc.Object, objc.class("NSLocale"), "currentLocale", .{}) orelse return .en;
    const separator = objc.msg(?objc.Object, locale, "decimalSeparator", .{}) orelse return .en;
    return core.Language.fromDecimalSeparator(objc.fromNSString(separator));
}
