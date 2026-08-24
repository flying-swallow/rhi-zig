// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! WebGL2 backend shim — the peer of `webgpu.zig` / `vulkan.zig` / `metal.zig`.
//!
//! **Web-only**, and specifically a *fallback* under `.wgpu`: WebGL2 needs no
//! browser flags, where WebGPU is still gated on Linux Chrome and absent from
//! older browsers. Both backends are compiled into the same wasm module and the
//! JS glue picks between them before instantiation.
//!
//! ## The wasm boundary
//!
//! Same contract as `webgpu.zig`: scalars plus `(ptr, len)` pairs only, never a
//! shared C struct, so nothing can drift silently between the Zig and JS sides.
//! Objects are `Handle`s into a JS-side table with `0` meaning null.
//!
//! ## What WebGL2 is not
//!
//! WebGL2 is OpenGL ES 3.0: an immediate-mode state machine with no command
//! buffers, no pipeline objects, no render passes, and no descriptor sets. The
//! RHI's contract is that recording and execution are separate, so `Cmd` on this
//! backend records into `webgl/command_list.zig` and `Queue.submit` replays it.
//! Executing inline would quietly break any caller that records ahead of submit.

const rhi = @import("root.zig");
const std = @import("std");

/// Enum tables and format mapping. Split out for the same reason as
/// `webgpu/enums.zig`: it compiles on every target, so its glue-contract test
/// runs under a normal `zig build test`.
pub const enums = @import("webgl/enums.zig");
pub const command_list = @import("webgl/command_list.zig");

pub const gl = enums.gl;
pub const to_gl_format = enums.to_gl_format;
pub const to_gl_compare = enums.to_gl_compare;
pub const to_gl_index_type = enums.to_gl_index_type;
pub const GlFormat = enums.GlFormat;

/// An entry in the JS-side object table (`WebGLBuffer`, `WebGLTexture`,
/// `WebGLProgram`, …). `.none` is the null object.
pub const Handle = enum(u32) {
    none = 0,
    _,

    pub fn isNone(self: Handle) bool {
        return self == .none;
    }
};

/// Caches vertex array objects, because WebGL2 has no
/// `ARB_vertex_attrib_binding`: `vertexAttribPointer` records whatever is bound
/// to `ARRAY_BUFFER` at the time, so a VAO fuses the vertex *format* with the
/// specific buffers it reads.
///
/// The RHI hands those over separately and in the opposite order — `bind_pipeline`
/// knows the format, `bind_vertex_buffer` the buffer — so the VAO cannot belong
/// to the pipeline. It is keyed on the triple instead.
///
/// The key uses resource cookies rather than raw GL handles: cookies are stable
/// unique ids, while GL reuses handle numbers after a delete (the same reason
/// `root.zig` stamps them in the first place). `invalidate` must be called when
/// any input is destroyed, or a later resource with a recycled handle would
/// silently inherit a stale VAO.
pub const VaoCache = struct {
    pub const Key = struct { pipeline: u64, vertex: u64, index: u64 };

    map: std.AutoHashMapUnmanaged(Key, Handle) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VaoCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VaoCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |vao| gl_delete_vertex_array(vao.*);
        self.map.deinit(self.allocator);
    }

    pub fn get(
        self: *VaoCache,
        pipeline: *rhi.Pipeline,
        vertex: ?*rhi.Buffer,
        index: ?*rhi.Buffer,
    ) !Handle {
        const key: Key = .{
            .pipeline = pipeline.backend.webgl.cookie,
            .vertex = if (vertex) |v| v.cookie else 0,
            .index = if (index) |i| i.cookie else 0,
        };
        if (self.map.get(key)) |vao| return vao;

        const vao = gl_create_vertex_array();
        if (vao.isNone()) return error.WebGL2VertexArrayCreationFailed;
        if (vertex) |v| {
            const layout = pipeline.backend.webgl.vertex_attributes[0..pipeline.backend.webgl.vertex_attribute_count];
            for (layout) |attr| {
                gl_vertex_attrib_pointer(
                    vao,
                    v.backend.webgl.buffer,
                    attr.location,
                    attr.components,
                    pipeline.backend.webgl.vertex_stride,
                    attr.offset,
                );
            }
        }
        if (index) |i| gl_vao_set_element_buffer(vao, i.backend.webgl.buffer);

        try self.map.put(self.allocator, key, vao);
        return vao;
    }

    /// Drops every VAO that referenced `cookie`, in any of the three slots.
    pub fn invalidate(self: *VaoCache, cookie: u64) void {
        if (cookie == 0) return;
        var stale: [32]Key = undefined;
        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (k.pipeline == cookie or k.vertex == cookie or k.index == cookie) {
                if (n < stale.len) {
                    stale[n] = k;
                    n += 1;
                }
            }
        }
        for (stale[0..n]) |k| {
            if (self.map.fetchRemove(k)) |kv| gl_delete_vertex_array(kv.value);
        }
    }
};

