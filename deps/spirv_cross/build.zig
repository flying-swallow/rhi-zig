const std = @import("std");

/// Builds `spirv_cross_tool`, a build-time translator from SPIR-V to GLSL ES.
///
/// Unlike `deps/vma`, this produces a **host executable**, not a library for the
/// target: it runs during the build to preprocess shaders, so it must be built
/// for whatever machine is running the build, not for wasm.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("spirv_cross", .{});

    const root_module = b.createModule(.{
        // Host, not `standardTargetOptions`: this binary is run by the build.
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Only the GLSL backend's translation units. The upstream CLI additionally
    // pulls in the MSL/HLSL/C++/reflection backends, none of which are wanted.
    const sources = [_][]const u8{
        "spirv_cross.cpp",
        "spirv_cross_parsed_ir.cpp",
        "spirv_parser.cpp",
        "spirv_cfg.cpp",
        "spirv_glsl.cpp",
    };
    for (sources) |src| {
        root_module.addCSourceFile(.{
            .file = upstream.path(src),
            .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
        });
    }
    root_module.addCSourceFile(.{
        .file = b.path("spirv_cross_tool.cpp"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
    root_module.addIncludePath(upstream.path("."));

    const exe = b.addExecutable(.{ .name = "spirv_cross_tool", .root_module = root_module });
    b.installArtifact(exe);
}
