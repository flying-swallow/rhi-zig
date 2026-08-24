// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const vulkan = @import("root.zig").vulkan;
const std = @import("std");

pub const Pool = struct {
    pub const Self = @This();
    backend: union {
        vk: if (rhi.platform_has_api(.vk))
            struct {
                queue: *rhi.Queue,
                pool: rhi.vulkan.vk.CommandPool,
            }
        else
            void,
        dx12: if (rhi.platform_has_api(.dx12)) void else void,
        mtl: void, // Metal does not use command pools
        wgpu: void, // Neither does WebGPU: encoders are created per frame
        webgl: void, // Nor WebGL2, which has no command object at all
    },

    pub fn reset(self: *Self, device: *rhi.Device) !void {
        if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            try dkb.resetCommandPool(device.backend.vk.device, self.backend.vk.pool, .{});
            return;
        }
        if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
            // Metal has no command pools; command buffers are transient.
            return;
        }
        if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
            // Same on WebGPU: a GPUCommandEncoder is created and consumed within
            // a frame, so there is no pool storage to reset.
            return;
        }
        if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
            // The recorder is reset by `Cmd.begin`, which owns it.
            return;
        }
        unreachable;
    }

    pub fn deinit(self: *Self, device: *rhi.Device) void {
        if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            dkb.destroyCommandPool(device.backend.vk.device, self.backend.vk.pool, null);
            return;
        }
        if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
            return;
        }
        if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
            return;
        }
        if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
            return;
        }
        unreachable;
    }

    pub fn init(device: *rhi.Device, queue: *rhi.Queue) !Self {
        if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            var cmd_pool_create_info = rhi.vulkan.vk.CommandPoolCreateInfo{
                .flags = .{
                    .reset_command_buffer = true,
                },
                .queue_family_index = queue.backend.vk.family_index,
            };
            const pool: rhi.vulkan.vk.CommandPool = try dkb.createCommandPool(device.backend.vk.device, &cmd_pool_create_info, null);
            return .{ .backend = .{ .vk = .{
                .queue = queue,
                .pool = pool,
            } } };
        }
        if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
            return .{ .backend = .{ .mtl = {} } };
        }
        if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
            return .{ .backend = .{ .wgpu = {} } };
        }
        if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
            return .{ .backend = .{ .webgl = {} } };
        }
        return error.UnsupportedBackend;
    }
};

pub const CommandRingElement = struct {
    pub const Self = @This();
    cmds: []rhi.Cmd,
    pool: *rhi.Pool,
    backend: union {
        vk: if (rhi.platform_has_api(.vk)) struct {
            semaphore: rhi.vulkan.vk.Semaphore = .null_handle,
            fence: rhi.vulkan.vk.Fence = .null_handle,
        } else void,
        dx12: if (rhi.platform_has_api(.dx12)) void else void,
        mtl: if (rhi.platform_has_api(.mtl)) void else void,
        wgpu: if (rhi.platform_has_api(.wgpu)) void else void,
        webgl: if (rhi.platform_has_api(.webgl)) void else void,
    },

    pub fn wait(self: *Self, device: *rhi.Device) !void {
        if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            var fences = [_]rhi.vulkan.vk.Fence{self.backend.vk.fence};
            _ = try dkb.waitForFences(device.backend.vk.device, fences[0..], .true, std.math.maxInt(u64));
            return;
        }
        if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
            // CPU/GPU frame pacing on Metal is provided implicitly by
            // CAMetalLayer.nextDrawable, which blocks once the maximum number of
            // drawables is in flight. (An MTLSharedEvent could give finer-grained
            // overlap later.)
            return;
        }
        if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
            // A browser frame cannot block on the GPU, and it does not need to:
            // the page renders one frame per requestAnimationFrame callback, and
            // the browser keeps every submitted resource alive until its work
            // retires. Frame pacing is the compositor's job.
            return;
        }
        if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
            // Same reasoning as WebGPU: a page cannot block on the GPU
            // (`MAX_CLIENT_WAIT_TIMEOUT_WEBGL` is 0), and GL keeps deleted
            // objects alive until the commands referencing them retire.
            return;
        }
        unreachable;
    }
};

