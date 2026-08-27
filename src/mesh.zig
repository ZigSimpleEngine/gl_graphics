const std = @import("std");
const gl = @import("gl");
const math = @import("math");

fn scalarGLType(comptime T: type) gl.enums.DataType {
    return switch (T) {
        f32 => .float, f16 => .half_float, f64 => .float,
        i8 => .byte, u8 => .unsigned_byte, i16 => .short, u16 => .unsigned_short,
        i32 => .int, u32 => .unsigned_int, bool => .unsigned_byte, else => .float,
    };
}
fn isIntType(comptime T: type) bool {
    return switch (T) { i8, u8, i16, u16, i32, u32 => true, else => false };
}
pub const AttribInfo = struct {
    index: u32, size: i32, gl_type: gl.enums.DataType, normalized: bool, stride: i32, offset: usize, divisor: u32 = 0, is_integer: bool = false,
};
fn computeLayout(comptime Vertex: type) []const AttribInfo {
    const fields = @typeInfo(Vertex).@"struct".fields;
    var infos: []const AttribInfo = &.{};
    var attrib_index: u32 = 0;
    inline for (fields) |field| {
        const FieldType = field.type;
        const offset = @offsetOf(Vertex, field.name);
        const stride: i32 = @intCast(@sizeOf(Vertex));
        if (@hasDecl(FieldType, "len") and @hasDecl(FieldType, "value_type")) {
            const len = FieldType.len; const Scalar = FieldType.value_type;
            infos = infos ++ [_]AttribInfo{.{ .index = attrib_index, .size = @intCast(len), .gl_type = scalarGLType(Scalar), .normalized = false, .stride = stride, .offset = offset, .is_integer = isIntType(Scalar) }};
            attrib_index += 1;
        } else if (@hasDecl(FieldType, "cols") and @hasDecl(FieldType, "rows")) {
            const cols = FieldType.cols; const rows = FieldType.rows; const Scalar = FieldType.value_type;
            const col_size: i32 = @intCast(rows); const col_bytes = @sizeOf(FieldType.col_type);
            for (0..cols) |c| {
                const col_offset = offset + c * col_bytes;
                infos = infos ++ [_]AttribInfo{.{ .index = attrib_index, .size = col_size, .gl_type = scalarGLType(Scalar), .normalized = false, .stride = stride, .offset = col_offset, .is_integer = isIntType(Scalar) }};
                attrib_index += 1;
            }
        } else if (@typeInfo(FieldType) == .int or @typeInfo(FieldType) == .float or FieldType == bool) {
            infos = infos ++ [_]AttribInfo{.{ .index = attrib_index, .size = 1, .gl_type = scalarGLType(FieldType), .normalized = false, .stride = stride, .offset = offset, .is_integer = isIntType(FieldType) }};
            attrib_index += 1;
        } else if (@typeInfo(FieldType) == .array) {
            const Child = std.meta.Child(FieldType); const len = @typeInfo(FieldType).array.len;
            infos = infos ++ [_]AttribInfo{.{ .index = attrib_index, .size = @intCast(len), .gl_type = scalarGLType(Child), .normalized = false, .stride = stride, .offset = offset, .is_integer = isIntType(Child) }};
            attrib_index += 1;
        } else { @compileError("Mesh vertex field '" ++ field.name ++ "' unsupported type " ++ @typeName(FieldType)); }
    }
    return infos;
}
fn indexGLType(comptime Index: type) gl.enums.DataType {
    return switch (Index) {
        u8 => .unsigned_byte, u16 => .unsigned_short, u32 => .unsigned_int, i16 => .short, i32 => .int,
        else => @compileError("Mesh index type must be u8/u16/u32"),
    };
}

