pub const Swapchain = @This();
pub const rhi = @import("root.zig");
const builtin = @import("builtin");
const vulkan = @import("vulkan.zig");
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
        layer: *anyopaque = null,
    },
} else {
    // Unsupported platform
    @compileError("Unsupported platform for WindowHandle");
};

allocator: std.mem.Allocator,
present_queue: *rhi.Queue,
width: u16,
height: u16,
backend: union(rhi.Backend) {
    vk: rhi.wrapper_platform_type(.vk, struct {
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
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
},


fn vk_wapchain_create_info_khr_default(option: struct {
                                        surface: rhi.vulkan.vk.SurfaceKHR, 
                                        format: rhi.vulkan.vk.Format,
                                        present_mode: rhi.vulkan.vk.PresentModeKHR,
                                        color_space: rhi.vulkan.vk.ColorSpaceKHR, 
                                        width: u32, height: u32,
                                        image_count: usize
                                        }) rhi.vulkan.vk.SwapchainCreateInfoKHR {
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

pub fn image_view(self: *Swapchain, renderer: *rhi.Renderer, index: u32) rhi.Image.ImageView {
    if (rhi.is_target_selected(.vk, renderer)) {
        return .{
            .vk = self.backend.vk.views[index],
        };
    }
    unreachable;
}

pub fn image(self: *Swapchain, renderer: *rhi.Renderer, index: u32) rhi.Image {
    if (rhi.is_target_selected(.vk, renderer)) {
        return .{
            .backend = .{
                .vk = .{ .image = self.backend.vk.images[index] },
            },
        };
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

pub fn deinit(self: *Swapchain, renderer: *rhi.Renderer, device: *rhi.Device) void {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        var ikb: *rhi.vulkan.vk.InstanceWrapper = &renderer.backend.vk.ikb;
        for(self.backend.vk.signal_semaphores) |sem| {
            dkb.destroySemaphore(device.backend.vk.device, sem, null);
        }
        for(self.backend.vk.views) |view| {
            dkb.destroyImageView(device.backend.vk.device, view, null);
        }
        dkb.destroySwapchainKHR(device.backend.vk.device, self.backend.vk.swapchain, null);
        ikb.destroySurfaceKHR(renderer.backend.vk.instance, self.backend.vk.surface, null);
        self.allocator.free(self.backend.vk.images);
        self.allocator.free(self.backend.vk.views);
        self.allocator.free(self.backend.vk.signal_semaphores);
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

pub fn acquire_next_image(self: *Swapchain, renderer: *rhi.Renderer, device: *rhi.Device) !u32 {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        self.backend.vk.signal_idx = (self.backend.vk.signal_idx + 1) % @as(u32, @intCast(self.backend.vk.signal_semaphores.len));
        const res = try dkb.acquireNextImageKHR(device.backend.vk.device, self.backend.vk.swapchain, std.math.maxInt(u64), self.backend.vk.signal_semaphores[self.backend.vk.signal_idx], .null_handle);
        return res.image_index;
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}
    return error.UnsupportedBackend;
}

pub fn resize(self: *Swapchain, renderer: *rhi.Renderer, device: *rhi.Device, width: u16, height: u16) !bool {
    if(width == self.width and height == self.height) {
        return false;
    }
    if (rhi.is_target_selected(.vk, renderer)) {
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
        for(self.backend.vk.views) |view| {
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
    
        for(0..images.len) |k| {
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

pub fn init(allocator: std.mem.Allocator, renderer: *rhi.Renderer, device: *rhi.Device, width: u16, height: u16, queue: *rhi.Queue, handle: WindowHandle, option: struct {
    format: SwapchainFormat = .bt709_g22_8bit,
    image_count: u32 = 3,
}) !Swapchain {
    if (rhi.is_target_selected(.vk, renderer)) {
        var ikb: *rhi.vulkan.vk.InstanceWrapper = &renderer.backend.vk.ikb;
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const surface: rhi.vulkan.vk.SurfaceKHR = if (builtin.os.tag == .windows) {} else if (builtin.os.tag == .linux) p: {
            switch (handle) {
                .x11 => |val| {
                    var xlib_surface_create: rhi.vulkan.vk.XlibSurfaceCreateInfoKHR = .{
                        .s_type = .xlib_surface_create_info_khr,
                        .dpy = @ptrCast(val.display),
                        .window = val.window,
                    };
                    break :p try ikb.createXlibSurfaceKHR(renderer.backend.vk.instance, &xlib_surface_create, null);
                },
                .wayland => |val| {
                    var wayland_surface_create: rhi.vulkan.vk.WaylandSurfaceCreateInfoKHR = .{
                        .s_type = .wayland_surface_create_info_khr,
                        .display = @ptrCast(val.display),
                        .surface = @ptrCast(val.surface),
                    };
                    break :p try ikb.createWaylandSurfaceKHR(renderer.backend.vk.instance, &wayland_surface_create, null);
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

        const swapchain_create_info = vk_wapchain_create_info_khr_default(.{
            .surface = surface,
            .format = selected_surface.format,
            .present_mode = present_mode,
            .color_space = selected_surface.color_space,
            .width = width,
            .height = height,
            .image_count = option.image_count,
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

        std.debug.assert(images.len == option.image_count);
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
            .present_queue = queue,
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
