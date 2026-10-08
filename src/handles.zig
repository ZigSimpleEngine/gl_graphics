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
///
/// Returns: `UnknownFieldId` / `FieldTypeMismatch` / `UnsupportedUniformField` / `SizeMismatch`.
fn validateUniformItem(fields: gpu_meta.UniformFields, it: UniformFieldItem, check_uploadable: bool) gpu_meta.ResourceError!void {
    if (it.field_id >= fields.fields.len) return error.UnknownFieldId;
    const d = fields.fields[it.field_id];
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
    /// Virtual table with all type-erased thunks for `AnyBuffer`.
    pub const VTable = struct {
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
        /// Flushes an `Editor` in one underlying edit/apply cycle. Captured at wrap.
        editor_apply_fn: *const fn (*const Editor) void,
    };

    /// Wrapped `*Buffer(T)`, owned by whoever holds the pool reference.
    ptr: *anyopaque,
    /// Pointer to the static per-type virtual table.
    vtable: *const VTable,
    /// Element type description (name/size/align).
    data: gpu_meta.TypeDesc,
    /// `@sizeOf` the element type.
    elem_size: usize,
    /// GL object name cached at wrap time.
    gl_id: u32,

    /// Wraps a typed buffer pointer. The record does not take ownership:
    /// destroy exactly once via `remove` + `destroy`.
    /// Preferred entry point is `buf.asAnyBuffer()` on the concrete type;
    /// this `wrap` is the underlying implementation.
    /// Parameters:
    /// - ptr: `*Buffer(T)` for any `T`.
    ///
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
            const vtable: VTable = .{
                .destroy_fn = @This().destroy,
                .is_valid_fn = @This().isValid,
                .get_id_fn = @This().getId,
                .get_target_fn = @This().getTarget,
                .get_usage_fn = @This().getUsage,
                .get_size_fn = @This().getSize,
                .get_count_fn = @This().getCount,
                .is_mapped_fn = @This().isMapped,
                .query_size_fn = @This().querySize,
                .query_usage_fn = @This().queryUsage,
                .query_mapped_fn = @This().queryMapped,
                .query_map_length_fn = @This().queryMapLength,
                .query_map_offset_fn = @This().queryMapOffset,
                .query_access_fn = @This().queryAccess,
                .bind_fn = @This().bind,
                .bind_to_fn = @This().bindTo,
                .map_fn = @This().map,
                .flush_fn = @This().flush,
                .unmap_fn = @This().unmap,
                .editor_apply_fn = @This().applyEditor,
            };
        };
        return .{
            .ptr = ptr,
            .vtable = &S.vtable,
            .data = comptime gpu_meta.describe(B.DataType),
            .elem_size = @sizeOf(B.DataType),
            .gl_id = ptr.getId(),
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
        ///
        /// Returns: void.
        pub fn apply(self: *const Editor) void {
            self.rec.vtable.editor_apply_fn(self);
        }
    };

    /// Creates an `Editor` for batched buffer updates.
    /// Parameters:
    /// - self: buffer record to edit (copied; immune to pool reallocations).
    ///
    /// Returns: initialized `Editor` with no pending changes.
    pub fn edit(self: *const AnyBuffer) Editor {
        return .{ .rec = self.* };
    }

    /// Downcasts back to a typed buffer. Returns null on type mismatch.
    /// Parameters:
    /// - self: record to downcast.
    /// - T: expected element type.
    ///
    /// Returns: `*Buffer(T)` or null.
    pub fn cast(self: *AnyBuffer, comptime T: type) ?*Buffer(T) {
        if (self.elem_size != @sizeOf(T)) return null;
        if (!std.mem.eql(u8, self.data.name, @typeName(T))) return null;
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Destroys the wrapped buffer (the abstracted resource).
    pub fn destroy(self: *const AnyBuffer, alloc: std.mem.Allocator) void {
        self.vtable.destroy_fn(self.ptr, alloc);
    }
    /// See `Buffer.isValid`.
    pub fn isValid(self: *const AnyBuffer) bool {
        return self.vtable.is_valid_fn(self.ptr);
    }
    /// Returns the live GL object name.
    pub fn getId(self: *const AnyBuffer) u32 {
        return self.vtable.get_id_fn(self.ptr);
    }
    /// See `Buffer.getTarget`.
    pub fn getTarget(self: *const AnyBuffer) gl.buffers.BufferTarget {
        return self.vtable.get_target_fn(self.ptr);
    }
    /// See `Buffer.getUsage`.
    pub fn getUsage(self: *const AnyBuffer) gl.buffers.BufferUsage {
        return self.vtable.get_usage_fn(self.ptr);
    }
    /// See `Buffer.getSizeBytes`.
    pub fn getSizeBytes(self: *const AnyBuffer) usize {
        return self.vtable.get_size_fn(self.ptr);
    }
    /// See `Buffer.getCount`.
    pub fn getCount(self: *const AnyBuffer) usize {
        return self.vtable.get_count_fn(self.ptr);
    }
    /// See `Buffer.getIsMapped`.
    pub fn getIsMapped(self: *const AnyBuffer) bool {
        return self.vtable.is_mapped_fn(self.ptr);
    }
    /// See `Buffer.querySize`.
    pub fn querySize(self: *const AnyBuffer) i32 {
        return self.vtable.query_size_fn(self.ptr);
    }
    /// See `Buffer.queryUsage`.
    pub fn queryUsage(self: *const AnyBuffer) i32 {
        return self.vtable.query_usage_fn(self.ptr);
    }
    /// See `Buffer.queryMapped`.
    pub fn queryMapped(self: *const AnyBuffer) bool {
        return self.vtable.query_mapped_fn(self.ptr);
    }
    /// See `Buffer.queryMapLength`.
    pub fn queryMapLength(self: *const AnyBuffer) i32 {
        return self.vtable.query_map_length_fn(self.ptr);
    }
    /// See `Buffer.queryMapOffset`.
    pub fn queryMapOffset(self: *const AnyBuffer) i32 {
        return self.vtable.query_map_offset_fn(self.ptr);
    }
    /// See `Buffer.queryAccessFlags`.
    pub fn queryAccessFlags(self: *const AnyBuffer) i32 {
        return self.vtable.query_access_fn(self.ptr);
    }
    /// See `Buffer.bind`.
    pub fn bind(self: *const AnyBuffer) void {
        self.vtable.bind_fn(self.ptr);
    }
    /// See `Buffer.bindTo`.
    pub fn bindTo(self: *const AnyBuffer, target: gl.buffers.BufferTarget) void {
        self.vtable.bind_to_fn(self.ptr, target);
    }
    /// Alias for `bind`.
    pub fn use(self: *const AnyBuffer) void {
        self.bind();
    }
    /// Maps a range; see `Buffer.Editor.mapNow`. Synchronous by nature
    /// (the pointer is needed immediately): intentionally not part of `Editor`.
    pub fn mapRange(self: *AnyBuffer, offset: usize, len: usize, access: gl.buffers.MapAccess) ?*anyopaque {
        return self.vtable.map_fn(self.ptr, offset, len, access);
    }
    /// Flushes a mapped range. Synchronous single GL call by nature:
    /// intentionally not part of `Editor`.
    pub fn flushRange(self: *AnyBuffer, offset: usize, len: usize) void {
        self.vtable.flush_fn(self.ptr, offset, len);
    }
    /// Unmaps the buffer. Synchronous single GL call by nature:
    /// intentionally not part of `Editor`. See `Buffer.Editor.unmapNow`.
    pub fn unmap(self: *AnyBuffer) bool {
        return self.vtable.unmap_fn(self.ptr);
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
    /// Virtual table with all type-erased thunks for `AnyMesh`.
    pub const VTable = struct {
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
    };

    /// Wrapped `*Mesh(Vertex)`, owned by whoever holds the pool reference.
    ptr: *anyopaque,
    /// Pointer to the static per-type virtual table.
    vtable: *const VTable,
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
    /// Preferred entry point is `mesh.asAnyMesh()` on the concrete type;
    /// this `wrap` is the underlying implementation.
    /// Parameters:
    /// - ptr: `*Mesh(Vertex)` for any `Vertex`.
    ///
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
            const vtable: VTable = .{
                .destroy_fn = @This().destroy,
                .is_valid_fn = @This().isValid,
                .get_vao_fn = @This().getVao,
                .get_vbo_fn = @This().getVbo,
                .get_ebo_fn = @This().getEbo,
                .get_vertex_count_fn = @This().getVertexCount,
                .get_index_count_fn = @This().getIndexCount,
                .get_index_type_fn = @This().getIndexType,
                .get_primitive_fn = @This().getPrimitive,
                .bind_fn = @This().bind,
                .draw_fn = @This().draw,
                .draw_instanced_fn = @This().drawInstanced,
                .editor_apply_fn = @This().applyEditor,
            };
        };
        return .{
            .ptr = ptr,
            .vtable = &S.vtable,
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
        ///
        /// Returns: void.
        pub fn apply(self: *const Editor) void {
            self.rec.vtable.editor_apply_fn(self);
        }
    };

    /// Creates an `Editor` for batched mesh updates.
    /// Parameters:
    /// - self: mesh record to edit (copied; immune to pool reallocations).
    ///
    /// Returns: initialized `Editor` with no pending changes.
    pub fn edit(self: *const AnyMesh) Editor {
        return .{ .rec = self.* };
    }

    /// Downcasts back to a typed mesh. Returns null on type mismatch.
    /// Parameters:
    /// - self: record to downcast.
    /// - V: expected vertex type.
    ///
    /// Returns: `*Mesh(V)` or null.
    pub fn cast(self: *AnyMesh, comptime V: type) ?*Mesh(V) {
        if (self.stride != @sizeOf(V)) return null;
        if (!std.mem.eql(u8, self.vertex.name, @typeName(V))) return null;
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Destroys the wrapped mesh (the abstracted resource).
    pub fn destroy(self: *const AnyMesh, alloc: std.mem.Allocator) void {
        self.vtable.destroy_fn(self.ptr, alloc);
    }
    /// See `Mesh.isValid`.
    pub fn isValid(self: *const AnyMesh) bool {
        return self.vtable.is_valid_fn(self.ptr);
    }
    /// See `Mesh.getVao`.
    pub fn getVao(self: *const AnyMesh) u32 {
        return self.vtable.get_vao_fn(self.ptr);
    }
    /// See `Mesh.getVbo`.
    pub fn getVbo(self: *const AnyMesh) u32 {
        return self.vtable.get_vbo_fn(self.ptr);
    }
    /// See `Mesh.getEbo`.
    pub fn getEbo(self: *const AnyMesh) u32 {
        return self.vtable.get_ebo_fn(self.ptr);
    }
    /// See `Mesh.getVertexCount`.
    pub fn getVertexCount(self: *const AnyMesh) usize {
        return self.vtable.get_vertex_count_fn(self.ptr);
    }
    /// See `Mesh.getIndexCount`.
    pub fn getIndexCount(self: *const AnyMesh) usize {
        return self.vtable.get_index_count_fn(self.ptr);
    }
    /// See `Mesh.getIndexType` (runtime value, set by the last indices upload).
    pub fn getIndexType(self: *const AnyMesh) gl.enums.DataType {
        return self.vtable.get_index_type_fn(self.ptr);
    }
    /// See `Mesh.getPrimitive`.
    pub fn getPrimitive(self: *const AnyMesh) gl.drawing.PrimitiveType {
        return self.vtable.get_primitive_fn(self.ptr);
    }
    /// Number of top-level vertex fields.
    pub fn getFieldCount(self: *const AnyMesh) usize {
        return self.vertex.fields.len;
    }
    /// See `Mesh.bind`.
    pub fn bind(self: *const AnyMesh) void {
        self.vtable.bind_fn(self.ptr);
    }
    /// Alias for `bind`.
    pub fn use(self: *const AnyMesh) void {
        self.bind();
    }
    /// See `Mesh.draw`.
    pub fn draw(self: *const AnyMesh) void {
        self.vtable.draw_fn(self.ptr);
    }
    /// See `Mesh.drawInstanced`.
    pub fn drawInstanced(self: *const AnyMesh, instance_count: i32) void {
        self.vtable.draw_instanced_fn(self.ptr, instance_count);
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

/// Vertex shader input fields for mesh compatibility (`Vert.Vertex` fields,
/// empty when the descriptor provides none). Shared by both program wraps.
fn programVertexInputs(comptime Vert: type) []const gpu_meta.FieldDesc {
    if (!@hasDecl(Vert, "Vertex")) return &.{};
    const VX = Vert.Vertex;
    if (@typeInfo(VX) != .@"struct") return &.{};
    return gpu_meta.describe(VX).fields;
}

/// Live uniform location query against an explicit field list and program id.
/// Shared by the vertex/fragment upload paths of both program wraps.
fn locateProgramUniform(fields: gpu_meta.UniformFields, field_id: u32, program: u32) gpu_meta.ResourceError!i32 {
    if (field_id >= fields.fields.len) return error.UnknownFieldId;
    // Field names are static strings without a terminator: copy to a
    // bounded stack buffer instead of allocating.
    const uname = fields.fields[field_id].name;
    var buf: [256]u8 = undefined;
    if (uname.len >= buf.len) return error.UnknownFieldId;
    @memcpy(buf[0..uname.len], uname);
    buf[uname.len] = 0;
    return gl.uniforms.location(program, buf[0..uname.len :0]);
}

/// Stage-dispatched location query over both field lists.
/// Shared by the `uniform_location_fn` thunk of both program wraps;
/// an empty list naturally reports `UnknownFieldId`.
fn locateProgramUniformByStage(vert_fields: gpu_meta.UniformFields, frag_fields: gpu_meta.UniformFields, stage: UniformStage, field_id: u32, program: u32) gpu_meta.ResourceError!i32 {
    const fields = switch (stage) {
        .vert => vert_fields,
        .frag => frag_fields,
    };
    return locateProgramUniform(fields, field_id, program);
}

/// Direct plain-data field upload into the bound program variant.
/// Shared by the vertex/fragment upload thunks of both program wraps.
fn uploadProgramField(fields: gpu_meta.UniformFields, field_id: u32, program: u32, want_type: usize, bytes: []const u8) gpu_meta.ResourceError!void {
    if (field_id >= fields.fields.len) return error.UnknownFieldId;
    const desc = fields.fields[field_id];
    if (desc.type_id != want_type) return error.FieldTypeMismatch;
    if (desc.kind == .other) return error.UnsupportedUniformField;
    const loc = try locateProgramUniform(fields, field_id, program);
    if (loc == -1) return;
    try shader_runtime.uploadUniformByKind(loc, desc.kind, bytes);
}

/// Copies raw defines bytes into an aligned stack value of type `T`.
/// `bytes.len` must equal `@sizeOf(T)`; alignment of the input is ignored.
fn bytesToDefines(comptime T: type, bytes: []const u8) gpu_meta.ResourceError!T {
    if (bytes.len != @sizeOf(T)) return error.SizeMismatch;
    var out: T = undefined;
    @memcpy(std.mem.asBytes(&out), bytes);
    return out;
}

/// Type-erased wrapper over `ShaderProgram(Vert, Frag)` and
/// `VertexProgram(Vert)` (via `wrap` and `wrapVertex` respectively).
///
/// Keeps the singleton program id plus descriptor names, both `Uniform`
/// descriptions and the vertex shader input list (`Vert.Vertex` fields when
/// the descriptor provides them), so a program can be matched against meshes
/// without knowing the descriptors. The wrapped program stays a comptime
/// singleton: thunks captured at `wrap` time call its static methods.
pub const AnyProgram = struct {
    /// Virtual table with all type-erased thunks for `AnyProgram`.
    pub const VTable = struct {
        /// Destroys all linked variants.
        destroy_fn: *const fn (std.mem.Allocator) void,
        /// Returns the program id for raw defines bytes, linking on first call.
        instance_fn: *const fn (std.mem.Allocator, []const u8, ?[]const u8) anyerror!u32,
        /// Binds the program variant for raw defines bytes.
        use_fn: *const fn (std.mem.Allocator, []const u8, ?[]const u8) anyerror!void,
        /// Returns the linked variant id or 0 (no link, no alloc).
        get_id_for_fn: *const fn ([]const u8, ?[]const u8) u32,
        /// Live uniform location query by stage + field id + explicit program.
        uniform_location_fn: *const fn (UniformStage, u32, u32) gpu_meta.ResourceError!i32,
        /// Direct plain-data field upload into an explicit program (vertex stage).
        upload_vert_fn: *const fn (u32, u32, usize, []const u8) gpu_meta.ResourceError!void,
        /// Direct plain-data field upload (fragment stage). Null when no fragment stage.
        upload_frag_fn: ?*const fn (u32, u32, usize, []const u8) gpu_meta.ResourceError!void,
    };

    /// Pointer to the static per-type virtual table.
    vtable: *const VTable,
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
    /// Vertex uniform field table (static hash map + descriptors, `field_id` == index).
    vert_fields: gpu_meta.UniformFields,
    /// Fragment uniform field table (static hash map + descriptors, `field_id` == index).
    frag_fields: gpu_meta.UniformFields,
    /// Vertex `Define` description (empty struct when no flags).
    vert_defines: gpu_meta.TypeDesc,
    /// Fragment `Define` description (empty when no fragment stage/flags).
    frag_defines: gpu_meta.TypeDesc,
    /// Vertex defines field table (`field_id` == index).
    vert_defines_fields: gpu_meta.UniformFields,
    /// Fragment defines field table (empty when no fragment stage).
    frag_defines_fields: gpu_meta.UniformFields,

    /// Wraps a full shader program type. The record does not take ownership:
    /// the program stays a comptime singleton owned by its own static state.
    /// Preferred entry point is `Prog.asAnyProgram()` on the concrete type;
    /// this `wrap` is the underlying implementation.
    /// Parameters:
    /// - Prog: `ShaderProgram(Vert, Frag)` type for any descriptors.
    ///
    /// Returns: type-erased record.
    pub fn wrap(comptime Prog: type) AnyProgram {
        if (!@hasDecl(Prog, "HasFrag") or !@hasDecl(Prog, "Vert") or !@hasDecl(Prog, "Frag")) @compileError("AnyProgram.wrap expects a ShaderProgram(Vert, Frag) type, got " ++ @typeName(Prog));
        const Vert = Prog.Vert;
        const FragU = Prog.Frag.Uniform;
        const VertU = Vert.Uniform;
        const VertD = Prog.VertDefines;
        const FragD = Prog.FragDefines;
        const vert_fields = comptime gpu_meta.uniformFields(VertU);
        const frag_fields = comptime gpu_meta.uniformFields(FragU);
        const vert_defines_fields = comptime gpu_meta.uniformFields(VertD);
        const frag_defines_fields = comptime gpu_meta.uniformFields(FragD);
        const S = struct {
            fn destroy(allocator: std.mem.Allocator) void {
                Prog.destroy(allocator);
            }
            fn instance(allocator: std.mem.Allocator, vert_bytes: []const u8, frag_bytes: ?[]const u8) anyerror!u32 {
                const vd = try bytesToDefines(VertD, vert_bytes);
                const fd_bytes = frag_bytes orelse return error.SizeMismatch;
                const fd = try bytesToDefines(FragD, fd_bytes);
                return Prog.instance(allocator, vd, fd);
            }
            fn use(allocator: std.mem.Allocator, vert_bytes: []const u8, frag_bytes: ?[]const u8) anyerror!void {
                try Prog.use(allocator, try bytesToDefines(VertD, vert_bytes), try bytesToDefines(FragD, frag_bytes orelse return error.SizeMismatch));
            }
            fn getIdFor(vert_bytes: []const u8, frag_bytes: ?[]const u8) u32 {
                const vd = bytesToDefines(VertD, vert_bytes) catch return 0;
                const fd = bytesToDefines(FragD, frag_bytes orelse return 0) catch return 0;
                if (Prog.getVariant(.{ .vert = vd, .frag = fd })) |v| return v.prog_id;
                return 0;
            }
            fn locateUniform(stage: UniformStage, field_id: u32, program: u32) gpu_meta.ResourceError!i32 {
                return locateProgramUniformByStage(vert_fields, frag_fields, stage, field_id, program);
            }
            fn uploadVert(program: u32, field_id: u32, want_type: usize, bytes: []const u8) gpu_meta.ResourceError!void {
                try uploadProgramField(vert_fields, field_id, program, want_type, bytes);
            }
            fn uploadFrag(program: u32, field_id: u32, want_type: usize, bytes: []const u8) gpu_meta.ResourceError!void {
                try uploadProgramField(frag_fields, field_id, program, want_type, bytes);
            }
            const vtable: VTable = .{
                .destroy_fn = @This().destroy,
                .instance_fn = @This().instance,
                .use_fn = @This().use,
                .get_id_for_fn = @This().getIdFor,
                .uniform_location_fn = @This().locateUniform,
                .upload_vert_fn = @This().uploadVert,
                .upload_frag_fn = @This().uploadFrag,
            };
        };
        return .{
            .vtable = &S.vtable,
            .vert_name = @typeName(Vert),
            .frag_name = @typeName(Prog.Frag),
            .has_frag = true,
            .vert_uniform = comptime gpu_meta.describe(VertU),
            .frag_uniform = comptime gpu_meta.describe(FragU),
            .vertex_inputs = comptime programVertexInputs(Vert),
            .vert_fields = vert_fields,
            .frag_fields = frag_fields,
            .vert_defines = comptime gpu_meta.describe(VertD),
            .frag_defines = comptime gpu_meta.describe(FragD),
            .vert_defines_fields = vert_defines_fields,
            .frag_defines_fields = frag_defines_fields,
        };
    }

    /// Wraps a vertex-only program type. Same ownership rules as `wrap`;
    /// the fragment side of the record is empty (`vtable.upload_frag_fn` null,
    /// `frag_name` null, empty fragment descriptors).
    /// Preferred entry point is `Prog.asAnyProgram()` on the concrete type;
    /// this `wrapVertex` is the underlying implementation.
    /// Parameters:
    /// - Prog: `VertexProgram(Vert)` type for any vertex descriptor.
    ///
    /// Returns: type-erased record.
    pub fn wrapVertex(comptime Prog: type) AnyProgram {
        if (!@hasDecl(Prog, "HasFrag") or !@hasDecl(Prog, "Vert")) @compileError("AnyProgram.wrapVertex expects a VertexProgram(Vert) type, got " ++ @typeName(Prog));
        const Vert = Prog.Vert;
        const VertU = Vert.Uniform;
        const VertD = Prog.VertDefines;
        const vert_fields = comptime gpu_meta.uniformFields(VertU);
        const frag_fields = comptime gpu_meta.uniformFields(struct {});
        const vert_defines_fields = comptime gpu_meta.uniformFields(VertD);
        const frag_defines_fields = comptime gpu_meta.uniformFields(struct {});
        const S = struct {
            fn destroy(allocator: std.mem.Allocator) void {
                Prog.destroy(allocator);
            }
            fn instance(allocator: std.mem.Allocator, vert_bytes: []const u8, frag_bytes: ?[]const u8) anyerror!u32 {
                _ = frag_bytes;
                return Prog.instance(allocator, try bytesToDefines(VertD, vert_bytes));
            }
            fn use(allocator: std.mem.Allocator, vert_bytes: []const u8, frag_bytes: ?[]const u8) anyerror!void {
                _ = frag_bytes;
                try Prog.use(allocator, try bytesToDefines(VertD, vert_bytes));
            }
            fn getIdFor(vert_bytes: []const u8, frag_bytes: ?[]const u8) u32 {
                _ = frag_bytes;
                const vd = bytesToDefines(VertD, vert_bytes) catch return 0;
                if (Prog.getVariant(vd)) |v| return v.prog_id;
                return 0;
            }
            fn locateUniform(stage: UniformStage, field_id: u32, program: u32) gpu_meta.ResourceError!i32 {
                return locateProgramUniformByStage(vert_fields, frag_fields, stage, field_id, program);
            }
            fn uploadVert(program: u32, field_id: u32, want_type: usize, bytes: []const u8) gpu_meta.ResourceError!void {
                try uploadProgramField(vert_fields, field_id, program, want_type, bytes);
            }
            const vtable: VTable = .{
                .destroy_fn = @This().destroy,
                .instance_fn = @This().instance,
                .use_fn = @This().use,
                .get_id_for_fn = @This().getIdFor,
                .uniform_location_fn = @This().locateUniform,
                .upload_vert_fn = @This().uploadVert,
                .upload_frag_fn = null,
            };
        };
        return .{
            .vtable = &S.vtable,
            .vert_name = @typeName(Vert),
            .frag_name = null,
            .has_frag = false,
            .vert_uniform = comptime gpu_meta.describe(VertU),
            .frag_uniform = comptime gpu_meta.describe(struct {}),
            .vertex_inputs = comptime programVertexInputs(Vert),
            .vert_fields = vert_fields,
            .frag_fields = frag_fields,
            .vert_defines = comptime gpu_meta.describe(VertD),
            .frag_defines = comptime gpu_meta.describe(struct {}),
            .vert_defines_fields = vert_defines_fields,
            .frag_defines_fields = frag_defines_fields,
        };
    }

    /// Checks whether the record matches the given descriptor pair.
    /// Full programs only: use `matchesVertex` for vertex-only programs.
    /// Parameters:
    /// - self: record to check.
    /// - V: expected vertex descriptor type.
    /// - F: expected fragment descriptor type.
    ///
    /// Returns: true on descriptor match.
    pub fn matches(self: *const AnyProgram, comptime V: type, comptime F: type) bool {
        if (!self.has_frag) return false;
        if (!std.mem.eql(u8, self.vert_name, @typeName(V))) return false;
        const fname = self.frag_name orelse return false;
        if (!std.mem.eql(u8, fname, @typeName(F))) return false;
        return true;
    }

    /// Checks whether the record matches the given vertex descriptor
    /// and has no fragment stage.
    /// Parameters:
    /// - self: record to check.
    /// - V: expected vertex descriptor type.
    ///
    /// Returns: true on descriptor match.
    pub fn matchesVertex(self: *const AnyProgram, comptime V: type) bool {
        if (self.has_frag) return false;
        if (!std.mem.eql(u8, self.vert_name, @typeName(V))) return false;
        return true;
    }

    /// Destroys all linked variants.
    pub fn destroy(self: *const AnyProgram, allocator: std.mem.Allocator) void {
        self.vtable.destroy_fn(allocator);
    }
    /// Returns the program id for raw defines bytes, linking on first call.
    pub fn instance(self: *const AnyProgram, allocator: std.mem.Allocator, vert_defines_bytes: []const u8, frag_defines_bytes: ?[]const u8) anyerror!u32 {
        return self.vtable.instance_fn(allocator, vert_defines_bytes, frag_defines_bytes);
    }
    /// Binds the program variant for raw defines bytes. See `ShaderProgram.use`.
    pub fn use(self: *const AnyProgram, allocator: std.mem.Allocator, vert_defines_bytes: []const u8, frag_defines_bytes: ?[]const u8) anyerror!void {
        try self.vtable.use_fn(allocator, vert_defines_bytes, frag_defines_bytes);
    }
    /// Returns the linked variant id for defines bytes or 0.
    pub fn getIdFor(self: *const AnyProgram, vert_defines_bytes: []const u8, frag_defines_bytes: ?[]const u8) u32 {
        return self.vtable.get_id_for_fn(vert_defines_bytes, frag_defines_bytes);
    }
    /// Queries a live uniform location by stage + field id + explicit program.
    /// The program variant must be linked; the caller should cache the result.
    pub fn uniformLocation(self: *const AnyProgram, stage: UniformStage, field_id: u32, program: u32) gpu_meta.ResourceError!i32 {
        return self.vtable.uniform_location_fn(stage, field_id, program);
    }
    /// Resolves a vertex defines field id by name with a type check.
    pub fn getVertDefinesFieldId(self: *const AnyProgram, name: []const u8, comptime T: type) ?u32 {
        return self.vert_defines_fields.getId(name, T);
    }
    /// Resolves a fragment defines field id by name with a type check.
    pub fn getFragDefinesFieldId(self: *const AnyProgram, name: []const u8, comptime T: type) ?u32 {
        if (!self.has_frag) return null;
        return self.frag_defines_fields.getId(name, T);
    }
    /// Resolves a vertex uniform field id by name with a type check.
    /// Returns null when the field is missing or the type does not match.
    pub fn getVertUniformFieldId(self: *const AnyProgram, name: []const u8, comptime T: type) ?u32 {
        return self.vert_fields.getId(name, T);
    }
    /// Resolves a fragment uniform field id by name with a type check.
    /// Returns null when there is no fragment stage, the field is missing,
    /// or the type does not match.
    pub fn getFragUniformFieldId(self: *const AnyProgram, name: []const u8, comptime T: type) ?u32 {
        if (!self.has_frag) return null;
        return self.frag_fields.getId(name, T);
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
        /// Vertex uniform field table for validation.
        vert_fields: gpu_meta.UniformFields,
        /// Fragment uniform field table for validation.
        frag_fields: gpu_meta.UniformFields,
        /// Borrowed vertex field writes.
        _pending_vert: []const UniformFieldItem = &.{},
        /// Borrowed fragment field writes.
        _pending_frag: []const UniformFieldItem = &.{},

        /// Queues vertex uniform field writes for one `apply` batch.
        /// Parameters:
        /// - self: editor instance.
        /// - items: borrowed field writes applied in order.
        ///
        /// Returns: `*const Editor` for chaining.
        pub fn setVertUniformFields(self: *const Editor, items: []const UniformFieldItem) *const Editor {
            @constCast(self)._pending_vert = items;
            return @constCast(self);
        }
        /// Queues fragment uniform field writes for one `apply` batch.
        /// Parameters:
        /// - self: editor instance.
        /// - items: borrowed field writes applied in order.
        ///
        /// Returns: `*const Editor` for chaining.
        pub fn setFragUniformFields(self: *const Editor, items: []const UniformFieldItem) *const Editor {
            @constCast(self)._pending_frag = items;
            return @constCast(self);
        }
        /// Validates the whole batch, binds the variant once, uploads all.
        /// Parameters:
        /// - self: editor holding pending writes.
        /// - allocator: allocator for variant compilation.
        /// - vert_defines_bytes: raw `VertDefines` bytes.
        /// - frag_defines_bytes: raw `FragDefines` bytes (null for vertex-only).
        ///
        /// Returns: validation error before any GL call, if the batch is bad.
        pub fn apply(self: *const Editor, allocator: std.mem.Allocator, vert_defines_bytes: []const u8, frag_defines_bytes: ?[]const u8) anyerror!void {
            for (self._pending_vert) |it| try validateUniformItem(self.vert_fields, it, true);
            for (self._pending_frag) |it| {
                if (!self.rec.has_frag) return error.UnknownFieldId;
                try validateUniformItem(self.frag_fields, it, true);
            }
            const pid = try self.rec.vtable.instance_fn(allocator, vert_defines_bytes, frag_defines_bytes);
            gl.programs.use(pid);
            for (self._pending_vert) |it| try self.rec.vtable.upload_vert_fn(pid, it.field_id, it.type_id, it.bytes);
            if (self.rec.vtable.upload_frag_fn) |f| {
                for (self._pending_frag) |it| try f(pid, it.field_id, it.type_id, it.bytes);
            } else if (self._pending_frag.len > 0) return error.UnknownFieldId;
        }
    };

    /// Creates an `Editor` for batched uniform uploads.
    /// Parameters:
    /// - self: program record to edit (copied; immune to pool reallocations).
    ///
    /// Returns: initialized `Editor` with no pending writes.
    pub fn edit(self: *const AnyProgram) Editor {
        return .{ .rec = self.*, .vert_fields = self.vert_fields, .frag_fields = self.frag_fields };
    }
};

/// Type-erased view over a `Material` or `VertexMaterial` plain struct
/// (via `wrap` and `wrapVertex` respectively).
///
/// The record never owns the material: the instance lives with the caller
/// (stack, ECS storage, arena) and is only borrowed through `ptr`. There is
/// deliberately no destroy/create: materials are ordinary structs.
///
/// Field writes go through the CPU-side uniform cache (any field kind,
/// including samplers: validated by type id + size, uploaded on `use`),
/// so the record exposes the complete uniform functionality.
pub const AnyMaterial = struct {
    /// Virtual table with all type-erased thunks for `AnyMaterial`.
    pub const VTable = struct {
        /// Uploads cached uniforms for the cached defines. See `Material.use`.
        use_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror!void,
        /// Mutable byte view of the cached vertex uniform (`len == @sizeOf(VertU)`).
        /// The slice borrows the caller-owned instance; its address satisfies
        /// the vertex uniform alignment recorded in `vert_uniform`.
        vert_raw_fn: *const fn (*anyopaque) []u8,
        /// Mutable byte view of the cached fragment uniform, or null when the
        /// record has no fragment stage. Same borrow/alignment rules as `vert_raw_fn`.
        frag_raw_fn: *const fn (*anyopaque) ?[]u8,
        /// Mutable byte view of the cached vertex defines.
        vert_defines_raw_fn: *const fn (*anyopaque) []u8,
        /// Mutable byte view of the cached fragment defines, or null when absent.
        frag_defines_raw_fn: *const fn (*anyopaque) ?[]u8,
        /// Reads the bound material type's `render_order` const (see `Material.render_order`).
        get_render_order_fn: *const fn () i32,
    };

    /// Borrowed `*Material` instance, owned by the caller.
    ptr: *anyopaque,
    /// Pointer to the static per-type virtual table.
    vtable: *const VTable,
    /// `@typeName` of the bound shader program (identity for comparisons).
    program_name: []const u8,
    /// `@typeName` of the material type (identity for `cast`).
    material_name: []const u8,
    /// `@typeName` of the vertex descriptor.
    program_vert_name: []const u8,
    /// `@typeName` of the fragment descriptor, if any.
    program_frag_name: ?[]const u8,
    /// Whether a fragment stage is configured.
    has_frag: bool,
    /// Vertex shader input fields for mesh compatibility.
    vertex_inputs: []const gpu_meta.FieldDesc,
    /// Vertex `Uniform` description.
    vert_uniform: gpu_meta.TypeDesc,
    /// Fragment `Uniform` description (empty when no fragment stage).
    frag_uniform: gpu_meta.TypeDesc,
    /// Vertex uniform field table (static hash map + descriptors, `field_id` == index).
    vert_fields: gpu_meta.UniformFields,
    /// Fragment uniform field table (static hash map + descriptors, empty when no fragment stage).
    frag_fields: gpu_meta.UniformFields,
    /// Vertex `Define` description.
    vert_defines: gpu_meta.TypeDesc,
    /// Fragment `Define` description (empty when no fragment stage).
    frag_defines: gpu_meta.TypeDesc,
    /// Vertex defines field table.
    vert_defines_fields: gpu_meta.UniformFields,
    /// Fragment defines field table.
    frag_defines_fields: gpu_meta.UniformFields,

    /// Wraps a borrowed full material pointer. The record never takes ownership:
    /// the caller keeps owning the instance (stack, ECS storage, arena).
    /// Preferred entry point is `m.asAnyMaterial()` on the concrete type;
    /// this `wrap` is the underlying implementation.
    /// Parameters:
    /// - ptr: `*Material` for any full material struct type.
    ///
    /// Returns: type-erased record.
    pub fn wrap(ptr: anytype) AnyMaterial {
        const M = std.meta.Child(@TypeOf(ptr));
        if (!@hasDecl(M, "VertUniformT") or !@hasDecl(M, "FragUniformT") or !@hasDecl(M, "ShaderProgram")) @compileError("AnyMaterial.wrap expects a *Material struct pointer, got " ++ @typeName(@TypeOf(ptr)));
        const P = @TypeOf(ptr);
        const Prog = M.ShaderProgram;
        const VertU = M.VertUniformT;
        const FragU = M.FragUniformT;
        const vert_fields = comptime gpu_meta.uniformFields(VertU);
        const frag_fields = comptime gpu_meta.uniformFields(FragU);
        const vert_defines_fields = comptime gpu_meta.uniformFields(Prog.VertDefines);
        const frag_defines_fields = comptime gpu_meta.uniformFields(Prog.FragDefines);
        const S = struct {
            fn use(p: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
                const m: P = @ptrCast(@alignCast(p));
                try m.use(allocator);
            }
            fn vertRaw(p: *anyopaque) []u8 {
                const m: P = @ptrCast(@alignCast(p));
                return std.mem.asBytes(&m.vertUniform);
            }
            fn fragRaw(p: *anyopaque) ?[]u8 {
                const m: P = @ptrCast(@alignCast(p));
                return std.mem.asBytes(&m.fragUniform);
            }
            fn vertDefinesRaw(p: *anyopaque) []u8 {
                const m: P = @ptrCast(@alignCast(p));
                return std.mem.asBytes(&m.vertDefines);
            }
            fn fragDefinesRaw(p: *anyopaque) ?[]u8 {
                const m: P = @ptrCast(@alignCast(p));
                return std.mem.asBytes(&m.fragDefines);
            }
            fn getRenderOrder() i32 {
                if (@hasDecl(M, "render_order")) return M.render_order else return 0;
            }
            const vtable: VTable = .{
                .use_fn = @This().use,
                .vert_raw_fn = @This().vertRaw,
                .frag_raw_fn = @This().fragRaw,
                .vert_defines_raw_fn = @This().vertDefinesRaw,
                .frag_defines_raw_fn = @This().fragDefinesRaw,
                .get_render_order_fn = @This().getRenderOrder,
            };
        };
        return .{
            .ptr = ptr,
            .vtable = &S.vtable,
            .program_name = @typeName(Prog),
            .material_name = @typeName(M),
            .program_vert_name = @typeName(Prog.Vert),
            .program_frag_name = @typeName(Prog.Frag),
            .has_frag = true,
            .vertex_inputs = comptime programVertexInputs(Prog.Vert),
            .vert_uniform = comptime gpu_meta.describe(VertU),
            .frag_uniform = comptime gpu_meta.describe(FragU),
            .vert_fields = vert_fields,
            .frag_fields = frag_fields,
            .vert_defines = comptime gpu_meta.describe(Prog.VertDefines),
            .frag_defines = comptime gpu_meta.describe(Prog.FragDefines),
            .vert_defines_fields = vert_defines_fields,
            .frag_defines_fields = frag_defines_fields,
        };
    }

    /// Wraps a borrowed vertex-only material pointer. Same ownership rules as
    /// `wrap`; the fragment side is empty: `getFragUniformRaw` returns null and
    /// per-field fragment accesses report `UnknownFieldId`.
    /// Preferred entry point is `m.asAnyMaterial()` on the concrete type;
    /// this `wrapVertex` is the underlying implementation.
    /// Parameters:
    /// - ptr: `*VertexMaterial` for any vertex-only material struct type.
    ///
    /// Returns: type-erased record.
    pub fn wrapVertex(ptr: anytype) AnyMaterial {
        const M = std.meta.Child(@TypeOf(ptr));
        if (!@hasDecl(M, "VertUniformT") or !@hasDecl(M, "ShaderProgram")) @compileError("AnyMaterial.wrapVertex expects a *VertexMaterial struct pointer, got " ++ @typeName(@TypeOf(ptr)));
        const P = @TypeOf(ptr);
        const Prog = M.ShaderProgram;
        const VertU = M.VertUniformT;
        const vert_fields = comptime gpu_meta.uniformFields(VertU);
        const vert_defines_fields = comptime gpu_meta.uniformFields(Prog.VertDefines);
        const S = struct {
            fn use(p: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
                const m: P = @ptrCast(@alignCast(p));
                try m.use(allocator);
            }
            fn vertRaw(p: *anyopaque) []u8 {
                const m: P = @ptrCast(@alignCast(p));
                return std.mem.asBytes(&m.vertUniform);
            }
            fn fragRaw(_: *anyopaque) ?[]u8 {
                return null;
            }
            fn vertDefinesRaw(p: *anyopaque) []u8 {
                const m: P = @ptrCast(@alignCast(p));
                return std.mem.asBytes(&m.vertDefines);
            }
            fn fragDefinesRaw(_: *anyopaque) ?[]u8 {
                return null;
            }
            fn getRenderOrder() i32 {
                if (@hasDecl(M, "render_order")) return M.render_order else return 0;
            }
            const vtable: VTable = .{
                .use_fn = @This().use,
                .vert_raw_fn = @This().vertRaw,
                .frag_raw_fn = @This().fragRaw,
                .vert_defines_raw_fn = @This().vertDefinesRaw,
                .frag_defines_raw_fn = @This().fragDefinesRaw,
                .get_render_order_fn = @This().getRenderOrder,
            };
        };
        return .{
            .ptr = ptr,
            .vtable = &S.vtable,
            .program_name = @typeName(Prog),
            .material_name = @typeName(M),
            .program_vert_name = @typeName(Prog.Vert),
            .program_frag_name = null,
            .has_frag = false,
            .vertex_inputs = comptime programVertexInputs(Prog.Vert),
            .vert_uniform = comptime gpu_meta.describe(VertU),
            .frag_uniform = comptime gpu_meta.describe(struct {}),
            .vert_fields = vert_fields,
            .frag_fields = comptime gpu_meta.uniformFields(struct {}),
            .vert_defines = comptime gpu_meta.describe(Prog.VertDefines),
            .frag_defines = comptime gpu_meta.describe(struct {}),
            .vert_defines_fields = vert_defines_fields,
            .frag_defines_fields = comptime gpu_meta.uniformFields(struct {}),
        };
    }

    /// Downcasts back to a typed material. Returns null on type mismatch.
    /// Parameters:
    /// - self: record to downcast.
    /// - M: expected material struct type.
    ///
    /// Returns: `*M` or null.
    pub fn cast(self: *AnyMaterial, comptime M: type) ?*M {
        if (!std.mem.eql(u8, self.material_name, @typeName(M))) return null;
        return @ptrCast(@alignCast(self.ptr));
    }

    /// Binds the program variant for the cached defines and uploads uniforms.
    pub fn use(self: *AnyMaterial, allocator: std.mem.Allocator) anyerror!void {
        try self.vtable.use_fn(self.ptr, allocator);
    }
    /// Reads the bound material type's `render_order` const (set once at material
    /// creation; see `Material.render_order`). Returns 0 when the bound material
    /// type has no `render_order` const.
    pub fn getRenderOrder(self: *const AnyMaterial) i32 {
        return self.vtable.get_render_order_fn();
    }
    /// Mutable byte view of the cached vertex uniform of this instance.
    /// `len` is always `@sizeOf(VertUniform)` and the address satisfies the
    /// vertex uniform alignment from `vert_uniform`. The slice borrows the
    /// caller-owned instance: valid while the instance is alive. Reading is
    /// just not writing through the same slice; upload to GL happens via `use`.
    pub fn getVertUniformRaw(self: *AnyMaterial) []u8 {
        const raw = self.vtable.vert_raw_fn(self.ptr);
        std.debug.assert(raw.len == self.vert_uniform.size);
        std.debug.assert(std.mem.isAligned(@intFromPtr(raw.ptr), self.vert_uniform.alignment));
        return raw;
    }
    /// Mutable byte view of the cached fragment uniform of this instance,
    /// or null when there is no fragment stage. Same borrow/size/alignment
    /// rules as `getVertUniformRaw` (against `frag_uniform`).
    pub fn getFragUniformRaw(self: *AnyMaterial) ?[]u8 {
        if (!self.has_frag) return null;
        const raw = self.vtable.frag_raw_fn(self.ptr) orelse return null;
        std.debug.assert(raw.len == self.frag_uniform.size);
        std.debug.assert(std.mem.isAligned(@intFromPtr(raw.ptr), self.frag_uniform.alignment));
        return raw;
    }
    /// Resolves a vertex uniform field id by name with a type check via static hash map.
    /// Returns null when the field is missing or the type does not match.
    pub fn getVertUniformFieldId(self: *const AnyMaterial, name: []const u8, comptime T: type) ?u32 {
        return self.vert_fields.getId(name, T);
    }
    /// Resolves a fragment uniform field id by name with a type check via static hash map.
    /// Returns null when there is no fragment stage, the field is missing,
    /// or the type does not match.
    pub fn getFragUniformFieldId(self: *const AnyMaterial, name: []const u8, comptime T: type) ?u32 {
        if (!self.has_frag) return null;
        return self.frag_fields.getId(name, T);
    }
    /// Resolves a vertex defines field id by name with a type check.
    pub fn getVertDefinesFieldId(self: *const AnyMaterial, name: []const u8, comptime T: type) ?u32 {
        return self.vert_defines_fields.getId(name, T);
    }
    /// Resolves a fragment defines field id by name with a type check.
    pub fn getFragDefinesFieldId(self: *const AnyMaterial, name: []const u8, comptime T: type) ?u32 {
        if (!self.has_frag) return null;
        return self.frag_defines_fields.getId(name, T);
    }
    /// Mutable byte view of the cached vertex defines.
    pub fn getVertDefinesRaw(self: *AnyMaterial) []u8 {
        const raw = self.vtable.vert_defines_raw_fn(self.ptr);
        std.debug.assert(raw.len == self.vert_defines.size);
        return raw;
    }
    /// Mutable byte view of the cached fragment defines, or null when absent.
    pub fn getFragDefinesRaw(self: *AnyMaterial) ?[]u8 {
        if (!self.has_frag) return null;
        return self.vtable.frag_defines_raw_fn(self.ptr);
    }
    /// Writes one cached vertex uniform field by id (any kind, uploaded on `use`).
    /// Parameters:
    /// - field_id: id from `getVertUniformFieldId`.
    /// - data: value whose type must match the field type.
    ///
    /// Returns: `UnknownFieldId` or `FieldTypeMismatch`/`SizeMismatch` on failure.
    pub fn setVertUniformData(self: *AnyMaterial, field_id: u32, data: anytype) gpu_meta.ResourceError!void {
        if (field_id >= self.vert_fields.fields.len) return error.UnknownFieldId;
        const raw = self.vtable.vert_raw_fn(self.ptr);
        try gpu_meta.writeField(@ptrCast(raw.ptr), self.vert_fields.fields[field_id], gpu_meta.typeId(@TypeOf(data)), std.mem.asBytes(&data));
    }
    /// Reads one cached vertex uniform field by id.
    /// Parameters:
    /// - field_id: id from `getVertUniformFieldId`.
    /// - T: comptime expected field type.
    ///
    /// Returns: field value copy, or `UnknownFieldId`/`FieldTypeMismatch`/`SizeMismatch` on failure.
    pub fn getVertUniformData(self: *const AnyMaterial, field_id: u32, comptime T: type) gpu_meta.ResourceError!T {
        if (field_id >= self.vert_fields.fields.len) return error.UnknownFieldId;
        const raw = self.vtable.vert_raw_fn(self.ptr);
        var out: T = undefined;
        try gpu_meta.readField(@ptrCast(raw.ptr), self.vert_fields.fields[field_id], gpu_meta.typeId(T), std.mem.asBytes(&out));
        return out;
    }
    /// Writes one cached fragment uniform field by id (any kind, uploaded on `use`).
    /// Parameters:
    /// - field_id: id from `getFragUniformFieldId`.
    /// - data: value whose type must match the field type.
    ///
    /// Returns: `UnknownFieldId` or `FieldTypeMismatch`/`SizeMismatch` on failure.
    pub fn setFragUniformData(self: *AnyMaterial, field_id: u32, data: anytype) gpu_meta.ResourceError!void {
        if (!self.has_frag) return error.UnknownFieldId;
        if (field_id >= self.frag_fields.fields.len) return error.UnknownFieldId;
        const raw = self.vtable.frag_raw_fn(self.ptr) orelse return error.UnknownFieldId;
        try gpu_meta.writeField(@ptrCast(raw.ptr), self.frag_fields.fields[field_id], gpu_meta.typeId(@TypeOf(data)), std.mem.asBytes(&data));
    }
    /// Reads one cached fragment uniform field by id.
    /// Parameters:
    /// - field_id: id from `getFragUniformFieldId`.
    /// - T: comptime expected field type.
    ///
    /// Returns: field value copy, or `UnknownFieldId`/`FieldTypeMismatch`/`SizeMismatch` on failure.
    pub fn getFragUniformData(self: *const AnyMaterial, field_id: u32, comptime T: type) gpu_meta.ResourceError!T {
        if (!self.has_frag) return error.UnknownFieldId;
        if (field_id >= self.frag_fields.fields.len) return error.UnknownFieldId;
        const raw = self.vtable.frag_raw_fn(self.ptr) orelse return error.UnknownFieldId;
        var out: T = undefined;
        try gpu_meta.readField(@ptrCast(raw.ptr), self.frag_fields.fields[field_id], gpu_meta.typeId(T), std.mem.asBytes(&out));
        return out;
    }
    /// Writes one cached uniform field by pre-resolved ids, trying the vertex
    /// stage first and then the fragment stage. Each non-null id is written
    /// independently: a failure on one stage does not block the other.
    /// Parameters:
    /// - vert_field_id: id from `getVertUniformFieldId`, or null to skip vert.
    /// - frag_field_id: id from `getFragUniformFieldId`, or null to skip frag.
    /// - data: value whose type must match the field type.
    ///
    /// Returns: true when at least one stage was written, false otherwise
    /// (both ids null, or no write succeeded).
    pub fn trySetUniformDataById(self: *AnyMaterial, vert_field_id: ?u32, frag_field_id: ?u32, data: anytype) bool {
        var written = false;
        if (vert_field_id) |id| {
            blk: {
                self.setVertUniformData(id, data) catch break :blk;
                written = true;
            }
        }
        if (frag_field_id) |id| {
            blk: {
                self.setFragUniformData(id, data) catch break :blk;
                written = true;
            }
        }
        return written;
    }
    /// Writes a cached uniform field by name to every stage that declares it
    /// with a matching type (vertex and/or fragment). Convenience wrapper over
    /// `getVertUniformFieldId`/`getFragUniformFieldId` plus `trySetUniformDataById`,
    /// so callers no longer need the `if (getId) |id| { try setData }` pattern
    /// per stage.
    /// Parameters:
    /// - name: uniform field name looked up in both stages.
    /// - data: value whose type must match the field type; `@TypeOf(data)`
    ///   is used for the id lookup.
    ///
    /// Returns: true when at least one stage was written, false when the name
    /// is missing on both stages (or its type does not match).
    pub fn trySetUniformDataByName(self: *AnyMaterial, name: []const u8, data: anytype) bool {
        const T = @TypeOf(data);
        return self.trySetUniformDataById(self.getVertUniformFieldId(name, T), self.getFragUniformFieldId(name, T), data);
    }
    /// Writes one cached vertex defines field by id (uploaded on `use` via variant).
    pub fn setVertDefinesData(self: *AnyMaterial, field_id: u32, data: anytype) gpu_meta.ResourceError!void {
        if (field_id >= self.vert_defines_fields.fields.len) return error.UnknownFieldId;
        const raw = self.vtable.vert_defines_raw_fn(self.ptr);
        try gpu_meta.writeField(@ptrCast(raw.ptr), self.vert_defines_fields.fields[field_id], gpu_meta.typeId(@TypeOf(data)), std.mem.asBytes(&data));
    }
    /// Reads one cached vertex defines field by id.
    pub fn getVertDefinesData(self: *const AnyMaterial, field_id: u32, comptime T: type) gpu_meta.ResourceError!T {
        if (field_id >= self.vert_defines_fields.fields.len) return error.UnknownFieldId;
        const raw = self.vtable.vert_defines_raw_fn(self.ptr);
        var out: T = undefined;
        try gpu_meta.readField(@ptrCast(raw.ptr), self.vert_defines_fields.fields[field_id], gpu_meta.typeId(T), std.mem.asBytes(&out));
        return out;
    }
    /// Writes one cached fragment defines field by id.
    pub fn setFragDefinesData(self: *AnyMaterial, field_id: u32, data: anytype) gpu_meta.ResourceError!void {
        if (!self.has_frag) return error.UnknownFieldId;
        if (field_id >= self.frag_defines_fields.fields.len) return error.UnknownFieldId;
        const raw = self.vtable.frag_defines_raw_fn(self.ptr) orelse return error.UnknownFieldId;
        try gpu_meta.writeField(@ptrCast(raw.ptr), self.frag_defines_fields.fields[field_id], gpu_meta.typeId(@TypeOf(data)), std.mem.asBytes(&data));
    }
    /// Reads one cached fragment defines field by id.
    pub fn getFragDefinesData(self: *const AnyMaterial, field_id: u32, comptime T: type) gpu_meta.ResourceError!T {
        if (!self.has_frag) return error.UnknownFieldId;
        if (field_id >= self.frag_defines_fields.fields.len) return error.UnknownFieldId;
        const raw = self.vtable.frag_defines_raw_fn(self.ptr) orelse return error.UnknownFieldId;
        var out: T = undefined;
        try gpu_meta.readField(@ptrCast(raw.ptr), self.frag_defines_fields.fields[field_id], gpu_meta.typeId(T), std.mem.asBytes(&out));
        return out;
    }

    /// Batched writer for the CPU-side uniform cache.
    ///
    /// Single-field immediate writes (`setVertUniformData` / `setFragUniformData`)
    /// each do a read-modify-write of the whole cached struct. The editor
    /// validates the WHOLE batch first, then commits everything, so a bad item
    /// leaves the cache untouched (atomic commit). Upload to GL still happens
    /// explicitly via `use` — the cache batching is the edit/apply equivalent.
    pub const Editor = struct {
        /// Record copy: borrows the caller-owned material instance.
        rec: AnyMaterial,
        /// Vertex uniform field table for validation.
        vert_fields: gpu_meta.UniformFields,
        /// Fragment uniform field table for validation.
        frag_fields: gpu_meta.UniformFields,
        /// Borrowed vertex field writes.
        _pending_vert: []const UniformFieldItem = &.{},
        /// Borrowed fragment field writes.
        _pending_frag: []const UniformFieldItem = &.{},

        /// Queues cached vertex uniform writes for one atomic `apply`.
        /// Parameters:
        /// - self: editor instance.
        /// - items: borrowed field writes applied in order.
        ///
        /// Returns: `*const Editor` for chaining.
        pub fn setVertUniformFields(self: *const Editor, items: []const UniformFieldItem) *const Editor {
            @constCast(self)._pending_vert = items;
            return @constCast(self);
        }
        /// Queues cached fragment uniform writes for one atomic `apply`.
        /// Parameters:
        /// - self: editor instance.
        /// - items: borrowed field writes applied in order.
        ///
        /// Returns: `*const Editor` for chaining.
        pub fn setFragUniformFields(self: *const Editor, items: []const UniformFieldItem) *const Editor {
            @constCast(self)._pending_frag = items;
            return @constCast(self);
        }
        /// Validates the whole batch, then commits all writes atomically.
        /// Parameters:
        /// - self: editor holding pending writes.
        ///
        /// Returns: validation error with the cache untouched, if the batch is bad.
        pub fn apply(self: *const Editor) gpu_meta.ResourceError!void {
            for (self._pending_vert) |it| try validateUniformItem(self.vert_fields, it, false);
            for (self._pending_frag) |it| try validateUniformItem(self.frag_fields, it, false);
            // NOTE: no `kind != .other` restriction here (unlike the program
            // editor): cache writes are plain memcpys, any field kind works.
            // Field writes go straight into the borrowed instance bytes
            // (same path as setVertUniformData/setFragUniformData).
            if (self._pending_vert.len > 0) {
                const vert_raw = self.rec.vtable.vert_raw_fn(self.rec.ptr);
                for (self._pending_vert) |it| try gpu_meta.writeField(@ptrCast(vert_raw.ptr), self.vert_fields.fields[it.field_id], it.type_id, it.bytes);
            }
            if (self._pending_frag.len > 0) {
                const frag_raw = (self.rec.vtable.frag_raw_fn(self.rec.ptr)) orelse return error.UnknownFieldId;
                for (self._pending_frag) |it| try gpu_meta.writeField(@ptrCast(frag_raw.ptr), self.frag_fields.fields[it.field_id], it.type_id, it.bytes);
            }
        }
    };

    /// Creates an `Editor` for atomic cache writes.
    /// Parameters:
    /// - self: material record to edit (copied; immune to pool reallocations).
    ///
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
///
/// Returns: true on compatibility.
pub fn meshAcceptsProgram(mesh: *const AnyMesh, prog: *const AnyProgram) bool {
    return gpu_meta.fieldsSatisfiedBy(prog.vertex_inputs, mesh.vertex.fields);
}

/// Checks whether a material fits a mesh: the material's program vertex
/// inputs must be satisfied by the mesh vertex fields.
/// Parameters:
/// - mat: type-erased material.
/// - mesh: type-erased mesh.
///
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
    // NOTE: only struct types are valid vertices (`Mesh` rejects the rest at
    // comptime), so mismatch is probed with a different struct, not `u32`.
    try std.testing.expect(rec.cast(struct { nope: u8 }) == null);
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
    const prog_vtable: AnyProgram.VTable = .{
        .destroy_fn = struct {
            fn f(_: std.mem.Allocator) void {}
        }.f,
        .instance_fn = struct {
            fn f(_: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror!u32 {
                return 0;
            }
        }.f,
        .use_fn = struct {
            fn f(_: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror!void {}
        }.f,
        .get_id_for_fn = struct {
            fn f(_: []const u8, _: ?[]const u8) u32 {
                return 0;
            }
        }.f,
        .uniform_location_fn = struct {
            fn f(_: UniformStage, _: u32, _: u32) gpu_meta.ResourceError!i32 {
                return -1;
            }
        }.f,
        .upload_vert_fn = struct {
            fn f(_: u32, _: u32, _: usize, _: []const u8) gpu_meta.ResourceError!void {}
        }.f,
        .upload_frag_fn = null,
    };
    const prog_rec = AnyProgram{
        .vtable = &prog_vtable,
        .vert_name = @typeName(ShaderVert),
        .frag_name = null,
        .has_frag = false,
        .vert_uniform = comptime gpu_meta.describe(ShaderVert.Uniform),
        .frag_uniform = comptime gpu_meta.describe(struct {}),
        .vertex_inputs = inputs,
        .vert_fields = comptime gpu_meta.uniformFields(ShaderVert.Uniform),
        .frag_fields = comptime gpu_meta.uniformFields(struct {}),
        .vert_defines = comptime gpu_meta.describe(struct {}),
        .frag_defines = comptime gpu_meta.describe(struct {}),
        .vert_defines_fields = comptime gpu_meta.uniformFields(struct {}),
        .frag_defines_fields = comptime gpu_meta.uniformFields(struct {}),
    };
    try std.testing.expect(meshAcceptsProgram(&mesh_rec, &prog_rec));

    const BadVert = struct {
        pub const Vertex = struct { position: math.Vec(3, f32), normal: math.Vec(3, f32) };
        pub const Uniform = struct {};
    };
    var bad_rec = prog_rec;
    bad_rec.vertex_inputs = comptime gpu_meta.describe(BadVert.Vertex).fields;
    try std.testing.expect(!meshAcceptsProgram(&mesh_rec, &bad_rec));

    const mat_vtable: AnyMaterial.VTable = undefined;
    var mat_rec = AnyMaterial{
        .ptr = @ptrFromInt(0x10),
        .vtable = &mat_vtable,
        .program_name = "TestProg",
        .material_name = "TestMat",
        .program_vert_name = @typeName(ShaderVert),
        .program_frag_name = null,
        .has_frag = false,
        .vertex_inputs = inputs,
        .vert_uniform = comptime gpu_meta.describe(ShaderVert.Uniform),
        .frag_uniform = comptime gpu_meta.describe(struct {}),
        .vert_fields = comptime gpu_meta.uniformFields(ShaderVert.Uniform),
        .frag_fields = comptime gpu_meta.uniformFields(struct {}),
        .vert_defines = comptime gpu_meta.describe(struct {}),
        .frag_defines = comptime gpu_meta.describe(struct {}),
        .vert_defines_fields = comptime gpu_meta.uniformFields(struct {}),
        .frag_defines_fields = comptime gpu_meta.uniformFields(struct {}),
    };
    try std.testing.expect(materialAcceptsMesh(&mat_rec, &mesh_rec));
    mat_rec.vertex_inputs = comptime gpu_meta.describe(BadVert.Vertex).fields;
    try std.testing.expect(!materialAcceptsMesh(&mat_rec, &mesh_rec));
}

// Minimal fake programs: quack like `ShaderProgram(Vert, Frag)` and
// `VertexProgram(Vert)` but touch no GL, so `AnyProgram.wrap`/`wrapVertex`
// and all non-GL paths are testable without a context.
const FakeVertP = struct {
    pub const Vertex = struct { aPos: [3]f32 };
    pub const Uniform = struct { uScale: f32, uTex: *const u8 };
    pub const Define = struct {};
};
const FakeFragP = struct {
    pub const Uniform = struct { uColor: f32 };
    pub const Define = struct {};
};
const FakeProgramP = struct {
    pub const HasFrag = true;
    pub const Vert = FakeVertP;
    pub const Frag = FakeFragP;
    pub const VertDefines = FakeVertP.Define;
    pub const FragDefines = FakeFragP.Define;
    pub const ProgramDefines = struct { vert: VertDefines, frag: FragDefines };
    pub const Variant = struct { prog_id: u32 };
    var id: u32 = 42;
    pub fn instance(_: std.mem.Allocator, _: VertDefines, _: FragDefines) !u32 {
        return id;
    }
    pub fn getVariant(_: ProgramDefines) ?Variant {
        return .{ .prog_id = id };
    }
    pub fn use(_: std.mem.Allocator, _: VertDefines, _: FragDefines) !void {}
    pub fn destroy(_: std.mem.Allocator) void {
        id = 0;
    }
};
const FakeProgramNoFrag = struct {
    pub const HasFrag = false;
    pub const Vert = FakeVertP;
    pub const VertDefines = FakeVertP.Define;
    pub const ProgramDefines = VertDefines;
    pub const Variant = struct { prog_id: u32 };
    var id: u32 = 1;
    pub fn instance(_: std.mem.Allocator, _: VertDefines) !u32 {
        return id;
    }
    pub fn getVariant(_: ProgramDefines) ?Variant {
        return .{ .prog_id = id };
    }
    pub fn use(_: std.mem.Allocator, _: VertDefines) !void {}
    pub fn destroy(_: std.mem.Allocator) void {
        id = 0;
    }
};

// Minimal fake materials: plain structs like `Material`/`VertexMaterial`
// (no create/destroy), so the full `AnyMaterial` API
// (wrap/wrapVertex/cast/fields/cache/Editor) is testable.
const FakeVertU = struct { uMvp: f32, uFlag: bool, uTex: ?*const u8 = null };
const FakeFragU = struct { uColor: f32 };
const FakeProgVertex = struct {
    pub const Vert = struct {
        pub const Vertex = struct { position: [3]f32 };
        pub const Define = struct {};
    };
    pub const VertDefines = Vert.Define;
    pub const HasFrag = false;
    var id: u32 = 9;
    pub fn instance(_: std.mem.Allocator, _: VertDefines) !u32 {
        return id;
    }
    pub fn use(_: std.mem.Allocator, _: VertDefines) !void {}
    pub fn destroy(_: std.mem.Allocator) void {
        id = 0;
    }
};
const FakeProgM = struct {
    pub const Vert = struct {
        pub const Vertex = struct { position: [3]f32 };
        pub const Define = struct {};
    };
    pub const VertDefines = Vert.Define;
    pub const FragDefines = FakeFragP.Define;
    pub const Frag = FakeFragP;
    pub const HasFrag = false;
    var id: u32 = 7;
    pub fn instance(_: std.mem.Allocator, _: VertDefines, _: FragDefines) !u32 {
        return id;
    }
    pub fn use(_: std.mem.Allocator, _: VertDefines, _: FragDefines) !void {}
    pub fn destroy(_: std.mem.Allocator) void {
        id = 0;
    }
};
const FakeMat = struct {
    pub const VertUniformT = FakeVertU;
    pub const FragUniformT = FakeFragU;
    pub const ShaderProgram = FakeProgM;
    vertUniform: FakeVertU,
    fragUniform: FakeFragU,
    vertDefines: FakeProgM.VertDefines = .{},
    fragDefines: FakeProgM.FragDefines = .{},
    used: bool = false,
    pub fn use(self: *@This(), _: std.mem.Allocator) !void {
        self.used = true;
    }
};
const FakeVertMat = struct {
    pub const VertUniformT = FakeVertU;
    pub const ShaderProgram = FakeProgVertex;
    vertUniform: FakeVertU,
    vertDefines: FakeProgVertex.VertDefines = .{},
    used: bool = false,
    pub fn use(self: *@This(), _: std.mem.Allocator) !void {
        self.used = true;
    }
};

test "any program wrap/meta/validation without GL" {
    const alloc = std.testing.allocator;
    var rec = AnyProgram.wrap(FakeProgramP);
    defer rec.destroy(alloc);

    try std.testing.expectEqualStrings(@typeName(FakeVertP), rec.vert_name);
    try std.testing.expect(rec.has_frag);
    try std.testing.expectEqualStrings(@typeName(FakeFragP), rec.frag_name.?);
    const empty_vert: [@sizeOf(FakeProgramP.VertDefines)]u8 = @splat(0);
    const empty_frag: [@sizeOf(FakeProgramP.FragDefines)]u8 = @splat(0);
    try std.testing.expectEqual(@as(u32, 42), try rec.instance(alloc, &empty_vert, &empty_frag));
    try std.testing.expectEqual(@as(u32, 42), rec.getIdFor(&empty_vert, &empty_frag));
    try std.testing.expectEqual(@as(usize, 1), rec.vertex_inputs.len);
    try std.testing.expectEqual(@as(usize, 2), rec.vert_fields.fields.len);
    try std.testing.expectEqual(@as(usize, 1), rec.frag_fields.fields.len);

    try std.testing.expect(rec.matches(FakeVertP, FakeFragP));
    try std.testing.expect(!rec.matchesVertex(FakeVertP));
    try std.testing.expect(!rec.matches(FakeFragP, FakeFragP));

    const tid_f32 = gpu_meta.typeId(f32);
    const id_scale = rec.getVertUniformFieldId("uScale", f32) orelse unreachable;
    try std.testing.expectEqual(@as(u32, 0), id_scale);
    try std.testing.expect(rec.getVertUniformFieldId("nope", f32) == null);
    try std.testing.expect(rec.getVertUniformFieldId("uScale", i32) == null);

    // error paths return before any GL call (all uploads go through Editor)
    const bad_id = [_]UniformFieldItem{.{ .field_id = 99, .type_id = tid_f32, .bytes = std.mem.asBytes(&id_scale) }};
    try std.testing.expectError(error.UnknownFieldId, rec.edit().setVertUniformFields(&bad_id).apply(alloc, &empty_vert, &empty_frag));
    const tid_tex = gpu_meta.typeId(*const u8);
    const id_tex = rec.getVertUniformFieldId("uTex", *const u8) orelse unreachable;
    const bad_kind = [_]UniformFieldItem{.{ .field_id = id_tex, .type_id = tid_tex, .bytes = "x" }};
    try std.testing.expectError(error.UnsupportedUniformField, rec.edit().setVertUniformFields(&bad_kind).apply(alloc, &empty_vert, &empty_frag));

    // vertex-only program: frag lookup returns null when there is no fragment stage
    var rec2 = AnyProgram.wrapVertex(FakeProgramNoFrag);
    defer rec2.destroy(alloc);
    try std.testing.expect(!rec2.has_frag);
    try std.testing.expect(rec2.matchesVertex(FakeVertP));
    try std.testing.expect(!rec2.matchesVertex(FakeFragP));
    try std.testing.expect(rec2.getFragUniformFieldId("uColor", f32) == null);
    const bad_frag = [_]UniformFieldItem{.{ .field_id = 0, .type_id = tid_f32, .bytes = std.mem.asBytes(&id_scale) }};
    try std.testing.expectError(error.UnknownFieldId, rec2.edit().setFragUniformFields(&bad_frag).apply(alloc, &empty_vert, null));
}

test "any material wrap/fields/cache/editor without GL" {
    const alloc = std.testing.allocator;
    var m: FakeMat = .{ .vertUniform = .{ .uMvp = 1.0, .uFlag = false }, .fragUniform = .{ .uColor = 0.5 }, .used = false };
    var rec = AnyMaterial.wrap(&m);

    try std.testing.expectEqualStrings(@typeName(FakeProgM), rec.program_name);
    try std.testing.expect(rec.cast(FakeMat) == &m);
    try std.testing.expect(rec.cast(struct {}) == null);

    const tid_f32 = gpu_meta.typeId(f32);
    const tid_bool = gpu_meta.typeId(bool);
    const id_mvp = rec.getVertUniformFieldId("uMvp", f32) orelse unreachable;
    const id_flag = rec.getVertUniformFieldId("uFlag", bool) orelse unreachable;
    const two: f32 = 2.0;
    try rec.setVertUniformData(id_mvp, two);
    try std.testing.expectEqual(@as(f32, 2.0), try rec.getVertUniformData(id_mvp, f32));
    try std.testing.expect(rec.getVertUniformFieldId("nope", f32) == null);
    try std.testing.expect(rec.getVertUniformFieldId("uMvp", bool) == null);
    try std.testing.expectError(error.UnknownFieldId, rec.setVertUniformData(99, two));
    try std.testing.expectError(error.FieldTypeMismatch, rec.setVertUniformData(id_mvp, true));
    try std.testing.expectError(error.FieldTypeMismatch, rec.getVertUniformData(id_mvp, bool));

    // whole-cache access via mutable raw slice (same memory as the instance).
    {
        const raw = rec.getVertUniformRaw();
        try std.testing.expectEqual(@sizeOf(FakeVertU), raw.len);
        try std.testing.expect(std.mem.isAligned(@intFromPtr(raw.ptr), @alignOf(FakeVertU)));
        var cache: [@sizeOf(FakeVertU)]u8 = undefined;
        @memcpy(cache[0..], raw);
        var altered = cache;
        altered[0] ^= 0xFF;
        @memcpy(raw, altered[0..]);
        try std.testing.expectEqualSlices(u8, altered[0..], rec.getVertUniformRaw());
        @memcpy(rec.getVertUniformRaw(), cache[0..]);
    }
    // frag raw is present for full materials.
    {
        const frag_raw = rec.getFragUniformRaw().?;
        try std.testing.expectEqual(@sizeOf(FakeFragU), frag_raw.len);
        try std.testing.expect(std.mem.isAligned(@intFromPtr(frag_raw.ptr), @alignOf(FakeFragU)));
    }

    // editor: failed batch leaves the cache untouched (atomic commit)
    var three: f32 = 3.0;
    const e = rec.edit();
    _ = e.setVertUniformFields(&.{
        .{ .field_id = id_mvp, .type_id = tid_f32, .bytes = std.mem.asBytes(&three) },
        .{ .field_id = 99, .type_id = tid_f32, .bytes = std.mem.asBytes(&three) },
    });
    try std.testing.expectError(error.UnknownFieldId, e.apply());
    try std.testing.expectEqual(@as(f32, 2.0), try rec.getVertUniformData(id_mvp, f32));

    // editor: successful batch commits everything, still no GL involved
    const e2 = rec.edit();
    var flag_on: bool = true;
    _ = e2.setVertUniformFields(&.{
        .{ .field_id = id_mvp, .type_id = tid_f32, .bytes = std.mem.asBytes(&three) },
        .{ .field_id = id_flag, .type_id = tid_bool, .bytes = std.mem.asBytes(&flag_on) },
    });
    const id_color = rec.getFragUniformFieldId("uColor", f32) orelse unreachable;
    var color: f32 = 0.25;
    _ = e2.setFragUniformFields(&.{.{ .field_id = id_color, .type_id = tid_f32, .bytes = std.mem.asBytes(&color) }});
    try e2.apply();
    try std.testing.expectEqual(@as(f32, 3.0), try rec.getVertUniformData(id_mvp, f32));
    try std.testing.expect(try rec.getVertUniformData(id_flag, bool));

    // Nullable resource field: defaults to null, roundtrips null and non-null.
    try std.testing.expect(m.vertUniform.uTex == null);
    const id_tex = rec.getVertUniformFieldId("uTex", ?*const u8) orelse unreachable;
    try std.testing.expect(rec.getVertUniformRaw().len == @sizeOf(FakeVertU));
    try rec.setVertUniformData(id_tex, @as(?*const u8, null));
    try std.testing.expect((try rec.getVertUniformData(id_tex, ?*const u8)) == null);
    var xb: u8 = 9;
    try rec.setVertUniformData(id_tex, @as(?*const u8, &xb));
    try std.testing.expectEqual(@as(u8, 9), (try rec.getVertUniformData(id_tex, ?*const u8)).?.*);

    try rec.use(alloc);
    try std.testing.expect(m.used);
}

test "any vertex material wrap without GL" {
    const alloc = std.testing.allocator;
    var m: FakeVertMat = .{ .vertUniform = .{ .uMvp = 1.0, .uFlag = true }, .used = false };
    var rec = AnyMaterial.wrapVertex(&m);
    try std.testing.expect(!rec.has_frag);
    try std.testing.expect(rec.cast(FakeVertMat) == &m);
    try std.testing.expect(rec.cast(FakeMat) == null);

    const id_mvp = rec.getVertUniformFieldId("uMvp", f32) orelse unreachable;
    const two: f32 = 2.0;
    try rec.setVertUniformData(id_mvp, two);
    try std.testing.expectEqual(@as(f32, 2.0), try rec.getVertUniformData(id_mvp, f32));

    // whole-cache access via mutable raw slice on the vertex side.
    {
        const raw = rec.getVertUniformRaw();
        try std.testing.expectEqual(@sizeOf(FakeVertU), raw.len);
        try std.testing.expect(std.mem.isAligned(@intFromPtr(raw.ptr), @alignOf(FakeVertU)));
        var cache: [@sizeOf(FakeVertU)]u8 = undefined;
        @memcpy(cache[0..], raw);
    }

    // fragment raw is null when there is no fragment stage;
    // other fragment accesses still report UnknownFieldId.
    try std.testing.expect(rec.getFragUniformFieldId("uColor", f32) == null);
    try std.testing.expect(rec.getFragUniformRaw() == null);
    try std.testing.expectError(error.UnknownFieldId, rec.setFragUniformData(0, two));
    try std.testing.expectError(error.UnknownFieldId, rec.getFragUniformData(0, f32));

    try rec.use(alloc);
    try std.testing.expect(m.used);
}

test "any material trySetUniform helpers without GL" {
    // Full material: ByName writes only the stage(s) declaring the name.
    var m: FakeMat = .{ .vertUniform = .{ .uMvp = 1.0, .uFlag = false }, .fragUniform = .{ .uColor = 0.5 }, .used = false };
    var rec = AnyMaterial.wrap(&m);

    // Vert-only name: writes vert, leaves frag untouched.
    try std.testing.expect(rec.trySetUniformDataByName("uMvp", @as(f32, 2.0)));
    try std.testing.expectEqual(@as(f32, 2.0), m.vertUniform.uMvp);
    try std.testing.expectEqual(@as(f32, 0.5), m.fragUniform.uColor);

    // Frag-only name: writes frag.
    try std.testing.expect(rec.trySetUniformDataByName("uColor", @as(f32, 0.25)));
    try std.testing.expectEqual(@as(f32, 0.25), m.fragUniform.uColor);

    // Missing name and type mismatch: no write, false.
    try std.testing.expect(!rec.trySetUniformDataByName("nope", @as(f32, 1.0)));
    try std.testing.expect(!rec.trySetUniformDataByName("uMvp", true));
    try std.testing.expectEqual(@as(f32, 2.0), m.vertUniform.uMvp);

    // ById with pre-resolved ids: one stage, both null, bad id, type mismatch.
    const v_mvp = rec.getVertUniformFieldId("uMvp", f32);
    const f_color = rec.getFragUniformFieldId("uColor", f32);
    try std.testing.expect(rec.trySetUniformDataById(v_mvp, null, @as(f32, 3.0)));
    try std.testing.expectEqual(@as(f32, 3.0), m.vertUniform.uMvp);
    try std.testing.expect(rec.trySetUniformDataById(null, f_color, @as(f32, 0.75)));
    try std.testing.expectEqual(@as(f32, 0.75), m.fragUniform.uColor);
    try std.testing.expect(!rec.trySetUniformDataById(null, null, @as(f32, 9.0)));
    try std.testing.expect(!rec.trySetUniformDataById(99, null, @as(f32, 9.0)));
    try std.testing.expect(!rec.trySetUniformDataById(v_mvp, null, true));
    try std.testing.expectEqual(@as(f32, 3.0), m.vertUniform.uMvp);

    // Broadcast: the same name in both stages is written twice by one call.
    const SharedVertU = struct { uMvp: f32 };
    const SharedFragU = struct { uMvp: f32 };
    const SharedMat = struct {
        pub const VertUniformT = SharedVertU;
        pub const FragUniformT = SharedFragU;
        pub const ShaderProgram = FakeProgM;
        vertUniform: SharedVertU,
        fragUniform: SharedFragU,
        vertDefines: FakeProgM.VertDefines = .{},
        fragDefines: FakeProgM.FragDefines = .{},
        used: bool = false,
        pub fn use(self: *@This(), _: std.mem.Allocator) !void {
            self.used = true;
        }
    };
    var sm: SharedMat = .{ .vertUniform = .{ .uMvp = 1.0 }, .fragUniform = .{ .uMvp = 1.0 } };
    var srec = AnyMaterial.wrap(&sm);
    try std.testing.expect(srec.trySetUniformDataByName("uMvp", @as(f32, 7.0)));
    try std.testing.expectEqual(@as(f32, 7.0), sm.vertUniform.uMvp);
    try std.testing.expectEqual(@as(f32, 7.0), sm.fragUniform.uMvp);
    try std.testing.expect(srec.trySetUniformDataById(
        srec.getVertUniformFieldId("uMvp", f32),
        srec.getFragUniformFieldId("uMvp", f32),
        @as(f32, 8.0),
    ));
    try std.testing.expectEqual(@as(f32, 8.0), sm.vertUniform.uMvp);
    try std.testing.expectEqual(@as(f32, 8.0), sm.fragUniform.uMvp);

    // Vertex-only material: frag side is skipped, vert still writes.
    var vm: FakeVertMat = .{ .vertUniform = .{ .uMvp = 1.0, .uFlag = true }, .used = false };
    var vrec = AnyMaterial.wrapVertex(&vm);
    try std.testing.expect(vrec.trySetUniformDataByName("uMvp", @as(f32, 4.0)));
    try std.testing.expectEqual(@as(f32, 4.0), vm.vertUniform.uMvp);
    try std.testing.expect(!vrec.trySetUniformDataByName("uColor", @as(f32, 1.0)));
    try std.testing.expect(vrec.trySetUniformDataById(vrec.getVertUniformFieldId("uMvp", f32), null, @as(f32, 5.0)));
    try std.testing.expectEqual(@as(f32, 5.0), vm.vertUniform.uMvp);
}

test "asAny forwarders on concrete types without GL" {
    const alloc = std.testing.allocator;

    const B = Buffer(f32);
    const buf = try B.create(alloc);
    defer buf.destroy(alloc);
    var brec = buf.asAnyBuffer();
    try std.testing.expect(brec.cast(f32) == buf);
    try std.testing.expect(brec.cast(u16) == null);

    const math = @import("math");
    const V = struct { pos: math.Vec(3, f32) };
    const M = Mesh(V);
    const mesh = try M.create(alloc);
    defer mesh.destroy(alloc);
    var mrec = mesh.asAnyMesh();
    try std.testing.expect(mrec.cast(V) == mesh);
    // NOTE: only struct types are valid vertices, so mismatch is probed
    // with a different struct rather than a scalar.
    try std.testing.expect(mrec.cast(struct { nope: u8 }) == null);

    // Programs are variant caches: referencing the forwarder decl
    // monomorphizes its body (and the wrap call) without executing any GL.
    const VD = struct {
        pub const Uniform = struct { uA: f32 };
        pub const IdCache = struct { uA: i32 };
        pub const Define = struct {};
        pub const Editor = struct {
            pub fn setUniform(self: *@This(), u: Uniform) *@This() {
                _ = u;
                return self;
            }
            pub fn apply(self: *@This()) void {
                _ = self;
            }
        };
        pub fn instance(_: std.mem.Allocator, _: Define) !u32 {
            return 0;
        }
        pub fn destroy(_: std.mem.Allocator) void {}
        pub fn edit(_: u32) Editor {
            return .{};
        }
    };
    const FD = struct {
        pub const Uniform = struct { uB: f32 };
        pub const IdCache = struct { uB: i32 };
        pub const Define = struct {};
        pub const Editor = struct {
            pub fn setUniform(self: *@This(), u: Uniform) *@This() {
                _ = u;
                return self;
            }
            pub fn apply(self: *@This()) void {
                _ = self;
            }
        };
        pub fn instance(_: std.mem.Allocator, _: Define) !u32 {
            return 0;
        }
        pub fn destroy(_: std.mem.Allocator) void {}
        pub fn edit(_: u32) Editor {
            return .{};
        }
    };
    const P = @import("shader_program.zig").ShaderProgram(VD, FD);
    const VP = @import("shader_program.zig").VertexProgram(VD);
    _ = &P.asAnyProgram;
    _ = &VP.asAnyProgram;
}