pub fn Mesh(comptime Index: type, comptime Vertex: type) type {
    switch (@typeInfo(Vertex)) { .@"struct" => {}, else => @compileError("Mesh Vertex must be struct") }
    const layout = comptime computeLayout(Vertex);
    const index_gl_type = comptime indexGLType(Index);

    const Impl = struct {
        vao: u32 = 0, vbo: u32 = 0, ebo: u32 = 0,
        vertex_count: usize = 0, index_count: usize = 0,
        primitive: gl.drawing.PrimitiveType = .triangles,
        vertex_usage: gl.buffers.BufferUsage = .static_draw,
        index_usage: gl.buffers.BufferUsage = .static_draw,
        initialized: bool = false,
    };

    return opaque {
        inline fn impl(self: *@This()) *Impl { return @ptrCast(@alignCast(self)); }
        inline fn implConst(self: *const @This()) *const Impl { return @ptrCast(@alignCast(self)); }

        pub const IndexType = Index;
        pub const VertexType = Vertex;
        pub const Layout = layout;
        pub const IndexGLType = index_gl_type;

        pub fn create(allocator: std.mem.Allocator) !*@This() {
            const m = try allocator.create(Impl);
            m.* = .{};
            var vao: u32 = 0; var vbo: u32 = 0; var ebo: u32 = 0;
            gl.vertex_arrays.gen(1, &vao);
            gl.buffers.gen(1, &vbo);
            gl.buffers.gen(1, &ebo);
            m.vao = vao; m.vbo = vbo; m.ebo = ebo; m.initialized = true;
            return @ptrCast(m);
        }
        pub fn init(allocator: std.mem.Allocator) !*@This() { return create(allocator); }
        pub fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
            const m = self.impl();
            if (m.ebo != 0) gl.buffers.delete(1, &m.ebo);
            if (m.vbo != 0) gl.buffers.delete(1, &m.vbo);
            if (m.vao != 0) gl.vertex_arrays.delete(1, &m.vao);
            allocator.destroy(m);
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void { self.destroy(allocator); }
        pub fn isValid(self: *const @This()) bool { const m = self.implConst(); return m.initialized and m.vao != 0; }

        pub fn getVao(self: *const @This()) u32 { return self.implConst().vao; }
        pub fn getVbo(self: *const @This()) u32 { return self.implConst().vbo; }
        pub fn getEbo(self: *const @This()) u32 { return self.implConst().ebo; }
        pub fn getVertexCount(self: *const @This()) usize { return self.implConst().vertex_count; }
        pub fn getIndexCount(self: *const @This()) usize { return self.implConst().index_count; }
        pub fn getPrimitive(self: *const @This()) gl.drawing.PrimitiveType { return self.implConst().primitive; }
        pub fn getIndexType(_: *const @This()) gl.enums.DataType { return index_gl_type; }
        pub fn getStride(_: *const @This()) usize { return @sizeOf(Vertex); }
        pub fn getLayout(_: *const @This()) []const AttribInfo { return layout; }
        pub fn getVertexUsage(self: *const @This()) gl.buffers.BufferUsage { return self.implConst().vertex_usage; }
        pub fn getIndexUsage(self: *const @This()) gl.buffers.BufferUsage { return self.implConst().index_usage; }

        pub fn use(self: *const @This()) void { gl.vertex_arrays.bind(self.implConst().vao); }
        pub fn bind(self: *const @This()) void { self.use(); }
        pub fn unbind() void { gl.vertex_arrays.bind(0); }
        pub fn draw(self: *const @This()) void {
            self.use();
            const m = self.implConst();
            if (m.index_count > 0) gl.drawing.drawElements(m.primitive, @intCast(m.index_count), index_gl_type, null)
            else if (m.vertex_count > 0) gl.drawing.drawArrays(m.primitive, 0, @intCast(m.vertex_count));
        }
        pub fn drawInstanced(self: *const @This(), instance_count: i32) void {
            self.use();
            const m = self.implConst();
            if (m.index_count > 0) gl.drawing.drawElementsInstanced(m.primitive, @intCast(m.index_count), index_gl_type, null, instance_count)
            else gl.drawing.drawArraysInstanced(m.primitive, 0, @intCast(m.vertex_count), instance_count);
        }

        pub fn edit(self: *@This()) Editor { return Editor.init(self); }

        pub const Editor = struct {
            _mesh: *@This(),
            _pending_vertices: ?[]const Vertex = null,
            _pending_indices: ?[]const Index = null,
            _pending_vertex_buffer: ?u32 = null,
            _pending_index_buffer: ?u32 = null,
            _pending_vertex_usage: ?gl.buffers.BufferUsage = null,
            _pending_index_usage: ?gl.buffers.BufferUsage = null,
            _pending_primitive: ?gl.drawing.PrimitiveType = null,
            _pending_divisors: ?[]const struct { index: u32, divisor: u32 } = null,

            pub fn init(mesh: *@This()) Editor { return .{ ._mesh = mesh }; }

            pub fn setVertices(self: *Editor, vertices: []const Vertex) *Editor { self._pending_vertices = vertices; return self; }
            pub fn setIndices(self: *Editor, indices: []const Index) *Editor { self._pending_indices = indices; return self; }
            pub fn setVertexBuffer(self: *Editor, buffer_id: u32) *Editor { self._pending_vertex_buffer = buffer_id; return self; }
            pub fn setIndexBuffer(self: *Editor, buffer_id: u32) *Editor { self._pending_index_buffer = buffer_id; return self; }
            pub fn setVertexBufferTyped(self: *Editor, buffer: anytype) *Editor { self._pending_vertex_buffer = buffer.getId(); return self; }
            pub fn setIndexBufferTyped(self: *Editor, buffer: anytype) *Editor { self._pending_index_buffer = buffer.getId(); return self; }
            pub fn setVertexUsage(self: *Editor, usage: gl.buffers.BufferUsage) *Editor { self._pending_vertex_usage = usage; return self; }
            pub fn setIndexUsage(self: *Editor, usage: gl.buffers.BufferUsage) *Editor { self._pending_index_usage = usage; return self; }
            pub fn setPrimitive(self: *Editor, primitive: gl.drawing.PrimitiveType) *Editor { self._pending_primitive = primitive; return self; }
            pub fn setDivisor(self: *Editor, attrib_index: u32, divisor: u32) *Editor { _ = attrib_index; _ = divisor; return self; }
            pub fn setAttributeDivisors(self: *Editor, divisors: []const struct { index: u32, divisor: u32 }) *Editor { self._pending_divisors = divisors; return self; }

            pub fn apply(self: *Editor) void {
                const m = self._mesh.impl();
                const v_usage = self._pending_vertex_usage orelse m.vertex_usage;
                const i_usage = self._pending_index_usage orelse m.index_usage;
                if (self._pending_primitive) |p| m.primitive = p;
                if (self._pending_vertex_usage) |u| m.vertex_usage = u;
                if (self._pending_index_usage) |u| m.index_usage = u;
                gl.vertex_arrays.bind(m.vao);
                if (self._pending_vertex_buffer) |vbo_id| {
                    gl.buffers.bind(.array_buffer, vbo_id);
                    m.vbo = vbo_id;
                    if (self._pending_vertices) |verts| m.vertex_count = verts.len;
                    configureAttributes();
                } else if (self._pending_vertices) |verts| {
                    gl.buffers.bind(.array_buffer, m.vbo);
                    const bytes = std.mem.sliceAsBytes(verts);
                    gl.buffers.bufferData(.array_buffer, bytes.len, bytes.ptr, v_usage);
                    m.vertex_count = verts.len;
                    configureAttributes();
                }
                if (self._pending_index_buffer) |ebo_id| {
                    gl.buffers.bind(.element_array_buffer, ebo_id);
                    m.ebo = ebo_id;
                    if (self._pending_indices) |inds| m.index_count = inds.len;
                } else if (self._pending_indices) |inds| {
                    gl.buffers.bind(.element_array_buffer, m.ebo);
                    const bytes = std.mem.sliceAsBytes(inds);
                    gl.buffers.bufferData(.element_array_buffer, bytes.len, bytes.ptr, i_usage);
                    m.index_count = inds.len;
                }
                if (self._pending_divisors) |divs| for (divs) |d| gl.vertex_attributes.divisor(d.index, d.divisor);
                self.* = Editor.init(self._mesh);
            }
            fn configureAttributes() void {
                inline for (layout) |attr| {
                    if (attr.is_integer) gl.vertex_attributes.iPointer(attr.index, attr.size, attr.gl_type, attr.stride, @ptrFromInt(attr.offset))
                    else gl.vertex_attributes.pointer(attr.index, attr.size, attr.gl_type, attr.normalized, attr.stride, @ptrFromInt(attr.offset));
                    gl.vertex_attributes.enable(attr.index);
                    if (attr.divisor != 0) gl.vertex_attributes.divisor(attr.index, attr.divisor);
                }
            }
        };
    };
}
