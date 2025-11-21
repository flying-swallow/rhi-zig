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
pub const Toplogy = enum(u8) { 
    point_list, 
    line_list, 
    line_strip, 
    triangle_list, 
    triangle_strip, 
    line_list_with_adjacency, 
    line_strip_with_adjacency, 
    triangle_list_with_adjacency, 
    triangle_strip_with_adjacency, 
    patch_list 
};

pub const PrimativeRestart = enum(u2) {
    disable,
    indices_u16,
    indices_u32,
};

// https://registry.khronos.org/vulkan/specs/latest/man/html/VkCullModeFlagBits.html
// https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_cull_mode
pub const CullMode = struct {
    front_bit: u1,
    back_bit: u1
};

pub const FillMode = enum(u1) {
    solid,
    wireframe,

    pub fn to_vk(self: FillMode) rhi.vulkan.vk.PolygonMode {
        return switch (self) {
            .solid => .fill,
            .wireframe => .line,
        };
    }
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
    viewport_num: u16,
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

// https://registry.khronos.org/vulkan/specs/latest/man/html/VkLogicOp.html
// https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_logic_op
// S - source color 0
// D - destination color
pub const LogicOp = enum(u8) {
    none,
    clear, // 0
    @"and", // s & d
    and_reverse, // s & ~d
    copy, // s
    and_inverted, // ~s & d
    xor, // s ^ d
    @"or", // s | d
    nor, // ~(s | d)
    equivalent, // ~(s ^ d)
    invert, // ~d
    or_reverse, // s | ~d
    copy_inverted, // ~s
    or_inverted, // ~s | d
    nand, // ~(s & d)
    set, // 1
};

pub const MultiView = enum(u1) {
    // Destination "viewport" and/or "layer" must be set in shaders explicitly, "viewMask" for rendering can be < than the one used for pipeline creation (D3D12 style)
    flexible, // requires "features.flexibleMultiview"

    // View instances go to statically assigned corresponding attachment layers, "viewMask" for rendering must match the one used for pipeline creation (VK style)
    layer_based, // requires "features.layerBasedMultiview"

    // View instances go to statically assigned corresponding viewports, "viewMask" for pipeline creation is unused (D3D11 style)
    viewport_based, // requires "features.viewportBasedMultiview"
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

    pub fn to_vk(self: BlendFactor) rhi.vulkan.vk.BlendFactor {
        return switch (self) {
            .zero => .zero,
            .one => .one,
            .src_color => .src_color,
            .one_minus_src_color => .one_minus_src_color,
            .dst_color => .dst_color,
            .one_minus_dst_color => .one_minus_dst_color,
            .src_alpha => .src_alpha,
            .one_minus_src_alpha => .one_minus_src_alpha,
            .dst_alpha => .dst_alpha,
            .one_minus_dst_alpha => .one_minus_src_alpha,
            .constant_color => .constant_color,
            .one_minus_constant_color => .one_minus_constant_color,
            .constant_alpha => .constant_alpha,
            .one_minus_constant_alpha => .one_minus_constant_alpha,
            .src_alpha_saturate => .src_alpha_saturate,
        };
    }
};

pub const BlendOp = enum(u3) {
    add,
    subtract,
    reverse_subtract,
    min,
    max,

    pub fn to_vk(self: BlendOp) rhi.vulkan.vk.BlendOp {
        return switch (self) {
            .add => .add,
            .subtract => .subtract,
            .reverse_subtract => .reverse_subtract,
            .min => .min,
            .max => .max
        };
    }
};

pub const WriteMask = struct {
    r_bit: u1 = 0,
    g_bit: u1 = 0,
    b_bit: u1 = 0,
    a_bit: u1 = 0,
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

// https://registry.khronos.org/vulkan/specs/latest/man/html/VkPipelineDepthStencilStateCreateInfo.html
pub const DepthAttachmentDesc = struct {
    compare_op: BlendOp,
    write: bool,
    bound_test: bool, // requires "features.depthBoundsTest", expects "CmdSetDepthBounds"
};

pub const StencilAttachmentDesc = struct {
    front_compare_op: BlendOp,
    front_fail_op: BlendOp,
    front_pass_op: BlendOp,
    front_depth_fail_op: BlendOp,
    front_write_mask: WriteMask,
    front_compare_mask: WriteMask,

    back_compare_op: BlendOp,
    back_fail_op: BlendOp,
    back_pass_op: BlendOp,
    back_depth_fail_op: BlendOp,
    back_write_mask: WriteMask,
    back_compare_mask: WriteMask,
};

pub const OutputMergerDesc = struct {
    color_attachments: []const ColorAttachmentDesc,
    depth_attachment: ?DepthAttachmentDesc,
    stencil_attachment: ?StencilAttachmentDesc,
    depth_stencil_format: rhi.Format,
    logic_op: LogicOp, // requires "features.logicOp"
    view_mask: u8, // requires "tiers.dualSourceBlend != 0"
    multi_view: MultiView,
};

pub const ShaderStage = struct {
    none: u1 = 0,
    stage_vertex: u1 = 0,
    stage_tesselation_control: u1 = 0,
    stage_tesselation_evaluation: u1 = 0,
    stage_geometry: u1 = 0,
    stage_pixel: u1 = 0,
    stage_compute: u1 = 0,
};

pub const ShaderDesc = struct {
    stage: ShaderStage,
    entry_point: []const u8,
    vk: ?struct {
        data: []const u32,
        code_size: usize,
    },
};

pub const GraphicsPipelineDesc = struct { 
    layout: *rhi.PipelineLayout, 
    vertex_input: ?VertexInputDesc, 
    input_assembly: InputAssemblyDesc, 
    rasterization: RasterizationDesc, 
    multisample: ?MultisampleDesc, 
    output_merger: OutputMergerDesc, 
    shaders: []ShaderDesc 
};

pub fn create_graphics_pipeline(alloc: std.mem.Allocator, renderer: *rhi.Renderer, device: *rhi.Device, desc: *const GraphicsPipelineDesc) !Pipeline {
    var pipline_shader_stages: std.ArrayList(rhi.vulkan.vk.PipelineShaderStageCreateInfo) = .empty;
    var color_blend_attachments: std.ArrayList(rhi.vulkan.vk.PipelineColorBlendAttachmentState) = .empty;
    var color_attachments: std.ArrayList(rhi.vulkan.vk.Format) = .empty;
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    defer {
        for (pipline_shader_stages.items) |stage| {
            dkb.destroyShaderModule(device.backend.vk.device, stage.module, null);
        }
        pipline_shader_stages.deinit(alloc);
        color_blend_attachments.deinit(alloc);
        color_attachments.deinit(alloc);
    }
    var dynamic_states = [_]rhi.vulkan.vk.DynamicState{
        .viewport,
        .scissor,
    };
    var dynamic_state: rhi.vulkan.vk.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };
    var viewport_state: rhi.vulkan.vk.PipelineViewportStateCreateInfo = .{
        .viewport_count = desc.rasterization.viewport_num,
        .scissor_count = desc.rasterization.viewport_num,
    };

    var rasterization_state: rhi.vulkan.vk.PipelineRasterizationStateCreateInfo = .{
        .depth_clamp_enable = desc.rasterization.depth_clamp,
        .rasterizer_discard_enable = false, // not supported d3d12
        .polygon_mode = desc.rasterization.fill_mode.to_vk(),
        .cull_mode = .{
            .front_bit = desc.rasterization.cull_mode.front_bit,
            .back_bit = desc.rasterization.cull_mode.back_bit, 
        },
        //.front_face = desc.rasterization.front_counter_clockwise ? .counter_clockwise : .clockwise,
        .depth_bias_constant_factor = 0.0,
        .depth_bias_slope_factor = 0.0,
        .depth_bias_clamp = 0.0,
        .depth_bias_enable = .false,
        .line_width = 1.0,
    };


    for (desc.output_merger.color_attachments) |attachment| {
        color_attachments.append(alloc, rhi.vulkan.vk_format(attachment.format));
        try color_blend_attachments.append(alloc, .{
            .blend_enable = if (attachment.blend_enable) .true else .false,
            .src_color_blend_factor = attachment.src_color_blend_factor.to_vk(),
            .dst_color_blend_factor = attachment.dst_color_blend_factor.to_vk(),
            .color_blend_op = attachment.color_blend_op.to_vk(),
            .src_alpha_blend_factor = attachment.src_alpha_blend_factor.to_vk(),
            .dst_alpha_blend_factor = attachment.dst_alpha_blend_factor.to_vk(),
            .alpha_blend_op = attachment.alpha_blend_op.to_vk(),
            .color_write_mask = .{
                .r_bit = attachment.write_mask.r_bit,
                .g_bit = attachment.write_mask.g_bit,
                .b_bit = attachment.write_mask.b_bit,
                .a_bit = attachment.write_mask.a_bit 
            },
        });
    }
    var pipeline_blend_state: rhi.vulkan.vk.PipelineColorBlendStateCreateInfo = .{
        .logic_op_enable = .false,
        .logic_op = .clear,
        .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        .attachment_count = color_blend_attachments.items.len,
        .p_attachments = &color_blend_attachments.items
    };


    for (desc.shaders) |shader| {
        std.debug.assert(shader.vk != null);
        std.debug.assert(rhi.is_target_selected(.vk, renderer));
        var shader_module: rhi.vulkan.vk.ShaderModuleCreateInfo = .{ .code_size = shader.vk.?.code_size, .p_code = shader.vk.?.data };
        const module = dkb.createShaderModule(device.backend.vk.device, &shader_module, null) catch |err| {
            std.log.err("Failed to create fragment shader module: {}", .{err});
            return err;
        };
        pipline_shader_stages.append(alloc, .{ 
            .stage = .{
                .vertex_bit = shader.stage.stage_vertex,
                .tessellation_control_bit = shader.stage.stage_tesselation_control,
                .tessellation_evaluation_bit = shader.stage.stage_tesselation_evaluation,
                .geometry_bit = shader.stage.stage_geometry,
                .fragment_bit = shader.stage.stage_pixel,
                .compute_bit = shader.stage.stage_compute,
            }, 
            .module = module, 
            .p_name = shader.entry_point 
        });
    }
    
    var vertex_input_state = rhi.vulkan.vk.PipelineVertexInputStateCreateInfo {
        .vertex_binding_description_count = 0,
        .vertex_attribute_description_count = 0,
    };

    
    var pipeline_input_assembly = rhi.vulkan.vk.PipelineInputAssemblyStateCreateInfo {
        .topology = rhi.vulkan.vk_topology(desc.input_assembly.toplogy),
        .primitive_restart_enable = .false,
    };
    
    var multisample_state = rhi.vulkan.vk.PipelineMultisampleStateCreateInfo {
        .rasterization_samples = .{
            .@"1_bit" = true
        },
        .sample_shading_enable = .false,
        .min_sample_shading = 1.0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    var pipeline_create_info =  [1]rhi.vulkan.vk.GraphicsPipelineCreateInfo {
        .{
            .stage_count = pipline_shader_stages.items.len,
            .p_stages = &pipline_shader_stages.items,
            .subpass = 0,
            .layout = desc.layout.backend.vk.layout,
            .base_pipeline_index = -1,
            .p_color_blend_state = &pipeline_blend_state,
            .p_rasterization_state = &rasterization_state,
            .p_multisample_state = &multisample_state,
            .p_vertex_input_state = &vertex_input_state,
            .p_viewport_state = &viewport_state,
            .p_input_assembly_state = &pipeline_input_assembly,
            .p_dynamic_state = &dynamic_state,
        }
    };
    var pipeline_render_info: rhi.vulkan.vk.PipelineRenderingCreateInfo = .{
        .color_attachment_count = color_blend_attachments.items.len,
        .p_color_attachment_formats = &color_blend_attachments.items,
        .view_mask = 0,
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };
    rhi.vulkan.add_next(&pipeline_create_info[0], &pipeline_render_info);
    
    var pipeline: [1]rhi.vulkan.vk.Pipeline = .{.null_handle};
    _ = try dkb.createGraphicsPipelines(device.backend.vk.device, .null_handle, 1, &pipeline_create_info, null, &pipeline);

    return .{ .backend = .{ .vk = .{ .pipeline = pipeline[0] } } };
}
