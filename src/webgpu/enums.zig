// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! WebGPU enum tables, the `rhi.Format` mapping, and the converters between
//! them and the backend-neutral RHI vocabulary.
//!
//! Split out of `webgpu.zig` so it compiles on every target, not just wasm:
//! `webgpu.zig` declares `extern "wgpu"` imports and is only reachable when
//! `platform_has_api(.wgpu)`, which would put the glue-contract test below out
//! of reach of a normal `zig build test`.

const rhi = @import("../root.zig");
const std = @import("std");

// ---------------------------------------------------------------------------
// Enums
//
// Each of these is an index into a parallel table of WebGPU string literals in
// glue.js. Order is the contract: adding a value means adding it in both files,
// at the same position.
// ---------------------------------------------------------------------------

/// Mirrors `GPUTextureFormat`. This is the WebGPU-supported subset of
/// `rhi.Format` — roughly 40 of its ~90 entries. Anything outside it is an
/// error rather than a silently substituted neighbour.
pub const TextureFormat = enum(u32) {
    // 8-bit
    r8unorm,
    r8snorm,
    r8uint,
    r8sint,
    // 16-bit
    r16uint,
    r16sint,
    r16float,
    rg8unorm,
    rg8snorm,
    rg8uint,
    rg8sint,
    // 32-bit
    r32uint,
    r32sint,
    r32float,
    rg16uint,
    rg16sint,
    rg16float,
    rgba8unorm,
    rgba8unorm_srgb,
    rgba8snorm,
    rgba8uint,
    rgba8sint,
    bgra8unorm,
    bgra8unorm_srgb,
    // packed 32-bit
    rgb9e5ufloat,
    rgb10a2uint,
    rgb10a2unorm,
    rg11b10ufloat,
    // 64-bit
    rg32uint,
    rg32sint,
    rg32float,
    rgba16uint,
    rgba16sint,
    rgba16float,
    // 128-bit
    rgba32uint,
    rgba32sint,
    rgba32float,
    // depth / stencil
    depth16unorm,
    depth24plus,
    depth24plus_stencil8,
    depth32float,
    depth32float_stencil8,
    // BC compressed
    bc1_rgba_unorm,
    bc1_rgba_unorm_srgb,
    bc2_rgba_unorm,
    bc2_rgba_unorm_srgb,
    bc3_rgba_unorm,
    bc3_rgba_unorm_srgb,
    bc4_r_unorm,
    bc4_r_snorm,
    bc5_rg_unorm,
    bc5_rg_snorm,
    bc6h_rgb_ufloat,
    bc6h_rgb_float,
    bc7_rgba_unorm,
    bc7_rgba_unorm_srgb,
    // ETC2 compressed
    etc2_rgb8unorm,
    etc2_rgb8unorm_srgb,
    etc2_rgb8a1unorm,
    etc2_rgb8a1unorm_srgb,
    etc2_rgba8unorm,
    etc2_rgba8unorm_srgb,
    eac_r11unorm,
    eac_r11snorm,
    eac_rg11unorm,
    eac_rg11snorm,

    /// Sentinel for "this rhi.Format has no WebGPU spelling". Never crosses the
    /// wasm boundary — `to_wgpu_texture_format` turns it into an error first.
    undefined_format,
};

pub const TextureDimension = enum(u32) { @"1d", @"2d", @"3d" };

pub const TextureViewDimension = enum(u32) {
    @"1d",
    @"2d",
    @"2d_array",
    cube,
    cube_array,
    @"3d",
};

pub const TextureAspect = enum(u32) { all, stencil_only, depth_only };

pub const LoadOp = enum(u32) { load, clear };
pub const StoreOp = enum(u32) { store, discard };

pub const PrimitiveTopology = enum(u32) {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
};

pub const CullMode = enum(u32) { none, front, back };
pub const FrontFace = enum(u32) { ccw, cw };

pub const CompareFunction = enum(u32) {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,
};

pub const IndexFormat = enum(u32) { uint16, uint32 };

pub const VertexFormat = enum(u32) {
    float32,
    float32x2,
    float32x3,
    float32x4,
};

pub const FilterMode = enum(u32) { nearest, linear };
pub const AddressMode = enum(u32) { clamp_to_edge, repeat, mirror_repeat };

/// `GPUBufferUsage` flags.
pub const BufferUsage = struct {
    pub const map_read: u32 = 0x0001;
    pub const map_write: u32 = 0x0002;
    pub const copy_src: u32 = 0x0004;
    pub const copy_dst: u32 = 0x0008;
    pub const index: u32 = 0x0010;
    pub const vertex: u32 = 0x0020;
    pub const uniform: u32 = 0x0040;
    pub const storage: u32 = 0x0080;
    pub const indirect: u32 = 0x0100;
    pub const query_resolve: u32 = 0x0200;
};

