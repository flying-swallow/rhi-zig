const std = @import("std");
const rhi = @import("root.zig");

/// Where a `GPURef` box lives. `inline` is a keyword, so the non-heap policy is
/// named `.embedded` (the ref-counted value lives inside its owner / a pool slot).
pub const Storage = enum { heap, embedded };

/// Reference-counted wrapper around a GPU resource `T`.
///
/// `storage` selects, at comptime, who owns the box's memory:
///   - `.heap`     — `create` allocates the box and the final `deref` frees it.
///   - `.embedded` — `init` builds it by value; the owner (stack, struct field,
///                   pool block) owns the memory and the final `deref` frees nothing.
///
/// In both cases the refcount starts at 1 (the creator holds a reference) and the
/// final `deref` calls `inner.deinit(device)` to release the GPU resource.
/// `ref()`/`deref()` are zero-arg so instances flow through `TimelineDeferral`.
pub fn GPURef(comptime T: type, comptime storage: Storage) type {
    return switch (storage) {
        .heap => struct {
            const Self = @This();

            references: std.atomic.Value(u32) = .init(1),
            inner: T,
            device: *rhi.Device,
            alloc: std.mem.Allocator,

            /// Heap-allocate a box. Refcount starts at 1.
            pub fn create(gpa: std.mem.Allocator, device: *rhi.Device, value: T) !*Self {
                const self = try gpa.create(Self);
                self.* = .{ .inner = value, .device = device, .alloc = gpa };
                return self;
            }

            /// Whether any reference is still outstanding.
            pub fn hasRef(self: *Self) bool {
                return self.references.load(.monotonic) > 0;
            }

            pub fn ref(self: *Self) void {
                _ = self.references.fetchAdd(1, .monotonic);
            }

            pub fn deref(self: *Self) void {
                if (self.references.fetchSub(1, .acq_rel) == 1) self.finalize();
            }

            fn finalize(self: *Self) void {
                self.inner.deinit(self.device);
                self.alloc.destroy(self);
            }
        },
        .embedded => struct {
            const Self = @This();

            references: std.atomic.Value(u32) = .init(1),
            inner: T,
            device: *rhi.Device,

            /// Construct by value, no allocation. Refcount starts at 1.
            /// Must live at a stable address once shared: place it, then only
            /// ref()/deref() through a pointer — never copy it after the first ref.
            pub fn init(device: *rhi.Device, value: T) Self {
                return .{ .inner = value, .device = device };
            }

            /// Whether any reference is still outstanding.
            pub fn hasRef(self: *Self) bool {
                return self.references.load(.monotonic) > 0;
            }

            pub fn ref(self: *Self) void {
                _ = self.references.fetchAdd(1, .monotonic);
            }

            pub fn deref(self: *Self) void {
                if (self.references.fetchSub(1, .acq_rel) == 1) self.finalize();
            }

            fn finalize(self: *Self) void {
                self.inner.deinit(self.device);
            }
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fake = struct {
    destroyed: *u32,
    fn deinit(self: *Fake, _: *rhi.Device) void {
        self.destroyed.* += 1;
    }
};

test "GPURef .heap: final deref finalizes inner and frees the box" {
    var dev: rhi.Device = undefined; // valid address; contents never read
    const device = &dev;
    var destroyed: u32 = 0;

    const R = GPURef(Fake, .heap);
    const r = try R.create(testing.allocator, device, .{ .destroyed = &destroyed });
    try testing.expectEqual(@as(u32, 1), r.references.load(.monotonic));

    r.ref();
    try testing.expectEqual(@as(u32, 2), r.references.load(.monotonic));

    r.deref(); // 2 -> 1, still alive
    try testing.expectEqual(@as(u32, 0), destroyed);

    r.deref(); // 1 -> 0, inner finalized + box freed (testing.allocator leak-checks the free)
    try testing.expectEqual(@as(u32, 1), destroyed);
}

test "GPURef .embedded: final deref finalizes inner without freeing" {
    var dev: rhi.Device = undefined;
    const device = &dev;
    var destroyed: u32 = 0;

    var slot: GPURef(Fake, .embedded) = .init(device, .{ .destroyed = &destroyed });
    try testing.expectEqual(@as(u32, 1), slot.references.load(.monotonic));

    slot.ref(); // 2
    slot.deref(); // 1
    try testing.expectEqual(@as(u32, 0), destroyed);

    slot.deref(); // 0 -> finalize inner; no allocation to free (stack memory)
    try testing.expectEqual(@as(u32, 1), destroyed);
}

test "GPURef .heap flows through TimelineDeferral; drain alone does not destroy" {
    var dev: rhi.Device = undefined;
    const device = &dev;
    var destroyed: u32 = 0;

    const R = GPURef(Fake, .heap);
    const r = try R.create(testing.allocator, device, .{ .destroyed = &destroyed });

    var td = rhi.timline_deferral.TimelineDeferral(&.{*R}).init(testing.allocator);
    defer td.deinit();

    try td.enqueue(r); // ref -> 2
    try td.seal(1);

    td.drain(1); // deref -> 1: the creator still holds a reference, so not destroyed
    try testing.expectEqual(@as(u32, 0), destroyed);

    r.deref(); // creator releases -> 0 -> destroyed
    try testing.expectEqual(@as(u32, 1), destroyed);
}
