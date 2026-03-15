const std = @import("std");
const builtin = @import("builtin");

const AssetType = enum { glsl };
pub const Asset = union(AssetType) {
    glsl: []const u8,
};

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
    
    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    if (b.lazyDependency("vma", .{
        .target = target,
        .optimize = optimize,
        .registry = registry 
    })) |vma_dep| {
        engine_module.addImport(
            "vma",
            vma_dep.module("vma"),
        );
        engine_module.linkLibrary(vma_dep.artifact("vma"));
    }

    const vulkan = b.dependency("vulkan", .{
        .registry = registry,
    }).module("vulkan-zig");
    engine_module.addImport("vulkan", vulkan);

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

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        //.preferred_linkage = .static,
        //.strip = null,
        //.sanitize_c = null,
        //.pic = null,
        //.lto = null,
        //.emscripten_pthreads = false,
        //.install_build_config_h = false,
    });

    const assets_shader_01 = [_]Asset{
        .{ .glsl = "mandelbrot.frag" },
        .{ .glsl = "fullscreen.vert" },
    };

    //const asset_02 = [_] Asset {
    //    .{ .glsl =  "02_mesh.vert" },
    //    .{ .glsl =  "02_mesh.frag" },
    //};

    const examples = [_]struct { file: []const u8, name: []const u8, assets: []const Asset = &.{} }{
        .{ .file = "examples/00Clear.zig", .name = "00_clear" },
        .{ .file = "examples/01Shader.zig", .name = "01_shader", .assets = assets_shader_01[0..] },
        .{ .file = "examples/02Mesh.zig", .name = "02_mesh" }, //, .assets = asset_02[0..] },
    };
    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "rhi", .module = engine_module },
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
        for (example.assets) |asset| {
            switch (asset) {
                .glsl => |val| {
                    const glslang_cmd = b.addSystemCommand(&.{"glslc"});
                    glslang_cmd.addFileArg(b.path(b.fmt("example_assets/{s}", .{val})));
                    glslang_cmd.addArg("-o");
                    glslang_cmd.addArg(try b.build_root.join(b.allocator, &.{ "example_assets", b.fmt("{s}.spv", .{val}) }));
                    glslang_cmd.step.name = b.fmt("{s} glslc", .{val});
                    exe.step.dependOn(&glslang_cmd.step);
                },
            }
        }
    }
}
