const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");
const core = @import("core");

pub const ResourceLoader = rhi.ResourceLoader(.{ .max_sets = 2, .buffer_size = 8 * 1024 * 1024 });
pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });
var allocator: std.mem.Allocator = undefined;
pub const AppContext = struct {
    window: *core.sdl.SDL_Window = undefined,
    allocator: std.mem.Allocator = undefined,
    renderer: rhi.Renderer = undefined,
    swapchain: rhi.Swapchain = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    resource_loader: ResourceLoader = undefined,
    dirty_resize: bool = false,
    graphics_cmd_ring: CmdRingBuffer = undefined,
    pipeline: rhi.vulkan.vk.Pipeline = undefined,
    layout: rhi.vulkan.vk.PipelineLayout = undefined,
};

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
            dkb.cmdBindPipeline(ring_element.cmds[0].backend.vk.cmd, .graphics, cntx.pipeline);
            dkb.cmdDraw(ring_element.cmds[0].backend.vk.cmd, 3, 1, 0, 0);

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
    const fullscreen_vs = std.fs.cwd().readFileAllocOptions("spv/fullscreen.vert.spv", allocator, .unlimited, .@"4", null) catch |err| {
        std.log.err("Failed to open vertex file: {}", .{err});
        return err;
    };
    defer allocator.free(fullscreen_vs);
    const mandelbrot_fs = std.fs.cwd().readFileAllocOptions("spv/mandelbrot.frag.spv", allocator, .unlimited, .@"4", null) catch |err| {
        std.log.err("Failed to open fragment file: {}", .{err});
        return err;
    };
    defer allocator.free(mandelbrot_fs);
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    var shader_module_create_vs: rhi.vulkan.vk.ShaderModuleCreateInfo = .{
        .code_size = fullscreen_vs.len,
        .p_code = @ptrCast(fullscreen_vs.ptr),
    };
    const vs_module = dkb.createShaderModule(device.backend.vk.device, &shader_module_create_vs, null) catch |err| {
        std.log.err("Failed to create vertex shader module: {}", .{err});
        return err;
    };
    defer dkb.destroyShaderModule(device.backend.vk.device, vs_module, null);
    var shader_module_create_fs: rhi.vulkan.vk.ShaderModuleCreateInfo = .{
        .code_size = mandelbrot_fs.len,
        .p_code = @ptrCast(mandelbrot_fs.ptr),
    };
    const fs_module = dkb.createShaderModule(device.backend.vk.device, &shader_module_create_fs, null) catch |err| {
        std.log.err("Failed to create fragment shader module: {}", .{err});
        return err;
    };
    defer dkb.destroyShaderModule(device.backend.vk.device, fs_module, null);

    var stages = [_]rhi.vulkan.vk.PipelineShaderStageCreateInfo{ .{
        .stage = .{ .vertex_bit = true },
        .module = vs_module,
        .p_name = "main",
    }, .{
        .stage = .{ .fragment_bit = true },
        .module = fs_module,
        .p_name = "main",
    } };
    var color_attachment_desc = [_]rhi.vulkan.vk.PipelineColorBlendAttachmentState{.{
        .blend_enable = .true,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
        },
    }};
    var dynamic_states = [_]rhi.vulkan.vk.DynamicState{
        .viewport,
        .scissor,
    };
    var dynamic_state: rhi.vulkan.vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };
    var pipeline_blend_state: rhi.vulkan.vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .clear,
        .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        .attachment_count = color_attachment_desc.len,
        .p_attachments = &color_attachment_desc,
    };
    var viewport_state: rhi.vulkan.vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = 1,
        .scissor_count = 1,
    };
    var rasterization_state: rhi.vulkan.vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{
            .front_bit = false,
            .back_bit = false,
        },
        .front_face = .clockwise,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_slope_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_enable = .false,
        .line_width = 1.0,
    };
    var pipeline_input_assembly = rhi.vulkan.vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };
    var multisample_state = rhi.vulkan.vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    var vertex_input_state = rhi.vulkan.vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 0,
        .vertex_attribute_description_count = 0,
    };
    var pipeline_layout_info = rhi.vulkan.vk.PipelineLayoutCreateInfo{
        .set_layout_count = 0,
        .push_constant_range_count = 0,
    };
    const pipeline_layout = try dkb.createPipelineLayout(device.backend.vk.device, &pipeline_layout_info, null);
    errdefer dkb.destroyPipelineLayout(device.backend.vk.device, pipeline_layout, null);
    var pipeline_create_info = [1]rhi.vulkan.vk.GraphicsPipelineCreateInfo{.{
        .stage_count = stages.len,
        .p_stages = &stages,
        .subpass = 0,
        .layout = pipeline_layout,
        .base_pipeline_index = -1,
        .p_color_blend_state = &pipeline_blend_state,
        .p_rasterization_state = &rasterization_state,
        .p_multisample_state = &multisample_state,
        .p_vertex_input_state = &vertex_input_state,
        .p_viewport_state = &viewport_state,
        .p_input_assembly_state = &pipeline_input_assembly,
        .p_dynamic_state = &dynamic_state,
    }};
    var color_attachments = [_]rhi.vulkan.vk.Format{swapchain.backend.vk.format};
    var pipeline_render_info: rhi.vulkan.vk.PipelineRenderingCreateInfo = .{
        .color_attachment_count = color_attachments.len,
        .p_color_attachment_formats = &color_attachments,
        .view_mask = 0,
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };
    rhi.vulkan.add_next(&pipeline_create_info[0], &pipeline_render_info);
    var pipeline: [1]rhi.vulkan.vk.Pipeline = .{.null_handle};
    _ = try dkb.createGraphicsPipelines(device.backend.vk.device, .null_handle, 1, &pipeline_create_info, null, &pipeline);

    application.* = .{
        .window = window.?,
        .allocator = allocator,
        .renderer = renderer,
        .swapchain = swapchain,
        .device = device,
        .timekeeper = .{ .tocks_per_s = core.sdl.SDL_GetPerformanceFrequency() },
        .dirty_resize = false,
        .graphics_cmd_ring = try CmdRingBuffer.init(&renderer, &device, &device.graphics_queue),
        .pipeline = pipeline[0],
        .layout = pipeline_layout,
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

    var dkb: *rhi.vulkan.vk.DeviceWrapper = &cntx.device.backend.vk.dkb;
    dkb.destroyPipeline(cntx.device.backend.vk.device, cntx.pipeline, null);
    dkb.destroyPipelineLayout(cntx.device.backend.vk.device, cntx.layout, null);

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
