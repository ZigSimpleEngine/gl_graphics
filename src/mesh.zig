const std = @import("std");
const gl = @import("gl");
const math = @import("math");

/// Maps a scalar Zig type to the corresponding OpenGL data type.
/// Parameters:
/// - `T`: Scalar type to map (e.g., `f32`, `i16`, `u32`, `bool`).
///
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
///
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
///
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

/// Number of top-level fields in the vertex struct (each becomes one SOA VBO).
fn fieldCount(comptime Vertex: type) usize {
    return @typeInfo(Vertex).@"struct".fields.len;
}

/// Byte stride between consecutive elements of a vertex field when stored tightly
/// as a plain SOA array: `@sizeOf(FieldType)` for vectors/scalars/arrays, and the
/// full matrix element size (so column attributes advance between matrices).
fn fieldElemStride(comptime FieldType: type) i32 {
    return @intCast(@sizeOf(FieldType));
}

/// Number of GL attribute locations a single vertex field expands to.
/// Mirrors the branch logic of `computeLayout`.
fn fieldAttribCount(comptime FieldType: type) usize {
    if (@typeInfo(FieldType) == .@"struct" and @hasDecl(FieldType, "len") and @hasDecl(FieldType, "value_type")) {
        return 1;
    } else if (@typeInfo(FieldType) == .@"struct" and @hasDecl(FieldType, "cols") and @hasDecl(FieldType, "rows")) {
        return FieldType.cols;
    } else if (@typeInfo(FieldType) == .array) {
        return 1;
    } else if (@typeInfo(FieldType) == .int or @typeInfo(FieldType) == .float or FieldType == bool) {
        return 1;
    } else {
        return 0;
    }
}

/// Maps a GL attribute location index (as produced by `computeLayout`) back to the
/// source vertex field index and the byte offset of the column within a matrix field.
const FieldSlot = struct {
    field_index: usize,
    field_type: type,
    column_offset: usize,
};
fn computeFieldSlots(comptime Vertex: type) [computeLayout(Vertex).len]FieldSlot {
    const fields = @typeInfo(Vertex).@"struct".fields;
    var slots: [computeLayout(Vertex).len]FieldSlot = undefined;
    var slot_i: usize = 0;
    inline for (fields, 0..) |field, fi| {
        const FT = field.type;
        if (@typeInfo(FT) == .@"struct" and @hasDecl(FT, "len") and @hasDecl(FT, "value_type")) {
            slots[slot_i] = .{ .field_index = fi, .field_type = FT, .column_offset = 0 };
            slot_i += 1;
        } else if (@typeInfo(FT) == .@"struct" and @hasDecl(FT, "cols") and @hasDecl(FT, "rows")) {
            for (0..FT.cols) |c| {
                slots[slot_i] = .{ .field_index = fi, .field_type = FT, .column_offset = c * @sizeOf(FT.col_type) };
                slot_i += 1;
            }
        } else if (@typeInfo(FT) == .int or @typeInfo(FT) == .float or FT == bool) {
            slots[slot_i] = .{ .field_index = fi, .field_type = FT, .column_offset = 0 };
            slot_i += 1;
        } else if (@typeInfo(FT) == .array) {
            slots[slot_i] = .{ .field_index = fi, .field_type = FT, .column_offset = 0 };
            slot_i += 1;
        }
    }
    return slots;
}

/// Maps a mesh index type to the corresponding OpenGL element type.
/// Parameters:
/// - `Index`: Index element type. Supported: `u8`, `u16`, `u32`, `i16`, `i32`.
///
/// Returns: `gl.enums.DataType` suitable for `drawElements`.
fn indexGLType(comptime Index: type) gl.enums.DataType {
    return switch (Index) {
        u8 => .unsigned_byte, u16 => .unsigned_short, u32 => .unsigned_int, i16 => .short, i32 => .int,
        else => @compileError("Mesh index type must be u8/u16/u32"),
    };
}

