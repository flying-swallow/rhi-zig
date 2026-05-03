//! Port of Sebastian Aaltonen's OffsetAllocator (MIT, 2023).
//!
//! A two-level segregated-fit (TLSF-like) allocator that hands out
//! `(offset, size)` ranges from a fixed-size virtual region. Designed for
//! sub-allocating GPU buffer/heap regions, but the implementation here
//! manages only metadata — the caller owns the underlying storage.

const std = @import("std");

pub const num_top_bins: u32 = 32;
pub const bins_per_leaf: u32 = 8;
pub const top_bins_index_shift: u32 = 3;
pub const leaf_bins_index_mask: u32 = 0x7;
pub const num_leaf_bins: u32 = num_top_bins * bins_per_leaf;

/// 16-bit node indices halve the metadata cost but cap maxAllocs at 65536.
/// Match the C++ default (32-bit).
pub const NodeIndex = u32;

pub const Allocation = struct {
    pub const no_space: u32 = 0xffffffff;

    offset: u32 = no_space,
    metadata: NodeIndex = no_space,
};

pub const StorageReport = struct {
    total_free_space: u32,
    largest_free_region: u32,
};

pub const StorageReportFull = struct {
    pub const Region = struct {
        size: u32,
        count: u32,
    };
    free_regions: [num_leaf_bins]Region,
};

/// Floating-point-style size→bin mapping. Bins are spaced log-linearly so
/// that the worst-case overhead of rounding to a bin is a fixed percentage.
pub const SmallFloat = struct {
    pub const mantissa_bits: u32 = 3;
    pub const mantissa_value: u32 = 1 << mantissa_bits;
    pub const mantissa_mask: u32 = mantissa_value - 1;

    pub fn uintToFloatRoundUp(size: u32) u32 {
        var exp: u32 = 0;
        var mantissa: u32 = 0;

        if (size < mantissa_value) {
            mantissa = size;
        } else {
            const leading_zeros: u32 = @clz(size);
            const highest_set_bit: u32 = 31 - leading_zeros;
            const mantissa_start_bit: u32 = highest_set_bit - mantissa_bits;
            exp = mantissa_start_bit + 1;
            mantissa = (size >> @intCast(mantissa_start_bit)) & mantissa_mask;

            const low_bits_mask: u32 = (@as(u32, 1) << @intCast(mantissa_start_bit)) - 1;
            if ((size & low_bits_mask) != 0) mantissa += 1;
        }

        // `+` (not `|`) so that a mantissa overflow carries into the exponent.
        return (exp << mantissa_bits) + mantissa;
    }

    pub fn uintToFloatRoundDown(size: u32) u32 {
        var exp: u32 = 0;
        var mantissa: u32 = 0;

        if (size < mantissa_value) {
            mantissa = size;
        } else {
            const leading_zeros: u32 = @clz(size);
            const highest_set_bit: u32 = 31 - leading_zeros;
            const mantissa_start_bit: u32 = highest_set_bit - mantissa_bits;
            exp = mantissa_start_bit + 1;
            mantissa = (size >> @intCast(mantissa_start_bit)) & mantissa_mask;
        }

        return (exp << mantissa_bits) | mantissa;
    }

    pub fn floatToUint(float_value: u32) u32 {
        const exponent: u32 = float_value >> mantissa_bits;
        const mantissa: u32 = float_value & mantissa_mask;
        if (exponent == 0) return mantissa;
        return (mantissa | mantissa_value) << @intCast(exponent - 1);
    }
};

fn findLowestSetBitAfter(bit_mask: u32, start_bit_index: u32) u32 {
    // The C version relies on `1 << 32` UB wrapping to 1 on x86. Guard explicitly.
    if (start_bit_index >= 32) return Allocation.no_space;
    const mask_before: u32 = (@as(u32, 1) << @intCast(start_bit_index)) - 1;
    const mask_after: u32 = ~mask_before;
    const bits_after: u32 = bit_mask & mask_after;
    if (bits_after == 0) return Allocation.no_space;
    return @intCast(@ctz(bits_after));
}

