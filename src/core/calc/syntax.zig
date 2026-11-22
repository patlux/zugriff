//! The structure of a task: parsing tokens and showing the task again, its
//! numbers in German or English notation and its words in the palette's
//! language.
//!
//! Percentages follow the pocket calculator: `80 + 19 %` is 95,20 and
//! `80 × 19 %` is 15,20. The tree keeps them as written (`adjust`,
//! `percent`, `of`); the evaluator gives them that meaning.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Decimal = @import("decimal.zig").Decimal;
const lexer = @import("lexer.zig");
const units = @import("units.zig");
const Locale = @import("../language.zig").Locale;
const Token = lexer.Token;
const Literal = lexer.Literal;
const Op = lexer.Op;
const Func = lexer.Func;
const Constant = lexer.Constant;
const Currency = lexer.Currency;

pub const Expr = union(enum) {
    number: Literal,
    constant: Constant,
    /// A unit used as a factor, as in `/ h`.
    unit: units.Id,
    quantity: struct { value: *const Expr, unit: units.Id },
    /// A currency label; the value is the plain number.
    money: struct { value: *const Expr, currency: Currency },
    group: *const Expr,
    neg: *const Expr,
    binary: struct { op: Op, left: *const Expr, right: *const Expr },
    /// `3 h 20 min`.
    joined: struct { left: *const Expr, right: *const Expr },
    percent: *const Expr,
    /// `19 % von 80` (a share) or `15 von 60` (a ratio).
    of: struct { left: *const Expr, right: *const Expr },
    /// `base ± percent %` with calculator semantics.
    adjust: struct { base: *const Expr, op: Op, percent: *const Expr },
    func: struct { func: Func, arg: *const Expr },
};

pub const Target = union(enum) {
    unit: units.Id,
    percent,
    currency: Currency,
};

/// A parsed task: an expression and the unit to convert it to.
pub const Task = struct {
    expr: *const Expr,
    target: ?Target = null,

    /// Whether the task does something with its numbers. A lone number, a
    /// lone constant or a single quantity is a search term, not a task.
    pub fn computes(t: Task) bool {
        return t.target != null or computesExpr(t.expr);
    }

    /// The task as Zugriff read it (`reading`), shown for `locale`:
    /// `1.299,00 € + 19 % von 80` or `€1,299.00 + 19% of 80`.
    pub fn show(t: Task, a: Allocator, reading: Reading, locale: Locale) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        const s: Shower = .{ .a = a, .reading = reading, .locale = locale, .out = &out };
        try s.expr(t.expr);
        if (t.target) |target| switch (target) {
            .unit => |u| try out.print(a, " in {s}", .{units.get(u).name(locale.language, false)}),
            .percent => try out.appendSlice(a, " in %"),
            .currency => |c| try out.print(a, " in {s}", .{c}),
        };
        return out.toOwnedSlice(a);
    }
};

/// Which way to read a number such as `1.250`.
pub const Reading = enum {
    german,
    /// The dot before three digits is a decimal point.
    english,
};

/// What an unfinished task still needs.
pub const Gap = union(enum) {
    /// A number after this sign or word, for example `×` or `von`.
    number: []const u8,
    closing_parenthesis,
    /// The unit after `in`.
    unit,

    pub fn eql(a: Gap, b: Gap) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .number => |after| std.mem.eql(u8, after, b.number),
            else => true,
        };
    }
};

pub const ParseResult = union(enum) {
    task: Task,
    incomplete: Gap,
    invalid,
};

pub fn parse(a: Allocator, tokens: []const Token) !ParseResult {
    var p: Parser = .{ .a = a, .tokens = tokens };
    const expr = p.sum() catch |e| return p.failure(e);
    var target: ?Target = null;
    if (p.eat(.convert)) target = p.target() catch |e| return p.failure(e);
    if (p.position < tokens.len) return .invalid;
    return .{ .task = .{ .expr = expr, .target = target } };
}

