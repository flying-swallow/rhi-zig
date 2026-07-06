// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");
const sdl_app = @import("./sdl_app.zig");

const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

const vs_path = if (is_apple) "example_assets/02_mesh.vert.metal" else "example_assets/02_mesh.vert.spv";
const fs_path = if (is_apple) "example_assets/02_mesh.frag.metal" else "example_assets/02_mesh.frag.spv";

const PushConsts = extern struct {
    time: f32,
    aspect: f32,
    y_sign: f32,
};

pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });

pub const Context = struct {
    window: *sdl_app.sdl.SDL_Window = undefined,
    swapchain: rhi.Swapchain = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    dirty_resize: bool = false,
    graphics_cmd_ring: CmdRingBuffer = undefined,
    shader: rhi.Shader = undefined,
    pipeline: rhi.Pipeline = undefined,
    depth_image: rhi.Image = undefined,
    depth_view: rhi.ImageView = undefined,
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
    0.5,  -0.5, -0.5, // V1
    -0.5, 0.5,  -0.5, // V2
    0.5,  0.5,  -0.5, // V3
    -0.5, -0.5, 0.5, // V4
    0.5,  -0.5, 0.5, // V5
    -0.5, 0.5,  0.5, // V6
    0.5,  0.5,  0.5, // V7
};