pub fn CommandRingBuffer(
    comptime options: struct {
        pool_count: usize, // number of command buffers in the ring
        cmd_per_pool: usize = 1, // number of command buffers per pool
        sync_primative: bool = false,
    },
) type {
    return struct {
        pub const Self = @This();
        pool_index: usize,
        cmd_index: usize,
        fence_index: usize,
        pools: [options.pool_count]rhi.Pool,
        cmds: [options.pool_count][options.cmd_per_pool]rhi.Cmd,
        backend: union {
            vk: if (rhi.platform_has_api(.vk)) struct {
                fences: if (options.sync_primative) [options.pool_count][options.cmd_per_pool]rhi.vulkan.vk.Fence else void,
                semaphores: if (options.sync_primative) [options.pool_count][options.cmd_per_pool]rhi.vulkan.vk.Semaphore else void,
            } else void,
            dx12: if (rhi.platform_has_api(.dx12)) void else void,
            mtl: if (rhi.platform_has_api(.mtl)) void else void,
            // `sync_primative` is honored by allocating nothing: WebGPU has no
            // fence or semaphore object for the ring to hand out.
            wgpu: if (rhi.platform_has_api(.wgpu)) void else void,
            webgl: if (rhi.platform_has_api(.webgl)) void else void,
        },
        pub fn advance(self: *Self) void {
            self.pool_index = (self.pool_index + 1) % options.pool_count;
            self.cmd_index = 0;
            self.fence_index = 0;
        }
        pub fn get(self: *Self, device: *rhi.Device, num_cmds: usize) CommandRingElement {
            _ = device; // kept for a uniform (renderer, device) calling convention
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                std.debug.assert(num_cmds <= options.cmd_per_pool);
                std.debug.assert(num_cmds + self.cmd_index <= options.cmd_per_pool);
                const result = CommandRingElement{ .cmds = self.cmds[self.pool_index][self.cmd_index .. self.cmd_index + num_cmds], .pool = &self.pools[self.pool_index], .backend = .{ .vk = .{
                    .semaphore = if (options.sync_primative) self.backend.vk.semaphores[self.pool_index][self.fence_index] else null,
                    .fence = if (options.sync_primative) self.backend.vk.fences[self.pool_index][self.fence_index] else null,
                } } };
                self.fence_index += 1;
                self.cmd_index += num_cmds;
                return result;
            }
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                std.debug.assert(num_cmds <= options.cmd_per_pool);
                std.debug.assert(num_cmds + self.cmd_index <= options.cmd_per_pool);
                const result = CommandRingElement{
                    .cmds = self.cmds[self.pool_index][self.cmd_index .. self.cmd_index + num_cmds],
                    .pool = &self.pools[self.pool_index],
                    .backend = .{ .mtl = {} },
                };
                self.fence_index += 1;
                self.cmd_index += num_cmds;
                return result;
            }
            if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
                std.debug.assert(num_cmds <= options.cmd_per_pool);
                std.debug.assert(num_cmds + self.cmd_index <= options.cmd_per_pool);
                const result = CommandRingElement{
                    .cmds = self.cmds[self.pool_index][self.cmd_index .. self.cmd_index + num_cmds],
                    .pool = &self.pools[self.pool_index],
                    .backend = .{ .wgpu = {} },
                };
                self.fence_index += 1;
                self.cmd_index += num_cmds;
                return result;
            }
            if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
                std.debug.assert(num_cmds <= options.cmd_per_pool);
                std.debug.assert(num_cmds + self.cmd_index <= options.cmd_per_pool);
                const result = CommandRingElement{
                    .cmds = self.cmds[self.pool_index][self.cmd_index .. self.cmd_index + num_cmds],
                    .pool = &self.pools[self.pool_index],
                    .backend = .{ .webgl = {} },
                };
                self.fence_index += 1;
                self.cmd_index += num_cmds;
                return result;
            }
            unreachable;
        }
        pub fn init(device: *rhi.Device, queue: *rhi.Queue) !Self {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                var cmds: [options.pool_count][options.cmd_per_pool]rhi.Cmd = undefined;
                var pools: [options.pool_count]rhi.Pool = undefined;
                var semaphores: if (options.sync_primative) [options.pool_count][options.cmd_per_pool]rhi.vulkan.vk.Semaphore else void = undefined;
                var fences: if (options.sync_primative) [options.pool_count][options.cmd_per_pool]rhi.vulkan.vk.Fence else void = undefined;
                for (0..options.pool_count) |pool_index| {
                    pools[pool_index] = try rhi.Pool.init(device, queue);
                    for (0..options.cmd_per_pool) |cmd_index| {
                        cmds[pool_index][cmd_index] = try rhi.Cmd.init(device, &pools[pool_index]);
                        if (options.sync_primative) {
                            var semaphore_create_info = rhi.vulkan.vk.SemaphoreCreateInfo{ .s_type = .semaphore_create_info };
                            semaphores[pool_index][cmd_index] = try dkb.createSemaphore(device.backend.vk.device, &semaphore_create_info, null);

                            var fence_create_info = rhi.vulkan.vk.FenceCreateInfo{ .s_type = .fence_create_info, .flags = .{ .signaled = true } };
                            fences[pool_index][cmd_index] = try dkb.createFence(
                                device.backend.vk.device,
                                &fence_create_info,
                                null,
                            );
                        }
                    }
                }
                return .{ .pool_index = options.pool_count, .cmd_index = 0, .fence_index = 0, .cmds = cmds, .pools = pools, .backend = .{ .vk = .{
                    .semaphores = semaphores,
                    .fences = fences,
                } } };
            }
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                var cmds: [options.pool_count][options.cmd_per_pool]rhi.Cmd = undefined;
                var pools: [options.pool_count]rhi.Pool = undefined;
                for (0..options.pool_count) |pool_index| {
                    pools[pool_index] = try rhi.Pool.init(device, queue);
                    for (0..options.cmd_per_pool) |cmd_index| {
                        cmds[pool_index][cmd_index] = try rhi.Cmd.init(device, &pools[pool_index]);
                    }
                }
                return .{ .pool_index = options.pool_count, .cmd_index = 0, .fence_index = 0, .cmds = cmds, .pools = pools, .backend = .{ .mtl = {} } };
            }
            if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
                var cmds: [options.pool_count][options.cmd_per_pool]rhi.Cmd = undefined;
                var pools: [options.pool_count]rhi.Pool = undefined;
                for (0..options.pool_count) |pool_index| {
                    pools[pool_index] = try rhi.Pool.init(device, queue);
                    for (0..options.cmd_per_pool) |cmd_index| {
                        cmds[pool_index][cmd_index] = try rhi.Cmd.init(device, &pools[pool_index]);
                    }
                }
                return .{ .pool_index = options.pool_count, .cmd_index = 0, .fence_index = 0, .cmds = cmds, .pools = pools, .backend = .{ .wgpu = {} } };
            }
            if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
                var cmds: [options.pool_count][options.cmd_per_pool]rhi.Cmd = undefined;
                var pools: [options.pool_count]rhi.Pool = undefined;
                for (0..options.pool_count) |pool_index| {
                    pools[pool_index] = try rhi.Pool.init(device, queue);
                    for (0..options.cmd_per_pool) |cmd_index| {
                        cmds[pool_index][cmd_index] = try rhi.Cmd.init(device, &pools[pool_index]);
                    }
                }
                return .{ .pool_index = options.pool_count, .cmd_index = 0, .fence_index = 0, .cmds = cmds, .pools = pools, .backend = .{ .webgl = {} } };
            }

            unreachable; // should never reach here
        }

        pub fn deinit(self: *Self, device: *rhi.Device) void {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                for (0..options.pool_count) |pool_index| {
                    if (options.sync_primative) {
                        for (0..options.cmd_per_pool) |cmd_index| {
                            dkb.destroySemaphore(device.backend.vk.device, self.backend.vk.semaphores[pool_index][cmd_index], null);
                            dkb.destroyFence(device.backend.vk.device, self.backend.vk.fences[pool_index][cmd_index], null);
                        }
                    }
                    for (0..options.cmd_per_pool) |cmd_index| {
                        self.cmds[pool_index][cmd_index].deinit(device, &self.pools[pool_index]);
                    }
                    dkb.destroyCommandPool(device.backend.vk.device, self.pools[pool_index].backend.vk.pool, null);
                }
                return;
            }
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                for (0..options.pool_count) |pool_index| {
                    for (0..options.cmd_per_pool) |cmd_index| {
                        self.cmds[pool_index][cmd_index].deinit(device, &self.pools[pool_index]);
                    }
                }
                return;
            }
            if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
                for (0..options.pool_count) |pool_index| {
                    for (0..options.cmd_per_pool) |cmd_index| {
                        self.cmds[pool_index][cmd_index].deinit(device, &self.pools[pool_index]);
                    }
                }
                return;
            }
            if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
                for (0..options.pool_count) |pool_index| {
                    for (0..options.cmd_per_pool) |cmd_index| {
                        self.cmds[pool_index][cmd_index].deinit(device, &self.pools[pool_index]);
                    }
                }
                return;
            }
            unreachable;
        }
    };
}

pub const Cmd = @This();
backend: union {
    vk: if (rhi.platform_has_api(.vk)) struct {
        cmd: rhi.vulkan.vk.CommandBuffer,
    } else void,
    dx12: if (rhi.platform_has_api(.dx12)) void else void,
    // Metal command buffers are created per-frame from the queue. The live
    // render encoder (between begin_rendering/end_rendering) is held here too.
    mtl: if (rhi.platform_has_api(.mtl)) struct {
        queue: rhi.metal.mtl.CommandQueue,
        cmd: ?rhi.metal.mtl.CommandBuffer = null,
        encoder: ?rhi.metal.mtl.RenderCommandEncoder = null,
        index_buffer: ?rhi.metal.mtl.Buffer = null,
        index_type: rhi.metal.types.IndexType = .uint16,
    } else void,
    // WebGPU splits recording in two: copies and pass creation go to the
    // GPUCommandEncoder, while draw state goes to the GPURenderPassEncoder that
    // `begin_rendering` opens. Both are held here, plus the GPUCommandBuffer
    // that `end` produces and `Queue.submit` consumes.
    wgpu: if (rhi.platform_has_api(.wgpu)) struct {
        device: rhi.webgpu.Handle = .none,
        queue: rhi.webgpu.Handle = .none,
        encoder: rhi.webgpu.Handle = .none,
        pass: rhi.webgpu.Handle = .none,
        cmd_buffer: rhi.webgpu.Handle = .none,
        /// Bound by `bind_pipeline` so `set_push_constants` can reach the
        /// uniform buffer standing in for push constants.
        pipeline: ?*rhi.Pipeline = null,
    } else void,
    // WebGL2 has no command buffer, so recording means appending to a list that
    // `Queue.submit` replays. See `webgl/command_list.zig` for why this is
    // deferred rather than issued inline.
    webgl: if (rhi.platform_has_api(.webgl)) struct {
        recorder: rhi.webgl.command_list.Recorder,
    } else void,
},

pub fn init(device: *rhi.Device, pool: *Pool) !Cmd {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var command_allocate_info = rhi.vulkan.vk.CommandBufferAllocateInfo{
            .command_pool = pool.backend.vk.pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        var command: [1]rhi.vulkan.vk.CommandBuffer = undefined;
        try dkb.allocateCommandBuffers(device.backend.vk.device, &command_allocate_info, command[0..].ptr);
        return .{ .backend = .{ .vk = .{
            .cmd = command[0],
        } } };
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        return .{ .backend = .{ .mtl = .{ .queue = device.backend.mtl.queue } } };
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        return .{ .backend = .{ .wgpu = .{
            .device = device.backend.wgpu.device,
            .queue = device.backend.wgpu.queue,
        } } };
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        return .{ .backend = .{ .webgl = .{
            .recorder = rhi.webgl.command_list.Recorder.init(device.backend.webgl.allocator),
        } } };
    }
    unreachable;
}

pub fn deinit(self: *Cmd, device: *rhi.Device, pool: *Pool) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var command = [_]rhi.vulkan.vk.CommandBuffer{
            self.backend.vk.cmd,
        };
        dkb.freeCommandBuffers(device.backend.vk.device, pool.backend.vk.pool, command[0..]);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        // An encoder or command buffer still live at teardown was never
        // submitted; drop it so the JS handle table does not leak the entry.
        rhi.webgpu.wgpu_release(self.backend.wgpu.pass);
        rhi.webgpu.wgpu_release(self.backend.wgpu.encoder);
        rhi.webgpu.wgpu_release(self.backend.wgpu.cmd_buffer);
        self.backend.wgpu.pass = .none;
        self.backend.wgpu.encoder = .none;
        self.backend.wgpu.cmd_buffer = .none;
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        self.backend.webgl.recorder.deinit();
        return;
    }
    unreachable;
}

