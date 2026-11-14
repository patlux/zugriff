//! Turns a query into a calculation: recognise it, evaluate it and format
//! the answer the German way.
//!
//! Everything a calculation returns lives in the arena it is given.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Decimal = @import("decimal.zig").Decimal;
const lexer = @import("lexer.zig");
const syntax = @import("syntax.zig");
const eval = @import("eval.zig");
const units = @import("units.zig");
const text = @import("../text.zig");
const Token = lexer.Token;
const Literal = lexer.Literal;
const Expr = syntax.Expr;
const Task = syntax.Task;
const Reading = syntax.Reading;
pub const Gap = syntax.Gap;
pub const Deadline = eval.Deadline;

/// Digits a result keeps when it does not come out exact.
pub const significant_digits = 12;

/// Integers with more digits than this switch to scientific notation.
const max_integer_digits = 30;

/// A query that is a task, with its answer or the reason there is none.
pub const Calculation = struct {
    /// The task as Zugriff read it: `(1.299 + 89,90) × 3`, `1.299,00 € + 19 %`.
    task: []const u8,
    /// Words at the edges of a pasted task that were left out, as written.
    skipped: []const []const u8 = &.{},
    /// A dot before three digits was read as a thousands separator; the
    /// other reading is one of the alternatives.
    thousands_dot: bool = false,
    /// The query started with `=`, so even a lone value counts.
    forced: bool = false,
    conversion: ?Conversion = null,
    outcome: Outcome,
    /// Other common readings of the same task, best first.
    alternatives: []const Alternative = &.{},

    pub fn answer(c: Calculation) ?Answer {
        return switch (c.outcome) {
            .answer => |a| a,
            .problem => null,
        };
    }
};

pub const Outcome = union(enum) {
    answer: Answer,
    problem: Problem,
};

/// What the `in` of a task converts.
pub const Conversion = enum {
    /// kB, MB, GB, TB: decimal, the way Finder counts.
    decimal_data,
    units,
};

pub const Rounding = enum {
    /// To `significant_digits` digits.
    significant,
    /// To two decimals, for amounts of money.
    cents,
    /// To two decimals, for quantities with a unit.
    hundredths,
};

/// What follows the number of an answer.
pub const Label = union(enum) {
    none,
    unit: []const u8,
    percent,
    currency: []const u8,

    pub fn eql(a: Label, b: Label) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .unit => |u| std.mem.eql(u8, u, b.unit),
            .currency => |c| std.mem.eql(u8, c, b.currency),
            .none, .percent => true,
        };
    }
};

/// A computed result.
pub const Answer = struct {
    /// The result as shown and copied, without `≈`: `4.166,70`,
    /// `1.545,81 €`, `2.400 MB`, `1,23 × 10³⁰`.
    text: []const u8,
    /// The number alone, for programs: `4166.70`, `1.23e30`.
    number: []const u8,
    /// How the result was rounded, if it was.
    rounding: ?Rounding = null,
    value: Decimal,
    label: Label,

    pub fn isApproximate(a: Answer) bool {
        return a.rounding != null;
    }

    /// `≈ 3,14159265359` or `4.166,70`.
    pub fn shown(a: Answer, alloc: Allocator) ![]const u8 {
        return if (a.isApproximate()) alloc.print("≈ {s}", .{a.text}) else a.text;
    }

    /// The sign between task and result: `=` or `≈`.
    pub fn relation(a: Answer) []const u8 {
        return if (a.isApproximate()) "≈" else "=";
    }

    /// A copy into `alloc`, for answers that outlive their calculation.
    pub fn dupe(a: Answer, alloc: Allocator) !Answer {
        return .{
            .text = try alloc.dupe(u8, a.text),
            .number = try alloc.dupe(u8, a.number),
            .rounding = a.rounding,
            .value = .{
                .negative = a.value.negative,
                .int = try alloc.dupe(u8, a.value.int),
                .frac = try alloc.dupe(u8, a.value.frac),
            },
            .label = switch (a.label) {
                .unit => |u| .{ .unit = try alloc.dupe(u8, u) },
                .currency => |c| .{ .currency = try alloc.dupe(u8, c) },
                .none => .none,
                .percent => .percent,
            },
        };
    }
};

