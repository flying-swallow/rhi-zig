// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const vma = @import("root.zig").vma;
const std = @import("std");

/// A single GPU-visible memory block returned by an AllocFn.
pub const BlockMem = struct {
    mapped_region: ?[]u8 = null,
    backend: union {
        vk: if (rhi.platform_has_api(.vk)) struct {
            buffer: rhi.vulkan.vk.Buffer = .null_handle,
            allocation: vma.c.VmaAllocation = null,
        } else void,
        dx12: rhi.wrapper_platform_type(.dx12, struct {}),
        mtl: rhi.wrapper_platform_type(.mtl, struct {}),
    } = undefined,

    pub fn isEmpty(self: *const BlockMem) bool {
        if (comptime rhi.platform_has_api(.vk)) {
            return self.backend.vk.buffer == .null_handle;
        }
        return true;
    }

    pub fn deinit(self: *BlockMem, device: *rhi.Device) void {
        if (comptime rhi.platform_has_api(.vk)) {
            if (self.backend.vk.buffer != .null_handle) {
                vma.c.vmaDestroyBuffer(
                    device.backend.vk.vma_allocator,
                    @ptrFromInt(@intFromEnum(self.backend.vk.buffer)),
                    self.backend.vk.allocation,
                );
            }
        }
    }
};

/// Allocation request result — describes the sub-range within a block to write into.
pub const AllocReq = struct {
    block: BlockMem,
    /// Slice of the persistently-mapped host memory for this sub-range.
    mapped: []u8,
    /// Byte offset of this sub-range within the block's VkBuffer.
    buffer_offset: usize,
    /// Requested (un-aligned) size in bytes.
    buffer_size: usize,
};

/// Callback type used to allocate a new backing block.
pub const AllocFn = *const fn (device: *rhi.Device, scratch: *ScratchAlloc) BlockMem;

/// Descriptor for initialising a ScratchAlloc.
pub const Desc = struct {
    block_size: usize,
    alignment_req: usize,
    alloc: AllocFn,
};

