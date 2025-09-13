const rhi = @import("root.zig");
const vma = @import("vma");
const std = @import("std");
const vulkan = @import("vulkan.zig");
const builtin = @import("builtin");

pub const Device = @This();
graphics_queue: rhi.Queue,
compute_queue: ?rhi.Queue,
transfer_queue: ?rhi.Queue,
adapter: rhi.PhysicalAdapter,
backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct {
        maintenance_5_feature_enabled: bool,
        conservative_raster_tier: bool,
        swapchain_mutable_format: bool,
        memory_budget: bool,
        device: rhi.vulkan.vk.Device,
        vma_allocator: vma.c.VmaAllocation,
        dkb: rhi.vulkan.vk.DeviceWrapper,
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
} = undefined,

fn supports_extension(extensions: [][*:0]const u8, value: []const u8) bool {
    for (extensions) |ext| {
        if (std.mem.eql(u8, std.mem.sliceTo(ext, 0), value)) {
            return true;
        }
    }
    return false;
}

pub fn init(allocator: std.mem.Allocator, renderer: *rhi.Renderer, adapter: *rhi.PhysicalAdapter) !Device {
    if (rhi.is_target_selected(.vk, renderer)) {
        const ikb: *rhi.vulkan.vk.InstanceWrapper = &renderer.backend.vk.ikb;
        const vkb: *rhi.vulkan.vk.BaseWrapper = &renderer.backend.vk.vkb;
        var extension_num: u32 = 0;
        _ = try renderer.backend.vk.ikb.enumerateDeviceExtensionProperties(adapter.backend.vk.physical_device, null, &extension_num, null);
        const extension_properties: []rhi.vulkan.vk.ExtensionProperties = try allocator.alloc(rhi.vulkan.vk.ExtensionProperties, extension_num);
        defer allocator.free(extension_properties);
        _ = try renderer.backend.vk.ikb.enumerateDeviceExtensionProperties(adapter.backend.vk.physical_device, null, &extension_num, extension_properties.ptr);
        var enabled_extension_names = std.ArrayList([*:0]const u8).empty;
        defer enabled_extension_names.deinit(allocator);

        for (vulkan.default_device_extensions) |default_ext| {
            if (vulkan.vk_has_extension(extension_properties, std.mem.sliceTo(default_ext, 0))) {
                try enabled_extension_names.append(allocator, default_ext);
            }
        }

        const queue_family_props = ret_props: {
            var familyNum: u32 = 0;
            renderer.backend.vk.ikb.getPhysicalDeviceQueueFamilyProperties(adapter.backend.vk.physical_device, &familyNum, null);
            const res: []rhi.vulkan.vk.QueueFamilyProperties = try allocator.alloc(rhi.vulkan.vk.QueueFamilyProperties, familyNum);
            renderer.backend.vk.ikb.getPhysicalDeviceQueueFamilyProperties(adapter.backend.vk.physical_device, &familyNum, res.ptr);
            break :ret_props res;
        };
        defer allocator.free(queue_family_props);

        var device_queue_create_info = std.ArrayList(rhi.vulkan.vk.DeviceQueueCreateInfo).empty;
        defer device_queue_create_info.deinit(allocator);
        const priorities = [_]f32{ 1.0, 0.9, 0.8, 0.7, 0.6, 0.5 };
        {
            var queue_buf: [16][]const u8 = undefined;
            var queue_feature = std.ArrayList([]const u8).initBuffer(&queue_buf);
            var i: usize = 0;
            while (i < queue_family_props.len) : (i += 1) {
                if (queue_family_props[i].queue_flags.graphics_bit)
                    queue_feature.appendAssumeCapacity("VK_QUEUE_GRAPHICS_BIT");
                if (queue_family_props[i].queue_flags.compute_bit)
                    queue_feature.appendAssumeCapacity("VK_QUEUE_COMPUTE_BIT");
                if (queue_family_props[i].queue_flags.transfer_bit)
                    queue_feature.appendAssumeCapacity("VK_QUEUE_TRANSFER_BIT");
                if (queue_family_props[i].queue_flags.sparse_binding_bit)
                    queue_feature.appendAssumeCapacity("VK_QUEUE_SPARSE_BINDING_BIT");
                if (queue_family_props[i].queue_flags.protected_bit)
                    queue_feature.appendAssumeCapacity("VK_QUEUE_PROTECTED_BIT");
                if (queue_family_props[i].queue_flags.video_decode_bit_khr)
                    queue_feature.appendAssumeCapacity("VK_QUEUE_VIDEO_DECODE_BIT_KHR");
                if (queue_family_props[i].queue_flags.video_encode_bit_khr)
                    queue_feature.appendAssumeCapacity("VK_QUEUE_VIDEO_ENCODE_BIT_KHR");
                if (queue_family_props[i].queue_flags.optical_flow_bit_nv)
                    queue_feature.appendAssumeCapacity("VK_QUEUE_OPTICAL_FLOW_BIT_NV");
                const features = try std.mem.join(allocator, ",", queue_feature.items);
                defer allocator.free(features);
                std.debug.print("Queue Family {d}: {s}\n", .{ i, features });
                queue_feature.clearRetainingCapacity();
            }
        }

        var rhi_queues: [3]?rhi.Queue = .{null} ** 3;
        const configured = [_]struct {
            required_bits: rhi.vulkan.vk.QueueFlags,
        }{
            .{ .required_bits = .{ .graphics_bit = true } },
            .{ .required_bits = .{ .compute_bit = true } },
            .{ .required_bits = .{ .transfer_bit = true } },
        };
        for (configured, 0..) |config, config_idx| {
            var min_queue_flags: u32 = std.math.maxInt(u32);
            var best_queue_family_idx: usize = 0;
            for (0..queue_family_props.len) |family_idx| {
                const queue_family_prop = &queue_family_props[family_idx];
                if (config_idx == 0 and queue_family_prop.queue_flags.contains(config.required_bits)) {
                    best_queue_family_idx = family_idx;
                    break;
                }

                const queue_create_info = p: {
                    for (device_queue_create_info.items) |item| {
                        if (item.queue_family_index == family_idx) {
                            break :p &item;
                        }
                    }
                    break :p null;
                };
                if (queue_family_prop.queue_count == 0) {
                    continue;
                }
                const matching_queue_flags: u32 = queue_family_prop.queue_flags.intersect(config.required_bits).toInt();
                // Example: Required flag is VK_QUEUE_TRANSFER_BIT and the queue family has only VK_QUEUE_TRANSFER_BIT set
                if ((matching_queue_flags > 0) and ((queue_family_props[family_idx].queue_flags.toInt() & ~config.required_bits.toInt()) == 0) and
                    (queue_family_props[family_idx].queue_count - (if (queue_create_info) |c| c.queue_count else 0)) > 0)
                {
                    best_queue_family_idx = family_idx;
                    break;
                }

                // Queue family 1 has VK_QUEUE_TRANSFER_BIT | VK_QUEUE_COMPUTE_BIT
                // Queue family 2 has VK_QUEUE_TRANSFER_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_SPARSE_BINDING_BIT
                // Since 1 has less flags, we choose queue family 1
                if ((matching_queue_flags > 0) and ((queue_family_props[family_idx].queue_flags.toInt() - matching_queue_flags) < min_queue_flags)) {
                    best_queue_family_idx = family_idx;
                    min_queue_flags = (queue_family_prop.queue_flags.toInt() - matching_queue_flags);
                }
            }

            var queue_create_info = p: {
                for (device_queue_create_info.items) |*item| {
                    if (item.queue_family_index == best_queue_family_idx) {
                        break :p item;
                    }
                }
                try device_queue_create_info.append(allocator, .{
                    .s_type = .device_queue_create_info,
                    .queue_family_index = @intCast(best_queue_family_idx),
                    .queue_count = 0,
                    .p_queue_priorities = &priorities,
                });
                break :p &device_queue_create_info.items[device_queue_create_info.items.len - 1];
            };
            // we've run out of queues in this family, try to find a duplicate queue from other families
            if (queue_create_info.queue_count >= queue_family_props[queue_create_info.queue_family_index].queue_count) {
                min_queue_flags = std.math.maxInt(u32);
                var dup_queue: ?*rhi.Queue = null;
                var i: usize = 0;
                while (i < rhi_queues.len) : (i += 1) {
                    if (rhi_queues[i]) |*eq| {
                        const matching_queue_flags = eq.backend.vk.queue_flags.intersect(config.required_bits);
                        if ((matching_queue_flags.toInt() > 0) and ((eq.backend.vk.queue_flags.toInt() & ~config.required_bits.toInt()) == 0)) {
                            dup_queue = eq;
                            break;
                        }

                        if ((matching_queue_flags.toInt() > 0) and ((eq.backend.vk.queue_flags.toInt() - matching_queue_flags.toInt()) < min_queue_flags)) {
                            min_queue_flags = (eq.backend.vk.queue_flags.toInt() - matching_queue_flags.toInt());
                            dup_queue = eq;
                        }
                    }
                }
                if (dup_queue) |d| {
                    rhi_queues[config_idx] = d.*;
                }
            } else {
                rhi_queues[config_idx] = rhi.Queue{
                    .backend = .{ .vk = .{
                        .queue_flags = queue_family_props[queue_create_info.queue_family_index].queue_flags,
                        .family_index = queue_create_info.queue_family_index,
                        .slot_index = queue_create_info.queue_count,
                    } },
                };
                queue_create_info.queue_count += 1;
            }
        }

        const has_maintenance_5 = supports_extension(enabled_extension_names.items, rhi.vulkan.vk.extensions.khr_maintenance_5.name);
        var features: rhi.vulkan.vk.PhysicalDeviceFeatures2 = .{
            .s_type = .physical_device_features_2,
            .features = std.mem.zeroes(rhi.vulkan.vk.PhysicalDeviceFeatures),
        };

        var features11: rhi.vulkan.vk.PhysicalDeviceVulkan11Features = .{ .s_type = .physical_device_vulkan_1_1_features };
        vulkan.add_next(&features, &features11);

        var features12: rhi.vulkan.vk.PhysicalDeviceVulkan12Features = .{ .s_type = .physical_device_vulkan_1_2_features };
        vulkan.add_next(&features, &features12);

        var features13: rhi.vulkan.vk.PhysicalDeviceVulkan13Features = .{ .s_type = .physical_device_vulkan_1_3_features };
        if (renderer.backend.vk.api_version >= @as(u32, @bitCast(rhi.vulkan.vk.API_VERSION_1_3))) {
            vulkan.add_next(&features, &features13);
        }

        var maintenance5Features: rhi.vulkan.vk.PhysicalDeviceMaintenance5FeaturesKHR = .{ .s_type = .physical_device_maintenance_5_features_khr };
        if (has_maintenance_5) {
            vulkan.add_next(&features, &maintenance5Features);
        }

        var presentIdFeatures: rhi.vulkan.vk.PhysicalDevicePresentIdFeaturesKHR = .{ .s_type = .physical_device_present_id_features_khr };
        if (supports_extension(enabled_extension_names.items, rhi.vulkan.vk.extensions.khr_present_id.name)) {
            vulkan.add_next(&features, &presentIdFeatures);
        }

        var presentWaitFeatures: rhi.vulkan.vk.PhysicalDevicePresentWaitFeaturesKHR = .{ .s_type = .physical_device_present_wait_features_khr };
        if (supports_extension(enabled_extension_names.items, rhi.vulkan.vk.extensions.khr_present_wait.name)) {
            vulkan.add_next(&features, &presentWaitFeatures);
        }

        var line_rasterization_features: rhi.vulkan.vk.PhysicalDeviceLineRasterizationFeaturesKHR = .{ .s_type = .physical_device_line_rasterization_features_khr };
        if (supports_extension(enabled_extension_names.items, rhi.vulkan.vk.extensions.khr_line_rasterization.name)) {
            vulkan.add_next(&features, &line_rasterization_features);
        }
        renderer.backend.vk.ikb.getPhysicalDeviceFeatures2(adapter.backend.vk.physical_device, &features);
        //renderer.backend.vk.ikb.dispatch.vkGetPhysicalDeviceFeatures2.?(adapter.backend.vk.physical_device, &features);
        var device_create_info: rhi.vulkan.vk.DeviceCreateInfo = .{ 
            .p_next = &features, 
            .p_queue_create_infos = device_queue_create_info.items.ptr, 
            .queue_create_info_count = @intCast(device_queue_create_info.items.len), 
            .pp_enabled_extension_names = enabled_extension_names.items.ptr, 
            .enabled_extension_count = @intCast(enabled_extension_names.items.len) 
        };
        const device: rhi.vulkan.vk.Device = try ikb.createDevice(adapter.backend.vk.physical_device, &device_create_info, null);
        const dkb = rhi.vulkan.vk.DeviceWrapper.load(device, ikb.dispatch.vkGetDeviceProcAddr.?);
        
        for(0..rhi_queues.len) |i| {
            if (rhi_queues[i]) |*q| {
                if (q.backend.vk.queue == .null_handle) {
                    q.backend.vk.queue = dkb.getDeviceQueue(device, q.backend.vk.family_index, q.backend.vk.slot_index);
                }
            }
        }

        const vma_allocator: vma.c.VmaAllocator = p: {
            const vulkan_func: vma.c.VmaVulkanFunctions = .{
                .vkGetPhysicalDeviceProperties = @ptrCast(ikb.dispatch.vkGetPhysicalDeviceProperties),
                .vkGetInstanceProcAddr = @ptrCast(vkb.dispatch.vkGetInstanceProcAddr),
                .vkGetDeviceProcAddr = @ptrCast(ikb.dispatch.vkGetDeviceProcAddr),
                .vkGetPhysicalDeviceMemoryProperties = @ptrCast(ikb.dispatch.vkGetPhysicalDeviceMemoryProperties),
                .vkAllocateMemory = @ptrCast(dkb.dispatch.vkAllocateMemory),
                .vkFreeMemory = @ptrCast(dkb.dispatch.vkFreeMemory),
                .vkMapMemory = @ptrCast(dkb.dispatch.vkMapMemory),
                .vkUnmapMemory = @ptrCast(dkb.dispatch.vkUnmapMemory),
                .vkFlushMappedMemoryRanges = @ptrCast(dkb.dispatch.vkFlushMappedMemoryRanges),
                .vkInvalidateMappedMemoryRanges = @ptrCast(dkb.dispatch.vkInvalidateMappedMemoryRanges),
                .vkBindBufferMemory = @ptrCast(dkb.dispatch.vkBindBufferMemory),
                .vkBindImageMemory = @ptrCast(dkb.dispatch.vkBindImageMemory),
                .vkGetBufferMemoryRequirements = @ptrCast(dkb.dispatch.vkGetBufferMemoryRequirements),
                .vkGetImageMemoryRequirements = @ptrCast(dkb.dispatch.vkGetImageMemoryRequirements),
                .vkCreateBuffer = @ptrCast(dkb.dispatch.vkCreateBuffer),
                .vkDestroyBuffer = @ptrCast(dkb.dispatch.vkDestroyBuffer),
                .vkCreateImage = @ptrCast(dkb.dispatch.vkCreateImage),
                .vkDestroyImage = @ptrCast(dkb.dispatch.vkDestroyImage),
                .vkCmdCopyBuffer = @ptrCast(dkb.dispatch.vkCmdCopyBuffer),
                // Fetch "vkGetBufferMemoryRequirements2" on Vulkan >= 1.1, fetch "vkGetBufferMemoryRequirements2KHR" when using VK_KHR_dedicated_allocation extension.
                .vkGetBufferMemoryRequirements2KHR = @ptrCast(dkb.dispatch.vkGetBufferMemoryRequirements2KHR),
                // Fetch "vkGetImageMemoryRequirements2" on Vulkan >= 1.1, fetch "vkGetImageMemoryRequirements2KHR" when using VK_KHR_dedicated_allocation extension.
                .vkGetImageMemoryRequirements2KHR = @ptrCast(dkb.dispatch.vkGetImageMemoryRequirements2KHR),
                // Fetch "vkBindBufferMemory2" on Vulkan >= 1.1, fetch "vkBindBufferMemory2KHR" when using VK_KHR_bind_memory2 extension.
                .vkBindBufferMemory2KHR = @ptrCast(dkb.dispatch.vkBindBufferMemory2KHR),
                // Fetch "vkBindImageMemory2" on Vulkan >= 1.1, fetch "vkBindImageMemory2KHR" when using VK_KHR_bind_memory2 extension.
                .vkBindImageMemory2KHR = @ptrCast(dkb.dispatch.vkBindImageMemory2KHR),
                // Fetch from "vkGetPhysicalDeviceMemoryProperties2" on Vulkan >= 1.1, but you can also fetch it from "vkGetPhysicalDeviceMemoryProperties2KHR" if you enabled extension
                // VK_KHR_get_physical_device_properties2.
                .vkGetPhysicalDeviceMemoryProperties2KHR = @ptrCast(ikb.dispatch.vkGetPhysicalDeviceMemoryProperties2KHR),
                // Fetch from "vkGetDeviceBufferMemoryRequirements" on Vulkan >= 1.3, but you can also fetch it from "vkGetDeviceBufferMemoryRequirementsKHR" if you enabled extension VK_KHR_maintenance4.
                .vkGetDeviceBufferMemoryRequirements = @ptrCast(dkb.dispatch.vkGetDeviceBufferMemoryRequirements),
                // Fetch from "vkGetDeviceImageMemoryRequirements" on Vulkan >= 1.3, but you can also fetch it from "vkGetDeviceImageMemoryRequirementsKHR" if you enabled extension VK_KHR_maintenance4.
                .vkGetDeviceImageMemoryRequirements = @ptrCast(dkb.dispatch.vkGetDeviceImageMemoryRequirements),
            };

            // zig fmt: off
            var vma_create_info: vma.c.VmaAllocatorCreateInfo = .{ 
                .physicalDevice = @ptrFromInt(@intFromEnum(adapter.backend.vk.physical_device)), 
                .device = @ptrFromInt(@intFromEnum(device)), 
                .flags = (if (adapter.backend.vk.is_buffer_device_address_supported) @as(u32, @intCast(vma.c.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT)) else 0) | 
                         (if (adapter.backend.vk.is_amd_device_coherent_memory_supported) @as(u32, @intCast(vma.c.VMA_ALLOCATOR_CREATE_AMD_DEVICE_COHERENT_MEMORY_BIT)) else 0), 
                .instance = @ptrFromInt(@intFromEnum(renderer.backend.vk.instance)), 
                .pVulkanFunctions = &vulkan_func, 
                .vulkanApiVersion = @bitCast(rhi.vulkan.vk.API_VERSION_1_3) 
            };
            // zig fmt: on
            var vma_allocator: vma.c.VmaAllocator = null;
            try rhi.vulkan.wrap_vk_result(@enumFromInt(vma.c.vmaCreateAllocator(&vma_create_info, &vma_allocator)));
            break :p vma_allocator;
        };

        return .{ 
            .graphics_queue = if (rhi_queues[0]) |q| q else return error.NoGraphicsQueue, 
            .compute_queue = rhi_queues[1], 
            .transfer_queue = rhi_queues[2], 
            .adapter = adapter.*, 
            .backend = .{ 
            .vk = .{
                    .maintenance_5_feature_enabled = has_maintenance_5,
                    .conservative_raster_tier = false,
                    .swapchain_mutable_format = false,
                    .memory_budget = false,
                    .dkb = dkb,
                    .device = device,
                    .vma_allocator = @ptrCast(vma_allocator), 
                } 
            } };
    }
    return error.Unitialized;
}

pub fn deinit(self: *Device, renderer: *rhi.Renderer) void {

    if (rhi.is_target_selected(.vk, renderer)) {
        vma.c.vmaDestroyAllocator(@ptrCast(self.backend.vk.vma_allocator));
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &self.backend.vk.dkb;
        dkb.destroyDevice(self.backend.vk.device, null);
        return;
    }
    unreachable;
}
