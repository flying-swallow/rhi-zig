const rhi = @import("root.zig");
const vma = @import("vma");
const std = @import("std");

//pub const Barrier = struct {
//    pub const Self = @This();
//    backend: union {
//        vk: rhi.wrapper_platform_type(.vk, struct {
//            stage: rhi.vulkan.vk.PipelineStageFlags2,
//            access: rhi.vulkan.vk.AccessFlags2,
//        }),
//        dx12: rhi.wrapper_platform_type(.dx12, struct {}),
//        mtl: rhi.wrapper_platform_type(.mtl, struct {}),
//    },
//};

pub const Buffer = @This();
mapped_region: ?[]u8 = null,
backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct {
        buffer: rhi.vulkan.vk.Buffer = .null_handle,
        allocation: vma.c.VmaAllocation = null,
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
} = undefined,

pub const BufferUsage = struct {
    shader_resource: bool = false, // SHADER_RESOURCE                          Read-only shader resource (SRV)
    shader_resource_storage: bool = false, // SHADER_RESOURCE_STORAGE                  Read/write shader resource (UAV)
    vertex_buffer: bool = false, // VERTEX_BUFFER                            Vertex buffer
    index_buffer: bool = false, // INDEX_BUFFER                             Index buffer
    constant_buffer: bool = false, // CONSTANT_BUFFER                          Constant buffer (D3D11: can't be combined with other usages)
    argument_buffer: bool = false, // ARGUMENT_BUFFER                          Argument buffer in "Indirect" commands
    scratch_buffer: bool = false, // SCRATCH_BUFFER                           Scratch buffer in "CmdBuild*" commands
    shader_binding_table: bool = false, // SHADER_BINDING_TABLE                     Shader binding table (SBT) in "CmdDispatchRays*" commands
    acceleration_structure_build_input: bool = false, // SHADER_RESOURCE                          Read-only input in "CmdBuildAccelerationStructures" command
    acceleration_structure_storage: bool = false, // ACCELERATION_STRUCTURE_READ/WRITE        (INTERNAL) acceleration structure storage
    micromap_build_input: bool = false, // SHADER_RESOURCE                          Read-only input in "CmdBuildMicromaps" command
    micromap_storage: bool = false, // MICROMAP_READ/WRITE                      (INTERNAL) micromap storage

//    pub fn vk_buffer_usage_flags(self: BufferUsage, device: *rhi.Device) rhi.vulkan.vk.BufferUsageFlags {
//        return .{
//            .shader_device_address_bit = device.adapter.backend.vk.is_buffer_device_address_supported
//        };
//
//    }
};

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
//            .shader_device_address_bit = device.adapter.backend.vk.is_buffer_device_address_supported,
//            .vertex_buffer_bit = options.usage.vertex_buffer,
//            .index_buffer_bit = options.usage.index_buffer,
//            .uniform_buffer_bit = options.usage.constant_buffer,
//            .constant_buffer_bit = options.usage.constant_buffer,
//            .indirect_buffer_bit = options.usage.argument_buffer,
//            .storage_buffer_bit = options.usage.scratch_buffer or options.usage.shader_resource_storage,
//            .shader_binding_table_bit_khr = options.usage.shader_binding_table,
//            .acceleration_structure_storage_bit_khr = options.usage.acceleration_structure_storage,
//            .acceleration_structure_build_input_read_only_bit_khr = options.usage.acceleration_structure_build_input,
//            .micromap_storage_bit_ext = options.usage.micromap_storage,
//            .micromap_build_input_read_only_bit_ext = options.usage.micromap_build_input
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
    buffer: Buffer,
    memory_range: []u8,
};
