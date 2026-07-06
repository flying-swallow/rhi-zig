// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const std = @import("std");
const vulkan = @import("root.zig").vulkan;

pub const Pipeline = @This();
backend: union {
    vk: if (rhi.platform_has_api(.vk)) struct {
        pipeline: rhi.vulkan.vk.Pipeline,
        layout: rhi.vulkan.vk.PipelineLayout = .null_handle,
    } else void,
    dx12: if (rhi.platform_has_api(.dx12)) void else void,
    mtl: if (rhi.platform_has_api(.mtl)) struct {
        state: rhi.metal.mtl.RenderPipelineState,
        // Metal depth/stencil state is bound on the encoder, not baked into the
        // render pipeline, so it is carried here and set by `Cmd.bind_pipeline`.
        depth_stencil_state: ?rhi.metal.mtl.DepthStencilState = null,
    } else void,
},

pub fn deinit(self: *Pipeline, device: *rhi.Device) void {
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.destroyPipeline(device.backend.vk.device, self.backend.vk.pipeline, null);
        if (self.backend.vk.layout != .null_handle)
            dkb.destroyPipelineLayout(device.backend.vk.device, self.backend.vk.layout, null);
        return;
    }
    if (rhi.is_target_selected(.mtl)) {
        if (self.backend.mtl.depth_stencil_state) |dss| dss.release();
        self.backend.mtl.state.release();
        return;
    }
}

pub const VertexFormat = enum { float, float2, float3, float4 };
pub const VertexAttribute = struct { location: u32, format: VertexFormat, offset: u32 };
pub const VertexLayout = struct { stride: u32, attributes: []const VertexAttribute };

/// Metal reserves vertex buffer index 0 for the vertex-stage push constants
/// (slangc emits the `[[vk::push_constant]]` block at `[[buffer(0)]]`), so
/// vertex streams are bound starting at index 1.
pub const mtl_vertex_buffer_base: u32 = 1;

