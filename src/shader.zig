// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const std = @import("std");
const vulkan = @import("root.zig").vulkan;

pub const Shader = @This();
pub const Stage = enum(u8) {
    stage_none = 0x0,
    stage_vertex = 0x1,
    stage_tesselation_control = 0x2,
    stage_tesselation_evaluation = 0x4,
    stage_geometry = 0x8,
    stage_pixel = 0x10,
    stage_compute = 0x20,

    stage_graphics = .stage_vertex | .stage_tesselation_control |
        .stage_tesselation_evaluation | .stage_geometry | .stage_pixel,
};

pub const ShaderMetadata = struct {};

backend: union(rhi.Backend) {
    vk: if (rhi.platform_has_api(.vk)) struct {
        vertex_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        tesselation_control_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        tesselation_evaluation_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        geometry_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        pixel_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        compute_module: rhi.vulkan.vk.ShaderModule = .null_handle,
    } else void,
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: if (rhi.platform_has_api(.mtl)) struct {
        vertex_library: ?rhi.metal.mtl.Library = null,
        vertex_function: ?rhi.metal.mtl.Function = null,
        fragment_library: ?rhi.metal.mtl.Library = null,
        fragment_function: ?rhi.metal.mtl.Function = null,
    } else void,
    // WGSL keeps the entry point's real name (`@vertex fn vertexMain`), unlike
    // the SPIR-V path where slangc rewrites every entry point to `main` and the
    // Vulkan arm can hardcode it. The names are captured here and handed to
    // `createRenderPipeline`. The slices point at the caller's `entry_point`
    // arguments, which the examples supply as string literals.
    wgpu: if (rhi.platform_has_api(.wgpu)) struct {
        vertex_module: rhi.webgpu.Handle = .none,
        vertex_entry: []const u8 = "",
        fragment_module: rhi.webgpu.Handle = .none,
        fragment_entry: []const u8 = "",
        compute_module: rhi.webgpu.Handle = .none,
        compute_entry: []const u8 = "",
    } else void,
    // GL links a whole program from both stages at once, so there is no
    // per-stage object and no entry point name: SPIRV-Cross always emits
    // `main`. The GLSL source is retained until the pipeline links it.
    webgl: if (rhi.platform_has_api(.webgl)) struct {
        vertex_source: []const u8 = "",
        fragment_source: []const u8 = "",
    } else void,
},

pub fn stages(self: *Shader) Stage {
    return res: switch (self.backend) {
        .dx12 => .stage_none,
        .mtl => |m| {
            var bits: u8 = 0;
            if (m.vertex_function != null) bits |= @intFromEnum(Stage.stage_vertex);
            if (m.fragment_function != null) bits |= @intFromEnum(Stage.stage_pixel);
            break :res @enumFromInt(bits);
        },
        .vk => |vk| {
            var res: Stage = .{};
            if (vk.vertex_module != .null_handle)
                res |= .stage_vertex;
            if (vk.tesselation_control_module != .null_handle)
                res |= .stage_tesselation_control;
            if (vk.tesselation_evaluation_module != .null_handle)
                res |= .stage_tesselation_evaluation;
            if (vk.geometry_module != .null_handle)
                res |= .stage_geometry;
            if (vk.pixel_module != .null_handle)
                res |= .stage_pixel;
            if (vk.compute_module != .null_handle)
                res |= .stage_compute;
            break :res res;
        },
    };
}

pub fn deinit(self: *Shader, device: *rhi.Device) void {
    if ((comptime rhi.platform_has_api(.mtl)) and rhi.renderer.instance.backend == .mtl) {
        if (self.backend.mtl.vertex_function) |f| f.release();
        if (self.backend.mtl.vertex_library) |l| l.release();
        if (self.backend.mtl.fragment_function) |f| f.release();
        if (self.backend.mtl.fragment_library) |l| l.release();
        return;
    }
    if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const vk = self.backend.vk;
        if (vk.vertex_module != .null_handle) dkb.destroyShaderModule(device.backend.vk.device, vk.vertex_module, null);
        if (vk.pixel_module != .null_handle) dkb.destroyShaderModule(device.backend.vk.device, vk.pixel_module, null);
        return;
    }
    if ((comptime rhi.platform_has_api(.webgl)) and rhi.renderer.instance.backend == .webgl) {
        // The sources are borrowed from the caller and the program belongs to
        // the pipeline, so there is nothing to release.
        return;
    }
    if ((comptime rhi.platform_has_api(.wgpu)) and rhi.renderer.instance.backend == .wgpu) {
        const w = &self.backend.wgpu;
        rhi.webgpu.wgpu_release(w.vertex_module);
        rhi.webgpu.wgpu_release(w.fragment_module);
        rhi.webgpu.wgpu_release(w.compute_module);
        w.vertex_module = .none;
        w.fragment_module = .none;
        w.compute_module = .none;
        return;
    }
}

const shader_stage_desc = struct {
    data: []const u8,
    entry_point: []const u8,
};

