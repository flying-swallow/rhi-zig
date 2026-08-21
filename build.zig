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

/// Compile one Slang entry point to WGSL for the WebGPU backend.
///
/// Two differences from the SPIR-V path matter:
///   - WGSL output keeps the real entry-point name (`@vertex fn vertexMain`),
///     whereas slangc rewrites SPIR-V entry points to `main`. Callers must pass
///     `entry` through to `createRenderPipeline` rather than assuming "main".
///   - `defines` gets `-D<name>` appended. The examples use this to swap a
///     `[[vk::push_constant]]` block for `[[vk::binding(0,0)]] ConstantBuffer`,
///     because slangc emits push constants as a `var<uniform>` with no
///     `@group`/`@binding` attribute, which WebGPU rejects.
pub fn compileSlangWgsl(
    b: *std.Build,
    slangc: std.Build.LazyPath,
    src: []const u8,
    entry: []const u8,
    stage: []const u8,
    out_name: []const u8,
    defines: []const []const u8,
) std.Build.LazyPath {
    const run = std.Build.Step.Run.create(b, b.fmt("slangc wgsl {s}", .{out_name}));
    run.addFileArg(slangc); // argv[0]: the resolved slangc binary
    run.addFileArg(b.path(src));
    run.addArgs(&.{ "-target", "wgsl", "-entry", entry, "-stage", stage });
    for (defines) |d| run.addArg(b.fmt("-D{s}", .{d}));
    run.addArg("-o");
    return run.addOutputFileArg(out_name);
}

/// Compile one Slang entry point to GLSL ES 3.00 for the WebGL2 backend.
///
/// Slang cannot emit an ES profile (`-h target` offers only Vulkan-flavoured
/// `glsl`, and `-h profile` lists `glsl_110`..`glsl_460` with no ES variants),
/// so this is a two-step chain: `slangc -target spirv`, then the vendored
/// SPIRV-Cross tool from `deps/spirv_cross`.
///
/// The tool also applies the NDC fixups GL needs — Y flip and a `[0,1]` to
/// `[-1,1]` depth remap — so no `.slang` source needs a GL-specific variant.
pub fn compileSlangGlslEs(
    b: *std.Build,
    slangc: std.Build.LazyPath,
    spirv_cross_tool: std.Build.LazyPath,
    src: []const u8,
    entry: []const u8,
    stage: []const u8,
    out_name: []const u8,
) std.Build.LazyPath {
    const spv = std.Build.Step.Run.create(b, b.fmt("slangc spirv {s}", .{out_name}));
    spv.addFileArg(slangc); // argv[0]: the resolved slangc binary
    spv.addFileArg(b.path(src));
    spv.addArgs(&.{ "-target", "spirv", "-entry", entry, "-stage", stage, "-o" });
    const spv_path = spv.addOutputFileArg(b.fmt("{s}.spv", .{out_name}));

    const glsl = std.Build.Step.Run.create(b, b.fmt("spirv-cross glsl-es {s}", .{out_name}));
    glsl.addFileArg(spirv_cross_tool);
    glsl.addFileArg(spv_path);
    const out = glsl.addOutputFileArg(out_name);
    glsl.addArgs(&.{ "300", "es" });
    return out;
}

/// Builds the vendored SPIRV-Cross translator and returns its executable.
/// Lazy: only a WebAssembly build needs it, and it compiles C++.
pub fn getSpirvCrossTool(b: *std.Build, rhi_dep: ?*std.Build.Dependency) ?std.Build.LazyPath {
    const builder = if (rhi_dep) |d| d.builder else b;
    const dep = builder.lazyDependency("spirv_cross", .{}) orelse return null;
    return dep.artifact("spirv_cross_tool").getEmittedBin();
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

    // A null "no GPU backend" build: `platform_api` collapses to `{}`, so
    // `Image`/`ImageView`/etc. become tiny handle types with no Vulkan/Metal/VMA
    // or imgui dependency, and none of those C libraries are linked. Lets a
    // headless tool or server import `rhi` for its type surface (e.g. an asset
    // record that names `rhi.Image`) without dragging in the renderer. Runtime
    // GPU calls are unavailable in this mode (they are never analyzed).
    const headless = b.option(bool, "headless", "Null RHI backend: no Vulkan/Metal/VMA/imgui, type-only") orelse false;
    // WebGPU is web-only: on a WebAssembly target `platform_api` collapses to
    // `{.wgpu}` (see `src/root.zig`), the backend talks to `navigator.gpu`
    // through the JS glue in `src/webgpu/glue.js`, and none of the native GPU
    // deps (Vulkan headers, VMA, vulkan-zig, Metal) or cimgui are wired in.
    const is_web = target.result.cpu.arch.isWasm();
    const zwindows: ?*std.Build.Dependency = if (builtin.target.os.tag == .windows) b.lazyDependency("zwindows", .{}) else null;

    const engine_module = b.addModule("rhi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = if (zwindows) |zw| &.{
            .{ .name = "zwindows", .module = zw.module("zwindows") },
        } else &.{},
    });

    // Expose the headless flag to the source (`root.zig` keys `platform_api` and
    // the imgui re-exports off it). Always wired, so a normal (vk/mtl) build just
    // reads `headless == false`.
    const rhi_options = b.addOptions();
    rhi_options.addOption(bool, "headless", headless);
    engine_module.addImport("build_options", rhi_options.createModule());

    const lib = b.addLibrary(.{ .name = "rhi", .linkage = .static, .root_module = engine_module });

    // Dear ImGui, consumed as the `cimgui` module (dear_bindings' C API).
    //
    // Configured with no renderer/platform backends: the ImGui layer in
    // `src/imgui.zig` renders draw data through the RHI itself, so cimgui's own
    // imgui_impl_* backends are unused. This also keeps the core library from
    // pulling in cimgui's bundled SDL3/Vulkan/GLFW (and avoids a duplicate SDL3
    // against the one the examples link).
    if (!headless and !is_web) {
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
    }

    // The ImGui layer's shader is authored in Slang and compiled to SPIR-V by
    // slangc (the same toolchain the examples use), then embedded into the
    // module via anonymous imports (`@embedFile("imgui_vert_spv")`). slangc is
    // resolved from an explicit `-Dslangc=` path, otherwise the prebuilt release
    // for this host is fetched lazily.
    if (!headless and !is_web) {
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
    if (!headless and !is_web) {
        const is_apple = target.result.os.tag == .macos or target.result.os.tag == .ios;
        if (!is_apple) {
            const vulkan_headers = b.dependency("vulkan_headers", .{});
            const registry = vulkan_headers.path("registry/vk.xml");
            if (b.lazyDependency("vma", .{
                .target = target,
                .optimize = optimize,
                .registry = vulkan_headers.path(""),
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
    }


    // Install vendored binaries

    b.installArtifact(lib);

    // The web backends are half Zig, half JS: `src/webgpu.zig` and
    // `src/webgl.zig` declare the imports, and the two glue files implement
    // them against `navigator.gpu` and a `webgl2` canvas context. `glue.js`
    // owns the probe that picks between them. Install both so a consumer can
    // serve them alongside their .wasm.
    if (is_web) {
        b.installFile("src/webgpu/glue.js", "web/glue.js");
        // Flat, not `web/webgl/glue.js`: glue.js imports it as a sibling.
        b.installFile("src/webgl/glue.js", "web/webgl_glue.js");
    }

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
