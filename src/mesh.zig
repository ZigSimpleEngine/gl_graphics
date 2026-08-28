const std = @import("std");
const gl = @import("gl");
const math = @import("math");

/// Maps a scalar Zig type to the corresponding OpenGL data type.
/// Parameters:
/// - `T`: Scalar type to map (e.g., `f32`, `i16`, `u32`, `bool`).
/// Returns: `gl.enums.DataType` value for the given type; defaults to `.float` for unsupported types.
fn scalarGLType(comptime T: type) gl.enums.DataType {
    return switch (T) {
        f32 => .float, f16 => .half_float, f64 => .float,
        i8 => .byte, u8 => .unsigned_byte, i16 => .short, u16 => .unsigned_short,
        i32 => .int, u32 => .unsigned_int, bool => .unsigned_byte, else => .float,
    };
}

/// Determines whether a type is an integer vertex attribute type.
/// Parameters:
/// - `T`: Type to test.
/// Returns: `true` if `T` is `i8`, `u8`, `i16`, `u16`, `i32`, or `u32`; `false` otherwise.
fn isIntType(comptime T: type) bool {
    return switch (T) { i8, u8, i16, u16, i32, u32 => true, else => false };
}

/// Describes a single vertex attribute entry for OpenGL vertex specification.
pub const AttribInfo = struct {
    /// Location index of the attribute in the shader.
    index: u32,
    /// Number of components per vertex attribute (1 to 4).
    size: i32,
    /// OpenGL data type of each component.
    gl_type: gl.enums.DataType,
    /// Whether fixed-point data should be normalized on access.
    normalized: bool,
    /// Byte stride between consecutive vertices.
    stride: i32,
    /// Byte offset of this attribute within the vertex struct.
    offset: usize,
    /// Instance divisor for instanced rendering; 0 means per-vertex.
    divisor: u32 = 0,
    /// Whether the attribute requires integer pointer setup.
    is_integer: bool = false,
};

