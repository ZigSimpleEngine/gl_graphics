const std = @import("std");
const gl = @import("gl");
const math = @import("math");

/// Plain camera struct parameterized by scalar type.
///
/// Value semantics like `Transform`/`Material`: create with a struct
/// literal (`var cam: Camera(f32) = .{}`), mutate public fields directly.
/// No allocator, no `create`/`destroy`, no editor.
///
/// The projection matrix is never stored: `getProjection` builds it on
/// demand from the current parameters, so fields can never go stale.
/// Only `view` is cached, updated by the single writer `use(world)`.
pub fn Camera(comptime scalar_type_: type) type {
    return struct {
        const Self = @This();

        pub const Scalar = scalar_type_;
        pub const Vec3 = math.Vec(3, Scalar);
        pub const Mat4 = math.Mat(4, 4, Scalar);

        /// Vertical field of view in radians (perspective).
        fov_y: Scalar = std.math.degreesToRadians(60.0),
        /// Aspect ratio (width / height).
        aspect: Scalar = 16.0 / 9.0,
        /// Near clipping plane.
        near: Scalar = 0.1,
        /// Far clipping plane.
        far: Scalar = 1000.0,
        /// Cached view matrix, updated by `use(world)`.
        view: Mat4 = Mat4.identity(),
        /// Viewport X coordinate.
        viewport_x: i32 = 0,
        /// Viewport Y coordinate.
        viewport_y: i32 = 0,
        /// Viewport width.
        viewport_w: i32 = 800,
        /// Viewport height.
        viewport_h: i32 = 600,
        /// Perspective projection when true, orthographic otherwise.
        is_perspective: bool = true,
        /// Left bound of orthographic projection.
        ortho_left: Scalar = -1,
        /// Right bound of orthographic projection.
        ortho_right: Scalar = 1,
        /// Bottom bound of orthographic projection.
        ortho_bottom: Scalar = -1,
        /// Top bound of orthographic projection.
        ortho_top: Scalar = 1,

        /// Builds the projection matrix from current parameters.
        pub fn getProjection(self: *const Self) Mat4 {
            if (self.is_perspective) {
                const p = math.mat.perspectiveRad(
                    @floatCast(self.fov_y),
                    @floatCast(self.aspect),
                    @floatCast(self.near),
                    @floatCast(self.far),
                );
                return castFromF32(p);
            }
            const p = math.mat.ortho(
                @floatCast(self.ortho_left),
                @floatCast(self.ortho_right),
                @floatCast(self.ortho_bottom),
                @floatCast(self.ortho_top),
                @floatCast(self.near),
                @floatCast(self.far),
            );
            return castFromF32(p);
        }

        /// Returns the combined view-projection matrix.
        pub fn getViewProjection(self: *const Self) Mat4 {
            return self.getProjection().mul(self.view);
        }

        /// Applies the viewport to the GL context.
        pub fn applyViewport(self: *const Self) void {
            gl.viewport.viewport(self.viewport_x, self.viewport_y, self.viewport_w, self.viewport_h);
        }

        /// Updates the view from the global camera world matrix and
        /// applies the viewport.
        pub fn use(self: *Self, world: Mat4) void {
            self.view = world.inverse();
            self.applyViewport();
        }

        fn castFromF32(m: math.Mat(4, 4, f32)) Mat4 {
            if (Scalar == f32) return m;
            var res = Mat4.identity();
            inline for (0..4) |c| {
                inline for (0..4) |r| {
                    res.data[c].v[r] = @floatCast(m.data[c].v[r]);
                }
            }
            return res;
        }

        fn castToF32(m: Mat4) math.Mat(4, 4, f32) {
            if (Scalar == f32) return m;
            var res = math.Mat(4, 4, f32).identity();
            inline for (0..4) |c| {
                inline for (0..4) |r| {
                    res.data[c].v[r] = @floatCast(m.data[c].v[r]);
                }
            }
            return res;
        }
    };
}
