const std = @import("std");
const gl = @import("gl");

// Generic GPU buffer abstraction managing a typed resource.
// `data_: type` is the element type stored in the buffer (e.g., f32, Vertex,
// u16 indices).  All state is opaque; only getters exist on the buffer itself.
// Mutation is done via `Buffer.Editor` MethodChain with deferred `apply()`.
pub fn Buffer(comptime data_: type) type {
    return struct {
        const Self = @This();

        pub const DataType = data_;

        // ---- opaque state ----
        _id: u32 = 0,
        _target: gl.buffers.BufferTarget = .array_buffer,
        _usage: gl.buffers.BufferUsage = .static_draw,
        _size_bytes: usize = 0,
        _count: usize = 0,
        _mapped: bool = false,
        _access: ?gl.buffers.MapAccess = null,

        // ------------------------------------------------------------
        // Lifecycle
        // ------------------------------------------------------------
        pub fn init() Self {
            var id: u32 = 0;
            gl.buffers.gen(1, &id);
            return .{ ._id = id };
        }

        pub fn deinit(self: *Self) void {
            if (self._id != 0) {
                gl.buffers.delete(1, &self._id);
                self._id = 0;
                self._size_bytes = 0;
                self._count = 0;
            }
        }

        pub fn isValid(self: *const Self) bool {
            return self._id != 0 and gl.buffers.isBuffer(self._id);
        }

        // ------------------------------------------------------------
        // Getters — expose all GL-queryable state
        // ------------------------------------------------------------
        pub fn getId(self: *const Self) u32 { return self._id; }
        pub fn getTarget(self: *const Self) gl.buffers.BufferTarget { return self._target; }
        pub fn getUsage(self: *const Self) gl.buffers.BufferUsage { return self._usage; }
        pub fn getSizeBytes(self: *const Self) usize { return self._size_bytes; }
        pub fn getCount(self: *const Self) usize { return self._count; }
        pub fn getDataType(_: *const Self) type { return DataType; }
        pub fn getIsMapped(self: *const Self) bool { return self._mapped; }

        pub fn querySize(self: *const Self) i32 {
            gl.buffers.bind(self._target, self._id);
            var v: i32 = 0;
            gl.buffers.getParameter(self._target, .buffer_size, &v);
            return v;
        }
        pub fn queryUsage(self: *const Self) i32 {
            gl.buffers.bind(self._target, self._id);
            var v: i32 = 0;
            gl.buffers.getParameter(self._target, .buffer_usage, &v);
            return v;
        }
        pub fn queryMapped(self: *const Self) bool {
            gl.buffers.bind(self._target, self._id);
            var v: i32 = 0;
            gl.buffers.getParameter(self._target, .buffer_mapped, &v);
            return v != 0;
        }
        pub fn queryMapLength(self: *const Self) i32 {
            gl.buffers.bind(self._target, self._id);
            var v: i32 = 0;
            gl.buffers.getParameter(self._target, .buffer_map_length, &v);
            return v;
        }
        pub fn queryMapOffset(self: *const Self) i32 {
            gl.buffers.bind(self._target, self._id);
            var v: i32 = 0;
            gl.buffers.getParameter(self._target, .buffer_map_offset, &v);
            return v;
        }
        pub fn queryAccessFlags(self: *const Self) i32 {
            gl.buffers.bind(self._target, self._id);
            var v: i32 = 0;
            gl.buffers.getParameter(self._target, .buffer_access_flags, &v);
            return v;
        }

        pub fn bind(self: *const Self) void {
            gl.buffers.bind(self._target, self._id);
        }
        pub fn bindTo(self: *const Self, target: gl.buffers.BufferTarget) void {
            gl.buffers.bind(target, self._id);
        }
        pub fn use(self: *const Self) void { self.bind(); }

        // ------------------------------------------------------------
        // Editor — deferred MethodChain
        // ------------------------------------------------------------
        pub fn edit(self: *Self) Editor {
            return Editor.init(self);
        }

        pub const Editor = struct {
            _buffer: *Self,

            _pending_target: ?gl.buffers.BufferTarget = null,
            _pending_usage: ?gl.buffers.BufferUsage = null,
            _pending_data: ?struct {
                slice: []const DataType,
                usage: gl.buffers.BufferUsage,
            } = null,
            _pending_data_bytes: ?struct {
                bytes: []const u8,
                usage: gl.buffers.BufferUsage,
            } = null,
            _pending_sub_data: ?struct {
                offset: usize,
                bytes: []const u8,
            } = null,
            _pending_sub_data_typed: ?struct {
                offset_elements: usize,
                slice: []const DataType,
            } = null,
            _pending_reserve: ?struct {
                size_bytes: usize,
                usage: gl.buffers.BufferUsage,
            } = null,
            _pending_copy: ?struct {
                read_target: gl.buffers.BufferTarget,
                read_offset: usize,
                write_offset: usize,
                size: usize,
            } = null,
            _pending_bind_base: ?struct {
                target: gl.buffers.BufferTarget,
                index: u32,
            } = null,
            _pending_bind_range: ?struct {
                target: gl.buffers.BufferTarget,
                index: u32,
                offset: usize,
                size: usize,
            } = null,
            _pending_map: ?struct {
                offset: usize,
                length: usize,
                access: gl.buffers.MapAccess,
            } = null,
            _pending_unmap: bool = false,
            _pending_flush: ?struct { offset: usize, length: usize } = null,

            pub fn init(buffer: *Self) Editor {
                return .{ ._buffer = buffer };
            }

            // ---- setters (chain) ----
            pub fn setTarget(self: *Editor, target: gl.buffers.BufferTarget) *Editor {
                self._pending_target = target;
                return self;
            }
            pub fn setUsage(self: *Editor, usage: gl.buffers.BufferUsage) *Editor {
                self._pending_usage = usage;
                return self;
            }
            /// Upload typed slice with explicit usage — stored pending until apply.
            pub fn setData(self: *Editor, data: []const DataType, usage: gl.buffers.BufferUsage) *Editor {
                self._pending_data = .{ .slice = data, .usage = usage };
                return self;
            }
            /// Upload raw bytes with usage.
            pub fn setDataBytes(self: *Editor, bytes: []const u8, usage: gl.buffers.BufferUsage) *Editor {
                self._pending_data_bytes = .{ .bytes = bytes, .usage = usage };
                return self;
            }
            /// Reserve storage without uploading (null data).
            pub fn reserve(self: *Editor, size_bytes: usize, usage: gl.buffers.BufferUsage) *Editor {
                self._pending_reserve = .{ .size_bytes = size_bytes, .usage = usage };
                return self;
            }
            pub fn setSubData(self: *Editor, offset: usize, bytes: []const u8) *Editor {
                self._pending_sub_data = .{ .offset = offset, .bytes = bytes };
                return self;
            }
            pub fn setSubDataTyped(self: *Editor, offset_elements: usize, slice: []const DataType) *Editor {
                self._pending_sub_data_typed = .{ .offset_elements = offset_elements, .slice = slice };
                return self;
            }
            pub fn setCopySubData(self: *Editor, read_target: gl.buffers.BufferTarget, read_offset: usize, write_offset: usize, size: usize) *Editor {
                self._pending_copy = .{ .read_target = read_target, .read_offset = read_offset, .write_offset = write_offset, .size = size };
                return self;
            }
            pub fn setBindBase(self: *Editor, target: gl.buffers.BufferTarget, index: u32) *Editor {
                self._pending_bind_base = .{ .target = target, .index = index };
                return self;
            }
            pub fn setBindRange(self: *Editor, target: gl.buffers.BufferTarget, index: u32, offset: usize, size: usize) *Editor {
                self._pending_bind_range = .{ .target = target, .index = index, .offset = offset, .size = size };
                return self;
            }
            pub fn setMap(self: *Editor, offset: usize, length: usize, access: gl.buffers.MapAccess) *Editor {
                self._pending_map = .{ .offset = offset, .length = length, .access = access };
                return self;
            }
            pub fn setUnmap(self: *Editor) *Editor {
                self._pending_unmap = true;
                return self;
            }
            pub fn setFlushMappedRange(self: *Editor, offset: usize, length: usize) *Editor {
                self._pending_flush = .{ .offset = offset, .length = length };
                return self;
            }

            // Convenience: setData without explicit usage uses pending or buffer's current usage
            pub fn setDataSimple(self: *Editor, data: []const DataType) *Editor {
                const u = self._pending_usage orelse self._buffer._usage;
                return self.setData(data, u);
            }

            pub fn apply(self: *Editor) void {
                const buf = self._buffer;
                const target = self._pending_target orelse buf._target;

                // Apply pending target change
                if (self._pending_target) |t| buf._target = t;
                if (self._pending_usage) |u| buf._usage = u;

                // Bind once if any operation needs binding
                const needs_bind = self._pending_data != null or self._pending_data_bytes != null or
                    self._pending_reserve != null or self._pending_sub_data != null or
                    self._pending_sub_data_typed != null or self._pending_copy != null or
                    self._pending_map != null or self._pending_unmap or self._pending_flush != null;

                if (needs_bind or self._pending_bind_base != null or self._pending_bind_range != null) {
                    // For bindBase/Range we bind with specific target; else normal bind
                }

                if (self._pending_data) |d| {
                    gl.buffers.bind(target, buf._id);
                    const bytes: []const u8 = std.mem.sliceAsBytes(d.slice);
                    gl.buffers.bufferData(target, bytes.len, bytes.ptr, d.usage);
                    buf._size_bytes = bytes.len;
                    buf._count = d.slice.len;
                    buf._usage = d.usage;
                } else if (self._pending_data_bytes) |d| {
                    gl.buffers.bind(target, buf._id);
                    gl.buffers.bufferData(target, d.bytes.len, d.bytes.ptr, d.usage);
                    buf._size_bytes = d.bytes.len;
                    buf._count = d.bytes.len / @sizeOf(DataType);
                    buf._usage = d.usage;
                } else if (self._pending_reserve) |r| {
                    gl.buffers.bind(target, buf._id);
                    gl.buffers.bufferData(target, r.size_bytes, null, r.usage);
                    buf._size_bytes = r.size_bytes;
                    buf._count = r.size_bytes / @sizeOf(DataType);
                    buf._usage = r.usage;
                }

                if (self._pending_sub_data) |s| {
                    gl.buffers.bind(target, buf._id);
                    gl.buffers.bufferSubData(target, s.offset, s.bytes.len, s.bytes.ptr);
                }
                if (self._pending_sub_data_typed) |s| {
                    gl.buffers.bind(target, buf._id);
                    const bytes = std.mem.sliceAsBytes(s.slice);
                    const offset_bytes = s.offset_elements * @sizeOf(DataType);
                    gl.buffers.bufferSubData(target, offset_bytes, bytes.len, bytes.ptr);
                }
                if (self._pending_copy) |c| {
                    // copy between buffers: read_target already bound elsewhere? Use gl copy
                    gl.buffers.copySubData(c.read_target, target, c.read_offset, c.write_offset, c.size);
                }
                if (self._pending_bind_base) |b| {
                    gl.buffers.bindBase(b.target, b.index, buf._id);
                }
                if (self._pending_bind_range) |r| {
                    gl.buffers.bindRange(r.target, r.index, buf._id, @intCast(r.offset), @intCast(r.size));
                }
                if (self._pending_map) |m| {
                    gl.buffers.bind(target, buf._id);
                    _ = gl.buffers.map(target, m.offset, m.length, m.access);
                    buf._mapped = true;
                    buf._access = m.access;
                }
                if (self._pending_flush) |f| {
                    gl.buffers.flushMappedRange(target, f.offset, f.length);
                }
                if (self._pending_unmap) {
                    const ok = gl.buffers.unmap(target);
                    buf._mapped = !ok;
                    if (ok) buf._access = null;
                }

                // Reset pending
                self.* = Editor.init(buf);
            }

            // Direct map helper that applies immediately and returns pointer (not deferred)
            pub fn mapNow(self: *Editor, offset: usize, length: usize, access: gl.buffers.MapAccess) ?*anyopaque {
                const buf = self._buffer;
                const target = self._pending_target orelse buf._target;
                gl.buffers.bind(target, buf._id);
                const ptr = gl.buffers.map(target, offset, length, access);
                if (ptr != null) {
                    buf._mapped = true;
                    buf._access = access;
                }
                return ptr;
            }
            pub fn unmapNow(self: *Editor) bool {
                const buf = self._buffer;
                const target = self._pending_target orelse buf._target;
                const ok = gl.buffers.unmap(target);
                buf._mapped = !ok;
                if (ok) buf._access = null;
                return ok;
            }
        };
    };
}
