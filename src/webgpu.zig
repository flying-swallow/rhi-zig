// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! WebGPU backend shim — the peer of `vulkan.zig` / `metal.zig`.
//!
//! This backend is **web-only**: it exists exactly on WebAssembly targets and
//! talks to `navigator.gpu` through the JS glue in `src/webgpu/glue.js`. There
//! is no native wgpu-native/Dawn path.
//!
//! ## The wasm boundary
//!
//! Every import below takes **scalar arguments plus `(ptr, len)` pairs**. No
//! C-layout struct is ever shared with JS. Decoding descriptor structs on the JS
//! side with a `DataView` would drift silently the moment a field is added or
//! reordered, and the symptom would be a corrupted pipeline rather than a
//! compile error, so the verbosity here is deliberate.
//!
//! Objects are `Handle`s: indices into a JS-side table. `0` is null, matching the
//! `cookie == 0` "empty" convention in `root.zig`.
//!
//! Sizes and offsets are `u32`. WebGPU spells them `u64`, but a `u64` parameter
//! becomes a JS `BigInt` at the wasm boundary, and no browser-resident resource
//! approaches 4 GiB. `u64` values that must survive round-trips (timeline
//! counters) are split into `lo`/`hi` pairs instead.

const rhi = @import("root.zig");
const std = @import("std");

/// Enum tables, the `rhi.Format` mapping, and the converters. Kept in a separate
/// file so they compile (and their glue-contract test runs) on every target.
pub const enums = @import("webgpu/enums.zig");
pub const TextureFormat = enums.TextureFormat;
pub const TextureDimension = enums.TextureDimension;
pub const TextureViewDimension = enums.TextureViewDimension;
pub const TextureAspect = enums.TextureAspect;
pub const LoadOp = enums.LoadOp;
pub const StoreOp = enums.StoreOp;
pub const PrimitiveTopology = enums.PrimitiveTopology;
pub const CullMode = enums.CullMode;
pub const FrontFace = enums.FrontFace;
pub const CompareFunction = enums.CompareFunction;
pub const IndexFormat = enums.IndexFormat;
pub const VertexFormat = enums.VertexFormat;
pub const FilterMode = enums.FilterMode;
pub const AddressMode = enums.AddressMode;
pub const BufferUsage = enums.BufferUsage;
pub const TextureUsage = enums.TextureUsage;
pub const to_wgpu_texture_format = enums.to_wgpu_texture_format;
pub const from_wgpu_texture_format = enums.from_wgpu_texture_format;
pub const is_depth_format = enums.is_depth_format;
pub const to_wgpu_load_op = enums.to_wgpu_load_op;
pub const to_wgpu_store_op = enums.to_wgpu_store_op;
pub const to_wgpu_index_format = enums.to_wgpu_index_format;
pub const to_wgpu_vertex_format = enums.to_wgpu_vertex_format;
pub const to_wgpu_view_dimension = enums.to_wgpu_view_dimension;
pub const to_wgpu_aspect = enums.to_wgpu_aspect;

/// An entry in the JS-side object table. `.none` is the null object.
pub const Handle = enum(u32) {
    none = 0,
    _,

    pub fn isNone(self: Handle) bool {
        return self == .none;
    }
};

// ---------------------------------------------------------------------------
// Imports implemented by src/webgpu/glue.js
// ---------------------------------------------------------------------------

/// Adapter and device are requested by the glue *before* the wasm module is
/// instantiated, so these are plain getters and the synchronous
/// `Renderer.init` -> `enumerate_adapters` -> `Device.init` chain needs no
/// async plumbing.
pub extern "wgpu" fn wgpu_adapter_get() Handle;
pub extern "wgpu" fn wgpu_device_get() Handle;
pub extern "wgpu" fn wgpu_device_get_queue(device: Handle) Handle;

/// Writes at most `buf_len` UTF-8 bytes of the adapter description into wasm
/// memory and returns the number written.
pub extern "wgpu" fn wgpu_adapter_name(adapter: Handle, buf_ptr: [*]u8, buf_len: u32) u32;
pub extern "wgpu" fn wgpu_adapter_vendor_id(adapter: Handle) u32;
pub extern "wgpu" fn wgpu_adapter_device_id(adapter: Handle) u32;
/// 0 = discrete, 1 = integrated, 2 = cpu, 3 = unknown. The browser only exposes
/// a coarse hint, so this is best-effort.
pub extern "wgpu" fn wgpu_adapter_type(adapter: Handle) u32;
pub extern "wgpu" fn wgpu_adapter_limit(adapter: Handle, limit_ptr: [*]const u8, limit_len: u32) u32;

/// Drops a handle from the JS table. Safe on `.none`.
pub extern "wgpu" fn wgpu_release(handle: Handle) void;

// Surface (canvas)
pub extern "wgpu" fn wgpu_surface_create(selector_ptr: [*]const u8, selector_len: u32) Handle;
pub extern "wgpu" fn wgpu_surface_preferred_format() TextureFormat;
pub extern "wgpu" fn wgpu_surface_configure(
    surface: Handle,
    device: Handle,
    format: TextureFormat,
    width: u32,
    height: u32,
) void;
/// The canvas texture for this frame. WebGPU has no acquire index, so callers
/// always report image index 0.
pub extern "wgpu" fn wgpu_surface_get_current_texture(surface: Handle) Handle;

