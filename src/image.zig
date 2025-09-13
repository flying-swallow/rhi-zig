const rhi = @import("root.zig");
const vma = @import("vma");
const std = @import("std");

pub const Barrier = union {
    vk: rhi.wrapper_platform_type(.vk, rhi.vulkan.vk.ImageMemoryBarrier2),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
};

pub const Image = @This();
backend: union {
    vk: rhi.wrapper_platform_type(.vk, struct {
        image: rhi.vulkan.vk.Image,
        allocation: ?vma.c.VmaAllocation = null,
    }),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
},

pub const ImageView = union {
    vk: rhi.wrapper_platform_type(.vk, rhi.vulkan.vk.ImageView),
    dx12: rhi.wrapper_platform_type(.dx12, struct {}),
    mtl: rhi.wrapper_platform_type(.mtl, struct {}),
};


//pub fn barrier(self: *Image, comptime selection: rhi.Backend, renderer: *rhi.Renderer, options: struct {
//    const AccessLayoutStage = struct {
//        access: rhi.Cmd.AccessBits = .unknown,
//        layout: rhi.Cmd.Layout = .unknown,
//        stage: rhi.Cmd.StageBits = .none,
//    };
//    before: AccessLayoutStage = .{},
//    after: AccessLayoutStage = .{},
//}) switch(selection) {
//    .vk => volk.c.VkImageMemoryBarrier2,
//    .dx12 => struct {},
//    .mtl => struct {},
//}{
//    _ = self;
//    _ = options;
//    if (rhi.is_target_selected(.vk, renderer)) {
//        return .{
//            .vk = volk.c.VkImageMemoryBarrier2 {}
//        };
//    } else if (rhi.is_target_selected(.dx12, rhi.get_renderer)) {
//    } else if (rhi.is_target_selected(.mtl, rhi.get_renderer)) {
//    }
//    return error.UnsupportedBackend;
//}

