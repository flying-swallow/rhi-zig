const rhi = @import("root.zig");
const std = @import("std");
const vulkan = @import("vulkan.zig");

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
    vk: rhi.wrapper_platform_type(.vk, struct {
        vertex_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        tesselation_control_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        tesselation_evaluation_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        geometry_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        pixel_module: rhi.vulkan.vk.ShaderModule = .null_handle,
        compute_module: rhi.vulkan.vk.ShaderModule = .null_handle,
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
},

pub fn stages(self: *Shader) Stage {
    return res: switch (self.backend) {
        .dx12 => .stage_none,
        .mtl => .stage_none,
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
        else => .stage_none,
    };
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
    comp_stage: ?shader_stage_desc = null }) !Shader {
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
        } } };
    } else if (rhi.is_target_selected(.dx12, renderer)) {} else if (rhi.is_target_selected(.mtl, renderer)) {}

    return error.UnsupportedBackend;
}
