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
    // A timeline is a monotonic counter plus a completion signal, and WebGPU has
    // both: `next`/`pending` are plain arithmetic on `signal_value`, and
    // `queue.onSubmittedWorkDone()` writes the value it was given back into
    // `completed_value` when the GPU catches up. Stored as two u32 halves so no
    // BigInt crosses the wasm boundary.
    wgpu: rhi.wrapper_platform_type(.wgpu, struct {
        completed_value: [2]u32 = .{ 0, 0 },
    }),
    // GL gives a real completion signal: a WebGLSync polled with a zero
    // timeout. `pending_syncs` holds one entry per in-flight submit, retired in
    // order by `completed`.
    webgl: rhi.wrapper_platform_type(.webgl, struct {
        pub const max_in_flight = 8;
        completed_value: u64 = 0,
        syncs: [max_in_flight]rhi.webgl.Handle = @splat(.none),
        values: [max_in_flight]u64 = @splat(0),
        count: u32 = 0,
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
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.is_target_selected(.wgpu)) {
        return .{
            .signal_value = 0,
            .backend = .{ .wgpu = .{} },
        };
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.is_target_selected(.webgl)) {
        return .{
            .signal_value = 0,
            .backend = .{ .webgl = .{} },
        };
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
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.is_target_selected(.wgpu)) {
        // Nothing was allocated: the counter lives in `signal_value` and the
        // completion halves are plain fields.
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.is_target_selected(.webgl)) {
        const w = &self.backend.webgl;
        for (w.syncs[0..w.count]) |sync| rhi.webgl.gl_delete_sync(sync);
        w.count = 0;
        return;
    }
}

/// Records a `WebGLSync` for the submit that just signalled `value`.
///
/// Called by `Swapchain.frame_submit`; there is no equivalent on the other
/// backends, where the submit itself carries the timeline value.
pub fn signal_webgl(self: *Timeline, value: u64) void {
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.is_target_selected(.webgl)) {
        const w = &self.backend.webgl;
        const sync = rhi.webgl.gl_fence_sync();
        if (sync.isNone()) {
            // Without a fence there is no way to observe completion; treating
            // the value as already reached keeps deferred release moving rather
            // than stalling it forever. It is the same optimism the Metal arm
            // takes, and safe for the same reason: GL keeps deleted objects
            // alive until the commands referencing them retire.
            w.completed_value = value;
            return;
        }
        if (w.count == w.syncs.len) {
            // The ring is full, which means the GPU is more than
            // `max_in_flight` frames behind. Retire the oldest optimistically
            // rather than leaking the sync.
            rhi.webgl.gl_delete_sync(w.syncs[0]);
            w.completed_value = w.values[0];
            std.mem.copyForwards(rhi.webgl.Handle, w.syncs[0 .. w.count - 1], w.syncs[1..w.count]);
            std.mem.copyForwards(u64, w.values[0 .. w.count - 1], w.values[1..w.count]);
            w.count -= 1;
        }
        w.syncs[w.count] = sync;
        w.values[w.count] = value;
        w.count += 1;
    }
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
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.is_target_selected(.webgl)) {
        // A real GPU completion signal, unlike the WebGPU arm's callback: poll
        // the oldest fences with a zero timeout and retire them in order.
        // `MAX_CLIENT_WAIT_TIMEOUT_WEBGL` is 0, so this can never block.
        const w = &@constCast(self).backend.webgl;
        var retired: u32 = 0;
        while (retired < w.count) : (retired += 1) {
            if (rhi.webgl.gl_client_wait_sync(w.syncs[retired]) == 0) break;
            rhi.webgl.gl_delete_sync(w.syncs[retired]);
            w.completed_value = w.values[retired];
        }
        if (retired > 0) {
            const remaining = w.count - retired;
            std.mem.copyForwards(rhi.webgl.Handle, w.syncs[0..remaining], w.syncs[retired..w.count]);
            std.mem.copyForwards(u64, w.values[0..remaining], w.values[retired..w.count]);
            w.count = remaining;
        }
        return w.completed_value;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.is_target_selected(.wgpu)) {
        // `Swapchain.frame_submit` registers a `queue.onSubmittedWorkDone()`
        // callback per submit; the glue writes the value it was handed back into
        // these two halves when the GPU catches up. Reads are non-blocking and
        // may lag `pending()` by several frames, which is exactly what deferred
        // release wants.
        return rhi.webgpu.join_u64(
            self.backend.wgpu.completed_value[0],
            self.backend.wgpu.completed_value[1],
        );
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
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.is_target_selected(.webgl)) {
        // `MAX_CLIENT_WAIT_TIMEOUT_WEBGL` is 0, so `clientWaitSync` cannot
        // block; poll `completed()` from the frame loop instead.
        return error.UnsupportedBackend;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.is_target_selected(.wgpu)) {
        // A browser frame cannot block on the GPU: the page would deadlock,
        // because the `onSubmittedWorkDone` callback that would advance this
        // timeline cannot run until the current task returns. Poll `completed()`
        // from the frame loop instead.
        return error.UnsupportedBackend;
    }
}