pub fn begin(self: *Cmd, device: *rhi.Device) !void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var begin_info = rhi.vulkan.vk.CommandBufferBeginInfo{
            .s_type = .command_buffer_begin_info,
            .flags = .{
                .one_time_submit = true,
            },
        };
        try dkb.beginCommandBuffer(self.backend.vk.cmd, &begin_info);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.cmd = self.backend.mtl.queue.commandBuffer() orelse return error.MetalCommandBufferFailed;
        self.backend.mtl.encoder = null;
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        const wgpu = rhi.webgpu;
        // A GPUCommandEncoder is single-use: it is consumed by `finish()`, so a
        // fresh one is created per frame rather than reset like a Vulkan pool.
        const encoder = wgpu.wgpu_device_create_command_encoder(self.backend.wgpu.device);
        if (encoder.isNone()) return error.WebGPUCommandEncoderFailed;
        self.backend.wgpu.encoder = encoder;
        self.backend.wgpu.pass = .none;
        self.backend.wgpu.pipeline = null;
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        self.backend.webgl.recorder.reset();
        return;
    }
    unreachable;
}

pub fn end(self: *Cmd, device: *rhi.Device) !void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        try dkb.endCommandBuffer(self.backend.vk.cmd);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        // Commit happens in Swapchain.frame_submit.
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        const wgpu = rhi.webgpu;
        std.debug.assert(self.backend.wgpu.pass.isNone()); // end_rendering not called
        const buf = wgpu.wgpu_command_encoder_finish(self.backend.wgpu.encoder);
        if (buf.isNone()) return error.WebGPUCommandEncoderFinishFailed;
        // `finish()` consumes the encoder.
        wgpu.wgpu_release(self.backend.wgpu.encoder);
        self.backend.wgpu.encoder = .none;
        self.backend.wgpu.cmd_buffer = buf;
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        // Recording is complete; `Queue.submit` replays it. Nothing to close.
        std.debug.assert(!self.backend.webgl.recorder.pass_open); // end_rendering not called
        return;
    }
    unreachable;
}

// -- Backend-agnostic render command API -----------------------------------
//
// These mirror what the examples used to record inline against raw Vulkan, but
// dispatch to either backend. On Vulkan they reproduce the previous behavior
// exactly; on Metal they drive the live MTLRenderCommandEncoder, and barriers
// become no-ops (the render pass load/store actions handle transitions).

pub const LoadOp = enum { load, clear, dont_care };
pub const StoreOp = enum { store, dont_care };

pub const Rect = struct { x: i32 = 0, y: i32 = 0, width: u32, height: u32 };

pub const Viewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub const ColorAttachment = struct {
    view: rhi.ImageView,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },
};

pub const DepthAttachment = struct {
    view: rhi.ImageView,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_depth: f32 = 1.0,
};

pub fn begin_rendering(self: *Cmd, device: *rhi.Device, options: struct {
    color_attachments: []const ColorAttachment,
    render_area: Rect,
    depth_attachment: ?DepthAttachment = null,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var vk_attachments: [8]rhi.vulkan.vk.RenderingAttachmentInfo = undefined;
        for (options.color_attachments, 0..) |att, i| {
            vk_attachments[i] = .{
                .image_view = att.view.backend.vk,
                .image_layout = .color_attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = switch (att.load_op) {
                    .load => .load,
                    .clear => .clear,
                    .dont_care => .dont_care,
                },
                .store_op = switch (att.store_op) {
                    .store => .store,
                    .dont_care => .dont_care,
                },
                .clear_value = .{ .color = .{ .float_32 = att.clear_color } },
            };
        }
        var info = rhi.vulkan.vk.RenderingInfo{
            .render_area = .{
                .offset = .{ .x = options.render_area.x, .y = options.render_area.y },
                .extent = .{ .width = options.render_area.width, .height = options.render_area.height },
            },
            .view_mask = 0,
            .layer_count = 1,
            .color_attachment_count = @intCast(options.color_attachments.len),
            .p_color_attachments = vk_attachments[0..].ptr,
        };
        var depth_att: rhi.vulkan.vk.RenderingAttachmentInfo = undefined;
        if (options.depth_attachment) |da| {
            depth_att = .{
                .image_view = da.view.backend.vk,
                .image_layout = .depth_attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = switch (da.load_op) {
                    .load => .load,
                    .clear => .clear,
                    .dont_care => .dont_care,
                },
                .store_op = switch (da.store_op) {
                    .store => .store,
                    .dont_care => .dont_care,
                },
                .clear_value = .{ .depth_stencil = .{ .depth = da.clear_depth, .stencil = 0 } },
            };
            info.p_depth_attachment = &depth_att;
        }
        dkb.cmdBeginRendering(self.backend.vk.cmd, &info);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        const desc = rhi.metal.mtl.RenderPassDescriptor.renderPassDescriptor();
        for (options.color_attachments, 0..) |att, i| {
            const ca = desc.colorAttachments().object(@intCast(i));
            ca.setTexture(att.view.mtl);
            ca.setLoadAction(switch (att.load_op) {
                .load => .load,
                .clear => .clear,
                .dont_care => .dont_care,
            });
            ca.setStoreAction(switch (att.store_op) {
                .store => .store,
                .dont_care => .dont_care,
            });
            ca.setClearColor(.{ .red = att.clear_color[0], .green = att.clear_color[1], .blue = att.clear_color[2], .alpha = att.clear_color[3] });
        }
        if (options.depth_attachment) |da| {
            const d = desc.depthAttachment();
            d.setTexture(da.view.mtl);
            d.setLoadAction(switch (da.load_op) {
                .load => .load,
                .clear => .clear,
                .dont_care => .dont_care,
            });
            d.setStoreAction(switch (da.store_op) {
                .store => .store,
                .dont_care => .dont_care,
            });
            d.setClearDepth(da.clear_depth);
        }
        self.backend.mtl.encoder = self.backend.mtl.cmd.?.renderCommandEncoder(desc) orelse unreachable;
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        const wgpu = rhi.webgpu;
        // WebGPU render passes take exactly the attachments given here; there is
        // no render area, so `render_area` only informs the default viewport,
        // which the browser already derives from the attachment size.
        std.debug.assert(options.color_attachments.len == 1); // WebGPU MRT is not wired up yet
        const color = options.color_attachments[0];
        const depth: rhi.webgpu.Handle = if (options.depth_attachment) |da| da.view.backend.wgpu else .none;
        const pass = wgpu.wgpu_command_encoder_begin_render_pass(
            self.backend.wgpu.encoder,
            color.view.backend.wgpu,
            wgpu.to_wgpu_load_op(color.load_op),
            wgpu.to_wgpu_store_op(color.store_op),
            color.clear_color[0],
            color.clear_color[1],
            color.clear_color[2],
            color.clear_color[3],
            depth,
            if (options.depth_attachment) |da| wgpu.to_wgpu_load_op(da.load_op) else .clear,
            if (options.depth_attachment) |da| wgpu.to_wgpu_store_op(da.store_op) else .store,
            if (options.depth_attachment) |da| da.clear_depth else 1.0,
        );
        self.backend.wgpu.pass = pass;
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        std.debug.assert(options.color_attachments.len == 1); // MRT is not wired up
        const color = options.color_attachments[0];
        const rec = &self.backend.webgl.recorder;
        // The FBO is resolved during replay from the views, so that a swapchain
        // target uses the swapchain's own FBO rather than building a new one.
        const fbo = rhi.webgl.resolve_framebuffer(device, color.view, options.depth_attachment);
        rec.pass_open = true;
        rec.append(.{ .begin_render_pass = .{
            .fbo = fbo,
            .width = color.view.backend.webgl.width,
            .height = color.view.backend.webgl.height,
            .clear_color = color.load_op == .clear,
            .color = color.clear_color,
            .has_depth = options.depth_attachment != null,
            .clear_depth_value = if (options.depth_attachment) |d| d.load_op == .clear else false,
            .depth = if (options.depth_attachment) |d| d.clear_depth else 1.0,
        } });
        return;
    }
    unreachable;
}

