// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const rhi = @import("root.zig");
const std = @import("std");

pub const GpuPassTiming = struct {
    name: []const u8,
    ms: f32,
    depth: u32,
};

pub fn GpuProfiler(comptime num_slots: u32) type {
    return struct {
        const Self = @This();
        pub const max_queries: u32 = 256;

        const Scope = struct {
            name: [*:0]const u8,
            depth: u32,
            begin_idx: u32,
            end_idx: u32,
        };

        const SlotBackend = union {
            vk: if (rhi.platform_has_api(.vk)) struct {
                pool: rhi.vulkan.vk.QueryPool,
            } else void,
            dx12: void,
            mtl: void,
        };

        const Slot = struct {
            timeline_value: u64,
            resolved: bool,
            query_count: u32,
            scopes: std.ArrayListUnmanaged(Scope),
            backend: SlotBackend,
        };

        slots: [num_slots]Slot,
        open_stack: std.ArrayListUnmanaged(u32),
        active_slot: u32,
        enabled: bool,
        ticks_to_ms: f64,
        valid_bits_mask: u64,
        results: std.ArrayListUnmanaged(GpuPassTiming),
        total_ms: f32,

        pub fn init(self: *Self, allocator: std.mem.Allocator, device: *rhi.Device) !void {
            self.open_stack = .{};
            self.results = .{};
            self.active_slot = 0;
            self.enabled = false;
            self.ticks_to_ms = 0;
            self.valid_bits_mask = ~@as(u64, 0);
            self.total_ms = 0;

            if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
                const dkb = &device.backend.vk.dkb;
                const vk_device = device.backend.vk.device;

                var family_count: u32 = 0;
                rhi.renderer.instance.backend.vk.ikb.getPhysicalDeviceQueueFamilyProperties(
                    device.adapter.backend.vk.physical_device,
                    &family_count,
                    null,
                );
                const family_props = try allocator.alloc(rhi.vulkan.vk.QueueFamilyProperties, family_count);
                defer allocator.free(family_props);
                rhi.renderer.instance.backend.vk.ikb.getPhysicalDeviceQueueFamilyProperties(
                    device.adapter.backend.vk.physical_device,
                    &family_count,
                    family_props.ptr,
                );

                const gfx_family = device.graphics_queue.backend.vk.family_index;
                const valid_bits = family_props[gfx_family].timestamp_valid_bits;
                self.valid_bits_mask = if (valid_bits >= 64)
                    ~@as(u64, 0)
                else
                    (@as(u64, 1) << @intCast(valid_bits)) - 1;

                if (device.adapter.timestamp_frequency_hz > 0) {
                    self.ticks_to_ms = 1000.0 / @as(f64, @floatFromInt(device.adapter.timestamp_frequency_hz));
                }

                const create_info = rhi.vulkan.vk.QueryPoolCreateInfo{
                    .query_type = .timestamp,
                    .query_count = max_queries,
                };
                for (0..num_slots) |i| {
                    self.slots[i] = .{
                        .timeline_value = 0,
                        .resolved = true,
                        .query_count = 0,
                        .scopes = .{},
                        .backend = .{ .vk = .{
                            .pool = try dkb.createQueryPool(vk_device, &create_info, null),
                        } },
                    };
                }

                self.enabled = true;
                return;
            }

            if ((comptime rhi.platform_has_api(.mtl)) and rhi.is_target_selected(.mtl)) {
                for (0..num_slots) |i| {
                    self.slots[i] = .{
                        .timeline_value = 0,
                        .resolved = true,
                        .query_count = 0,
                        .scopes = .{},
                        .backend = .{ .mtl = {} },
                    };
                }
                return;
            }
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator, device: *rhi.Device) void {
            if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
                const dkb = &device.backend.vk.dkb;
                const vk_device = device.backend.vk.device;
                for (0..num_slots) |i| {
                    dkb.destroyQueryPool(vk_device, self.slots[i].backend.vk.pool, null);
                    self.slots[i].scopes.deinit(allocator);
                }
            } else {
                for (0..num_slots) |i| {
                    self.slots[i].scopes.deinit(allocator);
                }
            }
            self.open_stack.deinit(allocator);
            self.results.deinit(allocator);
        }

        // Call after primary command buffer begin(), before any pass. slot matches
        // the current frame-in-flight index; timeline_value is what this submit will signal.
        pub fn begin_frame(
            self: *Self,
            allocator: std.mem.Allocator,
            device: *rhi.Device,
            cmd: *rhi.Cmd,
            slot: u32,
            timeline_value: u64,
        ) !void {
            if (!self.enabled) return;
            std.debug.assert(slot < num_slots);

            self.active_slot = slot;
            const s = &self.slots[slot];
            s.timeline_value = timeline_value;
            s.resolved = false;
            s.query_count = 0;
            try s.scopes.resize(allocator, 0);
            self.open_stack.clearRetainingCapacity();

            if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
                const dkb = &device.backend.vk.dkb;
                dkb.cmdResetQueryPool(cmd.backend.vk.cmd, s.backend.vk.pool, 0, max_queries);
                return;
            }
        }

        // Write a start timestamp and push a named scope. Nestable.
        pub fn begin_scope(
            self: *Self,
            allocator: std.mem.Allocator,
            device: *rhi.Device,
            cmd: *rhi.Cmd,
            name: [*:0]const u8,
        ) !void {
            if (!self.enabled) return;

            const s = &self.slots[self.active_slot];
            const depth: u32 = @intCast(self.open_stack.items.len);
            const scope_idx: u32 = @intCast(s.scopes.items.len);

            var begin_idx: u32 = std.math.maxInt(u32);
            var end_idx: u32 = std.math.maxInt(u32);

            if (s.query_count + 2 <= max_queries) {
                begin_idx = s.query_count;
                end_idx = s.query_count + 1;
                s.query_count += 2;

                if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
                    const dkb = &device.backend.vk.dkb;
                    dkb.cmdWriteTimestamp2(
                        cmd.backend.vk.cmd,
                        .{ .top_of_pipe_bit = true },
                        s.backend.vk.pool,
                        begin_idx,
                    );
                }
            }

            try s.scopes.append(allocator, .{
                .name = name,
                .depth = depth,
                .begin_idx = begin_idx,
                .end_idx = end_idx,
            });
            try self.open_stack.append(allocator, scope_idx);
        }

        // Write end timestamp and pop the scope. Must pair with begin_scope.
        pub fn end_scope(self: *Self, device: *rhi.Device, cmd: *rhi.Cmd) void {
            if (!self.enabled) return;
            if (self.open_stack.items.len == 0) return;

            const scope_idx = self.open_stack.pop();
            const s = &self.slots[self.active_slot];
            const scope = &s.scopes.items[scope_idx];

            if (scope.end_idx != std.math.maxInt(u32)) {
                if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
                    const dkb = &device.backend.vk.dkb;
                    dkb.cmdWriteTimestamp2(
                        cmd.backend.vk.cmd,
                        .{ .bottom_of_pipe_bit = true },
                        s.backend.vk.pool,
                        scope.end_idx,
                    );
                }
            }
        }

        // Read back any slot the GPU has finished. Non-blocking; call once per frame
        // after advancing the timeline. completed_timeline is the last signalled value.
        pub fn resolve(
            self: *Self,
            allocator: std.mem.Allocator,
            device: *rhi.Device,
            completed_timeline: u64,
        ) !void {
            if (!self.enabled) return;

            self.results.clearRetainingCapacity();
            self.total_ms = 0;

            if ((comptime rhi.platform_has_api(.vk)) and rhi.is_target_selected(.vk)) {
                const dkb = &device.backend.vk.dkb;
                const vk_device = device.backend.vk.device;

                for (0..num_slots) |i| {
                    const s = &self.slots[i];
                    if (s.resolved or s.timeline_value > completed_timeline or s.query_count == 0) continue;

                    var timestamps: [max_queries]u64 = undefined;
                    const vk_result = dkb.getQueryPoolResults(
                        vk_device,
                        s.backend.vk.pool,
                        0,
                        s.query_count,
                        s.query_count * @sizeOf(u64),
                        @ptrCast(&timestamps),
                        @sizeOf(u64),
                        .{ .@"64_bit" = true },
                    ) catch continue;
                    if (vk_result == .not_ready) continue;

                    var depth0_total: f64 = 0;
                    for (s.scopes.items) |scope| {
                        if (scope.begin_idx == std.math.maxInt(u32)) {
                            try self.results.append(allocator, .{
                                .name = std.mem.sliceTo(scope.name, 0),
                                .ms = 0,
                                .depth = scope.depth,
                            });
                            continue;
                        }
                        const ticks = (timestamps[scope.end_idx] -% timestamps[scope.begin_idx]) & self.valid_bits_mask;
                        const ms: f32 = @floatCast(@as(f64, @floatFromInt(ticks)) * self.ticks_to_ms);
                        try self.results.append(allocator, .{
                            .name = std.mem.sliceTo(scope.name, 0),
                            .ms = ms,
                            .depth = scope.depth,
                        });
                        if (scope.depth == 0) depth0_total += @as(f64, @floatFromInt(ticks)) * self.ticks_to_ms;
                    }
                    self.total_ms = @floatCast(depth0_total);
                    s.resolved = true;
                    break;
                }
                return;
            }
        }

        pub fn last_results(self: *const Self) []const GpuPassTiming {
            return self.results.items;
        }

        pub fn last_total_ms(self: *const Self) f32 {
            return self.total_ms;
        }
    };
}

// RAII scope bracket. Usage:
//   var scope = try GpuScope(N).init(&profiler, device, cmd, allocator, "PassName");
//   defer scope.deinit();
pub fn GpuScope(comptime num_slots: u32) type {
    const Profiler = GpuProfiler(num_slots);
    return struct {
        profiler: *Profiler,
        device: *rhi.Device,
        cmd: *rhi.Cmd,

        pub fn init(
            profiler: *Profiler,
            device: *rhi.Device,
            cmd: *rhi.Cmd,
            allocator: std.mem.Allocator,
            name: [*:0]const u8,
        ) !@This() {
            try profiler.begin_scope(allocator, device, cmd, name);
            return .{ .profiler = profiler, .device = device, .cmd = cmd };
        }

        pub fn deinit(self: *@This()) void {
            self.profiler.end_scope(self.device, self.cmd);
        }
    };
}
