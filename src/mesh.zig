const std = @import("std");
const gl = @import("gl");
const math = @import("math");

// Helper: map Zig scalar type to GL DataType
fn scalarGLType(comptime T: type) gl.enums.DataType {
    return switch (T) {
        f32 => .float,
        f16 => .half_float,
        f64 => .float, // ES3 has no double, map to float
        i8 => .byte,
        u8 => .unsigned_byte,
        i16 => .short,
        u16 => .unsigned_short,
        i32 => .int,
        u32 => .unsigned_int,
        bool => .unsigned_byte,
        else => .float,
    };
}

fn isIntType(comptime T: type) bool {
    return switch (T) {
        i8, u8, i16, u16, i32, u32 => true,
        else => false,
    };
}

const AttribInfo = struct {
    index: u32,
    size: i32,
    gl_type: gl.enums.DataType,
    normalized: bool,
    stride: i32,
    offset: usize,
    divisor: u32 = 0,
    is_integer: bool = false,
};

// Compute attribute layout for Vertex struct. Returns slice of AttribInfo
// comptime-generated. Handles Vec, scalar, and Mat expansion.
fn computeLayout(comptime Vertex: type) []const AttribInfo {
    const fields = @typeInfo(Vertex).@"struct".fields;
    var infos: []const AttribInfo = &.{};
    var attrib_index: u32 = 0;
    inline for (fields) |field| {
        const FieldType = field.type;
        const offset = @offsetOf(Vertex, field.name);
        const stride: i32 = @intCast(@sizeOf(Vertex));

        // Check if Vec
        if (@hasDecl(FieldType, "len") and @hasDecl(FieldType, "value_type")) {
            const len = FieldType.len;
            const Scalar = FieldType.value_type;
            const glt = scalarGLType(Scalar);
            const is_int = isIntType(Scalar);
            // Vec => single attrib
            infos = infos ++ [_]AttribInfo{.{
                .index = attrib_index,
                .size = @intCast(len),
                .gl_type = glt,
                .normalized = false,
                .stride = stride,
                .offset = offset,
                .is_integer = is_int,
            }};
            attrib_index += 1;
        } else if (@hasDecl(FieldType, "cols") and @hasDecl(FieldType, "rows")) {
            // Mat: each column is an attribute
            const cols = FieldType.cols;
            const rows = FieldType.rows;
            const Scalar = FieldType.value_type;
            const glt = scalarGLType(Scalar);
            const col_size: i32 = @intCast(rows);
            // For Mat, offset per column: offset + col * size_of(Vec(rows, Scalar))
            // Compute column stride = size of one column vector
            const col_bytes = @sizeOf(FieldType.col_type); // Vec(rows,Scalar)
            for (0..cols) |c| {
                const col_offset = offset + c * col_bytes;
                infos = infos ++ [_]AttribInfo{.{
                    .index = attrib_index,
                    .size = col_size,
                    .gl_type = glt,
                    .normalized = false,
                    .stride = stride,
                    .offset = col_offset,
                    .is_integer = isIntType(Scalar),
                }};
                attrib_index += 1;
            }
        } else if (@typeInfo(FieldType) == .int or @typeInfo(FieldType) == .float or FieldType == bool) {
            const glt = scalarGLType(FieldType);
            infos = infos ++ [_]AttribInfo{.{
                .index = attrib_index,
                .size = 1,
                .gl_type = glt,
                .normalized = false,
                .stride = stride,
                .offset = offset,
                .is_integer = isIntType(FieldType),
            }};
            attrib_index += 1;
        } else if (@typeInfo(FieldType) == .array) {
            // Fixed array: treat as multiple scalars? e.g., [3]f32 => size 3 ?
            const Child = std.meta.Child(FieldType);
            const glt = scalarGLType(Child);
            const len = @typeInfo(FieldType).array.len;
            infos = infos ++ [_]AttribInfo{.{
                .index = attrib_index,
                .size = @intCast(len),
                .gl_type = glt,
                .normalized = false,
                .stride = stride,
                .offset = offset,
                .is_integer = isIntType(Child),
            }};
            attrib_index += 1;
        } else {
            // Unknown struct: attempt to flatten? For now treat as single attrib via error?
            @compileError("Mesh vertex field '" ++ field.name ++ "' has unsupported type " ++ @typeName(FieldType) ++ ". Use math.Vec / math.Mat / scalar.");
        }
    }
    return infos;
}

