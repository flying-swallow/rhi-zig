//! Foundation (`NS`) bindings — the minimal slice the Metal layer needs:
//! strings (for shader source, labels, device names), error out-parameters, and
//! arrays. Mirrors the relevant parts of `metal-cpp/Foundation`.

const std = @import("std");
const objc = @import("objc");
const wrapper = @import("wrapper.zig");
const types = @import("types.zig");

pub const UInteger = types.UInteger;
pub const Integer = types.Integer;

/// `NSString`.
pub const String = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(String);
    pub const fromId = W.fromId;
    pub const fromObject = W.fromObject;
    pub const retain = W.retain;
    pub const release = W.release;

    /// Create an autoreleased `NSString` from a null-terminated UTF-8 slice
    /// (`+[NSString stringWithUTF8String:]`).
    pub fn fromUtf8(text: [:0]const u8) String {
        return wrapper.classMsgObject(String, "NSString", "stringWithUTF8String:", .{text.ptr}).?;
    }

    /// Create an autoreleased `NSString` from a (not necessarily NUL-terminated)
    /// UTF-8 byte slice (`+[NSString stringWithBytes:length:encoding:]`,
    /// `NSUTF8StringEncoding == 4`).
    pub fn fromUtf8Slice(bytes: []const u8) String {
        return wrapper.classMsgObject(String, "NSString", "stringWithBytes:length:encoding:", .{ bytes.ptr, @as(UInteger, bytes.len), @as(UInteger, 4) }).?;
    }

    /// The string's contents as a null-terminated UTF-8 slice (`-UTF8String`).
    /// The returned pointer is owned by the `NSString`; copy if you need it to
    /// outlive the receiver.
    pub fn utf8(self: String) [:0]const u8 {
        const ptr = self.obj.msgSend([*:0]const u8, objc.sel("UTF8String"), .{});
        return std.mem.span(ptr);
    }

    /// `-length` (number of UTF-16 code units).
    pub fn length(self: String) UInteger {
        return self.obj.msgSend(UInteger, objc.sel("length"), .{});
    }
};

/// `NSError`. Typically received via an out-parameter from a failing
/// `new*WithError:` call.
pub const Error = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(Error);
    pub const fromId = W.fromId;
    pub const fromObject = W.fromObject;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `-localizedDescription` — a human-readable message.
    pub fn localizedDescription(self: Error) String {
        return W.msgObject(self, String, "localizedDescription", .{}).?;
    }

    /// `-code`.
    pub fn code(self: Error) Integer {
        return self.obj.msgSend(Integer, objc.sel("code"), .{});
    }
};

/// `NSArray`.
pub const Array = struct {
    obj: objc.Object,
    const W = wrapper.Wrapper(Array);
    pub const fromId = W.fromId;
    pub const fromObject = W.fromObject;
    pub const retain = W.retain;
    pub const release = W.release;

    /// `-count`.
    pub fn count(self: Array) UInteger {
        return self.obj.msgSend(UInteger, objc.sel("count"), .{});
    }

    /// `-objectAtIndex:`, wrapped as `T`.
    pub fn objectAtIndex(self: Array, comptime T: type, index: UInteger) ?T {
        return W.msgObject(self, T, "objectAtIndex:", .{index});
    }
};