/// Why a task has no result.
pub const Problem = union(enum) {
    /// The task is not finished yet; nothing is wrong while typing.
    incomplete: Gap,
    division_by_zero,
    /// The result is complex, such as the square root of a negative number.
    not_real,
    /// Units that do not convert into each other, such as km and kg.
    incompatible,
    /// A conversion between currencies, which needs exchange rates.
    no_rates,
    /// The evaluation took longer than the palette may wait.
    too_slow,
    /// A task forced with `=` that cannot be read.
    unreadable,

    pub fn eql(a: Problem, b: Problem) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .incomplete => |g| g.eql(b.incomplete),
            else => true,
        };
    }
};

/// Another reading of the task, shown below its main result.
pub const Alternative = struct {
    task: []const u8,
    answer: Answer,
    kind: AlternativeKind,
};

pub const AlternativeKind = union(enum) {
    /// Only the percentage of `base ± p %`: the surcharge or the discount.
    share: bool,
    /// `base ± p %` read backwards: the value before the percentage.
    before: bool,
    /// The dot before three digits as a decimal point.
    decimal_point,
    /// A decimal data size in binary units (`MiB`).
    binary: []const u8,
};

pub const Mode = enum {
    /// A palette query: only real tasks count.
    query,
    /// A pasted line: a lone amount counts, and leading words are its label.
    line,
};

/// Recognises `raw` as a task and evaluates it within `budget_ns`.
///
/// Null keeps the query a search: a single number, a word or a constant is
/// not a task, and neither is anything with an unknown word between
/// numbers. `=` at the start makes every readable value a task.
pub fn calculate(a: Allocator, raw: []const u8, budget_ns: u64) !?Calculation {
    return calculateIn(a, raw, .query, Deadline.after(budget_ns));
}

pub fn calculateIn(a: Allocator, raw: []const u8, mode: Mode, deadline: Deadline) !?Calculation {
    const trimmed = text.trim(raw);
    const forced = std.mem.startsWith(u8, trimmed, "=");
    const body = if (forced) text.trim(trimmed[1..]) else trimmed;
    const tokens = try lexer.tokenize(a, body) orelse return null;
    const edges = try trimEdges(a, tokens);
    const core = edges.core;
    if (core.len == 0) return null;
    for (core) |t| if (t == .word or t == .mark) return null;
    const has_number = for (core) |t| {
        if (t == .number) break true;
    } else false;
    if (!forced and (!has_number or (mode == .query and !startsLikeTask(core)))) return null;

    const task = switch (try syntax.parse(a, core)) {
        .task => |t| t,
        .incomplete => |gap| {
            // An unfinished task is only worth a card while it is typed,
            // not when words around it might mean something else entirely.
            if (edges.skipped.len > 0 or mode == .line) return null;
            return .{
                .task = try a.dupe(u8, body),
                .forced = forced,
                .outcome = .{ .problem = .{ .incomplete = gap } },
            };
        },
        .invalid => {
            if (!forced) return null;
            return .{
                .task = try a.dupe(u8, body),
                .skipped = edges.skipped,
                .forced = forced,
                .outcome = .{ .problem = .unreadable },
            };
        },
    };
    if (mode == .query and !forced and !task.computes()) return null;

    // The other numbers of a task decide how to read `1.250`: next to
    // `89,90` it is German, next to `3.14` English, and on its own Zugriff
    // reads it German and offers the English reading too.
    var seen: NotationSeen = .{};
    syntax.literals(task.expr, &seen);
    const reading: Reading = if (seen.english and !seen.german) .english else .german;
    const ambiguous = seen.either and !seen.german and !seen.english;
    const conversion: ?Conversion = if (task.target) |t| switch (t) {
        .unit => |u| switch (units.get(u).kind) {
            .decimal_data => .decimal_data,
            .angle, .other => .units,
        },
        .percent, .currency => null,
    } else null;

    const outcome = try evaluate(a, task, reading, deadline);
    const alts: []const Alternative = switch (outcome) {
        .answer => |ans| try alternatives(a, task, ans, reading, ambiguous, deadline),
        .problem => &.{},
    };
    return .{
        .task = try task.show(a, reading),
        .skipped = edges.skipped,
        .thousands_dot = ambiguous,
        .forced = forced,
        .conversion = conversion,
        .outcome = outcome,
        .alternatives = alts,
    };
}