/// `GPUTextureUsage` flags.
pub const TextureUsage = struct {
    pub const copy_src: u32 = 0x01;
    pub const copy_dst: u32 = 0x02;
    pub const texture_binding: u32 = 0x04;
    pub const storage_binding: u32 = 0x08;
    pub const render_attachment: u32 = 0x10;
};

// ---------------------------------------------------------------------------
// Format mapping
// ---------------------------------------------------------------------------

const FormatPair = struct { rhi.Format, TextureFormat };

/// Only formats WebGPU actually names appear here. `rhi.Format` entries that
/// have no WebGPU equivalent (the OpenGL luminance formats, `bgr8_unorm`,
/// `rgb8_unorm`, the 32-bit 3-component formats, the D3D-style planar aliases,
/// the 16-bit normalized formats, `r5_g6_b5_unorm` and friends) are absent on
/// purpose so `to_wgpu_texture_format` reports them rather than approximating.
const format_mappings = [_]FormatPair{
    .{ .r8_unorm, .r8unorm },
    .{ .r8_snorm, .r8snorm },
    .{ .r8_uint, .r8uint },
    .{ .r8_sint, .r8sint },
    .{ .rg8_unorm, .rg8unorm },
    .{ .rg8_snorm, .rg8snorm },
    .{ .rg8_uint, .rg8uint },
    .{ .rg8_sint, .rg8sint },
    .{ .bgra8_unorm, .bgra8unorm },
    .{ .bgra8_srgb, .bgra8unorm_srgb },
    .{ .rgba8_unorm, .rgba8unorm },
    .{ .rgba8_snorm, .rgba8snorm },
    .{ .rgba8_uint, .rgba8uint },
    .{ .rgba8_sint, .rgba8sint },
    .{ .rgba8_srgb, .rgba8unorm_srgb },
    .{ .r16_uint, .r16uint },
    .{ .r16_sint, .r16sint },
    .{ .r16_sfloat, .r16float },
    .{ .rg16_uint, .rg16uint },
    .{ .rg16_sint, .rg16sint },
    .{ .rg16_sfloat, .rg16float },
    .{ .rgba16_uint, .rgba16uint },
    .{ .rgba16_sint, .rgba16sint },
    .{ .rgba16_sfloat, .rgba16float },
    .{ .r32_uint, .r32uint },
    .{ .r32_sint, .r32sint },
    .{ .r32_sfloat, .r32float },
    .{ .rg32_uint, .rg32uint },
    .{ .rg32_sint, .rg32sint },
    .{ .rg32_sfloat, .rg32float },
    .{ .rgba32_uint, .rgba32uint },
    .{ .rgba32_sint, .rgba32sint },
    .{ .rgba32_sfloat, .rgba32float },
    .{ .r10_g10_b10_a2_unorm, .rgb10a2unorm },
    .{ .r10_g10_b10_a2_uint, .rgb10a2uint },
    .{ .r11_g11_b10_ufloat, .rg11b10ufloat },
    .{ .r9_g9_b9_e5_unorm, .rgb9e5ufloat },
    .{ .d16_unorm, .depth16unorm },
    .{ .d32_sfloat, .depth32float },
    .{ .d24_unorm_s8_uint, .depth24plus_stencil8 },
    .{ .d32_sfloat_s8_uint, .depth32float_stencil8 },
    .{ .bc1_rgba_unorm, .bc1_rgba_unorm },
    .{ .bc1_rgba_srgb, .bc1_rgba_unorm_srgb },
    .{ .bc2_rgba_unorm, .bc2_rgba_unorm },
    .{ .bc2_rgba_srgb, .bc2_rgba_unorm_srgb },
    .{ .bc3_rgba_unorm, .bc3_rgba_unorm },
    .{ .bc3_rgba_srgb, .bc3_rgba_unorm_srgb },
    .{ .bc4_r_unorm, .bc4_r_unorm },
    .{ .bc4_r_snorm, .bc4_r_snorm },
    .{ .bc5_rg_unorm, .bc5_rg_unorm },
    .{ .bc5_rg_snorm, .bc5_rg_snorm },
    .{ .bc6h_rgb_ufloat, .bc6h_rgb_ufloat },
    .{ .bc6h_rgb_sfloat, .bc6h_rgb_float },
    .{ .bc7_rgba_unorm, .bc7_rgba_unorm },
    .{ .bc7_rgba_srgb, .bc7_rgba_unorm_srgb },
    .{ .etc2_r8g8b8_unorm, .etc2_rgb8unorm },
    .{ .etc2_r8g8b8_srgb, .etc2_rgb8unorm_srgb },
    .{ .etc2_r8g8b8a1_unorm, .etc2_rgb8a1unorm },
    .{ .etc2_r8g8b8a1_srgb, .etc2_rgb8a1unorm_srgb },
    .{ .etc2_r8g8b8a8_unorm, .etc2_rgba8unorm },
    .{ .etc2_r8g8b8a8_srgb, .etc2_rgba8unorm_srgb },
    .{ .etc2_eac_r11_unorm, .eac_r11unorm },
    .{ .etc2_eac_r11_snorm, .eac_r11snorm },
    .{ .etc2_eac_r11g11_unorm, .eac_rg11unorm },
    .{ .etc2_eac_r11g11_snorm, .eac_rg11snorm },
};

