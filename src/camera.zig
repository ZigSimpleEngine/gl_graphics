const std = @import("std");
const gl = @import("gl");
const math = @import("math");
const Transform = @import("transform.zig").Transform;

// Camera abstraction controlling view/projection state.
// Works with GL state via Editor MethodChain.
pub fn Camera(comptime scalar_type_: type) type {
    return struct {
        const Self = @This();
        pub const Scalar = scalar_type_;
        pub const Vec3 = math.Vec(3, Scalar);
        pub const Mat4 = math.Mat(4, 4, Scalar);
        pub const TransformT = Transform(Scalar);

        // ---- opaque ----
        _transform: TransformT,
        _fov_y: Scalar = std.math.degreesToRadians(60.0),
        _aspect: Scalar = 16.0 / 9.0,
        _near: Scalar = 0.1,
        _far: Scalar = 1000.0,
        _projection: Mat4 = Mat4.identity(),
        _view: Mat4 = Mat4.identity(),
        _viewport_x: i32 = 0,
        _viewport_y: i32 = 0,
        _viewport_w: i32 = 800,
        _viewport_h: i32 = 600,
        _is_perspective: bool = true,
        // ortho bounds if not perspective
        _ortho_left: Scalar = -1,
        _ortho_right: Scalar = 1,
        _ortho_bottom: Scalar = -1,
        _ortho_top: Scalar = 1,

        pub fn init(transform: TransformT) Self {
            var cam = Self{ ._transform = transform };
            cam.recalculateProjection();
            cam.recalculateView();
            return cam;
        }

        // ------------------------------------------------------------
        // Getters (read-only)
        // ------------------------------------------------------------
        pub fn getTransform(self: *const Self) *const TransformT { return &self._transform; }
        pub fn getTransformMut(self: *Self) *TransformT { return &self._transform; }
        pub fn getFovY(self: *const Self) Scalar { return self._fov_y; }
        pub fn getAspect(self: *const Self) Scalar { return self._aspect; }
        pub fn getNear(self: *const Self) Scalar { return self._near; }
        pub fn getFar(self: *const Self) Scalar { return self._far; }
        pub fn getProjection(self: *const Self) Mat4 { return self._projection; }
        pub fn getView(self: *const Self) Mat4 { return self._view; }
        pub fn getViewProjection(self: *const Self) Mat4 { return self._projection.mul(self._view); }
        pub fn getViewport(self: *const Self) struct { x: i32, y: i32, w: i32, h: i32 } {
            return .{ .x = self._viewport_x, .y = self._viewport_y, .w = self._viewport_w, .h = self._viewport_h };
        }
        pub fn isPerspective(self: *const Self) bool { return self._is_perspective; }
        pub fn isOrtho(self: *const Self) bool { return !self._is_perspective; }

        // ------------------------------------------------------------
        // Internal recalculations
        // ------------------------------------------------------------
        fn recalculateProjection(self: *Self) void {
            if (self._is_perspective) {
                // Use generic f32 version then cast
                const fov: f32 = @floatCast(self._fov_y);
                const aspect: f32 = @floatCast(self._aspect);
                const near: f32 = @floatCast(self._near);
                const far: f32 = @floatCast(self._far);
                const p = math.mat.perspective(fov, aspect, near, far);
                // Cast back to Scalar mat
                self._projection = castMat4(p);
            } else {
                const l: f32 = @floatCast(self._ortho_left);
                const r: f32 = @floatCast(self._ortho_right);
                const b: f32 = @floatCast(self._ortho_bottom);
                const t: f32 = @floatCast(self._ortho_top);
                const n: f32 = @floatCast(self._near);
                const f: f32 = @floatCast(self._far);
                const p = math.mat.ortho(l, r, b, t, n, f);
                self._projection = castMat4(p);
            }
        }
        fn recalculateView(self: *Self) void {
            // View = inverse of transform matrix
            self._view = self._transform.getMatrix().inverse();
        }

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

        // Apply viewport to GL immediately (called from Editor.apply or use)
        pub fn applyViewport(self: *const Self) void {
            gl.viewport.viewport(self._viewport_x, self._viewport_y, self._viewport_w, self._viewport_h);
        }

        pub fn use(self: *Self) void {
            self.recalculateView();
            self.applyViewport();
        }

        // ------------------------------------------------------------
        // Editor
        // ------------------------------------------------------------
        pub fn edit(self: *Self) Editor {
            return Editor.init(self);
        }

        pub const Editor = struct {
            _camera: *Self,

            _pending_fov_y: ?Scalar = null,
            _pending_aspect: ?Scalar = null,
            _pending_near: ?Scalar = null,
            _pending_far: ?Scalar = null,
            _pending_viewport: ?struct { x: i32, y: i32, w: i32, h: i32 } = null,
            _pending_perspective: ?bool = null,
            _pending_ortho: ?struct { l: Scalar, r: Scalar, b: Scalar, t: Scalar } = null,
            _pending_position: ?Vec3 = null,
            _pending_look_at: ?struct { eye: Vec3, center: Vec3, up: Vec3 } = null,

            pub fn init(camera: *Self) Editor {
                return .{ ._camera = camera };
            }

            pub fn setFovY(self: *Editor, fov_y: Scalar) *Editor { self._pending_fov_y = fov_y; return self; }
            pub fn setAspect(self: *Editor, aspect: Scalar) *Editor { self._pending_aspect = aspect; return self; }
            pub fn setNear(self: *Editor, near: Scalar) *Editor { self._pending_near = near; return self; }
            pub fn setFar(self: *Editor, far: Scalar) *Editor { self._pending_far = far; return self; }
            pub fn setPerspective(self: *Editor, fov_y: Scalar, aspect: Scalar, near: Scalar, far: Scalar) *Editor {
                self._pending_perspective = true;
                self._pending_fov_y = fov_y;
                self._pending_aspect = aspect;
                self._pending_near = near;
                self._pending_far = far;
                return self;
            }
            pub fn setOrtho(self: *Editor, left: Scalar, right: Scalar, bottom: Scalar, top: Scalar, near: Scalar, far: Scalar) *Editor {
                self._pending_perspective = false;
                self._pending_ortho = .{ .l = left, .r = right, .b = bottom, .t = top };
                self._pending_near = near;
                self._pending_far = far;
                return self;
            }
            pub fn setViewport(self: *Editor, x: i32, y: i32, w: i32, h: i32) *Editor {
                self._pending_viewport = .{ .x = x, .y = y, .w = w, .h = h };
                return self;
            }
            pub fn setPosition(self: *Editor, pos: Vec3) *Editor {
                self._pending_position = pos;
                return self;
            }
            pub fn setLookAt(self: *Editor, eye: Vec3, center: Vec3, up: Vec3) *Editor {
                self._pending_look_at = .{ .eye = eye, .center = center, .up = up };
                return self;
            }
            pub fn setTransform(self: *Editor, transform: TransformT) *Editor {
                // Direct replace
                self._camera._transform = transform;
                return self;
            }

            pub fn apply(self: *Editor) void {
                const cam = self._camera;
                if (self._pending_fov_y) |v| cam._fov_y = v;
                if (self._pending_aspect) |v| cam._aspect = v;
                if (self._pending_near) |v| cam._near = v;
                if (self._pending_far) |v| cam._far = v;
                if (self._pending_perspective) |is_persp| cam._is_perspective = is_persp;
                if (self._pending_ortho) |o| {
                    cam._ortho_left = o.l;
                    cam._ortho_right = o.r;
                    cam._ortho_bottom = o.b;
                    cam._ortho_top = o.t;
                }
                if (self._pending_viewport) |vp| {
                    cam._viewport_x = vp.x;
                    cam._viewport_y = vp.y;
                    cam._viewport_w = vp.w;
                    cam._viewport_h = vp.h;
                    cam.applyViewport();
                }
                if (self._pending_position) |p| {
                    cam._transform.position = p;
                    cam._transform.recalculateTransformMatrix();
                    cam.recalculateView();
                }
                if (self._pending_look_at) |la| {
                    const eye_f = math.Vec(3, f32).init(.{ @floatCast(la.eye.v[0]), @floatCast(la.eye.v[1]), @floatCast(la.eye.v[2]) });
                    const center_f = math.Vec(3, f32).init(.{ @floatCast(la.center.v[0]), @floatCast(la.center.v[1]), @floatCast(la.center.v[2]) });
                    const up_f = math.Vec(3, f32).init(.{ @floatCast(la.up.v[0]), @floatCast(la.up.v[1]), @floatCast(la.up.v[2]) });
                    const view_f = math.mat.lookAt(eye_f, center_f, up_f);
                    cam._view = Self.castMat4Inner(view_f);
                    cam._transform._matrix = cam._view.inverse();
                    cam._transform.position = Vec3.init(.{
                        cam._transform._matrix.data[3].v[0],
                        cam._transform._matrix.data[3].v[1],
                        cam._transform._matrix.data[3].v[2],
                    });
                }

                cam.recalculateProjection();
                cam.recalculateView();

                self.* = Editor.init(cam);
            }

            fn castMat4Inner(m: math.Mat(4, 4, f32)) Mat4 {
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
