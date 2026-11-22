//! The units the calculator knows: how they are spelled, shown, and what
//! they are worth in base units.
//!
//! Units are typed in German or English, and shown in the language of the
//! palette where their names differ (`Tage`, `days`).
//!
//! Base units: metre, kilogram, second, bit, kelvin and the degree of arc.
//! Every factor is an exact ratio, so conversions stay exact; only °C and
//! °F carry an offset as well.
const std = @import("std");
const Language = @import("../language.zig").Language;

pub const dimension_count = 6;
/// Powers of length, mass, time, data, temperature and angle.
pub const Dims = [dimension_count]i8;

const length: Dims = .{ 1, 0, 0, 0, 0, 0 };
const mass: Dims = .{ 0, 1, 0, 0, 0, 0 };
const time: Dims = .{ 0, 0, 1, 0, 0, 0 };
const data: Dims = .{ 0, 0, 0, 1, 0, 0 };
const temperature: Dims = .{ 0, 0, 0, 0, 1, 0 };
const angle: Dims = .{ 0, 0, 0, 0, 0, 1 };
const area: Dims = .{ 2, 0, 0, 0, 0, 0 };
const volume: Dims = .{ 3, 0, 0, 0, 0, 0 };
const speed: Dims = .{ 1, 0, -1, 0, 0, 0 };
const energy: Dims = .{ 2, 1, -2, 0, 0, 0 };
const power: Dims = .{ 2, 1, -3, 0, 0, 0 };

pub const dimensionless: Dims = @splat(0);

/// An exact ratio `num / den`.
pub const Ratio = struct { num: u64, den: u64 = 1 };

pub const Kind = union(enum) {
    /// A decimal data unit, and the display name of its binary counterpart
    /// (`GB` and `GiB`): conversions into it also offer the binary one.
    decimal_data: []const u8,
    angle,
    other,
};

pub const Unit = struct {
    /// Lowercase spellings that name it.
    spellings: []const []const u8,
    /// How the task and the answer show it.
    display: []const u8,
    /// The answer's name for exactly one (`1 Tag`); `display` otherwise.
    one: ?[]const u8 = null,
    /// The English names where they differ from `display` and `one`.
    english: ?[]const u8 = null,
    english_one: ?[]const u8 = null,
    dims: Dims,
    /// Base units per unit.
    factor: Ratio,
    /// Added before scaling to the base unit (°C and °F to kelvin).
    offset: Ratio = .{ .num = 0 },
    kind: Kind = .other,

    /// The name in `language`; `count_one` for exactly one (`1 Tag`, `1 day`).
    pub fn name(u: Unit, language: Language, count_one: bool) []const u8 {
        return switch (language) {
            .de => if (count_one) u.one orelse u.display else u.display,
            .en => if (count_one) u.english_one orelse u.english orelse u.display else u.english orelse u.display,
        };
    }
};

/// An index into `all`.
pub const Id = u16;