pub fn to_wgpu_texture_format(format: rhi.Format) !TextureFormat {
    inline for (format_mappings) |pair| {
        if (pair[0] == format) return pair[1];
    }
    return error.UnsupportedFormat;
}

pub fn from_wgpu_texture_format(format: TextureFormat) rhi.Format {
    inline for (format_mappings) |pair| {
        if (pair[1] == format) return pair[0];
    }
    return .unknown;
}

/// `rhi.Format` -> whether the format carries a depth aspect. Used to pick the
/// render-pass attachment slot without a second lookup table.
pub fn is_depth_format(format: rhi.Format) bool {
    return switch (format) {
        .d16_unorm,
        .d32_sfloat,
        .d16_unorm_s8_uint,
        .d24_unorm_s8_uint,
        .d32_sfloat_s8_uint,
        .d32_sfloat_s8_uint_x24,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Enum converters
// ---------------------------------------------------------------------------

pub fn to_wgpu_load_op(op: rhi.cmd.LoadOp) LoadOp {
    return switch (op) {
        .load => .load,
        .clear => .clear,
        // WebGPU has no "don't care" load; `clear` is the honest cheap default,
        // since `load` would pull in undefined contents.
        .dont_care => .clear,
    };
}

pub fn to_wgpu_store_op(op: rhi.cmd.StoreOp) StoreOp {
    return switch (op) {
        .store => .store,
        .dont_care => .discard,
    };
}

pub fn to_wgpu_index_format(t: rhi.cmd.IndexType) IndexFormat {
    return switch (t) {
        .uint16 => .uint16,
        .uint32 => .uint32,
    };
}

pub fn to_wgpu_vertex_format(f: rhi.pipeline.VertexFormat) VertexFormat {
    return switch (f) {
        .float => .float32,
        .float2 => .float32x2,
        .float3 => .float32x3,
        .float4 => .float32x4,
    };
}

pub fn to_wgpu_view_dimension(t: rhi.image_view.ViewType) !TextureViewDimension {
    return switch (t) {
        .shader_resource_1d, .shader_resource_storage_1d => .@"1d",
        // The attachment view types carry no dimensionality of their own; every
        // attachment the examples create is a plain 2D surface.
        .shader_resource_2d,
        .shader_resource_storage_2d,
        .color_attachment,
        .depth_stencil_attachment,
        .depth_readonly_stencil_attachment,
        .depth_attachment_stencil_readonly,
        .depth_stencil_readonly,
        => .@"2d",
        .shader_resource_1d_array, .shader_resource_storage_1d_array => error.UnsupportedViewType,
        .shader_resource_2d_array, .shader_resource_storage_2d_array => .@"2d_array",
        .shader_resource_3d, .shader_resource_storage_3d => .@"3d",
        .shader_resource_cube => .cube,
        .shader_resource_cube_array => .cube_array,
        // WebGPU has no variable-rate-shading attachment.
        .shading_rate_attachment => error.UnsupportedViewType,
    };
}

pub fn to_wgpu_aspect(a: @FieldType(rhi.image_view.ViewDesc, "aspect")) TextureAspect {
    return switch (a) {
        .color, .depth_stencil => .all,
        .depth => .depth_only,
        .stencil => .stencil_only,
    };
}

// ---------------------------------------------------------------------------
// Glue contract
// ---------------------------------------------------------------------------

/// The WebGPU spelling of an enum field: the field name with `_` replaced by
/// `-`. That single rule covers every table (`rgba8unorm_srgb` ->
/// `rgba8unorm-srgb`, `bc1_rgba_unorm` -> `bc1-rgba-unorm`, `less_equal` ->
/// `less-equal`, `2d_array` -> `2d-array`).
fn webgpuName(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        const out = buf;
        return &out;
    }
}

/// Asserts that `table_name` in glue.js lists exactly the fields of `T`, in
/// order.
///
/// The Zig enums and the JS string tables are positional: a value's integer is
/// its index in the JS array. Nothing in either language enforces that, and a
/// drift shows up at runtime as the wrong texture format or blend op rather
/// than as an error, so it is checked here instead.
fn expectTableMatches(comptime T: type, comptime table_name: []const u8, js: []const u8) !void {
    // The `inline for` unrolls once per enum field, and TextureFormat alone has
    // 67 of them, each doing comptime string work.
    @setEvalBranchQuota(20_000);
    const decl = "const " ++ table_name ++ " = [";
    const start = (std.mem.indexOf(u8, js, decl) orelse {
        std.debug.print("glue.js has no table named {s}\n", .{table_name});
        return error.TableNotFound;
    }) + decl.len;
    const body = js[start .. start + (std.mem.indexOf(u8, js[start..], "];") orelse return error.UnterminatedTable)];

    // Walk the quoted entries in order. `null` entries (the `undefined_format`
    // sentinel) are placeholders and are skipped by the field walk below.
    var cursor: usize = 0;
    inline for (@typeInfo(T).@"enum".field_names) |field_name| {
        const expected = comptime webgpuName(field_name);
        // `undefined_format` has no WebGPU spelling; glue.js holds `null` there.
        const is_sentinel = comptime std.mem.eql(u8, field_name, "undefined_format");
        if (is_sentinel) {
            const n = std.mem.indexOfPos(u8, body, cursor, "null") orelse {
                std.debug.print("{s}: expected a null placeholder for {s}\n", .{ table_name, field_name });
                return error.SentinelMissing;
            };
            cursor = n + "null".len;
            continue;
        }
        const open = std.mem.indexOfScalarPos(u8, body, cursor, '"') orelse {
            std.debug.print("{s}: ran out of entries at {s}\n", .{ table_name, field_name });
            return error.TooFewEntries;
        };
        const close = std.mem.indexOfScalarPos(u8, body, open + 1, '"') orelse return error.UnterminatedEntry;
        const actual = body[open + 1 .. close];
        if (!std.mem.eql(u8, actual, expected)) {
            std.debug.print("{s} index mismatch: zig {s} -> expected \"{s}\", glue.js has \"{s}\"\n", .{ table_name, field_name, expected, actual });
            return error.EntryMismatch;
        }
        cursor = close + 1;
    }

    // Anything left over means glue.js lists more entries than the enum has,
    // which shifts every index after it.
    if (std.mem.indexOfScalarPos(u8, body, cursor, '"') != null) {
        std.debug.print("{s}: glue.js has more entries than {s} has fields\n", .{ table_name, @typeName(T) });
        return error.TooManyEntries;
    }
}

test "webgpu: glue.js enum tables match the Zig enums" {
    const js = @embedFile("glue.js");
    try expectTableMatches(TextureFormat, "TEXTURE_FORMAT", js);
    try expectTableMatches(TextureDimension, "TEXTURE_DIMENSION", js);
    try expectTableMatches(TextureViewDimension, "VIEW_DIMENSION", js);
    try expectTableMatches(TextureAspect, "TEXTURE_ASPECT", js);
    try expectTableMatches(LoadOp, "LOAD_OP", js);
    try expectTableMatches(StoreOp, "STORE_OP", js);
    try expectTableMatches(PrimitiveTopology, "TOPOLOGY", js);
    try expectTableMatches(CullMode, "CULL_MODE", js);
    try expectTableMatches(FrontFace, "FRONT_FACE", js);
    try expectTableMatches(CompareFunction, "COMPARE", js);
    try expectTableMatches(IndexFormat, "INDEX_FORMAT", js);
    try expectTableMatches(VertexFormat, "VERTEX_FORMAT", js);
}

test "webgpu: format mapping round-trips" {
    for (format_mappings) |pair| {
        try std.testing.expectEqual(pair[1], try to_wgpu_texture_format(pair[0]));
        try std.testing.expectEqual(pair[0], from_wgpu_texture_format(pair[1]));
    }
    // A format WebGPU cannot express is reported, not approximated.
    try std.testing.expectError(error.UnsupportedFormat, to_wgpu_texture_format(.bgr8_unorm));
    try std.testing.expectError(error.UnsupportedFormat, to_wgpu_texture_format(.rgb32_sfloat));
    try std.testing.expectError(error.UnsupportedFormat, to_wgpu_texture_format(.r16_unorm));
}
