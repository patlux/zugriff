//! Evaluates a task: exact fractions while the arithmetic allows it, a
//! binary float only where a function or a constant has no exact value,
//! and units with their dimensions.
//!
//! This takes the place of fend-core in the Rust version. Values are kept
//! in base units (`units.zig`); the units a result is shown in follow the
//! task: the target of `in`, otherwise the units of the operands.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Big = std.math.big.int.Managed;
const Decimal = @import("decimal.zig").Decimal;
const lexer = @import("lexer.zig");
const syntax = @import("syntax.zig");
const units = @import("units.zig");
const Expr = syntax.Expr;
const Reading = syntax.Reading;
const Dims = units.Dims;

/// Larger exact numbers are not worth the wait: the palette answers "zu
/// aufwendig" instead (2^100000 has 30 103 digits).
const max_bits = 100_000;

pub const Error = error{ DivisionByZero, NotReal, Incompatible, TooSlow, Unreadable, OutOfMemory };

/// When a calculation has to give up. Read from the monotonic clock.
pub const Deadline = struct {
    end_ns: u64,

    pub fn after(budget_ns: u64) Deadline {
        return .{ .end_ns = now() +| budget_ns };
    }

    pub fn passed(d: Deadline) bool {
        return now() >= d.end_ns;
    }

    fn now() u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
};

