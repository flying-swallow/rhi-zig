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
    wgpu: rhi.wrapper_platform_type(.wgpu, struct {
        texture: rhi.webgpu.Handle = .none,
        format: rhi.Format = .unknown,
        /// A canvas texture is owned by the browser and must not be released by
        /// us; textures we created must.
        owned: bool = true,
    }),
    webgl: rhi.wrapper_platform_type(.webgl, struct {
        texture: rhi.webgl.Handle = .none,
        format: rhi.Format = .unknown,
        width: u32 = 0,
        height: u32 = 0,
        /// The swapchain's colour texture is owned by the swapchain, so a
        /// by-value copy handed out by `Swapchain.image` must not free it.
        owned: bool = true,
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
    if (rhi.is_target_selected(.webgl)) {
        const webgl = rhi.webgl;
        // WebGL2 has no storage images, no VRS, no transient attachments, and
        // no subpass inputs.
        if (options.usage.storage or options.usage.shading_rate or
            options.usage.transient_attachment or options.usage.input_attachment)
            return error.UnsupportedBackend;
        if (options.samples != .@"1") return error.UnsupportedBackend;
        if (options.image_type != .type_2d) return error.UnsupportedBackend;
        if (options.array_layers != 1) return error.UnsupportedBackend;

        const fmt = try webgl.to_gl_format(options.format);
        const texture = webgl.gl_create_texture_2d(fmt.internal_format, options.width, options.height, options.mip_levels);
        if (texture.isNone()) return error.WebGL2TextureCreationFailed;
        return .{
            .cookie = rhi.next_cookie(),
            .backend = .{ .webgl = .{
                .texture = texture,
                .format = options.format,
                .width = options.width,
                .height = options.height,
                .owned = true,
            } },
        };
    }
    if (rhi.is_target_selected(.wgpu)) {
        const wgpu = rhi.webgpu;
        const format = try wgpu.to_wgpu_texture_format(options.format);

        var usage: u32 = 0;
        if (options.usage.transfer_src) usage |= wgpu.TextureUsage.copy_src;
        if (options.usage.transfer_dst) usage |= wgpu.TextureUsage.copy_dst;
        if (options.usage.sampled) usage |= wgpu.TextureUsage.texture_binding;
        if (options.usage.storage) usage |= wgpu.TextureUsage.storage_binding;
        if (options.usage.color_attachment or options.usage.depth_stencil_attachment)
            usage |= wgpu.TextureUsage.render_attachment;

        // WebGPU has no variable-rate shading, no transient (memoryless)
        // attachments, and no subpass input attachments, so a texture asking for
        // one of those cannot be created faithfully.
        if (options.usage.shading_rate or options.usage.transient_attachment or options.usage.input_attachment)
            return error.UnsupportedBackend;
        // Multisampled textures need a resolve path the backend does not have yet.
        if (options.samples != .@"1") return error.UnsupportedBackend;

        const dimension: wgpu.TextureDimension = switch (options.image_type) {
            .type_1d => .@"1d",
            .type_2d => .@"2d",
            .type_3d => .@"3d",
        };
        // WebGPU folds array layers and depth into one `depthOrArrayLayers`.
        const depth_or_layers: u32 = if (options.image_type == .type_3d) options.depth else options.array_layers;

        const texture = wgpu.wgpu_device_create_texture(
            device.backend.wgpu.device,
            format,
            options.width,
            options.height,
            depth_or_layers,
            options.mip_levels,
            1,
            dimension,
            usage,
        );
        if (texture.isNone()) return error.WebGPUTextureCreationFailed;
        return .{
            .cookie = rhi.next_cookie(),
            .backend = .{ .wgpu = .{ .texture = texture, .format = options.format, .owned = true } },
        };
    }
    return error.UnsupportedBackend;
}

/// Bytes per texel, for the row pitch `GPUQueue.writeTexture` requires.
///
/// `rhi.format.GetProps` already carries this as `stride` (bytes per block, and
/// a plain format's block is one texel), so the value comes from there. The
/// narrowing is the caller's, not the table's: this upload path computes a row
/// pitch per texel, so a block-compressed format -- whose pitch is
/// `width / block_width * stride` -- and a depth/stencil format, which
/// `writeTexture` cannot take at all, are reported rather than guessed.
fn texel_size(format: rhi.Format) !u32 {
    const props = rhi.format.GetProps(format);
    if (props.stride == 0 or props.is_compressed) return error.UnsupportedFormat;
    if (props.block_width != 1 or props.block_height != 1) return error.UnsupportedFormat;
    if (props.is_depth or props.is_stencil) return error.UnsupportedFormat;
    return props.stride;
}

/// Upload host pixels straight into one mip level of this texture.
///
/// This exists rather than routing everything through
/// `Cmd.copy_buffer_to_texture` because the browser does not want a staging
/// buffer: `GPUQueue.writeTexture` and `texSubImage2D` both take CPU memory
/// directly, and WebGPU's buffer-to-texture copy additionally imposes a
/// `bytesPerRow % 256` rule that `writeTexture` has no equivalent of. On
/// WebGL2 a buffer source would need `PIXEL_UNPACK_BUFFER`, which collides with
/// the target locking `gl_create_buffer` fixes for a buffer's lifetime.
///
/// It is a one-shot, blocking call meant for load-time uploads. On Vulkan it
/// stages, submits and waits; on the web backends it is a queue operation
/// ordered before any later submit.
pub fn write(self: *Image, device: *rhi.Device, options: struct {
    data: []const u8,
    mip_level: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
    /// Vulkan only: the state the image is in right now. The default suits a
    /// freshly created image; pass `.{ .shader_resource = true }` to overwrite
    /// one that is already being sampled.
    current_state: rhi.cmd.ResourceState = .{},
}) !void {
    if (options.data.len == 0) return;

    if (rhi.is_target_selected(.webgl)) {
        const webgl = rhi.webgl;
        const fmt = try webgl.to_gl_format(self.backend.webgl.format);
        webgl.gl_tex_sub_image_2d(
            self.backend.webgl.texture,
            options.mip_level,
            options.x,
            options.y,
            options.width,
            options.height,
            fmt.format,
            fmt.type,
            options.data.ptr,
            @intCast(options.data.len),
        );
        return;
    }
    if (rhi.is_target_selected(.wgpu)) {
        const wgpu = rhi.webgpu;
        const texel = try texel_size(self.backend.wgpu.format);
        wgpu.wgpu_queue_write_texture(
            device.backend.wgpu.queue,
            self.backend.wgpu.texture,
            options.mip_level,
            options.x,
            options.y,
            0,
            options.width,
            options.height,
            1,
            options.data.ptr,
            @intCast(options.data.len),
            options.width * texel,
            options.height,
        );
        return;
    }
    if (rhi.is_target_selected(.vk)) {
        // Vulkan is the one backend that genuinely needs a staging copy. Doing
        // it here keeps callers off the barrier dance for a load-time upload.
        var staging: rhi.Buffer = try .init_general(device, .{
            .size = options.data.len,
            .persistant_map = true,
            .sequential_access = true,
            .buffer_usage = .prefer_host,
            .usage = .{},
        });
        defer staging.deinit(device);
        @memcpy(staging.mapped_region.?[0..options.data.len], options.data);

        var pool = try rhi.Pool.init(device, &device.graphics_queue);
        defer pool.deinit(device);
        var cmd = try rhi.Cmd.init(device, &pool);
        defer cmd.deinit(device, &pool);

        try cmd.begin(device);
        cmd.image_barrier(device, .{
            .image = self,
            .before = options.current_state,
            .after = .{ .copy_dst = true },
        });
        cmd.copy_buffer_to_texture(device, .{
            .src = &staging,
            .dst = self,
            .buffer_offset = 0,
            .mip_level = options.mip_level,
            .x = @intCast(options.x),
            .y = @intCast(options.y),
            .width = options.width,
            .height = options.height,
        });
        cmd.image_barrier(device, .{
            .image = self,
            .before = .{ .copy_dst = true },
            .after = .{ .shader_resource = true },
        });
        try cmd.end(device);
        try device.graphics_queue.submit(device, .{ .vk = .{ .cmds = &.{&cmd} } });
        try device.graphics_queue.wait_queue_idle(device);
        return;
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
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        if (self.backend.webgl.owned) {
            // FBOs referencing this texture must go with it; GL reuses handles.
            device.backend.webgl.fbo_cache.invalidate(self.cookie);
            rhi.webgl.gl_delete_texture(self.backend.webgl.texture);
        }
        self.backend.webgl.texture = .none;
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        // A canvas texture belongs to the browser and is invalidated at the end
        // of the frame that acquired it; releasing it here would drop a handle
        // we never owned.
        if (self.backend.wgpu.owned) rhi.webgpu.wgpu_release(self.backend.wgpu.texture);
        self.backend.wgpu.texture = .none;
        return;
    }
    unreachable;
}

