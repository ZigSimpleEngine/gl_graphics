const std = @import("std");
const Transform = @import("transform.zig").Transform;

pub fn Model(comptime material_: type, comptime mesh_: type, comptime scalar_type_: type) type {
    return opaque {
        const Self = @This();
        pub const Material = material_;
        pub const Mesh = mesh_;
        pub const Scalar = scalar_type_;
        pub const TransformT = Transform(Scalar);

        const Impl = struct {
            material: *Material = undefined,
            mesh: *Mesh = undefined,
            transform: *TransformT = undefined,
            on_use_callback: ?*const fn (*Self) void = null,
        };

        inline fn impl(self: *Self) *Impl { return @ptrCast(@alignCast(self)); }
        inline fn implConst(self: *const Self) *const Impl { return @ptrCast(@alignCast(self)); }

        pub fn create(allocator: std.mem.Allocator, material: *Material, mesh: *Mesh, transform: *TransformT, on_use_callback: ?*const fn (*Self) void) !*Self {
            const m = try allocator.create(Impl);
            m.* = .{ .material = material, .mesh = mesh, .transform = transform, .on_use_callback = on_use_callback };
            return @ptrCast(m);
        }
        pub fn init(material: *Material, mesh: *Mesh, transform: *TransformT, on_use_callback: ?*const fn (*Self) void) *Self {
            return create(std.heap.page_allocator, material, mesh, transform, on_use_callback) catch @panic("Model OOM");
        }
        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void { allocator.destroy(self.impl()); }
        pub fn deinit(self: *Self) void { self.destroy(std.heap.page_allocator); }

        pub fn getMaterial(self: *const Self) *Material { return self.implConst().material; }
        pub fn getMesh(self: *const Self) *Mesh { return self.implConst().mesh; }
        pub fn getTransform(self: *const Self) *TransformT { return self.implConst().transform; }
        pub fn setMaterial(self: *Self, mat: *Material) void { self.impl().material = mat; }
        pub fn setMesh(self: *Self, mesh: *Mesh) void { self.impl().mesh = mesh; }
        pub fn setTransform(self: *Self, tr: *TransformT) void { self.impl().transform = tr; }
        pub fn setOnUseCallback(self: *Self, cb: ?*const fn (*Self) void) void { self.impl().on_use_callback = cb; }
        pub fn getOnUseCallback(self: *const Self) ?*const fn (*Self) void { return self.implConst().on_use_callback; }

        pub fn use(self: *Self) void {
            const m = self.impl();
            if (m.on_use_callback) |cb| cb(self);
            m.transform.recalculateTransformMatrix();
            m.mesh.use();
            m.material.use();
        }
        pub fn draw(self: *Self) void { self.use(); self.impl().mesh.draw(); }
    };
}
