const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");
const sdl_application = @import("./sdl_application.zig");

pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });
var allocator: std.mem.Allocator = undefined;
pub const AppContext = struct { 
    window: *sdl_application.sdl.SDL_Window = undefined, 
    allocator: std.mem.Allocator = undefined, 
    renderer: rhi.Renderer = undefined, 
    swapchain: rhi.Swapchain = undefined, 
    device: rhi.Device = undefined, 
    timekeeper: rhi.TimeKeeper = undefined, 
    dirty_resize: bool = false, 
    graphics_cmd_ring: CmdRingBuffer = undefined 
};

fn iterate_handler(cntx: *AppContext) anyerror!sdl_application.sdl.SDL_AppResult {
    while (cntx.timekeeper.consume()) {}

    // draw
    {
        if (@atomicRmw(bool, &cntx.dirty_resize, .Xchg, false, .monotonic) == true) {
            var w: c_int = 0;
            var h: c_int = 0;
            if (sdl_application.sdl.SDL_GetWindowSize(cntx.window, &w, &h)) {
                _ = try cntx.swapchain.resize(&cntx.renderer, &cntx.device, @intCast(w), @intCast(h));
            } else {
                std.log.err("{s}", .{sdl_application.sdl.SDL_GetError()});
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

            const clear_ops = [_]struct {
                clear_color: [4]f32,
                clear_rect: rhi.vulkan.vk.Rect2D,
            }{
                .{ .clear_color = [4]f32{ 0.0, 0.0, 0.0, 1.0 }, .clear_rect = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = cntx.swapchain.width / 2, .height = cntx.swapchain.height / 2 } } },
                .{ .clear_color = [4]f32{ 1.0, 0.0, 0.0, 1.0 }, .clear_rect = .{ .offset = .{ .x = @intCast(cntx.swapchain.width / 2), .y = 0 }, .extent = .{ .width = cntx.swapchain.width / 2, .height = cntx.swapchain.height / 2 } } },
                .{ .clear_color = [4]f32{ 0.0, 1.0, 0.0, 1.0 }, .clear_rect = .{ .offset = .{ .x = 0, .y = @intCast(cntx.swapchain.height / 2) }, .extent = .{ .width = cntx.swapchain.width / 2, .height = cntx.swapchain.height / 2 } } },
                .{ .clear_color = [4]f32{ 0.0, 0.0, 1.0, 1.0 }, .clear_rect = .{ .offset = .{ .x = @intCast(cntx.swapchain.width / 2), .y = @intCast(cntx.swapchain.height / 2) }, .extent = .{ .width = cntx.swapchain.width / 2, .height = cntx.swapchain.height / 2 } } },
            };
            for (clear_ops) |cr| {
                var clearRect = [_]rhi.vulkan.vk.ClearRect{.{
                    .rect = cr.clear_rect,
                    .base_array_layer = 0,
                    .layer_count = 1,
                }};
                var clearAttachment = [_]rhi.vulkan.vk.ClearAttachment{.{
                    .aspect_mask = .{ .color_bit = true }, //rhi.volk.c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .color_attachment = 0,
                    .clear_value = .{ .color = .{ .float_32 = cr.clear_color } },
                }};
                dkb.cmdClearAttachments(ring_element.cmds[0].backend.vk.cmd, @intCast(clearAttachment.len), clearAttachment[0..].ptr, @intCast(clearRect.len), clearRect[0..].ptr);
            }

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

            const wait_semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
                .semaphore = cntx.swapchain.backend.vk.current_semaphore(),
                .stage_mask = .{ .color_attachment_output_bit = true },
                .value = 0,
                .device_index = 0,
            }};

            const semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
                .semaphore = ring_element.backend.vk.semaphore,
                .value = 0,
                .stage_mask = .{
                    .all_commands_bit = true,
                },
                .device_index = 0,
            }};

            // zig fmt: off
            var submit_info = [_]rhi.vulkan.vk.SubmitInfo2{.{ 
                .p_command_buffer_infos = cmd_submit[0..].ptr, 
                .command_buffer_info_count = cmd_submit.len, 
                .p_wait_semaphore_infos = wait_semaphore_info[0..].ptr, 
                .wait_semaphore_info_count = wait_semaphore_info.len, 
                .p_signal_semaphore_infos = semaphore_info[0..].ptr, 
                .signal_semaphore_info_count = semaphore_info.len 
            }};
            // zig fmt: on
            const fence_status = try dkb.getFenceStatus(cntx.device.backend.vk.device, ring_element.backend.vk.fence);
            std.debug.assert(fence_status == .success);
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
    cntx.timekeeper.produce(sdl_application.sdl.SDL_GetPerformanceCounter());
    return sdl_application.sdl.SDL_APP_CONTINUE;
}

