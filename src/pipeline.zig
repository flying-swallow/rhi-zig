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
    // WebGPU has no push constants, so a pipeline that declares them owns the
    // uniform buffer + bind group standing in for them. `Cmd.set_push_constants`
    // writes the buffer and binds the group; the shader declares the block as
    // `[[vk::binding(0,0)]] ConstantBuffer<T>` so slangc emits a valid
    // `@group(0) @binding(0) var<uniform>`.
    wgpu: if (rhi.platform_has_api(.wgpu)) struct {
        pipeline: rhi.webgpu.Handle = .none,
        push_constant_buffer: rhi.webgpu.Handle = .none,
        push_constant_group: rhi.webgpu.Handle = .none,
        push_constant_size: u32 = 0,
        /// `getBindGroupLayout(1)`, kept alive for the pipeline's lifetime so
        /// `Cmd.web_bind_descriptors` can build groups against it.
        texture_group_layout: rhi.webgpu.Handle = .none,
        /// Last group built, memoised: a renderer typically binds the same
        /// textures every frame.
        texture_group: rhi.webgpu.Handle = .none,
        texture_group_key: u64 = 0,
        texture_binding_count: u32 = 0,
        texture_bindings: [max_texture_bindings]TextureSlot = @splat(.{}),
    } else void,
    // GL has no pipeline object: everything `init_graphics` bakes is context
    // state applied at bind time, plus a linked program. The vertex layout is
    // kept here rather than baked into a VAO, because a VAO also fuses in the
    // buffers, which are not known yet (see `webgl.VaoCache`).
    webgl: if (rhi.platform_has_api(.webgl)) struct {
        /// Stable id used as part of the VAO cache key; GL reuses handles.
        cookie: u64 = 0,
        program: rhi.webgl.Handle = .none,
        topology: u32 = 0,
        index_type: u32 = 0,
        depth_test: bool = false,
        depth_write: bool = false,
        depth_compare: u32 = 0,
        cull_enabled: bool = false,
        cull_mode: u32 = 0,
        front_face: u32 = 0,
        blend_enabled: bool = false,
        blend_src_color: u32 = 0,
        blend_dst_color: u32 = 0,
        blend_color_op: u32 = 0,
        blend_src_alpha: u32 = 0,
        blend_dst_alpha: u32 = 0,
        blend_alpha_op: u32 = 0,
        write_mask: [4]u32 = .{ 1, 1, 1, 1 },
        vertex_stride: u32 = 0,
        vertex_attribute_count: u32 = 0,
        vertex_attributes: [8]rhi.webgl.VertexAttrib = undefined,
        push_constant_member_count: u32 = 0,
        push_constant_members: [16]rhi.webgl.PushConstantMember = undefined,
        /// The declared texture slots. GL needs no group/binding numbers -- the
        /// sampler uniforms were pointed at their units at link time -- but the
        /// names are kept so `Cmd.web_bind_descriptors` can recover a slot's
        /// unit.
        texture_binding_count: u32 = 0,
        texture_bindings: [max_texture_bindings]TextureSlot = @splat(.{}),
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
    if (rhi.is_target_selected(.webgl)) {
        const w = &self.backend.webgl;
        device.backend.webgl.vao_cache.invalidate(w.cookie);
        rhi.webgl.gl_delete_program(w.program);
        w.program = .none;
        return;
    }
    if (rhi.is_target_selected(.wgpu)) {
        const w = &self.backend.wgpu;
        rhi.webgpu.wgpu_release(w.texture_group);
        rhi.webgpu.wgpu_release(w.texture_group_layout);
        rhi.webgpu.wgpu_release(w.push_constant_group);
        rhi.webgpu.wgpu_release(w.push_constant_buffer);
        rhi.webgpu.wgpu_release(w.pipeline);
        w.texture_group = .none;
        w.texture_group_layout = .none;
        w.push_constant_group = .none;
        w.push_constant_buffer = .none;
        w.pipeline = .none;
        return;
    }
}

pub const VertexFormat = enum { float, float2, float3, float4 };
pub const VertexAttribute = struct { location: u32, format: VertexFormat, offset: u32 };
pub const VertexLayout = struct { stride: u32, attributes: []const VertexAttribute };

