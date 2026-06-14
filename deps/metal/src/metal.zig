//! Metal (`MTL`) bindings — the curated subset the RHI backend needs. Each type
//! is a typed view over an `objc_object*`; methods forward to `objc_msgSend`
//! with the selector named in the matching `metal-cpp` header. Extend on demand.

const std = @import("std");
const objc = @import("objc");
const wrapper = @import("wrapper.zig");
const types = @import("types.zig");
const ns = @import("foundation.zig");

pub const UInteger = types.UInteger;

/// `MTLCreateSystemDefaultDevice()` — a C function exported by the Metal
/// framework (not an Objective-C method). Returns nil if Metal is unavailable.
extern fn MTLCreateSystemDefaultDevice() objc.c.id;

/// Returns the system default GPU device, or null if none is available.
/// Owned by the caller — `release()` when done.
pub fn createSystemDefaultDevice() ?Device {
    return Device.fromId(MTLCreateSystemDefaultDevice());
}

// -- Device ----------------------------------------------------------------

pub const Device = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(Device);
    pub const fromId = W.fromId;
    pub const fromObject = W.fromObject;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `-name` (autoreleased `NSString`).
    pub fn name(self: Device) ns.String {
        return W.msgObject(self, ns.String, "name", .{}).?;
    }

    /// `-isLowPower` — true for integrated GPUs.
    pub fn isLowPower(self: Device) bool {
        return self.obj.msgSend(bool, objc.sel("isLowPower"), .{});
    }

    /// `-newCommandQueue`. Owned by the caller.
    pub fn newCommandQueue(self: Device) ?CommandQueue {
        return W.msgObject(self, CommandQueue, "newCommandQueue", .{});
    }

    /// `-newBufferWithLength:options:`. Owned by the caller.
    pub fn newBuffer(self: Device, length: UInteger, options: types.ResourceOptions) ?Buffer {
        return W.msgObject(self, Buffer, "newBufferWithLength:options:", .{ length, options.toInt() });
    }

    /// `-newBufferWithBytes:length:options:` — initialise from CPU memory.
    pub fn newBufferWithBytes(self: Device, bytes: *const anyopaque, length: UInteger, options: types.ResourceOptions) ?Buffer {
        return W.msgObject(self, Buffer, "newBufferWithBytes:length:options:", .{ bytes, length, options.toInt() });
    }

    /// `-newTextureWithDescriptor:`. Owned by the caller.
    pub fn newTexture(self: Device, descriptor: TextureDescriptor) ?Texture {
        return W.msgObject(self, Texture, "newTextureWithDescriptor:", .{descriptor.obj.value});
    }

    /// `-newDepthStencilStateWithDescriptor:`. Owned by the caller.
    pub fn newDepthStencilState(self: Device, descriptor: DepthStencilDescriptor) ?DepthStencilState {
        return W.msgObject(self, DepthStencilState, "newDepthStencilStateWithDescriptor:", .{descriptor.obj.value});
    }

    /// `-newLibraryWithSource:options:error:`. On failure returns null and, if
    /// `out_err` is non-null, stores the `NSError`. Owned by the caller.
    pub fn newLibraryWithSource(self: Device, source: ns.String, options: ?CompileOptions, out_err: ?*?ns.Error) ?Library {
        var err_id: objc.c.id = null;
        const opt_id: objc.c.id = if (options) |o| o.obj.value else null;
        const result = self.obj.msgSend(objc.Object, objc.sel("newLibraryWithSource:options:error:"), .{ source.obj.value, opt_id, &err_id });
        if (out_err) |slot| slot.* = ns.Error.fromId(err_id);
        return Library.fromId(result.value);
    }

    /// `-newRenderPipelineStateWithDescriptor:error:`. Owned by the caller.
    pub fn newRenderPipelineState(self: Device, descriptor: RenderPipelineDescriptor, out_err: ?*?ns.Error) ?RenderPipelineState {
        var err_id: objc.c.id = null;
        const result = self.obj.msgSend(objc.Object, objc.sel("newRenderPipelineStateWithDescriptor:error:"), .{ descriptor.obj.value, &err_id });
        if (out_err) |slot| slot.* = ns.Error.fromId(err_id);
        return RenderPipelineState.fromId(result.value);
    }
};

