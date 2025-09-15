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

    const engine_module = b.addModule("rhi" ,.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zwindows", .module = zwindows.module("zwindows") },
            .{ .name = "zd3d12", .module = zwindows.module("zd3d12") },
            .{ .name = "zxaudio2", .module = zwindows.module("zxaudio2") }
        },
    });

    const lib = b.addLibrary(.{
        .name = "rhi",
        .linkage = .static, 
        .root_module = engine_module 
    });

    if(b.lazyDependency("vma", .{
        .target = target,
        .optimize = optimize,
    })) |vma_dep| {
        engine_module.addImport(
            "vma",
            vma_dep.module("vma"),
        );
        engine_module.linkLibrary(vma_dep.artifact("vma"));
    }

    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");      
    const vulkan = b.dependency("vulkan", .{
        .registry = registry,
    }).module("vulkan-zig");
    engine_module.addImport("vulkan", vulkan);


    const activate_zwindows = @import("zwindows").activateSdk(b, zwindows);
    lib.step.dependOn(activate_zwindows);
    
    // Install vendored binaries
    @import("zwindows").install_d3d12(&lib.step, zwindows, .bin);

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
