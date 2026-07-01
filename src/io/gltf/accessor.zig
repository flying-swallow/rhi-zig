//! Typed reading of glTF accessor data into plain Zig slices.
//!
//! These helpers decode the Buffer -> BufferView -> Accessor indirection,
//! honoring `byteOffset`, `byteStride` and `normalized`, and converting the
//! stored component type to `f32`/`u32`. Sparse accessors are not supported.

const std = @import("std");
const types = @import("types.zig");
const gltf = @import("gltf.zig");

pub const Error = error{
    SparseUnsupported,
    MissingBufferView,
    UnsupportedComponentType,
    /// The accessor's element shape doesn't fit the requested read (e.g. asking
    /// for vec3 from a SCALAR accessor, or non-scalar indices).
    ComponentMismatch,
    IndexOutOfBounds,
    BufferOverrun,
} || std.mem.Allocator.Error;

/// Resolved element addressing for one accessor over its backing buffer.
const Layout = struct {
    buf: []const u8,
    base_offset: usize,
    stride: usize,
    component_size: usize,
    component_count: usize,
    component_type: types.ComponentType,
    normalized: bool,
    count: usize,

    fn elementOffset(self: Layout, i: usize) usize {
        return self.base_offset + i * self.stride;
    }
};

fn layout(g: *const gltf.Gltf, accessor_index: usize) Error!Layout {
    const doc = g.document;
    if (accessor_index >= doc.accessors.len) return error.IndexOutOfBounds;
    const acc = doc.accessors[accessor_index];
    if (acc.sparse != null) return error.SparseUnsupported;

    const bv_index = acc.bufferView orelse return error.MissingBufferView;
    if (bv_index >= doc.bufferViews.len) return error.IndexOutOfBounds;
    const view = doc.bufferViews[bv_index];
    if (view.buffer >= g.buffers.len) return error.IndexOutOfBounds;
    const buf = g.buffers[view.buffer];

    const comp_size = acc.componentType.byteSize();
    if (comp_size == 0) return error.UnsupportedComponentType;
    const comp_count = acc.@"type".componentCount();
    const elem_size = comp_size * comp_count;
    const stride: usize = if (view.byteStride) |s| (if (s != 0) s else elem_size) else elem_size;

    const base = view.byteOffset + acc.byteOffset;
    const count: usize = @intCast(acc.count);
    // Bounds: the last element must lie fully inside the backing buffer.
    if (count > 0) {
        const last = base + (count - 1) * stride + elem_size;
        if (last > buf.len) return error.BufferOverrun;
    }
    return .{
        .buf = buf,
        .base_offset = base,
        .stride = stride,
        .component_size = comp_size,
        .component_count = comp_count,
        .component_type = acc.componentType,
        .normalized = acc.normalized,
        .count = count,
    };
}

fn readComponentF32(buf: []const u8, p: usize, ct: types.ComponentType, normalized: bool) f32 {
    return switch (ct) {
        .float => @bitCast(std.mem.readInt(u32, buf[p..][0..4], .little)),
        .unsigned_byte => blk: {
            const v = buf[p];
            break :blk if (normalized) @as(f32, @floatFromInt(v)) / 255.0 else @floatFromInt(v);
        },
        .byte => blk: {
            const v = std.mem.readInt(i8, buf[p..][0..1], .little);
            break :blk if (normalized) @max(@as(f32, @floatFromInt(v)) / 127.0, -1.0) else @floatFromInt(v);
        },
        .unsigned_short => blk: {
            const v = std.mem.readInt(u16, buf[p..][0..2], .little);
            break :blk if (normalized) @as(f32, @floatFromInt(v)) / 65535.0 else @floatFromInt(v);
        },
        .short => blk: {
            const v = std.mem.readInt(i16, buf[p..][0..2], .little);
            break :blk if (normalized) @max(@as(f32, @floatFromInt(v)) / 32767.0, -1.0) else @floatFromInt(v);
        },
        .unsigned_int => @floatFromInt(std.mem.readInt(u32, buf[p..][0..4], .little)),
        _ => 0,
    };
}

fn readComponentU32(buf: []const u8, p: usize, ct: types.ComponentType) Error!u32 {
    return switch (ct) {
        .unsigned_byte => buf[p],
        .unsigned_short => std.mem.readInt(u16, buf[p..][0..2], .little),
        .unsigned_int => std.mem.readInt(u32, buf[p..][0..4], .little),
        else => error.UnsupportedComponentType,
    };
}

/// Read a vector accessor (N in 2..4) as `[]@Vector(N, f32)`. Caller frees.
pub fn readVec(comptime N: comptime_int, allocator: std.mem.Allocator, g: *const gltf.Gltf, accessor_index: usize) Error![]@Vector(N, f32) {
    comptime std.debug.assert(N >= 1 and N <= 4);
    const l = try layout(g, accessor_index);
    if (l.component_count != N) return error.ComponentMismatch;

    const out = try allocator.alloc(@Vector(N, f32), l.count);
    errdefer allocator.free(out);
    for (0..l.count) |e| {
        const eo = l.elementOffset(e);
        var v: @Vector(N, f32) = undefined;
        inline for (0..N) |c| {
            v[c] = readComponentF32(l.buf, eo + c * l.component_size, l.component_type, l.normalized);
        }
        out[e] = v;
    }
    return out;
}

/// Read a SCALAR f32 accessor. Caller frees.
pub fn readScalarF32(allocator: std.mem.Allocator, g: *const gltf.Gltf, accessor_index: usize) Error![]f32 {
    const l = try layout(g, accessor_index);
    if (l.component_count != 1) return error.ComponentMismatch;

    const out = try allocator.alloc(f32, l.count);
    errdefer allocator.free(out);
    for (0..l.count) |e| {
        out[e] = readComponentF32(l.buf, l.elementOffset(e), l.component_type, l.normalized);
    }
    return out;
}

/// Read a SCALAR index accessor, promoting u8/u16/u32 to u32. Caller frees.
pub fn readIndices(allocator: std.mem.Allocator, g: *const gltf.Gltf, accessor_index: usize) Error![]u32 {
    const l = try layout(g, accessor_index);
    if (l.component_count != 1) return error.ComponentMismatch;

    const out = try allocator.alloc(u32, l.count);
    errdefer allocator.free(out);
    for (0..l.count) |e| {
        out[e] = try readComponentU32(l.buf, l.elementOffset(e), l.component_type);
    }
    return out;
}
