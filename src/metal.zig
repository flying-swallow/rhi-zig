// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! RHI-side wrapper over the `deps/metal` binding fabric, mirroring how
//! `vulkan.zig` wraps the `vulkan` module. Re-exports the Metal / Foundation /
//! QuartzCore namespaces and hosts RHI-specific Metal helpers (e.g. format
//! conversions) as they are needed.
const std = @import("std");
const rhi = @import("root.zig");

const metal = @import("metal");

/// Metal (`MTL`) — device, queues, buffers, textures, pipelines, encoders.
pub const mtl = metal.mtl;
/// Foundation (`NS`) — strings, errors, arrays.
pub const ns = metal.ns;
/// QuartzCore (`CA`) — `CAMetalLayer`, `CAMetalDrawable`.
pub const ca = metal.ca;
/// POD structs and enums (sizes, clear colors, pixel formats, ...).
pub const types = metal.types;
/// The underlying Objective-C bridge.
pub const objc = metal.objc;

/// Maps a core `rhi.Format` to an `MTLPixelFormat`. Only a curated subset is
/// supported; unsupported formats map to `.invalid`.
pub fn to_mtl_pixel_format(format: rhi.Format) types.PixelFormat {
    return switch (format) {
        .rgba8_unorm => .rgba8unorm,
        .bgra8_unorm => .bgra8unorm,
        .bgra8_srgb  => .bgra8unorm_srgb,
        .d32_sfloat  => .depth32float,
        else         => .invalid,
    };
}
