const std = @import("std");

/// The one place the version is written.
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{ .name = "zugriff", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    exe.root_module.addOptions("build_options", options);
    linkFrameworks(exe.root_module);
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
    const test_step = b.step("test", "Run the tests (offscreen, no window)");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// Carbon for the hot keys and the secure-input check, ApplicationServices
/// for the Accessibility check and the synthetic ⌘V. nanoui links AppKit.
fn linkFrameworks(m: *std.Build.Module) void {
    m.linkFramework("Carbon", .{});
    m.linkFramework("ApplicationServices", .{});
}
