const std = @import("std");
const gl = @import("gl");
const math = @import("math");
const Transform = @import("core").Transform;

/// Function `Camera`.
///
/// Parameters:
/// - `scalar_type_` — parameter `scalar_type_`.
///
/// Returns: `type`.
pub fn Camera(comptime scalar_type_: type) type {
    return opaque {
        const Self = @This();

        /// Constant `Scalar`.
        pub const Scalar = scalar_type_;

        /// Constant `Vec3`.
        pub const Vec3 = math.Vec(3, Scalar);

        /// Constant `Mat4`.
        pub const Mat4 = math.Mat(4, 4, Scalar);

        /// Constant `TransformT`.
        pub const TransformT = Transform(Scalar);

        /// Documentation.
        const Impl = struct {
            /// Transform reference.
            transform: *TransformT,

            /// Vertical field of view in radians (perspective).
            fov_y: Scalar = std.math.degreesToRadians(60.0),

            /// Aspect ratio (width / height).
            aspect: Scalar = 16.0 / 9.0,

            /// Near clipping plane.
            near: Scalar = 0.1,

            /// Far clipping plane.
            far: Scalar = 1000.0,

            /// Cached projection matrix.
            projection: Mat4 = Mat4.identity(),

            /// Cached view matrix.
            view: Mat4 = Mat4.identity(),

            /// Viewport X coordinate.
            viewport_x: i32 = 0,

            /// Viewport Y coordinate.
            viewport_y: i32 = 0,

            /// Viewport width.
            viewport_w: i32 = 800,

            /// Viewport height.
            viewport_h: i32 = 600,

            /// Flag for perspective projection, false is orthographic.
            is_perspective: bool = true,

            /// Left bound of orthographic projection.
            ortho_left: Scalar = -1,

            /// Right bound of orthographic projection.
            ortho_right: Scalar = 1,

            /// Bottom bound of orthographic projection.
            ortho_bottom: Scalar = -1,

            /// Top bound of orthographic projection.
            ortho_top: Scalar = 1,

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

        /// Recalculates the projection matrix.
        ///
        /// Parameters:
        /// - `m` — parameter `m`.
        fn recalcProjection(m: *Impl) void {
            if (m.is_perspective) {
                const fov: f32 = @floatCast(m.fov_y);
                const aspect: f32 = @floatCast(m.aspect);
                const near: f32 = @floatCast(m.near);
                const far: f32 = @floatCast(m.far);
                const p = math.mat.perspective(fov, aspect, near, far);
                m.projection = castMat4Outer(p);
            } else {
                const l: f32 = @floatCast(m.ortho_left);
                const r: f32 = @floatCast(m.ortho_right);
                const b: f32 = @floatCast(m.ortho_bottom);
                const t: f32 = @floatCast(m.ortho_top);
                const n: f32 = @floatCast(m.near);
                const f: f32 = @floatCast(m.far);
                const p = math.mat.ortho(l, r, b, t, n, f);
                m.projection = castMat4Outer(p);
            }
        }

        /// Recalculates the view matrix as inverse of transform.
        ///
        /// Parameters:
        /// - `m` — parameter `m`.
        fn recalcView(m: *Impl) void {
            m.view = m.transform.getMatrix().inverse();
        }

        /// Casts `f32` matrix to current scalar type.
        ///
        /// Parameters:
        /// - `m` — parameter `m`.
        /// - `4` — parameter `4`.
        /// - `f32` — parameter `f32`.
        ///
        /// Returns: `)`.
        fn castMat4Outer(m: math.Mat(4, 4, f32)) Mat4 {
            if (Scalar == f32) return @bitCast(m);
            var res = Mat4.identity();
            inline for (0..4) |c| {
                inline for (0..4) |r| {
                    res.data[c].v[r] = @floatCast(m.data[c].v[r]);
                }
            }
            return res;
        }

        /// Creates a new instance.
        ///
        /// Parameters:
        /// - `allocator` — parameter `allocator`.
        /// - `transform` — parameter `transform`.
        /// - `on_use_callback` — parameter `on_use_callback`.
        ///
        /// Returns: `void)`.
        pub fn create(allocator: std.mem.Allocator, transform: *TransformT, on_use_callback: ?*const fn (*Self) void) !*Self {
            const m = try allocator.create(Impl);
            m.* = .{ .transform = transform, .on_use_callback = on_use_callback };
            recalcProjection(m);
            recalcView(m);
            return @ptrCast(m);
        }

        /// Creates an instance with default transform.
        ///
        /// Parameters:
        /// - `allocator` — parameter `allocator`.
        /// - `on_use_callback` — parameter `on_use_callback`.
        ///
        /// Returns: `void)`.
        pub fn default(allocator: std.mem.Allocator, on_use_callback: ?*const fn (*Self) void) !*Self {
            const transform = try TransformT.identity(allocator);
            errdefer transform.destroy(allocator);
            return create(allocator, transform, on_use_callback);
        }

        /// Destroys the instance, freeing `Impl`.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        /// - `allocator` — parameter `allocator`.
        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self.impl());
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

        /// Returns a mutable transform pointer.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `*TransformT`.
        pub fn getTransformMut(self: *Self) *TransformT {
            return self.impl().transform;
        }

        /// Returns the vertical field of view.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `Scalar`.
        pub fn getFovY(self: *const Self) Scalar {
            return self.implConst().fov_y;
        }

        /// Returns the aspect ratio.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `Scalar`.
        pub fn getAspect(self: *const Self) Scalar {
            return self.implConst().aspect;
        }

        /// Returns the near plane.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `Scalar`.
        pub fn getNear(self: *const Self) Scalar {
            return self.implConst().near;
        }

        /// Returns the far plane.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `Scalar`.
        pub fn getFar(self: *const Self) Scalar {
            return self.implConst().far;
        }

        /// Returns the projection matrix.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `Mat4`.
        pub fn getProjection(self: *const Self) Mat4 {
            return self.implConst().projection;
        }

        /// Returns the view matrix.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `Mat4`.
        pub fn getView(self: *const Self) Mat4 {
            return self.implConst().view;
        }

        /// Returns the combined view-projection matrix.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `Mat4`.
        pub fn getViewProjection(self: *const Self) Mat4 {
            const m = self.implConst();
            return m.projection.mul(m.view);
        }

        /// Returns the viewport parameters.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `struct`.
        pub fn getViewport(self: *const Self) struct { x: i32, y: i32, w: i32, h: i32 } {
            const m = self.implConst();
            return .{ .x = m.viewport_x, .y = m.viewport_y, .w = m.viewport_w, .h = m.viewport_h };
        }

        /// Checks if camera is in perspective mode.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `bool`.
        pub fn isPerspective(self: *const Self) bool {
            return self.implConst().is_perspective;
        }

        /// Checks if camera is in orthographic mode.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `bool`.
        pub fn isOrtho(self: *const Self) bool {
            return !self.implConst().is_perspective;
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

        /// Applies the viewport to the GL context.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        pub fn applyViewport(self: *const Self) void {
            const m = self.implConst();
            gl.viewport.viewport(m.viewport_x, m.viewport_y, m.viewport_w, m.viewport_h);
        }

        /// Activates the instance, updating state.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        pub fn use(self: *Self) void {
            const m = self.impl();
            if (m.on_use_callback) |cb| cb(self);
            recalcView(m);
            self.applyViewport();
        }

        /// Creates an editor for deferred batched changes.
        ///
        /// Parameters:
        /// - `self` — parameter `self`.
        ///
        /// Returns: `Editor`.
        pub fn edit(self: *Self) Editor {
            return Editor.init(self);
        }

        /// Constant `Editor`.
        pub const Editor = struct {
            /// Associated camera.
            _camera: *Self,

            /// Pending `fov_y` value.
            _pending_fov_y: ?Scalar = null,

            /// Pending `aspect` value.
            _pending_aspect: ?Scalar = null,

            /// Pending `near` value.
            _pending_near: ?Scalar = null,

            /// Pending `far` value.
            _pending_far: ?Scalar = null,

            /// Pending viewport parameters.
            _pending_viewport: ?struct { x: i32, y: i32, w: i32, h: i32 } = null,

            /// Pending perspective flag.
            _pending_perspective: ?bool = null,

            /// Pending orthographic bounds.
            _pending_ortho: ?struct { l: Scalar, r: Scalar, b: Scalar, t: Scalar } = null,

            /// Pending camera position.
            _pending_position: ?Vec3 = null,

            /// Pending look-at parameters.
            _pending_look_at: ?struct { eye: Vec3, center: Vec3, up: Vec3 } = null,

            /// Documentation for `_pending_on_use_callback: ?*const fn (*Self) void = null,`.
            _pending_on_use_callback: ?*const fn (*Self) void = null,

            /// Flag indicating pending callback presence.
            _has_pending_on_use_callback: bool = false,

            /// Alias for `create` for API uniformity.
            ///
            /// Parameters:
            /// - `camera` — parameter `camera`.
            ///
            /// Returns: `Editor`.
            pub fn init(camera: *Self) Editor {
                return .{ ._camera = camera };
            }

            /// Sets the pending `fov_y`.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `v` — parameter `v`.
            ///
            /// Returns: `*const`.
            pub fn setFovY(self: *const Editor, v: Scalar) *const Editor {
                @constCast(self)._pending_fov_y = v;
                return @constCast(self);
            }

            /// Sets the pending `aspect`.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `v` — parameter `v`.
            ///
            /// Returns: `*const`.
            pub fn setAspect(self: *const Editor, v: Scalar) *const Editor {
                @constCast(self)._pending_aspect = v;
                return @constCast(self);
            }

            /// Sets the pending `near`.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `v` — parameter `v`.
            ///
            /// Returns: `*const`.
            pub fn setNear(self: *const Editor, v: Scalar) *const Editor {
                @constCast(self)._pending_near = v;
                return @constCast(self);
            }

            /// Sets the pending `far`.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `v` — parameter `v`.
            ///
            /// Returns: `*const`.
            pub fn setFar(self: *const Editor, v: Scalar) *const Editor {
                @constCast(self)._pending_far = v;
                return @constCast(self);
            }

            /// Sets a perspective projection.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `fov_y` — parameter `fov_y`.
            /// - `aspect` — parameter `aspect`.
            /// - `near` — parameter `near`.
            /// - `far` — parameter `far`.
            ///
            /// Returns: `*const`.
            pub fn setPerspective(self: *const Editor, fov_y: Scalar, aspect: Scalar, near: Scalar, far: Scalar) *const Editor {
                @constCast(self)._pending_perspective = true;
                @constCast(self)._pending_fov_y = fov_y;
                @constCast(self)._pending_aspect = aspect;
                @constCast(self)._pending_near = near;
                @constCast(self)._pending_far = far;
                return @constCast(self);
            }

            /// Sets an orthographic projection.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `left` — parameter `left`.
            /// - `right` — parameter `right`.
            /// - `bottom` — parameter `bottom`.
            /// - `top` — parameter `top`.
            /// - `near` — parameter `near`.
            /// - `far` — parameter `far`.
            ///
            /// Returns: `*const`.
            pub fn setOrtho(self: *const Editor, left: Scalar, right: Scalar, bottom: Scalar, top: Scalar, near: Scalar, far: Scalar) *const Editor {
                @constCast(self)._pending_perspective = false;
                @constCast(self)._pending_ortho = .{ .l = left, .r = right, .b = bottom, .t = top };
                @constCast(self)._pending_near = near;
                @constCast(self)._pending_far = far;
                return @constCast(self);
            }

            /// Sets the pending viewport.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `x` — parameter `x`.
            /// - `y` — parameter `y`.
            /// - `w` — parameter `w`.
            /// - `h` — parameter `h`.
            ///
            /// Returns: `*const`.
            pub fn setViewport(self: *const Editor, x: i32, y: i32, w: i32, h: i32) *const Editor {
                @constCast(self)._pending_viewport = .{ .x = x, .y = y, .w = w, .h = h };
                return @constCast(self);
            }

            /// Sets the pending position.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `pos` — parameter `pos`.
            ///
            /// Returns: `*const`.
            pub fn setPosition(self: *const Editor, pos: Vec3) *const Editor {
                @constCast(self)._pending_position = pos;
                return @constCast(self);
            }

            /// Sets the pending look-at.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `eye` — parameter `eye`.
            /// - `center` — parameter `center`.
            /// - `up` — parameter `up`.
            ///
            /// Returns: `*const`.
            pub fn setLookAt(self: *const Editor, eye: Vec3, center: Vec3, up: Vec3) *const Editor {
                @constCast(self)._pending_look_at = .{ .eye = eye, .center = center, .up = up };
                return @constCast(self);
            }

            /// Replaces the transform immediately.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `transform` — parameter `transform`.
            ///
            /// Returns: `*const`.
            pub fn setTransform(self: *const Editor, transform: *TransformT) *const Editor {
                @constCast(self)._camera.impl().transform = transform;
                return @constCast(self);
            }

            /// Sets the pending `on_use` callback.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            /// - `cb` — parameter `cb`.
            ///
            /// Returns: `void)`.
            pub fn setOnUseCallback(self: *const Editor, cb: ?*const fn (*Self) void) *const Editor {
                @constCast(self)._pending_on_use_callback = cb;
                @constCast(self)._has_pending_on_use_callback = true;
                return @constCast(self);
            }

            /// Applies all pending changes.
            ///
            /// Parameters:
            /// - `self` — parameter `self`.
            pub fn apply(self: *const Editor) void {
                const cam = @constCast(self)._camera.impl();
                if (@constCast(self)._pending_fov_y) |v| cam.fov_y = v;
                if (@constCast(self)._pending_aspect) |v| cam.aspect = v;
                if (@constCast(self)._pending_near) |v| cam.near = v;
                if (@constCast(self)._pending_far) |v| cam.far = v;
                if (@constCast(self)._pending_perspective) |is_p| cam.is_perspective = is_p;
                if (@constCast(self)._pending_ortho) |o| {
                    cam.ortho_left = o.l;
                    cam.ortho_right = o.r;
                    cam.ortho_bottom = o.b;
                    cam.ortho_top = o.t;
                }
                if (@constCast(self)._pending_viewport) |vp| {
                    cam.viewport_x = vp.x;
                    cam.viewport_y = vp.y;
                    cam.viewport_w = vp.w;
                    cam.viewport_h = vp.h;
                    @constCast(self)._camera.applyViewport();
                }
                if (@constCast(self)._pending_position) |p| {
                    cam.transform.position().* = p;
                    cam.transform.recalculateTransformMatrix();
                    recalcView(cam);
                }
                if (@constCast(self)._pending_look_at) |la| {
                    const eye_f = math.Vec(3, f32).init(.{ la.eye.v[0], la.eye.v[1], la.eye.v[2] });
                    const center_f = math.Vec(3, f32).init(.{ la.center.v[0], la.center.v[1], la.center.v[2] });
                    const up_f = math.Vec(3, f32).init(.{ la.up.v[0], la.up.v[1], la.up.v[2] });
                    const view_f = math.mat.lookAt(eye_f, center_f, up_f);
                    cam.view = castMat4(view_f);
                    cam.transform.impl().matrix = cam.view.inverse();
                    cam.transform.position().* = Vec3.init(.{ cam.transform.impl().matrix.data[3].v[0], cam.transform.impl().matrix.data[3].v[1], cam.transform.impl().matrix.data[3].v[2] });
                }
                if (@constCast(self)._has_pending_on_use_callback) cam.on_use_callback = @constCast(self)._pending_on_use_callback;
                recalcProjection(cam);
                recalcView(cam);
                @constCast(self).* = Editor.init(@constCast(self)._camera);
            }

            /// Casts `f32` matrix to scalar type.
            ///
            /// Parameters:
            /// - `m` — parameter `m`.
            /// - `4` — parameter `4`.
            /// - `f32` — parameter `f32`.
            ///
            /// Returns: `)`.
            fn castMat4(m: math.Mat(4, 4, f32)) Mat4 {
                if (Scalar == f32) return @bitCast(m);
                var res = Mat4.identity();
                inline for (0..4) |c| {
                    inline for (0..4) |r| {
                        res.data[c].v[r] = @floatCast(m.data[c].v[r]);
                    }
                }
                return res;
            }
        };
    };
}
