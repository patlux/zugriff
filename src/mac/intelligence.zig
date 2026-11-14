//! Keeps AppKit from wiring the palette into Apple Intelligence.
//!
//! On macOS 27 AppKit does this for every app on its own, and each step
//! loads a chain of system frameworks the palette never uses (AppIntents,
//! WritingToolsUI, GenerativeModels and, through them, WebKit): about 500
//! images on the start path and 130 more at the first show. Measured on
//! macOS 27.2: 1168 images after the start without this, 659 with it. The
//! steps, each an Objective-C method:
//!
//! - `-[NSApplication init]` registers the app with App Intents
//!   (`_registerApplicationWithUIIntelligence`).
//! - `finishLaunching` adds the Writing Tools to the Edit menu
//!   (`_updateLegacyWritingToolsItemsInEditMenu:`, `isWritingToolsAvailable`).
//! - The first text input context watches Siri's availability
//!   (`addObserverForEnhancedSiriAvailabilityDidChangeUsingBlock:`).
//! - A focused text field checks whether to offer the Writing Tools
//!   (`_startDwellingCheck`, `NSCampoLightweightUIController isEligible`).
//!
//! There is no default or Info.plist key for any of them, so `optOut`
//! replaces these methods with ones that do nothing. They are private: a
//! method that is missing, or whose signature is not the one checked here,
//! stays as it is, and the palette then loads what it loads today. The text
//! input itself (accents, input methods) stays untouched.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

const log = std.log.scoped(.zugriff);

const Method = *opaque {};
extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;
extern "c" fn object_getClass(obj: objc.Object) objc.Class;
extern "c" fn class_getInstanceMethod(cls: objc.Class, name: objc.SEL) ?Method;
extern "c" fn method_getTypeEncoding(m: Method) ?[*:0]const u8;
extern "c" fn method_setImplementation(m: Method, imp: *const anyopaque) ?*const anyopaque;

/// Where a method lives: on the class object (`+`) or its instances (`-`).
const Side = enum { class, instance };

/// A method to silence: replaced by `imp` if it has exactly `types`.
const Hook = struct {
    class: [:0]const u8,
    selector: [:0]const u8,
    side: Side,
    /// The Objective-C type encoding the method must have (checked on
    /// macOS 27.0.1 and 27.2).
    types: [:0]const u8,
    imp: *const anyopaque,
};

const hooks = [_]Hook{
    .{
        .class = "NSApplication",
        .selector = "_registerApplicationWithUIIntelligence",
        .side = .instance,
        .types = "v16@0:8",
        .imp = &ignore,
    },
    .{
        .class = "NSApplication",
        .selector = "_updateLegacyWritingToolsItemsInEditMenu:",
        .side = .instance,
        .types = "v24@0:8@16",
        .imp = &ignoreObject,
    },
    .{
        .class = "NSWritingToolsCoordinator",
        .selector = "isWritingToolsAvailable",
        .side = .class,
        .types = "B16@0:8",
        .imp = &no,
    },
    .{
        .class = "NSWritingToolsCoordinator",
        .selector = "addObserverForEnhancedSiriAvailabilityDidChangeUsingBlock:",
        .side = .class,
        .types = "@24@0:8@?16",
        .imp = &noObserver,
    },
    .{
        .class = "NSCampoLightweightUIController",
        .selector = "isEligible",
        .side = .class,
        .types = "B16@0:8",
        .imp = &no,
    },
    .{
        .class = "NSTextInputContext",
        .selector = "_startDwellingCheck",
        .side = .instance,
        .types = "v16@0:8",
        .imp = &ignore,
    },
};

/// Silences the hooks. Call it on the main thread before the first
/// `NSApplication` exists (before `nanoui.App.create`).
pub fn optOut() void {
    var replaced: usize = 0;
    for (hooks) |h| {
        if (replace(h)) replaced += 1 else log.debug("Apple Intelligence: {s} {s} bleibt", .{ h.class, h.selector });
    }
    log.info("Apple Intelligence abgeschaltet: {d} von {d} Stellen", .{ replaced, hooks.len });
}

/// Replaces `h`'s method if it exists with exactly the expected signature.
fn replace(h: Hook) bool {
    const cls = objc_getClass(h.class) orelse return false;
    const owner = switch (h.side) {
        .instance => cls,
        .class => object_getClass(@ptrCast(cls)),
    };
    const m = class_getInstanceMethod(owner, objc.sel(h.selector)) orelse return false;
    const types = method_getTypeEncoding(m) orelse return false;
    if (!std.mem.eql(u8, std.mem.span(types), h.types)) return false;
    _ = method_setImplementation(m, h.imp);
    return true;
}

fn ignore(_: objc.Object, _: objc.SEL) callconv(.c) void {}

fn ignoreObject(_: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {}

fn no(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.NO;
}

/// No observer token: AppKit keeps it only to remove the observer again.
fn noObserver(_: objc.Object, _: objc.SEL, _: ?*anyopaque) callconv(.c) ?objc.Object {
    return null;
}

extern "c" fn class_addMethod(cls: objc.Class, name: objc.SEL, imp: *const anyopaque, types: [*:0]const u8) objc.BOOL;

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

/// A hook on the test class: `"B16@0:8"` replaced by `no`.
fn probe(class: [:0]const u8, selector: [:0]const u8, side: Side) Hook {
    return .{ .class = class, .selector = selector, .side = side, .types = "B16@0:8", .imp = &no };
}

test "a method is replaced only where its signature is the expected one" {
    const testing = std.testing;
    const cls = objc.defineClass(.{ .name = "ZugriffIntelligenceProbe", .methods = &.{
        .{ .name = "probeMatching", .imp = &yes, .types = "B16@0:8" },
        .{ .name = "probeOtherTypes", .imp = &yes, .types = "c16@0:8" },
    } });
    _ = class_addMethod(object_getClass(@ptrCast(cls)), objc.sel("probeClassSide"), &yes, "B16@0:8");

    const name = "ZugriffIntelligenceProbe";
    try testing.expect(replace(probe(name, "probeMatching", .instance)));
    try testing.expect(!replace(probe(name, "probeOtherTypes", .instance)));
    try testing.expect(!replace(probe(name, "probeMissing", .instance)));
    try testing.expect(!replace(probe("ZugriffNoSuchClass", "probeMatching", .instance)));
    // A class method is not among the instance methods.
    try testing.expect(!replace(probe(name, "probeClassSide", .instance)));
    try testing.expect(replace(probe(name, "probeClassSide", .class)));

    const obj = objc.new("ZugriffIntelligenceProbe");
    defer objc.release(obj);
    try testing.expect(!objc.msg(objc.BOOL, obj, "probeMatching", .{}));
    try testing.expect(objc.msg(objc.BOOL, obj, "probeOtherTypes", .{}));
    try testing.expect(!objc.msg(objc.BOOL, cls, "probeClassSide", .{}));
}
