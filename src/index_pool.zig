// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! A pool of unique u32 IDs.
//!
//! Hands out IDs from a fixed-size reserved range and accepts them back.
//! The free set is stored as a sorted list of inclusive `[start, end]`
//! ranges; returns coalesce with adjacent ranges so that the metadata
//! stays compact even after long allocate/free histories.
//!
//! Ported from the C++ `hpl::IndexPool` in HPL2 (Amnesia64). The original
//! had an asymmetric coalescing bug and missed some merges on insert;
//! both are fixed here.

const std = @import("std");

pub const invalid_index: u32 = std.math.maxInt(u32);

const IdRange = struct {
    start: u32,
    end: u32,
};

pub const IndexPool = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    available: std.ArrayList(IdRange),

    /// Reserve IDs `[0, reserve)`. `reserve` must be > 0.
    pub fn init(allocator: std.mem.Allocator, reserve: u32) !Self {
        std.debug.assert(reserve > 0);
        var available: std.ArrayList(IdRange) = .empty;
        try available.append(allocator, .{ .start = 0, .end = reserve - 1 });
        return .{ .gpa = allocator, .available = available };
    }

    pub fn deinit(self: *Self) void {
        self.available.deinit(self.gpa);
    }

    /// Pop the highest free ID. Returns null when the pool is empty.
    pub fn requestId(self: *Self) ?u32 {
        if (self.available.items.len == 0) return null;
        const entry = &self.available.items[self.available.items.len - 1];
        if (entry.end == entry.start) {
            const res = entry.start;
            _ = self.available.pop();
            return res;
        }
        const res = entry.end;
        entry.end -= 1;
        return res;
    }

    /// Reset to a single range `[0, max_end_seen]`, where `max_end_seen` is
    /// the highest range endpoint currently in the free list.
    pub fn reset(self: *Self) void {
        var max: u32 = 0;
        for (self.available.items) |entry| {
            if (entry.end > max) max = entry.end;
        }
        self.available.clearRetainingCapacity();
        // Capacity is preserved by clearRetainingCapacity, and was >= 1 from init.
        self.available.appendAssumeCapacity(.{ .start = 0, .end = max });
    }

    /// Reset to a single range `[0, reserve)`. `reserve` must be > 0.
    pub fn resetToReserved(self: *Self, reserve: u32) void {
        std.debug.assert(reserve > 0);
        self.available.clearRetainingCapacity();
        self.available.appendAssumeCapacity(.{ .start = 0, .end = reserve - 1 });
    }

    /// Return a previously-requested ID to the pool.
    /// Asserts in debug if the ID is already free.
    pub fn returnId(self: *Self, index: u32) !void {
        // Binary search: smallest i such that available[i].start > index,
        // or items.len if no such i exists.
        const items = self.available.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].start > index) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        const insert_at = lo;

        // The candidate neighbors are insert_at - 1 (prev) and insert_at (next).
        const has_prev = insert_at > 0;
        const has_next = insert_at < items.len;

        // Duplicate-return detection.
        if (has_prev) std.debug.assert(items[insert_at - 1].end < index);
        if (has_next) std.debug.assert(items[insert_at].start > index);

        const prev_adj = has_prev and items[insert_at - 1].end + 1 == index;
        const next_adj = has_next and items[insert_at].start == index + 1;

        if (prev_adj and next_adj) {
            // Merge prev and next into a single range.
            items[insert_at - 1].end = items[insert_at].end;
            _ = self.available.orderedRemove(insert_at);
        } else if (prev_adj) {
            items[insert_at - 1].end = index;
        } else if (next_adj) {
            items[insert_at].start = index;
        } else {
            try self.available.insert(self.gpa, insert_at, .{ .start = index, .end = index });
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "IndexPool basic request and exhaust" {
    var pool = try IndexPool.init(testing.allocator, 4);
    defer pool.deinit();

    try testing.expectEqual(@as(?u32, 3), pool.requestId());
    try testing.expectEqual(@as(?u32, 2), pool.requestId());
    try testing.expectEqual(@as(?u32, 1), pool.requestId());
    try testing.expectEqual(@as(?u32, 0), pool.requestId());
    try testing.expectEqual(@as(?u32, null), pool.requestId());
}

test "IndexPool return coalesces with previous" {
    var pool = try IndexPool.init(testing.allocator, 8);
    defer pool.deinit();

    // Drain everything.
    var i: u32 = 0;
    while (i < 8) : (i += 1) _ = pool.requestId();
    try testing.expectEqual(@as(?u32, null), pool.requestId());

    // Return in ascending order — should coalesce into one range.
    try pool.returnId(0);
    try pool.returnId(1);
    try pool.returnId(2);
    try testing.expectEqual(@as(usize, 1), pool.available.items.len);
    try testing.expectEqual(@as(u32, 0), pool.available.items[0].start);
    try testing.expectEqual(@as(u32, 2), pool.available.items[0].end);
}

test "IndexPool return coalesces with next" {
    var pool = try IndexPool.init(testing.allocator, 8);
    defer pool.deinit();

    var i: u32 = 0;
    while (i < 8) : (i += 1) _ = pool.requestId();

    // Return in descending order — should coalesce into one range.
    try pool.returnId(7);
    try pool.returnId(6);
    try pool.returnId(5);
    try testing.expectEqual(@as(usize, 1), pool.available.items.len);
    try testing.expectEqual(@as(u32, 5), pool.available.items[0].start);
    try testing.expectEqual(@as(u32, 7), pool.available.items[0].end);
}

test "IndexPool return bridges two ranges" {
    var pool = try IndexPool.init(testing.allocator, 8);
    defer pool.deinit();

    var i: u32 = 0;
    while (i < 8) : (i += 1) _ = pool.requestId();

    // Build the free list as two disjoint ranges: [0,2] and [4,6].
    try pool.returnId(0);
    try pool.returnId(1);
    try pool.returnId(2);
    try pool.returnId(4);
    try pool.returnId(5);
    try pool.returnId(6);
    try testing.expectEqual(@as(usize, 2), pool.available.items.len);

    // Returning 3 should bridge the two ranges.
    try pool.returnId(3);
    try testing.expectEqual(@as(usize, 1), pool.available.items.len);
    try testing.expectEqual(@as(u32, 0), pool.available.items[0].start);
    try testing.expectEqual(@as(u32, 6), pool.available.items[0].end);
}

test "IndexPool isolated returns produce separate ranges" {
    var pool = try IndexPool.init(testing.allocator, 16);
    defer pool.deinit();

    var i: u32 = 0;
    while (i < 16) : (i += 1) _ = pool.requestId();

    try pool.returnId(2);
    try pool.returnId(7);
    try pool.returnId(12);

    try testing.expectEqual(@as(usize, 3), pool.available.items.len);
    try testing.expectEqual(@as(u32, 2), pool.available.items[0].start);
    try testing.expectEqual(@as(u32, 2), pool.available.items[0].end);
    try testing.expectEqual(@as(u32, 7), pool.available.items[1].start);
    try testing.expectEqual(@as(u32, 7), pool.available.items[1].end);
    try testing.expectEqual(@as(u32, 12), pool.available.items[2].start);
    try testing.expectEqual(@as(u32, 12), pool.available.items[2].end);
}

test "IndexPool resetToReserved" {
    var pool = try IndexPool.init(testing.allocator, 4);
    defer pool.deinit();

    _ = pool.requestId();
    _ = pool.requestId();
    pool.resetToReserved(8);

    try testing.expectEqual(@as(usize, 1), pool.available.items.len);
    try testing.expectEqual(@as(u32, 0), pool.available.items[0].start);
    try testing.expectEqual(@as(u32, 7), pool.available.items[0].end);
}

test "IndexPool request after return reuses returned id" {
    var pool = try IndexPool.init(testing.allocator, 4);
    defer pool.deinit();

    const a = pool.requestId().?;
    const b = pool.requestId().?;
    try pool.returnId(a);
    const c = pool.requestId().?;
    // a was the highest; after return it sits at the end of the free list,
    // so requestId pops it first.
    try testing.expectEqual(a, c);
    _ = b;
}

test "IndexPool stress: round-trip preserves uniqueness" {
    const N: u32 = 1024;
    var pool = try IndexPool.init(testing.allocator, N);
    defer pool.deinit();

    var seen = try testing.allocator.alloc(bool, N);
    defer testing.allocator.free(seen);
    @memset(seen, false);

    var handed_out: [N]u32 = undefined;
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        const id = pool.requestId().?;
        try testing.expect(id < N);
        try testing.expect(!seen[id]);
        seen[id] = true;
        handed_out[i] = id;
    }
    try testing.expectEqual(@as(?u32, null), pool.requestId());

    // Return everything in a scrambled order.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    rand.shuffle(u32, &handed_out);
    for (handed_out) |id| try pool.returnId(id);

    // Free list should have collapsed back to a single full range.
    try testing.expectEqual(@as(usize, 1), pool.available.items.len);
    try testing.expectEqual(@as(u32, 0), pool.available.items[0].start);
    try testing.expectEqual(@as(u32, N - 1), pool.available.items[0].end);
}
