const std = @import("std");
const builtin = @import("builtin");

/// One compiled shader stage: a Slang source + entry point + stage, emitted as
/// `<out>.spv` (Vulkan) and, on Apple targets, `<out>.metal` (Metal). The
/// examples load the artifact whose extension matches the active backend.
pub const ShaderStage = struct {
    src: []const u8,
    entry: []const u8,
    stage: []const u8, // "vertex" | "fragment" | "compute"
    out: []const u8,
};

/// The `build.zig.zon` dependency name for the prebuilt Slang compiler matching
/// the build host (shaders are compiled on the host, not the target), or null
/// if no prebuilt is shipped for this host.
fn slangHostDep() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "slang_linux_x86_64",
            .aarch64 => "slang_linux_aarch64",
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "slang_macos_x86_64",
            .aarch64 => "slang_macos_aarch64",
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "slang_windows_x86_64",
            .aarch64 => "slang_windows_aarch64",
            else => null,
        },
        else => null,
    };
}

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

    // The examples need SDL for windowing. SDL can be skipped (e.g. to build
    // just the library, or to avoid a toolchain-incompatible transitive SDL
    // dependency) with `-Dskip_examples`.
    const skip_examples = b.option(bool, "skip_examples", "Do not build the SDL examples") orelse false;
    if (skip_examples) return;

    // SDL is a lazy dependency so the rest of the workspace (and the library)
    // can build without compiling SDL's transitive build graph.
    const sdl_dep = b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    const shaders_01 = [_]ShaderStage{
        .{ .src = "01_mandelbrot.slang", .entry = "vertexMain", .stage = "vertex", .out = "fullscreen.vert" },
        .{ .src = "01_mandelbrot.slang", .entry = "fragmentMain", .stage = "fragment", .out = "mandelbrot.frag" },
    };

    const sdl_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("examples/sdl_includes.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_translate_c.addIncludePath(sdl_dep.path("include"));
    const sdl_c_module = sdl_translate_c.createModule();

    const shaders_02 = [_]ShaderStage{
        .{ .src = "02_mesh.slang", .entry = "vertexMain", .stage = "vertex", .out = "02_mesh.vert" },
        .{ .src = "02_mesh.slang", .entry = "fragmentMain", .stage = "fragment", .out = "02_mesh.frag" },
    };

    // `apple` marks examples that have been ported to the backend-agnostic API
    // and therefore build on macOS/iOS (Metal). The others are still Vulkan-only.
    const examples = [_]struct { file: []const u8, name: []const u8, shaders: []const ShaderStage = &.{}, apple: bool = false }{
        .{ .file = "examples/00Clear.zig", .name = "00_clear", .apple = true },
        .{ .file = "examples/01Shader.zig", .name = "01_shader", .shaders = shaders_01[0..], .apple = true },
        .{ .file = "examples/02Mesh.zig", .name = "02_mesh", .shaders = shaders_02[0..], .apple = true },
    };
    // Resolve the Slang compiler used to build example shaders: an explicit
    // `-Dslangc=` path (e.g. the Vulkan SDK's), otherwise the prebuilt release
    // for this host — fetched lazily, so only the matching archive downloads.
    const slangc: std.Build.LazyPath = if (b.option([]const u8, "slangc", "Path to a slangc executable (skips the prebuilt Slang download)")) |p|
        .{ .cwd_relative = p }
    else slang: {
        const dep_name = slangHostDep() orelse {
            std.log.err("no prebuilt slangc for this host; pass -Dslangc=/path/to/slangc", .{});
            return error.UnsupportedSlangHost;
        };
        // Returns null on the first pass (triggers the fetch); the build then
        // re-runs with the archive available.
        const slang_dep = b.lazyDependency(dep_name, .{}) orelse return;
        break :slang slang_dep.path("bin/slangc" ++ if (builtin.os.tag == .windows) ".exe" else "");
    };

    for (examples) |example| {
        if (is_apple and !example.apple) continue;
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "rhi", .module = engine_module },
                    .{ .name = "sdl", .module = sdl_c_module },
                },
            }),
        });
        exe.root_module.linkLibrary(sdl_dep.artifact("SDL3"));

        b.installArtifact(exe);
        const run_step = b.step(example.name, example.file);
        const example_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            example_cmd.addArgs(args);
        }
        run_step.dependOn(&example_cmd.step);
        example_cmd.step.dependOn(b.getInstallStep());
        for (example.shaders) |sh| {
            // Vulkan: Slang -> SPIR-V (always built; the rhi lib targets vk off Apple).
            const spv = std.Build.Step.Run.create(b, b.fmt("{s} slangc spirv", .{sh.out}));
            spv.addFileArg(slangc); // argv[0]: the resolved slangc binary
            spv.addFileArg(b.path(b.fmt("example_assets/{s}", .{sh.src})));
            spv.addArgs(&.{ "-target", "spirv", "-entry", sh.entry, "-stage", sh.stage, "-o" });
            spv.addArg(try b.build_root.join(b.allocator, &.{ "example_assets", b.fmt("{s}.spv", .{sh.out}) }));
            exe.step.dependOn(&spv.step);

            // Metal: Slang -> MSL (Apple only). Compiled at runtime via newLibraryWithSource.
            if (is_apple) {
                const msl = std.Build.Step.Run.create(b, b.fmt("{s} slangc metal", .{sh.out}));
                msl.addFileArg(slangc);
                msl.addFileArg(b.path(b.fmt("example_assets/{s}", .{sh.src})));
                msl.addArgs(&.{ "-target", "metal", "-entry", sh.entry, "-stage", sh.stage, "-o" });
                msl.addArg(try b.build_root.join(b.allocator, &.{ "example_assets", b.fmt("{s}.metal", .{sh.out}) }));
                exe.step.dependOn(&msl.step);
            }
        }
    }
}
