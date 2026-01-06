const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");
const sdl_app = @import("./sdl_app.zig");

pub const ResourceLoader = rhi.ResourceLoader(.{ .max_sets = 2, .buffer_size = 8 * 1024 * 1024 });
pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });

pub const Context = struct {
    allocator: std.mem.Allocator = undefined,
    frame_heap: std.heap.ArenaAllocator = undefined,

    window: *sdl_app.sdl.SDL_Window = undefined,
    renderer: rhi.Renderer = undefined,
    swapchain: rhi.Swapchain = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    resource_loader: ResourceLoader = undefined,
    dirty_resize: bool = false,
    graphics_cmd_ring: CmdRingBuffer = undefined,

    cube_vertex_buffer: rhi.Buffer = undefined,
    cube_index_buffer: rhi.Buffer = undefined,
};

pub const cube_index = [_]u16{
    0, 1, 2, 2, 1, 3, // back face
    4, 6, 5, 5, 6, 7, // front face
    4, 5, 0, 0, 5, 1, // bottom face
    2, 3, 6, 6, 3, 7, // top face
    4, 0, 6, 6, 0, 2, // left face
    1, 5, 3, 3, 5, 7, // right face
};

pub const cube_mesh = [_]f32{
    -0.5, -0.5, -0.5, // V0
    0.5, -0.5, -0.5, // V1
    -0.5, 0.5, -0.5, // V2
    0.5, 0.5, -0.5, // V3
    -0.5, -0.5, 0.5, // V4
    0.5, -0.5, 0.5, // V5
    -0.5, 0.5, 0.5, // V6
    0.5, 0.5, 0.5, // V7
};

