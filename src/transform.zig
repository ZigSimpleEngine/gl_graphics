const std = @import("std");
const math = @import("math");

// Transform hierarchy with parent/children, position/rotation/scale
// and cached matrix.  All fields prefixed _ are considered private / opaque.
pub fn Transform(comptime scalar_type_: type) type {
    return struct {
        const Self = @This();
        pub const Scalar = scalar_type_;
        pub const Vec3 = math.Vec(3, Scalar);
        pub const QuatT = math.Quat(Scalar);
        pub const Mat4 = math.Mat(4, 4, Scalar);

        // ---- opaque ----
        _children: std.ArrayList(*Self) = .empty,
        _parent: ?*Self = null,

        position: Vec3 = Vec3.zero(),
        rotation: QuatT = .{},
        scale: Vec3 = Vec3.one(),

        _matrix: Mat4 = Mat4.identity(),

        // ------------------------------------------------------------
        // Constructors
        // ------------------------------------------------------------
        pub fn init(position: Vec3, rotation: QuatT, scale: Vec3) Self {
            return .{
                .position = position,
                .rotation = rotation,
                .scale = scale,
                ._matrix = Mat4.identity(),
            };
        }

        pub fn identity() Self {
            return .{};
        }

        // ------------------------------------------------------------
        // Children API
        // ------------------------------------------------------------
        pub fn getChild(self: *const Self, id: usize) ?*Self {
            if (id >= self._children.items.len) return null;
            return self._children.items[id];
        }

        pub fn getChildrenCount(self: *const Self) usize {
            return self._children.items.len;
        }

        pub fn getChildren(self: *const Self) ChildrenIterator {
            return .{ .children = self._children.items, .index = 0 };
        }

        pub const ChildrenIterator = struct {
            children: []*Self,
            index: usize,

            pub fn next(self: *ChildrenIterator) ?*Self {
                if (self.index >= self.children.len) return null;
                const v = self.children[self.index];
                self.index += 1;
                return v;
            }
            pub fn reset(self: *ChildrenIterator) void { self.index = 0; }
        };

        pub fn setChild(self: *Self, id: usize, transform: *Self) void {
            if (id >= self._children.items.len) return;
            // Detach old child parent link if needed
            const old = self._children.items[id];
            if (old._parent == self) old._parent = null;
            self._children.items[id] = transform;
            transform._parent = self;
        }

        pub fn addChild(self: *Self, allocator: std.mem.Allocator, transform: *Self) !void {
            try self._children.append(allocator, transform);
            transform._parent = self;
        }

        pub fn removeChild(self: *Self, allocator: std.mem.Allocator, id: usize) void {
            _ = allocator;
            if (id >= self._children.items.len) return;
            const child = self._children.items[id];
            if (child._parent == self) child._parent = null;
            _ = self._children.orderedRemove(id);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self._children.deinit(allocator);
            self._parent = null;
        }

        // ------------------------------------------------------------
        // Parent API
        // ------------------------------------------------------------
        pub fn getParent(self: *const Self) ?*Self {
            return self._parent;
        }

        pub fn setParent(self: *Self, parent: ?*Self) void {
            // Detach from old parent's children list? Only clear parent pointer;
            // full removal from old parent requires explicit removeChild.
            // To keep hierarchy consistent, if old parent exists, we don't auto-remove
            // from its list (caller should handle). This is minimal.
            self._parent = parent;
        }

        // Matrix getter (opaque cache)
        pub fn getMatrix(self: *const Self) Mat4 {
            return self._matrix;
        }

        // ------------------------------------------------------------
        // Matrix recalculation
        // ------------------------------------------------------------
        // Computes local TRS matrix then multiplies by parent cache on the left
        // (parent * local) so that result is "offset" for parent.
        fn computeLocalMatrix(self: *const Self) Mat4 {
            // Build TRS: T * R * S  (translate, then rotate, then scale)
            // Start identity, translate, then rotate via quat mat, then scale.
            var m = Mat4.identity();
            m = m.translate(self.position);
            // Apply rotation via quat → mat4
            const rot = math.quat.mat4_cast(self.rotation);
            m = m.mul(rot);
            m = m.scale(self.scale);
            return m;
        }

        pub fn recalculateTransformMatrix(self: *Self) void {
            const local = self.computeLocalMatrix();
            if (self._parent) |p| {
                self._matrix = p._matrix.mul(local);
            } else {
                self._matrix = local;
            }
        }

        // Walk upward to root, then recalculate chain downward to self.
        pub fn recalculateTransformMatricesUpward(self: *Self) void {
            // Collect stack of nodes from self up to root
            var stack: std.ArrayList(*Self) = .empty;
            defer stack.deinit(std.heap.page_allocator); // fallback; prefer caller allocator? Use page for simplicity
            // Actually we need allocator; use std.heap.page_allocator as transient
            var cur: ?*Self = self;
            while (cur) |node| {
                stack.append(std.heap.page_allocator, node) catch break;
                cur = node._parent;
            }
            // Now stack is [self, parent, ..., root] — reverse to compute top-down
            var i: usize = stack.items.len;
            while (i > 0) {
                i -= 1;
                const node = stack.items[i];
                node.recalculateTransformMatrix();
            }
        }

        // Starting from self, recalculate downward for all descendants depth-first.
        pub fn recalculateTransformMatricesDownward(self: *Self) void {
            self.recalculateTransformMatrix();
            for (self._children.items) |child| {
                child.recalculateTransformMatricesDownward();
            }
        }

        // Optional allocator-aware version
        pub fn recalculateUpwardAlloc(self: *Self, allocator: std.mem.Allocator) !void {
            var stack: std.ArrayList(*Self) = .empty;
            defer stack.deinit(allocator);
            var cur: ?*Self = self;
            while (cur) |node| {
                try stack.append(allocator, node);
                cur = node._parent;
            }
            var i: usize = stack.items.len;
            while (i > 0) {
                i -= 1;
                stack.items[i].recalculateTransformMatrix();
            }
        }

        pub fn recalculateDownwardAlloc(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator;
            self.recalculateTransformMatricesDownward();
        }
    };
}
