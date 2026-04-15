const rhi = @import("root.zig");
const vma = @import("vma");
const std = @import("std");
const vulkan = @import("vulkan.zig");

//pub const ResourceLoader = @This();
pub const ResourceConfig = struct {
    max_sets: usize,
    buffer_size: usize,
};

pub const DefaultResourceConfig = ResourceConfig{
    .max_sets = 2,
    .buffer_size = 8 * (1024 * 1024), // 8 MB
};

pub const BufferTransaction = struct {
    target: *rhi.Buffer,
    offset: usize,
    size: usize,

    // begin mapping
    mapped: rhi.Buffer.MappedMemoryRange = undefined,

    //internal: struct { mapped_region: rhi.Buffer.MappedMemoryRange = .{} },
};

pub const TextureTransaction = struct {
    target: rhi.Image,

    // https://github.com/microsoft/DirectXTex/wiki/Image
    format: rhi.Format, // RI_Format_e
    slice_num: u32,
    row_pitch: u32,

    x: u16,
    y: u16,
    z: u16,
    width: u32,
    height: u32,
    depth: u32,

    array_offset: u32,
    mip_offset: u32,

    // begin mapping
    align_row_pitch: u32,
    align_slice_pitch: u32,
    mapped: rhi.Buffer.MappedMemoryRange,
};

const ResourceJobType = enum {};
const UploadJob = struct {
    inner: union(ResourceJobType) {},
};

