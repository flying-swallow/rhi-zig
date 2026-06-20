pub const Swapchain = @This();
pub const rhi = @import("root.zig");
const builtin = @import("builtin");
const vulkan = @import("root.zig").vulkan;
const std = @import("std");

pub const SwapchainFormat = enum { bt709_g10_16bit, bt709_g22_8bit, bt709_g22_10bit, bt2020_g2084_10bit };

pub const WindowType = if (builtin.os.tag == .windows) enum {
    windows,
} else if (builtin.os.tag == .linux) enum {
    x11,
    wayland,
} else if (builtin.os.tag == .macos or .ios) enum { metal } else {
    // Unsupported platform
    @compileError("Unsupported platform for WindowType");
};

pub const WindowHandle = if (builtin.os.tag == .windows) union(WindowType) {
    windows: struct {
        hwnd: ?*anyopaque = null,
        hinstance: ?*anyopaque = null,
    },
} else if (builtin.os.tag == .linux) union(WindowType) {
    x11: struct {
        display: ?*anyopaque = null,
        window: c_ulong = 0,
    },
    wayland: struct {
        display: ?*anyopaque = null,
        surface: ?*anyopaque = null,
        shell_surface: ?*anyopaque = null,
    },
} else if (builtin.os.tag == .macos or .ios) union(WindowType) {
    metal: struct {
        layer: ?*anyopaque = null,
    },
} else {
    // Unsupported platform
    @compileError("Unsupported platform for WindowHandle");
};

allocator: std.mem.Allocator,
width: u16,
height: u16,
backend: union {
    vk: if (rhi.platform_has_api(.vk)) struct {
        pub const Self = @This();

        format: rhi.vulkan.vk.Format,
        swapchain: rhi.vulkan.vk.SwapchainKHR,
        surface: rhi.vulkan.vk.SurfaceKHR,
        images: []rhi.vulkan.vk.Image,
        views: []rhi.vulkan.vk.ImageView,

        signal_idx: u32 = 0,
        signal_semaphores: []rhi.vulkan.vk.Semaphore,

        image_format: rhi.vulkan.vk.Format,
        image_colorspace: rhi.vulkan.vk.ColorSpaceKHR,
        present_mode: rhi.vulkan.vk.PresentModeKHR,

        pub fn current_semaphore(self: *Self) rhi.vulkan.vk.Semaphore {
            return self.signal_semaphores[self.signal_idx];
        }
    } else void,
    dx12: if (rhi.platform_has_api(.dx12)) void else void,
    mtl: if (rhi.platform_has_api(.mtl)) struct {
        layer: rhi.metal.ca.MetalLayer,
        pixel_format: rhi.metal.types.PixelFormat,
        // The drawable acquired this frame (vended by the layer). Held until
        // present.
        current_drawable: ?rhi.metal.ca.MetalDrawable = null,
    } else void,
},

fn vk_wapchain_create_info_khr_default(option: struct { surface: rhi.vulkan.vk.SurfaceKHR, format: rhi.vulkan.vk.Format, present_mode: rhi.vulkan.vk.PresentModeKHR, color_space: rhi.vulkan.vk.ColorSpaceKHR, width: u32, height: u32, image_count: usize }) rhi.vulkan.vk.SwapchainCreateInfoKHR {
    return .{
        .surface = option.surface,
        .min_image_count = @intCast(option.image_count),
        .image_format = option.format,
        .image_color_space = option.color_space,
        .image_extent = .{
            .width = option.width,
            .height = option.height,
        },
        .image_array_layers = 1,
        .image_usage = .{
            .color_attachment_bit = true,
            .transfer_src_bit = true,
        },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = null,
        .pre_transform = .{
            .identity_bit_khr = true,
        },
        .composite_alpha = .{
            .opaque_bit_khr = true,
        },
        .present_mode = option.present_mode,
        .clipped = .true,
    };
}

pub fn image_view(self: *Swapchain, index: u32) rhi.Image.ImageView {
    if (rhi.is_target_selected(.vk)) {
        return .{
            .backend = .{ .vk = self.backend.vk.views[index] },
        };
    }
    if (rhi.is_target_selected(.mtl)) {
        return .{ .backend = .{ .mtl = self.backend.mtl.current_drawable.?.texture() } };
    }
    unreachable;
}

pub fn image(self: *Swapchain, index: u32) rhi.Image {
    if (rhi.is_target_selected(.vk)) {
        return .{
            .backend = .{
                .vk = .{ .image = self.backend.vk.images[index] },
            },
        };
    }
    if (rhi.is_target_selected(.mtl)) {
        return .{ .backend = .{ .mtl = .{ .texture = self.backend.mtl.current_drawable.?.texture() } } };
    }
    unreachable;
}

