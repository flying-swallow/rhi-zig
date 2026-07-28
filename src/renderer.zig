// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const vulkan = @import("root.zig").vulkan;
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

pub const Renderer = @This();

/// The single global renderer instance. There is only ever one renderer per
/// application, so it is a global singleton rather than a value threaded through
/// the API. Populated by `init`; referenced elsewhere as `rhi.renderer.instance`.
pub var instance: Renderer = undefined;

backend: union(rhi.Backend) {
    vk: if (rhi.platform_has_api(.vk)) struct {
        api_version: u32,
        instance: rhi.vulkan.vk.Instance,
        debug_message_utils: ?rhi.vulkan.vk.DebugUtilsMessengerEXT,
        vkb: rhi.vulkan.vk.BaseWrapper,
        ikb: rhi.vulkan.vk.InstanceWrapper,
    } else void,
    dx12: if (rhi.platform_has_api(.dx12)) void else void,
    mtl: if (rhi.platform_has_api(.mtl)) void else void,
    webgpu: if (rhi.platform_has_api(.webgpu)) struct {
        instance: rhi.webgpu.c.WGPUInstance,
    } else void,
},

pub fn apiString() []const u8 {
    return switch (instance.backend) {
        .vk => "Vulkan",
        .dx12 => "DirectX 12",
        .mtl => "Metal",
        .webgpu => "WebGPU",
    };
}

pub fn target_api() rhi.Backend {
    if (instance.backend == .vk and comptime rhi.platform_has_api(.vk)) {
        return .vk;
    }
    if (instance.backend == .dx12 and comptime rhi.platform_has_api(.dx12)) {
        return .dx12;
    }
    if (instance.backend == .mtl and comptime rhi.platform_has_api(.mtl)) {
        return .mtl;
    }
    if (instance.backend == .webgpu and comptime rhi.platform_has_api(.webgpu)) {
        return .webgpu;
    }
    unreachable;
}

pub fn deinit() void {
    const renderer = &instance;
    switch (renderer.backend) {
        .vk => |vk| {
            _ = vk;
            //if (vk.debug_message_utils != null and renderer.backend.vk.ikb.dispatch.vkDestroyDebugUtilsMessengerEXT != null ) { // vk.c.vkDestroyDebugUtilsMessengerEXT != null) {
            //    renderer.backend.vk.ikb.destroyDebugUtilsMessengerEXT(vk.instance, vk.debug_message_utils, null);
            //}
            //if (vk.instance != null) {
            //    volk.c.vkDestroyInstance.?(vk.instance, null);
            //}
        },
        .dx12 => {},
        .mtl => {},
        .webgpu => |webgpu| {
            if (comptime rhi.platform_has_api(.webgpu)) {
                rhi.webgpu.c.wgpuInstanceRelease(webgpu.instance);
            }
        },
    }
}

