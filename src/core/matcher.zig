//! Fuzzy scoring of items against queries.
//!
//! Titles match as a fuzzy subsequence with bonuses for word starts,
//! consecutive characters and prefixes. Keywords (bundle-id components, the
//! executable) match only from their start and always score below a title
//! match.
const std = @import("std");
const text = @import("text.zig");
const Item = @import("item.zig").Item;
const Query = @import("query.zig").Query;

const score_match: i32 = 16;
const score_start: i32 = 24;
const score_boundary: i32 = 18;
const score_consecutive: i32 = 14;
const score_prefix: i32 = 32;
const score_exact: i32 = 48;
const gap_open: i32 = 4;
const gap_step: i32 = 2;
const max_leading_gap: usize = 6;
/// Added for every token that matches the visible title. It keeps any title
/// match above a keyword-only match, no matter how good the alias is.
const title_priority: i32 = 1_000_000;

/// Scores items against queries while reusing its scratch buffers: one
/// matcher lives for one search pass.
pub const Matcher = struct {
    gpa: std.mem.Allocator,
    needle: std.ArrayList(u21) = .empty,
    haystack: std.ArrayList(u21) = .empty,

    pub fn init(gpa: std.mem.Allocator) Matcher {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *Matcher) void {
        m.needle.deinit(m.gpa);
        m.haystack.deinit(m.gpa);
        m.* = undefined;
    }

    /// How well `query` matches `item`; null when it does not.
    ///
    /// Every query token must match the title or one of the keywords.
    pub fn score(m: *Matcher, item: Item, query: Query) !?i32 {
        if (query.isEmpty()) return 0;
        var total: i32 = 0;
        for (query.tokens) |token| {
            m.needle.clearRetainingCapacity();
            try text.decodeInto(m.gpa, token, &m.needle);
            if (m.needle.items.len == 0) continue;

            var best: ?i32 = if (try m.scoreText(item.title)) |s| s + title_priority else null;
            // Only a prefix match counts for an alias, otherwise every app
            // with a `com.apple.*` bundle would match almost any query.
            for (item.keywords) |keyword| {
                if (!text.startsWithFold(keyword, token)) continue;
                if (try m.scoreText(keyword)) |s| best = if (best) |b| @max(b, s) else s;
            }
            total += best orelse return null;
        }
        return total;
    }

    fn scoreText(m: *Matcher, s: []const u8) !?i32 {
        m.haystack.clearRetainingCapacity();
        try text.decodeInto(m.gpa, s, &m.haystack);
        return matchText(m.needle.items, m.haystack.items);
    }
};

/// Scores one token against one string: case-insensitive and greedy, the
/// leftmost occurrence of each character wins.
fn matchText(needle: []const u21, haystack: []const u21) ?i32 {
    if (haystack.len == 0) return null;
    var position = findFrom(haystack, 0, needle[0]) orelse return null;

    var s: i32 = score_match - leadingGapPenalty(position);
    if (position == 0) {
        s += score_start;
    } else if (isWordBoundary(haystack, position)) {
        s += score_boundary;
    }

    const first_position = position;
    for (needle[1..]) |nc| {
        const next = findFrom(haystack, position + 1, nc) orelse return null;
        s += score_match;
        if (next == position + 1) {
            s += score_consecutive;
        } else {
            const gap = next - position - 1;
            s -= gap_open + gap_step * @as(i32, @intCast(gap -| 1));
        }
        if (isWordBoundary(haystack, next)) s += score_boundary;
        position = next;
    }

    if (first_position == 0) {
        s += score_prefix;
        if (needle.len == haystack.len) s += score_exact;
    }
    return s;
}

fn findFrom(haystack: []const u21, start: usize, cp: u21) ?usize {
    if (start > haystack.len) return null;
    for (haystack[start..], start..) |c, i| if (text.eqlFold(c, cp)) return i;
    return null;
}

fn leadingGapPenalty(position: usize) i32 {
    return gap_step * @as(i32, @intCast(@min(position, max_leading_gap)));
}

fn isWordBoundary(chars: []const u21, position: usize) bool {
    if (position == 0) return false;
    const previous = chars[position - 1];
    const current = chars[position];
    return !text.isAlphanumeric(previous) or (text.isLower(previous) and text.isUpper(current));
}

const testing = std.testing;

fn testItem(title: []const u8) Item {
    return .{ .title = title, .action = .{ .launch_application = "/Applications/Test.app" } };
}

fn scoreTitle(title: []const u8, q: []const u8) !i32 {
    var m: Matcher = .init(testing.allocator);
    defer m.deinit();
    const query = try Query.init(testing.allocator, q);
    defer query.deinit(testing.allocator);
    return (try m.score(testItem(title), query)).?;
}

fn matches(it: Item, q: []const u8) !bool {
    var m: Matcher = .init(testing.allocator);
    defer m.deinit();
    const query = try Query.init(testing.allocator, q);
    defer query.deinit(testing.allocator);
    return (try m.score(it, query)) != null;
}

test "exact title beats merely prefixed title" {
    try testing.expect(try scoreTitle("Safari", "safari") > try scoreTitle("Safari Technology Preview", "safari"));
}

test "prefix beats infix" {
    try testing.expect(try scoreTitle("Safari", "saf") > try scoreTitle("Xcode Safari Helper", "saf"));
}

test "consecutive characters beat scattered characters" {
    try testing.expect(try scoreTitle("Terminal", "term") > try scoreTitle("Terminal", "trml"));
}

test "word boundaries beat matches inside a word" {
    try testing.expect(try scoreTitle("System Settings", "st") > try scoreTitle("LastPass", "st"));
}

test "matching is case-insensitive, also beyond ASCII" {
    try testing.expectEqual(try scoreTitle("Safari", "safari"), try scoreTitle("Safari", "SAFARI"));
    try testing.expectEqual(try scoreTitle("Safari", "safari"), try scoreTitle("Safari", "SaFaRi"));
    try testing.expect(try matches(testItem("Über"), "über"));
    try testing.expect(try matches(testItem("Über"), "ÜBER"));
}

test "every token has to match" {
    const it = testItem("Google Chrome");
    try testing.expect(try matches(it, "google"));
    try testing.expect(try matches(it, "google chrome"));
    try testing.expect(!try matches(it, "google safari"));
    try testing.expect(!try matches(testItem("Safari"), "safari zzz"));
}

test "keywords match from the start and score below the title" {
    var keyword_item = testItem("Google");
    keyword_item.keywords = &.{"Chrome"};
    try testing.expect(try scoreTitle("Google Chrome", "chrome") > blk: {
        var m: Matcher = .init(testing.allocator);
        defer m.deinit();
        const q = try Query.init(testing.allocator, "chrome");
        defer q.deinit(testing.allocator);
        break :blk (try m.score(keyword_item, q)).?;
    });

    var chess = testItem("Chess");
    chess.keywords = &.{ "Chess", "com" };
    try testing.expect(try matches(chess, "che"));
    try testing.expect(!try matches(chess, "calc"));
}

test "empty queries match everything" {
    try testing.expect(try matches(testItem("Safari"), "   "));
    try testing.expect(try matches(testItem("Safari"), ""));
}