/// An exact fraction in lowest terms; the denominator is positive.
pub const Rat = struct {
    num: Big,
    den: Big,

    pub fn fromInt(a: Allocator, v: anytype) !Rat {
        return .{ .num = try Big.initSet(a, v), .den = try Big.initSet(a, 1) };
    }

    pub fn fromRatio(a: Allocator, r: units.Ratio) !Rat {
        return normalized(a, try Big.initSet(a, r.num), try Big.initSet(a, r.den));
    }

    /// `d` exactly: its digits over a power of ten.
    pub fn fromDecimal(a: Allocator, d: Decimal) !Rat {
        var num = try Big.init(a);
        const digits = try std.mem.concat(a, u8, &.{ d.int, d.frac });
        num.setString(10, digits) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBase, error.InvalidCharacter => unreachable,
        };
        if (d.negative) num.negate();
        return normalized(a, num, try pow10(a, d.frac.len));
    }

    /// The binary value of `x` exactly (a float is a fraction over a power of two).
    pub fn fromFloat(a: Allocator, x: f64) !Rat {
        if (x == 0) return fromInt(a, 0);
        const parts = std.math.frexp(x);
        // significand in [0.5, 1): times 2^53 it is an integer.
        const m: i64 = @intFromFloat(parts.significand * 9007199254740992.0);
        const e = parts.exponent - 53;
        var num = try Big.initSet(a, m);
        var den = try Big.initSet(a, 1);
        if (e >= 0) {
            var shifted = try Big.init(a);
            try shifted.shiftLeft(&num, @intCast(e));
            num = shifted;
        } else {
            var shifted = try Big.init(a);
            try shifted.shiftLeft(&den, @intCast(-e));
            den = shifted;
        }
        return normalized(a, num, den);
    }

    fn normalized(a: Allocator, num_in: Big, den_in: Big) !Rat {
        var num = num_in;
        var den = den_in;
        if (den.eqlZero()) return error.DivisionByZero;
        if (!den.isPositive()) {
            num.negate();
            den.negate();
        }
        if (num.eqlZero()) return .{ .num = num, .den = try Big.initSet(a, 1) };
        var g = try Big.init(a);
        try g.gcd(&num, &den);
        if (g.toConst().orderAgainstScalar(1) == .eq) return .{ .num = num, .den = den };
        var q1 = try Big.init(a);
        var r1 = try Big.init(a);
        try q1.divTrunc(&r1, &num, &g);
        var q2 = try Big.init(a);
        var r2 = try Big.init(a);
        try q2.divTrunc(&r2, &den, &g);
        return .{ .num = q1, .den = q2 };
    }

    pub fn isZero(r: Rat) bool {
        return r.num.eqlZero();
    }

    pub fn isNegative(r: Rat) bool {
        return !r.num.isPositive() and !r.num.eqlZero();
    }

    pub fn isInteger(r: Rat) bool {
        return r.den.toConst().orderAgainstScalar(1) == .eq;
    }

    pub fn add(x: Rat, a: Allocator, y: Rat) !Rat {
        var p1 = try Big.init(a);
        try p1.mul(&x.num, &y.den);
        var p2 = try Big.init(a);
        try p2.mul(&y.num, &x.den);
        var num = try Big.init(a);
        try num.add(&p1, &p2);
        var den = try Big.init(a);
        try den.mul(&x.den, &y.den);
        return normalized(a, num, den);
    }

    pub fn neg(x: Rat, a: Allocator) !Rat {
        var num = try x.num.cloneWithDifferentAllocator(a);
        num.negate();
        return .{ .num = num, .den = x.den };
    }

    pub fn sub(x: Rat, a: Allocator, y: Rat) !Rat {
        return x.add(a, try y.neg(a));
    }

    pub fn mul(x: Rat, a: Allocator, y: Rat) !Rat {
        var num = try Big.init(a);
        try num.mul(&x.num, &y.num);
        var den = try Big.init(a);
        try den.mul(&x.den, &y.den);
        return normalized(a, num, den);
    }

    pub fn div(x: Rat, a: Allocator, y: Rat) !Rat {
        if (y.isZero()) return error.DivisionByZero;
        var num = try Big.init(a);
        try num.mul(&x.num, &y.den);
        var den = try Big.init(a);
        try den.mul(&x.den, &y.num);
        return normalized(a, num, den);
    }

    pub fn abs(x: Rat, a: Allocator) !Rat {
        var num = try x.num.cloneWithDifferentAllocator(a);
        num.abs();
        return .{ .num = num, .den = x.den };
    }

    /// `x^n` for an integer `n`; too large a result is `TooSlow`.
    pub fn powInt(x: Rat, a: Allocator, n: i64) Error!Rat {
        if (n == 0) return fromInt(a, 1);
        if (x.isZero()) return if (n < 0) error.DivisionByZero else fromInt(a, 0);
        const e: u64 = @abs(n);
        const bits = @max(x.num.bitCountAbs(), x.den.bitCountAbs());
        // |x| = 1 stays 1 at any power.
        if (bits > 1 or x.den.toConst().orderAgainstScalar(1) != .eq) {
            if (e > max_bits or (bits -| 1) * e > max_bits) return error.TooSlow;
        }
        const e32: u32 = std.math.cast(u32, e) orelse return error.TooSlow;
        var num = try Big.init(a);
        try num.pow(&x.num, e32);
        var den = try Big.init(a);
        try den.pow(&x.den, e32);
        if (n < 0) return normalized(a, den, num);
        return normalized(a, num, den);
    }

    /// The exact square root, when numerator and denominator are squares.
    pub fn sqrtExact(x: Rat, a: Allocator) error{OutOfMemory}!?Rat {
        if (x.isNegative()) return null;
        var n = try Big.init(a);
        n.sqrt(&x.num) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else null;
        var n2 = try Big.init(a);
        try n2.mul(&n, &n);
        if (!n2.eql(x.num)) return null;
        var d = try Big.init(a);
        d.sqrt(&x.den) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else null;
        var d2 = try Big.init(a);
        try d2.mul(&d, &d);
        if (!d2.eql(x.den)) return null;
        return .{ .num = n, .den = d };
    }

    /// Rounds half away from zero to an integer.
    pub fn round(x: Rat, a: Allocator) !Rat {
        // floor(|x| + 1/2), with the sign put back.
        var twice = try Big.init(a);
        try twice.shiftLeft(&x.num, 1);
        twice.abs();
        var plus = try Big.init(a);
        try plus.add(&twice, &x.den);
        var den2 = try Big.init(a);
        try den2.shiftLeft(&x.den, 1);
        var q = try Big.init(a);
        var r = try Big.init(a);
        try q.divTrunc(&r, &plus, &den2);
        if (x.isNegative()) q.negate();
        return .{ .num = q, .den = try Big.initSet(a, 1) };
    }

    pub fn toFloat(x: Rat) f64 {
        const n = x.num.toFloat(f64, .nearest_even)[0];
        const d = x.den.toFloat(f64, .nearest_even)[0];
        return n / d;
    }

    pub const Digits = struct { value: Decimal, exact: bool };

    /// The value as a decimal: every digit when the denominator has no
    /// prime factors but 2 and 5, else `sig` significant digits.
    pub fn toDecimal(x: Rat, a: Allocator, sig: usize) !Digits {
        const negative = x.isNegative();
        var mag = try x.num.cloneWithDifferentAllocator(a);
        mag.abs();
        // Count the twos and fives of the denominator.
        var rest = try x.den.cloneWithDifferentAllocator(a);
        var twos: usize = 0;
        var fives: usize = 0;
        const five = try Big.initSet(a, 5);
        while (!rest.eqlZero() and rest.isEven()) {
            var half = try Big.init(a);
            try half.shiftRight(&rest, 1);
            rest = half;
            twos += 1;
        }
        while (true) {
            var q = try Big.init(a);
            var r = try Big.init(a);
            try q.divTrunc(&r, &rest, &five);
            if (!r.eqlZero()) break;
            rest = q;
            fives += 1;
        }
        if (rest.toConst().orderAgainstScalar(1) == .eq) {
            const places = @max(twos, fives);
            var scaled = try Big.init(a);
            try scaled.mul(&mag, &try pow10(a, places));
            var q = try Big.init(a);
            var r = try Big.init(a);
            try q.divTrunc(&r, &scaled, &x.den);
            return .{ .value = try withPoint(a, negative, try bigString(a, q), places), .exact = true };
        }
        // Enough digits for `sig` significant ones and one to round with.
        var places: usize = sig + 1;
        while (true) {
            var scaled = try Big.init(a);
            try scaled.mul(&mag, &try pow10(a, places));
            var q = try Big.init(a);
            var r = try Big.init(a);
            try q.divTrunc(&r, &scaled, &x.den);
            const digits = try bigString(a, q);
            const have = if (q.eqlZero()) 0 else digits.len;
            if (have >= sig + 1) {
                const d = try withPoint(a, negative, digits, places);
                return .{ .value = (try d.roundSignificant(a, sig)).value, .exact = false };
            }
            places += sig + 1 - have;
        }
    }
};

