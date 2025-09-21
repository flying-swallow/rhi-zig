const rhi = @import("root.zig");
const std = @import("std");
const gpu_preset = @import("gpu_preset.zig");

pub const Vendor = enum(u8) { unknown, nvidia, amd, intel };

pub const PresetLevel = enum(u8) {
    none,
    office, // this means unsupported
    very_low, // mostly for mobile gpu
    low,
    medium,
    high,
    ultra,
};

pub const AdapterType = enum(u8) {
    other,
    cpu,
    virtual,
    integrated,
    discrete,
};

pub const PhysicalAdapter = @This();
backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct {
        physical_device: rhi.vulkan.vk.PhysicalDevice = .null_handle,
        api_version: u32 = 0,
        is_swap_chain_supported: bool = false,
        is_buffer_device_address_supported: bool = false,
        is_amd_device_coherent_memory_supported: bool = false,
        is_present_id_supported: bool = false,
        is_maintenance5_supported: bool = false,
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
},
name: [256]u8 = std.mem.zeroes([256]u8),
luid: u64 = 0,
video_memory_size: u64 = 0,
system_memory_size: u64 = 0,
device_id: u32 = 0,
vendor: Vendor = .unknown,
preset_level: PresetLevel = .none,
adapter_type: AdapterType = .other,

// Viewports
viewport_max_num: u32 = 0,
viewport_bounds_range: [2]f32 = [_]f32{ 0, 0 },

// Attachments
attachment_max_dim: u32 = 0,
attachment_layer_max_num: u32 = 0,
color_attachment_max_num: u32 = 0,

// Multi-sampling
color_sample_max_num: u32 = 0,
depth_sample_max_num: u32 = 0,
stencil_sample_max_num: u32 = 0,
zero_attachments_sample_max_num: u32 = 0,
texture_color_sample_max_num: u32 = 0,
texture_integer_sample_max_num: u32 = 0,
texture_depth_sample_max_num: u32 = 0,
texture_stencil_sample_max_num: u32 = 0,
storage_texture_sample_max_num: u32 = 0,

// Resource dimensions
texture_1d_max_dim: u16 = 0,
texture_2d_max_dim: u16 = 0,
texture_3d_max_dim: u16 = 0,
texture_array_layer_max_num: u16 = 0,
typed_buffer_max_dim: u32 = 0,

// Memory
device_upload_heap_size: u64 = 0, // ReBAR
memory_allocation_max_num: u32 = 0,
sampler_allocation_max_num: u32 = 0,
constant_buffer_max_range: u32 = 0,
storage_buffer_max_range: u32 = 0,
buffer_texture_granularity: u64 = 0,
buffer_max_size: u64 = 0,

// Memory alignment
upload_buffer_texture_row_alignment: u32 = 0,
upload_buffer_texture_slice_alignment: u32 = 0,
buffer_shader_resource_offset_alignment: u32 = 0,
constant_buffer_offset_alignment: u32 = 0,
// scratch_buffer_offset_alignment: u32, // commented out
// shader_binding_table_alignment: u32, // commented out

// Pipeline layout
pipeline_layout_descriptor_set_max_num: u32 = 0,
pipeline_layout_root_constant_max_size: u32 = 0,
pipeline_layout_root_descriptor_max_num: u32 = 0,

// Descriptor set
descriptor_set_sampler_max_num: u32 = 0,
descriptor_set_constant_buffer_max_num: u32 = 0,
descriptor_set_storage_buffer_max_num: u32 = 0,
descriptor_set_texture_max_num: u32 = 0,
descriptor_set_storage_texture_max_num: u32 = 0,

// Shader resources
per_stage_descriptor_sampler_max_num: u32 = 0,
per_stage_descriptor_constant_buffer_max_num: u32 = 0,
per_stage_descriptor_storage_buffer_max_num: u32 = 0,
per_stage_descriptor_texture_max_num: u32 = 0,
per_stage_descriptor_storage_texture_max_num: u32 = 0,
per_stage_resource_max_num: u32 = 0,

// Vertex shader
vertex_shader_attribute_max_num: u32 = 0,
vertex_shader_stream_max_num: u32 = 0,
vertex_shader_output_component_max_num: u32 = 0,

