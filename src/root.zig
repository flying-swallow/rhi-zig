//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const builtin = @import("builtin");

pub const vulkan = @import("vulkan.zig");
pub const vma = @import("vma");
pub const format = @import("format.zig");
pub const renderer = @import("renderer.zig");
pub const device = @import("device.zig");
pub const queue = @import("queue.zig");
pub const physical_adapter = @import("physical_adapter.zig");
pub const swapchain = @import("swapchain.zig");
pub const descriptor = @import("descriptor.zig");
pub const cmd = @import("cmd.zig");
pub const image = @import("image.zig");
pub const sampler = @import("sampler.zig");
pub const buffer = @import("buffer.zig");
pub const fence = @import("fence.zig");
pub const pipeline_layout = @import("pipeline_layout.zig");
pub const pipeline = @import("pipeline.zig");
pub const resource_loader = @import("resource_loader.zig");

pub const Renderer = renderer.Renderer;
pub const PhysicalAdapter = physical_adapter.PhysicalAdapter;
pub const Queue = queue.Queue;
pub const Device = device.Device;
pub const Swapchain = swapchain.Swapchain;
pub const WindowHandle = swapchain.WindowHandle;
pub const Pool = cmd.Pool;
pub const Cmd = cmd.Cmd;
pub const Image = image.Image;
pub const Descriptor = descriptor.Descriptor;
pub const Sampler = sampler.Sampler;
pub const Format = format.Format;
pub const Buffer = buffer.Buffer;
pub const Fence = fence.Fence;
pub const ResourceLoader = resource_loader.ResourceLoader;
pub const PipelineLayout = pipeline_layout.PipelineLayout;
pub const GraphicsPipeline = pipeline.GraphicsPipeline;
pub const TimeKeeper = @import("time_keeper.zig");

pub const Selection = enum {
    default, 
    vk,
    dx12,
    mtl
};

pub const Backend = enum {
    vk,
    dx12,
    mtl,
};

pub const platform_api = blk: {
    switch (builtin.os.tag) {
        .windows => break :blk [_]Backend{ .vk, .dx12 },
        .linux => break :blk [_]Backend{ .vk },
        .macos => break :blk [_]Backend{ .mtl },
        .ios => break :blk [_]Backend{ .mtl },
        else => break :blk [_]Backend{},
    }
};


pub fn platform_has_api(comptime target: Backend) bool {
    for (platform_api) |t| {
        if (t == target) return true;
    }
    return false;
}

pub fn is_target_selected(comptime api: Backend, ren: *Renderer) bool{
    switch(api) {
        .vk => return platform_has_api(.vk) and ren.backend == .vk,
        .dx12 => return platform_has_api(.dx12) and ren.backend == .dx12,
        .mtl => return platform_has_api(.mtl) and ren.backend == .mtl,
    }
}

pub fn select(ren: *Renderer ,comptime T: type, pass: T, comptime predicate: fn(comptime target: Backend, val: T) void) void {
    for (platform_api) |api| {
        if(ren.backend == api){
            predicate(api, pass);
            return;
        }
    }
}

pub fn wrapper_platform_type(api: Backend, comptime impl: type) type {
    if(platform_has_api(api)){
        return impl;
    } else {
        return void;
    }
}

