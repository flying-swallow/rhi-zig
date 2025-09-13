const std = @import("std");
// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("vma", .{});

    const module = b.addModule("vma", .{ .root_source_file = b.path("main.zig") });
    module.addIncludePath(upstream.path(""));

    const commonArgs = &[_][]const u8 { "-std=c++17" };
    //const releaseArgs = &[_][]const u8 { } ++ commonArgs ++ comptime getConfigArgs(vma_config.releaseConfig);
    //const debugArgs = &[_][]const u8 { } ++ commonArgs ++ comptime getConfigArgs(vma_config.debugConfig);
    //const args = if (mode == .Debug) debugArgs else releaseArgs;
    const lib = b.addLibrary(.{
        .name = "vma",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();
    lib.linkLibCpp(); 
    lib.addCSourceFile(.{
        .file = b.path("vma_impl.cpp"), 
        .flags = commonArgs 
    });
    lib.installHeadersDirectory(
        upstream.path("include"),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    b.installArtifact(lib);
}