// Tessellation shaders
tess_control_shader_generation_max_level: u32 = 0,
tess_control_shader_patch_point_max_num: u32 = 0,
tess_control_shader_per_vertex_input_component_max_num: u32 = 0,
tess_control_shader_per_vertex_output_component_max_num: u32 = 0,
tess_control_shader_per_patch_output_component_max_num: u32 = 0,
tess_control_shader_total_output_component_max_num: u32 = 0,
tess_evaluation_shader_input_component_max_num: u32 = 0,
tess_evaluation_shader_output_component_max_num: u32 = 0,

// Geometry shader
geometry_shader_invocation_max_num: u32 = 0,
geometry_shader_input_component_max_num: u32 = 0,
geometry_shader_output_component_max_num: u32 = 0,
geometry_shader_output_vertex_max_num: u32 = 0,
geometry_shader_total_output_component_max_num: u32 = 0,

// Fragment shader
fragment_shader_input_component_max_num: u32 = 0,
fragment_shader_output_attachment_max_num: u32 = 0,
fragment_shader_dual_source_attachment_max_num: u32 = 0,

// Compute shader
compute_shader_shared_memory_max_size: u32 = 0,
compute_shader_work_group_max_num: [3]u32 = [_]u32{ 0, 0, 0 },
compute_shader_work_group_invocation_max_num: u32 = 0,
compute_shader_work_group_max_dim: [3]u32 = [_]u32{ 0, 0, 0 },

// Precision bits
viewport_precision_bits: u32 = 0,
sub_pixel_precision_bits: u32 = 0,
sub_texel_precision_bits: u32 = 0,
mipmap_precision_bits: u32 = 0,

// Other
timestamp_frequency_hz: u64 = 0,
draw_indirect_max_num: u32 = 0,
sampler_lod_bias_min: f32 = 0,
sampler_lod_bias_max: f32 = 0,
sampler_anisotropy_max: f32 = 0,
texel_offset_min: i32 = 0,
texel_offset_max: u32 = 0,
texel_gather_offset_min: i32 = 0,
texel_gather_offset_max: u32 = 0,
clip_distance_max_num: u32 = 0,
cull_distance_max_num: u32 = 0,
combined_clip_and_cull_distance_max_num: u32 = 0,
// shading_rate_attachment_tile_size: u8, // commented out
// shader_model: u8, // commented out

// Tiers
// conservative_raster_tier: u8, // commented out
// sample_locations_tier: u8, // commented out
// ray_tracing_tier: u8, // commented out
// shading_rate_tier: u8, // commented out
//bindless_tier: u8 = 0,

// Features (bitfields replaced with bool)
is_texture_filter_min_max_supported: bool = false,
is_logic_func_supported: bool = false,
is_depth_bounds_test_supported: bool = false,
is_draw_indirect_count_supported: bool = false,
is_independent_front_and_back_stencil_reference_and_masks_supported: bool = false,
is_copy_queue_timestamp_supported: bool = false,
is_enchanced_barrier_supported: bool = false,
is_memory_tier2_supported: bool = false,
is_dynamic_depth_bias_supported: bool = false,
is_viewport_origin_bottom_left_supported: bool = false,
is_region_resolve_supported: bool = false,

// Shader features
is_shader_native_i16_supported: bool = false,
is_shader_native_f16_supported: bool = false,
is_shader_native_i32_supported: bool = false,
is_shader_native_f32_supported: bool = false,
is_shader_native_i64_supported: bool = false,
is_shader_native_f64_supported: bool = false,
is_shader_atomics_i16_supported: bool = false,
is_shader_atomics_i32_supported: bool = false,
is_shader_atomics_i64_supported: bool = false,

// Emulated features
is_draw_parameters_emulation_enabled: bool = false,

pub fn default_select_adapter(adapters: []const PhysicalAdapter) usize {
    var selected_adapter_index: usize = 0;
    for (adapters, 0..) |adp, idx| {
        if (@intFromEnum(adp.adapter_type) > @intFromEnum(adapters[selected_adapter_index].adapter_type))
            selected_adapter_index = idx;
        if (@intFromEnum(adp.adapter_type) < @intFromEnum(adapters[selected_adapter_index].adapter_type))
            continue;

        if (@intFromEnum(adp.preset_level) > @intFromEnum(adapters[selected_adapter_index].preset_level))
            selected_adapter_index = idx;
        if (@intFromEnum(adp.preset_level) < @intFromEnum(adapters[selected_adapter_index].preset_level))
            continue;

        if (adp.video_memory_size > adapters[selected_adapter_index].video_memory_size)
            selected_adapter_index = idx;
    }
    return selected_adapter_index;
}

