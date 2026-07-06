// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const std = @import("std");
const rhi = @import("root.zig");
pub const vk = @import("vulkan");
pub const vma = @import("vma");

pub const default_device_extensions = &[_][:0]const u8{
    vk.extensions.khr_swapchain.name,
    vk.extensions.khr_maintenance_1.name,
    vk.extensions.khr_shader_draw_parameters.name,
    vk.extensions.ext_shader_subgroup_ballot.name,
    vk.extensions.ext_shader_subgroup_vote.name,
    vk.extensions.khr_dedicated_allocation.name,
    vk.extensions.khr_get_memory_requirements_2.name,

    vk.extensions.khr_draw_indirect_count.name,
    vk.extensions.ext_device_fault.name,
    // Fragment shader interlock extension to be used for ROV type functionality in Vulkan
    vk.extensions.ext_fragment_shader_interlock.name,

    //************************************************************************/
    // AMD Specific Extensions
    //************************************************************************/
    vk.extensions.amd_draw_indirect_count.name,
    vk.extensions.amd_shader_ballot.name,
    vk.extensions.amd_gcn_shader.name,
    vk.extensions.amd_buffer_marker.name,
    vk.extensions.amd_device_coherent_memory.name,
    //************************************************************************/
    // Multi GPU Extensions
    //************************************************************************/
    vk.extensions.khr_device_group.name,
    //************************************************************************/
    // Bindless & Non Uniform access Extensions
    //************************************************************************/
    vk.extensions.ext_descriptor_indexing.name,
    vk.extensions.khr_maintenance_3.name,
    // Required by raytracing and the new bindless descriptor API if we use it in future
    vk.extensions.khr_buffer_device_address.name,
    //************************************************************************/
    // Shader Atomic Int 64 Extension
    //************************************************************************/
    vk.extensions.khr_shader_atomic_int_64.name,
    //************************************************************************/
    //************************************************************************/
    vk.extensions.khr_ray_query.name,
    vk.extensions.khr_ray_tracing_pipeline.name,
    // Required by VK_KHR_ray_tracing_pipeline
    vk.extensions.khr_spirv_1_4.name,
    // Required by VK_KHR_spirv_1_4
    vk.extensions.khr_shader_float_controls.name,

    vk.extensions.khr_acceleration_structure.name,
    // Required by VK_KHR_acceleration_structure
    vk.extensions.khr_deferred_host_operations.name,
    //************************************************************************/
    // YCbCr format support
    //************************************************************************/
    // Requirement for VK_KHR_sampler_ycbcr_conversion
    vk.extensions.khr_bind_memory_2.name,
    vk.extensions.khr_sampler_ycbcr_conversion.name,
    vk.extensions.khr_bind_memory_2.name,
    vk.extensions.khr_image_format_list.name,
    vk.extensions.khr_image_format_list.name,
    vk.extensions.ext_sample_locations.name,
    //************************************************************************/
    // Dynamic rendering
    //************************************************************************/
    vk.extensions.khr_dynamic_rendering.name,
    vk.extensions.khr_depth_stencil_resolve.name, // Required by VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME
    vk.extensions.khr_create_renderpass_2.name, // Required by VK_KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME
    vk.extensions.khr_multiview.name, // Required by VK_KHR_CREATE_RENDERPASS_2_EXTENSION_NAME
    //************************************************************************/
    // Nsight Aftermath
    //************************************************************************/
    vk.extensions.ext_astc_decode_mode.name,
};

pub fn add_next(current: anytype, next: anytype) void {
    const tmp = current.p_next;
    current.p_next = next;
    next.p_next = tmp;
}

