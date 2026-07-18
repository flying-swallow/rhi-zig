// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const std = @import("std");

pub const AccelerationStructure = @This();

pub const Type = enum(u8) { bottom_level, top_level };

pub const BuildMode = enum(u8) { build, update };

pub const BuildFlags = struct {
    allow_update: bool = false,
    allow_compaction: bool = false,
    allow_data_access: bool = false,
    prefer_fast_trace: bool = false,
    prefer_fast_build: bool = false,
    minimize_memory: bool = false,
};

pub const GeometryFlags = struct {
    opaque_geometry: bool = false,
    no_duplicate_any_hit_invocation: bool = false,
};

pub const IndexType = enum(u8) { u16, u32 };

// matches VkAabbPositionsKHR layout
pub const Aabb = extern struct {
    min_x: f32 = 0,
    min_y: f32 = 0,
    min_z: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,
    max_z: f32 = 0,
};

pub const InstanceFlags = packed struct(u8) {
    triangle_cull_disable: bool = false,
    triangle_flip_facing: bool = false,
    force_opaque: bool = false,
    force_non_opaque: bool = false,
    _reserved: u4 = 0,
};

// callers fill a buffer of these and pass it as the TLAS instance buffer;
// matches VkAccelerationStructureInstanceKHR layout (64 bytes)
pub const Instance = extern struct {
    transform: [3][4]f32,
    properties: packed struct(u32) {
        custom_index: u24 = 0,
        mask: u8 = 0xff,
    } = .{},
    sbt: packed struct(u32) {
        record_offset: u24 = 0,
        flags: InstanceFlags = .{},
    } = .{},
    // from AccelerationStructure.device_address()
    acceleration_structure_reference: u64,
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 64);
}

pub const TrianglesDesc = struct {
    vertex_buffer: *rhi.Buffer,
    vertex_offset: u64 = 0,
    vertex_num: u32,
    vertex_stride: u16,
    vertex_format: rhi.Format,

    index_buffer: ?*rhi.Buffer = null, // null = unindexed
    index_offset: u64 = 0,
    index_num: u32 = 0,
    index_type: IndexType = .u32,

    transform_buffer: ?*rhi.Buffer = null, // optional, points to [3][4]f32 row-major entries
    transform_offset: u64 = 0,
};

pub const AabbsDesc = struct {
    buffer: *rhi.Buffer, // points to Aabb entries
    offset: u64 = 0,
    num: u32,
    stride: u32 = @sizeOf(Aabb),
};

pub const GeometryDesc = struct {
    flags: GeometryFlags = .{},
    geometry: union(enum) {
        triangles: TrianglesDesc,
        aabbs: AabbsDesc,
    },
};

pub const BuildInfo = union(enum) {
    bottom_level: []const GeometryDesc,
    top_level: u32, // max instance count
};

pub const BuildSizes = struct {
    acceleration_structure_size: u64,
    build_scratch_size: u64,
    update_scratch_size: u64,
};

structure_type: Type,
flags: BuildFlags,
/// Stable identity / descriptor-set cache key, stamped at creation (0 == empty).
cookie: u64 = 0,
backend: union {
    vk: if (rhi.platform_has_api(.vk)) struct {
        handle: rhi.vulkan.vk.AccelerationStructureKHR = .null_handle,
        device_address: u64 = 0,
    } else void,
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
} = undefined,

/// An unset / not-yet-created acceleration structure (cookie 0).
pub fn isEmpty(self: AccelerationStructure) bool {
    return self.cookie == 0;
}

fn vk_buffer_address(device: *rhi.Device, buf: *rhi.Buffer, offset: u64) rhi.vulkan.vk.DeviceAddress {
    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
    const info = rhi.vulkan.vk.BufferDeviceAddressInfo{ .buffer = buf.backend.vk.buffer };
    return dkb.getBufferDeviceAddress(device.backend.vk.device, &info) + offset;
}