fn iterate_handler(app_context: *sdl_app.AppContext(Context)) anyerror!sdl_app.sdl.SDL_AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}
    // draw
    {
        if (@atomicRmw(bool, &cntx.dirty_resize, .Xchg, false, .monotonic) == true) {
            var w: c_int = 0;
            var h: c_int = 0;
            if (sdl_app.sdl.SDL_GetWindowSize(cntx.window, &w, &h)) {
                _ = try cntx.swapchain.resize(&cntx.renderer, &cntx.device, @intCast(w), @intCast(h));
            } else {
                std.log.err("{s}", .{sdl_app.sdl.SDL_GetError()});
            }
        }

        cntx.graphics_cmd_ring.advance();
        const swapchain_index = try cntx.swapchain.acquire_next_image(&cntx.renderer, &cntx.device);
        var ring_element = cntx.graphics_cmd_ring.get(&cntx.renderer, 1);
        try ring_element.wait(&cntx.renderer, &cntx.device); // Wait for the GPU to finish with this command buffer

        try ring_element.pool.reset(&cntx.renderer, &cntx.device); // Reset the pool (which also resets the command buffers)
        try ring_element.cmds[0].begin(&cntx.renderer, &cntx.device);
        if (rhi.is_target_selected(.vk, &cntx.renderer)) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &cntx.device.backend.vk.dkb;
            const img = cntx.swapchain.image(&cntx.renderer, swapchain_index);
            const image_view = cntx.swapchain.image_view(&cntx.renderer, swapchain_index);
            {
                var barriers = [_]rhi.vulkan.vk.ImageMemoryBarrier2{.{
                    .src_stage_mask = .{},
                    .src_access_mask = .{},
                    .dst_stage_mask = .{ .color_attachment_output_bit = true },
                    .dst_access_mask = .{ .color_attachment_write_bit = true },
                    .old_layout = .undefined,
                    .new_layout = .color_attachment_optimal,
                    .src_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                    .image = img.backend.vk.image,
                    .subresource_range = .{
                        .aspect_mask = rhi.vulkan.VKImageSpaceFlagsFromFormatAndStencil(cntx.swapchain.backend.vk.format, false),
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                }};
                var dependency_info = rhi.vulkan.vk.DependencyInfo{
                    .image_memory_barrier_count = barriers.len,
                    .p_image_memory_barriers = barriers[0..].ptr,
                };
                dkb.cmdPipelineBarrier2(ring_element.cmds[0].backend.vk.cmd, &dependency_info);
            }
            {
                var color_attachment = [_]rhi.vulkan.vk.RenderingAttachmentInfo{.{
                    .resolve_mode = .{},
                    .resolve_image_layout = .undefined,
                    .image_view = image_view.vk,
                    .image_layout = .color_attachment_optimal,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{ .color = .{ .float_32 = [4]f32{ 0.0, 0.0, 0.0, 1.0 } } },
                }};

                var rending_info = rhi.vulkan.vk.RenderingInfo{
                    .render_area = .{
                        .offset = .{ .x = 0, .y = 0 },
                        .extent = .{ .width = cntx.swapchain.width, .height = cntx.swapchain.height },
                    },
                    .view_mask = 0,
                    .layer_count = 1,
                    .color_attachment_count = 1,
                    .p_color_attachments = &color_attachment,
                };
                dkb.cmdBeginRendering(ring_element.cmds[0].backend.vk.cmd, &rending_info);
            }
            var viewport = [_]rhi.vulkan.vk.Viewport{.{
                .x = 0.0,
                .y = 0.0,
                .width = @floatFromInt(cntx.swapchain.width),
                .height = @floatFromInt(cntx.swapchain.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            }};
            var scissor_rect = [_]rhi.vulkan.vk.Rect2D{.{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = cntx.swapchain.width, .height = cntx.swapchain.height },
            }};
            dkb.cmdSetViewport(ring_element.cmds[0].backend.vk.cmd, 0, 1, &viewport);
            dkb.cmdSetScissor(ring_element.cmds[0].backend.vk.cmd, 0, 1, &scissor_rect);
            //dkb.cmdBindPipeline(ring_element.cmds[0].backend.vk.cmd, .graphics, cntx.pipeline);
            //dkb.cmdDraw(ring_element.cmds[0].backend.vk.cmd, 3, 1, 0, 0);

            dkb.cmdEndRendering(ring_element.cmds[0].backend.vk.cmd);

            {
                var barriers = [_]rhi.vulkan.vk.ImageMemoryBarrier2{.{
                    .src_stage_mask = .{ .color_attachment_output_bit = true },
                    .src_access_mask = .{ .color_attachment_write_bit = true },
                    .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
                    .dst_access_mask = .{},
                    .old_layout = .color_attachment_optimal,
                    .new_layout = .present_src_khr,
                    .src_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                    .dst_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                    .image = img.backend.vk.image,
                    .subresource_range = .{
                        .aspect_mask = rhi.vulkan.VKImageSpaceFlagsFromFormatAndStencil(cntx.swapchain.backend.vk.format, false),
                        .base_mip_level = 0,
                        .level_count = 1,
                        .base_array_layer = 0,
                        .layer_count = 1,
                    },
                }};
                var dependency_info = rhi.vulkan.vk.DependencyInfo{
                    .image_memory_barrier_count = barriers.len,
                    .p_image_memory_barriers = barriers[0..].ptr,
                };
                dkb.cmdPipelineBarrier2(ring_element.cmds[0].backend.vk.cmd, &dependency_info);
            }

            try ring_element.cmds[0].end(&cntx.renderer, &cntx.device);

            const cmd_submit = [_]rhi.vulkan.vk.CommandBufferSubmitInfo{.{
                .command_buffer = ring_element.cmds[0].backend.vk.cmd,
                .device_mask = 0,
            }};

            var flush = try cntx.resource_loader.VKFlushResourceUpdate(&cntx.renderer, &.{});
            var semaphore_buf: [2]rhi.vulkan.vk.SemaphoreSubmitInfo = undefined;
            var wait_semaphore_info: std.ArrayList(rhi.vulkan.vk.SemaphoreSubmitInfo) = .initBuffer(&semaphore_buf);
            wait_semaphore_info.appendAssumeCapacity(.{
                .semaphore = cntx.swapchain.backend.vk.current_semaphore(),
                .stage_mask = .{ .color_attachment_output_bit = true },
                .value = 0,
                .device_index = 0,
            });
            if (flush.signaled) {
                wait_semaphore_info.appendAssumeCapacity(.{
                    .semaphore = flush.semaphore,
                    .stage_mask = .{ .all_transfer_bit = true },
                    .value = 0,
                    .device_index = 0,
                });
            }

            const semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
                .semaphore = ring_element.backend.vk.semaphore,
                .value = 0,
                .stage_mask = .{
                    .all_commands_bit = true,
                },
                .device_index = 0,
            }};

            var submit_info = [_]rhi.vulkan.vk.SubmitInfo2{.{ .p_command_buffer_infos = cmd_submit[0..].ptr, .command_buffer_info_count = cmd_submit.len, .p_wait_semaphore_infos = wait_semaphore_info.items[0..].ptr, .wait_semaphore_info_count = @intCast(wait_semaphore_info.items.len), .p_signal_semaphore_infos = semaphore_info[0..].ptr, .signal_semaphore_info_count = semaphore_info.len }};
            std.debug.assert(try dkb.getFenceStatus(cntx.device.backend.vk.device, ring_element.backend.vk.fence) == .success);
            const reset_fence = [_]rhi.vulkan.vk.Fence{ring_element.backend.vk.fence};
            _ = try dkb.resetFences(cntx.device.backend.vk.device, reset_fence.len, reset_fence[0..].ptr);
            _ = try dkb.queueSubmit2(cntx.device.graphics_queue.backend.vk.queue, 1, submit_info[0..].ptr, ring_element.backend.vk.fence);

            var swapchains = [_]rhi.vulkan.vk.SwapchainKHR{cntx.swapchain.backend.vk.swapchain};
            var image_indecies = [_]u32{swapchain_index};
            var wait_semaphores = [_]rhi.vulkan.vk.Semaphore{ring_element.backend.vk.semaphore};
            var present_info = rhi.vulkan.vk.PresentInfoKHR{
                .swapchain_count = 1,
                .p_swapchains = swapchains[0..].ptr,
                .p_image_indices = image_indecies[0..].ptr,
                .wait_semaphore_count = wait_semaphores.len,
                .p_wait_semaphores = wait_semaphores[0..].ptr,
            };
            _ = try dkb.queuePresentKHR(cntx.device.graphics_queue.backend.vk.queue, &present_info);
        }
    }
    cntx.timekeeper.produce(sdl_app.sdl.SDL_GetPerformanceCounter());
    return sdl_app.sdl.SDL_APP_CONTINUE;
}

