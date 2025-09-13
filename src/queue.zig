const rhi = @import("root.zig");
const std = @import("std");
pub const Queue = @This();
backend: union(rhi.Backend) {
    vk: rhi.wrapper_platform_type(.vk, struct { 
        queue_flags: rhi.vulkan.vk.QueueFlags = .{}, 
        family_index: u32 = 0, 
        slot_index: u32 = 0, 
        queue: rhi.vulkan.vk.Queue = .null_handle 
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
},

pub fn submit(self: *Queue, renderer: *rhi.Renderer, device: *rhi.Device, options: struct {
    vk: ?rhi.wrapper_platform_type(.vk, struct {
        wait_semaphores: []const rhi.vulkan.vk.Semaphore,
        mask_wait_stages: []const rhi.vulkan.vk.PipelineStageFlags,
        signal_semaphores: []const rhi.vulkan.vk.Semaphore,
        cmds: []const *rhi.Cmd,
    }),
    dx12: ?rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: ?rhi.wrapper_platform_type(.mtl, struct {}),
}) void {
    if (rhi.is_target_selected(.vk, renderer)) {
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
    }
}

pub fn wait_queue_idle(self: *Queue, renderer: *rhi.Renderer, device: *rhi.Device) !void {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        _ = try dkb.queueWaitIdle(self.backend.vk.queue);
    }
}
