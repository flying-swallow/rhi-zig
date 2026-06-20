const std = @import("std");
pub fn build(b: *std.Build) void {
    const vulkan_registery = b.option(std.Build.LazyPath, "registry", "The Vulkan SDK");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upstream = b.dependency("vma", .{});


    const translate_c = b.addTranslateC(.{
        .root_source_file = upstream.path("include/vk_mem_alloc.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(upstream.path("include"));
    if (vulkan_registery) |vk| {
        translate_c.addIncludePath(vk.path(b, "include"));
    }
    const c_module = translate_c.createModule();

    const module = b.addModule("vma", .{ .root_source_file = b.path("main.zig") });
    module.addImport("c", c_module);
    module.addIncludePath(upstream.path("include"));

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