/// The decimal digits of `x`.
pub fn bigString(a: Allocator, x: Big) error{OutOfMemory}![]u8 {
    return x.toString(a, 10, .lower) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidBase => unreachable,
    };
}

fn pow10(a: Allocator, n: usize) !Big {
    var ten = try Big.initSet(a, 10);
    var out = try Big.init(a);
    try out.pow(&ten, @intCast(n));
    return out;
}

/// `digits` with a decimal point `places` from the right.
fn withPoint(a: Allocator, negative: bool, digits: []const u8, places: usize) !Decimal {
    const padded = if (digits.len > places) digits else blk: {
        const p = try a.alloc(u8, places + 1);
        @memset(p[0 .. places + 1 - digits.len], '0');
        @memcpy(p[places + 1 - digits.len ..], digits);
        break :blk p;
    };
    const split = padded.len - places;
    const s = try a.print("{s}{s}{s}{s}", .{
        if (negative) "-" else "",
        padded[0..split],
        if (places > 0) "." else "",
        padded[split..],
    });
    return (try Decimal.parse(a, s)).?;
}

pub const Num = union(enum) {
    exact: Rat,
    approx: f64,

    fn float(n: Num) f64 {
        return switch (n) {
            .exact => |r| r.toFloat(),
            .approx => |f| f,
        };
    }
};

/// The units a value is shown in: up to four units with powers.
pub const UnitList = struct {
    ids: [4]units.Id = undefined,
    pows: [4]i8 = undefined,
    len: u8 = 0,

    pub fn single(id: units.Id) UnitList {
        var l: UnitList = .{};
        l.ids[0] = id;
        l.pows[0] = 1;
        l.len = 1;
        return l;
    }

    fn addUnit(l: *UnitList, id: units.Id, p: i8) void {
        for (0..l.len) |i| if (l.ids[i] == id) {
            l.pows[i] += p;
            if (l.pows[i] == 0) l.remove(i);
            return;
        };
        if (l.len == l.ids.len) return;
        l.ids[l.len] = id;
        l.pows[l.len] = p;
        l.len += 1;
    }

    fn remove(l: *UnitList, i: usize) void {
        var j = i;
        while (j + 1 < l.len) : (j += 1) {
            l.ids[j] = l.ids[j + 1];
            l.pows[j] = l.pows[j + 1];
        }
        l.len -= 1;
    }

    fn combine(x: UnitList, y: UnitList, sign: i8) UnitList {
        var out = x;
        for (0..y.len) |i| out.addUnit(y.ids[i], y.pows[i] * sign);
        return out;
    }

    fn scaled(l: UnitList, n: i8) UnitList {
        var out = l;
        for (0..out.len) |i| out.pows[i] *= n;
        return out;
    }
};