/// Blend state for `init_graphics`'s single color target.
///
/// `null` on the options struct means blending is off, which is what every
/// caller predating this got. The defaults here are straight (non-premultiplied)
/// alpha, because that is what a sprite or glyph atlas with an alpha channel
/// wants and it is the only reason to reach for this at all.
///
/// The full `ColorAttachmentDesc` below expresses the same thing per attachment
/// for the descriptor-based path; this is the one-target subset `init_graphics`
/// can actually deliver on all four backends.
pub const BlendState = struct {
    src_color: BlendFactor = .src_alpha,
    dst_color: BlendFactor = .one_minus_src_alpha,
    color_op: BlendOp = .add,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .one_minus_src_alpha,
    alpha_op: BlendOp = .add,
    write_mask: WriteMask = .{ .r = 1, .g = 1, .b = 1, .a = 1 },

    /// Straight (non-premultiplied) alpha: `src.rgb * src.a + dst.rgb * (1 - src.a)`.
    pub const straight_alpha: BlendState = .{};

    /// Premultiplied alpha: the source already carries `rgb * a`.
    pub const premultiplied_alpha: BlendState = .{ .src_color = .one };

    /// Additive, for glows and particles. Leaves the destination alpha alone.
    pub const additive: BlendState = .{
        .src_color = .src_alpha,
        .dst_color = .one,
        .src_alpha = .zero,
        .dst_alpha = .one,
    };
};

/// A texture the fragment stage reads, and the sampler it is sampled with.
///
/// Both are named: `Cmd.web_bind_descriptors` addresses them by name, the way
/// `rpi.Program.bindDescriptors` addresses a program's layout. The sampler pair
/// is null for a shader that only `texelFetch`es -- such a shader declares no
/// `SamplerState`, so slangc emits no sampler binding for it.
pub const TextureBinding = struct {
    /// The name of the texture in the shader source. GL also links by it: the
    /// vendored SPIRV-Cross tool names each combined `sampler2D` after the
    /// image it came from, so this is exactly the identifier the `.slang` file
    /// used. WGSL and SPIR-V address the resource itself by group/binding
    /// instead, and use this only for the name lookup.
    name: []const u8,
    /// `@binding(n)` of the texture within group 1.
    binding: u32,
    /// The `SamplerState`'s name in the shader source, when it declares one.
    /// Required whenever `sampler_binding` is set, because that is what a
    /// `sampler` descriptor is matched on.
    sampler_name: ?[]const u8 = null,
    /// ...and its `@binding(n)`, when the shader declares one.
    sampler_binding: ?u32 = null,
};

pub const max_texture_bindings = 8;

