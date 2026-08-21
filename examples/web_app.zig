// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Web harness for the examples — the `sdl_app.zig` counterpart for
//! `wasm32-freestanding` + WebGPU.
//!
//! This is separate code rather than a port because the two drive frames in
//! opposite directions. `sdl_app.zig` owns a blocking `while` loop and pumps
//! events inside it; on the web that would hang the browser's event loop
//! forever, and `getCurrentTexture` would never advance. Here the *browser*
//! owns the loop: `src/webgpu/glue.js` calls `rhi_web_frame` once per
//! `requestAnimationFrame` and the harness returns immediately.
//!
//! Both modules expose the same small platform API (see `platform.zig`), so an
//! example's body is the same on either.

const builtin = @import("builtin");
const std = @import("std");
const rhi = @import("rhi");

/// What an example's handlers report back. Mirrors `SDL_AppResult` without
/// depending on SDL.
pub const AppResult = enum(u8) { cont, success, failure };

/// There is no window on the web, only a canvas. The selector is handed in by
/// the glue at startup, and the size is whatever the glue measured for this
/// frame (CSS size times device pixel ratio).
pub const Window = struct {
    selector: []const u8 = "#canvas",
    width: u32 = 0,
    height: u32 = 0,
};

/// The web dispatches no events: there is no quit, and resizes are observed by
/// polling the canvas size each frame, exactly as the examples already do for
/// their native windows. The type exists so an example's `app_event` handler
/// keeps the same signature on both platforms.
pub const Event = struct {
    pub const Type = enum { none };
    type: Type = .none,
};

pub fn AppContext(comptime Context: type) type {
    return struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        frame_arean: std.heap.ArenaAllocator,
        inner: Context,
    };
}

pub fn window_handle(window: *Window) !rhi.WindowHandle {
    return rhi.WindowHandle{ .canvas = .{ .selector = window.selector } };
}

pub fn window_size_in_pixels(window: *Window, out_w: *c_int, out_h: *c_int) bool {
    out_w.* = @intCast(window.width);
    out_h.* = @intCast(window.height);
    return window.width > 0 and window.height > 0;
}

/// The high-resolution timestamp requestAnimationFrame handed the glue for this
/// frame, in milliseconds since page load.
var frame_time_ms: f64 = 0;

/// Milliseconds are this counter's unit, hence the frequency below.
pub fn perf_counter() u64 {
    return @intFromFloat(frame_time_ms);
}

pub fn perf_frequency() u64 {
    return 1000;
}

/// Milliseconds since startup — the `SDL_GetTicks` equivalent.
pub fn ticks_ms() u64 {
    return @intFromFloat(frame_time_ms);
}

/// Log level values must match the `wgpu_log` switch in glue.js.
fn logLevel(comptime level: std.log.Level) u32 {
    return switch (level) {
        .debug => 0,
        .info => 1,
        .warn => 2,
        .err => 3,
    };
}

/// Routes `std.log` to the browser console. Without this, `wasm32-freestanding`
/// has nowhere to write and every diagnostic is silently dropped.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [1024]u8 = undefined;
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const msg = std.fmt.bufPrint(&buf, prefix ++ format, args) catch blk: {
        // A message longer than the buffer is truncated rather than dropped.
        break :blk buf[0..];
    };
    rhi.webgpu.wgpu_log(logLevel(level), msg.ptr, @intCast(msg.len));
}

/// Routes panics to the browser console before trapping. The default panic
/// handler on freestanding wasm produces an unreachable trap with no message.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, first_trace_addr: ?usize) noreturn {
        _ = first_trace_addr;
        rhi.webgpu.wgpu_log(3, msg.ptr, @intCast(msg.len));
        @trap();
    }
}.f);

/// Scratch buffer the glue writes the canvas selector into before calling
/// `rhi_web_init`. Freed once the swapchain has copied what it needs.
var selector_storage: [256]u8 = undefined;

pub fn Application(comptime Context: type, handlers: struct {
    /// Unused on the web — the page's <title> and the canvas size come from the
    /// HTML. Present so the handler struct matches `sdl_app.Application`.
    title: [:0]const u8,
    width: u32 = 640,
    height: u32 = 480,
    iterate_handler: fn (cntx: *AppContext(Context)) anyerror!AppResult,
    app_init: fn (cntx: *AppContext(Context), window: *Window) anyerror!AppResult,
    app_event: fn (cntx: *AppContext(Context), event: *Event) anyerror!AppResult,
    app_quit: fn (cntx: *AppContext(Context), result: AppResult) void,
}) type {
    return struct {
        const Self = @This();
        var context: AppContext(Context) = undefined;
        var window: Window = .{};
        var live: bool = false;

        /// Referenced from the example with `comptime { _ = App.web_exports; }`
        /// so the symbols are emitted. `export` inside a generic type only
        /// reaches the binary if the namespace is referenced.
        pub const web_exports = struct {
            /// Gives the glue a scratch pointer to write the canvas selector
            /// into. `len` is bounded by `selector_storage`.
            export fn rhi_web_alloc(len: u32) [*]u8 {
                std.debug.assert(len <= selector_storage.len);
                return &selector_storage;
            }

            export fn rhi_web_init(selector_ptr: [*]const u8, selector_len: u32) i32 {
                context.gpa = std.heap.page_allocator;
                context.frame_arean = std.heap.ArenaAllocator.init(context.gpa);
                // There is no filesystem on freestanding wasm, so nothing that
                // runs here may touch `io`. The web examples `@embedFile` their
                // shaders instead of reading them.
                context.io = undefined;
                window = .{ .selector = selector_ptr[0..selector_len] };

                const rc = handlers.app_init(&context, &window) catch |err| {
                    std.log.err("app_init failed: {t}", .{err});
                    return 1;
                };
                if (rc != .cont) return 1;
                live = true;
                return 0;
            }

            /// Called once per requestAnimationFrame with the canvas backing
            /// store size the glue just applied and the callback's
            /// high-resolution timestamp. Returns non-zero to stop the loop.
            export fn rhi_web_frame(width: u32, height: u32, time_ms: f64) i32 {
                if (!live) return 1;
                window.width = width;
                window.height = height;
                frame_time_ms = time_ms;
                _ = context.frame_arean.reset(.retain_capacity);

                const rc = handlers.iterate_handler(&context) catch |err| {
                    std.log.err("iterate failed: {t}", .{err});
                    return 1;
                };
                return if (rc == .cont) 0 else 1;
            }

            export fn rhi_web_deinit() void {
                if (!live) return;
                live = false;
                handlers.app_quit(&context, .success);
                context.frame_arean.deinit();
            }
        };
    };
}