pub const Allocator = struct {
    const Self = @This();

    pub const Node = struct {
        pub const unused: NodeIndex = 0xffffffff;

        data_offset: u32 = 0,
        data_size: u32 = 0,
        bin_list_prev: NodeIndex = unused,
        bin_list_next: NodeIndex = unused,
        neighbor_prev: NodeIndex = unused,
        neighbor_next: NodeIndex = unused,
        used: bool = false,
    };

    gpa: std.mem.Allocator,
    size: u32,
    max_allocs: u32,
    free_storage: u32 = 0,

    used_bins_top: u32 = 0,
    used_bins: [num_top_bins]u8 = [_]u8{0} ** num_top_bins,
    bin_indices: [num_leaf_bins]NodeIndex = [_]NodeIndex{Node.unused} ** num_leaf_bins,

    nodes: []Node = &.{},
    free_nodes: []NodeIndex = &.{},
    free_offset: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, size: u32, max_allocs: u32) !Self {
        var self: Self = .{
            .gpa = gpa,
            .size = size,
            .max_allocs = max_allocs,
        };
        try self.reset();
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.nodes.len != 0) self.gpa.free(self.nodes);
        if (self.free_nodes.len != 0) self.gpa.free(self.free_nodes);
        self.nodes = &.{};
        self.free_nodes = &.{};
    }

    pub fn reset(self: *Self) !void {
        self.free_storage = 0;
        self.used_bins_top = 0;
        self.free_offset = self.max_allocs - 1;

        self.used_bins = [_]u8{0} ** num_top_bins;
        self.bin_indices = [_]NodeIndex{Node.unused} ** num_leaf_bins;

        if (self.nodes.len != 0) self.gpa.free(self.nodes);
        if (self.free_nodes.len != 0) self.gpa.free(self.free_nodes);

        self.nodes = try self.gpa.alloc(Node, self.max_allocs);
        for (self.nodes) |*n| n.* = .{};

        self.free_nodes = try self.gpa.alloc(NodeIndex, self.max_allocs);
        // Stack of free indices — pop from the top so node 0 comes out first.
        var i: u32 = 0;
        while (i < self.max_allocs) : (i += 1) {
            self.free_nodes[i] = self.max_allocs - i - 1;
        }

        // The whole region begins as a single free node spanning [0, size).
        _ = self.insertNodeIntoBin(self.size, 0);
    }

    pub fn allocate(self: *Self, alloc_size: u32) Allocation {
        if (self.free_offset == 0) {
            return .{ .offset = Allocation.no_space, .metadata = Allocation.no_space };
        }

        // Round up: smallest bin that is guaranteed to fit `alloc_size`.
        const min_bin_index = SmallFloat.uintToFloatRoundUp(alloc_size);

        const min_top_bin_index = min_bin_index >> top_bins_index_shift;
        const min_leaf_bin_index = min_bin_index & leaf_bins_index_mask;

        var top_bin_index = min_top_bin_index;
        var leaf_bin_index: u32 = Allocation.no_space;

        // Probe the rounded-up bin first. May fail (the rounded-up leaf within
        // this top bin can be empty even though other leaves above it aren't).
        if ((self.used_bins_top & (@as(u32, 1) << @intCast(top_bin_index))) != 0) {
            leaf_bin_index = findLowestSetBitAfter(
                @as(u32, self.used_bins[top_bin_index]),
                min_leaf_bin_index,
            );
        }

        // Fall back to the next non-empty top bin. Any leaf there fits.
        if (leaf_bin_index == Allocation.no_space) {
            top_bin_index = findLowestSetBitAfter(self.used_bins_top, min_top_bin_index + 1);
            if (top_bin_index == Allocation.no_space) {
                return .{ .offset = Allocation.no_space, .metadata = Allocation.no_space };
            }
            leaf_bin_index = @intCast(@ctz(self.used_bins[top_bin_index]));
        }

        const bin_index = (top_bin_index << top_bins_index_shift) | leaf_bin_index;

        // Pop the head of the bin's linked list.
        const node_index = self.bin_indices[bin_index];
        const node = &self.nodes[node_index];
        const node_total_size = node.data_size;
        const node_data_offset = node.data_offset;
        const node_neighbor_next = node.neighbor_next;

        node.data_size = alloc_size;
        node.used = true;
        self.bin_indices[bin_index] = node.bin_list_next;
        if (node.bin_list_next != Node.unused)
            self.nodes[node.bin_list_next].bin_list_prev = Node.unused;
        self.free_storage -= node_total_size;

        // Update bin-occupancy bitmasks if the bin is now empty.
        if (self.bin_indices[bin_index] == Node.unused) {
            self.used_bins[top_bin_index] &= ~(@as(u8, 1) << @intCast(leaf_bin_index));
            if (self.used_bins[top_bin_index] == 0) {
                self.used_bins_top &= ~(@as(u32, 1) << @intCast(top_bin_index));
            }
        }

        // Push the unused tail back into the freelist as a smaller free node.
        const reminder_size = node_total_size - alloc_size;
        if (reminder_size > 0) {
            const new_node_index = self.insertNodeIntoBin(reminder_size, node_data_offset + alloc_size);

            // Splice the new node between `node` and its old next neighbor.
            if (node_neighbor_next != Node.unused)
                self.nodes[node_neighbor_next].neighbor_prev = new_node_index;
            self.nodes[new_node_index].neighbor_prev = node_index;
            self.nodes[new_node_index].neighbor_next = node_neighbor_next;
            self.nodes[node_index].neighbor_next = new_node_index;
        }

        return .{ .offset = node_data_offset, .metadata = node_index };
    }

    pub fn free(self: *Self, allocation: Allocation) void {
        std.debug.assert(allocation.metadata != Allocation.no_space);
        if (self.nodes.len == 0) return;

        const node_index = allocation.metadata;
        std.debug.assert(self.nodes[node_index].used);

        var offset = self.nodes[node_index].data_offset;
        var sz = self.nodes[node_index].data_size;

        // Coalesce with previous neighbor if it's free.
        const prev_neighbor = self.nodes[node_index].neighbor_prev;
        if (prev_neighbor != Node.unused and !self.nodes[prev_neighbor].used) {
            offset = self.nodes[prev_neighbor].data_offset;
            sz += self.nodes[prev_neighbor].data_size;

            self.removeNodeFromBin(prev_neighbor);

            std.debug.assert(self.nodes[prev_neighbor].neighbor_next == node_index);
            self.nodes[node_index].neighbor_prev = self.nodes[prev_neighbor].neighbor_prev;
        }

        // Coalesce with next neighbor if it's free.
        const next_neighbor = self.nodes[node_index].neighbor_next;
        if (next_neighbor != Node.unused and !self.nodes[next_neighbor].used) {
            sz += self.nodes[next_neighbor].data_size;

            self.removeNodeFromBin(next_neighbor);

            std.debug.assert(self.nodes[next_neighbor].neighbor_prev == node_index);
            self.nodes[node_index].neighbor_next = self.nodes[next_neighbor].neighbor_next;
        }

        const final_neighbor_next = self.nodes[node_index].neighbor_next;
        const final_neighbor_prev = self.nodes[node_index].neighbor_prev;

        // Return the freed node to the freelist.
        self.free_offset += 1;
        self.free_nodes[self.free_offset] = node_index;

        // Re-insert the (possibly coalesced) free range as a new bin node.
        const combined_node_index = self.insertNodeIntoBin(sz, offset);

        if (final_neighbor_next != Node.unused) {
            self.nodes[combined_node_index].neighbor_next = final_neighbor_next;
            self.nodes[final_neighbor_next].neighbor_prev = combined_node_index;
        }
        if (final_neighbor_prev != Node.unused) {
            self.nodes[combined_node_index].neighbor_prev = final_neighbor_prev;
            self.nodes[final_neighbor_prev].neighbor_next = combined_node_index;
        }
    }

    fn insertNodeIntoBin(self: *Self, sz: u32, data_offset: u32) u32 {
        // Round down: pick the largest bin that the size is still guaranteed
        // to satisfy (so any allocation rounded *up* into this bin will fit).
        const bin_index = SmallFloat.uintToFloatRoundDown(sz);

        const top_bin_index = bin_index >> top_bins_index_shift;
        const leaf_bin_index = bin_index & leaf_bins_index_mask;

        if (self.bin_indices[bin_index] == Node.unused) {
            self.used_bins[top_bin_index] |= @as(u8, 1) << @intCast(leaf_bin_index);
            self.used_bins_top |= @as(u32, 1) << @intCast(top_bin_index);
        }

        const top_node_index = self.bin_indices[bin_index];
        const node_index = self.free_nodes[self.free_offset];
        // `-%=` matches the C wrap-around. The `free_offset == 0` guard in
        // `allocate` prevents this from being read back as an OOB index.
        self.free_offset -%= 1;

        self.nodes[node_index] = .{
            .data_offset = data_offset,
            .data_size = sz,
            .bin_list_next = top_node_index,
        };
        if (top_node_index != Node.unused)
            self.nodes[top_node_index].bin_list_prev = node_index;
        self.bin_indices[bin_index] = node_index;

        self.free_storage += sz;
        return node_index;
    }

    fn removeNodeFromBin(self: *Self, node_index: u32) void {
        const node_data_size = self.nodes[node_index].data_size;
        const node_bin_prev = self.nodes[node_index].bin_list_prev;
        const node_bin_next = self.nodes[node_index].bin_list_next;

        if (node_bin_prev != Node.unused) {
            // Middle of a bin's linked list — just unlink.
            self.nodes[node_bin_prev].bin_list_next = node_bin_next;
            if (node_bin_next != Node.unused)
                self.nodes[node_bin_next].bin_list_prev = node_bin_prev;
        } else {
            // Head of the list — also has to update bin-occupancy bitmasks.
            const bin_index = SmallFloat.uintToFloatRoundDown(node_data_size);
            const top_bin_index = bin_index >> top_bins_index_shift;
            const leaf_bin_index = bin_index & leaf_bins_index_mask;

            self.bin_indices[bin_index] = node_bin_next;
            if (node_bin_next != Node.unused)
                self.nodes[node_bin_next].bin_list_prev = Node.unused;

            if (self.bin_indices[bin_index] == Node.unused) {
                self.used_bins[top_bin_index] &= ~(@as(u8, 1) << @intCast(leaf_bin_index));
                if (self.used_bins[top_bin_index] == 0) {
                    self.used_bins_top &= ~(@as(u32, 1) << @intCast(top_bin_index));
                }
            }
        }

        self.free_offset += 1;
        self.free_nodes[self.free_offset] = node_index;
        self.free_storage -= node_data_size;
    }

    pub fn allocationSize(self: *const Self, allocation: Allocation) u32 {
        if (allocation.metadata == Allocation.no_space) return 0;
        if (self.nodes.len == 0) return 0;
        return self.nodes[allocation.metadata].data_size;
    }

    pub fn storageReport(self: *const Self) StorageReport {
        var largest_free_region: u32 = 0;
        var free_storage: u32 = 0;

        if (self.free_offset > 0) {
            free_storage = self.free_storage;
            if (self.used_bins_top != 0) {
                const top_bin_index: u32 = 31 - @clz(self.used_bins_top);
                const leaf_bin_index: u32 = 31 - @clz(@as(u32, self.used_bins[top_bin_index]));
                largest_free_region = SmallFloat.floatToUint(
                    (top_bin_index << top_bins_index_shift) | leaf_bin_index,
                );
                std.debug.assert(free_storage >= largest_free_region);
            }
        }

        return .{ .total_free_space = free_storage, .largest_free_region = largest_free_region };
    }

    pub fn storageReportFull(self: *const Self) StorageReportFull {
        var report: StorageReportFull = undefined;
        var i: u32 = 0;
        while (i < num_leaf_bins) : (i += 1) {
            var count: u32 = 0;
            var node_index = self.bin_indices[i];
            while (node_index != Node.unused) {
                node_index = self.nodes[node_index].bin_list_next;
                count += 1;
            }
            report.free_regions[i] = .{ .size = SmallFloat.floatToUint(i), .count = count };
        }
        return report;
    }
};

