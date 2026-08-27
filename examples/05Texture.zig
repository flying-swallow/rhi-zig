// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const builtin = @import("builtin");
const std = @import("std");
const rhi = @import("rhi");
// `pub` so `web_root.zig` can reach the harness without importing
// platform.zig itself — a file may belong to only one module.
pub const platform = @import("./platform.zig");

const is_web = builtin.cpu.arch.isWasm();

pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = 4, .sync_primative = true });

/// The swapchain is a ref-counted box: each frame it is enqueued into `deferral`
/// (ref++), so its ref-count tracks how many in-flight frames still use it. When a
/// resize recreates it, the old box's outstanding usage refs drain over the next
/// frames and it self-disposes — no pipeline stall, no in-flight free.
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
    /// Set when acquire/present reports OUT_OF_DATE; recreated at the next frame top.
    force_rebuild: bool = false,

    shader: rhi.Shader = undefined,
    pipeline: rhi.Pipeline = undefined,
    vertex_buffer: rhi.Buffer = undefined,
    texture: rhi.Image = undefined,
    texture_view: rhi.ImageView = undefined,
    sampler: rhi.Sampler = undefined,
};

/// Clip-space quad. Positions are written by the CPU, so the vertex stage is a
/// pass-through and there is no transform to get wrong while checking texturing.
const Vertex = extern struct { pos: [2]f32, uv: [2]f32 };

const quad = [6]Vertex{
    .{ .pos = .{ -0.6, -0.6 }, .uv = .{ 0.0, 1.0 } },
    .{ .pos = .{ 0.6, -0.6 }, .uv = .{ 1.0, 1.0 } },
    .{ .pos = .{ 0.6, 0.6 }, .uv = .{ 1.0, 0.0 } },
    .{ .pos = .{ -0.6, -0.6 }, .uv = .{ 0.0, 1.0 } },
    .{ .pos = .{ 0.6, 0.6 }, .uv = .{ 1.0, 0.0 } },
    .{ .pos = .{ -0.6, 0.6 }, .uv = .{ 0.0, 0.0 } },
};

const tex_size = 8;

/// An 8x8 checkerboard of opaque red and half-transparent white, generated
/// rather than loaded: freestanding wasm has no filesystem. The transparent
/// squares are what make a blending failure obvious -- they must take on the
/// clear colour behind them.
fn checkerboard() [tex_size * tex_size * 4]u8 {
    var out: [tex_size * tex_size * 4]u8 = undefined;
    for (0..tex_size) |y| {
        for (0..tex_size) |x| {
            const i = (y * tex_size + x) * 4;
            if ((x + y) % 2 == 0) {
                out[i + 0] = 220;
                out[i + 1] = 40;
                out[i + 2] = 40;
                out[i + 3] = 255;
            } else {
                out[i + 0] = 255;
                out[i + 1] = 255;
                out[i + 2] = 255;
                out[i + 3] = 128;
            }
        }
    }
    return out;
}

fn iterate_handler(app_context: *platform.AppContext(Context)) anyerror!platform.AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}

    // Reclaim swapchains (and anything else parked) whose frames the GPU has finished.
    cntx.deferral.drain(try cntx.timeline.completed(&cntx.device));

    // Poll the window size and rebuild the swapchain if it changed or a previous
    // acquire/present reported OUT_OF_DATE (HPL2-style; no resize event / resize()).
    var poll_w: c_int = 0;
    var poll_h: c_int = 0;
    {
        const have_size = platform.window_size_in_pixels(cntx.window, &poll_w, &poll_h);
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
            return .cont;
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
            // A saturated background so a half-transparent texel is visibly
            // tinted by it when blending works, and pure white when it does not.
            .clear_color = .{ 0.05, 0.35, 0.15, 1.0 },
        }},
        .render_area = .{ .width = w, .height = h },
    });
    cmd.set_viewport(&cntx.device, .{ .width = @floatFromInt(w), .height = @floatFromInt(h) });
    cmd.set_scissor(&cntx.device, .{ .width = w, .height = h });

    cmd.bind_pipeline(&cntx.device, &cntx.pipeline);
    try cmd.web_bind_descriptors(&cntx.device, &cntx.pipeline, &.{
        .init("tex", rhi.Descriptor.sampledImage(&cntx.device, &cntx.texture_view), 0),
        .init("smp", rhi.Descriptor.sampler(&cntx.device, &cntx.sampler), 0),
    });
    cmd.bind_vertex_buffer(&cntx.device, &cntx.vertex_buffer, 0);
    cmd.draw(&cntx.device, .{ .vertex_count = quad.len });

    cmd.end_rendering(&cntx.device);

    // color_attachment -> present
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

    try cntx.deferral.seal(cntx.timeline.pending());
    cntx.timekeeper.produce(platform.perf_counter());
    return .cont;
}

