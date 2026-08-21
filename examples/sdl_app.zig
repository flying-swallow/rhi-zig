// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

pub const sdl = @import("sdl");
const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");

pub fn AppContext(comptime Context: type) type {
    return struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        frame_arean: std.heap.ArenaAllocator,
        inner: Context,
    };
}

pub fn sdl_window_handle_to_rhi_window_handle(window: *sdl.SDL_Window) !rhi.WindowHandle {
    // zig fmt: off
    if (builtin.os.tag == .windows) {
        return rhi.WindowHandle{ .win32 = .{
            .hinstance = sdl.SDL_GetPointerProperty(sdl.SDL_GetWindowProperties(window), sdl.SDL_PROP_WINDOW_WIN32_HINSTANCE_POINTER, null).?,
            .hwnd = sdl.SDL_GetPointerProperty(sdl.SDL_GetWindowProperties(window), sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null).?,
        } };
    } else if (builtin.os.tag == .linux) {
        if (std.mem.eql(u8, std.mem.sliceTo(sdl.SDL_GetCurrentVideoDriver(), 0), "x11")) {
            return rhi.WindowHandle{ .x11 = .{
                .display = sdl.SDL_GetPointerProperty(sdl.SDL_GetWindowProperties(window), sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null).?,
                .window = @intCast(sdl.SDL_GetNumberProperty(sdl.SDL_GetWindowProperties(window), sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0)),
            } };
        } else if (std.mem.eql(u8, std.mem.sliceTo(sdl.SDL_GetCurrentVideoDriver(), 0), "wayland")) {
            return rhi.WindowHandle { .wayland = .{ 
                .display = sdl.SDL_GetPointerProperty(sdl.SDL_GetWindowProperties(window), sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null).?, 
                .surface = sdl.SDL_GetPointerProperty(sdl.SDL_GetWindowProperties(window), sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null).?, 
                .shell_surface = null 
            } };
        }
    } else if (builtin.os.tag == .macos or builtin.os.tag == .ios) {
        // Create a Metal-backed view and hand its CAMetalLayer to the RHI.
        const view = sdl.SDL_Metal_CreateView(window);
        if (view == null) return error.SdlError;
        const layer = sdl.SDL_Metal_GetLayer(view) orelse return error.SdlError;
        return rhi.WindowHandle{ .metal = .{ .layer = layer } };
    }
    // zig fmt: on
    return error.SdlError;
}

/// Honor a `--video-driver <name>` / `--video-driver=<name>` command-line flag by
/// forcing SDL's video backend (e.g. `x11` so the example can be captured in
/// RenderDoc, which doesn't support Wayland). Must be called before `SDL_Init`.
/// Any SDL driver name is accepted; without the flag SDL auto-selects as usual.
fn applyVideoDriverArg(init: std.process.Init) void {
    // `iterateAllocator` compiles on every target (the allocator-free `iterate`
    // is a Windows compile error); on POSIX the allocation/deinit are trivial.
    var it = init.minimal.args.iterateAllocator(init.gpa) catch return;
    defer it.deinit();
    _ = it.next(); // skip the program name
    while (it.next()) |arg| {
        const driver: ?[:0]const u8 =
            if (std.mem.startsWith(u8, arg, "--video-driver="))
                arg["--video-driver=".len..] // tail of a [:0] slice keeps its sentinel
            else if (std.mem.eql(u8, arg, "--video-driver"))
                it.next()
            else
                null;
        if (driver) |name| {
            _ = sdl.SDL_SetHintWithPriority(sdl.SDL_HINT_VIDEO_DRIVER, name.ptr, sdl.SDL_HINT_OVERRIDE);
            std.log.info("Forcing SDL video driver: {s}", .{name});
        }
    }
}

