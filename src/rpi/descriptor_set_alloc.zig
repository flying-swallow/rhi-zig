//! Frame-aware descriptor-set allocator — the piece `rpi/program.zig` imports as
//! `descriptor_set_alloc.zig` but that was never committed. It is a faithful Zig
//! port of Amnesia64 HPL2's `RIDescriptorSetAllocator.h/.cpp` plus the per-program
//! `vkDescriptorSetAlloc` pool-creation callback from `RIProgram.cpp`.
//!
//! Each program descriptor-set slot owns one `Alloc`. An `Alloc` is an LRU cache
//! of `VkDescriptorSet`s keyed by a content hash of the bindings that land in the
//! set: `resolve()` returns a cached set (with `found = true`, no rewrite needed)
//! or a recycled/fresh set (`found = false`, caller must write it). Sets fall out
//! of reuse only once they are older than `frames_in_flight` frames, so a set that
//! may still be referenced by an in-flight command buffer is never overwritten.
//! Pools sized to the set's reflected descriptor counts are created lazily, each
//! yielding `DESCRIPTOR_MAX_SIZE` sets.
//!
//! Vulkan-only. `vk` collapses to `void` off-Vulkan; nothing here is analyzed on
//! Metal because `rpi/program.zig` only references these types inside its
//! Vulkan-gated paths.

const rhi = @import("../root.zig");
const std = @import("std");

/// The Vulkan namespace, or `void` where Vulkan is unavailable. Gated so the
/// `if (false)` branch is never evaluated on Metal (where `rhi.vulkan == void`).
const vk = if (rhi.platform_has_api(.vk)) rhi.vulkan.vk else void;

const Program = @import("program.zig");
const binding = @import("binding.zig");

/// Frames a set stays resident before it may be recycled. Matches the swapchain
/// ring depth (`rhi.Swapchain = Swapchain(3)`).
pub const RI_NUMBER_FRAMES_FLIGHT: u32 = 3;

/// Sets allocated per pool (mirrors `DESCRIPTOR_MAX_SIZE` in RIProgram.cpp).
const DESCRIPTOR_MAX_SIZE: u32 = 64;
/// Bucket count of the intrusive hash table (mirrors `ALLOC_HASH_RESERVE`).
const ALLOC_HASH_RESERVE: usize = 256;
/// Slots per heap block; blocks give slots stable addresses across `Alloc` moves.
const RESERVE_BLOCK_SIZE: usize = 1024;

/// Per-descriptor-type pool sizing, copied from the program's `DescriptorSetSlot`
/// counts at `Alloc.init` time. Held by value (never a pointer into the `Program`,
/// which is returned by value from `initialize` and would move).
pub const PoolSizes = struct {
    sampler: u32 = 0,
    combined_image_sampler: u32 = 0,
    constant_buffer: u32 = 0,
    dynamic_constant_buffer: u32 = 0,
    texture: u32 = 0,
    storage_texture: u32 = 0,
    buffer: u32 = 0,
    storage_buffer: u32 = 0,
    structured_buffer: u32 = 0,
    storage_structured_buffer: u32 = 0,
    acceleration_structure: u32 = 0,
};

/// One cached descriptor set with its intrusive LRU-queue and hash-chain links.
/// Allocated in `RESERVE_BLOCK_SIZE` heap blocks so the address stays valid for
/// the lifetime of the `Alloc`.
pub const Slot = struct {
    hash: u64 = 0,
    frame_count: u32 = 0,

    qu_next: ?*Slot = null,
    qu_prev: ?*Slot = null,
    h_next: ?*Slot = null,
    h_prev: ?*Slot = null,

    pool: if (rhi.platform_has_api(.vk)) vk.DescriptorPool else void = undefined,
    /// The bindable set handle; read by `Program.bindDescriptors` as `result.set.handle`.
    handle: if (rhi.platform_has_api(.vk)) vk.DescriptorSet else void = undefined,
};

pub const Result = struct {
    /// When true the set was found in the cache and already holds the right
    /// descriptors; the caller skips the write. When false the caller must write it.
    found: bool,
    set: *Slot,
};