pub fn init_graphics_shader(device: *rhi.Device, options: struct {
    vertex_stage: ?shader_stage_desc = null,
    fragment_stage: ?shader_stage_desc = null,
    geometry_stage: ?shader_stage_desc = null,
    hull_stage: ?shader_stage_desc = null,
    domain_stage: ?shader_stage_desc = null,
    comp_stage: ?shader_stage_desc = null,
}) !Shader {
    if (rhi.is_target_selected(.vk)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        return .{ .backend = .{ .vk = .{
            .vertex_module = if (options.vertex_stage) |stage| res: {
                std.debug.assert(stage.data.len % @sizeOf(u32) == 0);
                var module_create_info: vulkan.vk.ShaderModuleCreateInfo = .{
                    .code_size = stage.data.len,
                    .p_code = @ptrCast(@alignCast(stage.data.ptr)),
                };
                break :res try dkb.createShaderModule(device.backend.vk.device, &module_create_info, null);
            } else .null_handle,
            .pixel_module = if (options.fragment_stage) |stage| res: {
                std.debug.assert(stage.data.len % @sizeOf(u32) == 0);
                var module_create_info: vulkan.vk.ShaderModuleCreateInfo = .{
                    .code_size = stage.data.len,
                    .p_code = @ptrCast(@alignCast(stage.data.ptr)),
                };
                break :res try dkb.createShaderModule(device.backend.vk.device, &module_create_info, null);
            } else .null_handle,
        } } };
    }
    if (rhi.is_target_selected(.mtl)) {
        const dev = device.backend.mtl.device;
        var result: Shader = .{ .backend = .{ .mtl = .{} } };
        if (options.vertex_stage) |stage| {
            const src = rhi.metal.ns.String.fromUtf8Slice(stage.data);
            var err: ?rhi.metal.ns.Error = null;
            const lib = dev.newLibraryWithSource(src, null, &err) orelse {
                if (err) |e| std.log.err("MSL compile (vertex): {s}", .{e.localizedDescription().utf8()});
                return error.ShaderCompilationFailed;
            };
            const name = rhi.metal.ns.String.fromUtf8Slice(stage.entry_point);
            result.backend.mtl.vertex_library = lib;
            result.backend.mtl.vertex_function = lib.newFunction(name) orelse return error.ShaderEntryPointNotFound;
        }
        if (options.fragment_stage) |stage| {
            const src = rhi.metal.ns.String.fromUtf8Slice(stage.data);
            var err: ?rhi.metal.ns.Error = null;
            const lib = dev.newLibraryWithSource(src, null, &err) orelse {
                if (err) |e| std.log.err("MSL compile (fragment): {s}", .{e.localizedDescription().utf8()});
                return error.ShaderCompilationFailed;
            };
            const name = rhi.metal.ns.String.fromUtf8Slice(stage.entry_point);
            result.backend.mtl.fragment_library = lib;
            result.backend.mtl.fragment_function = lib.newFunction(name) orelse return error.ShaderEntryPointNotFound;
        }
        return result;
    }
    if (rhi.is_target_selected(.webgl)) {
        // GL links one program from both stages, so nothing is created here —
        // the sources are held until `Pipeline.init_graphics` links them. The
        // entry point name is ignored: SPIRV-Cross always emits `main`.
        if (options.geometry_stage != null or options.hull_stage != null or options.domain_stage != null)
            return error.UnsupportedBackend;
        if (options.comp_stage != null) return error.UnsupportedBackend; // no compute in WebGL2
        return .{ .backend = .{ .webgl = .{
            .vertex_source = if (options.vertex_stage) |s| s.data else "",
            .fragment_source = if (options.fragment_stage) |s| s.data else "",
        } } };
    }
    if (rhi.is_target_selected(.wgpu)) {
        const wgpu = rhi.webgpu;
        // `data` is WGSL source text here, not SPIR-V words, so the 4-byte
        // alignment the Vulkan arm asserts does not apply.
        if (options.geometry_stage != null or options.hull_stage != null or options.domain_stage != null)
            return error.UnsupportedBackend; // WebGPU has no geometry or tessellation stages

        var result: Shader = .{ .backend = .{ .wgpu = .{} } };
        errdefer result.deinit(device);
        const dev = device.backend.wgpu.device;
        if (options.vertex_stage) |stage| {
            const m = wgpu.wgpu_device_create_shader_module(dev, stage.data.ptr, @intCast(stage.data.len));
            if (m.isNone()) return error.ShaderCompilationFailed;
            result.backend.wgpu.vertex_module = m;
            result.backend.wgpu.vertex_entry = stage.entry_point;
        }
        if (options.fragment_stage) |stage| {
            const m = wgpu.wgpu_device_create_shader_module(dev, stage.data.ptr, @intCast(stage.data.len));
            if (m.isNone()) return error.ShaderCompilationFailed;
            result.backend.wgpu.fragment_module = m;
            result.backend.wgpu.fragment_entry = stage.entry_point;
        }
        if (options.comp_stage) |stage| {
            const m = wgpu.wgpu_device_create_shader_module(dev, stage.data.ptr, @intCast(stage.data.len));
            if (m.isNone()) return error.ShaderCompilationFailed;
            result.backend.wgpu.compute_module = m;
            result.backend.wgpu.compute_entry = stage.entry_point;
        }
        return result;
    }
    return error.UnsupportedBackend;
}
