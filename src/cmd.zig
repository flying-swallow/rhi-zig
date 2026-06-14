const rhi = @import("root.zig");
const vulkan = @import("root.zig").vulkan;
const std = @import("std");

pub const StageBits = struct {
    index_input: bool = false, //    index buffer consumption
    vertex_shader: bool = false, //    vertex shader
    tess_control_shader: bool = false, //    tessellation control (hull) shader
    tess_evaluation_shader: bool = false, //    tessellation evaluation (domain) shader
    geometry_shader: bool = false, //    geometry shader
    mesh_control_shader: bool = false, //    mesh control (task) shader
    mesh_evaluation_shader: bool = false, //    mesh evaluation (amplification) shader
    fragment_shader: bool = false, //    fragment (pixel) shader
    depth_stencil_attachment: bool = false, //    depth-stencil r/w operations
    color_attachment: bool = false, //    color r/w operations

    // compute                                    // invoked by  "cmddispatch*" (not rays)
    compute_shader: bool = false, //    compute shader

    // ray tracing                                // invoked by "cmddispatchrays*"
    raygen_shader: bool = false, //    ray generation shader
    miss_shader: bool = false, //    miss shader
    intersection_shader: bool = false, //    intersection shader
    closest_hit_shader: bool = false, //    closest hit shader
    any_hit_shader: bool = false, //    any hit shader
    callable_shader: bool = false, //    callable shader

    acceleration_structure: bool, // invoked by "cmd*accelerationstructure*"

    // copy
    copy: bool = false, // invoked by "cmdcopy*", "cmdupload*" and "cmdreadback*"
    clear_storage: bool = false, // invoked by "cmdclearstorage*"
    resolve: bool = false, // invoked by "cmdresolvetexture"

    // modifiers
    indirect: bool = false, // invoked by "indirect" command (used in addition to other bits)
};

//pub const StageBits = enum(u32) {
//    // Special
//    all = 0, // lazy default for barriers
//    none = 0x7fffffff,
//
//    // graphics                                   // invoked by "cmddraw*"
//    index_input = 1 << 0, //    index buffer consumption
//    vertex_shader = 1 << 1, //    vertex shader
//    tess_control_shader = 1 << 2, //    tessellation control (hull) shader
//    tess_evaluation_shader = 1 << 3, //    tessellation evaluation (domain) shader
//    geometry_shader = 1 << 4, //    geometry shader
//    mesh_control_shader = 1 << 5, //    mesh control (task) shader
//    mesh_evaluation_shader = 1 << 6, //    mesh evaluation (amplification) shader
//    fragment_shader = 1 << 7, //    fragment (pixel) shader
//    depth_stencil_attachment = 1 << 8, //    depth-stencil r/w operations
//    color_attachment = 1 << 9, //    color r/w operations
//
//    // compute                                    // invoked by  "cmddispatch*" (not rays)
//    compute_shader = 1 << 10, //    compute shader
//
//    // ray tracing                                // invoked by "cmddispatchrays*"
//    raygen_shader = 1 << 11, //    ray generation shader
//    miss_shader = 1 << 12, //    miss shader
//    intersection_shader = 1 << 13, //    intersection shader
//    closest_hit_shader = 1 << 14, //    closest hit shader
//    any_hit_shader = 1 << 15, //    any hit shader
//    callable_shader = 1 << 16, //    callable shader
//
//    acceleration_structure = 1 << 17, // invoked by "cmd*accelerationstructure*"
//
//    // copy
//    copy = 1 << 18, // invoked by "cmdcopy*", "cmdupload*" and "cmdreadback*"
//    clear_storage = 1 << 19, // invoked by "cmdclearstorage*"
//    resolve = 1 << 20, // invoked by "cmdresolvetexture"
//
//    // modifiers
//    indirect = 1 << 21, // invoked by "indirect" command (used in addition to other bits)
//
//    // umbrella stages
//    tessellation_shaders = .tess_control_shader | .tess_evaluation_shader,
//    mesh_shaders = .mesh_control_shader | .mesh_evaluation_shader,
//
//    graphics_shaders = .vertex_shader |
//        .tessellation_shaders |
//        .geometry_shader |
//        .mesh_shaders |
//        .fragment_shader,
//
//    // invoked by "cmddispatchrays"
//    ray_tracing_shaders = .raygen_shader |
//        .miss_shader |
//        .intersection_shader |
//        .closest_hit_shader |
//        .any_hit_shader |
//        .callable_shader,
//
//    // invoked by "cmddraw*"
//    draw = .index_input |
//        .graphics_shaders |
//        .depth_stencil_attachment |
//        .color_attachment,
//
//};

