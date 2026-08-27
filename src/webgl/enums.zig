// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! WebGL2 (OpenGL ES 3.0) constants, the `rhi.Format` mapping, and converters.
//!
//! Split out of `webgl.zig` for the same reason `webgpu/enums.zig` is split out
//! of `webgpu.zig`: `webgl.zig` declares `extern "webgl"` imports and is only
//! reachable when `platform_has_api(.webgl)`, which would put the glue-contract
//! test below out of reach of a normal `zig build test`.
//!
//! Unlike the WebGPU tables, these are **numeric GL enum values, not indices**.
//! They cross the boundary as the numbers WebGL itself defines, so glue.js can
//! pass them straight through — there is no positional ordering to keep in sync,
//! only the values themselves, which the test below pins.

const rhi = @import("../root.zig");
const std = @import("std");

/// The subset of GL enum values this backend uses. Values are from the OpenGL
/// ES 3.0 / WebGL2 specification and are what actually cross into JS.
pub const gl = struct {
    // Buffer targets and usage
    pub const ARRAY_BUFFER: u32 = 0x8892;
    pub const ELEMENT_ARRAY_BUFFER: u32 = 0x8893;
    pub const STATIC_DRAW: u32 = 0x88E4;
    pub const DYNAMIC_DRAW: u32 = 0x88E8;

    // Capabilities
    pub const CULL_FACE: u32 = 0x0B44;
    pub const DEPTH_TEST: u32 = 0x0B71;
    pub const BLEND: u32 = 0x0BE2;
    pub const SCISSOR_TEST: u32 = 0x0C11;
    pub const RASTERIZER_DISCARD: u32 = 0x8C89;

    // Blend factors
    pub const ZERO: u32 = 0x0000;
    pub const ONE: u32 = 0x0001;
    pub const SRC_COLOR: u32 = 0x0300;
    pub const ONE_MINUS_SRC_COLOR: u32 = 0x0301;
    pub const SRC_ALPHA: u32 = 0x0302;
    pub const ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
    pub const DST_ALPHA: u32 = 0x0304;
    pub const ONE_MINUS_DST_ALPHA: u32 = 0x0305;
    pub const DST_COLOR: u32 = 0x0306;
    pub const ONE_MINUS_DST_COLOR: u32 = 0x0307;
    pub const SRC_ALPHA_SATURATE: u32 = 0x0308;
    pub const CONSTANT_COLOR: u32 = 0x8001;
    pub const ONE_MINUS_CONSTANT_COLOR: u32 = 0x8002;
    pub const CONSTANT_ALPHA: u32 = 0x8003;
    pub const ONE_MINUS_CONSTANT_ALPHA: u32 = 0x8004;

    // Blend equations
    pub const FUNC_ADD: u32 = 0x8006;
    pub const FUNC_SUBTRACT: u32 = 0x800A;
    pub const FUNC_REVERSE_SUBTRACT: u32 = 0x800B;
    pub const MIN: u32 = 0x8007;
    pub const MAX: u32 = 0x8008;

    // Texture filtering and wrapping
    pub const NEAREST: u32 = 0x2600;
    pub const LINEAR: u32 = 0x2601;
    pub const NEAREST_MIPMAP_NEAREST: u32 = 0x2700;
    pub const LINEAR_MIPMAP_NEAREST: u32 = 0x2701;
    pub const NEAREST_MIPMAP_LINEAR: u32 = 0x2702;
    pub const LINEAR_MIPMAP_LINEAR: u32 = 0x2703;
    pub const CLAMP_TO_EDGE: u32 = 0x812F;
    pub const REPEAT: u32 = 0x2901;
    pub const MIRRORED_REPEAT: u32 = 0x8370;
    pub const TEXTURE0: u32 = 0x84C0;

    // Face / winding
    pub const FRONT: u32 = 0x0404;
    pub const BACK: u32 = 0x0405;
    pub const CW: u32 = 0x0900;
    pub const CCW: u32 = 0x0901;

    // Compare functions
    pub const NEVER: u32 = 0x0200;
    pub const LESS: u32 = 0x0201;
    pub const EQUAL: u32 = 0x0202;
    pub const LEQUAL: u32 = 0x0203;
    pub const GREATER: u32 = 0x0204;
    pub const NOTEQUAL: u32 = 0x0205;
    pub const GEQUAL: u32 = 0x0206;
    pub const ALWAYS: u32 = 0x0207;

    // Primitive modes
    pub const POINTS: u32 = 0x0000;
    pub const LINES: u32 = 0x0001;
    pub const LINE_STRIP: u32 = 0x0003;
    pub const TRIANGLES: u32 = 0x0004;
    pub const TRIANGLE_STRIP: u32 = 0x0005;

    // Index types
    pub const UNSIGNED_SHORT: u32 = 0x1403;
    pub const UNSIGNED_INT: u32 = 0x1405;

    // Component types
    pub const FLOAT: u32 = 0x1406;
    pub const UNSIGNED_BYTE: u32 = 0x1401;
    pub const HALF_FLOAT: u32 = 0x140B;
    pub const UNSIGNED_INT_24_8: u32 = 0x84FA;
    pub const FLOAT_32_UNSIGNED_INT_24_8_REV: u32 = 0x8DAD;

    // Pixel formats
    pub const RED: u32 = 0x1903;
    pub const RGBA_INTEGER: u32 = 0x8D99;
    pub const RG: u32 = 0x8227;
    pub const RGB: u32 = 0x1907;
    pub const RGBA: u32 = 0x1908;
    pub const DEPTH_COMPONENT: u32 = 0x1902;
    pub const DEPTH_STENCIL: u32 = 0x84F9;

    // Sized internal formats
    pub const R8: u32 = 0x8229;
    pub const RG8: u32 = 0x822B;
    pub const RGB8: u32 = 0x8051;
    pub const RGBA8: u32 = 0x8058;
    pub const SRGB8_ALPHA8: u32 = 0x8C43;
    pub const R16F: u32 = 0x822D;
    pub const RG16F: u32 = 0x822F;
    pub const RGBA16F: u32 = 0x881A;
    pub const R32F: u32 = 0x822E;
    pub const RG32F: u32 = 0x8230;
    pub const RGBA32F: u32 = 0x8814;
    // 0x8D76, not 0x8D88 -- the latter is GL_RGBA16I, the *signed* format.
    // Storing the signed one made `texStorage2D` allocate a format that
    // `texSubImage2D` could not then upload RGBA_INTEGER/UNSIGNED_SHORT into,
    // which is how the Slug band texture arrived as an empty sampler.
    pub const RGBA16UI: u32 = 0x8D76;
    pub const RGB10_A2: u32 = 0x8059;
    pub const R11F_G11F_B10F: u32 = 0x8C3A;
    pub const RGB9_E5: u32 = 0x8C3D;
    pub const DEPTH_COMPONENT16: u32 = 0x81A5;
    pub const DEPTH_COMPONENT24: u32 = 0x81A6;
    pub const DEPTH_COMPONENT32F: u32 = 0x8CAC;
    pub const DEPTH24_STENCIL8: u32 = 0x88F0;
    pub const DEPTH32F_STENCIL8: u32 = 0x8CAD;

    // Framebuffers
    pub const FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
    pub const COLOR_ATTACHMENT0: u32 = 0x8CE0;
    pub const DEPTH_ATTACHMENT: u32 = 0x8D00;
    pub const DEPTH_STENCIL_ATTACHMENT: u32 = 0x821A;

    // Uniform types, as reported by getActiveUniform
    pub const FLOAT_VEC2: u32 = 0x8B50;
    pub const FLOAT_VEC3: u32 = 0x8B51;
    pub const FLOAT_VEC4: u32 = 0x8B52;
    pub const INT: u32 = 0x1404;
    pub const INT_VEC2: u32 = 0x8B53;
    pub const INT_VEC3: u32 = 0x8B54;
    pub const INT_VEC4: u32 = 0x8B55;
    pub const UNSIGNED_INT_VEC2: u32 = 0x8DC6;
    pub const UNSIGNED_INT_VEC3: u32 = 0x8DC7;
    pub const UNSIGNED_INT_VEC4: u32 = 0x8DC8;
    pub const FLOAT_MAT4: u32 = 0x8B5C;

    // getParameter names
    pub const MAX_TEXTURE_SIZE: u32 = 0x0D33;
    pub const MAX_ARRAY_TEXTURE_LAYERS: u32 = 0x88FF;
    pub const MAX_3D_TEXTURE_SIZE: u32 = 0x8073;
};

