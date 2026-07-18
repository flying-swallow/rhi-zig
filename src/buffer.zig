// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const vma = @import("root.zig").vma;
const std = @import("std");
const builtin = @import("builtin");

pub const Buffer = @This();

/// Where a buffer's memory lives, expressed backend-neutrally (mirrors
/// `RIMemoryLocation_e`). Maps to a VMA memory usage + flags on Vulkan.
pub const MemoryLocation = enum {
    /// Device-local, not host-mapped. `mapped_region` is null; seed via the
    /// resource uploader.
    device,
    /// Persistently mapped for sequential host writes.
    host_upload,
};

/// Stable identity / descriptor-set cache key, stamped at creation (0 == empty).
/// `Descriptor` derives its own cookie from this.
cookie: u64 = 0,
mapped_region: ?[]u8 = null,
backend: union {
    vk: if (rhi.platform_has_api(.vk)) struct {
        buffer: rhi.vulkan.vk.Buffer = .null_handle,
        allocation: vma.c.VmaAllocation = null,
    } else void,
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: if (rhi.platform_has_api(.mtl)) struct {
        buffer: rhi.metal.mtl.Buffer,
    } else void,
} = undefined,

//  General buffer initialization function
pub fn init_general(
    device: *rhi.Device,
    options: struct {
        size: usize,
        stride: usize = 0,
        persistant_map: bool = false,
        // vk: sequential_access indicates that the mapped memory will be written sequentially
        sequential_access: bool = false,
        usage: struct {
            // zig fmt: off
            shader_resource: bool = false,                     // SHADER_RESOURCE                          Read-only shader resource (SRV)
            shader_resource_storage: bool = false,             // SHADER_RESOURCE_STORAGE                  Read/write shader resource (UAV)
            transfer_src: bool = true,                         // TRANSFER_SRC                             Source of a copy (defaults on for parity)
            transfer_dst: bool = true,                         // TRANSFER_DST                             Destination of a copy (defaults on for parity)
            indirect: bool = false,                            // INDIRECT                                 Source of indirect draw/dispatch args
            device_address: bool = false,                      // DEVICE_ADDRESS                           Addressable as a raw GPU pointer (BDA)
            vertex_buffer: bool = false,                       // VERTEX_BUFFER                            Vertex buffer
            index_buffer: bool = false,                        // INDEX_BUFFER                             Index buffer
            constant_buffer: bool = false,                     // CONSTANT_BUFFER                          Constant buffer (D3D11: can't be combined with other usages)
            argument_buffer: bool = false,                     // ARGUMENT_BUFFER                          Argument buffer in "Indirect" commands
            scratch_buffer: bool = false,                      // SCRATCH_BUFFER                           Scratch buffer in "CmdBuild*" commands
            shader_binding_table: bool = false,                // SHADER_BINDING_TABLE                     Shader binding table (SBT) in "CmdDispatchRays*" commands
            acceleration_structure_build_input: bool = false,  // SHADER_RESOURCE                          Read-only input in "CmdBuildAccelerationStructures" command
            acceleration_structure_storage: bool = false,      // ACCELERATION_STRUCTURE_READ/WRITE        (INTERNAL) acceleration structure storage
            micromap_build_input: bool = false,                // SHADER_RESOURCE                          Read-only input in "CmdBuildMicromaps" command
            micromap_storage: bool = false,                    // MICROMAP_READ/WRITE                      (INTERNAL) micromap storage
            // zig fmt: on
        },
        buffer_usage: enum { auto, prefer_device, prefer_host } = .auto,
    },
) !Buffer {
    if (rhi.is_target_selected(.vk)) {
        // zig fmt: off
        var usage  = rhi.vulkan.vk.BufferUsageFlags{
            .shader_device_address = device.adapter.backend.vk.is_buffer_device_address_supported or options.usage.device_address,
            .transfer_dst = options.usage.transfer_dst,
            .transfer_src = options.usage.transfer_src,
            .vertex_buffer = options.usage.vertex_buffer,
            .index_buffer = options.usage.index_buffer,
            .uniform_buffer = options.usage.constant_buffer,
            .indirect_buffer = options.usage.argument_buffer or options.usage.indirect,
            .storage_buffer = options.usage.scratch_buffer,
            .shader_binding_table_khr = options.usage.shader_binding_table,
            .acceleration_structure_storage_khr = options.usage.acceleration_structure_storage,
            .acceleration_structure_build_input_read_only_khr = options.usage.acceleration_structure_build_input,
            .micromap_storage_ext = options.usage.micromap_storage,
            .micromap_build_input_read_only_ext = options.usage.micromap_build_input
        };
        // zig fmt: on
        if (options.stride == 0 or options.stride == 4) {
            if (options.usage.shader_resource)
                usage.uniform_texel_buffer = true;
            if (options.usage.shader_resource_storage)
                usage.storage_texel_buffer = true;
        }
        if (options.stride > 0)
            usage.storage_buffer = true; // so called SSBO, can be R/W in shaders
        var allocation_info: vma.c.VmaAllocationCreateInfo = .{};
        allocation_info.usage = switch (options.buffer_usage) {
            .prefer_device => vma.c.VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE,
            .prefer_host => vma.c.VMA_MEMORY_USAGE_AUTO_PREFER_HOST,
            .auto => vma.c.VMA_MEMORY_USAGE_AUTO,
        };

        if (options.persistant_map) {
            allocation_info.flags |= if (options.sequential_access)
                vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT
            else
                vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT;
            allocation_info.flags |= vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT;
        }
        var buffer_create_info: rhi.vulkan.vk.BufferCreateInfo = .{
            .sharing_mode = .exclusive,
            .size = options.size,
            .usage = usage,
        };
        var vma_info = vma.c.VmaAllocationInfo{};
        var vk_buffer: vma.c.VkBuffer = undefined;
        var vma_alloc: vma.c.VmaAllocation = undefined;
        // zig fmt: off
        try rhi.vulkan.VKWrapResult(@enumFromInt(vma.c.vmaCreateBuffer(
            device.backend.vk.vma_allocator, 
            @ptrCast(&buffer_create_info), 
            &allocation_info, 
            &vk_buffer, 
            &vma_alloc, 
            &vma_info)));
        // zig fmt: on
        return .{
            .cookie = rhi.next_cookie(),
            .backend = .{ .vk = .{
                .buffer = @enumFromInt(@intFromPtr(vk_buffer)),
                .allocation = vma_alloc,
            } },
            .mapped_region = if (vma_info.pMappedData != null)
                @as([*c]u8, @ptrCast(vma_info.pMappedData))[0..options.size]
            else
                null,
        };
    }
    if (rhi.is_target_selected(.mtl)) {
        // Shared storage: the buffer is CPU-visible, so `mapped_region` points
        // straight at its contents (no staging/blit needed on Apple Silicon).
        const buffer = device.backend.mtl.device.newBuffer(options.size, .{ .storage_mode = .shared }) orelse
            return error.MetalBufferCreationFailed;
        const contents = buffer.contents();
        return .{
            .cookie = rhi.next_cookie(),
            .backend = .{ .mtl = .{ .buffer = buffer } },
            .mapped_region = if (contents) |p| @as([*]u8, @ptrCast(p))[0..options.size] else null,
        };
    }
    unreachable;
}

