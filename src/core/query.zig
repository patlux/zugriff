//! A parsed palette query: the raw text plus lowercased search tokens.
//!
//! Whitespace separates tokens. Every token has to match an item, which lets
//! a query such as `chrome goog` narrow a list instead of widening it.
const std = @import("std");
const text = @import("text.zig");

pub const Query = struct {
    raw: []const u8,
    tokens: []const []const u8,

    /// Splits and lowercases `raw`; free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, raw: []const u8) !Query {
        var tokens: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (tokens.items) |t| gpa.free(t);
            tokens.deinit(gpa);
        }
        var it = text.words(raw);
        while (it.next()) |word| try tokens.append(gpa, try text.lowerAlloc(gpa, word));
        return .{ .raw = raw, .tokens = try tokens.toOwnedSlice(gpa) };
    }

    pub fn deinit(q: Query, gpa: std.mem.Allocator) void {
        for (q.tokens) |t| gpa.free(t);
        gpa.free(q.tokens);
    }

    /// Whether the query contains at least one search token.
    pub fn isEmpty(q: Query) bool {
        return q.tokens.len == 0;
    }
};

test "tokens are lowercased words" {
    const gpa = std.testing.allocator;
    const q = try Query.init(gpa, "  Google  CHROME ");
    defer q.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), q.tokens.len);
    try std.testing.expectEqualStrings("google", q.tokens[0]);
    try std.testing.expectEqualStrings("chrome", q.tokens[1]);
    const empty = try Query.init(gpa, "   ");
    defer empty.deinit(gpa);
    try std.testing.expect(empty.isEmpty());
}
