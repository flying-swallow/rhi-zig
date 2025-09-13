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

pub fn debug_utils_messenger(messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT, _: vk.DebugUtilsMessageTypeFlagsEXT, callbackData: ?*const vk.DebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(vk.vulkan_call_conv) vk.Bool32 {
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

pub fn determains_aspect_mask(format: vk.Format, include_stencil: bool) vk.ImageAspectFlags {
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

pub fn wrap_vk_result(result: vk.Result) !void {
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

pub fn vk_format(format: rhi.format.Format) rhi.vulkan.vk.Format {
    return switch (format) {
        .unknown => vk.Format.undefined,
        .d16_unorm_s8_uint => vk.Format.d16_unorm_s8_uint,
        .d24_unorm_s8_uint => vk.Format.d24_unorm_s8_uint,
        .d32_sfloat_s8_uint => vk.Format.d32_sfloat_s8_uint,
        .r8_unorm => vk.Format.r8_unorm,
        .r8_snorm => vk.Format.r8_snorm,
        .r8_uint => vk.Format.r8_uint,
        .r8_sint => vk.Format.r8_sint,
        .rg8_unorm => vk.Format.r8g8_unorm,
        .rg8_snorm => vk.Format.r8g8_snorm,
        .rg8_uint => vk.Format.r8g8_uint,
        .rg8_sint => vk.Format.r8g8_sint,
        .bgra8_unorm => vk.Format.b8g8r8a8_unorm,
        .bgra8_srgb => vk.Format.b8g8r8a8_srgb,
        .bgr8_unorm => vk.Format.b8g8r8_unorm,
        .rgb8_unorm => vk.Format.r8g8b8_unorm,
        .rgba8_unorm => vk.Format.r8g8b8a8_unorm,
        .rgba8_snorm => vk.Format.r8g8b8a8_snorm,
        .rgba8_uint => vk.Format.r8g8b8a8_uint,
        .rgba8_sint => vk.Format.r8g8b8a8_sint,
        .rgba8_srgb => vk.Format.r8g8b8a8_srgb,
        .r16_unorm => vk.Format.r16_unorm,
        .r16_snorm => vk.Format.r16_snorm,
        .r16_uint => vk.Format.r16_uint,
        .r16_sint => vk.Format.r16_sint,
        .r16_sfloat => vk.Format.r16_sfloat,
        .rg16_unorm => vk.Format.r16g16_unorm,
        .rg16_snorm => vk.Format.r16g16_snorm,
        .rg16_uint => vk.Format.r16g16_uint,
        .rg16_sint => vk.Format.r16g16_sint,
        .rg16_sfloat => vk.Format.r16g16_sfloat,
        .rgba16_unorm => vk.Format.r16g16b16a16_unorm,
        .rgba16_snorm => vk.Format.r16g16b16a16_snorm,
        .rgba16_uint => vk.Format.r16g16b16a16_uint,
        .rgba16_sint => vk.Format.r16g16b16a16_sint,
        .rgba16_sfloat => vk.Format.r16g16b16a16_sfloat,
        .r32_uint => vk.Format.r32_uint,
        .r32_sint => vk.Format.r32_sint,
        .r32_sfloat => vk.Format.r32_sfloat,
        .rg32_uint => vk.Format.r32g32_uint,
        .rg32_sint => vk.Format.r32g32_sint,
        .rg32_sfloat => vk.Format.r32g32_sfloat,
        .rgb32_uint => vk.Format.r32g32b32_uint,
        .rgb32_sint => vk.Format.r32g32b32_sint,
        .rgb32_sfloat => vk.Format.r32g32b32_sfloat,
        .rgba32_uint => vk.Format.r32g32b32a32_uint,
        .rgba32_sint => vk.Format.r32g32b32a32_sint,
        .rgba32_sfloat => vk.Format.r32g32b32a32_sfloat,
        .r10_g10_b10_a2_unorm => vk.Format.a2b10g10r10_unorm_pack32,
        .r10_g10_b10_a2_uint => vk.Format.a2b10g10r10_uint_pack32,
        .r11_g11_b10_ufloat => vk.Format.b10g11r11_ufloat_pack32,
        .r9_g9_b9_e5_unorm => vk.Format.e5b9g9r9_ufloat_pack32,
        .r5_g6_b5_unorm => vk.Format.r5g6b5_unorm_pack16,
        .r5_g5_b5_a1_unorm => vk.Format.a1r5g5b5_unorm_pack16,
        .r4_g4_b4_a4_unorm => vk.Format.a4r4g4b4_unorm_pack16,
        .bc1_rgba_unorm => vk.Format.bc1_rgba_unorm_block,
        .bc1_rgba_srgb => vk.Format.bc1_rgba_srgb_block,
        .bc2_rgba_unorm => vk.Format.bc2_unorm_block,
        .bc2_rgba_srgb => vk.Format.bc2_srgb_block,
        .bc3_rgba_unorm => vk.Format.bc3_unorm_block,
        .bc3_rgba_srgb => vk.Format.bc3_srgb_block,
        .bc4_r_unorm => vk.Format.bc4_unorm_block,
        .bc4_r_snorm => vk.Format.bc4_snorm_block,
        .bc5_rg_unorm => vk.Format.bc5_unorm_block,
        .bc5_rg_snorm => vk.Format.bc5_snorm_block,
        .bc6h_rgb_ufloat => vk.Format.bc6h_ufloat_block,
        .bc6h_rgb_sfloat => vk.Format.bc6h_sfloat_block,
        .bc7_rgba_unorm => vk.Format.bc7_unorm_block,
        .bc7_rgba_srgb => vk.Format.bc7_srgb_block,
        .d16_unorm => vk.Format.d16_unorm,
        .d32_sfloat => vk.Format.d32_sfloat,
        .d32_sfloat_s8_uint_x24 => vk.Format.d32_sfloat_s8_uint,
        .r24_unorm_x8 => vk.Format.d24_unorm_s8_uint,
        .x24_r8_uint => vk.Format.d24_unorm_s8_uint,
        .x32_r8_uint_x24 => vk.Format.d32_sfloat_s8_uint,
        .r32_sfloat_x8_x24 => vk.Format.d32_sfloat_s8_uint,
        .etc1_r8g8b8_oes => vk.Format.etc2_r8g8b8_unorm_block,
        .etc2_r8g8b8_unorm => vk.Format.etc2_r8g8b8_unorm_block,
        .etc2_r8g8b8_srgb => vk.Format.etc2_r8g8b8_srgb_block,
        .etc2_r8g8b8a1_unorm => vk.Format.etc2_r8g8b8a1_unorm_block,
        .etc2_r8g8b8a1_srgb => vk.Format.etc2_r8g8b8a1_srgb_block,
        .etc2_r8g8b8a8_unorm => vk.Format.etc2_r8g8b8a8_unorm_block,
        .etc2_r8g8b8a8_srgb => vk.Format.etc2_r8g8b8a8_srgb_block,
        .etc2_eac_r11_unorm => vk.Format.eac_r11_unorm_block,
        .etc2_eac_r11_snorm => vk.Format.eac_r11_snorm_block,
        .etc2_eac_r11g11_unorm => vk.Format.eac_r11g11_unorm_block,
        .etc2_eac_r11g11_snorm => vk.Format.eac_r11g11_snorm_block,
        else => vk.Format.undefined,
    };
}
