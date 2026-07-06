// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const std = @import("std");
pub const Queue = @This();

backend: union {
    vk: if (rhi.platform_has_api(.vk))
        struct { queue_flags: rhi.vulkan.vk.QueueFlags = .{}, family_index: u32 = 0, slot_index: u32 = 0, queue: rhi.vulkan.vk.Queue = .null_handle }
    else
        void,
    dx12: if (rhi.platform_has_api(.dx12)) void else void,
    // Metal has a single device-level command queue; there is no separate
    // queue-family concept. Frame submission is driven by `Swapchain.frame_submit`.
    mtl: if (rhi.platform_has_api(.mtl)) struct {
        queue: rhi.metal.mtl.CommandQueue,
    } else void,
},

pub fn submit(self: *Queue, device: *rhi.Device, options: struct {
    vk: ?if (rhi.platform_has_api(.vk)) struct {
        wait_semaphores: []const rhi.vulkan.vk.Semaphore,
        mask_wait_stages: []const rhi.vulkan.vk.PipelineStageFlags,
        signal_semaphores: []const rhi.vulkan.vk.Semaphore,
        cmds: []const *rhi.Cmd,
    } else void,
    dx12: ?if (rhi.platform_has_api(.dx12)) void else void,
    mtl: ?if (rhi.platform_has_api(.mtl)) void else void,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        std.debug.assert(options.vk != null);
        var submit_infos = rhi.vulkan.vk.SubmitInfo{
            .s_type = .submit_info,
            .wait_semaphore_count = options.vk.?.wait_semaphores.len,
            .p_wait_semaphores = if (options.vk.?.wait_semaphores.len > 0) &options.vk.?.wait_semaphores[0] else null,
            .p_wait_dst_stage_mask = if (options.vk.?.mask_wait_stages.len > 0) &options.vk.?.mask_wait_stages[0] else null,
            .command_buffer_count = options.vk.?.cmds.len,
            .p_command_buffers = if (options.vk.?.cmds.len > 0) &options.vk.?.cmds[0].backend.vk.cmd else null,
            .signal_semaphore_count = options.vk.?.signal_semaphores.len,
            .p_signal_semaphores = if (options.vk.?.signal_semaphores.len > 0) &options.vk.?.signal_semaphores[0] else null,
        };
        _ = try device.backend.vk.dkb.queueSubmit(self.backend.vk.queue, 1, &submit_infos, null);
        return;
    }
    unreachable;
}

pub fn wait_queue_idle(self: *Queue, device: *rhi.Device) !void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        _ = try dkb.queueWaitIdle(self.backend.vk.queue);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        // On Metal, ordering/completion is tracked per command buffer (the
        // command ring waits on the last submitted buffer). A device-wide
        // queue wait is a no-op here.
        return;
    }
    unreachable;
}
