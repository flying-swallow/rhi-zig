// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

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
    // WebGPU orders work within a queue implicitly; there is no cross-submit
    // semaphore to create.
    wgpu: rhi.wrapper_platform_type(.wgpu, struct {}),
    webgl: rhi.wrapper_platform_type(.webgl, struct {}),
} = undefined,

pub fn init(device: *rhi.Device) !Semaphore {
    if (rhi.is_target_selected(.vk)) {
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
    if (rhi.is_target_selected(.webgl)) {
        // Same as WebGPU: GL orders work within a context, and a browser frame
        // cannot wait on the GPU. The object exists so the command ring and
        // swapchain keep their backend-neutral shape.
        return .{ .backend = .{ .webgl = .{} } };
    }
    if (rhi.is_target_selected(.wgpu)) {
        // Nothing to create: work submitted to a WebGPU queue is ordered
        // against everything submitted before it, and a browser frame has no
        // way to wait on the GPU anyway. The handle exists so the command ring
        // and swapchain can keep their backend-neutral shape.
        return .{ .backend = .{ .wgpu = .{} } };
    }
    return error.UnsupportedBackend;
}