// ---------------------------------------------------------------------------
// Tests (ported from offsetAllocatorTests.cpp)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "SmallFloat uintToFloat" {
    // Denorms, exp=1 and exp=2 + mantissa = 0 are precise (3-bit mantissa).
    const precise_count: u32 = 17;
    var i: u32 = 0;
    while (i < precise_count) : (i += 1) {
        try testing.expectEqual(i, SmallFloat.uintToFloatRoundUp(i));
        try testing.expectEqual(i, SmallFloat.uintToFloatRoundDown(i));
    }

    const Case = struct { number: u32, up: u32, down: u32 };
    const cases = [_]Case{
        .{ .number = 17, .up = 17, .down = 16 },
        .{ .number = 118, .up = 39, .down = 38 },
        .{ .number = 1024, .up = 64, .down = 64 },
        .{ .number = 65536, .up = 112, .down = 112 },
        .{ .number = 529445, .up = 137, .down = 136 },
        .{ .number = 1048575, .up = 144, .down = 143 },
    };
    for (cases) |c| {
        try testing.expectEqual(c.up, SmallFloat.uintToFloatRoundUp(c.number));
        try testing.expectEqual(c.down, SmallFloat.uintToFloatRoundDown(c.number));
    }
}

test "SmallFloat floatToUint" {
    const precise_count: u32 = 17;
    var i: u32 = 0;
    while (i < precise_count) : (i += 1) {
        try testing.expectEqual(i, SmallFloat.floatToUint(i));
    }

    // float→uint→float must be lossless for all values in this range.
    // Values >= 240 overflow u32.
    i = 0;
    while (i < 240) : (i += 1) {
        const v = SmallFloat.floatToUint(i);
        try testing.expectEqual(i, SmallFloat.uintToFloatRoundUp(v));
        try testing.expectEqual(i, SmallFloat.uintToFloatRoundDown(v));
    }
}