/// The per-descriptor-set LRU allocator.
pub const Alloc = struct {
    frames_in_flight: u32 = 0,
    sizes: PoolSizes = .{},
    set_layout: if (rhi.platform_has_api(.vk)) vk.DescriptorSetLayout else void = undefined,

    hash_slots: [ALLOC_HASH_RESERVE]?*Slot = @splat(null),
    queue_begin: ?*Slot = null,
    queue_end: ?*Slot = null,

    reserved: std.ArrayListUnmanaged(*Slot) = .empty,
    pools: std.ArrayListUnmanaged(if (rhi.platform_has_api(.vk)) vk.DescriptorPool else void) = .empty,
    blocks: std.ArrayListUnmanaged([]Slot) = .empty,
    block_index: usize = 0,

    pub const Config = struct {
        set_layout: vk.DescriptorSetLayout,
        sizes: PoolSizes,
    };

    pub fn init(config: Config, frames_in_flight: u32) Alloc {
        return .{
            .frames_in_flight = frames_in_flight,
            .sizes = config.sizes,
            .set_layout = config.set_layout,
        };
    }

    /// Destroy the pools and free the slot blocks / bookkeeping arrays. The GPU
    /// must be idle (the sets must no longer be referenced by any command buffer).
    pub fn free(self: *Alloc, allocator: std.mem.Allocator, device: *rhi.Device) void {
        var dkb: *vk.DeviceWrapper = &device.backend.vk.dkb;
        const dev = device.backend.vk.device;
        for (self.pools.items) |pool| dkb.destroyDescriptorPool(dev, pool, null);
        self.pools.deinit(allocator);
        for (self.blocks.items) |block| allocator.free(block);
        self.blocks.deinit(allocator);
        self.reserved.deinit(allocator);
        self.* = .{};
    }

    /// Resolve a descriptor set for `hash` at `frame_count` (a monotonically
    /// increasing frame counter, not the ring index). See the file comment for
    /// the returned `found` semantics.
    pub fn resolve(self: *Alloc, allocator: std.mem.Allocator, device: *rhi.Device, frame_count: u32, hash: u64) !Result {
        const hash_index = hash % ALLOC_HASH_RESERVE;

        // 1. Cache hit — move the slot to the MRU end of the queue and reuse it.
        var c = self.hash_slots[hash_index];
        while (c) |s| : (c = s.h_next) {
            if (s.hash != hash) continue;
            if (self.queue_end != s) {
                // Unlink from its current queue position.
                if (self.queue_begin == s) {
                    self.queue_begin = s.qu_next;
                    if (s.qu_next) |n| n.qu_prev = null;
                } else {
                    if (s.qu_prev) |p| p.qu_next = s.qu_next;
                    if (s.qu_next) |n| n.qu_prev = s.qu_prev;
                }
                // Re-link at the MRU end.
                s.qu_next = null;
                s.qu_prev = self.queue_end;
                if (self.queue_end) |e| e.qu_next = s;
                self.queue_end = s;
            }
            s.frame_count = frame_count;
            return .{ .found = true, .set = s };
        }

        // 2. Recycle the LRU tail if it is older than the frames-in-flight window.
        if (self.queue_begin) |begin| {
            if (frame_count > begin.frame_count + self.frames_in_flight) {
                detach(self, begin);
                begin.frame_count = frame_count;
                begin.hash = hash;
                attach(self, begin);
                return .{ .found = false, .set = begin };
            }
        }

        // 3. Take a reserved slot, growing the pool if the reserve is empty.
        if (self.reserved.items.len == 0) {
            try self.createPool(allocator, device);
            std.debug.assert(self.reserved.items.len > 0);
        }
        const slot = self.reserved.pop().?;
        slot.hash = hash;
        slot.frame_count = frame_count;
        attach(self, slot);
        return .{ .found = false, .set = slot };
    }

    /// Create one `VkDescriptorPool` sized to this set's descriptor counts and
    /// allocate `DESCRIPTOR_MAX_SIZE` sets from it into fresh reserved slots.
    /// Port of `vkDescriptorSetAlloc` in RIProgram.cpp.
    fn createPool(self: *Alloc, allocator: std.mem.Allocator, device: *rhi.Device) !void {
        var dkb: *vk.DeviceWrapper = &device.backend.vk.dkb;
        const dev = device.backend.vk.device;
        const s = self.sizes;

        var sizes: [16]vk.DescriptorPoolSize = undefined;
        var n: u32 = 0;
        const add = struct {
            fn f(arr: []vk.DescriptorPoolSize, i: *u32, t: vk.DescriptorType, count: u32) void {
                if (count == 0) return;
                arr[i.*] = .{ .type = t, .descriptor_count = count * DESCRIPTOR_MAX_SIZE };
                i.* += 1;
            }
        }.f;
        add(&sizes, &n, .sampler, s.sampler);
        add(&sizes, &n, .combined_image_sampler, s.combined_image_sampler);
        add(&sizes, &n, .uniform_buffer, s.constant_buffer);
        add(&sizes, &n, .uniform_buffer_dynamic, s.dynamic_constant_buffer);
        add(&sizes, &n, .sampled_image, s.texture);
        add(&sizes, &n, .storage_image, s.storage_texture);
        add(&sizes, &n, .uniform_texel_buffer, s.buffer);
        add(&sizes, &n, .storage_texel_buffer, s.storage_buffer);
        add(&sizes, &n, .storage_buffer, s.structured_buffer + s.storage_structured_buffer);
        add(&sizes, &n, .acceleration_structure_khr, s.acceleration_structure);

        const info: vk.DescriptorPoolCreateInfo = .{
            .flags = .{ .free_descriptor_set_bit = true },
            .max_sets = DESCRIPTOR_MAX_SIZE,
            .pool_size_count = n,
            .p_pool_sizes = if (n > 0) &sizes else null,
        };
        const pool = try dkb.createDescriptorPool(dev, &info, null);
        errdefer dkb.destroyDescriptorPool(dev, pool, null);
        try self.pools.append(allocator, pool);

        var layouts: [DESCRIPTOR_MAX_SIZE]vk.DescriptorSetLayout = undefined;
        for (&layouts) |*l| l.* = self.set_layout;
        var handles: [DESCRIPTOR_MAX_SIZE]vk.DescriptorSet = undefined;
        const alloc_info: vk.DescriptorSetAllocateInfo = .{
            .descriptor_pool = pool,
            .descriptor_set_count = DESCRIPTOR_MAX_SIZE,
            .p_set_layouts = &layouts,
        };
        try dkb.allocateDescriptorSets(dev, &alloc_info, &handles);

        try self.reserved.ensureUnusedCapacity(allocator, DESCRIPTOR_MAX_SIZE);
        for (handles) |h| {
            const slot = try self.allocSlot(allocator);
            slot.pool = pool;
            slot.handle = h;
            self.reserved.appendAssumeCapacity(slot);
        }
    }

    /// Hand out the next slot from the current heap block, allocating a new block
    /// when the current one is exhausted. Port of `allocDescriptorSetSlot`.
    fn allocSlot(self: *Alloc, allocator: std.mem.Allocator) !*Slot {
        if (self.blocks.items.len == 0 or self.block_index == RESERVE_BLOCK_SIZE) {
            const block = try allocator.alloc(Slot, RESERVE_BLOCK_SIZE);
            for (block) |*slot| slot.* = .{};
            try self.blocks.append(allocator, block);
            self.block_index = 0;
        }
        const block = self.blocks.items[self.blocks.items.len - 1];
        const slot = &block[self.block_index];
        self.block_index += 1;
        return slot;
    }

    /// Append `slot` at the MRU queue end and prepend it in its hash bucket.
    fn attach(self: *Alloc, slot: *Slot) void {
        slot.qu_next = null;
        slot.qu_prev = self.queue_end;
        if (self.queue_end) |e| e.qu_next = slot;
        self.queue_end = slot;
        if (self.queue_begin == null) self.queue_begin = slot;

        const hi = slot.hash % ALLOC_HASH_RESERVE;
        slot.h_prev = null;
        slot.h_next = self.hash_slots[hi];
        if (self.hash_slots[hi]) |h| h.h_prev = slot;
        self.hash_slots[hi] = slot;
    }

    /// Unlink `slot` from both the queue and its hash bucket.
    fn detach(self: *Alloc, slot: *Slot) void {
        if (self.queue_begin == slot) {
            self.queue_begin = slot.qu_next;
            if (slot.qu_next) |n| n.qu_prev = null;
        } else if (self.queue_end == slot) {
            self.queue_end = slot.qu_prev;
            if (slot.qu_prev) |p| p.qu_next = null;
        } else {
            if (slot.qu_prev) |p| p.qu_next = slot.qu_next;
            if (slot.qu_next) |n| n.qu_prev = slot.qu_prev;
        }

        const hi = slot.hash % ALLOC_HASH_RESERVE;
        if (self.hash_slots[hi] == slot) {
            self.hash_slots[hi] = slot.h_next;
            if (slot.h_next) |n| n.h_prev = null;
        } else {
            if (slot.h_prev) |p| p.h_next = slot.h_next;
            if (slot.h_next) |n| n.h_prev = slot.h_prev;
        }
        slot.h_prev = null;
        slot.h_next = null;
    }
};

