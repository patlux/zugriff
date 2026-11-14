//! Reads a typed or pasted task into tokens.
//!
//! The lexer knows German number notation, the operator signs that come out
//! of Word, PDFs and web pages, and a small set of words (`mal`, `zzgl.`,
//! `von`, unit names). Everything else is an unknown word: the caller may
//! drop it at the edges of the task, but never between two numbers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("../text.zig");
const Decimal = @import("decimal.zig").Decimal;
const units = @import("units.zig");

pub const Op = enum {
    add,
    sub,
    mul,
    div,
    pow,

    /// The sign the task shows for this operator.
    pub fn sign(op: Op) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "−",
            .mul => "×",
            .div => "/",
            .pow => "^",
        };
    }
};

pub const Func = enum { sqrt, sin, cos, tan, ln, log, abs, round };

pub const Constant = enum { pi, e };

/// A currency sign or code. Zugriff carries it as a label; it never converts
/// between currencies, because that needs exchange rates from the network.
pub const Currency = []const u8;

/// The notation a number gives away: `3,5` is German, `3.14` English, `42`
/// and `1.250` could be either.
pub const Notation = enum { german, english, either };

/// A number as typed, read the German way.
pub const Literal = struct {
    value: Decimal,
    /// The English reading of a dot before exactly three digits (`1.250` is
    /// 1.25), which German reads as a thousands separator (1250).
    alternative: ?Decimal = null,
    notation: Notation,
};

pub const Token = union(enum) {
    number: Literal,
    op: Op,
    percent,
    /// `von`: `19 % von 80`, `15 von 60`.
    of,
    open,
    close,
    func: Func,
    constant: Constant,
    unit: units.Id,
    currency: Currency,
    /// `in`, `zu`, `→`: converts to the unit that follows.
    convert,
    /// A word Zugriff does not know.
    word: []const u8,
    /// Punctuation that may end a pasted sentence or quote a task.
    mark,

    /// Whether this token can end a value, so that `x` after it means "times".
    fn endsValue(t: Token) bool {
        return switch (t) {
            .number, .close, .constant, .unit, .currency, .percent => true,
            else => false,
        };
    }

    pub fn eql(a: Token, b: Token) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .op => |op| op == b.op,
            .func => |f| f == b.func,
            .constant => |k| k == b.constant,
            .unit => |u| u == b.unit,
            .currency => |c| std.mem.eql(u8, c, b.currency),
            .word => |w| std.mem.eql(u8, w, b.word),
            .number => false,
            .percent, .of, .open, .close, .convert, .mark => true,
        };
    }
};

