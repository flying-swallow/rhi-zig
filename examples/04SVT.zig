// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//!
//! Copyright 2018 Ales Mlakar. All rights reserved.
//! License: https://github.com/bkaradzic/bgfx/blob/master/LICENSE
//!


//! 04-svt — software virtual texturing, in the spirit of bgfx's examples/40-svt,
//! built to show off the higher-level `rpi` (render-program) layer.
//!
//! A single huge logical texture (VIRTUAL_SIZE²) is split into fixed tiles; only
//! a small working set is physically resident in a GPU atlas. Each frame:
//!   1. a low-cost *feedback* pass writes, per covered pixel, the id of the
//!      virtual page it wants into a storage buffer (bound BY NAME via rpi),
//!   2. the CPU reads that back (a few frames later), streams the needed tiles
//!      into the atlas, and rebuilds a single-level page-table (indirection)
//!      texture, and
//!   3. a *composite* pass samples the atlas indirectly through the page table
//!      (page table + atlas + two samplers, all bound BY NAME via rpi).
//!
//! Both passes are built and bound entirely through `rhi.rpi.Program`: pipeline
//! cache, push constants, and name-resolved descriptor sets. Vulkan-only.

const std = @import("std");
const rhi = @import("rhi");
const rpi = rhi.rpi;
const ig = rhi.imgui_c;
const zla = @import("zla");
const builtin = @import("builtin");
const sdl_app = @import("./sdl_app.zig");

// ---------------------------------------------------------------------------
// Virtual-texture configuration
// ---------------------------------------------------------------------------
const VIRTUAL_SIZE: u32 = 8192;
const TILE_SIZE: u32 = 128;
const BORDER: u32 = 1;
const PAGE_SIZE: u32 = TILE_SIZE + 2 * BORDER; // 130
const PAGE_TABLE_SIZE: u32 = VIRTUAL_SIZE / TILE_SIZE; // 64 (finest indirection grid)
const MIP_COUNT: u32 = 7; // log2(64) + 1
const ATLAS_COUNT: u32 = 24; // resident tiles per atlas side
const ATLAS_PX: u32 = ATLAS_COUNT * PAGE_SIZE;
const NUM_SLOTS: u32 = ATLAS_COUNT * ATLAS_COUNT;
const UPLOADS_PER_FRAME: u32 = 12;
const FB_RING: usize = 3; // feedback-buffer ring depth (>= frames in flight)
const TILE_BYTES: usize = PAGE_SIZE * PAGE_SIZE * 4;
// The page table is now a full mip pyramid (64→1); its CPU/staging footprint is
// the sum of all levels' texels, laid out level-by-level at `indexer.offsets[L]`.
const PT_TOTAL_TEXELS: u32 = blk: {
    var total: u32 = 0;
    var l: u32 = 0;
    while (l < MIP_COUNT) : (l += 1) {
        const s = PAGE_TABLE_SIZE >> @intCast(l);
        total += s * s;
    }
    break :blk total;
};
const PT_BYTES: usize = PT_TOTAL_TEXELS * 4;
const NONE: u32 = 0xffff_ffff;

const vs_path = "example_assets/04_svt.vert.spv";
const composite_fs_path = "example_assets/04_svt_composite.frag.spv";
const feedback_fs_path = "example_assets/04_svt_feedback.frag.spv";

const Vertex = extern struct { x: f32, y: f32, z: f32, u: f32, v: f32 };

const PushConsts = extern struct {
    mvp: [16]f32,
    page_table_size: f32,
    virtual_texture_size: f32,
    mip_count: f32,
    mip_bias: f32,
    atlas_count: f32,
    border_scale: f32,
    border_offset: f32,
    _pad: f32 = 0,
};

// A quad ground plane in XZ, UVs spanning the whole virtual texture.
const PLANE_HALF: f32 = 25.0;
const plane_verts = [_]Vertex{
    .{ .x = -PLANE_HALF, .y = 0, .z = -PLANE_HALF, .u = 0, .v = 0 },
    .{ .x = PLANE_HALF, .y = 0, .z = -PLANE_HALF, .u = 1, .v = 0 },
    .{ .x = -PLANE_HALF, .y = 0, .z = PLANE_HALF, .u = 0, .v = 1 },
    .{ .x = PLANE_HALF, .y = 0, .z = PLANE_HALF, .u = 1, .v = 1 },
};
const plane_index = [_]u16{ 0, 1, 2, 2, 1, 3 };

// ---------------------------------------------------------------------------
// Mip-pyramid page numbering (bgfx PageIndexer): a bijection between a
// (mip, x, y) page and a linear index across the whole pyramid.
// ---------------------------------------------------------------------------
const Page = struct { mip: u32, x: u32, y: u32 };

const PageIndexer = struct {
    sizes: [MIP_COUNT]u32 = undefined,
    offsets: [MIP_COUNT]u32 = undefined,
    total: u32 = 0,

    fn init() PageIndexer {
        var pi: PageIndexer = .{};
        var total: u32 = 0;
        for (0..MIP_COUNT) |i| {
            const s = PAGE_TABLE_SIZE >> @intCast(i);
            pi.sizes[i] = s;
            pi.offsets[i] = total;
            total += s * s;
        }
        pi.total = total;
        return pi;
    }

    fn index(self: *const PageIndexer, mip: u32, x: u32, y: u32) u32 {
        return self.offsets[mip] + y * self.sizes[mip] + x;
    }

    fn decode(self: *const PageIndexer, idx: u32) Page {
        var mip: u32 = 0;
        while (mip + 1 < MIP_COUNT and idx >= self.offsets[mip + 1]) mip += 1;
        const local = idx - self.offsets[mip];
        const s = self.sizes[mip];
        return .{ .mip = mip, .x = local % s, .y = local / s };
    }
};