// -- Command submission ----------------------------------------------------

pub const CommandQueue = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(CommandQueue);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `-commandBuffer` (autoreleased).
    pub fn commandBuffer(self: CommandQueue) ?CommandBuffer {
        return W.msgObject(self, CommandBuffer, "commandBuffer", .{});
    }

    /// `-setLabel:`.
    pub fn setLabel(self: CommandQueue, label: ns.String) void {
        self.obj.msgSend(void, objc.sel("setLabel:"), .{label.obj.value});
    }
};

pub const CommandBuffer = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(CommandBuffer);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `-renderCommandEncoderWithDescriptor:` (autoreleased).
    pub fn renderCommandEncoder(self: CommandBuffer, descriptor: RenderPassDescriptor) ?RenderCommandEncoder {
        return W.msgObject(self, RenderCommandEncoder, "renderCommandEncoderWithDescriptor:", .{descriptor.obj.value});
    }

    /// `-presentDrawable:` — schedules the drawable to be presented.
    /// `drawable` is any object conforming to `MTLDrawable` (e.g. a
    /// `CAMetalDrawable`); pass its underlying `id`.
    pub fn presentDrawable(self: CommandBuffer, drawable: objc.c.id) void {
        self.obj.msgSend(void, objc.sel("presentDrawable:"), .{drawable});
    }

    /// `-commit`.
    pub fn commit(self: CommandBuffer) void {
        self.obj.msgSend(void, objc.sel("commit"), .{});
    }

    /// `-waitUntilCompleted`.
    pub fn waitUntilCompleted(self: CommandBuffer) void {
        self.obj.msgSend(void, objc.sel("waitUntilCompleted"), .{});
    }
};

pub const RenderCommandEncoder = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(RenderCommandEncoder);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `-setRenderPipelineState:`.
    pub fn setRenderPipelineState(self: RenderCommandEncoder, state: RenderPipelineState) void {
        self.obj.msgSend(void, objc.sel("setRenderPipelineState:"), .{state.obj.value});
    }

    /// `-setVertexBuffer:offset:atIndex:`.
    pub fn setVertexBuffer(self: RenderCommandEncoder, buffer: Buffer, offset: UInteger, index: UInteger) void {
        self.obj.msgSend(void, objc.sel("setVertexBuffer:offset:atIndex:"), .{ buffer.obj.value, offset, index });
    }

    /// `-setVertexBytes:length:atIndex:` — inline constant data (push constants).
    pub fn setVertexBytes(self: RenderCommandEncoder, bytes: *const anyopaque, length: UInteger, index: UInteger) void {
        self.obj.msgSend(void, objc.sel("setVertexBytes:length:atIndex:"), .{ bytes, length, index });
    }

    /// `-setViewport:`.
    pub fn setViewport(self: RenderCommandEncoder, viewport: types.Viewport) void {
        self.obj.msgSend(void, objc.sel("setViewport:"), .{viewport});
    }

    /// `-setDepthStencilState:`.
    pub fn setDepthStencilState(self: RenderCommandEncoder, state: DepthStencilState) void {
        self.obj.msgSend(void, objc.sel("setDepthStencilState:"), .{state.obj.value});
    }

    /// `-setScissorRect:`.
    pub fn setScissorRect(self: RenderCommandEncoder, rect: types.ScissorRect) void {
        self.obj.msgSend(void, objc.sel("setScissorRect:"), .{rect});
    }

    /// `-drawPrimitives:vertexStart:vertexCount:`.
    pub fn drawPrimitives(self: RenderCommandEncoder, primitive_type: types.PrimitiveType, vertex_start: UInteger, vertex_count: UInteger) void {
        self.obj.msgSend(void, objc.sel("drawPrimitives:vertexStart:vertexCount:"), .{ primitive_type, vertex_start, vertex_count });
    }

    /// `-drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:`.
    pub fn drawIndexedPrimitives(self: RenderCommandEncoder, primitive_type: types.PrimitiveType, index_count: UInteger, index_type: types.IndexType, index_buffer: Buffer, index_buffer_offset: UInteger) void {
        self.obj.msgSend(void, objc.sel("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:"), .{ primitive_type, index_count, index_type, index_buffer.obj.value, index_buffer_offset });
    }

    /// `-endEncoding`.
    pub fn endEncoding(self: RenderCommandEncoder) void {
        self.obj.msgSend(void, objc.sel("endEncoding"), .{});
    }
};

