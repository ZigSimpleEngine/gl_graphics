const std = @import("std");
const gl = @import("gl");
const math = @import("math");
const Transform = @import("transform.zig").Transform;

pub fn Camera(comptime scalar_type_: type) type {
    return opaque {
        const Self = @This();
        pub const Scalar = scalar_type_;
        pub const Vec3 = math.Vec(3, Scalar);
        pub const Mat4 = math.Mat(4, 4, Scalar);
        pub const TransformT = Transform(Scalar);

        const Impl = struct {
            transform: *TransformT,
            fov_y: Scalar = std.math.degreesToRadians(60.0),
            aspect: Scalar = 16.0 / 9.0,
            near: Scalar = 0.1,
            far: Scalar = 1000.0,
            projection: Mat4 = Mat4.identity(),
            view: Mat4 = Mat4.identity(),
            viewport_x: i32 = 0,
            viewport_y: i32 = 0,
            viewport_w: i32 = 800,
            viewport_h: i32 = 600,
            is_perspective: bool = true,
            ortho_left: Scalar = -1,
            ortho_right: Scalar = 1,
            ortho_bottom: Scalar = -1,
            ortho_top: Scalar = 1,
            on_use_callback: ?*const fn (*Self) void = null,
        };

        inline fn impl(self: *Self) *Impl {
            return @ptrCast(@alignCast(self));
        }
        inline fn implConst(self: *const Self) *const Impl {
            return @ptrCast(@alignCast(self));
        }

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
        fn recalcView(m: *Impl) void {
            m.view = m.transform.getMatrix().inverse();
        }
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

        pub fn create(allocator: std.mem.Allocator, transform: *TransformT, on_use_callback: ?*const fn (*Self) void) !*Self {
            const m = try allocator.create(Impl);
            m.* = .{ .transform = transform, .on_use_callback = on_use_callback };
            recalcProjection(m);
            recalcView(m);
            return @ptrCast(m);
        }
        pub fn init(allocator: std.mem.Allocator, transform: *TransformT, on_use_callback: ?*const fn (*Self) void) !*Self {
            return create(allocator, transform, on_use_callback);
        }
        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self.impl());
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.destroy(allocator);
        }

        // Getters
        pub fn getTransform(self: *const Self) *TransformT {
            return self.implConst().transform;
        }
        pub fn getTransformMut(self: *Self) *TransformT {
            return self.impl().transform;
        }
        pub fn getFovY(self: *const Self) Scalar {
            return self.implConst().fov_y;
        }
        pub fn getAspect(self: *const Self) Scalar {
            return self.implConst().aspect;
        }
        pub fn getNear(self: *const Self) Scalar {
            return self.implConst().near;
        }
        pub fn getFar(self: *const Self) Scalar {
            return self.implConst().far;
        }
        pub fn getProjection(self: *const Self) Mat4 {
            return self.implConst().projection;
        }
        pub fn getView(self: *const Self) Mat4 {
            return self.implConst().view;
        }
        pub fn getViewProjection(self: *const Self) Mat4 {
            const m = self.implConst();
            return m.projection.mul(m.view);
        }
        pub fn getViewport(self: *const Self) struct { x: i32, y: i32, w: i32, h: i32 } {
            const m = self.implConst();
            return .{ .x = m.viewport_x, .y = m.viewport_y, .w = m.viewport_w, .h = m.viewport_h };
        }
        pub fn isPerspective(self: *const Self) bool {
            return self.implConst().is_perspective;
        }
        pub fn isOrtho(self: *const Self) bool {
            return !self.implConst().is_perspective;
        }
        pub fn getOnUseCallback(self: *const Self) ?*const fn (*Self) void {
            return self.implConst().on_use_callback;
        }

        pub fn applyViewport(self: *const Self) void {
            const m = self.implConst();
            gl.viewport.viewport(m.viewport_x, m.viewport_y, m.viewport_w, m.viewport_h);
        }
        pub fn use(self: *Self) void {
            const m = self.impl();
            if (m.on_use_callback) |cb| cb(self);
            recalcView(m);
            self.applyViewport();
        }

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
            _pending_on_use_callback: ?*const fn (*Self) void = null,
            _has_pending_on_use_callback: bool = false,
            pub fn init(camera: *Self) Editor {
                return .{ ._camera = camera };
            }
            pub fn setFovY(self: *Editor, v: Scalar) *Editor {
                self._pending_fov_y = v;
                return self;
            }
            pub fn setAspect(self: *Editor, v: Scalar) *Editor {
                self._pending_aspect = v;
                return self;
            }
            pub fn setNear(self: *Editor, v: Scalar) *Editor {
                self._pending_near = v;
                return self;
            }
            pub fn setFar(self: *Editor, v: Scalar) *Editor {
                self._pending_far = v;
                return self;
            }
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
            pub fn setTransform(self: *Editor, transform: *TransformT) *Editor {
                self._camera.impl().transform = transform;
                return self;
            }
            pub fn setOnUseCallback(self: *Editor, cb: ?*const fn (*Self) void) *Editor {
                self._pending_on_use_callback = cb;
                self._has_pending_on_use_callback = true;
                return self;
            }
            pub fn apply(self: *Editor) void {
                const cam = self._camera.impl();
                if (self._pending_fov_y) |v| cam.fov_y = v;
                if (self._pending_aspect) |v| cam.aspect = v;
                if (self._pending_near) |v| cam.near = v;
                if (self._pending_far) |v| cam.far = v;
                if (self._pending_perspective) |is_p| cam.is_perspective = is_p;
                if (self._pending_ortho) |o| {
                    cam.ortho_left = o.l;
                    cam.ortho_right = o.r;
                    cam.ortho_bottom = o.b;
                    cam.ortho_top = o.t;
                }
                if (self._pending_viewport) |vp| {
                    cam.viewport_x = vp.x;
                    cam.viewport_y = vp.y;
                    cam.viewport_w = vp.w;
                    cam.viewport_h = vp.h;
                    self._camera.applyViewport();
                }
                if (self._pending_position) |p| {
                    cam.transform.setPosition(p);
                    cam.transform.recalculateTransformMatrix();
                    recalcView(cam);
                }
                if (self._pending_look_at) |la| {
                    const eye_f = math.Vec(3, f32).init(.{ @floatCast(la.eye.v[0]), @floatCast(la.eye.v[1]), @floatCast(la.eye.v[2]) });
                    const center_f = math.Vec(3, f32).init(.{ @floatCast(la.center.v[0]), @floatCast(la.center.v[1]), @floatCast(la.center.v[2]) });
                    const up_f = math.Vec(3, f32).init(.{ @floatCast(la.up.v[0]), @floatCast(la.up.v[1]), @floatCast(la.up.v[2]) });
                    const view_f = math.mat.lookAt(eye_f, center_f, up_f);
                    cam.view = castMat4(view_f);
                    cam.transform.impl().matrix = cam.view.inverse();
                    cam.transform.setPosition(Vec3.init(.{ cam.transform.impl().matrix.data[3].v[0], cam.transform.impl().matrix.data[3].v[1], cam.transform.impl().matrix.data[3].v[2] }));
                }
                if (self._has_pending_on_use_callback) cam.on_use_callback = self._pending_on_use_callback;
                recalcProjection(cam);
                recalcView(cam);
                self.* = Editor.init(self._camera);
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
        };
    };
}
