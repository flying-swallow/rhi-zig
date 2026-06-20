//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const builtin = @import("builtin");

pub const vma = if (platform_has_api(.vk)) @import("vma") else void;
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
pub const acceleration_structure = @import("acceleration_structure.zig");
pub const fence = @import("fence.zig");
pub const pipeline_layout = @import("pipeline_layout.zig");
pub const pipeline = @import("pipeline.zig");
pub const resource_loader = @import("resource_loader.zig");
pub const shader = @import("shader.zig");
pub const semaphore = @import("semaphore.zig");
pub const scratch_alloc = @import("scratch_alloc.zig");
pub const segment_alloc = @import("segment_alloc.zig");
pub const offset_alloc = @import("offset_alloc.zig");
pub const index_pool = @import("index_pool.zig");

pub const Renderer = renderer.Renderer;
pub const PhysicalAdapter = physical_adapter.PhysicalAdapter;
pub const Queue = queue.Queue;
pub const Device = device.Device;
pub const Swapchain = swapchain.Swapchain;
pub const WindowHandle = swapchain.WindowHandle;
pub const Pool = cmd.Pool;
pub const Cmd = cmd.Cmd;
pub const Image = image.Image;
pub const DepthTexture = image.DepthTexture;
pub const Descriptor = descriptor.Descriptor;
pub const Sampler = sampler.Sampler;
pub const Format = format.Format;
pub const Buffer = buffer.Buffer;
pub const AccelerationStructure = acceleration_structure.AccelerationStructure;
pub const Fence = fence.Fence;
pub const ResourceLoader = resource_loader.ResourceLoader;
pub const Pipeline = pipeline.Pipeline;
pub const PipelineLayout = pipeline_layout.PipelineLayout;
pub const Shader = shader.Shader;
pub const Semaphore = semaphore.Semaphore;
pub const ScratchAlloc = scratch_alloc.ScratchAlloc;
pub const ScratchAllocBlockMem = scratch_alloc.BlockMem;
pub const ScratchAllocReq = scratch_alloc.AllocReq;
pub const SegmentAlloc = segment_alloc.SegmentAlloc;
pub const SegmentAllocReq = segment_alloc.Req;
pub const OffsetAllocator = offset_alloc.Allocator;
pub const OffsetAllocation = offset_alloc.Allocation;
pub const IndexPool = index_pool.IndexPool;
pub const TimeKeeper = @import("time_keeper.zig");

/// Monotonic source of resource identity cookies. A cookie is a stable, unique
/// id stamped on a resource at creation; it is used as a descriptor-set cache
/// key because a raw backend handle is unsafe as identity (handles get reused).
/// `0` is reserved for "empty / uncreated".
var cookie_counter: std.atomic.Value(u64) = .init(1);

pub fn next_cookie() u64 {
    return cookie_counter.fetchAdd(1, .monotonic);
}

/// Backend-neutral descriptor category (mirrors `RIDescriptorType_e`). The
/// engine uses separate sampled images + samplers (no combined-image-sampler).
pub const DescriptorType = enum {
    sampled_image,
    storage_image,
    sampler,
    uniform_buffer,
    storage_buffer,
    acceleration_structure,
};

pub const Selection = enum { default, vk, dx12, mtl };

pub const Backend = enum {
    vk,
    dx12,
    mtl,
};

pub const platform_api = blk: {
    switch (builtin.os.tag) {
        .windows => break :blk [_]Backend{ .vk, .dx12 },
        .linux => break :blk [_]Backend{.vk},
        .macos => break :blk [_]Backend{.mtl},
        .ios => break :blk [_]Backend{.mtl},
        else => break :blk [_]Backend{},
    }
};

pub fn platform_has_api(comptime target: Backend) bool {
    for (platform_api) |t| {
        if (t == target) return true;
    }
    return false;
}

pub const vulkan = if (platform_has_api(.vk)) @import("vulkan.zig") else void;
pub const metal = if (platform_has_api(.mtl)) @import("metal.zig") else void;

/// `inline` so that `platform_has_api(api)` (a comptime-known bool) folds into
/// the caller's `if` condition: on a platform where `api` is unavailable the
/// branch becomes comptime-false and its body (which dereferences that
/// backend's types) is never analyzed.
pub inline fn is_target_selected(comptime api: Backend) bool {
    if (comptime !platform_has_api(api)) return false;
    return renderer.instance.backend == api;
}

//pub fn select(ren: *Renderer, comptime T: type, pass: T, comptime predicate: fn (comptime target: Backend, val: T) void) void {
//    for (platform_api) |api| {
//        if (ren.backend == api) {
//            predicate(api, pass);
//            return;
//        }
//    }
//}

pub fn wrapper_platform_type(comptime api: Backend, comptime impl: type) type {
    if (platform_has_api(api)) {
        return impl;
    } else {
        return void;
    }
}

test "metal: renderer -> adapter -> device init" {
    if (comptime !platform_has_api(.mtl)) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    try Renderer.init(allocator, .{ .mtl = .{} });
    defer Renderer.deinit();
    try std.testing.expectEqualStrings("Metal", Renderer.apiString());

    var adapters = try PhysicalAdapter.enumerate_adapters(allocator);
    defer adapters.deinit(allocator);
    try std.testing.expect(adapters.items.len >= 1);

    const idx = PhysicalAdapter.default_select_adapter(adapters.items);
    const name = std.mem.sliceTo(&adapters.items[idx].name, 0);
    try std.testing.expect(name.len > 0);
    std.debug.print("metal device: {s}\n", .{name});

    var dev = try Device.init(allocator, &adapters.items[idx]);
    defer dev.deinit();
    try dev.graphics_queue.wait_queue_idle(&dev);
}

test "metal: swapchain drawable + command buffer" {
    if (comptime !platform_has_api(.mtl)) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    try Renderer.init(allocator, .{ .mtl = .{} });
    defer Renderer.deinit();
    var adapters = try PhysicalAdapter.enumerate_adapters(allocator);
    defer adapters.deinit(allocator);
    const idx = PhysicalAdapter.default_select_adapter(adapters.items);
    var dev = try Device.init(allocator, &adapters.items[idx]);
    defer dev.deinit();

    // Stand in for a window surface with an offscreen CAMetalLayer.
    const layer = metal.ca.MetalLayer.layer();
    const handle: WindowHandle = .{ .metal = .{ .layer = @ptrCast(layer.obj.value) } };

    var sc = try Swapchain.init(allocator, &dev, 64, 64, handle, .{});
    defer sc.deinit(&dev);

    const index = try sc.acquire_next_image(&dev);
    const view = sc.image_view(index);
    try std.testing.expect(view.backend.mtl.obj.value != null);

    var pool = try Pool.init(&dev, &dev.graphics_queue);
    defer pool.deinit(&dev);
    var command = try Cmd.init(&dev, &pool);
    try command.begin(&dev);
    try std.testing.expect(command.backend.mtl.cmd != null);
}

test {
    _ = @import("acceleration_structure.zig");
    _ = @import("cmd.zig");
}
