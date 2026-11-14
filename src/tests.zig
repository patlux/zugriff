//! Every test of the project, in one binary: `zig build test`.
test {
    _ = @import("core/text.zig");
    _ = @import("core/item.zig");
    _ = @import("core/query.zig");
    _ = @import("core/matcher.zig");
    _ = @import("core/catalog.zig");
    _ = @import("core/direct.zig");
    _ = @import("core/emoji.zig");
    _ = @import("core/calc.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/glyphs.zig");
    _ = @import("ui/tests_palette.zig");
}
