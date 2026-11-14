//! The palette's window: a non-activating panel over everything, centred on
//! the screen under the pointer, with the system's blur behind it.
//!
//! nanoui makes the panel (`title_bar = .popover`: a borderless,
//! non-activating NSPanel that takes keys and hides when it loses them).
//! The rest of the configuration happens once, from the start path; a show
//! only centres the panel and orders it front.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

/// Logical size of the palette.
pub const width: f64 = 640;
pub const height: f64 = 420;
/// Corner radius of the panel: the one nanoui gives a popover's content view.
pub const corner_radius: f64 = 12;

/// The window options nanoui creates the panel with.
pub fn options(
    view: nanoui.ui.View,
    theme: nanoui.ui.Theme,
    ctx: *anyopaque,
    on_key: *const fn (ctx: *anyopaque, w: *nanoui.Window) void,
    on_close: *const fn (ctx: *anyopaque, w: *nanoui.Window) void,
) nanoui.WindowOptions {
    return .{
        .title = "Zugriff",
        .width = width,
        .height = height,
        .min_width = width,
        .min_height = height,
        .resizable = false,
        .title_bar = .popover,
        .visible = false,
        .theme = theme,
        .on_key = .{ .ctx = ctx, .func = on_key },
        .on_close = .{ .ctx = ctx, .func = on_close },
        .content = .{ .view = view },
    };
}

/// Applies what the show path should not pay for: the panel's behaviour,
/// the dark appearance and the blurred backdrop.
pub fn configure(w: *nanoui.Window) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const win = w.nswindow;

    // AppKit caches the WindowServer's "prevents activation" tag when the
    // window is made; refresh it, or a show still activates the app and the
    // app in front loses its active window appearance. Private SPI, guarded.
    if (objc.msg(objc.BOOL, win, "respondsToSelector:", .{objc.sel("_setPreventsActivation:")})) {
        objc.msg(void, win, "_setPreventsActivation:", .{objc.YES});
    } else std.log.warn("-[NSWindow _setPreventsActivation:] fehlt; das Panel nimmt den Fokus", .{});

    // A launcher appears and disappears at once.
    objc.msg(void, win, "setAnimationBehavior:", .{@as(objc.NSInteger, 2)}); // NSWindowAnimationBehaviorNone
    // CanJoinAllSpaces | FullScreenAuxiliary | Transient | IgnoresCycle
    const behavior: objc.NSUInteger = (1 << 0) | (1 << 8) | (1 << 3) | (1 << 6);
    objc.msg(void, win, "setCollectionBehavior:", .{behavior});
    objc.msg(void, win, "setHidesOnDeactivate:", .{objc.NO});
    if (objc.msg(objc.BOOL, win, "isKindOfClass:", .{objc.class("NSPanel")})) {
        const level = objc.msg(objc.NSInteger, win, "level", .{});
        objc.msg(void, win, "setFloatingPanel:", .{objc.YES});
        objc.msg(void, win, "setBecomesKeyOnlyIfNeeded:", .{objc.NO});
        objc.msg(void, win, "setWorksWhenModal:", .{objc.YES});
        // `setFloatingPanel:` resets the level to the floating one.
        objc.msg(void, win, "setLevel:", .{level});
    }

    // The theme is dark and stays dark: the blur must not turn light under
    // light text when the system is in light mode.
    if (objc.msg(
        ?objc.Object,
        objc.class("NSAppearance"),
        "appearanceNamed:",
        .{objc.nsString("NSAppearanceNameDarkAqua")},
    )) |dark| {
        objc.msg(void, win, "setAppearance:", .{dark});
    }
    installBackdrop(w);
}

/// The system's blur behind the panel: an NSVisualEffectView under the
/// view nanoui draws into, which presents a translucent frame.
fn installBackdrop(w: *nanoui.Window) void {
    const surface = w.surface orelse return;
    const bounds = objc.msg(objc.CGRect, surface.nsview, "bounds", .{});
    const effect = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{bounds});
    objc.msg(void, effect, "setMaterial:", .{@as(objc.NSInteger, 13)}); // HUDWindow
    objc.msg(void, effect, "setBlendingMode:", .{@as(objc.NSInteger, 0)}); // behind the window
    // The panel never activates the app, and an inactive effect view does not blur.
    objc.msg(void, effect, "setState:", .{@as(objc.NSInteger, 1)}); // active
    surface.attachBackdrop(effect);
    objc.release(effect);
    roundContent(w.nswindow);
}

/// `attachBackdrop` puts a new host view in as the content view. nanoui
/// rounded the old one for the popover; without the same on the host, the
/// blur and the window shadow keep square corners around the rounded frame.
fn roundContent(win: objc.Object) void {
    const content = objc.msg(?objc.Object, win, "contentView", .{}) orelse return;
    objc.msg(void, content, "setWantsLayer:", .{objc.YES});
    const layer = objc.msg(?objc.Object, content, "layer", .{}) orelse return;
    objc.msg(void, layer, "setCornerRadius:", .{corner_radius});
    objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    objc.msg(void, win, "invalidateShadow", .{});
}

