const std = @import("std");
const Transform = @import("core").Transform;

/// Function `Model`.
///
/// Parameters:
/// - `material_` — parameter `material_`.
/// - `mesh_` — parameter `mesh_`.
/// - `scalar_type_` — parameter `scalar_type_`.
///
/// Returns: `type`.
pub fn Model(comptime material_: type, comptime mesh_: type, comptime scalar_type_: type) type {
    return opaque {
        const Self = @This();

/// Constant `Material`.
        pub const Material = material_;

/// Constant `Mesh`.
        pub const Mesh = mesh_;

/// Constant `Scalar`.
        pub const Scalar = scalar_type_;

/// Constant `TransformT`.
        pub const TransformT = Transform(Scalar);

/// Documentation.
        const Impl = struct {
/// Pointer to material.
            material: *Material = undefined,

/// Pointer to mesh.
            mesh: *Mesh = undefined,

/// Transform reference.
            transform: *TransformT = undefined,

/// Documentation for `on_use_callback: ?*const fn (*Self) void = null,`.
            on_use_callback: ?*const fn (*Self) void = null,
        };

/// Function `impl`.
///
/// Parameters:
/// - `self` — parameter `self`.
///
/// Returns: `*Impl`.
        inline fn impl(self: *Self) *Impl {
            return @ptrCast(@alignCast(self));
        }

/// Function `implConst`.
///
/// Parameters:
/// - `self` — parameter `self`.
///
/// Returns: `*const`.
        inline fn implConst(self: *const Self) *const Impl {
            return @ptrCast(@alignCast(self));
        }

/// Creates a new instance.
///
/// Parameters:
/// - `allocator` — parameter `allocator`.
/// - `material` — parameter `material`.
/// - `mesh` — parameter `mesh`.
/// - `transform` — parameter `transform`.
/// - `on_use_callback` — parameter `on_use_callback`.
///
/// Returns: `void)`.
        pub fn create(allocator: std.mem.Allocator, material: *Material, mesh: *Mesh, transform: *TransformT, on_use_callback: ?*const fn (*Self) void) !*Self {
            const m = try allocator.create(Impl);
            m.* = .{ .material = material, .mesh = mesh, .transform = transform, .on_use_callback = on_use_callback };
            return @ptrCast(m);
        }

/// Alias for `create` for API uniformity.
///
/// Parameters:
/// - `allocator` — parameter `allocator`.
/// - `material` — parameter `material`.
/// - `mesh` — parameter `mesh`.
/// - `transform` — parameter `transform`.
/// - `on_use_callback` — parameter `on_use_callback`.
///
/// Returns: `void)`.
        pub fn init(allocator: std.mem.Allocator, material: *Material, mesh: *Mesh, transform: *TransformT, on_use_callback: ?*const fn (*Self) void) !*Self {
            return create(allocator, material, mesh, transform, on_use_callback);
        }

/// Destroys the instance, freeing `Impl`.
///
/// Parameters:
/// - `self` — parameter `self`.
/// - `allocator` — parameter `allocator`.
        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self.impl());
        }

/// Alias for `destroy` for RAII.
///
/// Parameters:
/// - `self` — parameter `self`.
/// - `allocator` — parameter `allocator`.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.destroy(allocator);
        }

/// Returns the material pointer.
///
/// Parameters:
/// - `self` — parameter `self`.
///
/// Returns: `*Material`.
        pub fn getMaterial(self: *const Self) *Material {
            return self.implConst().material;
        }

/// Returns the mesh pointer.
///
/// Parameters:
/// - `self` — parameter `self`.
///
/// Returns: `*Mesh`.
        pub fn getMesh(self: *const Self) *Mesh {
            return self.implConst().mesh;
        }

/// Returns the transform pointer.
///
/// Parameters:
/// - `self` — parameter `self`.
///
/// Returns: `*TransformT`.
        pub fn getTransform(self: *const Self) *TransformT {
            return self.implConst().transform;
        }

/// Replaces the material.
///
/// Parameters:
/// - `self` — parameter `self`.
/// - `mat` — parameter `mat`.
        pub fn setMaterial(self: *Self, mat: *Material) void {
            self.impl().material = mat;
        }

/// Replaces the mesh.
///
/// Parameters:
/// - `self` — parameter `self`.
/// - `mesh` — parameter `mesh`.
        pub fn setMesh(self: *Self, mesh: *Mesh) void {
            self.impl().mesh = mesh;
        }

/// Replaces the transform immediately.
///
/// Parameters:
/// - `self` — parameter `self`.
/// - `tr` — parameter `tr`.
        pub fn setTransform(self: *Self, tr: *TransformT) void {
            self.impl().transform = tr;
        }

/// Sets the pending `on_use` callback.
///
/// Parameters:
/// - `self` — parameter `self`.
/// - `cb` — parameter `cb`.
///
/// Returns: `void)`.
        pub fn setOnUseCallback(self: *Self, cb: ?*const fn (*Self) void) void {
            self.impl().on_use_callback = cb;
        }

/// Returns the `on_use` callback.
///
/// Parameters:
/// - `self` — parameter `self`.
///
/// Returns: `?*const`.
        pub fn getOnUseCallback(self: *const Self) ?*const fn (*Self) void {
            return self.implConst().on_use_callback;
        }

/// Activates the instance, updating state.
///
/// Parameters:
/// - `self` — parameter `self`.
        pub fn use(self: *Self) void {
            const m = self.impl();
            if (m.on_use_callback) |cb| cb(self);
            m.transform.recalculateTransformMatrix();
            m.mesh.use();
            m.material.use();
        }

/// Renders the model.
///
/// Parameters:
/// - `self` — parameter `self`.
        pub fn draw(self: *Self) void {
            self.use();
            self.impl().mesh.draw();
        }
    };
}