pub fn SdlApplicaton(comptime Context: type, handlers: struct {
    iterate_handler: fn (cntx: *AppContext(Context)) anyerror!sdl.SDL_AppResult,
    app_init: fn (cntx: *AppContext(Context), argv: [][*:0]u8) anyerror!sdl.SDL_AppResult,
    app_event: fn (cntx: *AppContext(Context), event: *sdl.SDL_Event) anyerror!sdl.SDL_AppResult,
    app_quit: fn (cntx: *AppContext(Context), result: sdl.SDL_AppResult) void,
}) type {
    return struct {
        var context: AppContext(Context) = undefined;
        const Self = @This();

        fn sdlAppInitC(appstate: ?*?*anyopaque, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) sdl.SDL_AppResult {
            _ = appstate;
            {
                const version = sdl.SDL_GetVersion();
                std.log.info("SDL runtime version: {d}.{d}.{d}", .{
                    sdl.SDL_VERSIONNUM_MAJOR(version),
                    sdl.SDL_VERSIONNUM_MINOR(version),
                    sdl.SDL_VERSIONNUM_MICRO(version),
                });
                const revision: [*:0]const u8 = sdl.SDL_GetRevision();
                std.log.info("SDL runtime revision: {s}", .{revision});
            }
            return handlers.app_init(&context, @ptrCast(argv.?[0..@intCast(argc)])) catch |err| {
                std.debug.print("Error in app init handler: {any}\n", .{err});
                return sdl.SDL_APP_FAILURE;
            };
        }

        pub fn sdlAppIterateC(appstate: ?*anyopaque) callconv(.c) sdl.SDL_AppResult {
            _ = appstate;
            return handlers.iterate_handler(&context) catch |err| {
                std.debug.print("Error in iterate handler: {any}\n", .{err});
                return sdl.SDL_APP_FAILURE;
            };
        }

        fn sdlAppEventC(appstate: ?*anyopaque, event: ?*sdl.SDL_Event) callconv(.c) sdl.SDL_AppResult {
            _ = appstate;
            _ = context.frame_arean.reset(.retain_capacity);
            return handlers.app_event(&context, event.?) catch |err| {
                std.debug.print("Error in app event handler: {any}\n", .{err});
                return sdl.SDL_APP_FAILURE;
            };
        }

        fn sdlAppQuitC(appstate: ?*anyopaque, result: sdl.SDL_AppResult) callconv(.c) void {
            _ = appstate;
            handlers.app_quit(&context, result);
            context.frame_arean.deinit();
        }
        fn sdlEventWatcher(appstate: ?*anyopaque, event: [*c]sdl.SDL_Event) callconv(.c) bool {
            _ = appstate;
            // During a live window resize SDL_PumpEvents can block for up to ~1s
            // inside a single SDL_PollEvent, freezing our owned loop — so the only
            // chance to draw a frame is from this watch, which SDL dispatches
            // synchronously as it pumps.
            //
            // Render ONLY on SDL_EVENT_WINDOW_EXPOSED: SDL documents it as "should be
            // redrawn, and can be redrawn directly from event watchers", and the
            // compositor throttles it to the refresh cadence. Do NOT render on
            // RESIZED/PIXEL_SIZE_CHANGED — those stream in per compositor configure,
            // and drawing a full vsync-blocked frame (+ swapchain recreate) on each
            // one stalls the pump so it can't ack the next configure, making the
            // window lag behind the cursor. iterate_handler already polls the current
            // window size and rebuilds the swapchain, so the next EXPOSED renders the
            // latest size regardless.
            if (event.*.type == sdl.SDL_EVENT_WINDOW_EXPOSED) {
                _ = handlers.iterate_handler(&context) catch |err| {
                    std.debug.print("Error in iterate handler: {any}\n", .{err});
                };
            }
            // Watch callbacks' return value is ignored by SDL; return true.
            return true;
        }

        fn sdlMainC(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
            // Drive the app with an explicit loop instead of
            // SDL_EnterAppMainCallbacks: under the callback model SDL_PumpEvents
            // blocks for up to ~1s between iterate calls during a Wayland
            // interactive resize, starving rendering. Owning the loop and pumping
            // with non-blocking SDL_PollEvent keeps the render cadence under our
            // control. (SDL_RunApp still wraps this for platform bootstrapping.)
            const init_rc = sdlAppInitC(null, argc, argv);
            if (init_rc != sdl.SDL_APP_CONTINUE) {
                sdlAppQuitC(null, init_rc);
                return if (init_rc == sdl.SDL_APP_FAILURE) 1 else 0;
            }
            _ = sdl.SDL_AddEventWatch(sdlEventWatcher, null);
            var result: sdl.SDL_AppResult = sdl.SDL_APP_CONTINUE;
            loop: while (result == sdl.SDL_APP_CONTINUE) {
                var event: sdl.SDL_Event = undefined;
                while (sdl.SDL_PollEvent(&event)) {
                    const er = sdlAppEventC(null, &event);
                    if (er != sdl.SDL_APP_CONTINUE) {
                        result = er;
                        continue :loop;
                    }
                }
                result = sdlAppIterateC(null);
            }
            sdlAppQuitC(null, result);
            return if (result == sdl.SDL_APP_FAILURE) 1 else 0;
        }

        pub fn exec(init: std.process.Init) u8 {
            context.io = init.io;
            context.gpa = init.gpa;
            context.frame_arean = std.heap.ArenaAllocator.init(context.gpa);

            // Optional: force the SDL video driver (e.g. `--video-driver x11` to
            // run under RenderDoc, which doesn't support Wayland). Must happen
            // before SDL_Init, which the app_init handler calls.
            applyVideoDriverArg(init);

            var empty_argv: [0:null]?[*:0]u8 = .{};
            const status: u8 = @truncate(@as(c_uint, @bitCast(sdl.SDL_RunApp(empty_argv.len, @ptrCast(&empty_argv), sdlMainC, null))));
            return status;
        }
    };
}