pub const AccessBits = struct {
    index_buffer: bool = false,
    vertex_buffer: bool = false,
    constant_buffer: bool = false,
    shader_resource: bool = false,
    shader_resource_storage: bool = false,
    argument_buffer: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment_write: bool = false,
    depth_stencil_attachment_read: bool = false,
    copy_source: bool = false,
    copy_destination: bool = false,
    resolve_source: bool = false,
    resolve_destination: bool = false,
    acceleration_structure_read: bool = false,
    acceleration_structure_write: bool = false,
    shading_rate_attachment: bool = false,
};

pub const Layout = enum(u8) {
    undefined = 0,
    color_attachment = 1,
    depth_stencil_attachment = 2,
    depth_stencil_read_only = 3,
    shader_resource = 4,
    shader_resource_storage = 5,
    copy_source = 6,
    copy_destination = 7,
    resolve_source = 8,
    resolve_destination = 9,
    present = 10,
    shading_rate_attachment = 11,
};

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
    },

    pub fn reset(self: *Self, renderer: *rhi.Renderer, device: *rhi.Device) !void {
        if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            try dkb.resetCommandPool(device.backend.vk.device, self.backend.vk.pool, .{});
            return;
        }
        if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
            // Metal has no command pools; command buffers are transient.
            return;
        }
        unreachable;
    }

    pub fn deinit(self: *Self, renderer: *rhi.Renderer, device: *rhi.Device) void {
        if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            dkb.destroyCommandPool(device.backend.vk.device, self.backend.vk.pool, null);
            return;
        }
        if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
            return;
        }
        unreachable;
    }

    pub fn init(renderer: *rhi.Renderer, device: *rhi.Device, queue: *rhi.Queue) !Self {
        if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            var cmd_pool_create_info = rhi.vulkan.vk.CommandPoolCreateInfo{
                .flags = .{
                    .reset_command_buffer_bit = true,
                },
                .queue_family_index = queue.backend.vk.family_index,
            };
            const pool: rhi.vulkan.vk.CommandPool = try dkb.createCommandPool(device.backend.vk.device, &cmd_pool_create_info, null);
            return .{ .backend = .{ .vk = .{
                .queue = queue,
                .pool = pool,
            } } };
        }
        if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
            return .{ .backend = .{ .mtl = {} } };
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
    },

    pub fn wait(self: *Self, renderer: *rhi.Renderer, device: *rhi.Device) !void {
        if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            var fences = [_]rhi.vulkan.vk.Fence{self.backend.vk.fence};
            _ = try dkb.waitForFences(device.backend.vk.device, fences[0..], .true, std.math.maxInt(u64));
            return;
        }
        if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
            // CPU/GPU frame pacing on Metal is provided implicitly by
            // CAMetalLayer.nextDrawable, which blocks once the maximum number of
            // drawables is in flight. (An MTLSharedEvent could give finer-grained
            // overlap later.)
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
        },
        pub fn advance(self: *Self) void {
            self.pool_index = (self.cmd_index + 1) % options.pool_count;
            self.cmd_index = 0;
            self.fence_index = 0;
        }
        pub fn get(self: *Self, renderer: *rhi.Renderer, num_cmds: usize) CommandRingElement {
            if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
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
            if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
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
            unreachable;
        }
        pub fn init(renderer: *rhi.Renderer, device: *rhi.Device, queue: *rhi.Queue) !Self {
            if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                var cmds: [options.pool_count][options.cmd_per_pool]rhi.Cmd = undefined;
                var pools: [options.pool_count]rhi.Pool = undefined;
                var semaphores: if (options.sync_primative) [options.pool_count][options.cmd_per_pool]rhi.vulkan.vk.Semaphore else void = undefined;
                var fences: if (options.sync_primative) [options.pool_count][options.cmd_per_pool]rhi.vulkan.vk.Fence else void = undefined;
                for (0..options.pool_count) |pool_index| {
                    pools[pool_index] = try rhi.Pool.init(renderer, device, queue);
                    for (0..options.cmd_per_pool) |cmd_index| {
                        cmds[pool_index][cmd_index] = try rhi.Cmd.init(renderer, device, &pools[pool_index]);
                        if (options.sync_primative) {
                            var semaphore_create_info = rhi.vulkan.vk.SemaphoreCreateInfo{ .s_type = .semaphore_create_info };
                            semaphores[pool_index][cmd_index] = try dkb.createSemaphore(device.backend.vk.device, &semaphore_create_info, null);

                            var fence_create_info = rhi.vulkan.vk.FenceCreateInfo{ .s_type = .fence_create_info, .flags = .{ .signaled_bit = true } };
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
            if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
                var cmds: [options.pool_count][options.cmd_per_pool]rhi.Cmd = undefined;
                var pools: [options.pool_count]rhi.Pool = undefined;
                for (0..options.pool_count) |pool_index| {
                    pools[pool_index] = try rhi.Pool.init(renderer, device, queue);
                    for (0..options.cmd_per_pool) |cmd_index| {
                        cmds[pool_index][cmd_index] = try rhi.Cmd.init(renderer, device, &pools[pool_index]);
                    }
                }
                return .{ .pool_index = options.pool_count, .cmd_index = 0, .fence_index = 0, .cmds = cmds, .pools = pools, .backend = .{ .mtl = {} } };
            }

            unreachable; // should never reach here
        }

        pub fn deinit(self: *Self, renderer: *rhi.Renderer, device: *rhi.Device) void {
            if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                for (0..options.pool_count) |pool_index| {
                    if (options.sync_primative) {
                        for (0..options.cmd_per_pool) |cmd_index| {
                            dkb.destroySemaphore(device.backend.vk.device, self.backend.vk.semaphores[pool_index][cmd_index], null);
                            dkb.destroyFence(device.backend.vk.device, self.backend.vk.fences[pool_index][cmd_index], null);
                        }
                    }
                    for (0..options.cmd_per_pool) |cmd_index| {
                        self.cmds[pool_index][cmd_index].deinit(renderer, device, &self.pools[pool_index]);
                    }
                    dkb.destroyCommandPool(device.backend.vk.device, self.pools[pool_index].backend.vk.pool, null);
                }
                return;
            }
            if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
                for (0..options.pool_count) |pool_index| {
                    for (0..options.cmd_per_pool) |cmd_index| {
                        self.cmds[pool_index][cmd_index].deinit(renderer, device, &self.pools[pool_index]);
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
},

pub fn init(renderer: *rhi.Renderer, device: *rhi.Device, pool: *Pool) !Cmd {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
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
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        return .{ .backend = .{ .mtl = .{ .queue = device.backend.mtl.queue } } };
    }
    unreachable;
}

pub fn deinit(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, pool: *Pool) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var command = [_]rhi.vulkan.vk.CommandBuffer{
            self.backend.vk.cmd,
        };
        dkb.freeCommandBuffers(device.backend.vk.device, pool.backend.vk.pool, command[0..]);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        return;
    }
    unreachable;
}

