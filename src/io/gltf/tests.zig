// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! glTF loader tests over real model fixtures (curated from the tinygltf test
//! suite — see testdata/README.md). Coverage mirrors the applicable, non-fuzz
//! cases from tinygltf `tests/tester.cc`; serialization, custom-JSON-parser,
//! and image-pixel-decoding cases do not apply to this read-only loader.
//!
//! Two styles:
//!   - Hermetic: `@embedFile` + `loadFromSlice` (no filesystem).
//!   - External-sibling: `loadFile` with a real `std.Io`, for models that
//!     reference sibling `.bin`/image files. These use cwd-relative paths and
//!     therefore assume the tests run from the repository root (as `zig build
//!     test` and `zig test` from the repo root both do).

const std = @import("std");
const gltf = @import("gltf.zig");
const accessor = @import("accessor.zig");
const types = @import("types.zig");

const testing = std.testing;

fn positionAccessor(g: *const gltf.Gltf) ?u32 {
    if (g.document.meshes.len == 0) return null;
    return g.document.meshes[0].primitives[0].attributes.map.get("POSITION");
}

// --- Hermetic: GLB binary ---------------------------------------------------

test "load box01.glb: buffers, positions and indices" {
    const bytes = @embedFile("testdata/box01.glb");
    var g = try gltf.loadFromSlice(testing.allocator, bytes, .{});
    defer g.deinit();

    try testing.expectEqual(@as(usize, 1), g.buffers.len);
    try testing.expect(g.document.meshes.len >= 1);

    const pos = positionAccessor(&g).?;
    const positions = try accessor.readVec(3, testing.allocator, &g, pos);
    defer testing.allocator.free(positions);
    try testing.expectEqual(@as(usize, 32), positions.len);
    try testing.expectApproxEqAbs(@as(f32, -0.5), positions[0][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), positions[0][1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), positions[0][2], 1e-6);

    const indices_acc = g.document.meshes[0].primitives[0].indices.?;
    const indices = try accessor.readIndices(testing.allocator, &g, indices_acc);
    defer testing.allocator.free(indices);
    try testing.expectEqual(@as(usize, 36), indices.len);
    try testing.expectEqual(@as(u32, 0), indices[0]);
}

test "load glb with zero-sized BIN chunk" {
    const bytes = @embedFile("testdata/zero-sized-bin-chunk-issue-440.glb");
    var g = try gltf.loadFromSlice(testing.allocator, bytes, .{});
    defer g.deinit();
}

test "load glb with optional inverse bind matrices (issue-492)" {
    const bytes = @embedFile("testdata/issue-492.glb");
    var g = try gltf.loadFromSlice(testing.allocator, bytes, .{});
    defer g.deinit();
    try testing.expect(g.document.skins.len >= 1);
}

test "sparse accessors are rejected on read" {
    const bytes = @embedFile("testdata/singleBlendshapeCube_sparse.glb");
    var g = try gltf.loadFromSlice(testing.allocator, bytes, .{});
    defer g.deinit();

    var sparse_index: ?usize = null;
    for (g.document.accessors, 0..) |acc, i| {
        if (acc.sparse != null) {
            sparse_index = i;
            break;
        }
    }
    try testing.expect(sparse_index != null);
    // `layout` rejects sparse before any other check, so the read fn used does
    // not matter.
    try testing.expectError(error.SparseUnsupported, accessor.readScalarF32(testing.allocator, &g, sparse_index.?));
}

// --- Hermetic: ASCII glTF with embedded/base64 data -------------------------

test "extensionsUsed parsed (extensions-issue97)" {
    const bytes = @embedFile("testdata/extensions-issue97.gltf");
    var g = try gltf.loadFromSlice(testing.allocator, bytes, .{});
    defer g.deinit();

    try testing.expectEqual(@as(usize, 1), g.document.extensionsUsed.len);
    try testing.expectEqualStrings("VENDOR_material_some_ext", g.document.extensionsUsed[0]);

    // The buffer is a base64 data URI, so geometry reads without any base_dir.
    const pos = positionAccessor(&g).?;
    const positions = try accessor.readVec(3, testing.allocator, &g, pos);
    defer testing.allocator.free(positions);
    try testing.expect(positions.len > 0);
}

// --- Hermetic: bounds checking ---------------------------------------------

test "bounds: accessor with invalid bufferView" {
    // buffers:[] so the load itself succeeds; the error surfaces on read.
    const bytes = @embedFile("testdata/invalid-buffer-view-index.gltf");
    var g = try gltf.loadFromSlice(testing.allocator, bytes, .{});
    defer g.deinit();
    try testing.expectError(error.IndexOutOfBounds, accessor.readIndices(testing.allocator, &g, 0));
}

test "bounds: primitive indices accessor out of bounds" {
    const bytes = @embedFile("testdata/invalid-primitive-indices.gltf");
    var g = try gltf.loadFromSlice(testing.allocator, bytes, .{});
    defer g.deinit();
    const indices_acc = g.document.meshes[0].primitives[0].indices.?;
    try testing.expectError(error.IndexOutOfBounds, accessor.readIndices(testing.allocator, &g, indices_acc));
}

