//! Queries that name exactly one thing instead of describing a search.
//!
//! A typed absolute path or a web address is not a search term: the palette
//! can open it directly. Detection lives here so the UI never has to guess
//! which rows a query means.
const std = @import("std");
const text = @import("text.zig");

pub const DirectTarget = union(enum) {
    /// A path that exists, with a leading `~` already expanded.
    path: []const u8,
    /// A web address with an explicit `http` or `https` scheme, as typed.
    url: []const u8,

    /// Classifies a raw query; null keeps it a search. The result lives in
    /// `arena`.
    ///
    /// Only absolute paths count, because a relative one would resolve
    /// against the agent's working directory rather than the place the user
    /// means. URLs need their scheme so that `example.com` still searches.
    pub fn detect(arena: std.mem.Allocator, io: std.Io, home: ?[]const u8, raw: []const u8) !?DirectTarget {
        const trimmed = text.trim(raw);
        if (webAddress(trimmed)) |url| return .{ .url = try arena.dupe(u8, url) };
        if (try existingPath(arena, io, home, trimmed)) |p| return .{ .path = p };
        return null;
    }
};

fn webAddress(raw: []const u8) ?[]const u8 {
    const scheme_len: usize = for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (raw.len >= scheme.len and std.ascii.eqlIgnoreCase(raw[0..scheme.len], scheme)) break scheme.len;
    } else return null;
    const rest = raw[scheme_len..];
    // A URL without a host or with whitespace is a typo, not a link.
    if (rest.len == 0) return null;
    var it = text.iterate(rest);
    while (it.next()) |cp| if (text.isWhitespace(cp)) return null;
    return raw;
}

fn existingPath(arena: std.mem.Allocator, io: std.Io, home: ?[]const u8, raw: []const u8) !?[]const u8 {
    const path: []const u8 = if (std.mem.startsWith(u8, raw, "~/")) blk: {
        const h = home orelse return null;
        if (h.len == 0) return null;
        const rest = raw[2..];
        if (rest.len == 0) break :blk try arena.dupe(u8, h);
        break :blk try arena.print("{s}/{s}", .{ std.mem.trimEnd(u8, h, "/"), rest });
    } else if (std.mem.eql(u8, raw, "~")) blk: {
        const h = home orelse return null;
        if (h.len == 0) return null;
        break :blk try arena.dupe(u8, h);
    } else if (std.mem.startsWith(u8, raw, "/")) try arena.dupe(u8, raw) else return null;

    // Every stat error counts as missing: a path the agent cannot see is
    // not a path it should offer.
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return null;
    return path;
}

const testing = std.testing;

fn homeDir() ?[]const u8 {
    const h = std.c.getenv("HOME") orelse return null;
    return std.mem.span(h);
}

fn detect(raw: []const u8) !?DirectTarget {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try DirectTarget.detect(arena.allocator(), testing.io, homeDir(), raw) orelse return null;
    // Copied out of the arena for the caller's comparison.
    return switch (found) {
        .path => |p| .{ .path = try testing.allocator.dupe(u8, p) },
        .url => |u| .{ .url = try testing.allocator.dupe(u8, u) },
    };
}

fn free(t: ?DirectTarget) void {
    if (t) |v| switch (v) {
        inline else => |s| testing.allocator.free(s),
    };
}

test "detects existing absolute paths and trims whitespace" {
    const tmp = "/tmp";
    const a = try detect("  /tmp  ");
    defer free(a);
    try testing.expectEqualStrings(tmp, a.?.path);
    try testing.expect(try detect("/zugriff/does/not/exist") == null);
}

test "expands the home shortcut" {
    const home = homeDir() orelse return error.SkipZigTest;
    const a = try detect("~");
    defer free(a);
    try testing.expectEqualStrings(home, a.?.path);
    const b = try detect("~/");
    defer free(b);
    try testing.expectEqualStrings(home, b.?.path);
    try testing.expect(try detect("~/zugriff-does-not-exist") == null);
}

test "relative paths and bare words stay searches" {
    for ([_][]const u8{ "main.rs", "./relative", "../relative", "com.apple.Safari" }) |spec| {
        try testing.expect(try detect(spec) == null);
    }
}

test "web addresses need a scheme and a host" {
    for ([_][]const u8{ "https://example.com", "http://localhost:3000/path?query=1", "HTTPS://EXAMPLE.COM" }) |spec| {
        const t = try detect(spec);
        defer free(t);
        try testing.expectEqualStrings(spec, t.?.url);
    }
    for ([_][]const u8{
        "https://",
        "http://",
        "https://example.com with a space",
        "example.com",
        "www.example.com",
        "mailto:nobody@example.com",
        "/https://example.com",
    }) |spec| {
        try testing.expect(try detect(spec) == null);
    }
}
