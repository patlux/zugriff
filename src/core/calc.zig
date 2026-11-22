//! The calculator: tasks typed or pasted into the palette.
//!
//! A query becomes a task only when all of it is one: numbers with
//! operators, functions or a unit conversion, in German or English
//! notation, with words like `mal`, `zzgl.` or `von`. Everything else stays
//! a search. The evaluator works with exact fractions and never touches the
//! network, so currency conversions have no result.
const calculation = @import("calc/calculation.zig");
const sheet_mod = @import("calc/sheet.zig");

pub const Calculation = calculation.Calculation;
pub const Outcome = calculation.Outcome;
pub const Answer = calculation.Answer;
pub const Problem = calculation.Problem;
pub const Gap = calculation.Gap;
pub const Reading = calculation.Reading;
pub const Separator = calculation.Separator;
pub const Rounding = calculation.Rounding;
pub const Conversion = calculation.Conversion;
pub const Alternative = calculation.Alternative;
pub const AlternativeKind = calculation.AlternativeKind;
pub const significant_digits = calculation.significant_digits;
pub const calculate = calculation.calculate;
pub const Sheet = sheet_mod.Sheet;
pub const SheetLine = sheet_mod.Line;
pub const sheet = sheet_mod.sheet;

test {
    _ = @import("calc/decimal.zig");
    _ = @import("calc/units.zig");
    _ = @import("calc/lexer.zig");
    _ = @import("calc/syntax.zig");
    _ = @import("calc/eval.zig");
    _ = calculation;
    _ = sheet_mod;
}
