const rhi = @import("root.zig");
const std = @import("std");
const vulkan = @import("root.zig").vulkan;

pub const Semaphore = @This();
backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct {
        semaphore: rhi.vulkan.vk.Semaphore = .null_handle,
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
} = undefined,

pub fn init(renderer: *rhi.Renderer, device: *rhi.Device) !Semaphore {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var add_info: rhi.vulkan.vk.SemaphoreCreateInfo = .{};
        const semaphore = try dkb.createSemaphore(device.backend.vk.device, &add_info, null);
        // zig fmt: off
        return .{ 
            .backend = .{ 
                .vk = .{ 
                    .semaphore = semaphore 
                } 
            } 
        };
        // zig fmt: on
    }
}
