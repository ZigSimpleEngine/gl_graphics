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

        /// Minimal ortho box size (width == height) covering the
        /// `shadow_distance`-truncated frustum in ANY orientation.
        ///
        /// Derivation: with effective far `F = min(far, shadow_distance)`,
        /// center at depth `(near + F) / 2` and `t = tan(fov_y / 2)`, the
        /// farthest corner from the center is a far-plane corner at
        /// `sqrt(((F - near) / 2)^2 + (F·t·aspect)^2 + (F·t)^2)`
        /// (near corners are strictly closer: same axial term, smaller
        /// lateral extents). Any light-space projection only shortens this
        /// distance, so half this value covers every corner in every
        /// orientation — and some orientation achieves it exactly, hence
        /// minimal. Returns twice that distance.
        ///
        /// Example: fov 60°, aspect 1.5, near 0.1, shadow_distance 10
        /// gives `F = 10`, `t ≈ 0.577`, `sqrt(4.95^2 + 8.66^2 + 5.77^2) ≈
        /// 11.53`, i.e. a box of ≈ 23.05 world units.
        pub fn shadowBoxSize(fov_y: Scalar, aspect: Scalar, near: Scalar, far: Scalar, shadow_distance: Scalar) Scalar {
            const t = std.math.tan(@as(f32, @floatCast(fov_y)) * 0.5);
            const f: f32 = @min(@as(f32, @floatCast(far)), @as(f32, @floatCast(shadow_distance)));
            const n: f32 = @floatCast(near);
            const half_depth = (f - n) * 0.5;
            const far_hw = f * t * @as(f32, @floatCast(aspect));
            const far_hh = f * t;
            const d_max = @sqrt(half_depth * half_depth + far_hw * far_hw + far_hh * far_hh);
            return @floatCast(d_max * 2.0);
        }

        /// Builds an orthographic camera for a directional light covering
        /// this camera's frustum (truncated to `shadow_distance`, the analog
        /// of `far` for the shadow map).
        ///
        /// `camera_world` is this camera's world matrix, `light_direction`
        /// points from the surface toward the light (same convention as
        /// `DirectionalLight.direction`). `resolution` is the square
        /// shadowmap size in texels (pass 0 to skip snapping).
        ///
        /// The ortho box has a FIXED size from `shadowBoxSize`: unlike a
        /// per-frame tight fit, a fixed size keeps the texel size constant,
        /// which is what makes the shadow stable — a tight fit changes the
        /// texel size every frame when the camera rotates, and no snapping
        /// can fix that swimming.
        ///
        /// The box is centered on the (texel-snapped) frustum center, so it
        /// follows the camera; depth range stays tight per frame (harmless:
        /// both map and lookup use the same matrix). Returns the light
        /// camera by value with `view` already set; the caller reads the
        /// light VP via `getViewProjection()`. The viewport is left at
        /// defaults: the shadow pass sets the GL viewport itself.
        pub fn shadowCamera(
            self: *const Self,
            camera_world: Mat4,
            light_direction: Vec3,
            shadow_distance: Scalar,
            resolution: u32,
        ) Self {
            const FVec3 = math.Vec(3, f32);

            const world = castToF32(camera_world);
            const eye = FVec3.init(.{ world.data[3].v[0], world.data[3].v[1], world.data[3].v[2] });
            const fwd = FVec3.init(.{ world.data[2].v[0], world.data[2].v[1], world.data[2].v[2] }).neg().normalize();
            const right = FVec3.init(.{ world.data[0].v[0], world.data[0].v[1], world.data[0].v[2] }).normalize();
            const up = FVec3.init(.{ world.data[1].v[0], world.data[1].v[1], world.data[1].v[2] }).normalize();

            const fov: f32 = @floatCast(self.fov_y);
            const aspect: f32 = @floatCast(self.aspect);
            const near: f32 = @floatCast(self.near);
            const far: f32 = @min(@as(f32, @floatCast(self.far)), @as(f32, @floatCast(shadow_distance)));
            const tan_h = std.math.tan(fov * 0.5);

            const nw = near * tan_h * aspect;
            const nh = near * tan_h;
            const fw = far * tan_h * aspect;
            const fh = far * tan_h;
            const nc = eye.add(fwd.mul(near));
            const fc = eye.add(fwd.mul(far));
            const corners = [_]FVec3{
                nc.add(up.mul(nh)).sub(right.mul(nw)),
                nc.add(up.mul(nh)).add(right.mul(nw)),
                nc.sub(up.mul(nh)).sub(right.mul(nw)),
                nc.sub(up.mul(nh)).add(right.mul(nw)),
                fc.add(up.mul(fh)).sub(right.mul(fw)),
                fc.add(up.mul(fh)).add(right.mul(fw)),
                fc.sub(up.mul(fh)).sub(right.mul(fw)),
                fc.sub(up.mul(fh)).add(right.mul(fw)),
            };
            const mid = eye.add(fwd.mul((near + far) * 0.5));

            const d = FVec3.init(.{
                @as(f32, @floatCast(light_direction.v[0])),
                @as(f32, @floatCast(light_direction.v[1])),
                @as(f32, @floatCast(light_direction.v[2])),
            }).normalize();
            const world_up = if (@abs(d.v[1]) > 0.99)
                FVec3.init(.{ 1, 0, 0 })
            else
                FVec3.init(.{ 0, 1, 0 });
            const view_dir = d.neg();
            const side = view_dir.cross(world_up).normalize();
            const light_up = side.cross(view_dir);

            const depth_margin: f32 = 5.0;
            // Minimal box covering the frustum in any orientation (fixed =>
            // constant texel size => stable shadow, see `shadowBoxSize`).
            const box_f: f32 = @floatCast(shadowBoxSize(self.fov_y, self.aspect, self.near, self.far, shadow_distance));

            // Fixed box: constant texel size (box/resolution) plus a center
            // snapped to the texel grid. The light axes never rotate, so the
            // world->texel mapping below only ever shifts by whole texels
            // (content-aligned, invisible) no matter how the source camera
            // moves or rotates.
            var mid_s = mid;
            if (resolution != 0 and box_f > 0) {
                const tw: f32 = box_f / @as(f32, @floatFromInt(resolution));
                const mx = mid.dot(side);
                const my = mid.dot(light_up);
                mid_s = mid
                    .add(side.mul(@round(mx / tw) * tw - mx))
                    .add(light_up.mul(@round(my / tw) * tw - my));
            }

            // Eye on the light axis through the (snapped) center: the view
            // direction stays exactly `-d`, depth placement is continuous
            // (harmless — map and lookup share the matrix).
            var t_max: f32 = -std.math.inf(f32);
            for (corners) |c| {
                t_max = @max(t_max, c.sub(mid).dot(d));
            }
            const light_eye = mid_s.add(d.mul(t_max + depth_margin));
            const light_view = math.mat.lookAt(light_eye, mid_s, light_up);

            // Tight depth range only (x/y come from the fixed box).
            var min_dist: f32 = std.math.inf(f32);
            var max_dist: f32 = -std.math.inf(f32);
            for (corners) |c| {
                const p = light_view.mulVec(FVec4.init(.{ c.v[0], c.v[1], c.v[2], 1 }));
                const dist = -p.v[2];
                min_dist = @min(min_dist, dist);
                max_dist = @max(max_dist, dist);
            }

            // Bounds on the texel grid: center is snapped and (for even
            // resolutions) half extents are whole texels, so every bound
            // lands exactly on the grid.
            const cx = mid_s.dot(side);
            const cy = mid_s.dot(light_up);
            const half = box_f * 0.5;

            return .{
                .is_perspective = false,
                .view = castFromF32(light_view),
                .ortho_left = cx - half,
                .ortho_right = cx + half,
                .ortho_bottom = cy - half,
                .ortho_top = cy + half,
                .near = @max(min_dist - depth_margin, 0.01),
                .far = max_dist + depth_margin,
            };
        }

        const FVec4 = math.Vec(4, f32);

        fn castFromF32(m: math.Mat(4, 4, f32)) Mat4 {
            if (Scalar == f32) return @bitCast(m);
            var res = Mat4.identity();
            inline for (0..4) |c| {
                inline for (0..4) |r| {
                    res.data[c].v[r] = @floatCast(m.data[c].v[r]);
                }
            }
            return res;
        }

        fn castToF32(m: Mat4) math.Mat(4, 4, f32) {
            if (Scalar == f32) return @bitCast(m);
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
