const std = @import("std");
const zla = @import("zla"); 

pub const Vertex = struct {
    position: usize,
    normal: ?usize,
    textureCoordinate: ?usize,
};

pub const Face = struct {
    vertices: []Vertex,
};

pub const Line = struct {
    vertices: [2]Vertex,
};


pub const Model = struct {
    const Self = @This();

    //allocator: std.mem.Allocator,
    //arena: std.heap.ArenaAllocator,

    positions: []@Vector(4, f32),
    normals: []@Vector(4, f32),
    textureCoordinates: []@Vector(2, f32),
    //faces: [],
    //lines: []Line,
    //objects: []Object,

    //pub fn deinit(self: *Self) void {
    //    self.allocator.free(self.positions);
    //    self.allocator.free(self.normals);
    //    self.allocator.free(self.textureCoordinates);
    //    self.allocator.free(self.faces);
    //    self.allocator.free(self.lines);
    //    self.allocator.free(self.objects);
    //    self.arena.deinit();
    //    self.* = undefined;
    //}
};



pub fn load(
    allocator: std.mem.Allocator,

) void {

}