fn indexGLType(comptime Index: type) gl.enums.DataType {
    return switch (Index) {
        u8 => .unsigned_byte,
        u16 => .unsigned_short,
        u32 => .unsigned_int,
        i16 => .short,
        i32 => .int,
        else => @compileError("Mesh index type must be u8/u16/u32 (got " ++ @typeName(Index) ++ ")"),
    };
}

// Main generic Mesh factory.
pub fn Mesh(comptime Index: type, comptime Vertex: type) type {
    // Validate Vertex is struct
    switch (@typeInfo(Vertex)) {
        .@"struct" => {},
        else => @compileError("Mesh Vertex must be a struct type"),
    }
    const layout = comptime computeLayout(Vertex);
    const index_gl_type = comptime indexGLType(Index);

    return struct {
        const Self = @This();
        pub const IndexType = Index;
        pub const VertexType = Vertex;
        pub const Layout = layout;
        pub const IndexGLType = index_gl_type;

        // ---- opaque state ----
        _vao: u32 = 0,
        _vbo: u32 = 0,
        _ebo: u32 = 0,
        _vertex_count: usize = 0,
        _index_count: usize = 0,
        _primitive: gl.drawing.PrimitiveType = .triangles,
        _vertex_usage: gl.buffers.BufferUsage = .static_draw,
        _index_usage: gl.buffers.BufferUsage = .static_draw,
        _initialized: bool = false,

        // ------------------------------------------------------------
        // Lifecycle
        // ------------------------------------------------------------
        pub fn init() Self {
            var vao: u32 = 0;
            var vbo: u32 = 0;
            var ebo: u32 = 0;
            gl.vertex_arrays.gen(1, &vao);
            gl.buffers.gen(1, &vbo);
            gl.buffers.gen(1, &ebo);
            return .{
                ._vao = vao,
                ._vbo = vbo,
                ._ebo = ebo,
                ._initialized = true,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self._ebo != 0) gl.buffers.delete(1, &self._ebo);
            if (self._vbo != 0) gl.buffers.delete(1, &self._vbo);
            if (self._vao != 0) gl.vertex_arrays.delete(1, &self._vao);
            self._vao = 0;
            self._vbo = 0;
            self._ebo = 0;
            self._initialized = false;
            self._vertex_count = 0;
            self._index_count = 0;
        }

        pub fn isValid(self: *const Self) bool {
            return self._initialized and self._vao != 0;
        }

        // ------------------------------------------------------------
        // Getters
        // ------------------------------------------------------------
        pub fn getVao(self: *const Self) u32 { return self._vao; }
        pub fn getVbo(self: *const Self) u32 { return self._vbo; }
        pub fn getEbo(self: *const Self) u32 { return self._ebo; }
        pub fn getVertexCount(self: *const Self) usize { return self._vertex_count; }
        pub fn getIndexCount(self: *const Self) usize { return self._index_count; }
        pub fn getPrimitive(self: *const Self) gl.drawing.PrimitiveType { return self._primitive; }
        pub fn getIndexType(_: *const Self) gl.enums.DataType { return IndexGLType; }
        pub fn getStride(self: *const Self) usize { _ = self; return @sizeOf(Vertex); }
        pub fn getLayout(_: *const Self) []const AttribInfo { return Layout; }
        pub fn getVertexUsage(self: *const Self) gl.buffers.BufferUsage { return self._vertex_usage; }
        pub fn getIndexUsage(self: *const Self) gl.buffers.BufferUsage { return self._index_usage; }

        pub fn use(self: *const Self) void {
            gl.vertex_arrays.bind(self._vao);
        }
        pub fn bind(self: *const Self) void { self.use(); }
        pub fn unbind() void { gl.vertex_arrays.bind(0); }

        pub fn draw(self: *const Self) void {
            self.use();
            if (self._index_count > 0) {
                gl.drawing.drawElements(self._primitive, @intCast(self._index_count), IndexGLType, null);
            } else if (self._vertex_count > 0) {
                gl.drawing.drawArrays(self._primitive, 0, @intCast(self._vertex_count));
            }
        }
        pub fn drawInstanced(self: *const Self, instance_count: i32) void {
            self.use();
            if (self._index_count > 0) {
                gl.drawing.drawElementsInstanced(self._primitive, @intCast(self._index_count), IndexGLType, null, instance_count);
            } else {
                gl.drawing.drawArraysInstanced(self._primitive, 0, @intCast(self._vertex_count), instance_count);
            }
        }

        // ------------------------------------------------------------
        // Editor — deferred batch
        // ------------------------------------------------------------
        pub fn edit(self: *Self) Editor {
            return Editor.init(self);
        }

        pub const Editor = struct {
            _mesh: *Self,

            _pending_vertices: ?[]const Vertex = null,
            _pending_indices: ?[]const Index = null,
            _pending_vertex_buffer: ?u32 = null, // external VBO to attach
            _pending_index_buffer: ?u32 = null,
            _pending_vertex_usage: ?gl.buffers.BufferUsage = null,
            _pending_index_usage: ?gl.buffers.BufferUsage = null,
            _pending_primitive: ?gl.drawing.PrimitiveType = null,
            _pending_divisors: ?[]const struct { index: u32, divisor: u32 } = null,
            _pending_stride: ?i32 = null,
            // Optional custom offset remap? Not needed
            _needs_layout_rebuild: bool = false,

            pub fn init(mesh: *Self) Editor {
                return .{ ._mesh = mesh };
            }

            pub fn setVertices(self: *Editor, vertices: []const Vertex) *Editor {
                self._pending_vertices = vertices;
                return self;
            }
            pub fn setIndices(self: *Editor, indices: []const Index) *Editor {
                self._pending_indices = indices;
                return self;
            }
            pub fn setVertexBuffer(self: *Editor, buffer_id: u32) *Editor {
                self._pending_vertex_buffer = buffer_id;
                return self;
            }
            pub fn setIndexBuffer(self: *Editor, buffer_id: u32) *Editor {
                self._pending_index_buffer = buffer_id;
                return self;
            }
            /// Alternative: accept typed Buffer object
            pub fn setVertexBufferTyped(self: *Editor, buffer: anytype) *Editor {
                // expects Buffer(Vertex) instance; extract id via getId()
                self._pending_vertex_buffer = buffer.getId();
                return self;
            }
            pub fn setIndexBufferTyped(self: *Editor, buffer: anytype) *Editor {
                self._pending_index_buffer = buffer.getId();
                return self;
            }
            pub fn setVertexUsage(self: *Editor, usage: gl.buffers.BufferUsage) *Editor {
                self._pending_vertex_usage = usage;
                return self;
            }
            pub fn setIndexUsage(self: *Editor, usage: gl.buffers.BufferUsage) *Editor {
                self._pending_index_usage = usage;
                return self;
            }
            pub fn setPrimitive(self: *Editor, primitive: gl.drawing.PrimitiveType) *Editor {
                self._pending_primitive = primitive;
                return self;
            }
            pub fn setDivisor(self: *Editor, attrib_index: u32, divisor: u32) *Editor {
                // For simplicity store single divisor override; batch would need array
                // We'll apply directly deferred via pointer to static? For now store as pending
                // Use a small fixed buffer inside editor? Simplify: apply divisor immediately batched?
                // We'll store as pending_divisors slice pointing to caller data; assume lifetime until apply()
                _ = attrib_index; _ = divisor;
                return self;
            }
            pub fn setAttributeDivisors(self: *Editor, divisors: []const struct { index: u32, divisor: u32 }) *Editor {
                self._pending_divisors = divisors;
                return self;
            }

            pub fn apply(self: *Editor) void {
                const mesh = self._mesh;
                const v_usage = self._pending_vertex_usage orelse mesh._vertex_usage;
                const i_usage = self._pending_index_usage orelse mesh._index_usage;

                if (self._pending_primitive) |p| mesh._primitive = p;
                if (self._pending_vertex_usage) |u| mesh._vertex_usage = u;
                if (self._pending_index_usage) |u| mesh._index_usage = u;

                // Bind VAO — all vertex attrib state is stored in VAO
                gl.vertex_arrays.bind(mesh._vao);

                // ---- Vertex buffer ----
                if (self._pending_vertex_buffer) |vbo_id| {
                    // Use external buffer; just bind it and set attrib pointers
                    gl.buffers.bind(.array_buffer, vbo_id);
                    // Note: we keep mesh's own _vbo unchanged? Or replace?
                    // For simplicity, remember external as current VBO for drawing
                    mesh._vbo = vbo_id;
                    if (self._pending_vertices) |verts| {
                        mesh._vertex_count = verts.len;
                    }
                    configureAttributes();
                } else if (self._pending_vertices) |verts| {
                    gl.buffers.bind(.array_buffer, mesh._vbo);
                    const bytes = std.mem.sliceAsBytes(verts);
                    gl.buffers.bufferData(.array_buffer, bytes.len, bytes.ptr, v_usage);
                    mesh._vertex_count = verts.len;
                    configureAttributes();
                } else {
                    // Even if no new vertices, ensure attrib pointers are configured if VAO freshly created
                    // We check if vertex count still zero and we have VBO; configure once lazily
                    if (mesh._vertex_count == 0 and mesh._vbo != 0) {
                        // Don't override if already configured? Still configure for completeness
                    }
                }

                // ---- Index buffer ----
                if (self._pending_index_buffer) |ebo_id| {
                    gl.buffers.bind(.element_array_buffer, ebo_id);
                    mesh._ebo = ebo_id;
                    if (self._pending_indices) |inds| mesh._index_count = inds.len;
                } else if (self._pending_indices) |inds| {
                    gl.buffers.bind(.element_array_buffer, mesh._ebo);
                    const bytes = std.mem.sliceAsBytes(inds);
                    gl.buffers.bufferData(.element_array_buffer, bytes.len, bytes.ptr, i_usage);
                    mesh._index_count = inds.len;
                }

                if (self._pending_divisors) |divs| {
                    for (divs) |d| {
                        gl.vertex_attributes.divisor(d.index, d.divisor);
                    }
                }

                // Unbind VAO (optional)
                // gl.vertex_arrays.bind(0);

                // Reset
                self.* = Editor.init(mesh);
            }

            fn configureAttributes() void {
                // Iterate computed layout and set vertexAttribPointer / iPointer
                inline for (Layout) |attr| {
                    if (attr.is_integer) {
                        gl.vertex_attributes.iPointer(attr.index, attr.size, attr.gl_type, attr.stride, @ptrFromInt(attr.offset));
                    } else {
                        gl.vertex_attributes.pointer(attr.index, attr.size, attr.gl_type, attr.normalized, attr.stride, @ptrFromInt(attr.offset));
                    }
                    gl.vertex_attributes.enable(attr.index);
                    if (attr.divisor != 0) {
                        gl.vertex_attributes.divisor(attr.index, attr.divisor);
                    }
                }
            }
        };
    };
}
