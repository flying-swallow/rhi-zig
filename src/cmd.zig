const rhi = @import("root.zig");
const vulkan = @import("vulkan.zig");
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
    backend: union(rhi.Backend) {
        vk: rhi.wrapper_platform_type(.vk, struct {
            queue: *rhi.Queue,
            pool: rhi.vulkan.vk.CommandPool,
        }),
        dx12: rhi.wrapper_platform_type(.dx12, struct {}),
        mtl: void, // Metal does not use command pools
    },

    pub fn reset(self: *Self, renderer: *rhi.Renderer, device: *rhi.Device) !void {
        if (rhi.is_target_selected(.vk, renderer)) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            try dkb.resetCommandPool(device.backend.vk.device, self.backend.vk.pool, .{});
            return;
        } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
        unreachable;
    }

    pub fn init(renderer: *rhi.Renderer, device: *rhi.Device, queue: *rhi.Queue) !Self {
        if (rhi.is_target_selected(.vk, renderer)) {
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
        } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
        return error.UnsupportedBackend;
    }
};

pub const CommandringElement = struct {
    pub const Self = @This();
    cmds: []rhi.Cmd,
    pool: *rhi.Pool,
    backend: union {
        vk: rhi.wrapper_platform_type(.vk, struct {
            semaphore: rhi.vulkan.vk.Semaphore = .null_handle,
            fence: rhi.vulkan.vk.Fence = .null_handle,
        }),
        dx12: rhi.wrapper_platform_type(.dx12, struct {}),
        mtl: rhi.wrapper_platform_type(.mtl, struct {}),
    },

    pub fn wait(self: *Self, renderer: *rhi.Renderer, device: *rhi.Device) !void {
        if (rhi.is_target_selected(.vk, renderer)) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            var fences = [_]rhi.vulkan.vk.Fence{self.backend.vk.fence};
            _ = try dkb.waitForFences(device.backend.vk.device, 1, fences[0..].ptr, .true, std.math.maxInt(u64));
        } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
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
            vk: rhi.wrapper_platform_type(.vk, struct {
                fences: if (options.sync_primative) [options.pool_count][options.cmd_per_pool]rhi.vulkan.vk.Fence else void,
                semaphores: if (options.sync_primative) [options.pool_count][options.cmd_per_pool]rhi.vulkan.vk.Semaphore else void,
            }),
            dx12: rhi.wrapper_platform_type(.dx12, struct {}),
            mtl: rhi.wrapper_platform_type(.mtl, struct {}),
        },
        pub fn advance(self: *Self) void {
            self.pool_index = (self.cmd_index + 1) % options.pool_count;
            self.cmd_index = 0;
            self.fence_index = 0;
        }
        pub fn get(self: *Self, renderer: *rhi.Renderer, num_cmds: usize) CommandringElement {
            if (rhi.is_target_selected(.vk, renderer)) {
                std.debug.assert(num_cmds <= options.cmd_per_pool);
                std.debug.assert(num_cmds + self.cmd_index <= options.cmd_per_pool);
                const result = CommandringElement{ .cmds = self.cmds[self.pool_index][self.cmd_index .. self.cmd_index + num_cmds], .pool = &self.pools[self.pool_index], .backend = .{ .vk = .{
                    .semaphore = if (options.sync_primative) self.backend.vk.semaphores[self.pool_index][self.fence_index] else null,
                    .fence = if (options.sync_primative) self.backend.vk.fences[self.pool_index][self.fence_index] else null,
                } } };
                self.fence_index += 1;
                self.cmd_index += num_cmds;
                return result;
            }
            unreachable;
        }
        pub fn init(renderer: *rhi.Renderer, device: *rhi.Device, queue: *rhi.Queue) !Self {
            if (rhi.is_target_selected(.vk, renderer)) {
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
            } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}

            unreachable; // should never reach here
        }

        pub fn deinit(self: *Self, renderer: *rhi.Renderer, device: *rhi.Device) void {
            if (rhi.is_target_selected(.vk, renderer)) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                for (0..options.pool_count) |pool_index| {
                    if (options.sync_primative) {
                        for (0..options.cmd_per_pool) |cmd_index| {
                            dkb.destroySemaphore(device.backend.vk.device, self.backend.vk.semaphores[pool_index][cmd_index], null);
                            dkb.destroyFence(device.backend.vk.device, self.backend.vk.fences[pool_index][cmd_index], null);
                        }
                    }
                    for(0..options.cmd_per_pool) |cmd_index| {
                        self.cmds[pool_index][cmd_index].deinit(renderer, device, &self.pools[pool_index]);
                    }
                    dkb.destroyCommandPool(device.backend.vk.device, self.pools[pool_index].backend.vk.pool, null);
                }
            } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
        }
    };
}

pub const Cmd = @This();
backend: union(rhi.Backend) {
    vk: rhi.wrapper_platform_type(.vk, struct {
        cmd: rhi.vulkan.vk.CommandBuffer,
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
},

pub fn init(renderer: *rhi.Renderer, device: *rhi.Device, pool: *Pool) !Cmd {
    if (rhi.is_target_selected(.vk, renderer)) {
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
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
    return error.UnsupportedBackend;
}

pub fn deinit(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device, pool: *Pool) void {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var command = [_]rhi.vulkan.vk.CommandBuffer {
            self.backend.vk.cmd,
        };
        dkb.freeCommandBuffers(device.backend.vk.device, pool.backend.vk.pool, command.len, command[0..].ptr );
        return;
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
    unreachable;
}

pub fn begin(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device) !void {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var begin_info = rhi.vulkan.vk.CommandBufferBeginInfo{
            .s_type = .command_buffer_begin_info,
            .flags = .{
                .one_time_submit_bit = true,
            },
        };
        try dkb.beginCommandBuffer(self.backend.vk.cmd, &begin_info);
        return;
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
    unreachable;
}

pub fn end(self: *Cmd, renderer: *rhi.Renderer, device: *rhi.Device) !void {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        try dkb.endCommandBuffer(self.backend.vk.cmd);
        return;
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
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
