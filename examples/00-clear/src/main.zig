const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");
const core = @import("core");

pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });
var allocator: std.mem.Allocator = undefined;
pub const AppContext = struct { 
    window: *core.sdl.SDL_Window = undefined, 
    allocator: std.mem.Allocator = undefined, 
    renderer: rhi.Renderer = undefined, 
    swapchain: rhi.Swapchain = undefined, 
    device: rhi.Device = undefined, 
    timekeeper: rhi.TimeKeeper = undefined, 
    dirty_resize: bool = false, 
    graphics_cmd_ring: CmdRingBuffer = undefined 
};

//var window: *core.sdl.SDL_Window = undefined;
//var renderer: rhi.Renderer = undefined;
//var swapchain: rhi.Swapchain = undefined;
//var device: rhi.Device = undefined;
//var timekeeper: rhi.TimeKeeper = undefined;
//var dirty_resize: bool = false;
//var graphics_cmd_ring: CmdRingBuffer = undefined;

///// Converts the return value of an SDL function to an error union.
//inline fn errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
//    .bool => void,
//    .pointer, .optional => @TypeOf(value.?),
//    .int => |info| switch (info.signedness) {
//        .signed => @TypeOf(@max(0, value)),
//        .unsigned => @TypeOf(value),
//    },
//    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
//} {
//    return switch (@typeInfo(@TypeOf(value))) {
//        .bool => if (!value) error.SdlError,
//        .pointer, .optional => value orelse error.SdlError,
//        .int => |info| switch (info.signedness) {
//            .signed => if (value >= 0) @max(0, value) else error.SdlError,
//            .unsigned => if (value != 0) value else error.SdlError,
//        },
//        else => comptime unreachable,
//    };
//}

//const ErrorStore = struct {
//    const status_not_stored = 0;
//    const status_storing = 1;
//    const status_stored = 2;
//
//    status: core.sdl.SDL_AtomicInt = .{},
//    err: anyerror = undefined,
//    trace_index: usize = undefined,
//    trace_addrs: [32]usize = undefined,
//
//    fn reset(es: *ErrorStore) void {
//        _ = core.sdl.SDL_SetAtomicInt(&es.status, status_not_stored);
//    }
//
//    fn store(es: *ErrorStore, err: anyerror) core.sdl.SDL_AppResult {
//        if (core.sdl.SDL_CompareAndSwapAtomicInt(&es.status, status_not_stored, status_storing)) {
//            es.err = err;
//            if (@errorReturnTrace()) |src_trace| {
//                es.trace_index = src_trace.index;
//                const len = @min(es.trace_addrs.len, src_trace.instruction_addresses.len);
//                @memcpy(es.trace_addrs[0..len], src_trace.instruction_addresses[0..len]);
//            }
//            _ = core.sdl.SDL_SetAtomicInt(&es.status, status_stored);
//        }
//        return core.sdl.SDL_APP_FAILURE;
//    }
//
//    fn load(es: *ErrorStore) ?anyerror {
//        if (core.sdl.SDL_GetAtomicInt(&es.status) != status_stored) return null;
//        if (@errorReturnTrace()) |dst_trace| {
//            dst_trace.index = es.trace_index;
//            const len = @min(dst_trace.instruction_addresses.len, es.trace_addrs.len);
//            @memcpy(dst_trace.instruction_addresses[0..len], es.trace_addrs[0..len]);
//        }
//        return es.err;
//    }
//};
//var app_err: ErrorStore = .{};

