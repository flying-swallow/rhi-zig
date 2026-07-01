const rhi = @import("root.zig");
const std = @import("std");

/// How an image is bound through a view (mirrors `RITextureViewType_e`).
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
    depth_readonly_stencil_attachment,
    depth_attachment_stencil_readonly,
    depth_stencil_readonly,
    shading_rate_attachment,
};

/// Backend-neutral view descriptor consumed by `ImageView.init` (mirrors `RITextureViewDesc`).
pub const ViewDesc = struct {
    view_type: ViewType = .shader_resource_2d,
    format: rhi.Format,
    aspect: enum { color, depth, stencil, depth_stencil } = .color,
    base_mip: u32 = 0,
    mip_num: u32 = 1,
    base_layer: u32 = 0,
    layer_num: u32 = 1,
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

    pub fn init(
        device: *rhi.Device,
        image: *const rhi.Image,
        desc: ViewDesc,
    ) !ImageView {
        if (rhi.is_target_selected(.vk)) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            const aspect_mask: rhi.vulkan.vk.ImageAspectFlags = switch (desc.aspect) {
                .color         => .{ .color_bit = true },
                .depth         => .{ .depth_bit = true },
                .stencil       => .{ .stencil_bit = true },
                .depth_stencil => .{ .depth_bit = true, .stencil_bit = true },
            };
            const vk_view_type: rhi.vulkan.vk.ImageViewType = switch (desc.view_type) {
                .shader_resource_1d,
                .shader_resource_storage_1d              => .@"1d",
                .shader_resource_1d_array,
                .shader_resource_storage_1d_array        => .@"1d_array",
                .shader_resource_2d,
                .shader_resource_storage_2d,
                .color_attachment,
                .depth_stencil_attachment,
                .depth_readonly_stencil_attachment,
                .depth_attachment_stencil_readonly,
                .depth_stencil_readonly,
                .shading_rate_attachment                 => .@"2d",
                .shader_resource_2d_array,
                .shader_resource_storage_2d_array        => .@"2d_array",
                .shader_resource_cube                    => .cube,
                .shader_resource_cube_array              => .cube_array,
                .shader_resource_3d,
                .shader_resource_storage_3d              => .@"3d",
            };
            const view_create_info: rhi.vulkan.vk.ImageViewCreateInfo = .{
                .image = image.backend.vk.image,
                .view_type = vk_view_type,
                .format = rhi.vulkan.to_vk_format(desc.format),
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = aspect_mask,
                    .base_mip_level = desc.base_mip,
                    .level_count = desc.mip_num,
                    .base_array_layer = desc.base_layer,
                    .layer_count = desc.layer_num,
                },
            };
            const vk_view = try dkb.createImageView(device.backend.vk.device, &view_create_info, null);
            return .{ .backend = .{ .vk = vk_view }, .cookie = rhi.next_cookie() };
        }
        if (rhi.is_target_selected(.mtl)) {
            // Metal textures are their own views.
            return .{ .backend = .{ .mtl = image.backend.mtl.texture }, .cookie = rhi.next_cookie() };
        }
        return error.UnsupportedBackend;
    }

    pub fn deinit(self: *ImageView, device: *rhi.Device) void {
        if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
            var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
            dkb.destroyImageView(device.backend.vk.device, self.backend.vk, null);
            return;
        }
        // Metal: no-op — Image owns the MTLTexture.
        if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) return;
    }
};