// ---------------------------------------------------------------------------
// Ray-tracing pipeline cache slot + build (Vulkan only)
// ---------------------------------------------------------------------------

/// A cached ray-tracing pipeline plus its shader-binding table. The four strided
/// regions are precomputed so `Program.traceRays` can dispatch without recomputing
/// them. Mirrors `RIProgram::RTPipelineSlot`.
pub const RTPipelineSlot = struct {
    handle: if (rhi.platform_has_api(.vk)) vk.Pipeline else void =
        if (rhi.platform_has_api(.vk)) .null_handle else {},
    /// Host-visible SBT buffer owning the group handles.
    sbt: ?rhi.Buffer = null,
    raygen_region: if (rhi.platform_has_api(.vk)) vk.StridedDeviceAddressRegionKHR else void = .{ .stride = 0, .size = 0 },
    miss_region: if (rhi.platform_has_api(.vk)) vk.StridedDeviceAddressRegionKHR else void = .{ .stride = 0, .size = 0 },
    hit_region: if (rhi.platform_has_api(.vk)) vk.StridedDeviceAddressRegionKHR else void = .{ .stride = 0, .size = 0 },
    callable_region: if (rhi.platform_has_api(.vk)) vk.StridedDeviceAddressRegionKHR else void = .{ .stride = 0, .size = 0 },

    pub fn destroy(self: *RTPipelineSlot, device: *rhi.Device) void {
        var dkb: *vk.DeviceWrapper = &device.backend.vk.dkb;
        if (self.handle != .null_handle) dkb.destroyPipeline(device.backend.vk.device, self.handle, null);
        if (self.sbt) |*b| b.deinit(device);
        self.* = .{};
    }
};

