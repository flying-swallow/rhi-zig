//! Metal binding fabric for the RHI: thin, idiomatic-Zig typed wrappers over the
//! Metal / Foundation / QuartzCore Objective-C APIs, built on `zig_objc`. This is
//! the connecting layer the `.mtl` RHI backend calls into; it replicates the
//! curated slice of the `metal-cpp` API surface the backend needs.
//!
//! Namespaces mirror the frameworks:
//! - `mtl`   — Metal (`MTL`): device, queues, buffers, textures, pipelines, ...
//! - `ns`    — Foundation (`NS`): strings, errors, arrays.
//! - `ca`    — QuartzCore (`CA`): `CAMetalLayer`, `CAMetalDrawable`.
//! - `types` — POD structs and enums (sizes, clear colors, pixel formats, ...).

const std = @import("std");
const builtin = @import("builtin");

pub const objc = @import("objc");
pub const types = @import("types.zig");
pub const ns = @import("foundation.zig");
pub const mtl = @import("metal.zig");
pub const ca = @import("quartzcore.zig");

test "smoke: device, queue, buffer, layer" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    // A device may be absent in a headless CI VM; skip rather than fail.
    const device = mtl.createSystemDefaultDevice() orelse return error.SkipZigTest;
    defer device.release();

    // Reading a real property proves selector dispatch + NSString round-trips.
    const name = device.name().utf8();
    try std.testing.expect(name.len > 0);

    const queue = device.newCommandQueue() orelse return error.MetalQueueFailed;
    defer queue.release();

    const buffer = device.newBuffer(256, .{}) orelse return error.MetalBufferFailed;
    defer buffer.release();
    try std.testing.expectEqual(@as(types.UInteger, 256), buffer.length());

    // Class-method factory + struct-argument selector (proves the ABI path).
    const layer = ca.MetalLayer.layer();
    layer.setDevice(device);
    layer.setPixelFormat(.bgra8unorm);
    layer.setDrawableSize(.{ .width = 64, .height = 64 });
    try std.testing.expectEqual(types.PixelFormat.bgra8unorm, layer.pixelFormat());

    // Struct-return selector (CGSize) over msgSend.
    const size = layer.drawableSize();
    try std.testing.expectEqual(@as(f64, 64), size.width);
}

test "all wrapper decls compile" {
    // Force semantic analysis of every binding (and its methods) so unused
    // wrappers still fail the build if a selector signature is wrong.
    inline for (.{ types, ns, mtl, ca }) |mod| {
        std.testing.refAllDecls(mod);
        inline for (comptime std.meta.declarations(mod)) |decl| {
            const field = @field(mod, decl.name);
            if (@TypeOf(field) == type and @typeInfo(field) == .@"struct") {
                std.testing.refAllDecls(field);
            }
        }
    }
}