// -- Resources -------------------------------------------------------------

pub const Buffer = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(Buffer);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `-contents` — CPU-accessible pointer (shared/managed storage only).
    pub fn contents(self: Buffer) ?*anyopaque {
        return self.obj.msgSend(?*anyopaque, objc.sel("contents"), .{});
    }

    /// `-length`.
    pub fn length(self: Buffer) UInteger {
        return self.obj.msgSend(UInteger, objc.sel("length"), .{});
    }
};

pub const Texture = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(Texture);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    pub fn width(self: Texture) UInteger {
        return self.obj.msgSend(UInteger, objc.sel("width"), .{});
    }

    pub fn height(self: Texture) UInteger {
        return self.obj.msgSend(UInteger, objc.sel("height"), .{});
    }
};

// -- Shaders / pipeline state ----------------------------------------------

pub const Library = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(Library);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `-newFunctionWithName:`. Owned by the caller.
    pub fn newFunction(self: Library, function_name: ns.String) ?Function {
        return W.msgObject(self, Function, "newFunctionWithName:", .{function_name.obj.value});
    }
};

pub const Function = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(Function);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;
};

pub const RenderPipelineState = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(RenderPipelineState);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;
};

pub const DepthStencilState = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(DepthStencilState);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;
};

// -- Descriptors (created via alloc+init or a class factory) ---------------

pub const CompileOptions = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(CompileOptions);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    pub fn init() CompileOptions {
        return wrapper.allocInit(CompileOptions, "MTLCompileOptions");
    }
};

pub const RenderPipelineDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(RenderPipelineDescriptor);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    pub fn init() RenderPipelineDescriptor {
        return wrapper.allocInit(RenderPipelineDescriptor, "MTLRenderPipelineDescriptor");
    }

    pub fn setVertexFunction(self: RenderPipelineDescriptor, function: Function) void {
        self.obj.msgSend(void, objc.sel("setVertexFunction:"), .{function.obj.value});
    }

    pub fn setFragmentFunction(self: RenderPipelineDescriptor, function: Function) void {
        self.obj.msgSend(void, objc.sel("setFragmentFunction:"), .{function.obj.value});
    }

    pub fn setLabel(self: RenderPipelineDescriptor, label: ns.String) void {
        self.obj.msgSend(void, objc.sel("setLabel:"), .{label.obj.value});
    }

    pub fn setVertexDescriptor(self: RenderPipelineDescriptor, vertex_descriptor: VertexDescriptor) void {
        self.obj.msgSend(void, objc.sel("setVertexDescriptor:"), .{vertex_descriptor.obj.value});
    }

    pub fn setDepthAttachmentPixelFormat(self: RenderPipelineDescriptor, format: types.PixelFormat) void {
        self.obj.msgSend(void, objc.sel("setDepthAttachmentPixelFormat:"), .{format});
    }

    /// `-colorAttachments` (autoreleased array).
    pub fn colorAttachments(self: RenderPipelineDescriptor) RenderPipelineColorAttachmentDescriptorArray {
        return W.msgObject(self, RenderPipelineColorAttachmentDescriptorArray, "colorAttachments", .{}).?;
    }
};

// -- MTLVertexDescriptor ---------------------------------------------------

pub const VertexDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(VertexDescriptor);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `+vertexDescriptor` (autoreleased).
    pub fn vertexDescriptor() VertexDescriptor {
        return wrapper.classMsgObject(VertexDescriptor, "MTLVertexDescriptor", "vertexDescriptor", .{}).?;
    }

    pub fn attributes(self: VertexDescriptor) VertexAttributeDescriptorArray {
        return W.msgObject(self, VertexAttributeDescriptorArray, "attributes", .{}).?;
    }

    pub fn layouts(self: VertexDescriptor) VertexBufferLayoutDescriptorArray {
        return W.msgObject(self, VertexBufferLayoutDescriptorArray, "layouts", .{}).?;
    }
};

pub const VertexAttributeDescriptorArray = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(VertexAttributeDescriptorArray);
    pub const fromId = W.fromId;
    pub fn object(self: VertexAttributeDescriptorArray, index: UInteger) VertexAttributeDescriptor {
        return W.msgObject(self, VertexAttributeDescriptor, "objectAtIndexedSubscript:", .{index}).?;
    }
};

