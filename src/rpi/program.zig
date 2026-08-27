// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! `Program` — the rpi-layer render program. A higher-level abstraction over the
//! core `rhi` layer that bundles, for one set of shader stages:
//!   * the per-stage shader binaries,
//!   * a pipeline layout (descriptor-set layouts + push-constant range),
//!   * a hash-keyed pipeline cache (graphics / compute / ray-tracing),
//!   * descriptor sets resolved by *name* through a frame-aware allocator.
//!
//! It is a faithful Zig port of the C++ engine's `RIProgram`, with one design
//! change requested for this layer: the descriptor layout + name->binding map are
//! declared *explicitly* by the caller (see `binding.Layout`) instead of being
//! derived from SPIR-V reflection. Real reflection can replace that later
//! without touching `bindDescriptors` / `findReflection`.
//!
//! Backend notes:
//!   * Vulkan paths (initialize/pipeline build/bindDescriptors/RT/bindless) are
//!     gated behind `platform_has_api(.vk)` and compile out where Vulkan is
//!     absent (e.g. macOS, where `platform_api = {.mtl}`).
//!   * Metal supports the render-pipeline cache + push constants. Compute
//!     pipelines and argument-buffer descriptors return `error.Unsupported`
//!     until the Metal binding/encoder surface grows them (matching where the
//!     Metal backend already defers descriptors to argument buffers).

const rhi = @import("../root.zig");
const std = @import("std");

const binding = @import("binding.zig");
const pdesc = @import("pipeline_desc.zig");
const dsa = @import("descriptor_set_alloc.zig");

pub const ProgramStage = binding.ProgramStage;
pub const ShaderStageFlags = binding.ShaderStageFlags;
pub const DescriptorBindingID = binding.DescriptorBindingID;
pub const BindingReflection = binding.BindingReflection;
pub const DescriptorBinding = binding.DescriptorBinding;
pub const ModuleStage = binding.ModuleStage;
pub const Layout = binding.Layout;
pub const GraphicsPipelineDesc = pdesc.GraphicsPipelineDesc;
pub const ComputePipelineDesc = pdesc.ComputePipelineDesc;

pub const PipelineBindPoint = enum { graphics, compute, ray_tracing };

pub const Program = @This();

pub const DESCRIPTOR_SET_MAX = 4;
/// Max distinct shader-input attribute locations a vertex stage can reflect.
pub const MAX_VERTEX_ATTRIBUTES = 16;

/// One per-stage shader binary (an owned copy of the SPIR-V / MSL blob). The
/// entry point is stored NUL-terminated so its `.ptr` is a valid C string for
/// `VkPipelineShaderStageCreateInfo::pName`.
const ShaderBinary = struct {
    buf: []u8 = &.{},
    entry_point: [:0]u8 = @constCast(&[_:0]u8{}),
};

/// Cache value for a built backend pipeline. The active arm is determined by the
/// renderer backend; the inactive arm is `void` via `wrapper_platform_type`.
const PipelineSlot = union {
    vk: rhi.wrapper_platform_type(.vk, struct {
        handle: rhi.vulkan.vk.Pipeline,
    }),
    mtl: rhi.wrapper_platform_type(.mtl, struct {
        render: ?rhi.metal.mtl.RenderPipelineState = null,
        primitive: rhi.metal.types.PrimitiveType = .triangle,
    }),
    /// WebGPU and WebGL2 share one arm: both are reached only on wasm, both are
    /// compiled in together, and both build the same core `rhi.Pipeline`. The
    /// `.wgpu` gate therefore reads as "this is a web target".
    web: rhi.wrapper_platform_type(.wgpu, struct {
        handle: rhi.Pipeline,
    }),
};

/// Per descriptor-set state (pool sizing + the vk allocator/layout).
const DescriptorSetSlot = struct {
    backend: union {
        vk: rhi.wrapper_platform_type(.vk, struct {
            set_layout: rhi.vulkan.vk.DescriptorSetLayout = .null_handle,
            alloc: dsa.Alloc = .{},
        }),
        mtl: rhi.wrapper_platform_type(.mtl, struct {}),
    } = undefined,

    sampler_max: u16 = 0,
    combined_image_sampler_max: u16 = 0,
    constant_buffer_max: u16 = 0,
    dynamic_constant_buffer_max: u16 = 0,
    texture_max: u16 = 0,
    storage_texture_max: u16 = 0,
    buffer_max: u16 = 0,
    storage_buffer_max: u16 = 0,
    structured_buffer_max: u16 = 0,
    storage_structured_buffer_max: u16 = 0,
    acceleration_structure_max: u16 = 0,

    /// True for sets whose layout is borrowed (bindless). The Program does not
    /// allocate / write / bind descriptors for these; the caller binds them via
    /// `bindBindlessDescriptorSet`.
    is_external: bool = false,
    /// Whether any binding actually lands in this set (vk layout was created).
    used: bool = false,
};

allocator: std.mem.Allocator,
device: *rhi.Device,

shader_bin: [ProgramStage.count]ShaderBinary = @splat(.{}),
binding_reflection: std.ArrayListUnmanaged(BindingReflection) = .empty,

has_push_constant: bool = false,
push_constant_size: u32 = 0,
push_constant_stages: ShaderStageFlags = .{},

vertex_input_mask: u32 = 0,

pipeline: std.AutoHashMapUnmanaged(u64, PipelineSlot) = .empty,

program_descriptors: [DESCRIPTOR_SET_MAX]DescriptorSetSlot = @splat(.{}),

backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct {
        pipeline_layout: rhi.vulkan.vk.PipelineLayout = .null_handle,
        rt_pipeline: std.AutoHashMapUnmanaged(u64, dsa.RTPipelineSlot) = .empty,
        layout_count: u32 = 0,
    }),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
    web: rhi.wrapper_platform_type(.wgpu, struct {
        /// Built once in `initialize`: the web backends compile a shader per
        /// program, not per pipeline.
        shader: rhi.Shader = undefined,
        /// Derived from the explicit layout, owned by the Program. The core
        /// pipeline borrows this slice, so it must outlive every pipeline in
        /// the cache.
        texture_bindings: []rhi.pipeline.TextureBinding = &.{},
        /// The pipeline `bindPipeline` last bound. `pushConstants` and
        /// `bindDescriptors` need it: on the web both are addressed through the
        /// pipeline's own layout rather than a standalone pipeline layout.
        bound: ?*rhi.Pipeline = null,
    }),
} = undefined,

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Build a Program from its shader stages and an explicit descriptor layout.
/// `modules[*].data` and `layout` are borrowed; shader blobs are copied.
pub fn initialize(
    allocator: std.mem.Allocator,
    device: *rhi.Device,
    modules: []const ModuleStage,
    layout: Layout,
) !Program {
    var self = Program{ .allocator = allocator, .device = device };

    // Copy shader binaries + entry points into per-stage slots (all backends).
    errdefer self.free_shader_bins();
    for (modules) |m| {
        const idx = @backingInt(m.stage);
        const buf = try allocator.dupe(u8, m.data);
        errdefer allocator.free(buf);
        const entry = try allocator.allocSentinel(u8, m.entry_point.len, 0);
        @memcpy(entry, m.entry_point);
        self.shader_bin[idx] = .{ .buf = buf, .entry_point = entry };
    }

    // Build the name->binding map from the explicit layout (all backends).
    errdefer self.binding_reflection.deinit(allocator);
    try self.build_reflection(layout);

    if (layout.push_constant) |pc| {
        self.has_push_constant = true;
        self.push_constant_size = pc.size;
        self.push_constant_stages = pc.stages;
    }

    if (rhi.is_target_selected(.vk)) {
        self.backend = .{ .vk = .{} };
        try self.initialize_vk(device, layout);
        return self;
    }
    if (rhi.is_target_selected(.mtl)) {
        self.backend = .{ .mtl = .{} };
        return self;
    }
    if (comptime rhi.platform_has_api(.wgpu)) {
        self.backend = .{ .web = .{} };
        try self.initialize_web(device, layout);
        return self;
    }
    return error.UnsupportedBackend;
}

// ---- Web (WebGPU / WebGL2) ------------------------------------------------

/// Compiles the program's stages and turns the explicit layout into the
/// `TextureBinding` table the core pipeline wants.
///
/// The web backends have no descriptor sets: a WebGPU bind group is built from
/// a whole pipeline-owned layout and a WebGL2 texture unit is global state, so
/// what a slot needs is a name and an index. That is why the sampler is folded
/// into its image's entry here instead of staying a binding of its own.
fn initialize_web(self: *Program, device: *rhi.Device, layout: Layout) !void {
    const vs = self.shader_bin[@backingInt(ProgramStage.vertex)];
    const fs = self.shader_bin[@backingInt(ProgramStage.fragment)];

    self.backend.web.shader = try rhi.Shader.init_graphics_shader(device, .{
        .vertex_stage = if (vs.buf.len > 0)
            .{ .data = vs.buf, .entry_point = vs.entry_point }
        else
            null,
        .fragment_stage = if (fs.buf.len > 0)
            .{ .data = fs.buf, .entry_point = fs.entry_point }
        else
            null,
    });
    errdefer self.backend.web.shader.deinit(device);

    var textures: std.ArrayListUnmanaged(rhi.pipeline.TextureBinding) = .empty;
    errdefer textures.deinit(self.allocator);
    for (layout.bindings) |b| {
        if (b.descriptor_type != .sampled_image) continue;
        // Pair with the sampler declared in the same set, if there is one. A
        // shader that only ever `Load`s (integer texel fetch) declares none,
        // and must not be given one: WebGPU validates the bind group against
        // the layout the shader actually declares.
        // Both stay null when there is none: a `sampler_binding` with no name
        // is unaddressable, and the core layer rejects that pairing outright.
        var sampler_name: ?[]const u8 = null;
        var sampler_binding: ?u32 = null;
        for (layout.bindings) |c| {
            if (c.descriptor_type != .sampler or c.set != b.set) continue;
            sampler_name = c.name;
            sampler_binding = c.binding;
            break;
        }
        try textures.append(self.allocator, .{
            .name = b.name,
            .binding = b.binding,
            .sampler_name = sampler_name,
            .sampler_binding = sampler_binding,
        });
    }
    self.backend.web.texture_bindings = try textures.toOwnedSlice(self.allocator);
}