/// Minimal backend-agnostic graphics pipeline for the examples: a vertex +
/// fragment shader rendering to the swapchain's color format, triangle list,
/// dynamic viewport/scissor, with an optional vertex layout and vertex-stage
/// push constants.
pub fn init_graphics(device: *rhi.Device, options: struct {
    shader: *rhi.Shader,
    swapchain: *rhi.Swapchain,
    vertex_layout: ?VertexLayout = null,
    push_constant_size: u32 = 0,
    /// Enable depth testing/writing against a D32_SFLOAT depth attachment.
    depth_test: bool = false,
}) !Pipeline {
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const vk_shader = options.shader.backend.vk;
        var stages = [_]rhi.vulkan.vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex_bit = true }, .module = vk_shader.vertex_module, .p_name = "main" },
            .{ .stage = .{ .fragment_bit = true }, .module = vk_shader.pixel_module, .p_name = "main" },
        };
        var color_blend_attachment = [_]rhi.vulkan.vk.PipelineColorBlendAttachmentState{.{
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        }};
        var dynamic_states = [_]rhi.vulkan.vk.DynamicState{ .viewport, .scissor };
        var dynamic_state: rhi.vulkan.vk.PipelineDynamicStateCreateInfo = .{
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };
        var blend_state: rhi.vulkan.vk.PipelineColorBlendStateCreateInfo = .{
            .logic_op_enable = .false,
            .logic_op = .clear,
            .blend_constants = .{ 0, 0, 0, 0 },
            .attachment_count = color_blend_attachment.len,
            .p_attachments = &color_blend_attachment,
        };
        var viewport_state: rhi.vulkan.vk.PipelineViewportStateCreateInfo = .{ .viewport_count = 1, .scissor_count = 1 };
        var rasterization_state: rhi.vulkan.vk.PipelineRasterizationStateCreateInfo = .{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{ .front_bit = false, .back_bit = false },
            .front_face = .clockwise,
            .depth_bias_constant_factor = 0,
            .depth_bias_slope_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_enable = .false,
            .line_width = 1,
        };
        var input_assembly: rhi.vulkan.vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_list, .primitive_restart_enable = .false };
        var multisample_state: rhi.vulkan.vk.PipelineMultisampleStateCreateInfo = .{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };
        var vertex_bindings: [1]rhi.vulkan.vk.VertexInputBindingDescription = undefined;
        var vertex_attrs: [8]rhi.vulkan.vk.VertexInputAttributeDescription = undefined;
        var vertex_input_state: rhi.vulkan.vk.PipelineVertexInputStateCreateInfo = .{
            .vertex_binding_description_count = 0,
            .vertex_attribute_description_count = 0,
        };
        if (options.vertex_layout) |layout_desc| {
            vertex_bindings[0] = .{ .binding = 0, .stride = layout_desc.stride, .input_rate = .vertex };
            for (layout_desc.attributes, 0..) |attr, i| {
                vertex_attrs[i] = .{ .location = attr.location, .binding = 0, .format = vk_vertex_format(attr.format), .offset = attr.offset };
            }
            vertex_input_state = .{
                .vertex_binding_description_count = 1,
                .p_vertex_binding_descriptions = &vertex_bindings,
                .vertex_attribute_description_count = @intCast(layout_desc.attributes.len),
                .p_vertex_attribute_descriptions = &vertex_attrs,
            };
        }
        var push_ranges: [1]rhi.vulkan.vk.PushConstantRange = undefined;
        var layout_info: rhi.vulkan.vk.PipelineLayoutCreateInfo = .{ .set_layout_count = 0, .push_constant_range_count = 0 };
        if (options.push_constant_size > 0) {
            push_ranges[0] = .{ .stage_flags = .{ .vertex_bit = true }, .offset = 0, .size = options.push_constant_size };
            layout_info.push_constant_range_count = 1;
            layout_info.p_push_constant_ranges = &push_ranges;
        }
        const layout = try dkb.createPipelineLayout(device.backend.vk.device, &layout_info, null);
        errdefer dkb.destroyPipelineLayout(device.backend.vk.device, layout, null);

        var depth_stencil_state: rhi.vulkan.vk.PipelineDepthStencilStateCreateInfo = .{
            .depth_test_enable = if (options.depth_test) .true else .false,
            .depth_write_enable = if (options.depth_test) .true else .false,
            .depth_compare_op = .less,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
            .front = std.mem.zeroes(rhi.vulkan.vk.StencilOpState),
            .back = std.mem.zeroes(rhi.vulkan.vk.StencilOpState),
        };
        var create_info = [1]rhi.vulkan.vk.GraphicsPipelineCreateInfo{.{
            .stage_count = stages.len,
            .p_stages = &stages,
            .subpass = 0,
            .layout = layout,
            .base_pipeline_index = -1,
            .p_color_blend_state = &blend_state,
            .p_rasterization_state = &rasterization_state,
            .p_multisample_state = &multisample_state,
            .p_vertex_input_state = &vertex_input_state,
            .p_viewport_state = &viewport_state,
            .p_input_assembly_state = &input_assembly,
            .p_dynamic_state = &dynamic_state,
            .p_depth_stencil_state = &depth_stencil_state,
        }};
        var color_formats = [_]rhi.vulkan.vk.Format{options.swapchain.backend.vk.format};
        var rendering_info: rhi.vulkan.vk.PipelineRenderingCreateInfo = .{
            .color_attachment_count = color_formats.len,
            .p_color_attachment_formats = &color_formats,
            .view_mask = 0,
            .depth_attachment_format = if (options.depth_test) .d32_sfloat else .undefined,
            .stencil_attachment_format = .undefined,
        };
        rhi.vulkan.add_next(&create_info[0], &rendering_info);
        var pipeline: [1]rhi.vulkan.vk.Pipeline = .{.null_handle};
        _ = try dkb.createGraphicsPipelines(device.backend.vk.device, .null_handle, &create_info, null, &pipeline);
        return .{ .backend = .{ .vk = .{ .pipeline = pipeline[0], .layout = layout } } };
    }
    if (rhi.is_target_selected(.mtl)) {
        const dev = device.backend.mtl.device;
        const desc = rhi.metal.mtl.RenderPipelineDescriptor.init();
        defer desc.release();
        desc.setVertexFunction(options.shader.backend.mtl.vertex_function.?);
        desc.setFragmentFunction(options.shader.backend.mtl.fragment_function.?);
        desc.colorAttachments().object(0).setPixelFormat(options.swapchain.backend.mtl.pixel_format);
        if (options.depth_test) {
            desc.setDepthAttachmentPixelFormat(.depth32float);
        }
        if (options.vertex_layout) |layout_desc| {
            const vd = rhi.metal.mtl.VertexDescriptor.vertexDescriptor();
            const buf_index: rhi.metal.types.UInteger = mtl_vertex_buffer_base;
            for (layout_desc.attributes) |attr| {
                const a = vd.attributes().object(attr.location);
                a.setFormat(mtl_vertex_format(attr.format));
                a.setOffset(attr.offset);
                a.setBufferIndex(buf_index);
            }
            const l = vd.layouts().object(buf_index);
            l.setStride(layout_desc.stride);
            l.setStepFunction(.per_vertex);
            desc.setVertexDescriptor(vd);
        }
        var err: ?rhi.metal.ns.Error = null;
        const state = dev.newRenderPipelineState(desc, &err) orelse {
            if (err) |e| std.log.err("MTLRenderPipelineState: {s}", .{e.localizedDescription().utf8()});
            return error.PipelineCreationFailed;
        };
        var depth_stencil_state: ?rhi.metal.mtl.DepthStencilState = null;
        if (options.depth_test) {
            const dss_desc = rhi.metal.mtl.DepthStencilDescriptor.init();
            defer dss_desc.release();
            dss_desc.setDepthCompareFunction(.less);
            dss_desc.setDepthWriteEnabled(true);
            depth_stencil_state = dev.newDepthStencilState(dss_desc);
        }
        return .{ .backend = .{ .mtl = .{ .state = state, .depth_stencil_state = depth_stencil_state } } };
    }
    return error.UnsupportedBackend;
}

