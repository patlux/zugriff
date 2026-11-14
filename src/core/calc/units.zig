//! The units the calculator knows: how they are spelled, shown, and what
//! they are worth in base units.
//!
//! Base units: metre, kilogram, second, bit, kelvin and the degree of arc.
//! Every factor is an exact ratio, so conversions stay exact; only °C and
//! °F carry an offset as well.
const std = @import("std");

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
    dims: Dims,
    /// Base units per unit.
    factor: Ratio,
    /// Added before scaling to the base unit (°C and °F to kelvin).
    offset: Ratio = .{ .num = 0 },
    kind: Kind = .other,
};

/// An index into `all`.
pub const Id = u16;

pub const all = [_]Unit{
    .{
        .spellings = &.{ "mm", "millimeter" },
        .display = "mm",
        .dims = length,
        .factor = .{ .num = 1, .den = 1000 },
    },
    .{
        .spellings = &.{ "cm", "zentimeter" },
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
        .spellings = &.{ "m", "meter" },
        .display = "m",
        .dims = length,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{ "km", "kilometer" },
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
        .spellings = &.{ "ft", "fuß", "feet" },
        .display = "ft",
        .dims = length,
        .factor = .{ .num = 3048, .den = 10000 },
    },
    .{
        .spellings = &.{"yd"},
        .display = "yd",
        .dims = length,
        .factor = .{ .num = 9144, .den = 10000 },
    },
    .{
        .spellings = &.{ "zoll", "inch", "inches" },
        .display = "Zoll",
        .dims = length,
        .factor = .{ .num = 254, .den = 10000 },
    },
    .{
        .spellings = &.{ "nmi", "sm", "seemeile", "seemeilen" },
        .display = "sm",
        .dims = length,
        .factor = .{ .num = 1852 },
    },
    .{
        .spellings = &.{ "mg", "milligramm" },
        .display = "mg",
        .dims = mass,
        .factor = .{ .num = 1, .den = 1_000_000 },
    },
    .{
        .spellings = &.{ "g", "gramm" },
        .display = "g",
        .dims = mass,
        .factor = .{ .num = 1, .den = 1000 },
    },
    .{
        .spellings = &.{ "kg", "kilo", "kilogramm" },
        .display = "kg",
        .dims = mass,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{ "tonne", "tonnen" },
        .display = "t",
        .dims = mass,
        .factor = .{ .num = 1000 },
    },
    .{
        .spellings = &.{ "lb", "lbs" },
        .display = "lb",
        .dims = mass,
        .factor = .{ .num = 45359237, .den = 100_000_000 },
    },
    .{
        .spellings = &.{ "oz", "unze", "unzen" },
        .display = "oz",
        .dims = mass,
        .factor = .{ .num = 45359237, .den = 1_600_000_000 },
    },
    .{
        .spellings = &.{ "ml", "milliliter" },
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
        .spellings = &.{ "l", "liter" },
        .display = "l",
        .dims = volume,
        .factor = .{ .num = 1, .den = 1000 },
    },
    .{
        .spellings = &.{ "gal", "gallone", "gallonen" },
        .display = "gal",
        .dims = volume,
        .factor = .{ .num = 3785411784, .den = 1_000_000_000_000 },
    },
    .{
        .spellings = &.{ "ms", "millisekunde", "millisekunden" },
        .display = "ms",
        .dims = time,
        .factor = .{ .num = 1, .den = 1000 },
    },
    .{
        .spellings = &.{ "s", "sek", "sekunde", "sekunden" },
        .display = "s",
        .dims = time,
        .factor = .{ .num = 1 },
    },
    .{
        .spellings = &.{ "min", "minute", "minuten" },
        .display = "min",
        .dims = time,
        .factor = .{ .num = 60 },
    },
    .{
        .spellings = &.{ "h", "std", "stunde", "stunden" },
        .display = "h",
        .dims = time,
        .factor = .{ .num = 3600 },
    },
    .{
        .spellings = &.{ "tag", "tage", "tagen" },
        .display = "Tage",
        .one = "Tag",
        .dims = time,
        .factor = .{ .num = 86400 },
    },
    .{
        .spellings = &.{ "woche", "wochen" },
        .display = "Wochen",
        .one = "Woche",
        .dims = time,
        .factor = .{ .num = 604800 },
    },
    // A year of 365,25 days, a month the twelfth of it.
    .{
        .spellings = &.{ "monat", "monate", "monaten" },
        .display = "Monate",
        .one = "Monat",
        .dims = time,
        .factor = .{ .num = 2629800 },
    },
    .{
        .spellings = &.{ "jahr", "jahre", "jahren" },
        .display = "Jahre",
        .one = "Jahr",
        .dims = time,
        .factor = .{ .num = 31557600 },
    },
    .{
        .spellings = &.{ "b", "byte", "bytes" },
        .display = "Byte",
        .dims = data,
        .factor = .{ .num = 8 },
    },
    .{
        .spellings = &.{ "bit", "bits" },
        .display = "Bit",
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
        .spellings = &.{ "kn", "knoten" },
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
        .spellings = &.{ "°", "grad" },
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
        .spellings = &.{ "ha", "hektar" },
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

test "every unit is found by its spellings and data units name their binary twin" {
    for (all, 0..) |u, i| {
        for (u.spellings) |s| try std.testing.expectEqual(@as(?Id, @intCast(i)), bySpelling(s));
        switch (u.kind) {
            .decimal_data => |binary| try std.testing.expectEqualStrings(binary, all[byDisplay(binary)].display),
            .angle, .other => {},
        }
    }
}
