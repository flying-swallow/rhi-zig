// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const std = @import("std");
const builtin = @import("builtin");

/// Copy a compiled library's include directories onto a TranslateC step so the
/// aggregator header can resolve the library's installed headers. Mirrors the
/// helper documented by cimgui.zig for consuming its C bindings.
fn addIncludePathsToTranslateC(translate_c: *std.Build.Step.TranslateC, lib: *std.Build.Step.Compile) void {
    for (lib.root_module.include_dirs.items) |included| {
        switch (included) {
            .path => |p| translate_c.addIncludePath(p),
            .path_system => |p| translate_c.addSystemIncludePath(p),
            .config_header_step => |ch| translate_c.addConfigHeader(ch),
            .other_step => |other| addIncludePathsToTranslateC(translate_c, other),
            else => {},
        }
    }
}

/// Compile one Slang entry point to SPIR-V and return a LazyPath to the emitted
/// module, for embedding via `addAnonymousImport` + `@embedFile`.
pub fn compileSlangSpv(
    b: *std.Build,
    slangc: std.Build.LazyPath,
    src: []const u8,
    entry: []const u8,
    stage: []const u8,
    out_name: []const u8,
) std.Build.LazyPath {
    const run = std.Build.Step.Run.create(b, b.fmt("slangc spirv {s}", .{out_name}));
    run.addFileArg(slangc); // argv[0]: the resolved slangc binary
    run.addFileArg(b.path(src));
    run.addArgs(&.{ "-target", "spirv", "-entry", entry, "-stage", stage, "-o" });
    return run.addOutputFileArg(out_name);
}

/// Exposes the prebuilt `slangc` executable from the `slang` dependency.
pub fn getSlangc(b: *std.Build, rhi_dep: ?*std.Build.Dependency) ?std.Build.LazyPath {
    if (b.option([]const u8, "slangc", "Path to a slangc executable (skips the prebuilt Slang download)")) |p| {
        return .{ .cwd_relative = p };
    }
    const builder = if (rhi_dep) |d| d.builder else b;
    const slang_pkg = builder.lazyImport(@This(), "slang") orelse return null;
    const slang_dep = builder.lazyDependency("slang", .{}) orelse return null;
    return slang_pkg.slangc(slang_dep.builder);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zwindows: ?*std.Build.Dependency = if (builtin.target.os.tag == .windows) b.lazyDependency("zwindows", .{
        .zxaudio2_debug_layer = (builtin.mode == .Debug),
        .zd3d12_debug_layer = (builtin.mode == .Debug),
        .zd3d12_gbv = b.option(bool, "zd3d12_gbv", "Enable GPU-Based Validation") orelse false,
    }) else null;

    const engine_module = b.addModule("rhi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = if (zwindows) |zw| &.{
            .{ .name = "zwindows", .module = zw.module("zwindows") },
            .{ .name = "zd3d12", .module = zw.module("zd3d12") },
            .{ .name = "zxaudio2", .module = zw.module("zxaudio2") },
        } else &.{},
    });

    const lib = b.addLibrary(.{ .name = "rhi", .linkage = .static, .root_module = engine_module });

    // Dear ImGui, consumed as the `cimgui` module (dear_bindings' C API).
    //
    // Configured with no renderer/platform backends: the ImGui layer in
    // `src/imgui.zig` renders draw data through the RHI itself, so cimgui's own
    // imgui_impl_* backends are unused. This also keeps the core library from
    // pulling in cimgui's bundled SDL3/Vulkan/GLFW (and avoids a duplicate SDL3
    // against the one the examples link).
    if (b.lazyDependency("cimgui_zig", .{
        .target = target,
        .optimize = optimize,
    })) |cimgui_dep| {
        const cimgui_lib = cimgui_dep.artifact("cimgui");
        engine_module.linkLibrary(cimgui_lib);

        const cimgui_translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/cimgui.h"),
            .target = target,
            .optimize = optimize,
        });
        addIncludePathsToTranslateC(cimgui_translate_c, cimgui_lib);
        engine_module.addImport("cimgui", cimgui_translate_c.createModule());
    }

    // The ImGui layer's shader is authored in Slang and compiled to SPIR-V by
    // slangc (the same toolchain the examples use), then embedded into the
    // module via anonymous imports (`@embedFile("imgui_vert_spv")`). slangc is
    // resolved from an explicit `-Dslangc=` path, otherwise the prebuilt release
    // for this host is fetched lazily.
    {
        const slangc = getSlangc(b, null) orelse return;
        const vert_spv = compileSlangSpv(b, slangc, "src/shaders/imgui.slang", "vertexMain", "vertex", "imgui.vert.spv");
        const frag_spv = compileSlangSpv(b, slangc, "src/shaders/imgui.slang", "fragmentMain", "fragment", "imgui.frag.spv");
        engine_module.addAnonymousImport("imgui_vert_spv", .{ .root_source_file = vert_spv });
        engine_module.addAnonymousImport("imgui_frag_spv", .{ .root_source_file = frag_spv });
    }

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
        // lazyImport (not @import): zwindows is a lazy dep now, so its build
        // helpers must be imported the same way as the lazy `slang` package —
        // a plain @import would be comptime-resolved even on non-Windows and
        // fail because the dep isn't fetched there.
        if (b.lazyImport(@This(), "zwindows")) |zwindow| {
            if (zwindows) |zw| {
                const activate_zwindows = zwindow.activateSdk(b, zw);
                lib.step.dependOn(activate_zwindows);
                zwindow.install_d3d12(&lib.step, zw, .bin);
            }
        }
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
