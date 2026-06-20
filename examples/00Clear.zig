const builtin = @import("builtin");
const std = @import("std");
const rhi = @import("rhi");
const sdl_app = @import("./sdl_app.zig");

const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });
pub const Context = struct {
    window: *sdl_app.sdl.SDL_Window = undefined,
    swapchain: rhi.Swapchain = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    dirty_resize: bool = false,
    graphics_cmd_ring: CmdRingBuffer = undefined,
};

fn iterate_handler(app_context: *sdl_app.AppContext(Context)) anyerror!sdl_app.sdl.SDL_AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}

    if (@atomicRmw(bool, &cntx.dirty_resize, .Xchg, false, .monotonic) == true) {
        var w: c_int = 0;
        var h: c_int = 0;
        if (sdl_app.sdl.SDL_GetWindowSize(cntx.window, &w, &h)) {
            _ = try cntx.swapchain.resize(&cntx.device, @intCast(w), @intCast(h));
        } else {
            std.log.err("{s}", .{sdl_app.sdl.SDL_GetError()});
        }
    }

    cntx.graphics_cmd_ring.advance();
    const swapchain_index = try cntx.swapchain.acquire_next_image(&cntx.device);
    var ring_element = cntx.graphics_cmd_ring.get(&cntx.device,1);
    try ring_element.wait(&cntx.device); // Wait for the GPU to finish with this command buffer

    try ring_element.pool.reset(&cntx.device); // Reset the pool (which also resets the command buffers)
    var cmd = &ring_element.cmds[0];
    try cmd.begin(&cntx.device);

    var img = cntx.swapchain.image(swapchain_index);
    const view = cntx.swapchain.image_view(swapchain_index);
    const w = cntx.swapchain.width;
    const h = cntx.swapchain.height;

    // undefined -> color_attachment (real on Vulkan, no-op on Metal)
    cmd.image_barrier(&cntx.device,.{
        .image = &img,
        .before = .{},
        .after = .{ .render_target = true },
    });

    cmd.begin_rendering(&cntx.device,.{
        .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ 0.1, 0.2, 0.4, 1.0 },
        }},
        .render_area = .{ .width = w, .height = h },
    });

    // Four quadrant clears (Vulkan sub-rect clears; on Metal the load-action
    // clear above fills the whole drawable).
    cmd.clear_attachment_regions(&cntx.device,.{ .regions = &.{
        .{ .color = .{ 0.0, 0.0, 0.0, 1.0 }, .rect = .{ .x = 0, .y = 0, .width = w / 2, .height = h / 2 } },
        .{ .color = .{ 1.0, 0.0, 0.0, 1.0 }, .rect = .{ .x = @intCast(w / 2), .y = 0, .width = w / 2, .height = h / 2 } },
        .{ .color = .{ 0.0, 1.0, 0.0, 1.0 }, .rect = .{ .x = 0, .y = @intCast(h / 2), .width = w / 2, .height = h / 2 } },
        .{ .color = .{ 0.0, 0.0, 1.0, 1.0 }, .rect = .{ .x = @intCast(w / 2), .y = @intCast(h / 2), .width = w / 2, .height = h / 2 } },
    } });

    cmd.end_rendering(&cntx.device);

    // color_attachment -> present (real on Vulkan, no-op on Metal)
    cmd.image_barrier(&cntx.device,.{
        .image = &img,
        .before = .{ .render_target = true },
        .after = .{ .present = true },
    });

    try cntx.swapchain.frame_submit(&cntx.device, &cntx.device.graphics_queue, .{
        .image_index = swapchain_index,
        .ring_element = &ring_element,
        .cmd = cmd,
    });

    cntx.timekeeper.produce(sdl_app.sdl.SDL_GetPerformanceCounter());
    return sdl_app.sdl.SDL_APP_CONTINUE;
}

fn app_init(app_context: *sdl_app.AppContext(Context), argv: [][*:0]u8) anyerror!sdl_app.sdl.SDL_AppResult {
    _ = argv;
    var cntx: *Context = &app_context.inner;
    if (sdl_app.sdl.SDL_SetAppMetadata("Tabletop", "0.0.0", "tabletop") == false) {
        return error.SetAppMetadataFailed;
    }
    if (sdl_app.sdl.SDL_Init(sdl_app.sdl.SDL_INIT_VIDEO) == false) {
        return error.SDLInitFailed;
    }

    const window = sdl_app.sdl.SDL_CreateWindow("00-helloworld", 640, 480, sdl_app.sdl.SDL_WINDOW_RESIZABLE);
    if (window == null) return error.CreateWindowFailed;
    errdefer sdl_app.sdl.SDL_DestroyWindow(window);

    const window_handle = try sdl_app.sdl_window_handle_to_rhi_window_handle(window.?);
    try rhi.Renderer.init(app_context.gpa, if (is_apple)
        .{ .mtl = .{} }
    else
        .{ .vk = .{ .app_name = "GraphicsKernel", .enable_validation_layer = true } });
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(app_context.gpa);
    defer adapters.deinit(app_context.gpa);

    const selected_adapter_index = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    var device = try rhi.Device.init(app_context.gpa, &adapters.items[selected_adapter_index]);
    const swapchain = try rhi.Swapchain.init(app_context.gpa, &device, 640, 480, window_handle, .{});

    cntx.window = window.?;
    cntx.swapchain = swapchain;
    cntx.device = device;
    cntx.timekeeper = .{ .tocks_per_s = sdl_app.sdl.SDL_GetPerformanceFrequency() };
    cntx.dirty_resize = false;
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.device,&cntx.device.graphics_queue);
    return sdl_app.sdl.SDL_APP_CONTINUE;
}

fn app_quit(app_context: *sdl_app.AppContext(Context), result: sdl_app.sdl.SDL_AppResult) void {
    var cntx: *Context = &app_context.inner;
    cntx.device.graphics_queue.wait_queue_idle(&cntx.device) catch |err| {
        std.log.err("Failed to wait graphics queue idle: {}", .{err});
    };

    cntx.graphics_cmd_ring.deinit(&cntx.device);
    cntx.swapchain.deinit(&cntx.device);
    cntx.device.deinit();
    rhi.Renderer.deinit();
    std.debug.print("App quit called with result: {any}\n", .{result});
}

fn app_event(app_context: *sdl_app.AppContext(Context), event: *sdl_app.sdl.SDL_Event) anyerror!sdl_app.sdl.SDL_AppResult {
    switch (event.type) {
        sdl_app.sdl.SDL_EVENT_QUIT => {
            return sdl_app.sdl.SDL_APP_SUCCESS;
        },
        sdl_app.sdl.SDL_EVENT_WINDOW_RESIZED => {
            @atomicStore(bool, &app_context.inner.dirty_resize, true, .monotonic);
        },
        else => {},
    }
    return sdl_app.sdl.SDL_APP_CONTINUE;
}

pub fn main(init: std.process.Init) !void {
    _ = sdl_app.SdlApplicaton(Context, .{
        .iterate_handler = iterate_handler,
        .app_init = app_init,
        .app_event = app_event,
        .app_quit = app_quit,
    }).exec(init);
}
