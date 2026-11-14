//! The bits of Unicode the search needs: lowercasing, letter and
//! whitespace classes, and code point iteration.
//!
//! Zig's std knows ASCII only. App names and emoji names are Latin with
//! umlauts and accents, sometimes Greek or Cyrillic; the tables here cover
//! those scripts. Code points outside them compare as they are.
const std = @import("std");

/// The lowercase form of `cp` for Latin (with Latin-1 and Latin
/// Extended-A), Greek and Cyrillic capitals; everything else unchanged.
pub fn lower(cp: u21) u21 {
    if (cp < 0x80) return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    if (cp >= 0xC0 and cp <= 0xDE and cp != 0xD7) return cp + 32;
    if (cp >= 0x100 and cp <= 0x137) return cp | 1;
    if (cp >= 0x139 and cp <= 0x148) return if (cp % 2 == 1) cp + 1 else cp;
    if (cp >= 0x14A and cp <= 0x177) return cp | 1;
    if (cp == 0x178) return 0xFF;
    if (cp >= 0x179 and cp <= 0x17E) return if (cp % 2 == 1) cp + 1 else cp;
    if (cp >= 0x391 and cp <= 0x3AB and cp != 0x3A2) return cp + 32;
    if (cp >= 0x410 and cp <= 0x42F) return cp + 32;
    if (cp >= 0x400 and cp <= 0x40F) return cp + 80;
    return cp;
}

pub fn isUpper(cp: u21) bool {
    return lower(cp) != cp;
}

pub fn isLower(cp: u21) bool {
    if (cp < 0x80) return cp >= 'a' and cp <= 'z';
    if (cp == 0xDF) return true;
    if (cp >= 0xE0 and cp <= 0xFF and cp != 0xF7) return true;
    if (cp >= 0x100 and cp <= 0x17F) return lower(cp) == cp and !isUpper(cp);
    if (cp >= 0x3B1 and cp <= 0x3CB) return true;
    if (cp >= 0x430 and cp <= 0x45F) return true;
    return false;
}

/// Letters of any script, approximately: ASCII letters, and above ASCII
/// everything that is not a space, a sign or punctuation of the common
/// blocks.
pub fn isAlphabetic(cp: u21) bool {
    if (cp < 0x80) return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z');
    if (cp < 0xC0) return cp == 0xAA or cp == 0xB5 or cp == 0xBA;
    if (cp == 0xD7 or cp == 0xF7) return false;
    if (cp >= 0x2000 and cp <= 0x2BFF) return false; // punctuation, symbols, arrows
    if (cp >= 0x3000 and cp <= 0x303F) return false;
    if (cp >= 0xFE00 and cp <= 0xFE0F) return false;
    if (cp >= 0x1F000) return false; // emoji
    return !isWhitespace(cp);
}

pub fn isDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

pub fn isAlphanumeric(cp: u21) bool {
    return isAlphabetic(cp) or isDigit(cp);
}

/// Unicode's White_Space property.
pub fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', 0x0B, 0x0C, '\r', 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        0x2000...0x200A => true,
        else => false,
    };
}

/// Decodes `s` into code points; invalid bytes come out as U+FFFD.
pub const Iterator = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *Iterator) ?u21 {
        if (it.i >= it.s.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(it.s[it.i]) catch {
            it.i += 1;
            return 0xFFFD;
        };
        if (it.i + len > it.s.len) {
            it.i = it.s.len;
            return 0xFFFD;
        }
        const cp = decodeSeq(it.s[it.i..][0..len]) orelse 0xFFFD;
        it.i += len;
        return cp;
    }

    /// The byte offset of the next code point.
    pub fn offset(it: Iterator) usize {
        return it.i;
    }
};

/// One UTF-8 sequence of 1–4 bytes; null when it is malformed.
fn decodeSeq(b: []const u8) ?u21 {
    switch (b.len) {
        1 => return b[0],
        2 => return std.unicode.utf8Decode2(b[0..2].*) catch null,
        3 => return std.unicode.utf8Decode3(b[0..3].*) catch null,
        4 => return std.unicode.utf8Decode4(b[0..4].*) catch null,
        else => return null,
    }
}