/// Computes the vertex attribute layout for a vertex struct at compile time.
/// Handles vector-like structs with `len` and `value_type`, matrix-like structs with `cols`, `rows`, `value_type` and `col_type`, scalars, and arrays.
/// Parameters:
/// - `Vertex`: Struct type representing a single vertex.
/// Returns: Compile-time slice of `AttribInfo` entries, one per attribute or matrix column.
fn computeLayout(comptime Vertex: type) []const AttribInfo {
    const fields = @typeInfo(Vertex).@"struct".fields;
    var infos: []const AttribInfo = &.{};
    var attrib_index: u32 = 0;
    inline for (fields) |field| {
        const FieldType = field.type;
        const offset = @offsetOf(Vertex, field.name);
        const stride: i32 = @intCast(@sizeOf(Vertex));
        if (@typeInfo(FieldType) == .@"struct" and @hasDecl(FieldType, "len") and @hasDecl(FieldType, "value_type")) {
            const len = FieldType.len; const Scalar = FieldType.value_type;
            infos = infos ++ [_]AttribInfo{.{ .index = attrib_index, .size = @intCast(len), .gl_type = scalarGLType(Scalar), .normalized = false, .stride = stride, .offset = offset, .is_integer = isIntType(Scalar) }};
            attrib_index += 1;
        } else if (@typeInfo(FieldType) == .@"struct" and @hasDecl(FieldType, "cols") and @hasDecl(FieldType, "rows")) {
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

/// Maps a mesh index type to the corresponding OpenGL element type.
/// Parameters:
/// - `Index`: Index element type. Supported: `u8`, `u16`, `u32`, `i16`, `i32`.
/// Returns: `gl.enums.DataType` suitable for `drawElements`.
fn indexGLType(comptime Index: type) gl.enums.DataType {
    return switch (Index) {
        u8 => .unsigned_byte, u16 => .unsigned_short, u32 => .unsigned_int, i16 => .short, i32 => .int,
        else => @compileError("Mesh index type must be u8/u16/u32"),
    };
}

/// Creates a generic mesh type parameterized by index and vertex types.
/// Parameters:
/// - `Index`: Index buffer element type.
/// - `Vertex`: Vertex struct type defining layout.
/// Returns: Opaque mesh type providing GPU resource management and draw API.
pub fn Mesh(comptime Index: type, comptime Vertex: type) type {
    switch (@typeInfo(Vertex)) { .@"struct" => {}, else => @compileError("Mesh Vertex must be struct") }
    const layout = comptime computeLayout(Vertex);
    const index_gl_type = comptime indexGLType(Index);
    const Impl = struct {
        /// Vertex array object handle.
        vao: u32 = 0,
        /// Vertex buffer object handle.
        vbo: u32 = 0,
        /// Element buffer object handle.
        ebo: u32 = 0,
        /// Number of vertices currently stored.
        vertex_count: usize = 0,
        /// Number of indices currently stored.
        index_count: usize = 0,
        /// Primitive type used for drawing.
        primitive: gl.drawing.PrimitiveType = .triangles,
        /// Buffer usage hint for vertex data.
        vertex_usage: gl.buffers.BufferUsage = .static_draw,
        /// Buffer usage hint for index data.
        index_usage: gl.buffers.BufferUsage = .static_draw,
        /// Whether GL objects have been initialized.
        initialized: bool = false,
    };

    return opaque {
        /// Opaque self type alias.
        const Self = @This();

        /// Casts an opaque mesh pointer to mutable internal storage.
        /// Parameters:
        /// - `self`: Opaque mesh pointer.
        /// Returns: Mutable `*Impl` pointer to internal data.
        inline fn impl(self: *Self) *Impl { return @ptrCast(@alignCast(self)); }

        /// Casts an opaque mesh pointer to const internal storage.
        /// Parameters:
        /// - `self`: Const opaque mesh pointer.
        /// Returns: Const `*const Impl` pointer to internal data.
        inline fn implConst(self: *const Self) *const Impl { return @ptrCast(@alignCast(self)); }

        /// Index element type for this mesh specialization.
        pub const IndexType = Index;

        /// Vertex type for this mesh specialization.
        pub const VertexType = Vertex;

        /// Compile-time computed vertex attribute layout.
        pub const Layout = layout;

        /// OpenGL data type for index elements.
        pub const IndexGLType = index_gl_type;

        /// Creates a new mesh with generated VAO, VBO and EBO.
        /// Parameters:
        /// - `allocator`: Allocator used to allocate internal storage.
        /// Returns: Pointer to the newly created opaque mesh, or allocation error.
        pub fn create(allocator: std.mem.Allocator) !*@This() {
            const m = try allocator.create(Impl);
            m.* = .{};
            var vao: u32 = 0; var vbo: u32 = 0; var ebo: u32 = 0;
            if (gl.loader.loaded()) {
                gl.vertex_arrays.gen(1, @ptrCast(&vao));
                gl.buffers.gen(1, @ptrCast(&vbo));
                gl.buffers.gen(1, @ptrCast(&ebo));
            } else {
                vao = 1; vbo = 2; ebo = 3;
            }
            m.vao = vao; m.vbo = vbo; m.ebo = ebo; m.initialized = true;
            return @ptrCast(m);
        }

        /// Alias for `create`.
        /// Parameters:
        /// - `allocator`: Allocator used to allocate internal storage.
        /// Returns: Pointer to the newly created opaque mesh.
        pub fn init(allocator: std.mem.Allocator) !*@This() { return create(allocator); }

        /// Destroys the mesh and deletes associated GL objects.
        /// Parameters:
        /// - `self`: Mesh to destroy.
        /// - `allocator`: Allocator that created the mesh.
        /// Returns: `void`.
        pub fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
            const m = self.impl();
            if (gl.loader.loaded() and m.ebo != 0) gl.buffers.delete(1, @ptrCast(&m.ebo));
            if (gl.loader.loaded() and m.vbo != 0) gl.buffers.delete(1, @ptrCast(&m.vbo));
            if (gl.loader.loaded() and m.vao != 0) gl.vertex_arrays.delete(1, @ptrCast(&m.vao));
            allocator.destroy(m);
        }

        /// Alias for `destroy`.
        /// Parameters:
        /// - `self`: Mesh to deinitialize.
        /// - `allocator`: Allocator that created the mesh.
        /// Returns: `void`.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void { self.destroy(allocator); }

        /// Checks whether the mesh has valid initialized GL handles.
        /// Parameters:
        /// - `self`: Mesh to test.
        /// Returns: `true` if initialized and VAO is non-zero.
        pub fn isValid(self: *const @This()) bool { const m = self.implConst(); return m.initialized and m.vao != 0; }

        /// Returns the vertex array object handle.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: VAO handle as `u32`.
        pub fn getVao(self: *const @This()) u32 { return self.implConst().vao; }

        /// Returns the vertex buffer object handle.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: VBO handle as `u32`.
        pub fn getVbo(self: *const @This()) u32 { return self.implConst().vbo; }

        /// Returns the element buffer object handle.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: EBO handle as `u32`.
        pub fn getEbo(self: *const @This()) u32 { return self.implConst().ebo; }

        /// Returns the current vertex count.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: Number of vertices.
        pub fn getVertexCount(self: *const @This()) usize { return self.implConst().vertex_count; }

        /// Returns the current index count.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: Number of indices.
        pub fn getIndexCount(self: *const @This()) usize { return self.implConst().index_count; }

        /// Returns the primitive type used for drawing.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: `gl.drawing.PrimitiveType` value.
        pub fn getPrimitive(self: *const @This()) gl.drawing.PrimitiveType { return self.implConst().primitive; }

        /// Returns the OpenGL type for index elements.
        /// Parameters:
        /// - `self`: Mesh instance (unused, kept for API symmetry).
        /// Returns: `gl.enums.DataType` for indices.
        pub fn getIndexType(_: *const @This()) gl.enums.DataType { return index_gl_type; }

        /// Returns the byte stride of a single vertex.
        /// Parameters:
        /// - `self`: Mesh instance (unused).
        /// Returns: Size of `Vertex` in bytes.
        pub fn getStride(_: *const @This()) usize { return @sizeOf(Vertex); }

        /// Returns the compile-time vertex attribute layout.
        /// Parameters:
        /// - `self`: Mesh instance (unused).
        /// Returns: Slice of `AttribInfo` describing attributes.
        pub fn getLayout(_: *const @This()) []const AttribInfo { return layout; }

        /// Returns the buffer usage hint for vertex data.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: `gl.buffers.BufferUsage` for vertices.
        pub fn getVertexUsage(self: *const @This()) gl.buffers.BufferUsage { return self.implConst().vertex_usage; }

        /// Returns the buffer usage hint for index data.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: `gl.buffers.BufferUsage` for indices.
        pub fn getIndexUsage(self: *const @This()) gl.buffers.BufferUsage { return self.implConst().index_usage; }

        /// Binds the mesh VAO as current.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: `void`.
        pub fn use(self: *const @This()) void { gl.vertex_arrays.bind(self.implConst().vao); }

        /// Alias for `use`, binds the mesh VAO.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: `void`.
        pub fn bind(self: *const @This()) void { self.use(); }

        /// Unbinds any VAO by binding 0.
        /// Parameters: none.
        /// Returns: `void`.
        pub fn unbind() void { gl.vertex_arrays.bind(0); }

        /// Draws the mesh using stored counts and primitive.
        /// Uses `drawElements` if indices exist, otherwise `drawArrays`.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// Returns: `void`.
        pub fn draw(self: *const @This()) void {
            self.use();
            const m = self.implConst();
            if (m.index_count > 0) gl.drawing.drawElements(m.primitive, @intCast(m.index_count), index_gl_type, null)
            else if (m.vertex_count > 0) gl.drawing.drawArrays(m.primitive, 0, @intCast(m.vertex_count));
        }

        /// Draws the mesh instanced.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// - `instance_count`: Number of instances to draw.
        /// Returns: `void`.
        pub fn drawInstanced(self: *const @This(), instance_count: i32) void {
            self.use();
            const m = self.implConst();
            if (m.index_count > 0) gl.drawing.drawElementsInstanced(m.primitive, @intCast(m.index_count), index_gl_type, null, instance_count)
            else gl.drawing.drawArraysInstanced(m.primitive, 0, @intCast(m.vertex_count), instance_count);
        }

        /// Creates an editor for batching mesh updates.
        /// Parameters:
        /// - `self`: Mesh to edit.
        /// Returns: `Editor` instance bound to the mesh.
        pub fn edit(self: *Self) Editor { return Editor.init(self); }

        /// Builder that batches pending mesh updates and applies them atomically.
        pub const Editor = struct {
            /// Target mesh being edited.
            _mesh: *Self,
            /// Pending vertex slice to upload.
            _pending_vertices: ?[]const Vertex = null,
            /// Pending index slice to upload.
            _pending_indices: ?[]const Index = null,
            /// Pending external vertex buffer handle override.
            _pending_vertex_buffer: ?u32 = null,
            /// Pending external index buffer handle override.
            _pending_index_buffer: ?u32 = null,
            /// Pending vertex buffer usage hint override.
            _pending_vertex_usage: ?gl.buffers.BufferUsage = null,
            /// Pending index buffer usage hint override.
            _pending_index_usage: ?gl.buffers.BufferUsage = null,
            /// Pending primitive type override.
            _pending_primitive: ?gl.drawing.PrimitiveType = null,
            /// Pending per-attribute divisor overrides.
            _pending_divisors: ?[]const struct { index: u32, divisor: u32 } = null,

            /// Initializes an editor for the given mesh.
            /// Parameters:
            /// - `mesh`: Mesh to edit.
            /// Returns: Initialized `Editor`.
            pub fn init(mesh: *Self) Editor { return .{ ._mesh = mesh }; }

            /// Queues vertex data for upload.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `vertices`: Slice of vertices to upload.
            /// Returns: `*const Editor` for chaining.
            pub fn setVertices(self: *const Editor, vertices: []const Vertex) *const Editor { @constCast(self)._pending_vertices = vertices; return @constCast(self); }

            /// Queues index data for upload.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `indices`: Slice of indices to upload.
            /// Returns: `*const Editor` for chaining.
            pub fn setIndices(self: *const Editor, indices: []const Index) *const Editor { @constCast(self)._pending_indices = indices; return @constCast(self); }

            /// Overrides the vertex buffer handle.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `buffer_id`: External GL buffer handle for vertices.
            /// Returns: `*const Editor` for chaining.
            pub fn setVertexBuffer(self: *const Editor, buffer_id: u32) *const Editor { @constCast(self)._pending_vertex_buffer = buffer_id; return @constCast(self); }

            /// Overrides the index buffer handle.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `buffer_id`: External GL buffer handle for indices.
            /// Returns: `*const Editor` for chaining.
            pub fn setIndexBuffer(self: *const Editor, buffer_id: u32) *const Editor { @constCast(self)._pending_index_buffer = buffer_id; return @constCast(self); }

            /// Overrides the vertex buffer using a typed buffer object.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `buffer`: Typed buffer providing `getId()`.
            /// Returns: `*const Editor` for chaining.
            pub fn setVertexBufferTyped(self: *const Editor, buffer: anytype) *const Editor { @constCast(self)._pending_vertex_buffer = buffer.getId(); return @constCast(self); }

            /// Overrides the index buffer using a typed buffer object.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `buffer`: Typed buffer providing `getId()`.
            /// Returns: `*const Editor` for chaining.
            pub fn setIndexBufferTyped(self: *const Editor, buffer: anytype) *const Editor { @constCast(self)._pending_index_buffer = buffer.getId(); return @constCast(self); }

            /// Sets the vertex buffer usage hint.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `usage`: `gl.buffers.BufferUsage` hint.
            /// Returns: `*const Editor` for chaining.
            pub fn setVertexUsage(self: *const Editor, usage: gl.buffers.BufferUsage) *const Editor { @constCast(self)._pending_vertex_usage = usage; return @constCast(self); }

            /// Sets the index buffer usage hint.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `usage`: `gl.buffers.BufferUsage` hint.
            /// Returns: `*const Editor` for chaining.
            pub fn setIndexUsage(self: *const Editor, usage: gl.buffers.BufferUsage) *const Editor { @constCast(self)._pending_index_usage = usage; return @constCast(self); }

            /// Sets the primitive type for drawing.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `primitive`: `gl.drawing.PrimitiveType` value.
            /// Returns: `*const Editor` for chaining.
            pub fn setPrimitive(self: *const Editor, primitive: gl.drawing.PrimitiveType) *const Editor { @constCast(self)._pending_primitive = primitive; return @constCast(self); }

            /// Sets a divisor for a single attribute index (no-op placeholder).
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `attrib_index`: Attribute location.
            /// - `divisor`: Instance divisor.
            /// Returns: `*const Editor` for chaining.
            pub fn setDivisor(self: *const Editor, attrib_index: u32, divisor: u32) *const Editor { _ = attrib_index; _ = divisor; return @constCast(self); }

            /// Sets per-attribute divisors in bulk.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `divisors`: Slice of `{index, divisor}` pairs.
            /// Returns: `*const Editor` for chaining.
            pub fn setAttributeDivisors(self: *const Editor, divisors: []const struct { index: u32, divisor: u32 }) *const Editor { @constCast(self)._pending_divisors = divisors; return @constCast(self); }

            /// Applies all pending changes to GL and resets pending state.
            /// Binds VAO, uploads vertex and index data or rebinds external buffers, configures attributes and divisors.
            /// Parameters:
            /// - `self`: Editor instance.
            /// Returns: `void`.
            pub fn apply(self: *const Editor) void {
                const m = @constCast(self)._mesh.impl();
                const loaded = gl.loader.loaded();
                const v_usage = @constCast(self)._pending_vertex_usage orelse m.vertex_usage;
                const i_usage = @constCast(self)._pending_index_usage orelse m.index_usage;
                if (@constCast(self)._pending_primitive) |p| m.primitive = p;
                if (@constCast(self)._pending_vertex_usage) |u| m.vertex_usage = u;
                if (@constCast(self)._pending_index_usage) |u| m.index_usage = u;
                if (loaded) gl.vertex_arrays.bind(m.vao);
                if (@constCast(self)._pending_vertex_buffer) |vbo_id| {
                    if (loaded) gl.buffers.bind(.array_buffer, vbo_id);
                    m.vbo = vbo_id;
                    if (@constCast(self)._pending_vertices) |verts| m.vertex_count = verts.len;
                    configureAttributes();
                } else if (@constCast(self)._pending_vertices) |verts| {
                    if (loaded) gl.buffers.bind(.array_buffer, m.vbo);
                    const bytes = std.mem.sliceAsBytes(verts);
                    if (loaded) gl.buffers.bufferData(.array_buffer, bytes.len, bytes.ptr, v_usage);
                    m.vertex_count = verts.len;
                    configureAttributes();
                }
                if (@constCast(self)._pending_index_buffer) |ebo_id| {
                    if (loaded) gl.buffers.bind(.element_array_buffer, ebo_id);
                    m.ebo = ebo_id;
                    if (@constCast(self)._pending_indices) |inds| m.index_count = inds.len;
                } else if (@constCast(self)._pending_indices) |inds| {
                    if (loaded) gl.buffers.bind(.element_array_buffer, m.ebo);
                    const bytes = std.mem.sliceAsBytes(inds);
                    if (loaded) gl.buffers.bufferData(.element_array_buffer, bytes.len, bytes.ptr, i_usage);
                    m.index_count = inds.len;
                }
                if (@constCast(self)._pending_divisors) |divs| for (divs) |d| if (loaded) gl.vertex_attributes.divisor(d.index, d.divisor);
                @constCast(self).* = Editor.init(@constCast(self)._mesh);
            }

            /// Configures vertex attribute pointers from the compile-time layout.
            /// Parameters: none (uses outer `layout` and current VAO binding).
            /// Returns: `void`.
            fn configureAttributes() void {
                const loaded = gl.loader.loaded();
                inline for (layout) |attr| {
                    if (attr.is_integer) {
                        if (loaded) gl.vertex_attributes.iPointer(attr.index, attr.size, attr.gl_type, attr.stride, @ptrFromInt(attr.offset));
                    } else if (loaded) {
                        gl.vertex_attributes.pointer(attr.index, attr.size, attr.gl_type, attr.normalized, attr.stride, @ptrFromInt(attr.offset));
                    }
                    if (loaded) gl.vertex_attributes.enable(attr.index);
                    if (attr.divisor != 0) if (loaded) gl.vertex_attributes.divisor(attr.index, attr.divisor);
                }
            }
        };
    };
}