/// The three values `texStorage2D`/`texImage2D` need for one `rhi.Format`.
pub const GlFormat = struct {
    internal_format: u32,
    format: u32,
    type: u32,
};

const FormatPair = struct { rhi.Format, GlFormat };

/// Only formats WebGL2 can actually store appear here. Notably **there is no
/// renderable BGRA** in WebGL2, so `bgra8_unorm` is absent — the swapchain uses
/// `RGBA8` on this backend where the WebGPU one takes the browser's preferred
/// canvas format (often `bgra8unorm`).
const format_mappings = [_]FormatPair{
    .{ .r8_unorm, .{ .internal_format = gl.R8, .format = gl.RED, .type = gl.UNSIGNED_BYTE } },
    .{ .rg8_unorm, .{ .internal_format = gl.RG8, .format = gl.RG, .type = gl.UNSIGNED_BYTE } },
    .{ .rgb8_unorm, .{ .internal_format = gl.RGB8, .format = gl.RGB, .type = gl.UNSIGNED_BYTE } },
    .{ .rgba8_unorm, .{ .internal_format = gl.RGBA8, .format = gl.RGBA, .type = gl.UNSIGNED_BYTE } },
    .{ .rgba8_srgb, .{ .internal_format = gl.SRGB8_ALPHA8, .format = gl.RGBA, .type = gl.UNSIGNED_BYTE } },
    .{ .r16_sfloat, .{ .internal_format = gl.R16F, .format = gl.RED, .type = gl.HALF_FLOAT } },
    .{ .rg16_sfloat, .{ .internal_format = gl.RG16F, .format = gl.RG, .type = gl.HALF_FLOAT } },
    .{ .rgba16_sfloat, .{ .internal_format = gl.RGBA16F, .format = gl.RGBA, .type = gl.HALF_FLOAT } },
    .{ .r32_sfloat, .{ .internal_format = gl.R32F, .format = gl.RED, .type = gl.FLOAT } },
    .{ .rg32_sfloat, .{ .internal_format = gl.RG32F, .format = gl.RG, .type = gl.FLOAT } },
    .{ .rgba32_sfloat, .{ .internal_format = gl.RGBA32F, .format = gl.RGBA, .type = gl.FLOAT } },
    // Integer formats are sampled with `texelFetch` through a `usampler2D` and
    // are never filterable; `gl_create_texture_2d` defaults to NEAREST so they
    // come out complete.
    .{ .rgba16_uint, .{ .internal_format = gl.RGBA16UI, .format = gl.RGBA_INTEGER, .type = gl.UNSIGNED_SHORT } },
    .{ .r10_g10_b10_a2_unorm, .{ .internal_format = gl.RGB10_A2, .format = gl.RGBA, .type = gl.UNSIGNED_BYTE } },
    .{ .r11_g11_b10_ufloat, .{ .internal_format = gl.R11F_G11F_B10F, .format = gl.RGB, .type = gl.HALF_FLOAT } },
    .{ .r9_g9_b9_e5_unorm, .{ .internal_format = gl.RGB9_E5, .format = gl.RGB, .type = gl.HALF_FLOAT } },
    .{ .d16_unorm, .{ .internal_format = gl.DEPTH_COMPONENT16, .format = gl.DEPTH_COMPONENT, .type = gl.UNSIGNED_SHORT } },
    .{ .d32_sfloat, .{ .internal_format = gl.DEPTH_COMPONENT32F, .format = gl.DEPTH_COMPONENT, .type = gl.FLOAT } },
    .{ .d24_unorm_s8_uint, .{ .internal_format = gl.DEPTH24_STENCIL8, .format = gl.DEPTH_STENCIL, .type = gl.UNSIGNED_INT_24_8 } },
    .{ .d32_sfloat_s8_uint, .{ .internal_format = gl.DEPTH32F_STENCIL8, .format = gl.DEPTH_STENCIL, .type = gl.FLOAT_32_UNSIGNED_INT_24_8_REV } },
};