pub fn end_rendering(self: *Cmd, device: *rhi.Device) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdEndRendering(self.backend.vk.cmd);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.encoder.?.endEncoding();
        self.backend.mtl.encoder = null;
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        rhi.webgpu.wgpu_render_pass_end(self.backend.wgpu.pass);
        rhi.webgpu.wgpu_release(self.backend.wgpu.pass);
        self.backend.wgpu.pass = .none;
        self.backend.wgpu.pipeline = null;
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        self.backend.webgl.recorder.pass_open = false;
        self.backend.webgl.recorder.append(.end_render_pass);
        return;
    }
    unreachable;
}

pub fn set_viewport(self: *Cmd, device: *rhi.Device, vp: Viewport) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var v = [_]rhi.vulkan.vk.Viewport{.{ .x = vp.x, .y = vp.y, .width = vp.width, .height = vp.height, .min_depth = vp.min_depth, .max_depth = vp.max_depth }};
        dkb.cmdSetViewport(self.backend.vk.cmd, 0, &v);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.encoder.?.setViewport(.{ .origin_x = vp.x, .origin_y = vp.y, .width = vp.width, .height = vp.height, .znear = vp.min_depth, .zfar = vp.max_depth });
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        rhi.webgpu.wgpu_render_pass_set_viewport(self.backend.wgpu.pass, vp.x, vp.y, vp.width, vp.height, vp.min_depth, vp.max_depth);
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        // Recorded as given; the Y flip happens at replay, which is the only
        // place that knows the render target's height.
        self.backend.webgl.recorder.append(.{ .set_viewport = vp });
        return;
    }
    unreachable;
}

pub fn set_scissor(self: *Cmd, device: *rhi.Device, rect: Rect) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var s = [_]rhi.vulkan.vk.Rect2D{.{ .offset = .{ .x = rect.x, .y = rect.y }, .extent = .{ .width = rect.width, .height = rect.height } }};
        dkb.cmdSetScissor(self.backend.vk.cmd, 0, &s);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.encoder.?.setScissorRect(.{ .x = @intCast(rect.x), .y = @intCast(rect.y), .width = rect.width, .height = rect.height });
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        // WebGPU scissor origins are unsigned; a negative origin is a validation
        // error there rather than a clamp, so clamp it here.
        rhi.webgpu.wgpu_render_pass_set_scissor_rect(
            self.backend.wgpu.pass,
            @intCast(@max(rect.x, 0)),
            @intCast(@max(rect.y, 0)),
            rect.width,
            rect.height,
        );
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        self.backend.webgl.recorder.append(.{ .set_scissor = rect });
        return;
    }
    unreachable;
}

pub fn bind_pipeline(self: *Cmd, device: *rhi.Device, pipeline: *rhi.Pipeline) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdBindPipeline(self.backend.vk.cmd, .graphics, pipeline.backend.vk.pipeline);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.encoder.?.setRenderPipelineState(pipeline.backend.mtl.state);
        if (pipeline.backend.mtl.depth_stencil_state) |dss| {
            self.backend.mtl.encoder.?.setDepthStencilState(dss);
        }
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        rhi.webgpu.wgpu_render_pass_set_pipeline(self.backend.wgpu.pass, pipeline.backend.wgpu.pipeline);
        // Remembered so `set_push_constants` can find the uniform buffer and
        // bind group this pipeline owns.
        self.backend.wgpu.pipeline = pipeline;
        if (!pipeline.backend.wgpu.push_constant_group.isNone()) {
            rhi.webgpu.wgpu_render_pass_set_bind_group(self.backend.wgpu.pass, 0, pipeline.backend.wgpu.push_constant_group);
        }
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        self.backend.webgl.recorder.append(.{ .bind_pipeline = pipeline });
        return;
    }
    unreachable;
}

/// Bind named descriptors against the slots the pipeline declared in
/// `texture_bindings`.
///
/// Same vocabulary as `rpi.Program.bindDescriptors` -- `rhi.Descriptor` values
/// addressed by shader-side name -- but none of its machinery: the web backends
/// have no descriptor sets. A WebGPU bind group is built from a whole
/// pipeline-owned layout, and a WebGL2 texture unit is global state, so what a
/// slot needs is the resource handle and nothing else.
///
/// All slots go at once because WebGPU builds a bind group from a whole layout
/// in a single call; a per-slot API could not be mapped onto that without
/// deferring group construction to draw time and tracking dirty slots.
///
/// The name carries the backend prefix because there is no desktop path:
/// Vulkan and Metal return `error.UnsupportedBackend`, and there the same
/// descriptors go through `rpi.Program.bindDescriptors`, which owns the
/// descriptor-set layouts a set write needs. Call this after `bind_pipeline`.
pub fn web_bind_descriptors(
    self: *Cmd,
    device: *rhi.Device,
    pipeline: *rhi.Pipeline,
    bindings: []const rhi.DescriptorBinding,
) !void {
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        const w = &pipeline.backend.wgpu;
        const slots = w.texture_bindings[0..w.texture_binding_count];
        const resolved = try resolve_descriptor_slots(slots, bindings);
        if (slots.len == 0) return;

        // A renderer binds the same textures every frame, so the group is
        // memoised against the identity of what went into it.
        var key: u64 = 1469598103934665603;
        for (resolved[0..slots.len]) |r| {
            key = (key ^ if (r.texture) |d| d.cookie else 0) *% 1099511628211;
            key = (key ^ if (r.sampler) |d| d.cookie else 0) *% 1099511628211;
        }

        if (w.texture_group.isNone() or w.texture_group_key != key) {
            var entries: [rhi.pipeline.max_texture_bindings * 2 * 2]u32 = undefined;
            var n: usize = 0;
            for (slots, resolved[0..slots.len]) |slot, r| {
                const tex = r.texture orelse return error.DescriptorMissing;
                entries[n] = slot.binding;
                entries[n + 1] = @intFromEnum(tex.backend.wgpu.handle);
                n += 2;
                if (slot.sampler_binding) |sb| {
                    const smp = r.sampler orelse return error.SamplerRequired;
                    entries[n] = sb;
                    entries[n + 1] = @intFromEnum(smp.backend.wgpu.handle);
                    n += 2;
                }
            }
            const group = rhi.webgpu.wgpu_device_create_bind_group_textures(
                device.backend.wgpu.device,
                w.texture_group_layout,
                &entries,
                @intCast(n),
            );
            if (group.isNone()) return error.WebGPUBindGroupCreationFailed;
            rhi.webgpu.wgpu_release(w.texture_group);
            w.texture_group = group;
            w.texture_group_key = key;
        }
        rhi.webgpu.wgpu_render_pass_set_bind_group(self.backend.wgpu.pass, 1, w.texture_group);
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        const w = &pipeline.backend.webgl;
        const slots = w.texture_bindings[0..w.texture_binding_count];
        const resolved = try resolve_descriptor_slots(slots, bindings);
        // A slot's index is its texture unit -- that is what the sampler
        // uniforms were pointed at when the program was linked.
        for (resolved[0..slots.len], 0..) |r, unit| {
            const tex = r.texture orelse return error.DescriptorMissing;
            self.backend.webgl.recorder.append(.{ .bind_texture = .{
                .unit = @intCast(unit),
                // A slot with no sampler descriptor leaves the unit's sampler
                // object unbound, and the texture's own parameters apply.
                .texture = tex.backend.webgl.handle,
                .sampler = if (r.sampler) |smp| smp.backend.webgl.handle else .none,
            } });
        }
        return;
    }
    return error.UnsupportedBackend;
}

/// One slot's gathered descriptors, indexed alongside the pipeline's slots.
const ResolvedSlot = struct {
    texture: ?*const rhi.Descriptor = null,
    sampler: ?*const rhi.Descriptor = null,
};

