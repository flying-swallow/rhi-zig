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

pub fn deinit(self: *Shader, renderer: *rhi.Renderer, device: *rhi.Device) void {
    if ((comptime rhi.platform_has_api(.mtl)) and renderer.backend == .mtl) {
        if (self.backend.mtl.vertex_function) |f| f.release();
        if (self.backend.mtl.vertex_library) |l| l.release();
        if (self.backend.mtl.fragment_function) |f| f.release();
        if (self.backend.mtl.fragment_library) |l| l.release();
        return;
    }
    if ((comptime rhi.platform_has_api(.vk)) and renderer.backend == .vk) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        const vk = self.backend.vk;
        if (vk.vertex_module != .null_handle) dkb.destroyShaderModule(device.backend.vk.device, vk.vertex_module, null);
        if (vk.pixel_module != .null_handle) dkb.destroyShaderModule(device.backend.vk.device, vk.pixel_module, null);
        return;
    }
}

const shader_stage_desc = struct {
    data: []const u8,
    entry_point: []const u8,
};

pub fn init_graphics_shader(device: *rhi.Device, renderer: *rhi.Renderer, options: struct {
    vertex_stage: ?shader_stage_desc = null,
    fragment_stage: ?shader_stage_desc = null,
    geometry_stage: ?shader_stage_desc = null,
    hull_stage: ?shader_stage_desc = null,
    domain_stage: ?shader_stage_desc = null,
    comp_stage: ?shader_stage_desc = null,
}) !Shader {
    if (rhi.is_target_selected(.vk, renderer)) {
        var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
        return .{ .backend = .{ .vk = .{
            .vertex_module = if (options.vertex_stage) |stage| res: {
                std.debug.assert(stage.data.len % @sizeOf(u32) == 0);
                var module_create_info: vulkan.vk.ShaderModuleCreateInfo = .{
                    .sType = vulkan.vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                    .p_next = null,
                    .flags = 0,
                    .code_size = stage.data.len / @sizeOf(u32),
                    .p_code = @ptrCast(stage.data.ptr),
                };
                break :res try dkb.createShaderModule(device.backend.vk.device, &module_create_info, null);
            } else .null_handle,
            .pixel_module = if (options.fragment_stage) |stage| res: {
                std.debug.assert(stage.data.len % @sizeOf(u32) == 0);
                var module_create_info: vulkan.vk.ShaderModuleCreateInfo = .{
                    .sType = vulkan.vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                    .p_next = null,
                    .flags = 0,
                    .code_size = stage.data.len / @sizeOf(u32),
                    .p_code = @ptrCast(stage.data.ptr),
                };
                break :res try dkb.createShaderModule(device.backend.vk.device, &module_create_info, null);
            } else .null_handle,
        } } };
    }
    if (rhi.is_target_selected(.mtl, renderer)) {
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
    return error.UnsupportedBackend;
}