/// Creates a generic mesh type parameterized by vertex type.
/// Index type is inferred from the slice passed to `setIndices`, avoiding conversions.
/// Parameters:
/// - `Vertex`: Vertex struct type defining layout.
///
/// Returns: Opaque mesh type providing GPU resource management and draw API.
pub fn Mesh(comptime Vertex: type) type {
    switch (@typeInfo(Vertex)) { .@"struct" => {}, else => @compileError("Mesh Vertex must be struct") }
    const layout = comptime computeLayout(Vertex);
    const field_count = comptime fieldCount(Vertex);
    const field_slots = comptime computeFieldSlots(Vertex);
    // Byte size of each top-level vertex field, used to validate raw SOA uploads.
    const vertex_field_sizes = comptime blk: {
        const fs = @typeInfo(Vertex).@"struct".fields;
        var arr: [fs.len]usize = undefined;
        for (fs, 0..) |f, i| arr[i] = @sizeOf(f.type);
        break :blk arr;
    };
    const Impl = struct {
        /// Vertex array object handle.
        vao: u32 = 0,
        /// Vertex buffer object handle (used for interleaved AOS layout).
        vbo: u32 = 0,
        /// Element buffer object handle.
        ebo: u32 = 0,
        /// One VBO per vertex field, used for split (SOA) layout. 0 = not created.
        field_vbos: [field_count]u32 = .{0} ** field_count,
        /// Number of vertices currently stored.
        vertex_count: usize = 0,
        /// Number of indices currently stored.
        index_count: usize = 0,
        /// OpenGL type for the current index buffer (determined from last setIndices).
        index_gl_type: gl.enums.DataType = .unsigned_short,
        /// Primitive type used for drawing.
        primitive: gl.drawing.PrimitiveType = .triangles,
        /// Buffer usage hint for vertex data.
        vertex_usage: gl.buffers.BufferUsage = .static_draw,
        /// Buffer usage hint for index data.
        index_usage: gl.buffers.BufferUsage = .static_draw,
        /// Whether the mesh is currently configured with split (SOA) vertex buffers.
        using_soa: bool = false,
        /// Whether GL objects have been initialized.
        initialized: bool = false,
    };

    return opaque {
        /// Opaque self type alias.
        const Self = @This();

        /// Casts an opaque mesh pointer to mutable internal storage.
        /// Parameters:
        /// - `self`: Opaque mesh pointer.
        ///
        /// Returns: Mutable `*Impl` pointer to internal data.
        inline fn impl(self: *Self) *Impl { return @ptrCast(@alignCast(self)); }

        /// Casts an opaque mesh pointer to const internal storage.
        /// Parameters:
        /// - `self`: Const opaque mesh pointer.
        ///
        /// Returns: Const `*const Impl` pointer to internal data.
        inline fn implConst(self: *const Self) *const Impl { return @ptrCast(@alignCast(self)); }

        /// Vertex type for this mesh specialization.
        pub const VertexType = Vertex;

        /// SOA form of `Vertex`: struct where each vertex field is represented as a slice.
        /// Use as `Mesh.SOA` or `VertexType.SOA`-like via `Mesh.SOA`. Each field has type `[]const FieldType`.
        pub const SOA = blk: {
            const vfields = @typeInfo(Vertex).@"struct".fields;
            var names: [vfields.len][]const u8 = undefined;
            var types: [vfields.len]type = undefined;
            var attrs: [vfields.len]std.builtin.Type.StructField.Attributes = undefined;
            for (vfields, 0..) |vf, i| {
                names[i] = vf.name;
                types[i] = []const vf.type;
                attrs[i] = .{};
            }
            break :blk @Struct(.auto, null, &names, &types, &attrs);
        };

        /// Compile-time computed vertex attribute layout.
        pub const Layout = layout;

        /// Deprecated: Index type is now dynamic. Kept for compatibility as void.
        pub const IndexType = void;
        /// Deprecated: Index GL type is now dynamic per-mesh.
        pub const IndexGLType = gl.enums.DataType.unsigned_short;

        /// Creates a new mesh with generated VAO, VBO and EBO.
        /// Parameters:
        /// - `allocator`: Allocator used to allocate internal storage.
        ///
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

        /// Creates a new mesh and immediately initializes it from a SOA struct.
        /// Convenience wrapper around `create` + `edit().setMeshSOA(...).apply()`.
        /// Accepts the same struct as `setMeshSOA` (e.g. `instanceSOA` result with `position`/`uv`/`normal`/`indices`).
        /// Parameters:
        /// - `allocator`: Allocator for mesh storage.
        /// - `mesh_soa_data`: Struct with vertex slices and optional `indices`.
        ///
        /// Returns: Pointer to the initialized mesh or allocation error.
        pub fn createWithSOA(allocator: std.mem.Allocator, mesh_soa_data: anytype) !*@This() {
            const self = try create(allocator);
            errdefer self.destroy(allocator);
            self.edit().setMeshSOA(mesh_soa_data).apply();
            return self;
        }

        /// Destroys the mesh and deletes associated GL objects.
        /// Parameters:
        /// - `self`: Mesh to destroy.
        /// - `allocator`: Allocator that created the mesh.
        ///
        /// Returns: `void`.
        pub fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
            const m = self.impl();
            if (gl.loader.loaded()) {
                if (m.ebo != 0) gl.buffers.delete(1, @ptrCast(&m.ebo));
                if (m.vbo != 0) gl.buffers.delete(1, @ptrCast(&m.vbo));
                inline for (0..field_count) |i| {
                    if (m.field_vbos[i] != 0) {
                        var id = m.field_vbos[i];
                        gl.buffers.delete(1, @ptrCast(&id));
                    }
                }
                if (m.vao != 0) gl.vertex_arrays.delete(1, @ptrCast(&m.vao));
            }
            allocator.destroy(m);
        }

        /// Checks whether the mesh has valid initialized GL handles.
        /// Parameters:
        /// - `self`: Mesh to test.
        ///
        /// Returns: `true` if initialized and VAO is non-zero.
        pub fn isValid(self: *const @This()) bool { const m = self.implConst(); return m.initialized and m.vao != 0; }

        /// Returns the vertex array object handle.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: VAO handle as `u32`.
        pub fn getVao(self: *const @This()) u32 { return self.implConst().vao; }

        /// Returns the vertex buffer object handle.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: VBO handle as `u32`.
        pub fn getVbo(self: *const @This()) u32 { return self.implConst().vbo; }

        /// Returns the element buffer object handle.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: EBO handle as `u32`.
        pub fn getEbo(self: *const @This()) u32 { return self.implConst().ebo; }

        /// Returns the current vertex count.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: Number of vertices.
        pub fn getVertexCount(self: *const @This()) usize { return self.implConst().vertex_count; }

        /// Returns the current index count.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: Number of indices.
        pub fn getIndexCount(self: *const @This()) usize { return self.implConst().index_count; }

        /// Returns the primitive type used for drawing.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: `gl.drawing.PrimitiveType` value.
        pub fn getPrimitive(self: *const @This()) gl.drawing.PrimitiveType { return self.implConst().primitive; }

        /// Returns the OpenGL type for index elements.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: `gl.enums.DataType` for indices.
        pub fn getIndexType(self: *const @This()) gl.enums.DataType { return self.implConst().index_gl_type; }

        /// Returns the byte stride of a single vertex.
        /// Parameters:
        /// - `self`: Mesh instance (unused).
        ///
        /// Returns: Size of `Vertex` in bytes.
        pub fn getStride(_: *const @This()) usize { return @sizeOf(Vertex); }

        /// Returns the compile-time vertex attribute layout.
        /// Parameters:
        /// - `self`: Mesh instance (unused).
        ///
        /// Returns: Slice of `AttribInfo` describing attributes.
        pub fn getLayout(_: *const @This()) []const AttribInfo { return layout; }

        /// Returns the buffer usage hint for vertex data.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: `gl.buffers.BufferUsage` for vertices.
        pub fn getVertexUsage(self: *const @This()) gl.buffers.BufferUsage { return self.implConst().vertex_usage; }

        /// Returns the buffer usage hint for index data.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: `gl.buffers.BufferUsage` for indices.
        pub fn getIndexUsage(self: *const @This()) gl.buffers.BufferUsage { return self.implConst().index_usage; }

        /// Binds the mesh VAO as current.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: `void`.
        pub fn use(self: *const @This()) void { gl.vertex_arrays.bind(self.implConst().vao); }

        /// Alias for `use`, binds the mesh VAO.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: `void`.
        pub fn bind(self: *const @This()) void { self.use(); }

        /// Unbinds any VAO by binding 0.
        /// Parameters: none.
        ///
        /// Returns: `void`.
        pub fn unbind() void { gl.vertex_arrays.bind(0); }

        /// Draws the mesh using stored counts and primitive.
        /// Uses `drawElements` if indices exist, otherwise `drawArrays`.
        /// Parameters:
        /// - `self`: Mesh instance.
        ///
        /// Returns: `void`.
        pub fn draw(self: *const @This()) void {
            self.use();
            const m = self.implConst();
            if (m.index_count > 0) gl.drawing.drawElements(m.primitive, @intCast(m.index_count), m.index_gl_type, null)
            else if (m.vertex_count > 0) gl.drawing.drawArrays(m.primitive, 0, @intCast(m.vertex_count));
        }

        /// Draws the mesh instanced.
        /// Parameters:
        /// - `self`: Mesh instance.
        /// - `instance_count`: Number of instances to draw.
        ///
        /// Returns: `void`.
        pub fn drawInstanced(self: *const @This(), instance_count: i32) void {
            self.use();
            const m = self.implConst();
            if (m.index_count > 0) gl.drawing.drawElementsInstanced(m.primitive, @intCast(m.index_count), m.index_gl_type, null, instance_count)
            else gl.drawing.drawArraysInstanced(m.primitive, 0, @intCast(m.vertex_count), instance_count);
        }

        /// Creates an editor for batching mesh updates.
        /// Parameters:
        /// - `self`: Mesh to edit.
        ///
        /// Returns: `Editor` instance bound to the mesh.
        pub fn edit(self: *Self) Editor { return Editor.init(self); }

        /// Builder that batches pending mesh updates and applies them atomically.
        pub const Editor = struct {
            /// Target mesh being edited.
            _mesh: *Self,
            /// Pending vertex slice to upload (interleaved AOS layout).
            _pending_vertices: ?[]const Vertex = null,
            /// Pending raw vertex bytes to upload (interleaved AOS layout).
            /// Alternative to `_pending_vertices` for type-erased uploads.
            _pending_vertices_bytes: ?struct { bytes: []const u8, count: usize } = null,
            /// True when pending vertices are supplied as split (SOA) per-field slices.
            _using_soa: bool = false,
            /// Pending per-field raw byte slices (only valid when `_using_soa`).
            _pending_soa_fields: [field_count]?[]const u8 = .{null} ** field_count,
            /// Number of vertices in the pending SOA data.
            _pending_soa_count: usize = 0,
            /// Pending index slice bytes to upload.
            _pending_indices_bytes: ?[]const u8 = null,
            /// Pending index GL type.
            _pending_index_gl_type: ?gl.enums.DataType = null,
            /// Pending index count.
            _pending_index_count: usize = 0,
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
            ///
            /// Returns: Initialized `Editor`.
            pub fn init(mesh: *Self) Editor { return .{ ._mesh = mesh }; }

            /// Queues vertex data for upload (interleaved AOS layout).
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `vertices`: Slice of vertices to upload.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setVertices(self: *const Editor, vertices: []const Vertex) *const Editor {
                const mut = @constCast(self);
                mut._using_soa = false;
                mut._pending_vertices = vertices;
                return mut;
            }

            /// Queues raw vertex bytes for upload (interleaved AOS layout).
            /// Type-erased counterpart of `setVertices`: no `Vertex` type is
            /// needed at the call site, only the byte size contract
            /// `bytes.len == count * @sizeOf(Vertex)`.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `bytes`: Raw interleaved vertex bytes to upload.
            /// - `count`: Number of vertices encoded in `bytes`.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setVerticesBytes(self: *const Editor, bytes: []const u8, count: usize) *const Editor {
                const mut = @constCast(self);
                if (bytes.len != count * @sizeOf(Vertex)) @panic("setVerticesBytes: byte size mismatch");
                mut._using_soa = false;
                mut._pending_vertices = null;
                mut._pending_vertices_bytes = .{ .bytes = bytes, .count = count };
                return mut;
            }

            /// Queues vertex data in SOA (struct-of-arrays) form for upload.
            /// Each vertex field is recorded as its own byte slice; no temporary
            /// interleaved array is allocated and no GL calls are issued here. The
            /// actual per-field VBO upload happens in `apply`.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `soa`: Value of type Vertex.SOA containing per-attribute slices.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setVerticesSOA(self: *const Editor, soa: anytype) *const Editor {
                const mut = @constCast(self);
                const SoaT = @TypeOf(soa);
                const soa_info = @typeInfo(SoaT);
                if (soa_info != .@"struct") @compileError("SOA must be a struct");
                const vertex_info = @typeInfo(Vertex);
                if (vertex_info != .@"struct") @compileError("Vertex must be a struct");
                const vertex_fields = vertex_info.@"struct".fields;

                // Reset any previous SOA pending state.
                mut._using_soa = false;
                mut._pending_vertices = null;
                for (&mut._pending_soa_fields) |*slot| slot.* = null;
                mut._pending_soa_count = 0;

                // Determine element count from the first non-empty field.
                var count: usize = 0;
                const soa_fields = soa_info.@"struct".fields;
                if (soa_fields.len > 0) {
                    count = @field(soa, soa_fields[0].name).len;
                    inline for (soa_fields) |f| {
                        if (@field(soa, f.name).len != count) @panic("SOA fields length mismatch");
                    }
                }
                if (count == 0) {
                    mut._pending_soa_count = 0;
                    mut._using_soa = true;
                    return mut;
                }

                // Match each vertex field to its SOA slice and store raw bytes.
                inline for (vertex_fields, 0..) |vf, fi| {
                    if (@hasField(SoaT, vf.name)) {
                        const slice = @field(soa, vf.name);
                        if (slice.len != count) @panic("SOA field length mismatch");
                        mut._pending_soa_fields[fi] = std.mem.sliceAsBytes(slice);
                    }
                }
                mut._pending_soa_count = count;
                mut._using_soa = true;
                return mut;
            }

            /// Queues vertex data in SOA form from an arbitrary source struct.
            /// Performs comptime validation that every field of `Vertex` exists in `source` with matching element type.
            /// Assembles a `VertexType.SOA`-like struct with exactly the vertex fields and forwards to `setVerticesSOA`.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `source`: Struct containing slices/arrays for each vertex attribute (may contain extra fields).
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setVerticesSOA2(self: *const Editor, source: anytype) *const Editor {
                const Source = @TypeOf(source);
                const sInfo = @typeInfo(Source);
                if (sInfo != .@"struct") @compileError("setVerticesSOA2: source must be a struct, got " ++ @typeName(Source));
                const vInfo = @typeInfo(Vertex);

                // exact name match, with comptime type check
                inline for (vInfo.@"struct".fields) |vf| {
                    if (@hasField(Source, vf.name)) {
                        const SrcFieldType = @FieldType(Source, vf.name);
                        const child = switch (@typeInfo(SrcFieldType)) {
                            .pointer => |p| switch (p.size) {
                                .slice => p.child,
                                .one => switch (@typeInfo(p.child)) {
                                    .array => |a| a.child,
                                    else => @compileError("setVerticesSOA2: field '" ++ vf.name ++ "' must be a slice or array, got " ++ @typeName(SrcFieldType)),
                                },
                                else => @compileError("setVerticesSOA2: field '" ++ vf.name ++ "' must be a slice or array, got " ++ @typeName(SrcFieldType)),
                            },
                            .array => |a| a.child,
                            else => @compileError("setVerticesSOA2: field '" ++ vf.name ++ "' must be a slice or array, got " ++ @typeName(SrcFieldType)),
                        };
                        if (child != vf.type) {
                            @compileError("setVerticesSOA2: field '" ++ vf.name ++ "' element type mismatch: expected " ++ @typeName(vf.type) ++ ", got " ++ @typeName(child) ++ " (field type " ++ @typeName(SrcFieldType) ++ ")");
                        }
                    }
                }
                const CustomSOA = comptime blk: {
                    var present: usize = 0;
                    for (vInfo.@"struct".fields) |vf| {
                        if (@hasField(Source, vf.name)) present += 1;
                    }
                    var names: [present][]const u8 = undefined;
                    var types: [present]type = undefined;
                    var attrs: [present]std.builtin.Type.StructField.Attributes = undefined;
                    var idx: usize = 0;
                    for (vInfo.@"struct".fields) |vf| {
                        if (@hasField(Source, vf.name)) {
                            names[idx] = vf.name;
                            types[idx] = []const vf.type;
                            attrs[idx] = .{};
                            idx += 1;
                        }
                    }
                    break :blk @Struct(.auto, null, &names, &types, &attrs);
                };
                var soa: CustomSOA = undefined;
                inline for (vInfo.@"struct".fields) |vf| {
                    if (@hasField(Source, vf.name)) {
                        const SrcFT = @FieldType(Source, vf.name);
                        const info = @typeInfo(SrcFT);
                        if (info == .array) {
                            @field(soa, vf.name) = &@field(source, vf.name);
                        } else if (info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) == .array) {
                            @field(soa, vf.name) = @field(source, vf.name)[0..];
                        } else {
                            @field(soa, vf.name) = @field(source, vf.name);
                        }
                    }
                }
                return self.setVerticesSOA(soa);
            }

            /// Queues index data for upload. Index type is inferred from the slice element type.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `indices`: Slice or array of indices (`[]const u8`/`u16`/`u32` etc., also `[N]T` or `*const [N]T`).
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setIndices(self: *const Editor, indices: anytype) *const Editor {
                const Indices = @TypeOf(indices);
                const Child = switch (@typeInfo(Indices)) {
                    .pointer => |p| switch (p.size) {
                        .slice => p.child,
                        .one => switch (@typeInfo(p.child)) {
                            .array => |a| a.child,
                            else => @compileError("setIndices expects a slice or array, got " ++ @typeName(Indices)),
                        },
                        else => @compileError("setIndices expects a slice or array, got " ++ @typeName(Indices)),
                    },
                    .array => |a| a.child,
                    else => @compileError("setIndices expects a slice or array, got " ++ @typeName(Indices)),
                };
                const gl_type = indexGLType(Child);
                const mut = @constCast(self);
                const bytes: []const u8 = switch (@typeInfo(Indices)) {
                    .pointer => |p| switch (p.size) {
                        .slice => std.mem.sliceAsBytes(indices),
                        .one => std.mem.sliceAsBytes(indices[0..]),
                        else => unreachable,
                    },
                    .array => blk: {
                        const slice: []const Child = &indices;
                        break :blk std.mem.sliceAsBytes(slice);
                    },
                    else => unreachable,
                };
                const count: usize = switch (@typeInfo(Indices)) {
                    .pointer => |p| switch (p.size) {
                        .slice => indices.len,
                        .one => indices.len,
                        else => unreachable,
                    },
                    .array => @typeInfo(Indices).array.len,
                    else => unreachable,
                };
                mut._pending_indices_bytes = bytes;
                mut._pending_index_gl_type = gl_type;
                mut._pending_index_count = count;
                return mut;
            }

            /// Queues both vertex and index data from a single mesh SOA struct.
            /// Accepts the same struct as `setVerticesSOA2` (e.g. wavefront_obj's `instanceSOA` result) which contains vertex attributes (`position`, `normal`, `uv`, etc.) plus optional `indices`.
            /// Vertex attributes are forwarded to `setVerticesSOA2`; if `indices` field exists it is forwarded to `setIndices`.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `mesh_data_soa`: Struct with vertex slices and optional `indices` slice/array.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setMeshSOA(self: *const Editor, mesh_data_soa: anytype) *const Editor {
                const Data = @TypeOf(mesh_data_soa);
                if (@typeInfo(Data) != .@"struct") @compileError("setMeshSOA expects a struct, got " ++ @typeName(Data));
                _ = self.setVerticesSOA2(mesh_data_soa);
                if (@hasField(Data, "indices")) {
                    _ = self.setIndices(@field(mesh_data_soa, "indices"));
                }
                return self;
            }

            /// Queues raw index bytes for upload with an explicit element type.
            /// Type-erased counterpart of `setIndices`: the element type is
            /// given as a GL enum instead of a Zig slice type.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `bytes`: Raw index bytes to upload.
            /// - `gl_type`: Element type (`.unsigned_byte`/`.unsigned_short`/`.unsigned_int`).
            /// - `count`: Number of indices encoded in `bytes`.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setIndicesBytes(self: *const Editor, bytes: []const u8, gl_type: gl.enums.DataType, count: usize) *const Editor {
                const elem_size: usize = switch (gl_type) {
                    .unsigned_byte => 1,
                    .unsigned_short, .short => 2,
                    .unsigned_int, .int => 4,
                    else => @panic("setIndicesBytes: unsupported index type"),
                };
                if (bytes.len != count * elem_size) @panic("setIndicesBytes: byte size mismatch");
                const mut = @constCast(self);
                mut._pending_indices_bytes = bytes;
                mut._pending_index_gl_type = gl_type;
                mut._pending_index_count = count;
                return mut;
            }

            /// Queues raw bytes for one SOA vertex field.
            /// Type-erased building block for split-layout uploads: call once per
            /// populated field, then `setSoaCount`, then `apply`. Bytes must hold
            /// `count * @sizeOf(field)` tightly packed elements.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `field_index`: Top-level vertex field index (declaration order).
            /// - `bytes`: Raw field bytes to upload.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setSoaField(self: *const Editor, field_index: u32, bytes: []const u8) *const Editor {
                const mut = @constCast(self);
                if (field_index >= field_count) @panic("setSoaField: field index out of bounds");
                mut._using_soa = true;
                mut._pending_vertices = null;
                mut._pending_vertices_bytes = null;
                mut._pending_soa_fields[field_index] = bytes;
                return mut;
            }

            /// Sets the vertex count for a type-erased SOA upload.
            /// Companion of `setSoaField`; sizes are validated in `apply`.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `count`: Number of vertices in every populated SOA field.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setSoaCount(self: *const Editor, count: usize) *const Editor {
                const mut = @constCast(self);
                mut._using_soa = true;
                mut._pending_vertices = null;
                mut._pending_vertices_bytes = null;
                mut._pending_soa_count = count;
                return mut;
            }

            /// Overrides the vertex buffer handle.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `buffer_id`: External GL buffer handle for vertices.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setVertexBuffer(self: *const Editor, buffer_id: u32) *const Editor { @constCast(self)._pending_vertex_buffer = buffer_id; return @constCast(self); }

            /// Overrides the index buffer handle.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `buffer_id`: External GL buffer handle for indices.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setIndexBuffer(self: *const Editor, buffer_id: u32) *const Editor { @constCast(self)._pending_index_buffer = buffer_id; return @constCast(self); }

            /// Overrides the vertex buffer using a typed buffer object.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `buffer`: Typed buffer providing `getId()`.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setVertexBufferTyped(self: *const Editor, buffer: anytype) *const Editor { @constCast(self)._pending_vertex_buffer = buffer.getId(); return @constCast(self); }

            /// Overrides the index buffer using a typed buffer object.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `buffer`: Typed buffer providing `getId()`.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setIndexBufferTyped(self: *const Editor, buffer: anytype) *const Editor { @constCast(self)._pending_index_buffer = buffer.getId(); return @constCast(self); }

            /// Sets the vertex buffer usage hint.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `usage`: `gl.buffers.BufferUsage` hint.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setVertexUsage(self: *const Editor, usage: gl.buffers.BufferUsage) *const Editor { @constCast(self)._pending_vertex_usage = usage; return @constCast(self); }

            /// Sets the index buffer usage hint.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `usage`: `gl.buffers.BufferUsage` hint.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setIndexUsage(self: *const Editor, usage: gl.buffers.BufferUsage) *const Editor { @constCast(self)._pending_index_usage = usage; return @constCast(self); }

            /// Sets the primitive type for drawing.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `primitive`: `gl.drawing.PrimitiveType` value.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setPrimitive(self: *const Editor, primitive: gl.drawing.PrimitiveType) *const Editor { @constCast(self)._pending_primitive = primitive; return @constCast(self); }

            /// Sets a divisor for a single attribute index (no-op placeholder).
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `attrib_index`: Attribute location.
            /// - `divisor`: Instance divisor.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setDivisor(self: *const Editor, attrib_index: u32, divisor: u32) *const Editor { _ = attrib_index; _ = divisor; return @constCast(self); }

            /// Sets per-attribute divisors in bulk.
            /// Parameters:
            /// - `self`: Editor instance.
            /// - `divisors`: Slice of `{index, divisor}` pairs.
            ///
            /// Returns: `*const Editor` for chaining.
            pub fn setAttributeDivisors(self: *const Editor, divisors: []const struct { index: u32, divisor: u32 }) *const Editor { @constCast(self)._pending_divisors = divisors; return @constCast(self); }

            /// Applies all pending changes to GL and resets pending state.
            /// Binds VAO, uploads vertex and index data or rebinds external buffers, configures attributes and divisors.
            /// Parameters:
            /// - `self`: Editor instance.
            ///
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

                if (@constCast(self)._using_soa) {
                    // Upload each vertex field into its own VBO, then configure
                    // attribute pointers against those dedicated buffers.
                    applySOA(self);
                } else if (@constCast(self)._pending_vertex_buffer) |vbo_id| {
                    if (loaded) gl.buffers.bind(.array_buffer, vbo_id);
                    m.vbo = vbo_id;
                    m.using_soa = false;
                    if (@constCast(self)._pending_vertices) |verts| m.vertex_count = verts.len;
                    if (@constCast(self)._pending_vertices_bytes) |vb| m.vertex_count = vb.count;
                    configureAttributes();
                } else if (@constCast(self)._pending_vertices) |verts| {
                    if (loaded) gl.buffers.bind(.array_buffer, m.vbo);
                    const bytes = std.mem.sliceAsBytes(verts);
                    if (loaded) gl.buffers.bufferData(.array_buffer, bytes.len, bytes.ptr, v_usage);
                    m.vertex_count = verts.len;
                    m.using_soa = false;
                    configureAttributes();
                } else if (@constCast(self)._pending_vertices_bytes) |vb| {
                    if (loaded) gl.buffers.bind(.array_buffer, m.vbo);
                    if (loaded) gl.buffers.bufferData(.array_buffer, vb.bytes.len, vb.bytes.ptr, v_usage);
                    m.vertex_count = vb.count;
                    m.using_soa = false;
                    configureAttributes();
                }
                if (@constCast(self)._pending_index_buffer) |ebo_id| {
                    if (loaded) gl.buffers.bind(.element_array_buffer, ebo_id);
                    m.ebo = ebo_id;
                    if (@constCast(self)._pending_indices_bytes) |_| {
                        m.index_count = @constCast(self)._pending_index_count;
                        if (@constCast(self)._pending_index_gl_type) |t| m.index_gl_type = t;
                    }
                } else if (@constCast(self)._pending_indices_bytes) |bytes| {
                    if (loaded) gl.buffers.bind(.element_array_buffer, m.ebo);
                    if (loaded) gl.buffers.bufferData(.element_array_buffer, bytes.len, bytes.ptr, i_usage);
                    m.index_count = @constCast(self)._pending_index_count;
                    if (@constCast(self)._pending_index_gl_type) |t| m.index_gl_type = t;
                }
                if (@constCast(self)._pending_divisors) |divs| for (divs) |d| if (loaded) gl.vertex_attributes.divisor(d.index, d.divisor);
                @constCast(self).* = Editor.init(@constCast(self)._mesh);
            }

            /// Uploads pending SOA data: one dedicated VBO per vertex field, then
            /// configures attribute pointers to read from those placed buffers.
            /// Parameters: none (uses `_mesh`, `_pending_soa_fields`, `_pending_soa_count`).
            ///
            /// Returns: `void`.
            fn applySOA(self: *const Editor) void {
                const m = @constCast(self)._mesh.impl();
                const loaded = gl.loader.loaded();
                const v_usage = @constCast(self)._pending_vertex_usage orelse m.vertex_usage;
                const count = @constCast(self)._pending_soa_count;
                inline for (0..field_count) |fi| {
                    if (@constCast(self)._pending_soa_fields[fi]) |bytes| {
                        if (bytes.len != count * vertex_field_sizes[fi]) @panic("SOA field byte size mismatch");
                    }
                }
                m.vertex_count = count;
                m.using_soa = true;

                if (loaded) {
                    // Create/upload a VBO per populated field.
                    inline for (0..field_count) |fi| {
                        const bytes = @constCast(self)._pending_soa_fields[fi];
                        if (bytes != null) {
                            if (m.field_vbos[fi] == 0) {
                                var id: u32 = 0;
                                gl.buffers.gen(1, @ptrCast(&id));
                                m.field_vbos[fi] = id;
                            }
                            gl.buffers.bind(.array_buffer, m.field_vbos[fi]);
                            gl.buffers.bufferData(.array_buffer, bytes.?.len, bytes.?.ptr, v_usage);
                        }
                    }
                }

                configureAttributesSOA(self);
            }

            /// Configures attribute pointers for the split (SOA) layout: each attribute
            /// reads from its own VBO with a tight stride and no per-attribute offset.
            /// Parameters: `self` (uses `_pending_soa_fields` and mesh `field_vbos`).
            ///
            /// Returns: `void`.
            fn configureAttributesSOA(self: *const Editor) void {
                const loaded = gl.loader.loaded();
                inline for (layout, 0..) |attr, li| {
                    const slot = field_slots[li];
                    const field_bytes = @constCast(self)._pending_soa_fields[slot.field_index];
                    if (field_bytes != null) {
                        if (loaded) gl.buffers.bind(.array_buffer, @constCast(self)._mesh.impl().field_vbos[slot.field_index]);
                        const stride = fieldElemStride(slot.field_type);
                        const ptr: ?*const anyopaque = @ptrFromInt(slot.column_offset);
                        if (attr.is_integer) {
                            if (loaded) gl.vertex_attributes.iPointer(attr.index, attr.size, attr.gl_type, stride, ptr);
                        } else if (loaded) {
                            gl.vertex_attributes.pointer(attr.index, attr.size, attr.gl_type, attr.normalized, stride, ptr);
                        }
                        if (loaded) gl.vertex_attributes.enable(attr.index);
                        if (attr.divisor != 0) if (loaded) gl.vertex_attributes.divisor(attr.index, attr.divisor);
                    }
                }
            }

            /// Configures vertex attribute pointers from the compile-time layout
            /// (interleaved AOS layout, single VBO).
            /// Parameters: none (uses outer `layout` and current VAO binding).
            ///
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