// ---------------------------------------------------------------------------
// LRU page cache: maps resident virtual pages to atlas slots. Coarse "parent"
// pages are pinned so every page-table texel always has a fallback.
// ---------------------------------------------------------------------------
const PageCache = struct {
    slot_page: [NUM_SLOTS]u32 = @splat(NONE),
    last_used: [NUM_SLOTS]u64 = @splat(0),
    pinned: [NUM_SLOTS]bool = @splat(false),
    map: std.AutoHashMapUnmanaged(u32, u32) = .empty, // page idx -> slot
    used: u32 = 0,
    clock: u64 = 0,

    fn deinit(self: *PageCache, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }

    const Res = struct { slot: u32, loaded: bool };

    /// Ensure `page_idx` is resident, returning its slot and whether it was
    /// newly loaded (the caller then streams the tile pixels into that slot).
    fn request(self: *PageCache, alloc: std.mem.Allocator, page_idx: u32, pin: bool) !Res {
        self.clock += 1;
        if (self.map.get(page_idx)) |slot| {
            self.last_used[slot] = self.clock;
            if (pin) self.pinned[slot] = true;
            return .{ .slot = slot, .loaded = false };
        }
        var slot: u32 = undefined;
        if (self.used < NUM_SLOTS) {
            slot = self.used;
            self.used += 1;
        } else {
            // Evict the least-recently-used non-pinned slot.
            var best: u32 = NONE;
            var best_time: u64 = std.math.maxInt(u64);
            for (0..NUM_SLOTS) |i| {
                if (self.pinned[i]) continue;
                if (self.last_used[i] < best_time) {
                    best_time = self.last_used[i];
                    best = @intCast(i);
                }
            }
            slot = best;
            const old = self.slot_page[slot];
            if (old != NONE) _ = self.map.remove(old);
        }
        self.slot_page[slot] = page_idx;
        self.last_used[slot] = self.clock;
        self.pinned[slot] = pin;
        try self.map.put(alloc, page_idx, slot);
        return .{ .slot = slot, .loaded = true };
    }
};

/// Synthesize a tile's pixels from its (mip, x, y): a per-tile color plus a
/// checkerboard, so which tiles/mips are resident is visually obvious.
fn procTile(page: Page, buf: []u8) void {
    const r0: u32 = (page.x *% 41 +% page.mip *% 60 +% 40) & 0xff;
    const g0: u32 = (page.y *% 47 +% page.mip *% 20 +% 40) & 0xff;
    const b0: u32 = (page.mip *% 35 +% 90) & 0xff;
    for (0..PAGE_SIZE) |py| {
        for (0..PAGE_SIZE) |px| {
            const checker = ((px / 16) + (py / 16)) & 1;
            const scale: u32 = if (checker == 0) 255 else 150;
            const i = (py * PAGE_SIZE + px) * 4;
            buf[i + 0] = @intCast(r0 * scale / 255);
            buf[i + 1] = @intCast(g0 * scale / 255);
            buf[i + 2] = @intCast(b0 * scale / 255);
            buf[i + 3] = 255;
        }
    }
}

fn swapchainRhiFormat(sc: *rhi.Swapchain) rhi.Format {
    return switch (sc.backend.vk.image_format) {
        .b8g8r8a8_unorm => .bgra8_unorm,
        .r8g8b8a8_unorm => .rgba8_unorm,
        .b8g8r8a8_srgb => .bgra8_srgb,
        .r8g8b8a8_srgb => .rgba8_srgb,
        else => .bgra8_unorm,
    };
}

// ---------------------------------------------------------------------------
// App state
// ---------------------------------------------------------------------------
const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;
pub const CmdRingBuffer = rhi.Cmd.CommandRingBuffer(.{ .pool_count = FB_RING, .sync_primative = true });

pub const Context = struct {
    window: *sdl_app.sdl.SDL_Window = undefined,
    swapchain: rhi.Swapchain = undefined,
    device: rhi.Device = undefined,
    timekeeper: rhi.TimeKeeper = undefined,
    dirty_resize: bool = false,
    graphics_cmd_ring: CmdRingBuffer = undefined,

    feedback_program: rpi.Program = undefined,
    composite_program: rpi.Program = undefined,

    atlas_image: rhi.Image = undefined,
    atlas_view: rhi.ImageView = undefined,
    pt_image: rhi.Image = undefined,
    pt_view: rhi.ImageView = undefined,
    nearest_sampler: rhi.Sampler = undefined,
    linear_sampler: rhi.Sampler = undefined,

    quad_vb: rhi.Buffer = undefined,
    quad_ib: rhi.Buffer = undefined,

    feedback_ring: [FB_RING]rhi.Buffer = undefined,
    staging_ring: [FB_RING]rhi.Buffer = undefined,

    indexer: PageIndexer = undefined,
    cache: PageCache = .{},
    pt_cpu: [PT_BYTES]u8 = undefined,

    imgui: rhi.ImGui = undefined,

    frame: u64 = 0,
    uploads_total: u64 = 0,
    resources_initialized: bool = false,
    gpa: std.mem.Allocator = undefined,

    // Camera + UI state.
    last_ticks: u64 = 0,
    fly_mode: bool = false,
    cam_pos: zla.Vec3f32 = .{ 0, 10, 16 },
    cam_yaw: f32 = 0,
    cam_pitch: f32 = -0.5,
    move_speed: f32 = 20.0,
    mip_bias: f32 = 0.0,
    req_min_mip: u32 = 0,
    req_max_mip: u32 = 0,
};