/// One slot's declaration as resolved at pipeline creation, kept so
/// `Cmd.web_bind_descriptors` can match a named descriptor to it without the
/// caller repeating the declaration. The slot's index is the WebGL2 texture
/// unit.
pub const TextureSlot = struct {
    /// Wyhash of the declared names, hashed the same way
    /// `rhi.DescriptorBindingID` hashes so the two sides agree.
    name_hash: u64 = 0,
    sampler_name_hash: ?u64 = null,
    /// WebGPU `@binding(n)` within group 1. Ignored on WebGL2, which binds by
    /// unit.
    binding: u32 = 0,
    sampler_binding: ?u32 = null,
};

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
    /// Alpha blending for the single color target. `null` disables it.
    blend: ?BlendState = null,
    /// Textures the fragment stage reads. `Cmd.web_bind_descriptors` addresses
    /// an entry by the names declared here; an entry's index is the WebGL2
    /// texture unit.
    ///
    /// On WebGPU these live in `@group(1)`: group 0 is taken by the uniform
    /// buffer standing in for push constants (see the `wgpu` arm of
    /// `Pipeline.backend`), so a shader declaring textures at group 0 would
    /// collide with it.
    texture_bindings: []const TextureBinding = &.{},
}) !Pipeline {
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const vk_shader = options.shader.backend.vk;
        var stages = [_]rhi.vulkan.vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex = true }, .module = vk_shader.vertex_module, .p_name = "main" },
            .{ .stage = .{ .fragment = true }, .module = vk_shader.pixel_module, .p_name = "main" },
        };
        const blend = options.blend orelse BlendState{
            // Blending off: pass the source through untouched.
            .src_color = .one,
            .dst_color = .zero,
            .src_alpha = .one,
            .dst_alpha = .zero,
        };
        var color_blend_attachment = [_]rhi.vulkan.vk.PipelineColorBlendAttachmentState{.{
            .blend_enable = if (options.blend != null) .true else .false,
            .src_color_blend_factor = blend.src_color.to_vk(),
            .dst_color_blend_factor = blend.dst_color.to_vk(),
            .color_blend_op = blend.color_op.to_vk(),
            .src_alpha_blend_factor = blend.src_alpha.to_vk(),
            .dst_alpha_blend_factor = blend.dst_alpha.to_vk(),
            .alpha_blend_op = blend.alpha_op.to_vk(),
            .color_write_mask = .{
                .r = blend.write_mask.r == 1,
                .g = blend.write_mask.g == 1,
                .b = blend.write_mask.b == 1,
                .a = blend.write_mask.a == 1,
            },
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
            .cull_mode = .{ .front = false, .back = false },
            .front_face = .clockwise,
            .depth_bias_constant_factor = 0,
            .depth_bias_slope_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_enable = .false,
            .line_width = 1,
        };
        var input_assembly: rhi.vulkan.vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_list, .primitive_restart_enable = .false };
        var multisample_state: rhi.vulkan.vk.PipelineMultisampleStateCreateInfo = .{
            .rasterization_samples = .{ .@"1" = true },
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
            push_ranges[0] = .{ .stage_flags = .{ .vertex = true }, .offset = 0, .size = options.push_constant_size };
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
        // `deps/metal`'s `RenderPipelineColorAttachmentDescriptor` binds only
        // `setPixelFormat:` -- there is no `setBlendingEnabled:` or blend-factor
        // setter, and `types.zig` has no `MTLBlendFactor`/`MTLBlendOperation`.
        // Report that rather than dropping the caller's blend state on the
        // floor, which is how the rest of this backend treats what it cannot
        // express (see `to_gl_format`'s `error.UnsupportedFormat`).
        if (options.blend != null) return error.BlendUnsupportedOnMetal;
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
    if (rhi.is_target_selected(.webgl)) {
        const webgl = rhi.webgl;
        const sh = &options.shader.backend.webgl;

        var err_buf: [1024]u8 = undefined;
        @memset(&err_buf, 0);
        const program = webgl.gl_create_program(
            sh.vertex_source.ptr,
            @intCast(sh.vertex_source.len),
            sh.fragment_source.ptr,
            @intCast(sh.fragment_source.len),
            &err_buf,
            err_buf.len,
        );
        if (program.isNone()) {
            const msg = std.mem.sliceTo(&err_buf, 0);
            webgl.log_err("program link failed: {s}", .{msg});
            return error.ShaderCompilationFailed;
        }
        errdefer webgl.gl_delete_program(program);

        var result: Pipeline = .{ .backend = .{ .webgl = .{
            .cookie = rhi.next_cookie(),
            .program = program,
            .topology = webgl.gl.TRIANGLES,
            .index_type = webgl.gl.UNSIGNED_SHORT,
            .depth_test = options.depth_test,
            .depth_write = options.depth_test,
            .depth_compare = webgl.gl.LESS,
            // Matches the Vulkan arm, which disables culling and winds
            // clockwise. SPIRV-Cross flips Y in the shader, which reverses the
            // apparent winding, so `.ccw` here corresponds to the other
            // backends' `.cw`.
            .cull_enabled = false,
            .cull_mode = webgl.gl.BACK,
            .front_face = webgl.gl.CCW,
        } } };

        if (options.blend) |blend| {
            const w = &result.backend.webgl;
            w.blend_enabled = true;
            w.blend_src_color = webgl.enums.to_gl_blend_factor(blend.src_color);
            w.blend_dst_color = webgl.enums.to_gl_blend_factor(blend.dst_color);
            w.blend_color_op = webgl.enums.to_gl_blend_op(blend.color_op);
            w.blend_src_alpha = webgl.enums.to_gl_blend_factor(blend.src_alpha);
            w.blend_dst_alpha = webgl.enums.to_gl_blend_factor(blend.dst_alpha);
            w.blend_alpha_op = webgl.enums.to_gl_blend_op(blend.alpha_op);
            w.write_mask = .{
                blend.write_mask.r,
                blend.write_mask.g,
                blend.write_mask.b,
                blend.write_mask.a,
            };
        }

        if (options.vertex_layout) |layout_desc| {
            std.debug.assert(layout_desc.attributes.len <= 8);
            result.backend.webgl.vertex_stride = layout_desc.stride;
            result.backend.webgl.vertex_attribute_count = @intCast(layout_desc.attributes.len);
            for (layout_desc.attributes, 0..) |attr, i| {
                result.backend.webgl.vertex_attributes[i] = .{
                    .location = attr.location,
                    .components = webgl.enums.vertex_components(attr.format),
                    .offset = attr.offset,
                };
            }
        }

        if (options.push_constant_size > 0) {
            try reflect_push_constants(&result, options.push_constant_size);
        }

        // Point each `sampler2D` uniform at its texture unit once, here, rather
        // than on every bind: the assignment is program state and survives.
        std.debug.assert(options.texture_bindings.len <= max_texture_bindings);
        result.backend.webgl.texture_binding_count = @intCast(options.texture_bindings.len);
        for (options.texture_bindings, 0..) |tb, unit| {
            result.backend.webgl.texture_bindings[unit] = try resolve_texture_slot(tb);
            if (webgl.gl_set_sampler_unit(program, tb.name.ptr, @intCast(tb.name.len), @intCast(unit)) != 0) {
                webgl.log_err("pipeline declares texture '{s}' but the program exposes no such sampler uniform", .{tb.name});
                return error.TextureBindingNotFound;
            }
        }
        return result;
    }
    if (rhi.is_target_selected(.wgpu)) {
        const wgpu = rhi.webgpu;
        const sh = &options.shader.backend.wgpu;

        // Vertex attributes cross the wasm boundary as a flat array of
        // (location, format, offset) triples rather than a struct, so there is
        // no field layout for the JS side to drift out of sync with.
        var attrs: [8 * 3]u32 = undefined;
        var attr_count: u32 = 0;
        var stride: u32 = 0;
        if (options.vertex_layout) |layout_desc| {
            std.debug.assert(layout_desc.attributes.len <= 8);
            stride = layout_desc.stride;
            for (layout_desc.attributes, 0..) |attr, i| {
                attrs[i * 3 + 0] = attr.location;
                attrs[i * 3 + 1] = @intFromEnum(wgpu.to_wgpu_vertex_format(attr.format));
                attrs[i * 3 + 2] = attr.offset;
            }
            attr_count = @intCast(layout_desc.attributes.len * 3);
        }

        // `depth_test` is documented as targeting D32_SFLOAT, matching the other
        // backends; `.undefined_format` means the pass has no depth attachment.
        const depth_format: wgpu.TextureFormat = if (options.depth_test) .depth32float else .undefined_format;

        // Blending off still needs factors to pass across the boundary; the
        // `blend_enable` flag is what decides whether JS attaches them.
        const blend = options.blend orelse BlendState{};
        const wgpu_write_mask: u32 =
            (@as(u32, blend.write_mask.r) << 0) |
            (@as(u32, blend.write_mask.g) << 1) |
            (@as(u32, blend.write_mask.b) << 2) |
            (@as(u32, blend.write_mask.a) << 3);

        const pipeline = wgpu.wgpu_device_create_render_pipeline(
            device.backend.wgpu.device,
            sh.vertex_module,
            sh.vertex_entry.ptr,
            @intCast(sh.vertex_entry.len),
            sh.fragment_module,
            sh.fragment_entry.ptr,
            @intCast(sh.fragment_entry.len),
            options.swapchain.backend.wgpu.format,
            depth_format,
            .triangle_list,
            .none,
            // The Vulkan arm rasterizes with `front_face = .clockwise` and no
            // culling; match it so the same mesh winds the same way.
            .cw,
            @intFromBool(options.depth_test),
            .less,
            stride,
            &attrs,
            attr_count,
            @intFromBool(options.blend != null),
            wgpu.to_wgpu_blend_factor(blend.src_color),
            wgpu.to_wgpu_blend_factor(blend.dst_color),
            wgpu.to_wgpu_blend_op(blend.color_op),
            wgpu.to_wgpu_blend_factor(blend.src_alpha),
            wgpu.to_wgpu_blend_factor(blend.dst_alpha),
            wgpu.to_wgpu_blend_op(blend.alpha_op),
            wgpu_write_mask,
        );
        if (pipeline.isNone()) return error.WebGPUPipelineCreationFailed;

        var result: Pipeline = .{ .backend = .{ .wgpu = .{ .pipeline = pipeline } } };
        if (options.push_constant_size > 0) {
            // WebGPU has no push constants, so the block becomes a uniform buffer
            // at `@group(0) @binding(0)` that this pipeline owns and
            // `Cmd.set_push_constants` writes. The shader must declare it as
            // `[[vk::binding(0,0)]] ConstantBuffer<T>`; slangc's
            // `[[vk::push_constant]]` emits a `var<uniform>` with no
            // group/binding attribute, which WebGPU rejects outright.
            //
            // Uniform buffer bindings must be a multiple of 16 bytes.
            const size = std.mem.alignForward(u32, options.push_constant_size, 16);
            const buf = wgpu.wgpu_device_create_buffer(
                device.backend.wgpu.device,
                size,
                wgpu.BufferUsage.uniform | wgpu.BufferUsage.copy_dst,
            );
            if (buf.isNone()) {
                wgpu.wgpu_release(pipeline);
                return error.WebGPUBufferCreationFailed;
            }
            // The pipeline was created with `layout: "auto"`, so its bind group
            // layout is derived from the shader rather than built by hand.
            const layout = wgpu.wgpu_render_pipeline_get_bind_group_layout(pipeline, 0);
            const group = wgpu.wgpu_device_create_bind_group_uniform(device.backend.wgpu.device, layout, buf, 0, size);
            wgpu.wgpu_release(layout);
            if (group.isNone()) {
                wgpu.wgpu_release(buf);
                wgpu.wgpu_release(pipeline);
                return error.WebGPUBindGroupCreationFailed;
            }
            result.backend.wgpu.push_constant_buffer = buf;
            result.backend.wgpu.push_constant_group = group;
            result.backend.wgpu.push_constant_size = size;
        }

        if (options.texture_bindings.len > 0) {
            std.debug.assert(options.texture_bindings.len <= max_texture_bindings);
            // `layout: "auto"` again -- group 1's layout is derived from the
            // shader, so it cannot be built by hand and must be read back off
            // the pipeline.
            const tex_layout = wgpu.wgpu_render_pipeline_get_bind_group_layout(pipeline, 1);
            if (tex_layout.isNone()) {
                wgpu.wgpu_release(pipeline);
                return error.WebGPUBindGroupLayoutMissing;
            }
            result.backend.wgpu.texture_group_layout = tex_layout;
            result.backend.wgpu.texture_binding_count = @intCast(options.texture_bindings.len);
            for (options.texture_bindings, 0..) |tb, i| {
                result.backend.wgpu.texture_bindings[i] = try resolve_texture_slot(tb);
            }
        }
        return result;
    }
    return error.UnsupportedBackend;
}

