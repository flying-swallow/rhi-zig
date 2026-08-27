// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const std = @import("std");
const rhi = @import("rhi");
const builtin = @import("builtin");
// `pub` so `web_root.zig` can reach the harness without importing
// platform.zig itself — a file may belong to only one module.
pub const platform = @import("./platform.zig");

const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;
const is_web = builtin.cpu.arch.isWasm();

const vs_path = if (is_apple) "example_assets/02_mesh.vert.metal" else "example_assets/02_mesh.vert.spv";
const fs_path = if (is_apple) "example_assets/02_mesh.frag.metal" else "example_assets/02_mesh.frag.spv";

const PushConsts = extern struct {
    time: f32,
    aspect: f32,
    y_sign: f32,
};

pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });

/// The swapchain is a ref-counted box: each frame it is enqueued into `deferral`
/// (ref++), so its ref-count tracks how many in-flight frames still use it. On a
/// resize the old box's usage refs drain over the next frames and it self-disposes.
const SwapchainRef = rhi.gpu_ref.GPURef(rhi.Swapchain, .heap);
const Deferral = rhi.timline_deferral.TimelineDeferral(&.{*SwapchainRef});

pub const Context = struct {
    window: *platform.Window = undefined,
    swapchain: *SwapchainRef = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    graphics_cmd_ring: CmdRingBuffer = undefined,
    timeline: rhi.Timeline = undefined,
    deferral: Deferral = undefined,
    force_rebuild: bool = false,
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

fn iterate_handler(app_context: *platform.AppContext(Context)) anyerror!platform.AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}

    // Reclaim swapchains (and anything else parked) whose frames the GPU has finished.
    cntx.deferral.drain(try cntx.timeline.completed(&cntx.device));

    // Poll the window size and rebuild the swapchain (and the matching depth buffer)
    // if it changed or a previous acquire/present reported OUT_OF_DATE (HPL2-style).
    {
        var w: c_int = 0;
        var h: c_int = 0;
        const have_size = platform.window_size_in_pixels(cntx.window, &w, &h);
        const presentable = have_size and w > 0 and h > 0;
        if (presentable and (cntx.force_rebuild or
            cntx.swapchain.inner.width != @as(u16, @intCast(w)) or
            cntx.swapchain.inner.height != @as(u16, @intCast(h))))
        {
            const next = try rhi.Swapchain.init(app_context.gpa, &cntx.device, .{
                .width = @intCast(w),
                .height = @intCast(h),
                .queue = &cntx.device.graphics_queue,
                .source = .{ .old_swapchain = &cntx.swapchain.inner },
            });
            if (!next.isEmpty()) {
                const box = try SwapchainRef.create(app_context.gpa, &cntx.device, next);
                cntx.swapchain.deref(); // drop our ref on the old box; it self-disposes
                cntx.swapchain = box; //   once its per-frame usage refs drain
                cntx.force_rebuild = false;

                // Depth buffer must match the swapchain extent; rebuild it too
                // (recreated inline, mirroring the original resize path).
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
            }
        }
    }

    // Acquire. On OUT_OF_DATE skip the whole frame (nothing may wait on the
    // unsignaled acquire semaphore) and rebuild next frame.
    var swapchain_index: u32 = undefined;
    switch (try cntx.swapchain.inner.acquire_next_image(&cntx.device, &swapchain_index)) {
        .out_of_date => {
            cntx.force_rebuild = true;
            return .cont;
        },
        else => {},
    }

    // Mark the swapchain as used by this frame (usage ref++).
    try cntx.deferral.enqueue(cntx.swapchain);

    cntx.graphics_cmd_ring.advance();
    var ring_element = cntx.graphics_cmd_ring.get(&cntx.device, 1);
    try ring_element.wait(&cntx.device);

    try ring_element.pool.reset(&cntx.device);
    var cmd = &ring_element.cmds[0];
    try cmd.begin(&cntx.device);

    var img = cntx.swapchain.inner.image(swapchain_index);
    const view = cntx.swapchain.inner.image_view(swapchain_index);
    const w = cntx.swapchain.inner.width;
    const h = cntx.swapchain.inner.height;

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
        .time = @as(f32, @floatFromInt(platform.ticks_ms())) / 1000.0,
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

    const present_status = try cntx.swapchain.inner.frame_submit(&cntx.device, &cntx.device.graphics_queue, .{
        .image_index = swapchain_index,
        .ring_element = &ring_element,
        .cmd = cmd,
        .timeline = &cntx.timeline,
    });
    if (present_status == .out_of_date) cntx.force_rebuild = true;

    // Close this frame's usage batch at the timeline value the submit signalled.
    try cntx.deferral.seal(cntx.timeline.pending());

    cntx.timekeeper.produce(platform.perf_counter());
    return .cont;
}