fn vk_build_flags(flags: BuildFlags) rhi.vulkan.vk.BuildAccelerationStructureFlagsKHR {
    return .{
        .allow_update_khr = flags.allow_update,
        .allow_compaction_khr = flags.allow_compaction,
        .allow_data_access_khr = flags.allow_data_access,
        .prefer_fast_trace_khr = flags.prefer_fast_trace,
        .prefer_fast_build_khr = flags.prefer_fast_build,
        .low_memory_khr = flags.minimize_memory,
    };
}

fn vk_geometry(device: *rhi.Device, desc: *const GeometryDesc) rhi.vulkan.vk.AccelerationStructureGeometryKHR {
    const geometry_flags = rhi.vulkan.vk.GeometryFlagsKHR{
        .opaque_khr = desc.flags.opaque_geometry,
        .no_duplicate_any_hit_invocation_khr = desc.flags.no_duplicate_any_hit_invocation,
    };
    switch (desc.geometry) {
        .triangles => |tri| {
            return .{
                .geometry_type = .triangles_khr,
                .flags = geometry_flags,
                .geometry = .{ .triangles = .{
                    .vertex_format = rhi.vulkan.to_vk_format(tri.vertex_format),
                    .vertex_data = .{ .device_address = vk_buffer_address(device, tri.vertex_buffer, tri.vertex_offset) },
                    .vertex_stride = tri.vertex_stride,
                    .max_vertex = tri.vertex_num -| 1,
                    .index_type = if (tri.index_buffer != null) switch (tri.index_type) {
                        .u16 => rhi.vulkan.vk.IndexType.uint16,
                        .u32 => rhi.vulkan.vk.IndexType.uint32,
                    } else .none_khr,
                    .index_data = .{ .device_address = if (tri.index_buffer) |ib| vk_buffer_address(device, ib, tri.index_offset) else 0 },
                    .transform_data = .{ .device_address = if (tri.transform_buffer) |tb| vk_buffer_address(device, tb, tri.transform_offset) else 0 },
                } },
            };
        },
        .aabbs => |aabbs| {
            return .{
                .geometry_type = .aabbs_khr,
                .flags = geometry_flags,
                .geometry = .{ .aabbs = .{
                    .data = .{ .device_address = vk_buffer_address(device, aabbs.buffer, aabbs.offset) },
                    .stride = aabbs.stride,
                } },
            };
        },
    }
}

fn geometry_primitive_count(desc: *const GeometryDesc) u32 {
    return switch (desc.geometry) {
        .triangles => |tri| (if (tri.index_buffer != null) tri.index_num else tri.vertex_num) / 3,
        .aabbs => |aabbs| aabbs.num,
    };
}

// query the storage/scratch sizes required by an acceleration structure before
// creating it; device addresses in the geometry descriptions are ignored by the
// driver for this query, only counts/formats/strides matter.
pub fn get_build_sizes(
    allocator: std.mem.Allocator,
    device: *rhi.Device,
    options: struct {
        flags: BuildFlags = .{},
        info: BuildInfo,
    },
) !BuildSizes {
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var size_info = rhi.vulkan.vk.AccelerationStructureBuildSizesInfoKHR{
            .acceleration_structure_size = 0,
            .build_scratch_size = 0,
            .update_scratch_size = 0,
        };
        switch (options.info) {
            .bottom_level => |geometries| {
                const vk_geometries = try allocator.alloc(rhi.vulkan.vk.AccelerationStructureGeometryKHR, geometries.len);
                defer allocator.free(vk_geometries);
                const primitive_counts = try allocator.alloc(u32, geometries.len);
                defer allocator.free(primitive_counts);
                for (geometries, 0..) |*desc, i| {
                    vk_geometries[i] = vk_geometry(device, desc);
                    primitive_counts[i] = geometry_primitive_count(desc);
                }
                const build_info = rhi.vulkan.vk.AccelerationStructureBuildGeometryInfoKHR{
                    .type = .bottom_level_khr,
                    .flags = vk_build_flags(options.flags),
                    .mode = .build_khr,
                    .geometry_count = @intCast(vk_geometries.len),
                    .p_geometries = vk_geometries.ptr,
                    .scratch_data = .{ .device_address = 0 },
                };
                dkb.getAccelerationStructureBuildSizesKHR(device.backend.vk.device, .device_khr, &build_info, primitive_counts.ptr, &size_info);
            },
            .top_level => |instance_num| {
                const instances_geometry = rhi.vulkan.vk.AccelerationStructureGeometryKHR{
                    .geometry_type = .instances_khr,
                    .geometry = .{ .instances = .{
                        .array_of_pointers = .false,
                        .data = .{ .device_address = 0 },
                    } },
                };
                const build_info = rhi.vulkan.vk.AccelerationStructureBuildGeometryInfoKHR{
                    .type = .top_level_khr,
                    .flags = vk_build_flags(options.flags),
                    .mode = .build_khr,
                    .geometry_count = 1,
                    .p_geometries = @ptrCast(&instances_geometry),
                    .scratch_data = .{ .device_address = 0 },
                };
                const primitive_counts = [_]u32{instance_num};
                dkb.getAccelerationStructureBuildSizesKHR(device.backend.vk.device, .device_khr, &build_info, &primitive_counts, &size_info);
            },
        }
        return .{
            .acceleration_structure_size = size_info.acceleration_structure_size,
            .build_scratch_size = size_info.build_scratch_size,
            .update_scratch_size = size_info.update_scratch_size,
        };
    }
    unreachable;
}

