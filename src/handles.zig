/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");
/// Compile-time type metadata import.
const gpu_meta = @import("gpu_meta.zig");
/// Shader runtime import (byte-level uniform upload).
const shader_runtime = @import("shader_runtime.zig");
/// Typed buffer import.
const Buffer = @import("buffer.zig").Buffer;
/// Typed mesh import.
const mesh_mod = @import("mesh.zig");
/// Typed mesh import.
const Mesh = mesh_mod.Mesh;
/// Vertex attribute info import.
const AttribInfo = mesh_mod.AttribInfo;
/// Typed shader program import.
const ShaderProgram = @import("shader_program.zig").ShaderProgram;
/// Typed material import.
const Material = @import("material.zig").Material;

/// One pending uniform field write for `AnyProgram.Editor` / `AnyMaterial.Editor`.
/// Slices are borrowed from the caller: `apply` before they go out of scope.
pub const UniformFieldItem = struct {
    /// Field index inside the stage `Uniform` struct.
    field_id: u32,
    /// `gpu_meta.typeId` of the expected field type.
    type_id: usize,
    /// Exactly `@sizeOf(field)` bytes in native field layout (any alignment).
    bytes: []const u8,
};

/// Validates one pending uniform field write against static descriptors.
/// Used by the program/material editors before committing anything.
/// Parameters:
/// - fields: stage uniform field descriptors.
/// - it: pending write to validate.
/// - check_uploadable: when true, resource kinds (sampler/block/nested)
///   are rejected for direct GL upload; cache writes pass false.
/// Returns: `UnknownFieldId` / `FieldTypeMismatch` / `UnsupportedUniformField` / `SizeMismatch`.
fn validateUniformItem(fields: []const gpu_meta.UniformFieldDesc, it: UniformFieldItem, check_uploadable: bool) gpu_meta.ResourceError!void {
    if (it.field_id >= fields.len) return error.UnknownFieldId;
    const d = fields[it.field_id];
    if (d.type_id != it.type_id) return error.FieldTypeMismatch;
    if (check_uploadable) {
        if (d.kind == .other) return error.UnsupportedUniformField;
        const want = gpu_meta.uniformKindSize(d.kind) orelse return error.UnsupportedUniformField;
        if (it.bytes.len != want) return error.SizeMismatch;
    } else {
        if (it.bytes.len != d.size) return error.SizeMismatch;
    }
}

