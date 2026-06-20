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
