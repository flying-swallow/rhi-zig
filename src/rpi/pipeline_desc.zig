// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Backend-neutral pipeline descriptors for the `rpi` (render-program
//! interface) layer. These mirror `RIGraphicsPipelineDesc` /
//! `RIComputePipelineDesc` from the C++ engine: the same call site builds a
//! `VkGraphicsPipelineCreateInfo` on Vulkan or an `MTL::RenderPipelineDescriptor`
//! on Metal. The descriptors carry exactly the state the engine's render passes
//! set today (topology, raster, depth, per-attachment blend, dynamic-rendering
//! color/depth formats, vertex layout) using RI/rhi enums.
//!
//! `rpi` is a higher-level layer that sits on top of the core `rhi` module and
//! only composes its public surface (Shader, Pipeline, Buffer, Image, ...).

const rhi = @import("../root.zig");
const std = @import("std");

/// Reused from the core layer so the neutral desc and the lower-level pipeline
/// builders speak the same blend/write vocabulary.
pub const BlendFactor = rhi.pipeline.BlendFactor;
pub const BlendOp = rhi.pipeline.BlendOp;
pub const WriteMask = rhi.pipeline.WriteMask;

pub const Topology = enum(u8) {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,

    pub fn to_vk(self: Topology) rhi.vulkan.vk.PrimitiveTopology {
        return switch (self) {
            .point_list => .point_list,
            .line_list => .line_list,
            .line_strip => .line_strip,
            .triangle_list => .triangle_list,
            .triangle_strip => .triangle_strip,
        };
    }

    pub fn to_mtl(self: Topology) rhi.metal.types.PrimitiveType {
        return switch (self) {
            .point_list => .point,
            .line_list => .line,
            .line_strip => .line_strip,
            .triangle_list => .triangle,
            .triangle_strip => .triangle_strip,
        };
    }
};

pub const CullMode = enum(u8) {
    none,
    front,
    back,

    pub fn to_vk(self: CullMode) rhi.vulkan.vk.CullModeFlags {
        return switch (self) {
            .none => .{},
            .front => .{ .front = true },
            .back => .{ .back = true },
        };
    }
};

pub const CompareOp = enum(u8) {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,

    pub fn to_vk(self: CompareOp) rhi.vulkan.vk.CompareOp {
        return switch (self) {
            .never => .never,
            .less => .less,
            .equal => .equal,
            .less_equal => .less_or_equal,
            .greater => .greater,
            .not_equal => .not_equal,
            .greater_equal => .greater_or_equal,
            .always => .always,
        };
    }

    pub fn to_mtl(self: CompareOp) rhi.metal.types.CompareFunction {
        return switch (self) {
            .never => .never,
            .less => .less,
            .equal => .equal,
            .less_equal => .less_equal,
            .greater => .greater,
            .not_equal => .not_equal,
            .greater_equal => .greater_equal,
            .always => .always,
        };
    }
};

/// A single vertex attribute. `format` is a core `rhi.Format`; it is lowered to
/// the backend vertex-format on build.
pub const VertexAttribute = struct {
    location: u32,
    binding: u32,
    format: rhi.Format,
    offset: u32,
};

pub const VertexStream = struct {
    binding: u32,
    stride: u32,
    per_instance: bool = false,
};

/// One color render target: format (null => attachment unused) plus per-target
/// blend state.
pub const ColorAttachment = struct {
    format: ?rhi.Format = null,
    blend_enabled: bool = false,
    src_color: BlendFactor = .one,
    dst_color: BlendFactor = .zero,
    color_blend_op: BlendOp = .add,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .zero,
    alpha_blend_op: BlendOp = .add,
    write_mask: WriteMask = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
};

pub const MAX_COLOR_ATTACHMENTS = 8;
pub const MAX_VERTEX_STREAMS = 16;
pub const MAX_VERTEX_ATTRIBUTES = 16;

/// Backend-neutral graphics-pipeline description consumed by
/// `Program.bindPipeline`.
pub const GraphicsPipelineDesc = struct {
    topology: Topology = .triangle_list,
    cull_mode: CullMode = .none,
    front_counter_clockwise: bool = false,

    depth_test_enable: bool = false,
    depth_write_enable: bool = false,
    depth_compare_op: CompareOp = .less_equal,
    /// null => no depth attachment.
    depth_stencil_format: ?rhi.Format = null,

    sample_count: u32 = 1,

    colors: []const ColorAttachment = &.{},
    vertex_streams: []const VertexStream = &.{},
    vertex_attributes: []const VertexAttribute = &.{},
};

/// Backend-neutral compute-pipeline description. No extra state today (the
/// compute shader binary + pipeline layout come from the Program); present for
/// API symmetry and future options. Mirrors `RIComputePipelineDesc`.
pub const ComputePipelineDesc = struct {
    reserved: u32 = 0,
};

/// Maps a core `rhi.Format` to an `MTLPixelFormat`. Delegates to
/// `rhi.metal.to_mtl_pixel_format` which is the single source of truth.
pub fn to_mtl_pixel_format(format: rhi.Format) rhi.metal.types.PixelFormat {
    return rhi.metal.to_mtl_pixel_format(format);
}

/// Maps a core `rhi.Format` to an `MTLVertexFormat` for vertex attributes.
pub fn to_mtl_vertex_format(format: rhi.Format) rhi.metal.types.VertexFormat {
    return switch (format) {
        .r32_sfloat => .float,
        .rg32_sfloat => .float2,
        .rgb32_sfloat => .float3,
        .rgba32_sfloat => .float4,
        else => .invalid,
    };
}