// Per-tile uploads recorded on the CPU, replayed into the command buffer.
const Upload = struct { slot: u32, page: Page };

fn iterate_handler(app_context: *sdl_app.AppContext(Context)) anyerror!sdl_app.sdl.SDL_AppResult {
    var cntx = &app_context.inner;
    while (cntx.timekeeper.consume()) {}

    if (@atomicRmw(bool, &cntx.dirty_resize, .Xchg, false, .monotonic) == true) {
        var w: c_int = 0;
        var h: c_int = 0;
        if (sdl_app.sdl.SDL_GetWindowSize(cntx.window, &w, &h)) {
            _ = try cntx.swapchain.resize(&cntx.device, @intCast(w), @intCast(h));
        }
    }

    cntx.graphics_cmd_ring.advance();
    const swapchain_index = try cntx.swapchain.acquire_next_image(&cntx.device);
    var ring_element = cntx.graphics_cmd_ring.get(&cntx.device, 1);
    try ring_element.wait(&cntx.device);

    const slot: usize = @intCast(cntx.frame % FB_RING);

    // --- 1. Read back the feedback written into this slot the last time it was
    // used (a few frames ago). The ring depth guarantees that frame is complete.
    const flags: [*]u32 = @ptrCast(@alignCast(cntx.feedback_ring[slot].mapped_region.?.ptr));

    var uploads: [UPLOADS_PER_FRAME]Upload = undefined;
    var upload_count: u32 = 0;

    // Always keep the coarse "parent" mips (4,5,6) resident: the coarsest page
    // covers the whole texture, so every page-table texel always has a fallback.
    {
        var mip: u32 = 4;
        while (mip < MIP_COUNT) : (mip += 1) {
            const s = cntx.indexer.sizes[mip];
            for (0..s) |yy| {
                for (0..s) |xx| {
                    try requestPage(cntx, cntx.indexer.index(mip, @intCast(xx), @intCast(yy)), true, &uploads, &upload_count);
                }
            }
        }
    }

    // Requests from the (stale) feedback buffer. Track the requested mip range:
    // as the camera recedes, the finest requested mip (req_min_mip) rises — the
    // numeric proof that detail now scales down with distance.
    var req_count: u32 = 0;
    var min_mip: u32 = MIP_COUNT - 1;
    var max_mip: u32 = 0;
    if (cntx.resources_initialized) {
        var i: u32 = 0;
        while (i < cntx.indexer.total) : (i += 1) {
            if (flags[i] == 0) continue;
            req_count += 1;
            const pm = cntx.indexer.decode(i).mip;
            if (pm < min_mip) min_mip = pm;
            if (pm > max_mip) max_mip = pm;
            try requestPage(cntx, i, false, &uploads, &upload_count);
        }
    }
    cntx.req_min_mip = if (req_count > 0) min_mip else 0;
    cntx.req_max_mip = max_mip;

    cntx.uploads_total += upload_count;
    if (cntx.frame % 60 == 0) {
        std.log.info("frame {d}: resident={d}/{d}  tiles_streamed={d}  feedback_pages={d}  requested_mip=[{d}..{d}]", .{ cntx.frame, cntx.cache.used, NUM_SLOTS, cntx.uploads_total, req_count, cntx.req_min_mip, cntx.req_max_mip });
    }

    // Clear this slot so the GPU's feedback writes this frame start from zero.
    @memset(cntx.feedback_ring[slot].mapped_region.?, 0);

    // --- 2. Stage tile pixels + rebuild the page table into this slot's staging buffer.
    const staging = cntx.staging_ring[slot].mapped_region.?;
    for (uploads[0..upload_count], 0..) |up, k| {
        procTile(up.page, staging[k * TILE_BYTES ..][0..TILE_BYTES]);
    }
    rebuildPageTable(cntx);
    const pt_off = UPLOADS_PER_FRAME * TILE_BYTES;
    @memcpy(staging[pt_off..][0..PT_BYTES], cntx.pt_cpu[0..]);

    // --- 3. Record the command buffer.
    try ring_element.pool.reset(&cntx.device);
    var cmd = &ring_element.cmds[0];
    try cmd.begin(&cntx.device);

    // Transition atlas + page table into copy_dst, upload, then into shader_resource.
    const atlas_before: rhi.cmd.ResourceState = if (cntx.resources_initialized) .{ .shader_resource = true } else .{};
    cmd.resource_barrier(&cntx.device, .{ .image = 2 }, .{ .image_barriers = &.{
        .{ .image = &cntx.atlas_image, .before = atlas_before, .after = .{ .copy_dst = true } },
        .{ .image = &cntx.pt_image, .before = atlas_before, .after = .{ .copy_dst = true } },
    } });

    for (uploads[0..upload_count], 0..) |up, k| {
        const sx = up.slot % ATLAS_COUNT;
        const sy = up.slot / ATLAS_COUNT;
        cmd.copy_buffer_to_texture(&cntx.device, .{
            .src = &cntx.staging_ring[slot],
            .dst = &cntx.atlas_image,
            .buffer_offset = k * TILE_BYTES,
            .x = @intCast(sx * PAGE_SIZE),
            .y = @intCast(sy * PAGE_SIZE),
            .width = PAGE_SIZE,
            .height = PAGE_SIZE,
        });
    }
    {
        var level: u32 = 0;
        while (level < MIP_COUNT) : (level += 1) {
            const size = PAGE_TABLE_SIZE >> @intCast(level);
            cmd.copy_buffer_to_texture(&cntx.device, .{
                .src = &cntx.staging_ring[slot],
                .dst = &cntx.pt_image,
                .buffer_offset = pt_off + @as(u64, cntx.indexer.offsets[level]) * 4,
                .mip_level = level,
                .width = size,
                .height = size,
            });
        }
    }

    cmd.resource_barrier(&cntx.device, .{ .image = 2 }, .{ .image_barriers = &.{
        .{ .image = &cntx.atlas_image, .before = .{ .copy_dst = true }, .after = .{ .shader_resource = true } },
        .{ .image = &cntx.pt_image, .before = .{ .copy_dst = true }, .after = .{ .shader_resource = true } },
    } });
    cntx.resources_initialized = true;

    // Shared transform + params.
    const w = cntx.swapchain.width;
    const h = cntx.swapchain.height;
    const aspect = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h));
    const now = sdl_app.sdl.SDL_GetTicks();
    const dt: f32 = @as(f32, @floatFromInt(now -% cntx.last_ticks)) / 1000.0;
    cntx.last_ticks = now;

    // ImGui frame + control panel (issued before the composite pass records it).
    cntx.imgui.newFrame(@floatFromInt(w), @floatFromInt(h), if (dt > 0) dt else 1.0 / 60.0);
    drawUi(cntx);

    // Camera: a manual WASD/mouse fly cam when enabled, otherwise an automatic
    // orbit that also sweeps near→far so the LOD scale-down is visible hands-free.
    const view_mat = if (cntx.fly_mode) blk: {
        const yaw = cntx.cam_yaw;
        const pitch = cntx.cam_pitch;
        const forward = zla.Vec3f32{ @sin(yaw) * @cos(pitch), @sin(pitch), -@cos(yaw) * @cos(pitch) };
        const right = zla.vec.normalize(zla.vec.cross(forward, zla.Vec3f32{ 0, 1, 0 }));
        var vel = zla.Vec3f32{ 0, 0, 0 };
        const keys = sdl_app.sdl.SDL_GetKeyboardState(null);
        if (keys[sdl_app.sdl.SDL_SCANCODE_W]) vel += forward;
        if (keys[sdl_app.sdl.SDL_SCANCODE_S]) vel -= forward;
        if (keys[sdl_app.sdl.SDL_SCANCODE_D]) vel += right;
        if (keys[sdl_app.sdl.SDL_SCANCODE_A]) vel -= right;
        if (keys[sdl_app.sdl.SDL_SCANCODE_E]) vel += zla.Vec3f32{ 0, 1, 0 };
        if (keys[sdl_app.sdl.SDL_SCANCODE_Q]) vel -= zla.Vec3f32{ 0, 1, 0 };
        cntx.cam_pos += zla.vec.scale(vel, cntx.move_speed * dt);
        break :blk zla.Mat4f32.lookAt(cntx.cam_pos, cntx.cam_pos + forward, .{ 0, 1, 0 });
    } else blk: {
        const t = @as(f32, @floatFromInt(now)) / 1000.0;
        const orbit = t * 0.25;
        const s = 0.5 - 0.5 * @cos(t * 0.5); // smooth 0..1..0
        const dist = 6.0 + s * 34.0; // sweep 6 → 40 units from the plane
        const height = 4.0 + s * 20.0;
        const eye = zla.Vec3f32{ @cos(orbit) * dist, height, @sin(orbit) * dist };
        break :blk zla.Mat4f32.lookAt(eye, .{ 0, 0, 0 }, .{ 0, 1, 0 });
    };
    // zla is column-major — exactly what the shader's `mul(pc.mvp, pos)` wants,
    // so no transpose is needed.
    const view_proj = zla.Mat4f32.perspective(55.0 * std.math.pi / 180.0, aspect, 0.1, 300.0).mul(view_mat);
    const pc: PushConsts = .{
        .mvp = @bitCast(view_proj.items),
        .page_table_size = @floatFromInt(PAGE_TABLE_SIZE),
        .virtual_texture_size = @floatFromInt(VIRTUAL_SIZE),
        .mip_count = @floatFromInt(MIP_COUNT),
        .mip_bias = cntx.mip_bias,
        .atlas_count = @floatFromInt(ATLAS_COUNT),
        .border_scale = @as(f32, @floatFromInt(TILE_SIZE)) / @as(f32, @floatFromInt(PAGE_SIZE)),
        .border_offset = @as(f32, @floatFromInt(BORDER)) / @as(f32, @floatFromInt(PAGE_SIZE)),
    };

    // --- Feedback pass: no color target, writes page ids into the SSBO.
    cmd.begin_rendering(&cntx.device, .{ .color_attachments = &.{}, .render_area = .{ .width = w, .height = h } });
    cmd.set_viewport(&cntx.device, .{ .width = @floatFromInt(w), .height = @floatFromInt(h) });
    cmd.set_scissor(&cntx.device, .{ .width = w, .height = h });
    try cntx.feedback_program.bindPipeline(&cntx.device, cmd, 1, "svt_feedback", .{
        .topology = .triangle_list,
        .cull_mode = .none,
        .colors = &.{}, // rasterize for the SSBO side effect only
        .vertex_streams = &.{.{ .binding = 0, .stride = @sizeOf(Vertex) }},
        .vertex_attributes = &.{
            .{ .location = 0, .binding = 0, .format = .rgb32_sfloat, .offset = 0 },
            .{ .location = 1, .binding = 0, .format = .rg32_sfloat, .offset = 12 },
        },
    });
    cntx.feedback_program.pushConstants(&cntx.device, cmd, std.mem.asBytes(&pc), 0);
    try cntx.feedback_program.bindDescriptors(&cntx.device, cmd, @truncate(cntx.frame), &.{
        rpi.DescriptorBinding.init("feedback_buffer", rhi.Descriptor.storageBuffer(&cntx.device, &cntx.feedback_ring[slot], 0, cntx.indexer.total * 4), 0),
    }, .graphics);
    cmd.bind_vertex_buffer(&cntx.device, &cntx.quad_vb, 0);
    cmd.bind_index_buffer(&cntx.device, &cntx.quad_ib, .uint16);
    cmd.draw_indexed(&cntx.device, .{ .index_count = plane_index.len });
    cmd.end_rendering(&cntx.device);

    // --- Composite pass: sample the atlas through the page table into the swapchain.
    var img = cntx.swapchain.image(swapchain_index);
    const view = cntx.swapchain.image_view(swapchain_index);
    cmd.image_barrier(&cntx.device, .{ .image = &img, .before = .{}, .after = .{ .render_target = true } });

    cmd.begin_rendering(&cntx.device, .{
        .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_color = .{ 0.0, 0.0, 0.05, 1.0 } }},
        .render_area = .{ .width = w, .height = h },
    });
    cmd.set_viewport(&cntx.device, .{ .width = @floatFromInt(w), .height = @floatFromInt(h) });
    cmd.set_scissor(&cntx.device, .{ .width = w, .height = h });
    const color_atts = [_]rpi.pipeline_desc.ColorAttachment{.{ .format = swapchainRhiFormat(&cntx.swapchain) }};
    try cntx.composite_program.bindPipeline(&cntx.device, cmd, 2, "svt_composite", .{
        .topology = .triangle_list,
        .cull_mode = .none,
        .colors = color_atts[0..],
        .vertex_streams = &.{.{ .binding = 0, .stride = @sizeOf(Vertex) }},
        .vertex_attributes = &.{
            .{ .location = 0, .binding = 0, .format = .rgb32_sfloat, .offset = 0 },
            .{ .location = 1, .binding = 0, .format = .rg32_sfloat, .offset = 12 },
        },
    });
    cntx.composite_program.pushConstants(&cntx.device, cmd, std.mem.asBytes(&pc), 0);
    try cntx.composite_program.bindDescriptors(&cntx.device, cmd, @truncate(cntx.frame), &.{
        rpi.DescriptorBinding.init("s_page_table", rhi.Descriptor.sampledImage(&cntx.device, &cntx.pt_view), 0),
        rpi.DescriptorBinding.init("s_atlas", rhi.Descriptor.sampledImage(&cntx.device, &cntx.atlas_view), 0),
        rpi.DescriptorBinding.init("page_sampler", rhi.Descriptor.sampler(&cntx.device, &cntx.nearest_sampler), 0),
        rpi.DescriptorBinding.init("atlas_sampler", rhi.Descriptor.sampler(&cntx.device, &cntx.linear_sampler), 0),
    }, .graphics);
    cmd.bind_vertex_buffer(&cntx.device, &cntx.quad_vb, 0);
    cmd.bind_index_buffer(&cntx.device, &cntx.quad_ib, .uint16);
    cmd.draw_indexed(&cntx.device, .{ .index_count = plane_index.len });
    // Overlay the ImGui panel into the same swapchain pass.
    try cntx.imgui.render(&cntx.device, cmd);
    cmd.end_rendering(&cntx.device);

    cmd.image_barrier(&cntx.device, .{ .image = &img, .before = .{ .render_target = true }, .after = .{ .present = true } });

    try cntx.swapchain.frame_submit(&cntx.device, &cntx.device.graphics_queue, .{
        .image_index = swapchain_index,
        .ring_element = &ring_element,
        .cmd = cmd,
    });

    cntx.frame += 1;
    cntx.timekeeper.produce(sdl_app.sdl.SDL_GetPerformanceCounter());
    return sdl_app.sdl.SDL_APP_CONTINUE;
}