test "OffsetAllocator basic" {
    var allocator = try Allocator.init(testing.allocator, 1024 * 1024 * 256, 128 * 1024);
    defer allocator.deinit();

    const a = allocator.allocate(1337);
    try testing.expectEqual(@as(u32, 0), a.offset);
    allocator.free(a);
}

test "OffsetAllocator allocate simple" {
    var allocator = try Allocator.init(testing.allocator, 1024 * 1024 * 256, 128 * 1024);
    defer allocator.deinit();

    const a = allocator.allocate(0);
    try testing.expectEqual(@as(u32, 0), a.offset);

    const b = allocator.allocate(1);
    try testing.expectEqual(@as(u32, 0), b.offset);

    const c = allocator.allocate(123);
    try testing.expectEqual(@as(u32, 1), c.offset);

    const d = allocator.allocate(1234);
    try testing.expectEqual(@as(u32, 124), d.offset);

    allocator.free(a);
    allocator.free(b);
    allocator.free(c);
    allocator.free(d);

    const validate_all = allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(@as(u32, 0), validate_all.offset);
    allocator.free(validate_all);
}

test "OffsetAllocator merge trivial" {
    var allocator = try Allocator.init(testing.allocator, 1024 * 1024 * 256, 128 * 1024);
    defer allocator.deinit();

    const a = allocator.allocate(1337);
    try testing.expectEqual(@as(u32, 0), a.offset);
    allocator.free(a);

    const b = allocator.allocate(1337);
    try testing.expectEqual(@as(u32, 0), b.offset);
    allocator.free(b);

    const validate_all = allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(@as(u32, 0), validate_all.offset);
    allocator.free(validate_all);
}

