// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Dear ImGui rendering layer built on top of the RHI.
//!
//! Renders ImGui's draw data through the RHI's `rpi.Program` (a backend-neutral
//! render program: pipeline cache + name-resolved descriptor binding) and a
//! `SegmentAlloc` ring for per-frame vertex/index scratch. Only the ImGui *core*
//! C bindings are used (`@import("cimgui")`, dear_bindings' `dcimgui.h`); input
//! is fed by the application (see the `add*Event` helpers), keeping the core
//! library free of a windowing dependency.
//!
//! The draw path (`render`) is backend-neutral. The one-time font-atlas upload
//! and sampler creation in `init` are Vulkan-only for now, so `init` returns
//! `error.UnsupportedBackend` on Metal until the RHI grows Metal texture upload
//! + samplers. The font atlas uses ImGui's legacy single-texture path.
const std = @import("std");
const rhi = @import("root.zig");
pub const c = @import("cimgui");

const Program = rhi.rpi.Program;

/// SPIR-V must be 4-byte aligned for `Shader`/`Program`; `align(4)` guarantees it.
/// The blobs are compiled from `src/shaders/imgui.slang` by slangc and exposed
/// as anonymous imports (see build.zig).
const imgui_vert_spv: [imgui_vert_bytes.len]u8 align(4) = imgui_vert_bytes;
const imgui_frag_spv: [imgui_frag_bytes.len]u8 align(4) = imgui_frag_bytes;
const imgui_vert_bytes = @embedFile("imgui_vert_spv").*;
const imgui_frag_bytes = @embedFile("imgui_frag_spv").*;

/// Push-constant block matching `src/shaders/imgui.vert` (vertex stage).
const PushConstants = extern struct {
    scale: [2]f32,
    translate: [2]f32,
};

