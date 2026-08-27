const std = @import("std");
const Transform = @import("transform.zig").Transform;

// Model abstraction tying material, mesh, and transform.
// `material_` and `mesh_` are types (generated via Material(...) and Mesh(...)),
// `scalar_type_` is scalar for transform.
pub fn Model(comptime material_: type, comptime mesh_: type, comptime scalar_type_: type) type {
    return struct {
        const Self = @This();
        pub const Material = material_;
        pub const Mesh = mesh_;
        pub const Scalar = scalar_type_;
        pub const TransformT = Transform(Scalar);

        // ---- opaque ----
        _material: Material,
        _mesh: Mesh,
        _transform: TransformT,
        _on_use_callback: ?*const fn (*Self) void = null,

        pub fn init(material: Material, mesh: Mesh, transform: TransformT, on_use_callback: ?*const fn (*Self) void) Self {
            return .{
                ._material = material,
                ._mesh = mesh,
                ._transform = transform,
                ._on_use_callback = on_use_callback,
            };
        }

        // Getters
        pub fn getMaterial(self: *const Self) *const Material { return &self._material; }
        pub fn getMaterialMut(self: *Self) *Material { return &self._material; }
        pub fn getMesh(self: *const Self) *const Mesh { return &self._mesh; }
        pub fn getMeshMut(self: *Self) *Mesh { return &self._mesh; }
        pub fn getTransform(self: *const Self) *const TransformT { return &self._transform; }
        pub fn getTransformMut(self: *Self) *TransformT { return &self._transform; }

        pub fn setMaterial(self: *Self, mat: Material) void { self._material = mat; }
        pub fn setMesh(self: *Self, mesh: Mesh) void { self._mesh = mesh; }
        pub fn setTransform(self: *Self, tr: TransformT) void { self._transform = tr; }
        pub fn setOnUseCallback(self: *Self, cb: ?*const fn (*Self) void) void { self._on_use_callback = cb; }

        // Use: callback -> mesh.use -> material.use
        pub fn use(self: *Self) void {
            if (self._on_use_callback) |cb| cb(self);
            // Ensure transform matrices are up-to-date before drawing.
            // User is responsible for calling recalculate if hierarchy changed,
            // but we ensure current node's matrix is at least local.
            self._transform.recalculateTransformMatrix();
            self._mesh.use();
            self._material.use();
        }

        pub fn draw(self: *Self) void {
            self.use();
            self._mesh.draw();
        }
    };
}
