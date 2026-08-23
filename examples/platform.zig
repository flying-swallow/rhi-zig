// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Selects the example harness for the target: SDL on the desktop, the browser
//! on WebAssembly. Both modules expose the same surface (`AppResult`, `Window`,
//! `Event`, `AppContext`, `window_handle`, `window_size_in_pixels`,
//! `perf_counter`, `perf_frequency`, `logFn`, `Application`), so an example's
//! body does not branch on the platform.
//!
//! WebGPU is web-only (see `src/root.zig`), so this is also what decides which
//! RHI backend an example runs on.

const builtin = @import("builtin");

pub const impl = if (builtin.cpu.arch.isWasm())
    @import("./web_app.zig")
else
    @import("./sdl_app.zig");

pub const AppResult = impl.AppResult;
pub const Window = impl.Window;
pub const Event = impl.Event;
pub const AppContext = impl.AppContext;
pub const window_handle = impl.window_handle;
pub const window_size_in_pixels = impl.window_size_in_pixels;
pub const perf_counter = impl.perf_counter;
pub const perf_frequency = impl.perf_frequency;
pub const ticks_ms = impl.ticks_ms;
pub const logFn = impl.logFn;
/// Only meaningful on the web; `web_root.zig` installs it as the panic handler.
pub const panic = if (builtin.cpu.arch.isWasm()) impl.panic else {};
pub const Application = impl.Application;

const std = @import("std");
const rhi = @import("rhi");

/// Brings up the renderer with the backend this target actually has. Written as
/// a function rather than a config constant because `Renderer.init` takes an
/// anonymous tagged union, which a stored struct literal will not coerce to.
pub fn init_renderer(gpa: std.mem.Allocator) !void {
    if (comptime builtin.cpu.arch.isWasm()) {
        // WebGPU first, WebGL2 as the fallback. The glue has already decided
        // which one it could set up — it only requests a `webgl2` context when
        // WebGPU is unusable, since a canvas hands out one context type — so
        // this just follows its lead. WebGL2 needs no browser flags, where
        // WebGPU is still gated on Linux Chrome.
        rhi.Renderer.init(gpa, .{ .wgpu = .{} }) catch |err| switch (err) {
            error.WebGPUAdapterUnavailable => try rhi.Renderer.init(gpa, .{ .webgl = .{} }),
            else => return err,
        };
    } else if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
        try rhi.Renderer.init(gpa, .{ .mtl = .{} });
    } else {
        try rhi.Renderer.init(gpa, .{ .vk = .{ .app_name = "GraphicsKernel", .enable_validation_layer = true } });
    }
}