fn vk_vertex_format(format: VertexFormat) rhi.vulkan.vk.Format {
    return switch (format) {
        .float => .r32_sfloat,
        .float2 => .r32g32_sfloat,
        .float3 => .r32g32b32_sfloat,
        .float4 => .r32g32b32a32_sfloat,
    };
}

fn mtl_vertex_format(format: VertexFormat) rhi.metal.types.VertexFormat {
    return switch (format) {
        .float => .float,
        .float2 => .float2,
        .float3 => .float3,
        .float4 => .float4,
    };
}

// https://registry.khronos.org/vulkan/specs/latest/man/html/VkPrimitiveTopology.html
// https://learn.microsoft.com/en-us/windows/win32/api/d3dcommon/ne-d3dcommon-d3d_primitive_topology
// https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_primitive_topology_type
pub const Toplogy = enum(u8) { point_list, line_list, line_strip, triangle_list, triangle_strip, line_list_with_adjacency, line_strip_with_adjacency, triangle_list_with_adjacency, triangle_strip_with_adjacency, patch_list };

pub const PrimativeRestart = enum(u2) {
    disable,
    indices_u16,
    indices_u32,
};

// https://registry.khronos.org/vulkan/specs/latest/man/html/VkCullModeFlagBits.html
// https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_cull_mode
pub const CullMode = struct { front_bit: u1, back_bit: u1 };

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
    depth_bias: ?DepthBiasDesc,
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
            .max => .max,
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

pub const GraphicsPipelineDesc = struct { layout: *rhi.PipelineLayout, vertex_input: ?VertexInputDesc, input_assembly: InputAssemblyDesc, rasterization: RasterizationDesc, multisample: ?MultisampleDesc, output_merger: OutputMergerDesc, shaders: []ShaderDesc };

