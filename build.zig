const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zwindows = b.dependency("zwindows", .{
        .zxaudio2_debug_layer = (builtin.mode == .Debug),
        .zd3d12_debug_layer = (builtin.mode == .Debug),
        .zd3d12_gbv = b.option(bool, "zd3d12_gbv", "Enable GPU-Based Validation") orelse false,
    });

    const engine_module = b.addModule("rhi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zwindows", .module = zwindows.module("zwindows") }, .{ .name = "zd3d12", .module = zwindows.module("zd3d12") }, .{ .name = "zxaudio2", .module = zwindows.module("zxaudio2") } },
    });

    const lib = b.addLibrary(.{ .name = "rhi", .linkage = .static, .root_module = engine_module });
    
    // The Vulkan backend (and its VMA allocator) are only wired in on non-Apple
    // targets. On Apple platforms `platform_api = {.mtl}`, so the Vulkan/VMA
    // modules are never imported by the source — and pulling them would require
    // the Vulkan SDK headers and the vulkan-zig generator, neither of which is
    // needed for a Metal build.
    const is_apple = target.result.os.tag == .macos or target.result.os.tag == .ios;
    if (!is_apple) {
        const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
        if (b.lazyDependency("vma", .{
            .target = target,
            .optimize = optimize,
            .registry = registry,
        })) |vma_dep| {
            engine_module.addImport("vma", vma_dep.module("vma"));
            engine_module.linkLibrary(vma_dep.artifact("vma"));
        }

        const vulkan = b.dependency("vulkan", .{
            .registry = registry,
        }).module("vulkan-zig");
        engine_module.addImport("vulkan", vulkan);
    } else {
        // Wire in the Metal binding fabric (deps/metal), which links the
        // Metal/QuartzCore/Foundation frameworks via zig_objc.
        if (b.lazyDependency("metal", .{
            .target = target,
            .optimize = optimize,
        })) |metal_dep| {
            engine_module.addImport("metal", metal_dep.module("metal"));
        }
    }

    if (builtin.target.os.tag == .windows) {
        const zwindow = @import("zwindows");
        const activate_zwindows = zwindow.activateSdk(b, zwindows);
        lib.step.dependOn(activate_zwindows);
        zwindow.install_d3d12(&lib.step, zwindows, .bin);
    }
    // Install vendored binaries

    b.installArtifact(lib);
    const mod_tests = b.addTest(.{
        .root_module = engine_module,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = engine_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