fn iterate_handler(app_context: *sdl_app.AppContext(Context)) anyerror!sdl_app.sdl.SDL_AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}

    if (@atomicRmw(bool, &cntx.dirty_resize, .Xchg, false, .monotonic) == true) {
        var w: c_int = 0;
        var h: c_int = 0;
        if (sdl_app.sdl.SDL_GetWindowSize(cntx.window, &w, &h)) {
            _ = try cntx.swapchain.resize(&cntx.device, @intCast(w), @intCast(h));
            cntx.depth_view.deinit(&cntx.device);
            cntx.depth_image.deinit(&cntx.device);
            cntx.depth_image = try rhi.Image.init(&cntx.device, .{
                .format = .d32_sfloat,
                .width = @intCast(w),
                .height = @intCast(h),
                .usage = .{ .depth_stencil_attachment = true },
                .memory_usage = .prefer_device,
            });
            cntx.depth_view = try rhi.ImageView.init(&cntx.device, &cntx.depth_image, .{
                .format = .d32_sfloat,
                .aspect = .depth,
            });
        } else {
            std.log.err("{s}", .{sdl_app.sdl.SDL_GetError()});
        }
    }

    cntx.graphics_cmd_ring.advance();
    const swapchain_index = try cntx.swapchain.acquire_next_image(&cntx.device);
    var ring_element = cntx.graphics_cmd_ring.get(&cntx.device,1);
    try ring_element.wait(&cntx.device);

    try ring_element.pool.reset(&cntx.device);
    var cmd = &ring_element.cmds[0];
    try cmd.begin(&cntx.device);

    var img = cntx.swapchain.image(swapchain_index);
    const view = cntx.swapchain.image_view(swapchain_index);
    const w = cntx.swapchain.width;
    const h = cntx.swapchain.height;

    var depth_img = cntx.depth_image;
    cmd.resource_barrier(&cntx.device,.{ .image = 2 }, .{ .image_barriers = &.{
        .{ .image = &img, .before = .{}, .after = .{ .render_target = true } },
        .{ .image = &depth_img, .before = .{}, .after = .{ .depth_write = true }, .aspect = .depth },
    } });

    cmd.begin_rendering(&cntx.device,.{
        .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ 0.0, 0.0, 0.0, 1.0 },
        }},
        .depth_attachment = .{
            .view = cntx.depth_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_depth = 1.0,
        },
        .render_area = .{ .width = w, .height = h },
    });

    cmd.set_viewport(&cntx.device,.{ .width = @floatFromInt(w), .height = @floatFromInt(h) });
    cmd.set_scissor(&cntx.device,.{ .width = w, .height = h });
    cmd.bind_pipeline(&cntx.device,&cntx.pipeline);
    cmd.bind_vertex_buffer(&cntx.device,&cntx.cube_vertex_buffer, 0);
    cmd.bind_index_buffer(&cntx.device,&cntx.cube_index_buffer, .uint16);

    const pc: PushConsts = .{
        .time = @as(f32, @floatFromInt(sdl_app.sdl.SDL_GetTicks())) / 1000.0,
        .aspect = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h)),
        .y_sign = if (is_apple) 1.0 else -1.0,
    };
    cmd.set_push_constants(&cntx.device,&cntx.pipeline, std.mem.asBytes(&pc));
    cmd.draw_indexed(&cntx.device,.{ .index_count = 36 });

    cmd.end_rendering(&cntx.device);

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

    try rhi.Renderer.init(app_context.gpa, if (is_apple)
        .{ .mtl = .{} }
    else
        .{ .vk = .{ .app_name = "GraphicsKernel", .enable_validation_layer = true } });
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(app_context.gpa);
    defer adapters.deinit(app_context.gpa);

    const selected_adapter_index = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    cntx.device = try rhi.Device.init(app_context.gpa, &adapters.items[selected_adapter_index]);
    cntx.swapchain = try rhi.Swapchain.init(app_context.gpa, &cntx.device, 640, 480, window_handle, .{});
    cntx.timekeeper = .{ .tocks_per_s = sdl_app.sdl.SDL_GetPerformanceFrequency() };
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.device,&cntx.device.graphics_queue);
    cntx.dirty_resize = false;

    // Index buffer (host-visible / shared, written directly).
    {
        const index_bytes = std.mem.sliceAsBytes(cube_index[0..]);
        cntx.cube_index_buffer = try .init_general(&cntx.device, .{
            .size = index_bytes.len,
            .persistant_map = true,
            .buffer_usage = .prefer_host,
            .usage = .{ .index_buffer = true },
        });
        @memcpy(cntx.cube_index_buffer.mapped_region.?[0..index_bytes.len], index_bytes);
    }
    // Vertex buffer.
    {
        const vertex_bytes = std.mem.sliceAsBytes(cube_mesh[0..]);
        cntx.cube_vertex_buffer = try .init_general(&cntx.device, .{
            .size = vertex_bytes.len,
            .persistant_map = true,
            .buffer_usage = .prefer_host,
            .usage = .{ .vertex_buffer = true },
        });
        @memcpy(cntx.cube_vertex_buffer.mapped_region.?[0..vertex_bytes.len], vertex_bytes);
    }

    const vs = std.Io.Dir.cwd().readFileAllocOptions(app_context.io, vs_path, app_context.gpa, .unlimited, .@"4", null) catch |err| {
        std.log.err("Failed to open vertex shader '{s}': {}", .{ vs_path, err });
        return err;
    };
    defer app_context.gpa.free(vs);
    const fs = std.Io.Dir.cwd().readFileAllocOptions(app_context.io, fs_path, app_context.gpa, .unlimited, .@"4", null) catch |err| {
        std.log.err("Failed to open fragment shader '{s}': {}", .{ fs_path, err });
        return err;
    };
    defer app_context.gpa.free(fs);

    cntx.shader = try rhi.Shader.init_graphics_shader(&cntx.device, .{
        .vertex_stage = .{ .data = vs, .entry_point = "vertexMain" },
        .fragment_stage = .{ .data = fs, .entry_point = "fragmentMain" },
    });
    cntx.pipeline = try rhi.Pipeline.init_graphics(&cntx.device, .{
        .shader = &cntx.shader,
        .swapchain = &cntx.swapchain,
        .vertex_layout = .{ .stride = @sizeOf(f32) * 3, .attributes = &.{
            .{ .location = 0, .format = .float3, .offset = 0 },
        } },
        .push_constant_size = @sizeOf(PushConsts),
        .depth_test = true,
    });
    cntx.depth_image = try rhi.Image.init(&cntx.device, .{
        .format = .d32_sfloat,
        .width = 640,
        .height = 480,
        .usage = .{ .depth_stencil_attachment = true },
        .memory_usage = .prefer_device,
    });
    cntx.depth_view = try rhi.ImageView.init(&cntx.device, &cntx.depth_image, .{
        .format = .d32_sfloat,
        .aspect = .depth,
    });

    cntx.window = window.?;
    return sdl_app.sdl.SDL_APP_CONTINUE;
}

fn app_quit(app_context: *sdl_app.AppContext(Context), result: sdl_app.sdl.SDL_AppResult) void {
    var cntx: *Context = &app_context.inner;
    cntx.device.graphics_queue.wait_queue_idle(&cntx.device) catch |err| {
        std.log.err("Failed to wait graphics queue idle: {}", .{err});
    };

    cntx.depth_view.deinit(&cntx.device);
    cntx.depth_image.deinit(&cntx.device);
    cntx.pipeline.deinit(&cntx.device);
    cntx.shader.deinit(&cntx.device);
    cntx.cube_vertex_buffer.deinit(&cntx.device);
    cntx.cube_index_buffer.deinit(&cntx.device);
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