fn drawUi(cntx: *Context) void {
    if (ig.ImGui_Begin("04-svt virtual texturing", null, 0)) {
        ig.ImGui_Text("%.1f FPS", ig.ImGui_GetIO().*.Framerate);
        ig.ImGui_Separator();
        if (ig.ImGui_Checkbox("Fly camera (Esc to release)", &cntx.fly_mode)) {
            _ = sdl_app.sdl.SDL_SetWindowRelativeMouseMode(cntx.window, cntx.fly_mode);
        }
        ig.ImGui_Text("WASD move, Q/E down/up, mouse look");
        _ = ig.ImGui_SliderFloat("Move speed", &cntx.move_speed, 2.0, 80.0);
        _ = ig.ImGui_SliderFloat("Mip bias", &cntx.mip_bias, -2.0, 3.0);
        ig.ImGui_Separator();
        ig.ImGui_Text("Resident tiles: %d / %d", @as(c_int, @intCast(cntx.cache.used)), @as(c_int, NUM_SLOTS));
        ig.ImGui_Text("Tiles streamed: %d", @as(c_int, @intCast(cntx.uploads_total)));
        ig.ImGui_Text("Requested mip: %d .. %d (finest rises as you recede)", @as(c_int, @intCast(cntx.req_min_mip)), @as(c_int, @intCast(cntx.req_max_mip)));
    }
    ig.ImGui_End();
}