test "mesh editor soa2 basic and extra fields" {
    const V = struct { pos: math.Vec(3, f32), uv: math.Vec(2, f32) };
    const M = Mesh(V);
    const gpa = std.testing.allocator;
    const mesh = try M.create(gpa);
    defer mesh.destroy(gpa);
    const pos = [_]math.Vec(3, f32){ math.Vec(3, f32).zero(), math.Vec(3, f32).init(.{ 1, 0, 0 }) };
    const uv = [_]math.Vec(2, f32){ math.Vec(2, f32).init(.{ 0, 0 }), math.Vec(2, f32).init(.{ 1, 1 }) };
    // source with extra field should be accepted, extra ignored
    const src = .{ .pos = pos[0..], .uv = uv[0..], .extra = @as(i32, 5) };
    mesh.edit().setVerticesSOA2(src).apply();
    try std.testing.expect(mesh.getVertexCount() == 2);
    // verify SOA type exists and matches expected
    _ = M.SOA;
    try std.testing.expect(@hasField(M.SOA, "pos"));
    try std.testing.expect(@hasField(M.SOA, "uv"));
}

test "mesh editor soa2 delegates to soa" {
    const V = struct { aPos: math.Vec(3, f32), aNormal: math.Vec(3, f32) };
    const M = Mesh(V);
    const gpa = std.testing.allocator;
    const mesh = try M.create(gpa);
    defer mesh.destroy(gpa);
    const aPos = [_]math.Vec(3, f32){ math.Vec(3, f32).zero(), math.Vec(3, f32).init(.{ 1, 2, 3 }) };
    const aNormal = [_]math.Vec(3, f32){ math.Vec(3, f32).init(.{ 0, 0, 1 }), math.Vec(3, f32).init(.{ 0, 1, 0 }) };
    const src = .{ .aPos = aPos[0..], .aNormal = aNormal[0..] };
    mesh.edit().setVerticesSOA2(src).apply();
    try std.testing.expect(mesh.getVertexCount() == 2);
    // direct soa should give same result
    const mesh2 = try M.create(gpa);
    defer mesh2.destroy(gpa);
    mesh2.edit().setVerticesSOA(.{ .aPos = aPos[0..], .aNormal = aNormal[0..] }).apply();
    try std.testing.expect(mesh2.getVertexCount() == 2);
}

