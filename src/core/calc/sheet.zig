//! Several pasted lines at once: each line on its own, then the sum.
const std = @import("std");
const Allocator = std.mem.Allocator;
const calculation = @import("calculation.zig");
const eval = @import("eval.zig");
const text = @import("../text.zig");
const Locale = @import("../language.zig").Locale;
const Answer = calculation.Answer;
const Label = calculation.Label;
const Deadline = calculation.Deadline;

/// The lines of a pasted block and what they add up to.
pub const Sheet = struct {
    lines: []const Line,
    /// The sum of every line whose result is a plain number or an amount in
    /// one currency.
    total: ?Answer = null,
    mean: ?Answer = null,
    largest: ?Answer = null,
    smallest: ?Answer = null,
    /// Lines that went into the sum.
    counted: usize = 0,
};

pub const Line = struct {
    /// The line as pasted, trimmed.
    text: []const u8,
    /// Null for a line without a number or one Zugriff cannot read.
    answer: ?Answer,
};

/// Calculates every non-empty line for `locale`; words before the first
/// number are its label (`Hotel 3 × 129,00`).
pub fn sheet(a: Allocator, lines_in: []const []const u8, budget_ns: u64, locale: Locale) !Sheet {
    const deadline = Deadline.after(budget_ns);
    var lines: std.ArrayList(Line) = .empty;
    for (lines_in) |raw| {
        const line = text.trim(raw);
        if (line.len == 0) continue;
        const c = try calculation.calculateIn(a, line, .line, deadline, locale);
        try lines.append(a, .{ .text = line, .answer = if (c) |calc| calc.answer() else null });
    }

    // Amounts add up when they share their currency; a line with another
    // unit stays out of the sum.
    var label: Label = .none;
    for (lines.items) |l| if (l.answer) |ans| if (ans.label == .currency) {
        label = ans.label;
        break;
    };
    var summable: std.ArrayList(Answer) = .empty;
    for (lines.items) |l| if (l.answer) |ans| {
        if (ans.label == .none or ans.label.eql(label)) try summable.append(a, ans);
    };

    var out: Sheet = .{ .lines = try lines.toOwnedSlice(a), .counted = summable.items.len };
    if (summable.items.len == 0) return out;

    var cents = false;
    var approximate = false;
    var total = summable.items[0].value;
    for (summable.items, 0..) |ans, i| {
        if (std.mem.findScalar(u8, ans.number, '.')) |dot| cents = cents or ans.number.len - dot - 1 == 2;
        approximate = approximate or ans.isApproximate();
        if (i > 0) total = try total.add(a, ans.value);
    }
    out.total = try calculation.formatValue(a, total, approximate, label, cents, locale.numbers);

    const rat = try eval.Rat.fromDecimal(a, total);
    const mean = try rat.div(a, try eval.Rat.fromInt(a, summable.items.len));
    const digits = try mean.toDecimal(a, 15);
    out.mean = try calculation.formatValue(a, digits.value, approximate or !digits.exact, label, cents, locale.numbers);

    var largest = summable.items[0];
    var smallest = summable.items[0];
    for (summable.items[1..]) |ans| {
        if (ans.value.compare(largest.value) == .gt) largest = ans;
        if (ans.value.compare(smallest.value) == .lt) smallest = ans;
    }
    out.largest = largest;
    out.smallest = smallest;
    return out;
}

const testing = std.testing;

test "adds up pasted lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sheet(a, &.{
        "Hotel 3 × 129,00",
        "Bahn 2 × 89,90",
        "",
        "Essen 146,35",
        "Taxi 38,50 − 10 %",
        "Trinkgeld",
    }, 5 * std.time.ns_per_s, .both(.de));
    const want = [_]?[]const u8{ "387,00", "179,80", "146,35", "34,65", null };
    try testing.expectEqual(want.len, s.lines.len);
    for (want, s.lines) |w, l| {
        if (w) |text_| {
            try testing.expectEqualStrings(text_, try l.answer.?.shown(a));
        } else try testing.expect(l.answer == null);
    }
    try testing.expectEqual(@as(usize, 4), s.counted);
    try testing.expectEqualStrings("747,80", try s.total.?.shown(a));
    try testing.expectEqualStrings("186,95", try s.mean.?.shown(a));
    try testing.expectEqualStrings("387,00", try s.largest.?.shown(a));
    try testing.expectEqualStrings("34,65", try s.smallest.?.shown(a));
}

test "keeps the currency of the amounts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sheet(a, &.{ "12,50 €", "7,99 €", "3 km" }, 5 * std.time.ns_per_s, .both(.de));
    try testing.expectEqual(@as(usize, 2), s.counted);
    try testing.expectEqualStrings("20,49 €", try s.total.?.shown(a));
}