const Error = error{ Incomplete, Invalid, OutOfMemory };

const Parser = struct {
    a: Allocator,
    tokens: []const Token,
    position: usize = 0,
    /// The sign or word just read, for "es fehlt eine Zahl nach …".
    last: []const u8 = "",
    gap: Gap = .unit,

    fn failure(p: *Parser, e: Error) !ParseResult {
        return switch (e) {
            error.Incomplete => .{ .incomplete = p.gap },
            error.Invalid => .invalid,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn peek(p: *Parser) ?Token {
        return if (p.position < p.tokens.len) p.tokens[p.position] else null;
    }

    fn peekAt(p: *Parser, offset: usize) ?Token {
        const i = p.position + offset;
        return if (i < p.tokens.len) p.tokens[i] else null;
    }

    fn advance(p: *Parser) ?Token {
        const t = p.peek();
        p.position += 1;
        return t;
    }

    fn eat(p: *Parser, want: std.meta.Tag(Token)) bool {
        const t = p.peek() orelse return false;
        if (t != want) return false;
        p.position += 1;
        return true;
    }

    fn eatOp(p: *Parser, op: Op) bool {
        const t = p.peek() orelse return false;
        if (t != .op or t.op != op) return false;
        p.position += 1;
        return true;
    }

    fn new(p: *Parser, e: Expr) !*const Expr {
        const node = try p.a.create(Expr);
        node.* = e;
        return node;
    }

    fn missingNumber(p: *Parser) Error {
        p.gap = .{ .number = p.last };
        return error.Incomplete;
    }

    fn sum(p: *Parser) Error!*const Expr {
        var left = try p.term();
        while (true) {
            const t = p.peek() orelse return left;
            if (t == .op and (t.op == .add or t.op == .sub)) {
                const op = t.op;
                _ = p.advance();
                p.last = op.sign();
                const right = try p.term();
                left = switch (right.*) {
                    .percent => |percent| try p.new(.{ .adjust = .{ .base = left, .op = op, .percent = percent } }),
                    else => try p.new(.{ .binary = .{ .op = op, .left = left, .right = right } }),
                };
            } else if (t == .number and endsWithQuantity(left) and (p.peekAt(1) orelse return left) == .unit) {
                const right = try p.term();
                left = try p.new(.{ .joined = .{ .left = left, .right = right } });
            } else return left;
        }
    }

    fn term(p: *Parser) Error!*const Expr {
        var left = try p.of();
        while (p.peek()) |t| {
            if (t != .op or (t.op != .mul and t.op != .div)) break;
            const op = t.op;
            _ = p.advance();
            p.last = op.sign();
            const right = try p.of();
            left = try p.new(.{ .binary = .{ .op = op, .left = left, .right = right } });
        }
        return left;
    }

    fn of(p: *Parser) Error!*const Expr {
        const left = try p.unary();
        if (p.eat(.of)) {
            p.last = "von";
            const right = try p.unary();
            return p.new(.{ .of = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn unary(p: *Parser) Error!*const Expr {
        if (p.eatOp(.sub)) {
            p.last = Op.sub.sign();
            return p.new(.{ .neg = try p.unary() });
        }
        if (p.eatOp(.add)) {
            p.last = Op.add.sign();
            return p.unary();
        }
        return p.power();
    }

    fn power(p: *Parser) Error!*const Expr {
        const base = try p.postfix();
        if (p.eatOp(.pow)) {
            p.last = Op.pow.sign();
            const exponent = try p.unary();
            return p.new(.{ .binary = .{ .op = .pow, .left = base, .right = exponent } });
        }
        return base;
    }

    fn postfix(p: *Parser) Error!*const Expr {
        var e = try p.primary();
        while (p.eat(.percent)) e = try p.new(.{ .percent = e });
        return e;
    }

    fn primary(p: *Parser) Error!*const Expr {
        const t = p.advance() orelse return p.missingNumber();
        return switch (t) {
            .number => |lit| p.labelled(try p.new(.{ .number = lit })),
            .currency => |currency| blk: {
                // `€ 100`, `$5`: the sign before the number.
                const next = p.advance() orelse return p.missingNumber();
                if (next != .number) return error.Invalid;
                const amount = try p.new(.{ .number = next.number });
                break :blk p.new(.{ .money = .{ .value = amount, .currency = currency } });
            },
            .constant => |k| p.new(.{ .constant = k }),
            .open => blk: {
                p.last = "(";
                const inner = try p.sum();
                const close = p.advance() orelse {
                    p.gap = .closing_parenthesis;
                    return error.Incomplete;
                };
                if (close != .close) return error.Invalid;
                break :blk p.labelled(try p.new(.{ .group = inner }));
            },
            .func => |f| blk: {
                p.last = funcName(f);
                const arg = try p.postfix();
                break :blk p.new(.{ .func = .{ .func = f, .arg = arg } });
            },
            .unit => |u| p.new(.{ .unit = u }),
            else => error.Invalid,
        };
    }

    /// A unit or currency right after a value: `2,4 GB`, `1.299 €`.
    fn labelled(p: *Parser, value: *const Expr) Error!*const Expr {
        const t = p.peek() orelse return value;
        switch (t) {
            .unit => |u| {
                _ = p.advance();
                return p.new(.{ .quantity = .{ .value = value, .unit = u } });
            },
            .currency => |c| {
                _ = p.advance();
                return p.new(.{ .money = .{ .value = value, .currency = c } });
            },
            else => return value,
        }
    }

    fn target(p: *Parser) Error!Target {
        const t = p.advance() orelse {
            p.gap = .unit;
            return error.Incomplete;
        };
        return switch (t) {
            .unit => |u| .{ .unit = u },
            .percent => .percent,
            .currency => |c| .{ .currency = c },
            else => error.Invalid,
        };
    }
};

fn endsWithQuantity(e: *const Expr) bool {
    return switch (e.*) {
        .quantity => true,
        .joined => |j| endsWithQuantity(j.right),
        else => false,
    };
}

pub fn funcName(f: Func) []const u8 {
    return switch (f) {
        .sqrt => "√",
        .sin => "sin",
        .cos => "cos",
        .tan => "tan",
        .ln => "ln",
        .log => "log",
        .abs => "abs",
        .round => "runden",
    };
}

pub fn isTrig(f: Func) bool {
    return f == .sin or f == .cos or f == .tan;
}

pub fn literalValue(lit: Literal, reading: Reading) Decimal {
    if (reading == .english) if (lit.alternative) |alt| return alt;
    return lit.value;
}

/// Writes an expression the way `Task.show` shows it.
const Shower = struct {
    a: Allocator,
    reading: Reading,
    locale: Locale,
    out: *std.ArrayList(u8),

    fn put(s: Shower, bytes: []const u8) !void {
        try s.out.appendSlice(s.a, bytes);
    }

    /// `19 %` in German notation, `19%` in English.
    fn percentSign(s: Shower) !void {
        try s.put(if (s.locale.numbers == .de) " %" else "%");
    }

    fn expr(s: Shower, e: *const Expr) Allocator.Error!void {
        const a = s.a;
        switch (e.*) {
            .number => |lit| try s.put(try literalValue(lit, s.reading).format(a, s.locale.numbers)),
            .constant => |k| try s.put(if (k == .pi) "π" else "e"),
            .unit => |u| try s.put(units.get(u).name(s.locale.language, false)),
            .quantity => |q| {
                try s.expr(q.value);
                if (units.get(q.unit).kind != .angle) try s.put(" ");
                try s.put(units.get(q.unit).name(s.locale.language, false));
            },
            .money => |m| if (s.locale.numbers == .de) {
                try s.expr(m.value);
                try s.out.print(a, " {s}", .{m.currency});
            } else {
                // `$1,299.00`, `CHF 1,299.00`.
                try s.put(m.currency);
                if (!isSymbol(m.currency)) try s.put(" ");
                try s.expr(m.value);
            },
            .group => |inner| {
                try s.put("(");
                try s.expr(inner);
                try s.put(")");
            },
            .neg => |inner| {
                try s.put("−");
                try s.expr(inner);
            },
            .binary => |b| {
                try s.expr(b.left);
                if (b.op == .pow) {
                    try s.put("^");
                } else try s.out.print(a, " {s} ", .{b.op.sign()});
                try s.expr(b.right);
            },
            .joined => |j| {
                try s.expr(j.left);
                try s.put(" ");
                try s.expr(j.right);
            },
            .percent => |inner| {
                try s.expr(inner);
                try s.percentSign();
            },
            .of => |o| {
                try s.expr(o.left);
                try s.put(if (s.locale.language == .de) " von " else " of ");
                try s.expr(o.right);
            },
            .adjust => |adj| {
                try s.expr(adj.base);
                try s.out.print(a, " {s} ", .{adj.op.sign()});
                try s.expr(adj.percent);
                try s.percentSign();
            },
            .func => |f| {
                if (f.func == .sqrt) {
                    try s.put("√");
                    try s.expr(f.arg);
                    return;
                }
                try s.out.print(a, "{s}(", .{funcName(f.func)});
                try s.expr(unwrapGroup(f.arg));
                if (isTrig(f.func) and !hasAngle(f.arg)) try s.put("°");
                try s.put(")");
            },
        }
    }
};

/// Whether a currency is written as a sign (`€`, `$`) rather than a code
/// (`CHF`): English puts a sign right before the amount, a code with a space.
pub fn isSymbol(currency: []const u8) bool {
    return currency.len > 0 and !std.ascii.isAlphabetic(currency[0]);
}

fn unwrapGroup(e: *const Expr) *const Expr {
    return switch (e.*) {
        .group => |inner| inner,
        else => e,
    };
}

pub fn hasAngle(e: *const Expr) bool {
    return switch (e.*) {
        .quantity => |q| units.get(q.unit).kind == .angle,
        .group => |inner| hasAngle(inner),
        else => false,
    };
}

fn computesExpr(e: *const Expr) bool {
    return switch (e.*) {
        .number, .constant, .unit => false,
        .quantity => |q| computesExpr(q.value),
        .money => |m| computesExpr(m.value),
        .group, .neg, .percent => |inner| computesExpr(inner),
        .joined => |j| computesExpr(j.left) or computesExpr(j.right),
        .binary, .of, .adjust, .func => true,
    };
}

/// Calls `visit.literal(lit)` for every number literal in `e`.
pub fn literals(e: *const Expr, visit: anytype) void {
    switch (e.*) {
        .number => |lit| visit.literal(lit),
        .constant, .unit => {},
        .quantity => |q| literals(q.value, visit),
        .money => |m| literals(m.value, visit),
        .group, .neg, .percent => |inner| literals(inner, visit),
        .func => |f| literals(f.arg, visit),
        .binary => |b| {
            literals(b.left, visit);
            literals(b.right, visit);
        },
        .joined => |j| {
            literals(j.left, visit);
            literals(j.right, visit);
        },
        .of => |o| {
            literals(o.left, visit);
            literals(o.right, visit);
        },
        .adjust => |adj| {
            literals(adj.base, visit);
            literals(adj.percent, visit);
        },
    }
}

/// Every distinct currency label in `e`, at most `out.len`; returns the count.
pub fn currencies(e: *const Expr, out: []Currency, n: usize) usize {
    var count = n;
    switch (e.*) {
        .money => |m| {
            const known = for (out[0..count]) |c| {
                if (std.mem.eql(u8, c, m.currency)) break true;
            } else false;
            if (!known and count < out.len) {
                out[count] = m.currency;
                count += 1;
            }
            count = currencies(m.value, out, count);
        },
        .number, .constant, .unit => {},
        .quantity => |q| count = currencies(q.value, out, count),
        .group, .neg, .percent => |inner| count = currencies(inner, out, count),
        .func => |f| count = currencies(f.arg, out, count),
        .binary => |b| count = currencies(b.right, out, currencies(b.left, out, count)),
        .joined => |j| count = currencies(j.right, out, currencies(j.left, out, count)),
        .of => |o| count = currencies(o.right, out, currencies(o.left, out, count)),
        .adjust => |adj| count = currencies(adj.percent, out, currencies(adj.base, out, count)),
    }
    return count;
}

/// The unit of a single quantity, as in `2,4 GB` of `2,4 GB in MB`.
pub fn quantityUnit(e: *const Expr) ?units.Id {
    return switch (e.*) {
        .quantity => |q| q.unit,
        .group => |inner| quantityUnit(inner),
        .money => |m| quantityUnit(m.value),
        else => null,
    };
}

const testing = std.testing;

fn parsed(a: Allocator, s: []const u8) !ParseResult {
    const tokens = (try lexer.tokenize(a, s, .de)).?;
    return parse(a, tokens);
}

fn shown(a: Allocator, s: []const u8, reading: Reading) ![]const u8 {
    return (try parsed(a, s)).task.show(a, reading, .both(.de));
}

fn shownIn(a: Allocator, s: []const u8, reading: Reading, locale: Locale) ![]const u8 {
    const tokens = (try lexer.tokenize(a, s, locale.numbers)).?;
    return (try parse(a, tokens)).task.show(a, reading, locale);
}

test "shows the task in German" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("(1.299 + 89,90) × 3", try shown(a, "(1.299 + 89,90) * 3", .german));
    try testing.expectEqualStrings("1.299,00 € + 19 %", try shown(a, "1299,00 € zzgl. 19 %", .german));
    try testing.expectEqualStrings("2,4 GB in MB", try shown(a, "2,4 GB in MB", .german));
    try testing.expectEqualStrings("√2 × 10", try shown(a, "wurzel 2 mal 10", .german));
    try testing.expectEqualStrings("sin(30°)", try shown(a, "sin 30", .german));
    try testing.expectEqualStrings("1,250 × 4", try shown(a, "1.250 x 4", .english));
}

test "shows the task in English" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const en: Locale = .both(.en);
    try testing.expectEqualStrings("(1,299 + 89.90) × 3", try shownIn(a, "(1,299 + 89.90) * 3", .english, en));
    try testing.expectEqualStrings("€1,299.00 + 19%", try shownIn(a, "1,299.00 € plus 19 %", .english, en));
    try testing.expectEqualStrings("CHF 12 × 3", try shownIn(a, "12 CHF times 3", .english, en));
    try testing.expectEqualStrings("19% of 80", try shownIn(a, "19 % of 80", .english, en));
    try testing.expectEqualStrings("2 weeks in days", try shownIn(a, "2 Wochen in Tage", .english, en));
    // English texts with German numbers, as on a Mac in English with a German region.
    const mixed: Locale = .{ .language = .en, .numbers = .de };
    try testing.expectEqualStrings("19 % of 1.299,00 €", try shownIn(a, "19 % von 1.299,00 €", .german, mixed));
}

test "names what an unfinished task needs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try parsed(a, "(1.299 + 89,90) ×")).incomplete.eql(.{ .number = "×" }));
    try testing.expect((try parsed(a, "(12 + 3")).incomplete.eql(.closing_parenthesis));
    try testing.expect((try parsed(a, "2,4 GB in")).incomplete.eql(.unit));
    try testing.expect(try parsed(a, "12 3") == .invalid);
}

test "a lone value does not compute" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "42", "pi", "3 m", "19 %", "-5", "1.299 €" }) |s| {
        try testing.expect(!(try parsed(a, s)).task.computes());
    }
    for ([_][]const u8{ "2 + 2", "wurzel 2", "3 m in cm", "19 % von 80" }) |s| {
        try testing.expect((try parsed(a, s)).task.computes());
    }
}
