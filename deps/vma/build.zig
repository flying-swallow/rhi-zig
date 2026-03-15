const std = @import("std");
pub fn build(b: *std.Build) void {
    const vulkan_registery = b.option(std.Build.LazyPath, "registry", "The Vulkan SDK");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("vma", .{});


    const module = b.addModule("vma", .{ .root_source_file = b.path("main.zig") });
    module.addIncludePath(upstream.path(""));

    const commonArgs = &[_][]const u8{"-std=c++17"};
    const root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    root_module.addCSourceFile(.{ .file = b.path("vma_impl.cpp"), .flags = commonArgs });
    root_module.addIncludePath(upstream.path("include"));
    if (vulkan_registery) |vk| {
        root_module.addIncludePath(vk.path(b, "include"));
    }
    const lib = b.addLibrary(.{
        .name = "vma",
        .root_module = root_module,
        .linkage = .static,
    });

    b.installArtifact(lib);
}