/// Match each binding to the slot whose declared name it carries. Order-free:
/// the caller lists bindings in whatever order reads well, as it does with
/// `rpi.Program.bindDescriptors`.
fn resolve_descriptor_slots(
    slots: []const rhi.pipeline.TextureSlot,
    bindings: []const rhi.DescriptorBinding,
) ![rhi.pipeline.max_texture_bindings]ResolvedSlot {
    var out: [rhi.pipeline.max_texture_bindings]ResolvedSlot = @splat(.{});
    for (bindings) |*b| {
        // An empty descriptor names an uncreated resource; `bindDescriptors`
        // skips those, so this does too.
        if (b.descriptor.isEmpty()) continue;
        var matched = false;
        // Every slot is checked, not just the first hit: one `SamplerState`
        // shared by two textures is named by both their slots.
        for (slots, 0..) |slot, i| {
            if (slot.name_hash == b.handle.hash) {
                if (b.descriptor.type != .sampled_image) return error.DescriptorTypeMismatch;
                out[i].texture = &b.descriptor;
                matched = true;
            }
            if (slot.sampler_name_hash) |h| if (h == b.handle.hash) {
                if (b.descriptor.type != .sampler) return error.DescriptorTypeMismatch;
                out[i].sampler = &b.descriptor;
                matched = true;
            };
        }
        if (!matched) return error.BindingNotFound;
    }
    return out;
}

pub fn draw(self: *Cmd, device: *rhi.Device, options: struct {
    vertex_count: u32,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdDraw(self.backend.vk.cmd, options.vertex_count, options.instance_count, options.first_vertex, options.first_instance);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.encoder.?.drawPrimitives(.triangle, options.first_vertex, options.vertex_count);
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        rhi.webgpu.wgpu_render_pass_draw(
            self.backend.wgpu.pass,
            options.vertex_count,
            options.instance_count,
            options.first_vertex,
            options.first_instance,
        );
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        // WebGL2 has no base instance: `drawArraysInstanced` starts at 0. A
        // non-zero value would silently render the wrong thing.
        std.debug.assert(options.first_instance == 0);
        self.backend.webgl.recorder.append(.{ .draw = .{
            .vertex_count = options.vertex_count,
            .instance_count = options.instance_count,
            .first_vertex = options.first_vertex,
        } });
        return;
    }
    unreachable;
}

pub fn clear_attachment_regions(self: *Cmd, device: *rhi.Device, options: struct {
    regions: []const struct { color: [4]f32, rect: Rect },
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        for (options.regions) |r| {
            var clear_rect = [_]rhi.vulkan.vk.ClearRect{.{
                .rect = .{ .offset = .{ .x = r.rect.x, .y = r.rect.y }, .extent = .{ .width = r.rect.width, .height = r.rect.height } },
                .base_array_layer = 0,
                .layer_count = 1,
            }};
            var clear_att = [_]rhi.vulkan.vk.ClearAttachment{.{
                .aspect_mask = .{ .color = true },
                .color_attachment = 0,
                .clear_value = .{ .color = .{ .float_32 = r.color } },
            }};
            dkb.cmdClearAttachments(self.backend.vk.cmd, clear_att[0..], clear_rect[0..]);
        }
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        // Metal cannot clear sub-rects inside a pass; the begin_rendering load
        // action already cleared the whole attachment. Per-quadrant fills would
        // need solid-color draws (a follow-up).
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        // WebGPU has no mid-pass partial clear at all: a render pass clears only
        // through its attachment load ops. Emulating this needs a dedicated
        // pipeline and a quad draw per region, which is not wired up. Panicking
        // rather than silently doing nothing keeps the gap visible; callers on
        // web skip this entirely.
        @panic("clear_attachment_regions: WebGPU has no mid-pass partial clear (use the attachment load_op)");
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        // WebGL2 *can* do this, unlike WebGPU: a scissored clear per region.
        const rec = &self.backend.webgl.recorder;
        const Region = rhi.webgl.command_list.ClearRegion;
        var regions: [16]Region = undefined;
        std.debug.assert(options.regions.len <= regions.len);
        for (options.regions, 0..) |r, i| {
            regions[i] = .{ .color = r.color, .x = r.rect.x, .y = r.rect.y, .width = r.rect.width, .height = r.rect.height };
        }
        const bytes = std.mem.sliceAsBytes(regions[0..options.regions.len]);
        const offset = rec.stash(bytes);
        rec.append(.{ .clear_regions = .{ .offset = offset, .count = @intCast(options.regions.len) } });
        return;
    }
    unreachable;
}

pub const IndexType = enum { uint16, uint32 };

pub fn bind_vertex_buffer(self: *Cmd, device: *rhi.Device, buffer: *rhi.Buffer, slot: u32) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const buffers = [_]rhi.vulkan.vk.Buffer{buffer.backend.vk.buffer};
        const offsets = [_]rhi.vulkan.vk.DeviceSize{0};
        dkb.cmdBindVertexBuffers(self.backend.vk.cmd, slot, &buffers, &offsets);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.encoder.?.setVertexBuffer(buffer.backend.mtl.buffer, 0, rhi.pipeline.mtl_vertex_buffer_base + slot);
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        // A host-written buffer still holds its contents in a wasm-memory shadow
        // until something uses it; flush before the GPU can read it.
        buffer.flush(device);
        rhi.webgpu.wgpu_render_pass_set_vertex_buffer(self.backend.wgpu.pass, slot, buffer.backend.wgpu.buffer, 0);
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        buffer.flush(device);
        self.backend.webgl.recorder.append(.{ .bind_vertex_buffer = .{ .buffer = buffer, .slot = slot } });
        return;
    }
    unreachable;
}

pub fn bind_index_buffer(self: *Cmd, device: *rhi.Device, buffer: *rhi.Buffer, index_type: IndexType) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdBindIndexBuffer(self.backend.vk.cmd, buffer.backend.vk.buffer, 0, switch (index_type) {
            .uint16 => .uint16,
            .uint32 => .uint32,
        });
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.index_buffer = buffer.backend.mtl.buffer;
        self.backend.mtl.index_type = switch (index_type) {
            .uint16 => .uint16,
            .uint32 => .uint32,
        };
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        buffer.flush(device);
        rhi.webgpu.wgpu_render_pass_set_index_buffer(
            self.backend.wgpu.pass,
            buffer.backend.wgpu.buffer,
            rhi.webgpu.to_wgpu_index_format(index_type),
            0,
        );
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        buffer.flush(device);
        self.backend.webgl.recorder.append(.{ .bind_index_buffer = .{ .buffer = buffer, .index_type = index_type } });
        return;
    }
    unreachable;
}

pub fn draw_indexed(self: *Cmd, device: *rhi.Device, options: struct {
    index_count: u32,
    instance_count: u32 = 1,
    first_index: u32 = 0,
    vertex_offset: i32 = 0,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdDrawIndexed(self.backend.vk.cmd, options.index_count, options.instance_count, options.first_index, options.vertex_offset, 0);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        const index_size: u32 = switch (self.backend.mtl.index_type) {
            .uint16 => 2,
            .uint32 => 4,
        };
        self.backend.mtl.encoder.?.drawIndexedPrimitives(
            .triangle,
            options.index_count,
            self.backend.mtl.index_type,
            self.backend.mtl.index_buffer.?,
            options.first_index * index_size,
        );
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        rhi.webgpu.wgpu_render_pass_draw_indexed(
            self.backend.wgpu.pass,
            options.index_count,
            options.instance_count,
            options.first_index,
            options.vertex_offset,
            0,
        );
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        // WebGL2 has no base vertex (`glDrawElementsBaseVertex` is ES 3.2), so
        // a non-zero offset cannot be honoured and must not be dropped quietly.
        std.debug.assert(options.vertex_offset == 0);
        self.backend.webgl.recorder.append(.{ .draw_indexed = .{
            .index_count = options.index_count,
            .instance_count = options.instance_count,
            .first_index = options.first_index,
        } });
        return;
    }
    unreachable;
}