/// Hash a slot's declared names once, at pipeline creation, so binding a
/// descriptor to it is a hash compare rather than a string compare.
///
/// A sampler binding number with no name would be unaddressable: nothing could
/// name the sampler descriptor that fills it.
fn resolve_texture_slot(tb: TextureBinding) !TextureSlot {
    if (tb.sampler_binding != null and tb.sampler_name == null) return error.SamplerNameRequired;
    return .{
        .name_hash = rhi.DescriptorBindingID.create(tb.name).hash,
        .sampler_name_hash = if (tb.sampler_name) |n| rhi.DescriptorBindingID.create(n).hash else null,
        .binding = tb.binding,
        .sampler_binding = tb.sampler_binding,
    };
}

/// Resolves the push-constant block into individual `glUniform*` targets.
///
/// GL has no push constants. SPIRV-Cross emits the block as a plain struct
/// uniform (`uniform PushConsts_std430 pc;`), whose members are set one at a
/// time, so they are reflected once here at link time.
///
/// Offsets are derived from declaration order and natural packing, because a
/// plain struct uniform — unlike a uniform *block* — exposes no queryable
/// member offsets. The total is checked against the declared
/// `push_constant_size`, which is what catches a layout this assumption cannot
/// model rather than letting it silently feed wrong values to the shader.
fn reflect_push_constants(pipeline: *Pipeline, push_constant_size: u32) !void {
    const webgl = rhi.webgl;
    const w = &pipeline.backend.webgl;
    const count = webgl.gl_active_uniform_count(w.program);

    var offset: u32 = 0;
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var name_buf: [128]u8 = undefined;
        var gl_type: u32 = 0;
        const name_len = webgl.gl_active_uniform_info(w.program, i, &name_buf, name_buf.len, &gl_type);
        if (name_len == 0) continue;
        const name = name_buf[0..name_len];
        // Only members of the push-constant struct; a bare uniform has no dot.
        if (std.mem.indexOfScalar(u8, name, '.') == null) continue;

        // Unsigned members matter: a shader that indexes a texture atlas
        // naturally declares its dimensions as `uint`, and SPIRV-Cross emits
        // the block members with the source types.
        const size: u32 = switch (gl_type) {
            webgl.gl.FLOAT, webgl.gl.INT, webgl.gl.UNSIGNED_INT => 4,
            webgl.gl.FLOAT_VEC2, webgl.gl.INT_VEC2, webgl.gl.UNSIGNED_INT_VEC2 => 8,
            webgl.gl.FLOAT_VEC3, webgl.gl.INT_VEC3, webgl.gl.UNSIGNED_INT_VEC3 => 12,
            webgl.gl.FLOAT_VEC4, webgl.gl.INT_VEC4, webgl.gl.UNSIGNED_INT_VEC4 => 16,
            webgl.gl.FLOAT_MAT4 => 64,
            else => return error.UnsupportedPushConstantMember,
        };
        // Natural alignment: 4 for scalars, the component size for vectors, as
        // an `extern struct` of f32 arrays lays out on the CPU side.
        const alignment: u32 = if (size >= 16) 16 else if (size >= 8) 8 else 4;
        offset = std.mem.alignForward(u32, offset, alignment);

        if (n >= w.push_constant_members.len) return error.TooManyPushConstantMembers;
        w.push_constant_members[n] = .{
            .location = webgl.gl_uniform_location(w.program, name.ptr, name_len),
            .gl_type = gl_type,
            .offset = offset,
            .size = size,
        };
        offset += size;
        n += 1;
    }

    if (n == 0) {
        // The pipeline declares push constants but the program exposes none:
        // the shader was compiled without the block, or the driver optimised it
        // away. Either way `set_push_constants` would silently do nothing.
        webgl.log_err("pipeline declares {d} bytes of push constants but the program exposes no matching uniforms", .{push_constant_size});
        return error.PushConstantsNotFound;
    }
    if (offset != push_constant_size) {
        webgl.log_err("reflected push constants total {d} bytes, but the pipeline declares {d}", .{ offset, push_constant_size });
        return error.PushConstantLayoutMismatch;
    }
    w.push_constant_member_count = n;
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
pub const CullMode = struct { front: u1, back: u1 };

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
            .one_minus_dst_alpha => .one_minus_dst_alpha,
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
    r: u1 = 0,
    g: u1 = 0,
    b: u1 = 0,
    a: u1 = 0,
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
            .front = desc.rasterization.cull_mode.front,
            .back = desc.rasterization.cull_mode.back,
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
            .color_write_mask = .{ .r = attachment.write_mask.r, .g = attachment.write_mask.g, .b = attachment.write_mask.b, .a = attachment.write_mask.a },
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
            .vertex = shader.stage.stage_vertex,
            .tessellation_control = shader.stage.stage_tesselation_control,
            .tessellation_evaluation = shader.stage.stage_tesselation_evaluation,
            .geometry = shader.stage.stage_geometry,
            .fragment = shader.stage.stage_pixel,
            .compute = shader.stage.stage_compute,
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
