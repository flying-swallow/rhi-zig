const rhi = @import("root.zig");
const std = @import("std");

const DescriptorSetSlot = struct {
    hash: u32,
    group_index: u32,

    queue_next: ?*DescriptorSetSlot,
    queue_prev: ?*DescriptorSetSlot,

    hash_next: ?*DescriptorSetSlot,
    hash_prev: ?*DescriptorSetSlot,

    backend: union(rhi.Backend) {
        vk: if (rhi.platform_has_api(.vk)) struct {
            pool: rhi.vulkan.vk.DescriptorPool,
            handle: rhi.vulkan.vk.DescriptorSet,
        } else void,
        dx12: if (rhi.platform_has_api(.dx12)) struct {} else void,
        mtl: rhi.wrapper_platform_type(.mtl, struct {}),
    },
};

pub const DescriptorSetResult = struct {
    // if false -- the descriptor needs to be configured
    found: bool,
    set: *DescriptorSetSlot,
};

const DescriptorPoolConfig = struct {
    num_hash_slots: u32 = 1024,
};

pub fn DescriptorPool(comptime config: DescriptorPoolConfig) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        alloc_descriptors: *const fn (pool: *Self, device: *rhi.Device) void,
        groups_inflight: u32, // number of concurrent frames that can be in-flight at once, used to determine how many descriptor sets to allocate in each pool

        hash_slots: [config.num_hash_slots]?*DescriptorSetSlot = @splat(null),
        queue_head: ?*DescriptorSetSlot = null,
        queue_tail: ?*DescriptorSetSlot = null,

        reserved_slots: std.ArrayList(*DescriptorSetSlot) = .empty,

        backend: union {
            vk: if (rhi.platform_has_api(.vk)) struct {
                allocated_pools: std.ArrayList(rhi.vulkan.vk.DescriptorPool),
            } else void,
            dx12: if (rhi.platform_has_api(.dx12)) struct {} else void,
            mtl: rhi.wrapper_platform_type(.mtl, struct {}),
        },

        pub fn init(
            groups_inflight: u32,
            alloc_descriptors: *const fn (pool: *Self, device: *rhi.Device) void,
            allocator: std.mem.Allocator,
        ) !Self {
            return .{
                .groups_inflight = groups_inflight,
                .alloc_descriptors = alloc_descriptors,
                .allocator = allocator,
                .reserved_slots = .empty,
                .backend = if (rhi.is_target_selected(.vk)) .{ .vk = .{
                    .allocated_pools = .empty,
                } } else if (rhi.is_target_selected(.dx12)) .{ .dx12 = {} } else if (rhi.is_target_selected(.mtl)) .{ .mtl = {} } else void,
            };
        }

        pub fn deinit(self: *Self, device: *rhi.Device) void {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.renderer.instance.backend == .vk) {
                var dkb: *rhi.vulkan.vk.DeviceWrapper = &device.backend.vk.dkb;
                for (self.backend.vk.allocated_pools.items) |pool| {
                    dkb.destroyDescriptorPool(device.backend.vk.device, pool, null);
                }
                self.backend.vk.allocated_pools.deinit(self.allocator);
            }
            self.reserved_slots.deinit(self.allocator);
        }

        fn attach_descriptor_slot(self: *Self, slot: *DescriptorSetSlot) void {
            {
                slot.queue_next = null;
                slot.queue_prev = self.queue_tail;
                if (self.queue_tail) |q| {
                    q.queue_next = slot;
                }
                self.queue_tail = slot;
                if (self.queue_head == null) {
                    self.queue_head = slot;
                }
            }
            {
                const hash_index = slot.hash % config.num_hash_slots;
                slot.hash_next = null;
                slot.hash_prev = null;
                if (self.hash_slots[hash_index]) |s| {
                    s.hash_prev = slot;
                    slot.hash_next = self.hash_slots[hash_index];
                }
                self.hash_slots[hash_index] = slot;
            }
        }

        fn detach_descriptor_slot(self: *Self, slot: *DescriptorSetSlot) void {
            // remove from queue
            {
                if (self.queue_head == slot) {
                    self.queue_head = slot.queue_next;
                    if (slot.queue_next) |q| {
                        q.queue_prev = null;
                    }
                } else if (self.queue_tail == slot) {
                    self.queue_tail = slot.queue_prev;
                    if (slot.queue_prev) |q| {
                        q.queue_next = null;
                    }
                } else {
                    if (slot.queue_prev) |s| {
                        s.queue_next = slot.queue_next;
                    }
                    if (slot.queue_next) |s| {
                        s.queue_prev = slot.queue_prev;
                    }
                }
            }
            // free from hashTable
            {
                const hash_index = slot.hash % config.num_hash_slots;
                if (self.hash_slots[hash_index] == slot) {
                    self.hash_slots[hash_index] = slot.hash_next;
                    if (slot.hash_next) |s| {
                        s.hash_prev = null;
                    }
                } else {
                    if (slot.hash_prev) |s| {
                        s.hash_next = slot.hash_next;
                    }
                    if (slot.hash_next) |s| {
                        s.hash_prev = slot.hash_prev;
                    }
                }
            }
        }

        /// Resolves a descriptor set for the given group index and hash. If a matching descriptor set is found in the pool, it is returned. Otherwise, a new descriptor set is allocated using the provided allocation function and returned.
        pub fn resolve_descriptor_set(self: *Self, device: *rhi.Device, group_index: u32, hash: u32) DescriptorSetResult {
            const hash_index: usize = hash % config.num_hash_slots;
            {
                var slot: ?*DescriptorSetSlot = self.hash_slots[hash_index];
                while (slot) |s| {
                    if (s.hash == hash) {
                        // move to MRU end of the LRU queue if not already there
                        if (self.queue_tail != s) {
                            if (self.queue_head == s) {
                                self.queue_head = s.queue_next;
                                if (s.queue_next) |n| {
                                    n.queue_prev = null;
                                }
                            } else {
                                if (s.queue_prev) |p| {
                                    p.queue_next = s.queue_next;
                                }
                                if (s.queue_next) |n| {
                                    n.queue_prev = s.queue_prev;
                                }
                            }
                            s.queue_next = null;
                            s.queue_prev = self.queue_tail;
                            if (self.queue_tail) |qq| {
                                qq.queue_next = s;
                            }
                            self.queue_tail = s;
                        }
                        s.group_index = group_index;
                        return .{ .found = true, .set = s };
                    }
                    slot = s.hash_next;
                }
            }

            if (self.queue_head) |head| {
                if (group_index > head.group_index + self.groups_inflight) {
                    self.detach_descriptor_slot(head);
                    head.group_index = group_index;
                    head.hash = hash;
                    self.attach_descriptor_slot(head);
                    return .{ .found = false, .set = head };
                }
            }

            if (self.reserved_slots.items.len == 0) {
                self.alloc_descriptors(self, device);
                std.debug.assert(self.reserved_slots.items.len > 0);
            }
            const slot = self.reserved_slots.pop() orelse unreachable;
            slot.hash = hash;
            slot.group_index = group_index;
            attach_descriptor_slot(self, slot);
            return .{ .found = false, .set = slot };
        }
    };
}