pub const Value = struct {
    num: Num,
    dims: Dims = units.dimensionless,
    shown: UnitList = .{},

    fn dimensionless(v: Value) bool {
        return std.mem.eql(i8, &v.dims, &units.dimensionless);
    }
};

pub const Evaluator = struct {
    a: Allocator,
    reading: Reading,
    deadline: Deadline,

    pub fn eval(ev: *Evaluator, e: *const Expr) Error!Value {
        if (ev.deadline.passed()) return error.TooSlow;
        return switch (e.*) {
            .number => |lit| .{ .num = .{ .exact = try Rat.fromDecimal(ev.a, syntax.literalValue(lit, ev.reading)) } },
            .constant => |k| .{ .num = .{ .approx = if (k == .pi) std.math.pi else std.math.e } },
            .unit => |id| .{
                .num = .{ .exact = try Rat.fromRatio(ev.a, units.get(id).factor) },
                .dims = units.get(id).dims,
                .shown = .single(id),
            },
            .quantity => |q| ev.quantity(try ev.eval(q.value), q.unit),
            .money => |m| ev.eval(m.value),
            .group => |inner| ev.eval(inner),
            .neg => |inner| blk: {
                // −5 °C is five degrees below zero on its scale, not minus 278,15 K.
                if (inner.* == .quantity and units.get(inner.quantity.unit).offset.num != 0) {
                    var amount = try ev.eval(inner.quantity.value);
                    amount.num = try ev.numOp(.sub, .{ .exact = try Rat.fromInt(ev.a, 0) }, amount.num);
                    break :blk ev.quantity(amount, inner.quantity.unit);
                }
                var v = try ev.eval(inner);
                v.num = switch (v.num) {
                    .exact => |r| .{ .exact = try r.neg(ev.a) },
                    .approx => |f| .{ .approx = -f },
                };
                break :blk v;
            },
            .binary => |b| ev.binary(b.op, try ev.eval(b.left), try ev.eval(b.right)),
            .joined => |j| ev.binary(.add, try ev.eval(j.left), try ev.eval(j.right)),
            .percent => |inner| ev.binary(.div, try ev.eval(inner), try ev.int(100)),
            .of => |o| switch (o.left.*) {
                .percent => |share| blk: {
                    const part = try ev.binary(.div, try ev.eval(share), try ev.int(100));
                    break :blk ev.binary(.mul, part, try ev.eval(o.right));
                },
                else => ev.binary(.div, try ev.eval(o.left), try ev.eval(o.right)),
            },
            .adjust => |adj| blk: {
                const part = try ev.binary(.div, try ev.eval(adj.percent), try ev.int(100));
                const factor = try ev.binary(adj.op, try ev.int(1), part);
                break :blk ev.binary(.mul, try ev.eval(adj.base), factor);
            },
            .func => |f| ev.func(f.func, f.arg),
        };
    }

    fn int(ev: *Evaluator, v: i64) !Value {
        return .{ .num = .{ .exact = try Rat.fromInt(ev.a, v) } };
    }

    fn quantity(ev: *Evaluator, v: Value, id: units.Id) Error!Value {
        const u = units.get(id);
        var out = v;
        // A temperature is a point on its scale: 20 °C is 293,15 K.
        if (u.offset.num != 0 and v.dimensionless()) {
            const off = try Rat.fromRatio(ev.a, u.offset);
            out.num = try ev.numOp(.add, v.num, .{ .exact = off });
        }
        out.num = try ev.numOp(.mul, out.num, .{ .exact = try Rat.fromRatio(ev.a, u.factor) });
        for (&out.dims, u.dims) |*d, ud| d.* += ud;
        out.shown = out.shown.combine(.single(id), 1);
        return out;
    }

    fn numOp(ev: *Evaluator, op: lexer.Op, x: Num, y: Num) Error!Num {
        if (x == .exact and y == .exact) {
            return .{ .exact = switch (op) {
                .add => try x.exact.add(ev.a, y.exact),
                .sub => try x.exact.sub(ev.a, y.exact),
                .mul => try x.exact.mul(ev.a, y.exact),
                .div => try x.exact.div(ev.a, y.exact),
                .pow => unreachable,
            } };
        }
        const f = x.float();
        const g = y.float();
        return .{ .approx = switch (op) {
            .add => f + g,
            .sub => f - g,
            .mul => f * g,
            .div => if (g == 0) return error.DivisionByZero else f / g,
            .pow => unreachable,
        } };
    }

    fn binary(ev: *Evaluator, op: lexer.Op, x: Value, y: Value) Error!Value {
        switch (op) {
            .add, .sub => {
                if (!std.mem.eql(i8, &x.dims, &y.dims)) return error.Incompatible;
                return .{
                    .num = try ev.numOp(op, x.num, y.num),
                    .dims = x.dims,
                    .shown = if (x.shown.len > 0) x.shown else y.shown,
                };
            },
            .mul, .div => {
                var dims = x.dims;
                const sign: i8 = if (op == .mul) 1 else -1;
                for (&dims, y.dims) |*d, yd| d.* += sign * yd;
                var shown = x.shown.combine(y.shown, sign);
                // km / m: no dimension is left, nothing to show.
                if (std.mem.eql(i8, &dims, &units.dimensionless)) shown = .{};
                return .{ .num = try ev.numOp(op, x.num, y.num), .dims = dims, .shown = shown };
            },
            .pow => return ev.power(x, y),
        }
    }

    fn power(ev: *Evaluator, base: Value, exp: Value) Error!Value {
        if (!exp.dimensionless()) return error.Incompatible;
        if (exp.num == .exact and exp.num.exact.isInteger()) {
            const n = exp.num.exact.num.toInt(i64) catch return error.TooSlow;
            const n8 = std.math.cast(i8, n);
            if (!base.dimensionless() and n8 == null) return error.TooSlow;
            var dims = base.dims;
            if (n8) |k| for (&dims) |*d| {
                d.* = std.math.mul(i8, d.*, k) catch return error.TooSlow;
            };
            const shown = if (n8) |k| base.shown.scaled(k) else base.shown;
            return switch (base.num) {
                .exact => |r| .{ .num = .{ .exact = try r.powInt(ev.a, n) }, .dims = dims, .shown = shown },
                .approx => |f| .{
                    .num = .{ .approx = std.math.pow(f64, f, @floatFromInt(n)) },
                    .dims = dims,
                    .shown = shown,
                },
            };
        }
        if (!base.dimensionless()) return error.Incompatible;
        const f = base.num.float();
        const g = exp.num.float();
        if (f < 0) return error.NotReal;
        return .{ .num = .{ .approx = std.math.pow(f64, f, g) } };
    }

    fn func(ev: *Evaluator, f: lexer.Func, arg_expr: *const Expr) Error!Value {
        const arg = try ev.eval(arg_expr);
        switch (f) {
            .sqrt => {
                for (arg.dims) |d| if (@rem(d, 2) != 0) return error.Incompatible;
                var dims = arg.dims;
                for (&dims) |*d| d.* = @divExact(d.*, 2);
                var shown: UnitList = .{};
                const halves = for (0..arg.shown.len) |i| {
                    if (@rem(arg.shown.pows[i], 2) != 0) break false;
                } else true;
                if (halves) {
                    shown = arg.shown;
                    for (0..shown.len) |i| shown.pows[i] = @divExact(shown.pows[i], 2);
                }
                const num: Num = switch (arg.num) {
                    .exact => |r| blk: {
                        if (r.isNegative()) return error.NotReal;
                        if (try r.sqrtExact(ev.a)) |root| break :blk .{ .exact = root };
                        break :blk .{ .approx = @sqrt(r.toFloat()) };
                    },
                    .approx => |x| if (x < 0) return error.NotReal else .{ .approx = @sqrt(x) },
                };
                return .{ .num = num, .dims = dims, .shown = shown };
            },
            .ln, .log => {
                if (!arg.dimensionless()) return error.Incompatible;
                if (arg.num == .exact and arg.num.exact.isInteger() and f == .log) {
                    // log10 of a power of ten is exact.
                    if (try exactLog10(ev.a, arg.num.exact)) |n| return ev.int(n);
                }
                const x = arg.num.float();
                if (x <= 0) return error.NotReal;
                if (arg.num == .exact and arg.num.exact.isInteger() and x == 1) return ev.int(0);
                return .{ .num = .{ .approx = if (f == .ln) @log(x) else std.math.log10(x) } };
            },
            .abs => {
                var v = arg;
                v.num = switch (arg.num) {
                    .exact => |r| .{ .exact = try r.abs(ev.a) },
                    .approx => |x| .{ .approx = @abs(x) },
                };
                return v;
            },
            .round => {
                var v = arg;
                v.num = switch (arg.num) {
                    .exact => |r| .{ .exact = try r.round(ev.a) },
                    .approx => |x| .{ .approx = @round(x) },
                };
                return v;
            },
            .sin, .cos, .tan => {
                // German school maths: angles are degrees, with ° or without.
                const angle_dims: Dims = .{ 0, 0, 0, 0, 0, 1 };
                if (!arg.dimensionless() and !std.mem.eql(i8, &arg.dims, &angle_dims)) return error.Incompatible;
                const radians = arg.num.float() * std.math.pi / 180.0;
                var y = switch (f) {
                    .sin => @sin(radians),
                    .cos => @cos(radians),
                    else => @tan(radians),
                };
                // sin 180° is zero, not a rounding error of π.
                if (@abs(y) < 1e-12) y = 0;
                if (!std.math.isFinite(y) or @abs(y) > 1e15) return error.DivisionByZero;
                return .{ .num = .{ .approx = y } };
            },
        }
    }
};