test "OffsetAllocator reuse trivial" {
    var allocator = try Allocator.init(testing.allocator, 1024 * 1024 * 256, 128 * 1024);
    defer allocator.deinit();

    const a = allocator.allocate(1024);
    try testing.expectEqual(@as(u32, 0), a.offset);

    const b = allocator.allocate(3456);
    try testing.expectEqual(@as(u32, 1024), b.offset);

    allocator.free(a);

    const c = allocator.allocate(1024);
    try testing.expectEqual(@as(u32, 0), c.offset);

    allocator.free(c);
    allocator.free(b);

    const validate_all = allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(@as(u32, 0), validate_all.offset);
    allocator.free(validate_all);
}

test "OffsetAllocator reuse complex" {
    var allocator = try Allocator.init(testing.allocator, 1024 * 1024 * 256, 128 * 1024);
    defer allocator.deinit();

    const a = allocator.allocate(1024);
    try testing.expectEqual(@as(u32, 0), a.offset);

    const b = allocator.allocate(3456);
    try testing.expectEqual(@as(u32, 1024), b.offset);

    allocator.free(a);

    const c = allocator.allocate(2345);
    try testing.expectEqual(@as(u32, 1024 + 3456), c.offset);

    const d = allocator.allocate(456);
    try testing.expectEqual(@as(u32, 0), d.offset);

    const e = allocator.allocate(512);
    try testing.expectEqual(@as(u32, 456), e.offset);

    const report = allocator.storageReport();
    try testing.expectEqual(@as(u32, 1024 * 1024 * 256 - 3456 - 2345 - 456 - 512), report.total_free_space);
    try testing.expect(report.largest_free_region != report.total_free_space);

    allocator.free(c);
    allocator.free(d);
    allocator.free(b);
    allocator.free(e);

    const validate_all = allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(@as(u32, 0), validate_all.offset);
    allocator.free(validate_all);
}

