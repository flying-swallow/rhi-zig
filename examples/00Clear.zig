// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const builtin = @import("builtin");
const std = @import("std");
const example_build_options = @import("example_build_options");
const rhi = @import("rhi");
const sdl_app = @import("./sdl_app.zig");

const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });

/// The swapchain is a ref-counted box: each frame it is enqueued into `deferral`
/// (ref++), so its ref-count tracks how many in-flight frames still use it. When a
/// resize recreates it, the old box's outstanding usage refs drain over the next
/// frames and it self-disposes — no pipeline stall, no in-flight free.
const SwapchainRef = rhi.gpu_ref.GPURef(rhi.Swapchain, .heap);
const Deferral = rhi.timline_deferral.TimelineDeferral(&.{*SwapchainRef});

pub const Context = struct {
    window: *sdl_app.sdl.SDL_Window = undefined,
    swapchain: *SwapchainRef = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    graphics_cmd_ring: CmdRingBuffer = undefined,
    timeline: rhi.Timeline = undefined,
    deferral: Deferral = undefined,
    /// Set when acquire/present reports OUT_OF_DATE; recreated at the next frame top.
    force_rebuild: bool = false,
};

fn iterate_handler(app_context: *sdl_app.AppContext(Context)) anyerror!sdl_app.sdl.SDL_AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}

    // Reclaim swapchains (and anything else parked) whose frames the GPU has finished.
    cntx.deferral.drain(try cntx.timeline.completed(&cntx.device));

    // Poll the window size and rebuild the swapchain if it changed or a previous
    // acquire/present reported OUT_OF_DATE (HPL2-style; no resize event / resize()).
    var poll_w: c_int = 0;
    var poll_h: c_int = 0;
    {
        const have_size = sdl_app.sdl.SDL_GetWindowSizeInPixels(cntx.window, &poll_w, &poll_h);
        const presentable = have_size and poll_w > 0 and poll_h > 0;
        if (presentable and (cntx.force_rebuild or
            cntx.swapchain.inner.width != @as(u16, @intCast(poll_w)) or
            cntx.swapchain.inner.height != @as(u16, @intCast(poll_h))))
        {
            const next = try rhi.Swapchain.init(app_context.gpa, &cntx.device, .{
                .width = @intCast(poll_w),
                .height = @intCast(poll_h),
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

    // Acquire. On OUT_OF_DATE skip the whole frame (nothing may wait on the
    // unsignaled acquire semaphore) and rebuild next frame.
    var swapchain_index: u32 = undefined;
    const acq = try cntx.swapchain.inner.acquire_next_image(&cntx.device, &swapchain_index);
    switch (acq) {
        .out_of_date => {
            cntx.force_rebuild = true;
            return sdl_app.sdl.SDL_APP_CONTINUE;
        },
        else => {},
    }

    // Mark the swapchain as used by this frame (usage ref++).
    try cntx.deferral.enqueue(cntx.swapchain);

    cntx.graphics_cmd_ring.advance();
    var ring_element = cntx.graphics_cmd_ring.get(&cntx.device, 1);
    try ring_element.wait(&cntx.device); // Wait for the GPU to finish with this command buffer

    try ring_element.pool.reset(&cntx.device); // Reset the pool (which also resets the command buffers)
    var cmd = &ring_element.cmds[0];
    try cmd.begin(&cntx.device);

    var img = cntx.swapchain.inner.image(swapchain_index);
    const view = cntx.swapchain.inner.image_view(swapchain_index);
    const w = cntx.swapchain.inner.width;
    const h = cntx.swapchain.inner.height;

    // undefined -> color_attachment (real on Vulkan, no-op on Metal)
    cmd.image_barrier(&cntx.device, .{
        .image = &img,
        .before = .{},
        .after = .{ .render_target = true },
    });

    cmd.begin_rendering(&cntx.device, .{
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
    cmd.clear_attachment_regions(&cntx.device, .{ .regions = &.{
        .{ .color = .{ 0.0, 0.0, 0.0, 1.0 }, .rect = .{ .x = 0, .y = 0, .width = w / 2, .height = h / 2 } },
        .{ .color = .{ 1.0, 0.0, 0.0, 1.0 }, .rect = .{ .x = @intCast(w / 2), .y = 0, .width = w / 2, .height = h / 2 } },
        .{ .color = .{ 0.0, 1.0, 0.0, 1.0 }, .rect = .{ .x = 0, .y = @intCast(h / 2), .width = w / 2, .height = h / 2 } },
        .{ .color = .{ 0.0, 0.0, 1.0, 1.0 }, .rect = .{ .x = @intCast(w / 2), .y = @intCast(h / 2), .width = w / 2, .height = h / 2 } },
    } });

    cmd.end_rendering(&cntx.device);

    // color_attachment -> present (real on Vulkan, no-op on Metal)
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
    try rhi.Renderer.init(app_context.gpa, if (example_build_options.webgpu)
        .{ .webgpu = .{} }
    else if (is_apple)
        .{ .mtl = .{} }
    else
        .{ .vk = .{ .app_name = "GraphicsKernel", .enable_validation_layer = true } });
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(app_context.gpa);
    defer adapters.deinit(app_context.gpa);

    const selected_adapter_index = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    cntx.window = window.?;
    cntx.device = try rhi.Device.init(app_context.gpa, &adapters.items[selected_adapter_index]);

    const swapchain = try rhi.Swapchain.init(app_context.gpa, &cntx.device, .{
        .width = 640,
        .height = 480,
        .queue = &cntx.device.graphics_queue,
        .source = .{ .window_handle = window_handle },
    });
    cntx.swapchain = try SwapchainRef.create(app_context.gpa, &cntx.device, swapchain);

    cntx.timekeeper = .{ .tocks_per_s = sdl_app.sdl.SDL_GetPerformanceFrequency() };
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.device, &cntx.device.graphics_queue);
    cntx.timeline = try rhi.Timeline.init(&cntx.device);
    cntx.deferral = Deferral.init(app_context.gpa);
    cntx.force_rebuild = false;
    return sdl_app.sdl.SDL_APP_CONTINUE;
}

fn app_quit(app_context: *sdl_app.AppContext(Context), result: sdl_app.sdl.SDL_AppResult) void {
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
    cntx.graphics_cmd_ring.deinit(&cntx.device);
    cntx.device.deinit();
    rhi.Renderer.deinit();
    std.debug.print("App quit called with result: {any}\n", .{result});
}

fn app_event(app_context: *sdl_app.AppContext(Context), event: *sdl_app.sdl.SDL_Event) anyerror!sdl_app.sdl.SDL_AppResult {
    _ = app_context;
    switch (event.type) {
        sdl_app.sdl.SDL_EVENT_QUIT => {
            return sdl_app.sdl.SDL_APP_SUCCESS;
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