fn requestPage(cntx: *Context, page_idx: u32, pin: bool, uploads: *[UPLOADS_PER_FRAME]Upload, count: *u32) !void {
    // Touching an already-resident page is free; loading a new tile costs an
    // upload, so skip new pages once this frame's upload budget is spent (they
    // are re-requested next frame — the coarse fallback covers them meanwhile).
    const resident = cntx.cache.map.contains(page_idx);
    if (!resident and count.* >= UPLOADS_PER_FRAME) return;
    const res = try cntx.cache.request(cntx.gpa, page_idx, pin);
    if (res.loaded) {
        uploads[count.*] = .{ .slot = res.slot, .page = cntx.indexer.decode(page_idx) };
        count.* += 1;
    }
}

/// Rebuild every mip level of the page table (indirection texture). Level L's
/// texel (x,y) references the resident tile for virtual page (L,x,y), or — when
/// that exact page isn't resident — the finest resident ancestor at a coarser
/// mip covering it. Sampling level L therefore yields a tile no finer than L,
/// so distant regions (which sample a coarse level) resolve to coarse tiles
/// even while finer tiles for the same region remain resident. The pinned
/// coarse mips (4,5,6) guarantee an ancestor always exists, so no texel is a
/// hole. Levels are packed contiguously at byte `indexer.offsets[L]*4`.
fn rebuildPageTable(cntx: *Context) void {
    @memset(cntx.pt_cpu[0..], 0);
    var level: u32 = 0;
    while (level < MIP_COUNT) : (level += 1) {
        const size = cntx.indexer.sizes[level];
        const base = cntx.indexer.offsets[level];
        var y: u32 = 0;
        while (y < size) : (y += 1) {
            var x: u32 = 0;
            while (x < size) : (x += 1) {
                // Walk from mip `level` toward coarser mips until a resident
                // tile is found for the covering page.
                var found_slot: u32 = NONE;
                var found_mip: u32 = 0;
                var m = level;
                var px = x;
                var py = y;
                while (m < MIP_COUNT) {
                    if (cntx.cache.map.get(cntx.indexer.index(m, px, py))) |s| {
                        found_slot = s;
                        found_mip = m;
                        break;
                    }
                    m += 1;
                    px >>= 1;
                    py >>= 1;
                }
                const i = (base + y * size + x) * 4;
                if (found_slot != NONE) {
                    cntx.pt_cpu[i + 0] = @intCast(found_slot % ATLAS_COUNT);
                    cntx.pt_cpu[i + 1] = @intCast(found_slot / ATLAS_COUNT);
                    cntx.pt_cpu[i + 2] = @intCast(found_mip);
                    cntx.pt_cpu[i + 3] = 255;
                }
            }
        }
    }
}