pub fn to_gl_format(format: rhi.Format) !GlFormat {
    inline for (format_mappings) |pair| {
        if (pair[0] == format) return pair[1];
    }
    return error.UnsupportedFormat;
}

/// Whether a format carries a depth aspect, so the render pass knows which
/// attachment point to use.
pub fn is_depth_format(format: rhi.Format) bool {
    return switch (format) {
        .d16_unorm, .d32_sfloat, .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_sfloat_s8_uint, .d32_sfloat_s8_uint_x24 => true,
        else => false,
    };
}

pub fn has_stencil(format: rhi.Format) bool {
    return switch (format) {
        .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_sfloat_s8_uint, .d32_sfloat_s8_uint_x24 => true,
        else => false,
    };
}

pub fn to_gl_index_type(t: rhi.cmd.IndexType) u32 {
    return switch (t) {
        .uint16 => gl.UNSIGNED_SHORT,
        .uint32 => gl.UNSIGNED_INT,
    };
}

pub fn index_type_size(t: rhi.cmd.IndexType) u32 {
    return switch (t) {
        .uint16 => 2,
        .uint32 => 4,
    };
}

pub fn to_gl_compare(op: rhi.pipeline.CompareOp) u32 {
    return switch (op) {
        .never => gl.NEVER,
        .less => gl.LESS,
        .equal => gl.EQUAL,
        .less_equal => gl.LEQUAL,
        .greater => gl.GREATER,
        .not_equal => gl.NOTEQUAL,
        .greater_equal => gl.GEQUAL,
        .always => gl.ALWAYS,
    };
}