/// A block-based linear allocator for GPU-mapped memory.
///
/// Sub-allocates from a current block with a linear bump pointer.  When the
/// current block is exhausted a used block is pushed onto the `recycle` list
/// and the next free block is popped from `pool` (or a fresh one is allocated
/// via `alloc`).  Calling `reset` moves all recycled blocks back into `pool`
/// so they can be re-used in the next frame.
pub const ScratchAlloc = struct {
    const Self = @This();

    /// Blocks that were used this "frame" and have not yet been reset.
    recycle: std.ArrayList(BlockMem),
    /// Blocks that are free to be re-used.
    pool: std.ArrayList(BlockMem),

    alignment_req: usize,
    block_size: usize,
    alloc: AllocFn,

    /// The block currently being sub-allocated from.
    current: BlockMem,
    /// Byte offset of the next free location within `current`.
    block_offset: usize,

    pub fn init(allocator: std.mem.Allocator, desc: Desc) Self {
        return .{
            .recycle = std.ArrayList(BlockMem).init(allocator),
            .pool = std.ArrayList(BlockMem).init(allocator),
            .alignment_req = desc.alignment_req,
            .block_size = desc.block_size,
            .alloc = desc.alloc,
            .current = .{ .backend = undefined },
            .block_offset = 0,
        };
    }

    pub fn deinit(self: *Self, device: *rhi.Device) void {
        if (!self.current.isEmpty()) {
            self.current.deinit(device);
        }
        for (self.recycle.items) |*b| b.deinit(device);
        for (self.pool.items) |*b| b.deinit(device);
        self.recycle.deinit();
        self.pool.deinit();
    }

    /// Return all recycled blocks to the free pool and reset the bump pointer.
    /// Call this once per frame before issuing new allocations.
    pub fn reset(self: *Self) void {
        // Move every recycled block back to the free pool.
        self.pool.appendSlice(self.recycle.items) catch {};
        self.recycle.clearRetainingCapacity();
        self.block_offset = 0;
    }

    /// Number of blocks that have been touched this frame (current + recycled).
    pub fn num_used_blocks(self: *const Self) usize {
        var n: usize = 0;
        if (!self.current.isEmpty()) n += 1;
        n += self.recycle.items.len;
        return n;
    }

    /// Indexed access over the used blocks (current first, then recycled).
    pub fn get_used_block(self: *Self, index: usize) *BlockMem {
        if (!self.current.isEmpty()) {
            if (index == 0) return &self.current;
            return &self.recycle.items[index - 1];
        }
        return &self.recycle.items[index];
    }

    /// Sub-allocate `req_size` bytes from the scratch pool.
    /// Panics if `alloc` is null (same behaviour as the C assert).
    pub fn alloc_buffer(self: *Self, device: *rhi.Device, req_size: usize) AllocReq {
        const aligned_size = std.mem.alignForward(usize, req_size, self.alignment_req);

        if (self.current.isEmpty()) {
            // No current block — grab a fresh one.
            self.current = self.alloc(device, self);
            self.block_offset = 0;
        } else if (self.block_offset + aligned_size > self.block_size) {
            // Current block is exhausted — recycle it and get the next one.
            self.recycle.append(self.current) catch {};
            if (self.pool.items.len > 0) {
                self.current = self.pool.pop();
            } else {
                self.current = self.alloc(device, self);
            }
            self.block_offset = 0;
        }

        const mapped = if (self.current.mapped_region) |r|
            r[self.block_offset .. self.block_offset + req_size]
        else
            &[_]u8{};

        const req = AllocReq{
            .block = self.current,
            .mapped = mapped,
            .buffer_offset = self.block_offset,
            .buffer_size = req_size,
        };
        self.block_offset += aligned_size;
        return req;
    }

    /// Flush the host-visible memory for a previously allocated request so
    /// that the GPU can observe the writes.
    pub fn flush_req(device: *rhi.Device, req: *const AllocReq) !void {
        if (comptime rhi.platform_has_api(.vk)) {
            try rhi.vulkan.VKWrapResult(@enumFromInt(vma.c.vmaFlushAllocation(
                device.backend.vk.vma_allocator,
                req.block.backend.vk.allocation,
                req.buffer_offset,
                req.buffer_size,
            )));
        }
    }
};

/// Built-in AllocFn that creates a uniform-buffer-compatible block
/// (equivalent to `RIUniformScratchAllocHandler` in the C implementation).
pub fn uniform_block_alloc(device: *rhi.Device, scratch: *ScratchAlloc) BlockMem {
    if (comptime rhi.platform_has_api(.vk)) {
        const allocation_info = vma.c.VmaAllocationCreateInfo{
            .usage = vma.c.VMA_MEMORY_USAGE_AUTO,
            .flags = vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT |
                vma.c.VMA_ALLOCATION_CREATE_HOST_ACCESS_ALLOW_TRANSFER_INSTEAD_BIT |
                vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
        };
        const buffer_create_info = rhi.vulkan.vk.BufferCreateInfo{
            .size = scratch.block_size,
            .sharing_mode = .exclusive,
            .usage = .{ .uniform_buffer = true },
        };
        var vma_info = vma.c.VmaAllocationInfo{};
        var vk_buffer: vma.c.VkBuffer = undefined;
        var vma_alloc: vma.c.VmaAllocation = undefined;
        rhi.vulkan.VKWrapResult(@enumFromInt(vma.c.vmaCreateBuffer(
            device.backend.vk.vma_allocator,
            @ptrCast(&buffer_create_info),
            &allocation_info,
            &vk_buffer,
            &vma_alloc,
            &vma_info,
        ))) catch @panic("vmaCreateBuffer failed in uniform_block_alloc");

        return .{
            .backend = .{ .vk = .{
                .buffer = @enumFromInt(@intFromPtr(vk_buffer)),
                .allocation = vma_alloc,
            } },
            .mapped_region = if (vma_info.pMappedData != null)
                @as([*c]u8, @ptrCast(vma_info.pMappedData))[0..scratch.block_size]
            else
                null,
        };
    }
    unreachable;
}

/// Convenience constants matching the original C macros.
pub const uniform_scratch_block_size: usize = 256 * 128;
pub const uniform_scratch_alignment: usize = 256;
