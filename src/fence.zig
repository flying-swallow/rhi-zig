const rhi = @import("root.zig");
const std = @import("std");
const vulkan = @import("vulkan.zig");

pub const Fence = @This();
backend: union {
    vk: if (rhi.platform_has_api(.vk)) struct {
        fence: rhi.vulkan.vk.Fence = .null_handle,
    } else void,
    dx12: if (rhi.platform_has_api(.dx12)) void else void,
    mtl: if (rhi.platform_has_api(.mtl)) void else void,
} = undefined,

pub const FenceStatus = enum {
    complete,
    incomplete,
};

//pub fn get_fence_status(comptime backend: rhi.Backend, device: *rhi.Device, fence: anytype) FenceStatus {
//    switch (backend) {
//        .vk => {
//            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
//            const status = try dkb.getFenceStatus(device.backend.vk.device, fence);
//            return switch (status) {
//                .success => .complete,
//                .not_ready => .incomplete,
//                else => unreachable, // should be unreachable due to wrap_err
//            };
//        },
//        _ => unreachable,
//    }
//}

pub fn init(renderer: *rhi.Renderer, device: *rhi.Device, signaled: bool) !Fence {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var create_info: rhi.vulkan.vk.FenceCreateInfo = .{
            .flags = if (signaled) .{ .signaled_bit = true } else .{},
        };
        const fence = try dkb.createFence(device.backend.vk.device, &create_info, null);
        return .{ .backend = .{ .vk = .{
            .fence = fence,
        } } };
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
    return error.UnsupportedBackend;
}

pub fn wait_for_fences(comptime reserve: usize, device: *rhi.Device, renderer: *rhi.Renderer, fences: []const *Fence) !void {
    if (rhi.is_target_selected(.vk, renderer)) {
        std.debug.assert(fences.len <= reserve);
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var vk_fences: [reserve]rhi.vulkan.vk.Fence = undefined;
        for (fences, 0..) |fence, i| {
            vk_fences[i] = fence.backend.vk.fence;
        }
        _ = try dkb.waitForFences(device.backend.vk.device, fences.len, vk_fences.ptr, .true, std.math.maxInt(u64));
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
}

pub fn wait_for_fences_alloc(allocator: std.mem.Allocator, device: *rhi.Device, renderer: *rhi.Renderer, fences: []const *Fence) void {
    if (rhi.is_target_selected(.vk, renderer)) {
        var vk_fences = try allocator.alloc(rhi.vulkan.vk.Fence, fences.len);
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        defer allocator.free(vk_fences);
        for (fences, 0..) |fence, i| {
            vk_fences[i] = fence.backend.vk.fence;
        }
        _ = try dkb.waitForFences(device.backend.vk.device, vk_fences.len, vk_fences.ptr, .true, std.math.maxInt(u64));
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
}

//pub fn get_fence_status(self: *Fence, device: *rhi.Device, renderer: *rhi.Renderer) !FenceStatus {
//    if (rhi.is_target_selected(.vk, renderer)) {
//        const status = volk.c.vkGetFenceStatus.?(device.backend.vk.device, self.backend.vk.fence);
//        return switch (status) {
//            volk.c.VK_SUCCESS => .complete,
//            volk.c.VK_NOT_READY => .incomplete,
//            else => unreachable, // should be unreachable due to wrap_err
//        };
//    } else if (rhi.is_target_selected(.dx12, renderer)) {
//    } else if (rhi.is_target_selected(.mtl, renderer)) {
//    }
//    return error.UnsupportedBackend;
//}
