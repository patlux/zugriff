//! Exact decimal numbers as digit strings.
//!
//! Rounding and formatting (German `1.234,5`, English `1,234.5`) work on the
//! digits directly, so no value passes through a binary float on its way to
//! the screen. Every function
//! that builds a new number takes an allocator; the calculator gives it an
//! arena per calculation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Language = @import("../language.zig").Language;

/// A finite decimal number: sign, integer digits and fraction digits.
pub const Decimal = struct {
    negative: bool = false,
    /// Integer digits without leading zeros; `"0"` for zero.
    int: []const u8 = "0",
    /// Fraction digits as written, trailing zeros included.
    frac: []const u8 = "",

    pub const one: Decimal = .{ .int = "1" };

    /// Parses `-1234.5678`, `0.5` or `42`: ASCII digits, one optional dot.
    pub fn parse(a: Allocator, s: []const u8) !?Decimal {
        const negative = std.mem.startsWith(u8, s, "-");
        const digits = if (negative) s[1..] else s;
        const dot = std.mem.findScalar(u8, digits, '.');
        const int = if (dot) |d| digits[0..d] else digits;
        const frac = if (dot) |d| digits[d + 1 ..] else "";
        if (int.len == 0 or !allDigits(int) or !allDigits(frac) or (dot != null and frac.len == 0)) return null;
        const d = try fromParts(a, negative, int, frac);
        return d;
    }

    fn fromParts(a: Allocator, negative: bool, int_in: []const u8, frac: []const u8) !Decimal {
        const stripped = std.mem.trimStart(u8, int_in, "0");
        var d: Decimal = .{
            .negative = negative,
            .int = if (stripped.len == 0) "0" else try a.dupe(u8, stripped),
            .frac = try a.dupe(u8, frac),
        };
        if (d.isZero()) d.negative = false;
        return d;
    }

    pub fn isZero(d: Decimal) bool {
        return std.mem.eql(u8, d.int, "0") and allZeros(d.frac);
    }

    pub fn isInteger(d: Decimal) bool {
        return allZeros(d.frac);
    }

    /// Fraction digits up to the last non-zero one.
    pub fn decimals(d: Decimal) usize {
        return std.mem.trimEnd(u8, d.frac, "0").len;
    }

    /// Fraction digits as written: `89,90` has two.
    pub fn typedDecimals(d: Decimal) usize {
        return d.frac.len;
    }

    pub fn intDigits(d: Decimal) usize {
        return if (std.mem.eql(u8, d.int, "0")) 0 else d.int.len;
    }

    /// Zeros between the decimal point and the first non-zero fraction digit.
    pub fn leadingZeros(d: Decimal) usize {
        var n: usize = 0;
        while (n < d.frac.len and d.frac[n] == '0') n += 1;
        return n;
    }

    pub const Rounded = struct { value: Decimal, lost: bool };

    /// Rounds half away from zero to `places` fraction digits and drops
    /// trailing zeros; `lost` says whether a non-zero digit was cut off.
    pub fn roundDecimals(d: Decimal, a: Allocator, places: usize) !Rounded {
        if (d.frac.len <= places) return .{ .value = try d.trimmed(a), .lost = false };
        const cut = d.frac[places..];
        const lost = !allZeros(cut);
        const round_up = cut[0] >= '5';
        const kept = try std.mem.concat(a, u8, &.{ d.int, d.frac[0..places] });
        const digits = if (round_up) try increment(a, kept) else kept;
        const split = digits.len - places;
        const r = try fromParts(a, d.negative, digits[0..split], digits[split..]);
        return .{ .value = try r.trimmed(a), .lost = lost };
    }

    /// Rounds to `digits` significant digits (half away from zero).
    pub fn roundSignificant(d: Decimal, a: Allocator, digits: usize) !Rounded {
        if (d.isZero()) return .{ .value = try d.trimmed(a), .lost = false };
        const int_digits = d.intDigits();
        if (int_digits >= digits) {
            // Rounding happens left of the decimal point.
            const places = int_digits - digits;
            const r = try d.roundDecimals(a, 0);
            const ri = try roundIntegerDigits(a, r.value.int, places);
            return .{
                .value = try fromParts(a, d.negative, ri.digits, ""),
                .lost = r.lost or ri.lost or !d.isInteger(),
            };
        }
        const places = if (int_digits == 0) d.leadingZeros() + digits else digits - int_digits;
        return d.roundDecimals(a, places);
    }

    /// Appends zeros up to `places` fraction digits.
    pub fn padded(d: Decimal, a: Allocator, places: usize) !Decimal {
        if (d.frac.len >= places) return d;
        const frac = try a.alloc(u8, places);
        @memcpy(frac[0..d.frac.len], d.frac);
        @memset(frac[d.frac.len..], '0');
        return .{ .negative = d.negative, .int = d.int, .frac = frac };
    }

    pub fn trimmed(d: Decimal, a: Allocator) !Decimal {
        return fromParts(a, d.negative, d.int, std.mem.trimEnd(u8, d.frac, "0"));
    }

    /// German notation: `.` groups thousands, `,` separates the fraction.
    pub fn german(d: Decimal, a: Allocator) ![]u8 {
        return d.format(a, .de);
    }

    /// The notation of `numbers`: German `1.234,5` or English `1,234.5`.
    pub fn format(d: Decimal, a: Allocator, numbers: Language) ![]u8 {
        const group: u8 = if (numbers == .de) '.' else ',';
        const point: u8 = if (numbers == .de) ',' else '.';
        var out: std.ArrayList(u8) = .empty;
        if (d.negative) try out.append(a, '-');
        try groupThousands(a, &out, d.int, group);
        if (d.frac.len > 0) {
            try out.append(a, point);
            try out.appendSlice(a, d.frac);
        }
        return out.toOwnedSlice(a);
    }

    /// Program notation: no grouping, `.` separates the fraction.
    pub fn plain(d: Decimal, a: Allocator) ![]u8 {
        return a.print("{s}{s}{s}{s}", .{
            if (d.negative) "-" else "",
            d.int,
            if (d.frac.len > 0) "." else "",
            d.frac,
        });
    }

    /// Mantissa (rounded to `digits` significant digits, trailing zeros
    /// dropped) and the power of ten, for `1,23 × 10³⁰`.
    pub fn scientific(d: Decimal, a: Allocator, digits: usize) !Scientific {
        var exponent: i32 = if (d.intDigits() > 0)
            @as(i32, @intCast(d.intDigits())) - 1
        else
            -(@as(i32, @intCast(d.leadingZeros())) + 1);
        const all = try std.mem.concat(a, u8, &.{ d.int, d.frac });
        const significant = std.mem.trimStart(u8, all, "0");
        const head = significant[0..@min(1, significant.len)];
        const tail = if (significant.len > 1) significant[1..] else "";
        const mantissa = try fromParts(a, d.negative, head, tail);
        var r = try mantissa.roundSignificant(a, digits);
        // Rounding 9,99… up can carry into a second integer digit.
        if (r.value.int.len > 1) {
            const rest = try std.mem.concat(a, u8, &.{ r.value.int[1..], r.value.frac });
            const shifted = try fromParts(a, r.value.negative, r.value.int[0..1], rest);
            r.value = try shifted.trimmed(a);
            exponent += 1;
        }
        return .{ .mantissa = r.value, .exponent = exponent, .lost = r.lost };
    }

    /// The value divided by `10^places`: `19` becomes `0.19` for two places.
    pub fn scaledDown(d: Decimal, a: Allocator, places: usize) !Decimal {
        const width = places + 1;
        const int = if (d.int.len >= width) d.int else blk: {
            const padded_int = try a.alloc(u8, width);
            @memset(padded_int[0 .. width - d.int.len], '0');
            @memcpy(padded_int[width - d.int.len ..], d.int);
            break :blk padded_int;
        };
        const split = int.len - places;
        return fromParts(a, d.negative, int[0..split], try std.mem.concat(a, u8, &.{ int[split..], d.frac }));
    }

    pub fn negated(d: Decimal) Decimal {
        var n = d;
        n.negative = !d.negative and !d.isZero();
        return n;
    }

    /// Adds two decimals exactly.
    pub fn add(d: Decimal, a: Allocator, other: Decimal) !Decimal {
        const places = @max(d.frac.len, other.frac.len);
        const left = try d.padded(a, places);
        const right = try other.padded(a, places);
        const width = @max(left.int.len, right.int.len) + 1;
        const x = try scaled(a, left, width);
        const y = try scaled(a, right, width);
        var negative: bool = undefined;
        var digits: []u8 = undefined;
        if (left.negative == right.negative) {
            negative = left.negative;
            digits = try addDigits(a, x, y);
        } else if (std.mem.order(u8, x, y) == .lt) {
            negative = right.negative;
            digits = try subDigits(a, y, x);
        } else {
            negative = left.negative;
            digits = try subDigits(a, x, y);
        }
        const split = digits.len - places;
        return fromParts(a, negative, digits[0..split], digits[split..]);
    }

    pub fn compare(d: Decimal, other: Decimal) std.math.Order {
        if (!d.negative and other.negative) return .gt;
        if (d.negative and !other.negative) return .lt;
        var magnitude = std.math.order(d.int.len, other.int.len);
        if (magnitude == .eq) magnitude = std.mem.order(u8, d.int, other.int);
        if (magnitude == .eq) {
            // Compare the fractions as if padded to the same length.
            const n = @max(d.frac.len, other.frac.len);
            for (0..n) |i| {
                const x: u8 = if (i < d.frac.len) d.frac[i] else '0';
                const y: u8 = if (i < other.frac.len) other.frac[i] else '0';
                if (x != y) {
                    magnitude = std.math.order(x, y);
                    break;
                }
            }
        }
        return if (d.negative) magnitude.invert() else magnitude;
    }
};