fn app_init(app_context: *sdl_app.AppContext(Context), argv: [][*:0]u8) anyerror!sdl_app.sdl.SDL_AppResult {
    _ = argv;
    if (sdl_app.sdl.SDL_SetAppMetadata("04-svt", "0.0.0", "svt") == false) return error.SetAppMetadataFailed;
    if (sdl_app.sdl.SDL_Init(sdl_app.sdl.SDL_INIT_VIDEO) == false) return error.SDLInitFailed;

    const window = sdl_app.sdl.SDL_CreateWindow("04-svt (virtual texturing via rpi)", 1024, 640, sdl_app.sdl.SDL_WINDOW_RESIZABLE);
    if (window == null) return error.CreateWindowFailed;
    errdefer sdl_app.sdl.SDL_DestroyWindow(window);

    const window_handle = try sdl_app.sdl_window_handle_to_rhi_window_handle(window.?);
    var cntx: *Context = &app_context.inner;
    cntx.gpa = app_context.gpa;
    cntx.indexer = PageIndexer.init();
    cntx.cache = .{};

    try rhi.Renderer.init(app_context.gpa, .{ .vk = .{ .app_name = "04-svt", .enable_validation_layer = true } });
    var adapters = try rhi.PhysicalAdapter.enumerate_adapters(app_context.gpa);
    defer adapters.deinit(app_context.gpa);
    const selected = rhi.PhysicalAdapter.default_select_adapter(adapters.items[0..]);
    cntx.device = try rhi.Device.init(app_context.gpa, &adapters.items[selected]);
    cntx.swapchain = try rhi.Swapchain.init(app_context.gpa, &cntx.device, 1024, 640, window_handle, .{});
    cntx.timekeeper = .{ .tocks_per_s = sdl_app.sdl.SDL_GetPerformanceFrequency() };
    cntx.graphics_cmd_ring = try CmdRingBuffer.init(&cntx.device, &cntx.device.graphics_queue);
    cntx.imgui = try rhi.ImGui.init(app_context.gpa, &cntx.device, &cntx.swapchain);
    cntx.dirty_resize = false;
    cntx.frame = 0;
    cntx.uploads_total = 0;
    cntx.resources_initialized = false;

    // Camera + UI state.
    cntx.last_ticks = sdl_app.sdl.SDL_GetTicks();
    cntx.fly_mode = false;
    cntx.cam_pos = .{ 0, 10, 16 };
    cntx.cam_yaw = 0;
    cntx.cam_pitch = -0.5;
    cntx.move_speed = 20.0;
    cntx.mip_bias = 0.0;
    cntx.req_min_mip = 0;
    cntx.req_max_mip = 0;

    // Atlas + page-table images.
    cntx.atlas_image = try rhi.Image.init(&cntx.device, .{
        .format = .rgba8_unorm,
        .width = ATLAS_PX,
        .height = ATLAS_PX,
        .usage = .{ .sampled = true, .transfer_dst = true },
        .memory_usage = .prefer_device,
    });
    cntx.atlas_view = try rhi.ImageView.init(&cntx.device, &cntx.atlas_image, .{ .format = .rgba8_unorm });
    cntx.pt_image = try rhi.Image.init(&cntx.device, .{
        .format = .rgba8_unorm,
        .width = PAGE_TABLE_SIZE,
        .height = PAGE_TABLE_SIZE,
        .mip_levels = MIP_COUNT,
        .usage = .{ .sampled = true, .transfer_dst = true },
        .memory_usage = .prefer_device,
    });
    cntx.pt_view = try rhi.ImageView.init(&cntx.device, &cntx.pt_image, .{ .format = .rgba8_unorm, .mip_num = MIP_COUNT });

    cntx.nearest_sampler = try rhi.Sampler.init(&cntx.device, .{
        .min_filter = .nearest, .mag_filter = .nearest, .mip_map_mode = .nearest,
        .address_u = .clamp_to_edge, .address_v = .clamp_to_edge, .address_w = .clamp_to_edge,
        .mip_lod_bias = 0, .set_lod_range = false, .min_lod = 0, .max_lod = 0,
        .max_anisotropy = 1, .compare_func = .never,
    });
    cntx.linear_sampler = try rhi.Sampler.init(&cntx.device, .{
        .min_filter = .linear, .mag_filter = .linear, .mip_map_mode = .nearest,
        .address_u = .clamp_to_edge, .address_v = .clamp_to_edge, .address_w = .clamp_to_edge,
        .mip_lod_bias = 0, .set_lod_range = false, .min_lod = 0, .max_lod = 0,
        .max_anisotropy = 1, .compare_func = .never,
    });

    // Geometry.
    {
        const bytes = std.mem.sliceAsBytes(plane_verts[0..]);
        cntx.quad_vb = try .init_general(&cntx.device, .{ .size = bytes.len, .persistant_map = true, .buffer_usage = .prefer_host, .usage = .{ .vertex_buffer = true } });
        @memcpy(cntx.quad_vb.mapped_region.?[0..bytes.len], bytes);
    }
    {
        const bytes = std.mem.sliceAsBytes(plane_index[0..]);
        cntx.quad_ib = try .init_general(&cntx.device, .{ .size = bytes.len, .persistant_map = true, .buffer_usage = .prefer_host, .usage = .{ .index_buffer = true } });
        @memcpy(cntx.quad_ib.mapped_region.?[0..bytes.len], bytes);
    }

    // Feedback SSBO ring (stride 4 => a storage buffer) + staging ring.
    for (0..FB_RING) |i| {
        cntx.feedback_ring[i] = try .init_general(&cntx.device, .{
            .size = cntx.indexer.total * 4,
            .stride = 4,
            .persistant_map = true,
            .buffer_usage = .prefer_host,
            .usage = .{},
        });
        @memset(cntx.feedback_ring[i].mapped_region.?, 0);

        cntx.staging_ring[i] = try .init_general(&cntx.device, .{
            .size = UPLOADS_PER_FRAME * TILE_BYTES + PT_BYTES,
            .persistant_map = true,
            .sequential_access = true,
            .buffer_usage = .prefer_host,
            .usage = .{},
        });
    }

    // Programs.
    const vs = try readSpv(app_context, vs_path);
    defer app_context.gpa.free(vs);
    const feedback_fs = try readSpv(app_context, feedback_fs_path);
    defer app_context.gpa.free(feedback_fs);
    const composite_fs = try readSpv(app_context, composite_fs_path);
    defer app_context.gpa.free(composite_fs);

    const pc_range: rpi.PushConstantRange = .{ .stages = .{ .vertex = true, .fragment = true }, .size = @sizeOf(PushConsts) };

    // Slang emits every SPIR-V entry point as "main" (one entry per module).
    cntx.feedback_program = try rpi.Program.initialize(app_context.gpa, &cntx.device, &.{
        .{ .stage = .vertex, .data = vs, .entry_point = "main" },
        .{ .stage = .fragment, .data = feedback_fs, .entry_point = "main" },
    }, .{
        .bindings = &.{
            .{ .name = "feedback_buffer", .set = 0, .binding = 0, .descriptor_type = .storage_buffer, .stages = .{ .fragment = true } },
        },
        .push_constant = pc_range,
    });

    cntx.composite_program = try rpi.Program.initialize(app_context.gpa, &cntx.device, &.{
        .{ .stage = .vertex, .data = vs, .entry_point = "main" },
        .{ .stage = .fragment, .data = composite_fs, .entry_point = "main" },
    }, .{
        .bindings = &.{
            .{ .name = "s_page_table", .set = 0, .binding = 1, .descriptor_type = .sampled_image, .stages = .{ .fragment = true } },
            .{ .name = "s_atlas", .set = 0, .binding = 2, .descriptor_type = .sampled_image, .stages = .{ .fragment = true } },
            .{ .name = "page_sampler", .set = 0, .binding = 3, .descriptor_type = .sampler, .stages = .{ .fragment = true } },
            .{ .name = "atlas_sampler", .set = 0, .binding = 4, .descriptor_type = .sampler, .stages = .{ .fragment = true } },
        },
        .push_constant = pc_range,
    });

    cntx.window = window.?;
    return sdl_app.sdl.SDL_APP_CONTINUE;
}