pub fn begin(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device) !void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var begin_info = rhi.vulkan.vk.CommandBufferBeginInfo{
            .s_type = .command_buffer_begin_info,
            .flags = .{
                .one_time_submit_bit = true,
            },
        };
        try dkb.beginCommandBuffer(self.backend.vk.cmd, &begin_info);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        self.backend.mtl.cmd = self.backend.mtl.queue.commandBuffer() orelse return error.MetalCommandBufferFailed;
        self.backend.mtl.encoder = null;
        return;
    }
    unreachable;
}

pub fn end(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device) !void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        try dkb.endCommandBuffer(self.backend.vk.cmd);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        // Commit happens in Swapchain.frame_submit.
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
    view: rhi.Image.ImageView,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: [4]f32 = .{ 0, 0, 0, 1 },
};

pub const ImageBarrier = struct {
    image: *rhi.Image,
    old_layout: Layout,
    new_layout: Layout,
    aspect: enum { color, depth } = .color,
};

/// Insert image memory barriers. Real on Vulkan; a no-op on Metal. `reserve` is
/// the stack-allocated barrier capacity (compile-time); `image_barriers.len`
/// must not exceed it.
pub fn pipeline_barrier(self: *Cmd, comptime reserve: usize, renderer: *rhi.Renderer, device: *rhi.Device, options: struct {
    image_barriers: []const ImageBarrier,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        if (options.image_barriers.len == 0) return;
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        std.debug.assert(options.image_barriers.len <= reserve);
        var vk_barriers: [reserve]rhi.vulkan.vk.ImageMemoryBarrier2 = undefined;
        for (options.image_barriers, 0..) |b, i| {
            vk_barriers[i] = .{
                .src_stage_mask = .{},
                .src_access_mask = .{},
                .dst_stage_mask = .{},
                .dst_access_mask = .{},
                .old_layout = vk_image_layout(b.old_layout),
                .new_layout = vk_image_layout(b.new_layout),
                .src_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = rhi.vulkan.vk.QUEUE_FAMILY_IGNORED,
                .image = b.image.backend.vk.image,
                .subresource_range = .{
                    .aspect_mask = switch (b.aspect) {
                        .color => .{ .color_bit = true },
                        .depth => .{ .depth_bit = true },
                    },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            switch (b.new_layout) {
                .color_attachment => {
                    vk_barriers[i].dst_stage_mask = .{ .color_attachment_output_bit = true };
                    vk_barriers[i].dst_access_mask = .{ .color_attachment_write_bit = true };
                },
                .depth_stencil_attachment => {
                    vk_barriers[i].dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true };
                    vk_barriers[i].dst_access_mask = .{ .depth_stencil_attachment_write_bit = true };
                },
                .present => {
                    vk_barriers[i].src_stage_mask = .{ .color_attachment_output_bit = true };
                    vk_barriers[i].src_access_mask = .{ .color_attachment_write_bit = true };
                    vk_barriers[i].dst_stage_mask = .{ .bottom_of_pipe_bit = true };
                },
                else => {},
            }
        }
        var dep = rhi.vulkan.vk.DependencyInfo{
            .image_memory_barrier_count = @intCast(options.image_barriers.len),
            .p_image_memory_barriers = &vk_barriers,
        };
        dkb.cmdPipelineBarrier2(self.backend.vk.cmd, &dep);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        // Metal render-pass load/store actions handle layout transitions.
        return;
    }
    unreachable;
}

fn vk_image_layout(layout: Layout) rhi.vulkan.vk.ImageLayout {
    return switch (layout) {
        .undefined => .undefined,
        .color_attachment => .color_attachment_optimal,
        .depth_stencil_attachment => .depth_attachment_optimal,
        .present => .present_src_khr,
        else => .general,
    };
}

pub const DepthAttachment = struct {
    view: rhi.Image.ImageView,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_depth: f32 = 1.0,
};

pub fn begin_rendering(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, options: struct {
    color_attachments: []const ColorAttachment,
    render_area: Rect,
    depth_attachment: ?DepthAttachment = null,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var vk_attachments: [8]rhi.vulkan.vk.RenderingAttachmentInfo = undefined;
        for (options.color_attachments, 0..) |att, i| {
            vk_attachments[i] = .{
                .image_view = att.view.vk,
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
                .image_view = da.view.vk,
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
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
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
    unreachable;
}

pub fn end_rendering(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdEndRendering(self.backend.vk.cmd);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        self.backend.mtl.encoder.?.endEncoding();
        self.backend.mtl.encoder = null;
        return;
    }
    unreachable;
}

pub fn set_viewport(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, vp: Viewport) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var v = [_]rhi.vulkan.vk.Viewport{.{ .x = vp.x, .y = vp.y, .width = vp.width, .height = vp.height, .min_depth = vp.min_depth, .max_depth = vp.max_depth }};
        dkb.cmdSetViewport(self.backend.vk.cmd, 0, &v);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        self.backend.mtl.encoder.?.setViewport(.{ .origin_x = vp.x, .origin_y = vp.y, .width = vp.width, .height = vp.height, .znear = vp.min_depth, .zfar = vp.max_depth });
        return;
    }
    unreachable;
}

pub fn set_scissor(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, rect: Rect) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var s = [_]rhi.vulkan.vk.Rect2D{.{ .offset = .{ .x = rect.x, .y = rect.y }, .extent = .{ .width = rect.width, .height = rect.height } }};
        dkb.cmdSetScissor(self.backend.vk.cmd, 0, &s);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        self.backend.mtl.encoder.?.setScissorRect(.{ .x = @intCast(rect.x), .y = @intCast(rect.y), .width = rect.width, .height = rect.height });
        return;
    }
    unreachable;
}

