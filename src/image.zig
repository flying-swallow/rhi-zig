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

/// How an image is bound through a view (mirrors `RITextureViewType_e`),
/// including the 3D sampled/storage variants added upstream.
pub const ViewType = enum {
    shader_resource_1d,
    shader_resource_1d_array,
    shader_resource_2d,
    shader_resource_2d_array,
    shader_resource_cube,
    shader_resource_cube_array,
    shader_resource_3d,
    shader_resource_storage_1d,
    shader_resource_storage_1d_array,
    shader_resource_storage_2d,
    shader_resource_storage_2d_array,
    shader_resource_storage_3d,
    color_attachment,
    depth_stencil_attachment,
};

/// A view onto an `Image`. Carries a `cookie` so it can be referenced as a
/// bindless descriptor source (`Descriptor.sampledImage` / `.storageImage`);
/// attachment-only views may leave it 0.
pub const ImageView = struct {
    backend: union(rhi.Backend) {
        vk: if (rhi.platform_has_api(.vk)) rhi.vulkan.vk.ImageView else void,
        dx12: rhi.wrapper_platform_type(.dx12, struct {}),
        mtl: if (rhi.platform_has_api(.mtl)) rhi.metal.mtl.Texture else void,
    },
    cookie: u64 = 0,

    pub fn isEmpty(self: ImageView) bool {
        return self.cookie == 0;
    }
};

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
            transient_attachment: bool = false,
            input_attachment: bool = false,
        },
        memory_usage: enum { auto, prefer_device, prefer_host } = .auto,
    },
) !Image {
    if (rhi.is_target_selected(.vk)) {
        // zig fmt: off
        const usage = rhi.vulkan.vk.ImageUsageFlags{
            .transfer_src_bit = options.usage.transfer_src,
            .transfer_dst_bit = options.usage.transfer_dst,
            .sampled_bit = options.usage.sampled,
            .storage_bit = options.usage.storage,
            .color_attachment_bit = options.usage.color_attachment,
            .depth_stencil_attachment_bit = options.usage.depth_stencil_attachment,
            .transient_attachment_bit = options.usage.transient_attachment,
            .input_attachment_bit = options.usage.input_attachment,
        };
        // zig fmt: on

        var image_create_info: rhi.vulkan.vk.ImageCreateInfo = .{
            .image_type = switch (options.image_type) {
                .type_1d => .type_1d,
                .type_2d => .type_2d,
                .type_3d => .type_3d,
            },
            .format = rhi.vulkan.to_vk_format(options.format),
            .extent = .{ .width = options.width, .height = options.height, .depth = options.depth },
            .mip_levels = options.mip_levels,
            .array_layers = options.array_layers,
            .samples = switch (options.samples) {
                .@"1" => .{ .@"1_bit" = true },
                .@"2" => .{ .@"2_bit" = true },
                .@"4" => .{ .@"4_bit" = true },
                .@"8" => .{ .@"8_bit" = true },
                .@"16" => .{ .@"16_bit" = true },
                .@"32" => .{ .@"32_bit" = true },
                .@"64" => .{ .@"64_bit" = true },
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
    unreachable;
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
    unreachable;
}

/// A depth render target sized to a render area. Bundles the backing image and
/// (on Vulkan) its image view; on Metal it is a single private texture. Used as
/// the depth attachment in `Cmd.begin_rendering`.
pub const DepthTexture = struct {
    width: u32,
    height: u32,
    /// Stable cookie for the depth view, minted once at init so repeated
    /// `view()` calls return a stable descriptor identity.
    view_cookie: u64 = 0,
    backend: union {
        vk: if (rhi.platform_has_api(.vk)) struct {
            image: rhi.vulkan.vk.Image,
            allocation: vma.c.VmaAllocation,
            view: rhi.vulkan.vk.ImageView,
        } else void,
        dx12: rhi.wrapper_platform_type(.dx12, struct {}),
        mtl: if (rhi.platform_has_api(.mtl)) struct {
            texture: rhi.metal.mtl.Texture,
        } else void,
    },

    /// 32-bit float depth (`VK_FORMAT_D32_SFLOAT` / `MTLPixelFormatDepth32Float`).
    pub fn init(device: *rhi.Device, width: u32, height: u32) !DepthTexture {
        if (rhi.is_target_selected(.vk)) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            var image_create_info: rhi.vulkan.vk.ImageCreateInfo = .{
                .image_type = .@"2d",
                .format = .d32_sfloat,
                .extent = .{ .width = width, .height = height, .depth = 1 },
                .mip_levels = 1,
                .array_layers = 1,
                .samples = .{ .@"1_bit" = true },
                .tiling = .optimal,
                .usage = .{ .depth_stencil_attachment_bit = true },
                .sharing_mode = .exclusive,
                .initial_layout = .undefined,
            };
            var allocation_info: vma.c.VmaAllocationCreateInfo = .{};
            allocation_info.usage = vma.c.VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE;
            var vma_info = vma.c.VmaAllocationInfo{};
            var vk_image: vma.c.VkImage = undefined;
            var vma_alloc: vma.c.VmaAllocation = undefined;
            try rhi.vulkan.VKWrapResult(@enumFromInt(vma.c.vmaCreateImage(
                device.backend.vk.vma_allocator,
                @ptrCast(&image_create_info),
                &allocation_info,
                &vk_image,
                &vma_alloc,
                &vma_info,
            )));
            const depth_image: rhi.vulkan.vk.Image = @enumFromInt(@intFromPtr(vk_image));
            const view_create_info: rhi.vulkan.vk.ImageViewCreateInfo = .{
                .image = depth_image,
                .view_type = .@"2d",
                .format = .d32_sfloat,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{ .aspect_mask = .{ .depth_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
            };
            const depth_view = try dkb.createImageView(device.backend.vk.device, &view_create_info, null);
            return .{ .width = width, .height = height, .view_cookie = rhi.next_cookie(), .backend = .{ .vk = .{ .image = depth_image, .allocation = vma_alloc, .view = depth_view } } };
        }
        if (rhi.is_target_selected(.mtl)) {
            const desc = rhi.metal.mtl.TextureDescriptor.texture2D(.depth32float, width, height, false);
            desc.setUsage(.{ .render_target = true });
            desc.setStorageMode(.private);
            const texture = device.backend.mtl.device.newTexture(desc) orelse return error.MetalDepthTextureFailed;
            return .{ .width = width, .height = height, .view_cookie = rhi.next_cookie(), .backend = .{ .mtl = .{ .texture = texture } } };
        }
        return error.UnsupportedBackend;
    }

    pub fn deinit(self: *DepthTexture, device: *rhi.Device) void {
        if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            dkb.destroyImageView(device.backend.vk.device, self.backend.vk.view, null);
            vma.c.vmaDestroyImage(device.backend.vk.vma_allocator, @ptrFromInt(@intFromEnum(self.backend.vk.image)), self.backend.vk.allocation);
            return;
        }
        if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
            self.backend.mtl.texture.release();
            return;
        }
    }

    /// The attachment view to pass to `Cmd.begin_rendering`'s depth attachment.
    pub fn view(self: *DepthTexture) ImageView {
        if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
            return .{ .backend = .{ .vk = self.backend.vk.view }, .cookie = self.view_cookie };
        }
        if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
            return .{ .backend = .{ .mtl = self.backend.mtl.texture }, .cookie = self.view_cookie };
        }
        unreachable;
    }

    /// A transient `Image` view of the depth target for `Cmd.resource_barrier`
    /// (Vulkan layout transitions; a no-op target on Metal).
    pub fn image(self: *DepthTexture) Image {
        if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
            return .{ .backend = .{ .vk = .{ .image = self.backend.vk.image, .allocation = null } } };
        }
        if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
            return .{ .backend = .{ .mtl = .{ .texture = self.backend.mtl.texture } } };
        }
        unreachable;
    }
};