fn readSpv(app_context: *sdl_app.AppContext(Context), path: []const u8) ![]align(4) u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(app_context.io, path, app_context.gpa, .unlimited, .@"4", null) catch |err| {
        std.log.err("Failed to open shader '{s}': {}", .{ path, err });
        return err;
    };
}

fn app_quit(app_context: *sdl_app.AppContext(Context), result: sdl_app.sdl.SDL_AppResult) void {
    var cntx: *Context = &app_context.inner;
    cntx.device.graphics_queue.wait_queue_idle(&cntx.device) catch |err| {
        std.log.err("wait idle: {}", .{err});
    };

    cntx.imgui.deinit(&cntx.device);
    cntx.feedback_program.deinit(&cntx.device);
    cntx.composite_program.deinit(&cntx.device);
    for (0..FB_RING) |i| {
        cntx.feedback_ring[i].deinit(&cntx.device);
        cntx.staging_ring[i].deinit(&cntx.device);
    }
    cntx.nearest_sampler.deinit(&cntx.device);
    cntx.linear_sampler.deinit(&cntx.device);
    cntx.atlas_view.deinit(&cntx.device);
    cntx.atlas_image.deinit(&cntx.device);
    cntx.pt_view.deinit(&cntx.device);
    cntx.pt_image.deinit(&cntx.device);
    cntx.quad_vb.deinit(&cntx.device);
    cntx.quad_ib.deinit(&cntx.device);
    cntx.cache.deinit(cntx.gpa);
    cntx.graphics_cmd_ring.deinit(&cntx.device);
    cntx.swapchain.deinit(&cntx.device);
    cntx.device.deinit();
    rhi.Renderer.deinit();
    _ = result;
}