/// Caches framebuffer objects per (colour texture, depth texture) pair.
///
/// A GL render pass is an FBO with attachments, and the RHI supplies the
/// attachments fresh on every `begin_rendering`. Rebuilding and validating an
/// FBO per frame would be wasteful, so they are cached on the same
/// cookie-keyed basis as `VaoCache`, and for the same reason: GL reuses handle
/// numbers after a delete.
pub const FboCache = struct {
    pub const Key = struct { color: u64, depth: u64 };

    map: std.AutoHashMapUnmanaged(Key, Handle) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FboCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FboCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |fbo| gl_delete_framebuffer(fbo.*);
        self.map.deinit(self.allocator);
    }

    pub fn get(self: *FboCache, color: rhi.ImageView, depth: ?rhi.ImageView) !Handle {
        const key: Key = .{
            .color = color.cookie,
            .depth = if (depth) |d| d.cookie else 0,
        };
        if (self.map.get(key)) |fbo| return fbo;

        const fbo = gl_create_framebuffer();
        if (fbo.isNone()) return error.WebGL2FramebufferCreationFailed;
        gl_framebuffer_texture_2d(fbo, gl.COLOR_ATTACHMENT0, color.backend.webgl.texture);
        if (depth) |d| {
            const attachment: u32 = if (enums.has_stencil(d.backend.webgl.format))
                gl.DEPTH_STENCIL_ATTACHMENT
            else
                gl.DEPTH_ATTACHMENT;
            gl_framebuffer_texture_2d(fbo, attachment, d.backend.webgl.texture);
        }
        const status = gl_check_framebuffer_status(fbo);
        if (status != gl.FRAMEBUFFER_COMPLETE) {
            gl_delete_framebuffer(fbo);
            return error.WebGL2FramebufferIncomplete;
        }

        try self.map.put(self.allocator, key, fbo);
        return fbo;
    }

    /// Drops every FBO that referenced `cookie` in either slot.
    pub fn invalidate(self: *FboCache, cookie: u64) void {
        if (cookie == 0) return;
        var stale: [16]Key = undefined;
        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (k.color == cookie or k.depth == cookie) {
                if (n < stale.len) {
                    stale[n] = k;
                    n += 1;
                }
            }
        }
        for (stale[0..n]) |k| {
            if (self.map.fetchRemove(k)) |kv| gl_delete_framebuffer(kv.value);
        }
    }
};

/// Resolves the framebuffer a render pass should target.
///
/// Recording has no error path in the RHI's API (`begin_rendering` returns
/// void), and silently skipping a pass would render nothing with no
/// explanation, so an unbuildable framebuffer panics with the reason.
pub fn resolve_framebuffer(device: *rhi.Device, color: rhi.ImageView, depth: ?rhi.cmd.DepthAttachment) Handle {
    const depth_view: ?rhi.ImageView = if (depth) |d| d.view else null;
    return device.backend.webgl.fbo_cache.get(color, depth_view) catch |err| {
        std.debug.panic("webgl: could not build a framebuffer: {t}", .{err});
    };
}

/// One vertex attribute, pre-resolved into the form `vertexAttribPointer` wants.
pub const VertexAttrib = struct {
    location: u32,
    components: u32,
    offset: u32,
};

/// One reflected member of the push-constant block. GL has no push constants;
/// SPIRV-Cross emits the block as a plain struct uniform whose members are
/// looked up by name once, at link time.
pub const PushConstantMember = struct {
    location: i32 = -1,
    gl_type: u32 = 0,
    offset: u32 = 0,
    size: u32 = 0,
};

// ---------------------------------------------------------------------------
// Imports implemented by src/webgl/glue.js
// ---------------------------------------------------------------------------