/// Splits `s` into tokens, in `a`; null when it holds a character or a
/// number that no task contains, such as `10:42`, `1.2.3` or `#`.
pub fn tokenize(a: Allocator, s: []const u8) !?[]Token {
    var chars: std.ArrayList(u21) = .empty;
    try text.decodeInto(a, s, &chars);
    const cs = chars.items;
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;

    while (i < cs.len) {
        const current = cs[i];
        const next: ?u21 = if (i + 1 < cs.len) cs[i + 1] else null;

        if (text.isWhitespace(current)) {
            i += 1;
            continue;
        }

        if (text.isDigit(current)) {
            const start = i;
            i = scanNumber(cs, i);
            const raw = try encode(a, cs[start..i]);
            const literal = try readNumber(a, raw) orelse return null;
            try tokens.append(a, .{ .number = literal });
            continue;
        }

        // `3x2` and `3 x 2`: an x right after a value multiplies.
        if ((current == 'x' or current == 'X') and lastEndsValue(tokens.items) and next != null and
            (text.isDigit(next.?) or text.isWhitespace(next.?) or next.? == '('))
        {
            try tokens.append(a, .{ .op = .mul });
            i += 1;
            continue;
        }

        if (isWordStart(current)) {
            const start = i;
            i = scanWord(cs, i);
            const word = try encode(a, cs[start..i]);
            if (std.ascii.eqlIgnoreCase(word, "geteilt")) {
                // `geteilt durch` is one operator.
                const after = skipSpaces(cs, i);
                if (after + 5 <= cs.len) {
                    const durch = try encode(a, cs[after .. after + 5]);
                    const ends = after + 5 >= cs.len or !text.isAlphanumeric(cs[after + 5]);
                    if (std.ascii.eqlIgnoreCase(durch, "durch") and ends) i = after + 5;
                }
            }
            const previous: ?Token = if (tokens.items.len > 0) tokens.items[tokens.items.len - 1] else null;
            try tokens.append(a, try classifyWord(a, word, previous));
            continue;
        }

        const token: Token = switch (current) {
            '+' => .{ .op = .add },
            '-' => if (next == '>') blk: {
                i += 1;
                break :blk .convert;
            } else .{ .op = .sub },
            '−', '–', '—' => .{ .op = .sub },
            '*' => if (next == '*') blk: {
                i += 1;
                break :blk .{ .op = .pow };
            } else .{ .op = .mul },
            '×', '·', '⋅', '✕' => .{ .op = .mul },
            '/', '÷', '∕' => .{ .op = .div },
            // `12 : 4` divides; `10:42` is a time and not a task.
            ':' => blk: {
                const spaced = i > 0 and text.isWhitespace(cs[i - 1]) and next != null and text.isWhitespace(next.?);
                if (!spaced) return null;
                break :blk .{ .op = .div };
            },
            '^' => .{ .op = .pow },
            '%' => .percent,
            '(' => .open,
            ')' => .close,
            '√' => .{ .func = .sqrt },
            'π' => .{ .constant = .pi },
            '€' => .{ .currency = "€" },
            '$' => .{ .currency = "$" },
            '£' => .{ .currency = "£" },
            '¥' => .{ .currency = "¥" },
            '→', '⇒' => .convert,
            '=' => if (next == '>') blk: {
                i += 1;
                break :blk .convert;
            } else .mark,
            '?', '!', '.', ',', ';', '"', '„', '“', '”', '\'', '‚', '‘', '’', '«', '»' => .mark,
            else => return null,
        };
        try tokens.append(a, token);
        i += 1;
    }
    const out = try tokens.toOwnedSlice(a);
    return out;
}

fn lastEndsValue(tokens: []const Token) bool {
    return tokens.len > 0 and tokens[tokens.len - 1].endsValue();
}

