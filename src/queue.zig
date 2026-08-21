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
    wgpu: if (rhi.platform_has_api(.wgpu)) struct {
        queue: rhi.webgpu.Handle = .none,
    } else void,
    // GL has no queue object; the context is the queue.
    webgl: if (rhi.platform_has_api(.webgl)) struct {} else void,
},

pub fn submit(self: *Queue, device: *rhi.Device, options: struct {
    vk: ?if (rhi.platform_has_api(.vk)) struct {
        wait_semaphores: []const rhi.vulkan.vk.Semaphore = &.{},
        mask_wait_stages: []const rhi.vulkan.vk.PipelineStageFlags = &.{},
        signal_semaphores: []const rhi.vulkan.vk.Semaphore = &.{},
        cmds: []const *rhi.Cmd = &.{},
    } else void = null,
    dx12: ?if (rhi.platform_has_api(.dx12)) void else void = null,
    mtl: ?if (rhi.platform_has_api(.mtl)) void else void = null,
    // WebGPU submission carries no wait/signal semaphores: work submitted to a
    // queue is ordered against everything before it, and the browser presents
    // the canvas implicitly once the frame callback returns.
    wgpu: ?if (rhi.platform_has_api(.wgpu)) struct {
        cmds: []const *rhi.Cmd = &.{},
    } else void = null,
    // WebGL2 has no command buffer, so submitting means replaying what `Cmd`
    // recorded (see `webgl/command_list.zig`).
    webgl: ?if (rhi.platform_has_api(.webgl)) struct {
        cmds: []const *rhi.Cmd = &.{},
    } else void = null,
}) !void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        const vk = rhi.vulkan.vk;
        std.debug.assert(options.vk != null);
        const opts = options.vk.?;
        // The `*rhi.Cmd` entries are not contiguous, so gather their handles.
        var cbs: [8]vk.CommandBuffer = undefined;
        std.debug.assert(opts.cmds.len <= cbs.len);
        for (opts.cmds, 0..) |c, i| cbs[i] = c.backend.vk.cmd;
        var submit_infos = [_]vk.SubmitInfo{.{
            .s_type = .submit_info,
            .wait_semaphore_count = @intCast(opts.wait_semaphores.len),
            .p_wait_semaphores = if (opts.wait_semaphores.len > 0) opts.wait_semaphores.ptr else null,
            .p_wait_dst_stage_mask = if (opts.mask_wait_stages.len > 0) opts.mask_wait_stages.ptr else null,
            .command_buffer_count = @intCast(opts.cmds.len),
            .p_command_buffers = if (opts.cmds.len > 0) &cbs else null,
            .signal_semaphore_count = @intCast(opts.signal_semaphores.len),
            .p_signal_semaphores = if (opts.signal_semaphores.len > 0) opts.signal_semaphores.ptr else null,
        }};
        _ = try device.backend.vk.dkb.queueSubmit(self.backend.vk.queue, &submit_infos, .null_handle);
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        const wgpu = rhi.webgpu;
        std.debug.assert(options.wgpu != null);
        const opts = options.wgpu.?;
        // Shadow-buffer writes are flushed at bind time (see `Buffer.flush`), and
        // `queueWriteBuffer` is ordered against later submits on the same queue,
        // so there is nothing to reconcile here.
        // The `*rhi.Cmd` entries are not contiguous, so gather their handles.
        var bufs: [8]wgpu.Handle = undefined;
        std.debug.assert(opts.cmds.len <= bufs.len);
        for (opts.cmds, 0..) |c, i| bufs[i] = c.backend.wgpu.cmd_buffer;
        wgpu.wgpu_queue_submit(self.backend.wgpu.queue, &bufs, @intCast(opts.cmds.len));
        for (opts.cmds) |c| {
            wgpu.wgpu_release(c.backend.wgpu.cmd_buffer);
            c.backend.wgpu.cmd_buffer = .none;
        }
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        std.debug.assert(options.webgl != null);
        for (options.webgl.?.cmds) |c| {
            rhi.webgl.command_list.replay(&c.backend.webgl.recorder, device);
        }
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
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        // A browser frame cannot block on the GPU at all. Callers use this at
        // shutdown to make teardown safe; the browser already keeps submitted
        // resources alive until their work retires, so there is nothing to do.
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        // Unlike WebGPU, GL does expose a real flush-and-wait.
        rhi.webgl.gl_finish();
        return;
    }
    unreachable;
}