//fn sdlAppInit(appstate: ?*?*anyopaque, argv: [][*:0]u8) !core.sdl.SDL_AppResult {
//    _ = appstate;
//    _ = argv;
//    std.log.debug("SDL build time version: {d}.{d}.{d}", .{
//        core.sdl.SDL_MAJOR_VERSION,
//        core.sdl.SDL_MINOR_VERSION,
//        core.sdl.SDL_MICRO_VERSION,
//    });
//    std.log.debug("SDL build time revision: {s}", .{core.sdl.SDL_REVISION});
//    {
//        const version = core.sdl.SDL_GetVersion();
//        std.log.debug("SDL runtime version: {d}.{d}.{d}", .{
//            core.sdl.SDL_VERSIONNUM_MAJOR(version),
//            core.sdl.SDL_VERSIONNUM_MINOR(version),
//            core.sdl.SDL_VERSIONNUM_MICRO(version),
//        });
//        const revision: [*:0]const u8 = core.sdl.SDL_GetRevision();
//        std.log.debug("SDL runtime revision: {s}", .{revision});
//    }
//
//    try errify(core.sdl.SDL_SetAppMetadata("Speedbreaker", "0.0.0", "example.zig-examples.breakout"));
//
//    try errify(core.sdl.SDL_Init(sdl3.SDL_INIT_VIDEO));
//    // We don't need to call 'SDL_Quit()' when using main callbacks.
//
//    timekeeper = .{ .tocks_per_s = core.sdl.SDL_GetPerformanceFrequency() };
//    window = try errify(core.sdl.SDL_CreateWindow("00-helloworld", 640, 480, sdl3.SDL_WINDOW_RESIZABLE));
//    errdefer core.sdl.SDL_DestroyWindow(window);
//    renderer = try rhi.Renderer.init(allocator, .{
//        .vk = .{ .app_name = "GraphicsKernel", .enable_validation_layer = true },
//    });
//
//    const window_handle: rhi.WindowHandle = p: {
//        if (builtin.os.tag == .windows) {} else if (builtin.os.tag == .linux) {
//            if (std.mem.eql(u8, std.mem.sliceTo(core.sdl.SDL_GetCurrentVideoDriver(), 0), "x11")) {
//                break :p rhi.WindowHandle{ .x11 = .{
//                    .display = core.sdl.SDL_GetPointerProperty(sdl3.SDL_GetWindowProperties(window), sdl3.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null).?,
//                    .window = @intCast(core.sdl.SDL_GetNumberProperty(sdl3.SDL_GetWindowProperties(window), sdl3.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0)),
//                } };
//            } else if (std.mem.eql(u8, std.mem.sliceTo(core.sdl.SDL_GetCurrentVideoDriver(), 0), "wayland")) {
//                break :p rhi.WindowHandle{ .wayland = .{ .display = core.sdl.SDL_GetPointerProperty(sdl3.SDL_GetWindowProperties(window), sdl3.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null).?, .surface = sdl3.SDL_GetPointerProperty(sdl3.SDL_GetWindowProperties(window), sdl3.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null).?, .shell_surface = null } };
//            }
//        } else if (builtin.os.tag == .macos or builtin.os.tag == .ios) {}
//        return error.SdlError;
//    };
//    renderer = try rhi.Renderer.init(allocator, .{
//        .vk = .{ .app_name = "GraphicsKernel", .enable_validation_layer = true },
//    });
//    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(allocator, &renderer);
//    errdefer adapters.deinit(allocator);
//
//    var selected_adapter_index: usize = 0;
//    for (adapters.items, 0..) |adp, idx| {
//        if (@intFromEnum(adp.adapter_type) > @intFromEnum(adapters.items[selected_adapter_index].adapter_type))
//            selected_adapter_index = idx;
//        if (@intFromEnum(adp.adapter_type) < @intFromEnum(adapters.items[selected_adapter_index].adapter_type))
//            continue;
//
//        if (@intFromEnum(adp.preset_level) > @intFromEnum(adapters.items[selected_adapter_index].preset_level))
//            selected_adapter_index = idx;
//        if (@intFromEnum(adp.preset_level) < @intFromEnum(adapters.items[selected_adapter_index].preset_level))
//            continue;
//
//        if (adp.video_memory_size > adapters.items[selected_adapter_index].video_memory_size)
//            selected_adapter_index = idx;
//    }
//    var device = try rhi.Device.init(allocator, &renderer, &adapters.items[selected_adapter_index]);
//    var swapchain = try rhi.Swapchain.init(allocator, &renderer, &device, 640, 480, &device.graphics_queue, window_handle, .{});
//    //opaque_layout = try rhi.PipelineLayout.init(allocator, &renderer, &device, .{});
//
//    //opaque_pass = .{ .backend = .{ .vk = .{ .pipeline = p: {
//    //    const vert_spv = rhi.vulkan.toShaderBytecode(@embedFile("spv/opaque.vert.spv"));
//    //    const frag_spv = rhi.vulkan.toShaderBytecode(@embedFile("spv/opaque.frag.spv"));
//
//    //    const opauqe_vert = try rhi.vulkan.create_embeded_module(&vert_spv, &device);
//    //    defer rhi.volk.c.vkDestroyShaderModule.?(device.backend.vk.device, opauqe_vert, null);
//    //    const opaque_frag = try rhi.vulkan.create_embeded_module(&frag_spv, &device);
//    //    defer rhi.volk.c.vkDestroyShaderModule.?(device.backend.vk.device, opaque_frag, null);
//
//    //    var colorAttachments = rhi.volk.c.VkPipelineColorBlendAttachmentState{ .blendEnable = rhi.volk.c.VK_FALSE };
//    //    var colorBlendState = rhi.volk.c.VkPipelineColorBlendStateCreateInfo{
//    //        .sType = rhi.volk.c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
//    //        .pAttachments = &colorAttachments,
//    //        .attachmentCount = 1,
//    //    };
//    //    var viewportState = rhi.volk.c.VkPipelineViewportStateCreateInfo{
//    //        .sType = rhi.volk.c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
//    //        .viewportCount = 1,
//    //    };
//
//    //    const shader_modules = [_]rhi.volk.c.VkPipelineShaderStageCreateInfo{
//    //        .{
//    //            .sType = rhi.volk.c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
//    //            .stage = rhi.volk.c.VK_SHADER_STAGE_VERTEX_BIT,
//    //            .module = opauqe_vert,
//    //            .pName = "main",
//    //        },
//    //        .{
//    //            .sType = rhi.volk.c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
//    //            .stage = rhi.volk.c.VK_SHADER_STAGE_FRAGMENT_BIT,
//    //            .module = opaque_frag,
//    //            .pName = "main",
//    //        },
//    //    };
//
//    //    var rasterizationState = rhi.volk.c.VkPipelineRasterizationStateCreateInfo{ .sType = rhi.volk.c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = rhi.volk.c.VK_POLYGON_MODE_FILL, .cullMode = rhi.volk.c.VK_CULL_MODE_NONE, .frontFace = rhi.volk.c.VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0 };
//
//    //    var multisampleState = rhi.volk.c.VkPipelineMultisampleStateCreateInfo{ .sType = rhi.volk.c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = rhi.volk.c.VK_SAMPLE_COUNT_1_BIT };
//    //    const vertextbindingDesc = [_]rhi.volk.c.VkVertexInputAttributeDescription{.{ .format = rhi.format.to_vk_format(rhi.Format.rgb32_sfloat), .location = 0, .offset = 0 }};
//    //    const vertexInputStreamDesc = [_]rhi.volk.c.VkVertexInputBindingDescription{.{ .binding = 0, .stride = @sizeOf(f32) * 3, .inputRate = rhi.volk.c.VK_VERTEX_INPUT_RATE_VERTEX }};
//    //    const vertexInputState = rhi.volk.c.VkPipelineVertexInputStateCreateInfo{ .sType = rhi.volk.c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .vertexAttributeDescriptionCount = vertextbindingDesc.len, .pVertexAttributeDescriptions = vertextbindingDesc[0..].ptr, .vertexBindingDescriptionCount = vertexInputStreamDesc.len, .pVertexBindingDescriptions = vertexInputStreamDesc[0..].ptr };
//    //    var pipeline_create_info = rhi.volk.c.VkGraphicsPipelineCreateInfo{
//    //        .sType = rhi.volk.c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
//    //        .pViewportState = &viewportState,
//    //        .pColorBlendState = &colorBlendState,
//    //        .pStages = shader_modules[0..].ptr,
//    //        .stageCount = shader_modules.len,
//    //        .layout = opaque_layout.backend.vk.layout,
//    //        .pMultisampleState = &multisampleState,
//    //        .pRasterizationState = &rasterizationState,
//    //        .pVertexInputState = &vertexInputState,
//    //    };
//    //    var res: rhi.volk.c.VkPipeline = undefined;
//    //    try rhi.vulkan.wrap_err(rhi.volk.c.vkCreateGraphicsPipelines.?(device.backend.vk.device, null, 1, &pipeline_create_info, null, &res));
//    //    break :p res;
//    //} } } };
//
//    graphics_cmd_ring = try CmdRingBuffer.init(&renderer, &device, &device.graphics_queue);
//
//    return core.sdl.SDL_APP_CONTINUE;
//}