// ---------------------------------------------------------------------------
// Common platform API
//
// The same surface `web_app.zig` exposes, so examples 00-02 can be written
// against `platform.zig` and built for either the desktop (SDL) or the browser
// (WebGPU on a canvas). This is additive: `SdlApplicaton` above is unchanged
// and still drives `03_imgui` / `04_svt`.
// ---------------------------------------------------------------------------

/// What an example's handlers report back. Maps onto `SDL_AppResult`.
pub const AppResult = enum(u8) { cont, success, failure };

pub const Window = sdl.SDL_Window;
pub const Event = sdl.SDL_Event;

pub fn window_handle(window: *Window) !rhi.WindowHandle {
    return sdl_window_handle_to_rhi_window_handle(window);
}

pub fn window_size_in_pixels(window: *Window, out_w: *c_int, out_h: *c_int) bool {
    return sdl.SDL_GetWindowSizeInPixels(window, out_w, out_h);
}

pub fn perf_counter() u64 {
    return sdl.SDL_GetPerformanceCounter();
}

pub fn perf_frequency() u64 {
    return sdl.SDL_GetPerformanceFrequency();
}

/// Milliseconds since startup.
pub fn ticks_ms() u64 {
    return sdl.SDL_GetTicks();
}

/// `std.log` needs no redirection on a desktop target; this exists so
/// `platform.zig` can name the same symbol on both.
pub const logFn = std.log.defaultLog;

/// Window creation moves into the harness (the web has no window to create), so
/// the title and initial size are declared with the handlers.
pub fn Application(comptime Context: type, handlers: struct {
    title: [:0]const u8,
    width: u32 = 640,
    height: u32 = 480,
    iterate_handler: fn (cntx: *AppContext(Context)) anyerror!AppResult,
    app_init: fn (cntx: *AppContext(Context), window: *Window) anyerror!AppResult,
    app_event: fn (cntx: *AppContext(Context), event: *Event) anyerror!AppResult,
    app_quit: fn (cntx: *AppContext(Context), result: AppResult) void,
}) type {
    return struct {
        var context: AppContext(Context) = undefined;
        var window: *Window = undefined;
        const Self = @This();

        /// Nothing to emit off the web. Referencing it from an example
        /// (`comptime { _ = App.web_exports; }`) is a no-op here.
        pub const web_exports = struct {};

        fn iterate() AppResult {
            return handlers.iterate_handler(&context) catch |err| {
                std.log.err("iterate failed: {t}", .{err});
                return .failure;
            };
        }

        fn eventWatcher(appstate: ?*anyopaque, event: [*c]sdl.SDL_Event) callconv(.c) bool {
            _ = appstate;
            // See the note on `sdlEventWatcher` above: during a live Wayland
            // resize SDL_PumpEvents can block for ~1s, and EXPOSED is the only
            // chance to draw.
            if (event.*.type == sdl.SDL_EVENT_WINDOW_EXPOSED) _ = iterate();
            return true;
        }

        fn mainC(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
            _ = argc;
            _ = argv;
            if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
                std.log.err("SDL_Init failed", .{});
                return 1;
            }
            const w = sdl.SDL_CreateWindow(handlers.title, @intCast(handlers.width), @intCast(handlers.height), sdl.SDL_WINDOW_RESIZABLE) orelse {
                std.log.err("SDL_CreateWindow failed", .{});
                return 1;
            };
            window = w;
            defer sdl.SDL_DestroyWindow(window);

            const init_rc = handlers.app_init(&context, window) catch |err| {
                std.log.err("app_init failed: {t}", .{err});
                return 1;
            };
            if (init_rc != .cont) {
                handlers.app_quit(&context, init_rc);
                return if (init_rc == .failure) 1 else 0;
            }
            _ = sdl.SDL_AddEventWatch(eventWatcher, null);

            var result: AppResult = .cont;
            loop: while (result == .cont) {
                var event: sdl.SDL_Event = undefined;
                while (sdl.SDL_PollEvent(&event)) {
                    if (event.type == sdl.SDL_EVENT_QUIT) {
                        result = .success;
                        continue :loop;
                    }
                    _ = context.frame_arean.reset(.retain_capacity);
                    const er = handlers.app_event(&context, &event) catch |err| {
                        std.log.err("app_event failed: {t}", .{err});
                        result = .failure;
                        continue :loop;
                    };
                    if (er != .cont) {
                        result = er;
                        continue :loop;
                    }
                }
                result = iterate();
            }
            handlers.app_quit(&context, result);
            context.frame_arean.deinit();
            return if (result == .failure) 1 else 0;
        }

        pub fn exec(init: std.process.Init) u8 {
            context.io = init.io;
            context.gpa = init.gpa;
            context.frame_arean = std.heap.ArenaAllocator.init(context.gpa);
            applyVideoDriverArg(init);
            var empty_argv: [0:null]?[*:0]u8 = .{};
            const status = sdl.SDL_RunApp(empty_argv.len, @ptrCast(&empty_argv), mainC, null);
            return @truncate(@as(c_uint, @bitCast(status)));
        }
    };
}
