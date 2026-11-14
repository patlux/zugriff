//! The platform-independent search model: palette rows, queries, ranking,
//! direct targets, the calculator and the emoji table. Nothing here knows
//! macOS or nanoui.
pub const text = @import("core/text.zig");
const item = @import("core/item.zig");
pub const Item = item.Item;
pub const Action = item.Action;
pub const Icon = item.Icon;
const catalog = @import("core/catalog.zig");
pub const Catalog = catalog.Catalog;
pub const SearchHit = catalog.SearchHit;
pub const Query = @import("core/query.zig").Query;
pub const DirectTarget = @import("core/direct.zig").DirectTarget;
pub const calc = @import("core/calc.zig");
pub const emoji = @import("core/emoji.zig");