pub const all = [_]Unit{
    .{
        .spellings = &.{ "mm", "millimeter", "millimeters" },
        .display = "mm",
        .dims = length,
        .factor = .{ .num = 1, .den = 1000 },
    },
    .{
        .spellings = &.{ "cm", "zentimeter", "centimeter", "centimeters" },
        .display = "cm",
        .dims = length,
        .factor = .{ .num = 1, .den = 100 },
    },
    .{
        .spellings = &.{"dm"},
        .display = "dm",
        .dims = length,
        .factor = .{ .num = 1, .den = 10 },
    },
    .{
        .spellings = &.{ "m", "meter", "meters", "metre", "metres" },
        .display = "m",
        .dims = length,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{ "km", "kilometer", "kilometers" },
        .display = "km",
        .dims = length,
        .factor = .{ .num = 1000 },
    },
    .{
        .spellings = &.{ "mi", "meile", "meilen", "mile", "miles" },
        .display = "mi",
        .dims = length,
        .factor = .{ .num = 1609344, .den = 1000 },
    },
    .{
        .spellings = &.{ "ft", "fuß", "feet", "foot" },
        .display = "ft",
        .dims = length,
        .factor = .{ .num = 3048, .den = 10000 },
    },
    .{
        .spellings = &.{ "yd", "yard", "yards" },
        .display = "yd",
        .dims = length,
        .factor = .{ .num = 9144, .den = 10000 },
    },
    .{
        .spellings = &.{ "zoll", "inch", "inches" },
        .display = "Zoll",
        .english = "inches",
        .english_one = "inch",
        .dims = length,
        .factor = .{ .num = 254, .den = 10000 },
    },
    .{
        .spellings = &.{ "nmi", "sm", "seemeile", "seemeilen" },
        .display = "sm",
        .english = "nmi",
        .dims = length,
        .factor = .{ .num = 1852 },
    },
    .{
        .spellings = &.{ "mg", "milligramm", "milligram", "milligrams" },
        .display = "mg",
        .dims = mass,
        .factor = .{ .num = 1, .den = 1_000_000 },
    },
    .{
        .spellings = &.{ "g", "gramm", "gram", "grams" },
        .display = "g",
        .dims = mass,
        .factor = .{ .num = 1, .den = 1000 },
    },
    .{
        .spellings = &.{ "kg", "kilo", "kilogramm", "kilogram", "kilograms" },
        .display = "kg",
        .dims = mass,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{ "tonne", "tonnen", "tonnes" },
        .display = "t",
        .dims = mass,
        .factor = .{ .num = 1000 },
    },
    .{
        .spellings = &.{ "lb", "lbs", "pound", "pounds" },
        .display = "lb",
        .dims = mass,
        .factor = .{ .num = 45359237, .den = 100_000_000 },
    },
    .{
        .spellings = &.{ "oz", "unze", "unzen", "ounce", "ounces" },
        .display = "oz",
        .dims = mass,
        .factor = .{ .num = 45359237, .den = 1_600_000_000 },
    },
    .{
        .spellings = &.{ "ml", "milliliter", "milliliters" },
        .display = "ml",
        .dims = volume,
        .factor = .{ .num = 1, .den = 1_000_000 },
    },
    .{
        .spellings = &.{"cl"},
        .display = "cl",
        .dims = volume,
        .factor = .{ .num = 1, .den = 100_000 },
    },
    .{
        .spellings = &.{"dl"},
        .display = "dl",
        .dims = volume,
        .factor = .{ .num = 1, .den = 10_000 },
    },
    .{
        .spellings = &.{ "l", "liter", "liters", "litre", "litres" },
        .display = "l",
        .dims = volume,
        .factor = .{ .num = 1, .den = 1000 },
    },
    .{
        .spellings = &.{ "gal", "gallone", "gallonen", "gallon", "gallons" },
        .display = "gal",
        .dims = volume,
        .factor = .{ .num = 3785411784, .den = 1_000_000_000_000 },
    },
    .{
        .spellings = &.{ "ms", "millisekunde", "millisekunden", "millisecond", "milliseconds" },
        .display = "ms",
        .dims = time,
        .factor = .{ .num = 1, .den = 1000 },
    },
    .{
        .spellings = &.{ "s", "sek", "sekunde", "sekunden", "sec", "second", "seconds" },
        .display = "s",
        .dims = time,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{ "min", "minute", "minuten", "minutes" },
        .display = "min",
        .dims = time,
        .factor = .{ .num = 60 },
    },
    .{
        .spellings = &.{ "h", "std", "stunde", "stunden", "hr", "hrs", "hour", "hours" },
        .display = "h",
        .dims = time,
        .factor = .{ .num = 3600 },
    },
    .{
        .spellings = &.{ "tag", "tage", "tagen", "day", "days" },
        .display = "Tage",
        .one = "Tag",
        .english = "days",
        .english_one = "day",
        .dims = time,
        .factor = .{ .num = 86400 },
    },
    .{
        .spellings = &.{ "woche", "wochen", "week", "weeks" },
        .display = "Wochen",
        .one = "Woche",
        .english = "weeks",
        .english_one = "week",
        .dims = time,
        .factor = .{ .num = 604800 },
    },
    // A tropical year of 365,2422 days, as fend counts it; a month is its twelfth.
    .{
        .spellings = &.{ "monat", "monate", "monaten", "month", "months" },
        .display = "Monate",
        .one = "Monat",
        .english = "months",
        .english_one = "month",
        .dims = time,
        .factor = .{ .num = 262974384, .den = 100 },
    },
    .{
        .spellings = &.{ "jahr", "jahre", "jahren", "year", "years" },
        .display = "Jahre",
        .one = "Jahr",
        .english = "years",
        .english_one = "year",
        .dims = time,
        .factor = .{ .num = 3155692608, .den = 100 },
    },
    .{
        .spellings = &.{ "b", "byte", "bytes" },
        .display = "Byte",
        .english = "bytes",
        .english_one = "byte",
        .dims = data,
        .factor = .{ .num = 8 },
    },
    .{
        .spellings = &.{ "bit", "bits" },
        .display = "Bit",
        .english = "bits",
        .english_one = "bit",
        .dims = data,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{"kb"},
        .display = "kB",
        .dims = data,
        .factor = .{ .num = 8_000 },
        .kind = .{ .decimal_data = "KiB" },
    },
    .{
        .spellings = &.{"mb"},
        .display = "MB",
        .dims = data,
        .factor = .{ .num = 8_000_000 },
        .kind = .{ .decimal_data = "MiB" },
    },
    .{
        .spellings = &.{"gb"},
        .display = "GB",
        .dims = data,
        .factor = .{ .num = 8_000_000_000 },
        .kind = .{ .decimal_data = "GiB" },
    },
    .{
        .spellings = &.{"tb"},
        .display = "TB",
        .dims = data,
        .factor = .{ .num = 8_000_000_000_000 },
        .kind = .{ .decimal_data = "TiB" },
    },
    .{
        .spellings = &.{"kib"},
        .display = "KiB",
        .dims = data,
        .factor = .{ .num = 8 << 10 },
    },
    .{
        .spellings = &.{"mib"},
        .display = "MiB",
        .dims = data,
        .factor = .{ .num = 8 << 20 },
    },
    .{
        .spellings = &.{"gib"},
        .display = "GiB",
        .dims = data,
        .factor = .{ .num = 8 << 30 },
    },
    .{
        .spellings = &.{"tib"},
        .display = "TiB",
        .dims = data,
        .factor = .{ .num = 8 << 40 },
    },
    .{
        .spellings = &.{ "km/h", "kmh" },
        .display = "km/h",
        .dims = speed,
        .factor = .{ .num = 1000, .den = 3600 },
    },
    .{
        .spellings = &.{"m/s"},
        .display = "m/s",
        .dims = speed,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{"mph"},
        .display = "mph",
        .dims = speed,
        .factor = .{ .num = 1609344, .den = 3_600_000 },
    },
    .{
        .spellings = &.{ "kn", "knoten", "knot", "knots" },
        .display = "kn",
        .dims = speed,
        .factor = .{ .num = 1852, .den = 3600 },
    },
    .{
        .spellings = &.{ "°c", "celsius" },
        .display = "°C",
        .dims = temperature,
        .factor = .{ .num = 1 },
        .offset = .{ .num = 27315, .den = 100 },
    },
    .{
        .spellings = &.{ "°f", "fahrenheit" },
        .display = "°F",
        .dims = temperature,
        .factor = .{ .num = 5, .den = 9 },
        .offset = .{ .num = 45967, .den = 100 },
    },
    .{
        .spellings = &.{"kelvin"},
        .display = "K",
        .dims = temperature,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{ "°", "grad", "degree", "degrees" },
        .display = "°",
        .dims = angle,
        .factor = .{ .num = 1 },
        .kind = .angle,
    },
    .{
        .spellings = &.{ "m²", "qm", "m2" },
        .display = "m²",
        .dims = area,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{ "km²", "km2" },
        .display = "km²",
        .dims = area,
        .factor = .{ .num = 1_000_000 },
    },
    .{
        .spellings = &.{ "ha", "hektar", "hectare", "hectares" },
        .display = "ha",
        .dims = area,
        .factor = .{ .num = 10_000 },
    },
    .{
        .spellings = &.{ "m³", "m3" },
        .display = "m³",
        .dims = volume,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{ "j", "joule" },
        .display = "J",
        .dims = energy,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{"kj"},
        .display = "kJ",
        .dims = energy,
        .factor = .{ .num = 1000 },
    },
    .{
        .spellings = &.{"cal"},
        .display = "cal",
        .dims = energy,
        .factor = .{ .num = 4184, .den = 1000 },
    },
    .{
        .spellings = &.{"kcal"},
        .display = "kcal",
        .dims = energy,
        .factor = .{ .num = 4184 },
    },
    .{
        .spellings = &.{"wh"},
        .display = "Wh",
        .dims = energy,
        .factor = .{ .num = 3600 },
    },
    .{
        .spellings = &.{"kwh"},
        .display = "kWh",
        .dims = energy,
        .factor = .{ .num = 3_600_000 },
    },
    .{
        .spellings = &.{ "w", "watt" },
        .display = "W",
        .dims = power,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{"kw"},
        .display = "kW",
        .dims = power,
        .factor = .{ .num = 1000 },
    },
};