fn app_event(app_context: *sdl_app.AppContext(Context), event: *sdl_app.sdl.SDL_Event) anyerror!sdl_app.sdl.SDL_AppResult {
    const sdl = sdl_app.sdl;
    var cntx = &app_context.inner;
    switch (event.type) {
        sdl.SDL_EVENT_QUIT => return sdl.SDL_APP_SUCCESS,
        sdl.SDL_EVENT_WINDOW_RESIZED => @atomicStore(bool, &cntx.dirty_resize, true, .monotonic),
        sdl.SDL_EVENT_MOUSE_MOTION => {
            cntx.imgui.addMousePosEvent(event.motion.x, event.motion.y);
            if (cntx.fly_mode) {
                const sens: f32 = 0.0025;
                cntx.cam_yaw += event.motion.xrel * sens;
                cntx.cam_pitch = std.math.clamp(cntx.cam_pitch - event.motion.yrel * sens, -1.5, 1.5);
            }
        },
        sdl.SDL_EVENT_MOUSE_WHEEL => cntx.imgui.addMouseWheelEvent(event.wheel.x, event.wheel.y),
        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP => {
            const down = event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN;
            const button: i32 = switch (event.button.button) {
                sdl.SDL_BUTTON_LEFT => 0,
                sdl.SDL_BUTTON_RIGHT => 1,
                sdl.SDL_BUTTON_MIDDLE => 2,
                else => return sdl.SDL_APP_CONTINUE,
            };
            cntx.imgui.addMouseButtonEvent(button, down);
        },
        sdl.SDL_EVENT_KEY_DOWN => {
            if (event.key.key == sdl.SDLK_ESCAPE and cntx.fly_mode) {
                cntx.fly_mode = false;
                _ = sdl.SDL_SetWindowRelativeMouseMode(cntx.window, false);
            }
        },
        else => {},
    }
    return sdl.SDL_APP_CONTINUE;
}

pub fn main(init: std.process.Init) !void {
    _ = sdl_app.SdlApplicaton(Context, .{
        .iterate_handler = iterate_handler,
        .app_init = app_init,
        .app_event = app_event,
        .app_quit = app_quit,
    }).exec(init);
}