fn exactLog10(a: Allocator, r: Rat) !?i64 {
    if (r.isNegative() or r.isZero()) return null;
    const s = try bigString(a, r.num);
    if (s[0] != '1') return null;
    for (s[1..]) |ch| if (ch != '0') return null;
    return @intCast(s.len - 1);
}

/// A value as the answer shows it: a number in its units.
pub const Output = struct {
    value: Decimal,
    approximate: bool,
    /// `""` for a plain number, `"%"`, or the units: `km/h`, `Tage`.
    unit: []const u8,
};

pub const Target = union(enum) { none, unit: units.Id, percent };

/// Converts `v` to its target (or the units it carries) and to digits.
pub fn output(a: Allocator, v: Value, target: Target) Error!Output {
    var shown = v.shown;
    var num = v.num;
    var percent = false;
    switch (target) {
        .none => {},
        .unit => |id| {
            if (!std.mem.eql(i8, &v.dims, &units.get(id).dims)) return error.Incompatible;
            shown = .single(id);
        },
        .percent => {
            if (!v.dimensionless()) return error.Incompatible;
            shown = .{};
            percent = true;
            num = switch (num) {
                .exact => |r| .{ .exact = try r.mul(a, try Rat.fromInt(a, 100)) },
                .approx => |f| .{ .approx = f * 100 },
            };
        },
    }
    if (shown.len == 0 and !v.dimensionless() and target == .none) {
        // Units cancelled into something without a name: show base units.
        shown = baseUnits(v.dims);
    }

    // From base units into the shown ones.
    if (shown.len == 1 and shown.pows[0] == 1 and units.get(shown.ids[0]).offset.num != 0) {
        const u = units.get(shown.ids[0]);
        num = try divide(a, num, try Rat.fromRatio(a, u.factor));
        num = try subtract(a, num, try Rat.fromRatio(a, u.offset));
    } else {
        for (0..shown.len) |i| {
            const factor = try Rat.fromRatio(a, units.get(shown.ids[i]).factor);
            const p = shown.pows[i];
            const scaled = try factor.powInt(a, @abs(p));
            num = if (p > 0) try divide(a, num, scaled) else try multiply(a, num, scaled);
        }
    }

    const digits: Rat.Digits = switch (num) {
        .exact => |r| try r.toDecimal(a, 15),
        .approx => |f| blk: {
            if (!std.math.isFinite(f)) return error.TooSlow;
            const d = try (try Rat.fromFloat(a, f)).toDecimal(a, 15);
            const rounded = (try d.value.roundSignificant(a, 15)).value;
            // A float that has a short decimal (0,5, 2) is that number;
            // one with more than twelve digits is a rounded irrational.
            const kept = std.mem.trimEnd(u8, rounded.frac, "0");
            const all_digits = try std.mem.concat(a, u8, &.{ rounded.int, kept });
            const significant = std.mem.trimStart(u8, all_digits, "0");
            break :blk .{ .value = try rounded.trimmed(a), .exact = significant.len <= 12 };
        },
    };
    return .{
        .value = digits.value,
        .approximate = !digits.exact,
        .unit = if (percent) "%" else try label(a, shown, digits.value),
    };
}