/// The unit spelled `lower` (already lowercase), if any.
pub fn bySpelling(lower: []const u8) ?Id {
    for (all, 0..) |u, i| {
        for (u.spellings) |s| if (std.mem.eql(u8, s, lower)) return @intCast(i);
    }
    return null;
}

/// The unit shown as `display`: `GiB`, `K`, `t`.
pub fn byDisplay(display: []const u8) Id {
    for (all, 0..) |u, i| if (std.mem.eql(u8, u.display, display)) return @intCast(i);
    unreachable;
}

pub fn get(id: Id) Unit {
    return all[id];
}

test "units name themselves in either language" {
    const days = get(bySpelling("days").?);
    try std.testing.expectEqualStrings("Tage", days.name(.de, false));
    try std.testing.expectEqualStrings("Tag", days.name(.de, true));
    try std.testing.expectEqualStrings("days", days.name(.en, false));
    try std.testing.expectEqualStrings("day", days.name(.en, true));
    const km = get(bySpelling("kilometers").?);
    try std.testing.expectEqualStrings("km", km.name(.en, true));
    try std.testing.expectEqualStrings("inches", get(bySpelling("zoll").?).name(.en, false));
}

test "every unit is found by its spellings and data units name their binary twin" {
    for (all, 0..) |u, i| {
        for (u.spellings) |s| try std.testing.expectEqual(@as(?Id, @intCast(i)), bySpelling(s));
        switch (u.kind) {
            .decimal_data => |binary| try std.testing.expectEqualStrings(binary, all[byDisplay(binary)].display),
            .angle, .other => {},
        }
    }
}