//fn sdlAppEvent(appstate: ?*anyopaque, event: *core.sdl.SDL_Event) !sdl3.SDL_AppResult {
//    _ = appstate;
//    switch (event.type) {
//        core.sdl.SDL_EVENT_QUIT => {
//            return core.sdl.SDL_APP_SUCCESS;
//        },
//        core.sdl.SDL_EVENT_WINDOW_RESIZED => {
//           @atomicStore(bool, &dirty_resize, true, .monotonic);
//        },
//        else => {},
//    }
//    return core.sdl.SDL_APP_CONTINUE;
//}

//fn sdlAppIterate(appstate: ?*anyopaque) !core.sdl.SDL_AppResult {
//    _ = appstate;
//
//    while (timekeeper.consume()) {}
//
//    // draw
//    {
//        if (@atomicRmw(bool, &dirty_resize, .Xchg, false, .monotonic) == true) {
//            var w: c_int = 0;
//            var h: c_int = 0;
//            if (core.sdl.SDL_GetWindowSize(window, &w, &h)) {
//                _ = try swapchain.resize(&renderer, &device, @intCast(w), @intCast(h));
//            } else {
//                std.log.err("{s}", .{core.sdl.SDL_GetError()});
//            }
//        }
//
//        graphics_cmd_ring.advance();
//        const swapchain_index = try swapchain.acquire_next_image(&renderer, &device);
//        var ring_element = graphics_cmd_ring.get(&renderer, 1);
//        try ring_element.wait(&renderer, &device); // Wait for the GPU to finish with this command buffer
//
//        try ring_element.pool.reset(&renderer, &device); // Reset the pool (which also resets the command buffers)
//        try ring_element.cmds[0].begin(&renderer, &device);
//        if (rhi.is_target_selected(.vk, &renderer)) {
//            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
//            const img = swapchain.image(&renderer, swapchain_index);
//            const image_view = swapchain.image_view(&renderer, swapchain_index);
//            {
//                var barriers = [_]rhi.vulkan.vk.ImageMemoryBarrier2{.{
//                    .src_stage_mask = .{},
//                    .src_access_mask = .{},
//                    .dst_stage_mask = .{ .color_attachment_output_bit = true },
//                    .dst_access_mask = .{ .color_attachment_write_bit = true },
//                    .old_layout = .undefined,
//                    .new_layout = .color_attachment_optimal,
//                    .src_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
//                    .dst_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
//                    .image = img.backend.vk.image,
//                    .subresource_range = .{
//                        .aspect_mask = rhi.vulkan.determains_aspect_mask(swapchain.backend.vk.format, false),
//                        .base_mip_level = 0,
//                        .level_count = 1,
//                        .base_array_layer = 0,
//                        .layer_count = 1,
//                    },
//                }};
//                var dependency_info = rhi.vulkan.vk.DependencyInfo{
//                    .image_memory_barrier_count = barriers.len,
//                    .p_image_memory_barriers = barriers[0..].ptr,
//                };
//                dkb.cmdPipelineBarrier2(ring_element.cmds[0].backend.vk.cmd, &dependency_info);
//            }
//            {
//                var color_attachment = [_]rhi.vulkan.vk.RenderingAttachmentInfo{.{
//                    .resolve_mode = .{},
//                    .resolve_image_layout = .undefined,
//                    .image_view = image_view.vk,
//                    .image_layout = .color_attachment_optimal,
//                    .load_op = .clear,
//                    .store_op = .store,
//                    .clear_value = .{ .color = .{ .float_32 = [4]f32{ 0.0, 0.0, 0.0, 1.0 } } },
//                }};
//
//                var rending_info = rhi.vulkan.vk.RenderingInfo{
//                    .render_area = .{
//                        .offset = .{ .x = 0, .y = 0 },
//                        .extent = .{ .width = swapchain.width, .height = swapchain.height },
//                    },
//                    .view_mask = 0,
//                    .layer_count = 1,
//                    .color_attachment_count = 1,
//                    .p_color_attachments = &color_attachment,
//                };
//                dkb.cmdBeginRendering(ring_element.cmds[0].backend.vk.cmd, &rending_info);
//            }
//
//            const clear_ops = [_]struct {
//                clear_color: [4]f32,
//                clear_rect: rhi.vulkan.vk.Rect2D,
//            }{
//                .{ .clear_color = [4]f32{ 0.0, 0.0, 0.0, 1.0 }, .clear_rect = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = swapchain.width / 2, .height = swapchain.height / 2 } } },
//                .{ .clear_color = [4]f32{ 1.0, 0.0, 0.0, 1.0 }, .clear_rect = .{ .offset = .{ .x = @intCast(swapchain.width / 2), .y = 0 }, .extent = .{ .width = swapchain.width / 2, .height = swapchain.height / 2 } } },
//                .{ .clear_color = [4]f32{ 0.0, 1.0, 0.0, 1.0 }, .clear_rect = .{ .offset = .{ .x = 0, .y = @intCast(swapchain.height / 2) }, .extent = .{ .width = swapchain.width / 2, .height = swapchain.height / 2 } } },
//                .{ .clear_color = [4]f32{ 0.0, 0.0, 1.0, 1.0 }, .clear_rect = .{ .offset = .{ .x = @intCast(swapchain.width / 2), .y = @intCast(swapchain.height / 2) }, .extent = .{ .width = swapchain.width / 2, .height = swapchain.height / 2 } } },
//            };
//            for (clear_ops) |cr| {
//                var clearRect = [_]rhi.vulkan.vk.ClearRect{.{
//                    .rect = cr.clear_rect,
//                    .base_array_layer = 0,
//                    .layer_count = 1,
//                }};
//                var clearAttachment = [_]rhi.vulkan.vk.ClearAttachment{.{
//                    .aspect_mask = .{ .color_bit = true }, //rhi.volk.c.VK_IMAGE_ASPECT_COLOR_BIT,
//                    .color_attachment = 0,
//                    .clear_value = .{ .color = .{ .float_32 = cr.clear_color } },
//                }};
//                dkb.cmdClearAttachments(ring_element.cmds[0].backend.vk.cmd, @intCast(clearAttachment.len), clearAttachment[0..].ptr, @intCast(clearRect.len), clearRect[0..].ptr);
//            }
//
//            dkb.cmdEndRendering(ring_element.cmds[0].backend.vk.cmd);
//
//            {
//                var barriers = [_]rhi.vulkan.vk.ImageMemoryBarrier2{.{
//                    .src_stage_mask = .{ .color_attachment_output_bit = true },
//                    .src_access_mask = .{ .color_attachment_write_bit = true },
//                    .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
//                    .dst_access_mask = .{},
//                    .old_layout = .color_attachment_optimal,
//                    .new_layout = .present_src_khr,
//                    .src_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
//                    .dst_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
//                    .image = img.backend.vk.image,
//                    .subresource_range = .{
//                        .aspect_mask = rhi.vulkan.determains_aspect_mask(swapchain.backend.vk.format, false),
//                        .base_mip_level = 0,
//                        .level_count = 1,
//                        .base_array_layer = 0,
//                        .layer_count = 1,
//                    },
//                }};
//                var dependency_info = rhi.vulkan.vk.DependencyInfo{
//                    .image_memory_barrier_count = barriers.len,
//                    .p_image_memory_barriers = barriers[0..].ptr,
//                };
//                dkb.cmdPipelineBarrier2(ring_element.cmds[0].backend.vk.cmd, &dependency_info);
//            }
//
//            try ring_element.cmds[0].end(&renderer, &device);
//
//            const cmd_submit = [_]rhi.vulkan.vk.CommandBufferSubmitInfo{.{
//                .command_buffer = ring_element.cmds[0].backend.vk.cmd,
//                .device_mask = 0,
//            }};
//
//            const wait_semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
//                .semaphore = swapchain.backend.vk.current_semaphore(),
//                .stage_mask = .{ .color_attachment_output_bit = true },
//                .value = 0,
//                .device_index = 0,
//            }};
//
//            const semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
//                .semaphore = ring_element.backend.vk.semaphore,
//                .value = 0,
//                .stage_mask = .{
//                    .all_commands_bit = true,
//                },
//                .device_index = 0,
//            }};
//
//            var submit_info = [_]rhi.vulkan.vk.SubmitInfo2{.{ .p_command_buffer_infos = cmd_submit[0..].ptr, .command_buffer_info_count = cmd_submit.len, .p_wait_semaphore_infos = wait_semaphore_info[0..].ptr, .wait_semaphore_info_count = wait_semaphore_info.len, .p_signal_semaphore_infos = semaphore_info[0..].ptr, .signal_semaphore_info_count = semaphore_info.len }};
//            std.debug.assert(try dkb.getFenceStatus(device.backend.vk.device, ring_element.backend.vk.fence) == .success);
//            const reset_fence = [_]rhi.vulkan.vk.Fence{ring_element.backend.vk.fence};
//            _ = try dkb.resetFences(device.backend.vk.device, reset_fence.len, reset_fence[0..].ptr);
//            _ = try dkb.queueSubmit2(device.graphics_queue.backend.vk.queue, 1, submit_info[0..].ptr, ring_element.backend.vk.fence);
//
//            var swapchains = [_]rhi.vulkan.vk.SwapchainKHR{swapchain.backend.vk.swapchain};
//            var image_indecies = [_]u32{swapchain_index};
//            var wait_semaphores = [_]rhi.vulkan.vk.Semaphore{ring_element.backend.vk.semaphore};
//            var present_info = rhi.vulkan.vk.PresentInfoKHR{
//                .swapchain_count = 1,
//                .p_swapchains = swapchains[0..].ptr,
//                .p_image_indices = image_indecies[0..].ptr,
//                .wait_semaphore_count = wait_semaphores.len,
//                .p_wait_semaphores = wait_semaphores[0..].ptr,
//            };
//            _ = try dkb.queuePresentKHR(device.graphics_queue.backend.vk.queue, &present_info);
//        }
//    }
//    timekeeper.produce(core.sdl.SDL_GetPerformanceCounter());
//    return core.sdl.SDL_APP_CONTINUE;
//}

