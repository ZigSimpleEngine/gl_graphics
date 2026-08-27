const std = @import("std");

// High-level GL ES 3.0 abstractions (gl_graphics)
// Each module follows opaque pattern + Editor (MethodChain) for deferred batched GL calls.

pub const Texture = @import("texture.zig").Texture;
pub const Buffer = @import("buffer.zig").Buffer;
pub const Mesh = @import("mesh.zig").Mesh;
pub const Framebuffer = @import("framebuffer.zig").Framebuffer;

pub const Map = @import("map.zig").Map;
pub const Transform = @import("transform.zig").Transform;
pub const Model = @import("model.zig").Model;
pub const Camera = @import("camera.zig").Camera;

pub const ShaderProgram = @import("shader_program.zig").ShaderProgram;
pub const Material = @import("material.zig").Material;

pub const common = @import("descriptors/common.zig");
pub const descriptors = struct {
    pub const GlslDescriptor = @import("descriptors/glsl.zig").GlslDescriptor;
    pub const VertexDescriptor = @import("descriptors/vert.zig").VertexDescriptor;
    pub const FragmentDescriptor = @import("descriptors/frag.zig").FragmentDescriptor;
    pub const Common = common;
};

// Re-export helpers for convenience
pub const gl = @import("gl");
pub const math = @import("math");
pub const assets_manager = @import("assets_manager");

test "smoke — texture opaque + editor chain" {
    // This test only validates type-level API without a real GL context (no loader).
    // We test struct layout and method chain compilation.
    _ = Texture;
    _ = Buffer(u16);
    _ = Mesh(u16, struct { pos: math.Vec(3, f32), uv: math.Vec(2, f32) });
    _ = Transform(f32);
    _ = Map(.my_map, struct { a: i32 });
    const DummyVert = struct {
        pub const Vertex = struct { pos: math.Vec(3, f32) };
        pub const Uniform = struct { uMvp: math.Mat(4, 4, f32) };
        pub const IdCache = struct { uMvp: i32 };
        pub var id: u32 = 0;
        pub fn instance() u32 { return 1; }
        pub fn dispose() void {}
        pub const Editor = struct {
            _program: u32,
            pub fn init(p: u32) @This() { return .{ ._program = p }; }
            pub fn setUniform(self: *@This(), u: Uniform) *@This() { _ = u; return self; }
            pub fn set_uMvp(self: *@This(), v: math.Mat(4, 4, f32)) *@This() { _ = v; return self; }
            pub fn apply(self: *@This()) void { _ = self; }
        };
        pub fn edit(p: u32) Editor { return Editor.init(p); }
    };
    const DummyFrag = struct {
        pub const Uniform = struct { uColor: math.Vec(4, f32) };
        pub const IdCache = struct { uColor: i32 };
        pub var id: u32 = 0;
        pub fn instance() u32 { return 2; }
        pub fn dispose() void {}
        pub const Editor = struct {
            _program: u32,
            pub fn init(p: u32) @This() { return .{ ._program = p }; }
            pub fn setUniform(self: *@This(), u: Uniform) *@This() { _ = u; return self; }
            pub fn apply(self: *@This()) void { _ = self; }
        };
        pub fn edit(p: u32) Editor { return Editor.init(p); }
    };
    _ = ShaderProgram(DummyVert, DummyFrag);
    _ = Material(ShaderProgram(DummyVert, DummyFrag));
    _ = Framebuffer;
    _ = Camera(f32);
}

test "map get/set" {
    const MyMap = Map(.test_map, i32);
    MyMap.set(42);
    try std.testing.expectEqual(@as(i32, 42), MyMap.get(0));
}

test "transform hierarchy basic" {
    const T = Transform(f32);
    const gpa = std.testing.allocator;
    const root = try T.create(gpa);
    defer root.destroy(gpa);
    const child = try T.create(gpa);
    defer child.destroy(gpa);
    child.position().* = math.Vec(3, f32).init(.{ 1, 0, 0 });
    try root.addChild(gpa, child);
    try std.testing.expectEqual(@as(usize, 1), root.getChildrenCount());
    try std.testing.expect(child.getParent() == root);
    root.recalculateTransformMatricesDownward();
    _ = root.getMatrix();
    _ = child.getMatrix();
}

test "mesh layout compile" {
    const Vertex = struct {
        position: math.Vec(3, f32),
        texCoord: math.Vec(2, f32),
        normal: math.Vec(3, f32),
    };
    const M = Mesh(u16, Vertex);
    // Verify layout computed
    try std.testing.expect(M.Layout.len == 3);
    try std.testing.expectEqual(@as(i32, 3), M.Layout[0].size);
    try std.testing.expectEqual(@as(i32, 2), M.Layout[1].size);
}

test "descriptors parse" {
    // Force import of descriptor common tests
    _ = common;
    // Also ensure Glsl/Vert/Frag descriptors are referenced
    _ = descriptors.GlslDescriptor;
    _ = descriptors.VertexDescriptor;
    _ = descriptors.FragmentDescriptor;
}

test "descriptor common tests via refAllDecls" {
    std.testing.refAllDecls(common);
}

test "descriptor bake integration" {
    const assets_manager_mod = @import("assets_manager");
    var glsl_desc = descriptors.GlslDescriptor{};
    var vert_desc = descriptors.VertexDescriptor{};
    var frag_desc = descriptors.FragmentDescriptor{};
    var dir_desc = assets_manager_mod.descriptors.ZigDirectoryDescriptor{};
    var file_desc = assets_manager_mod.descriptors.ZigEmbedFileDescriptor{};
    const descs = [_]*const assets_manager_mod.descriptors.Descriptor{
        &vert_desc.descriptor(), &frag_desc.descriptor(), &glsl_desc.descriptor(), &dir_desc.descriptor(), &file_desc.descriptor(),
    };
    _ = descs;
    try std.testing.expect(true);
}

test "mesh editor chain const" {
    const V = struct { pos: math.Vec(3, f32) };
    const M = Mesh(u16, V);
    const gpa = std.testing.allocator;
    const mesh = try M.create(gpa);
    defer mesh.destroy(gpa);
    const verts = [_]V{ .{ .pos = math.Vec(3, f32).zero() } };
    // Exact chain from user report — should compile with *const set*
    mesh.edit().setVertices(verts[0..]).apply();
    // Also test chained setIndices
    const inds = [_]u16{0};
    mesh.edit().setVertices(verts[0..]).setIndices(inds[0..]).apply();
}

test "texture editor chain const" {
    const gpa = std.testing.allocator;
    const tex = try Texture.create(gpa);
    defer tex.destroy(gpa);
    tex.edit().setMinFilter(.linear).setMagFilter(.linear).setWrap(.repeat, .repeat).apply();
    tex.edit().setWrapS(.clamp_to_edge).setWrapT(.clamp_to_edge).setSwizzle(.red, .green, .blue, .alpha).apply();
}

test "buffer editor chain const" {
    const B = Buffer(f32);
    const gpa = std.testing.allocator;
    const buf = try B.create(gpa);
    defer buf.destroy(gpa);
    const data = [_]f32{ 1, 2, 3 };
    buf.edit().setData(data[0..], .static_draw).apply();
    buf.edit().setSubDataTyped(0, data[0..]).apply();
}