fn divide(a: Allocator, n: Num, r: Rat) !Num {
    return switch (n) {
        .exact => |x| .{ .exact = try x.div(a, r) },
        .approx => |f| .{ .approx = f / r.toFloat() },
    };
}

fn multiply(a: Allocator, n: Num, r: Rat) !Num {
    return switch (n) {
        .exact => |x| .{ .exact = try x.mul(a, r) },
        .approx => |f| .{ .approx = f * r.toFloat() },
    };
}

fn subtract(a: Allocator, n: Num, r: Rat) !Num {
    return switch (n) {
        .exact => |x| .{ .exact = try x.sub(a, r) },
        .approx => |f| .{ .approx = f - r.toFloat() },
    };
}

fn baseUnits(dims: Dims) UnitList {
    const base = [_][]const u8{ "m", "kg", "s", "Bit", "K", "°" };
    var l: UnitList = .{};
    for (dims, base) |d, name| if (d != 0) {
        l.ids[l.len] = units.byDisplay(name);
        l.pows[l.len] = d;
        l.len += 1;
        if (l.len == l.ids.len) break;
    };
    return l;
}

/// `km/h`, `m²`, `Tage` or `Tag` for exactly one.
fn label(a: Allocator, l: UnitList, value: Decimal) ![]const u8 {
    if (l.len == 0) return "";
    if (l.len == 1 and l.pows[0] == 1) {
        const u = units.get(l.ids[0]);
        const one = value.isInteger() and std.mem.eql(u8, value.int, "1");
        return if (one) u.one orelse u.display else u.display;
    }
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    for (0..l.len) |i| if (l.pows[i] > 0) {
        if (!first) try out.appendSlice(a, "·");
        first = false;
        try appendPower(a, &out, units.get(l.ids[i]).display, l.pows[i]);
    };
    if (first) try out.append(a, '1');
    var denominator = false;
    for (0..l.len) |i| if (l.pows[i] < 0) {
        try out.appendSlice(a, if (denominator) "·" else "/");
        denominator = true;
        try appendPower(a, &out, units.get(l.ids[i]).display, -l.pows[i]);
    };
    return out.toOwnedSlice(a);
}