pub const VertexAttributeDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(VertexAttributeDescriptor);
    pub const fromId = W.fromId;
    pub fn setFormat(self: VertexAttributeDescriptor, format: types.VertexFormat) void {
        self.obj.msgSend(void, objc.sel("setFormat:"), .{format});
    }
    pub fn setOffset(self: VertexAttributeDescriptor, offset: UInteger) void {
        self.obj.msgSend(void, objc.sel("setOffset:"), .{offset});
    }
    pub fn setBufferIndex(self: VertexAttributeDescriptor, index: UInteger) void {
        self.obj.msgSend(void, objc.sel("setBufferIndex:"), .{index});
    }
};

pub const VertexBufferLayoutDescriptorArray = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(VertexBufferLayoutDescriptorArray);
    pub const fromId = W.fromId;
    pub fn object(self: VertexBufferLayoutDescriptorArray, index: UInteger) VertexBufferLayoutDescriptor {
        return W.msgObject(self, VertexBufferLayoutDescriptor, "objectAtIndexedSubscript:", .{index}).?;
    }
};

pub const VertexBufferLayoutDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(VertexBufferLayoutDescriptor);
    pub const fromId = W.fromId;
    pub fn setStride(self: VertexBufferLayoutDescriptor, stride: UInteger) void {
        self.obj.msgSend(void, objc.sel("setStride:"), .{stride});
    }
    pub fn setStepFunction(self: VertexBufferLayoutDescriptor, step: types.VertexStepFunction) void {
        self.obj.msgSend(void, objc.sel("setStepFunction:"), .{step});
    }
    pub fn setStepRate(self: VertexBufferLayoutDescriptor, rate: UInteger) void {
        self.obj.msgSend(void, objc.sel("setStepRate:"), .{rate});
    }
};

pub const RenderPipelineColorAttachmentDescriptorArray = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(RenderPipelineColorAttachmentDescriptorArray);
    pub const fromId = W.fromId;

    /// `-objectAtIndexedSubscript:`.
    pub fn object(self: RenderPipelineColorAttachmentDescriptorArray, index: UInteger) RenderPipelineColorAttachmentDescriptor {
        return W.msgObject(self, RenderPipelineColorAttachmentDescriptor, "objectAtIndexedSubscript:", .{index}).?;
    }
};

pub const RenderPipelineColorAttachmentDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(RenderPipelineColorAttachmentDescriptor);
    pub const fromId = W.fromId;

    pub fn setPixelFormat(self: RenderPipelineColorAttachmentDescriptor, format: types.PixelFormat) void {
        self.obj.msgSend(void, objc.sel("setPixelFormat:"), .{format});
    }
};

pub const RenderPassDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(RenderPassDescriptor);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `+renderPassDescriptor` (autoreleased).
    pub fn renderPassDescriptor() RenderPassDescriptor {
        return wrapper.classMsgObject(RenderPassDescriptor, "MTLRenderPassDescriptor", "renderPassDescriptor", .{}).?;
    }

    /// `-colorAttachments` (autoreleased array).
    pub fn colorAttachments(self: RenderPassDescriptor) RenderPassColorAttachmentDescriptorArray {
        return W.msgObject(self, RenderPassColorAttachmentDescriptorArray, "colorAttachments", .{}).?;
    }

    /// `-depthAttachment` (autoreleased).
    pub fn depthAttachment(self: RenderPassDescriptor) RenderPassDepthAttachmentDescriptor {
        return W.msgObject(self, RenderPassDepthAttachmentDescriptor, "depthAttachment", .{}).?;
    }
};

pub const RenderPassDepthAttachmentDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(RenderPassDepthAttachmentDescriptor);
    pub const fromId = W.fromId;

    pub fn setTexture(self: RenderPassDepthAttachmentDescriptor, texture: Texture) void {
        self.obj.msgSend(void, objc.sel("setTexture:"), .{texture.obj.value});
    }

    pub fn setLoadAction(self: RenderPassDepthAttachmentDescriptor, action: types.LoadAction) void {
        self.obj.msgSend(void, objc.sel("setLoadAction:"), .{action});
    }

    pub fn setStoreAction(self: RenderPassDepthAttachmentDescriptor, action: types.StoreAction) void {
        self.obj.msgSend(void, objc.sel("setStoreAction:"), .{action});
    }

    pub fn setClearDepth(self: RenderPassDepthAttachmentDescriptor, depth: f64) void {
        self.obj.msgSend(void, objc.sel("setClearDepth:"), .{depth});
    }
};