/// Type-erased wrapper over `Buffer(T)` for any element type `T`.
///
/// Stores the full comptime type description (`data`) so different
/// instantiations can be compared and safely downcast with `cast`.
/// Fits `SlotPool(AnyBuffer)` and therefore the resource -> abstraction ->
/// ECS-component chain. All mutation goes through `Editor`; the typed
/// `setData`/`setSubDataTyped` conveniences stay on `Buffer(T)` only.
pub const AnyBuffer = struct {
    /// Wrapped `*Buffer(T)`, owned by whoever holds the pool reference.
    ptr: *anyopaque,
    /// Destroys the wrapped buffer and frees its storage.
    destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void,
    /// Thunks for state queries.
    is_valid_fn: *const fn (*const anyopaque) bool,
    get_id_fn: *const fn (*const anyopaque) u32,
    get_target_fn: *const fn (*const anyopaque) gl.buffers.BufferTarget,
    get_usage_fn: *const fn (*const anyopaque) gl.buffers.BufferUsage,
    get_size_fn: *const fn (*const anyopaque) usize,
    get_count_fn: *const fn (*const anyopaque) usize,
    is_mapped_fn: *const fn (*const anyopaque) bool,
    query_size_fn: *const fn (*const anyopaque) i32,
    query_usage_fn: *const fn (*const anyopaque) i32,
    query_mapped_fn: *const fn (*const anyopaque) bool,
    query_map_length_fn: *const fn (*const anyopaque) i32,
    query_map_offset_fn: *const fn (*const anyopaque) i32,
    query_access_fn: *const fn (*const anyopaque) i32,
    /// Thunks for binding.
    bind_fn: *const fn (*const anyopaque) void,
    bind_to_fn: *const fn (*const anyopaque, gl.buffers.BufferTarget) void,
    /// Thunks for synchronous mapped-memory operations (no deferred form).
    map_fn: *const fn (*anyopaque, usize, usize, gl.buffers.MapAccess) ?*anyopaque,
    flush_fn: *const fn (*anyopaque, usize, usize) void,
    unmap_fn: *const fn (*anyopaque) bool,
    /// Element type description (name/size/align).
    data: gpu_meta.TypeDesc,
    /// `@sizeOf` the element type.
    elem_size: usize,
    /// GL object name cached at wrap time.
    gl_id: u32,
    /// Flushes an `Editor` in one underlying edit/apply cycle. Captured at wrap.
    editor_apply_fn: *const fn (*const Editor) void,

    /// Wraps a typed buffer pointer. The record does not take ownership:
    /// destroy exactly once via `remove` + `destroy`.
    /// Parameters:
    /// - ptr: `*Buffer(T)` for any `T`.
    /// Returns: type-erased record.
    pub fn wrap(ptr: anytype) AnyBuffer {
        const B = std.meta.Child(@TypeOf(ptr));
        if (!@hasDecl(B, "DataType")) @compileError("AnyBuffer.wrap expects *Buffer(T), got " ++ @typeName(@TypeOf(ptr)));
        const P = @TypeOf(ptr);
        const S = struct {
            fn destroy(p: *anyopaque, alloc: std.mem.Allocator) void {
                const b: P = @ptrCast(@alignCast(p));
                b.destroy(alloc);
            }
            fn isValid(p: *const anyopaque) bool {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.isValid();
            }
            fn getId(p: *const anyopaque) u32 {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.getId();
            }
            fn getTarget(p: *const anyopaque) gl.buffers.BufferTarget {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.getTarget();
            }
            fn getUsage(p: *const anyopaque) gl.buffers.BufferUsage {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.getUsage();
            }
            fn getSize(p: *const anyopaque) usize {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.getSizeBytes();
            }
            fn getCount(p: *const anyopaque) usize {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.getCount();
            }
            fn isMapped(p: *const anyopaque) bool {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.getIsMapped();
            }
            fn querySize(p: *const anyopaque) i32 {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.querySize();
            }
            fn queryUsage(p: *const anyopaque) i32 {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.queryUsage();
            }
            fn queryMapped(p: *const anyopaque) bool {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.queryMapped();
            }
            fn queryMapLength(p: *const anyopaque) i32 {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.queryMapLength();
            }
            fn queryMapOffset(p: *const anyopaque) i32 {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.queryMapOffset();
            }
            fn queryAccess(p: *const anyopaque) i32 {
                const b: *const B = @ptrCast(@alignCast(p));
                return b.queryAccessFlags();
            }
            fn bind(p: *const anyopaque) void {
                const b: *const B = @ptrCast(@alignCast(p));
                b.bind();
            }
            fn bindTo(p: *const anyopaque, target: gl.buffers.BufferTarget) void {
                const b: *const B = @ptrCast(@alignCast(p));
                b.bindTo(target);
            }
            fn map(p: *anyopaque, offset: usize, len: usize, access: gl.buffers.MapAccess) ?*anyopaque {
                const b: P = @ptrCast(@alignCast(p));
                return b.edit().mapNow(offset, len, access);
            }
            fn flush(p: *anyopaque, offset: usize, len: usize) void {
                const b: P = @ptrCast(@alignCast(p));
                b.edit().setFlushMappedRange(offset, len).apply();
            }
            fn unmap(p: *anyopaque) bool {
                const b: P = @ptrCast(@alignCast(p));
                return b.edit().unmapNow();
            }
            fn applyEditor(e: *const Editor) void {
                const b: P = @ptrCast(@alignCast(e.rec.ptr));
                const ed = b.edit();
                if (e._pending_target) |t| _ = ed.setTarget(t);
                if (e._pending_usage) |u| _ = ed.setUsage(u);
                if (e._pending_data_bytes) |d| {
                    _ = ed.setDataBytes(d.bytes, d.usage);
                } else if (e._pending_reserve) |r| {
                    _ = ed.reserve(r.size_bytes, r.usage);
                }
                if (e._pending_sub_data) |s| _ = ed.setSubData(s.offset, s.bytes);
                if (e._pending_copy) |c| _ = ed.setCopySubData(c.read_target, c.read_offset, c.write_offset, c.size);
                if (e._pending_bind_base) |x| _ = ed.setBindBase(x.target, x.index);
                if (e._pending_bind_range) |x| _ = ed.setBindRange(x.target, x.index, x.offset, x.size);
                ed.apply();
            }
        };
        return .{
            .ptr = ptr,
            .destroy_fn = S.destroy,
            .is_valid_fn = S.isValid,
            .get_id_fn = S.getId,
            .get_target_fn = S.getTarget,
            .get_usage_fn = S.getUsage,
            .get_size_fn = S.getSize,
            .get_count_fn = S.getCount,
            .is_mapped_fn = S.isMapped,
            .query_size_fn = S.querySize,
            .query_usage_fn = S.queryUsage,
            .query_mapped_fn = S.queryMapped,
            .query_map_length_fn = S.queryMapLength,
            .query_map_offset_fn = S.queryMapOffset,
            .query_access_fn = S.queryAccess,
            .bind_fn = S.bind,
            .bind_to_fn = S.bindTo,
            .map_fn = S.map,
            .flush_fn = S.flush,
            .unmap_fn = S.unmap,
            .data = comptime gpu_meta.describe(B.DataType),
            .elem_size = @sizeOf(B.DataType),
            .gl_id = ptr.getId(),
            .editor_apply_fn = S.applyEditor,
        };
    }

    /// Batched, type-erased counterpart of `Buffer.Editor`.
    ///
    /// THE way to mutate a buffer through the abstraction: accumulate any
    /// combination of operations and flush them in ONE underlying edit/apply
    /// cycle (single bind + ordered GL calls). There are deliberately no
    /// single-op mutating shorthands on the record itself.
    /// Like the typed editor it borrows caller slices:
    /// call `apply` before they go out of scope. Mapping has no deferred form
    /// (the pointer is needed synchronously): use `mapRange`/`flushRange`/`unmap`
    /// on the record directly.
    pub const Editor = struct {
        /// Record copy: immune to pool reallocations, borrows the GL object.
        rec: AnyBuffer,
        _pending_target: ?gl.buffers.BufferTarget = null,
        _pending_usage: ?gl.buffers.BufferUsage = null,
        _pending_data_bytes: ?struct { bytes: []const u8, usage: gl.buffers.BufferUsage } = null,
        _pending_reserve: ?struct { size_bytes: usize, usage: gl.buffers.BufferUsage } = null,
        _pending_sub_data: ?struct { offset: usize, bytes: []const u8 } = null,
        _pending_copy: ?struct { read_target: gl.buffers.BufferTarget, read_offset: usize, write_offset: usize, size: usize } = null,
        _pending_bind_base: ?struct { target: gl.buffers.BufferTarget, index: u32 } = null,
        _pending_bind_range: ?struct { target: gl.buffers.BufferTarget, index: u32, offset: usize, size: usize } = null,

        /// Queues a target change. See `Buffer.Editor.setTarget`.
        pub fn setTarget(self: *const Editor, target: gl.buffers.BufferTarget) *const Editor {
            @constCast(self)._pending_target = target;
            return @constCast(self);
        }
        /// Queues a usage hint change. See `Buffer.Editor.setUsage`.
        pub fn setUsage(self: *const Editor, usage: gl.buffers.BufferUsage) *const Editor {
            @constCast(self)._pending_usage = usage;
            return @constCast(self);
        }
        /// Queues a `bufferData` byte upload. See `Buffer.Editor.setDataBytes`.
        pub fn setDataBytes(self: *const Editor, bytes: []const u8, usage: gl.buffers.BufferUsage) *const Editor {
            if (bytes.len % @constCast(self).rec.elem_size != 0) @panic("AnyBuffer.Editor.setDataBytes: byte size mismatch");
            @constCast(self)._pending_data_bytes = .{ .bytes = bytes, .usage = usage };
            return @constCast(self);
        }
        /// Queues a store reservation. See `Buffer.Editor.reserve`.
        pub fn reserve(self: *const Editor, size_bytes: usize, usage: gl.buffers.BufferUsage) *const Editor {
            @constCast(self)._pending_reserve = .{ .size_bytes = size_bytes, .usage = usage };
            return @constCast(self);
        }
        /// Queues a `bufferSubData` byte upload. See `Buffer.Editor.setSubData`.
        pub fn setSubData(self: *const Editor, offset: usize, bytes: []const u8) *const Editor {
            @constCast(self)._pending_sub_data = .{ .offset = offset, .bytes = bytes };
            return @constCast(self);
        }
        /// Queues a `glCopyBufferSubData` into this buffer. See `Buffer.Editor.setCopySubData`.
        pub fn setCopySubData(self: *const Editor, read_target: gl.buffers.BufferTarget, read_offset: usize, write_offset: usize, size: usize) *const Editor {
            @constCast(self)._pending_copy = .{ .read_target = read_target, .read_offset = read_offset, .write_offset = write_offset, .size = size };
            return @constCast(self);
        }
        /// Queues a `glBindBufferBase`. See `Buffer.Editor.setBindBase`.
        pub fn setBindBase(self: *const Editor, target: gl.buffers.BufferTarget, index: u32) *const Editor {
            @constCast(self)._pending_bind_base = .{ .target = target, .index = index };
            return @constCast(self);
        }
        /// Queues a `glBindBufferRange`. See `Buffer.Editor.setBindRange`.
        pub fn setBindRange(self: *const Editor, target: gl.buffers.BufferTarget, index: u32, offset: usize, size: usize) *const Editor {
            @constCast(self)._pending_bind_range = .{ .target = target, .index = index, .offset = offset, .size = size };
            return @constCast(self);
        }
        /// Flushes all pending operations in one underlying edit/apply cycle.
        /// Parameters:
        /// - self: editor holding pending operations.
        /// Returns: void.
        pub fn apply(self: *const Editor) void {
            self.rec.editor_apply_fn(self);
        }
    };

    /// Creates an `Editor` for batched buffer updates.
    /// Parameters:
    /// - self: buffer record to edit (copied; immune to pool reallocations).
    /// Returns: initialized `Editor` with no pending changes.
    pub fn edit(self: *const AnyBuffer) Editor {
        return .{ .rec = self.* };
    }

    /// Downcasts back to a typed buffer. Returns null on type mismatch.
    /// Parameters:
    /// - self: record to downcast.
    /// - T: expected element type.
    /// Returns: `*Buffer(T)` or null.
    pub fn cast(self: *AnyBuffer, comptime T: type) ?*Buffer(T) {
        if (self.elem_size != @sizeOf(T)) return null;
        if (!std.mem.eql(u8, self.data.name, @typeName(T))) return null;
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Destroys the wrapped buffer (the abstracted resource).
    pub fn destroy(self: *const AnyBuffer, alloc: std.mem.Allocator) void {
        self.destroy_fn(self.ptr, alloc);
    }
    /// See `Buffer.isValid`.
    pub fn isValid(self: *const AnyBuffer) bool {
        return self.is_valid_fn(self.ptr);
    }
    /// Returns the live GL object name.
    pub fn getId(self: *const AnyBuffer) u32 {
        return self.get_id_fn(self.ptr);
    }
    /// See `Buffer.getTarget`.
    pub fn getTarget(self: *const AnyBuffer) gl.buffers.BufferTarget {
        return self.get_target_fn(self.ptr);
    }
    /// See `Buffer.getUsage`.
    pub fn getUsage(self: *const AnyBuffer) gl.buffers.BufferUsage {
        return self.get_usage_fn(self.ptr);
    }
    /// See `Buffer.getSizeBytes`.
    pub fn getSizeBytes(self: *const AnyBuffer) usize {
        return self.get_size_fn(self.ptr);
    }
    /// See `Buffer.getCount`.
    pub fn getCount(self: *const AnyBuffer) usize {
        return self.get_count_fn(self.ptr);
    }
    /// See `Buffer.getIsMapped`.
    pub fn getIsMapped(self: *const AnyBuffer) bool {
        return self.is_mapped_fn(self.ptr);
    }
    /// See `Buffer.querySize`.
    pub fn querySize(self: *const AnyBuffer) i32 {
        return self.query_size_fn(self.ptr);
    }
    /// See `Buffer.queryUsage`.
    pub fn queryUsage(self: *const AnyBuffer) i32 {
        return self.query_usage_fn(self.ptr);
    }
    /// See `Buffer.queryMapped`.
    pub fn queryMapped(self: *const AnyBuffer) bool {
        return self.query_mapped_fn(self.ptr);
    }
    /// See `Buffer.queryMapLength`.
    pub fn queryMapLength(self: *const AnyBuffer) i32 {
        return self.query_map_length_fn(self.ptr);
    }
    /// See `Buffer.queryMapOffset`.
    pub fn queryMapOffset(self: *const AnyBuffer) i32 {
        return self.query_map_offset_fn(self.ptr);
    }
    /// See `Buffer.queryAccessFlags`.
    pub fn queryAccessFlags(self: *const AnyBuffer) i32 {
        return self.query_access_fn(self.ptr);
    }
    /// See `Buffer.bind`.
    pub fn bind(self: *const AnyBuffer) void {
        self.bind_fn(self.ptr);
    }
    /// See `Buffer.bindTo`.
    pub fn bindTo(self: *const AnyBuffer, target: gl.buffers.BufferTarget) void {
        self.bind_to_fn(self.ptr, target);
    }
    /// Alias for `bind`.
    pub fn use(self: *const AnyBuffer) void {
        self.bind();
    }
    /// Maps a range; see `Buffer.Editor.mapNow`. Synchronous by nature
    /// (the pointer is needed immediately): intentionally not part of `Editor`.
    pub fn mapRange(self: *AnyBuffer, offset: usize, len: usize, access: gl.buffers.MapAccess) ?*anyopaque {
        return self.map_fn(self.ptr, offset, len, access);
    }
    /// Flushes a mapped range. Synchronous single GL call by nature:
    /// intentionally not part of `Editor`.
    pub fn flushRange(self: *AnyBuffer, offset: usize, len: usize) void {
        self.flush_fn(self.ptr, offset, len);
    }
    /// Unmaps the buffer. Synchronous single GL call by nature:
    /// intentionally not part of `Editor`. See `Buffer.Editor.unmapNow`.
    pub fn unmap(self: *AnyBuffer) bool {
        return self.unmap_fn(self.ptr);
    }
};

/// One SOA vertex field payload for `AnyMesh.Editor.setSoa`.
pub const SoaFieldData = struct {
    /// Top-level vertex field index (declaration order).
    field_id: u32,
    /// Tightly packed field bytes (`count * @sizeOf(field)`).
    bytes: []const u8,
};

/// Index payload for `AnyMesh.Editor` batches.
pub const MeshIndexData = struct {
    /// Raw index bytes.
    bytes: []const u8,
    /// Element type (`.unsigned_byte`/`.unsigned_short`/`.unsigned_int`).
    gl_type: gl.enums.DataType,
    /// Index count.
    count: usize,
};

/// Type-erased wrapper over `Mesh(Vertex)` for any vertex struct `Vertex`.
///
/// Keeps the full vertex description (`vertex`), the compile-time attribute
/// `layout` slice and per-field metadata, so meshes can be compared against
/// shader programs (`meshAcceptsProgram`) without knowing `Vertex`.
pub const AnyMesh = struct {
    /// Wrapped `*Mesh(Vertex)`, owned by whoever holds the pool reference.
    ptr: *anyopaque,
    /// Destroys the wrapped mesh and frees its storage.
    destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void,
    is_valid_fn: *const fn (*const anyopaque) bool,
    get_vao_fn: *const fn (*const anyopaque) u32,
    get_vbo_fn: *const fn (*const anyopaque) u32,
    get_ebo_fn: *const fn (*const anyopaque) u32,
    get_vertex_count_fn: *const fn (*const anyopaque) usize,
    get_index_count_fn: *const fn (*const anyopaque) usize,
    get_index_type_fn: *const fn (*const anyopaque) gl.enums.DataType,
    get_primitive_fn: *const fn (*const anyopaque) gl.drawing.PrimitiveType,
    bind_fn: *const fn (*const anyopaque) void,
    draw_fn: *const fn (*const anyopaque) void,
    draw_instanced_fn: *const fn (*const anyopaque, i32) void,
    /// Flushes an `Editor` in one underlying edit/apply cycle. Captured at wrap.
    editor_apply_fn: *const fn (*const Editor) void,
    /// Vertex struct description (fields/members for compatibility checks).
    vertex: gpu_meta.TypeDesc,
    /// Compile-time attribute layout. Points at static memory.
    layout: []const AttribInfo,
    /// `@sizeOf(Vertex)`.
    stride: usize,

    /// Per-attribute divisor pair for `setAttributeDivisors`.
    pub const AttrDivisor = struct {
        index: u32,
        divisor: u32,
    };

    /// Wraps a typed mesh pointer. The record does not take ownership.
    /// Parameters:
    /// - ptr: `*Mesh(Vertex)` for any `Vertex`.
    /// Returns: type-erased record.
    pub fn wrap(ptr: anytype) AnyMesh {
        const M = std.meta.Child(@TypeOf(ptr));
        if (!@hasDecl(M, "VertexType") or !@hasDecl(M, "Layout")) @compileError("AnyMesh.wrap expects *Mesh(Vertex), got " ++ @typeName(@TypeOf(ptr)));
        const P = @TypeOf(ptr);
        const S = struct {
            fn destroy(p: *anyopaque, alloc: std.mem.Allocator) void {
                const m: P = @ptrCast(@alignCast(p));
                m.destroy(alloc);
            }
            fn isValid(p: *const anyopaque) bool {
                const m: *const M = @ptrCast(@alignCast(p));
                return m.isValid();
            }
            fn getVao(p: *const anyopaque) u32 {
                const m: *const M = @ptrCast(@alignCast(p));
                return m.getVao();
            }
            fn getVbo(p: *const anyopaque) u32 {
                const m: *const M = @ptrCast(@alignCast(p));
                return m.getVbo();
            }
            fn getEbo(p: *const anyopaque) u32 {
                const m: *const M = @ptrCast(@alignCast(p));
                return m.getEbo();
            }
            fn getVertexCount(p: *const anyopaque) usize {
                const m: *const M = @ptrCast(@alignCast(p));
                return m.getVertexCount();
            }
            fn getIndexCount(p: *const anyopaque) usize {
                const m: *const M = @ptrCast(@alignCast(p));
                return m.getIndexCount();
            }
            fn getIndexType(p: *const anyopaque) gl.enums.DataType {
                const m: *const M = @ptrCast(@alignCast(p));
                return m.getIndexType();
            }
            fn getPrimitive(p: *const anyopaque) gl.drawing.PrimitiveType {
                const m: *const M = @ptrCast(@alignCast(p));
                return m.getPrimitive();
            }
            fn bind(p: *const anyopaque) void {
                const m: *const M = @ptrCast(@alignCast(p));
                m.bind();
            }
            fn draw(p: *const anyopaque) void {
                const m: *const M = @ptrCast(@alignCast(p));
                m.draw();
            }
            fn drawInstanced(p: *const anyopaque, n: i32) void {
                const m: *const M = @ptrCast(@alignCast(p));
                m.drawInstanced(n);
            }
            fn applyEditor(e: *const Editor) void {
                const m: P = @ptrCast(@alignCast(e.rec.ptr));
                if (e._pending_vertex_buffer != null and (e._pending_vertices_bytes != null or e._pending_soa != null))
                    @panic("AnyMesh.Editor: vertex buffer override excludes uploads");
                if (e._pending_index_buffer != null and e._pending_indices_bytes != null)
                    @panic("AnyMesh.Editor: index buffer override excludes uploads");
                var ed = m.edit();
                if (e._pending_primitive) |x| _ = ed.setPrimitive(x);
                if (e._pending_vertex_usage) |x| _ = ed.setVertexUsage(x);
                if (e._pending_index_usage) |x| _ = ed.setIndexUsage(x);
                if (e._pending_soa) |s| {
                    for (s.fields) |f| _ = ed.setSoaField(f.field_id, f.bytes);
                    _ = ed.setSoaCount(s.count);
                } else if (e._pending_vertex_buffer) |id| {
                    _ = ed.setVertexBuffer(id);
                } else if (e._pending_vertices_bytes) |vb| {
                    _ = ed.setVerticesBytes(vb.bytes, vb.count);
                }
                if (e._pending_index_buffer) |id| {
                    _ = ed.setIndexBuffer(id);
                } else if (e._pending_indices_bytes) |idx| {
                    _ = ed.setIndicesBytes(idx.bytes, idx.gl_type, idx.count);
                }
                if (e._pending_divisors) |ds| {
                    for (ds) |d| _ = ed.setDivisor(d.index, d.divisor);
                }
                ed.apply();
            }
        };
        return .{
            .ptr = ptr,
            .destroy_fn = S.destroy,
            .is_valid_fn = S.isValid,
            .get_vao_fn = S.getVao,
            .get_vbo_fn = S.getVbo,
            .get_ebo_fn = S.getEbo,
            .get_vertex_count_fn = S.getVertexCount,
            .get_index_count_fn = S.getIndexCount,
            .get_index_type_fn = S.getIndexType,
            .get_primitive_fn = S.getPrimitive,
            .bind_fn = S.bind,
            .draw_fn = S.draw,
            .draw_instanced_fn = S.drawInstanced,
            .editor_apply_fn = S.applyEditor,
            .vertex = comptime gpu_meta.describe(M.VertexType),
            .layout = M.Layout,
            .stride = @sizeOf(M.VertexType),
        };
    }

    /// Batched, type-erased counterpart of `Mesh.Editor`.
    ///
    /// THE way to mutate a mesh through the abstraction: accumulate uploads,
    /// overrides, hints and divisors, then flush them in ONE underlying
    /// edit/apply cycle (single VAO bind). There are deliberately no
    /// single-op mutating shorthands on the record itself.
    /// Like the typed editor it borrows caller slices:
    /// call `apply` before they go out of scope. An external buffer override
    /// cannot be combined with uploads in one cycle (panics on `apply`).
    /// Single `setDivisor` has no abstract form (a documented no-op upstream):
    /// use `setAttributeDivisors`.
    pub const Editor = struct {
        /// Record copy: immune to pool reallocations, borrows the GL object.
        rec: AnyMesh,
        _pending_vertices_bytes: ?struct { bytes: []const u8, count: usize } = null,
        _pending_soa: ?struct { fields: []const SoaFieldData, count: usize } = null,
        _pending_indices_bytes: ?MeshIndexData = null,
        _pending_vertex_buffer: ?u32 = null,
        _pending_index_buffer: ?u32 = null,
        _pending_vertex_usage: ?gl.buffers.BufferUsage = null,
        _pending_index_usage: ?gl.buffers.BufferUsage = null,
        _pending_primitive: ?gl.drawing.PrimitiveType = null,
        _pending_divisors: ?[]const AttrDivisor = null,

        /// Queues interleaved vertex bytes. See `Mesh.Editor.setVerticesBytes`.
        pub fn setVerticesBytes(self: *const Editor, bytes: []const u8, count: usize) *const Editor {
            @constCast(self)._pending_vertices_bytes = .{ .bytes = bytes, .count = count };
            @constCast(self)._pending_soa = null;
            return @constCast(self);
        }
        /// Queues a split-layout upload. Borrowed slice; validated on `apply`.
        /// See `Mesh.Editor.setSoaField`/`setSoaCount` (batched form).
        pub fn setSoa(self: *const Editor, fields: []const SoaFieldData, count: usize) *const Editor {
            @constCast(self)._pending_soa = .{ .fields = fields, .count = count };
            @constCast(self)._pending_vertices_bytes = null;
            return @constCast(self);
        }
        /// Queues index bytes. See `Mesh.Editor.setIndicesBytes`.
        pub fn setIndicesBytes(self: *const Editor, bytes: []const u8, gl_type: gl.enums.DataType, count: usize) *const Editor {
            @constCast(self)._pending_indices_bytes = .{ .bytes = bytes, .gl_type = gl_type, .count = count };
            return @constCast(self);
        }
        /// Overrides the vertex buffer handle. See `Mesh.Editor.setVertexBuffer`.
        pub fn setVertexBuffer(self: *const Editor, buffer_id: u32) *const Editor {
            @constCast(self)._pending_vertex_buffer = buffer_id;
            return @constCast(self);
        }
        /// Overrides the index buffer handle. See `Mesh.Editor.setIndexBuffer`.
        pub fn setIndexBuffer(self: *const Editor, buffer_id: u32) *const Editor {
            @constCast(self)._pending_index_buffer = buffer_id;
            return @constCast(self);
        }
        /// See `Mesh.Editor.setVertexUsage`.
        pub fn setVertexUsage(self: *const Editor, usage: gl.buffers.BufferUsage) *const Editor {
            @constCast(self)._pending_vertex_usage = usage;
            return @constCast(self);
        }
        /// See `Mesh.Editor.setIndexUsage`.
        pub fn setIndexUsage(self: *const Editor, usage: gl.buffers.BufferUsage) *const Editor {
            @constCast(self)._pending_index_usage = usage;
            return @constCast(self);
        }
        /// See `Mesh.Editor.setPrimitive`.
        pub fn setPrimitive(self: *const Editor, primitive: gl.drawing.PrimitiveType) *const Editor {
            @constCast(self)._pending_primitive = primitive;
            return @constCast(self);
        }
        /// See `Mesh.Editor.setAttributeDivisors`.
        pub fn setAttributeDivisors(self: *const Editor, divisors: []const AttrDivisor) *const Editor {
            @constCast(self)._pending_divisors = divisors;
            return @constCast(self);
        }
        /// Flushes all pending operations in one underlying edit/apply cycle.
        /// Parameters:
        /// - self: editor holding pending operations.
        /// Returns: void.
        pub fn apply(self: *const Editor) void {
            self.rec.editor_apply_fn(self);
        }
    };

    /// Creates an `Editor` for batched mesh updates.
    /// Parameters:
    /// - self: mesh record to edit (copied; immune to pool reallocations).
    /// Returns: initialized `Editor` with no pending changes.
    pub fn edit(self: *const AnyMesh) Editor {
        return .{ .rec = self.* };
    }

    /// Downcasts back to a typed mesh. Returns null on type mismatch.
    /// Parameters:
    /// - self: record to downcast.
    /// - V: expected vertex type.
    /// Returns: `*Mesh(V)` or null.
    pub fn cast(self: *AnyMesh, comptime V: type) ?*Mesh(V) {
        if (self.stride != @sizeOf(V)) return null;
        if (!std.mem.eql(u8, self.vertex.name, @typeName(V))) return null;
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Destroys the wrapped mesh (the abstracted resource).
    pub fn destroy(self: *const AnyMesh, alloc: std.mem.Allocator) void {
        self.destroy_fn(self.ptr, alloc);
    }
    /// See `Mesh.isValid`.
    pub fn isValid(self: *const AnyMesh) bool {
        return self.is_valid_fn(self.ptr);
    }
    /// See `Mesh.getVao`.
    pub fn getVao(self: *const AnyMesh) u32 {
        return self.get_vao_fn(self.ptr);
    }
    /// See `Mesh.getVbo`.
    pub fn getVbo(self: *const AnyMesh) u32 {
        return self.get_vbo_fn(self.ptr);
    }
    /// See `Mesh.getEbo`.
    pub fn getEbo(self: *const AnyMesh) u32 {
        return self.get_ebo_fn(self.ptr);
    }
    /// See `Mesh.getVertexCount`.
    pub fn getVertexCount(self: *const AnyMesh) usize {
        return self.get_vertex_count_fn(self.ptr);
    }
    /// See `Mesh.getIndexCount`.
    pub fn getIndexCount(self: *const AnyMesh) usize {
        return self.get_index_count_fn(self.ptr);
    }
    /// See `Mesh.getIndexType` (runtime value, set by the last indices upload).
    pub fn getIndexType(self: *const AnyMesh) gl.enums.DataType {
        return self.get_index_type_fn(self.ptr);
    }
    /// See `Mesh.getPrimitive`.
    pub fn getPrimitive(self: *const AnyMesh) gl.drawing.PrimitiveType {
        return self.get_primitive_fn(self.ptr);
    }
    /// Number of top-level vertex fields.
    pub fn getFieldCount(self: *const AnyMesh) usize {
        return self.vertex.fields.len;
    }
    /// See `Mesh.bind`.
    pub fn bind(self: *const AnyMesh) void {
        self.bind_fn(self.ptr);
    }
    /// Alias for `bind`.
    pub fn use(self: *const AnyMesh) void {
        self.bind();
    }
    /// See `Mesh.draw`.
    pub fn draw(self: *const AnyMesh) void {
        self.draw_fn(self.ptr);
    }
    /// See `Mesh.drawInstanced`.
    pub fn drawInstanced(self: *const AnyMesh, instance_count: i32) void {
        self.draw_instanced_fn(self.ptr, instance_count);
    }
};

/// Unbinds any VAO (binds 0). Mesh-level operation without a mesh instance.
pub fn unbindMesh() void {
    gl.vertex_arrays.bind(0);
}

/// Uniform stage selector for `AnyProgram` field access.
pub const UniformStage = enum {
    vert,
    frag,
};

/// Type-erased wrapper over `ShaderProgram(Vert, Frag)`.
///
/// Keeps descriptor names, both `Uniform` descriptions and the vertex shader
/// input list (`Vert.Vertex` fields when the descriptor provides them), so a
/// program can be matched against meshes without knowing the descriptors.
pub const AnyProgram = struct {
    /// Wrapped `*ShaderProgram(Vert, Frag)`, owned by the pool reference holder.
    ptr: *anyopaque,
    /// Destroys the wrapped program and frees its storage.
    destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void,
    /// Binds the program for rendering.
    use_fn: *const fn (*const anyopaque) void,
    /// Returns the live GL program id.
    get_id_fn: *const fn (*const anyopaque) u32,
    /// Live uniform location query by stage + field id.
    uniform_location_fn: *const fn (*const anyopaque, UniformStage, u32) gpu_meta.ResourceError!i32,
    /// Direct plain-data field upload into the bound program (vertex stage).
    upload_vert_fn: *const fn (*const anyopaque, u32, usize, []const u8) gpu_meta.ResourceError!void,
    /// Direct plain-data field upload (fragment stage). Null when no fragment stage.
    upload_frag_fn: ?*const fn (*const anyopaque, u32, usize, []const u8) gpu_meta.ResourceError!void,
    /// `@typeName` of the vertex descriptor.
    vert_name: []const u8,
    /// `@typeName` of the fragment descriptor, if any.
    frag_name: ?[]const u8,
    /// Whether a fragment stage is configured.
    has_frag: bool,
    /// Vertex `Uniform` description.
    vert_uniform: gpu_meta.TypeDesc,
    /// Fragment `Uniform` description (empty when no fragment stage).
    frag_uniform: gpu_meta.TypeDesc,
    /// Vertex shader input fields (`Vert.Vertex`), empty when unavailable.
    vertex_inputs: []const gpu_meta.FieldDesc,
    /// Vertex uniform field descriptors (`field_id` == index).
    vert_fields: []const gpu_meta.UniformFieldDesc,
    /// Fragment uniform field descriptors (`field_id` == index).
    frag_fields: []const gpu_meta.UniformFieldDesc,
    /// GL program id cached at wrap time.
    gl_id: u32,

    /// Wraps a typed program pointer. The record does not take ownership.
    /// Parameters:
    /// - ptr: `*ShaderProgram(Vert, Frag)` for any descriptors.
    /// Returns: type-erased record.
    pub fn wrap(ptr: anytype) AnyProgram {
        const P = std.meta.Child(@TypeOf(ptr));
        if (!@hasDecl(P, "HasFrag") or !@hasDecl(P, "Vert") or !@hasDecl(P, "FragT")) @compileError("AnyProgram.wrap expects *ShaderProgram(Vert, Frag), got " ++ @typeName(@TypeOf(ptr)));
        const Vert = P.Vert;
        const has_frag = P.HasFrag;
        const FragU = if (has_frag) P.FragT.Uniform else struct {};
        const VertU = Vert.Uniform;
        const vert_fields = comptime gpu_meta.uniformFields(VertU);
        const frag_fields = comptime if (has_frag) gpu_meta.uniformFields(FragU) else @as([]const gpu_meta.UniformFieldDesc, &.{});
        const S = struct {
            fn destroy(p: *anyopaque, alloc: std.mem.Allocator) void {
                const s: @TypeOf(ptr) = @ptrCast(@alignCast(p));
                s.destroy(alloc);
            }
            fn use(p: *const anyopaque) void {
                const s: @TypeOf(ptr) = @ptrCast(@alignCast(@constCast(p)));
                s.use();
            }
            fn getId(p: *const anyopaque) u32 {
                const s: @TypeOf(ptr) = @ptrCast(@alignCast(@constCast(p)));
                return s.getId();
            }
            fn locateUniform(p: *const anyopaque, stage: UniformStage, field_id: u32) gpu_meta.ResourceError!i32 {
                const s: @TypeOf(ptr) = @ptrCast(@alignCast(@constCast(p)));
                const fields = switch (stage) {
                    .vert => vert_fields,
                    .frag => if (has_frag) frag_fields else return error.UnknownFieldId,
                };
                if (field_id >= fields.len) return error.UnknownFieldId;
                // Field names are static strings without a terminator: copy to a
                // bounded stack buffer instead of allocating.
                const uname = fields[field_id].name;
                var buf: [256]u8 = undefined;
                if (uname.len >= buf.len) return error.UnknownFieldId;
                @memcpy(buf[0..uname.len], uname);
                buf[uname.len] = 0;
                return gl.uniforms.location(s.getId(), buf[0..uname.len :0]);
            }
            fn uploadVert(p: *const anyopaque, field_id: u32, want_type: usize, bytes: []const u8) gpu_meta.ResourceError!void {
                if (field_id >= vert_fields.len) return error.UnknownFieldId;
                const desc = vert_fields[field_id];
                if (desc.type_id != want_type) return error.FieldTypeMismatch;
                if (desc.kind == .other) return error.UnsupportedUniformField;
                const loc = try locateUniform(p, .vert, field_id);
                if (loc == -1) return;
                try shader_runtime.uploadUniformByKind(loc, desc.kind, bytes);
            }
            fn uploadFrag(p: *const anyopaque, field_id: u32, want_type: usize, bytes: []const u8) gpu_meta.ResourceError!void {
                if (!has_frag) return error.UnknownFieldId;
                if (field_id >= frag_fields.len) return error.UnknownFieldId;
                const desc = frag_fields[field_id];
                if (desc.type_id != want_type) return error.FieldTypeMismatch;
                if (desc.kind == .other) return error.UnsupportedUniformField;
                const loc = try locateUniform(p, .frag, field_id);
                if (loc == -1) return;
                try shader_runtime.uploadUniformByKind(loc, desc.kind, bytes);
            }
        };
        const inputs = comptime blk: {
            if (!@hasDecl(Vert, "Vertex")) break :blk @as([]const gpu_meta.FieldDesc, &.{});
            const VX = Vert.Vertex;
            if (@typeInfo(VX) != .@"struct") break :blk @as([]const gpu_meta.FieldDesc, &.{});
            break :blk gpu_meta.describe(VX).fields;
        };
        return .{
            .ptr = ptr,
            .destroy_fn = S.destroy,
            .use_fn = S.use,
            .get_id_fn = S.getId,
            .uniform_location_fn = S.locateUniform,
            .upload_vert_fn = S.uploadVert,
            .upload_frag_fn = if (has_frag) S.uploadFrag else null,
            .vert_name = @typeName(Vert),
            .frag_name = if (P.Frag) |FT| @typeName(FT) else null,
            .has_frag = has_frag,
            .vert_uniform = comptime gpu_meta.describe(VertU),
            .frag_uniform = comptime gpu_meta.describe(FragU),
            .vertex_inputs = inputs,
            .vert_fields = vert_fields,
            .frag_fields = frag_fields,
            .gl_id = ptr.getId(),
        };
    }

    /// Downcasts back to a typed program. Returns null on descriptor mismatch.
    /// Parameters:
    /// - self: record to downcast.
    /// - V: expected vertex descriptor type.
    /// - F: expected fragment descriptor type (`null` for vertex-only programs).
    /// Returns: `*ShaderProgram(V, F)` or null.
    pub fn cast(self: *AnyProgram, comptime V: type, comptime F: ?type) ?*ShaderProgram(V, F) {
        if (!std.mem.eql(u8, self.vert_name, @typeName(V))) return null;
        if (F) |FT| {
            if (!self.has_frag) return null;
            const fname = self.frag_name orelse return null;
            if (!std.mem.eql(u8, fname, @typeName(FT))) return null;
        } else if (self.has_frag) return null;
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Destroys the wrapped program (the abstracted resource).
    pub fn destroy(self: *const AnyProgram, alloc: std.mem.Allocator) void {
        self.destroy_fn(self.ptr, alloc);
    }
    /// Binds the program for rendering. See `ShaderProgram.use`.
    pub fn use(self: *const AnyProgram) void {
        self.use_fn(self.ptr);
    }
    /// Returns the live GL program id.
    pub fn getId(self: *const AnyProgram) u32 {
        return self.get_id_fn(self.ptr);
    }
    /// Queries a live uniform location by stage + field id.
    /// The program must be linked; the caller should cache the result.
    pub fn uniformLocation(self: *const AnyProgram, stage: UniformStage, field_id: u32) gpu_meta.ResourceError!i32 {
        return self.uniform_location_fn(self.ptr, stage, field_id);
    }
    /// Resolves a vertex uniform field id by name with a type check.
    pub fn getVertUniformFieldId(self: *const AnyProgram, name: []const u8, want_type_id: usize) gpu_meta.ResourceError!u32 {
        return gpu_meta.uniformFieldIdByName(self.vert_fields, name, want_type_id);
    }
    /// Resolves a fragment uniform field id by name with a type check.
    pub fn getFragUniformFieldId(self: *const AnyProgram, name: []const u8, want_type_id: usize) gpu_meta.ResourceError!u32 {
        if (!self.has_frag) return error.UnknownFieldId;
        return gpu_meta.uniformFieldIdByName(self.frag_fields, name, want_type_id);
    }

    /// Batched uniform uploader mirroring the generated `Editor` pattern.
    ///
    /// THE way to write uniforms through the abstraction: queue any number of
    /// field writes and flush them with one `use()` (bind) inside `apply`.
    /// There are deliberately no single-field upload shorthands: each of them
    /// would hit GL separately.
    pub const Editor = struct {
        /// Record copy: immune to pool reallocations, borrows the GL object.
        rec: AnyProgram,
        /// Vertex uniform field descriptors for validation.
        vert_fields: []const gpu_meta.UniformFieldDesc,
        /// Fragment uniform field descriptors for validation.
        frag_fields: []const gpu_meta.UniformFieldDesc,
        /// Borrowed vertex field writes.
        _pending_vert: []const UniformFieldItem = &.{},
        /// Borrowed fragment field writes.
        _pending_frag: []const UniformFieldItem = &.{},

        /// Queues vertex uniform field writes for one `apply` batch.
        /// Parameters:
        /// - self: editor instance.
        /// - items: borrowed field writes applied in order.
        /// Returns: `*const Editor` for chaining.
        pub fn setVertUniformFields(self: *const Editor, items: []const UniformFieldItem) *const Editor {
            @constCast(self)._pending_vert = items;
            return @constCast(self);
        }
        /// Queues fragment uniform field writes for one `apply` batch.
        /// Parameters:
        /// - self: editor instance.
        /// - items: borrowed field writes applied in order.
        /// Returns: `*const Editor` for chaining.
        pub fn setFragUniformFields(self: *const Editor, items: []const UniformFieldItem) *const Editor {
            @constCast(self)._pending_frag = items;
            return @constCast(self);
        }
        /// Validates the whole batch, binds the program once, uploads all.
        /// Parameters:
        /// - self: editor holding pending writes.
        /// Returns: validation error before any GL call, if the batch is bad.
        pub fn apply(self: *const Editor) gpu_meta.ResourceError!void {
            for (self._pending_vert) |it| try validateUniformItem(self.vert_fields, it, true);
            for (self._pending_frag) |it| {
                if (!self.rec.has_frag) return error.UnknownFieldId;
                try validateUniformItem(self.frag_fields, it, true);
            }
            self.rec.use_fn(self.rec.ptr);
            for (self._pending_vert) |it| try self.rec.upload_vert_fn(self.rec.ptr, it.field_id, it.type_id, it.bytes);
            if (self.rec.upload_frag_fn) |f| {
                for (self._pending_frag) |it| try f(self.rec.ptr, it.field_id, it.type_id, it.bytes);
            } else if (self._pending_frag.len > 0) return error.UnknownFieldId;
        }
    };

    /// Creates an `Editor` for batched uniform uploads.
    /// Parameters:
    /// - self: program record to edit (copied; immune to pool reallocations).
    /// Returns: initialized `Editor` with no pending writes.
    pub fn edit(self: *const AnyProgram) Editor {
        return .{ .rec = self.*, .vert_fields = self.vert_fields, .frag_fields = self.frag_fields };
    }
};

/// Type-erased wrapper over `Material(Program)`.
///
/// Field writes go through the CPU-side uniform cache (any field kind,
/// including samplers: validated by type id + size, uploaded on `use`),
/// so the record exposes the complete uniform functionality.
pub const AnyMaterial = struct {
    /// Wrapped `*Material(Program)`, owned by the pool reference holder.
    ptr: *anyopaque,
    /// Destroys the wrapped material and frees its storage.
    destroy_fn: *const fn (*anyopaque, std.mem.Allocator) void,
    /// Uploads cached uniforms (typed path inside). See `Material.use`.
    use_fn: *const fn (*anyopaque) void,
    /// Returns the associated program GL id, or 0 when absent.
    get_program_id_fn: *const fn (*const anyopaque) u32,
    read_vert_fn: *const fn (*const anyopaque, []u8) gpu_meta.ResourceError!void,
    write_vert_fn: *const fn (*anyopaque, []const u8) gpu_meta.ResourceError!void,
    read_frag_fn: *const fn (*const anyopaque, []u8) gpu_meta.ResourceError!void,
    write_frag_fn: *const fn (*anyopaque, []const u8) gpu_meta.ResourceError!void,
    set_vert_field_fn: *const fn (*anyopaque, u32, usize, []const u8) gpu_meta.ResourceError!void,
    get_vert_field_fn: *const fn (*const anyopaque, u32, usize, []u8) gpu_meta.ResourceError!void,
    set_frag_field_fn: *const fn (*anyopaque, u32, usize, []const u8) gpu_meta.ResourceError!void,
    get_frag_field_fn: *const fn (*const anyopaque, u32, usize, []u8) gpu_meta.ResourceError!void,
    /// `@typeName` of the bound shader program (identity for comparisons).
    program_name: []const u8,
    /// `@typeName` of the vertex descriptor.
    program_vert_name: []const u8,
    /// `@typeName` of the fragment descriptor, if any.
    program_frag_name: ?[]const u8,
    /// Vertex shader input fields for mesh compatibility.
    vertex_inputs: []const gpu_meta.FieldDesc,
    /// Vertex `Uniform` description.
    vert_uniform: gpu_meta.TypeDesc,
    /// Fragment `Uniform` description.
    frag_uniform: gpu_meta.TypeDesc,
    /// Vertex uniform field descriptors (`field_id` == index).
    vert_fields: []const gpu_meta.UniformFieldDesc,
    /// Fragment uniform field descriptors (`field_id` == index).
    frag_fields: []const gpu_meta.UniformFieldDesc,

    /// Wraps a typed material pointer. The record does not take ownership.
    /// Parameters:
    /// - ptr: `*Material(Program)` for any program.
    /// Returns: type-erased record.
    pub fn wrap(ptr: anytype) AnyMaterial {
        const M = std.meta.Child(@TypeOf(ptr));
        if (!@hasDecl(M, "VertUniformT") or !@hasDecl(M, "FragUniformT") or !@hasDecl(M, "ShaderProgram")) @compileError("AnyMaterial.wrap expects *Material(Program), got " ++ @typeName(@TypeOf(ptr)));
        const P = @TypeOf(ptr);
        const Prog = M.ShaderProgram;
        const VertU = M.VertUniformT;
        const FragU = M.FragUniformT;
        const vert_fields = comptime gpu_meta.uniformFields(VertU);
        const frag_fields = comptime gpu_meta.uniformFields(FragU);
        const S = struct {
            fn destroy(p: *anyopaque, alloc: std.mem.Allocator) void {
                const m: P = @ptrCast(@alignCast(p));
                m.destroy(alloc);
            }
            fn use(p: *anyopaque) void {
                const m: P = @ptrCast(@alignCast(p));
                m.use();
            }
            fn getProgramId(p: *const anyopaque) u32 {
                const m: P = @ptrCast(@alignCast(@constCast(p)));
                const prog = m.getProgram() orelse return 0;
                return prog.getId();
            }
            fn readVert(p: *const anyopaque, out: []u8) gpu_meta.ResourceError!void {
                if (out.len != @sizeOf(VertU)) return error.SizeMismatch;
                const m: P = @ptrCast(@alignCast(@constCast(p)));
                const tmp = m.getVertUniform();
                @memcpy(out, std.mem.asBytes(&tmp));
            }
            fn writeVert(p: *anyopaque, bytes: []const u8) gpu_meta.ResourceError!void {
                if (bytes.len != @sizeOf(VertU)) return error.SizeMismatch;
                const m: P = @ptrCast(@alignCast(p));
                var tmp: VertU = undefined;
                @memcpy(std.mem.asBytes(&tmp), bytes);
                m.setVertUniform(tmp);
            }
            fn readFrag(p: *const anyopaque, out: []u8) gpu_meta.ResourceError!void {
                if (out.len != @sizeOf(FragU)) return error.SizeMismatch;
                const m: P = @ptrCast(@alignCast(@constCast(p)));
                const tmp = m.getFragUniform();
                @memcpy(out, std.mem.asBytes(&tmp));
            }
            fn writeFrag(p: *anyopaque, bytes: []const u8) gpu_meta.ResourceError!void {
                if (bytes.len != @sizeOf(FragU)) return error.SizeMismatch;
                const m: P = @ptrCast(@alignCast(p));
                var tmp: FragU = undefined;
                @memcpy(std.mem.asBytes(&tmp), bytes);
                m.setFragUniform(tmp);
            }
            fn setVertField(p: *anyopaque, field_id: u32, want_type: usize, bytes: []const u8) gpu_meta.ResourceError!void {
                if (field_id >= vert_fields.len) return error.UnknownFieldId;
                const m: P = @ptrCast(@alignCast(p));
                var tmp = m.getVertUniform();
                try gpu_meta.writeField(&tmp, vert_fields[field_id], want_type, bytes);
                m.setVertUniform(tmp);
            }
            fn getVertField(p: *const anyopaque, field_id: u32, want_type: usize, out: []u8) gpu_meta.ResourceError!void {
                if (field_id >= vert_fields.len) return error.UnknownFieldId;
                const m: P = @ptrCast(@alignCast(@constCast(p)));
                const tmp = m.getVertUniform();
                try gpu_meta.readField(&tmp, vert_fields[field_id], want_type, out);
            }
            fn setFragField(p: *anyopaque, field_id: u32, want_type: usize, bytes: []const u8) gpu_meta.ResourceError!void {
                if (field_id >= frag_fields.len) return error.UnknownFieldId;
                const m: P = @ptrCast(@alignCast(p));
                var tmp = m.getFragUniform();
                try gpu_meta.writeField(&tmp, frag_fields[field_id], want_type, bytes);
                m.setFragUniform(tmp);
            }
            fn getFragField(p: *const anyopaque, field_id: u32, want_type: usize, out: []u8) gpu_meta.ResourceError!void {
                if (field_id >= frag_fields.len) return error.UnknownFieldId;
                const m: P = @ptrCast(@alignCast(@constCast(p)));
                const tmp = m.getFragUniform();
                try gpu_meta.readField(&tmp, frag_fields[field_id], want_type, out);
            }
        };
        const inputs = comptime blk: {
            if (!@hasDecl(Prog.Vert, "Vertex")) break :blk @as([]const gpu_meta.FieldDesc, &.{});
            const VX = Prog.Vert.Vertex;
            if (@typeInfo(VX) != .@"struct") break :blk @as([]const gpu_meta.FieldDesc, &.{});
            break :blk gpu_meta.describe(VX).fields;
        };
        return .{
            .ptr = ptr,
            .destroy_fn = S.destroy,
            .use_fn = S.use,
            .get_program_id_fn = S.getProgramId,
            .read_vert_fn = S.readVert,
            .write_vert_fn = S.writeVert,
            .read_frag_fn = S.readFrag,
            .write_frag_fn = S.writeFrag,
            .set_vert_field_fn = S.setVertField,
            .get_vert_field_fn = S.getVertField,
            .set_frag_field_fn = S.setFragField,
            .get_frag_field_fn = S.getFragField,
            .program_name = @typeName(Prog),
            .program_vert_name = @typeName(Prog.Vert),
            .program_frag_name = if (Prog.HasFrag) @typeName(Prog.FragT) else null,
            .vertex_inputs = inputs,
            .vert_uniform = comptime gpu_meta.describe(VertU),
            .frag_uniform = comptime gpu_meta.describe(FragU),
            .vert_fields = vert_fields,
            .frag_fields = frag_fields,
        };
    }

    /// Downcasts back to a typed material. Returns null on program mismatch.
    /// Parameters:
    /// - self: record to downcast.
    /// - Prog: expected shader program type.
    /// Returns: `*Material(Prog)` or null.
    pub fn cast(self: *AnyMaterial, comptime Prog: type) ?*Material(Prog) {
        if (!std.mem.eql(u8, self.program_name, @typeName(Prog))) return null;
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Destroys the wrapped material (the abstracted resource).
    pub fn destroy(self: *const AnyMaterial, alloc: std.mem.Allocator) void {
        self.destroy_fn(self.ptr, alloc);
    }
    /// Binds the program and uploads cached uniforms. See `Material.use`.
    pub fn use(self: *AnyMaterial) void {
        self.use_fn(self.ptr);
    }
    /// Returns the associated program GL id, or 0 when absent.
    pub fn getProgramId(self: *const AnyMaterial) u32 {
        return self.get_program_id_fn(self.ptr);
    }
    /// Reads the whole cached vertex uniform into `out` (`out.len` must match).
    pub fn readVertCache(self: *const AnyMaterial, out: []u8) gpu_meta.ResourceError!void {
        try self.read_vert_fn(self.ptr, out);
    }
    /// Overwrites the whole cached vertex uniform (`bytes.len` must match).
    pub fn writeVertCache(self: *AnyMaterial, bytes: []const u8) gpu_meta.ResourceError!void {
        try self.write_vert_fn(self.ptr, bytes);
    }
    /// Reads the whole cached fragment uniform into `out` (`out.len` must match).
    pub fn readFragCache(self: *const AnyMaterial, out: []u8) gpu_meta.ResourceError!void {
        try self.read_frag_fn(self.ptr, out);
    }
    /// Overwrites the whole cached fragment uniform (`bytes.len` must match).
    pub fn writeFragCache(self: *AnyMaterial, bytes: []const u8) gpu_meta.ResourceError!void {
        try self.write_frag_fn(self.ptr, bytes);
    }
    /// Resolves a vertex uniform field id by name with a type check.
    pub fn getVertUniformFieldId(self: *const AnyMaterial, name: []const u8, want_type_id: usize) gpu_meta.ResourceError!u32 {
        return gpu_meta.uniformFieldIdByName(self.vert_fields, name, want_type_id);
    }
    /// Resolves a fragment uniform field id by name with a type check.
    pub fn getFragUniformFieldId(self: *const AnyMaterial, name: []const u8, want_type_id: usize) gpu_meta.ResourceError!u32 {
        return gpu_meta.uniformFieldIdByName(self.frag_fields, name, want_type_id);
    }
    /// Writes one cached vertex uniform field by id (any kind, uploaded on `use`).
    pub fn setVertUniformData(self: *AnyMaterial, field_id: u32, want_type_id: usize, bytes: []const u8) gpu_meta.ResourceError!void {
        try self.set_vert_field_fn(self.ptr, field_id, want_type_id, bytes);
    }
    /// Reads one cached vertex uniform field by id.
    pub fn getVertUniformData(self: *const AnyMaterial, field_id: u32, want_type_id: usize, out: []u8) gpu_meta.ResourceError!void {
        try self.get_vert_field_fn(self.ptr, field_id, want_type_id, out);
    }
    /// Writes one cached fragment uniform field by id (any kind, uploaded on `use`).
    pub fn setFragUniformData(self: *AnyMaterial, field_id: u32, want_type_id: usize, bytes: []const u8) gpu_meta.ResourceError!void {
        try self.set_frag_field_fn(self.ptr, field_id, want_type_id, bytes);
    }
    /// Reads one cached fragment uniform field by id.
    pub fn getFragUniformData(self: *const AnyMaterial, field_id: u32, want_type_id: usize, out: []u8) gpu_meta.ResourceError!void {
        try self.get_frag_field_fn(self.ptr, field_id, want_type_id, out);
    }

    /// Batched writer for the CPU-side uniform cache.
    ///
    /// Single-field immediate writes (`setVertUniformData` / `setFragUniformData`)
    /// each do a read-modify-write of the whole cached struct. The editor
    /// validates the WHOLE batch first, then commits everything, so a bad item
    /// leaves the cache untouched (atomic commit). Upload to GL still happens
    /// explicitly via `use` — the cache batching is the edit/apply equivalent.
    pub const Editor = struct {
        /// Record copy: immune to pool reallocations, borrows the material.
        rec: AnyMaterial,
        /// Vertex uniform field descriptors for validation.
        vert_fields: []const gpu_meta.UniformFieldDesc,
        /// Fragment uniform field descriptors for validation.
        frag_fields: []const gpu_meta.UniformFieldDesc,
        /// Borrowed vertex field writes.
        _pending_vert: []const UniformFieldItem = &.{},
        /// Borrowed fragment field writes.
        _pending_frag: []const UniformFieldItem = &.{},

        /// Queues cached vertex uniform writes for one atomic `apply`.
        /// Parameters:
        /// - self: editor instance.
        /// - items: borrowed field writes applied in order.
        /// Returns: `*const Editor` for chaining.
        pub fn setVertUniformFields(self: *const Editor, items: []const UniformFieldItem) *const Editor {
            @constCast(self)._pending_vert = items;
            return @constCast(self);
        }
        /// Queues cached fragment uniform writes for one atomic `apply`.
        /// Parameters:
        /// - self: editor instance.
        /// - items: borrowed field writes applied in order.
        /// Returns: `*const Editor` for chaining.
        pub fn setFragUniformFields(self: *const Editor, items: []const UniformFieldItem) *const Editor {
            @constCast(self)._pending_frag = items;
            return @constCast(self);
        }
        /// Validates the whole batch, then commits all writes atomically.
        /// Parameters:
        /// - self: editor holding pending writes.
        /// Returns: validation error with the cache untouched, if the batch is bad.
        pub fn apply(self: *const Editor) gpu_meta.ResourceError!void {
            for (self._pending_vert) |it| try validateUniformItem(self.vert_fields, it, false);
            for (self._pending_frag) |it| try validateUniformItem(self.frag_fields, it, false);
            // NOTE: no `kind != .other` restriction here (unlike the program
            // editor): cache writes are plain memcpys, any field kind works.
            for (self._pending_vert) |it| try self.rec.set_vert_field_fn(self.rec.ptr, it.field_id, it.type_id, it.bytes);
            for (self._pending_frag) |it| try self.rec.set_frag_field_fn(self.rec.ptr, it.field_id, it.type_id, it.bytes);
        }
    };

    /// Creates an `Editor` for atomic cache writes.
    /// Parameters:
    /// - self: material record to edit (copied; immune to pool reallocations).
    /// Returns: initialized `Editor` with no pending writes.
    pub fn edit(self: *const AnyMaterial) Editor {
        return .{ .rec = self.*, .vert_fields = self.vert_fields, .frag_fields = self.frag_fields };
    }
};

/// Checks whether a mesh satisfies a program's vertex shader inputs:
/// every input field must exist in the mesh vertex with an equal type.
/// Parameters:
/// - mesh: type-erased mesh.
/// - prog: type-erased program.
/// Returns: true on compatibility.
pub fn meshAcceptsProgram(mesh: *const AnyMesh, prog: *const AnyProgram) bool {
    return gpu_meta.fieldsSatisfiedBy(prog.vertex_inputs, mesh.vertex.fields);
}

/// Checks whether a material fits a mesh: the material's program vertex
/// inputs must be satisfied by the mesh vertex fields.
/// Parameters:
/// - mat: type-erased material.
/// - mesh: type-erased mesh.
/// Returns: true on compatibility (also usable in the reverse direction).
pub fn materialAcceptsMesh(mat: *const AnyMaterial, mesh: *const AnyMesh) bool {
    return gpu_meta.fieldsSatisfiedBy(mat.vertex_inputs, mesh.vertex.fields);
}

test "any buffer wrap/cast/upload without GL" {
    const alloc = std.testing.allocator;
    const B = Buffer(f32);
    const buf = try B.create(alloc);
    defer buf.destroy(alloc);

    var rec = AnyBuffer.wrap(buf);
    try std.testing.expectEqualStrings(@typeName(f32), rec.data.name);
    try std.testing.expectEqual(@sizeOf(f32), rec.elem_size);
    try std.testing.expect(rec.cast(f32) == buf);
    try std.testing.expect(rec.cast(u16) == null);
    try std.testing.expect(rec.cast(f64) == null);

    const data = [_]f32{ 1.0, 2.0, 3.0 };
    rec.edit().setDataBytes(std.mem.sliceAsBytes(data[0..]), .static_draw).apply();
    try std.testing.expectEqual(@as(usize, 3), rec.getCount());
    try std.testing.expectEqual(@as(usize, 12), rec.getSizeBytes());
    try std.testing.expect(rec.getTarget() == .array_buffer);

    const sub = [_]f32{9.0};
    const e = rec.edit();
    _ = e.setSubData(0, std.mem.sliceAsBytes(sub[0..]));
    _ = e.reserve(64, .dynamic_draw);
    e.apply();
    try std.testing.expectEqual(@as(usize, 64), rec.getSizeBytes());
    rec.edit().setTarget(.array_buffer).apply();
    rec.edit().setUsage(.static_draw).apply();
    try std.testing.expect(!rec.getIsMapped());
}

test "any mesh wrap/cast/uploads without GL" {
    const math = @import("math");
    const alloc = std.testing.allocator;
    const V = struct { pos: math.Vec(3, f32), uv: math.Vec(2, f32) };
    const M = Mesh(V);
    const mesh = try M.create(alloc);
    defer mesh.destroy(alloc);

    var rec = AnyMesh.wrap(mesh);
    try std.testing.expectEqualStrings(@typeName(V), rec.vertex.name);
    try std.testing.expectEqual(@sizeOf(V), rec.stride);
    try std.testing.expectEqual(@as(usize, 2), rec.getFieldCount());
    try std.testing.expect(rec.cast(V) == mesh);
    try std.testing.expect(rec.cast(u32) == null);
    try std.testing.expect(rec.layout.len == 2);

    const verts = [_]V{
        .{ .pos = math.Vec(3, f32).zero(), .uv = math.Vec(2, f32).zero() },
        .{ .pos = math.Vec(3, f32).init(.{ 1, 0, 0 }), .uv = math.Vec(2, f32).init(.{ 1, 1 }) },
    };
    rec.edit().setVerticesBytes(std.mem.sliceAsBytes(verts[0..]), verts.len).apply();
    try std.testing.expectEqual(@as(usize, 2), rec.getVertexCount());

    const idx = [_]u16{ 0, 1, 0 };
    rec.edit().setIndicesBytes(std.mem.sliceAsBytes(idx[0..]), .unsigned_short, idx.len).apply();
    try std.testing.expectEqual(@as(usize, 3), rec.getIndexCount());
    try std.testing.expect(rec.getIndexType() == .unsigned_short);

    // split-layout upload through the editor
    const pos = [_]math.Vec(3, f32){ math.Vec(3, f32).zero(), math.Vec(3, f32).init(.{ 0, 1, 0 }) };
    const uv = [_]math.Vec(2, f32){ math.Vec(2, f32).zero(), math.Vec(2, f32).init(.{ 0, 1 }) };
    const fields = [_]SoaFieldData{
        .{ .field_id = 0, .bytes = std.mem.sliceAsBytes(pos[0..]) },
        .{ .field_id = 1, .bytes = std.mem.sliceAsBytes(uv[0..]) },
    };
    const e = rec.edit();
    _ = e.setSoa(fields[0..], 2);
    _ = e.setIndicesBytes(std.mem.sliceAsBytes(idx[0..]), .unsigned_short, idx.len);
    e.apply();
    try std.testing.expectEqual(@as(usize, 2), rec.getVertexCount());
    try std.testing.expectEqual(@as(usize, 3), rec.getIndexCount());

    rec.edit().setPrimitive(.triangles).apply();
    try std.testing.expect(rec.getPrimitive() == .triangles);
    rec.edit().setVertexBuffer(rec.getVbo()).apply();
    rec.edit().setIndexBuffer(rec.getEbo()).apply();
}

test "any buffer editor batches into one cycle" {
    const alloc = std.testing.allocator;
    const buf = try Buffer(u16).create(alloc);
    defer buf.destroy(alloc);
    var rec = AnyBuffer.wrap(buf);

    const e = rec.edit();
    _ = e.setDataBytes(&[_]u8{ 1, 2, 3, 4 }, .static_draw);
    _ = e.setUsage(.dynamic_draw);
    // staged only: nothing applied yet
    try std.testing.expectEqual(@as(usize, 0), rec.getCount());
    try std.testing.expect(rec.getUsage() == .static_draw);
    e.apply();
    try std.testing.expectEqual(@as(usize, 2), rec.getCount());
    try std.testing.expectEqual(@as(usize, 4), rec.getSizeBytes());
    try std.testing.expect(rec.getUsage() == .dynamic_draw);

    // sub-data + reserve batch
    const e2 = rec.edit();
    _ = e2.setSubData(0, &[_]u8{9});
    _ = e2.reserve(32, .static_draw);
    e2.apply();
    try std.testing.expectEqual(@as(usize, 32), rec.getSizeBytes());
}

test "any mesh editor batches into one cycle" {
    const math = @import("math");
    const alloc = std.testing.allocator;
    const V = struct { pos: math.Vec(3, f32) };
    const mesh = try Mesh(V).create(alloc);
    defer mesh.destroy(alloc);
    var rec = AnyMesh.wrap(mesh);

    const verts = [_]V{
        .{ .pos = math.Vec(3, f32).zero() },
        .{ .pos = math.Vec(3, f32).init(.{ 1, 0, 0 }) },
    };
    const idx = [_]u16{ 0, 1 };
    const e = rec.edit();
    _ = e.setVerticesBytes(std.mem.sliceAsBytes(verts[0..]), verts.len);
    _ = e.setIndicesBytes(std.mem.sliceAsBytes(idx[0..]), .unsigned_short, idx.len);
    _ = e.setPrimitive(.triangles);
    // staged only
    try std.testing.expectEqual(@as(usize, 0), rec.getVertexCount());
    try std.testing.expectEqual(@as(usize, 0), rec.getIndexCount());
    e.apply();
    try std.testing.expectEqual(@as(usize, 2), rec.getVertexCount());
    try std.testing.expectEqual(@as(usize, 2), rec.getIndexCount());
    try std.testing.expect(rec.getIndexType() == .unsigned_short);
    try std.testing.expect(rec.getPrimitive() == .triangles);
}

test "mesh/program/material compatibility on fabricated records" {
    const math = @import("math");
    const alloc = std.testing.allocator;
    const V = struct { position: math.Vec(3, f32), uv: math.Vec(2, f32) };
    const M = Mesh(V);
    const mesh = try M.create(alloc);
    defer mesh.destroy(alloc);
    var mesh_rec = AnyMesh.wrap(mesh);

    const ShaderVert = struct {
        pub const Vertex = struct { position: math.Vec(3, f32), uv: math.Vec(2, f32) };
        pub const Uniform = struct { uMvp: math.Mat(4, 4, f32) };
    };
    const inputs = comptime gpu_meta.describe(ShaderVert.Vertex).fields;
    const prog_rec = AnyProgram{
        .ptr = @ptrFromInt(0x10),
        .destroy_fn = undefined,
        .use_fn = undefined,
        .get_id_fn = undefined,
        .uniform_location_fn = undefined,
        .upload_vert_fn = undefined,
        .upload_frag_fn = null,
        .vert_name = @typeName(ShaderVert),
        .frag_name = null,
        .has_frag = false,
        .vert_uniform = comptime gpu_meta.describe(ShaderVert.Uniform),
        .frag_uniform = comptime gpu_meta.describe(struct {}),
        .vertex_inputs = inputs,
        .vert_fields = comptime gpu_meta.uniformFields(ShaderVert.Uniform),
        .frag_fields = &.{},
        .gl_id = 0,
    };
    try std.testing.expect(meshAcceptsProgram(&mesh_rec, &prog_rec));

    const BadVert = struct {
        pub const Vertex = struct { position: math.Vec(3, f32), normal: math.Vec(3, f32) };
        pub const Uniform = struct {};
    };
    var bad_rec = prog_rec;
    bad_rec.vertex_inputs = comptime gpu_meta.describe(BadVert.Vertex).fields;
    try std.testing.expect(!meshAcceptsProgram(&mesh_rec, &bad_rec));

    var mat_rec = AnyMaterial{
        .ptr = @ptrFromInt(0x10),
        .destroy_fn = undefined,
        .use_fn = undefined,
        .get_program_id_fn = undefined,
        .read_vert_fn = undefined,
        .write_vert_fn = undefined,
        .read_frag_fn = undefined,
        .write_frag_fn = undefined,
        .set_vert_field_fn = undefined,
        .get_vert_field_fn = undefined,
        .set_frag_field_fn = undefined,
        .get_frag_field_fn = undefined,
        .program_name = "TestProg",
        .program_vert_name = @typeName(ShaderVert),
        .program_frag_name = null,
        .vertex_inputs = inputs,
        .vert_uniform = comptime gpu_meta.describe(ShaderVert.Uniform),
        .frag_uniform = comptime gpu_meta.describe(struct {}),
        .vert_fields = comptime gpu_meta.uniformFields(ShaderVert.Uniform),
        .frag_fields = &.{},
    };
    try std.testing.expect(materialAcceptsMesh(&mat_rec, &mesh_rec));
    mat_rec.vertex_inputs = comptime gpu_meta.describe(BadVert.Vertex).fields;
    try std.testing.expect(!materialAcceptsMesh(&mat_rec, &mesh_rec));
}

// Minimal fake program: quacks like `ShaderProgram(Vert, Frag)` but touches no
// GL, so `AnyProgram.wrap` and all non-GL paths are testable without a context.
const FakeVertP = struct {
    pub const Vertex = struct { aPos: [3]f32 };
    pub const Uniform = struct { uScale: f32, uTex: *const u8 };
};
const FakeFragP = struct {
    pub const Uniform = struct { uColor: f32 };
};
const FakeProgramP = struct {
    pub const HasFrag = true;
    pub const Vert = FakeVertP;
    pub const Frag = FakeFragP;
    pub const FragT = FakeFragP;
    id: u32 = 0,
    pub fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
    pub fn use(_: *const @This()) void {}
    pub fn getId(self: *const @This()) u32 {
        return self.id;
    }
};
const FakeProgramNoFrag = struct {
    pub const HasFrag = false;
    pub const Vert = FakeVertP;
    pub const Frag = null;
    pub const FragT = void;
    id: u32 = 0,
    pub fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
    pub fn use(_: *const @This()) void {}
    pub fn getId(self: *const @This()) u32 {
        return self.id;
    }
};

// Minimal fake material: quacks like `Material(Prog)` but touches no GL, so
// the full `AnyMaterial` API (wrap/cast/fields/cache/Editor) is testable.
const FakeVertU = struct { uMvp: f32, uFlag: bool };
const FakeFragU = struct { uColor: f32 };
const FakeProgM = struct {
    pub const Vert = struct {
        pub const Vertex = struct { position: [3]f32 };
    };
    pub const HasFrag = false;
    id: u32 = 0,
    pub fn getId(self: *const @This()) u32 {
        return self.id;
    }
};
const FakeMat = struct {
    pub const VertUniformT = FakeVertU;
    pub const FragUniformT = FakeFragU;
    pub const ShaderProgram = FakeProgM;
    prog: ?*FakeProgM,
    vert: FakeVertU,
    frag: FakeFragU,
    used: bool = false,
    pub fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
    pub fn use(self: *@This()) void {
        self.used = true;
    }
    pub fn getProgram(self: *const @This()) ?*FakeProgM {
        return self.prog;
    }
    pub fn getVertUniform(self: *const @This()) FakeVertU {
        return self.vert;
    }
    pub fn setVertUniform(self: *@This(), u: FakeVertU) void {
        self.vert = u;
    }
    pub fn getFragUniform(self: *const @This()) FakeFragU {
        return self.frag;
    }
    pub fn setFragUniform(self: *@This(), u: FakeFragU) void {
        self.frag = u;
    }
};

test "any program wrap/meta/validation without GL" {
    const alloc = std.testing.allocator;
    const p = try alloc.create(FakeProgramP);
    p.* = .{ .id = 42 };
    var rec = AnyProgram.wrap(p);
    defer rec.destroy(alloc);

    try std.testing.expectEqualStrings(@typeName(FakeVertP), rec.vert_name);
    try std.testing.expect(rec.has_frag);
    try std.testing.expectEqualStrings(@typeName(FakeFragP), rec.frag_name.?);
    try std.testing.expectEqual(@as(u32, 42), rec.gl_id);
    try std.testing.expectEqual(@as(usize, 1), rec.vertex_inputs.len);
    try std.testing.expectEqual(@as(usize, 2), rec.vert_fields.len);
    try std.testing.expectEqual(@as(usize, 1), rec.frag_fields.len);

    try std.testing.expect(rec.cast(FakeVertP, FakeFragP) == p);
    try std.testing.expect(rec.cast(FakeVertP, null) == null);
    try std.testing.expect(rec.cast(FakeFragP, FakeFragP) == null);

    const tid_f32 = gpu_meta.typeId(f32);
    const id_scale = try rec.getVertUniformFieldId("uScale", tid_f32);
    try std.testing.expectEqual(@as(u32, 0), id_scale);
    try std.testing.expectError(error.FieldNotFound, rec.getVertUniformFieldId("nope", tid_f32));
    try std.testing.expectError(error.FieldTypeMismatch, rec.getVertUniformFieldId("uScale", gpu_meta.typeId(i32)));

    // error paths return before any GL call (all uploads go through Editor)
    const bad_id = [_]UniformFieldItem{.{ .field_id = 99, .type_id = tid_f32, .bytes = std.mem.asBytes(&id_scale) }};
    try std.testing.expectError(error.UnknownFieldId, rec.edit().setVertUniformFields(&bad_id).apply());
    const tid_tex = gpu_meta.typeId(*const u8);
    const id_tex = try rec.getVertUniformFieldId("uTex", tid_tex);
    const bad_kind = [_]UniformFieldItem{.{ .field_id = id_tex, .type_id = tid_tex, .bytes = "x" }};
    try std.testing.expectError(error.UnsupportedUniformField, rec.edit().setVertUniformFields(&bad_kind).apply());

    // vertex-only program: frag access reports UnknownFieldId
    const p2 = try alloc.create(FakeProgramNoFrag);
    p2.* = .{ .id = 1 };
    var rec2 = AnyProgram.wrap(p2);
    defer rec2.destroy(alloc);
    try std.testing.expect(!rec2.has_frag);
    try std.testing.expect(rec2.cast(FakeVertP, null) == p2);
    try std.testing.expectError(error.UnknownFieldId, rec2.getFragUniformFieldId("uColor", tid_f32));
    const bad_frag = [_]UniformFieldItem{.{ .field_id = 0, .type_id = tid_f32, .bytes = std.mem.asBytes(&id_scale) }};
    try std.testing.expectError(error.UnknownFieldId, rec2.edit().setFragUniformFields(&bad_frag).apply());
}

test "any material wrap/fields/cache/editor without GL" {
    const alloc = std.testing.allocator;
    var prog = FakeProgM{ .id = 7 };
    const m = try alloc.create(FakeMat);
    m.* = .{ .prog = &prog, .vert = .{ .uMvp = 1.0, .uFlag = false }, .frag = .{ .uColor = 0.5 }, .used = false };
    var rec = AnyMaterial.wrap(m);
    defer rec.destroy(alloc);

    try std.testing.expectEqualStrings(@typeName(FakeProgM), rec.program_name);
    try std.testing.expect(rec.cast(FakeProgM) == m);
    try std.testing.expect(rec.cast(struct {}) == null);
    try std.testing.expectEqual(@as(u32, 7), rec.getProgramId());
    m.prog = null;
    try std.testing.expectEqual(@as(u32, 0), rec.getProgramId());
    m.prog = &prog;

    const tid_f32 = gpu_meta.typeId(f32);
    const tid_bool = gpu_meta.typeId(bool);
    const id_mvp = try rec.getVertUniformFieldId("uMvp", tid_f32);
    const id_flag = try rec.getVertUniformFieldId("uFlag", tid_bool);
    var two: f32 = 2.0;
    try rec.setVertUniformData(id_mvp, tid_f32, std.mem.asBytes(&two));
    var got: f32 = 0;
    try rec.getVertUniformData(id_mvp, tid_f32, std.mem.asBytes(&got));
    try std.testing.expectEqual(@as(f32, 2.0), got);
    try std.testing.expectError(error.FieldNotFound, rec.getVertUniformFieldId("nope", tid_f32));
    try std.testing.expectError(error.FieldTypeMismatch, rec.getVertUniformFieldId("uMvp", tid_bool));
    try std.testing.expectError(error.UnknownFieldId, rec.setVertUniformData(99, tid_f32, std.mem.asBytes(&two)));

    // whole-cache roundtrip
    var cache: [@sizeOf(FakeVertU)]u8 = undefined;
    try rec.readVertCache(&cache);
    try std.testing.expectError(error.SizeMismatch, rec.readVertCache(cache[0..1]));
    var altered = cache;
    altered[0] ^= 0xFF;
    try rec.writeVertCache(&altered);
    var check: [@sizeOf(FakeVertU)]u8 = undefined;
    try rec.readVertCache(&check);
    try std.testing.expectEqualSlices(u8, &altered, &check);
    try rec.writeVertCache(&cache);

    // editor: failed batch leaves the cache untouched (atomic commit)
    var three: f32 = 3.0;
    const e = rec.edit();
    _ = e.setVertUniformFields(&.{
        .{ .field_id = id_mvp, .type_id = tid_f32, .bytes = std.mem.asBytes(&three) },
        .{ .field_id = 99, .type_id = tid_f32, .bytes = std.mem.asBytes(&three) },
    });
    try std.testing.expectError(error.UnknownFieldId, e.apply());
    var still: f32 = 0;
    try rec.getVertUniformData(id_mvp, tid_f32, std.mem.asBytes(&still));
    try std.testing.expectEqual(@as(f32, 2.0), still);

    // editor: successful batch commits everything, still no GL involved
    const e2 = rec.edit();
    var flag_on: bool = true;
    _ = e2.setVertUniformFields(&.{
        .{ .field_id = id_mvp, .type_id = tid_f32, .bytes = std.mem.asBytes(&three) },
        .{ .field_id = id_flag, .type_id = tid_bool, .bytes = std.mem.asBytes(&flag_on) },
    });
    const id_color = try rec.getFragUniformFieldId("uColor", tid_f32);
    var color: f32 = 0.25;
    _ = e2.setFragUniformFields(&.{.{ .field_id = id_color, .type_id = tid_f32, .bytes = std.mem.asBytes(&color) }});
    try e2.apply();
    try rec.getVertUniformData(id_mvp, tid_f32, std.mem.asBytes(&still));
    try std.testing.expectEqual(@as(f32, 3.0), still);
    var got_flag: bool = false;
    try rec.getVertUniformData(id_flag, tid_bool, std.mem.asBytes(&got_flag));
    try std.testing.expect(got_flag);

    rec.use();
    try std.testing.expect(m.used);
}
