pub const sdl = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {}); // We are providing our own entry point
    @cInclude("SDL3/SDL_main.h");
});
const std = @import("std");

pub fn InitResult(comptime Context: anytype) type {
    return struct {
        result: sdl.SDL_AppResult,
        cntx: *Context,
    };
}

pub fn SdlApplicaton(comptime Context: anytype, handlers: struct {
            iterate_handler: fn (cntx: *Context) anyerror!sdl.SDL_AppResult,
            app_init: fn (argv: [][*:0]u8) anyerror!InitResult(Context),
            app_event: fn (cntx: *Context, event: *sdl.SDL_Event) anyerror!sdl.SDL_AppResult,
            app_quit: fn (cntx: *Context, result: sdl.SDL_AppResult) void,
        }) type {
    return struct {
        var context: ?*Context = null;
        
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
            const res = handlers.app_init(@ptrCast(argv.?[0..@intCast(argc)])) catch |err| {
                std.debug.print("Error in app init handler: {any}\n", .{err});
                return sdl.SDL_APP_FAILURE;
            };
            context = res.cntx;
            return res.result;
        }

        pub fn sdlAppIterateC(appstate: ?*anyopaque) callconv(.c) sdl.SDL_AppResult {
            _ = appstate;
            if(context) |ctx| {
                return handlers.iterate_handler(ctx) catch |err| {
                    std.debug.print("Error in iterate handler: {any}\n", .{err});
                    return sdl.SDL_APP_FAILURE;
                };
            } else {
                std.debug.print("Context is null in iterate handler\n", .{});
            }
            return sdl.SDL_APP_FAILURE;
        }

        fn sdlAppEventC(appstate: ?*anyopaque, event: ?*sdl.SDL_Event) callconv(.c) sdl.SDL_AppResult {
            _ = appstate;
            if(context) |ctx| {
                return handlers.app_event(ctx, event.?) catch |err| {
                    std.debug.print("Error in app event handler: {any}\n", .{err});
                    return sdl.SDL_APP_FAILURE;
                };
            } else {
                std.debug.print("Context is null in app event handler\n", .{});
            }
            return sdl.SDL_APP_FAILURE;
        }

        fn sdlAppQuitC(appstate: ?*anyopaque, result: sdl.SDL_AppResult) callconv(.c) void {
            _ = appstate;
            if(context) |ctx| {
                handlers.app_quit(ctx, result);
            } else {
                std.debug.print("Context is null in app quit handler\n", .{});
            }
        }

        fn sdlMainC(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
            return sdl.SDL_EnterAppMainCallbacks(argc, @ptrCast(argv), sdlAppInitC, sdlAppIterateC, sdlAppEventC, sdlAppQuitC);
        }

        pub fn exec() u8 {
            var empty_argv: [0:null]?[*:0]u8 = .{};
            const status: u8 = @truncate(@as(c_uint, @bitCast(sdl.SDL_RunApp(empty_argv.len, @ptrCast(&empty_argv), sdlMainC, null))));
            return status;
        }
    };
}