pub fn bind_pipeline(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, pipeline: *rhi.Pipeline) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdBindPipeline(self.backend.vk.cmd, .graphics, pipeline.backend.vk.pipeline);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        self.backend.mtl.encoder.?.setRenderPipelineState(pipeline.backend.mtl.state);
        if (pipeline.backend.mtl.depth_stencil_state) |dss| {
            self.backend.mtl.encoder.?.setDepthStencilState(dss);
        }
        return;
    }
    unreachable;
}

pub fn draw(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, options: struct {
    vertex_count: u32,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdDraw(self.backend.vk.cmd, options.vertex_count, options.instance_count, options.first_vertex, options.first_instance);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        self.backend.mtl.encoder.?.drawPrimitives(.triangle, options.first_vertex, options.vertex_count);
        return;
    }
    unreachable;
}

pub fn clear_attachment_regions(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, options: struct {
    regions: []const struct { color: [4]f32, rect: Rect },
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        for (options.regions) |r| {
            var clear_rect = [_]rhi.vulkan.vk.ClearRect{.{
                .rect = .{ .offset = .{ .x = r.rect.x, .y = r.rect.y }, .extent = .{ .width = r.rect.width, .height = r.rect.height } },
                .base_array_layer = 0,
                .layer_count = 1,
            }};
            var clear_att = [_]rhi.vulkan.vk.ClearAttachment{.{
                .aspect_mask = .{ .color_bit = true },
                .color_attachment = 0,
                .clear_value = .{ .color = .{ .float_32 = r.color } },
            }};
            dkb.cmdClearAttachments(self.backend.vk.cmd, clear_att[0..], clear_rect[0..]);
        }
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        // Metal cannot clear sub-rects inside a pass; the begin_rendering load
        // action already cleared the whole attachment. Per-quadrant fills would
        // need solid-color draws (a follow-up).
        return;
    }
    unreachable;
}