/// Builds (and caches by `pipeline_hash`) the core pipeline and binds it.
fn bindPipelineWeb(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    pipeline_hash: u64,
    desc: GraphicsPipelineDesc,
) !void {
    const gop = try self.pipeline.getOrPut(self.allocator, pipeline_hash);
    if (!gop.found_existing) {
        errdefer _ = self.pipeline.remove(pipeline_hash);

        // `init_graphics` describes one vertex stream, which is all the web
        // backends expose. A second stream would be silently ignored, so say so.
        if (desc.vertex_streams.len > 1) return error.Unsupported;

        var attrs: std.ArrayListUnmanaged(rhi.pipeline.VertexAttribute) = .empty;
        defer attrs.deinit(self.allocator);
        for (desc.vertex_attributes) |a| {
            try attrs.append(self.allocator, .{
                .location = a.location,
                .format = try to_web_vertex_format(a.format),
                .offset = a.offset,
            });
        }

        // An entry with no format is an unused attachment slot, the same
        // reading the Metal path gives it. Every declared target is passed
        // through: the web arms of `init_graphics` reject more than one, rather
        // than this layer silently rendering to the first.
        var colors: std.ArrayListUnmanaged(rhi.pipeline.ColorTarget) = .empty;
        defer colors.deinit(self.allocator);
        for (desc.colors) |c| {
            const format = c.format orelse continue;
            try colors.append(self.allocator, .{
                .format = format,
                .blend = if (c.blend_enabled) .{
                    .src_color = c.src_color,
                    .dst_color = c.dst_color,
                    .color_op = c.color_blend_op,
                    .src_alpha = c.src_alpha,
                    .dst_alpha = c.dst_alpha,
                    .alpha_op = c.alpha_blend_op,
                    .write_mask = c.write_mask,
                } else null,
            });
        }

        gop.value_ptr.* = .{
            .web = .{
                // `init_graphics` reads these slices during the call and copies
                // what it keeps, so the temporaries above outlive their use.
                .handle = try rhi.Pipeline.init_graphics(device, .{
                    .shader = &self.backend.web.shader,
                    // Formats, not a swapchain: the rpi layer renders through
                    // dynamic rendering and knows its targets only as formats.
                    .colors = colors.items,
                    .vertex_layout = if (desc.vertex_streams.len > 0) .{
                        .stride = desc.vertex_streams[0].stride,
                        .attributes = attrs.items,
                    } else null,
                    .push_constant_size = self.push_constant_size,
                    .depth = if (desc.depth_test_enable) .{
                        .format = desc.depth_stencil_format orelse .d32_sfloat,
                        .write = desc.depth_write_enable,
                        .compare = desc.depth_compare_op,
                    } else null,
                    .texture_bindings = self.backend.web.texture_bindings,
                }),
            },
        };
    }

    const slot = &gop.value_ptr.web.handle;
    cmd.bind_pipeline(device, slot);
    self.backend.web.bound = slot;
}

/// The web vertex layout carries only float vectors, which is everything the
/// neutral desc's callers use. An unmapped format is refused rather than
/// approximated -- a silently wrong stride reads as corrupt geometry.
fn to_web_vertex_format(format: rhi.Format) !rhi.pipeline.VertexFormat {
    return switch (format) {
        .r32_sfloat => .float,
        .rg32_sfloat => .float2,
        .rgb32_sfloat => .float3,
        .rgba32_sfloat => .float4,
        else => error.Unsupported,
    };
}

fn free_shader_bins(self: *Program) void {
    for (&self.shader_bin) |*b| {
        if (b.buf.len > 0) self.allocator.free(b.buf);
        if (b.entry_point.len > 0) self.allocator.free(b.entry_point);
        b.* = .{};
    }
}

/// Build `binding_reflection` (name hash -> set/register) and tally per-set pool
/// sizing counts from the explicit layout. Backend-independent.
fn build_reflection(self: *Program, layout: Layout) !void {
    for (layout.bindings) |lb| {
        std.debug.assert(lb.set < DESCRIPTOR_SET_MAX);
        const id = DescriptorBindingID.create(lb.name);
        const is_array = lb.count > 1;
        try self.binding_reflection.append(self.allocator, .{
            .hash = id.hash,
            .is_array = is_array,
            .dim_count = @intCast(@max(1, lb.count)),
            .set = @intCast(lb.set),
            .base_register_index = @intCast(lb.binding),
            .descriptor_type = lb.descriptor_type,
        });

        var slot = &self.program_descriptors[lb.set];
        slot.used = true;
        const n: u16 = @intCast(@max(1, lb.count));
        switch (lb.descriptor_type) {
            .sampler => slot.sampler_max += n,
            .combined_image_sampler => slot.combined_image_sampler_max += n,
            .sampled_image => slot.texture_max += n,
            .storage_image => slot.storage_texture_max += n,
            .uniform_texel_buffer => slot.buffer_max += n,
            .storage_texel_buffer => slot.storage_buffer_max += n,
            .uniform_buffer => slot.constant_buffer_max += n,
            .uniform_buffer_dynamic => slot.dynamic_constant_buffer_max += n,
            .storage_buffer, .storage_buffer_dynamic => slot.structured_buffer_max += n,
            .acceleration_structure => slot.acceleration_structure_max += n,
            else => {},
        }
    }
}

pub fn deinit(self: *Program, device: *rhi.Device) void {
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const dev = device.backend.vk.device;
        var it = self.pipeline.valueIterator();
        while (it.next()) |slot| dkb.destroyPipeline(dev, slot.vk.handle, null);
        var rit = self.backend.vk.rt_pipeline.iterator();
        while (rit.next()) |e| e.value_ptr.destroy(device);
        self.backend.vk.rt_pipeline.deinit(self.allocator);
        for (&self.program_descriptors) |*slot| {
            if (slot.is_external or !slot.used) continue;
            slot.backend.vk.alloc.free(self.allocator, device);
            if (slot.backend.vk.set_layout != .null_handle)
                dkb.destroyDescriptorSetLayout(dev, slot.backend.vk.set_layout, null);
        }
        if (self.backend.vk.pipeline_layout != .null_handle)
            dkb.destroyPipelineLayout(dev, self.backend.vk.pipeline_layout, null);
    } else if (rhi.is_target_selected(.mtl)) {
        var it = self.pipeline.valueIterator();
        while (it.next()) |slot| {
            if (slot.mtl.render) |r| r.release();
        }
    } else if (comptime rhi.platform_has_api(.wgpu)) {
        var it = self.pipeline.valueIterator();
        while (it.next()) |slot| slot.web.handle.deinit(device);
        self.allocator.free(self.backend.web.texture_bindings);
        self.backend.web.shader.deinit(device);
    }
    self.pipeline.deinit(self.allocator);
    self.binding_reflection.deinit(self.allocator);
    self.free_shader_bins();
}