fn alignUp(x: vk.DeviceSize, a: vk.DeviceSize) vk.DeviceSize {
    return (x + a - 1) & ~(a - 1);
}

/// Build (and cache by `pipeline_hash`) a ray-tracing pipeline + its SBT, then
/// bind it. The caller fills only pNext/flags/maxPipelineRayRecursionDepth on
/// `create_info`; stages, groups and layout come from the program. Port of
/// `RIProgram::bindRayTracingPipeline`.
///
/// Note: the SBT is placed in a plain host-upload `rhi.Buffer`; if a device
/// reports a `shaderGroupBaseAlignment` coarser than the buffer's base alignment
/// the region device addresses may be misaligned. Adequate for the common case;
/// a dedicated aligned allocation can replace it if a device needs it.
pub fn bindRayTracingPipeline(
    program: *Program,
    device: *rhi.Device,
    cmd: *rhi.Cmd,
    pipeline_hash: u64,
    create_info: *vk.RayTracingPipelineCreateInfoKHR,
) !void {
    var dkb: *vk.DeviceWrapper = &device.backend.vk.dkb;
    const dev = device.backend.vk.device;

    const gop = try program.backend.vk.rt_pipeline.getOrPut(program.allocator, pipeline_hash);
    if (!gop.found_existing) {
        errdefer _ = program.backend.vk.rt_pipeline.remove(pipeline_hash);

        // SBT alignment / handle-size requirements for this device.
        var rt_props: vk.PhysicalDeviceRayTracingPipelinePropertiesKHR = undefined;
        rt_props.s_type = .physical_device_ray_tracing_pipeline_properties_khr;
        rt_props.p_next = null;
        var props2: vk.PhysicalDeviceProperties2 = .{ .properties = undefined };
        props2.p_next = &rt_props;
        rhi.renderer.instance.backend.vk.ikb.getPhysicalDeviceProperties2(device.adapter.backend.vk.physical_device, &props2);

        const rt_stages = [_]struct { stage: Program.ProgramStage, bit: vk.ShaderStageFlags }{
            .{ .stage = .raygen, .bit = .{ .raygen_bit_khr = true } },
            .{ .stage = .miss, .bit = .{ .miss_bit_khr = true } },
            .{ .stage = .closest_hit, .bit = .{ .closest_hit_bit_khr = true } },
            .{ .stage = .any_hit, .bit = .{ .any_hit_bit_khr = true } },
            .{ .stage = .intersection, .bit = .{ .intersection_bit_khr = true } },
            .{ .stage = .callable, .bit = .{ .callable_bit_khr = true } },
        };
        const RT_STAGE_COUNT = rt_stages.len;

        var modules: [RT_STAGE_COUNT]vk.ShaderModule = @splat(.null_handle);
        var stages: [RT_STAGE_COUNT]vk.PipelineShaderStageCreateInfo = undefined;
        var stage_idx: [RT_STAGE_COUNT]i32 = @splat(-1);
        var stage_count: u32 = 0;
        defer for (0..stage_count) |i| dkb.destroyShaderModule(dev, modules[i], null);

        for (rt_stages, 0..) |st, i| {
            const bin = program.shader_bin[@intFromEnum(st.stage)];
            if (bin.buf.len == 0) continue;
            std.debug.assert(bin.buf.len % @sizeOf(u32) == 0);
            const mod_info: vk.ShaderModuleCreateInfo = .{
                .code_size = bin.buf.len,
                .p_code = @ptrCast(@alignCast(bin.buf.ptr)),
            };
            modules[stage_count] = try dkb.createShaderModule(dev, &mod_info, null);
            stages[stage_count] = .{
                .stage = st.bit,
                .module = modules[stage_count],
                .p_name = @ptrCast(bin.entry_point.ptr),
            };
            stage_idx[i] = @intCast(stage_count);
            stage_count += 1;
        }
        std.debug.assert(stage_idx[0] >= 0); // raygen is required

        // Groups: 1 raygen, optional miss, optional hit, optional callable.
        var groups: [4]vk.RayTracingShaderGroupCreateInfoKHR = undefined;
        var group_count: u32 = 0;
        const pushGeneral = struct {
            fn f(arr: []vk.RayTracingShaderGroupCreateInfoKHR, gc: *u32, shader: u32) void {
                arr[gc.*] = .{
                    .type = .general_khr,
                    .general_shader = shader,
                    .closest_hit_shader = vk.SHADER_UNUSED_KHR,
                    .any_hit_shader = vk.SHADER_UNUSED_KHR,
                    .intersection_shader = vk.SHADER_UNUSED_KHR,
                };
                gc.* += 1;
            }
        }.f;

        const raygen_off = group_count;
        pushGeneral(&groups, &group_count, @intCast(stage_idx[0]));
        const raygen_count: u32 = 1;

        const miss_off = group_count;
        var miss_count: u32 = 0;
        if (stage_idx[1] >= 0) {
            pushGeneral(&groups, &group_count, @intCast(stage_idx[1]));
            miss_count = 1;
        }

        const hit_off = group_count;
        var hit_count: u32 = 0;
        if (stage_idx[2] >= 0 or stage_idx[3] >= 0 or stage_idx[4] >= 0) {
            groups[group_count] = .{
                .type = if (stage_idx[4] >= 0) .procedural_hit_group_khr else .triangles_hit_group_khr,
                .general_shader = vk.SHADER_UNUSED_KHR,
                .closest_hit_shader = if (stage_idx[2] >= 0) @intCast(stage_idx[2]) else vk.SHADER_UNUSED_KHR,
                .any_hit_shader = if (stage_idx[3] >= 0) @intCast(stage_idx[3]) else vk.SHADER_UNUSED_KHR,
                .intersection_shader = if (stage_idx[4] >= 0) @intCast(stage_idx[4]) else vk.SHADER_UNUSED_KHR,
            };
            group_count += 1;
            hit_count = 1;
        }

        const callable_off = group_count;
        var callable_count: u32 = 0;
        if (stage_idx[5] >= 0) {
            pushGeneral(&groups, &group_count, @intCast(stage_idx[5]));
            callable_count = 1;
        }

        create_info.stage_count = stage_count;
        create_info.p_stages = &stages;
        create_info.group_count = group_count;
        create_info.p_groups = &groups;
        create_info.layout = program.backend.vk.pipeline_layout;
        if (create_info.max_pipeline_ray_recursion_depth == 0) create_info.max_pipeline_ray_recursion_depth = 1;
        create_info.base_pipeline_index = -1;

        var slot: RTPipelineSlot = .{};
        var pipes: [1]vk.Pipeline = .{.null_handle};
        const cis = [_]vk.RayTracingPipelineCreateInfoKHR{create_info.*};
        _ = try dkb.createRayTracingPipelinesKHR(dev, .null_handle, .null_handle, &cis, null, &pipes);
        slot.handle = pipes[0];
        errdefer dkb.destroyPipeline(dev, slot.handle, null);

        // SBT: one record per group, each padded to the handle alignment; each
        // region starts on a base-alignment boundary.
        const handle_size: vk.DeviceSize = rt_props.shader_group_handle_size;
        const handle_stride = alignUp(handle_size, rt_props.shader_group_handle_alignment);
        const base_align: vk.DeviceSize = rt_props.shader_group_base_alignment;
        const raygen_size = alignUp(handle_stride * raygen_count, base_align);
        const miss_size = alignUp(handle_stride * miss_count, base_align);
        const hit_size = alignUp(handle_stride * hit_count, base_align);
        const callable_size = alignUp(handle_stride * callable_count, base_align);
        const sbt_size = raygen_size + miss_size + hit_size + callable_size;

        var sbt = try rhi.Buffer.init_general(device, .{
            .size = sbt_size,
            .persistant_map = true,
            .buffer_usage = .prefer_host,
            .usage = .{ .shader_binding_table = true, .device_address = true, .shader_resource = true },
        });
        errdefer sbt.deinit(device);
        slot.sbt = sbt;

        // Fetch all group handles, then scatter each region's handles into the SBT.
        const handles_bytes = try program.allocator.alloc(u8, @intCast(handle_size * group_count));
        defer program.allocator.free(handles_bytes);
        try dkb.getRayTracingShaderGroupHandlesKHR(dev, slot.handle, 0, group_count, handles_bytes.len, handles_bytes.ptr);

        const mapped: [*]u8 = @ptrCast(sbt.mapped_region.?);
        writeRegion(mapped, handles_bytes, handle_size, handle_stride, raygen_off, raygen_count);
        writeRegion(mapped + raygen_size, handles_bytes, handle_size, handle_stride, miss_off, miss_count);
        writeRegion(mapped + raygen_size + miss_size, handles_bytes, handle_size, handle_stride, hit_off, hit_count);
        writeRegion(mapped + raygen_size + miss_size + hit_size, handles_bytes, handle_size, handle_stride, callable_off, callable_count);

        const bda_info: vk.BufferDeviceAddressInfo = .{ .buffer = sbt.backend.vk.buffer };
        const base = dkb.getBufferDeviceAddress(dev, &bda_info);
        // raygen region stride MUST equal its size per the spec.
        slot.raygen_region = .{ .device_address = base, .stride = raygen_size, .size = raygen_size };
        slot.miss_region = .{ .device_address = base + raygen_size, .stride = if (miss_count > 0) handle_stride else 0, .size = miss_size };
        slot.hit_region = .{ .device_address = base + raygen_size + miss_size, .stride = if (hit_count > 0) handle_stride else 0, .size = hit_size };
        slot.callable_region = .{ .device_address = base + raygen_size + miss_size + hit_size, .stride = if (callable_count > 0) handle_stride else 0, .size = callable_size };

        gop.value_ptr.* = slot;
    }
    dkb.cmdBindPipeline(cmd.backend.vk.cmd, .ray_tracing_khr, gop.value_ptr.handle);
}

fn writeRegion(dst: [*]u8, handles: []const u8, handle_size: vk.DeviceSize, handle_stride: vk.DeviceSize, group_off: u32, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const d = dst + i * handle_stride;
        const src = handles[(group_off + i) * handle_size ..][0..@intCast(handle_size)];
        @memcpy(d[0..@intCast(handle_size)], src);
    }
}
