//! QuartzCore (`CA`) bindings — `CAMetalLayer` and `CAMetalDrawable`, the bridge
//! between a window surface and Metal. Mirrors `metal-cpp/QuartzCore`.

const std = @import("std");
const objc = @import("objc");
const wrapper = @import("wrapper.zig");
const types = @import("types.zig");
const mtl = @import("metal.zig");

/// `CAMetalLayer`.
pub const MetalLayer = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(MetalLayer);
    pub const fromId = W.fromId;
    pub const fromObject = W.fromObject;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `+layer` — a fresh autoreleased layer.
    pub fn layer() MetalLayer {
        return wrapper.classMsgObject(MetalLayer, "CAMetalLayer", "layer", .{}).?;
    }

    /// `-setDevice:` — the Metal device the layer draws with.
    pub fn setDevice(self: MetalLayer, device: mtl.Device) void {
        self.obj.msgSend(void, objc.sel("setDevice:"), .{device.obj.value});
    }

    /// `-setPixelFormat:`.
    pub fn setPixelFormat(self: MetalLayer, format: types.PixelFormat) void {
        self.obj.msgSend(void, objc.sel("setPixelFormat:"), .{format});
    }

    /// `-pixelFormat`.
    pub fn pixelFormat(self: MetalLayer) types.PixelFormat {
        return self.obj.msgSend(types.PixelFormat, objc.sel("pixelFormat"), .{});
    }

    /// `-setDrawableSize:`.
    pub fn setDrawableSize(self: MetalLayer, size: types.CGSize) void {
        self.obj.msgSend(void, objc.sel("setDrawableSize:"), .{size});
    }

    /// `-drawableSize`.
    pub fn drawableSize(self: MetalLayer) types.CGSize {
        return self.obj.msgSend(types.CGSize, objc.sel("drawableSize"), .{});
    }

    /// `-nextDrawable` (autoreleased). Returns null if no drawable is available
    /// before the timeout.
    pub fn nextDrawable(self: MetalLayer) ?MetalDrawable {
        return W.msgObject(self, MetalDrawable, "nextDrawable", .{});
    }
};

/// `CAMetalDrawable` (conforms to `MTLDrawable`).
pub const MetalDrawable = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(MetalDrawable);
    pub const fromId = W.fromId;
    pub const fromObject = W.fromObject;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `-texture` — the renderable texture backing this drawable.
    pub fn texture(self: MetalDrawable) mtl.Texture {
        return W.msgObject(self, mtl.Texture, "texture", .{}).?;
    }

    /// The underlying `id` to hand to `CommandBuffer.presentDrawable`.
    pub fn id(self: MetalDrawable) objc.c.id {
        return self.obj.value;
    }
};
