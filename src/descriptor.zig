// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const std = @import("std");

pub const Descriptor = @This();

/// Unique id / descriptor-set cache key (0 == empty). Derived from the
/// referenced resource's own cookie folded with the binding parameters, so a
/// descriptor changes identity whenever the resource or its binding does, and a
/// resource with cookie 0 (uncreated) yields an empty descriptor — which
/// `Program.bindDescriptors` skips.
cookie: u64 = 0,
/// Backend-neutral descriptor category.
type: rhi.DescriptorType = .sampled_image,
/// Resolved backend descriptor info, filled in by the builders. Exactly one
/// union member is live per `type`; the descriptor-set writer consumes
/// `backend.vk.view.image` / `.buffer` directly.
backend: union(rhi.Backend) {
    vk: if (rhi.platform_has_api(.vk)) struct {
        type: rhi.vulkan.vk.DescriptorType,
        view: union {
            image: rhi.vulkan.vk.DescriptorImageInfo, // sampler + image_view + image_layout
            buffer: rhi.vulkan.vk.DescriptorBufferInfo, // buffer + offset + range
            accel: rhi.vulkan.vk.AccelerationStructureKHR,
        },
    } else void,
    dx12: if (rhi.platform_has_api(.dx12)) void else void,
    mtl: if (rhi.platform_has_api(.mtl)) void else void,
    // The web backends have no descriptor *sets*: a WebGPU bind group is built
    // from a whole pipeline-owned layout and a GL texture unit is plain global
    // state. What survives is the resource handle, which both backends address
    // as a single id -- `type` says whether it is a texture or a sampler.
    // `Cmd.web_bind_descriptors` consumes these.
    wgpu: if (rhi.platform_has_api(.wgpu)) struct { handle: rhi.webgpu.Handle } else void,
    webgl: if (rhi.platform_has_api(.webgl)) struct { handle: rhi.webgl.Handle } else void,
} = undefined,

pub fn isEmpty(self: Descriptor) bool {
    return self.cookie == 0;
}

/// Fold a resource cookie + binding params into the descriptor's identity
/// cookie. A 0 resource cookie passes through as 0 (empty), and the result is
/// nudged off 0 so a non-empty descriptor never aliases the empty sentinel.
fn derive(resource_cookie: u64, kind: rhi.DescriptorType, a: u64, b: u64) u64 {
    if (resource_cookie == 0) return 0;
    const parts = [_]u64{ resource_cookie, @intFromEnum(kind), a, b };
    const h = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, std.mem.sliceAsBytes(parts[0..]));
    return if (h == 0) 1 else h;
}

// ---- Backend-neutral descriptor builders ---------------------------------
// Each resolves the backend handle inline (while the referenced resource is
// alive) and derives the cookie from that resource's cookie. The `device`
// param selects the backend; on unsupported backends the builder yields an
// empty descriptor.

pub fn uniformBuffer(device: *rhi.Device,buf: *const rhi.Buffer, offset: u64, range: u64) Descriptor {
    _ = device; // kept for call-site stability; resolution needs only renderer + buf
    if (rhi.is_target_selected(.vk)) {
        return .{
            .cookie = derive(buf.cookie, .uniform_buffer, offset, range),
            .type = .uniform_buffer,
            .backend = .{ .vk = .{
                .type = .uniform_buffer,
                .view = .{ .buffer = .{ .buffer = buf.backend.vk.buffer, .offset = offset, .range = range } },
            } },
        };
    }
    return .{};
}

pub fn storageBuffer(device: *rhi.Device,buf: *const rhi.Buffer, offset: u64, range: u64) Descriptor {
    _ = device;
    if (rhi.is_target_selected(.vk)) {
        return .{
            .cookie = derive(buf.cookie, .storage_buffer, offset, range),
            .type = .storage_buffer,
            .backend = .{ .vk = .{
                .type = .storage_buffer,
                .view = .{ .buffer = .{ .buffer = buf.backend.vk.buffer, .offset = offset, .range = range } },
            } },
        };
    }
    return .{};
}