pub fn init(alloc: std.mem.Allocator, impl: union(rhi.Backend) {
    vk: struct { app_name: [*:0]const u8, enable_validation_layer: bool },
    dx12: struct {},
    mtl: struct {},
    webgpu: struct {},
}) !void {
    switch (impl) {
        .vk => |opt| {
            if (comptime rhi.platform_has_api(.vk)) {
                var dynLib = switch (builtin.os.tag) {
                    .windows => p: {
                        break :p std.DynLib.open("vulkan-1.dll") catch |err| {
                            std.debug.print("Failed to load vulkan-1.dll: {s}\n", .{err});
                            return err;
                        };
                    },
                    .linux => p: {
                        const libs = [_][]const u8{
                            "libvulkan.so.1",
                            "libvulkan.so",
                        };
                        for (libs) |lib| {
                            std.debug.print("Trying to load Vulkan library: {s}\n", .{lib});
                            const handle = std.DynLib.open(lib) catch continue;
                            break :p handle;
                        }
                        return error.VulkanLibraryNotFound;
                    },
                    .macos, .ios => p: {
                        const fallbackEnv = fall: {
                            if (std.process.hasEnvVar(alloc, "DYLD_FALLBACK_LIBRARY_PATH") catch {
                                break :fall null;
                            }) {
                                break :fall "/usr/local/lib/libvulkan.dylib";
                            }
                            break :fall null;
                        };
                        const libs = [_]?[]const u8{ "libvulkan.dylib", "libvulkan.1.dylib", fallbackEnv, "libMoltenVK.dylib", "vulkan.framework/vulkan", "MoltenVK.framework/MoltenVK" };
                        for (libs) |l| {
                            if (l) |ll| {
                                std.debug.print("Trying to load Vulkan library: {s}\n", .{ll});
                                const handle = std.DynLib.open(ll) catch continue;
                                break :p handle;
                            }
                        }
                        return error.VulkanLibraryNotFound;
                    },
                    else => @panic("Unsupported OS"),
                };

                const vkGetInstaceProcAddress = dynLib.lookup(rhi.vulkan.vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr");
                const loader = rhi.vulkan.vk.BaseWrapper.load(vkGetInstaceProcAddress.?);

                var app_info: rhi.vulkan.vk.ApplicationInfo = .{ .s_type = .application_info, .p_application_name = opt.app_name, .application_version = @bitCast(rhi.vulkan.vk.makeApiVersion(0, 0, 0, 1)), .engine_version = @bitCast(rhi.vulkan.vk.makeApiVersion(0, 0, 0, 1)), .api_version = @bitCast(rhi.vulkan.vk.API_VERSION_1_3) };

                const enabled_validation_features = [_]rhi.vulkan.vk.ValidationFeatureEnableEXT{.debug_printf_ext};
                var validationFeatures = rhi.vulkan.vk.ValidationFeaturesEXT{ .s_type = .validation_features_ext, .enabled_validation_feature_count = enabled_validation_features.len, .p_enabled_validation_features = enabled_validation_features[0..].ptr };

                var enabled_layer_names = std.ArrayList([*:0]const u8).empty;
                defer enabled_layer_names.deinit(alloc);
                var enabled_extension_names = std.ArrayList([*:0]const u8).empty;
                defer enabled_extension_names.deinit(alloc);

                var layerProperties: ?[]rhi.vulkan.vk.LayerProperties = null;
                defer if (layerProperties) |lp| alloc.free(lp);
                var extProperties: ?[]rhi.vulkan.vk.ExtensionProperties = null;
                defer if (extProperties) |ep| alloc.free(ep);
                {
                    var instanceLayers: u32 = 0;
                    _ = try loader.enumerateInstanceLayerProperties(&instanceLayers, null);
                    layerProperties = try alloc.alloc(rhi.vulkan.vk.LayerProperties, instanceLayers);
                    _ = try loader.enumerateInstanceLayerProperties(&instanceLayers, layerProperties.?[0..].ptr);

                    var i: usize = 0;
                    while (i < instanceLayers) : (i += 1) {
                        var useLayer: bool = false;
                        const instanceLayerSlice = std.mem.sliceTo(layerProperties.?[i].layer_name[0..], 0);
                        std.debug.print("Instance Layer: {s}({d}): {s}\n", .{ instanceLayerSlice, layerProperties.?[i].spec_version, if (useLayer) "ENABLED" else "DISABLED" });
                        useLayer |= (opt.enable_validation_layer and std.mem.eql(u8, instanceLayerSlice, "VK_LAYER_KHRONOS_validation"));
                        //if (opt.filterLayers.len > 0) {
                        //    useLayer |= std.mem.indexOf(u8, opt.filterLayers, layerProperties.?[i].layerName) != null;
                        //}
                        if (useLayer) {
                            try enabled_layer_names.append(alloc, @ptrCast(std.mem.sliceTo(layerProperties.?[i].layer_name[0..], 0)));
                        }
                    }
                }
                {
                    var extensionNum: u32 = 0;
                    _ = try loader.enumerateInstanceExtensionProperties(null, &extensionNum, null);
                    extProperties = try alloc.alloc(rhi.vulkan.vk.ExtensionProperties, extensionNum);
                    _ = try loader.enumerateInstanceExtensionProperties(null, &extensionNum, extProperties.?[0..].ptr);

                    var i: usize = 0;
                    while (i < extensionNum) : (i += 1) {
                        var useExtension: bool = false;
                        const extensionSlice = std.mem.sliceTo(extProperties.?[i].extension_name[0..], 0);
                        // Use platform-specific surface extensions
                        // Note: volk does not define these platform macros, so we use Zig's built-in OS detection
                        if (builtin.os.tag == .windows) {
                            useExtension |= std.mem.eql(u8, extensionSlice, rhi.vulkan.vk.extensions.khr_win_32_surface.name);
                        } else if (builtin.os.tag == .linux) {
                            useExtension |= std.mem.eql(u8, extensionSlice, rhi.vulkan.vk.extensions.khr_xlib_surface.name) or
                                std.mem.eql(u8, extensionSlice, rhi.vulkan.vk.extensions.khr_wayland_surface.name);
                        } else if (builtin.os.tag == .macos) {
                            useExtension |= std.mem.eql(u8, extensionSlice, rhi.vulkan.vk.extensions.ext_metal_surface.name);
                        }
                        useExtension |= std.mem.eql(u8, extensionSlice, rhi.vulkan.vk.extensions.khr_surface.name);
                        useExtension |= std.mem.eql(u8, extensionSlice, rhi.vulkan.vk.extensions.ext_swapchain_colorspace.name);
                        useExtension |= std.mem.eql(u8, extensionSlice, rhi.vulkan.vk.extensions.ext_debug_utils.name);

                        std.debug.print("Instance Extension: {s}({d}): {s}\n", .{ extensionSlice, extProperties.?[i].spec_version, if (useExtension) "ENABLED" else "DISABLED" });
                        if (useExtension) {
                            try enabled_extension_names.append(alloc, @ptrCast(std.mem.sliceTo(extProperties.?[i].extension_name[0..], 0)));
                        }
                    }
                }
                var instanceCreateInfo = rhi.vulkan.vk.InstanceCreateInfo{ .s_type = .instance_create_info, .p_application_info = &app_info, .pp_enabled_layer_names = enabled_layer_names.items.ptr, .enabled_layer_count = @intCast(enabled_layer_names.items.len), .pp_enabled_extension_names = enabled_extension_names.items.ptr, .enabled_extension_count = @intCast(enabled_extension_names.items.len) };

                if (impl.vk.enable_validation_layer) {
                    vulkan.add_next(&instanceCreateInfo, &validationFeatures);
                }
                const vk_instance: rhi.vulkan.vk.Instance = try loader.createInstance(&instanceCreateInfo, null);
                var instance_wrapper = rhi.vulkan.vk.InstanceWrapper.load(vk_instance, loader.dispatch.vkGetInstanceProcAddr.?);

                var debug_message_util: ?rhi.vulkan.vk.DebugUtilsMessengerEXT = null;
                if (impl.vk.enable_validation_layer and instance_wrapper.dispatch.vkCreateDebugUtilsMessengerEXT != null) {
                    var debug_create_info = rhi.vulkan.vk.DebugUtilsMessengerCreateInfoEXT{ .s_type = .debug_utils_messenger_create_info_ext, .pfn_user_callback = &vulkan.VKDebugMessengerUtility, .message_severity = .{ .info_ext = true, .warning_ext = true, .error_ext = true }, .message_type = .{ .general_ext = true, .validation_ext = true, .performance_ext = true } };
                    debug_message_util = try instance_wrapper.createDebugUtilsMessengerEXT(vk_instance, &debug_create_info, null);
                }

                Renderer.instance = Renderer{ .backend = .{ .vk = .{
                    .api_version = app_info.api_version,
                    .instance = vk_instance,
                    .ikb = instance_wrapper,
                    .debug_message_utils = debug_message_util,
                    .vkb = loader,
                } } };
                return;
            }
            return error.VulkanNotSupported;
        },
        .dx12 => {
            if (rhi.platform_has_api(.dx12)) {
                Renderer.instance = Renderer{ .backend = .{ .dx12 = {} } };
                return;
            }
            return error.DirectX12NotSupported;
            //@panic("DirectX 12 target not supported in this build configuration");
        },
        .mtl => {
            if (rhi.platform_has_api(.mtl)) {
                Renderer.instance = Renderer{ .backend = .{ .mtl = {} } };
                return;
            }
            return error.MetalNotSupported;
        },
        .webgpu => {
            if (comptime rhi.platform_has_api(.webgpu)) {
                const wgpu_instance = rhi.webgpu.c.wgpuCreateInstance(null);
                if (wgpu_instance == null) return error.WebGPUInstanceCreationFailed;
                Renderer.instance = .{ .backend = .{ .webgpu = .{ .instance = wgpu_instance } } };
                return;
            }
            return error.WebGPUNotSupported;
        },
    }
}

pub fn processEvents() void {
    if ((comptime rhi.platform_has_api(.webgpu)) and instance.backend == .webgpu) {
        rhi.webgpu.c.wgpuInstanceProcessEvents(instance.backend.webgpu.instance);
    }
}
