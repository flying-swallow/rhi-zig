// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Deferred command recording for the WebGL2 backend.
//!
//! WebGL2 has no command buffer, but the RHI's contract is that recording and
//! execution are separate — `CommandRingBuffer` exists to keep several buffers
//! in flight. Issuing GL calls inline from `Cmd` would quietly break that for
//! any caller that records ahead of submit, so `Cmd` appends to one of these
//! and `Queue.submit` replays it.

const rhi = @import("../root.zig");
const std = @import("std");
const webgl = @import("../webgl.zig");
const gl = webgl.gl;

pub const Command = union(enum) {
    begin_render_pass: struct {
        /// The FBO to render into. The swapchain's own FBO for a swapchain
        /// target; a per-pass FBO otherwise.
        fbo: webgl.Handle,
        width: u32,
        height: u32,
        clear_color: bool,
        color: [4]f32,
        has_depth: bool,
        clear_depth_value: bool,
        depth: f32,
    },
    end_render_pass,
    set_viewport: rhi.cmd.Viewport,
    set_scissor: rhi.cmd.Rect,
    bind_pipeline: *rhi.Pipeline,
    /// Raw handles rather than `*rhi.ImageView`: views are passed around by
    /// value (`Swapchain.image_view` hands one out), so the recorder cannot
    /// hold a pointer to a caller's temporary. Handles are stable and the
    /// caller owns lifetime, the same contract as the buffer entries above.
    bind_texture: struct { unit: u32, texture: webgl.Handle, sampler: webgl.Handle },
    bind_vertex_buffer: struct { buffer: *rhi.Buffer, slot: u32 },
    bind_index_buffer: struct { buffer: *rhi.Buffer, index_type: rhi.cmd.IndexType },
    /// Bytes live in the recorder's arena at `[offset, offset+len)`.
    set_push_constants: struct { pipeline: *rhi.Pipeline, offset: u32, len: u32 },
    draw: struct { vertex_count: u32, instance_count: u32, first_vertex: u32 },
    draw_indexed: struct { index_count: u32, instance_count: u32, first_index: u32 },
    /// `ClearRegion`s live in the recorder's arena at `[offset, offset+count)`.
    clear_regions: struct { offset: u32, count: u32 },
    copy_buffer: struct { src: *rhi.Buffer, src_offset: u32, dst: *rhi.Buffer, dst_offset: u32, size: u32 },
};

pub const ClearRegion = extern struct {
    color: [4]f32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

/// One command buffer's recording. Reset by `Cmd.begin`, replayed by
/// `Queue.submit`.
pub const Recorder = struct {
    commands: std.ArrayList(Command) = .empty,
    /// Inline payloads (push-constant blobs, clear-region arrays) that outlive
    /// the caller's stack but not the command buffer.
    arena: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    /// Set while a render pass is open, so replay knows the target's height for
    /// the Y flip and `Cmd` can assert that copies are not recorded inside one.
    pass_open: bool = false,

    pub fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Recorder) void {
        self.commands.deinit(self.allocator);
        self.arena.deinit(self.allocator);
    }

    pub fn reset(self: *Recorder) void {
        self.commands.clearRetainingCapacity();
        self.arena.clearRetainingCapacity();
        self.pass_open = false;
    }

    pub fn append(self: *Recorder, command: Command) void {
        self.commands.append(self.allocator, command) catch |err| {
            // Recording has no error path in the RHI's API (`Cmd.draw` and
            // friends return void), and dropping a command silently would
            // render the wrong thing. Fail loudly instead.
            std.debug.panic("webgl: out of memory recording a command: {t}", .{err});
        };
    }

    /// Copies `bytes` into the arena and returns its offset.
    pub fn stash(self: *Recorder, bytes: []const u8) u32 {
        const offset: u32 = @intCast(self.arena.items.len);
        self.arena.appendSlice(self.allocator, bytes) catch |err| {
            std.debug.panic("webgl: out of memory recording a payload: {t}", .{err});
        };
        return offset;
    }
};

