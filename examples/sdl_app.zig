pub const sdl = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {}); // We are providing our own entry point
    @cInclude("SDL3/SDL_main.h");
});
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

    }
    // zig fmt: on
    return error.SdlError;
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

        fn sdlMainC(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
            return sdl.SDL_EnterAppMainCallbacks(argc, @ptrCast(argv), sdlAppInitC, sdlAppIterateC, sdlAppEventC, sdlAppQuitC);
        }

        pub fn exec(init: std.process.Init) u8 {
            context.io = init.io;
            context.gpa = init.gpa;
            context.frame_arean = std.heap.ArenaAllocator.init(context.gpa);

            var empty_argv: [0:null]?[*:0]u8 = .{};
            const status: u8 = @truncate(@as(c_uint, @bitCast(sdl.SDL_RunApp(empty_argv.len, @ptrCast(&empty_argv), sdlMainC, null))));
            return status;
        }
    };
}