fn __priority_BT709_G22_16BIT(surface: *const rhi.vulkan.vk.SurfaceFormatKHR) u32 {
    return (@as(u32, @intFromBool(surface.format == .r16g16b16a16_sfloat))) |
        (@as(u32, @intFromBool(surface.color_space == .extended_srgb_linear_ext)) << 1);
}

fn __priority_BT709_G22_8BIT(surface: *const rhi.vulkan.vk.SurfaceFormatKHR) u32 {
    // https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/vkGetPhysicalDeviceSurfaceFormatsKHR.html
    // There is always a corresponding UNORM, SRGB just need to consider UNORM
    return (@as(u32, @intFromBool(surface.format == .r8g8b8a8_unorm or surface.format == .b8g8r8a8_unorm))) |
        (@as(u32, @intFromBool(surface.color_space == .srgb_nonlinear_khr)) << 1);
}

fn __priority_BT709_G22_10BIT(surface: *const rhi.vulkan.vk.SurfaceFormatKHR) u32 {
    return (@as(u32, @intFromBool(surface.format == .a2b10g10r10_unorm_pack32))) |
        (@as(u32, @intFromBool(surface.color_space == .srgb_nonlinear_khr)) << 1);
}

fn __priority_BT2020_G2084_10BIT(surface: *const rhi.vulkan.vk.SurfaceFormatKHR) u32 {
    return (@as(u32, @intFromBool(surface.format == .a2b10g10r10_unorm_pack32))) |
        (@as(u32, @intFromBool(surface.color_space == .hdr10_st2084_ext)) << 1);
}

pub fn deinit(self: *Swapchain, device: *rhi.Device) void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var ikb: *rhi.vulkan.vk.InstanceWrapper = &rhi.renderer.instance.backend.vk.ikb;
        for (self.backend.vk.signal_semaphores) |sem| {
            dkb.destroySemaphore(device.backend.vk.device, sem, null);
        }
        for (self.backend.vk.views) |view| {
            dkb.destroyImageView(device.backend.vk.device, view, null);
        }
        dkb.destroySwapchainKHR(device.backend.vk.device, self.backend.vk.swapchain, null);
        ikb.destroySurfaceKHR(rhi.renderer.instance.backend.vk.instance, self.backend.vk.surface, null);
        self.allocator.free(self.backend.vk.images);
        self.allocator.free(self.backend.vk.views);
        self.allocator.free(self.backend.vk.signal_semaphores);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        // The CAMetalLayer is owned by the window/SDL; nothing to free here.
        return;
    }
    unreachable;
}

pub const NextImageResult = struct { image_index: u32, backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct {
        semaphore: rhi.vulkan.vk.Semaphore,
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
} };

pub fn acquire_next_image(self: *Swapchain, device: *rhi.Device) !u32 {
    std.debug.assert(self.backend.vk.images.len > 0);
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        self.backend.vk.signal_idx = (self.backend.vk.signal_idx + 1) % @as(u32, @intCast(self.backend.vk.signal_semaphores.len));
        const res = try dkb.acquireNextImageKHR(device.backend.vk.device, self.backend.vk.swapchain, std.math.maxInt(u64), self.backend.vk.signal_semaphores[self.backend.vk.signal_idx], .null_handle);
        return res.image_index;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        // Metal has no image-index concept — the layer vends the next drawable
        // synchronously. Hold it for rendering/present; index 0 is inert.
        self.backend.mtl.current_drawable = self.backend.mtl.layer.nextDrawable() orelse
            return error.MetalNoDrawable;
        return 0;
    }
    unreachable;
}

pub fn present_vk(self: *Swapchain, device: *rhi.Device, queue: *rhi.Queue, image_index: u32, wait_semaphores: []const rhi.vulkan.vk.Semaphore ) !void {
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var swapchains = [_]rhi.vulkan.vk.SwapchainKHR{self.backend.vk.swapchain};
        var image_indices = [_]u32{image_index};

        var present_info = rhi.vulkan.vk.PresentInfoKHR{
            .swapchain_count = 1,
            .p_swapchains = swapchains[0..].ptr,
            .p_image_indices = image_indices[0..].ptr,
            .wait_semaphore_count = @intCast(wait_semaphores.len),
            .p_wait_semaphores = wait_semaphores.ptr,
        };
        _ = try dkb.queuePresentKHR(queue.backend.vk.queue, &present_info);
        return;
    }
    unreachable;
}

