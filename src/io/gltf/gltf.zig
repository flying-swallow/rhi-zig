//! Native Zig glTF 2.0 loader (`.gltf` JSON and `.glb` binary).
//!
//! `loadFromSlice` parses the document and resolves every buffer/image to raw
//! bytes living in an internal arena, so a `Gltf` is fully self-contained and
//! freed with a single `deinit()`. Image bytes are kept *encoded* (PNG/JPEG/…):
//! this loader does not decode pixels.
//!
//! All parsing/resolution works on byte slices and is unit-testable without the
//! filesystem; `loadFile` is the only entry point that touches `std.Io`.
//!
//! Typed reading of accessor data lives in `accessor.zig`.

const std = @import("std");

pub const types = @import("types.zig");
pub const accessor = @import("accessor.zig");
pub const Document = types.Document;

const log = std.log.scoped(.gltf);
const Io = std.Io;

/// GLB little-endian magic / chunk tags.
const glb_magic: u32 = 0x46546C67; // "glTF"
const glb_chunk_json: u32 = 0x4E4F534A; // "JSON"
const glb_chunk_bin: u32 = 0x004E4942; // "BIN\0"

pub const LoadError = error{
    InvalidGlb,
    UnsupportedGlbVersion,
    InvalidDataUri,
    /// A buffer/image referenced an external file but no `io`/`base_dir` was
    /// available to read it.
    ExternalUriUnsupported,
    /// A buffer has no `uri` but there is no GLB BIN chunk to back it.
    MissingBuffer,
    IndexOutOfBounds,
} || std.mem.Allocator.Error || std.base64.Error;

pub const LoadOptions = struct {
    /// Directory used to resolve relative (non-data) `uri`s. Null disables
    /// reading external `.bin`/image files.
    base_dir: ?[]const u8 = null,
    /// Required (together with `base_dir`) to read external files. Null keeps
    /// the load filesystem-free (data URIs and the GLB BIN chunk still work).
    io: ?Io = null,
};

pub const Gltf = struct {
    arena: std.heap.ArenaAllocator,
    document: Document,
    /// Resolved bytes for each `document.buffers[i]`.
    buffers: [][]const u8,
    /// Resolved encoded bytes for each `document.images[i]`, or null when the
    /// image has no readable source.
    images: []?[]const u8,

    pub fn deinit(self: *Gltf) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Bytes covered by `document.bufferViews[index]`.
    pub fn bufferViewBytes(self: *const Gltf, index: usize) LoadError![]const u8 {
        if (index >= self.document.bufferViews.len) return error.IndexOutOfBounds;
        const view = self.document.bufferViews[index];
        if (view.buffer >= self.buffers.len) return error.IndexOutOfBounds;
        const buf = self.buffers[view.buffer];
        const start = view.byteOffset;
        const end = start + view.byteLength;
        if (end > buf.len) return error.IndexOutOfBounds;
        return buf[start..end];
    }
};

/// Read `path` and load it. `io` is used both for the file itself and for any
/// external `.bin`/image files (resolved relative to `path`'s directory).
pub fn loadFile(allocator: std.mem.Allocator, io: Io, path: []const u8) !Gltf {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    return loadFromSlice(allocator, bytes, .{
        .base_dir = std.fs.path.dirname(path),
        .io = io,
    });
}

