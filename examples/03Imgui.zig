// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");
const sdl_app = @import("./sdl_app.zig");

const sdl = sdl_app.sdl;
/// Raw dear_bindings ImGui C API, re-exported by the RHI for building UI.
const ig = rhi.imgui_c;

pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });

/// The swapchain is a ref-counted box: each frame it is enqueued into `deferral`
/// (ref++), so its ref-count tracks how many in-flight frames still use it. On a
/// resize the old box's usage refs drain over the next frames and it self-disposes.
const SwapchainRef = rhi.gpu_ref.GPURef(rhi.Swapchain, .heap);
const Deferral = rhi.timline_deferral.TimelineDeferral(&.{*SwapchainRef});

pub const Context = struct {
    window: *sdl.SDL_Window = undefined,
    swapchain: *SwapchainRef = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    graphics_cmd_ring: CmdRingBuffer = undefined,
    timeline: rhi.Timeline = undefined,
    deferral: Deferral = undefined,
    imgui: rhi.ImGui = undefined,
    last_ticks: u64 = 0,
    force_rebuild: bool = false,
};

fn iterate_handler(app_context: *sdl_app.AppContext(Context)) anyerror!sdl.SDL_AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}

    // Reclaim swapchains (and anything else parked) whose frames the GPU has finished.
    cntx.deferral.drain(try cntx.timeline.completed(&cntx.device));

    // Poll the window size and rebuild the swapchain if it changed or a previous
    // acquire/present reported OUT_OF_DATE (HPL2-style; no resize event / resize()).
    {
        var pw: c_int = 0;
        var ph: c_int = 0;
        const have_size = sdl.SDL_GetWindowSize(cntx.window, &pw, &ph);
        const presentable = have_size and pw > 0 and ph > 0;
        if (presentable and (cntx.force_rebuild or
            cntx.swapchain.inner.width != @as(u16, @intCast(pw)) or
            cntx.swapchain.inner.height != @as(u16, @intCast(ph))))
        {
            const next = try rhi.Swapchain.init(app_context.gpa, &cntx.device, .{
                .width = @intCast(pw),
                .height = @intCast(ph),
                .queue = &cntx.device.graphics_queue,
                .source = .{ .old_swapchain = &cntx.swapchain.inner },
            });
            if (!next.isEmpty()) {
                const box = try SwapchainRef.create(app_context.gpa, &cntx.device, next);
                cntx.swapchain.deref(); // drop our ref on the old box; it self-disposes
                cntx.swapchain = box; //   once its per-frame usage refs drain
                cntx.force_rebuild = false;
            }
        }
    }

    // Acquire before starting the ImGui frame: on OUT_OF_DATE skip the whole frame
    // (nothing may wait on the unsignaled acquire semaphore, and no half-open ImGui
    // frame is left dangling) and rebuild next frame.
    var swapchain_index: u32 = undefined;
    switch (try cntx.swapchain.inner.acquire_next_image(&cntx.device, &swapchain_index)) {
        .out_of_date => {
            cntx.force_rebuild = true;
            return sdl.SDL_APP_CONTINUE;
        },
        else => {},
    }

    // Mark the swapchain as used by this frame (usage ref++).
    try cntx.deferral.enqueue(cntx.swapchain);

    const w = cntx.swapchain.inner.width;
    const h = cntx.swapchain.inner.height;

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
    var ring_element = cntx.graphics_cmd_ring.get(&cntx.device, 1);
    try ring_element.wait(&cntx.device);

    try ring_element.pool.reset(&cntx.device);
    var cmd = &ring_element.cmds[0];
    try cmd.begin(&cntx.device);

    var img = cntx.swapchain.inner.image(swapchain_index);
    const view = cntx.swapchain.inner.image_view(swapchain_index);

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

    const present_status = try cntx.swapchain.inner.frame_submit(&cntx.device, &cntx.device.graphics_queue, .{
        .image_index = swapchain_index,
        .ring_element = &ring_element,
        .cmd = cmd,
        .timeline = &cntx.timeline,
    });
    if (present_status == .out_of_date) cntx.force_rebuild = true;

    // Close this frame's usage batch at the timeline value the submit signalled.
    try cntx.deferral.seal(cntx.timeline.pending());

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
    const swapchain = try rhi.Swapchain.init(app_context.gpa, &cntx.device, .{
        .width = 1280,
        .height = 720,
        .queue = &cntx.device.graphics_queue,
        .source = .{ .window_handle = window_handle },
    });
    cntx.swapchain = try SwapchainRef.create(app_context.gpa, &cntx.device, swapchain);
    cntx.timekeeper = .{ .tocks_per_s = sdl.SDL_GetPerformanceFrequency() };
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.device, &cntx.device.graphics_queue);
    cntx.timeline = try rhi.Timeline.init(&cntx.device);
    cntx.deferral = Deferral.init(app_context.gpa);
    cntx.force_rebuild = false;
    cntx.last_ticks = 0;

    cntx.imgui = try rhi.ImGui.init(app_context.gpa, &cntx.device, &cntx.swapchain.inner);

    cntx.window = window.?;
    return sdl.SDL_APP_CONTINUE;
}

fn app_quit(app_context: *sdl_app.AppContext(Context), result: sdl.SDL_AppResult) void {
    var cntx: *Context = &app_context.inner;
    cntx.device.graphics_queue.wait_queue_idle(&cntx.device) catch |err| {
        std.log.err("Failed to wait graphics queue idle: {}", .{err});
    };

    // GPU is idle: release every per-frame usage ref, then our own ref on the
    // current swapchain (last owner -> Swapchain.deinit + free the box).
    cntx.deferral.drain(cntx.timeline.pending());
    cntx.swapchain.deref();
    cntx.deferral.deinit();
    cntx.timeline.deinit(&cntx.device);

    cntx.imgui.deinit(&cntx.device);
    cntx.graphics_cmd_ring.deinit(&cntx.device);
    cntx.device.deinit();
    rhi.Renderer.deinit();

    std.debug.print("App quit called with result: {any}\n", .{result});
}

fn app_event(app_context: *sdl_app.AppContext(Context), event: *sdl.SDL_Event) anyerror!sdl.SDL_AppResult {
    var imgui = &app_context.inner.imgui;
    switch (event.type) {
        sdl.SDL_EVENT_QUIT => return sdl.SDL_APP_SUCCESS,
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