/// Set vertex-stage push constants (Vulkan) / inline vertex bytes (Metal).
pub fn set_push_constants(self: *Cmd, device: *rhi.Device, pipeline: *rhi.Pipeline, bytes: []const u8) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdPushConstants(self.backend.vk.cmd, pipeline.backend.vk.layout, .{ .vertex = true }, 0, @intCast(bytes.len), bytes.ptr);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        // slangc places the vertex push-constant block at buffer index 0.
        self.backend.mtl.encoder.?.setVertexBytes(bytes.ptr, bytes.len, 0);
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        // WebGPU has no push constants. The pipeline owns a uniform buffer and a
        // `@group(0) @binding(0)` bind group standing in for the block, bound by
        // `bind_pipeline`; writing the buffer is all that remains. The write is
        // a queue operation, so it lands before the submit that reads it.
        const w = &pipeline.backend.wgpu;
        std.debug.assert(!w.push_constant_buffer.isNone()); // pipeline declared no push constants
        std.debug.assert(bytes.len <= w.push_constant_size);
        rhi.webgpu.wgpu_queue_write_buffer(
            self.backend.wgpu.queue,
            w.push_constant_buffer,
            0,
            bytes.ptr,
            @intCast(bytes.len),
        );
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        // The bytes are copied into the recorder's arena: the caller's buffer
        // (`std.mem.asBytes(&pc)` off the stack) is gone by replay time.
        const rec = &self.backend.webgl.recorder;
        const offset = rec.stash(bytes);
        rec.append(.{ .set_push_constants = .{
            .pipeline = pipeline,
            .offset = offset,
            .len = @intCast(bytes.len),
        } });
        return;
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// Additional leaf commands ported from HPL2 RITypes.h `RICmd`. The compute and
// transfer commands below have no Metal implementation yet: the Metal backend
// currently opens only a render encoder (see begin_rendering), with no compute
// or blit encoder lifecycle. They are Vulkan-complete and panic on Metal until
// that encoder plumbing lands; no Metal example exercises them.
// ---------------------------------------------------------------------------

/// Dispatch a compute grid.
pub fn dispatch(self: *Cmd, device: *rhi.Device, options: struct {
    group_count_x: u32 = 1,
    group_count_y: u32 = 1,
    group_count_z: u32 = 1,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdDispatch(self.backend.vk.cmd, options.group_count_x, options.group_count_y, options.group_count_z);
        return;
    }
    @panic("dispatch: not yet implemented on the Metal backend");
}

/// Dispatch a compute grid whose group counts are read from `buffer` at `offset`
/// (a `VkDispatchIndirectCommand`).
pub fn dispatch_indirect(self: *Cmd, device: *rhi.Device, buffer: *rhi.Buffer, offset: u64) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdDispatchIndirect(self.backend.vk.cmd, buffer.backend.vk.buffer, offset);
        return;
    }
    @panic("dispatch_indirect: not yet implemented on the Metal backend");
}

/// Issue `draw_count` indirect draws from `buffer` (`VkDrawIndirectCommand`s,
/// `stride` bytes apart).
pub fn draw_indirect(self: *Cmd, device: *rhi.Device, options: struct {
    buffer: *rhi.Buffer,
    offset: u64 = 0,
    draw_count: u32 = 1,
    stride: u32 = 0,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdDrawIndirect(self.backend.vk.cmd, options.buffer.backend.vk.buffer, options.offset, options.draw_count, options.stride);
        return;
    }
    @panic("draw_indirect: not yet implemented on the Metal backend");
}

/// Issue `draw_count` indexed indirect draws from `buffer`
/// (`VkDrawIndexedIndirectCommand`s, `stride` bytes apart).
pub fn draw_indexed_indirect(self: *Cmd, device: *rhi.Device, options: struct {
    buffer: *rhi.Buffer,
    offset: u64 = 0,
    draw_count: u32 = 1,
    stride: u32 = 0,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdDrawIndexedIndirect(self.backend.vk.cmd, options.buffer.backend.vk.buffer, options.offset, options.draw_count, options.stride);
        return;
    }
    @panic("draw_indexed_indirect: not yet implemented on the Metal backend");
}

/// Buffer-to-buffer copy of `size` bytes. Caller owns the surrounding barriers.
pub fn copy_buffer(self: *Cmd, device: *rhi.Device, options: struct {
    src: *rhi.Buffer,
    src_offset: u64 = 0,
    dst: *rhi.Buffer,
    dst_offset: u64 = 0,
    size: u64,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const regions = [_]rhi.vulkan.vk.BufferCopy{.{
            .src_offset = options.src_offset,
            .dst_offset = options.dst_offset,
            .size = options.size,
        }};
        dkb.cmdCopyBuffer(self.backend.vk.cmd, options.src.backend.vk.buffer, options.dst.backend.vk.buffer, regions[0..]);
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        // Copies are encoder-level commands and are illegal inside a render
        // pass. Catch that here rather than letting the browser reject the whole
        // submit with a validation message far from the cause.
        std.debug.assert(self.backend.wgpu.pass.isNone());
        options.src.flush(device);
        rhi.webgpu.wgpu_command_encoder_copy_buffer_to_buffer(
            self.backend.wgpu.encoder,
            options.src.backend.wgpu.buffer,
            @intCast(options.src_offset),
            options.dst.backend.wgpu.buffer,
            @intCast(options.dst_offset),
            @intCast(options.size),
        );
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        options.src.flush(device);
        self.backend.webgl.recorder.append(.{ .copy_buffer = .{
            .src = options.src,
            .src_offset = @intCast(options.src_offset),
            .dst = options.dst,
            .dst_offset = @intCast(options.dst_offset),
            .size = @intCast(options.size),
        } });
        return;
    }
    @panic("copy_buffer: not yet implemented on the Metal backend");
}

/// Copy one buffer region into a single texture subresource. `dst` must already
/// be in the `copy_dst` (TRANSFER_DST_OPTIMAL) state. `buffer_row_length` and
/// `buffer_image_height` are in texels (0 = tightly packed).
pub fn copy_buffer_to_texture(self: *Cmd, device: *rhi.Device, options: struct {
    src: *rhi.Buffer,
    dst: *rhi.Image,
    buffer_offset: u64 = 0,
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
    aspect: BarrierAspect = .color,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    width: u32,
    height: u32,
    depth: u32 = 1,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const regions = [_]rhi.vulkan.vk.BufferImageCopy{.{
            .buffer_offset = options.buffer_offset,
            .buffer_row_length = options.buffer_row_length,
            .buffer_image_height = options.buffer_image_height,
            .image_subresource = .{
                .aspect_mask = vk_barrier_aspect(options.aspect),
                .mip_level = options.mip_level,
                .base_array_layer = options.base_array_layer,
                .layer_count = options.layer_count,
            },
            .image_offset = .{ .x = options.x, .y = options.y, .z = options.z },
            .image_extent = .{ .width = options.width, .height = options.height, .depth = options.depth },
        }};
        dkb.cmdCopyBufferToImage(self.backend.vk.cmd, options.src.backend.vk.buffer, options.dst.backend.vk.image, .transfer_dst_optimal, regions[0..]);
        return;
    }
    @panic("copy_buffer_to_texture: not yet implemented on the Metal backend");
}

/// Copy one texture subresource into a buffer region. `src` must already be in
/// the `copy_src` (TRANSFER_SRC_OPTIMAL) state. `buffer_row_length` and
/// `buffer_image_height` are in texels (0 = tightly packed).
pub fn copy_texture_to_buffer(self: *Cmd, device: *rhi.Device, options: struct {
    src: *rhi.Image,
    dst: *rhi.Buffer,
    buffer_offset: u64 = 0,
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
    aspect: BarrierAspect = .color,
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
    width: u32,
    height: u32,
    depth: u32 = 1,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const regions = [_]rhi.vulkan.vk.BufferImageCopy{.{
            .buffer_offset = options.buffer_offset,
            .buffer_row_length = options.buffer_row_length,
            .buffer_image_height = options.buffer_image_height,
            .image_subresource = .{
                .aspect_mask = vk_barrier_aspect(options.aspect),
                .mip_level = options.mip_level,
                .base_array_layer = options.base_array_layer,
                .layer_count = options.layer_count,
            },
            .image_offset = .{ .x = options.x, .y = options.y, .z = options.z },
            .image_extent = .{ .width = options.width, .height = options.height, .depth = options.depth },
        }};
        dkb.cmdCopyImageToBuffer(self.backend.vk.cmd, options.src.backend.vk.image, .transfer_src_optimal, options.dst.backend.vk.buffer, regions[0..]);
        return;
    }
    @panic("copy_texture_to_buffer: not yet implemented on the Metal backend");
}

