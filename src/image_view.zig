// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

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
        wgpu: if (rhi.platform_has_api(.wgpu)) rhi.webgpu.Handle else void,
        // GL has no view object; a view is the texture plus the description an
        // FBO attachment needs, carried on the Image.
        webgl: if (rhi.platform_has_api(.webgl)) struct {
            texture: rhi.webgl.Handle = .none,
            format: rhi.Format = .unknown,
            width: u32 = 0,
            height: u32 = 0,
        } else void,
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
                .color         => .{ .color = true },
                .depth         => .{ .depth = true },
                .stencil       => .{ .stencil = true },
                .depth_stencil => .{ .depth = true, .stencil = true },
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
        if (rhi.is_target_selected(.webgl)) {
            // GL has no view object: an FBO attachment references the texture
            // directly, so a view is the texture plus what an attachment needs.
            if (desc.base_mip != 0 or desc.mip_num != 1 or desc.base_layer != 0 or desc.layer_num != 1)
                return error.UnsupportedBackend;
            // Validates the format even though nothing is created from it here,
            // so an unsupported one is reported at view creation rather than at
            // framebuffer completeness.
            _ = try rhi.webgl.to_gl_format(desc.format);
            return .{
                .backend = .{ .webgl = .{
                    .texture = image.backend.webgl.texture,
                    .format = desc.format,
                    .width = image.backend.webgl.width,
                    .height = image.backend.webgl.height,
                } },
                .cookie = rhi.next_cookie(),
            };
        }
        if (rhi.is_target_selected(.wgpu)) {
            const wgpu = rhi.webgpu;
            const view = wgpu.wgpu_texture_create_view(
                image.backend.wgpu.texture,
                try wgpu.to_wgpu_texture_format(desc.format),
                try wgpu.to_wgpu_view_dimension(desc.view_type),
                wgpu.to_wgpu_aspect(desc.aspect),
                desc.base_mip,
                desc.mip_num,
                desc.base_layer,
                desc.layer_num,
            );
            if (view.isNone()) return error.WebGPUTextureViewCreationFailed;
            return .{ .backend = .{ .wgpu = view }, .cookie = rhi.next_cookie() };
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
        // Like Metal, GL has no view object; the Image owns the texture. The
        // cached FBOs keyed on this view's cookie do have to go, though.
        if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
            device.backend.webgl.fbo_cache.invalidate(self.cookie);
            return;
        }
        // WebGPU views are real objects, unlike Metal's, so they must be dropped.
        if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
            rhi.webgpu.wgpu_release(self.backend.wgpu);
            self.backend.wgpu = .none;
            return;
        }
    }
};
