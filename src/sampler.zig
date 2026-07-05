const rhi = @import("root.zig");
const std = @import("std");
const vulkan = @import("root.zig").vulkan;

pub const FilterType = enum(u1) { nearest = 0, linear = 1 };

pub const MipMapMode = enum(u1) { nearest = 0, linear = 1 };

pub const CompareMode = enum(u3) { never = 0, less = 1, equal = 2, less_or_equal = 3, greater = 4, not_equal = 5, greater_or_equal = 6, always = 7 };

pub const AddressMode = enum(u2) { mirror = 0, repeat = 1, clamp_to_edge = 2, clamp_to_border = 3 };

pub const Sampler = @This();
/// Stable identity / descriptor-set cache key, stamped at creation (0 == empty).
cookie: u64 = 0,
backend: union(rhi.Backend) {
    vk: if (rhi.platform_has_api(.vk)) struct {
        sampler: rhi.vulkan.vk.Sampler = .null_handle,
    } else void,
    dx12: if (rhi.platform_has_api(.dx12)) void else void,
    mtl: if (rhi.platform_has_api(.mtl)) void else void,
},

/// Build a sampler descriptor referencing this sampler (cookie derived from the
/// sampler's). Delegates to the backend-neutral `Descriptor.sampler` builder.
pub fn descriptor(self: *Sampler, device: *rhi.Device) rhi.Descriptor {
    return rhi.Descriptor.sampler(device, self);
}

pub fn init(device: *rhi.Device, desc: struct {
    min_filter: FilterType,
    mag_filter: FilterType,
    mip_map_mode: MipMapMode,
    address_u: AddressMode,
    address_v: AddressMode,
    address_w: AddressMode,
    mip_lod_bias: f32,
    set_lod_range: bool,
    min_lod: f32,
    max_lod: f32,
    max_anisotropy: f32,
    compare_func: CompareMode,
}) !Sampler {
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const vk_address = struct {
            fn map(m: AddressMode) rhi.vulkan.vk.SamplerAddressMode {
                return switch (m) {
                    .mirror => .mirrored_repeat,
                    .repeat => .repeat,
                    .clamp_to_edge => .clamp_to_edge,
                    .clamp_to_border => .clamp_to_border,
                };
            }
        }.map;
        const sampler_create_info: rhi.vulkan.vk.SamplerCreateInfo = .{
            .flags = .{},
            .mag_filter = if (desc.mag_filter == .linear) .linear else .nearest,
            .min_filter = if (desc.min_filter == .linear) .linear else .nearest,
            .mipmap_mode = if (desc.mip_map_mode == .linear) .linear else .nearest,
            .address_mode_u = vk_address(desc.address_u),
            .address_mode_v = vk_address(desc.address_v),
            .address_mode_w = vk_address(desc.address_w),
            .mip_lod_bias = desc.mip_lod_bias,
            .anisotropy_enable = if (desc.max_anisotropy > 1.0) .true else .false,
            .max_anisotropy = if (desc.max_anisotropy > 1.0) desc.max_anisotropy else 1.0,
            .compare_enable = if (desc.compare_func != .never) .true else .false,
            .compare_op = switch (desc.compare_func) {
                .never => .never,
                .less => .less,
                .equal => .equal,
                .less_or_equal => .less_or_equal,
                .greater => .greater,
                .not_equal => .not_equal,
                .greater_or_equal => .greater_or_equal,
                .always => .always,
            },
            .min_lod = if (desc.set_lod_range) desc.min_lod else 0.0,
            .max_lod = if (desc.set_lod_range) desc.max_lod else rhi.vulkan.vk.LOD_CLAMP_NONE,
            .border_color = .float_opaque_black,
            .unnormalized_coordinates = .false,
        };
        const sampler = try dkb.createSampler(device.backend.vk.device, &sampler_create_info, null);
        return .{ .cookie = rhi.next_cookie(), .backend = .{ .vk = .{ .sampler = sampler } } };
    } else if (rhi.is_target_selected(.dx12)) {} else if (rhi.is_target_selected(.mtl)) {}
    return error.UnsupportedBackend;
}

pub fn deinit(self: *Sampler, device: *rhi.Device) void {
    switch (self.backend) {
        .vk => |vk| {
            if (vk.sampler != .null_handle) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                dkb.destroySampler(device.backend.vk.device, vk.sampler, null);
            }
        },
        .dx12 => {},
        .mtl => {},
    }
}