pub fn init(
    device: *rhi.Device,
    options: struct {
        structure_type: Type,
        flags: BuildFlags = .{},
        // caller-owned backing buffer created with usage.acceleration_structure_storage;
        // size comes from get_build_sizes().acceleration_structure_size
        storage: *rhi.Buffer,
        storage_offset: u64 = 0,
        storage_size: u64,
    },
) !AccelerationStructure {
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var create_info = rhi.vulkan.vk.AccelerationStructureCreateInfoKHR{
            .buffer = options.storage.backend.vk.buffer,
            .offset = options.storage_offset,
            .size = options.storage_size,
            .type = switch (options.structure_type) {
                .bottom_level => rhi.vulkan.vk.AccelerationStructureTypeKHR.bottom_level_khr,
                .top_level => rhi.vulkan.vk.AccelerationStructureTypeKHR.top_level_khr,
            },
        };
        const handle = try dkb.createAccelerationStructureKHR(device.backend.vk.device, &create_info, null);
        const address_info = rhi.vulkan.vk.AccelerationStructureDeviceAddressInfoKHR{ .acceleration_structure = handle };
        return .{
            .structure_type = options.structure_type,
            .flags = options.flags,
            .cookie = rhi.next_cookie(),
            .backend = .{ .vk = .{
                .handle = handle,
                .device_address = dkb.getAccelerationStructureDeviceAddressKHR(device.backend.vk.device, &address_info),
            } },
        };
    }
    unreachable;
}

pub fn deinit(self: *AccelerationStructure, device: *rhi.Device) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        dkb.destroyAccelerationStructureKHR(device.backend.vk.device, self.backend.vk.handle, null);
        return;
    }
    unreachable;
}

// address used by Instance.acceleration_structure_reference and by shaders
pub fn device_address(self: *const AccelerationStructure) u64 {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        return self.backend.vk.device_address;
    }
    unreachable;
}