pub const IndexType = enum { uint16, uint32 };

pub fn bind_vertex_buffer(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, buffer: *rhi.Buffer, slot: u32) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const buffers = [_]rhi.vulkan.vk.Buffer{buffer.backend.vk.buffer};
        const offsets = [_]rhi.vulkan.vk.DeviceSize{0};
        dkb.cmdBindVertexBuffers(self.backend.vk.cmd, slot, &buffers, &offsets);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        self.backend.mtl.encoder.?.setVertexBuffer(buffer.backend.mtl.buffer, 0, rhi.pipeline.mtl_vertex_buffer_base + slot);
        return;
    }
    unreachable;
}

pub fn bind_index_buffer(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, buffer: *rhi.Buffer, index_type: IndexType) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdBindIndexBuffer(self.backend.vk.cmd, buffer.backend.vk.buffer, 0, switch (index_type) {
            .uint16 => .uint16,
            .uint32 => .uint32,
        });
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        self.backend.mtl.index_buffer = buffer.backend.mtl.buffer;
        self.backend.mtl.index_type = switch (index_type) {
            .uint16 => .uint16,
            .uint32 => .uint32,
        };
        return;
    }
    unreachable;
}

pub fn draw_indexed(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, options: struct {
    index_count: u32,
    instance_count: u32 = 1,
    first_index: u32 = 0,
    vertex_offset: i32 = 0,
}) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdDrawIndexed(self.backend.vk.cmd, options.index_count, options.instance_count, options.first_index, options.vertex_offset, 0);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
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
    unreachable;
}

/// Set vertex-stage push constants (Vulkan) / inline vertex bytes (Metal).
pub fn set_push_constants(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, pipeline: *rhi.Pipeline, bytes: []const u8) void {
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.cmdPushConstants(self.backend.vk.cmd, pipeline.backend.vk.layout, .{ .vertex_bit = true }, 0, @intCast(bytes.len), bytes.ptr);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        // slangc places the vertex push-constant block at buffer index 0.
        self.backend.mtl.encoder.?.setVertexBytes(bytes.ptr, bytes.len, 0);
        return;
    }
    unreachable;
}

//pub fn resourceBarrier(self: *Cmd, allocator: std.mem.Allocator, renderer: *rhi.Renderer, options: struct {
//    image_barrier: []const rhi.Image.Barrier,
//}) void {
//    if (rhi.is_target_selected(.vk, renderer)) {
//        var vk_image_barriers = try allocator.alloc(volk.c.VkImageMemoryBarrier, options.image_barrier.len);
//        defer allocator.free(vk_image_barriers);
//        for (options.image_barrier, 0..) |barrier, i| {
//            @memcpy(&vk_image_barriers[i], &barrier);
//        }
//        volk.c.vkCmdPipelineBarrier.?(self.backend.vk.cmd, volk.c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, volk.c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, null, 0, null, vk_image_barriers.len, vk_image_barriers.ptr);
//    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
//}
