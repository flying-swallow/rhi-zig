// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! glTF 2.0 JSON schema as Zig structs, suitable for `std.json` static parsing.
//!
//! Field names are spelled exactly as the glTF JSON keys (camelCase) because
//! `std.json` matches object keys to struct field names verbatim — there is no
//! rename mechanism. The JSON reserved-word key `type` is written `@"type"`.
//! Every optional/defaulted field carries its glTF spec default so parsing
//! never fails on an omitted-but-optional key (`std.json` fills defaults for
//! fields absent from the document); only genuinely required keys are left
//! without a default so a malformed file surfaces `error.MissingField`.
//!
//! Reference for the data model: tinygltf `tiny_gltf.h`.

const std = @import("std");
const Value = std.json.Value;

/// Accessor element component scalar type (glTF `componentType`).
pub const ComponentType = enum(u32) {
    byte = 5120,
    unsigned_byte = 5121,
    short = 5122,
    unsigned_short = 5123,
    unsigned_int = 5125,
    float = 5126,
    _,

    pub fn byteSize(self: ComponentType) u32 {
        return switch (self) {
            .byte, .unsigned_byte => 1,
            .short, .unsigned_short => 2,
            .unsigned_int, .float => 4,
            _ => 0,
        };
    }
};

/// Accessor element shape (glTF `type`). Parsed from the JSON string by name.
pub const AccessorType = enum {
    SCALAR,
    VEC2,
    VEC3,
    VEC4,
    MAT2,
    MAT3,
    MAT4,

    pub fn componentCount(self: AccessorType) u32 {
        return switch (self) {
            .SCALAR => 1,
            .VEC2 => 2,
            .VEC3 => 3,
            .VEC4 => 4,
            .MAT2 => 4,
            .MAT3 => 9,
            .MAT4 => 16,
        };
    }
};

/// Primitive topology (glTF `mode`); 4 = TRIANGLES is the default.
pub const PrimitiveMode = enum(u32) {
    points = 0,
    lines = 1,
    line_loop = 2,
    line_strip = 3,
    triangles = 4,
    triangle_strip = 5,
    triangle_fan = 6,
    _,
};

