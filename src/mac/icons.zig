//! Application icons for the palette.
//!
//! macOS knows the best icon for a bundle: asset catalogs, vendor folders
//! and generic fallbacks all end up in one image through `NSWorkspace`.
//! Drawing it is AppKit work, so the palette renders icons after it is
//! visible instead of blocking the opening path.
//!
//! The rendered icon is a 64 px PNG in `~/Library/Caches/tech.piparo.zugriff/icons`,
//! named exactly as the Rust version names it: both versions share the cache.
//! `cached` answers from the file system alone, so the scan thread can
//! deliver icons without touching AppKit.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Icon = @import("../core.zig").Icon;
const files = @import("../files.zig");

/// Side length of the cached PNG in pixels: the row icon is 26 points, so
/// this covers a Retina display with room for the rounded corners.
pub const pixels = 64;

/// Part of the cache key. Bump it when the rendered icon should look different.
const cache_version: u64 = 1;

const fnv_offset_basis: u64 = 0xcbf2_9ce4_8422_2325;
const fnv_prime: u64 = 0x0000_0100_0000_01b3;

fn cacheDirectory(a: std.mem.Allocator, home: ?[]const u8) !?[]const u8 {
    const h = home orelse return null;
    if (h.len == 0) return null;
    const dir = try a.print("{s}/Library/Caches/tech.piparo.zugriff/icons", .{h});
    return dir;
}

/// The cache file for the current version of `app`: the bundle's
/// modification time is part of the key, so an update gets a new icon.
fn cachePath(a: std.mem.Allocator, io: std.Io, home: ?[]const u8, app: []const u8) !?[]const u8 {
    const dir = try cacheDirectory(a, home) orelse return null;
    const st = std.Io.Dir.cwd().statFile(io, app, .{}) catch return null;
    const modified = std.math.cast(u64, st.mtime.toSeconds()) orelse return null;
    const file = try a.print("{s}/{x:0>16}.png", .{ dir, cacheKey(app, modified) });
    return file;
}

pub fn cacheKey(app: []const u8, modified: u64) u64 {
    var hash = fnv_offset_basis;
    for ([_]u64{ cache_version, pixels, modified }) |v| hash = fnv1a(
        hash,
        std.mem.asBytes(&std.mem.nativeToLittle(u64, v)),
    );
    return fnv1a(hash, app);
}

fn fnv1a(start: u64, bytes: []const u8) u64 {
    var hash = start;
    for (bytes) |b| {
        hash ^= b;
        hash *%= fnv_prime;
    }
    return hash;
}

/// The icon already cached for the current version of `app`, read into `a`.
/// File system only: safe on the scan thread.
pub fn cached(a: std.mem.Allocator, io: std.Io, home: ?[]const u8, app: []const u8) !?Icon {
    const path = try cachePath(a, io, home, app) orelse return null;
    const png = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return null;
    return .{ .path = path, .png = png };
}

/// Renders the bundle icon into the cache and returns it. AppKit: main
/// thread only. A cache hit skips the AppKit work.
pub fn render(a: std.mem.Allocator, io: std.Io, home: ?[]const u8, app: []const u8) !Icon {
    if (try cached(a, io, home, app)) |hit| return hit;
    const path = try cachePath(a, io, home, app) orelse return error.NoCacheDirectory;
    const png = try renderPng(a, io, app);
    try writeAtomically(io, path, png);
    return .{ .path = path, .png = png };
}