/// Non-zero once the glue has a live WebGL2 context. The context itself is
/// created before instantiation, alongside the WebGPU probe, so the synchronous
/// `Renderer.init` -> `Device.init` chain needs no async plumbing.
pub extern "webgl" fn gl_available() u32;
/// Writes up to `buf_len` bytes of `RENDERER` into wasm memory; returns the
/// number written.
pub extern "webgl" fn gl_renderer_name(buf_ptr: [*]u8, buf_len: u32) u32;
pub extern "webgl" fn gl_get_parameter_int(pname: u32) i32;

// Buffers
/// `target` is fixed for the buffer's lifetime. WebGL2 locks a buffer to the
/// first target it is bound to — Chrome enforces that even for a
/// `COPY_WRITE_BUFFER` bind — so it is derived from the RHI usage flags at
/// creation and reused for every later bind.
pub extern "webgl" fn gl_create_buffer(target: u32, size: u32, usage: u32) Handle;
pub extern "webgl" fn gl_delete_buffer(buffer: Handle) void;
pub extern "webgl" fn gl_buffer_sub_data(target: u32, buffer: Handle, offset: u32, ptr: [*]const u8, len: u32) void;
pub extern "webgl" fn gl_copy_buffer_sub_data(src_target: u32, src: Handle, src_offset: u32, dst_target: u32, dst: Handle, dst_offset: u32, size: u32) void;

// Textures and framebuffers
pub extern "webgl" fn gl_create_texture_2d(internal_format: u32, width: u32, height: u32, levels: u32) Handle;
pub extern "webgl" fn gl_delete_texture(texture: Handle) void;
/// `texSubImage2D` from wasm linear memory. `format`/`type` are the GL pair for
/// the texture's `rhi.Format`, from `to_gl_format`.
pub extern "webgl" fn gl_tex_sub_image_2d(
    texture: Handle,
    level: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    format: u32,
    type: u32,
    ptr: [*]const u8,
    len: u32,
) void;
/// ES 3.0 sampler object. Filter and wrap state lives here rather than on the
/// texture, so one texture can be read with different sampling in two draws.
pub extern "webgl" fn gl_create_sampler(
    min_filter: u32,
    mag_filter: u32,
    wrap_s: u32,
    wrap_t: u32,
    wrap_r: u32,
) Handle;
pub extern "webgl" fn gl_delete_sampler(sampler: Handle) void;
/// Bind a texture (and optionally a sampler object) to a texture unit.
/// A `.none` sampler unbinds the unit's sampler, falling back to the texture's
/// own parameters.
pub extern "webgl" fn gl_bind_texture_unit(unit: u32, texture: Handle, sampler: Handle) void;
/// Point a `sampler2D` uniform at a texture unit. Done once at link time.
/// Returns 0 on success, -1 when the program has no such uniform.
pub extern "webgl" fn gl_set_sampler_unit(
    program: Handle,
    name_ptr: [*]const u8,
    name_len: u32,
    unit: u32,
) i32;
pub extern "webgl" fn gl_create_framebuffer() Handle;
pub extern "webgl" fn gl_delete_framebuffer(fbo: Handle) void;
/// `attachment` is `GL_COLOR_ATTACHMENT0` or `GL_DEPTH_ATTACHMENT`.
pub extern "webgl" fn gl_framebuffer_texture_2d(fbo: Handle, attachment: u32, texture: Handle) void;
/// Returns `GL_FRAMEBUFFER_COMPLETE` (0x8CD5) when usable.
pub extern "webgl" fn gl_check_framebuffer_status(fbo: Handle) u32;
pub extern "webgl" fn gl_bind_framebuffer(fbo: Handle) void;
/// Resolves the offscreen swapchain target onto the canvas (framebuffer 0).
/// WebGL2 cannot attach the default framebuffer's colour buffer to a custom
/// FBO, so rendering always goes offscreen and lands here.
pub extern "webgl" fn gl_blit_to_canvas(src_fbo: Handle, width: u32, height: u32) void;