fn app_init(app_context: *sdl_app.AppContext(Context), argv: [][*:0]u8) anyerror!sdl_app.InitResult(Context) {
    _ = argv;
    if (sdl_app.sdl.SDL_SetAppMetadata("02-Mesh", "0.0.0", "mesh") == false) {
        return error.SetAppMetadataFailed;
    }
    if (sdl_app.sdl.SDL_Init(sdl_app.sdl.SDL_INIT_VIDEO) == false) {
        return error.SDLInitFailed;
    }

    const window = sdl_app.sdl.SDL_CreateWindow("02-mesh", 640, 480, sdl_app.sdl.SDL_WINDOW_RESIZABLE);
    if (window == null) return error.CreateWindowFailed;
    errdefer sdl_app.sdl.SDL_DestroyWindow(window);

    const window_handle: rhi.WindowHandle = p: {
        if (builtin.os.tag == .windows) {} else if (builtin.os.tag == .linux) {
            if (std.mem.eql(u8, std.mem.sliceTo(sdl_app.sdl.SDL_GetCurrentVideoDriver(), 0), "x11")) {
                break :p rhi.WindowHandle{ .x11 = .{
                    .display = sdl_app.sdl.SDL_GetPointerProperty(sdl_app.sdl.SDL_GetWindowProperties(window), sdl_app.sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null).?,
                    .window = @intCast(sdl_app.sdl.SDL_GetNumberProperty(sdl_app.sdl.SDL_GetWindowProperties(window), sdl_app.sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0)),
                } };
            } else if (std.mem.eql(u8, std.mem.sliceTo(sdl_app.sdl.SDL_GetCurrentVideoDriver(), 0), "wayland")) {
                break :p rhi.WindowHandle{ .wayland = .{ .display = sdl_app.sdl.SDL_GetPointerProperty(sdl_app.sdl.SDL_GetWindowProperties(window), sdl_app.sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null).?, .surface = sdl_app.sdl.SDL_GetPointerProperty(sdl_app.sdl.SDL_GetWindowProperties(window), sdl_app.sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null).?, .shell_surface = null } };
            }
        } else if (builtin.os.tag == .macos or builtin.os.tag == .ios) {}
        return error.SdlError;
    };

    var cntx: *Context= &app_context.inner;

    cntx.renderer = try rhi.Renderer.init(cntx.gpa, .{
        .vk = .{ .app_name = "GraphicsKernel", .enable_validation_layer = true },
    });
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(cntx.gpa, &cntx.renderer);
    defer adapters.deinit(cntx.gpa);

    const selected_adapter_index = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    cntx.device = try rhi.Device.init(app_context.gpa, &cntx.renderer, &adapters.items[selected_adapter_index]);
    cntx.swapchain = try rhi.Swapchain.init(app_context.gpa, &cntx.renderer, &cntx.device, 640, 480, &cntx.device.graphics_queue, window_handle, .{});
    cntx.timekeeper = .{ .tocks_per_s = sdl_app.sdl.SDL_GetPerformanceFrequency() };
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.renderer, &cntx.device, &cntx.device.graphics_queue);
    cntx.dirty_resize = false;
    cntx.resource_loader = try ResourceLoader.init(app_context.gpa, &cntx.renderer, &cntx.device);

    {
        var cube_bytes = std.mem.asBytes(&cube_mesh);
        var transaction: rhi.resource_loader.BufferTransaction = .{ .target = &cntx.cube_vertex_buffer, .offset = 0, .size = cube_bytes.len };
        cntx.cube_vertex_buffer = try .init_general(&cntx.renderer, &cntx.device, .{
            .size = cube_bytes.len,
            .usage = .{ .vertex_buffer = true },
        });
        try cntx.resource_loader.begin_copy_buffer(&cntx.renderer, &transaction);
        @memcpy(transaction.mapped.memory_range[0..cube_bytes.len], cube_bytes[0..]);
        try cntx.resource_loader.end_copy_buffer(&cntx.renderer, &transaction);
    }
    {
        var index_bytes = std.mem.asBytes(&cube_index);
        cntx.cube_index_buffer = try .init_general(&cntx.renderer, &cntx.device, .{
            .size = index_bytes.len,
            .usage = .{ .index_buffer = true },
        });
        var transation: rhi.resource_loader.BufferTransaction = .{ .target = &cntx.cube_index_buffer, .offset = 0, .size = index_bytes.len };
        try cntx.resource_loader.begin_copy_buffer(&cntx.renderer, &transation);
        @memcpy(transation.mapped.memory_range[0..index_bytes.len], index_bytes[0..]);
        try cntx.resource_loader.end_copy_buffer(&cntx.renderer, &transation);
    }
    return sdl_app.sdl.SDL_APP_CONTINUE;
}

fn app_quit(cntx: *sdl_app.AppContext(Context), result: sdl_app.sdl.SDL_AppResult) void {
    cntx.device.graphics_queue.wait_queue_idle(&cntx.renderer, &cntx.device) catch |err| {
        std.log.err("Failed to wait graphics queue idle: {}", .{err});
    };

    cntx.graphics_cmd_ring.deinit(&cntx.renderer, &cntx.device);
    cntx.swapchain.deinit(&cntx.renderer, &cntx.device);
    cntx.device.deinit(&cntx.renderer);
    cntx.renderer.deinit();

    std.debug.print("App quit called with result: {any}\n", .{result});
}

fn app_event(cntx: *sdl_app.AppContext(Context), event: *sdl_app.sdl.SDL_Event) anyerror!sdl_app.sdl.SDL_AppResult {
    switch (event.type) {
        sdl_app.sdl.SDL_EVENT_QUIT => {
            return sdl_app.sdl.SDL_APP_SUCCESS;
        },
        sdl_app.sdl.SDL_EVENT_WINDOW_RESIZED => {
            @atomicStore(bool, &cntx.dirty_resize, true, .monotonic);
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
