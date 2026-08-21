// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const builtin = @import("builtin");
const std = @import("std");
const zwindows = if (builtin.os.tag == .windows) @import("zwindows") else void;

pub const SwapchainFormat = enum { bt709_g10_16bit, bt709_g22_8bit, bt709_g22_10bit, bt2020_g2084_10bit };

pub const WindowType = if (rhi.is_web) enum {
    canvas,
} else if (builtin.os.tag == .windows) enum {
    windows,
} else if (builtin.os.tag == .linux) enum {
    x11,
    wayland,
} else if (builtin.os.tag == .macos or builtin.os.tag == .ios) enum {
    metal,
} else {
    @compileError("Unsupported platform for WindowType");
};

pub const WindowHandle = if (rhi.is_web) union(WindowType) {
    /// A CSS selector naming the `<canvas>` to render into, e.g. `"#canvas"`.
    /// The glue resolves it with `document.querySelector` and takes a WebGPU
    /// context from it; the slice must outlive the swapchain's `init` call.
    canvas: struct {
        selector: []const u8 = "#canvas",
    },
} else if (builtin.os.tag == .windows) union(WindowType) {
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
} else if (builtin.os.tag == .macos or builtin.os.tag == .ios) union(WindowType) {
    metal: struct {
        layer: ?*anyopaque = null,
    },
} else {
    @compileError("Unsupported platform for WindowHandle");
};