pub const ImguiLayer = struct {
    pub const frames_in_flight = 3;
    /// Stable cache key for the (single) ImGui pipeline within the Program.
    const pipeline_key: u64 = 0x1697_D00D_1697_D00D;
    const init_vertex_capacity: u32 = 64 * 1024;
    const init_index_capacity: u32 = 128 * 1024;

    allocator: std.mem.Allocator,
    context: *c.ImGuiContext,
    program: Program,
    font_image: rhi.Image,
    font_view: rhi.ImageView,
    sampler: rhi.Sampler,
    tex_descriptor: rhi.Descriptor,
    sampler_descriptor: rhi.Descriptor,
    vertex_buffer: rhi.Buffer,
    index_buffer: rhi.Buffer,
    vertex_alloc: rhi.SegmentAlloc,
    index_alloc: rhi.SegmentAlloc,
    color_format: rhi.Format,
    frame_index: u64 = 0,

    /// Create the ImGui context and the GPU resources needed to render against
    /// `swapchain`'s color format. Vulkan only (see file header).
    pub fn init(allocator: std.mem.Allocator, device: *rhi.Device, swapchain: *rhi.Swapchain) !ImguiLayer {
        const context = c.ImGui_CreateContext(null) orelse return error.ImGuiContextCreationFailed;
        errdefer c.ImGui_DestroyContext(context);
        c.ImGui_StyleColorsDark(null);

        const io = c.ImGui_GetIO();
        // Per-cmd VtxOffset enables >64K-vertex meshes with 16-bit indices.
        io.*.BackendFlags |= c.ImGuiBackendFlags_RendererHasVtxOffset;

        // --- Font atlas: build pixels, create texture, upload once ----
        var pixels: [*c]u8 = undefined;
        var width: c_int = 0;
        var height: c_int = 0;
        var bytes_per_pixel: c_int = 0;
        c.ImFontAtlas_GetTexDataAsRGBA32(io.*.Fonts, &pixels, &width, &height, &bytes_per_pixel);
        const w: u32 = @intCast(width);
        const h: u32 = @intCast(height);

        var font_image = try rhi.Image.init(device, .{
            .format = .rgba8_unorm,
            .width = w,
            .height = h,
            .usage = .{ .sampled = true, .transfer_dst = true },
        });
        errdefer font_image.deinit(device);
        var font_view = try rhi.ImageView.init(device, &font_image, .{
            .view_type = .shader_resource_2d,
            .format = .rgba8_unorm,
        });
        errdefer font_view.deinit(device);
        try upload_texture(device, &font_image, pixels, w, h);
        // Legacy single-texture path: a non-zero id keeps ImGui's draw
        // commands carrying a valid texture reference. We always bind the
        // one font descriptor set, so the value itself is unused.
        c.ImFontAtlas_SetTexID(io.*.Fonts, 1);

        var sampler = try create_sampler(device);
        errdefer sampler.deinit(device);

        // --- Render program: pipeline cache + named descriptor layout -
        const modules = [_]Program.ModuleStage{
            .{ .stage = .vertex, .data = imgui_vert_spv[0..], .entry_point = "main" },
            .{ .stage = .fragment, .data = imgui_frag_spv[0..], .entry_point = "main" },
        };
        const layout = Program.Layout{
            .bindings = &.{
                .{ .name = "uTexture", .set = 0, .binding = 0, .descriptor_type = .sampled_image, .stages = .{ .fragment = true } },
                .{ .name = "uSampler", .set = 0, .binding = 1, .descriptor_type = .sampler, .stages = .{ .fragment = true } },
            },
            .push_constant = .{ .stages = .{ .vertex = true }, .size = @sizeOf(PushConstants) },
        };
        var program = try Program.initialize(allocator, device, &modules, layout);
        errdefer program.deinit(device);

        // --- Per-frame vertex/index scratch (ring) --------------------
        var vertex_buffer = try rhi.Buffer.init_general(device, .{
            .size = @as(usize, init_vertex_capacity) * @sizeOf(c.ImDrawVert),
            .persistant_map = true,
            .sequential_access = true,
            .buffer_usage = .prefer_host,
            .usage = .{ .vertex_buffer = true },
        });
        errdefer vertex_buffer.deinit(device);
        var index_buffer = try rhi.Buffer.init_general(device, .{
            .size = @as(usize, init_index_capacity) * @sizeOf(c.ImDrawIdx),
            .persistant_map = true,
            .sequential_access = true,
            .buffer_usage = .prefer_host,
            .usage = .{ .index_buffer = true },
        });
        errdefer index_buffer.deinit(device);

        return .{
            .allocator = allocator,
            .context = context,
            .program = program,
            .font_image = font_image,
            .font_view = font_view,
            .sampler = sampler,
            .tex_descriptor = rhi.Descriptor.sampledImage(device, &font_view),
            .sampler_descriptor = rhi.Descriptor.sampler(device, &sampler),
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .vertex_alloc = rhi.SegmentAlloc.init(.{ .max_elements = init_vertex_capacity, .element_stride = @sizeOf(c.ImDrawVert), .num_segments = frames_in_flight }),
            .index_alloc = rhi.SegmentAlloc.init(.{ .max_elements = init_index_capacity, .element_stride = @sizeOf(c.ImDrawIdx), .num_segments = frames_in_flight }),
            .color_format = swapchain_color_format(swapchain),
        };
    }

    pub fn deinit(self: *ImguiLayer, device: *rhi.Device) void {
        device.graphics_queue.wait_queue_idle(device) catch {};
        self.vertex_buffer.deinit(device);
        self.index_buffer.deinit(device);
        self.program.deinit(device);
        self.sampler.deinit(device);
        self.font_view.deinit(device);
        self.font_image.deinit(device);
        c.ImGui_DestroyContext(self.context);
    }

    /// Begin a new ImGui frame. `display_w/h` are in logical points; `dt` is
    /// seconds since the last frame. Call before issuing ImGui UI commands.
    pub fn newFrame(self: *ImguiLayer, display_w: f32, display_h: f32, dt: f32) void {
        _ = self;
        const io = c.ImGui_GetIO();
        io.*.DisplaySize = .{ .x = display_w, .y = display_h };
        io.*.DeltaTime = if (dt > 0) dt else 1.0 / 60.0;
        c.ImGui_NewFrame();
    }

    /// Finalize the frame and record its draw commands into `cmd`, which must be
    /// inside an active render pass (between `begin_rendering`/`end_rendering`).
    pub fn render(self: *ImguiLayer, device: *rhi.Device, cmd: *rhi.Cmd) !void {
        c.ImGui_Render();
        const draw_data = c.ImGui_GetDrawData();
        defer self.frame_index += 1;

        const fb_w = draw_data.*.DisplaySize.x * draw_data.*.FramebufferScale.x;
        const fb_h = draw_data.*.DisplaySize.y * draw_data.*.FramebufferScale.y;
        if (fb_w <= 0 or fb_h <= 0 or draw_data.*.TotalVtxCount == 0) return;

        const total_vtx: usize = @intCast(draw_data.*.TotalVtxCount);
        const total_idx: usize = @intCast(draw_data.*.TotalIdxCount);
        const vtx_req = try self.alloc_scratch(device, &self.vertex_alloc, &self.vertex_buffer, @sizeOf(c.ImDrawVert), total_vtx, .vertex);
        const idx_req = try self.alloc_scratch(device, &self.index_alloc, &self.index_buffer, @sizeOf(c.ImDrawIdx), total_idx, .index);

        // Copy every list's vertices/indices contiguously at the segment offset.
        const cmd_lists = draw_data.*.CmdLists;
        const list_count: usize = @intCast(cmd_lists.Size);
        var vtx_off: usize = @as(usize, vtx_req.element_offset) * @sizeOf(c.ImDrawVert);
        var idx_off: usize = @as(usize, idx_req.element_offset) * @sizeOf(c.ImDrawIdx);
        for (0..list_count) |i| {
            const list = cmd_lists.Data[i];
            const vb = std.mem.sliceAsBytes(list.*.VtxBuffer.Data[0..@intCast(list.*.VtxBuffer.Size)]);
            const ib = std.mem.sliceAsBytes(list.*.IdxBuffer.Data[0..@intCast(list.*.IdxBuffer.Size)]);
            @memcpy(self.vertex_buffer.mapped_region.?[vtx_off..][0..vb.len], vb);
            @memcpy(self.index_buffer.mapped_region.?[idx_off..][0..ib.len], ib);
            vtx_off += vb.len;
            idx_off += ib.len;
        }

        // Pipeline + fixed per-frame state, all through the render program. The
        // desc's arrays are kept on the stack across the bindPipeline call (it
        // reads them only when building the pipeline on the first frame).
        const color_attachments = [_]rhi.rpi.pipeline_desc.ColorAttachment{.{
            .format = self.color_format,
            .blend_enabled = true,
            .src_color = .src_alpha,
            .dst_color = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha = .one,
            .dst_alpha = .one_minus_src_alpha,
            .alpha_blend_op = .add,
        }};
        const vertex_streams = [_]rhi.rpi.pipeline_desc.VertexStream{.{ .binding = 0, .stride = @sizeOf(c.ImDrawVert) }};
        const vertex_attributes = [_]rhi.rpi.pipeline_desc.VertexAttribute{
            .{ .location = 0, .binding = 0, .format = .rg32_sfloat, .offset = @offsetOf(c.ImDrawVert, "pos") },
            .{ .location = 1, .binding = 0, .format = .rg32_sfloat, .offset = @offsetOf(c.ImDrawVert, "uv") },
            .{ .location = 2, .binding = 0, .format = .rgba8_unorm, .offset = @offsetOf(c.ImDrawVert, "col") },
        };
        try self.program.bindPipeline(device, cmd, pipeline_key, "imgui", .{
            .topology = .triangle_list,
            .cull_mode = .none,
            .colors = &color_attachments,
            .vertex_streams = &vertex_streams,
            .vertex_attributes = &vertex_attributes,
        });
        const inv_w = 2.0 / draw_data.*.DisplaySize.x;
        const inv_h = 2.0 / draw_data.*.DisplaySize.y;
        const pc: PushConstants = .{
            .scale = .{ inv_w, inv_h },
            .translate = .{ -1.0 - draw_data.*.DisplayPos.x * inv_w, -1.0 - draw_data.*.DisplayPos.y * inv_h },
        };
        self.program.pushConstants(device, cmd, std.mem.asBytes(&pc), 0);
        cmd.set_viewport(device, .{ .width = fb_w, .height = fb_h });
        cmd.bind_vertex_buffer(device, &self.vertex_buffer, 0);
        cmd.bind_index_buffer(device, &self.index_buffer, if (@sizeOf(c.ImDrawIdx) == 2) .uint16 else .uint32);
        try self.program.bindDescriptors(device, cmd, @truncate(self.frame_index), &.{
            Program.DescriptorBinding.init("uTexture", self.tex_descriptor, 0),
            Program.DescriptorBinding.init("uSampler", self.sampler_descriptor, 0),
        }, .graphics);

        // Per draw-cmd: clip rect -> scissor, then indexed draw. The segment
        // base offsets are folded into vertex_offset/first_index so the buffers
        // stay bound at offset 0.
        const clip_off = draw_data.*.DisplayPos;
        const clip_scale = draw_data.*.FramebufferScale;
        var global_vtx: u32 = vtx_req.element_offset;
        var global_idx: u32 = idx_req.element_offset;
        for (0..list_count) |i| {
            const list = cmd_lists.Data[i];
            const cbuf = list.*.CmdBuffer;
            for (0..@intCast(cbuf.Size)) |j| {
                const dcmd = &cbuf.Data[j];
                if (dcmd.UserCallback != null) continue; // callbacks unsupported

                var min_x = (dcmd.ClipRect.x - clip_off.x) * clip_scale.x;
                var min_y = (dcmd.ClipRect.y - clip_off.y) * clip_scale.y;
                var max_x = (dcmd.ClipRect.z - clip_off.x) * clip_scale.x;
                var max_y = (dcmd.ClipRect.w - clip_off.y) * clip_scale.y;
                if (min_x < 0) min_x = 0;
                if (min_y < 0) min_y = 0;
                if (max_x > fb_w) max_x = fb_w;
                if (max_y > fb_h) max_y = fb_h;
                if (max_x <= min_x or max_y <= min_y) continue;

                cmd.set_scissor(device, .{
                    .x = @intFromFloat(min_x),
                    .y = @intFromFloat(min_y),
                    .width = @intFromFloat(max_x - min_x),
                    .height = @intFromFloat(max_y - min_y),
                });
                cmd.draw_indexed(device, .{
                    .index_count = dcmd.ElemCount,
                    .first_index = global_idx + dcmd.IdxOffset,
                    .vertex_offset = @intCast(global_vtx + dcmd.VtxOffset),
                });
            }
            global_vtx += @intCast(list.*.VtxBuffer.Size);
            global_idx += @intCast(list.*.IdxBuffer.Size);
        }
    }

    const BufferKind = enum { vertex, index };

    /// Sub-allocate `count` elements from the ring for this frame. When the ring
    /// is full (`SegmentAlloc.alloc` returns null) the buffer is grown: drain the
    /// GPU, reallocate at a larger capacity, and retry.
    fn alloc_scratch(self: *ImguiLayer, device: *rhi.Device, seg: *rhi.SegmentAlloc, buf: *rhi.Buffer, stride: u32, count: usize, kind: BufferKind) !rhi.SegmentAllocReq {
        if (seg.alloc(self.frame_index, count)) |req| return req;

        try device.graphics_queue.wait_queue_idle(device);
        var new_max: u32 = seg.max_elements;
        while (@as(usize, new_max) < count) new_max *|= 2;
        new_max *|= 2;
        buf.deinit(device);
        buf.* = try rhi.Buffer.init_general(device, .{
            .size = @as(usize, new_max) * stride,
            .persistant_map = true,
            .sequential_access = true,
            .buffer_usage = .prefer_host,
            .usage = switch (kind) {
                .vertex => .{ .vertex_buffer = true },
                .index => .{ .index_buffer = true },
            },
        });
        seg.* = rhi.SegmentAlloc.init(.{ .max_elements = new_max, .element_stride = @intCast(stride), .num_segments = frames_in_flight });
        return seg.alloc(self.frame_index, count) orelse error.ImGuiScratchOverflow;
    }

    // ---- Input helpers (app maps its window events onto these) --------------

    pub fn addMousePosEvent(self: *ImguiLayer, x: f32, y: f32) void {
        _ = self;
        c.ImGuiIO_AddMousePosEvent(c.ImGui_GetIO(), x, y);
    }
    pub fn addMouseButtonEvent(self: *ImguiLayer, button: i32, down: bool) void {
        _ = self;
        c.ImGuiIO_AddMouseButtonEvent(c.ImGui_GetIO(), button, down);
    }
    pub fn addMouseWheelEvent(self: *ImguiLayer, x: f32, y: f32) void {
        _ = self;
        c.ImGuiIO_AddMouseWheelEvent(c.ImGui_GetIO(), x, y);
    }
    pub fn wantCaptureMouse(self: *ImguiLayer) bool {
        _ = self;
        return c.ImGui_GetIO().*.WantCaptureMouse;
    }
    pub fn wantCaptureKeyboard(self: *ImguiLayer) bool {
        _ = self;
        return c.ImGui_GetIO().*.WantCaptureKeyboard;
    }
};