fn renderPng(a: std.mem.Allocator, io: std.Io, app: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    // AppKit badges the icon of an alias, and `/Applications/Safari.app` is a
    // symlink: ask for the icon of the real bundle.
    const real = std.Io.Dir.realPathFileAbsoluteAlloc(io, app, a) catch try a.dupeSentinel(u8, app, 0);
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const image = objc.msg(objc.Object, ws, "iconForFile:", .{objc.nsString(real)});

    const side: objc.NSInteger = pixels;
    const bitmap_init = "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:" ++
        "hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:";
    const bitmap = objc.msg(?objc.Object, objc.alloc("NSBitmapImageRep"), bitmap_init, .{
        @as(?*anyopaque, null), // planes: allocated by the bitmap
        side, // pixels wide
        side, // pixels high
        @as(objc.NSInteger, 8), // bits per sample
        @as(objc.NSInteger, 4), // samples per pixel
        objc.YES, // alpha
        objc.NO, // planar
        objc.nsString("NSDeviceRGBColorSpace"),
        @as(objc.NSInteger, 0), // bytes per row: computed
        @as(objc.NSInteger, 0), // bits per pixel: computed
    }) orelse return error.NoBitmap;
    defer objc.release(bitmap);
    const ctx_class = objc.class("NSGraphicsContext");
    const context = objc.msg(
        ?objc.Object,
        ctx_class,
        "graphicsContextWithBitmapImageRep:",
        .{bitmap},
    ) orelse return error.NoContext;

    // Swap the drawing context for the bitmap, draw, and put the previous one back.
    const previous = objc.msg(?objc.Object, ctx_class, "currentContext", .{});
    objc.msg(void, ctx_class, "setCurrentContext:", .{context});
    const rect: objc.CGRect = .{ .size = .{ .width = pixels, .height = pixels } };
    objc.msg(void, image, "drawInRect:", .{rect});
    objc.msg(void, ctx_class, "setCurrentContext:", .{previous});

    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    // NSBitmapImageFileTypePNG
    const data = objc.msg(
        ?objc.Object,
        bitmap,
        "representationUsingType:properties:",
        .{ @as(objc.NSUInteger, 4), props },
    ) orelse return error.NoPng;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const bytes = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return error.NoPng;
    return a.dupe(u8, bytes[0..len]);
}

fn writeAtomically(io: std.Io, path: []const u8, png: []const u8) !void {
    const dir = std.Io.Dir.path.dirname(path) orelse return error.NoDirectory;
    try files.ensureDir(io, dir);
    // A process-specific temporary name keeps the rename atomic even when the
    // agent and a concurrent `zugriff icons` render the same bundle.
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = try std.mem.print(&buf, "{s}.{d}.tmp", .{ path, std.c.getpid() });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = png });
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}

/// Removes cache files older than `max_age_s`: the key holds the bundle's
/// modification time, so every app update leaves the previous icon behind.
pub fn pruneCache(a: std.mem.Allocator, io: std.Io, home: ?[]const u8, max_age_s: i64) !usize {
    const dir_path = try cacheDirectory(a, home) orelse return 0;
    return prune(io, dir_path, max_age_s);
}

fn prune(io: std.Io, dir_path: []const u8, max_age_s: i64) !usize {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer dir.close(io);
    const now = std.Io.Clock.real.now(io).toSeconds();
    var removed: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // Only what this module writes: icons and interrupted writes.
        if (!std.mem.endsWith(u8, entry.name, ".png") and !std.mem.endsWith(u8, entry.name, ".tmp")) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        if (now - st.mtime.toSeconds() < max_age_s) continue;
        dir.deleteFile(io, entry.name) catch continue;
        removed += 1;
    }
    return removed;
}

const testing = std.testing;

test "the cache key depends on the bundle and its version" {
    const app = "/Applications/Safari.app";
    try testing.expectEqual(cacheKey(app, 1_700_000_000), cacheKey(app, 1_700_000_000));
    try testing.expect(cacheKey(app, 1_700_000_000) != cacheKey(app, 1_700_000_001));
    try testing.expect(cacheKey(app, 1_700_000_000) != cacheKey("/Applications/Terminal.app", 1_700_000_000));
}

test "an unknown bundle has no cached icon" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try cached(arena.allocator(), testing.io, "/tmp", "/Applications/GibtEsNicht.app") == null);
}

test "prune removes stale icon files only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try a.print("/tmp/zugriff-icons-{d}", .{std.c.getpid()});
    const io = testing.io;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    for ([_][]const u8{ "old.png", "old.png.4711.tmp", "notes.txt" }) |name| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try a.print("{s}/{s}", .{ dir, name }), .data = "x" });
    }
    try testing.expectEqual(@as(usize, 2), try prune(io, dir, 0));
    try std.Io.Dir.cwd().access(io, try a.print("{s}/notes.txt", .{dir}), .{});
}