/// A number in scientific notation, from `Decimal.scientific`.
pub const Scientific = struct {
    mantissa: Decimal,
    exponent: i32,
    /// Whether rounding the mantissa dropped non-zero digits.
    lost: bool,

    /// `1,23 × 10³⁰`
    pub fn german(s: Scientific, a: Allocator) ![]u8 {
        return s.format(a, .de);
    }

    /// `1,23 × 10³⁰` or `1.23 × 10³⁰`.
    pub fn format(s: Scientific, a: Allocator, numbers: Language) ![]u8 {
        return a.print("{s} × 10{s}", .{ try s.mantissa.format(a, numbers), try superscript(a, s.exponent) });
    }

    /// `1.23e30`
    pub fn plain(s: Scientific, a: Allocator) ![]u8 {
        return a.print("{s}e{d}", .{ try s.mantissa.plain(a), s.exponent });
    }
};

fn superscript(a: Allocator, exponent: i32) ![]u8 {
    const digits = [_][]const u8{ "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" };
    var out: std.ArrayList(u8) = .empty;
    if (exponent < 0) try out.appendSlice(a, "⁻");
    var buf: [16]u8 = undefined;
    const s = std.mem.print(&buf, "{d}", .{@abs(exponent)}) catch unreachable;
    for (s) |ch| try out.appendSlice(a, digits[ch - '0']);
    return out.toOwnedSlice(a);
}