/// Copy a single 1:1 region between textures (no scaling). `src`/`dst` must be in
/// the `copy_src`/`copy_dst` states. Caller owns the surrounding barriers.
pub fn copy_image(self: *Cmd, device: *rhi.Device, options: struct {
    src: *rhi.Image,
    dst: *rhi.Image,
    aspect: BarrierAspect = .color,
    src_mip: u32 = 0,
    src_base_layer: u32 = 0,
    src_x: i32 = 0,
    src_y: i32 = 0,
    src_z: i32 = 0,
    dst_mip: u32 = 0,
    dst_base_layer: u32 = 0,
    dst_x: i32 = 0,
    dst_y: i32 = 0,
    dst_z: i32 = 0,
    layer_count: u32 = 1,
    width: u32,
    height: u32,
    depth: u32 = 1,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const aspect_mask = vk_barrier_aspect(options.aspect);
        const regions = [_]rhi.vulkan.vk.ImageCopy{.{
            .src_subresource = .{
                .aspect_mask = aspect_mask,
                .mip_level = options.src_mip,
                .base_array_layer = options.src_base_layer,
                .layer_count = options.layer_count,
            },
            .src_offset = .{ .x = options.src_x, .y = options.src_y, .z = options.src_z },
            .dst_subresource = .{
                .aspect_mask = aspect_mask,
                .mip_level = options.dst_mip,
                .base_array_layer = options.dst_base_layer,
                .layer_count = options.layer_count,
            },
            .dst_offset = .{ .x = options.dst_x, .y = options.dst_y, .z = options.dst_z },
            .extent = .{ .width = options.width, .height = options.height, .depth = options.depth },
        }};
        dkb.cmdCopyImage(self.backend.vk.cmd, options.src.backend.vk.image, .transfer_src_optimal, options.dst.backend.vk.image, .transfer_dst_optimal, regions[0..]);
        return;
    }
    @panic("copy_image: not yet implemented on the Metal backend");
}

/// Clear a storage image (mip 0, layer 0) that is in the GENERAL layout — pair
/// with the `clear_storage` resource state on the surrounding barriers.
pub fn clear_storage_image(self: *Cmd, device: *rhi.Device, image: *rhi.Image, color: [4]f32) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const clear_color = rhi.vulkan.vk.ClearColorValue{ .float_32 = color };
        const ranges = [_]rhi.vulkan.vk.ImageSubresourceRange{.{
            .aspect_mask = .{ .color = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        }};
        dkb.cmdClearColorImage(self.backend.vk.cmd, image.backend.vk.image, .general, &clear_color, ranges[0..]);
        return;
    }
    @panic("clear_storage_image: not yet implemented on the Metal backend");
}

// Combined access+layout resource state (Forge-style). Each field encodes one
// (access, layout) contribution and fields may be combined (e.g.
// `.{ .storage_write = true, .copy_dst = true }` for a producer that both
// stored and copied; `.{ .storage_read = true, .shader_resource = true }` for a
// sampled view of a storage image, which forces the GENERAL layout). The
// pipeline stages are derived conservatively from the set fields unless narrowed
// by a BarrierStages hint. The all-false value (`.{}`) is the UNDEFINED state.
// Ported from HPL2 RIBarrier.h RIResourceState_e.
pub const ResourceState = struct {
    general: bool = false, // GENERAL layout, broad read/write
    render_target: bool = false, // COLOR_ATTACHMENT_OPTIMAL, write
    render_target_read: bool = false, // COLOR_ATTACHMENT_OPTIMAL, read|write (blend)
    depth_write: bool = false, // DEPTH_ATTACHMENT_OPTIMAL
    depth_read: bool = false, // DEPTH_READ_ONLY_OPTIMAL
    shader_resource: bool = false, // SHADER_READ_ONLY_OPTIMAL, sampled
    storage_read: bool = false, // GENERAL, storage read
    storage_write: bool = false, // GENERAL, storage write
    copy_src: bool = false, // TRANSFER_SRC_OPTIMAL
    copy_dst: bool = false, // TRANSFER_DST_OPTIMAL
    present: bool = false, // PRESENT_SRC_KHR
    indirect_argument: bool = false, // buffer only
    vertex_buffer: bool = false, // buffer only
    index_buffer: bool = false, // buffer only
    constant_buffer: bool = false, // buffer only
    accel_read: bool = false, // acceleration structure read
    accel_write: bool = false, // acceleration structure build write
    clear_storage: bool = false, // GENERAL, vkCmdClear* transfer write
    host_read: bool = false, // buffer only; carries no image layout

    // Named composite mirroring RIResourceState_e's OR'd value (the UNDEFINED
    // state is just the all-false default, `.{}`).
    pub const unordered_access: ResourceState = .{ .storage_read = true, .storage_write = true };
};

// Optional per-side stage narrowing; all-false derives a conservative mask
// from the resource state (e.g. shader_resource -> all shader stages).
pub const BarrierStages = struct {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    ray_tracing: bool = false,
    draw_indirect: bool = false,
    copy: bool = false,
    blit: bool = false,
    clear: bool = false,
    accel_build: bool = false,
    // COLOR_ATTACHMENT_OUTPUT. Needed as a before-stage on the first barrier
    // after swapchain acquire: the acquire semaphore is waited at this stage,
    // and an UNDEFINED before-state alone derives no src stage to chain to it.
    color_attachment: bool = false,
    host: bool = false,

    pub const all_graphics: BarrierStages = .{ .vertex = true, .fragment = true };
    pub const all_shader: BarrierStages = .{ .vertex = true, .fragment = true, .compute = true, .ray_tracing = true };
};

pub const BarrierAspect = enum(u8) { color, depth, stencil, depth_stencil };

pub const ImageBarrier = struct {
    image: *const rhi.Image,
    before: ResourceState,
    after: ResourceState,
    before_stages: BarrierStages = .{}, // all-false => derive from 'before'
    after_stages: BarrierStages = .{}, // all-false => derive from 'after'
    aspect: BarrierAspect = .color,
    base_mip: u16 = 0,
    mip_count: u16 = 0, // 0 => REMAINING_MIP_LEVELS
    base_layer: u16 = 0,
    layer_count: u16 = 0, // 0 => REMAINING_ARRAY_LAYERS
};

pub const BufferBarrier = struct {
    buffer: *const rhi.Buffer,
    before: ResourceState,
    after: ResourceState,
    before_stages: BarrierStages = .{}, // all-false => derive from 'before'
    after_stages: BarrierStages = .{}, // all-false => derive from 'after'
    offset: u64 = 0,
    size: u64 = 0, // 0 => WHOLE_SIZE
};

// Global execution+memory barrier (no resource handle).
pub const MemoryBarrier = struct {
    before: ResourceState,
    after: ResourceState,
    before_stages: BarrierStages = .{}, // all-false => derive from 'before'
    after_stages: BarrierStages = .{}, // all-false => derive from 'after'
};

fn vk_resource_state_layout(state: ResourceState) rhi.vulkan.vk.ImageLayout {
    // GENERAL wins over the optimal layouts: a state that mixes storage access
    // with anything else (e.g. a sampled view of a storage image) can only be
    // satisfied by the GENERAL layout.
    if (state.general or state.storage_read or state.storage_write or state.clear_storage)
        return .general;
    if (state.render_target or state.render_target_read)
        return .color_attachment_optimal;
    if (state.depth_write)
        return .depth_attachment_optimal;
    if (state.depth_read)
        return .depth_read_only_optimal;
    if (state.shader_resource)
        return .shader_read_only_optimal;
    if (state.copy_src)
        return .transfer_src_optimal;
    if (state.copy_dst)
        return .transfer_dst_optimal;
    if (state.present)
        return .present_src_khr;
    // UNDEFINED, or buffer-only / accel states that carry no image layout.
    return .undefined;
}

fn vk_resource_state_access(state: ResourceState) rhi.vulkan.vk.AccessFlags2 {
    var access: rhi.vulkan.vk.AccessFlags2 = .{};
    if (state.general) {
        access.shader_read = true;
        access.shader_write = true;
    }
    if (state.render_target) access.color_attachment_write = true;
    if (state.render_target_read) {
        access.color_attachment_read = true;
        access.color_attachment_write = true;
    }
    if (state.depth_write) {
        access.depth_stencil_attachment_read = true;
        access.depth_stencil_attachment_write = true;
    }
    if (state.depth_read) access.depth_stencil_attachment_read = true;
    if (state.shader_resource) {
        access.shader_sampled_read = true;
        access.shader_read = true;
    }
    if (state.storage_read) access.shader_storage_read = true;
    if (state.storage_write) access.shader_storage_write = true;
    if (state.copy_src) access.transfer_read = true;
    if (state.copy_dst) access.transfer_write = true;
    if (state.indirect_argument) access.indirect_command_read = true;
    if (state.vertex_buffer) access.vertex_attribute_read = true;
    if (state.index_buffer) access.index_read = true;
    if (state.constant_buffer) access.uniform_read = true;
    if (state.accel_read) access.acceleration_structure_read_khr = true;
    if (state.accel_write) access.acceleration_structure_write_khr = true;
    if (state.clear_storage) access.transfer_write = true;
    if (state.host_read) access.host_read = true;
    return access;
}