pub fn Swapchain(comptime max_image_count: comptime_int) type {
    return struct {
        const Self = @This();

        /// Where the swapchain's surface comes from:
        ///  - window_handle : first create — init makes a fresh surface that the
        ///                    new swapchain owns.
        ///  - old_swapchain : recreate — reuse that swapchain's surface (ownership
        ///                    transferred to the new swapchain) and hand its
        ///                    handle to oldSwapchain so the driver reuses resources.
        pub const Desc = struct {
            width: u16,
            height: u16,
            format: SwapchainFormat = .bt709_g22_8bit,
            request_image_count: u32 = 3,
            /// true -> FIFO (v-synced); false -> IMMEDIATE/MAILBOX when supported.
            vsync: bool = true,
            /// Queue used to present; stored on the swapchain as `present_queue`.
            queue: *rhi.Queue,
            source: union(enum) {
                window_handle: WindowHandle,
                old_swapchain: *Self,
            },
        };

        /// Result of acquire/present. `out_of_date` means the swapchain must be
        /// recreated before the next acquire; `suboptimal` still presented this frame
        /// but should be recreated soon. Mirrors HPL2 RISwapchainStatus_e.
        pub const Status = enum { ok, out_of_date, suboptimal };

        /// Allocator captured at init; used by init's window_handle arm for the
        /// transient format/present-mode enumeration and on recreate.
        allocator: std.mem.Allocator,
        /// Queue this swapchain presents on (from Desc.queue).
        present_queue: *rhi.Queue,
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
            // WebGPU has no swapchain object: a configured canvas context hands
            // out one texture per frame. There is no image ring to index, no
            // acquire semaphore, and no explicit present — the browser composites
            // whatever was submitted when the frame callback returns.
            wgpu: if (rhi.platform_has_api(.wgpu)) struct {
                surface: rhi.webgpu.Handle = .none,
                format: rhi.webgpu.TextureFormat = .bgra8unorm,
                /// This frame's canvas texture and its view. Both are refreshed
                /// by `acquire_next_image` and released after submit, because a
                /// canvas texture is only valid for the frame that acquired it.
                current_texture: rhi.webgpu.Handle = .none,
                current_view: rhi.webgpu.Handle = .none,
            } else void,
            // WebGL2 cannot attach the canvas's colour buffer to a custom FBO,
            // and 02_mesh pairs the swapchain image with its own depth view in
            // one pass. So rendering always targets an offscreen colour texture
            // which `frame_submit` blits onto the canvas.
            webgl: if (rhi.platform_has_api(.webgl)) struct {
                color: rhi.webgl.Handle = .none,
                fbo: rhi.webgl.Handle = .none,
                format: rhi.Format = .rgba8_unorm,
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
                .image_usage = .{ .color_attachment = true, .transfer_src = true },
                .image_sharing_mode = .exclusive,
                .queue_family_index_count = 0,
                .p_queue_family_indices = null,
                .pre_transform = .{ .identity_khr = true },
                .composite_alpha = .{ .opaque_khr = true },
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
                    .aspect_mask = .{ .color = true },
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
            if (rhi.is_target_selected(.wgpu)) {
                std.debug.assert(index == 0);
                return .{ .backend = .{ .wgpu = self.backend.wgpu.current_view } };
            }
            if (rhi.is_target_selected(.webgl)) {
                std.debug.assert(index == 0);
                return .{
                    .backend = .{ .webgl = .{
                        .texture = self.backend.webgl.color,
                        .format = self.backend.webgl.format,
                        .width = self.width,
                        .height = self.height,
                    } },
                    // Stable across frames, unlike the WebGPU arm's per-frame
                    // canvas texture, so the FBO cache keyed on it stays warm.
                    // Offset into the high half so it cannot collide with a
                    // cookie handed out by `rhi.next_cookie`.
                    .cookie = @as(u64, @intFromEnum(self.backend.webgl.color)) | (1 << 32),
                };
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
            if (rhi.is_target_selected(.wgpu)) {
                std.debug.assert(index == 0);
                // `owned = false`: the canvas texture belongs to the browser and
                // is invalidated when the frame ends, so a `deinit` on this copy
                // must not release it.
                return .{ .backend = .{ .wgpu = .{
                    .texture = self.backend.wgpu.current_texture,
                    .owned = false,
                } } };
            }
            if (rhi.is_target_selected(.webgl)) {
                std.debug.assert(index == 0);
                // `owned = false`: the swapchain owns this texture, so a
                // `deinit` on the by-value copy must not delete it.
                return .{ .backend = .{ .webgl = .{
                    .texture = self.backend.webgl.color,
                    .format = self.backend.webgl.format,
                    .width = self.width,
                    .height = self.height,
                    .owned = false,
                } } };
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
                // A retired swapchain that transferred its surface (init's
                // old_swapchain arm) has .null_handle here — only the last owner frees it.
                if (self.backend.vk.surface != .null_handle)
                    ikb.destroySurfaceKHR(rhi.renderer.instance.backend.vk.instance, self.backend.vk.surface, null);
                return;
            }
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                return;
            }
            if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
                rhi.webgl.gl_delete_framebuffer(self.backend.webgl.fbo);
                rhi.webgl.gl_delete_texture(self.backend.webgl.color);
                self.backend.webgl.fbo = .none;
                self.backend.webgl.color = .none;
                return;
            }
            if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
                rhi.webgpu.wgpu_release(self.backend.wgpu.current_view);
                rhi.webgpu.wgpu_release(self.backend.wgpu.current_texture);
                // A swapchain that handed its surface to a successor (init's
                // old_swapchain arm) has `.none` here — only the last owner drops it.
                rhi.webgpu.wgpu_release(self.backend.wgpu.surface);
                self.backend.wgpu.current_view = .none;
                self.backend.wgpu.current_texture = .none;
                self.backend.wgpu.surface = .none;
                return;
            }
            unreachable;
        }

        /// True once this swapchain owns no images (a failed `init` returns this).
        pub fn isEmpty(self: *const Self) bool {
            return self.image_count == 0;
        }
        /// A usable swapchain: has images and a non-degenerate extent.
        pub fn isValid(self: *const Self) bool {
            return self.image_count > 0 and self.width > 0 and self.height > 0;
        }

        /// Acquire the next image. On `.ok`/`.suboptimal` the image index is written to
        /// `out_index`; on `.out_of_date` nothing is written and the caller must recreate.
        pub fn acquire_next_image(self: *Self, device: *rhi.Device, out_index: *u32) !Status {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                std.debug.assert(self.image_count > 0);
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                self.backend.vk.signal_idx = (self.backend.vk.signal_idx + 1) % @as(u32, self.image_count);
                const res = dkb.acquireNextImageKHR(device.backend.vk.device, self.backend.vk.swapchain, std.math.maxInt(u64), self.backend.vk.signal_semaphores[self.backend.vk.signal_idx], .null_handle) catch |err| switch (err) {
                    error.OutOfDateKHR => return .out_of_date,
                    else => return err,
                };
                out_index.* = res.image_index;
                return if (res.result == .suboptimal_khr) .suboptimal else .ok;
            }
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                self.backend.mtl.current_drawable = self.backend.mtl.layer.nextDrawable() orelse
                    return error.MetalNoDrawable;
                out_index.* = 0;
                return .ok;
            }
            if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
                // The offscreen target persists across frames, so there is
                // nothing to acquire and no way for this to be out of date.
                out_index.* = 0;
                return .ok;
            }
            if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
                const wgpu = rhi.webgpu;
                // Last frame's texture and view are invalid now; drop them before
                // taking this frame's.
                wgpu.wgpu_release(self.backend.wgpu.current_view);
                wgpu.wgpu_release(self.backend.wgpu.current_texture);

                const texture = wgpu.wgpu_surface_get_current_texture(self.backend.wgpu.surface);
                if (texture.isNone()) {
                    self.backend.wgpu.current_texture = .none;
                    self.backend.wgpu.current_view = .none;
                    // The canvas was resized out from under the configuration, or
                    // the context was lost; either way the caller must reconfigure.
                    return .out_of_date;
                }
                const view = wgpu.wgpu_texture_create_view(
                    texture,
                    self.backend.wgpu.format,
                    .@"2d",
                    .all,
                    0,
                    1,
                    0,
                    1,
                );
                self.backend.wgpu.current_texture = texture;
                self.backend.wgpu.current_view = view;
                out_index.* = 0;
                return .ok;
            }
            unreachable;
        }

        pub fn present_vk(self: *Self, device: *rhi.Device, image_index: u32, wait_semaphores: []const rhi.vulkan.vk.Semaphore) !Status {
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
                const res = dkb.queuePresentKHR(self.present_queue.backend.vk.queue, &present_info) catch |err| switch (err) {
                    error.OutOfDateKHR => return .out_of_date,
                    else => return err,
                };
                return if (res == .suboptimal_khr) .suboptimal else .ok;
            }
            if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
                return error.UnsupportedBackend;
            }
            if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
                // vk-named and vk-typed. The web has no explicit present at all:
                // the browser composites the canvas once the frame callback
                // returns. Use `frame_submit`.
                return error.UnsupportedBackend;
            }
            unreachable;
        }

        pub fn frame_submit(self: *Self, device: *rhi.Device, queue: *rhi.Queue, options: struct {
            image_index: u32,
            ring_element: *rhi.cmd.CommandRingElement,
            cmd: *rhi.Cmd,
            /// Monotonic GPU-completion timeline. This submit signals `timeline.next()`
            /// so deferred-release consumers can drain against `timeline.completed()`.
            timeline: *rhi.Timeline,
        }) !Status {
            try options.cmd.end(device);
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                const timeline_value = options.timeline.next();
                const cmd_submit = [_]rhi.vulkan.vk.CommandBufferSubmitInfo{.{
                    .command_buffer = options.cmd.backend.vk.cmd,
                    .device_mask = 0,
                }};
                const wait_semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{.{
                    .semaphore = self.backend.vk.current_semaphore(),
                    .stage_mask = .{ .color_attachment_output = true },
                    .value = 0,
                    .device_index = 0,
                }};
                const signal_semaphore_info = [_]rhi.vulkan.vk.SemaphoreSubmitInfo{
                    // binary semaphore the present waits on
                    .{
                        .semaphore = options.ring_element.backend.vk.semaphore,
                        .value = 0,
                        .stage_mask = .{ .all_commands = true },
                        .device_index = 0,
                    },
                    // timeline value marking this frame's GPU completion
                    .{
                        .semaphore = options.timeline.backend.vk.semaphore,
                        .value = timeline_value,
                        .stage_mask = .{ .all_commands = true },
                        .device_index = 0,
                    },
                };
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
                return try self.present_vk(device, options.image_index, &wait_semaphores);
            }
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                const drawable = self.backend.mtl.current_drawable orelse return error.MetalNoDrawable;
                const cb = options.cmd.backend.mtl.cmd orelse return error.MetalNoCommandBuffer;
                cb.presentDrawable(drawable.id());
                cb.commit();
                self.backend.mtl.current_drawable = null;
                return .ok;
            }
            if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
                const timeline_value = options.timeline.next();
                var cmds = [_]*rhi.Cmd{options.cmd};
                try queue.submit(device, .{ .webgl = .{ .cmds = &cmds } });

                // Resolve the offscreen target onto the canvas. The browser
                // composites whatever framebuffer 0 holds when the frame
                // callback returns; there is no present call.
                rhi.webgl.gl_blit_to_canvas(self.backend.webgl.fbo, self.width, self.height);
                options.timeline.signal_webgl(timeline_value);
                return .ok;
            }
            if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
                const timeline_value = options.timeline.next();
                var cmds = [_]*rhi.Cmd{options.cmd};
                try queue.submit(device, .{ .wgpu = .{ .cmds = &cmds } });

                // No present call: the browser composites the configured canvas
                // when the frame callback returns. Registering the completion
                // callback here is what lets `Timeline.completed` advance, which
                // deferred-release consumers drain against.
                const split = rhi.webgpu.split_u64(timeline_value);
                rhi.webgpu.wgpu_queue_on_submitted_work_done(
                    queue.backend.wgpu.queue,
                    &options.timeline.backend.wgpu.completed_value,
                    split.lo,
                    split.hi,
                );
                return .ok;
            }
            unreachable;
        }

        pub fn init(allocator: std.mem.Allocator, device: *rhi.Device, desc: Desc) !Self {
            if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
                const webgl = rhi.webgl;
                // WebGL2 cannot attach the canvas's colour buffer to a custom
                // FBO, and a render pass with a depth attachment needs one. So
                // the swapchain owns an offscreen colour texture, and
                // `frame_submit` blits it onto the canvas.
                //
                // RGBA8 rather than the browser's preferred canvas format:
                // WebGL2 has no renderable BGRA.
                const format: rhi.Format = .rgba8_unorm;
                const gl_format = try webgl.to_gl_format(format);
                const color = webgl.gl_create_texture_2d(gl_format.internal_format, desc.width, desc.height, 1);
                if (color.isNone()) return error.WebGL2TextureCreationFailed;
                errdefer webgl.gl_delete_texture(color);

                const fbo = webgl.gl_create_framebuffer();
                if (fbo.isNone()) return error.WebGL2FramebufferCreationFailed;
                errdefer webgl.gl_delete_framebuffer(fbo);
                webgl.gl_framebuffer_texture_2d(fbo, webgl.gl.COLOR_ATTACHMENT0, color);
                if (webgl.gl_check_framebuffer_status(fbo) != webgl.gl.FRAMEBUFFER_COMPLETE)
                    return error.WebGL2FramebufferIncomplete;

                return Self{
                    .allocator = allocator,
                    .present_queue = desc.queue,
                    // One target, refreshed in place; there is no image ring.
                    .image_count = 1,
                    .width = desc.width,
                    .height = desc.height,
                    .backend = .{ .webgl = .{ .color = color, .fbo = fbo, .format = format } },
                };
            }
            if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
                const wgpu = rhi.webgpu;
                // On recreate the canvas context is the same object; only the
                // configured size changes, so the surface handle is carried over
                // rather than rebuilt (and the old swapchain gives up ownership).
                const surface = switch (desc.source) {
                    .window_handle => |handle| wgpu.wgpu_surface_create(handle.canvas.selector.ptr, @intCast(handle.canvas.selector.len)),
                    .old_swapchain => |o| blk: {
                        const h = o.backend.wgpu.surface;
                        o.backend.wgpu.surface = .none;
                        break :blk h;
                    },
                };
                if (surface.isNone()) return error.WebGPUSurfaceCreationFailed;

                // `desc.format` selects a colour space / bit depth the browser
                // does not let us choose: a canvas takes the preferred format for
                // the device, and anything else risks an unsupported combination.
                const format = wgpu.wgpu_surface_preferred_format();
                wgpu.wgpu_surface_configure(surface, device.backend.wgpu.device, format, desc.width, desc.height);

                return Self{
                    .allocator = allocator,
                    .present_queue = desc.queue,
                    // WebGPU hands out one texture per frame; there is no ring of
                    // images for the caller to index, so the count is always 1.
                    .image_count = 1,
                    .width = desc.width,
                    .height = desc.height,
                    .backend = .{ .wgpu = .{ .surface = surface, .format = format } },
                };
            }
            if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
                const layer = switch (desc.source) {
                    .window_handle => |handle| rhi.metal.ca.MetalLayer.fromId(@ptrCast(@alignCast(handle.metal.layer))) orelse return error.MetalNoLayer,
                    .old_swapchain => |o| o.backend.mtl.layer,
                };
                const pixel_format: rhi.metal.types.PixelFormat = switch (desc.format) {
                    .bt709_g22_8bit => .bgra8unorm,
                    else => .bgra8unorm,
                };
                layer.setDevice(device.backend.mtl.device);
                layer.setPixelFormat(pixel_format);
                layer.setDrawableSize(.{ .width = @floatFromInt(desc.width), .height = @floatFromInt(desc.height) });
                return Self{
                    .allocator = allocator,
                    .present_queue = desc.queue,
                    .image_count = 1,
                    .width = desc.width,
                    .height = desc.height,
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

                // Resolve the surface from the source:
                //  - window_handle : create a fresh surface here (owned by us; freed on error).
                //  - old_swapchain : reuse the old swapchain's surface (ownership transferred
                //                    to this new swapchain on success) and retire its handle.
                var surface: rhi.vulkan.vk.SurfaceKHR = .null_handle;
                var retiring: rhi.vulkan.vk.SwapchainKHR = .null_handle;
                var old: ?*Self = null;
                var owns_fresh_surface = false;
                switch (desc.source) {
                    .window_handle => |handle| {
                        surface = if (builtin.os.tag == .linux) p: {
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
                        } else if (builtin.os.tag == .windows) p: {
                            switch (handle) {
                                .windows => |val| {
                                    const raw_hinst: ?*anyopaque = if (val.hinstance) |h| h else @ptrCast(zwindows.GetModuleHandleA(null));
                                    const info: rhi.vulkan.vk.Win32SurfaceCreateInfoKHR = .{
                                        .s_type = .win32_surface_create_info_khr,
                                        .hinstance = @ptrCast(raw_hinst.?),
                                        .hwnd = @ptrCast(val.hwnd.?),
                                    };
                                    break :p try ikb.createWin32SurfaceKHR(rhi.renderer.instance.backend.vk.instance, &info, null);
                                },
                            }
                        } else {
                            @compileError("Unsupported platform for Swapchain.init");
                        };
                        owns_fresh_surface = true;
                    },
                    .old_swapchain => |o| {
                        old = o;
                        surface = o.backend.vk.surface;
                        retiring = o.backend.vk.swapchain;
                    },
                }
                errdefer if (owns_fresh_surface) ikb.destroySurfaceKHR(rhi.renderer.instance.backend.vk.instance, surface, null);

                // Format + present mode: enumerate and select against a fresh surface;
                // reuse the old swapchain's already-selected values on a recreate (same
                // surface can't drift format, and this keeps recreate allocation-free).
                var image_format: rhi.vulkan.vk.Format = undefined;
                var image_colorspace: rhi.vulkan.vk.ColorSpaceKHR = undefined;
                var present_mode: rhi.vulkan.vk.PresentModeKHR = undefined;
                switch (desc.source) {
                    .window_handle => {
                        const available_formats = p: {
                            var count: u32 = 0;
                            _ = try ikb.getPhysicalDeviceSurfaceFormatsKHR(device.adapter.backend.vk.physical_device, surface, &count, null);
                            const buf = try allocator.alloc(rhi.vulkan.vk.SurfaceFormatKHR, count);
                            _ = try ikb.getPhysicalDeviceSurfaceFormatsKHR(device.adapter.backend.vk.physical_device, surface, &count, buf.ptr);
                            break :p buf;
                        };
                        defer allocator.free(available_formats);

                        const selection_fn = switch (desc.format) {
                            .bt709_g10_16bit => &priority_BT709_G10_16BIT,
                            .bt709_g22_8bit => &priority_BT709_G22_8BIT,
                            .bt709_g22_10bit => &priority_BT709_G22_10BIT,
                            .bt2020_g2084_10bit => &priority_BT2020_G2084_10BIT,
                        };
                        var selected_surface: *const rhi.vulkan.vk.SurfaceFormatKHR = &available_formats[0];
                        for (available_formats) |*fmt| {
                            if (selection_fn(fmt) > selection_fn(selected_surface)) selected_surface = fmt;
                        }
                        image_format = selected_surface.format;
                        image_colorspace = selected_surface.color_space;

                        const available_present_modes = p: {
                            var count: u32 = 0;
                            _ = try ikb.getPhysicalDeviceSurfacePresentModesKHR(device.adapter.backend.vk.physical_device, surface, &count, null);
                            const buf = try allocator.alloc(rhi.vulkan.vk.PresentModeKHR, count);
                            _ = try ikb.getPhysicalDeviceSurfacePresentModesKHR(device.adapter.backend.vk.physical_device, surface, &count, buf.ptr);
                            break :p buf;
                        };
                        defer allocator.free(available_present_modes);

                        present_mode = found: {
                            // vsync -> FIFO (always available); otherwise prefer a
                            // tearing/low-latency mode, falling back to FIFO.
                            const preferred: []const rhi.vulkan.vk.PresentModeKHR = if (desc.vsync)
                                &.{.fifo_khr}
                            else
                                &.{ .immediate_khr, .mailbox_khr, .fifo_relaxed_khr };
                            for (preferred) |p| {
                                for (available_present_modes) |a| {
                                    if (a == p) break :found p;
                                }
                            }
                            break :found .fifo_khr;
                        };
                    },
                    .old_swapchain => |o| {
                        image_format = o.backend.vk.image_format;
                        image_colorspace = o.backend.vk.image_colorspace;
                        present_mode = o.backend.vk.present_mode;
                    },
                }

                // Clamp image count to surface capabilities
                const surface_caps = try ikb.getPhysicalDeviceSurfaceCapabilitiesKHR(device.adapter.backend.vk.physical_device, surface);
                var desired_count: u32 = desc.request_image_count;
                if (surface_caps.min_image_count > 0 and desired_count < surface_caps.min_image_count)
                    desired_count = surface_caps.min_image_count;
                if (surface_caps.max_image_count > 0 and desired_count > surface_caps.max_image_count)
                    desired_count = surface_caps.max_image_count;

                var sc_info = vk_swapchain_create_info_default(.{
                    .surface = surface,
                    .format = image_format,
                    .present_mode = present_mode,
                    .color_space = image_colorspace,
                    .width = desc.width,
                    .height = desc.height,
                    .image_count = desired_count,
                });
                sc_info.old_swapchain = retiring;
                const sc_handle = try dkb.createSwapchainKHR(device.backend.vk.device, &sc_info, null);
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
                    views[k] = try vk_create_image_view(dkb, device.backend.vk.device, images[k], image_format);
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

                // Success: transfer surface ownership off the retiring swapchain so its
                // deinit won't free a surface this new swapchain now owns.
                if (old) |o| o.backend.vk.surface = .null_handle;

                return Self{
                    .allocator = allocator,
                    .present_queue = desc.queue,
                    .image_count = @intCast(image_count),
                    .width = desc.width,
                    .height = desc.height,
                    .backend = .{ .vk = .{
                        .format = image_format,
                        .swapchain = sc_handle,
                        .surface = surface,
                        .images = images,
                        .views = views,
                        .signal_semaphores = semaphores,
                        .image_format = image_format,
                        .image_colorspace = image_colorspace,
                        .present_mode = present_mode,
                    } },
                };
            }
            unreachable;
        }
    };
}
