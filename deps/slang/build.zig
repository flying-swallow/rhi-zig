const std = @import("std");
const builtin = @import("builtin");

// Required to exist; nothing to build — this package only exposes helpers.
pub fn build(b: *std.Build) void {
    _ = b;
}

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

/// Resolve the prebuilt `slangc` for the build host, fetching the matching
/// archive lazily. Returns null while the archive is still being fetched (the
/// build then re-runs), matching `lazyDependency` semantics. Call with the
/// slang package's own builder (`dep.builder`). Fatally errors if the host has
/// no prebuilt — callers should provide `-Dslangc=` in that case.
pub fn slangc(b: *std.Build) ?std.Build.LazyPath {
    const dep_name = slangHostDep() orelse {
        std.log.err("no prebuilt slangc for this host; pass -Dslangc=/path/to/slangc", .{});
        std.process.exit(1);
    };
    const dep = b.lazyDependency(dep_name, .{}) orelse return null;
    return dep.path("bin/slangc" ++ if (builtin.os.tag == .windows) ".exe" else "");
}