pub fn iterate(s: []const u8) Iterator {
    return .{ .s = s };
}

/// Appends the code points of `s` to `out`.
pub fn decodeInto(gpa: std.mem.Allocator, s: []const u8, out: *std.ArrayList(u21)) !void {
    var it = iterate(s);
    while (it.next()) |cp| try out.append(gpa, cp);
}

pub fn countCodepoints(s: []const u8) usize {
    var it = iterate(s);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn appendCp(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    try out.appendSlice(gpa, buf[0..n]);
}

/// `s` lowercased; the caller owns the result.
pub fn lowerAlloc(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, s.len);
    var it = iterate(s);
    while (it.next()) |cp| try appendCp(gpa, &out, lower(cp));
    return out.toOwnedSlice(gpa);
}

/// Lowercase without umlauts (`ä` → `a`, `ß` → `ss`), as the emoji table is
/// folded.
pub fn foldAlloc(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = iterate(s);
    while (it.next()) |raw| {
        switch (lower(raw)) {
            0xE4 => try out.append(gpa, 'a'),
            0xF6 => try out.append(gpa, 'o'),
            0xFC => try out.append(gpa, 'u'),
            0xDF => try out.appendSlice(gpa, "ss"),
            else => |cp| try appendCp(gpa, &out, cp),
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn eqlFold(a: u21, b: u21) bool {
    return a == b or lower(a) == lower(b);
}

/// Whether `s` starts with `prefix`, ignoring case.
pub fn startsWithFold(s: []const u8, prefix: []const u8) bool {
    var a = iterate(s);
    var b = iterate(prefix);
    while (b.next()) |pc| {
        const sc = a.next() orelse return false;
        if (!eqlFold(sc, pc)) return false;
    }
    return true;
}

/// Splits on Unicode whitespace, like Rust's `split_whitespace`.
pub const WordIterator = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(w: *WordIterator) ?[]const u8 {
        var it: Iterator = .{ .s = w.s, .i = w.i };
        // Skip leading space.
        var start = it.i;
        while (it.next()) |cp| {
            if (!isWhitespace(cp)) break;
            start = it.i;
        }
        if (start >= w.s.len) {
            w.i = w.s.len;
            return null;
        }
        it.i = start;
        var end = start;
        while (it.next()) |cp| {
            if (isWhitespace(cp)) break;
            end = it.i;
        }
        w.i = end;
        return w.s[start..end];
    }
};

pub fn words(s: []const u8) WordIterator {
    return .{ .s = s };
}

/// `s` without Unicode whitespace at both ends.
pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var it = iterate(s);
    while (it.next()) |cp| {
        if (!isWhitespace(cp)) break;
        start = it.i;
    }
    var end = start;
    it = .{ .s = s, .i = start };
    while (it.next()) |cp| {
        if (!isWhitespace(cp)) end = it.i;
    }
    return s[start..end];
}

test "lowercases Latin, Greek and Cyrillic capitals" {
    try std.testing.expectEqual(@as(u21, 'a'), lower('A'));
    try std.testing.expectEqual(@as(u21, 0xFC), lower(0xDC)); // Ü
    try std.testing.expectEqual(@as(u21, 0x3B1), lower(0x391)); // Α
    try std.testing.expectEqual(@as(u21, 0x431), lower(0x411)); // Б
    try std.testing.expect(isUpper('S') and isLower('s') and !isUpper('1'));
}

test "folds umlauts and splits on any space" {
    const gpa = std.testing.allocator;
    const folded = try foldAlloc(gpa, "Freudentränen Straße");
    defer gpa.free(folded);
    try std.testing.expectEqualStrings("freudentranen strasse", folded);
    var it = words("  ein\u{00A0}zwei  drei ");
    try std.testing.expectEqualStrings("ein", it.next().?);
    try std.testing.expectEqualStrings("zwei", it.next().?);
    try std.testing.expectEqualStrings("drei", it.next().?);
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqualStrings("a b", trim(" \ta b\u{3000}"));
}