pub const Asset = struct {
    version: []const u8 = "2.0",
    minVersion: ?[]const u8 = null,
    generator: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Buffer = struct {
    /// File path, data URI, or null (GLB BIN chunk backs buffer 0).
    uri: ?[]const u8 = null,
    byteLength: u64,
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const BufferView = struct {
    buffer: u32,
    byteOffset: u64 = 0,
    byteLength: u64,
    /// 0/null means tightly packed.
    byteStride: ?u32 = null,
    target: ?u32 = null,
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Accessor = struct {
    pub const Sparse = struct {
        pub const Indices = struct {
            bufferView: u32,
            byteOffset: u64 = 0,
            componentType: ComponentType,
        };
        pub const Values = struct {
            bufferView: u32,
            byteOffset: u64 = 0,
        };
        count: u64,
        indices: Indices,
        values: Values,
    };

    bufferView: ?u32 = null,
    byteOffset: u64 = 0,
    componentType: ComponentType,
    normalized: bool = false,
    count: u64,
    @"type": AccessorType,
    min: ?[]f32 = null,
    max: ?[]f32 = null,
    sparse: ?Sparse = null,
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const TextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    extras: ?Value = null,
};

pub const NormalTextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    scale: f32 = 1,
    extras: ?Value = null,
};

pub const OcclusionTextureInfo = struct {
    index: u32,
    texCoord: u32 = 0,
    strength: f32 = 1,
    extras: ?Value = null,
};

pub const PbrMetallicRoughness = struct {
    baseColorFactor: [4]f32 = .{ 1, 1, 1, 1 },
    baseColorTexture: ?TextureInfo = null,
    metallicFactor: f32 = 1,
    roughnessFactor: f32 = 1,
    metallicRoughnessTexture: ?TextureInfo = null,
    extras: ?Value = null,
};

pub const Material = struct {
    pub const AlphaMode = enum { OPAQUE, MASK, BLEND };

    name: ?[]const u8 = null,
    pbrMetallicRoughness: ?PbrMetallicRoughness = null,
    normalTexture: ?NormalTextureInfo = null,
    occlusionTexture: ?OcclusionTextureInfo = null,
    emissiveTexture: ?TextureInfo = null,
    emissiveFactor: [3]f32 = .{ 0, 0, 0 },
    alphaMode: AlphaMode = .OPAQUE,
    alphaCutoff: f32 = 0.5,
    doubleSided: bool = false,
    extras: ?Value = null,
};

pub const Primitive = struct {
    /// Attribute-semantic ("POSITION", "NORMAL", "TEXCOORD_0", ...) -> accessor.
    attributes: std.json.ArrayHashMap(u32) = .{},
    indices: ?u32 = null,
    material: ?u32 = null,
    mode: PrimitiveMode = .triangles,
    /// Morph targets: each is a semantic -> accessor map.
    targets: []std.json.ArrayHashMap(u32) = &.{},
    extras: ?Value = null,
};

pub const Mesh = struct {
    primitives: []Primitive,
    weights: []f32 = &.{},
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Texture = struct {
    sampler: ?u32 = null,
    source: ?u32 = null,
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Sampler = struct {
    magFilter: ?u32 = null,
    minFilter: ?u32 = null,
    wrapS: u32 = 10497,
    wrapT: u32 = 10497,
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Image = struct {
    uri: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    bufferView: ?u32 = null,
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Node = struct {
    camera: ?u32 = null,
    children: []u32 = &.{},
    skin: ?u32 = null,
    mesh: ?u32 = null,
    /// Column-major 4x4; when present it replaces translation/rotation/scale.
    matrix: ?[16]f32 = null,
    translation: ?[3]f32 = null,
    /// Unit quaternion [x, y, z, w].
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    weights: []f32 = &.{},
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Scene = struct {
    nodes: []u32 = &.{},
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Animation = struct {
    pub const Channel = struct {
        pub const Target = struct {
            node: ?u32 = null,
            path: []const u8,
        };
        sampler: u32,
        target: Target,
    };
    pub const AnimationSampler = struct {
        input: u32,
        interpolation: []const u8 = "LINEAR",
        output: u32,
    };
    channels: []Channel,
    samplers: []AnimationSampler,
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Skin = struct {
    inverseBindMatrices: ?u32 = null,
    skeleton: ?u32 = null,
    joints: []u32 = &.{},
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

pub const Camera = struct {
    @"type": []const u8,
    perspective: ?Value = null,
    orthographic: ?Value = null,
    name: ?[]const u8 = null,
    extras: ?Value = null,
};

/// The parsed glTF document tree (raw JSON model; index references are not yet
/// dereferenced). Buffer/image *bytes* are resolved separately by `gltf.Gltf`.
pub const Document = struct {
    asset: Asset = .{},
    scene: ?u32 = null,
    scenes: []Scene = &.{},
    nodes: []Node = &.{},
    meshes: []Mesh = &.{},
    accessors: []Accessor = &.{},
    bufferViews: []BufferView = &.{},
    buffers: []Buffer = &.{},
    materials: []Material = &.{},
    textures: []Texture = &.{},
    images: []Image = &.{},
    samplers: []Sampler = &.{},
    animations: []Animation = &.{},
    skins: []Skin = &.{},
    cameras: []Camera = &.{},
    extensionsUsed: [][]const u8 = &.{},
    extensionsRequired: [][]const u8 = &.{},
    extras: ?Value = null,
};

test "types: enum helpers" {
    try std.testing.expectEqual(@as(u32, 3), AccessorType.VEC3.componentCount());
    try std.testing.expectEqual(@as(u32, 16), AccessorType.MAT4.componentCount());
    try std.testing.expectEqual(@as(u32, 4), ComponentType.float.byteSize());
    try std.testing.expectEqual(@as(u32, 2), ComponentType.unsigned_short.byteSize());
}