/// Auto-detects GLB vs JSON and loads. `bytes` is not retained — all kept data
/// is copied into the returned `Gltf`'s arena.
pub fn loadFromSlice(allocator: std.mem.Allocator, bytes: []const u8, options: LoadOptions) !Gltf {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Split into the JSON document and (for GLB) the BIN chunk.
    var json_slice: []const u8 = bytes;
    var glb_bin: ?[]const u8 = null;
    if (bytes.len >= 4 and std.mem.readInt(u32, bytes[0..4], .little) == glb_magic) {
        const parsed = try parseGlb(bytes);
        json_slice = parsed.json;
        // Copy the BIN chunk into the arena so it outlives `bytes`.
        glb_bin = if (parsed.bin) |b| try a.dupe(u8, b) else null;
    }

    // `.alloc_always` so every parsed string is copied into the arena, making
    // `document` independent of the caller's `bytes`.
    const document = try std.json.parseFromSliceLeaky(Document, a, json_slice, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    const buffers = try a.alloc([]const u8, document.buffers.len);
    for (document.buffers, 0..) |buf, i| {
        buffers[i] = try resolveBufferBytes(a, buf, i, glb_bin, options);
    }

    const images = try a.alloc(?[]const u8, document.images.len);
    for (document.images, 0..) |img, i| {
        images[i] = try resolveImageBytes(a, img, document, buffers, options);
    }

    return .{
        .arena = arena,
        .document = document,
        .buffers = buffers,
        .images = images,
    };
}

const Glb = struct { json: []const u8, bin: ?[]const u8 };

fn parseGlb(bytes: []const u8) LoadError!Glb {
    if (bytes.len < 12) return error.InvalidGlb;
    const version = std.mem.readInt(u32, bytes[4..8], .little);
    if (version != 2) return error.UnsupportedGlbVersion;
    const total = std.mem.readInt(u32, bytes[8..12], .little);
    if (total > bytes.len) return error.InvalidGlb;

    var json: ?[]const u8 = null;
    var bin: ?[]const u8 = null;
    var off: usize = 12;
    while (off + 8 <= total) {
        const chunk_len = std.mem.readInt(u32, bytes[off..][0..4], .little);
        const chunk_type = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
        const data_start = off + 8;
        const data_end = data_start + chunk_len;
        if (data_end > total) return error.InvalidGlb;
        const data = bytes[data_start..data_end];
        switch (chunk_type) {
            glb_chunk_json => if (json == null) {
                json = data;
            },
            glb_chunk_bin => if (bin == null) {
                bin = data;
            },
            else => {}, // skip unknown chunks
        }
        // Chunks are 4-byte aligned.
        off = data_end;
        off += (4 - (off % 4)) % 4;
    }
    return .{ .json = json orelse return error.InvalidGlb, .bin = bin };
}

fn resolveBufferBytes(
    a: std.mem.Allocator,
    buf: types.Buffer,
    index: usize,
    glb_bin: ?[]const u8,
    options: LoadOptions,
) LoadError![]const u8 {
    if (buf.uri) |uri| return resolveUriBytes(a, uri, options);
    // No uri: only valid for buffer 0, backed by the GLB BIN chunk. The chunk
    // may be padded past `byteLength`, so trim to the declared buffer length.
    if (index == 0) {
        if (glb_bin) |b| {
            const len: usize = @intCast(buf.byteLength);
            if (len > b.len) return error.InvalidGlb;
            return b[0..len];
        }
    }
    return error.MissingBuffer;
}

fn resolveImageBytes(
    a: std.mem.Allocator,
    img: types.Image,
    document: Document,
    buffers: []const []const u8,
    options: LoadOptions,
) LoadError!?[]const u8 {
    if (img.uri) |uri| return try resolveUriBytes(a, uri, options);
    if (img.bufferView) |bv_index| {
        if (bv_index >= document.bufferViews.len) return error.IndexOutOfBounds;
        const view = document.bufferViews[bv_index];
        if (view.buffer >= buffers.len) return error.IndexOutOfBounds;
        const b = buffers[view.buffer];
        const end = view.byteOffset + view.byteLength;
        if (end > b.len) return error.IndexOutOfBounds;
        return b[view.byteOffset..end];
    }
    return null;
}

/// Resolve a buffer/image `uri` to bytes owned by `a`: a `data:` URI is
/// base64-decoded; otherwise the file is read relative to `options.base_dir`.
fn resolveUriBytes(a: std.mem.Allocator, uri: []const u8, options: LoadOptions) LoadError![]const u8 {
    if (std.mem.startsWith(u8, uri, "data:")) {
        const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidDataUri;
        const b64 = uri[comma + 1 ..];
        const decoder = std.base64.standard.Decoder;
        const n = try decoder.calcSizeForSlice(b64);
        const out = try a.alloc(u8, n);
        try decoder.decode(out, b64);
        return out;
    }
    const base_dir = options.base_dir orelse return error.ExternalUriUnsupported;
    const io = options.io orelse return error.ExternalUriUnsupported;
    const decoded = try percentDecode(a, uri);
    const path = try std.fs.path.join(a, &.{ base_dir, decoded });
    return Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return error.ExternalUriUnsupported;
}

/// Decode `%XX` escapes in a URI path. Returns `uri` unchanged when it has none.
fn percentDecode(a: std.mem.Allocator, uri: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, uri, '%') == null) return uri;
    var out = try std.ArrayList(u8).initCapacity(a, uri.len);
    var i: usize = 0;
    while (i < uri.len) {
        if (uri[i] == '%' and i + 2 < uri.len) {
            const hi = std.fmt.charToDigit(uri[i + 1], 16) catch {
                out.appendAssumeCapacity(uri[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(uri[i + 2], 16) catch {
                out.appendAssumeCapacity(uri[i]);
                i += 1;
                continue;
            };
            try out.append(a, @as(u8, hi) * 16 + lo);
            i += 3;
        } else {
            try out.append(a, uri[i]);
            i += 1;
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests (self-contained: no external asset files).
// ---------------------------------------------------------------------------

test {
    _ = types;
    _ = accessor;
    _ = @import("tests.zig");
}

// 3 positions (vec3 f32) + 3 indices (u16), packed into one buffer:
//   pos: (0,0,0) (1,0,0) (0,1,0)  -> 36 bytes
//   idx: 0,1,2                    -> 6 bytes (padded to 8 in the buffer view? no
//                                    — indices are a separate accessor at offset 36)
fn sampleGeometry() struct { bytes: [42]u8, b64_len: usize } {
    var bytes: [42]u8 = undefined;
    const pos = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    for (pos, 0..) |v, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], @bitCast(v), .little);
    const idx = [_]u16{ 0, 1, 2 };
    for (idx, 0..) |v, i| std.mem.writeInt(u16, bytes[36 + i * 2 ..][0..2], v, .little);
    return .{ .bytes = bytes, .b64_len = 0 };
}

test "gltf: parse ASCII with base64 buffer + read accessors" {
    const geo = sampleGeometry();
    var b64_buf: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &geo.bytes);

    var json_buf: [2048]u8 = undefined;
    const json = try std.fmt.bufPrint(&json_buf,
        \\{{
        \\  "asset": {{ "version": "2.0" }},
        \\  "buffers": [{{ "uri": "data:application/octet-stream;base64,{s}", "byteLength": 42 }}],
        \\  "bufferViews": [
        \\    {{ "buffer": 0, "byteOffset": 0, "byteLength": 36, "target": 34962 }},
        \\    {{ "buffer": 0, "byteOffset": 36, "byteLength": 6, "target": 34963 }}
        \\  ],
        \\  "accessors": [
        \\    {{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }},
        \\    {{ "bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR" }}
        \\  ],
        \\  "meshes": [{{ "primitives": [{{ "attributes": {{ "POSITION": 0 }}, "indices": 1, "mode": 4 }}] }}]
        \\}}
    , .{b64});

    var g = try loadFromSlice(std.testing.allocator, json, .{});
    defer g.deinit();

    try std.testing.expectEqual(@as(usize, 1), g.document.buffers.len);
    try std.testing.expectEqual(@as(usize, 42), g.buffers[0].len);
    try std.testing.expectEqual(@as(usize, 1), g.document.meshes.len);

    const prim = g.document.meshes[0].primitives[0];
    try std.testing.expectEqual(types.PrimitiveMode.triangles, prim.mode);
    try std.testing.expectEqual(@as(u32, 0), prim.attributes.map.get("POSITION").?);

    const positions = try accessor.readVec(3, std.testing.allocator, &g, 0);
    defer std.testing.allocator.free(positions);
    try std.testing.expectEqual(@as(usize, 3), positions.len);
    try std.testing.expectEqual(@as(f32, 1), positions[1][0]);
    try std.testing.expectEqual(@as(f32, 1), positions[2][1]);

    const indices = try accessor.readIndices(std.testing.allocator, &g, 1);
    defer std.testing.allocator.free(indices);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, indices);
}

test "gltf: parse GLB binary container" {
    const geo = sampleGeometry();

    const json =
        \\{ "asset": { "version": "2.0" },
        \\  "buffers": [{ "byteLength": 42 }],
        \\  "bufferViews": [{ "buffer": 0, "byteOffset": 0, "byteLength": 36 }],
        \\  "accessors": [{ "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" }] }
    ;
    // Pad JSON and BIN to 4-byte boundaries.
    const json_pad = (4 - (json.len % 4)) % 4;
    const bin_pad = (4 - (geo.bytes.len % 4)) % 4;
    const json_chunk = json.len + json_pad;
    const bin_chunk = geo.bytes.len + bin_pad;
    const total = 12 + 8 + json_chunk + 8 + bin_chunk;

    var glb = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(glb);
    @memset(glb, 0);
    std.mem.writeInt(u32, glb[0..4], glb_magic, .little);
    std.mem.writeInt(u32, glb[4..8], 2, .little);
    std.mem.writeInt(u32, glb[8..12], @intCast(total), .little);
    // JSON chunk
    std.mem.writeInt(u32, glb[12..16], @intCast(json_chunk), .little);
    std.mem.writeInt(u32, glb[16..20], glb_chunk_json, .little);
    @memset(glb[20 .. 20 + json_chunk], ' '); // pad JSON with spaces
    @memcpy(glb[20 .. 20 + json.len], json);
    // BIN chunk
    const bin_off = 20 + json_chunk;
    std.mem.writeInt(u32, glb[bin_off..][0..4], @intCast(bin_chunk), .little);
    std.mem.writeInt(u32, glb[bin_off + 4 ..][0..4], glb_chunk_bin, .little);
    @memcpy(glb[bin_off + 8 ..][0..geo.bytes.len], &geo.bytes);

    var g = try loadFromSlice(std.testing.allocator, glb, .{});
    defer g.deinit();

    try std.testing.expectEqual(@as(usize, 42), g.buffers[0].len);
    try std.testing.expectEqualSlices(u8, &geo.bytes, g.buffers[0]);

    const positions = try accessor.readVec(3, std.testing.allocator, &g, 0);
    defer std.testing.allocator.free(positions);
    try std.testing.expectEqual(@as(f32, 1), positions[2][1]);
}