fn encode(a: Allocator, cps: []const u21) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cps) |cp| {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

fn skipSpaces(cs: []const u21, start: usize) usize {
    var i = start;
    while (i < cs.len and text.isWhitespace(cs[i])) i += 1;
    return i;
}

/// Digits with `.` or `,` between them. A separator is part of the number
/// only when a digit follows, so `3.` at the end of a sentence stays `3`.
fn scanNumber(cs: []const u21, start: usize) usize {
    var i = start;
    while (i < cs.len) : (i += 1) {
        const c = cs[i];
        const separator = (c == '.' or c == ',') and i + 1 < cs.len and text.isDigit(cs[i + 1]);
        if (!text.isDigit(c) and !separator) break;
    }
    return i;
}

fn isWordStart(c: u21) bool {
    return text.isAlphabetic(c) or c == '°' or c == 'µ';
}

/// Letters, digits after the first letter, `°²³`, a `/` between letters
/// (`km/h`) and a final abbreviation dot (`zzgl.`).
fn scanWord(cs: []const u21, start: usize) usize {
    var i = start;
    while (i < cs.len) {
        const c = cs[i];
        const next: ?u21 = if (i + 1 < cs.len) cs[i + 1] else null;
        const part = text.isAlphanumeric(c) or c == '°' or c == '²' or c == '³' or c == 'µ' or
            (c == '/' and next != null and text.isAlphabetic(next.?));
        if (part) {
            i += 1;
        } else if (c == '.' and (next == null or !text.isAlphanumeric(next.?))) {
            return i + 1;
        } else break;
    }
    return i;
}

/// Reads `1.234,56`, `1,234.56`, `3,5`, `3.14` and `1.250` (both readings).
fn readNumber(a: Allocator, raw: []const u8) !?Literal {
    const dots = std.mem.count(u8, raw, ".");
    const commas = std.mem.count(u8, raw, ",");

    if (dots == 0 and commas == 0) return .{ .value = (try plain(a, raw, "")) orelse return null, .notation = .either };
    if (dots == 0 and commas == 1) {
        const at = std.mem.findScalar(u8, raw, ',').?;
        return .{ .value = (try plain(a, raw[0..at], raw[at + 1 ..])) orelse return null, .notation = .german };
    }
    if (dots == 1 and commas == 0) {
        const at = std.mem.findScalar(u8, raw, '.').?;
        const int = raw[0..at];
        const frac = raw[at + 1 ..];
        // `1.250` is 1250 in German and 1.25 in English. A leading `0.` or
        // another number of digits is a decimal point either way.
        if (frac.len == 3 and int.len >= 1 and int.len <= 3 and !std.mem.eql(u8, int, "0")) {
            return .{
                .value = (try plain(a, try std.mem.concat(a, u8, &.{ int, frac }), "")) orelse return null,
                .alternative = (try plain(a, int, frac)) orelse return null,
                .notation = .either,
            };
        }
        return .{ .value = (try plain(a, int, frac)) orelse return null, .notation = .english };
    }
    if (commas == 0) {
        const int = try grouped(a, raw, '.') orelse return null;
        return .{ .value = (try plain(a, int, "")) orelse return null, .notation = .german };
    }
    if (dots == 0) {
        const int = try grouped(a, raw, ',') orelse return null;
        return .{ .value = (try plain(a, int, "")) orelse return null, .notation = .english };
    }
    const split = std.mem.findLastAny(u8, raw, ".,").?;
    const decimal_sep = raw[split];
    const group_sep: u8 = if (decimal_sep == '.') ',' else '.';
    const notation: Notation = if (decimal_sep == '.') .english else .german;
    const int_part = raw[0..split];
    if (std.mem.findScalar(u8, int_part, decimal_sep) != null) return null;
    const int = try grouped(a, int_part, group_sep) orelse return null;
    return .{ .value = (try plain(a, int, raw[split + 1 ..])) orelse return null, .notation = notation };
}

fn plain(a: Allocator, int: []const u8, frac: []const u8) !?Decimal {
    const s = if (frac.len == 0) int else try a.print("{s}.{s}", .{ int, frac });
    return Decimal.parse(a, s);
}

/// Removes thousands separators if every group after the first has exactly
/// three digits; `28.10.2026` and `1.2.3` are no numbers.
fn grouped(a: Allocator, raw: []const u8, sep: u8) !?[]const u8 {
    var groups = std.mem.splitScalar(u8, raw, sep);
    const first = groups.first();
    if (first.len == 0 or first.len > 3) return null;
    var digits: std.ArrayList(u8) = .empty;
    try digits.appendSlice(a, first);
    while (groups.next()) |g| {
        if (g.len != 3) return null;
        try digits.appendSlice(a, g);
    }
    const out = try digits.toOwnedSlice(a);
    return out;
}

fn classifyWord(a: Allocator, word: []const u8, previous: ?Token) !Token {
    const lower = try text.lowerAlloc(a, word);
    const bare = if (std.mem.endsWith(u8, lower, ".")) lower[0 .. lower.len - 1] else lower;

    if (std.mem.eql(u8, bare, "x")) {
        if (previous != null and previous.?.endsValue()) return .{ .op = .mul };
        return .{ .word = word };
    }

    const Keyword = struct { []const []const u8, Token };
    const keywords = [_]Keyword{
        .{ &.{ "plus", "zzgl", "zuzüglich" }, .{ .op = .add } },
        .{ &.{ "minus", "abzgl", "abzüglich" }, .{ .op = .sub } },
        .{ &.{"mal"}, .{ .op = .mul } },
        .{ &.{ "durch", "geteilt" }, .{ .op = .div } },
        .{ &.{"hoch"}, .{ .op = .pow } },
        .{ &.{ "von", "of" }, .of },
        .{ &.{ "in", "zu", "to", "as", "nach", "als" }, .convert },
        .{ &.{ "wurzel", "sqrt" }, .{ .func = .sqrt } },
        .{ &.{"sin"}, .{ .func = .sin } },
        .{ &.{"cos"}, .{ .func = .cos } },
        .{ &.{"tan"}, .{ .func = .tan } },
        .{ &.{"ln"}, .{ .func = .ln } },
        .{ &.{ "log", "lg", "log10" }, .{ .func = .log } },
        .{ &.{ "abs", "betrag" }, .{ .func = .abs } },
        .{ &.{ "runden", "round" }, .{ .func = .round } },
        .{ &.{"pi"}, .{ .constant = .pi } },
        .{ &.{"e"}, .{ .constant = .e } },
        .{ &.{ "eur", "euro" }, .{ .currency = "€" } },
        .{ &.{ "usd", "dollar" }, .{ .currency = "$" } },
        .{ &.{ "chf", "franken" }, .{ .currency = "CHF" } },
        .{ &.{"gbp"}, .{ .currency = "£" } },
    };
    for (keywords) |k| for (k[0]) |spelling| if (std.mem.eql(u8, bare, spelling)) return k[1];

    // The case of these two decides: `K` is kelvin, `t` is tonne.
    if (std.mem.eql(u8, word, "K")) return .{ .unit = units.byDisplay("K") };
    if (std.mem.eql(u8, word, "t")) return .{ .unit = units.byDisplay("t") };

    if (units.bySpelling(lower) orelse units.bySpelling(bare)) |id| return .{ .unit = id };
    return .{ .word = word };
}

const testing = std.testing;

fn number(a: Allocator, s: []const u8) !struct { []const u8, ?[]const u8 } {
    const tokens = (try tokenize(a, s)).?;
    try testing.expectEqual(@as(usize, 1), tokens.len);
    const lit = tokens[0].number;
    return .{ try lit.value.plain(a), if (lit.alternative) |alt| try alt.plain(a) else null };
}

test "reads German and English numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "3,5", "3.5" },     .{ "1.234,56", "1234.56" },  .{ "1,234.56", "1234.56" },
        .{ "3.14", "3.14" },   .{ "1.234.567", "1234567" }, .{ "1,234,567", "1234567" },
        .{ "0.500", "0.500" }, .{ "1.299,00", "1299.00" },
    };
    for (cases) |c| {
        const n = try number(a, c[0]);
        try testing.expectEqualStrings(c[1], n[0]);
        try testing.expect(n[1] == null);
    }
    const both = try number(a, "1.250");
    try testing.expectEqualStrings("1250", both[0]);
    try testing.expectEqualStrings("1.250", both[1].?);
}