fn appendPower(a: Allocator, out: *std.ArrayList(u8), name: []const u8, p: i8) !void {
    try out.appendSlice(a, name);
    switch (p) {
        1 => {},
        2 => try out.appendSlice(a, "²"),
        3 => try out.appendSlice(a, "³"),
        else => try out.print(a, "^{d}", .{p}),
    }
}

const testing = std.testing;

test "fractions stay exact and print every digit they have" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const third = try (try Rat.fromInt(a, 1)).div(a, try Rat.fromInt(a, 3));
    const one = try third.mul(a, try Rat.fromInt(a, 3));
    try testing.expect(one.isInteger());
    const tenth = try Rat.fromDecimal(a, (try Decimal.parse(a, "0.1")).?);
    const sum = try tenth.add(a, try Rat.fromDecimal(a, (try Decimal.parse(a, "0.2")).?));
    const d = try sum.toDecimal(a, 15);
    try testing.expect(d.exact);
    try testing.expectEqualStrings("0.3", try d.value.plain(a));
    const approx = try third.toDecimal(a, 15);
    try testing.expect(!approx.exact);
    try testing.expectEqualStrings("0.333333333333333", try approx.value.plain(a));
}

test "powers grow exactly until they are too large" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const two = try Rat.fromInt(a, 2);
    const big = try two.powInt(a, 64);
    try testing.expectEqualStrings("18446744073709551616", try big.num.toString(a, 10, .lower));
    try testing.expectError(error.TooSlow, two.powInt(a, 1 << 20));
    const half = try two.powInt(a, -1);
    try testing.expectEqualStrings("0.5", try (try half.toDecimal(a, 15)).value.plain(a));
}

test "floats convert to their exact binary value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Rat.fromFloat(a, 0.5);
    try testing.expectEqualStrings("0.5", try (try r.toDecimal(a, 15)).value.plain(a));
    const big = try Rat.fromFloat(a, 1e20);
    try testing.expectEqualStrings("100000000000000000000", try big.num.toString(a, 10, .lower));
}
