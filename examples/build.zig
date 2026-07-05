const std = @import("std");

/// One compiled shader stage: a Slang source + entry point + stage, emitted as
/// `<out>.spv` (Vulkan) and, on Apple targets, `<out>.metal` (Metal). The
/// examples load the artifact whose extension matches the active backend.
pub const ShaderStage = struct {
    src: []const u8,
    entry: []const u8,
    stage: []const u8, // "vertex" | "fragment" | "compute"
    out: []const u8,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The core RHI library. Forwarding target/optimize lets it select the
    // matching backend (Vulkan off Apple, Metal on Apple).
    const rhi_dep = b.dependency("rhi", .{
        .target = target,
        .optimize = optimize,
    });
    const rhi_module = rhi_dep.module("rhi");

    // Linear-algebra helpers for 04SVT's view/projection math. The pinned zla
    // revision gates its benchmark behind `b.isRoot()`, so consuming it as a
    // dependency here no longer pulls the `zbench` dev-dependency. Available to
    // every example module; only the ones that `@import("zla")` pull it in.
    const zla_module = b.dependency("zla", .{
        .target = target,
        .optimize = optimize,
    }).module("zla");

    const is_apple = target.result.os.tag == .macos or target.result.os.tag == .ios;

    // SDL is a lazy dependency so the workspace can build without compiling
    // SDL's transitive build graph.
    const sdl_dep = b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    const shaders_01 = [_]ShaderStage{
        .{ .src = "01_mandelbrot.slang", .entry = "vertexMain", .stage = "vertex", .out = "fullscreen.vert" },
        .{ .src = "01_mandelbrot.slang", .entry = "fragmentMain", .stage = "fragment", .out = "mandelbrot.frag" },
    };

    const sdl_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("sdl_includes.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_translate_c.addIncludePath(sdl_dep.path("include"));
    const sdl_c_module = sdl_translate_c.createModule();

    const shaders_02 = [_]ShaderStage{
        .{ .src = "02_mesh.slang", .entry = "vertexMain", .stage = "vertex", .out = "02_mesh.vert" },
        .{ .src = "02_mesh.slang", .entry = "fragmentMain", .stage = "fragment", .out = "02_mesh.frag" },
    };

    const shaders_04 = [_]ShaderStage{
        // Shared vertex stage + the final composite fragment stage.
        .{ .src = "04_svt.slang", .entry = "vertexMain", .stage = "vertex", .out = "04_svt.vert" },
        .{ .src = "04_svt.slang", .entry = "compositeMain", .stage = "fragment", .out = "04_svt_composite.frag" },
        // Feedback fragment stage (writes requested page ids into an SSBO).
        .{ .src = "04_svt_feedback.slang", .entry = "feedbackMain", .stage = "fragment", .out = "04_svt_feedback.frag" },
    };

    // `apple` marks examples that have been ported to the backend-agnostic API
    // and therefore build on macOS/iOS (Metal). The others are still Vulkan-only.
    const examples = [_]struct { file: []const u8, name: []const u8, shaders: []const ShaderStage = &.{}, apple: bool = false }{
        .{ .file = "00Clear.zig", .name = "00_clear", .apple = true },
        .{ .file = "01Shader.zig", .name = "01_shader", .shaders = shaders_01[0..], .apple = true },
        .{ .file = "02Mesh.zig", .name = "02_mesh", .shaders = shaders_02[0..], .apple = true },
        // ImGui shaders are embedded in the core rhi library; no shader step
        // here. Vulkan-only until the Metal texture/sampler path lands.
        .{ .file = "03Imgui.zig", .name = "03_imgui", .apple = false },
        // Software virtual texturing through the rpi layer. Vulkan-only: rpi's
        // name-resolved descriptor binding is not yet implemented on Metal.
        .{ .file = "04SVT.zig", .name = "04_svt", .shaders = shaders_04[0..], .apple = false },
    };
    // Resolve the Slang compiler used to build example shaders: an explicit
    // `-Dslangc=` path (e.g. the Vulkan SDK's), otherwise the prebuilt release
    // for this host — fetched lazily, so only the matching archive downloads.
    const slangc: std.Build.LazyPath = if (b.option([]const u8, "slangc", "Path to a slangc executable (skips the prebuilt Slang download)")) |p|
        .{ .cwd_relative = p }
    else slang: {
        // deps/slang resolves the prebuilt `slangc` for this host. `slangc()`
        // returns null on the first pass (triggers the archive fetch); the
        // build then re-runs with it available.
        const slang_pkg = b.lazyImport(@This(), "slang") orelse return;
        const slang_dep = b.lazyDependency("slang", .{}) orelse return;
        break :slang slang_pkg.slangc(slang_dep.builder) orelse return;
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
                    .{ .name = "rhi", .module = rhi_module },
                    .{ .name = "sdl", .module = sdl_c_module },
                    .{ .name = "zla", .module = zla_module },
                },
            }),
        });
        exe.root_module.linkLibrary(sdl_dep.artifact("SDL3"));

        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);
        const run_step = b.step(example.name, example.file);
        const example_cmd = b.addRunArtifact(exe);
        if (@hasField(std.Build, "args") and b.args != null) { // TODO: Remove after 0.17
            example_cmd.addArgs(b.args.?);
        }
        run_step.dependOn(&example_cmd.step);
        example_cmd.step.dependOn(&install_exe.step);
        for (example.shaders) |sh| {
            // Vulkan: Slang -> SPIR-V (always built; the rhi lib targets vk off Apple).
            const spv = std.Build.Step.Run.create(b, b.fmt("{s} slangc spirv", .{sh.out}));
            spv.addFileArg(slangc); // argv[0]: the resolved slangc binary
            spv.addFileArg(b.path(b.fmt("example_assets/{s}", .{sh.src})));
            spv.addArgs(&.{ "-target", "spirv", "-entry", sh.entry, "-stage", sh.stage, "-o" });
            spv.addArg(try b.root.joinString(b.allocator, b.fmt("example_assets/{s}.spv", .{sh.out})));
            exe.step.dependOn(&spv.step);

            // Metal: Slang -> MSL (Apple only). Compiled at runtime via newLibraryWithSource.
            if (is_apple) {
                const msl = std.Build.Step.Run.create(b, b.fmt("{s} slangc metal", .{sh.out}));
                msl.addFileArg(slangc);
                msl.addFileArg(b.path(b.fmt("example_assets/{s}", .{sh.src})));
                msl.addArgs(&.{ "-target", "metal", "-entry", sh.entry, "-stage", sh.stage, "-o" });
                msl.addArg(try b.root.joinString(b.allocator, b.fmt("example_assets/{s}.metal", .{sh.out})));
                exe.step.dependOn(&msl.step);
            }
        }
    }
}
