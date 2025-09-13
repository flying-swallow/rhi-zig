const rhi = @import("root.zig");
const vma = @import("vma");
const std = @import("std");
const vulkan = @import("vulkan.zig");

pub const PipelineLayout = @This();

pub const DescriptorType = enum(u8) {
    sampler,
    combined_image_sampler,
    sampled_image,
    storage_image,
    uniform_texel_buffer,
    storage_texel_buffer,
    uniform_buffer,
    storage_buffer,
    uniform_buffer_dynamic,
    storage_buffer_dynamic,
    input_attachment,
    inline_uniform_block,
    acceleration_structure, // VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR
};

pub const DescriptorRangeBits = enum(u8) { none = 0, paritially_bound = 1 << 0, array = 1 << 1, variable_sized_array = 1 << 2 };

backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct { layout: rhi.vulkan.vk.PipelineLayout }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
},

pub const DescriptorRangeDesc = struct {
    base_register_index: u32,
    descriptor_num: u32, // treated as max size if "VARIABLE_SIZED_ARRAY" flag is set
    descriptor_type: DescriptorType,
    shader_stages: u32,
    flags: DescriptorRangeBits,
};

pub const DynamicConstantBufferDesc = struct {
    register_index: u32,
    shader_stages: union {
        vk: rhi.vulkan.vk.ShaderStageFlags,
    },
};

pub const DescriptorSetDesc = struct {
    register_space: u32, // must be unique, avoid big gaps
    ranges: []DescriptorRangeDesc,
    dynamic_constant_buffers: []DynamicConstantBufferDesc,
};

pub fn init(allocator: std.mem.Allocator, renderer: *rhi.Renderer, device: *rhi.Device, desc: struct {
    descriptor_sets: []DescriptorSetDesc = &.{},
}) !PipelineLayout {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const BindingSet = struct {
            register_index: u32,
            descriptor_bindings: std.ArrayList(rhi.vulkan.vk.DescriptorSetLayoutBinding),
            binding_flags: std.ArrayList(rhi.vulkan.vk.DescriptorBindingFlags),
        };

        var register_count: u32 = 0;
        var bindings = std.ArrayList(BindingSet).empty;
        defer {
            for (bindings.items) |*b| {
                b.descriptor_bindings.deinit(allocator);
                b.binding_flags.deinit(allocator);
            }
            bindings.deinit(allocator);
        }

        for (desc.descriptor_sets) |descriptor_set| {
            register_count = @max(descriptor_set.register_space + 1, register_count);
            for (descriptor_set.ranges) |descriptor_range| {
                const binding_set: *BindingSet = result: {
                    for (bindings.items) |*b| {
                        if (b.register_index == descriptor_set.register_space) {
                            break :result b;
                        }
                    }
                    try bindings.append(allocator, .{
                        .register_index = descriptor_set.register_space,
                        .descriptor_bindings = std.ArrayList(rhi.vulkan.vk.DescriptorSetLayoutBinding).empty,
                        .binding_flags = std.ArrayList(rhi.vulkan.vk.DescriptorBindingFlags).empty,
                    });
                    break :result &bindings.items[bindings.items.len - 1];
                };

                const layout_binding: rhi.vulkan.vk.DescriptorSetLayoutBinding = .{
                    .binding = descriptor_range.base_register_index,
                    .descriptor_type = switch (descriptor_range.descriptor_type) {
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
                        .inline_uniform_block => .inline_uniform_block_ext,
                        .acceleration_structure => .acceleration_structure_khr,
                    },
                    .descriptor_count = descriptor_range.descriptor_num,
                    .stage_flags = .{} //descriptor_range.shader_stages,
                };
                try binding_set.descriptor_bindings.append(allocator, layout_binding);
            }
        }

        const descriptor_set_layouts = try allocator.alloc(rhi.vulkan.vk.DescriptorSetLayout, register_count);
        defer allocator.free(descriptor_set_layouts);

        const has_gaps = register_count > bindings.items.len;
        if (has_gaps) {
            var create_layout = rhi.vulkan.vk.DescriptorSetLayoutCreateInfo{};
            const empty_layout: rhi.vulkan.vk.DescriptorSetLayout = try dkb.createDescriptorSetLayout(device.backend.vk.device, &create_layout, null);
            for (descriptor_set_layouts) |*dsl| dsl.* = empty_layout;
        }
        for (bindings.items) |b| {
            var binding_flag_info: rhi.vulkan.vk.DescriptorSetLayoutBindingFlagsCreateInfo = .{ .binding_count = @intCast(b.binding_flags.items.len), .p_binding_flags = b.binding_flags.items.ptr };

            var create_layout_info: rhi.vulkan.vk.DescriptorSetLayoutCreateInfo = .{ .binding_count = @intCast(b.descriptor_bindings.items.len), .p_bindings = b.descriptor_bindings.items.ptr };
            vulkan.add_next(&create_layout_info, &binding_flag_info);
            //try vulkan.wrap_err(volk.c.vkCreateDescriptorSetLayout.?(device.backend.vk.device, &create_layout_info, null, &descriptor_set_layouts[b.register_index]));
            descriptor_set_layouts[b.register_index] = try dkb.createDescriptorSetLayout(device.backend.vk.device, &create_layout_info, null);
        }
        const pipeline_layout_create_info = rhi.vulkan.vk.PipelineLayoutCreateInfo{
            .p_set_layouts = descriptor_set_layouts.ptr,
            .set_layout_count = register_count,
        };
        //pipeline_layout_create_info.pSetLayouts = descriptor_set_layouts.ptr;
        //pipeline_layout_create_info.setLayoutCount = register_count;
        const pipeline_layout: rhi.vulkan.vk.PipelineLayout = try dkb.createPipelineLayout(device.backend.vk.device, &pipeline_layout_create_info, null);

        return .{ .backend = .{ .vk = .{ .layout = pipeline_layout } } };
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
    return error.UnsupportedRenderAPI;
}