//fn sdlAppQuit(appstate: ?*anyopaque, result: anyerror!core.sdl.SDL_AppResult) void {
//    _ = appstate;
//    _ = result catch |err| if (err == error.SdlError) {
//        std.log.err("{s}", .{core.sdl.SDL_GetError()});
//    };
//    device.graphics_queue.wait_queue_idle(&renderer, &device) catch |err| {
//        std.log.err("Failed to wait graphics queue idle: {}", .{err});
//    };
//
//    graphics_cmd_ring.deinit(&renderer, &device);
//    swapchain.deinit(&renderer, &device);
//    device.deinit(&renderer);
//    renderer.deinit();
//}

//fn sdlAppInitC(appstate: ?*?*anyopaque, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) core.sdl.SDL_AppResult {
//    return sdlAppInit(appstate.?, @ptrCast(argv.?[0..@intCast(argc)])) catch |err| app_err.store(err);
//}
//
//fn sdlAppIterateC(appstate: ?*anyopaque) callconv(.c) core.sdl.SDL_AppResult {
//    return sdlAppIterate(appstate) catch |err| app_err.store(err);
//}
//
//fn sdlAppEventC(appstate: ?*anyopaque, event: ?*core.sdl.SDL_Event) callconv(.c) core.sdl.SDL_AppResult {
//    return sdlAppEvent(appstate, event.?) catch |err| app_err.store(err);
//}
//
//fn sdlAppQuitC(appstate: ?*anyopaque, result: core.sdl.SDL_AppResult) callconv(.c) void {
//    sdlAppQuit(appstate, app_err.load() orelse result);
//}
//
//fn sdlMainC(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
//    return core.sdl.SDL_EnterAppMainCallbacks(argc, @ptrCast(argv), sdlAppInitC, sdlAppIterateC, sdlAppEventC, sdlAppQuitC);
//}

