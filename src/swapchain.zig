// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const builtin = @import("builtin");
const std = @import("std");

pub const SwapchainFormat = enum { bt709_g10_16bit, bt709_g22_8bit, bt709_g22_10bit, bt2020_g2084_10bit };

pub const WindowType = if (builtin.os.tag == .windows) enum {
    windows,
} else if (builtin.os.tag == .linux) enum {
    x11,
    wayland,
} else if (builtin.os.tag == .macos or .ios) enum { metal } else {
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
    @compileError("Unsupported platform for WindowHandle");
};

pub fn Swapchain(comptime max_image_count: comptime_int) type {
    return struct {
        const Self = @This();

        /// Actual image count returned by the driver (≤ max_image_count).
        image_count: u16,
        width: u16,
        height: u16,
        backend: union {
            vk: if (rhi.platform_has_api(.vk)) struct {
                const VkBackend = @This();

                format: rhi.vulkan.vk.Format,
                swapchain: rhi.vulkan.vk.SwapchainKHR,
                surface: rhi.vulkan.vk.SurfaceKHR,
                images: [max_image_count]rhi.vulkan.vk.Image,
                views: [max_image_count]rhi.vulkan.vk.ImageView,

                signal_idx: u32 = 0,
                signal_semaphores: [max_image_count]rhi.vulkan.vk.Semaphore,

                image_format: rhi.vulkan.vk.Format,
                image_colorspace: rhi.vulkan.vk.ColorSpaceKHR,
                present_mode: rhi.vulkan.vk.PresentModeKHR,

                pub fn current_semaphore(self: *VkBackend) rhi.vulkan.vk.Semaphore {
                    return self.signal_semaphores[self.signal_idx];
                }
            } else void,
            dx12: if (rhi.platform_has_api(.dx12)) void else void,
            mtl: if (rhi.platform_has_api(.mtl)) struct {
                layer: rhi.metal.ca.MetalLayer,
                pixel_format: rhi.metal.types.PixelFormat,
                current_drawable: ?rhi.metal.ca.MetalDrawable = null,
            } else void,
        },

        fn vk_swapchain_create_info_default(option: struct {
            surface: rhi.vulkan.vk.SurfaceKHR,
            format: rhi.vulkan.vk.Format,
            present_mode: rhi.vulkan.vk.PresentModeKHR,
            color_space: rhi.vulkan.vk.ColorSpaceKHR,
            width: u32,
            height: u32,
            image_count: u32,
        }) rhi.vulkan.vk.SwapchainCreateInfoKHR {
            return .{
                .surface = option.surface,
                .min_image_count = option.image_count,
                .image_format = option.format,
                .image_color_space = option.color_space,
                .image_extent = .{ .width = option.width, .height = option.height },
                .image_array_layers = 1,
                .image_usage = .{ .color_attachment_bit = true, .transfer_src_bit = true },
                .image_sharing_mode = .exclusive,
                .queue_family_index_count = 0,
                .p_queue_family_indices = null,
                .pre_transform = .{ .identity_bit_khr = true },
                .composite_alpha = .{ .opaque_bit_khr = true },
                .present_mode = option.present_mode,
                .clipped = .true,
            };
        }

        fn priority_BT709_G10_16BIT(surface: *const rhi.vulkan.vk.SurfaceFormatKHR) u32 {
            return (@as(u32, @intFromBool(surface.format == .r16g16b16a16_sfloat))) |
                (@as(u32, @intFromBool(surface.color_space == .extended_srgb_linear_ext)) << 1);
        }

        fn priority_BT709_G22_8BIT(surface: *const rhi.vulkan.vk.SurfaceFormatKHR) u32 {
            return (@as(u32, @intFromBool(surface.format == .r8g8b8a8_unorm or surface.format == .b8g8r8a8_unorm))) |
                (@as(u32, @intFromBool(surface.color_space == .srgb_nonlinear_khr)) << 1);
        }

        fn priority_BT709_G22_10BIT(surface: *const rhi.vulkan.vk.SurfaceFormatKHR) u32 {
            return (@as(u32, @intFromBool(surface.format == .a2b10g10r10_unorm_pack32))) |
                (@as(u32, @intFromBool(surface.color_space == .srgb_nonlinear_khr)) << 1);
        }

        fn priority_BT2020_G2084_10BIT(surface: *const rhi.vulkan.vk.SurfaceFormatKHR) u32 {
            return (@as(u32, @intFromBool(surface.format == .a2b10g10r10_unorm_pack32))) |
                (@as(u32, @intFromBool(surface.color_space == .hdr10_st2084_ext)) << 1);
        }

        fn vk_create_image_view(
            dkb: *rhi.vulkan.vk.DeviceWrapper,
            device: rhi.vulkan.vk.Device,
            img: rhi.vulkan.vk.Image,
            format: rhi.vulkan.vk.Format,
        ) !rhi.vulkan.vk.ImageView {
            const info: rhi.vulkan.vk.ImageViewCreateInfo = .{
                .s_type = .image_view_create_info,
                .image = img,
                .view_type = .@"2d",
                .format = format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            return dkb.createImageView(device, &info, null);
        }

        pub fn image_view(self: *Self, index: u32) rhi.ImageView {
            if (rhi.is_target_selected(.vk)) {
                return .{ .backend = .{ .vk = self.backend.vk.views[index] } };
            }
            if (rhi.is_target_selected(.mtl)) {
                return .{ .backend = .{ .mtl = self.backend.mtl.current_drawable.?.texture() } };
            }
            unreachable;
        }

        pub fn image(self: *Self, index: u32) rhi.Image {
            if (rhi.is_target_selected(.vk)) {
                return .{ .backend = .{ .vk = .{ .image = self.backend.vk.images[index] } } };
            }
            if (rhi.is_target_selected(.mtl)) {
                return .{ .backend = .{ .mtl = .{ .texture = self.backend.mtl.current_drawable.?.texture() } } };
            }
            unreachable;
        }

        pub fn deinit(self: *Self, device: *rhi.Device) void {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                var ikb: *rhi.vulkan.vk.InstanceWrapper = &rhi.renderer.instance.backend.vk.ikb;
                for (self.backend.vk.signal_semaphores[0..self.image_count]) |sem| {
                    dkb.destroySemaphore(device.backend.vk.device, sem, null);
                }
                for (self.backend.vk.views[0..self.image_count]) |view| {
                    dkb.destroyImageView(device.backend.vk.device, view, null);
                }
                dkb.destroySwapchainKHR(device.backend.vk.device, self.backend.vk.swapchain, null);
                ikb.destroySurfaceKHR(rhi.renderer.instance.backend.vk.instance, self.backend.vk.surface, null);
                return;
            }
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                return;
            }
            unreachable;
        }

        pub fn acquire_next_image(self: *Self, device: *rhi.Device) !u32 {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                std.debug.assert(self.image_count > 0);
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                self.backend.vk.signal_idx = (self.backend.vk.signal_idx + 1) % @as(u32, self.image_count);
                const res = try dkb.acquireNextImageKHR(device.backend.vk.device, self.backend.vk.swapchain, std.math.maxInt(u64), self.backend.vk.signal_semaphores[self.backend.vk.signal_idx], .null_handle);
                return res.image_index;
            }
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                self.backend.mtl.current_drawable = self.backend.mtl.layer.nextDrawable() orelse
                    return error.MetalNoDrawable;
                return 0;
            }
            unreachable;
        }

        pub fn present_vk(self: *Self, device: *rhi.Device, queue: *rhi.Queue, image_index: u32, wait_semaphores: []const rhi.vulkan.vk.Semaphore) !void {
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

        pub fn frame_submit(self: *Self, device: *rhi.Device, queue: *rhi.Queue, options: struct {
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

        pub fn resize(self: *Self, device: *rhi.Device, width: u16, height: u16) !bool {
            if (width == self.width and height == self.height) return false;
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                self.backend.mtl.layer.setDrawableSize(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) });
                self.width = width;
                self.height = height;
                return true;
            }
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                const old_swapchain = self.backend.vk.swapchain;
                var sc_info = vk_swapchain_create_info_default(.{
                    .surface = self.backend.vk.surface,
                    .format = self.backend.vk.image_format,
                    .present_mode = self.backend.vk.present_mode,
                    .color_space = self.backend.vk.image_colorspace,
                    .width = width,
                    .height = height,
                    .image_count = self.image_count,
                });
                sc_info.old_swapchain = old_swapchain;
                self.backend.vk.swapchain = try dkb.createSwapchainKHR(device.backend.vk.device, &sc_info, null);
                dkb.destroySwapchainKHR(device.backend.vk.device, old_swapchain, null);

                for (self.backend.vk.views[0..self.image_count]) |view| {
                    dkb.destroyImageView(device.backend.vk.device, view, null);
                }

                var image_count: u32 = 0;
                _ = try dkb.getSwapchainImagesKHR(device.backend.vk.device, self.backend.vk.swapchain, &image_count, null);
                std.debug.assert(image_count <= max_image_count);
                _ = try dkb.getSwapchainImagesKHR(device.backend.vk.device, self.backend.vk.swapchain, &image_count, &self.backend.vk.images);
                self.image_count = @intCast(image_count);

                for (0..self.image_count) |k| {
                    self.backend.vk.views[k] = try vk_create_image_view(dkb, device.backend.vk.device, self.backend.vk.images[k], self.backend.vk.image_format);
                }

                self.width = width;
                self.height = height;
                return true;
            }
            unreachable;
        }

        pub fn init(allocator: std.mem.Allocator, device: *rhi.Device, width: u16, height: u16, handle: WindowHandle, option: struct {
            format: SwapchainFormat = .bt709_g22_8bit,
            request_image_count: u32 = 3,
        }) !Self {
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                const layer = rhi.metal.ca.MetalLayer.fromId(@ptrCast(@alignCast(handle.metal.layer))) orelse return error.MetalNoLayer;
                const pixel_format: rhi.metal.types.PixelFormat = switch (option.format) {
                    .bt709_g22_8bit => .bgra8unorm,
                    else => .bgra8unorm,
                };
                layer.setDevice(device.backend.mtl.device);
                layer.setPixelFormat(pixel_format);
                layer.setDrawableSize(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) });
                return Self{
                    .image_count = 1,
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

                const surface: rhi.vulkan.vk.SurfaceKHR = if (builtin.os.tag == .linux) p: {
                    switch (handle) {
                        .x11 => |val| {
                            const info: rhi.vulkan.vk.XlibSurfaceCreateInfoKHR = .{
                                .s_type = .xlib_surface_create_info_khr,
                                .dpy = @ptrCast(val.display),
                                .window = val.window,
                            };
                            break :p try ikb.createXlibSurfaceKHR(rhi.renderer.instance.backend.vk.instance, &info, null);
                        },
                        .wayland => |val| {
                            const info: rhi.vulkan.vk.WaylandSurfaceCreateInfoKHR = .{
                                .s_type = .wayland_surface_create_info_khr,
                                .display = @ptrCast(val.display),
                                .surface = @ptrCast(val.surface),
                            };
                            break :p try ikb.createWaylandSurfaceKHR(rhi.renderer.instance.backend.vk.instance, &info, null);
                        },
                    }
                } else {
                    @compileError("Unsupported platform for Swapchain.init");
                };
                errdefer ikb.destroySurfaceKHR(rhi.renderer.instance.backend.vk.instance, surface, null);

                // Select surface format
                const available_formats = p: {
                    var count: u32 = 0;
                    _ = try ikb.getPhysicalDeviceSurfaceFormatsKHR(device.adapter.backend.vk.physical_device, surface, &count, null);
                    const buf = try allocator.alloc(rhi.vulkan.vk.SurfaceFormatKHR, count);
                    _ = try ikb.getPhysicalDeviceSurfaceFormatsKHR(device.adapter.backend.vk.physical_device, surface, &count, buf.ptr);
                    break :p buf;
                };
                defer allocator.free(available_formats);

                const selection_fn = switch (option.format) {
                    .bt709_g10_16bit => &priority_BT709_G10_16BIT,
                    .bt709_g22_8bit => &priority_BT709_G22_8BIT,
                    .bt709_g22_10bit => &priority_BT709_G22_10BIT,
                    .bt2020_g2084_10bit => &priority_BT2020_G2084_10BIT,
                };
                var selected_surface: *const rhi.vulkan.vk.SurfaceFormatKHR = &available_formats[0];
                for (available_formats) |*fmt| {
                    if (selection_fn(fmt) > selection_fn(selected_surface)) selected_surface = fmt;
                }

                // Select present mode
                const available_present_modes = p: {
                    var count: u32 = 0;
                    _ = try ikb.getPhysicalDeviceSurfacePresentModesKHR(device.adapter.backend.vk.physical_device, surface, &count, null);
                    const buf = try allocator.alloc(rhi.vulkan.vk.PresentModeKHR, count);
                    _ = try ikb.getPhysicalDeviceSurfacePresentModesKHR(device.adapter.backend.vk.physical_device, surface, &count, buf.ptr);
                    break :p buf;
                };
                defer allocator.free(available_present_modes);

                const present_mode: rhi.vulkan.vk.PresentModeKHR = found: {
                    const preferred = [_]rhi.vulkan.vk.PresentModeKHR{ .immediate_khr, .fifo_relaxed_khr, .fifo_khr };
                    for (preferred) |p| {
                        for (available_present_modes) |a| {
                            if (a == p) break :found p;
                        }
                    }
                    break :found .fifo_khr;
                };

                // Clamp image count to surface capabilities
                const surface_caps = try ikb.getPhysicalDeviceSurfaceCapabilitiesKHR(device.adapter.backend.vk.physical_device, surface);
                var desired_count: u32 = option.request_image_count;
                if (surface_caps.min_image_count > 0 and desired_count < surface_caps.min_image_count)
                    desired_count = surface_caps.min_image_count;
                if (surface_caps.max_image_count > 0 and desired_count > surface_caps.max_image_count)
                    desired_count = surface_caps.max_image_count;

                const sc_handle = try dkb.createSwapchainKHR(device.backend.vk.device, &vk_swapchain_create_info_default(.{
                    .surface = surface,
                    .format = selected_surface.format,
                    .present_mode = present_mode,
                    .color_space = selected_surface.color_space,
                    .width = width,
                    .height = height,
                    .image_count = desired_count,
                }), null);
                errdefer dkb.destroySwapchainKHR(device.backend.vk.device, sc_handle, null);

                // Enumerate images into fixed arrays
                var image_count: u32 = 0;
                _ = try dkb.getSwapchainImagesKHR(device.backend.vk.device, sc_handle, &image_count, null);
                std.debug.assert(image_count <= max_image_count);
                var images: [max_image_count]rhi.vulkan.vk.Image = undefined;
                _ = try dkb.getSwapchainImagesKHR(device.backend.vk.device, sc_handle, &image_count, &images);

                var views: [max_image_count]rhi.vulkan.vk.ImageView = undefined;
                var views_created: u32 = 0;
                errdefer for (views[0..views_created]) |v| dkb.destroyImageView(device.backend.vk.device, v, null);
                for (0..image_count) |k| {
                    views[k] = try vk_create_image_view(dkb, device.backend.vk.device, images[k], selected_surface.format);
                    views_created += 1;
                }

                var semaphores: [max_image_count]rhi.vulkan.vk.Semaphore = undefined;
                var semas_created: u32 = 0;
                errdefer for (semaphores[0..semas_created]) |s| dkb.destroySemaphore(device.backend.vk.device, s, null);
                for (0..image_count) |k| {
                    const ci: rhi.vulkan.vk.SemaphoreCreateInfo = .{};
                    semaphores[k] = try dkb.createSemaphore(device.backend.vk.device, &ci, null);
                    semas_created += 1;
                }

                return Self{
                    .image_count = @intCast(image_count),
                    .width = width,
                    .height = height,
                    .backend = .{ .vk = .{
                        .format = selected_surface.format,
                        .swapchain = sc_handle,
                        .surface = surface,
                        .images = images,
                        .views = views,
                        .signal_semaphores = semaphores,
                        .image_format = selected_surface.format,
                        .image_colorspace = selected_surface.color_space,
                        .present_mode = present_mode,
                    } },
                };
            }
            unreachable;
        }
    };
}