fn app_init(app_context: *platform.AppContext(Context), window: *platform.Window) anyerror!platform.AppResult {
    var cntx: *Context = &app_context.inner;

    const window_handle = try platform.window_handle(window);
    try platform.init_renderer(app_context.gpa);
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(app_context.gpa);
    defer adapters.deinit(app_context.gpa);

    const selected_adapter_index = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    cntx.window = window;
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
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.device, &cntx.device.graphics_queue);
    cntx.timeline = try rhi.Timeline.init(&cntx.device);
    cntx.deferral = Deferral.init(app_context.gpa);
    cntx.force_rebuild = false;

    // WGSL keeps the real entry-point names; SPIRV-Cross rewrites both stages
    // to `main`, so the GLSL arm's names are ignored by the backend.
    const vs: []const u8 = if (rhi.renderer.instance.backend == .webgl) @embedFile("shader_vs_glsl") else @embedFile("shader_vs");
    const fs: []const u8 = if (rhi.renderer.instance.backend == .webgl) @embedFile("shader_fs_glsl") else @embedFile("shader_fs");
    cntx.shader = try rhi.Shader.init_graphics_shader(&cntx.device, .{
        .vertex_stage = .{ .data = vs, .entry_point = "vertexMain" },
        .fragment_stage = .{ .data = fs, .entry_point = "fragmentMain" },
    });

    cntx.pipeline = try rhi.Pipeline.init_graphics(&cntx.device, .{
        .shader = &cntx.shader,
        .colors = &.{.{
            .format = cntx.swapchain.inner.color_format(),
            .blend = .straight_alpha,
        }},
        .vertex_layout = .{ .stride = @sizeOf(Vertex), .attributes = &.{
            .{ .location = 0, .format = .float2, .offset = 0 },
            .{ .location = 1, .format = .float2, .offset = 8 },
        } },
        .texture_bindings = &.{
            .{ .name = "tex", .binding = 0, .sampler_name = "smp", .sampler_binding = 1 },
        },
    });

    cntx.vertex_buffer = try .init_general(&cntx.device, .{
        .size = @sizeOf(@TypeOf(quad)),
        .persistant_map = true,
        .buffer_usage = .prefer_host,
        .usage = .{ .vertex_buffer = true },
    });
    // Through `write` rather than `mapped_region`, so the same call works on
    // frame 1 and every frame after it on the web backends.
    cntx.vertex_buffer.write(&cntx.device, 0, std.mem.asBytes(&quad));

    cntx.texture = try rhi.Image.init(&cntx.device, .{
        .format = .rgba8_unorm,
        .width = tex_size,
        .height = tex_size,
        .usage = .{ .sampled = true, .transfer_dst = true },
        .memory_usage = .prefer_device,
    });
    cntx.texture_view = try rhi.ImageView.init(&cntx.device, &cntx.texture, .{ .format = .rgba8_unorm });
    const pixels = checkerboard();
    try cntx.texture.write(&cntx.device, .{
        .data = &pixels,
        .width = tex_size,
        .height = tex_size,
    });

    // Nearest, so the 8x8 source stays legibly blocky when magnified.
    cntx.sampler = try rhi.Sampler.init(&cntx.device, .{
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .mip_map_mode = .nearest,
        .address_u = .clamp_to_edge,
        .address_v = .clamp_to_edge,
        .address_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .set_lod_range = false,
        .min_lod = 0,
        .max_lod = 0,
        .max_anisotropy = 1,
        .compare_func = .never,
    });
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
    cntx.sampler.deinit(&cntx.device);
    cntx.texture_view.deinit(&cntx.device);
    cntx.texture.deinit(&cntx.device);
    cntx.vertex_buffer.deinit(&cntx.device);
    cntx.pipeline.deinit(&cntx.device);
    cntx.shader.deinit(&cntx.device);
    cntx.swapchain.deref();
    cntx.deferral.deinit();
    cntx.timeline.deinit(&cntx.device);
    cntx.graphics_cmd_ring.deinit(&cntx.device);
    cntx.device.deinit();
    rhi.Renderer.deinit();
    // std.log rather than std.debug.print: the latter goes through
    // `std.Options.debug_io`, which does not exist on freestanding wasm.
    std.log.info("App quit called with result: {t}", .{result});
}

fn app_event(app_context: *platform.AppContext(Context), event: *platform.Event) anyerror!platform.AppResult {
    _ = app_context;
    _ = event;
    // The desktop harness handles SDL_EVENT_QUIT itself; the web dispatches no
    // events at all (the page's lifetime is the app's).
    return .cont;
}

pub const App = platform.Application(Context, .{
    .title = "05-texture",
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