fn groupThousands(a: Allocator, out: *std.ArrayList(u8), int: []const u8, separator: u8) !void {
    for (int, 0..) |digit, i| {
        if (i > 0 and (int.len - i) % 3 == 0) try out.append(a, separator);
        try out.append(a, digit);
    }
}

fn allDigits(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn allZeros(s: []const u8) bool {
    for (s) |ch| if (ch != '0') return false;
    return true;
}

/// Adds one to a string of ASCII digits.
fn increment(a: Allocator, digits: []const u8) ![]u8 {
    const bytes = try a.dupe(u8, digits);
    var i = bytes.len;
    while (i > 0) {
        i -= 1;
        if (bytes[i] == '9') {
            bytes[i] = '0';
        } else {
            bytes[i] += 1;
            return bytes;
        }
    }
    return std.mem.concat(a, u8, &.{ "1", bytes });
}

/// Rounds an integer digit string to zeros in its last `places` digits.
fn roundIntegerDigits(a: Allocator, int: []const u8, places: usize) !struct { digits: []const u8, lost: bool } {
    if (places == 0) return .{ .digits = int, .lost = false };
    const split = int.len - places;
    const cut = int[split..];
    const lost = !allZeros(cut);
    const head = if (cut[0] >= '5') try increment(a, int[0..split]) else try a.dupe(u8, int[0..split]);
    const out = try a.alloc(u8, head.len + places);
    @memcpy(out[0..head.len], head);
    @memset(out[head.len..], '0');
    return .{ .digits = out, .lost = lost };
}

fn scaled(a: Allocator, d: Decimal, width: usize) ![]u8 {
    const out = try a.alloc(u8, width + d.frac.len);
    @memset(out[0 .. width - d.int.len], '0');
    @memcpy(out[width - d.int.len .. width], d.int);
    @memcpy(out[width..], d.frac);
    return out;
}

fn addDigits(a: Allocator, x: []const u8, y: []const u8) ![]u8 {
    const out = try a.alloc(u8, x.len + 1);
    var carry: u8 = 0;
    var i = x.len;
    while (i > 0) {
        i -= 1;
        const sum = (x[i] - '0') + (y[i] - '0') + carry;
        out[i + 1] = '0' + sum % 10;
        carry = sum / 10;
    }
    out[0] = '0' + carry;
    return out;
}

/// `x - y` for equally long digit strings with `x >= y`.
fn subDigits(a: Allocator, x: []const u8, y: []const u8) ![]u8 {
    const out = try a.alloc(u8, x.len);
    var borrow: i16 = 0;
    var i = x.len;
    while (i > 0) {
        i -= 1;
        var digit: i16 = @as(i16, x[i] - '0') - @as(i16, y[i] - '0') - borrow;
        borrow = 0;
        if (digit < 0) {
            digit += 10;
            borrow = 1;
        }
        out[i] = '0' + @as(u8, @intCast(digit));
    }
    return out;
}

const testing = std.testing;

const T = struct {
    arena: std.heap.ArenaAllocator,
    fn init() T {
        return .{ .arena = .init(testing.allocator) };
    }
    fn deinit(t: *T) void {
        t.arena.deinit();
        t.* = undefined;
    }
    fn a(t: *T) Allocator {
        return t.arena.allocator();
    }
    fn dec(t: *T, s: []const u8) Decimal {
        return (Decimal.parse(t.a(), s) catch unreachable).?;
    }
    fn plainOf(t: *T, d: Decimal) []const u8 {
        return d.plain(t.a()) catch unreachable;
    }
};

test "formats German and plain" {
    var t: T = .init();
    defer t.deinit();
    try testing.expectEqualStrings("4.166,70", try t.dec("4166.70").german(t.a()));
    try testing.expectEqualStrings("4166.70", t.plainOf(t.dec("4166.70")));
    try testing.expectEqualStrings("-1.234.567", try t.dec("-1234567").german(t.a()));
    try testing.expectEqualStrings("0,3", try t.dec("0.3").german(t.a()));
    try testing.expectEqualStrings("18.446.744.073.709.551.616", try t.dec("18446744073709551616").german(t.a()));
    try testing.expectEqualStrings("4,166.70", try t.dec("4166.70").format(t.a(), .en));
    try testing.expectEqualStrings("-1,234,567", try t.dec("-1234567").format(t.a(), .en));
    try testing.expectEqualStrings("0.3", try t.dec("0.3").format(t.a(), .en));
}

test "rounds half away from zero" {
    var t: T = .init();
    defer t.deinit();
    const cases = [_]struct { []const u8, usize, []const u8, bool }{
        .{ "1091.5966386555", 2, "1091.6", true },
        .{ "2.235", 2, "2.24", true },
        .{ "-2.235", 2, "-2.24", true },
        .{ "9.999", 2, "10", true },
        .{ "2.5", 2, "2.5", false },
    };
    for (cases) |c| {
        const r = try t.dec(c[0]).roundDecimals(t.a(), c[1]);
        try testing.expectEqualStrings(c[2], t.plainOf(r.value));
        try testing.expectEqual(c[3], r.lost);
    }
}

test "rounds to significant digits" {
    var t: T = .init();
    defer t.deinit();
    const pi = try t.dec("3.14159265358979").roundSignificant(t.a(), 12);
    try testing.expectEqualStrings("3.14159265359", t.plainOf(pi.value));
    try testing.expect(pi.lost);
    const small = try t.dec("0.000123456789012345").roundSignificant(t.a(), 3);
    try testing.expectEqualStrings("0.000123", t.plainOf(small.value));
    const big = try t.dec("123456789").roundSignificant(t.a(), 3);
    try testing.expectEqualStrings("123000000", t.plainOf(big.value));
    try testing.expect(big.lost);
    const same = try t.dec("4166.7").roundSignificant(t.a(), 12);
    try testing.expectEqualStrings("4166.7", t.plainOf(same.value));
    try testing.expect(!same.lost);
}

test "writes scientific notation" {
    var t: T = .init();
    defer t.deinit();
    const big = try t.dec("1267650600228229401496703205376").scientific(t.a(), 12);
    try testing.expectEqualStrings("1,26765060023 × 10³⁰", try big.german(t.a()));
    try testing.expectEqualStrings("1.26765060023 × 10³⁰", try big.format(t.a(), .en));
    try testing.expectEqualStrings("1.26765060023e30", try big.plain(t.a()));
    try testing.expect(big.lost);
    const small = try t.dec("0.00000000000000000001").scientific(t.a(), 12);
    try testing.expectEqualStrings("1 × 10⁻²⁰", try small.german(t.a()));
    try testing.expect(!small.lost);
    try testing.expectEqualStrings("1e1", try (try t.dec("9.9999999999999").scientific(t.a(), 3)).plain(t.a()));
}

test "adds and compares exactly" {
    var t: T = .init();
    defer t.deinit();
    try testing.expectEqualStrings("566.80", t.plainOf(try t.dec("387").add(t.a(), t.dec("179.80"))));
    try testing.expectEqualStrings("0.3", t.plainOf(try t.dec("0.1").add(t.a(), t.dec("0.2"))));
    try testing.expectEqualStrings("-2.5", t.plainOf(try t.dec("5").add(t.a(), t.dec("-7.5"))));
    try testing.expectEqualStrings("0", t.plainOf(try t.dec("-5").add(t.a(), t.dec("5"))));
    try testing.expectEqual(std.math.Order.lt, t.dec("34.65").compare(t.dec("387")));
    try testing.expectEqual(std.math.Order.gt, t.dec("-1").compare(t.dec("-2")));
    try testing.expectEqual(std.math.Order.eq, t.dec("2.50").compare(t.dec("2.5")));
}

test "scales down and negates" {
    var t: T = .init();
    defer t.deinit();
    try testing.expectEqualStrings("0.19", t.plainOf(try t.dec("19").scaledDown(t.a(), 2)));
    try testing.expectEqualStrings("0.025", t.plainOf(try t.dec("2.5").scaledDown(t.a(), 2)));
    try testing.expectEqualStrings("12.50", t.plainOf(try t.dec("1250").scaledDown(t.a(), 2)));
    const part = (try t.dec("19").scaledDown(t.a(), 2)).negated();
    try testing.expectEqualStrings("0.81", t.plainOf(try t.dec("1").add(t.a(), part)));
}

test "rejects text that is not a plain number" {
    var t: T = .init();
    defer t.deinit();
    for ([_][]const u8{ "", "-", "1.", ".5", "1.2.3", "1e5", "12a" }) |s| {
        try testing.expect(try Decimal.parse(t.a(), s) == null);
    }
}
