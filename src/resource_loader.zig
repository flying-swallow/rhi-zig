// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const vma = @import("root.zig").vma;
const std = @import("std");
const vulkan = @import("root.zig").vulkan;

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

    // Resource state the texture is left in after the upload copy completes.
    // The pre-copy transition is always undefined -> copy_dst; this is the
    // post-copy target (e.g. shader_resource for a sampled texture). Emitted
    // through the backend-neutral barrier API (Cmd.image_barrier).
    final_state: rhi.Cmd.ResourceState = .{ .shader_resource = true },
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
        resource_mutex: std.Io.Mutex = .init,
        upload_resource: TransferCommandGroup = undefined,
        copy_resource: TransferCommandGroup = undefined,

        is_running: bool = true,

        queue_mutex: std.Io.Mutex = .init,
        queue_cond: std.Io.Condition = .init,
        upload_queue: std.ArrayList(UploadJob) = std.ArrayList(UploadJob).empty,

        pub fn acquire_cmd(self: *Self, device: *rhi.Device, copy_set: *TransferCommandGroup) !rhi.Cmd {
            _ = self;
            if (!copy_set.is_recording) {
                if (rhi.is_target_selected(.vk)) {
                    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                    const fences = [_]rhi.vulkan.vk.Fence{copy_set.backend.vk.fences[copy_set.active_set]};
                    if (try dkb.getFenceStatus(device.backend.vk.device, fences[0]) == .not_ready) {
                        _ = dkb.waitForFences(device.backend.vk.device, fences[0..], .true, std.math.maxInt(u64)) catch unreachable;
                    }
                }
                copy_set.staging_buffer_offset = 0;
                for (copy_set.temporary_buffers.items) |buf| {
                    vma.c.vmaDestroyBuffer(device.backend.vk.vma_allocator, @ptrFromInt(@intFromEnum(buf.backend.vk.buffer)), buf.backend.vk.allocation);
                }
                copy_set.temporary_buffers.clearRetainingCapacity();
                try copy_set.pool[copy_set.active_set].reset(device);
                try copy_set.cmd[copy_set.active_set].begin(device);
                copy_set.is_recording = true;
            }
            return copy_set.cmd[copy_set.active_set];
        }

        pub fn allocate_temporary_buffer(self: *Self, device: *rhi.Device, group: *TransferCommandGroup, size: usize) !rhi.Buffer.MappedMemoryRange {
            var temporary_buffer: rhi.Buffer = result: {
                if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                    const allocation_info = vma.c.VmaAllocationCreateInfo{
                        .usage = vma.c.VMA_MEMORY_USAGE_AUTO,
                        .flags = vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT | vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
                    };
                    const stage_buffer_create_info = rhi.vulkan.vk.BufferCreateInfo{ .size = size, .sharing_mode = .exclusive, .usage = .{
                        .transfer_src = true,
                        .transfer_dst = true,
                    } };
                    var vma_info = vma.c.VmaAllocationInfo{};
                    var vk_buffer: vma.c.VkBuffer = undefined;
                    var vma_alloc: vma.c.VmaAllocation = undefined;
                    try vulkan.VKWrapResult(@enumFromInt(vma.c.vmaCreateBuffer(device.backend.vk.vma_allocator, @ptrCast(&stage_buffer_create_info), &allocation_info, &vk_buffer, &vma_alloc, &vma_info)));
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
            //            .transfer_src = true,
            //            .transfer_dst = true,
            //        } };
            //    const vma_info = vma.c.VmaAllocationInfo{};
            //    try rhi.vulkan.VKWrapResult(@enumFromInt(vma.c.vmaCreateBuffer(device.backend.vk.vma_allocator, &stage_buffer_create_info, &allocation_info, &res.backend.vk.buffer, &res.backend.vk.allocation, &vma_info)));
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

        fn deinit_command_group(self: *Self, device: *rhi.Device, group: *TransferCommandGroup) void {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            for (group.temporary_buffers.items[0..]) |*buf| {
                buf.deinit(device);
            }
            for (0..config.max_sets) |i| {
                group.cmd[i].deinit(device, &group.pool[i]);
                group.pool[i].deinit(device);
            }
            for(group.staging_buffer[0..]) |*buf| {
                buf.deinit(device);
            }
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                for(group.backend.vk.semaphores) |sem| {
                    dkb.destroySemaphore(device.backend.vk.device, sem, null);
                }
                for(group.backend.vk.fences) |fen| {
                    dkb.destroyFence(device.backend.vk.device, fen, null);
                }

            }
            group.temporary_buffers.deinit(self.allocator);   
        }
        fn init_resource_copy_queue(queue: *rhi.Queue, device: *rhi.Device) !TransferCommandGroup {
            var staging_buffer: [config.max_sets]rhi.Buffer = undefined;

            var pool: [config.max_sets]rhi.Pool = undefined;
            var cmd: [config.max_sets]rhi.Cmd = undefined;
            for (0..config.max_sets) |i| {
                pool[i] = try rhi.Pool.init(device, queue);
                cmd[i] = try rhi.Cmd.init(device, &pool[i]);

                if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                    const allocation_info = vma.c.VmaAllocationCreateInfo{
                        .usage = vma.c.VMA_MEMORY_USAGE_AUTO,
                        .flags = vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT | vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
                    };
                    const stage_buffer_create_info = rhi.vulkan.vk.BufferCreateInfo{ .size = config.buffer_size, .sharing_mode = .exclusive, .usage = .{
                        .transfer_src = true,
                        .transfer_dst = true,
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
                    if (rhi.is_target_selected(.vk)) {
                        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                        var semaphore_create_info: rhi.vulkan.vk.SemaphoreCreateInfo = .{};
                        var fence_create_info: rhi.vulkan.vk.FenceCreateInfo = .{
                            .flags =  .{ .signaled = true } ,
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

        pub fn init(allocator: std.mem.Allocator, device: *rhi.Device) !Self {
            var res = Self {
                .allocator = allocator,
            };
            res.upload_resource = try init_resource_copy_queue(&device.graphics_queue, device);
            res.copy_resource = try init_resource_copy_queue(if (device.transfer_queue) |*t| t else &device.graphics_queue, device);
            return res;
        }

        pub fn VKFlushResourceUpdate(self: *Self, io: std.Io, device: *rhi.Device, wait_semaphore_info: []rhi.vulkan.vk.SemaphoreSubmitInfo) !struct { fence: rhi.vulkan.vk.Fence, semaphore: rhi.vulkan.vk.Semaphore, signaled: bool } {
            std.debug.assert(rhi.renderer.target_api() == .vk);
            try self.resource_mutex.lock(io);
            defer self.resource_mutex.unlock(io);

            const group: *TransferCommandGroup = &self.upload_resource;
            const active_set = group.active_set;
            if (!self.upload_resource.is_recording) {
                return .{ .fence = group.backend.vk.fences[active_set], .semaphore = group.backend.vk.semaphores[active_set], .signaled = false };
            }
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            try group.cmd[group.active_set].end(device);
            const cmd_submit = [_]rhi.vulkan.vk.CommandBufferSubmitInfo{.{
                .command_buffer = group.cmd[group.active_set].backend.vk.cmd,
                .device_mask = 0,
            }};

            const signal_semaphore = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
                .semaphore = group.backend.vk.semaphores[group.active_set],
                .value = 0,
                .stage_mask = .{ .all_transfer = true },
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

            std.debug.assert(try dkb.getFenceStatus(device.backend.vk.device, group.backend.vk.fences[group.active_set]) == .success);
            const reset_fence = [_]rhi.vulkan.vk.Fence{group.backend.vk.fences[group.active_set]};
            _ = try dkb.resetFences(device.backend.vk.device, reset_fence[0..]);

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
        //    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        //    cmd.end(self.device);

        //    const cmd_submit = [_]rhi.vulkan.vk.CommandBufferSubmitInfo{.{
        //        .command_buffer = cmd.backend.vk.cmd,
        //        .device_mask = 0,
        //    }};

        //    const wait_semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
        //        .semaphore = semaphore.backend.vk.current_semaphore(),
        //        .stage_mask = .{ .color_attachment_output = true },
        //        .value = 0,
        //        .device_index = 0,
        //    }};

        //    const semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
        //        .semaphore = semaphore.backend.vk.semaphore,
        //        .value = 0,
        //        .stage_mask = .{
        //            .all_commands = true,
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


        pub fn deinit(self: *Self, device: *rhi.Device) void {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                self.deinit_command_group(device, &self.upload_resource);
                self.deinit_command_group(device, &self.copy_resource);
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

        pub fn begin_copy_buffer(self: *Self, io: std.Io, device: *rhi.Device, transaction: *BufferTransaction) !void {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                try self.resource_mutex.lock(io);
                defer self.resource_mutex.unlock(io);
                _ = try self.acquire_cmd(device, &self.upload_resource);
                transaction.mapped = res: {
                    if (allocate_from_stage_buffer(&self.upload_resource, transaction.size, 4)) |s| {
                        break :res s;
                    } else {
                        break :res try self.allocate_temporary_buffer(device, &self.upload_resource, transaction.size);
                    }
                };
                return;
            }
            unreachable;
        }

        pub fn end_copy_buffer(self: *Self, io: std.Io, device: *rhi.Device, transaction: *BufferTransaction) !void {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                var buffer_copy = [_]rhi.vulkan.vk.BufferCopy{.{
                    .src_offset = transaction.mapped.offset,
                    .dst_offset = transaction.offset,
                    .size = transaction.size,
                }};
                try self.resource_mutex.lock(io);
                defer self.resource_mutex.unlock(io);
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                const cmd = try self.acquire_cmd(device, &self.upload_resource);
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

        pub fn begin_copy_texture(self: *Self, io: std.Io, device: *rhi.Device, transaction: *TextureTransaction) !void {
            const format_props = rhi.format.GetProps(transaction.format);
            const aligned_row_pitch = std.mem.alignForward(usize, transaction.row_pitch, device.adapter.upload_buffer_texture_row_alignment);
            const aligned_slice_pitch = transaction.slice_num * aligned_row_pitch;
            transaction.align_row_pitch = @intCast(aligned_row_pitch);
            transaction.align_slice_pitch = @intCast(aligned_slice_pitch);

            // bufferOffset must be a multiple of the texel block size and the device's
            // optimalBufferCopyOffsetAlignment (Vulkan spec, vkCmdCopyBufferToImage).
            var offset_align: usize = device.adapter.upload_buffer_offset_alignment;
            if (format_props.stride > offset_align) offset_align = format_props.stride;
            if (offset_align < 4) offset_align = 4;

            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                try self.resource_mutex.lock(io);
                defer self.resource_mutex.unlock(io);
                _ = try self.acquire_cmd(device, &self.upload_resource);
                transaction.mapped = res: {
                    if (allocate_from_stage_buffer(&self.upload_resource, aligned_slice_pitch, offset_align)) |s| {
                        break :res s;
                    } else {
                        break :res try self.allocate_temporary_buffer(device, &self.upload_resource, aligned_slice_pitch);
                    }
                };
                return;
            }
            unreachable;
        }

        pub fn end_copy_texture(self: *Self, io: std.Io, device: *rhi.Device, transaction: *TextureTransaction) !void {
            const format_props = rhi.format.GetProps(transaction.format);
            // bufferRowLength / bufferImageHeight describe the layout of the staging
            // buffer in texels, and must match the strides the CPU used to write it
            // (the aligned row pitch, which can be 256-byte aligned on NVIDIA).
            const row_block_num = transaction.align_row_pitch / format_props.stride;
            const buffer_row_length = row_block_num * format_props.block_width;
            const slice_row_num = transaction.align_slice_pitch / transaction.align_row_pitch;
            const buffer_image_height = slice_row_num * format_props.block_height;
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                try self.resource_mutex.lock(io);
                defer self.resource_mutex.unlock(io);
                var cmd = try self.acquire_cmd(device, &self.upload_resource);

                // undefined -> copy_dst for the subresource being written.
                cmd.image_barrier(device, .{
                    .image = &transaction.target,
                    .before = .{},
                    .after = .{ .copy_dst = true },
                    .base_mip = @intCast(transaction.mip_offset),
                    .mip_count = 1,
                    .base_layer = @intCast(transaction.array_offset),
                    .layer_count = 1,
                });

                cmd.copy_buffer_to_texture(device, .{
                    .src = transaction.mapped.buffer,
                    .dst = &transaction.target,
                    .buffer_offset = @intCast(transaction.mapped.offset),
                    .buffer_row_length = buffer_row_length,
                    .buffer_image_height = buffer_image_height,
                    .mip_level = transaction.mip_offset,
                    .base_array_layer = transaction.array_offset,
                    .layer_count = 1,
                    .x = transaction.x,
                    .y = transaction.y,
                    .z = transaction.z,
                    .width = transaction.width,
                    .height = transaction.height,
                    .depth = transaction.depth,
                });

                // copy_dst -> the caller's requested final state.
                cmd.image_barrier(device, .{
                    .image = &transaction.target,
                    .before = .{ .copy_dst = true },
                    .after = transaction.final_state,
                    .base_mip = @intCast(transaction.mip_offset),
                    .mip_count = 1,
                    .base_layer = @intCast(transaction.array_offset),
                    .layer_count = 1,
                });
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
