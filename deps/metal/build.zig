const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The Objective-C bridge. `zig_objc` exposes its module under the name
    // "objc" and already links libobjc + Foundation and configures the Apple
    // SDK paths for its own module.
    const objc_dep = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });

    // The public "metal" module — the binding fabric consumers import.
    const mod = b.addModule("metal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("objc", objc_dep.module("objc"));
    linkApple(b, mod) catch |err| std.debug.panic("failed to configure Apple SDK: {s}", .{@errorName(err)});

    // `zig build test` compiles and runs the smoke test in src/root.zig.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

/// Link the Apple frameworks the bindings call into and add the SDK search
/// paths. Framework linking is per-module, so the consuming "metal" module must
/// declare these itself even though `zig_objc` also links some of them.
fn linkApple(b: *std.Build, m: *std.Build.Module) !void {
    m.linkSystemLibrary("objc", .{});
    m.linkFramework("Foundation", .{});
    m.linkFramework("Metal", .{});
    m.linkFramework("QuartzCore", .{});
    try addAppleSDK(b, m);
}

/// Add the Apple SDK framework / include / library search paths for the
/// module's resolved target. Mirrors `zig_objc`'s `addAppleSDK` helper, since
/// search paths are per-module and we cannot reuse the dependency's copy.
fn addAppleSDK(b: *std.Build, m: *std.Build.Module) !void {
    const target = m.resolved_target.?;
    const path = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse
        return error.AppleSDKNotFound;
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/System/Library/Frameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ path, "/usr/lib" }) });
}