pub fn to_gl_blend_factor(f: rhi.pipeline.BlendFactor) u32 {
    return switch (f) {
        .zero => gl.ZERO,
        .one => gl.ONE,
        .src_color => gl.SRC_COLOR,
        .one_minus_src_color => gl.ONE_MINUS_SRC_COLOR,
        .dst_color => gl.DST_COLOR,
        .one_minus_dst_color => gl.ONE_MINUS_DST_COLOR,
        .src_alpha => gl.SRC_ALPHA,
        .one_minus_src_alpha => gl.ONE_MINUS_SRC_ALPHA,
        .dst_alpha => gl.DST_ALPHA,
        .one_minus_dst_alpha => gl.ONE_MINUS_DST_ALPHA,
        .constant_color => gl.CONSTANT_COLOR,
        .one_minus_constant_color => gl.ONE_MINUS_CONSTANT_COLOR,
        .constant_alpha => gl.CONSTANT_ALPHA,
        .one_minus_constant_alpha => gl.ONE_MINUS_CONSTANT_ALPHA,
        .src_alpha_saturate => gl.SRC_ALPHA_SATURATE,
    };
}

pub fn to_gl_blend_op(op: rhi.pipeline.BlendOp) u32 {
    return switch (op) {
        .add => gl.FUNC_ADD,
        .subtract => gl.FUNC_SUBTRACT,
        .reverse_subtract => gl.FUNC_REVERSE_SUBTRACT,
        .min => gl.MIN,
        .max => gl.MAX,
    };
}

/// Number of float components in a vertex format, for `vertexAttribPointer`.
pub fn vertex_components(f: rhi.pipeline.VertexFormat) u32 {
    return switch (f) {
        .float => 1,
        .float2 => 2,
        .float3 => 3,
        .float4 => 4,
    };
}

// ---------------------------------------------------------------------------
// Glue contract
// ---------------------------------------------------------------------------