fn app_init(argv: [][*:0]u8) anyerror!sdl_application.InitResult(AppContext) {
    _ = argv;
    if (sdl_application.sdl.SDL_SetAppMetadata("Tabletop", "0.0.0", "tabletop") == false) {
        return error.SetAppMetadataFailed;
    }
    if (sdl_application.sdl.SDL_Init(sdl_application.sdl.SDL_INIT_VIDEO) == false) {
        return error.SDLInitFailed;
    }

    const window = sdl_application.sdl.SDL_CreateWindow("00-helloworld", 640, 480, sdl_application.sdl.SDL_WINDOW_RESIZABLE);
    if (window == null) return error.CreateWindowFailed;
    errdefer sdl_application.sdl.SDL_DestroyWindow(window);

    const window_handle: rhi.WindowHandle = p: {
        if (builtin.os.tag == .windows) {} else if (builtin.os.tag == .linux) {
            if (std.mem.eql(u8, std.mem.sliceTo(sdl_application.sdl.SDL_GetCurrentVideoDriver(), 0), "x11")) {
                break :p rhi.WindowHandle{ .x11 = .{
                    .display = sdl_application.sdl.SDL_GetPointerProperty(sdl_application.sdl.SDL_GetWindowProperties(window), sdl_application.sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null).?,
                    .window = @intCast(sdl_application.sdl.SDL_GetNumberProperty(sdl_application.sdl.SDL_GetWindowProperties(window), sdl_application.sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0)),
                } };
            } else if (std.mem.eql(u8, std.mem.sliceTo(sdl_application.sdl.SDL_GetCurrentVideoDriver(), 0), "wayland")) {
                break :p rhi.WindowHandle{ 
                    .wayland = .{ 
                        .display = sdl_application.sdl.SDL_GetPointerProperty(
                            sdl_application.sdl.SDL_GetWindowProperties(window), 
                            sdl_application.sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null).?, 
                        .surface = sdl_application.sdl.SDL_GetPointerProperty(sdl_application.sdl.SDL_GetWindowProperties(window), sdl_application.sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null).?, 
                        .shell_surface = null 
                    } 
                };
            }
        } else if (builtin.os.tag == .macos or builtin.os.tag == .ios) {}
        return error.SdlError;
    };

    var renderer = try rhi.Renderer.init(allocator, .{
        .vk = .{ .app_name = "GraphicsKernel", .enable_validation_layer = true },
    });
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(allocator, &renderer);
    defer adapters.deinit(allocator);

    const selected_adapter_index = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    var device = try rhi.Device.init(allocator, &renderer, &adapters.items[selected_adapter_index]);
    const swapchain = try rhi.Swapchain.init(allocator, &renderer, &device, 640, 480, &device.graphics_queue, window_handle, .{});

    const application = try allocator.create(AppContext);
    application.* = .{
        .window = window.?,
        .allocator = allocator,
        .renderer = renderer,
        .swapchain = swapchain,
        .device = device,
        .timekeeper = .{ .tocks_per_s = sdl_application.sdl.SDL_GetPerformanceFrequency() },
        .dirty_resize = false,
        .graphics_cmd_ring = try CmdRingBuffer.init(&renderer, &device, &device.graphics_queue),
    };
    return .{
        .cntx = application,
        .result = sdl_application.sdl.SDL_APP_CONTINUE,
    };
}

fn app_quit(cntx: *AppContext, result: sdl_application.sdl.SDL_AppResult) void {
    cntx.device.graphics_queue.wait_queue_idle(&cntx.renderer, &cntx.device) catch |err| {
        std.log.err("Failed to wait graphics queue idle: {}", .{err});
    };

    cntx.graphics_cmd_ring.deinit(&cntx.renderer, &cntx.device);
    cntx.swapchain.deinit(&cntx.renderer, &cntx.device);
    cntx.device.deinit(&cntx.renderer);
    cntx.renderer.deinit();

    cntx.allocator.destroy(cntx);
    std.debug.print("App quit called with result: {any}\n", .{result});
}

fn app_event(cntx: *AppContext, event: *sdl_application.sdl.SDL_Event) anyerror!sdl_application.sdl.SDL_AppResult {
    switch (event.type) {
        sdl_application.sdl.SDL_EVENT_QUIT => {
            return sdl_application.sdl.SDL_APP_SUCCESS;
        },
        sdl_application.sdl.SDL_EVENT_WINDOW_RESIZED => {
            @atomicStore(bool, &cntx.dirty_resize, true, .monotonic);
        },
        else => {},
    }
    return sdl_application.sdl.SDL_APP_CONTINUE;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();

    _ = sdl_application.SdlApplicaton(AppContext, .{
        .iterate_handler = iterate_handler,
        .app_init = app_init,
        .app_event = app_event,
        .app_quit = app_quit,
    }).exec();
}
