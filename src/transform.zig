const std = @import("std");
const math = @import("math");

pub fn Transform(comptime scalar_type_: type) type {
    return opaque {
        const Self = @This();
        pub const Scalar = scalar_type_;
        pub const Vec3 = math.Vec(3, Scalar);
        pub const QuatT = math.Quat(Scalar);
        pub const Mat4 = math.Mat(4, 4, Scalar);

        const Impl = struct {
            children: std.ArrayList(*Self) = .empty,
            parent: ?*Self = null,
            position: Vec3 = Vec3.zero(),
            rotation: QuatT = .{},
            scale: Vec3 = Vec3.one(),
            matrix: Mat4 = Mat4.identity(),
        };

        inline fn impl(self: *Self) *Impl { return @ptrCast(@alignCast(self)); }
        inline fn implConst(self: *const Self) *const Impl { return @ptrCast(@alignCast(self)); }

        pub fn create(allocator: std.mem.Allocator) !*Self {
            const m = try allocator.create(Impl);
            m.* = .{};
            return @ptrCast(m);
        }
        pub fn init(allocator: std.mem.Allocator, position: Vec3, rotation: QuatT, scale: Vec3) !*Self {
            const self = try create(allocator);
            const m = self.impl();
            m.position = position; m.rotation = rotation; m.scale = scale;
            self.recalculateTransformMatrix();
            return self;
        }
        pub fn identity(allocator: std.mem.Allocator) !*Self { return create(allocator); }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            const m = self.impl();
            m.children.deinit(allocator);
            allocator.destroy(m);
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void { self.destroy(allocator); }

        pub fn getPosition(self: *const Self) Vec3 { return self.implConst().position; }
        pub fn setPosition(self: *Self, v: Vec3) void { self.impl().position = v; }
        pub fn getRotation(self: *const Self) QuatT { return self.implConst().rotation; }
        pub fn setRotation(self: *Self, q: QuatT) void { self.impl().rotation = q; }
        pub fn getScale(self: *const Self) Vec3 { return self.implConst().scale; }
        pub fn setScale(self: *Self, v: Vec3) void { self.impl().scale = v; }
        pub fn getMatrix(self: *const Self) Mat4 { return self.implConst().matrix; }

        pub fn getChild(self: *const Self, id: usize) ?*Self {
            const m = self.implConst();
            if (id >= m.children.items.len) return null;
            return m.children.items[id];
        }
        pub fn getChildrenCount(self: *const Self) usize { return self.implConst().children.items.len; }
        pub fn getChildren(self: *const Self) ChildrenIterator { return .{ .children = self.implConst().children.items, .index = 0 }; }
        pub const ChildrenIterator = struct {
            children: []*Self,
            index: usize,
            pub fn next(self: *ChildrenIterator) ?*Self {
                if (self.index >= self.children.len) return null;
                const v = self.children[self.index]; self.index += 1; return v;
            }
            pub fn reset(self: *ChildrenIterator) void { self.index = 0; }
        };
        pub fn setChild(self: *Self, id: usize, transform: *Self) void {
            const m = self.impl();
            if (id >= m.children.items.len) return;
            const old = m.children.items[id];
            if (old.impl().parent == self) old.impl().parent = null;
            m.children.items[id] = transform;
            transform.impl().parent = self;
        }
        pub fn addChild(self: *Self, allocator: std.mem.Allocator, transform: *Self) !void {
            const m = self.impl();
            try m.children.append(allocator, transform);
            transform.impl().parent = self;
        }
        pub fn removeChild(self: *Self, allocator: std.mem.Allocator, id: usize) void {
            _ = allocator;
            const m = self.impl();
            if (id >= m.children.items.len) return;
            const child = m.children.items[id];
            if (child.impl().parent == self) child.impl().parent = null;
            _ = m.children.orderedRemove(id);
        }
        pub fn getParent(self: *const Self) ?*Self { return self.implConst().parent; }
        pub fn setParent(self: *Self, parent: ?*Self) void { self.impl().parent = parent; }

        fn computeLocalMatrix(self: *const Self) Mat4 {
            const m = self.implConst();
            var mat = Mat4.identity();
            mat = mat.translate(m.position);
            const rot = math.quat.mat4_cast(m.rotation);
            mat = mat.mul(rot);
            mat = mat.scale(m.scale);
            return mat;
        }
        pub fn recalculateTransformMatrix(self: *Self) void {
            const local = self.computeLocalMatrix();
            const m = self.impl();
            if (m.parent) |p| m.matrix = p.implConst().matrix.mul(local) else m.matrix = local;
        }
        pub fn recalculateTransformMatricesUpward(self: *Self, allocator: std.mem.Allocator) !void {
            var stack: std.ArrayList(*Self) = .empty;
            defer stack.deinit(allocator);
            var cur: ?*Self = self;
            while (cur) |node| { try stack.append(allocator, node); cur = node.implConst().parent; }
            var i: usize = stack.items.len;
            while (i > 0) { i -= 1; stack.items[i].recalculateTransformMatrix(); }
        }
        pub fn recalculateTransformMatricesDownward(self: *Self) void {
            self.recalculateTransformMatrix();
            const m = self.implConst();
            for (m.children.items) |child| child.recalculateTransformMatricesDownward();
        }
    };
}