/// Which notations the numbers of a task give away.
const NotationSeen = struct {
    german: bool = false,
    english: bool = false,
    either: bool = false,

    pub fn literal(s: *NotationSeen, lit: Literal) void {
        s.german = s.german or lit.notation == .german;
        s.english = s.english or lit.notation == .english;
        s.either = s.either or lit.alternative != null;
    }
};

/// Whether a number of the task has exactly two decimals.
const CentsSeen = struct {
    reading: Reading,
    any: bool = false,

    pub fn literal(s: *CentsSeen, lit: Literal) void {
        s.any = s.any or syntax.literalValue(lit, s.reading).typedDecimals() == 2;
    }
};

/// Removes unknown words and punctuation around a pasted task: `Netto …
/// MwSt.`, `Was ist … ?`. Returns the rest and the words left out.
fn trimEdges(a: Allocator, tokens: []const Token) !struct { core: []const Token, skipped: []const []const u8 } {
    const isEdge = struct {
        fn f(t: Token) bool {
            return t == .word or t == .mark;
        }
    }.f;
    var start: usize = 0;
    while (start < tokens.len and isEdge(tokens[start])) start += 1;
    var end = tokens.len;
    while (end > start and isEdge(tokens[end - 1])) end -= 1;
    var skipped: std.ArrayList([]const u8) = .empty;
    for (tokens[0..start]) |t| if (t == .word) try skipped.append(a, t.word);
    for (tokens[end..]) |t| if (t == .word) try skipped.append(a, t.word);
    return .{ .core = tokens[start..end], .skipped = try skipped.toOwnedSlice(a) };
}

/// A task starts with a number, a bracket, a minus sign, a function, a
/// currency or a constant that is used in an operation (`pi × 2`, not `pi`).
fn startsLikeTask(tokens: []const Token) bool {
    const first = tokens[0];
    const second: ?Token = if (tokens.len > 1) tokens[1] else null;
    return switch (first) {
        .number, .open, .func => true,
        .op => |op| op == .sub and second != null and (second.? == .number or second.? == .open),
        .currency => second != null and second.? == .number,
        .constant => second != null and switch (second.?) {
            .op, .percent, .of, .convert => true,
            else => false,
        },
        else => false,
    };
}

/// How an answer is formatted: currency labels and amounts with cents.
const Style = struct {
    currency: ?[]const u8,
    /// A number in the task has exactly two decimals, so the result keeps
    /// two as well: `(1.299 + 89,90) × 3` is 4.166,70.
    cents: bool,
};

fn styleOf(task: Task, reading: Reading) ?Style {
    var found: [2][]const u8 = undefined;
    const n = syntax.currencies(task.expr, &found, 0);
    if (task.target != null and task.target.? == .currency) return null;
    if (n > 1) return null;
    var cents: CentsSeen = .{ .reading = reading };
    syntax.literals(task.expr, &cents);
    return .{ .currency = if (n > 0) found[0] else null, .cents = cents.any };
}

fn evaluate(a: Allocator, task: Task, reading: Reading, deadline: Deadline) !Outcome {
    const style = styleOf(task, reading) orelse return .{ .problem = .no_rates };
    var ev: eval.Evaluator = .{ .a = a, .reading = reading, .deadline = deadline };
    const target: eval.Target = if (task.target) |t| switch (t) {
        .unit => |u| .{ .unit = u },
        .percent => .percent,
        .currency => return .{ .problem = .no_rates },
    } else .none;
    const out = blk: {
        const value = ev.eval(task.expr) catch |e| return problemOf(e);
        break :blk eval.output(a, value, target) catch |e| return problemOf(e);
    };
    return .{ .answer = try formatAnswer(a, out, style) };
}

fn problemOf(e: eval.Error) !Outcome {
    return .{ .problem = switch (e) {
        error.DivisionByZero => .division_by_zero,
        error.NotReal => .not_real,
        error.Incompatible => .incompatible,
        error.TooSlow => .too_slow,
        error.Unreadable => .unreadable,
        error.OutOfMemory => return error.OutOfMemory,
    } };
}

fn formatAnswer(a: Allocator, out: eval.Output, style: Style) !Answer {
    const lab: Label = if (out.unit.len == 0)
        (if (style.currency) |c| .{ .currency = c } else .none)
    else if (std.mem.eql(u8, out.unit, "%")) .percent else .{ .unit = out.unit };
    return formatValue(a, out.value, out.approximate, lab, style.cents);
}