/// Backend-agnostic end-of-frame: end the command buffer, submit it (signalling
/// the ring's sync primitive and waiting on the acquire semaphore), and present.
/// Replaces the inline submit/present the examples used to do against raw Vulkan.
pub fn frame_submit(self: *Swapchain, device: *rhi.Device, queue: *rhi.Queue, options: struct {
    image_index: u32,
    ring_element: *rhi.cmd.CommandRingElement,
    cmd: *rhi.Cmd,
}) !void {
    try options.cmd.end(device);
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const cmd_submit = [_]rhi.vulkan.vk.CommandBufferSubmitInfo{.{
            .command_buffer = options.cmd.backend.vk.cmd,
            .device_mask = 0,
        }};
        const wait_semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
            .semaphore = self.backend.vk.current_semaphore(),
            .stage_mask = .{ .color_attachment_output_bit = true },
            .value = 0,
            .device_index = 0,
        }};
        const signal_semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
            .semaphore = options.ring_element.backend.vk.semaphore,
            .value = 0,
            .stage_mask = .{ .all_commands_bit = true },
            .device_index = 0,
        }};
        var submit_info = [_]rhi.vulkan.vk.SubmitInfo2{.{
            .p_command_buffer_infos = cmd_submit[0..].ptr,
            .command_buffer_info_count = cmd_submit.len,
            .p_wait_semaphore_infos = wait_semaphore_info[0..].ptr,
            .wait_semaphore_info_count = wait_semaphore_info.len,
            .p_signal_semaphore_infos = signal_semaphore_info[0..].ptr,
            .signal_semaphore_info_count = signal_semaphore_info.len,
        }};
        std.debug.assert(try dkb.getFenceStatus(device.backend.vk.device, options.ring_element.backend.vk.fence) == .success);
        var reset_fence = [_]rhi.vulkan.vk.Fence{options.ring_element.backend.vk.fence};
        _ = try dkb.resetFences(device.backend.vk.device, reset_fence[0..]);
        _ = try dkb.queueSubmit2(queue.backend.vk.queue, submit_info[0..], options.ring_element.backend.vk.fence);

        var wait_semaphores = [_]rhi.vulkan.vk.Semaphore{options.ring_element.backend.vk.semaphore};
        try self.present_vk(device, queue, options.image_index, &wait_semaphores);
        return;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        const drawable = self.backend.mtl.current_drawable orelse return error.MetalNoDrawable;
        const cb = options.cmd.backend.mtl.cmd orelse return error.MetalNoCommandBuffer;
        cb.presentDrawable(drawable.id());
        cb.commit();
        self.backend.mtl.current_drawable = null;
        return;
    }
    unreachable;
}

pub fn resize(self: *Swapchain, device: *rhi.Device, width: u16, height: u16) !bool {
    if (width == self.width and height == self.height) {
        return false;
    }
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        self.backend.mtl.layer.setDrawableSize(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) });
        self.width = width;
        self.height = height;
        return true;
    }
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const old_swapchain = self.backend.vk.swapchain;
        var swapchain_create_info = vk_wapchain_create_info_khr_default(.{
            .surface = self.backend.vk.surface,
            .format = self.backend.vk.image_format,
            .present_mode = self.backend.vk.present_mode,
            .color_space = self.backend.vk.image_colorspace,
            .width = width,
            .height = height,
            .image_count = self.backend.vk.images.len,
        });
        swapchain_create_info.old_swapchain = old_swapchain;
        self.backend.vk.swapchain = try dkb.createSwapchainKHR(device.backend.vk.device, &swapchain_create_info, null);
        dkb.destroySwapchainKHR(device.backend.vk.device, old_swapchain, null);
        for (self.backend.vk.views) |view| {
            dkb.destroyImageView(device.backend.vk.device, view, null);
        }
        self.allocator.free(self.backend.vk.views);
        self.allocator.free(self.backend.vk.images);
        self.backend.vk.views = &[_]rhi.vulkan.vk.ImageView{};
        self.backend.vk.images = &[_]rhi.vulkan.vk.Image{};

        const images = p: {
            var imageNum: u32 = 0;
            _ = try dkb.getSwapchainImagesKHR(device.backend.vk.device, self.backend.vk.swapchain, &imageNum, null);
            const res = try self.allocator.alloc(rhi.vulkan.vk.Image, imageNum);
            _ = try dkb.getSwapchainImagesKHR(device.backend.vk.device, self.backend.vk.swapchain, &imageNum, res.ptr);
            break :p res;
        };
        errdefer self.allocator.free(images);
        const image_views = try self.allocator.alloc(rhi.vulkan.vk.ImageView, images.len);
        errdefer self.allocator.free(image_views);

        for (0..images.len) |k| {
            const view_create_info: rhi.vulkan.vk.ImageViewCreateInfo = .{
                .s_type = .image_view_create_info,
                .image = images[k],
                .view_type = .@"2d",
                .format = self.backend.vk.image_format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{
                        .color_bit = true,
                    },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            image_views[k] = try dkb.createImageView(device.backend.vk.device, &view_create_info, null);
        }

        self.backend.vk.images = images;
        self.backend.vk.views = image_views;
        self.width = width;
        self.height = height;
        return true;
    }
    unreachable;
}

