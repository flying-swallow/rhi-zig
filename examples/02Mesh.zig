const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");
const sdl_app = @import("./sdl_app.zig");

pub const ResourceLoader = rhi.ResourceLoader(.{ .max_sets = 2, .buffer_size = 8 * 1024 * 1024 });
pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });

pub const Context = struct {
    frame_heap: std.heap.ArenaAllocator = undefined,

    window: *sdl_app.sdl.SDL_Window = undefined,
    renderer: rhi.Renderer = undefined,
    swapchain: rhi.Swapchain = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    resource_loader: ResourceLoader = undefined,
    dirty_resize: bool = false,
    graphics_cmd_ring: CmdRingBuffer = undefined,
    pipeline: rhi.vulkan.vk.Pipeline = undefined,
    layout: rhi.vulkan.vk.PipelineLayout = undefined,

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
            dkb.cmdSetViewport(ring_element.cmds[0].backend.vk.cmd, 0, &viewport);
            dkb.cmdSetScissor(ring_element.cmds[0].backend.vk.cmd, 0, &scissor_rect);
            dkb.cmdBindPipeline(ring_element.cmds[0].backend.vk.cmd, .graphics, cntx.pipeline);

            const vertex_buffers = [_]rhi.vulkan.vk.Buffer{cntx.cube_vertex_buffer.backend.vk.buffer};
            const offsets = [_]rhi.vulkan.vk.DeviceSize{0};
            dkb.cmdBindVertexBuffers(ring_element.cmds[0].backend.vk.cmd, 0, &vertex_buffers, &offsets);
            dkb.cmdBindIndexBuffer(ring_element.cmds[0].backend.vk.cmd, cntx.cube_index_buffer.backend.vk.buffer, 0, .uint16);
           
            const time_f32: f32 = @floatCast(@as(f64, @floatFromInt(std.Io.Clock.real.now(app_context.io).toMilliseconds())) / 1000.0);
            const pc_bytes = std.mem.asBytes(&time_f32);
            dkb.cmdPushConstants(ring_element.cmds[0].backend.vk.cmd, cntx.layout, .{ .vertex_bit = true }, 0, @intCast(pc_bytes.len), pc_bytes.ptr);
            dkb.cmdDrawIndexed(ring_element.cmds[0].backend.vk.cmd, 36, 1, 0, 0, 0);
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

            const flush = try cntx.resource_loader.VKFlushResourceUpdate(app_context.io, &cntx.renderer, &.{});
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

            var submit_info = [_]rhi.vulkan.vk.SubmitInfo2{.{ 
                .p_command_buffer_infos = cmd_submit[0..].ptr, 
                .command_buffer_info_count = cmd_submit.len, 
                .p_wait_semaphore_infos = wait_semaphore_info.items[0..].ptr, 
                .wait_semaphore_info_count = @intCast(wait_semaphore_info.items.len), 
                .p_signal_semaphore_infos = semaphore_info[0..].ptr, 
                .signal_semaphore_info_count = semaphore_info.len 
            }};
            std.debug.assert(try dkb.getFenceStatus(cntx.device.backend.vk.device, ring_element.backend.vk.fence) == .success);
            const reset_fence = [_]rhi.vulkan.vk.Fence{ring_element.backend.vk.fence};
            _ = try dkb.resetFences(cntx.device.backend.vk.device, reset_fence[0..]);
            _ = try dkb.queueSubmit2(cntx.device.graphics_queue.backend.vk.queue, submit_info[0..], ring_element.backend.vk.fence);

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

fn app_init(app_context: *sdl_app.AppContext(Context), argv: [][*:0]u8) anyerror!sdl_app.sdl.SDL_AppResult {
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

    const window_handle = try sdl_app.sdl_window_handle_to_rhi_window_handle(window.?);
    var cntx: *Context = &app_context.inner;

    cntx.renderer = try rhi.Renderer.init(app_context.gpa, .{
        .vk = .{ .app_name = "GraphicsKernel", .enable_validation_layer = true },
    });
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(app_context.gpa, &cntx.renderer);
    defer adapters.deinit(app_context.gpa);

    const selected_adapter_index = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    cntx.device = try rhi.Device.init(app_context.gpa, &cntx.renderer, &adapters.items[selected_adapter_index]);
    cntx.swapchain = try rhi.Swapchain.init(app_context.gpa, &cntx.renderer, &cntx.device, 640, 480, &cntx.device.graphics_queue, window_handle, .{});
    cntx.timekeeper = .{ .tocks_per_s = sdl_app.sdl.SDL_GetPerformanceFrequency() };
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.renderer, &cntx.device, &cntx.device.graphics_queue);
    cntx.dirty_resize = false;
    cntx.resource_loader = try ResourceLoader.init(app_context.gpa, &cntx.renderer, &cntx.device);
    {
        var index_bytes = std.mem.asBytes(&cube_index);
        cntx.cube_index_buffer = try .init_general(&cntx.renderer, &cntx.device, .{
            .size = index_bytes.len,
            .usage = .{ .index_buffer = true },
        });
        var transation: rhi.resource_loader.BufferTransaction = .{ .target = &cntx.cube_index_buffer, .offset = 0, .size = index_bytes.len };
        try cntx.resource_loader.begin_copy_buffer(app_context.io, &cntx.renderer, &transation);
        @memcpy(transation.mapped.memory_range[0..index_bytes.len], index_bytes[0..]);
        try cntx.resource_loader.end_copy_buffer(app_context.io, &cntx.renderer, &transation);
    }
    {
        var cube_bytes = std.mem.asBytes(&cube_mesh);
        cntx.cube_vertex_buffer = try .init_general(&cntx.renderer, &cntx.device, .{
            .size = cube_bytes.len,
            .stride = @sizeOf(f32), 
            .usage = .{ .vertex_buffer = true },
        });
        var transaction: rhi.resource_loader.BufferTransaction = .{ .target = &cntx.cube_vertex_buffer, .offset = 0, .size = cube_bytes.len };
        try cntx.resource_loader.begin_copy_buffer(app_context.io, &cntx.renderer, &transaction);
        @memcpy(transaction.mapped.memory_range[0..cube_bytes.len], cube_bytes[0..]);
        try cntx.resource_loader.end_copy_buffer(app_context.io, &cntx.renderer, &transaction);
    }

    const mesh_vs = std.Io.Dir.cwd().readFileAllocOptions(app_context.io, "example_assets/02_mesh.vert.spv", app_context.gpa, .unlimited, .@"4", null) catch |err| {
        std.log.err("Failed to open vertex file: {}", .{err});
        return err;
    };
    defer app_context.gpa.free(mesh_vs);

    const mesh_fs = std.Io.Dir.cwd().readFileAllocOptions(app_context.io, "example_assets/02_mesh.frag.spv", app_context.gpa, .unlimited, .@"4", null) catch |err| {
        std.log.err("Failed to open fragment file: {}", .{err});
        return err;
    };
    defer app_context.gpa.free(mesh_fs);

    var dkb: *rhi.vulkan.vk.DeviceWrapper = &cntx.device.backend.vk.dkb;
    var shader_module_create_vs: rhi.vulkan.vk.ShaderModuleCreateInfo = .{
        .code_size = mesh_vs.len,
        .p_code = @ptrCast(mesh_vs.ptr),
    };
    const vs_module = dkb.createShaderModule(cntx.device.backend.vk.device, &shader_module_create_vs, null) catch |err| {
        std.log.err("Failed to create vertex shader module: {}", .{err});
        return err;
    };
    defer dkb.destroyShaderModule(cntx.device.backend.vk.device, vs_module, null);

    var shader_module_create_fs: rhi.vulkan.vk.ShaderModuleCreateInfo = .{
        .code_size = mesh_fs.len,
        .p_code = @ptrCast(mesh_fs.ptr),
    };
    const fs_module = dkb.createShaderModule(cntx.device.backend.vk.device, &shader_module_create_fs, null) catch |err| {
        std.log.err("Failed to create fragment shader module: {}", .{err});
        return err;
    };
    defer dkb.destroyShaderModule(cntx.device.backend.vk.device, fs_module, null);

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

    var vertex_binding_descriptions = [_]rhi.vulkan.vk.VertexInputBindingDescription{.{
        .binding = 0,
        .stride = @sizeOf(f32) * 3,
        .input_rate = .vertex,
    }};
    var vertex_attribute_descriptions = [_]rhi.vulkan.vk.VertexInputAttributeDescription{.{
        .location = 0,
        .binding = 0,
        .format = .r32g32b32_sfloat,
        .offset = 0,
    }};

    var vertex_input_state = rhi.vulkan.vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = &vertex_binding_descriptions,
        .vertex_attribute_description_count = 1,
        .p_vertex_attribute_descriptions = &vertex_attribute_descriptions,
    };

    var push_constant_range = [_] rhi.vulkan.vk.PushConstantRange{
        .{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(f32),
        }
    };

    var pipeline_layout_info = rhi.vulkan.vk.PipelineLayoutCreateInfo{
        .set_layout_count = 0,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = &push_constant_range,
    };

    cntx.layout = try dkb.createPipelineLayout(cntx.device.backend.vk.device, &pipeline_layout_info, null);
    errdefer dkb.destroyPipelineLayout(cntx.device.backend.vk.device, cntx.layout, null);

    var pipeline_create_info = [1]rhi.vulkan.vk.GraphicsPipelineCreateInfo{.{
        .stage_count = stages.len,
        .p_stages = &stages,
        .subpass = 0,
        .layout = cntx.layout,
        .base_pipeline_index = -1,
        .p_color_blend_state = &pipeline_blend_state,
        .p_rasterization_state = &rasterization_state,
        .p_multisample_state = &multisample_state,
        .p_vertex_input_state = &vertex_input_state,
        .p_viewport_state = &viewport_state,
        .p_input_assembly_state = &pipeline_input_assembly,
        .p_dynamic_state = &dynamic_state,
    }};
    var color_attachments = [_]rhi.vulkan.vk.Format{cntx.swapchain.backend.vk.format};
    var pipeline_render_info: rhi.vulkan.vk.PipelineRenderingCreateInfo = .{
        .color_attachment_count = color_attachments.len,
        .p_color_attachment_formats = &color_attachments,
        .view_mask = 0,
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };
    rhi.vulkan.add_next(&pipeline_create_info[0], &pipeline_render_info);
    var pipelines: [1]rhi.vulkan.vk.Pipeline = .{.null_handle};
    _ = try dkb.createGraphicsPipelines(cntx.device.backend.vk.device, .null_handle, &pipeline_create_info, null, &pipelines);
    cntx.pipeline = pipelines[0];

    return sdl_app.sdl.SDL_APP_CONTINUE;
}

fn app_quit(app_context: *sdl_app.AppContext(Context), result: sdl_app.sdl.SDL_AppResult) void {
    var cntx: *Context = &app_context.inner;
    cntx.device.graphics_queue.wait_queue_idle(&cntx.renderer, &cntx.device) catch |err| {
        std.log.err("Failed to wait graphics queue idle: {}", .{err});
    };

    var dkb: *rhi.vulkan.vk.DeviceWrapper = &cntx.device.backend.vk.dkb;
    dkb.destroyPipeline(cntx.device.backend.vk.device, cntx.pipeline, null);
    dkb.destroyPipelineLayout(cntx.device.backend.vk.device, cntx.layout, null);

    cntx.resource_loader.deinit(&cntx.renderer);
    cntx.cube_vertex_buffer.deinit(&cntx.renderer, &cntx.device);
    cntx.cube_index_buffer.deinit(&cntx.renderer, &cntx.device);
    cntx.graphics_cmd_ring.deinit(&cntx.renderer, &cntx.device);
    cntx.swapchain.deinit(&cntx.renderer, &cntx.device);
    cntx.device.deinit(&cntx.renderer);
    cntx.renderer.deinit();

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