pub fn enumerate_adapters(allocator: std.mem.Allocator, renderer: *rhi.Renderer) !std.ArrayList(PhysicalAdapter) {
    var result = std.ArrayList(PhysicalAdapter).empty;
    errdefer result.deinit(allocator);
    if (rhi.is_target_selected(.vk, renderer)) {
        var ikb: *rhi.vulkan.vk.InstanceWrapper = &renderer.backend.vk.ikb;
        var deviceGroupsCount: u32 = 0;
        _ = try ikb.enumeratePhysicalDevices(renderer.backend.vk.instance, &deviceGroupsCount, null);
        const physicalDeviceProperties = try allocator.alloc(rhi.vulkan.vk.PhysicalDeviceGroupProperties, deviceGroupsCount);
        for (physicalDeviceProperties) |*p| {
            p.* = .{
                .physical_device_count = 0,
                .physical_devices = undefined, 
                .subset_allocation = .false,
            };
        }
        defer allocator.free(physicalDeviceProperties);
        _ = try ikb.enumeratePhysicalDeviceGroups(renderer.backend.vk.instance, &deviceGroupsCount, physicalDeviceProperties.ptr);
        var i: usize = 0;
        while (i < deviceGroupsCount) : (i += 1) {
            const physical_device = physicalDeviceProperties[i].physical_devices[0];
            var extension_num: u32 = 0;
            _ = try ikb.enumerateDeviceExtensionProperties(physical_device, null, &extension_num, null);
            const extension_properties: []rhi.vulkan.vk.ExtensionProperties = try allocator.alloc(rhi.vulkan.vk.ExtensionProperties, extension_num);
            defer allocator.free(extension_properties);
            _ = try ikb.enumerateDeviceExtensionProperties(physical_device, null, &extension_num, extension_properties.ptr);

            var properties = std.mem.zeroes(rhi.vulkan.vk.PhysicalDeviceProperties2);
            properties.s_type = .physical_device_properties_2;
            var props11 = std.mem.zeroes(rhi.vulkan.vk.PhysicalDeviceVulkan11Properties);
            props11.s_type = .physical_device_vulkan_1_1_properties;
            var props12 = std.mem.zeroes(rhi.vulkan.vk.PhysicalDeviceVulkan12Properties);
            props12.s_type = .physical_device_vulkan_1_2_properties;
            var props13 = std.mem.zeroes(rhi.vulkan.vk.PhysicalDeviceVulkan13Properties);
            props13.s_type = .physical_device_vulkan_1_3_properties;
            var device_id_properties = std.mem.zeroes(rhi.vulkan.vk.PhysicalDeviceIDProperties);
            device_id_properties.s_type = .physical_device_id_properties;

            rhi.vulkan.add_next(&properties, &props11);
            rhi.vulkan.add_next(&properties, &props12);
            rhi.vulkan.add_next(&properties, &props13);
            rhi.vulkan.add_next(&properties, &device_id_properties);

            var features = std.mem.zeroes(rhi.vulkan.vk.PhysicalDeviceFeatures2);
            features.s_type = .physical_device_features_2;
            var features11: rhi.vulkan.vk.PhysicalDeviceVulkan11Features = .{ .s_type = .physical_device_vulkan_1_1_features };
            var features12: rhi.vulkan.vk.PhysicalDeviceVulkan12Features = .{ .s_type = .physical_device_vulkan_1_2_features };
            var features13: rhi.vulkan.vk.PhysicalDeviceVulkan13Features = .{ .s_type = .physical_device_vulkan_1_3_features };
            var present_id_features: rhi.vulkan.vk.PhysicalDevicePresentIdFeaturesKHR = .{ .s_type = .physical_device_present_id_features_khr };

            rhi.vulkan.add_next(&features, &features11);
            rhi.vulkan.add_next(&features, &features12);
            rhi.vulkan.add_next(&features, &features13);

            if (rhi.vulkan.vk_has_extension(extension_properties, rhi.vulkan.vk.extensions.khr_present_id.name[0..])) {
                rhi.vulkan.add_next(&features, &present_id_features);
            }

            //var memory_properties = std.mem.zeroes(rhi.vulkan.vk.PhysicalDeviceMemoryProperties);
            const memory_properties = ikb.getPhysicalDeviceMemoryProperties(physical_device);
            ikb.getPhysicalDeviceProperties2(physical_device, &properties);
            ikb.getPhysicalDeviceFeatures2(physical_device, &features);

            const limits = &properties.properties.limits;
            var physical_adapter: PhysicalAdapter = .{
                .luid = std.mem.readInt(u64, device_id_properties.device_luid[0..], .little),
                .device_id = properties.properties.device_id,
                .vendor = switch (properties.properties.vendor_id) {
                    0x10DE => .nvidia,
                    0x1002 => .amd,
                    0x8086 => .intel,
                    else => .unknown,
                },
                .backend = .{ .vk = .{
                    .api_version = properties.properties.api_version,
                    .physical_device = physical_device,
                    .is_present_id_supported = present_id_features.present_id == .true,
                    .is_swap_chain_supported = rhi.vulkan.vk_has_extension(extension_properties, rhi.vulkan.vk.extensions.khr_swapchain.name),
                    .is_buffer_device_address_supported = properties.properties.api_version >= @as(u32, @bitCast(rhi.vulkan.vk.API_VERSION_1_2)) or rhi.vulkan.vk_has_extension(extension_properties, rhi.vulkan.vk.extensions.khr_buffer_device_address.name),
                    .is_amd_device_coherent_memory_supported = rhi.vulkan.vk_has_extension(extension_properties, rhi.vulkan.vk.extensions.amd_device_coherent_memory.name),
                    .is_maintenance5_supported = rhi.vulkan.vk_has_extension(extension_properties, rhi.vulkan.vk.extensions.khr_maintenance_5.name),
                } },
                .preset_level = blk: {
                    for (gpu_preset.desktop_presets) |preset| {
                        if (preset.vendor_id == properties.properties.vendor_id and preset.model_id == properties.properties.device_id) {
                            break :blk preset.preset_level;
                        }
                    }
                    break :blk .none;
                },
                .adapter_type = switch (properties.properties.device_type) {
                    .other => .other,
                    .integrated_gpu => .integrated,
                    .discrete_gpu => .discrete,
                    .virtual_gpu => .virtual,
                    .cpu => .cpu,
                    else => .other,
                },
                .viewport_max_num = limits.max_viewports,
                .viewport_bounds_range = [_]f32{ limits.viewport_bounds_range[0], limits.viewport_bounds_range[1] },

                .attachment_max_dim = @min(limits.max_framebuffer_width, limits.max_framebuffer_height),
                .attachment_layer_max_num = limits.max_framebuffer_layers,
                .color_attachment_max_num = limits.max_color_attachments,

                .color_sample_max_num = @bitCast(limits.framebuffer_color_sample_counts),
                .depth_sample_max_num = @bitCast(limits.framebuffer_depth_sample_counts),
                .stencil_sample_max_num = @bitCast(limits.framebuffer_stencil_sample_counts),
                .zero_attachments_sample_max_num = @bitCast(limits.framebuffer_no_attachments_sample_counts),
                .texture_color_sample_max_num = @bitCast(limits.sampled_image_color_sample_counts),
                .texture_integer_sample_max_num = @bitCast(limits.sampled_image_integer_sample_counts),
                .texture_depth_sample_max_num = @bitCast(limits.sampled_image_depth_sample_counts),
                .texture_stencil_sample_max_num = @bitCast(limits.sampled_image_stencil_sample_counts),
                .storage_texture_sample_max_num = @bitCast(limits.storage_image_sample_counts),

                .texture_1d_max_dim = @intCast(limits.max_image_dimension_1d),
                .texture_2d_max_dim = @intCast(limits.max_image_dimension_2d),
                .texture_3d_max_dim = @intCast(limits.max_image_dimension_3d),
                .texture_array_layer_max_num = @intCast(limits.max_image_array_layers),
                .typed_buffer_max_dim = limits.max_texel_buffer_elements,
                .memory_allocation_max_num = limits.max_memory_allocation_count,
                .sampler_allocation_max_num = limits.max_sampler_allocation_count,
                .constant_buffer_max_range = limits.max_uniform_buffer_range,
                .storage_buffer_max_range = limits.max_storage_buffer_range,
                .buffer_texture_granularity = limits.buffer_image_granularity,
                .buffer_max_size = props13.max_buffer_size,

                .upload_buffer_texture_row_alignment = @intCast(limits.optimal_buffer_copy_row_pitch_alignment),
                .upload_buffer_texture_slice_alignment = @intCast(limits.optimal_buffer_copy_offset_alignment),
                .buffer_shader_resource_offset_alignment = @intCast(@max(limits.min_texel_buffer_offset_alignment, limits.min_storage_buffer_offset_alignment)),
                .constant_buffer_offset_alignment = @intCast(limits.min_uniform_buffer_offset_alignment),
                // physicalAdapter->scratchBufferOffsetAlignment = accelerationStructureProps.minAccelerationStructureScratchOffsetAlignment;
                // physicalAdapter->shaderBindingTableAlignment = rayTracingProps.shaderGroupBaseAlignment;

                .pipeline_layout_descriptor_set_max_num = limits.max_bound_descriptor_sets,
                .pipeline_layout_root_constant_max_size = limits.max_push_constants_size,
                // physicalAdapter->pipelineLayoutRootDescriptorMaxNum = pushDescriptorProps.maxPushDescriptors;

                .per_stage_descriptor_sampler_max_num = limits.max_per_stage_descriptor_samplers,
                .per_stage_descriptor_constant_buffer_max_num = limits.max_per_stage_descriptor_uniform_buffers,
                .per_stage_descriptor_storage_buffer_max_num = limits.max_per_stage_descriptor_storage_buffers,
                .per_stage_descriptor_texture_max_num = limits.max_per_stage_descriptor_sampled_images,
                .per_stage_descriptor_storage_texture_max_num = limits.max_per_stage_descriptor_storage_images,
                .per_stage_resource_max_num = limits.max_per_stage_resources,

                .descriptor_set_sampler_max_num = limits.max_descriptor_set_samplers,
                .descriptor_set_constant_buffer_max_num = limits.max_descriptor_set_uniform_buffers,
                .descriptor_set_storage_buffer_max_num = limits.max_descriptor_set_storage_buffers,
                .descriptor_set_texture_max_num = limits.max_descriptor_set_sampled_images,
                .descriptor_set_storage_texture_max_num = limits.max_descriptor_set_storage_images,

                .vertex_shader_attribute_max_num = limits.max_vertex_input_attributes,
                .vertex_shader_stream_max_num = limits.max_vertex_input_bindings,
                .vertex_shader_output_component_max_num = limits.max_vertex_output_components,

                .tess_control_shader_generation_max_level = limits.max_tessellation_generation_level,
                .tess_control_shader_patch_point_max_num = limits.max_tessellation_patch_size,
                .tess_control_shader_per_vertex_input_component_max_num = limits.max_tessellation_control_per_vertex_input_components,
                .tess_control_shader_per_vertex_output_component_max_num = limits.max_tessellation_control_per_vertex_output_components,
                .tess_control_shader_per_patch_output_component_max_num = limits.max_tessellation_control_per_patch_output_components,
                .tess_control_shader_total_output_component_max_num = limits.max_tessellation_control_total_output_components,
                .tess_evaluation_shader_input_component_max_num = limits.max_tessellation_evaluation_input_components,
                .tess_evaluation_shader_output_component_max_num = limits.max_tessellation_evaluation_output_components,

                .geometry_shader_invocation_max_num = limits.max_geometry_shader_invocations,
                .geometry_shader_input_component_max_num = limits.max_geometry_input_components,
                .geometry_shader_output_component_max_num = limits.max_geometry_output_components,
                .geometry_shader_output_vertex_max_num = limits.max_geometry_output_vertices,
                .geometry_shader_total_output_component_max_num = limits.max_geometry_total_output_components,

                .fragment_shader_input_component_max_num = limits.max_fragment_input_components,
                .fragment_shader_output_attachment_max_num = limits.max_fragment_output_attachments,
                .fragment_shader_dual_source_attachment_max_num = limits.max_fragment_dual_src_attachments,

                .compute_shader_shared_memory_max_size = limits.max_compute_shared_memory_size,
                .compute_shader_work_group_max_num = [_]u32{ limits.max_compute_work_group_count[0], limits.max_compute_work_group_count[1], limits.max_compute_work_group_count[2] },
                .compute_shader_work_group_invocation_max_num = limits.max_compute_work_group_invocations,
                .compute_shader_work_group_max_dim = [_]u32{ limits.max_compute_work_group_size[0], limits.max_compute_work_group_size[1], limits.max_compute_work_group_size[2] },

                .viewport_precision_bits = limits.viewport_sub_pixel_bits,
                .sub_pixel_precision_bits = limits.sub_pixel_precision_bits,
                .sub_texel_precision_bits = limits.sub_texel_precision_bits,
                .mipmap_precision_bits = limits.mipmap_precision_bits,

                .timestamp_frequency_hz = @intFromFloat(1e9 / @as(f64, limits.timestamp_period) + 0.5),
                .draw_indirect_max_num = limits.max_draw_indirect_count,
                .sampler_lod_bias_min = -limits.max_sampler_lod_bias,
                .sampler_lod_bias_max = limits.max_sampler_lod_bias,
                .sampler_anisotropy_max = limits.max_sampler_anisotropy,
                .texel_offset_min = limits.min_texel_offset,
                .texel_offset_max = limits.max_texel_offset,
                .texel_gather_offset_min = limits.min_texel_gather_offset,
                .texel_gather_offset_max = limits.max_texel_gather_offset,
                .clip_distance_max_num = limits.max_clip_distances,
                .cull_distance_max_num = limits.max_cull_distances,
                .combined_clip_and_cull_distance_max_num = limits.max_combined_clip_and_cull_distances,

                //physicalAdapter->vendor = VendorFromID( properties.properties.vendorID );
                //physicalAdapter->vk.physicalDevice = physicalAdapter->vk.physicalDevice;
                //physicalAdapter->vk.apiVersion = properties.properties.apiVersion;
                //physicalAdapter->presetLevel = RI_GPU_PRESET_NONE;

                //.bindless_tier = if (features12.descriptor_indexing > 0) 1 else 0,

                .is_texture_filter_min_max_supported = features12.sampler_filter_minmax == .true,
                .is_logic_func_supported = features.features.logic_op == .true,
                .is_depth_bounds_test_supported = features.features.depth_bounds == .true,
                .is_draw_indirect_count_supported = features12.draw_indirect_count == .true,
                .is_independent_front_and_back_stencil_reference_and_masks_supported = true,
                // physicalAdapter->isLineSmoothingSupported = lineRasterizationFeatures.smoothLines;
                .is_copy_queue_timestamp_supported = limits.timestamp_compute_and_graphics == .true,
                // physicalAdapter->isMeshShaderPipelineStatsSupported = meshShaderFeatures.meshShaderQueries == VK_TRUE;
                .is_enchanced_barrier_supported = true,
                .is_memory_tier2_supported = true, // TODO: seems to be the best match
                .is_dynamic_depth_bias_supported = true,
                .is_viewport_origin_bottom_left_supported = true,
                .is_region_resolve_supported = true,

                .is_shader_native_i16_supported = features.features.shader_int_16 == .true,
                .is_shader_native_f16_supported = features12.shader_float_16 == .true,
                .is_shader_native_i32_supported = true,
                .is_shader_native_f32_supported = true,
                .is_shader_native_i64_supported = features.features.shader_int_64 == .true,
                .is_shader_native_f64_supported = features.features.shader_float_64 == .true,
                // physicalAdapter->isShaderAtomicsF16Supported = (shaderAtomicFloat2Features.shaderBufferFloat16Atomics || shaderAtomicFloat2Features.shaderSharedFloat16Atomics) ? true : false;
                .is_shader_atomics_i32_supported = true,
                // physicalAdapter->isShaderAtomicsF32Supported = (shaderAtomicFloatFeatures.shaderBufferFloat32Atomics || shaderAtomicFloatFeatures.shaderSharedFloat32Atomics) ? true : false;
                .is_shader_atomics_i64_supported = if ((features12.shader_buffer_int_64_atomics == .true) or (features12.shader_shared_int_64_atomics == .true)) true else false,
                // physicalAdapter->isShaderAtomicsF64Supported = (shaderAtomicFloatFeatures.shaderBufferFloat64Atomics || shaderAtomicFloatFeatures.shaderSharedFloat64Atomics) ? true : false;
                //
                //
            };
            for (0..memory_properties.memory_heap_count) |heap_index| {
                const memory_heap = &memory_properties.memory_heaps[heap_index];
                if (memory_heap.flags.device_local_bit == true and physical_adapter.adapter_type != .integrated) {
                    physical_adapter.video_memory_size += memory_heap.size;
                } else {
                    physical_adapter.system_memory_size += memory_heap.size;
                }
            }
            for (0..memory_properties.memory_type_count) |type_index| {
                const memory_type = &memory_properties.memory_types[type_index];
                if (memory_type.property_flags.device_local_bit == true and memory_type.property_flags.host_visible_bit == false) {
                    physical_adapter.device_upload_heap_size += memory_properties.memory_heaps[memory_type.heap_index].size;
                }
            }

            std.mem.copyForwards(u8, physical_adapter.name[0..], std.mem.sliceTo(properties.properties.device_name[0..], 0));
            try result.append(allocator, physical_adapter);
        }
    }
    return result;
}