pub fn formatValue(a: Allocator, value: Decimal, approximate: bool, lab: Label, cents: bool) !Answer {
    const tiny = !value.isZero() and value.intDigits() == 0 and value.leadingZeros() >= 6;
    if (value.intDigits() > max_integer_digits or tiny) {
        const sci = try value.scientific(a, significant_digits);
        return .{
            .text = try withLabel(a, try sci.german(a), lab),
            .number = try sci.plain(a),
            .rounding = if (approximate or sci.lost) .significant else null,
            .value = value,
            .label = lab,
        };
    }

    var shown: Decimal = undefined;
    var lost: bool = undefined;
    var rounding: Rounding = undefined;
    switch (lab) {
        .unit => {
            const r = if (value.intDigits() == 0 and value.decimals() > 2)
                try value.roundSignificant(a, 3)
            else
                try value.roundDecimals(a, 2);
            shown = r.value;
            lost = r.lost;
            rounding = .hundredths;
        },
        .currency => if (!value.isInteger()) {
            const r = try value.roundDecimals(a, 2);
            shown = try r.value.padded(a, 2);
            lost = r.lost;
            rounding = .cents;
        } else {
            try plainRounding(a, value, approximate, cents, &shown, &lost);
            rounding = .significant;
        },
        .none, .percent => {
            try plainRounding(a, value, approximate, cents, &shown, &lost);
            rounding = .significant;
        },
    }
    return .{
        .text = try withLabel(a, try shown.german(a), lab),
        .number = try shown.plain(a),
        .rounding = if (approximate or lost) rounding else null,
        .value = shown,
        .label = lab,
    };
}

fn plainRounding(a: Allocator, value: Decimal, approximate: bool, cents: bool, shown: *Decimal, lost: *bool) !void {
    // Exact integers keep every digit up to `max_integer_digits`.
    const r: Decimal.Rounded = if (value.isInteger() and !approximate)
        .{ .value = (try value.roundDecimals(a, 0)).value, .lost = false }
    else
        try value.roundSignificant(a, significant_digits);
    shown.* = if (cents and !r.lost and !approximate and r.value.decimals() <= 2) try r.value.padded(a, 2) else r.value;
    lost.* = r.lost;
}

fn withLabel(a: Allocator, number: []const u8, lab: Label) ![]const u8 {
    return switch (lab) {
        .none => number,
        .percent => a.print("{s} %", .{number}),
        .currency => |c| a.print("{s} {s}", .{ number, c }),
        .unit => |u| if (std.mem.eql(u8, u, "°")) a.print("{s}°", .{number}) else a.print("{s} {s}", .{ number, u }),
    };
}

/// Collects the other readings that answer something else than the main one.
const Pusher = struct {
    a: Allocator,
    found: *std.ArrayList(Alternative),
    main: Answer,
    deadline: Deadline,

    fn push(p: Pusher, t: Task, kind: AlternativeKind, r: Reading) !void {
        if (p.deadline.passed()) return;
        switch (try evaluate(p.a, t, r, p.deadline)) {
            .answer => |other| if (!std.mem.eql(u8, other.text, p.main.text)) {
                try p.found.append(p.a, .{ .task = try t.show(p.a, r), .answer = other, .kind = kind });
            },
            .problem => {},
        }
    }
};

fn alternatives(
    a: Allocator,
    task: Task,
    ans: Answer,
    reading: Reading,
    ambiguous: bool,
    deadline: Deadline,
) ![]const Alternative {
    var found: std.ArrayList(Alternative) = .empty;
    const pusher: Pusher = .{ .a = a, .found = &found, .main = ans, .deadline = deadline };

    if (task.target == null) switch (task.expr.*) {
        .adjust => |adj| {
            const surcharge = adj.op == .add;
            const share_percent = try a.create(Expr);
            share_percent.* = .{ .percent = adj.percent };
            const share = try a.create(Expr);
            share.* = .{ .of = .{ .left = share_percent, .right = adj.base } };
            try pusher.push(.{ .expr = share }, .{ .share = surcharge }, reading);

            if (adj.percent.* == .number) {
                const part_raw = try adj.percent.number.value.scaledDown(a, 2);
                const part = if (surcharge) part_raw else part_raw.negated();
                const factor = try Decimal.one.add(a, part);
                const factor_expr = try a.create(Expr);
                factor_expr.* = .{ .number = .{ .value = factor, .notation = .either } };
                const before = try a.create(Expr);
                before.* = .{ .binary = .{ .op = .div, .left = adj.base, .right = factor_expr } };
                try pusher.push(.{ .expr = before }, .{ .before = surcharge }, reading);
            }
        },
        else => {},
    };

    if (ambiguous) try pusher.push(task, .decimal_point, .english);

    if (task.target) |t| if (t == .unit) switch (units.get(t.unit).kind) {
        .decimal_data => |binary| {
            var names: [2][]const u8 = .{ binary, "" };
            var n: usize = 1;
            if (syntax.quantityUnit(task.expr)) |source| switch (units.get(source).kind) {
                .decimal_data => |source_binary| if (!std.mem.eql(u8, source_binary, binary)) {
                    names[1] = source_binary;
                    n = 2;
                },
                else => {},
            };
            for (names[0..n]) |name| {
                const converted: Task = .{ .expr = task.expr, .target = .{ .unit = units.byDisplay(name) } };
                try pusher.push(converted, .{ .binary = name }, reading);
            }
        },
        else => {},
    };
    return found.toOwnedSlice(a);
}

