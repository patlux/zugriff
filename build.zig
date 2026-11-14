const std = @import("std");

/// The one place the version is written.
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{ .name = "zugriff-zig", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    exe.root_module.addOptions("build_options", options);
    linkFrameworks(exe.root_module);
    dropUnusedDylibs(exe);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Zugriff (GUI test host only; see AGENTS.md)").dependOn(&run.step);

    // Core, platform helpers and the palette, rendered offscreen with
    // ui.Tester: no window, no hotkey, no key events to other apps.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    tests.root_module.addOptions("build_options", options);
    linkFrameworks(tests.root_module);
    dropUnusedDylibs(tests);
    const test_step = b.step("test", "Run the tests (offscreen, no window)");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The palette's states as pictures, rendered offscreen.
    const shots = b.addExecutable(.{ .name = "shots", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shots.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    shots.root_module.addOptions("build_options", options);
    linkFrameworks(shots.root_module);
    dropUnusedDylibs(shots);
    const shoot = b.addRunArtifact(shots);
    shoot.has_side_effects = true;
    const pictures = shoot.addOutputDirectoryArg2("shots", .{});
    const install_shots = b.addInstallDirectory(.{
        .source_dir = pictures,
        .install_dir = .prefix,
        .install_subdir = "shots",
    });
    b.step("shots", "Render the palette's states to zig-out/shots (offscreen)").dependOn(&install_shots.step);
}

/// Carbon for the hot keys and the secure-input check, ApplicationServices
/// for the Accessibility check and the synthetic ⌘V. nanoui links AppKit.
fn linkFrameworks(m: *std.Build.Module) void {
    m.linkFramework("Carbon", .{});
    m.linkFramework("ApplicationServices", .{});
}

/// nanoui links every framework it can use, WebKit for its web view among
/// them. The palette has no web view, and WebKit alone makes dyld load 35
/// more images at every start (JavaScriptCore, WebCore, …). Drop each
/// framework no symbol is imported from; the ones nanoui reaches only
/// through the Objective-C runtime (Foundation, UniformTypeIdentifiers)
/// come with AppKit anyway.
fn dropUnusedDylibs(c: *std.Build.Step.Compile) void {
    c.dead_strip_dylibs = true;
}