// ---- Vulkan-only init helpers (only referenced under a comptime .vk gate) ---

/// Map the swapchain's chosen color format back to a core `rhi.Format` so the
/// ImGui pipeline's color attachment matches it for dynamic rendering.
fn swapchain_color_format(sc: *rhi.Swapchain) rhi.Format {
    if (comptime rhi.platform_has_api(.vk)) {
        return switch (sc.backend.vk.format) {
            .r8g8b8a8_unorm => .rgba8_unorm,
            .b8g8r8a8_unorm => .bgra8_unorm,
            .r16g16b16a16_sfloat => .rgba16_sfloat,
            .a2b10g10r10_unorm_pack32 => .r10_g10_b10_a2_unorm,
            else => .rgba8_unorm,
        };
    }
    return .rgba8_unorm;
}

/// Create a linear, clamp-to-edge sampler wrapped in an `rhi.Sampler`. Built
/// inline because `Sampler.init` is not yet finished; swap once it lands.
fn create_sampler(device: *rhi.Device) !rhi.Sampler {
    const vk = rhi.vulkan.vk;
    const dkb: *vk.DeviceWrapper = &device.backend.vk.dkb;
    var info: vk.SamplerCreateInfo = .{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
    };
    const handle = try dkb.createSampler(device.backend.vk.device, &info, null);
    return .{ .cookie = rhi.next_cookie(), .backend = .{ .vk = .{ .sampler = handle } } };
}