pub fn init(allocator: std.mem.Allocator, device: *rhi.Device, width: u16, height: u16, handle: WindowHandle, option: struct {
    format: SwapchainFormat = .bt709_g22_8bit,
    request_image_count: u32 = 3,
}) !Swapchain {
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        const layer = rhi.metal.ca.MetalLayer.fromId(@ptrCast(@alignCast(handle.metal.layer))) orelse return error.MetalNoLayer;
        const pixel_format: rhi.metal.types.PixelFormat = switch (option.format) {
            .bt709_g22_8bit => .bgra8unorm,
            else => .bgra8unorm,
        };
        layer.setDevice(device.backend.mtl.device);
        layer.setPixelFormat(pixel_format);
        layer.setDrawableSize(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) });
        return Swapchain{
            .allocator = allocator,
            .width = width,
            .height = height,
            .backend = .{ .mtl = .{
                .layer = layer,
                .pixel_format = pixel_format,
                .current_drawable = null,
            } },
        };
    }
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var ikb: *rhi.vulkan.vk.InstanceWrapper = &rhi.renderer.instance.backend.vk.ikb;
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const surface: rhi.vulkan.vk.SurfaceKHR = if (builtin.os.tag == .windows) {} else if (builtin.os.tag == .linux) p: {
            switch (handle) {
                .x11 => |val| {
                    var xlib_surface_create: rhi.vulkan.vk.XlibSurfaceCreateInfoKHR = .{
                        .s_type = .xlib_surface_create_info_khr,
                        .dpy = @ptrCast(val.display),
                        .window = val.window,
                    };
                    break :p try ikb.createXlibSurfaceKHR(rhi.renderer.instance.backend.vk.instance, &xlib_surface_create, null);
                },
                .wayland => |val| {
                    var wayland_surface_create: rhi.vulkan.vk.WaylandSurfaceCreateInfoKHR = .{
                        .s_type = .wayland_surface_create_info_khr,
                        .display = @ptrCast(val.display),
                        .surface = @ptrCast(val.surface),
                    };
                    break :p try ikb.createWaylandSurfaceKHR(rhi.renderer.instance.backend.vk.instance, &wayland_surface_create, null);
                },
            }
            return error.Unsupported;
        } else if (builtin.os.tag == .macos or builtin.os.tag == .ios) {} else {
            @compileError("Unsupported platform for Swapchain.init");
        };
        const avaliable_surface_formats = p: {
            var numSurfaceFormats: u32 = 0;
            _ = try ikb.getPhysicalDeviceSurfaceFormatsKHR(device.adapter.backend.vk.physical_device, surface, &numSurfaceFormats, null);
            const surface_formats = try allocator.alloc(rhi.vulkan.vk.SurfaceFormatKHR, numSurfaceFormats);
            _ = try ikb.getPhysicalDeviceSurfaceFormatsKHR(device.adapter.backend.vk.physical_device, surface, &numSurfaceFormats, surface_formats.ptr);
            break :p surface_formats;
        };
        defer allocator.free(avaliable_surface_formats);
        var selected_surface: *const rhi.vulkan.vk.SurfaceFormatKHR = &avaliable_surface_formats[0];
        const selection_fn = switch (option.format) {
            .bt709_g10_16bit => &__priority_BT709_G22_16BIT,
            .bt709_g22_8bit => &__priority_BT709_G22_8BIT,
            .bt709_g22_10bit => &__priority_BT709_G22_10BIT,
            .bt2020_g2084_10bit => &__priority_BT2020_G2084_10BIT,
        };
        for (avaliable_surface_formats) |*fmt| {
            if (selection_fn(fmt) > selection_fn(selected_surface)) {
                selected_surface = fmt;
            }
        }

        const avaliable_present_modes = p: {
            var numSurfaceFormats: u32 = 0;
            _ = try ikb.getPhysicalDeviceSurfacePresentModesKHR(device.adapter.backend.vk.physical_device, surface, &numSurfaceFormats, null);
            const present_modes = try allocator.alloc(rhi.vulkan.vk.PresentModeKHR, numSurfaceFormats);
            _ = try ikb.getPhysicalDeviceSurfacePresentModesKHR(device.adapter.backend.vk.physical_device, surface, &numSurfaceFormats, present_modes.ptr);
            break :p present_modes;
        };
        defer allocator.free(avaliable_present_modes);

        // The VK_PRESENT_MODE_FIFO_KHR mode must always be present as per spec
        // This mode waits for the vertical blank ("v-sync")
        const present_mode: rhi.vulkan.vk.PresentModeKHR = found: {
            const preferred_mode_list = [_]rhi.vulkan.vk.PresentModeKHR{
                .immediate_khr,
                .fifo_relaxed_khr,
                .fifo_khr,
            };
            for (preferred_mode_list) |preferred_mode| {
                for (avaliable_present_modes) |avil| {
                    if (avil == preferred_mode) {
                        break :found preferred_mode;
                    }
                }
            }
            break :found .fifo_khr;
        };

        // Clamp the requested image count to the surface's supported range.
        // A surfaceCaps value of 0 means "unspecified" — skip that side of the clamp.
        const surface_caps = try ikb.getPhysicalDeviceSurfaceCapabilitiesKHR(device.adapter.backend.vk.physical_device, surface);
        var desired_image_count: u32 = option.request_image_count;
        if (surface_caps.min_image_count > 0 and desired_image_count < surface_caps.min_image_count)
            desired_image_count = surface_caps.min_image_count;
        if (surface_caps.max_image_count > 0 and desired_image_count > surface_caps.max_image_count)
            desired_image_count = surface_caps.max_image_count;

        const swapchain_create_info = vk_wapchain_create_info_khr_default(.{
            .surface = surface,
            .format = selected_surface.format,
            .present_mode = present_mode,
            .color_space = selected_surface.color_space,
            .width = width,
            .height = height,
            .image_count = desired_image_count,
        });
        const swapchain: rhi.vulkan.vk.SwapchainKHR = try dkb.createSwapchainKHR(device.backend.vk.device, &swapchain_create_info, null);

        const images = p: {
            var imageNum: u32 = 0;
            _ = try dkb.getSwapchainImagesKHR(device.backend.vk.device, swapchain, &imageNum, null);
            const res = try allocator.alloc(rhi.vulkan.vk.Image, imageNum);
            _ = try dkb.getSwapchainImagesKHR(device.backend.vk.device, swapchain, &imageNum, res.ptr);
            break :p res;
        };
        errdefer allocator.free(images);

        const image_views = try allocator.alloc(rhi.vulkan.vk.ImageView, images.len);
        errdefer allocator.free(image_views);
        const image_acquire_semaphores = try allocator.alloc(rhi.vulkan.vk.Semaphore, images.len);
        errdefer allocator.free(image_acquire_semaphores);
        for (image_acquire_semaphores) |*sem| {
            var create_info: rhi.vulkan.vk.SemaphoreCreateInfo = .{};
            sem.* = try dkb.createSemaphore(device.backend.vk.device, &create_info, null);
        }
        for (0..images.len) |k| {
            const view_create_info: rhi.vulkan.vk.ImageViewCreateInfo = .{
                .s_type = .image_view_create_info,
                .image = images[k],
                .view_type = .@"2d",
                .format = selected_surface.format,
                .components = .{
                    .r = .identity,
                    .g = .identity,
                    .b = .identity,
                    .a = .identity,
                },
                .subresource_range = .{
                    .aspect_mask = .{
                        .color_bit = true,
                    },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            image_views[k] = try dkb.createImageView(device.backend.vk.device, &view_create_info, null);
        }
        return Swapchain{
            .allocator = allocator,
            .width = width,
            .height = height,
            .backend = .{
                .vk = .{
                    .format = selected_surface.format,
                    .swapchain = swapchain,
                    .surface = surface,
                    .images = images,
                    .views = image_views,
                    .signal_semaphores = image_acquire_semaphores,

                    .image_format = selected_surface.format,
                    .image_colorspace = selected_surface.color_space,
                    .present_mode = present_mode,
                },
            },
        };
    }
    unreachable;
}
