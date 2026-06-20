//! Shared plumbing for the typed Objective-C wrappers.
//!
//! Every Metal / Foundation / QuartzCore class is modelled the same way
//! `metal-cpp` models it: a thin typed view over an `objc_object*`. In Zig that
//! is a struct with a single `obj: objc.Object` field whose methods forward to
//! `objc.Object.msgSend` (the analogue of metal-cpp's `Object::sendMessage`).
//!
//! `Wrapper(Self)` returns a struct of declarations common to every wrapper.
//! Because `usingnamespace` is being removed from the language, callers pull the
//! pieces they want explicitly, e.g.:
//!
//! ```zig
//! pub const Device = struct {
//!     obj: objc.Object,
//!     const W = wrapper.Wrapper(Device);
//!     pub const fromId = W.fromId;
//!     pub const retain = W.retain;
//!     pub const release = W.release;
//!     // ... class-specific methods ...
//! };
//! ```
//!
//! ## Ownership
//! Mirror Cocoa's conventions. Anything returned from a `new*` / `alloc`+`init`
//! method is owned by the caller (retain count 1) — release it (`defer x.release()`).
//! Property getters (`name`, `nextDrawable`, `colorAttachments`, ...) return
//! autoreleased objects you do **not** own; `retain()` only if you keep them past
//! the current autorelease pool.

const std = @import("std");
const objc = @import("objc");

pub const Object = objc.Object;
pub const Class = objc.Class;
pub const Sel = objc.Sel;
pub const id = objc.c.id;

/// Look up a registered Objective-C class by name. Asserts it exists — the
/// system frameworks are linked, so a miss means a typo in the class name.
pub inline fn class(comptime name: [:0]const u8) Class {
    return objc.getClass(name) orelse
        std.debug.panic("objc class not found: {s}", .{name});
}

/// Common declarations shared by every wrapper struct `Self`, which must have a
/// single field `obj: objc.Object`.
pub fn Wrapper(comptime Self: type) type {
    return struct {
        /// Wrap a raw `id`. Returns null for a nil pointer so callers can map
        /// nullable Objective-C returns onto Zig optionals.
        pub inline fn fromId(raw: id) ?Self {
            const o = objc.Object.fromId(raw);
            if (o.value == null) return null;
            return Self{ .obj = o };
        }

        /// Wrap an `objc.Object`, propagating nil as null.
        pub inline fn fromObject(o: objc.Object) ?Self {
            if (o.value == null) return null;
            return Self{ .obj = o };
        }

        /// Send a message whose result is another wrapped object type `T`
        /// (`T` must itself expose `fromId`). Returns null when the result is nil.
        pub inline fn msgObject(self: Self, comptime T: type, comptime sel: [:0]const u8, args: anytype) ?T {
            const result = self.obj.msgSend(objc.Object, objc.sel(sel), args);
            return T.fromId(result.value);
        }

        /// Send a message with a plain (non-object) return type `T`.
        pub inline fn msg(self: Self, comptime T: type, comptime sel: [:0]const u8, args: anytype) T {
            return self.obj.msgSend(T, objc.sel(sel), args);
        }

        pub inline fn retain(self: Self) void {
            _ = self.obj.retain();
        }

        pub inline fn release(self: Self) void {
            self.obj.release();
        }
    };
}

/// `alloc` + `init` a fresh instance of `class_name`, returning it wrapped as
/// `T`. Used for descriptor objects (`MTLRenderPipelineDescriptor`, ...).
pub fn allocInit(comptime T: type, comptime class_name: [:0]const u8) T {
    const cls = class(class_name);
    const allocated = cls.msgSend(objc.Object, objc.sel("alloc"), .{});
    const inited = allocated.msgSend(objc.Object, objc.sel("init"), .{});
    return T{ .obj = inited };
}

/// Send a class (static) message returning a wrapped object type `T`.
pub fn classMsgObject(comptime T: type, comptime class_name: [:0]const u8, comptime sel: [:0]const u8, args: anytype) ?T {
    const cls = class(class_name);
    const result = cls.msgSend(objc.Object, objc.sel(sel), args);
    return T.fromId(result.value);
}
