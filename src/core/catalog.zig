//! An ordered collection of palette rows that can be searched.
//!
//! The catalog keeps the order it was created with, so an empty query shows
//! the list as the provider sorted it. It owns its rows: they live in its
//! arena until `deinit`.
const std = @import("std");
const text = @import("text.zig");
const item_mod = @import("item.zig");
const Item = item_mod.Item;
const Icon = item_mod.Icon;
const Query = @import("query.zig").Query;
const Matcher = @import("matcher.zig").Matcher;

/// A matching row and its relevance score.
pub const SearchHit = struct {
    /// Index into `Catalog.items`.
    index: usize,
    score: i32,
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item = &.{},
    folded: []const []const u8 = &.{},

    pub fn empty(gpa: std.mem.Allocator) Catalog {
        return .{ .arena = .init(gpa) };
    }

    /// Copies `items` into a new catalog.
    pub fn init(gpa: std.mem.Allocator, items: []const Item) !Catalog {
        var c: Catalog = .empty(gpa);
        errdefer c.deinit();
        const a = c.arena.allocator();
        const own = try a.alloc(Item, items.len);
        const folded = try a.alloc([]const u8, items.len);
        for (items, own, folded) |src, *dst, *f| {
            dst.* = try src.dupe(a);
            f.* = try text.lowerAlloc(a, src.title);
        }
        c.items = own;
        c.folded = folded;
        return c;
    }

    pub fn deinit(c: *Catalog) void {
        c.arena.deinit();
        c.* = undefined;
    }

    pub fn len(c: Catalog) usize {
        return c.items.len;
    }

    pub fn item(c: Catalog, index: usize) ?Item {
        return if (index < c.items.len) c.items[index] else null;
    }

    /// Attaches an icon to one row; unknown indices are ignored.
    pub fn setIcon(c: *Catalog, index: usize, icon: Icon) !void {
        if (index >= c.items.len) return;
        const a = c.arena.allocator();
        c.items[index].icon = .{ .path = try a.dupe(u8, icon.path), .png = try a.dupe(u8, icon.png) };
    }

    /// Whether both hold the same rows in the same order.
    pub fn sameItems(c: Catalog, other: Catalog) bool {
        if (c.items.len != other.items.len) return false;
        for (c.items, other.items) |a, b| if (!a.eql(b)) return false;
        return true;
    }

    /// The matching rows, best first; the caller frees the slice.
    ///
    /// Ties are broken alphabetically, then by catalog order, so the list
    /// never reorders between identical queries.
    pub fn search(c: Catalog, gpa: std.mem.Allocator, query: Query) ![]SearchHit {
        var hits: std.ArrayList(SearchHit) = .empty;
        errdefer hits.deinit(gpa);
        if (query.isEmpty()) {
            try hits.ensureTotalCapacity(gpa, c.items.len);
            for (0..c.items.len) |i| hits.appendAssumeCapacity(.{ .index = i, .score = 0 });
            return hits.toOwnedSlice(gpa);
        }
        var m: Matcher = .init(gpa);
        defer m.deinit();
        for (c.items, 0..) |it, i| {
            if (try m.score(it, query)) |s| try hits.append(gpa, .{ .index = i, .score = s });
        }
        // The index breaks every tie, so the order is total and the unstable
        // sort gives the same result as a stable one, with less code.
        std.mem.sortUnstable(SearchHit, hits.items, c, lessThan);
        return hits.toOwnedSlice(gpa);
    }

    fn lessThan(c: Catalog, a: SearchHit, b: SearchHit) bool {
        if (a.score != b.score) return a.score > b.score;
        switch (std.mem.order(u8, c.folded[a.index], c.folded[b.index])) {
            .lt => return true,
            .gt => return false,
            .eq => return a.index < b.index,
        }
    }
};

const testing = std.testing;

fn titles(c: Catalog, q: []const u8) ![]const []const u8 {
    const query = try Query.init(testing.allocator, q);
    defer query.deinit(testing.allocator);
    const hits = try c.search(testing.allocator, query);
    defer testing.allocator.free(hits);
    const out = try testing.allocator.alloc([]const u8, hits.len);
    for (hits, out) |h, *o| o.* = c.items[h.index].title;
    return out;
}

fn catalogOf(names: []const []const u8) !Catalog {
    var items: [8]Item = undefined;
    for (names, 0..) |n, i| items[i] = .{ .title = n, .action = .{ .launch_application = "/Applications/Test.app" } };
    return Catalog.init(testing.allocator, items[0..names.len]);
}

fn expectTitles(c: Catalog, q: []const u8, want: []const []const u8) !void {
    const got = try titles(c, q);
    defer testing.allocator.free(got);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "an empty query keeps the catalog order" {
    var c = try catalogOf(&.{ "Terminal", "App Store", "Safari" });
    defer c.deinit();
    try expectTitles(c, "", &.{ "Terminal", "App Store", "Safari" });
}

test "ranks the best application first" {
    var c = try catalogOf(&.{
        "Safari Technology Preview",
        "System Settings",
        "Safari",
        "Xcode",
        "Visual Studio Code",
    });
    defer c.deinit();
    const saf = try titles(c, "saf");
    defer testing.allocator.free(saf);
    try testing.expectEqualStrings("Safari", saf[0]);
    const settings = try titles(c, "settings");
    defer testing.allocator.free(settings);
    try testing.expectEqualStrings("System Settings", settings[0]);
    try expectTitles(c, "code", &.{ "Visual Studio Code", "Xcode" });
}

test "drops rows that do not match; ties are alphabetical" {
    var c = try catalogOf(&.{ "Safari", "Terminal" });
    defer c.deinit();
    try expectTitles(c, "zzz", &.{});
    try expectTitles(c, "term", &.{"Terminal"});
    var ties = try catalogOf(&.{ "Beta App", "Alpha App" });
    defer ties.deinit();
    try expectTitles(ties, "app", &.{ "Alpha App", "Beta App" });
}

test "icons attach to the matching row only" {
    var c = try catalogOf(&.{ "Safari", "Terminal" });
    defer c.deinit();
    try c.setIcon(0, .{ .path = "/tmp/safari.png", .png = "png" });
    try c.setIcon(9, .{ .path = "/tmp/unknown.png", .png = "png" });
    try testing.expectEqualStrings("/tmp/safari.png", c.items[0].icon.?.path);
    try testing.expect(c.items[1].icon == null);
}