// Programs
/// Compiles and links in one call; on failure returns `.none` and writes the
/// info log into `err_ptr`. A single import keeps the failure path in one place
/// rather than spread across eight.
pub extern "webgl" fn gl_create_program(
    vs_ptr: [*]const u8,
    vs_len: u32,
    fs_ptr: [*]const u8,
    fs_len: u32,
    err_ptr: [*]u8,
    err_len: u32,
) Handle;
pub extern "webgl" fn gl_delete_program(program: Handle) void;
pub extern "webgl" fn gl_use_program(program: Handle) void;
/// Number of active uniforms, used to reflect the push-constant block rather
/// than hardcoding its member names.
pub extern "webgl" fn gl_active_uniform_count(program: Handle) u32;
/// Writes the uniform's name into `name_ptr` and its GL type into `out_type`;
/// returns the name length. `index` is `[0, gl_active_uniform_count)`.
pub extern "webgl" fn gl_active_uniform_info(
    program: Handle,
    index: u32,
    name_ptr: [*]u8,
    name_len: u32,
    out_type: *u32,
) u32;
pub extern "webgl" fn gl_uniform_location(program: Handle, name_ptr: [*]const u8, name_len: u32) i32;
/// Sets one uniform from raw bytes; the glue dispatches on `gl_type`.
pub extern "webgl" fn gl_uniform_raw(location: i32, gl_type: u32, ptr: [*]const u8, len: u32) void;

// Vertex arrays
pub extern "webgl" fn gl_create_vertex_array() Handle;
pub extern "webgl" fn gl_delete_vertex_array(vao: Handle) void;
pub extern "webgl" fn gl_bind_vertex_array(vao: Handle) void;
/// Configures one attribute inside `vao` against `buffer`. WebGL2 has no
/// `ARB_vertex_attrib_binding`, so format and buffer cannot be set
/// independently — which is why VAOs are cached per (pipeline, vbo, ibo).
pub extern "webgl" fn gl_vertex_attrib_pointer(
    vao: Handle,
    buffer: Handle,
    location: u32,
    components: u32,
    stride: u32,
    offset: u32,
) void;
pub extern "webgl" fn gl_vao_set_element_buffer(vao: Handle, buffer: Handle) void;

// Fixed-function state
pub extern "webgl" fn gl_viewport(x: i32, y: i32, width: u32, height: u32, min_depth: f32, max_depth: f32) void;
pub extern "webgl" fn gl_scissor(x: i32, y: i32, width: u32, height: u32) void;
pub extern "webgl" fn gl_set_enabled(cap: u32, enabled: u32) void;
pub extern "webgl" fn gl_depth_func(func: u32) void;
pub extern "webgl" fn gl_depth_mask(enabled: u32) void;
pub extern "webgl" fn gl_cull_face(mode: u32) void;
pub extern "webgl" fn gl_front_face(mode: u32) void;
pub extern "webgl" fn gl_color_mask(r: u32, g: u32, b: u32, a: u32) void;
pub extern "webgl" fn gl_blend_func_separate(src_rgb: u32, dst_rgb: u32, src_alpha: u32, dst_alpha: u32) void;
pub extern "webgl" fn gl_blend_equation_separate(mode_rgb: u32, mode_alpha: u32) void;

// Clears and draws
pub extern "webgl" fn gl_clear_color(r: f32, g: f32, b: f32, a: f32) void;
pub extern "webgl" fn gl_clear_depth(depth: f32) void;
pub extern "webgl" fn gl_draw_arrays(mode: u32, first: u32, count: u32, instances: u32) void;
pub extern "webgl" fn gl_draw_elements(mode: u32, count: u32, index_type: u32, offset: u32, instances: u32) void;
pub extern "webgl" fn gl_finish() void;

// Sync — a real GPU completion signal, unlike the WebGPU arm's callback.
pub extern "webgl" fn gl_fence_sync() Handle;
/// Non-zero once the fence has signalled. Always polled with a zero timeout:
/// `MAX_CLIENT_WAIT_TIMEOUT_WEBGL` is 0, so a browser cannot block here.
pub extern "webgl" fn gl_client_wait_sync(sync: Handle) u32;
pub extern "webgl" fn gl_delete_sync(sync: Handle) void;

// Diagnostics
pub extern "webgl" fn gl_log(level: u32, ptr: [*]const u8, len: u32) void;

/// Reports a backend error to the browser console.
///
/// Deliberately not `std.log`: on `wasm32-freestanding` the default log
/// implementation reaches for `std.Options.debug_io`, which pulls in
/// `std.Io.Threaded` and posix and does not exist there. Routing through the
/// glue keeps the library usable without every consumer having to configure
/// `std_options` first.
pub fn log_err(comptime format: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[rhi/webgl] " ++ format, args) catch blk: {
        // A message longer than the buffer is truncated rather than dropped.
        break :blk buf[0..];
    };
    gl_log(3, msg.ptr, @intCast(msg.len));
}
