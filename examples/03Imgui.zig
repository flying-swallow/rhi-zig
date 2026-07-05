const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");
const sdl_app = @import("./sdl_app.zig");

const sdl = sdl_app.sdl;
/// Raw dear_bindings ImGui C API, re-exported by the RHI for building UI.
const ig = rhi.imgui_c;

pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });

pub const Context = struct {
    window: *sdl.SDL_Window = undefined,
    swapchain: rhi.Swapchain = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    dirty_resize: bool = false,
    graphics_cmd_ring: CmdRingBuffer = undefined,
    imgui: rhi.ImGui = undefined,
    last_ticks: u64 = 0,
};

fn iterate_handler(app_context: *sdl_app.AppContext(Context)) anyerror!sdl.SDL_AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}

    if (@atomicRmw(bool, &cntx.dirty_resize, .Xchg, false, .monotonic) == true) {
        var w: c_int = 0;
        var h: c_int = 0;
        if (sdl.SDL_GetWindowSize(cntx.window, &w, &h)) {
            _ = try cntx.swapchain.resize(&cntx.device, @intCast(w), @intCast(h));
        } else {
            std.log.err("{s}", .{sdl.SDL_GetError()});
        }
    }

    const w = cntx.swapchain.width;
    const h = cntx.swapchain.height;

    // --- ImGui frame: begin, build UI --------------------------------------
    const now = sdl.SDL_GetTicks();
    const dt: f32 = if (cntx.last_ticks == 0) 1.0 / 60.0 else @as(f32, @floatFromInt(now - cntx.last_ticks)) / 1000.0;
    cntx.last_ticks = now;
    cntx.imgui.newFrame(@floatFromInt(w), @floatFromInt(h), dt);

    ig.ImGui_ShowDemoWindow(null);
    if (ig.ImGui_Begin("rhi-zig", null, 0)) {
        ig.ImGui_Text("Dear ImGui on the RHI (%s backend)", rhi.Renderer.apiString().ptr);
        ig.ImGui_Text("%.1f FPS", ig.ImGui_GetIO().*.Framerate);
    }
    ig.ImGui_End();

    // --- Record the frame ---------------------------------------------------
    cntx.graphics_cmd_ring.advance();
    const swapchain_index = try cntx.swapchain.acquire_next_image(&cntx.device);
    var ring_element = cntx.graphics_cmd_ring.get(&cntx.device, 1);
    try ring_element.wait(&cntx.device);

    try ring_element.pool.reset(&cntx.device);
    var cmd = &ring_element.cmds[0];
    try cmd.begin(&cntx.device);

    var img = cntx.swapchain.image(swapchain_index);
    const view = cntx.swapchain.image_view(swapchain_index);

    cmd.image_barrier(&cntx.device, .{ .image = &img, .before = .{}, .after = .{ .render_target = true } });

    cmd.begin_rendering(&cntx.device, .{
        .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ 0.1, 0.1, 0.12, 1.0 },
        }},
        .render_area = .{ .width = w, .height = h },
    });

    try cntx.imgui.render(&cntx.device, cmd);

    cmd.end_rendering(&cntx.device);

    cmd.image_barrier(&cntx.device, .{
        .image = &img,
        .before = .{ .render_target = true },
        .after = .{ .present = true },
    });

    try cntx.swapchain.frame_submit(&cntx.device, &cntx.device.graphics_queue, .{
        .image_index = swapchain_index,
        .ring_element = &ring_element,
        .cmd = cmd,
    });

    cntx.timekeeper.produce(sdl.SDL_GetPerformanceCounter());
    return sdl.SDL_APP_CONTINUE;
}

fn app_init(app_context: *sdl_app.AppContext(Context), argv: [][*:0]u8) anyerror!sdl.SDL_AppResult {
    _ = argv;
    if (sdl.SDL_SetAppMetadata("03-ImGui", "0.0.0", "imgui") == false) return error.SetAppMetadataFailed;
    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) == false) return error.SDLInitFailed;

    const window = sdl.SDL_CreateWindow("03-imgui", 1280, 720, sdl.SDL_WINDOW_RESIZABLE);
    if (window == null) return error.CreateWindowFailed;
    errdefer sdl.SDL_DestroyWindow(window);

    const window_handle = try sdl_app.sdl_window_handle_to_rhi_window_handle(window.?);
    var cntx: *Context = &app_context.inner;

    try rhi.Renderer.init(app_context.gpa, .{ .vk = .{ .app_name = "rhi-imgui", .enable_validation_layer = true } });
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(app_context.gpa);
    defer adapters.deinit(app_context.gpa);

    const selected_adapter_index = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    cntx.device = try rhi.Device.init(app_context.gpa, &adapters.items[selected_adapter_index]);
    cntx.swapchain = try rhi.Swapchain.init(app_context.gpa, &cntx.device, 1280, 720, window_handle, .{});
    cntx.timekeeper = .{ .tocks_per_s = sdl.SDL_GetPerformanceFrequency() };
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.device, &cntx.device.graphics_queue);
    cntx.dirty_resize = false;
    cntx.last_ticks = 0;

    cntx.imgui = try rhi.ImGui.init(app_context.gpa, &cntx.device, &cntx.swapchain);

    cntx.window = window.?;
    return sdl.SDL_APP_CONTINUE;
}

fn app_quit(app_context: *sdl_app.AppContext(Context), result: sdl.SDL_AppResult) void {
    var cntx: *Context = &app_context.inner;
    cntx.device.graphics_queue.wait_queue_idle(&cntx.device) catch |err| {
        std.log.err("Failed to wait graphics queue idle: {}", .{err});
    };

    cntx.imgui.deinit(&cntx.device);
    cntx.graphics_cmd_ring.deinit(&cntx.device);
    cntx.swapchain.deinit(&cntx.device);
    cntx.device.deinit();
    rhi.Renderer.deinit();

    std.debug.print("App quit called with result: {any}\n", .{result});
}

fn app_event(app_context: *sdl_app.AppContext(Context), event: *sdl.SDL_Event) anyerror!sdl.SDL_AppResult {
    var imgui = &app_context.inner.imgui;
    switch (event.type) {
        sdl.SDL_EVENT_QUIT => return sdl.SDL_APP_SUCCESS,
        sdl.SDL_EVENT_WINDOW_RESIZED => @atomicStore(bool, &app_context.inner.dirty_resize, true, .monotonic),
        sdl.SDL_EVENT_MOUSE_MOTION => imgui.addMousePosEvent(event.motion.x, event.motion.y),
        sdl.SDL_EVENT_MOUSE_WHEEL => imgui.addMouseWheelEvent(event.wheel.x, event.wheel.y),
        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
            const down = event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN;
            const button: i32 = switch (event.button.button) {
                sdl.SDL_BUTTON_LEFT => 0,
                sdl.SDL_BUTTON_RIGHT => 1,
                sdl.SDL_BUTTON_MIDDLE => 2,
                else => return sdl.SDL_APP_CONTINUE,
            };
            imgui.addMouseButtonEvent(button, down);
        },
        else => {},
    }
    return sdl.SDL_APP_CONTINUE;
}

pub fn main(init: std.process.Init) !void {
    _ = sdl_app.SdlApplicaton(Context, .{
        .iterate_handler = iterate_handler,
        .app_init = app_init,
        .app_event = app_event,
        .app_quit = app_quit,
    }).exec(init);
}