pub fn create_graphics_pipeline(alloc: std.mem.Allocator, device: *rhi.Device, desc: *const GraphicsPipelineDesc) !Pipeline {
    var pipline_shader_stages: std.ArrayList(rhi.vulkan.vk.PipelineShaderStageCreateInfo) = .empty;
    var color_blend_attachments: std.ArrayList(rhi.vulkan.vk.PipelineColorBlendAttachmentState) = .empty;
    var color_attachment_formats: std.ArrayList(rhi.vulkan.vk.Format) = .empty;
    var binding_descriptions: std.ArrayList(rhi.vulkan.vk.VertexInputBindingDescription) = .empty;
    var attribute_descriptions: std.ArrayList(rhi.vulkan.vk.VertexInputAttributeDescription) = .empty;
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    defer {
        for (pipline_shader_stages.items) |stage| {
            dkb.destroyShaderModule(device.backend.vk.device, stage.module, null);
        }
        pipline_shader_stages.deinit(alloc);
        color_blend_attachments.deinit(alloc);
        color_attachment_formats.deinit(alloc);
        binding_descriptions.deinit(alloc);
        attribute_descriptions.deinit(alloc);
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
        .polygon_mode = rhi.vulkan.vk_fill_mode(desc.rasterization.fill_mode),
        .cull_mode = .{
            .front_bit = desc.rasterization.cull_mode.front_bit,
            .back_bit = desc.rasterization.cull_mode.back_bit,
        },
        .depth_bias_constant_factor = if (desc.rasterization.depth_bias) |bias| bias.constantelse else 0,
        .depth_bias_slope_factor = if (desc.rasterization.depth_bias) |bias| bias.slope else 0,
        .depth_bias_clamp = if (desc.rasterization.depth_bias) |bias| bias.clamp else 0,
        .depth_bias_enable = if (desc.rasterization.depth_bias) |_| true else false,
        .line_width = 1.0,
    };

    for (desc.output_merger.color_attachments) |attachment| {
        color_attachment_formats.append(alloc, rhi.vulkan.to_vk_format(attachment.format));
        try color_blend_attachments.append(alloc, .{
            .blend_enable = if (attachment.blend_enable) .true else .false,
            .src_color_blend_factor = attachment.src_color_blend_factor.to_vk(),
            .dst_color_blend_factor = attachment.dst_color_blend_factor.to_vk(),
            .color_blend_op = attachment.color_blend_op.to_vk(),
            .src_alpha_blend_factor = attachment.src_alpha_blend_factor.to_vk(),
            .dst_alpha_blend_factor = attachment.dst_alpha_blend_factor.to_vk(),
            .alpha_blend_op = attachment.alpha_blend_op.to_vk(),
            .color_write_mask = .{ .r_bit = attachment.write_mask.r_bit, .g_bit = attachment.write_mask.g_bit, .b_bit = attachment.write_mask.b_bit, .a_bit = attachment.write_mask.a_bit },
        });
    }
    var pipeline_blend_state: rhi.vulkan.vk.PipelineColorBlendStateCreateInfo = .{ .logic_op_enable = .false, .logic_op = .clear, .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 }, .attachment_count = color_blend_attachments.items.len, .p_attachments = &color_blend_attachments.items };

    for (desc.shaders) |shader| {
        std.debug.assert(shader.vk != null);
        std.debug.assert(rhi.is_target_selected(.vk));
        var shader_module: rhi.vulkan.vk.ShaderModuleCreateInfo = .{ .code_size = shader.vk.?.code_size, .p_code = shader.vk.?.data };
        const module = dkb.createShaderModule(device.backend.vk.device, &shader_module, null) catch |err| {
            std.log.err("Failed to create fragment shader module: {}", .{err});
            return err;
        };
        pipline_shader_stages.append(alloc, .{ .stage = .{
            .vertex_bit = shader.stage.stage_vertex,
            .tessellation_control_bit = shader.stage.stage_tesselation_control,
            .tessellation_evaluation_bit = shader.stage.stage_tesselation_evaluation,
            .geometry_bit = shader.stage.stage_geometry,
            .fragment_bit = shader.stage.stage_pixel,
            .compute_bit = shader.stage.stage_compute,
        }, .module = module, .p_name = shader.entry_point });
    }

    var vertex_input_state = rhi.vulkan.vk.PipelineVertexInputStateCreateInfo{};

    if (desc.vertex_input) |vertex_input| {
        for (vertex_input.streams) |stream| {
            try binding_descriptions.append(alloc, .{
                .binding = stream.binding_slot,
                .input_rate = switch (stream.step_rate) {
                    .per_vertex => .vertex,
                    .per_instance => .instance,
                },
            });
        }
        for (vertex_input.attributes) |attribute| {
            try attribute_descriptions.append(alloc, .{
                .location = attribute.vk.location,
                .binding = attribute.streamIndex,
                .format = rhi.vulkan.to_vk_format(attribute.format),
                .offset = attribute.offset,
            });
        }
        vertex_input_state = rhi.vulkan.vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = binding_descriptions.items.len,
            .p_vertex_binding_descriptions = &binding_descriptions.items[0],
            .vertex_attribute_description_count = attribute_descriptions.items.len,
            .p_vertex_attribute_descriptions = &attribute_descriptions.items[0],
        };
    }

    var pipeline_input_assembly = rhi.vulkan.vk.PipelineInputAssemblyStateCreateInfo{
        .topology = rhi.vulkan.vk_topology(desc.input_assembly.toplogy),
        .primitive_restart_enable = if (desc.input_assembly.primative_restart) .true else .false,
    };

    var multisample_state = rhi.vulkan.vk.PipelineMultisampleStateCreateInfo{};
    if (desc.multisample) |multi| {
        multisample_state.rasterization_samples = .{};
        multisample_state.sample_shading_enable = .false;
        multisample_state.min_sample_shading = 1.0;
        multisample_state.p_sample_mask = null;
        multisample_state.alpha_to_coverage_enable = multi.alpha_to_coverage;
        multisample_state.alpha_to_one_enable = .false;
    }

    var pipeline_create_info = [1]rhi.vulkan.vk.GraphicsPipelineCreateInfo{.{
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
        .p_depth_stencil_state = null,
        .p_input_assembly_state = &pipeline_input_assembly,
        .p_dynamic_state = &dynamic_state,
    }};
    var pipeline_render_info: rhi.vulkan.vk.PipelineRenderingCreateInfo = .{
        .color_attachment_count = color_attachment_formats.items.len,
        .p_color_attachment_formats = &color_attachment_formats.items,
        //.view_mask = 0,
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };
    rhi.vulkan.add_next(&pipeline_create_info[0], &pipeline_render_info);

    var pipeline: [1]rhi.vulkan.vk.Pipeline = .{.null_handle};
    _ = try dkb.createGraphicsPipelines(device.backend.vk.device, .null_handle, 1, &pipeline_create_info, null, &pipeline);

    return .{ .backend = .{ .vk = .{ .pipeline = pipeline[0] } } };
}
