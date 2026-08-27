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

// On Apple the shaders are MSL (compiled at runtime); elsewhere they are SPIR-V.
// The web build ignores both and embeds WGSL instead (see app_init).
const vs_path = if (is_apple) "example_assets/fullscreen.vert.metal" else "example_assets/fullscreen.vert.spv";
const fs_path = if (is_apple) "example_assets/mandelbrot.frag.metal" else "example_assets/mandelbrot.frag.spv";

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
};

fn iterate_handler(app_context: *platform.AppContext(Context)) anyerror!platform.AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}

    // Reclaim swapchains (and anything else parked) whose frames the GPU has finished.
    cntx.deferral.drain(try cntx.timeline.completed(&cntx.device));

    // Poll the window size and rebuild the swapchain if it changed or a previous
    // acquire/present reported OUT_OF_DATE (HPL2-style; no resize event / resize()).
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

    cmd.image_barrier(&cntx.device,.{
        .image = &img,
        .before = .{},
        .after = .{ .render_target = true },
    });

    cmd.begin_rendering(&cntx.device,.{
        .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ 0.0, 0.0, 0.0, 1.0 },
        }},
        .render_area = .{ .width = w, .height = h },
    });

    cmd.set_viewport(&cntx.device,.{ .width = @floatFromInt(w), .height = @floatFromInt(h) });
    cmd.set_scissor(&cntx.device,.{ .width = w, .height = h });
    cmd.bind_pipeline(&cntx.device,&cntx.pipeline);
    cmd.draw(&cntx.device,.{ .vertex_count = 3 });

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
    cntx.window = window;
    cntx.device = try rhi.Device.init(app_context.gpa, &adapters.items[selected_adapter_index]);

    var init_w: c_int = 0;
    var init_h: c_int = 0;
    _ = platform.window_size_in_pixels(window, &init_w, &init_h);
    var swapchain = try rhi.Swapchain.init(app_context.gpa, &cntx.device, .{
        .width = if (init_w > 0) @intCast(init_w) else 640,
        .height = if (init_h > 0) @intCast(init_h) else 480,
        .queue = &cntx.device.graphics_queue,
        .source = .{ .window_handle = window_handle },
    });

    // Freestanding wasm has no filesystem, so the web build embeds its shaders
    // at build time. Both languages are embedded because the backend is picked
    // in the browser: WGSL for WebGPU, GLSL ES 3.00 for the WebGL2 fallback.
    // (`shader_*` names are anonymous module imports; see examples/build.zig.)
    var shader = blk: {
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
    const pipeline = try rhi.Pipeline.init_graphics(&cntx.device, .{
        .shader = &shader,
        .colors = &.{.{ .format = swapchain.color_format() }},
    });

    cntx.swapchain = try SwapchainRef.create(app_context.gpa, &cntx.device, swapchain);
    cntx.timekeeper = .{ .tocks_per_s = platform.perf_frequency() };
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.device, &cntx.device.graphics_queue);
    cntx.timeline = try rhi.Timeline.init(&cntx.device);
    cntx.deferral = Deferral.init(app_context.gpa);
    cntx.force_rebuild = false;
    cntx.shader = shader;
    cntx.pipeline = pipeline;
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

    cntx.pipeline.deinit(&cntx.device);
    cntx.shader.deinit(&cntx.device);
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
    .title = "01-shader",
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
