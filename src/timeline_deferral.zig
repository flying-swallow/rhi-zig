// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Per-frame deferred-release helper for the RHI.
//!
//! While a frame records work you *mark* (reference) every resource it touches
//! with `enqueue`, so nothing is discarded while the GPU is still reading it.
//! `seal` closes the frame, tagging its marked items with the timeline value at
//! which the GPU will be finished. Once that value has passed, `drain` releases
//! (derefs) every item belonging to completed frames, oldest first — letting a
//! finished frame discard its resources as quickly as possible.
//!
//! `items` is a FIFO of every marked item; `batches` is the bookkeeping that
//! records, per sealed frame, its timeline value and how many items it owns.

const std = @import("std");

pub const Batch = struct {
    value: u64,
    len: usize,
};

/// Union field / enum tag name for the i-th supported type.
fn fieldName(comptime i: usize) [:0]const u8 {
    return std.fmt.comptimePrint("f{d}", .{i});
}

pub fn TimelineDeferral(comptime supported: []const type) type {
    // Build a tagged union over the supported item types so a single FIFO can
    // hold heterogeneous resources, each released through its own `deref`.
    const Target = build: {
        const TagInt = std.math.IntFittingRange(0, if (supported.len == 0) 0 else supported.len - 1);
        var names: [supported.len][:0]const u8 = undefined;
        var values: [supported.len]TagInt = undefined;
        var types: [supported.len]type = undefined;
        inline for (supported, 0..) |T, i| {
            names[i] = fieldName(i);
            values[i] = @intCast(i);
            types[i] = T;
        }
        const Tag = @Enum(TagInt, .exhaustive, &names, &values);
        break :build @Union(.auto, Tag, &names, &types, &@splat(.{}));
    };

    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        batches: std.ArrayList(Batch) = .empty,
        items: std.Deque(Target) = .empty,
        /// Items enqueued since the last `seal`, waiting to be batched.
        pending: usize = 0,

        /// Comptime index of `T` within `supported`.
        fn indexOf(comptime T: type) usize {
            inline for (supported, 0..) |S, i| {
                if (S == T) return i;
            }
            @compileError("TimelineDeferral: unsupported item type " ++ @typeName(T));
        }

        fn derefEntry(entry: Target) void {
            switch (entry) {
                inline else => |payload| payload.deref(),
            }
        }

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.batches.deinit(self.gpa);
            self.items.deinit(self.gpa);
        }

        /// Mark `item` as in use for the current (unsealed) frame.
        pub fn enqueue(self: *Self, item: anytype) !void {
            const name = comptime fieldName(indexOf(@TypeOf(item)));
            item.ref();
            try self.items.pushBack(self.gpa, @unionInit(Target, name, item));
            self.pending += 1;
        }

        /// Close the current frame, tagging its marked items with the timeline
        /// `value` at which the GPU will be finished with them. Sealing with
        /// nothing pending is a no-op.
        pub fn seal(self: *Self, value: u64) !void {
            if (self.pending == 0) return;
            try self.batches.append(self.gpa, .{ .value = value, .len = self.pending });
            self.pending = 0;
        }

        /// Release every item belonging to a frame whose timeline value has
        /// passed (`batch.value <= value`), oldest first.
        pub fn drain(self: *Self, value: u64) void {
            var drained: usize = 0;
            while (drained < self.batches.items.len) {
                const batch = self.batches.items[drained];
                if (batch.value > value) break;
                var n: usize = 0;
                while (n < batch.len) : (n += 1) {
                    derefEntry(self.items.popFront().?);
                }
                drained += 1;
            }
            if (drained > 0) {
                const remaining = self.batches.items.len - drained;
                std.mem.copyForwards(Batch, self.batches.items[0..remaining], self.batches.items[drained..]);
                self.batches.shrinkRetainingCapacity(remaining);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Resource = struct {
    refs: i32 = 0,
    fn ref(self: *Resource) void {
        self.refs += 1;
    }
    fn deref(self: *Resource) void {
        self.refs -= 1;
    }
};

test "TimelineDeferral drains marked items when their frame completes" {
    var td = TimelineDeferral(&.{*Resource}).init(testing.allocator);
    defer td.deinit();

    var a = Resource{};
    var b = Resource{};
    var c = Resource{};

    // Frame 0 uses a and b, completing at timeline value 1.
    try td.enqueue(&a);
    try td.enqueue(&b);
    try td.seal(1);

    // Frame 1 uses c, completing at timeline value 2.
    try td.enqueue(&c);
    try td.seal(2);

    // Everything is marked while its frame is still in flight.
    try testing.expectEqual(@as(i32, 1), a.refs);
    try testing.expectEqual(@as(i32, 1), b.refs);
    try testing.expectEqual(@as(i32, 1), c.refs);

    // GPU has passed timeline value 1: frame 0's items are released, c stays.
    td.drain(1);
    try testing.expectEqual(@as(i32, 0), a.refs);
    try testing.expectEqual(@as(i32, 0), b.refs);
    try testing.expectEqual(@as(i32, 1), c.refs);
    try testing.expectEqual(@as(usize, 1), td.items.len);
    try testing.expectEqual(@as(usize, 1), td.batches.items.len);

    // Timeline value 2: c is released too, everything drains.
    td.drain(2);
    try testing.expectEqual(@as(i32, 0), c.refs);
    try testing.expectEqual(@as(usize, 0), td.items.len);
    try testing.expectEqual(@as(usize, 0), td.batches.items.len);
}

test "TimelineDeferral drain below the earliest batch is a no-op" {
    var td = TimelineDeferral(&.{*Resource}).init(testing.allocator);
    defer td.deinit();

    var a = Resource{};
    var b = Resource{};
    try td.enqueue(&a);
    try td.enqueue(&b);
    try td.seal(5);

    // The GPU hasn't reached value 5 yet, so nothing may be released.
    td.drain(4);
    try testing.expectEqual(@as(i32, 1), a.refs);
    try testing.expectEqual(@as(i32, 1), b.refs);
    try testing.expectEqual(@as(usize, 2), td.items.len);
    try testing.expectEqual(@as(usize, 1), td.batches.items.len);
}

test "TimelineDeferral releases every type in a heterogeneous union" {
    const A = struct {
        refs: i32 = 0,
        fn ref(self: *@This()) void {
            self.refs += 1;
        }
        fn deref(self: *@This()) void {
            self.refs -= 1;
        }
    };
    const B = struct {
        refs: i32 = 0,
        fn ref(self: *@This()) void {
            self.refs += 1;
        }
        fn deref(self: *@This()) void {
            self.refs -= 1;
        }
    };

    var td = TimelineDeferral(&.{ *A, *B }).init(testing.allocator);
    defer td.deinit();

    var a = A{};
    var b = B{};
    try td.enqueue(&a);
    try td.enqueue(&b);
    try td.seal(1);

    try testing.expectEqual(@as(i32, 1), a.refs);
    try testing.expectEqual(@as(i32, 1), b.refs);

    // The `inline else` switch must dispatch deref for both union tags.
    td.drain(1);
    try testing.expectEqual(@as(i32, 0), a.refs);
    try testing.expectEqual(@as(i32, 0), b.refs);
    try testing.expectEqual(@as(usize, 0), td.items.len);
}