test "bounds: out-of-range integer fails to parse" {
    // byteLength: 1e300 overflows u64 -> JSON parse error.
    const bytes = @embedFile("testdata/integer-out-of-bounds.gltf");
    try testing.expectError(error.Overflow, gltf.loadFromSlice(testing.allocator, bytes, .{}));
}

// --- Hermetic: material defaults -------------------------------------------

test "material default values" {
    const json =
        \\{ "asset": { "version": "2.0" },
        \\  "materials": [ {}, { "pbrMetallicRoughness": {} } ] }
    ;
    var g = try gltf.loadFromSlice(testing.allocator, json, .{});
    defer g.deinit();

    try testing.expectEqual(@as(usize, 2), g.document.materials.len);

    const m0 = g.document.materials[0];
    try testing.expectEqual(types.Material.AlphaMode.OPAQUE, m0.alphaMode);
    try testing.expectEqual(@as(f32, 0.5), m0.alphaCutoff);
    try testing.expectEqual(false, m0.doubleSided);
    try testing.expectEqual([3]f32{ 0, 0, 0 }, m0.emissiveFactor);
    try testing.expect(m0.pbrMetallicRoughness == null);

    const pbr = g.document.materials[1].pbrMetallicRoughness.?;
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, pbr.baseColorFactor);
    try testing.expectEqual(@as(f32, 1), pbr.metallicFactor);
    try testing.expectEqual(@as(f32, 1), pbr.roughnessFactor);
}

// --- Hermetic: GLB container errors (hand-built) ---------------------------

const glb_magic: u32 = 0x46546C67;

test "glb invalid length is rejected" {
    var bytes: [20]u8 = undefined;
    @memset(&bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], glb_magic, .little);
    std.mem.writeInt(u32, bytes[4..8], 2, .little);
    std.mem.writeInt(u32, bytes[8..12], 0x0000f620, .little); // claims far more than 20 bytes
    try testing.expectError(error.InvalidGlb, gltf.loadFromSlice(testing.allocator, &bytes, .{}));
}

test "glb truncated header is rejected" {
    var bytes: [8]u8 = undefined; // magic present but < 12 bytes
    std.mem.writeInt(u32, bytes[0..4], glb_magic, .little);
    std.mem.writeInt(u32, bytes[4..8], 2, .little);
    try testing.expectError(error.InvalidGlb, gltf.loadFromSlice(testing.allocator, &bytes, .{}));
}

test "external uri without base_dir is rejected" {
    const json =
        \\{ "asset": { "version": "2.0" },
        \\  "buffers": [ { "uri": "foo.bin", "byteLength": 4 } ] }
    ;
    try testing.expectError(error.ExternalUriUnsupported, gltf.loadFromSlice(testing.allocator, json, .{}));
}

// --- External-sibling: loadFile with a real Io -----------------------------

const Threaded = std.Io.Threaded;

test "load Cube.gltf with external bin and images" {
    const gpa = testing.allocator;
    var t = Threaded.init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    var g = try gltf.loadFile(gpa, io, "src/io/gltf/testdata/Cube/Cube.gltf");
    defer g.deinit();

    try testing.expectEqual(@as(usize, 1), g.buffers.len);
    try testing.expectEqual(@as(usize, 2), g.document.images.len);
    try testing.expectEqualStrings("Cube_BaseColor.png", g.document.images[0].uri.?);
    try testing.expectEqualStrings("Cube_MetallicRoughness.png", g.document.images[1].uri.?);
    // External PNGs were read into encoded bytes.
    try testing.expect(g.images[0] != null and g.images[0].?.len > 0);
    try testing.expect(g.images[1] != null and g.images[1].?.len > 0);

    const pos = positionAccessor(&g).?;
    const positions = try accessor.readVec(3, gpa, &g, pos);
    defer gpa.free(positions);
    try testing.expectEqual(@as(usize, 36), positions.len);

    const indices_acc = g.document.meshes[0].primitives[0].indices.?;
    const indices = try accessor.readIndices(gpa, &g, indices_acc);
    defer gpa.free(indices);
    try testing.expectEqual(@as(usize, 36), indices.len);
}

test "load model with spaces in image uri" {
    const gpa = testing.allocator;
    var t = Threaded.init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    inline for (.{
        "src/io/gltf/testdata/CubeImageUriSpaces/CubeImageUriSpaces.gltf",
        "src/io/gltf/testdata/CubeImageUriSpaces/CubeImageUriMultipleSpaces.gltf",
    }) |path| {
        var g = try gltf.loadFile(gpa, io, path);
        defer g.deinit();
        try testing.expectEqual(@as(usize, 1), g.document.images.len);
        // The sibling .png (with spaces in its name) resolved and was read.
        try testing.expect(std.mem.indexOfScalar(u8, g.document.images[0].uri.?, ' ') != null);
        try testing.expect(g.images[0] != null and g.images[0].?.len > 0);
    }
}

test "bounds: image references out-of-range buffer" {
    const gpa = testing.allocator;
    var t = Threaded.init(gpa, .{});
    defer t.deinit();
    const io = t.io();

    // The buffer (simpleTriangle.bin) resolves, then the image's bufferView
    // points at buffer index 1, which does not exist.
    try testing.expectError(
        error.IndexOutOfBounds,
        gltf.loadFile(gpa, io, "src/io/gltf/testdata/BoundsChecking/invalid-buffer-index.gltf"),
    );
}
