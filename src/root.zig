const std = @import("std");

/// Texture — opaque wrapper over GL texture with deferred editor.
pub const Texture = @import("texture.zig").Texture;

/// Buffer — typed wrapper over GL buffer.
pub const Buffer = @import("buffer.zig").Buffer;

/// Mesh — VAO/VBO/EBO with computed vertex layout.
pub const Mesh = @import("mesh.zig").Mesh;

/// Framebuffer — wrapper over GL FBO.
pub const Framebuffer = @import("framebuffer.zig").Framebuffer;

/// Global registry by comptime name, re-exported from `core`.
pub const Map = @import("core").Map;

/// Hierarchical transform, re-exported from `core`.
pub const Transform = @import("core").Transform;

/// Camera with projection and viewport.
pub const Camera = @import("camera.zig").Camera;

/// Shader program, parameterized by vertex and fragment shaders.
pub const ShaderProgram = @import("shader_program.zig").ShaderProgram;

/// Material — container for uniforms and program.
pub const Material = @import("material.zig").Material;

/// Compile-time type metadata for resource abstractions (no GL dependency).
pub const gpu_meta = @import("gpu_meta.zig");

/// Type-erased GPU resource records (AnyBuffer/AnyMesh/AnyProgram/AnyMaterial).
pub const handles = @import("handles.zig");
pub const AnyBuffer = handles.AnyBuffer;
pub const AnyMesh = handles.AnyMesh;
pub const AnyProgram = handles.AnyProgram;
pub const AnyMaterial = handles.AnyMaterial;
pub const meshAcceptsProgram = handles.meshAcceptsProgram;
pub const materialAcceptsMesh = handles.materialAcceptsMesh;

/// Common GLSL parsing utilities.
pub const common = @import("descriptors/common.zig");

/// Shared runtime used by descriptor-generated shader code, so every
/// generated shader references the same functions instead of embedding
/// its own copy.
pub const shader_runtime = @import("shader_runtime.zig");
pub const uploadUniformValue = shader_runtime.uploadUniformValue;
pub const flattenUniforms = shader_runtime.flattenUniforms;
pub const applyUniforms = shader_runtime.applyUniforms;
pub const compileShaderSource = shader_runtime.compileShaderSource;
pub const disposeShader = shader_runtime.disposeShader;

/// Asset descriptors for generating Zig code from GLSL.
pub const descriptors = struct {
    /// Descriptor for `.glsl` files with structs.
    pub const GlslDescriptor = @import("descriptors/glsl.zig").GlslDescriptor;

    /// Descriptor for vertex shaders `.vert`.
    pub const VertexDescriptor = @import("descriptors/vert.zig").VertexDescriptor;

    /// Descriptor for fragment shaders `.frag`.
    pub const FragmentDescriptor = @import("descriptors/frag.zig").FragmentDescriptor;

    /// Alias for common utilities.
    pub const Common = common;
};

/// Re-export `gl` for consumer convenience.
pub const gl = @import("gl");

/// Re-export `math`.
pub const math = @import("math");

/// Re-export asset manager.
pub const assets_manager = @import("assets_manager");

/// Re-export `core` (Transform, Map).
pub const core = @import("core");

test "smoke — texture opaque + editor chain" {
    _ = Texture;
    _ = Buffer(u16);
    _ = Mesh(struct { pos: math.Vec(3, f32), uv: math.Vec(2, f32) });
    _ = Transform(f32);
    _ = Map(.my_map, struct { a: i32 });
    const DummyVert = struct {
        pub const Vertex = struct { pos: math.Vec(3, f32) };
        pub const Uniform = struct { uMvp: math.Mat(4, 4, f32) };
        pub const IdCache = struct { uMvp: i32 };
        pub var id: u32 = 0;
        pub fn instance() u32 {
            return 1;
        }
        pub fn dispose() void {}
        pub const Editor = struct {
            _program: u32,
            pub fn init(p: u32) @This() {
                return .{ ._program = p };
            }
            pub fn setUniform(self: *@This(), u: Uniform) *@This() {
                _ = u;
                return self;
            }
            pub fn set_uMvp(self: *@This(), v: math.Mat(4, 4, f32)) *@This() {
                _ = v;
                return self;
            }
            pub fn apply(self: *@This()) void {
                _ = self;
            }
        };
        pub fn edit(p: u32) Editor {
            return Editor.init(p);
        }
    };
    const DummyFrag = struct {
        pub const Uniform = struct { uColor: math.Vec(4, f32) };
        pub const IdCache = struct { uColor: i32 };
        pub var id: u32 = 0;
        pub fn instance() u32 {
            return 2;
        }
        pub fn dispose() void {}
        pub const Editor = struct {
            _program: u32,
            pub fn init(p: u32) @This() {
                return .{ ._program = p };
            }
            pub fn setUniform(self: *@This(), u: Uniform) *@This() {
                _ = u;
                return self;
            }
            pub fn apply(self: *@This()) void {
                _ = self;
            }
        };
        pub fn edit(p: u32) Editor {
            return Editor.init(p);
        }
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
    const M = Mesh(Vertex);
    try std.testing.expect(M.Layout.len == 3);
    try std.testing.expectEqual(@as(i32, 3), M.Layout[0].size);
    try std.testing.expectEqual(@as(i32, 2), M.Layout[1].size);
}

test "descriptors parse" {
    _ = common;
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
    const M = Mesh(V);
    const gpa = std.testing.allocator;
    const mesh = try M.create(gpa);
    defer mesh.destroy(gpa);
    const verts = [_]V{ .{ .pos = math.Vec(3, f32).zero() } };
    mesh.edit().setVertices(verts[0..]).apply();
    const inds = [_]u16{0};
    mesh.edit().setVertices(verts[0..]).setIndices(inds[0..]).apply();
}

test "mesh editor soa chain" {
    const V = struct {
        pos: math.Vec(3, f32),
        normal: math.Vec(3, f32),
        uv: math.Vec(2, f32),
    };
    const M = Mesh(V);
    const gpa = std.testing.allocator;
    const mesh = try M.create(gpa);
    defer mesh.destroy(gpa);
    const pos = [_]math.Vec(3, f32){ math.Vec(3, f32).init(.{ 0, 0, 0 }), math.Vec(3, f32).init(.{ 1, 0, 0 }) };
    const normal = [_]math.Vec(3, f32){ math.Vec(3, f32).init(.{ 0, 0, 1 }), math.Vec(3, f32).init(.{ 0, 0, 1 }) };
    const uv = [_]math.Vec(2, f32){ math.Vec(2, f32).init(.{ 0, 0 }), math.Vec(2, f32).init(.{ 1, 1 }) };
    const inds = [_]u16{ 0, 1, 0 };
    mesh.edit().setVerticesSOA(.{ .pos = pos[0..], .normal = normal[0..], .uv = uv[0..] }).setIndices(inds[0..]).apply();
    try std.testing.expect(mesh.getVertexCount() == 2);
    try std.testing.expect(mesh.getIndexCount() == 3);
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