test "mesh editor soa2 exact match with shader names" {
    const V = struct { position: math.Vec(3, f32), normal: math.Vec(3, f32), uv: math.Vec(2, f32) };
    const M = Mesh(V);
    const gpa = std.testing.allocator;
    const mesh = try M.create(gpa);
    defer mesh.destroy(gpa);
    const pos = [_]math.Vec(3, f32){ math.Vec(3, f32).zero(), math.Vec(3, f32).init(.{ 1, 0, 0 }) };
    const nrm = [_]math.Vec(3, f32){ math.Vec(3, f32).init(.{ 0, 0, 1 }), math.Vec(3, f32).init(.{ 0, 1, 0 }) };
    const uv = [_]math.Vec(2, f32){ math.Vec(2, f32).init(.{ 0, 0 }), math.Vec(2, f32).init(.{ 1, 1 }) };
    const posSlice: []const math.Vec(3, f32) = &pos;
    const nrmSlice: []const math.Vec(3, f32) = &nrm;
    const uvSlice: []const math.Vec(2, f32) = &uv;
    const src = .{ .position = posSlice, .normal = nrmSlice, .uv = uvSlice, .indices = [_]u16{ 0, 1 } };
    mesh.edit().setVerticesSOA2(src).apply();
    try std.testing.expect(mesh.getVertexCount() == 2);
}