// record a BLAS build/update; src is required (and must have been built with
// allow_update) when mode == .update
pub fn cmd_build_bottom_level(
    self: *AccelerationStructure,
    allocator: std.mem.Allocator,
    cmd: *rhi.Cmd,
    device: *rhi.Device,
    options: struct {
        src: ?*AccelerationStructure = null,
        mode: BuildMode = .build,
        geometries: []const GeometryDesc,
        scratch_buffer: *rhi.Buffer, // created with usage.scratch_buffer
        scratch_offset: u64 = 0,
    },
) !void {
    std.debug.assert(self.structure_type == .bottom_level);
    std.debug.assert(options.mode == .build or options.src != null);
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const vk_geometries = try allocator.alloc(rhi.vulkan.vk.AccelerationStructureGeometryKHR, options.geometries.len);
        defer allocator.free(vk_geometries);
        const ranges = try allocator.alloc(rhi.vulkan.vk.AccelerationStructureBuildRangeInfoKHR, options.geometries.len);
        defer allocator.free(ranges);
        for (options.geometries, 0..) |*desc, i| {
            vk_geometries[i] = vk_geometry(device, desc);
            ranges[i] = .{
                .primitive_count = geometry_primitive_count(desc),
                .primitive_offset = 0, // offsets are folded into the device addresses
                .first_vertex = 0,
                .transform_offset = 0,
            };
        }
        const build_infos = [_]rhi.vulkan.vk.AccelerationStructureBuildGeometryInfoKHR{.{
            .type = .bottom_level_khr,
            .flags = vk_build_flags(self.flags),
            .mode = switch (options.mode) {
                .build => rhi.vulkan.vk.BuildAccelerationStructureModeKHR.build_khr,
                .update => rhi.vulkan.vk.BuildAccelerationStructureModeKHR.update_khr,
            },
            .src_acceleration_structure = if (options.src) |src| src.backend.vk.handle else .null_handle,
            .dst_acceleration_structure = self.backend.vk.handle,
            .geometry_count = @intCast(vk_geometries.len),
            .p_geometries = vk_geometries.ptr,
            .scratch_data = .{ .device_address = vk_buffer_address(device, options.scratch_buffer, options.scratch_offset) },
        }};
        const range_ptrs = [_][*]const rhi.vulkan.vk.AccelerationStructureBuildRangeInfoKHR{ranges.ptr};
        dkb.cmdBuildAccelerationStructuresKHR(cmd.backend.vk.cmd, build_infos[0..], range_ptrs[0..]);
        return;
    }
    unreachable;
}

// record a TLAS build/update; instance_buffer points to Instance entries
pub fn cmd_build_top_level(
    self: *AccelerationStructure,
    cmd: *rhi.Cmd,
    device: *rhi.Device,
    options: struct {
        src: ?*AccelerationStructure = null,
        mode: BuildMode = .build,
        instance_num: u32,
        instance_buffer: *rhi.Buffer, // created with usage.acceleration_structure_build_input
        instance_offset: u64 = 0,
        scratch_buffer: *rhi.Buffer, // created with usage.scratch_buffer
        scratch_offset: u64 = 0,
    },
) !void {
    std.debug.assert(self.structure_type == .top_level);
    std.debug.assert(options.mode == .build or options.src != null);
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const instances_geometry = rhi.vulkan.vk.AccelerationStructureGeometryKHR{
            .geometry_type = .instances_khr,
            .geometry = .{ .instances = .{
                .array_of_pointers = .false,
                .data = .{ .device_address = vk_buffer_address(device, options.instance_buffer, options.instance_offset) },
            } },
        };
        const build_infos = [_]rhi.vulkan.vk.AccelerationStructureBuildGeometryInfoKHR{.{
            .type = .top_level_khr,
            .flags = vk_build_flags(self.flags),
            .mode = switch (options.mode) {
                .build => rhi.vulkan.vk.BuildAccelerationStructureModeKHR.build_khr,
                .update => rhi.vulkan.vk.BuildAccelerationStructureModeKHR.update_khr,
            },
            .src_acceleration_structure = if (options.src) |src| src.backend.vk.handle else .null_handle,
            .dst_acceleration_structure = self.backend.vk.handle,
            .geometry_count = 1,
            .p_geometries = @ptrCast(&instances_geometry),
            .scratch_data = .{ .device_address = vk_buffer_address(device, options.scratch_buffer, options.scratch_offset) },
        }};
        const ranges = [_]rhi.vulkan.vk.AccelerationStructureBuildRangeInfoKHR{.{
            .primitive_count = options.instance_num,
            .primitive_offset = 0, // offset is folded into the device address
            .first_vertex = 0,
            .transform_offset = 0,
        }};
        const range_ptrs = [_][*]const rhi.vulkan.vk.AccelerationStructureBuildRangeInfoKHR{ranges[0..].ptr};
        dkb.cmdBuildAccelerationStructuresKHR(cmd.backend.vk.cmd, build_infos[0..], range_ptrs[0..]);
        return;
    }
    unreachable;
}

test {
    std.testing.refAllDecls(AccelerationStructure);
}