fn app_init(app_context: *platform.AppContext(Context), window: *platform.Window) !platform.AppResult {
    var cntx: *Context = &app_context.inner;

    const window_handle = try platform.window_handle(window);
    try platform.init_renderer(app_context.gpa);
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(app_context.gpa);
    defer adapters.deinit(app_context.gpa);

    const selected_adapter_index = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    cntx.device = try rhi.Device.init(app_context.gpa, &adapters.items[selected_adapter_index]);

    var init_w: c_int = 0;
    var init_h: c_int = 0;
    _ = platform.window_size_in_pixels(window, &init_w, &init_h);
    const swapchain = try rhi.Swapchain.init(app_context.gpa, &cntx.device, .{
        .width = if (init_w > 0) @intCast(init_w) else 640,
        .height = if (init_h > 0) @intCast(init_h) else 480,
        .queue = &cntx.device.graphics_queue,
        .source = .{ .window_handle = window_handle },
    });
    cntx.swapchain = try SwapchainRef.create(app_context.gpa, &cntx.device, swapchain);
    cntx.timekeeper = .{ .tocks_per_s = platform.perf_frequency() };
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.device,&cntx.device.graphics_queue);
    cntx.timeline = try rhi.Timeline.init(&cntx.device);
    cntx.deferral = Deferral.init(app_context.gpa);
    cntx.force_rebuild = false;

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

    // Freestanding wasm has no filesystem, so the web build embeds its shaders
    // at build time. Both languages are embedded because the backend is picked
    // in the browser: WGSL for WebGPU, GLSL ES 3.00 for the WebGL2 fallback.
    // (`shader_*` names are anonymous module imports; see examples/build.zig.)
    cntx.shader = blk: {
        if (comptime is_web) {
            const vs: []const u8 = if (rhi.renderer.instance.backend == .webgl) @embedFile("shader_vs_glsl") else @embedFile("shader_vs");
            const fs: []const u8 = if (rhi.renderer.instance.backend == .webgl) @embedFile("shader_fs_glsl") else @embedFile("shader_fs");
            break :blk try rhi.Shader.init_graphics_shader(&cntx.device, .{
                .vertex_stage = .{ .data = vs, .entry_point = "vertexMain" },
                .fragment_stage = .{ .data = fs, .entry_point = "fragmentMain" },
            });
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
        break :blk try rhi.Shader.init_graphics_shader(&cntx.device, .{
            .vertex_stage = .{ .data = vs, .entry_point = "vertexMain" },
            .fragment_stage = .{ .data = fs, .entry_point = "fragmentMain" },
        });
    };
    cntx.pipeline = try rhi.Pipeline.init_graphics(&cntx.device, .{
        .shader = &cntx.shader,
        .colors = &.{.{ .format = cntx.swapchain.inner.color_format() }},
        .vertex_layout = .{ .stride = @sizeOf(f32) * 3, .attributes = &.{
            .{ .location = 0, .format = .float3, .offset = 0 },
        } },
        .push_constant_size = @sizeOf(PushConsts),
        .depth = .{ .format = .d32_sfloat },
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

    cntx.window = window;
    return .cont;
}

fn app_quit(app_context: *platform.AppContext(Context), result: platform.AppResult) void {
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

    cntx.depth_view.deinit(&cntx.device);
    cntx.depth_image.deinit(&cntx.device);
    cntx.pipeline.deinit(&cntx.device);
    cntx.shader.deinit(&cntx.device);
    cntx.cube_vertex_buffer.deinit(&cntx.device);
    cntx.cube_index_buffer.deinit(&cntx.device);
    cntx.graphics_cmd_ring.deinit(&cntx.device);
    cntx.device.deinit();
    rhi.Renderer.deinit();

    // std.log rather than std.debug.print: the latter goes through
    // `std.Options.debug_io`, which does not exist on freestanding wasm.
    std.log.info("App quit called with result: {t}", .{result});
}

fn app_event(app_context: *platform.AppContext(Context), event: *platform.Event) !platform.AppResult {
    _ = app_context;
    _ = event;
    // The desktop harness handles SDL_EVENT_QUIT itself; the web dispatches no
    // events at all (the page's lifetime is the app's).
    return .cont;
}

pub const App = platform.Application(Context, .{
    .title = "02-mesh",
    .iterate_handler = iterate_handler,
    .app_init = app_init,
    .app_event = app_event,
    .app_quit = app_quit,
});

// Emits `rhi_web_init` / `rhi_web_frame` / `rhi_web_deinit` for the JS glue to
// call. An empty namespace off the web.
comptime {
    _ = App.web_exports;
}

/// The browser owns the frame loop on the web: the glue instantiates the module
/// and drives the exports above, so `main` never runs there. It is still
/// declared because `std.start` inspects `root.main` regardless of `-fno-entry`
/// — but its parameter type is `void` on the web, because naming
/// `std.process.Init` there drags in `std.Io.Threaded` and, through it, posix.
pub fn main(init: if (is_web) void else std.process.Init) !void {
    if (comptime is_web) return;
    _ = App.exec(init);
}

/// `std.log` has nowhere to go on freestanding wasm without this.
pub const std_options: std.Options = .{ .logFn = platform.logFn };
