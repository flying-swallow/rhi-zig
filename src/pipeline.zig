const rhi = @import("root.zig");
const std = @import("std");
const vulkan = @import("vulkan.zig");

pub const GraphicsPipeline = struct {
    backend: union {
        vk: rhi.wrapper_platform_type(.vk, struct {
            pipeline: rhi.vulkan.vk.Pipeline = .null_handle,
        }),
        dx12: rhi.wrapper_platform_type(.dx12, struct {}),
        mtl: rhi.wrapper_platform_type(.mtl, struct {}),
    },
};