test "mesh setMeshSOA sets vertices and indices" {
    const V = struct { position: math.Vec(3, f32), uv: math.Vec(2, f32) };
    const M = Mesh(V);
    const gpa = std.testing.allocator;
    const mesh = try M.create(gpa);
    defer mesh.destroy(gpa);
    const pos = [_]math.Vec(3, f32){ math.Vec(3, f32).zero(), math.Vec(3, f32).init(.{ 1, 0, 0 }), math.Vec(3, f32).init(.{ 0, 1, 0 }) };
    const uv = [_]math.Vec(2, f32){ math.Vec(2, f32).init(.{ 0, 0 }), math.Vec(2, f32).init(.{ 1, 0 }), math.Vec(2, f32).init(.{ 0, 1 }) };
    const idx = [_]u16{ 0, 1, 2 };
    const meshData = .{ .position = pos[0..], .uv = uv[0..], .indices = idx[0..] };
    mesh.edit().setMeshSOA(meshData).apply();
    try std.testing.expect(mesh.getVertexCount() == 3);
    try std.testing.expect(mesh.getIndexCount() == 3);
    try std.testing.expect(mesh.getIndexType() == .unsigned_short);
}

test "mesh setMeshSOA without indices" {
    const V = struct { position: math.Vec(3, f32) };
    const M = Mesh(V);
    const gpa = std.testing.allocator;
    const mesh = try M.create(gpa);
    defer mesh.destroy(gpa);
    const pos = [_]math.Vec(3, f32){ math.Vec(3, f32).zero(), math.Vec(3, f32).init(.{ 1, 0, 0 }) };
    const meshData = .{ .position = pos[0..] };
    mesh.edit().setMeshSOA(meshData).apply();
    try std.testing.expect(mesh.getVertexCount() == 2);
    try std.testing.expect(mesh.getIndexCount() == 0);
}

test "mesh createWithSOA" {
    const V = struct { position: math.Vec(3, f32), uv: math.Vec(2, f32) };
    const M = Mesh(V);
    const gpa = std.testing.allocator;
    const pos = [_]math.Vec(3, f32){ math.Vec(3, f32).zero(), math.Vec(3, f32).init(.{ 1, 0, 0 }) };
    const uv = [_]math.Vec(2, f32){ math.Vec(2, f32).init(.{ 0, 0 }), math.Vec(2, f32).init(.{ 1, 0 }) };
    const idx = [_]u16{ 0, 1 };
    const meshData = .{ .position = pos[0..], .uv = uv[0..], .indices = idx[0..] };
    const mesh = try M.createWithSOA(gpa, meshData);
    defer mesh.destroy(gpa);
    try std.testing.expect(mesh.getVertexCount() == 2);
    try std.testing.expect(mesh.getIndexCount() == 2);
}
