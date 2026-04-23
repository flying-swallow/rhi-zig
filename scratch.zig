const std = @import("std");
const zd3d12 = @import("zd3d12");
pub fn main() void {
    std.debug.print("{}\n", .{@TypeOf(zd3d12)});
}
