//! Opening apps, files and links through Launch Services.
//!
//! Every call hands the work to `NSWorkspace` without waiting for it: an app
//! takes seconds to start, and the main thread draws the palette meanwhile.
//! Main thread only.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Action = @import("../core.zig").Action;

const log = std.log.scoped(.launch);

/// Performs a row's action. The emoji command never reaches here: the
/// palette opens the picker itself.
pub fn perform(action: Action) void {
    switch (action) {
        .launch_application => |path| openApplication(path),
        .open_path => |path| openUrl(fileUrl(path)),
        .open_url => |url| if (webUrl(url)) |u| openUrl(u) else log.err("keine gültige Adresse: {s}", .{url}),
        .reveal_path => |path| reveal(path),
        .open_emoji_picker => log.debug("Emoji-Befehl erreichte das Starten", .{}),
    }
}

fn workspace() objc.Object {
    return objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
}

fn fileUrl(path: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
}

fn webUrl(url: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)});
}

fn configuration() objc.Object {
    return objc.msg(objc.Object, objc.class("NSWorkspaceOpenConfiguration"), "configuration", .{});
}

/// Opens the bundle at `path` and brings it to the front.
pub fn openApplication(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    objc.msg(
        void,
        workspace(),
        "openApplicationAtURL:configuration:completionHandler:",
        .{ fileUrl(path), configuration(), @as(?*anyopaque, null) },
    );
}

/// Opens a file, a folder or a web address with its default application.
fn openUrl(url: objc.Object) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    objc.msg(
        void,
        workspace(),
        "openURL:configuration:completionHandler:",
        .{ url, configuration(), @as(?*anyopaque, null) },
    );
}

/// Selects a file or folder in Finder.
pub fn reveal(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const urls = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{fileUrl(path)});
    objc.msg(void, workspace(), "activateFileViewerSelectingURLs:", .{urls});
}

/// Opens a `x-apple.systempreferences:` or web address.
pub fn openAddress(url: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (webUrl(url)) |u| openUrl(u);
}