test "OffsetAllocator zero fragmentation" {
    var allocator = try Allocator.init(testing.allocator, 1024 * 1024 * 256, 128 * 1024);
    defer allocator.deinit();

    var allocations: [256]Allocation = undefined;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        allocations[i] = allocator.allocate(1024 * 1024);
        try testing.expectEqual(@as(u32, i * 1024 * 1024), allocations[i].offset);
    }

    {
        const report = allocator.storageReport();
        try testing.expectEqual(@as(u32, 0), report.total_free_space);
        try testing.expectEqual(@as(u32, 0), report.largest_free_region);
    }

    // Free four random slots.
    allocator.free(allocations[243]);
    allocator.free(allocations[5]);
    allocator.free(allocations[123]);
    allocator.free(allocations[95]);

    // Free four contiguous slots — allocator must coalesce.
    allocator.free(allocations[151]);
    allocator.free(allocations[152]);
    allocator.free(allocations[153]);
    allocator.free(allocations[154]);

    allocations[243] = allocator.allocate(1024 * 1024);
    allocations[5] = allocator.allocate(1024 * 1024);
    allocations[123] = allocator.allocate(1024 * 1024);
    allocations[95] = allocator.allocate(1024 * 1024);
    allocations[151] = allocator.allocate(1024 * 1024 * 4); // 4x larger
    try testing.expect(allocations[243].offset != Allocation.no_space);
    try testing.expect(allocations[5].offset != Allocation.no_space);
    try testing.expect(allocations[123].offset != Allocation.no_space);
    try testing.expect(allocations[95].offset != Allocation.no_space);
    try testing.expect(allocations[151].offset != Allocation.no_space);

    i = 0;
    while (i < 256) : (i += 1) {
        if (i < 152 or i > 154) allocator.free(allocations[i]);
    }

    {
        const report = allocator.storageReport();
        try testing.expectEqual(@as(u32, 1024 * 1024 * 256), report.total_free_space);
        try testing.expectEqual(@as(u32, 1024 * 1024 * 256), report.largest_free_region);
    }

    const validate_all = allocator.allocate(1024 * 1024 * 256);
    try testing.expectEqual(@as(u32, 0), validate_all.offset);
    allocator.free(validate_all);
}