// ResourceLoader manages transfers of resources to the GPU
// Note: make sure buffers/images are associated with the currect device create additional resource loaders for different devices
pub fn ResourceLoader(comptime config: ResourceConfig) type {
    return struct {
        pub const Self = @This();
        pub const ResourceSet = struct {};

        pub const TransferCommandGroup = struct {
            queue: *rhi.Queue,
            pool: [config.max_sets]rhi.Pool,
            cmd: [config.max_sets]rhi.Cmd,

            is_recording: bool = false,

            staging_buffer: [config.max_sets]rhi.Buffer,
            staging_buffer_offset: usize = 0,

            temporary_buffers: std.ArrayList(rhi.Buffer),
            active_set: usize = 0,

            // zig fmt: off
            backend: union { 
                vk: if (rhi.platform_has_api(.vk)) struct { 
                        semaphores: [config.max_sets]rhi.vulkan.vk.Semaphore, 
                        fences: [config.max_sets]rhi.vulkan.vk.Fence 
                    } else void 
            },
            // zig fmt: on
        };
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        resource_mutex: std.Io.Mutex = .init,
        upload_resource: TransferCommandGroup = undefined,
        copy_resource: TransferCommandGroup = undefined,

        is_running: bool = true,

        queue_mutex: std.Io.Mutex = .init,
        queue_cond: std.Io.Condition = .init,
        upload_queue: std.ArrayList(UploadJob) = std.ArrayList(UploadJob).empty,

        pub fn acquire_cmd(self: *Self, renderer: *rhi.Renderer, copy_set: *TransferCommandGroup) !rhi.Cmd {
            if (!copy_set.is_recording) {
                if (rhi.is_target_selected(.vk, renderer)) {
                    var dkb: *rhi.vulkan.vk.DeviceWrapper = &self.device.backend.vk.dkb;
                    const fences = [_]rhi.vulkan.vk.Fence{copy_set.backend.vk.fences[copy_set.active_set]};
                    if (try dkb.getFenceStatus(self.device.backend.vk.device, fences[0]) == .not_ready) {
                        _ = dkb.waitForFences(self.device.backend.vk.device, fences[0..], .true, std.math.maxInt(u64)) catch unreachable;
                    }
                }
                copy_set.staging_buffer_offset = 0;
                for (copy_set.temporary_buffers.items) |buf| {
                    vma.c.vmaDestroyBuffer(self.device.backend.vk.vma_allocator, @ptrFromInt(@intFromEnum(buf.backend.vk.buffer)), buf.backend.vk.allocation);
                }
                copy_set.temporary_buffers.clearRetainingCapacity();
                try copy_set.pool[copy_set.active_set].reset(renderer, self.device);
                try copy_set.cmd[copy_set.active_set].begin(renderer, self.device);
                copy_set.is_recording = true;
            }
            return copy_set.cmd[copy_set.active_set];
        }

        pub fn allocate_temporary_buffer(self: *Self, renderer: *rhi.Renderer, group: *TransferCommandGroup, size: usize) !rhi.Buffer.MappedMemoryRange {
            var temporary_buffer: rhi.Buffer = result: {
                if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                    const allocation_info = vma.c.VmaAllocationCreateInfo{
                        .usage = vma.c.VMA_MEMORY_USAGE_AUTO,
                        .flags = vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT | vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
                    };
                    const stage_buffer_create_info = rhi.vulkan.vk.BufferCreateInfo{ .size = size, .sharing_mode = .exclusive, .usage = .{
                        .transfer_src_bit = true,
                        .transfer_dst_bit = true,
                    } };
                    var vma_info = vma.c.VmaAllocationInfo{};
                    var vk_buffer: vma.c.VkBuffer = undefined;
                    var vma_alloc: vma.c.VmaAllocation = undefined;
                    try vulkan.VKWrapResult(@enumFromInt(vma.c.vmaCreateBuffer(self.device.backend.vk.vma_allocator, @ptrCast(&stage_buffer_create_info), &allocation_info, &vk_buffer, &vma_alloc, &vma_info)));
                    break :result .{
                        .backend = .{ .vk = .{
                            .buffer = @enumFromInt(@intFromPtr(vk_buffer)),
                            .allocation = vma_alloc,
                        } },
                        .mapped_region = @as([*c]u8, @ptrCast(vma_info.pMappedData))[0..size],
                    };
                }
                unreachable;
            };

            //const temporary_buffer: rhi.Buffer = if (rhi.is_target_selected(.vk, renderer)) result: {
            //    var res: rhi.Buffer = undefined;
            //    const allocation_info = vma.c.VmaAllocationCreateInfo{
            //        .usage = vma.c.VMA_MEMORY_USAGE_AUTO,
            //        .flags = vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT | vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
            //    };
            //    const stage_buffer_create_info = rhi.vulkan.vk.BufferCreateInfo{
            //        .size = size,
            //        .sharing_mode = .exclusive,
            //        .usage = .{
            //            .transfer_src_bit = true,
            //            .transfer_dst_bit = true,
            //        } };
            //    const vma_info = vma.c.VmaAllocationInfo{};
            //    try rhi.vulkan.VKWrapResult(@enumFromInt(vma.c.vmaCreateBuffer(self.device.backend.vk.vma_allocator, &stage_buffer_create_info, &allocation_info, &res.backend.vk.buffer, &res.backend.vk.allocation, &vma_info)));
            //    res.mapped_region = @as([*c]u8, @ptrCast(vma_info.pMappedData))[0..size];
            //    break :result res;
            //} else if (rhi.is_target_selected(.dx12, renderer)) {
            //    @compileError("Metal staging buffer not implemented");
            //} else if (rhi.is_target_selected(.mtl, renderer)) {
            //    @compileError("Metal staging buffer not implemented");
            //};
            try group.temporary_buffers.append(self.allocator, temporary_buffer);

            return temporary_buffer.get_mapped_region(0, size);
        }

        pub fn allocate_from_stage_buffer(group: *TransferCommandGroup, size: usize, alignment: usize) ?rhi.Buffer.MappedMemoryRange {
            const memory_request_size = std.mem.alignForward(usize, size, alignment);
            const staged_offset = std.mem.alignForward(usize, group.staging_buffer_offset, alignment);
            if ((staged_offset < config.buffer_size) and memory_request_size <= (config.buffer_size - staged_offset)) {
                group.staging_buffer_offset = staged_offset + memory_request_size;
                return group.staging_buffer[group.active_set].get_mapped_region(staged_offset, memory_request_size) catch unreachable;
            }
            return null;
        }

        //pub fn allocate_stage_memory(self: *Self, renderer: *rhi.Renderer, group: *TransferCommandGroup, size: usize, alignment: usize) !?rhi.Buffer.MappedMemoryRange {
        //    const memory_request_size = std.mem.alignForward(usize, size, alignment);
        //    if (memory_request_size > config.buffer_size) {
        //        std.log.info("Requested size {}/{} exceeds staging buffer size {}", .{ size, memory_request_size, config.buffer_size });
        //        return try self.allocate_temporary_buffer(group, renderer, memory_request_size);
        //    }

        //    const staged_offset = std.mem.alignForward(usize, self.staging_buffer_offset, alignment);
        //    const memory_available = (staged_offset < config.buffer_size) and memory_request_size <= (config.buffer_size - staged_offset);
        //    if (memory_available) {
        //        self.staging_buffer_offset = staged_offset + memory_request_size;
        //        return try self.staging_buffer[self.active_set].get_mapped_region(staged_offset, memory_request_size);
        //    } else {
        //        return null;
        //        //group.active_set = (group.active_set + 1) % config.max_sets;
        //        //return .{
        //        //    .buffer = &self.staging_buffer[self.active_set],
        //        //    .memory_range = undefined,
        //        //};
        //    }
        //}

        fn deinit_command_group(self: *Self, group: *TransferCommandGroup, renderer: *rhi.Renderer) void {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &self.device.backend.vk.dkb;
            for (group.temporary_buffers.items[0..]) |*buf| {
                buf.deinit(renderer, self.device);
            }
            for (0..config.max_sets) |i| {
                group.cmd[i].deinit(renderer, self.device, &group.pool[i]);
                group.pool[i].deinit(renderer, self.device);
            }
            for(group.staging_buffer[0..]) |*buf| {
                buf.deinit(renderer, self.device);
            }
            if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                for(group.backend.vk.semaphores) |sem| {
                    dkb.destroySemaphore(self.device.backend.vk.device, sem, null);
                }
                for(group.backend.vk.fences) |fen| {
                    dkb.destroyFence(self.device.backend.vk.device, fen, null);
                }

            }
            group.temporary_buffers.deinit(self.allocator);   
        }
        fn init_resource_copy_queue(renderer: *rhi.Renderer, queue: *rhi.Queue, device: *rhi.Device) !TransferCommandGroup {
            var staging_buffer: [config.max_sets]rhi.Buffer = undefined;

            var pool: [config.max_sets]rhi.Pool = undefined;
            var cmd: [config.max_sets]rhi.Cmd = undefined;
            for (0..config.max_sets) |i| {
                pool[i] = try rhi.Pool.init(renderer, device, queue);
                cmd[i] = try rhi.Cmd.init(renderer, device, &pool[i]);

                if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                    const allocation_info = vma.c.VmaAllocationCreateInfo{
                        .usage = vma.c.VMA_MEMORY_USAGE_AUTO,
                        .flags = vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT | vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
                    };
                    const stage_buffer_create_info = rhi.vulkan.vk.BufferCreateInfo{ .size = config.buffer_size, .sharing_mode = .exclusive, .usage = .{
                        .transfer_src_bit = true,
                        .transfer_dst_bit = true,
                    } };
                    var vma_info = vma.c.VmaAllocationInfo{};
                    var vk_buffer: vma.c.VkBuffer = undefined;
                    var vma_alloc: vma.c.VmaAllocation = undefined;
                    try vulkan.VKWrapResult(@enumFromInt(vma.c.vmaCreateBuffer(device.backend.vk.vma_allocator, @ptrCast(&stage_buffer_create_info), &allocation_info, &vk_buffer, &vma_alloc, &vma_info)));
                    staging_buffer[i] = .{
                        .backend = .{ .vk = .{
                            .buffer = @enumFromInt(@intFromPtr(vk_buffer)),
                            .allocation = vma_alloc,
                        } },
                        .mapped_region = @as([*c]u8, @ptrCast(vma_info.pMappedData))[0..config.buffer_size],
                    };
                } else {
                    std.debug.panic("TODO", .{});
                }
                //stage_buffers[i]

            }
            // zig fmt: off
            return .{
                .queue = queue,
                .pool = pool, 
                .cmd = cmd, 
                .staging_buffer = staging_buffer,
                .temporary_buffers = .empty,
                .backend = res: {
                    if (rhi.is_target_selected(.vk, renderer)) {
                        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                        var semaphore_create_info: rhi.vulkan.vk.SemaphoreCreateInfo = .{};
                        var fence_create_info: rhi.vulkan.vk.FenceCreateInfo = .{
                            .flags =  .{ .signaled_bit = true } ,
                        };
                        var semaphores: [config.max_sets]rhi.vulkan.vk.Semaphore = undefined;
                        var fences: [config.max_sets]rhi.vulkan.vk.Fence = undefined; 
                        for (0..config.max_sets) |i| {
                            semaphores[i] = try dkb.createSemaphore(device.backend.vk.device, &semaphore_create_info, null);
                            fences[i] = try dkb.createFence(device.backend.vk.device, &fence_create_info, null);
                        }
                        break :res .{ .vk = .{
                            .semaphores = semaphores,
                            .fences = fences
                        } };
                    }
                    unreachable;
                } };
            // zig fmt: on
        }

        pub fn init(allocator: std.mem.Allocator, renderer: *rhi.Renderer, device: *rhi.Device) !Self {
            var res = Self {
                .allocator = allocator,
                .device = device,
            };
            res.upload_resource = try init_resource_copy_queue(renderer, &device.graphics_queue, device);
            res.copy_resource = try init_resource_copy_queue(renderer, if (device.transfer_queue) |*t| t else &device.graphics_queue, device);
            return res;
        }

        pub fn VKFlushResourceUpdate(self: *Self, io: std.Io, renderer: *rhi.Renderer, wait_semaphore_info: []rhi.vulkan.vk.SemaphoreSubmitInfo) !struct { fence: rhi.vulkan.vk.Fence, semaphore: rhi.vulkan.vk.Semaphore, signaled: bool } {
            std.debug.assert(renderer.target_api() == .vk);
            try self.resource_mutex.lock(io);
            defer self.resource_mutex.unlock(io);

            const group: *TransferCommandGroup = &self.upload_resource;
            const active_set = group.active_set;
            if (!self.upload_resource.is_recording) {
                return .{ .fence = group.backend.vk.fences[active_set], .semaphore = group.backend.vk.semaphores[active_set], .signaled = false };
            }
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &self.device.backend.vk.dkb;
            try group.cmd[group.active_set].end(renderer, self.device);
            const cmd_submit = [_]rhi.vulkan.vk.CommandBufferSubmitInfo{.{
                .command_buffer = group.cmd[group.active_set].backend.vk.cmd,
                .device_mask = 0,
            }};

            const signal_semaphore = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
                .semaphore = group.backend.vk.semaphores[group.active_set],
                .value = 0,
                .stage_mask = .{ .all_transfer_bit = true },
                .device_index = 0,
            }};

            // zig fmt: off
            var submit_info = [_]rhi.vulkan.vk.SubmitInfo2{.{ 
                .p_command_buffer_infos = cmd_submit[0..].ptr, 
                .command_buffer_info_count = cmd_submit.len, 
                .p_wait_semaphore_infos = wait_semaphore_info[0..].ptr, 
                .wait_semaphore_info_count = @intCast(wait_semaphore_info.len), 
                .p_signal_semaphore_infos = signal_semaphore[0..].ptr, 
                .signal_semaphore_info_count = signal_semaphore.len 
            }};
            // zig fmt: on

            std.debug.assert(try dkb.getFenceStatus(self.device.backend.vk.device, group.backend.vk.fences[group.active_set]) == .success);
            const reset_fence = [_]rhi.vulkan.vk.Fence{group.backend.vk.fences[group.active_set]};
            _ = try dkb.resetFences(self.device.backend.vk.device, reset_fence[0..]);

            try dkb.queueSubmit2(self.upload_resource.queue.backend.vk.queue, submit_info[0..], group.backend.vk.fences[active_set]);
            group.active_set = (group.active_set + 1) % config.max_sets;
            group.is_recording = false;
            return .{ .fence = group.backend.vk.fences[active_set], .semaphore = group.backend.vk.semaphores[active_set], .signaled = true };
        }

        //pub fn flush(self: *Self, renderer: *rhi.Renderer, options: union {
        //    vk: rhi.wrapper_platform_type(.vk, struct {

        //    }),
        //}) union {
        //    vk: rhi.wrapper_platform_type(.vk, struct {}),
        //} {
        //    const pool: rhi.Pool = self.upload_resource.pool[self.upload_resource.active_set];
        //    const cmd: rhi.Cmd = self.upload_resource.cmd[self.upload_resource.active_set];
        //    const fence: rhi.Fence = self.upload_resource.fence[self.upload_resource.active_set];
        //    const semaphore: rhi.Semaphore = self.upload_resource.semaphore[self.upload_resource.active_set];

        //    if (!self.upload_resource.is_recording) {
        //        return .{ fence, semaphore };
        //    }
        //    var dkb: *rhi.vulkan.vk.DeviceWrapper = &self.device.backend.vk.dkb;
        //    cmd.end(renderer, self.device);

        //    const cmd_submit = [_]rhi.vulkan.vk.CommandBufferSubmitInfo{.{
        //        .command_buffer = cmd.backend.vk.cmd,
        //        .device_mask = 0,
        //    }};

        //    const wait_semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
        //        .semaphore = semaphore.backend.vk.current_semaphore(),
        //        .stage_mask = .{ .color_attachment_output_bit = true },
        //        .value = 0,
        //        .device_index = 0,
        //    }};

        //    const semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
        //        .semaphore = semaphore.backend.vk.semaphore,
        //        .value = 0,
        //        .stage_mask = .{
        //            .all_commands_bit = true,
        //        },
        //        .device_index = 0,
        //    }};

        //    var submit_info = [_]rhi.vulkan.vk.SubmitInfo2{.{}};
        //    dkb.queueSubmit2(self.upload_resource.queue, 1, submit_info[0..].ptr, fence.backend.vk.fence);

        //    self.upload_resource.active_set = (self.upload_resource.active_set + 1) % config.max_sets;
        //    return .{ fence, semaphore };
        //}

        // make sure pointer is stable before calling this
        //pub fn spawn(self: *Self) void {
        //    _ = try std.Thread.spawn(.{ .allocator = self.allocator }, Self.upload_thread, self);
        //}


        pub fn deinit(self: *Self, renderer: *rhi.Renderer) void {
            if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                self.deinit_command_group(&self.upload_resource, renderer);
                self.deinit_command_group(&self.copy_resource, renderer);
                //self.upload_queue.deinit(self.allocator);
                return;
            }
            unreachable;
        }

        //fn upload_thread(self: *Self) void {
        //    while (self.is_running) {
        //        self.queue_mutex.lock();
        //        defer self.queue_mutex.unlock();
        //        while (self.is_running and self.upload_queue.len == 0) {
        //            self.queue_cond.wait(&self.queue_mutex);
        //        }
        //    }
        //}

        pub fn begin_copy_buffer(self: *Self, io: std.Io, renderer: *rhi.Renderer, transaction: *BufferTransaction) !void {
            if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                try self.resource_mutex.lock(io);
                defer self.resource_mutex.unlock(io);
                _ = try self.acquire_cmd(renderer, &self.upload_resource);
                transaction.mapped = res: {
                    if (allocate_from_stage_buffer(&self.upload_resource, transaction.size, 4)) |s| {
                        break :res s;
                    } else {
                        break :res try self.allocate_temporary_buffer(renderer, &self.upload_resource, transaction.size);
                    }
                };
                return;
            }
            unreachable;
        }

        pub fn end_copy_buffer(self: *Self, io: std.Io, renderer: *rhi.Renderer, transaction: *BufferTransaction) !void {
            if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                var buffer_copy = [_]rhi.vulkan.vk.BufferCopy{.{
                    .src_offset = transaction.mapped.offset,
                    .dst_offset = transaction.offset,
                    .size = transaction.size,
                }};
                try self.resource_mutex.lock(io);
                defer self.resource_mutex.unlock(io);
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &self.device.backend.vk.dkb;
                const cmd = try self.acquire_cmd(renderer, &self.upload_resource);
                dkb.cmdCopyBuffer(
                    cmd.backend.vk.cmd,
                    transaction.mapped.buffer.backend.vk.buffer,
                    transaction.target.backend.vk.buffer,
                    &buffer_copy,
                );
                return;
            }
            unreachable;
        }

        pub fn begin_copy_texture(self: *Self, renderer: *rhi.Renderer, device: *rhi.Device, transaction: *TextureTransaction) !void {
            const aligned_row_pitch = std.mem.alignForward(usize, transaction.row_pitch, device.adapter.upload_buffer_texture_row_alignment);
            const aligned_slice_pitch = std.mem.alignForward(usize, transaction.slice_num * aligned_row_pitch, device.adapter.upload_buffer_texture_slice_alignment);
            transaction.align_row_pitch = @as(u32, aligned_row_pitch);
            transaction.align_slice_pitch = @as(u32, aligned_slice_pitch);
            if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                self.resource_mutex.lock();
                defer self.resource_mutex.unlock();
                _ = try self.acquire_cmd(renderer, &self.upload_resource);
                transaction.mapped = res: {
                    if (allocate_from_stage_buffer(&self.upload_resource, transaction.align_slice_pitch, 4)) |s| {
                        break :res s;
                    } else {
                        break :res self.allocate_temporary_buffer(renderer, &self.upload_resource, transaction.size, 4);
                    }
                };
                return;
            }
            unreachable;
        }

        pub fn end_copy_texture(self: *Self, renderer: *rhi.Renderer, transaction: *TextureTransaction) !void {
            const format_props = rhi.format.GetProps(transaction.format);
            const row_block_num = transaction.row_pitch / format_props.stride;
            const buffer_row_length = row_block_num * format_props.block_width;

            const slice_row_num = transaction.align_slice_pitch / transaction.row_pitch;
            const buffer_image_height = slice_row_num * format_props.block_width;
            if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
                // zig fmt: off
                var image_copy = rhi.vulkan.vk.BufferImageCopy{ 
                    .buffer_offset = transaction.mapped.offset, 
                    .buffer_row_length = buffer_row_length, 
                    .buffer_image_height = buffer_image_height, 
                    .image_offset = .{
                        .x = transaction.x,
                        .y = transaction.y,
                        .z = transaction.z,
                    }, 
                    .image_extent = .{
                        .width = transaction.width,
                        .height = transaction.height,
                        .depth = transaction.depth,
                    }, 
                    .image_subresource = .{ 
                        .mip_level = transaction.mip_offset, 
                        .base_array_layer = transaction.array_offset, 
                        .layer_count = 1, 
                        .aspect_mask = rhi.vulkan.VKImageAspectFlagsFromFormat(transaction.format)
                    } 
                };
                self.resource_mutex.lock();
                defer self.resource_mutex.unlock();
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &self.device.backend.vk.dkb;
                const cmd = self.acquire_cmd(renderer, &self.upload_resource);
                dkb.cmdCopyBufferToImage(cmd.backend.vk.cmd, 
                    transaction.mapped.buffer.backend.vk.buffer, 
                    transaction.target.backend.vk.image, 
                    .{ .transfer_dst_optimal = true }, 
                    1,
                    &image_copy
                );
                // zig fmt: on
                return;
            }
            unreachable;
        }
    };
}

// initialize a resource loader for a given device

//pub fn Texture(comptime config: rhi.BuildConfig) type {
//    return struct {
//        pub const Self = @This();
//        pub fn init() Self {
//            return Self{
//                .target = .{
//                    .vk = .{
//                        .image = undefined,
//                    },
//                }
//            };
//        }
//
//        target: union(rhi.Backend) {
//            vk: if (config.is_target_supported(.vk)) struct {
//                image: *volk.c.VkImage
//            } else void,
//            dx12: if (config.is_target_supported(.dx12)) struct {
//                // Vulkan-specific fields
//            } else void,
//            mtl: if (config.is_target_supported(.mtl)) struct {
//                // Vulkan-specific fields
//            } else void,
//        }
//    };
//}
