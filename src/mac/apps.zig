//! Discovery of installed application bundles.
//!
//! Runs on the scan thread: it reads folders and `Info.plist` files (through
//! Foundation, which reads binary and XML plists alike) and the icon cache,
//! never AppKit.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const core = @import("../core.zig");
const icons = @import("icons.zig");
const Item = core.Item;

/// How deep to descend below a search root. One level covers vendor folders
/// such as `/Applications/Adobe Photoshop 2024/`.
const max_depth = 1;

/// A list of apps and the arena that holds them.
pub const List = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item,

    pub fn deinit(l: *List) void {
        l.arena.deinit();
        l.* = undefined;
    }
};

/// Every launchable application, sorted by name. Unreadable bundles are
/// skipped: a broken third-party app must not keep the palette from working.
pub fn discover(gpa: std.mem.Allocator, io: std.Io, home: ?[]const u8) !List {
    var list: List = .{ .arena = .init(gpa), .items = &.{} };
    errdefer list.arena.deinit();
    const a = list.arena.allocator();

    var paths: std.ArrayList([]const u8) = .empty;
    try collect(a, io, "/Applications", max_depth, &paths);
    if (home) |h| try collect(a, io, try a.print("{s}/Applications", .{h}), max_depth, &paths);
    try collect(a, io, "/System/Applications", max_depth, &paths);
    // Finder lives outside the application folders people normally browse.
    try paths.append(a, "/System/Library/CoreServices/Finder.app");

    var seen_paths: std.StringHashMapUnmanaged(void) = .empty;
    var seen_ids: std.StringHashMapUnmanaged(void) = .empty;
    var items: std.ArrayList(Item) = .empty;
    for (paths.items) |path| {
        if ((try seen_paths.getOrPut(a, path)).found_existing) continue;
        const bundle = try load(a, io, home, path) orelse continue;
        if (bundle.id) |id| if ((try seen_ids.getOrPut(a, id)).found_existing) continue;
        try items.append(a, bundle.item);
    }

    const Sort = struct {
        const Self = @This();
        a: std.mem.Allocator,
        fn lt(s: Self, x: Item, y: Item) bool {
            const fx = core.text.lowerAlloc(s.a, x.title) catch x.title;
            const fy = core.text.lowerAlloc(s.a, y.title) catch y.title;
            return switch (std.mem.order(u8, fx, fy)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, x.title, y.title),
            };
        }
    };
    std.mem.sort(Item, items.items, Sort{ .a = a }, Sort.lt);
    list.items = try items.toOwnedSlice(a);
    return list;
}

fn collect(a: std.mem.Allocator, io: std.Io, dir_path: []const u8, depth: u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        // `/Applications/Safari.app` is a symlink: follow it, as `is_dir` does.
        const is_dir = switch (entry.kind) {
            .directory => true,
            .sym_link => blk: {
                const st = dir.statFile(io, entry.name, .{}) catch break :blk false;
                break :blk st.kind == .directory;
            },
            else => false,
        };
        if (!is_dir) continue;
        const path = try a.print("{s}/{s}", .{ dir_path, entry.name });
        if (std.ascii.endsWithIgnoreCase(entry.name, ".app")) {
            try out.append(a, path);
        } else if (depth > 0 and !std.mem.startsWith(u8, entry.name, ".")) {
            try collect(a, io, path, depth - 1, out);
        }
    }
}

const Bundle = struct { id: ?[]const u8, item: Item };

fn load(a: std.mem.Allocator, io: std.Io, home: ?[]const u8, path: []const u8) !?Bundle {
    const pool = objc.Pool.push();
    defer pool.pop();
    const info_path = try a.print("{s}/Contents/Info.plist", .{path});
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(info_path)});
    const info = objc.msg(
        ?objc.Object,
        objc.class("NSDictionary"),
        "dictionaryWithContentsOfURL:",
        .{url},
    ) orelse return null;

    if (boolValue(info, "LSBackgroundOnly")) return null;
    if (try string(a, info, "CFBundlePackageType")) |kind| if (!std.mem.eql(u8, kind, "APPL")) return null;

    const name = (try string(
        a,
        info,
        "CFBundleDisplayName",
    )) orelse (try string(a, info, "CFBundleName")) orelse return null;
    const title = core.text.trim(name);
    if (title.len == 0) return null;

    const id = try string(a, info, "CFBundleIdentifier");
    var keywords: std.ArrayList([]const u8) = .empty;
    if (id) |bundle_id| {
        // Components such as `Calculator` are useful search terms; the
        // reverse-DNS prefix and short components are not.
        var parts = std.mem.splitScalar(u8, bundle_id, '.');
        _ = parts.first();
        while (parts.next()) |part| if (part.len >= 3) try keywords.append(a, part);
    }
    if (try string(a, info, "CFBundleExecutable")) |exe| {
        const known = for (keywords.items) |k| {
            if (std.mem.eql(u8, k, exe)) break true;
        } else false;
        if (!known) try keywords.append(a, exe);
    }

    const parent = std.Io.Dir.path.dirname(path) orelse "";
    return .{ .id = id, .item = .{
        .title = title,
        .subtitle = try displayPath(a, home, parent),
        .keywords = try keywords.toOwnedSlice(a),
        .icon = try icons.cached(a, io, home, path),
        .action = .{ .launch_application = path },
    } };
}

/// A string value of the plist, copied into `a`.
fn string(a: std.mem.Allocator, dict: objc.Object, key: []const u8) !?[]const u8 {
    const v = objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)}) orelse return null;
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) return null;
    const copy = try a.dupe(u8, objc.fromNSString(v));
    return copy;
}

fn boolValue(dict: objc.Object, key: []const u8) bool {
    const v = objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)}) orelse return false;
    if (!objc.msg(objc.BOOL, v, "respondsToSelector:", .{objc.sel("boolValue")})) return false;
    return objc.msg(objc.BOOL, v, "boolValue", .{});
}

/// `~/Applications` for the home folder's apps.
pub fn displayPath(a: std.mem.Allocator, home: ?[]const u8, path: []const u8) ![]const u8 {
    if (home) |h| if (h.len > 0 and std.mem.startsWith(u8, path, h)) {
        const rest = path[h.len..];
        if (rest.len == 0) return "~";
        if (rest[0] == '/') return a.print("~{s}", .{rest});
    };
    return a.dupe(u8, path);
}

test "the home folder is shown as ~" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "~/Applications",
        try displayPath(a, "/Users/zugriff", "/Users/zugriff/Applications"),
    );
    try std.testing.expectEqualStrings("/Applications", try displayPath(a, "/Users/zugriff", "/Applications"));
    try std.testing.expectEqualStrings("/Users/zugriffer", try displayPath(a, "/Users/zugriff", "/Users/zugriffer"));
}