const testing = std.testing;
const budget: u64 = 5 * std.time.ns_per_s;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    fn init() Fixture {
        return .{ .arena = .init(testing.allocator) };
    }
    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.* = undefined;
    }
    fn calc(f: *Fixture, raw: []const u8) !?Calculation {
        return calculate(f.arena.allocator(), raw, budget);
    }
    fn answer(f: *Fixture, raw: []const u8) ![]const u8 {
        const c = (try f.calc(raw)) orelse return error.NotATask;
        const ans = c.answer() orelse {
            std.debug.print("{s}: {any}\n", .{ raw, c.outcome.problem });
            return error.NoAnswer;
        };
        return ans.shown(f.arena.allocator());
    }
    fn problem(f: *Fixture, raw: []const u8) !Problem {
        const c = (try f.calc(raw)) orelse return error.NotATask;
        return switch (c.outcome) {
            .problem => |p| p,
            .answer => error.UnexpectedAnswer,
        };
    }
};

test "calculates typed tasks" {
    var f: Fixture = .init();
    defer f.deinit();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "(1.299 + 89,90) × 3", "4.166,70" },
        .{ "12 * 3", "36" },
        .{ "3x2", "6" },
        .{ "2^64", "18.446.744.073.709.551.616" },
        .{ "0,1 + 0,2", "0,3" },
        .{ "1/3 * 3", "1" },
        .{ "wurzel 2 × 10", "≈ 14,1421356237" },
        .{ "=pi", "≈ 3,14159265359" },
        .{ "=2048", "2.048" },
        .{ "12 : 4", "3" },
        .{ "sin 30", "0,5" },
        .{ "2^100", "≈ 1,26765060023 × 10³⁰" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try f.answer(c[0]));
}

test "calculates like a pocket calculator" {
    var f: Fixture = .init();
    defer f.deinit();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "80 + 19 %", "95,2" },
        .{ "80 − 25 %", "60" },
        .{ "19 % von 80", "15,2" },
        .{ "80 × 19 %", "15,2" },
        .{ "15 von 60 in %", "25 %" },
        .{ "Taxi 38,50 − 10 %", "34,65" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try f.answer(c[0]));
}

test "reads pasted text and keeps the currency" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    const c = (try f.calc("Netto 1.299,00 € zzgl. 19 % MwSt.")).?;
    try testing.expectEqualStrings("1.299,00 € + 19 %", c.task);
    try testing.expectEqual(@as(usize, 2), c.skipped.len);
    try testing.expectEqualStrings("Netto", c.skipped[0]);
    try testing.expectEqualStrings("MwSt.", c.skipped[1]);
    try testing.expectEqualStrings("1.545,81 €", try c.answer().?.shown(a));
    try testing.expectEqual(@as(usize, 2), c.alternatives.len);
    try testing.expectEqualStrings("19 % von 1.299,00 €", c.alternatives[0].task);
    try testing.expectEqualStrings("246,81 €", try c.alternatives[0].answer.shown(a));
    try testing.expectEqualStrings("1.299,00 € / 1,19", c.alternatives[1].task);
    try testing.expectEqualStrings("≈ 1.091,60 €", try c.alternatives[1].answer.shown(a));
}