/// Replays a recorded command buffer against the GL context.
///
/// Y is flipped here rather than in the recorded values: the RHI's viewport and
/// scissor rects are top-left origin (Vulkan/D3D convention) while GL's are
/// bottom-left, and only replay knows the render target's height. The NDC
/// difference is handled separately, in the shader, by SPIRV-Cross's
/// `flip_vert_y` + `fixup_clipspace`.
pub fn replay(recorder: *const Recorder, device: *rhi.Device) void {
    var target_height: u32 = 0;
    var bound: ?*rhi.Pipeline = null;

    for (recorder.commands.items) |command| switch (command) {
        .begin_render_pass => |p| {
            target_height = p.height;
            webgl.gl_bind_framebuffer(p.fbo);
            // A leftover scissor or a masked depth write would silently reduce
            // the clear to a sub-rect, so both are reset first.
            webgl.gl_set_enabled(gl.SCISSOR_TEST, 0);
            webgl.gl_color_mask(1, 1, 1, 1);
            if (p.has_depth and p.clear_depth_value) webgl.gl_depth_mask(1);
            if (p.clear_color) {
                webgl.gl_clear_color(p.color[0], p.color[1], p.color[2], p.color[3]);
            }
            if (p.has_depth and p.clear_depth_value) {
                webgl.gl_clear_depth(p.depth);
            }
        },
        .end_render_pass => {
            webgl.gl_set_enabled(gl.SCISSOR_TEST, 0);
        },
        .set_viewport => |v| {
            const h: i32 = @intCast(target_height);
            const y = h - @as(i32, @intFromFloat(v.y)) - @as(i32, @intFromFloat(v.height));
            webgl.gl_viewport(@intFromFloat(v.x), y, @intFromFloat(v.width), @intFromFloat(v.height), v.min_depth, v.max_depth);
        },
        .set_scissor => |r| {
            const h: i32 = @intCast(target_height);
            const y = h - r.y - @as(i32, @intCast(r.height));
            webgl.gl_scissor(r.x, y, r.width, r.height);
            webgl.gl_set_enabled(gl.SCISSOR_TEST, 1);
        },
        .bind_pipeline => |pipeline| {
            bound = pipeline;
            apply_pipeline(pipeline);
        },
        .bind_texture => |t| {
            webgl.gl_bind_texture_unit(t.unit, t.texture, t.sampler);
        },
        .bind_vertex_buffer => |b| {
            if (bound) |pipeline| bind_vao(device, pipeline, b.buffer, null);
        },
        .bind_index_buffer => |b| {
            if (bound) |pipeline| bind_vao(device, pipeline, null, b.buffer);
        },
        .set_push_constants => |pc| {
            const bytes = recorder.arena.items[pc.offset .. pc.offset + pc.len];
            apply_push_constants(pc.pipeline, bytes);
        },
        .draw => |d| {
            const mode = if (bound) |p| p.backend.webgl.topology else gl.TRIANGLES;
            webgl.gl_draw_arrays(mode, d.first_vertex, d.vertex_count, d.instance_count);
        },
        .draw_indexed => |d| {
            const mode = if (bound) |p| p.backend.webgl.topology else gl.TRIANGLES;
            const t = if (bound) |p| p.backend.webgl.index_type else gl.UNSIGNED_SHORT;
            const size: u32 = if (t == gl.UNSIGNED_INT) 4 else 2;
            webgl.gl_draw_elements(mode, d.index_count, t, d.first_index * size, d.instance_count);
        },
        .clear_regions => |c| {
            // WebGL2 can do what WebGPU cannot: a scissored clear per region.
            const base = std.mem.bytesAsSlice(ClearRegion, recorder.arena.items[c.offset..]);
            const h: i32 = @intCast(target_height);
            for (base[0..c.count]) |r| {
                webgl.gl_scissor(r.x, h - r.y - @as(i32, @intCast(r.height)), r.width, r.height);
                webgl.gl_set_enabled(gl.SCISSOR_TEST, 1);
                webgl.gl_clear_color(r.color[0], r.color[1], r.color[2], r.color[3]);
            }
            webgl.gl_set_enabled(gl.SCISSOR_TEST, 0);
        },
        .copy_buffer => |c| {
            webgl.gl_copy_buffer_sub_data(
                c.src.backend.webgl.target,
                c.src.backend.webgl.buffer,
                c.src_offset,
                c.dst.backend.webgl.target,
                c.dst.backend.webgl.buffer,
                c.dst_offset,
                c.size,
            );
        },
    };
}

fn apply_pipeline(pipeline: *rhi.Pipeline) void {
    const p = &pipeline.backend.webgl;
    webgl.gl_use_program(p.program);
    webgl.gl_set_enabled(gl.DEPTH_TEST, @intFromBool(p.depth_test));
    webgl.gl_depth_mask(@intFromBool(p.depth_write));
    if (p.depth_test) webgl.gl_depth_func(p.depth_compare);
    webgl.gl_set_enabled(gl.CULL_FACE, @intFromBool(p.cull_enabled));
    if (p.cull_enabled) webgl.gl_cull_face(p.cull_mode);
    webgl.gl_front_face(p.front_face);
    // GL blend state is global, so it has to be set on every bind rather than
    // only when the pipeline enables it — otherwise a blended pipeline leaks
    // into the next unblended one.
    webgl.gl_set_enabled(gl.BLEND, @intFromBool(p.blend_enabled));
    if (p.blend_enabled) {
        webgl.gl_blend_func_separate(p.blend_src_color, p.blend_dst_color, p.blend_src_alpha, p.blend_dst_alpha);
        webgl.gl_blend_equation_separate(p.blend_color_op, p.blend_alpha_op);
    }
    webgl.gl_color_mask(p.write_mask[0], p.write_mask[1], p.write_mask[2], p.write_mask[3]);
}

/// WebGL2 has no `ARB_vertex_attrib_binding`, so a VAO fuses the vertex format
/// with the buffers it reads. The RHI hands them over separately —
/// `bind_pipeline` knows the format, `bind_vertex_buffer` the buffer — so the
/// VAO is looked up (or built) from whichever combination is current.
fn bind_vao(device: *rhi.Device, pipeline: *rhi.Pipeline, vertex: ?*rhi.Buffer, index: ?*rhi.Buffer) void {
    const state = &device.backend.webgl;
    if (vertex) |v| state.current_vertex_buffer = v;
    if (index) |i| state.current_index_buffer = i;
    const vao = state.vao_cache.get(
        pipeline,
        state.current_vertex_buffer,
        state.current_index_buffer,
    ) catch |err| {
        std.debug.panic("webgl: could not build a vertex array: {t}", .{err});
    };
    webgl.gl_bind_vertex_array(vao);
}

/// Push constants have no GL equivalent; SPIRV-Cross emits the block as a plain
/// struct uniform, whose members were reflected at link time.
fn apply_push_constants(pipeline: *rhi.Pipeline, bytes: []const u8) void {
    const p = &pipeline.backend.webgl;
    for (p.push_constant_members[0..p.push_constant_member_count]) |m| {
        if (m.offset + m.size > bytes.len) continue;
        webgl.gl_uniform_raw(m.location, m.gl_type, bytes.ptr + m.offset, m.size);
    }
}