// Conservative stage derivation for barriers that omit a stage hint.
fn vk_resource_state_stages(state: ResourceState) rhi.vulkan.vk.PipelineStageFlags2 {
    var flags: rhi.vulkan.vk.PipelineStageFlags2 = .{};
    if (state.general or state.shader_resource or state.storage_read or
        state.storage_write or state.constant_buffer)
    {
        flags.vertex_shader = true;
        flags.fragment_shader = true;
        flags.compute_shader = true;
        flags.ray_tracing_shader_khr = true;
    }
    if (state.render_target or state.render_target_read) flags.color_attachment_output = true;
    if (state.depth_write or state.depth_read) {
        flags.early_fragment_tests = true;
        flags.late_fragment_tests = true;
    }
    if (state.copy_src or state.copy_dst) {
        flags.copy = true;
        flags.blit = true;
        flags.clear = true;
    }
    if (state.indirect_argument) flags.draw_indirect = true;
    if (state.vertex_buffer or state.index_buffer) flags.vertex_input = true;
    if (state.accel_read or state.accel_write) flags.acceleration_structure_build_khr = true;
    if (state.clear_storage) flags.clear = true;
    if (state.host_read) flags.host = true;
    // UNDEFINED / PRESENT contribute no stages.
    return flags;
}

fn vk_barrier_stages(hint: BarrierStages, state_fallback: ResourceState) rhi.vulkan.vk.PipelineStageFlags2 {
    if (std.meta.eql(hint, BarrierStages{}))
        return vk_resource_state_stages(state_fallback);
    return .{
        .vertex_shader = hint.vertex,
        .fragment_shader = hint.fragment,
        .compute_shader = hint.compute,
        .ray_tracing_shader_khr = hint.ray_tracing,
        .draw_indirect = hint.draw_indirect,
        .copy = hint.copy,
        .blit = hint.blit,
        .clear = hint.clear,
        .acceleration_structure_build_khr = hint.accel_build,
        .color_attachment_output = hint.color_attachment,
        .host = hint.host,
    };
}

fn vk_barrier_aspect(aspect: BarrierAspect) rhi.vulkan.vk.ImageAspectFlags {
    return switch (aspect) {
        .color => .{ .color = true },
        .depth => .{ .depth = true },
        .stencil => .{ .stencil = true },
        .depth_stencil => .{ .depth = true, .stencil = true },
    };
}

// Emit pipeline barriers from resource-state transitions. All groups are
// batched into a single backend barrier command (vkCmdPipelineBarrier2); any
// group may be empty. The comptime capacities size the backend scratch arrays
// on the stack; each barrier slice must fit its capacity.
pub fn resource_barrier(
    self: *Cmd,
    device: *rhi.Device,
    comptime capacity: struct {
        memory: usize = 2,
        buffer: usize = 8,
        image: usize = 8,
    },
    options: struct {
        memory_barriers: []const MemoryBarrier = &.{},
        buffer_barriers: []const BufferBarrier = &.{},
        image_barriers: []const ImageBarrier = &.{},
    },
) void {
    std.debug.assert(options.memory_barriers.len <= capacity.memory);
    std.debug.assert(options.buffer_barriers.len <= capacity.buffer);
    std.debug.assert(options.image_barriers.len <= capacity.image);
    if (options.memory_barriers.len + options.buffer_barriers.len + options.image_barriers.len == 0)
        return;
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var vk_memory: [capacity.memory]rhi.vulkan.vk.MemoryBarrier2 = undefined;
        var vk_buffer: [capacity.buffer]rhi.vulkan.vk.BufferMemoryBarrier2 = undefined;
        var vk_image: [capacity.image]rhi.vulkan.vk.ImageMemoryBarrier2 = undefined;

        if (comptime capacity.memory != 0) for (options.memory_barriers, 0..) |*barrier, i| {
            vk_memory[i] = .{
                .src_stage_mask = vk_barrier_stages(barrier.before_stages, barrier.before),
                .src_access_mask = vk_resource_state_access(barrier.before),
                .dst_stage_mask = vk_barrier_stages(barrier.after_stages, barrier.after),
                .dst_access_mask = vk_resource_state_access(barrier.after),
            };
        };

        if (comptime capacity.buffer != 0) for (options.buffer_barriers, 0..) |*barrier, i| {
            vk_buffer[i] = .{
                .src_stage_mask = vk_barrier_stages(barrier.before_stages, barrier.before),
                .src_access_mask = vk_resource_state_access(barrier.before),
                .dst_stage_mask = vk_barrier_stages(barrier.after_stages, barrier.after),
                .dst_access_mask = vk_resource_state_access(barrier.after),
                .src_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                .buffer = barrier.buffer.backend.vk.buffer,
                .offset = barrier.offset,
                .size = if (barrier.size != 0) barrier.size else rhi.vulkan.vk.WHOLE_SIZE,
            };
        };

        if (comptime capacity.image != 0) for (options.image_barriers, 0..) |*barrier, i| {
            vk_image[i] = .{
                .src_stage_mask = vk_barrier_stages(barrier.before_stages, barrier.before),
                .src_access_mask = vk_resource_state_access(barrier.before),
                .dst_stage_mask = vk_barrier_stages(barrier.after_stages, barrier.after),
                .dst_access_mask = vk_resource_state_access(barrier.after),
                .old_layout = vk_resource_state_layout(barrier.before),
                .new_layout = vk_resource_state_layout(barrier.after),
                .src_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                .image = barrier.image.backend.vk.image,
                .subresource_range = .{
                    .aspect_mask = vk_barrier_aspect(barrier.aspect),
                    .base_mip_level = barrier.base_mip,
                    .level_count = if (barrier.mip_count != 0) barrier.mip_count else rhi.vulkan.vk.REMAINING_MIP_LEVELS,
                    .base_array_layer = barrier.base_layer,
                    .layer_count = if (barrier.layer_count != 0) barrier.layer_count else rhi.vulkan.vk.REMAINING_ARRAY_LAYERS,
                },
            };
        };

        var dependency_info = rhi.vulkan.vk.DependencyInfo{
            .memory_barrier_count = @intCast(options.memory_barriers.len),
            .p_memory_barriers = if (options.memory_barriers.len != 0) vk_memory[0..].ptr else null,
            .buffer_memory_barrier_count = @intCast(options.buffer_barriers.len),
            .p_buffer_memory_barriers = if (options.buffer_barriers.len != 0) vk_buffer[0..].ptr else null,
            .image_memory_barrier_count = @intCast(options.image_barriers.len),
            .p_image_memory_barriers = if (options.image_barriers.len != 0) vk_image[0..].ptr else null,
        };
        dkb.cmdPipelineBarrier2(self.backend.vk.cmd, &dependency_info);
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        // Nothing to emit. WebGPU tracks resource state itself and inserts the
        // transitions and memory dependencies a submit needs, so an explicit
        // barrier has no expressible form — a no-op here is the correct
        // implementation, not a stub.
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        // Also nothing to emit: GL orders commands within a context by
        // specification, so a barrier has no expressible form here either.
        return;
    }
    unreachable;
}

// Single-barrier conveniences.
pub fn memory_barrier(self: *Cmd, device: *rhi.Device, barrier: MemoryBarrier) void {
    self.resource_barrier(device,.{ .memory = 1, .buffer = 0, .image = 0 }, .{ .memory_barriers = &[_]MemoryBarrier{barrier} });
}

pub fn buffer_barrier(self: *Cmd, device: *rhi.Device, barrier: BufferBarrier) void {
    self.resource_barrier(device,.{ .memory = 0, .buffer = 1, .image = 0 }, .{ .buffer_barriers = &[_]BufferBarrier{barrier} });
}

pub fn image_barrier(self: *Cmd, device: *rhi.Device, barrier: ImageBarrier) void {
    self.resource_barrier(device,.{ .memory = 0, .buffer = 0, .image = 1 }, .{ .image_barriers = &[_]ImageBarrier{barrier} });
}

test {
    std.testing.refAllDecls(Cmd);
}
