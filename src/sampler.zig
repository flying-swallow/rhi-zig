// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

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
    wgpu: if (rhi.platform_has_api(.wgpu)) struct {
        sampler: rhi.webgpu.Handle = .none,
    } else void,
    // WebGL2 has real sampler objects -- `createSampler` / `bindSampler` are
    // core ES 3.0 -- so filter state does not have to live on the texture.
    webgl: if (rhi.platform_has_api(.webgl)) struct {
        sampler: rhi.webgl.Handle = .none,
    } else void,
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
    }
    if (rhi.is_target_selected(.wgpu)) {
        const wgpu = rhi.webgpu;
        const sampler = wgpu.wgpu_device_create_sampler(
            device.backend.wgpu.device,
            to_wgpu_filter(desc.mag_filter),
            to_wgpu_filter(desc.min_filter),
            to_wgpu_mip_filter(desc.mip_map_mode),
            try to_wgpu_address(desc.address_u),
            try to_wgpu_address(desc.address_v),
            try to_wgpu_address(desc.address_w),
            if (desc.set_lod_range) desc.min_lod else 0.0,
            if (desc.set_lod_range) desc.max_lod else 32.0,
            @intFromFloat(@max(1.0, desc.max_anisotropy)),
        );
        if (sampler.isNone()) return error.WebGPUSamplerCreationFailed;
        return .{ .cookie = rhi.next_cookie(), .backend = .{ .wgpu = .{ .sampler = sampler } } };
    }
    if (rhi.is_target_selected(.webgl)) {
        const webgl = rhi.webgl;
        const sampler = webgl.gl_create_sampler(
            // A mipmap-combined min filter makes a single-level texture
            // incomplete, so it is only used when the caller actually declared
            // a LOD range.
            gl_min_filter(desc.min_filter, desc.mip_map_mode, desc.set_lod_range and desc.max_lod > 0),
            gl_filter(desc.mag_filter),
            try to_gl_address(desc.address_u),
            try to_gl_address(desc.address_v),
            try to_gl_address(desc.address_w),
        );
        if (sampler.isNone()) return error.WebGL2SamplerCreationFailed;
        return .{ .cookie = rhi.next_cookie(), .backend = .{ .webgl = .{ .sampler = sampler } } };
    }
    return error.UnsupportedBackend;
}

fn to_wgpu_filter(f: FilterType) rhi.webgpu.FilterMode {
    return switch (f) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

fn to_wgpu_mip_filter(m: MipMapMode) rhi.webgpu.FilterMode {
    return switch (m) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

/// `clamp_to_border` has no WebGPU or WebGL2 equivalent. Reported rather than
/// quietly substituted, the same way `to_gl_format` treats `bgra8_unorm`.
fn to_wgpu_address(a: AddressMode) !rhi.webgpu.AddressMode {
    return switch (a) {
        .mirror => .mirror_repeat,
        .repeat => .repeat,
        .clamp_to_edge => .clamp_to_edge,
        .clamp_to_border => error.UnsupportedAddressMode,
    };
}

fn gl_filter(f: FilterType) u32 {
    return switch (f) {
        .nearest => rhi.webgl.gl.NEAREST,
        .linear => rhi.webgl.gl.LINEAR,
    };
}

fn gl_min_filter(f: FilterType, mip: MipMapMode, use_mips: bool) u32 {
    const gl = rhi.webgl.gl;
    if (!use_mips) return gl_filter(f);
    return switch (f) {
        .nearest => switch (mip) {
            .nearest => gl.NEAREST_MIPMAP_NEAREST,
            .linear => gl.NEAREST_MIPMAP_LINEAR,
        },
        .linear => switch (mip) {
            .nearest => gl.LINEAR_MIPMAP_NEAREST,
            .linear => gl.LINEAR_MIPMAP_LINEAR,
        },
    };
}

fn to_gl_address(a: AddressMode) !u32 {
    const gl = rhi.webgl.gl;
    return switch (a) {
        .mirror => gl.MIRRORED_REPEAT,
        .repeat => gl.REPEAT,
        .clamp_to_edge => gl.CLAMP_TO_EDGE,
        .clamp_to_border => error.UnsupportedAddressMode,
    };
}

pub fn deinit(self: *Sampler, device: *rhi.Device) void {
    switch (self.backend) {
        .vk => |vk| {
            if (comptime rhi.platform_has_api(.vk)) {
                if (vk.sampler != .null_handle) {
                    var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                    dkb.destroySampler(device.backend.vk.device, vk.sampler, null);
                }
            }
        },
        .dx12 => {},
        .mtl => {},
        .wgpu => |w| {
            if (comptime rhi.platform_has_api(.wgpu)) rhi.webgpu.wgpu_release(w.sampler);
        },
        .webgl => |w| {
            if (comptime rhi.platform_has_api(.webgl)) rhi.webgl.gl_delete_sampler(w.sampler);
        },
    }
}
