// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const std = @import("std");

pub const max_segments: usize = 8;

pub const Desc = struct {
    max_elements: u32,
    element_stride: u16,
    num_segments: u16,
};

pub const Req = struct {
    element_stride: u16,
    element_offset: u32,
    num_elements: u32,
};

const SegmentEntry = struct {
    frame_num: u64 = 0,
    num_elements: usize = 0,
};

/// A ring-buffer segment allocator that tracks per-frame ownership of element ranges.
///
/// Elements are sub-allocated linearly from a fixed-size ring buffer. Each frame
/// is tracked as a named segment; segments are reclaimed once they are more than
/// `num_segments` frames old, freeing their element range for reuse.
pub const SegmentAlloc = struct {
    const Self = @This();

    element_stride: u16,
    num_segments: u16,
    max_elements: u32,

    tail: u8,
    head: u8,
    elements_consumed: usize,
    element_offset: usize,
    segment: [max_segments]SegmentEntry,

    pub fn init(desc: Desc) Self {
        std.debug.assert(desc.num_segments < max_segments);
        std.debug.assert(desc.element_stride > 0);
        return .{
            .element_stride = desc.element_stride,
            .num_segments = desc.num_segments,
            .max_elements = desc.max_elements,
            .tail = 0,
            .head = 1,
            .elements_consumed = 0,
            .element_offset = 0,
            .segment = std.mem.zeroes([max_segments]SegmentEntry),
        };
    }

    /// Sub-allocate `num_elements` elements for `frame_index`.
    ///
    /// Returns null if there is not enough free space in the ring buffer.
    /// On a new frame index the head segment is advanced automatically.
    /// Old segments whose frame number is more than `num_segments` frames
    /// behind `frame_index` are reclaimed before the allocation is attempted.
    pub fn alloc(self: *Self, frame_index: u64, num_elements: usize) ?Req {
        const max: usize = self.max_elements;

        // Reclaim segments that are old enough.
        while (self.tail != self.head and
            frame_index >= self.segment[self.tail].frame_num + self.num_segments)
        {
            std.debug.assert(self.elements_consumed >= self.segment[self.tail].num_elements);
            self.elements_consumed -= self.segment[self.tail].num_elements;
            self.segment[self.tail] = .{};
            self.tail = @intCast((self.tail + 1) % max_segments);
        }

        // New frame — advance head.
        if (frame_index != self.segment[self.head].frame_num) {
            self.head = @intCast((self.head + 1) % max_segments);
            self.segment[self.head] = .{ .frame_num = frame_index };
            std.debug.assert(self.head != self.tail);
        }

        std.debug.assert(self.element_offset <= max);

        // Not enough total free space.
        if (max - self.elements_consumed < num_elements) {
            return null;
        }

        // Try to fit linearly from the current write cursor.
        if (self.element_offset + num_elements <= max) {
            const req = Req{
                .element_offset = @intCast(self.element_offset),
                .element_stride = self.element_stride,
                .num_elements = @intCast(num_elements),
            };
            self.element_offset += num_elements;
            self.elements_consumed += num_elements;
            self.segment[self.head].num_elements += num_elements;
            return req;
        }

        // Doesn't fit at the end — wrap around to offset 0.
        // The skipped tail padding is charged to the current segment so that
        // reclaim accounts for it when the segment is eventually freed.
        const tail_remainder = max - self.element_offset;
        if (max - (self.elements_consumed + tail_remainder) >= num_elements) {
            self.segment[self.head].num_elements += tail_remainder;
            self.elements_consumed += tail_remainder;

            const req = Req{
                .element_offset = 0,
                .element_stride = self.element_stride,
                .num_elements = @intCast(num_elements),
            };
            self.element_offset = num_elements;
            self.elements_consumed += num_elements;
            self.segment[self.head].num_elements += num_elements;
            return req;
        }

        return null;
    }
};

pub inline fn is_continuous(current_offset: usize, current_num_elements: usize, next_offset: usize) bool {
    return current_offset + current_num_elements == next_offset;
}

test "alloc wraps when the write cursor lands exactly on max_elements" {
    const testing = std.testing;
    // max = 8 with 2 elements per frame walks the cursor 0 -> 2 -> 4 -> 6 -> 8.
    // num_segments = 3 keeps enough history reclaimed that the ring never fills,
    // so frame 3's perfect tail fit leaves element_offset == max (the state that
    // previously tripped the `element_offset < max` assertion), and frame 4 must
    // wrap cleanly to offset 0.
    var seg = SegmentAlloc.init(.{ .max_elements = 8, .element_stride = 4, .num_segments = 3 });

    const expected_offsets = [_]u32{ 0, 2, 4, 6 };
    for (0..4) |frame| {
        const req = seg.alloc(@intCast(frame), 2) orelse return error.UnexpectedNull;
        try testing.expectEqual(expected_offsets[frame], req.element_offset);
        try testing.expect(seg.element_offset <= @as(usize, seg.max_elements));
    }

    // Frame 3's tail fit parks the write cursor exactly on max.
    try testing.expectEqual(@as(usize, 8), seg.element_offset);

    // Frame 4 must wrap to offset 0 instead of asserting.
    const wrapped = seg.alloc(4, 2) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, 0), wrapped.element_offset);
    try testing.expect(seg.element_offset <= @as(usize, seg.max_elements));
}