pub const RenderPassColorAttachmentDescriptorArray = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(RenderPassColorAttachmentDescriptorArray);
    pub const fromId = W.fromId;

    pub fn object(self: RenderPassColorAttachmentDescriptorArray, index: UInteger) RenderPassColorAttachmentDescriptor {
        return W.msgObject(self, RenderPassColorAttachmentDescriptor, "objectAtIndexedSubscript:", .{index}).?;
    }
};

pub const RenderPassColorAttachmentDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(RenderPassColorAttachmentDescriptor);
    pub const fromId = W.fromId;

    pub fn setTexture(self: RenderPassColorAttachmentDescriptor, texture: Texture) void {
        self.obj.msgSend(void, objc.sel("setTexture:"), .{texture.obj.value});
    }

    pub fn setLoadAction(self: RenderPassColorAttachmentDescriptor, action: types.LoadAction) void {
        self.obj.msgSend(void, objc.sel("setLoadAction:"), .{action});
    }

    pub fn setStoreAction(self: RenderPassColorAttachmentDescriptor, action: types.StoreAction) void {
        self.obj.msgSend(void, objc.sel("setStoreAction:"), .{action});
    }

    pub fn setClearColor(self: RenderPassColorAttachmentDescriptor, color: types.ClearColor) void {
        self.obj.msgSend(void, objc.sel("setClearColor:"), .{color});
    }
};

pub const TextureDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(TextureDescriptor);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    pub fn init() TextureDescriptor {
        return wrapper.allocInit(TextureDescriptor, "MTLTextureDescriptor");
    }

    /// `+texture2DDescriptorWithPixelFormat:width:height:mipmapped:`.
    pub fn texture2D(format: types.PixelFormat, w: UInteger, h: UInteger, mipmapped: bool) TextureDescriptor {
        return wrapper.classMsgObject(TextureDescriptor, "MTLTextureDescriptor", "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ format, w, h, mipmapped }).?;
    }

    pub fn setPixelFormat(self: TextureDescriptor, format: types.PixelFormat) void {
        self.obj.msgSend(void, objc.sel("setPixelFormat:"), .{format});
    }

    pub fn setWidth(self: TextureDescriptor, w: UInteger) void {
        self.obj.msgSend(void, objc.sel("setWidth:"), .{w});
    }

    pub fn setHeight(self: TextureDescriptor, h: UInteger) void {
        self.obj.msgSend(void, objc.sel("setHeight:"), .{h});
    }

    pub fn setTextureType(self: TextureDescriptor, texture_type: types.TextureType) void {
        self.obj.msgSend(void, objc.sel("setTextureType:"), .{texture_type});
    }

    pub fn setUsage(self: TextureDescriptor, usage: types.TextureUsage) void {
        self.obj.msgSend(void, objc.sel("setUsage:"), .{usage.toInt()});
    }

    pub fn setStorageMode(self: TextureDescriptor, mode: types.StorageMode) void {
        self.obj.msgSend(void, objc.sel("setStorageMode:"), .{@as(UInteger, @intFromEnum(mode))});
    }
};

pub const DepthStencilDescriptor = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(DepthStencilDescriptor);
    pub const fromId = W.fromId;
    pub const retain = W.retain;
    pub const release = W.release;

    pub fn init() DepthStencilDescriptor {
        return wrapper.allocInit(DepthStencilDescriptor, "MTLDepthStencilDescriptor");
    }

    pub fn setDepthCompareFunction(self: DepthStencilDescriptor, func: types.CompareFunction) void {
        self.obj.msgSend(void, objc.sel("setDepthCompareFunction:"), .{func});
    }

    pub fn setDepthWriteEnabled(self: DepthStencilDescriptor, enabled: bool) void {
        self.obj.msgSend(void, objc.sel("setDepthWriteEnabled:"), .{enabled});
    }
};