/// Centres the panel on the screen with the pointer, draws the palette's
/// current state into it and makes it the key window without activating
/// the app. The caller still redraws afterwards: the frames that follow
/// (the emoji pictures load over several) need that request.
pub fn show(w: *nanoui.Window) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    centerOnPointerScreen(w.nswindow);
    drawBeforeShow(w);
    w.show();
    drawWithKeys(w);
}

/// A hidden panel still holds the frame it showed last (the emoji grid
/// after the emoji picker), and nanoui draws the next one only at the
/// display link's tick after the panel is on screen, so the old frame
/// flashes up first. This draws the current state while the panel is
/// still hidden, in the window's transaction, so it comes on screen
/// together with the panel.
///
/// nanoui 0.14.4 draws in the transaction only for a live-resize step
/// (`Surface.resizeInTransaction`), which needs a visible surface and no
/// display link (a layer with a link refuses `nextDrawable`). So the link
/// is dropped for this one frame and the surface counts as visible while
/// it draws; afterwards nanoui's occlusion check takes over again.
fn drawBeforeShow(w: *nanoui.Window) void {
    const s = w.surface orelse return;
    if (w.isVisible() or s.in_frame or s.dead) return;
    // `release` shrank the drawables; `Surface.visible` sizes them again
    // only when it finds the window on screen.
    if (s.released) {
        s.released = false;
        s.renderer.resize(s.size, s.scale);
    }
    const had_link = s.display_link != null;
    s.stopLink();
    s.is_visible = true;
    const drawn = s.resizeInTransaction();
    s.is_visible = false;
    if (had_link) s.startLink();
    if (!drawn) std.log.warn("Palette vor dem Zeigen nicht gezeichnet; der Display-Link zeichnet sie", .{});
}

/// `drawBeforeShow`'s frame has no caret: the panel is not the key window
/// yet. nanoui would draw the next frame only after AppKit reports the panel
/// visible and at the display link's tick after that, about 30 ms later in a
/// freshly started UI process. This draws it now, with the keys, in the same
/// transaction, and hands that transaction to the WindowServer at once:
/// it would otherwise wait until the run loop next waits, which in a freshly
/// started UI process is after its whole first turn.
fn drawWithKeys(w: *nanoui.Window) void {
    const s = w.surface orelse return;
    if (!w.isVisible() or s.in_frame or s.dead) return;
    if (s.released) {
        s.released = false;
        s.renderer.resize(s.size, s.scale);
    }
    const had_link = s.display_link != null;
    s.stopLink();
    // On screen now; AppKit's occlusion report follows later.
    s.is_visible = true;
    const drawn = s.resizeInTransaction();
    if (had_link) s.startLink();
    if (!drawn) return std.log.warn("Palette mit Tastatur nicht gleich gezeichnet; der Display-Link zeichnet sie", .{});
    objc.msg(void, objc.class("CATransaction"), "flush", .{});
}

pub fn hide(w: *nanoui.Window) void {
    w.hide();
    release(w);
}

/// Lets go of what a hidden panel does not need: the drawables (five of
/// 4 MB at 640×420 on a Retina screen) and the decoded pictures. nanoui
/// 0.14.4 does this when the window stops being visible, but `Window.hide`
/// marks the surface hidden first, so that path never runs; this runs it as
/// a change from visible. The next show sizes the drawables again.
pub fn release(w: *nanoui.Window) void {
    const surface = w.surface orelse return;
    if (surface.released or w.isVisible()) return;
    surface.is_visible = true;
    surface.occlusionChanged();
}

fn centerOnPointerScreen(win: objc.Object) void {
    const pointer = objc.msg(objc.CGPoint, objc.class("NSEvent"), "mouseLocation", .{});
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const count = objc.msg(objc.NSUInteger, screens, "count", .{});
    var screen: ?objc.Object = null;
    for (0..count) |i| {
        const s = objc.msg(objc.Object, screens, "objectAtIndex:", .{i});
        const f = objc.msg(objc.CGRect, s, "frame", .{});
        if (pointer.x >= f.origin.x and pointer.x < f.origin.x + f.size.width and
            pointer.y >= f.origin.y and pointer.y < f.origin.y + f.size.height)
        {
            screen = s;
            break;
        }
    }
    const target = screen orelse objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return;
    const visible = objc.msg(objc.CGRect, target, "visibleFrame", .{});
    const x = visible.origin.x + (visible.size.width - width) / 2;
    const top = visible.origin.y + visible.size.height - (visible.size.height - height) / 2;
    objc.msg(void, win, "setFrameTopLeftPoint:", .{objc.CGPoint{ .x = x, .y = top }});
}
