//! Plain-old-data structs and enums shared across the Metal / Foundation /
//! QuartzCore bindings. These mirror the C structs and `NS_ENUM` values defined
//! by the system frameworks, so they are declared directly (no C import) with
//! the exact layout and integer values the Objective-C runtime expects.

const std = @import("std");

/// `NSUInteger` — pointer-width unsigned integer used pervasively by the
/// Foundation / Metal APIs for counts, lengths and indices.
pub const UInteger = usize;
/// `NSInteger` — pointer-width signed integer.
pub const Integer = isize;

// -- Geometry --------------------------------------------------------------

/// `CGSize` (CoreGraphics). Used by `CAMetalLayer.setDrawableSize`.
pub const CGSize = extern struct {
    width: f64,
    height: f64,
};

/// `MTLSize`.
pub const Size = extern struct {
    width: UInteger,
    height: UInteger,
    depth: UInteger,
};

/// `MTLOrigin`.
pub const Origin = extern struct {
    x: UInteger,
    y: UInteger,
    z: UInteger,
};

/// `MTLRegion`.
pub const Region = extern struct {
    origin: Origin,
    size: Size,
};

/// `MTLClearColor` — RGBA in the [0, 1] range.
pub const ClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

/// `MTLViewport`.
pub const Viewport = extern struct {
    origin_x: f64,
    origin_y: f64,
    width: f64,
    height: f64,
    znear: f64,
    zfar: f64,
};

/// `MTLScissorRect`.
pub const ScissorRect = extern struct {
    x: UInteger,
    y: UInteger,
    width: UInteger,
    height: UInteger,
};

// -- Enums (values taken from the metal-cpp headers) -----------------------

/// `MTLPixelFormat` (`MTLPixelFormat.hpp`). Curated subset — extend as needed.
pub const PixelFormat = enum(UInteger) {
    invalid = 0,
    rgba8unorm = 70,
    bgra8unorm = 80,
    bgra8unorm_srgb = 81,
    depth32float = 252,
    _,
};

/// `MTLLoadAction` (`MTLRenderPass.hpp`).
pub const LoadAction = enum(UInteger) {
    dont_care = 0,
    load = 1,
    clear = 2,
};

/// `MTLStoreAction` (`MTLRenderPass.hpp`).
pub const StoreAction = enum(UInteger) {
    dont_care = 0,
    store = 1,
    multisample_resolve = 2,
    store_and_multisample_resolve = 3,
};

/// `MTLPrimitiveType` (`MTLRenderCommandEncoder.hpp`).
pub const PrimitiveType = enum(UInteger) {
    point = 0,
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
};

/// `MTLIndexType` (`MTLStageInputOutputDescriptor.hpp`).
pub const IndexType = enum(UInteger) {
    uint16 = 0,
    uint32 = 1,
};

/// `MTLCompareFunction` (`MTLDepthStencil.hpp`).
pub const CompareFunction = enum(UInteger) {
    never = 0,
    less = 1,
    equal = 2,
    less_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_equal = 6,
    always = 7,
};

/// `MTLVertexFormat` (`MTLVertexDescriptor.hpp`). Curated subset.
pub const VertexFormat = enum(UInteger) {
    invalid = 0,
    uchar2 = 1,
    uchar4 = 3,
    float = 28,
    float2 = 29,
    float3 = 30,
    float4 = 31,
    _,
};

/// `MTLVertexStepFunction` (`MTLVertexDescriptor.hpp`).
pub const VertexStepFunction = enum(UInteger) {
    constant = 0,
    per_vertex = 1,
    per_instance = 2,
};

/// `MTLTextureType` (`MTLTexture.hpp`). Curated subset.
pub const TextureType = enum(UInteger) {
    type_1d = 0,
    type_2d = 2,
    type_3d = 7,
    type_cube = 5,
    _,
};

// -- Option sets (bitfields backed by NSUInteger) --------------------------

/// `MTLCPUCacheMode` — occupies the low 4 bits of `MTLResourceOptions`.
pub const CPUCacheMode = enum(u4) {
    default_cache = 0,
    write_combined = 1,
};

/// `MTLStorageMode` — occupies bits 4..7 of `MTLResourceOptions`.
pub const StorageMode = enum(u4) {
    shared = 0,
    managed = 1,
    private = 2,
    memoryless = 3,
};

/// `MTLHazardTrackingMode` — occupies bits 8..9 of `MTLResourceOptions`.
pub const HazardTrackingMode = enum(u2) {
    default = 0,
    untracked = 1,
    tracked = 2,
};

/// `MTLResourceOptions` — a packed `NSUInteger` bitfield. The default value
/// (`.{}`) is `StorageModeShared | CPUCacheModeDefaultCache`, matching Metal.
/// Convert to the integer the runtime expects with `toInt()`.
pub const ResourceOptions = packed struct(u64) {
    cpu_cache_mode: CPUCacheMode = .default_cache,
    storage_mode: StorageMode = .shared,
    hazard_tracking_mode: HazardTrackingMode = .default,
    _reserved: u54 = 0,

    pub inline fn toInt(self: ResourceOptions) u64 {
        return @bitCast(self);
    }
};

/// `MTLTextureUsage` — a packed `NSUInteger` bitfield.
pub const TextureUsage = packed struct(u64) {
    shader_read: bool = false,
    shader_write: bool = false,
    render_target: bool = false,
    _reserved_3: u1 = 0,
    pixel_format_view: bool = false,
    _reserved: u59 = 0,

    pub inline fn toInt(self: TextureUsage) u64 {
        return @bitCast(self);
    }
};

comptime {
    // Guard against accidental layout drift in the packed bitfields.
    std.debug.assert((ResourceOptions{ .storage_mode = .private }).toInt() == 0x20);
    std.debug.assert((ResourceOptions{ .storage_mode = .managed }).toInt() == 0x10);
    std.debug.assert((TextureUsage{ .render_target = true }).toInt() == 0x4);
}