/// An unset / not-yet-created buffer (cookie 0). A descriptor built from an
/// empty buffer is itself empty.
pub fn isEmpty(self: Buffer) bool {
    return self.cookie == 0;
}

pub fn deinit(self: *Buffer, device: *rhi.Device) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        vma.c.vmaDestroyBuffer(
            device.backend.vk.vma_allocator,
            @ptrFromInt(@intFromEnum(self.backend.vk.buffer)), self.backend.vk.allocation);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.buffer.release();
        return;
    }
    unreachable;
}

//pub fn init(renderer: *rhi.Renderer, device: *rhi.Device, options: struct {
//    size: usize,
//    stride: usize,
//    usage: BufferUsage
//}) Buffer {
//    _ = device;
//    _ = options;
//    if (rhi.is_target_selected(.vk, renderer)) {
//
//        var usage  = rhi.vulkan.vk.BufferUsageFlags{
//            .shader_device_address = device.adapter.backend.vk.is_buffer_device_address_supported,
//            .vertex_buffer = options.usage.vertex_buffer,
//            .index_buffer = options.usage.index_buffer,
//            .uniform_buffer = options.usage.constant_buffer,
//            .constant_buffer = options.usage.constant_buffer,
//            .indirect_buffer = options.usage.argument_buffer,
//            .storage_buffer = options.usage.scratch_buffer or options.usage.shader_resource_storage,
//            .shader_binding_table_khr = options.usage.shader_binding_table,
//            .acceleration_structure_storage_khr = options.usage.acceleration_structure_storage,
//            .acceleration_structure_build_input_read_only_khr = options.usage.acceleration_structure_build_input,
//            .micromap_storage_ext = options.usage.micromap_storage,
//            .micromap_build_input_read_only_ext = options.usage.micromap_build_input
//        };
//
//
//    //if (bufferUsageBits & BufferUsageBits::CONSTANT_BUFFER)
//    //    flags |= VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
//
//    //if (bufferUsageBits & BufferUsageBits::ARGUMENT_BUFFER)
//    //    flags |= VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;
//
//    //if (bufferUsageBits & BufferUsageBits::SCRATCH_BUFFER)
//    //    flags |= VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
//
//    //if (bufferUsageBits & BufferUsageBits::SHADER_BINDING_TABLE)
//    //    flags |= VK_BUFFER_USAGE_SHADER_BINDING_TABLE_BIT_KHR;
//
//    //if (bufferUsageBits & BufferUsageBits::ACCELERATION_STRUCTURE_STORAGE)
//    //    flags |= VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR;
//
//    //if (bufferUsageBits & BufferUsageBits::ACCELERATION_STRUCTURE_BUILD_INPUT)
//    //    flags |= VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR;
//
//    //if (bufferUsageBits & BufferUsageBits::MICROMAP_STORAGE)
//    //    flags |= VK_BUFFER_USAGE_MICROMAP_STORAGE_BIT_EXT;
//
//    //if (bufferUsageBits & BufferUsageBits::MICROMAP_BUILD_INPUT)
//    //    flags |= VK_BUFFER_USAGE_MICROMAP_BUILD_INPUT_READ_ONLY_BIT_EXT;
//
//    //// Based on comments for "BufferDesc::structureStride"
//    //if (structureStride == 0 || structureStride == 4) {
//    //    if (bufferUsageBits & BufferUsageBits::SHADER_RESOURCE)
//    //        flags |= VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT;
//
//    //    if (bufferUsageBits & BufferUsageBits::SHADER_RESOURCE_STORAGE)
//    //        flags |= VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT;
//    //}
//
//    //if (structureStride)
//    //    flags |= VK_BUFFER_USAGE_STORAGE_BUFFER_BIT; // so called SSBO, can be R/W in shaders
//
//    } else {
//        unreachable;
//    }
//}

pub fn get_mapped_region(self: *Buffer, offset: usize, size: usize) !MappedMemoryRange {
    if (self.mapped_region) |region| {
        return .{ .offset = offset, .buffer = self, .memory_range = region[offset .. offset + size] };
    }
    return error.BufferNotMapped;
}

pub const MappedMemoryRange = struct {
    pub const Self = @This();
    offset: usize, // offset within the buffer
    buffer: *Buffer,
    memory_range: []u8,

    pub fn isEmpty(self: *MappedMemoryRange) bool {
        return self.memory_range.len == 0;
    }
};
