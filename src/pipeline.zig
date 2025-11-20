const rhi = @import("root.zig");
const std = @import("std");
const vulkan = @import("vulkan.zig");

pub const Pipeline = @This();
backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct { pipeline: rhi.vulkan.vk.Pipeline }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
},

// https://registry.khronos.org/vulkan/specs/latest/man/html/VkPrimitiveTopology.html
// https://learn.microsoft.com/en-us/windows/win32/api/d3dcommon/ne-d3dcommon-d3d_primitive_topology
// https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_primitive_topology_type
pub const Toplogy = enum(u8) { point_list, line_list, line_strip, triangle_list, triangle_strip, line_list_with_adjacency, line_strip_with_adjacency, triangle_list_with_adjacency, triangle_strip_with_adjacency, patch_list };

pub const PrimativeRestart = enum(u8) {
    disable,
    indices_u16,
    indices_u32,
};

pub const FillMode = enum(u8) {
    solid,
    wireframe,
};

// https://registry.khronos.org/vulkan/specs/latest/man/html/VkCullModeFlagBits.html
// https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_cull_mode
pub const CullMode = enum(u2) {
    none = 0,
    front = 0x1,
    back = 0x2,
    front_and_back = .front | .back,
};

pub const FillMode = enum(u1) {
    solid,
    wireframe,
};

pub const VertexAttributeDesc = struct { d3d: struct {
    semantic_name: []const u8,
    sementic_index: u32,
}, vk: struct { location: u32 }, offset: u32, format: rhi.Format, streamIndex: u16 };

// https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#primsrast-depthbias-computation
// https://learn.microsoft.com/en-us/windows/win32/direct3d11/d3d10-graphics-programming-guide-output-merger-stage-depth-bias
// R - minimum resolvable difference
// S - maximum slope
//
// bias = constant * R + slopeFactor * S
// if (clamp > 0)
//     bias = min(bias, clamp)
// else if (clamp < 0)
//     bias = max(bias, clamp)
//
// enabled if constant != 0 or slope != 0
pub const DepthBiasDesc = struct {
    constant: f32,
    clamp: f32,
    slope: f32,
};

pub const RasterizationDesc = struct {
    depth_bias: DepthBiasDesc,
    fill_mode: FillMode,
    cull_mode: CullMode,
    front_counter_clockwise: bool,
    depth_clamp: bool,
    line_smoothing: bool, // requires "features.lineSmoothing"
    conservative_raster: bool, // requires "tiers.conservativeRaster != 0"
    shadingRate: bool, // requires "tiers.shadingRate != 0", expects "CmdSetShadingRate" and optionally "AttachmentsDesc::shadingRate"
};

pub const VertexStreamStepRate = enum(u1) {
    per_vertex = 0,
    per_instance = 1,
};

pub const MultisampleDesc = struct {
    sample_mask: u32,
    sample_num: u32,
    alpha_to_coverage: bool,
    sample_locations: bool, // requires "tiers.sampleLocations != 0", expects "CmdSetSampleLocations"
};

pub const InputAssemblyDesc = struct {
    toplogy: Toplogy,
    tess_control_point_num: u8,
    primative_restart: PrimativeRestart,
};

pub const VertexStreamDesc = struct {
    binding_slot: u16,
    step_rate: VertexStreamStepRate,
};

pub const VertexInputDesc = struct {
    attributes: []const VertexAttributeDesc,
    streams: []const VertexStreamDesc,
};

pub const BlendFactor = enum(u4) {
    zero,
    one,
    src_color,
    one_minus_src_color,
    dst_color,
    one_minus_dst_color,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,
    constant_color,
    one_minus_constant_color,
    constant_alpha,
    one_minus_constant_alpha,
    src_alpha_saturate,
};

pub const BlendOp = enum(u3) {
    add,
    subtract,
    reverse_subtract,
    min,
    max,
};

pub const WriteMask = enum(u8) {
    none = 0,
    red = 1 << 0,
    green = 1 << 1,
    blue = 1 << 2,
    alpha = 1 << 3,
    rgb = .red | .green | .blue,
    rgba = .red | .green | .blue | .alpha,
};

pub const ColorAttachmentDesc = struct {
    blend_enable: bool,
    format: rhi.Format,
    src_color_blend_factor: BlendFactor,
    dst_color_blend_factor: BlendFactor,
    color_blend_op: BlendOp,
    src_alpha_blend_factor: BlendFactor,
    dst_alpha_blend_factor: BlendFactor,
    alpha_blend_op: BlendOp,
    write_mask: WriteMask,
};

pub const OutputMergerDesc = struct {
};

pub const GraphicsPipelineDesc = struct {
    layout: *rhi.PipelineLayout,
    vertex_input: ?VertexInputDesc,
    input_assembly: InputAssemblyDesc,
    rasterization: RasterizationDesc,
    multisample: ?MultisampleDesc,

};