test "offers the English reading of a dot" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    const c = (try f.calc("1.250 × 4")).?;
    try testing.expect(c.thousands_dot);
    try testing.expectEqualStrings("5.000", try c.answer().?.shown(a));
    try testing.expectEqual(@as(usize, 1), c.alternatives.len);
    try testing.expectEqualStrings("1,250 × 4", c.alternatives[0].task);
    try testing.expectEqualStrings("5", try c.alternatives[0].answer.shown(a));
    try testing.expectEqual(@as(usize, 0), (try f.calc("3.14 × 2")).?.alternatives.len);
    const german = (try f.calc("(1.299 + 89,90) × 3")).?;
    try testing.expect(!german.thousands_dot);
    try testing.expectEqual(@as(usize, 0), german.alternatives.len);
    const english = (try f.calc("3.5 × 1.250")).?;
    try testing.expectEqualStrings("4,375", try english.answer().?.shown(a));
    try testing.expectEqual(@as(usize, 0), english.alternatives.len);
}

test "converts units and names binary sizes" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    const c = (try f.calc("2,4 GB in MB")).?;
    try testing.expectEqual(Conversion.decimal_data, c.conversion.?);
    try testing.expectEqualStrings("2.400 MB", try c.answer().?.shown(a));
    try testing.expectEqual(@as(usize, 2), c.alternatives.len);
    try testing.expectEqualStrings("≈ 2.288,82 MiB", try c.alternatives[0].answer.shown(a));
    try testing.expectEqualStrings("≈ 2,24 GiB", try c.alternatives[1].answer.shown(a));
    try testing.expectEqualStrings("50 m/s", try f.answer("180 km/h in m/s"));
    try testing.expectEqualStrings("≈ 22,22 °C", try f.answer("72 °F in °C"));
    try testing.expectEqualStrings("200 min", try f.answer("3 h 20 min in min"));
    try testing.expectEqualStrings("14 Tage", try f.answer("2 Wochen in Tage"));
    try testing.expectEqualStrings("1 Tag", try f.answer("24 h in Tage"));
    try testing.expectEqualStrings("6 km", try f.answer("3 km × 2"));
    try testing.expectEqualStrings("5 km/h", try f.answer("10 km / 2 h"));
    try testing.expectEqualStrings("23 °F", try f.answer("-5 °C in °F"));
    try testing.expectEqualStrings("≈ 365,24 Tage", try f.answer("1 Jahr in Tage"));
}

test "copies the number for programs" {
    var f: Fixture = .init();
    defer f.deinit();
    const ans = (try f.calc("(1.299 + 89,90) × 3")).?.answer().?;
    try testing.expectEqualStrings("4.166,70", ans.text);
    try testing.expectEqualStrings("4166.70", ans.number);
    try testing.expectEqualStrings("=", ans.relation());
}

test "names the problem" {
    var f: Fixture = .init();
    defer f.deinit();
    try testing.expect((try f.problem("1.299 / 0")).eql(.division_by_zero));
    try testing.expect((try f.problem("wurzel(-4)")).eql(.not_real));
    try testing.expect((try f.problem("100 € in $")).eql(.no_rates));
    try testing.expect((try f.problem("12 km + 3 kg")).eql(.incompatible));
    try testing.expect((try f.problem("(1.299 + 89,90) ×")).eql(.{ .incomplete = .{ .number = "×" } }));
    try testing.expect((try f.problem("(12 + 3")).eql(.{ .incomplete = .closing_parenthesis }));
}

test "leaves searches alone" {
    var f: Fixture = .init();
    defer f.deinit();
    for ([_][]const u8{
        "",                    "42",        "pi",           "2048",                  "3 m",             "Safari",
        "Microsoft Excel",     "1password", "Logic Pro 11", "log",                   "e-mail",          "10:42",
        "28.10.2026",          "0.6.1",     "12 Monkeys",   "Microsoft 365 + Teams", "+49 170 1234567", "/Users/nobody",
        "https://example.com",
    }) |raw| {
        if (try f.calc(raw)) |c| {
            std.debug.print("{s} became a task: {s}\n", .{ raw, c.task });
            return error.UnexpectedTask;
        }
    }
}

test "stops when the result is too large" {
    var f: Fixture = .init();
    defer f.deinit();
    const c = (try calculate(f.arena.allocator(), "2^(2^(2^20))", 5 * std.time.ns_per_ms)).?;
    try testing.expect(c.outcome.problem.eql(.too_slow));
}
