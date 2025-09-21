const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("vma", .{});

    const module = b.addModule("vma", .{ .root_source_file = b.path("main.zig") });
    module.addIncludePath(upstream.path(""));

    const commonArgs = &[_][]const u8 { "-std=c++17" };
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
