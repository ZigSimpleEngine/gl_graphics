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

/// ECS-style transform component, re-exported from `core`.
pub const Transform = @import("core").Transform;

/// Camera with projection and viewport.
pub const Camera = @import("camera.zig").Camera;

/// Shader program, parameterized by vertex and fragment shaders.
pub const ShaderProgram = @import("shader_program.zig").ShaderProgram;

/// Vertex-only shader program, parameterized by a vertex shader.
pub const VertexProgram = @import("shader_program.zig").VertexProgram;

/// Material — container for uniforms and program.
pub const Material = @import("material.zig").Material;

/// Vertex-only material — container for vertex uniforms and program.
pub const VertexMaterial = @import("material.zig").VertexMaterial;

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
pub const DefineSlot = shader_runtime.DefineSlot;
pub const buildVariantSrc = shader_runtime.buildVariantSrc;

/// Asset descriptors for generating Zig code from GLSL.
pub const descriptors = struct {
    /// EmbedDescriptor for `.glsl` files with structs.
    pub const GlslDescriptor = @import("descriptors/glsl.zig").GlslDescriptor;

    /// EmbedDescriptor for vertex shaders `.vert`.
    pub const VertexDescriptor = @import("descriptors/vert.zig").VertexDescriptor;

    /// EmbedDescriptor for fragment shaders `.frag`.
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

// File-scope doubles: `Owner` forward-references require container scope,
// mirroring generated shaders.
const DummyVertUniform = struct {
    pub const Owner = DummyVert;
    uMvp: math.Mat(4, 4, f32),
};
const DummyVert = struct {
    pub const Vertex = struct { pos: math.Vec(3, f32) };
    pub const Uniform = DummyVertUniform;
    pub const IdCache = struct { uMvp: i32 };
    pub const Define = struct {};
    pub fn instance(_: std.mem.Allocator, _: Define) !u32 {
        return 1;
    }
    pub fn destroy(_: std.mem.Allocator) void {}
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
const DummyFragUniform = struct {
    pub const Owner = DummyFrag;
    uColor: math.Vec(4, f32),
};
const DummyFrag = struct {
    pub const Uniform = DummyFragUniform;
    pub const IdCache = struct { uColor: i32 };
    pub const Define = struct {};
    pub fn instance(_: std.mem.Allocator, _: Define) !u32 {
        return 2;
    }
    pub fn destroy(_: std.mem.Allocator) void {}
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

test "smoke — texture opaque + editor chain" {
    _ = Texture;
    _ = Buffer(u16);
    _ = Mesh(struct { pos: math.Vec(3, f32), uv: math.Vec(2, f32) });
    _ = Transform(f32);
    _ = Map(.my_map, struct { a: i32 });
    _ = ShaderProgram(DummyVert, DummyFrag);
    _ = VertexProgram(DummyVert);
    const DummyMat = Material(DummyVertUniform, DummyVert.Define, .{ .uMvp = std.mem.zeroes(math.Mat(4, 4, f32)) }, .{}, DummyFragUniform, DummyFrag.Define, .{ .uColor = math.Vec(4, f32).zero() }, .{});
    const dummy_mat: DummyMat = .{};
    _ = dummy_mat;
    const DummyVertMat = VertexMaterial(DummyVertUniform, DummyVert.Define, .{ .uMvp = std.mem.zeroes(math.Mat(4, 4, f32)) }, .{});
    const dummy_vert_mat: DummyVertMat = .{};
    _ = dummy_vert_mat;
    _ = Framebuffer;
    _ = Camera(f32);
}

test "map get/set" {
    const MyMap = Map(.test_map, i32);
    MyMap.set(42);
    try std.testing.expectEqual(@as(i32, 42), MyMap.get(0));
}

test "transform ecs basic" {
    const T = Transform(f32);
    var root_t = T.identity();
    root_t.position = math.Vec(3, f32).init(.{ 1, 0, 0 });
    const root_world = root_t.toMatrix();

    var child_t = T.identity();
    const child_world = child_t.toWorldMatrix(root_world);
    // Child at local origin lands on the parent position.
    const child_pos = T.translation(child_world);
    try std.testing.expectEqual(@as(f32, 1), child_pos.v[0]);
    try std.testing.expectEqual(@as(f32, 0), child_pos.v[1]);
    try std.testing.expectEqual(@as(f32, 0), child_pos.v[2]);

    try std.testing.expectEqual(@as(f32, 1), root_t.rightLocal().v[0]);

    // Camera view path: inverse of the world matrix.
    const view = root_world.inverse();
    const view_t = T.translation(view);
    try std.testing.expectEqual(@as(f32, -1), view_t.v[0]);
    try std.testing.expectEqual(@as(f32, 0), view_t.v[1]);
    try std.testing.expectEqual(@as(f32, 0), view_t.v[2]);
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
    var dir_desc = assets_manager_mod.descriptors.embed.EmbedDirectoryDescriptor{};
    var file_desc = assets_manager_mod.descriptors.embed.EmbedFileDescriptor{};
    const descs = [_]*const assets_manager_mod.descriptors.embed.abstract.EmbedDescriptor{
        &vert_desc.descriptor(), &frag_desc.descriptor(), &glsl_desc.descriptor(), &dir_desc.descriptor(), &file_desc.descriptor(),
    };
    _ = descs;
    try std.testing.expect(true);
}

test "mesh editor chain const" {
    const V = struct { pos: math.Vec(3, f32) };
    const M = Mesh(V);
    const allocator = std.testing.allocator;
    const mesh = try M.create(allocator);
    defer mesh.destroy(allocator);
    const verts = [_]V{.{ .pos = math.Vec(3, f32).zero() }};
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
    const allocator = std.testing.allocator;
    const mesh = try M.create(allocator);
    defer mesh.destroy(allocator);
    const pos = [_]math.Vec(3, f32){ math.Vec(3, f32).init(.{ 0, 0, 0 }), math.Vec(3, f32).init(.{ 1, 0, 0 }) };
    const normal = [_]math.Vec(3, f32){ math.Vec(3, f32).init(.{ 0, 0, 1 }), math.Vec(3, f32).init(.{ 0, 0, 1 }) };
    const uv = [_]math.Vec(2, f32){ math.Vec(2, f32).init(.{ 0, 0 }), math.Vec(2, f32).init(.{ 1, 1 }) };
    const inds = [_]u16{ 0, 1, 0 };
    mesh.edit().setVerticesSOA(.{ .pos = pos[0..], .normal = normal[0..], .uv = uv[0..] }).setIndices(inds[0..]).apply();
    try std.testing.expect(mesh.getVertexCount() == 2);
    try std.testing.expect(mesh.getIndexCount() == 3);
}

test "texture editor chain const" {
    const allocator = std.testing.allocator;
    const tex = try Texture.create(allocator);
    defer tex.destroy(allocator);
    tex.edit().setMinFilter(.linear).setMagFilter(.linear).setWrap(.repeat, .repeat).apply();
    tex.edit().setWrapS(.clamp_to_edge).setWrapT(.clamp_to_edge).setSwizzle(.red, .green, .blue, .alpha).apply();
}

test "buffer editor chain const" {
    const B = Buffer(f32);
    const allocator = std.testing.allocator;
    const buf = try B.create(allocator);
    defer buf.destroy(allocator);
    const data = [_]f32{ 1, 2, 3 };
    buf.edit().setData(data[0..], .static_draw).apply();
    buf.edit().setSubDataTyped(0, data[0..]).apply();
}

test "framebuffer and camera cached paths without GL" {
    const allocator = std.testing.allocator;
    const fb = try Framebuffer.create(allocator);
    defer fb.destroy(allocator);
    try std.testing.expectEqual(@as(u32, 1), fb.getId());
    _ = fb.getTarget();
    _ = fb.getWidth();
    _ = fb.getHeight();
    _ = fb.getColorAttachment(0);
    _ = fb.getDepthAttachment();
    _ = fb.getStencilAttachment();
    _ = fb.getDepthStencilAttachment();
    _ = fb.getDrawBuffers();
    fb.edit().setTarget(.framebuffer).setSize(64, 48).apply();
    try std.testing.expectEqual(@as(i32, 64), fb.getWidth());
    try std.testing.expectEqual(@as(i32, 48), fb.getHeight());
    fb.edit().setColorAttachment(0, 7, .texture_2d, 0).apply();
    try std.testing.expectEqual(@as(?u32, 7), fb.getColorAttachment(0));
    // Live-GL entry points: analyze only, never execute headless.
    _ = &Framebuffer.bind;
    _ = &Framebuffer.bindTo;
    _ = &Framebuffer.use;
    _ = &Framebuffer.bindDefault;
    _ = &Framebuffer.useDefault;
    _ = &Framebuffer.getStatus;
    _ = &Framebuffer.isComplete;
    _ = &Framebuffer.getAttachmentParameter;
    _ = &Framebuffer.isValid;

    const C = Camera(f32);
    const cam = try C.create(allocator);
    defer cam.destroy(allocator);
    _ = cam.getFovY();
    _ = cam.getAspect();
    _ = cam.getNear();
    _ = cam.getFar();
    _ = cam.getProjection();
    _ = cam.getView();
    _ = cam.getViewProjection();
    _ = cam.getViewport();
    _ = cam.isPerspective();
    _ = cam.isOrtho();
    cam.edit().setFovY(1.0).setAspect(1.5).setNear(0.1).setFar(100.0).apply();
    try std.testing.expectEqual(@as(f32, 1.0), cam.getFovY());
    cam.edit().setPerspective(0.9, 1.4, 0.2, 200.0).apply();
    cam.edit().setOrtho(-1, 1, -1, 1, 0.1, 100.0).apply();
    // GL-touching: analyze only.
    _ = &C.use;
    _ = &C.applyViewport;
}