pub fn VKDebugMessengerUtility(messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, _: vk.DebugUtilsMessageTypeFlagsEXT, callbackData: ?*const vk.DebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(vk.vulkan_call_conv) vk.Bool32 {
    if (messageSeverity.error_bit_ext) {
        std.debug.print("VK ERROR: {s}\n", .{callbackData.?.p_message.?[0..]});
    }
    if (messageSeverity.warning_bit_ext) {
        std.debug.print("VK WARNING: {s}\n", .{callbackData.?.p_message.?[0..]});
    }
    if (messageSeverity.info_bit_ext) {
        std.debug.print("VK INFO: {s}\n", .{callbackData.?.p_message.?[0..]});
    }
    return .false;
}

pub fn VKImageAspectFlagsFromFormat(format: rhi.Format) rhi.vulkan.vk.ImageAspectFlags {
    const props = rhi.format.GetProps(format);
    var result = rhi.vulkan.vk.ImageAspectFlags{ .stencil_bit = props.is_stencil, .depth_bit = props.is_depth };

    if (result.stencil_bit || result.depth_bit) {
        return result;
    }
    result.color_bit = true;
    return result;
}

pub fn VKImageSpaceFlagsFromFormatAndStencil(format: vk.Format, include_stencil: bool) vk.ImageAspectFlags {
    return switch (format) {
        .d16_unorm, .x8_d24_unorm_pack32, .d32_sfloat => vk.ImageAspectFlags{ .depth_bit = true },
        .s8_uint => vk.ImageAspectFlags{ .stencil_bit = true },
        .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_sfloat_s8_uint => vk.ImageAspectFlags{
            .depth_bit = true,
            .stencil_bit = include_stencil,
        },
        else => vk.ImageAspectFlags{ .color_bit = true },
    };
}

pub fn vk_has_extension(properties: []const rhi.vulkan.vk.ExtensionProperties, val: []const u8) bool {
    for (properties) |prop| {
        if (std.mem.eql(u8, std.mem.sliceTo(prop.extension_name[0..], 0), val)) {
            return true;
        }
    }
    return false;
}

pub fn VKWrapResult(result: vk.Result) !void {
    if (result != vk.Result.success) {
        std.debug.print("Vulkan error: {d}\n", .{result});
        return error.VulkanError;
    }
}

pub fn toShaderBytecode(comptime src: []const u8) [src.len / 4]u32 {
    var result: [src.len / 4]u32 = undefined;
    @memcpy(std.mem.sliceAsBytes(result[0..]), src);
    return result;
}

//pub fn create_embeded_module(renderer: *rhi.Renderer, spv: []const u32, device: *rhi.Device) !volk.c.VkShaderModule {
//    std.debug.assert(renderer.backend == .vulkan);
//    var create_module: volk.c.VkShaderModule = undefined;
//    var shader_module_create_info = vk.ShaderModuleCreateInfo{
//        .sType = .shader_module_create_info,
//        .code_size = spv.len,
//        .p_code = spv.ptr,
//    };
//
//    try volk.c.vkCreateShaderModule.?(device.backend.vk.device, &shader_module_create_info, null, &create_module);
//    return create_module;
//}

pub fn vk_fill_mode(fill_mode: rhi.pipeline.FillMode) vk.PolygonMode {
    return switch (fill_mode) {
        .wireframe => .line,
        .solid => .fill,
    };
}

pub fn vk_topology(topology: rhi.pipeline.Toplogy) vk.PrimitiveTopology {
    return switch (topology) {
        .point_list => .point_list,
        .line_list => .line_list,
        .line_strip => .line_strip,
        .triangle_list => .triangle_list,
        .triangle_strip => .triangle_strip,
        .triangle_fan => .triangle_fan,
        .line_list_with_adjacency => .line_list_with_adjacency,
        .line_strip_with_adjacency => .line_strip_with_adjacency,
        .triangle_list_with_adjacency => .triangle_list_with_adjacency,
        .triangle_strip_with_adjacency => .triangle_strip_with_adjacency,
        .patch_list => .patch_list,
    };
}

const FormatMapping = struct {
    rhi: rhi.format.Format,
    vk: vk.Format,
};

const format_mappings = [_]FormatMapping{
    .{ .rhi = .unknown, .vk = .undefined },
    .{ .rhi = .d16_unorm_s8_uint, .vk = .d16_unorm_s8_uint },
    .{ .rhi = .d24_unorm_s8_uint, .vk = .d24_unorm_s8_uint },
    .{ .rhi = .d32_sfloat_s8_uint, .vk = .d32_sfloat_s8_uint },
    .{ .rhi = .r8_unorm, .vk = .r8_unorm },
    .{ .rhi = .r8_snorm, .vk = .r8_snorm },
    .{ .rhi = .r8_uint, .vk = .r8_uint },
    .{ .rhi = .r8_sint, .vk = .r8_sint },
    .{ .rhi = .rg8_unorm, .vk = .r8g8_unorm },
    .{ .rhi = .rg8_snorm, .vk = .r8g8_snorm },
    .{ .rhi = .rg8_uint, .vk = .r8g8_uint },
    .{ .rhi = .rg8_sint, .vk = .r8g8_sint },
    .{ .rhi = .bgra8_unorm, .vk = .b8g8r8a8_unorm },
    .{ .rhi = .bgra8_srgb, .vk = .b8g8r8a8_srgb },
    .{ .rhi = .bgr8_unorm, .vk = .b8g8r8_unorm },
    .{ .rhi = .rgb8_unorm, .vk = .r8g8b8_unorm },
    .{ .rhi = .rgba8_unorm, .vk = .r8g8b8a8_unorm },
    .{ .rhi = .rgba8_snorm, .vk = .r8g8b8a8_snorm },
    .{ .rhi = .rgba8_uint, .vk = .r8g8b8a8_uint },
    .{ .rhi = .rgba8_sint, .vk = .r8g8b8a8_sint },
    .{ .rhi = .rgba8_srgb, .vk = .r8g8b8a8_srgb },
    .{ .rhi = .r16_unorm, .vk = .r16_unorm },
    .{ .rhi = .r16_snorm, .vk = .r16_snorm },
    .{ .rhi = .r16_uint, .vk = .r16_uint },
    .{ .rhi = .r16_sint, .vk = .r16_sint },
    .{ .rhi = .r16_sfloat, .vk = .r16_sfloat },
    .{ .rhi = .rg16_unorm, .vk = .r16g16_unorm },
    .{ .rhi = .rg16_snorm, .vk = .r16g16_snorm },
    .{ .rhi = .rg16_uint, .vk = .r16g16_uint },
    .{ .rhi = .rg16_sint, .vk = .r16g16_sint },
    .{ .rhi = .rg16_sfloat, .vk = .r16g16_sfloat },
    .{ .rhi = .rgba16_unorm, .vk = .r16g16b16a16_unorm },
    .{ .rhi = .rgba16_snorm, .vk = .r16g16b16a16_snorm },
    .{ .rhi = .rgba16_uint, .vk = .r16g16b16a16_uint },
    .{ .rhi = .rgba16_sint, .vk = .r16g16b16a16_sint },
    .{ .rhi = .rgba16_sfloat, .vk = .r16g16b16a16_sfloat },
    .{ .rhi = .r32_uint, .vk = .r32_uint },
    .{ .rhi = .r32_sint, .vk = .r32_sint },
    .{ .rhi = .r32_sfloat, .vk = .r32_sfloat },
    .{ .rhi = .rg32_uint, .vk = .r32g32_uint },
    .{ .rhi = .rg32_sint, .vk = .r32g32_sint },
    .{ .rhi = .rg32_sfloat, .vk = .r32g32_sfloat },
    .{ .rhi = .rgb32_uint, .vk = .r32g32b32_uint },
    .{ .rhi = .rgb32_sint, .vk = .r32g32b32_sint },
    .{ .rhi = .rgb32_sfloat, .vk = .r32g32b32_sfloat },
    .{ .rhi = .rgba32_uint, .vk = .r32g32b32a32_uint },
    .{ .rhi = .rgba32_sint, .vk = .r32g32b32a32_sint },
    .{ .rhi = .rgba32_sfloat, .vk = .r32g32b32a32_sfloat },
    .{ .rhi = .r10_g10_b10_a2_unorm, .vk = .a2b10g10r10_unorm_pack32 },
    .{ .rhi = .r10_g10_b10_a2_uint, .vk = .a2b10g10r10_uint_pack32 },
    .{ .rhi = .r11_g11_b10_ufloat, .vk = .b10g11r11_ufloat_pack32 },
    .{ .rhi = .r9_g9_b9_e5_unorm, .vk = .e5b9g9r9_ufloat_pack32 },
    .{ .rhi = .r5_g6_b5_unorm, .vk = .r5g6b5_unorm_pack16 },
    .{ .rhi = .r5_g5_b5_a1_unorm, .vk = .a1r5g5b5_unorm_pack16 },
    .{ .rhi = .r4_g4_b4_a4_unorm, .vk = .a4r4g4b4_unorm_pack16 },
    .{ .rhi = .bc1_rgba_unorm, .vk = .bc1_rgba_unorm_block },
    .{ .rhi = .bc1_rgba_srgb, .vk = .bc1_rgba_srgb_block },
    .{ .rhi = .bc2_rgba_unorm, .vk = .bc2_unorm_block },
    .{ .rhi = .bc2_rgba_srgb, .vk = .bc2_srgb_block },
    .{ .rhi = .bc3_rgba_unorm, .vk = .bc3_unorm_block },
    .{ .rhi = .bc3_rgba_srgb, .vk = .bc3_srgb_block },
    .{ .rhi = .bc4_r_unorm, .vk = .bc4_unorm_block },
    .{ .rhi = .bc4_r_snorm, .vk = .bc4_snorm_block },
    .{ .rhi = .bc5_rg_unorm, .vk = .bc5_unorm_block },
    .{ .rhi = .bc5_rg_snorm, .vk = .bc5_snorm_block },
    .{ .rhi = .bc6h_rgb_ufloat, .vk = .bc6h_ufloat_block },
    .{ .rhi = .bc6h_rgb_sfloat, .vk = .bc6h_sfloat_block },
    .{ .rhi = .bc7_rgba_unorm, .vk = .bc7_unorm_block },
    .{ .rhi = .bc7_rgba_srgb, .vk = .bc7_srgb_block },
    .{ .rhi = .d16_unorm, .vk = .d16_unorm },
    .{ .rhi = .d32_sfloat, .vk = .d32_sfloat },
    .{ .rhi = .d32_sfloat_s8_uint_x24, .vk = .d32_sfloat_s8_uint },
    .{ .rhi = .r24_unorm_x8, .vk = .d24_unorm_s8_uint },
    .{ .rhi = .x24_r8_uint, .vk = .d24_unorm_s8_uint },
    .{ .rhi = .x32_r8_uint_x24, .vk = .d32_sfloat_s8_uint },
    .{ .rhi = .r32_sfloat_x8_x24, .vk = .d32_sfloat_s8_uint },
    .{ .rhi = .etc2_r8g8b8_unorm, .vk = .etc2_r8g8b8_unorm_block }, // Canonical for this block type normally
    .{ .rhi = .etc1_r8g8b8_oes, .vk = .etc2_r8g8b8_unorm_block }, // Alias
    .{ .rhi = .etc2_r8g8b8_srgb, .vk = .etc2_r8g8b8_srgb_block },
    .{ .rhi = .etc2_r8g8b8a1_unorm, .vk = .etc2_r8g8b8a1_unorm_block },
    .{ .rhi = .etc2_r8g8b8a1_srgb, .vk = .etc2_r8g8b8a1_srgb_block },
    .{ .rhi = .etc2_r8g8b8a8_unorm, .vk = .etc2_r8g8b8a8_unorm_block },
    .{ .rhi = .etc2_r8g8b8a8_srgb, .vk = .etc2_r8g8b8a8_srgb_block },
    .{ .rhi = .etc2_eac_r11_unorm, .vk = .eac_r11_unorm_block },
    .{ .rhi = .etc2_eac_r11_snorm, .vk = .eac_r11_snorm_block },
    .{ .rhi = .etc2_eac_r11g11_unorm, .vk = .eac_r11g11_unorm_block },
    .{ .rhi = .etc2_eac_r11g11_snorm, .vk = .eac_r11g11_snorm_block },
};

pub fn to_vk_format(format: rhi.format.Format) rhi.vulkan.vk.Format {
    inline for (format_mappings) |mapping| {
        if (mapping.rhi == format) return mapping.vk;
    }
    return .undefined;
}

pub fn from_vk_format(format: vk.Format) rhi.format.Format {
    inline for (format_mappings) |mapping| {
        if (mapping.vk == format) return mapping.rhi;
    }
    return .unknown;
}
