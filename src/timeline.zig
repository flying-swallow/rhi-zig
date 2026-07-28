// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const std = @import("std");

pub const Timeline = @This();

// CPU-side monotonic counter; mirrors the value last handed to a GPU submit.
signal_value: u64 = 0,
backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct {
        semaphore: rhi.vulkan.vk.Semaphore = .null_handle,
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
    webgpu: rhi.wrapper_platform_type(.webgpu, struct {
        completed_value: std.atomic.Value(u64) = .init(0),
    }),
} = undefined,

pub fn init(device: *rhi.Device) !Timeline {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
        const dkb = &device.backend.vk.dkb;
        const vk_device = device.backend.vk.device;

        var timeline_info = rhi.vulkan.vk.SemaphoreTypeCreateInfo{
            .semaphore_type = .timeline,
            .initial_value = 0,
        };
        var create_info = rhi.vulkan.vk.SemaphoreCreateInfo{};
        rhi.vulkan.add_next(&create_info, &timeline_info);
        const semaphore = try dkb.createSemaphore(vk_device, &create_info, null);
        return .{
            .signal_value = 0,
            .backend = .{ .vk = .{ .semaphore = semaphore } },
        };
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.is_target_selected(.mtl)) {
        return .{
            .signal_value = 0,
            .backend = .{ .mtl = .{} },
        };
    }
    if ((comptime rhi.platform_has_api(.webgpu)) and rhi.is_target_selected(.webgpu)) {
        return .{ .signal_value = 0, .backend = .{ .webgpu = .{} } };
    }
    return error.UnsupportedBackend;
}

pub fn deinit(self: *Timeline, device: *rhi.Device) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
        const dkb = &device.backend.vk.dkb;
        dkb.destroySemaphore(device.backend.vk.device, self.backend.vk.semaphore, null);
        self.backend.vk.semaphore = .null_handle;
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.is_target_selected(.mtl)) {
        return;
    }
    if ((comptime rhi.platform_has_api(.webgpu)) and rhi.is_target_selected(.webgpu)) return;
}

// Reserve the next signal value. Call immediately before the submit that signals it.
pub fn next(self: *Timeline) u64 {
    self.signal_value += 1;
    return self.signal_value;
}

// The highest value handed out by next() — i.e. the latest in-flight submit.
pub fn pending(self: *const Timeline) u64 {
    return self.signal_value;
}

// Query how far the GPU has actually progressed. Non-blocking; poll this in the frame loop.
pub fn completed(self: *const Timeline, device: *rhi.Device) !u64 {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
        const dkb = &device.backend.vk.dkb;
        return try dkb.getSemaphoreCounterValue(device.backend.vk.device, self.backend.vk.semaphore);
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.is_target_selected(.mtl)) {
        return self.signal_value;
    }
    if ((comptime rhi.platform_has_api(.webgpu)) and rhi.is_target_selected(.webgpu)) {
        rhi.renderer.processEvents();
        return self.signal_value;
    }
    return error.UnsupportedBackend;
}

// Block until the GPU reaches value. Use at shutdown only; prefer polling completed() in the frame loop.
pub fn wait(self: *const Timeline, device: *rhi.Device, value: u64) !void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
        const dkb = &device.backend.vk.dkb;
        const wait_info = rhi.vulkan.vk.SemaphoreWaitInfo{
            .semaphore_count = 1,
            .p_semaphores = &self.backend.vk.semaphore,
            .p_values = &value,
        };
        _ = try dkb.waitSemaphores(device.backend.vk.device, &wait_info, std.math.maxInt(u64));
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.is_target_selected(.mtl)) {
        return;
    }
    if ((comptime rhi.platform_has_api(.webgpu)) and rhi.is_target_selected(.webgpu)) {
        rhi.renderer.processEvents();
        return;
    }
}