/// Upload tightly-packed RGBA8 pixels into `image` via a staging buffer and a
/// one-shot, blocking command submission.
fn upload_texture(device: *rhi.Device, image: *rhi.Image, pixels: [*c]u8, w: u32, h: u32) !void {
    const vk = rhi.vulkan.vk;
    const dkb: *vk.DeviceWrapper = &device.backend.vk.dkb;
    const size: usize = @as(usize, w) * @as(usize, h) * 4;

    var staging = try rhi.Buffer.init_general(device, .{
        .size = size,
        .persistant_map = true,
        .sequential_access = true,
        .buffer_usage = .prefer_host,
        .usage = .{ .transfer_src = true },
    });
    defer staging.deinit(device);
    @memcpy(staging.mapped_region.?[0..size], pixels[0..size]);

    var pool = try rhi.Pool.init(device, &device.graphics_queue);
    defer pool.deinit(device);
    var cmd = try rhi.Cmd.init(device, &pool);
    defer cmd.deinit(device, &pool);

    try cmd.begin(device);
    cmd.image_barrier(device, .{ .image = image, .before = .{}, .after = .{ .copy_dst = true } });
    cmd.copy_buffer_to_texture(device, .{ .src = &staging, .dst = image, .width = w, .height = h });
    cmd.image_barrier(device, .{ .image = image, .before = .{ .copy_dst = true }, .after = .{ .shader_resource = true } });
    try cmd.end(device);

    var submits = [_]vk.SubmitInfo{.{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd.backend.vk.cmd),
    }};
    try dkb.queueSubmit(device.graphics_queue.backend.vk.queue, &submits, .null_handle);
    try dkb.queueWaitIdle(device.graphics_queue.backend.vk.queue);
}