test "refuses dates, versions and times" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "28.10.2026", "0.6.1", "1.2.3", "10:42", "1.23,4.5", "#3" }) |s| {
        try testing.expect(try tokenize(arena.allocator(), s) == null);
    }
}

test "reads signs from Word and PDFs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tokens = (try tokenize(arena.allocator(), "12 − 3 – 1 × 2 ÷ 4 · 5 : 6 x 7")).?;
    var ops: std.ArrayList(Op) = .empty;
    for (tokens) |t| if (t == .op) try ops.append(arena.allocator(), t.op);
    try testing.expectEqualSlices(Op, &.{ .sub, .sub, .mul, .div, .mul, .div, .mul }, ops.items);
}

test "knows German words and units" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tokens = (try tokenize(arena.allocator(), "3 mal 4 geteilt durch 2 zzgl. 19 % von 80 in km/h")).?;
    var seen: struct {
        mul: bool = false,
        div: bool = false,
        add: bool = false,
        of: bool = false,
        convert: bool = false,
    } = .{};
    for (tokens) |t| switch (t) {
        .op => |op| switch (op) {
            .mul => seen.mul = true,
            .div => seen.div = true,
            .add => seen.add = true,
            else => {},
        },
        .of => seen.of = true,
        .convert => seen.convert = true,
        .word => return error.UnexpectedWord,
        else => {},
    };
    try testing.expect(seen.mul and seen.div and seen.add and seen.of and seen.convert);
    try testing.expectEqualStrings("km/h", units.get(tokens[tokens.len - 1].unit).display);
}

test "keeps unknown words and end marks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tokens = (try tokenize(arena.allocator(), "Netto 1.299,00 € zzgl. 19 % MwSt.")).?;
    try testing.expectEqualStrings("Netto", tokens[0].word);
    try testing.expectEqualStrings("MwSt.", tokens[tokens.len - 1].word);
    var currency = false;
    for (tokens) |t| if (t == .currency and std.mem.eql(u8, t.currency, "€")) {
        currency = true;
    };
    try testing.expect(currency);
}