pub fn findReflection(self: *Program, handle: DescriptorBindingID) ?*const BindingReflection {
    for (self.binding_reflection.items) |*r| {
        if (r.hash == handle.hash) return r;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Pipeline binding
// ---------------------------------------------------------------------------

/// Build (and cache by `pipeline_hash`) the backend graphics pipeline from the
/// neutral descriptor and bind it on `cmd`.
pub fn bindPipeline(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    pipeline_hash: u64,
    debug_name: [*:0]const u8,
    desc: GraphicsPipelineDesc,
) !void {
    if (rhi.is_target_selected(.vk)) {
        try self.bindPipelineVk(device, cmd, pipeline_hash, debug_name, desc);
        return;
    }
    if (rhi.is_target_selected(.mtl)) {
        try self.bindPipelineMtl(device, cmd, pipeline_hash, debug_name, desc);
        return;
    }
    if (comptime rhi.platform_has_api(.wgpu)) {
        // `debug_name` has nowhere to go: neither web backend exposes object
        // labels through the glue.
        try self.bindPipelineWeb(device, cmd, pipeline_hash, desc);
        return;
    }
    return error.UnsupportedBackend;
}

/// Build/cache/bind the compute pipeline. Vulkan only for now.
pub fn bindComputePipeline(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    pipeline_hash: u64,
    debug_name: [*:0]const u8,
    desc: ComputePipelineDesc,
) !void {
    _ = desc;
    if (rhi.is_target_selected(.vk)) {
        try self.bindComputePipelineVk(device, cmd, pipeline_hash, debug_name);
        return;
    }
    // Metal compute requires a ComputePipelineState binding + a compute encoder
    // on Cmd, neither of which exist yet.
    return error.Unsupported;
}

/// Upload push constants using the program's reflected stage flags + layout.
pub fn pushConstants(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    data: []const u8,
    offset: u32,
) void {
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdPushConstants(
            cmd.backend.vk.cmd,
            self.backend.vk.pipeline_layout,
            self.push_constant_stages.to_vk(),
            offset,
            @intCast(data.len),
            data.ptr,
        );
        return;
    }
    if (rhi.is_target_selected(.mtl)) {
        // slangc emits the push-constant block at buffer(0). Set it on whichever
        // stages reference it.
        const enc = cmd.backend.mtl.encoder.?;
        if (self.push_constant_stages.vertex) enc.setVertexBytes(data.ptr, data.len, 0);
        if (self.push_constant_stages.fragment) enc.setFragmentBytes(data.ptr, data.len, 0);
        return;
    }
    if (comptime rhi.platform_has_api(.wgpu)) {
        // WebGPU has no push constants; the core layer emulates them with a
        // pipeline-owned uniform buffer, which is why this needs the pipeline
        // rather than a standalone layout. A partial update has no meaning
        // against a whole-buffer write, so a non-zero offset is a caller error.
        std.debug.assert(offset == 0);
        const pipeline = self.backend.web.bound orelse {
            std.debug.assert(false); // pushConstants before bindPipeline
            return;
        };
        cmd.set_push_constants(device, pipeline, data);
        return;
    }
}

// ---- Metal pipeline build -------------------------------------------------

fn bindPipelineMtl(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    pipeline_hash: u64,
    debug_name: [*:0]const u8,
    desc: GraphicsPipelineDesc,
) !void {
    const gop = try self.pipeline.getOrPut(self.allocator, pipeline_hash);
    if (!gop.found_existing) {
        errdefer _ = self.pipeline.remove(pipeline_hash);
        const dev = device.backend.mtl.device;
        const rp = rhi.metal.mtl.RenderPipelineDescriptor.init();
        defer rp.release();

        const vfn = try self.mtl_load_function(dev, .vertex);
        defer if (vfn) |f| f.release();
        const ffn = try self.mtl_load_function(dev, .fragment);
        defer if (ffn) |f| f.release();
        if (vfn) |f| rp.setVertexFunction(f);
        if (ffn) |f| rp.setFragmentFunction(f);

        for (desc.colors, 0..) |c, i| {
            const fmt = c.format orelse continue;
            // The Metal binding currently only exposes setPixelFormat on color
            // attachments; per-attachment blend state is a follow-up once the
            // bindings grow setBlendingEnabled/setSourceRGBBlendFactor/etc.
            rp.colorAttachments().object(@intCast(i)).setPixelFormat(pdesc.to_mtl_pixel_format(fmt));
        }
        if (desc.depth_stencil_format) |fmt| {
            rp.setDepthAttachmentPixelFormat(pdesc.to_mtl_pixel_format(fmt));
        }
        if (desc.vertex_attributes.len > 0) {
            const vd = rhi.metal.mtl.VertexDescriptor.vertexDescriptor();
            for (desc.vertex_attributes) |a| {
                const va = vd.attributes().object(a.location);
                va.setFormat(pdesc.to_mtl_vertex_format(a.format));
                va.setOffset(a.offset);
                va.setBufferIndex(a.binding);
            }
            for (desc.vertex_streams) |s| {
                const l = vd.layouts().object(s.binding);
                l.setStride(s.stride);
                l.setStepFunction(if (s.per_instance) .per_instance else .per_vertex);
            }
            rp.setVertexDescriptor(vd);
        }

        var err: ?rhi.metal.ns.Error = null;
        const state = dev.newRenderPipelineState(rp, &err) orelse {
            if (err) |e| std.log.err("metal render pipeline '{s}': {s}", .{ debug_name, e.localizedDescription().utf8() });
            return error.PipelineCreationFailed;
        };
        gop.value_ptr.* = .{ .mtl = .{ .render = state, .primitive = desc.topology.to_mtl() } };
    }
    cmd.backend.mtl.encoder.?.setRenderPipelineState(gop.value_ptr.mtl.render.?);
}

fn mtl_load_function(
    self: *Program,
    dev: rhi.metal.mtl.Device,
    stage: ProgramStage,
) !?rhi.metal.mtl.Function {
    const bin = self.shader_bin[@backingInt(stage)];
    if (bin.buf.len == 0) return null;
    const src = rhi.metal.ns.String.fromUtf8Slice(bin.buf);
    var err: ?rhi.metal.ns.Error = null;
    const lib = dev.newLibraryWithSource(src, null, &err) orelse {
        if (err) |e| std.log.err("MSL compile: {s}", .{e.localizedDescription().utf8()});
        return error.ShaderCompilationFailed;
    };
    defer lib.release();
    const name = rhi.metal.ns.String.fromUtf8Slice(bin.entry_point);
    return lib.newFunction(name) orelse error.ShaderEntryPointNotFound;
}

// ---- Vulkan pipeline build (compiled out on non-Vulkan backends) ----------

fn initialize_vk(self: *Program, device: *rhi.Device, layout: Layout) !void {
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    const dev = device.backend.vk.device;
    const a = self.allocator;

    // Accumulate per-set layout bindings.
    var set_bindings: [DESCRIPTOR_SET_MAX]std.ArrayListUnmanaged(rhi.vulkan.vk.DescriptorSetLayoutBinding) =
        @splat(.empty);
    var set_flags: [DESCRIPTOR_SET_MAX]std.ArrayListUnmanaged(rhi.vulkan.vk.DescriptorBindingFlags) =
        @splat(.empty);
    defer for (0..DESCRIPTOR_SET_MAX) |i| {
        set_bindings[i].deinit(a);
        set_flags[i].deinit(a);
    };

    for (layout.bindings) |lb| {
        const flags: rhi.vulkan.vk.DescriptorBindingFlags =
            if (lb.count > 1) .{ .partially_bound = true } else .{};
        try set_bindings[lb.set].append(a, .{
            .binding = lb.binding,
            .descriptor_type = vk_descriptor_type(lb.descriptor_type),
            .descriptor_count = @max(1, lb.count),
            .stage_flags = lb.stages.to_vk(),
        });
        try set_flags[lb.set].append(a, flags);
    }

    // Determine how many set layouts the pipeline layout needs (highest used set
    // index + 1, accounting for external layouts).
    var layout_count: u32 = 0;
    for (0..DESCRIPTOR_SET_MAX) |i| {
        if (set_bindings[i].items.len > 0 or external_layout_for(layout, i) != null)
            layout_count = @intCast(i + 1);
    }

    var set_layouts: [DESCRIPTOR_SET_MAX]rhi.vulkan.vk.DescriptorSetLayout =
        @splat(.null_handle);

    for (0..layout_count) |i| {
        if (external_layout_for(layout, i)) |ext| {
            set_layouts[i] = ext;
            self.program_descriptors[i].is_external = true;
            continue;
        }
        if (set_bindings[i].items.len > 0) {
            var flags_info: rhi.vulkan.vk.DescriptorSetLayoutBindingFlagsCreateInfo = .{
                .binding_count = @intCast(set_flags[i].items.len),
                .p_binding_flags = set_flags[i].items.ptr,
            };
            var create_info: rhi.vulkan.vk.DescriptorSetLayoutCreateInfo = .{
                .binding_count = @intCast(set_bindings[i].items.len),
                .p_bindings = set_bindings[i].items.ptr,
            };
            rhi.vulkan.add_next(&create_info, &flags_info);
            set_layouts[i] = try dkb.createDescriptorSetLayout(dev, &create_info, null);
        } else {
            // Gap: empty layout so the set index stays valid in the pipeline layout.
            var create_info: rhi.vulkan.vk.DescriptorSetLayoutCreateInfo = .{};
            set_layouts[i] = try dkb.createDescriptorSetLayout(dev, &create_info, null);
        }
        var slot = &self.program_descriptors[i];
        slot.backend = .{ .vk = .{
            .set_layout = set_layouts[i],
            .alloc = dsa.Alloc.init(.{
                .set_layout = set_layouts[i],
                .sizes = .{
                    .sampler = slot.sampler_max,
                    .combined_image_sampler = slot.combined_image_sampler_max,
                    .constant_buffer = slot.constant_buffer_max,
                    .dynamic_constant_buffer = slot.dynamic_constant_buffer_max,
                    .texture = slot.texture_max,
                    .storage_texture = slot.storage_texture_max,
                    .buffer = slot.buffer_max,
                    .storage_buffer = slot.storage_buffer_max,
                    .structured_buffer = slot.structured_buffer_max,
                    .storage_structured_buffer = slot.storage_structured_buffer_max,
                    .acceleration_structure = slot.acceleration_structure_max,
                },
            }, dsa.RI_NUMBER_FRAMES_FLIGHT),
        } };
    }

    var push_range: [1]rhi.vulkan.vk.PushConstantRange = undefined;
    var layout_create: rhi.vulkan.vk.PipelineLayoutCreateInfo = .{
        .set_layout_count = layout_count,
        .p_set_layouts = &set_layouts,
    };
    if (layout.push_constant) |pc| {
        push_range[0] = .{ .stage_flags = pc.stages.to_vk(), .offset = 0, .size = pc.size };
        layout_create.push_constant_range_count = 1;
        layout_create.p_push_constant_ranges = &push_range;
    }
    self.backend.vk.layout_count = layout_count;
    self.backend.vk.pipeline_layout = try dkb.createPipelineLayout(dev, &layout_create, null);
}

fn bindPipelineVk(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    pipeline_hash: u64,
    debug_name: [*:0]const u8,
    desc: GraphicsPipelineDesc,
) !void {
    _ = debug_name;
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    const dev = device.backend.vk.device;

    const gop = try self.pipeline.getOrPut(self.allocator, pipeline_hash);
    if (!gop.found_existing) {
        errdefer _ = self.pipeline.remove(pipeline_hash);

        var streams: [pdesc.MAX_VERTEX_STREAMS]rhi.vulkan.vk.VertexInputBindingDescription = undefined;
        for (desc.vertex_streams, 0..) |s, i| streams[i] = .{
            .binding = s.binding,
            .stride = s.stride,
            .input_rate = if (s.per_instance) .instance else .vertex,
        };
        var attrs: [pdesc.MAX_VERTEX_ATTRIBUTES]rhi.vulkan.vk.VertexInputAttributeDescription = undefined;
        for (desc.vertex_attributes, 0..) |at, i| attrs[i] = .{
            .location = at.location,
            .binding = at.binding,
            .format = rhi.vulkan.to_vk_format(at.format),
            .offset = at.offset,
        };
        var vertex_input: rhi.vulkan.vk.PipelineVertexInputStateCreateInfo = .{
            .vertex_binding_description_count = @intCast(desc.vertex_streams.len),
            .p_vertex_binding_descriptions = if (desc.vertex_streams.len > 0) &streams else null,
            .vertex_attribute_description_count = @intCast(desc.vertex_attributes.len),
            .p_vertex_attribute_descriptions = if (desc.vertex_attributes.len > 0) &attrs else null,
        };
        var input_assembly: rhi.vulkan.vk.PipelineInputAssemblyStateCreateInfo =
            .{ .topology = desc.topology.to_vk(), .primitive_restart_enable = .false };
        var raster: rhi.vulkan.vk.PipelineRasterizationStateCreateInfo = .{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = desc.cull_mode.to_vk(),
            .front_face = if (desc.front_counter_clockwise) .counter_clockwise else .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };
        var viewport_state: rhi.vulkan.vk.PipelineViewportStateCreateInfo =
            .{ .viewport_count = 1, .scissor_count = 1 };
        var multisample: rhi.vulkan.vk.PipelineMultisampleStateCreateInfo = .{
            .rasterization_samples = vk_sample_count(desc.sample_count),
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };
        var depth_stencil: rhi.vulkan.vk.PipelineDepthStencilStateCreateInfo = .{
            .depth_test_enable = if (desc.depth_test_enable) .true else .false,
            .depth_write_enable = if (desc.depth_write_enable) .true else .false,
            .depth_compare_op = desc.depth_compare_op.to_vk(),
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
            .front = std.mem.zeroes(rhi.vulkan.vk.StencilOpState),
            .back = std.mem.zeroes(rhi.vulkan.vk.StencilOpState),
        };
        var blend_attach: [pdesc.MAX_COLOR_ATTACHMENTS]rhi.vulkan.vk.PipelineColorBlendAttachmentState = undefined;
        var color_formats: [pdesc.MAX_COLOR_ATTACHMENTS]rhi.vulkan.vk.Format = undefined;
        for (desc.colors, 0..) |c, i| {
            blend_attach[i] = .{
                .blend_enable = if (c.blend_enabled) .true else .false,
                .src_color_blend_factor = c.src_color.to_vk(),
                .dst_color_blend_factor = c.dst_color.to_vk(),
                .color_blend_op = c.color_blend_op.to_vk(),
                .src_alpha_blend_factor = c.src_alpha.to_vk(),
                .dst_alpha_blend_factor = c.dst_alpha.to_vk(),
                .alpha_blend_op = c.alpha_blend_op.to_vk(),
                .color_write_mask = .{
                    .r = c.write_mask.r == 1,
                    .g = c.write_mask.g == 1,
                    .b = c.write_mask.b == 1,
                    .a = c.write_mask.a == 1,
                },
            };
            color_formats[i] = rhi.vulkan.to_vk_format(c.format orelse .unknown);
        }
        var color_blend: rhi.vulkan.vk.PipelineColorBlendStateCreateInfo = .{
            .logic_op_enable = .false,
            .logic_op = .clear,
            .blend_constants = .{ 0, 0, 0, 0 },
            .attachment_count = @intCast(desc.colors.len),
            .p_attachments = if (desc.colors.len > 0) &blend_attach else null,
        };
        var dynamic_states = [_]rhi.vulkan.vk.DynamicState{ .viewport, .scissor };
        var dynamic_state: rhi.vulkan.vk.PipelineDynamicStateCreateInfo =
            .{ .dynamic_state_count = dynamic_states.len, .p_dynamic_states = &dynamic_states };

        var rendering_info: rhi.vulkan.vk.PipelineRenderingCreateInfo = .{
            .color_attachment_count = @intCast(desc.colors.len),
            .p_color_attachment_formats = if (desc.colors.len > 0) &color_formats else null,
            .view_mask = 0,
            .depth_attachment_format = if (desc.depth_stencil_format) |f| rhi.vulkan.to_vk_format(f) else .undefined,
            .stencil_attachment_format = .undefined,
        };

        // Shader stages (vertex + fragment) built from the program's binaries.
        var modules: [2]rhi.vulkan.vk.ShaderModule = .{ .null_handle, .null_handle };
        var stages: [2]rhi.vulkan.vk.PipelineShaderStageCreateInfo = undefined;
        var stage_count: u32 = 0;
        defer for (0..stage_count) |i| dkb.destroyShaderModule(dev, modules[i], null);
        const stage_table = [_]struct { s: ProgramStage, bit: rhi.vulkan.vk.ShaderStageFlags }{
            .{ .s = .vertex, .bit = .{ .vertex = true } },
            .{ .s = .fragment, .bit = .{ .fragment = true } },
        };
        for (stage_table) |st| {
            const bin = self.shader_bin[@backingInt(st.s)];
            if (bin.buf.len == 0) continue;
            std.debug.assert(bin.buf.len % @sizeOf(u32) == 0);
            var mod_info: rhi.vulkan.vk.ShaderModuleCreateInfo = .{
                .code_size = bin.buf.len,
                .p_code = @ptrCast(@alignCast(bin.buf.ptr)),
            };
            modules[stage_count] = try dkb.createShaderModule(dev, &mod_info, null);
            stages[stage_count] = .{
                .stage = st.bit,
                .module = modules[stage_count],
                .p_name = @ptrCast(bin.entry_point.ptr),
            };
            stage_count += 1;
        }

        var create_info = [1]rhi.vulkan.vk.GraphicsPipelineCreateInfo{.{
            .stage_count = stage_count,
            .p_stages = &stages,
            .subpass = 0,
            .layout = self.backend.vk.pipeline_layout,
            .base_pipeline_index = -1,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &raster,
            .p_multisample_state = &multisample,
            .p_depth_stencil_state = &depth_stencil,
            .p_color_blend_state = &color_blend,
            .p_dynamic_state = &dynamic_state,
        }};
        rhi.vulkan.add_next(&create_info[0], &rendering_info);
        var handle: [1]rhi.vulkan.vk.Pipeline = .{.null_handle};
        _ = try dkb.createGraphicsPipelines(dev, .null_handle, &create_info, null, &handle);
        gop.value_ptr.* = .{ .vk = .{ .handle = handle[0] } };
    }
    dkb.cmdBindPipeline(cmd.backend.vk.cmd, .graphics, gop.value_ptr.vk.handle);
}

fn bindComputePipelineVk(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    pipeline_hash: u64,
    debug_name: [*:0]const u8,
) !void {
    _ = debug_name;
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    const dev = device.backend.vk.device;

    const gop = try self.pipeline.getOrPut(self.allocator, pipeline_hash);
    if (!gop.found_existing) {
        errdefer _ = self.pipeline.remove(pipeline_hash);
        const bin = self.shader_bin[@backingInt(ProgramStage.compute)];
        std.debug.assert(bin.buf.len > 0);
        std.debug.assert(bin.buf.len % @sizeOf(u32) == 0);
        var mod_info: rhi.vulkan.vk.ShaderModuleCreateInfo = .{
            .code_size = bin.buf.len,
            .p_code = @ptrCast(@alignCast(bin.buf.ptr)),
        };
        const module = try dkb.createShaderModule(dev, &mod_info, null);
        defer dkb.destroyShaderModule(dev, module, null);
        var create_info = [1]rhi.vulkan.vk.ComputePipelineCreateInfo{.{
            .stage = .{
                .stage = .{ .compute = true },
                .module = module,
                .p_name = @ptrCast(bin.entry_point.ptr),
            },
            .layout = self.backend.vk.pipeline_layout,
            .base_pipeline_index = -1,
        }};
        var handle: [1]rhi.vulkan.vk.Pipeline = .{.null_handle};
        _ = try dkb.createComputePipelines(dev, .null_handle, &create_info, null, &handle);
        gop.value_ptr.* = .{ .vk = .{ .handle = handle[0] } };
    }
    dkb.cmdBindPipeline(cmd.backend.vk.cmd, .compute, gop.value_ptr.vk.handle);
}

// ---------------------------------------------------------------------------
// Descriptor binding (by name)
// ---------------------------------------------------------------------------

/// Resolve, write, and bind descriptor sets for `bindings` by name. On Vulkan
/// this allocates per-set descriptor sets from the frame-aware ring, writes the
/// reflected bindings, and issues `vkCmdBindDescriptorSets`. Metal argument
/// buffers are a follow-up.
pub fn bindDescriptors(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    frame_index: u32,
    bindings: []const DescriptorBinding,
    bind_point: PipelineBindPoint,
) !void {
    if (rhi.is_target_selected(.vk)) {
        try self.bindDescriptorsVk(device, cmd, frame_index, bindings, bind_point);
        return;
    }
    if (comptime rhi.platform_has_api(.wgpu)) {
        // `frame_index` is unused here: it exists to pick a per-frame descriptor
        // set, and the web has none -- a WebGPU bind group is memoised by the
        // core layer against the resources that went into it.
        if (bind_point != .graphics) return error.Unsupported;
        const pipeline = self.backend.web.bound orelse return error.Unsupported;
        try cmd.web_bind_descriptors(device, pipeline, bindings);
        return;
    }
    // Metal: argument buffers + a compute encoder + useResource plumbing are not
    // yet wired in the Metal backend.
    return error.Unsupported;
}

fn bindDescriptorsVk(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    frame_index: u32,
    bindings: []const DescriptorBinding,
    bind_point: PipelineBindPoint,
) !void {
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    const dev = device.backend.vk.device;
    const vk_bind: rhi.vulkan.vk.PipelineBindPoint = switch (bind_point) {
        .graphics => .graphics,
        .compute => .compute,
        .ray_tracing => .ray_tracing_khr,
    };

    var sets_to_bind: [DESCRIPTOR_SET_MAX]rhi.vulkan.vk.DescriptorSet = undefined;
    var first_set: u32 = 0;
    var bind_count: u32 = 0;

    for (0..DESCRIPTOR_SET_MAX) |set_index| {
        const slot = &self.program_descriptors[set_index];
        if (slot.is_external or !slot.used) continue;

        // Identity hash over the bindings landing in this set.
        var hash: u64 = std.hash.Wyhash.hash(0, "rpi.descset");
        for (bindings) |*b| {
            const refl = self.findReflection(b.handle) orelse continue;
            if (refl.set != set_index or b.descriptor.cookie == 0) continue;
            hash = mix(hash, refl.hash);
            hash = mix(hash, b.register_offset);
            hash = mix(hash, b.descriptor.cookie);
        }
        if (hash == std.hash.Wyhash.hash(0, "rpi.descset")) continue;

        const result = try slot.backend.vk.alloc.resolve(self.allocator, device, frame_index, hash);
        if (!result.found) {
            var writes: [32]rhi.vulkan.vk.WriteDescriptorSet = undefined;
            // Per-write payload storage kept alive across the vkUpdateDescriptorSets
            // flush: the DescriptorBinding's descriptor is a caller-owned value, so
            // its VkDescriptor*Info must be copied into stable storage before the
            // WriteDescriptorSet pointers can reference it (mirrors RIProgram.cpp).
            var image_infos: [32]rhi.vulkan.vk.DescriptorImageInfo = undefined;
            var buffer_infos: [32]rhi.vulkan.vk.DescriptorBufferInfo = undefined;
            var accel_handles: [32]rhi.vulkan.vk.AccelerationStructureKHR = undefined;
            var accel_writes: [32]rhi.vulkan.vk.WriteDescriptorSetAccelerationStructureKHR = undefined;
            var n: usize = 0;
            for (bindings) |*b| {
                const refl = self.findReflection(b.handle) orelse continue;
                if (refl.set != set_index or b.descriptor.cookie == 0) continue;
                if (n == writes.len) {
                    dkb.updateDescriptorSets(dev, writes[0..n], null);
                    n = 0;
                }
                const w = &writes[n];
                w.* = .{
                    .dst_set = result.set.handle,
                    .dst_binding = if (refl.is_array) refl.base_register_index else @as(u32, refl.base_register_index) + b.register_offset,
                    .dst_array_element = if (refl.is_array) b.register_offset else 0,
                    .descriptor_count = 1,
                    .descriptor_type = b.descriptor.backend.vk.type,
                    // Point at the per-write stable slots; Vulkan reads only the one
                    // matching descriptor_type, the others are ignored.
                    .p_image_info = @ptrCast(&image_infos[n]),
                    .p_buffer_info = @ptrCast(&buffer_infos[n]),
                    .p_texel_buffer_view = undefined,
                };
                switch (b.descriptor.type) {
                    .uniform_buffer, .storage_buffer => buffer_infos[n] = b.descriptor.backend.vk.view.buffer,
                    .sampler, .sampled_image, .storage_image => image_infos[n] = b.descriptor.backend.vk.view.image,
                    .acceleration_structure => {
                        accel_handles[n] = b.descriptor.backend.vk.view.accel;
                        accel_writes[n] = .{
                            .acceleration_structure_count = 1,
                            .p_acceleration_structures = @ptrCast(&accel_handles[n]),
                        };
                        w.p_next = &accel_writes[n];
                    },
                }
                n += 1;
            }
            if (n > 0) dkb.updateDescriptorSets(dev, writes[0..n], null);
        }

        if (bind_count > 0 and first_set + bind_count != set_index) {
            dkb.cmdBindDescriptorSets(cmd.backend.vk.cmd, vk_bind, self.backend.vk.pipeline_layout, first_set, sets_to_bind[0..bind_count], null);
            bind_count = 0;
        }
        if (bind_count == 0) first_set = @intCast(set_index);
        sets_to_bind[bind_count] = result.set.handle;
        bind_count += 1;
    }
    if (bind_count > 0) {
        dkb.cmdBindDescriptorSets(cmd.backend.vk.cmd, vk_bind, self.backend.vk.pipeline_layout, first_set, sets_to_bind[0..bind_count], null);
    }
}

/// Bind an externally-owned bindless descriptor set at `set_index` against this
/// program's pipeline layout (Vulkan only).
pub fn bindBindlessDescriptorSet(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    set: rhi.vulkan.vk.DescriptorSet,
    set_index: u32,
    bind_point: PipelineBindPoint,
) void {
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    const vk_bind: rhi.vulkan.vk.PipelineBindPoint = switch (bind_point) {
        .graphics => .graphics,
        .compute => .compute,
        .ray_tracing => .ray_tracing_khr,
    };
    const sets = [_]rhi.vulkan.vk.DescriptorSet{set};
    dkb.cmdBindDescriptorSets(cmd.backend.vk.cmd, vk_bind, self.backend.vk.pipeline_layout, set_index, &sets, null);
}

// ---------------------------------------------------------------------------
// Ray tracing (Vulkan only)
// ---------------------------------------------------------------------------

/// Build (and cache) a ray-tracing pipeline + its SBT, then bind it. The caller
/// fills only pNext/flags/maxPipelineRayRecursionDepth on `create_info`; stages,
/// groups, and layout are filled from the program. See `descriptor_set_alloc.zig`
/// for the SBT slot.
pub fn bindRayTracingPipeline(
    self: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    pipeline_hash: u64,
    create_info: *rhi.vulkan.vk.RayTracingPipelineCreateInfoKHR,
) !void {
    try dsa.bindRayTracingPipeline(self, device, cmd, pipeline_hash, create_info);
}

/// Issue `vkCmdTraceRaysKHR` against the cached SBT for `pipeline_hash`.
pub fn traceRays(self: *Program, device: *rhi.Device, cmd: *rhi.Cmd, pipeline_hash: u64, width: u32, height: u32, depth: u32) void {
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    const slot = self.backend.vk.rt_pipeline.get(pipeline_hash).?;
    dkb.cmdTraceRaysKHR(cmd.backend.vk.cmd, &slot.raygen_region, &slot.miss_region, &slot.hit_region, &slot.callable_region, width, height, depth);
}

// ---------------------------------------------------------------------------
// Helpers (only referenced from Vulkan branches)
// ---------------------------------------------------------------------------

fn external_layout_for(layout: Layout, set_index: usize) ?rhi.vulkan.vk.DescriptorSetLayout {
    if (set_index < layout.external_sets.len) {
        if (layout.external_sets[set_index]) |ext| return ext;
    }
    return null;
}

fn mix(h: u64, v: anytype) u64 {
    return std.hash.Wyhash.hash(h, std.mem.asBytes(&@as(u64, v)));
}

fn vk_sample_count(n: u32) rhi.vulkan.vk.SampleCountFlags {
    return switch (n) {
        0, 1 => .{ .@"1" = true },
        2 => .{ .@"2" = true },
        4 => .{ .@"4" = true },
        8 => .{ .@"8" = true },
        else => .{ .@"1" = true },
    };
}

fn vk_descriptor_type(t: binding.DescriptorType) rhi.vulkan.vk.DescriptorType {
    return switch (t) {
        .sampler => .sampler,
        .combined_image_sampler => .combined_image_sampler,
        .sampled_image => .sampled_image,
        .storage_image => .storage_image,
        .uniform_texel_buffer => .uniform_texel_buffer,
        .storage_texel_buffer => .storage_texel_buffer,
        .uniform_buffer => .uniform_buffer,
        .storage_buffer => .storage_buffer,
        .uniform_buffer_dynamic => .uniform_buffer_dynamic,
        .storage_buffer_dynamic => .storage_buffer_dynamic,
        .input_attachment => .input_attachment,
        .inline_uniform_block => .inline_uniform_block,
        .acceleration_structure => .acceleration_structure_khr,
    };
}