//fn quit_handler(cntx: *AppContext) void {
//    _ = cntx;
//    std.debug.print("Quit handler called\n", .{});
//}
fn iterate_handler(cntx: *AppContext) anyerror!core.sdl.SDL_AppResult {
    while (cntx.timekeeper.consume()) {}

    // draw
    {
        if (@atomicRmw(bool, &cntx.dirty_resize, .Xchg, false, .monotonic) == true) {
            var w: c_int = 0;
            var h: c_int = 0;
            if (core.sdl.SDL_GetWindowSize(cntx.window, &w, &h)) {
                _ = try cntx.swapchain.resize(&cntx.renderer, &cntx.device, @intCast(w), @intCast(h));
            } else {
                std.log.err("{s}", .{core.sdl.SDL_GetError()});
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
                        .aspect_mask = rhi.vulkan.determains_aspect_mask(cntx.swapchain.backend.vk.format, false),
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
                        .aspect_mask = rhi.vulkan.determains_aspect_mask(cntx.swapchain.backend.vk.format, false),
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

            var submit_info = [_]rhi.vulkan.vk.SubmitInfo2{.{ .p_command_buffer_infos = cmd_submit[0..].ptr, .command_buffer_info_count = cmd_submit.len, .p_wait_semaphore_infos = wait_semaphore_info[0..].ptr, .wait_semaphore_info_count = wait_semaphore_info.len, .p_signal_semaphore_infos = semaphore_info[0..].ptr, .signal_semaphore_info_count = semaphore_info.len }};
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
    cntx.timekeeper.produce(core.sdl.SDL_GetPerformanceCounter());
    return core.sdl.SDL_APP_CONTINUE;
}

fn app_init(argv: [][*:0]u8) anyerror!core.InitResult(AppContext) {
    _ = argv;
    if (core.sdl.SDL_SetAppMetadata("Tabletop", "0.0.0", "tabletop") == false) {
        return error.SetAppMetadataFailed;
    }
    if (core.sdl.SDL_Init(core.sdl.SDL_INIT_VIDEO) == false) {
        return error.SDLInitFailed;
    }

    const window = core.sdl.SDL_CreateWindow("00-helloworld", 640, 480, core.sdl.SDL_WINDOW_RESIZABLE);
    if (window == null) return error.CreateWindowFailed;
    errdefer core.sdl.SDL_DestroyWindow(window);

    const window_handle: rhi.WindowHandle = p: {
        if (builtin.os.tag == .windows) {} else if (builtin.os.tag == .linux) {
            if (std.mem.eql(u8, std.mem.sliceTo(core.sdl.SDL_GetCurrentVideoDriver(), 0), "x11")) {
                break :p rhi.WindowHandle{ .x11 = .{
                    .display = core.sdl.SDL_GetPointerProperty(core.sdl.SDL_GetWindowProperties(window), core.sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null).?,
                    .window = @intCast(core.sdl.SDL_GetNumberProperty(core.sdl.SDL_GetWindowProperties(window), core.sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0)),
                } };
            } else if (std.mem.eql(u8, std.mem.sliceTo(core.sdl.SDL_GetCurrentVideoDriver(), 0), "wayland")) {
                break :p rhi.WindowHandle{ .wayland = .{ .display = core.sdl.SDL_GetPointerProperty(core.sdl.SDL_GetWindowProperties(window), core.sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null).?, .surface = core.sdl.SDL_GetPointerProperty(core.sdl.SDL_GetWindowProperties(window), core.sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null).?, .shell_surface = null } };
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
        .timekeeper = .{ .tocks_per_s = core.sdl.SDL_GetPerformanceFrequency() },
        .dirty_resize = false,
        .graphics_cmd_ring = try CmdRingBuffer.init(&renderer, &device, &device.graphics_queue),
    };
    return .{
        .cntx = application,
        .result = core.sdl.SDL_APP_CONTINUE,
    };
}

fn app_quit(cntx: *AppContext, result: core.sdl.SDL_AppResult) void {
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

fn app_event(cntx: *AppContext, event: *core.sdl.SDL_Event) anyerror!core.sdl.SDL_AppResult {
    switch (event.type) {
        core.sdl.SDL_EVENT_QUIT => {
            return core.sdl.SDL_APP_SUCCESS;
        },
        core.sdl.SDL_EVENT_WINDOW_RESIZED => {
            @atomicStore(bool, &cntx.dirty_resize, true, .monotonic);
        },
        else => {},
    }
    return core.sdl.SDL_APP_CONTINUE;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();

    _ = core.SdlApplicaton(AppContext, .{
        .iterate_handler = iterate_handler,
        .app_init = app_init,
        .app_event = app_event,
        .app_quit = app_quit,
    }).exec();
}
