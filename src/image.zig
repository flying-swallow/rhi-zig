// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const vma = @import("root.zig").vma;
const std = @import("std");

pub const Barrier = union {
    vk: if (rhi.platform_has_api(.vk)) rhi.vulkan.vk.ImageMemoryBarrier2 else void,
    dx12: if (rhi.platform_has_api(.dx12)) void else void,
    mtl: if (rhi.platform_has_api(.mtl)) void else void,
};

pub const Image = @This();
/// Stable identity / descriptor-set cache key, stamped at creation (0 == empty).
cookie: u64 = 0,
backend: union {
    vk: if (rhi.platform_has_api(.vk)) struct {
        image: rhi.vulkan.vk.Image,
        allocation: ?vma.c.VmaAllocation = null,
    } else void,
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    // A Metal texture is its own view, so there is no separate view object.
    mtl: rhi.wrapper_platform_type(.mtl, struct {
        texture: rhi.metal.mtl.Texture,
    }),
},

/// An unset / not-yet-created image (cookie 0).
pub fn isEmpty(self: Image) bool {
    return self.cookie == 0;
}

pub fn init(
    device: *rhi.Device,
    options: struct {
        image_type: enum { type_1d, type_2d, type_3d } = .type_2d,
        format: rhi.Format,
        width: u32,
        height: u32 = 1,
        depth: u32 = 1,
        mip_levels: u32 = 1,
        array_layers: u32 = 1,
        samples: enum { @"1", @"2", @"4", @"8", @"16", @"32", @"64" } = .@"1",
        tiling: enum { optimal, linear } = .optimal,
        usage: struct {
            transfer_src: bool = false,
            transfer_dst: bool = false,
            sampled: bool = false,
            storage: bool = false,
            color_attachment: bool = false,
            depth_stencil_attachment: bool = false,
            shading_rate: bool = false,
            transient_attachment: bool = false,
            input_attachment: bool = false,
        },
        /// Image creation flags (mirrors `RITextureFlagBits_e`).
        flags: struct {
            /// Image may back a cube / cube-array view
            /// (`VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT`).
            cube_compatible: bool = false,
            /// Block-compressed image may be viewed with an uncompressed format
            /// (`VK_IMAGE_CREATE_BLOCK_TEXEL_VIEW_COMPATIBLE_BIT`).
            block_texel_view_compatible: bool = false,
        } = .{},
        memory_usage: enum { auto, prefer_device, prefer_host } = .auto,
    },
) !Image {
    if (rhi.is_target_selected(.vk)) {
        // zig fmt: off
        const usage = rhi.vulkan.vk.ImageUsageFlags{
            .transfer_src = options.usage.transfer_src,
            .transfer_dst = options.usage.transfer_dst,
            .sampled = options.usage.sampled,
            .storage = options.usage.storage,
            .color_attachment = options.usage.color_attachment,
            .depth_stencil_attachment = options.usage.depth_stencil_attachment,
            .fragment_shading_rate_attachment_khr = options.usage.shading_rate,
            .transient_attachment = options.usage.transient_attachment,
            .input_attachment = options.usage.input_attachment,
        };
        const create_flags = rhi.vulkan.vk.ImageCreateFlags{
            .cube_compatible = options.flags.cube_compatible,
            .block_texel_view_compatible = options.flags.block_texel_view_compatible,
        };
        // zig fmt: on

        var image_create_info: rhi.vulkan.vk.ImageCreateInfo = .{
            .flags = create_flags,
            .image_type = switch (options.image_type) {
                .type_1d => .@"1d",
                .type_2d => .@"2d",
                .type_3d => .@"3d",
            },
            .format = rhi.vulkan.to_vk_format(options.format),
            .extent = .{ .width = options.width, .height = options.height, .depth = options.depth },
            .mip_levels = options.mip_levels,
            .array_layers = options.array_layers,
            .samples = switch (options.samples) {
                .@"1" => .{ .@"1" = true },
                .@"2" => .{ .@"2" = true },
                .@"4" => .{ .@"4" = true },
                .@"8" => .{ .@"8" = true },
                .@"16" => .{ .@"16" = true },
                .@"32" => .{ .@"32" = true },
                .@"64" => .{ .@"64" = true },
            },
            .tiling = switch (options.tiling) {
                .optimal => .optimal,
                .linear => .linear,
            },
            .usage = usage,
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        };

        var allocation_info: vma.c.VmaAllocationCreateInfo = .{};
        allocation_info.usage = switch (options.memory_usage) {
            .prefer_device => vma.c.VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE,
            .prefer_host => vma.c.VMA_MEMORY_USAGE_AUTO_PREFER_HOST,
            .auto => vma.c.VMA_MEMORY_USAGE_AUTO,
        };

        var vma_info = vma.c.VmaAllocationInfo{};
        var vk_image: vma.c.VkImage = undefined;
        var vma_alloc: vma.c.VmaAllocation = undefined;

        // zig fmt: off
        try rhi.vulkan.VKWrapResult(@enumFromInt(vma.c.vmaCreateImage(
            device.backend.vk.vma_allocator,
            @ptrCast(&image_create_info),
            &allocation_info,
            &vk_image,
            &vma_alloc,
            &vma_info,
        )));
        // zig fmt: on

        return .{
            .cookie = rhi.next_cookie(),
            .backend = .{ .vk = .{
                .image = @enumFromInt(@intFromPtr(vk_image)),
                .allocation = vma_alloc,
            } },
        };
    }
    if (rhi.is_target_selected(.mtl)) {
        const pixel_format = rhi.metal.to_mtl_pixel_format(options.format);
        const desc = rhi.metal.mtl.TextureDescriptor.texture2D(pixel_format, options.width, options.height, false);
        var mtl_usage = rhi.metal.types.TextureUsage{};
        if (options.usage.sampled) mtl_usage.shader_read = true;
        if (options.usage.storage) mtl_usage.shader_write = true;
        if (options.usage.color_attachment or options.usage.depth_stencil_attachment) mtl_usage.render_target = true;
        desc.setUsage(mtl_usage);
        desc.setStorageMode(switch (options.memory_usage) {
            .prefer_host => .shared,
            else => .private,
        });
        const texture = device.backend.mtl.device.newTexture(desc) orelse return error.MetalTextureFailed;
        return .{ .cookie = rhi.next_cookie(), .backend = .{ .mtl = .{ .texture = texture } } };
    }
    return error.UnsupportedBackend;
}

pub fn deinit(self: *Image, device: *rhi.Device) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        if (self.backend.vk.allocation) |alloc| {
            vma.c.vmaDestroyImage(
                device.backend.vk.vma_allocator,
                @ptrFromInt(@intFromEnum(self.backend.vk.image)),
                alloc,
            );
        } else {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            dkb.destroyImage(device.backend.vk.device, self.backend.vk.image, null);
        }
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.texture.release();
        return;
    }
    unreachable;
}