/// Asserts that glue.js agrees with a GL constant's value.
///
/// These cross the boundary as numbers, so unlike the WebGPU tables there is no
/// ordering to preserve — but a typo in either file is just as silent, and would
/// surface as an unrelated GL error rather than a mismatch.
fn expectConst(js: []const u8, name: []const u8, value: u32) !void {
    var buf: [96]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "{s}: 0x{X:0>4}", .{ name, value });
    if (std.mem.indexOf(u8, js, needle) == null) {
        std.debug.print("glue.js is missing or disagrees with GL constant: {s}\n", .{needle});
        return error.ConstantMismatch;
    }
}

test "webgl: glue.js GL constants match the Zig values" {
    const js = @embedFile("glue.js");
    try expectConst(js, "ARRAY_BUFFER", gl.ARRAY_BUFFER);
    try expectConst(js, "ELEMENT_ARRAY_BUFFER", gl.ELEMENT_ARRAY_BUFFER);
    try expectConst(js, "CULL_FACE", gl.CULL_FACE);
    try expectConst(js, "DEPTH_TEST", gl.DEPTH_TEST);
    try expectConst(js, "SCISSOR_TEST", gl.SCISSOR_TEST);
    try expectConst(js, "TRIANGLES", gl.TRIANGLES);
    try expectConst(js, "UNSIGNED_SHORT", gl.UNSIGNED_SHORT);
    try expectConst(js, "UNSIGNED_INT", gl.UNSIGNED_INT);
    try expectConst(js, "FLOAT", gl.FLOAT);
    try expectConst(js, "RGBA8", gl.RGBA8);
    try expectConst(js, "DEPTH_COMPONENT32F", gl.DEPTH_COMPONENT32F);
    try expectConst(js, "COLOR_ATTACHMENT0", gl.COLOR_ATTACHMENT0);
    try expectConst(js, "DEPTH_ATTACHMENT", gl.DEPTH_ATTACHMENT);
    try expectConst(js, "FRAMEBUFFER_COMPLETE", gl.FRAMEBUFFER_COMPLETE);
    try expectConst(js, "LESS", gl.LESS);
    try expectConst(js, "CW", gl.CW);
    try expectConst(js, "CCW", gl.CCW);
}

test "glue.js ABI version matches rhi.glue_abi_version" {
    // The wasm module and the glue are cached separately by the browser, so a
    // mismatch is a real and silent failure mode; the boot-time check only
    // helps if these two constants are kept in step.
    const js = @embedFile("../webgpu/glue.js");
    var buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "const GLUE_ABI_VERSION = {d};", .{rhi.glue_abi_version});
    if (std.mem.indexOf(u8, js, needle) == null) {
        std.debug.print(
            "src/webgpu/glue.js does not declare `{s}` — bump it alongside rhi.glue_abi_version\n",
            .{needle},
        );
        return error.GlueAbiVersionMismatch;
    }
}

test "webgl: format mapping covers what the examples need" {
    // 02_mesh's depth target and the swapchain colour format.
    try std.testing.expectEqual(gl.DEPTH_COMPONENT32F, (try to_gl_format(.d32_sfloat)).internal_format);
    try std.testing.expectEqual(gl.RGBA8, (try to_gl_format(.rgba8_unorm)).internal_format);
    try std.testing.expect(is_depth_format(.d32_sfloat));
    try std.testing.expect(!is_depth_format(.rgba8_unorm));
    try std.testing.expect(!has_stencil(.d32_sfloat));
    // WebGL2 has no renderable BGRA, so this must be reported rather than
    // silently swizzled.
    try std.testing.expectError(error.UnsupportedFormat, to_gl_format(.bgra8_unorm));

    // The Slug atlas pair: an RGBA32F curve texture and an RGBA16UI band
    // texture, both read with texelFetch.
    try std.testing.expectEqual(gl.RGBA32F, (try to_gl_format(.rgba32_sfloat)).internal_format);
    try std.testing.expectEqual(gl.RGBA16UI, (try to_gl_format(.rgba16_uint)).internal_format);
    try std.testing.expectEqual(gl.RGBA_INTEGER, (try to_gl_format(.rgba16_uint)).format);
}
