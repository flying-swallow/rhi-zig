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
    target: rhi.Buffer,
    offset: usize,
    size: usize,

    // begin mapping
    mapped: rhi.Buffer.MappedMemoryRange,

    internal: struct { mapped_region: rhi.Buffer.MappedMemoryRange },
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

    src_barrier: rhi.Image.Barrier,
    dst_barrier: rhi.Image.Barrier,

    // begin mapping
    align_row_pitch: u32,
    align_slice_pitch: u32,
    mapped: rhi.Buffer.MappedMemoryRange,
};

const ResourceJobType = enum {};
const UploadJob = struct {
    inner: union(ResourceJobType) {},
};

//pub fn util_get_texture_subresource_alignement(device: *rhi.Device, format: rhi.Format) usize {
//    const props = rhi.format.get_props(format);
//
//    var((props.block_width * props.block_height) * props.channel_bit_width()) >> 3;
//
//    uint32_t blockSize = max(1u, TinyImageFormat_BitSizeOfBlock(fmt) >> 3);
//    uint32_t alignment = round_up(pRenderer->pProperties->mUploadBufferTextureAlignment, blockSize);
//    return round_up(alignment, util_get_texture_row_alignment(pRenderer));
//}

// ResourceLoader manages transfers of resources to the GPU
// Note: make sure buffers/images are associated with the currect device create additional resource loaders for different devices
pub fn ResourceLoader(comptime config: ResourceConfig) type {
    return struct {
        pub const Self = @This();
        pub const TransferCommandGroup = struct {
            pool: [config.max_sets]rhi.Pool,
            cmd: [config.max_sets]rhi.Cmd,

            is_recording: bool = false,

            staging_buffer: [config.max_sets]rhi.Buffer,
            staging_buffer_offset: usize = 0,
            active_set: usize = 0,

            temporary_buffers: std.ArrayList(rhi.Buffer),
            fence: rhi.Fence,

            mutex: std.Thread.Mutex = .{},
        };
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        active_set: usize = 0,
        upload_resource: TransferCommandGroup = undefined,
        copy_resource: TransferCommandGroup = undefined,

        is_running: bool = true,

        queue_mutex: std.Thread.Mutex = .{},
        queue_cond: std.Thread.Condition = .{},
        upload_queue: std.ArrayList(UploadJob) = std.ArrayList(UploadJob).empty,

        pub fn acquire_cmd(self: *Self, renderer: *rhi.Renderer, copy_set: *TransferCommandGroup) rhi.Cmd {
            if (!copy_set.is_recording) {
                copy_set.pool[copy_set.active_set].reset(self.device, self.device.graphics_queue);
                copy_set.cmd[copy_set.active_set].begin(renderer, self.device);
                copy_set.is_recording = true;
            }
            return copy_set.cmd[copy_set.active_set];
        }

        pub fn allocate_temporary_buffer(self: *Self, renderer: *rhi.Renderer, copy_set: *TransferCommandGroup, size: usize) !rhi.Buffer.MappedMemoryRange {
            const temporary_buffer: rhi.Buffer = if (rhi.is_target_selected(.vk, renderer)) result: {
                var res: rhi.Buffer = undefined;
                const allocation_info = vma.c.VmaAllocationCreateInfo{
                    .usage = vma.c.VMA_MEMORY_USAGE_AUTO,
                    .flags = vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT | vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
                };
                const stage_buffer_create_info = rhi.vulkan.vk.BufferCreateInfo{ .s_type = .buffer_create_info, .size = size, .usage = .{
                    .transfer_src_bit = true,
                    .transfer_dst_bit = true,
                } };
                const vma_info = vma.c.VmaAllocationInfo{};
                try rhi.vulkan.wrap_vk_result(@enumFromInt(vma.c.vmaCreateBuffer(self.device.backend.vk.vma_allocator, &stage_buffer_create_info, &allocation_info, &res.backend.vk.buffer, &res.backend.vk.allocation, &vma_info)));

                res.mapped_region = @as([*c]u8, @ptrCast(vma_info.pMappedData))[0..size];
                break :result res;
            } else if (rhi.is_target_selected(.dx12, renderer)) {
                @compileError("Metal staging buffer not implemented");
            } else if (rhi.is_target_selected(.mtl, renderer)) {
                @compileError("Metal staging buffer not implemented");
            };
            try copy_set.temporary_buffers.append(self.allocator, temporary_buffer);

            return .{
                .buffer = temporary_buffer,
                .memory_range = if (temporary_buffer.mapped_region) |region| region else return error.BufferNotMapped,
            };
        }
        pub fn allocate_stage_buffer(self: *Self, group: *TransferCommandGroup, size: usize, alignment: usize) ?rhi.Buffer.MappedMemoryRange {
            const memory_request_size = std.mem.alignForward(usize, size, alignment);
            const staged_offset = std.mem.alignForward(usize, group.staging_buffer_offset, alignment);
            if((staged_offset < config.buffer_size) and memory_request_size <= (config.buffer_size - staged_offset)) {
                self.staging_buffer_offset = staged_offset + memory_request_size;
                return try group.staging_buffer[group.active_set].get_mapped_region(staged_offset, memory_request_size);
            }
            return null;
        }

        pub fn flush_copy_group(self: *Self, renderer: *rhi.Renderer, group: *TransferCommandGroup) void {
            _ = renderer;
            _ = group;
            _ = self;
        }

        pub fn allocate_stage_memory(self: *Self, renderer: *rhi.Renderer, group: *TransferCommandGroup, size: usize, alignment: usize) !?rhi.Buffer.MappedMemoryRange {
            const memory_request_size = std.mem.alignForward(usize, size, alignment);
            if (memory_request_size > config.buffer_size) {
                std.log.info("Requested size {}/{} exceeds staging buffer size {}", .{ size, memory_request_size, config.buffer_size });
                return try self.allocate_temporary_buffer(group, renderer, memory_request_size);
            }

            const staged_offset = std.mem.alignForward(usize, self.staging_buffer_offset, alignment);
            const memory_available = (staged_offset < config.buffer_size) and memory_request_size <= (config.buffer_size - staged_offset);
            if (memory_available) {
                self.staging_buffer_offset = staged_offset + memory_request_size;
                return try self.staging_buffer[self.active_set].get_mapped_region(staged_offset, memory_request_size);
            } else {
                return null;
                //group.active_set = (group.active_set + 1) % config.max_sets;
                //return .{
                //    .buffer = &self.staging_buffer[self.active_set],
                //    .memory_range = undefined,
                //};
            }
        }


        fn init_resource_copy_queue(renderer: *rhi.Renderer, queue: *rhi.Queue, device: *rhi.Device) !TransferCommandGroup {
            const staging_buffer: rhi.Buffer = if (rhi.is_target_selected(.vk, renderer)) result: {
                var res: rhi.Buffer = undefined;
                const allocation_info = vma.c.VmaAllocationCreateInfo{
                    .usage = vma.c.VMA_MEMORY_USAGE_AUTO,
                    .flags = vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT | vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
                };
                const stage_buffer_create_info = rhi.vulkan.vk.BufferCreateInfo{ .sType = .buffer_create_info, .size = config.buffer_size, .usage = .{
                    .transfer_src_bit = true,
                    .transfer_dst_bit = true,
                } };
                const vma_info = vma.c.VmaAllocationInfo{};
                try vulkan.wrap_err(vma.c.vmaCreateBuffer(device.backend.vk.vma_allocator, &stage_buffer_create_info, &allocation_info, &res.backend.vk.buffer, &res.backend.vk.allocation, &vma_info));
                res.mapped_region = @as([*c]u8, @ptrCast(vma_info.pMappedDatai))[0..config.buffer_size];
                break :result res;
            } else if (rhi.is_target_selected(.dx12, renderer)) {
                @compileError("Metal staging buffer not implemented");
            } else if (rhi.is_target_selected(.mtl, renderer)) {
                @compileError("Metal staging buffer not implemented");
            };

            const pool = rhi.Pool.init(renderer, device, queue);
            const cmd = rhi.Cmd.init(renderer, device, &pool);
            return .{
                .pool = pool,
                .cmd = cmd,
                .staging_buffer = staging_buffer,
            };
        }

        pub fn init(allocator: std.mem.Allocator, renderer: *rhi.Renderer, device: *rhi.Device) !ResourceLoader {
            var res = Self{
                .allocator = allocator,
                .device = device,
            };
            for (config.max_sets) |i| {
                res.upload_resource[i] = init_resource_copy_queue(renderer, &device.graphics_queue, device);
                res.copy_resource[i] = init_resource_copy_queue(renderer, if (device.transfer_queue) |*t| t else &device.graphics_queues, device);
            }
            return res;
        }

        // make sure pointer is stable before calling this
        pub fn spawn(self: *Self) void {
            _ = try std.Thread.spawn(.{ .allocator = self.allocator }, Self.upload_thread, self);
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        fn upload_thread(self: *Self) void {
            while (self.is_running) {
                self.queue_mutex.lock();
                while (self.is_running and self.upload_queue.len == 0) {
                    self.queue_cond.wait(&self.queue_mutex);
                }
                self.queue_mutex.unlock();
            }
        }

        pub fn begin_copy_buffer(self: *Self, renderer: *rhi.Renderer, transaction: *BufferTransaction) !void {
            if (rhi.is_target_selected(.vk, renderer)) {
                self.upload_resource.mutex.lock();
                const stage_buffer = try self.allocate_stage_memory(self, renderer, &self.upload_resource, transaction.size, 4);
                if (stage_buffer) |stage| {
                    transaction.mapped = stage;
                } else {
                    // allocate temporary buffer
                    transaction.mapped = try self.allocate_temporary_buffer(self, renderer, &self.upload_resource, transaction.size);
                }
                self.upload_resource.mutex.unlock();
            } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
        }

        pub fn end_copy_buffer(self: *Self, renderer: *rhi.Renderer, transaction: *BufferTransaction) !void {
            if (rhi.is_target_selected(.vk, renderer)) {
                self.upload_resource.mutex.lock();
                var cmd = self.acquire_cmd(renderer, &self.upload_resource);
                var buffer_copy = rhi.vulkan.vk.BufferCopy{
                    .srcOffset = transaction.mapped.offset,
                    .dstOffset = transaction.offset,
                    .size = transaction.size,
                };
                self.device.backend.vk.vkCmdCopyBuffer(
                    cmd.backend.vk.cmd,
                    transaction.mapped.buffer.backend.vk.buffer,
                    transaction.target.backend.vk.buffer,
                    1,
                    &buffer_copy,
                );
                self.upload_resource.mutex.unlock();
            } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
        }

        pub fn begin_copy_texture(self: *Self,renderer: *rhi.Renderer, device: *rhi.Device, transaction: *TextureTransaction) !void {
            const aligned_row_pitch = std.mem.alignForward(usize, transaction.row_pitch, device.adapter.upload_buffer_texture_row_alignment);
            const aligned_slice_pitch = std.mem.alignForward(usize, transaction.slice_num * aligned_row_pitch, device.adapter.upload_buffer_texture_slice_alignment);

            transaction.align_row_pitch = @as(u32, aligned_row_pitch);
            transaction.align_slice_pitch = @as(u32, aligned_slice_pitch);
            if (rhi.is_target_selected(.vk, renderer)) {
                const stage_buffer = try self.allocate_stage_memory(self, renderer, &self.upload_resource, transaction.align_slice_pitch, device.adapter.upload_buffer_texture_slice_alignment);
                if (stage_buffer) |stage| {
                    transaction.mapped = stage;
                } else {
                    // allocate temporary buffer
                    const temp_buffer = try self.allocate_temporary_buffer(self, renderer, &self.upload_resource, transaction.align_slice_pitch);
                    transaction.mapped = temp_buffer ;
                }
            } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
        }

        pub fn end_copy_texture(renderer: *rhi.Renderer, cmd: *rhi.Cmd, device: *rhi.Device, transaction: *TextureTransaction) !void {
            _ = cmd;
            _ = device;
            _ = transaction;
            if (rhi.is_target_selected(.vk, renderer)) {} else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
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