// Textures and views
pub extern "wgpu" fn wgpu_device_create_texture(
    device: Handle,
    format: TextureFormat,
    width: u32,
    height: u32,
    depth_or_layers: u32,
    mip_level_count: u32,
    sample_count: u32,
    dimension: TextureDimension,
    usage: u32,
) Handle;
pub extern "wgpu" fn wgpu_texture_create_view(
    texture: Handle,
    format: TextureFormat,
    dimension: TextureViewDimension,
    aspect: TextureAspect,
    base_mip_level: u32,
    mip_level_count: u32,
    base_array_layer: u32,
    array_layer_count: u32,
) Handle;

// Buffers
pub extern "wgpu" fn wgpu_device_create_buffer(device: Handle, size: u32, usage: u32) Handle;
pub extern "wgpu" fn wgpu_queue_write_buffer(
    queue: Handle,
    buffer: Handle,
    buffer_offset: u32,
    data_ptr: [*]const u8,
    data_len: u32,
) void;

// Shader modules. `wgsl_ptr` is WGSL *source text*, not SPIR-V words.
pub extern "wgpu" fn wgpu_device_create_shader_module(
    device: Handle,
    wgsl_ptr: [*]const u8,
    wgsl_len: u32,
) Handle;

/// Render pipelines use `layout: "auto"`, so WebGPU derives bind group layouts
/// from the shader and there is no explicit layout object to build.
///
/// `attrs_ptr` is a flat array of `(location, VertexFormat, offset)` triples,
/// `attrs_len` its element count (3 per attribute).
pub extern "wgpu" fn wgpu_device_create_render_pipeline(
    device: Handle,
    vs_module: Handle,
    vs_entry_ptr: [*]const u8,
    vs_entry_len: u32,
    fs_module: Handle,
    fs_entry_ptr: [*]const u8,
    fs_entry_len: u32,
    color_format: TextureFormat,
    depth_format: TextureFormat,
    topology: PrimitiveTopology,
    cull_mode: CullMode,
    front_face: FrontFace,
    depth_write: u32,
    depth_compare: CompareFunction,
    vertex_stride: u32,
    attrs_ptr: [*]const u32,
    attrs_len: u32,
) Handle;
pub extern "wgpu" fn wgpu_render_pipeline_get_bind_group_layout(pipeline: Handle, index: u32) Handle;
pub extern "wgpu" fn wgpu_device_create_bind_group_uniform(
    device: Handle,
    layout: Handle,
    buffer: Handle,
    offset: u32,
    size: u32,
) Handle;

// Command encoding
pub extern "wgpu" fn wgpu_device_create_command_encoder(device: Handle) Handle;
pub extern "wgpu" fn wgpu_command_encoder_begin_render_pass(
    encoder: Handle,
    color_view: Handle,
    color_load_op: LoadOp,
    color_store_op: StoreOp,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    depth_view: Handle,
    depth_load_op: LoadOp,
    depth_store_op: StoreOp,
    clear_depth: f32,
) Handle;
pub extern "wgpu" fn wgpu_command_encoder_copy_buffer_to_buffer(
    encoder: Handle,
    src: Handle,
    src_offset: u32,
    dst: Handle,
    dst_offset: u32,
    size: u32,
) void;
pub extern "wgpu" fn wgpu_command_encoder_finish(encoder: Handle) Handle;

pub extern "wgpu" fn wgpu_render_pass_set_viewport(
    pass: Handle,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
) void;
pub extern "wgpu" fn wgpu_render_pass_set_scissor_rect(pass: Handle, x: u32, y: u32, width: u32, height: u32) void;
pub extern "wgpu" fn wgpu_render_pass_set_pipeline(pass: Handle, pipeline: Handle) void;
pub extern "wgpu" fn wgpu_render_pass_set_bind_group(pass: Handle, index: u32, bind_group: Handle) void;
pub extern "wgpu" fn wgpu_render_pass_set_vertex_buffer(pass: Handle, slot: u32, buffer: Handle, offset: u32) void;
pub extern "wgpu" fn wgpu_render_pass_set_index_buffer(pass: Handle, buffer: Handle, format: IndexFormat, offset: u32) void;
pub extern "wgpu" fn wgpu_render_pass_draw(
    pass: Handle,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) void;
pub extern "wgpu" fn wgpu_render_pass_draw_indexed(
    pass: Handle,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    first_instance: u32,
) void;
pub extern "wgpu" fn wgpu_render_pass_end(pass: Handle) void;

// Queue
pub extern "wgpu" fn wgpu_queue_submit(queue: Handle, cmd_buffers_ptr: [*]const Handle, count: u32) void;
/// Registers a completion callback for the work submitted so far. When it
/// resolves, the glue writes `value_lo`/`value_hi` back to `out_ptr` as two
/// little-endian u32s — split so no `BigInt` crosses the boundary.
pub extern "wgpu" fn wgpu_queue_on_submitted_work_done(
    queue: Handle,
    out_ptr: [*]u32,
    value_lo: u32,
    value_hi: u32,
) void;

// Diagnostics
pub extern "wgpu" fn wgpu_log(level: u32, ptr: [*]const u8, len: u32) void;

/// Splits a `u64` for the `lo`/`hi` boundary convention above.
pub fn split_u64(v: u64) struct { lo: u32, hi: u32 } {
    return .{ .lo = @truncate(v), .hi = @truncate(v >> 32) };
}

pub fn join_u64(lo: u32, hi: u32) u64 {
    return @as(u64, lo) | (@as(u64, hi) << 32);
}
