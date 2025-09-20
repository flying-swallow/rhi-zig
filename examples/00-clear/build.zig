const std = @import("std");

pub fn glslang_step(b: *std.Build, name: []const u8, input_shader: std.Build.LazyPath) !*std.Build.Step.Run {
    const glslang_cmd = b.addSystemCommand(&.{"glslc"});
    glslang_cmd.addFileArg(input_shader);
    glslang_cmd.addArg("-o");
    glslang_cmd.addArg(try b.build_root.join(b.allocator, &.{"src", "spv",b.fmt("{s}.spv", .{name})}));
    glslang_cmd.step.name = b.fmt("{s} glslc", .{name});
    return glslang_cmd;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const rhi_dep = b.dependency("rhi", .{});
    const rhi = rhi_dep.module("rhi");
    const core_dep = b.dependency("core", .{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rhi", .module = rhi},
            .{ .name = "core", .module = core_dep.module("core")}
        },
    });

    const exe = b.addExecutable(.{
        .name = "_00_clear",
        .root_module = root_module
    });
    
    //exe.step.dependOn(&(try glslang_step(b, "opaque.frag", b.path("assets/opaque.frag"))).step);
    //exe.step.dependOn(&(try glslang_step(b, "opaque.vert", b.path("assets/opaque.vert"))).step);                 

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