/// Sampled (read-only) image. Bound in `shader_read_only_optimal`.
pub fn sampledImage(device: *rhi.Device,view: *const rhi.ImageView) Descriptor {
    _ = device;
    if (rhi.is_target_selected(.vk)) {
        return .{
            .cookie = derive(view.cookie, .sampled_image, 0, 0),
            .type = .sampled_image,
            .backend = .{ .vk = .{
                .type = .sampled_image,
                .view = .{ .image = .{
                    .sampler = .null_handle,
                    .image_view = view.backend.vk,
                    .image_layout = .shader_read_only_optimal,
                } },
            } },
        };
    }
    if (rhi.is_target_selected(.wgpu)) {
        // The wgpu arm of `ImageView.backend` is the handle itself, not a
        // struct wrapping one.
        return .{
            .cookie = derive(view.cookie, .sampled_image, 0, 0),
            .type = .sampled_image,
            .backend = .{ .wgpu = .{ .handle = view.backend.wgpu } },
        };
    }
    if (rhi.is_target_selected(.webgl)) {
        return .{
            .cookie = derive(view.cookie, .sampled_image, 0, 0),
            .type = .sampled_image,
            .backend = .{ .webgl = .{ .handle = view.backend.webgl.texture } },
        };
    }
    return .{};
}

/// Read/write storage image. Bound in `general`.
pub fn storageImage(device: *rhi.Device,view: *const rhi.ImageView) Descriptor {
    _ = device;
    if (rhi.is_target_selected(.vk)) {
        return .{
            .cookie = derive(view.cookie, .storage_image, 0, 0),
            .type = .storage_image,
            .backend = .{ .vk = .{
                .type = .storage_image,
                .view = .{ .image = .{
                    .sampler = .null_handle,
                    .image_view = view.backend.vk,
                    .image_layout = .general,
                } },
            } },
        };
    }
    return .{};
}

pub fn accelerationStructure(device: *rhi.Device,as: *const rhi.AccelerationStructure) Descriptor {
    _ = device;
    if (rhi.is_target_selected(.vk)) {
        return .{
            .cookie = derive(as.cookie, .acceleration_structure, 0, 0),
            .type = .acceleration_structure,
            .backend = .{ .vk = .{
                .type = .acceleration_structure_khr,
                .view = .{ .accel = as.backend.vk.handle },
            } },
        };
    }
    return .{};
}

pub fn sampler(device: *rhi.Device,s: *const rhi.Sampler) Descriptor {
    _ = device;
    if (rhi.is_target_selected(.vk)) {
        return .{
            .cookie = derive(s.cookie, .sampler, 0, 0),
            .type = .sampler,
            .backend = .{ .vk = .{
                .type = .sampler,
                .view = .{ .image = .{
                    .sampler = s.backend.vk.sampler,
                    .image_view = .null_handle,
                    .image_layout = .undefined,
                } },
            } },
        };
    }
    if (rhi.is_target_selected(.wgpu)) {
        return .{
            .cookie = derive(s.cookie, .sampler, 0, 0),
            .type = .sampler,
            .backend = .{ .wgpu = .{ .handle = s.backend.wgpu.sampler } },
        };
    }
    if (rhi.is_target_selected(.webgl)) {
        return .{
            .cookie = derive(s.cookie, .sampler, 0, 0),
            .type = .sampler,
            .backend = .{ .webgl = .{ .handle = s.backend.webgl.sampler } },
        };
    }
    return .{};
}

// ---- Named bindings ------------------------------------------------------
// A descriptor plus the shader-side name it is addressed by. Core rather than
// rpi-local, because both binding paths speak it: `rpi.Program.bindDescriptors`
// resolves the name against a `rpi.Layout`, `Cmd.web_bind_descriptors`
// against the pipeline's declared `texture_bindings`.

/// Stable identity for a named descriptor binding. The hash is what the binders
/// look up; the name is kept for diagnostics. Mirrors `DescriptorBindingID`.
pub const DescriptorBindingID = struct {
    name: []const u8,
    hash: u64,

    pub fn create(name: []const u8) DescriptorBindingID {
        return .{ .name = name, .hash = std.hash.Wyhash.hash(0, name) };
    }
};

/// A live binding handed to a binder: a name handle + the descriptor to write at
/// it, optionally offset within an array. Mirrors
/// `RIProgram::DescriptorBinding`.
pub const DescriptorBinding = struct {
    handle: DescriptorBindingID,
    register_offset: u32 = 0,
    descriptor: Descriptor,

    pub fn init(name: []const u8, desc: Descriptor, register_offset: u32) DescriptorBinding {
        return .{
            .handle = DescriptorBindingID.create(name),
            .register_offset = register_offset,
            .descriptor = desc,
        };
    }
};
