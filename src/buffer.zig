const std = @import("std");
const gl = @import("gl");

pub fn Buffer(comptime data_: type) type {
    const Impl = struct {
        id: u32 = 0,
        target: gl.buffers.BufferTarget = .array_buffer,
        usage: gl.buffers.BufferUsage = .static_draw,
        size_bytes: usize = 0,
        count: usize = 0,
        mapped: bool = false,
        access: ?gl.buffers.MapAccess = null,
    };

    return opaque {
        inline fn impl(self: *@This()) *Impl { return @ptrCast(@alignCast(self)); }
        inline fn implConst(self: *const @This()) *const Impl { return @ptrCast(@alignCast(self)); }

        pub const DataType = data_;

        pub fn create(allocator: std.mem.Allocator) !*@This() {
            const m = try allocator.create(Impl);
            m.* = .{};
            var id: u32 = 0;
            gl.buffers.gen(1, &id);
            m.id = id;
            return @ptrCast(m);
        }
        pub fn init() *@This() { return create(std.heap.page_allocator) catch @panic("Buffer.init OOM"); }
        pub fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
            const m = self.impl();
            if (m.id != 0) gl.buffers.delete(1, &m.id);
            allocator.destroy(m);
        }
        pub fn deinit(self: *@This()) void { self.destroy(std.heap.page_allocator); }

        pub fn isValid(self: *const @This()) bool { const m = self.implConst(); return m.id != 0 and gl.buffers.isBuffer(m.id); }

        pub fn getId(self: *const @This()) u32 { return self.implConst().id; }
        pub fn getTarget(self: *const @This()) gl.buffers.BufferTarget { return self.implConst().target; }
        pub fn getUsage(self: *const @This()) gl.buffers.BufferUsage { return self.implConst().usage; }
        pub fn getSizeBytes(self: *const @This()) usize { return self.implConst().size_bytes; }
        pub fn getCount(self: *const @This()) usize { return self.implConst().count; }
        pub fn getDataType(_: *const @This()) type { return data_; }
        pub fn getIsMapped(self: *const @This()) bool { return self.implConst().mapped; }

        pub fn querySize(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_size, &v); return v; }
        pub fn queryUsage(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_usage, &v); return v; }
        pub fn queryMapped(self: *const @This()) bool { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_mapped, &v); return v != 0; }
        pub fn queryMapLength(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_map_length, &v); return v; }
        pub fn queryMapOffset(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_map_offset, &v); return v; }
        pub fn queryAccessFlags(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_access_flags, &v); return v; }

        pub fn bind(self: *const @This()) void { const m = self.implConst(); gl.buffers.bind(m.target, m.id); }
        pub fn bindTo(self: *const @This(), target: gl.buffers.BufferTarget) void { gl.buffers.bind(target, self.implConst().id); }
        pub fn use(self: *const @This()) void { self.bind(); }

        pub fn edit(self: *@This()) Editor { return Editor.init(self); }

        pub const Editor = struct {
            _buffer: *@This(),
            _pending_target: ?gl.buffers.BufferTarget = null,
            _pending_usage: ?gl.buffers.BufferUsage = null,
            _pending_data: ?struct { slice: []const data_, usage: gl.buffers.BufferUsage } = null,
            _pending_data_bytes: ?struct { bytes: []const u8, usage: gl.buffers.BufferUsage } = null,
            _pending_sub_data: ?struct { offset: usize, bytes: []const u8 } = null,
            _pending_sub_data_typed: ?struct { offset_elements: usize, slice: []const data_ } = null,
            _pending_reserve: ?struct { size_bytes: usize, usage: gl.buffers.BufferUsage } = null,
            _pending_copy: ?struct { read_target: gl.buffers.BufferTarget, read_offset: usize, write_offset: usize, size: usize } = null,
            _pending_bind_base: ?struct { target: gl.buffers.BufferTarget, index: u32 } = null,
            _pending_bind_range: ?struct { target: gl.buffers.BufferTarget, index: u32, offset: usize, size: usize } = null,
            _pending_map: ?struct { offset: usize, length: usize, access: gl.buffers.MapAccess } = null,
            _pending_unmap: bool = false,
            _pending_flush: ?struct { offset: usize, length: usize } = null,

            pub fn init(buffer: *@This()) Editor { return .{ ._buffer = buffer }; }

            pub fn setTarget(self: *Editor, target: gl.buffers.BufferTarget) *Editor { self._pending_target = target; return self; }
            pub fn setUsage(self: *Editor, usage: gl.buffers.BufferUsage) *Editor { self._pending_usage = usage; return self; }
            pub fn setData(self: *Editor, data: []const data_, usage: gl.buffers.BufferUsage) *Editor { self._pending_data = .{ .slice = data, .usage = usage }; return self; }
            pub fn setDataBytes(self: *Editor, bytes: []const u8, usage: gl.buffers.BufferUsage) *Editor { self._pending_data_bytes = .{ .bytes = bytes, .usage = usage }; return self; }
            pub fn reserve(self: *Editor, size_bytes: usize, usage: gl.buffers.BufferUsage) *Editor { self._pending_reserve = .{ .size_bytes = size_bytes, .usage = usage }; return self; }
            pub fn setSubData(self: *Editor, offset: usize, bytes: []const u8) *Editor { self._pending_sub_data = .{ .offset = offset, .bytes = bytes }; return self; }
            pub fn setSubDataTyped(self: *Editor, offset_elements: usize, slice: []const data_) *Editor { self._pending_sub_data_typed = .{ .offset_elements = offset_elements, .slice = slice }; return self; }
            pub fn setCopySubData(self: *Editor, read_target: gl.buffers.BufferTarget, read_offset: usize, write_offset: usize, size: usize) *Editor { self._pending_copy = .{ .read_target = read_target, .read_offset = read_offset, .write_offset = write_offset, .size = size }; return self; }
            pub fn setBindBase(self: *Editor, target: gl.buffers.BufferTarget, index: u32) *Editor { self._pending_bind_base = .{ .target = target, .index = index }; return self; }
            pub fn setBindRange(self: *Editor, target: gl.buffers.BufferTarget, index: u32, offset: usize, size: usize) *Editor { self._pending_bind_range = .{ .target = target, .index = index, .offset = offset, .size = size }; return self; }
            pub fn setMap(self: *Editor, offset: usize, length: usize, access: gl.buffers.MapAccess) *Editor { self._pending_map = .{ .offset = offset, .length = length, .access = access }; return self; }
            pub fn setUnmap(self: *Editor) *Editor { self._pending_unmap = true; return self; }
            pub fn setFlushMappedRange(self: *Editor, offset: usize, length: usize) *Editor { self._pending_flush = .{ .offset = offset, .length = length }; return self; }
            pub fn setDataSimple(self: *Editor, data: []const data_) *Editor {
                const u = self._pending_usage orelse self._buffer.implConst().usage;
                return self.setData(data, u);
            }

            pub fn apply(self: *Editor) void {
                const buf = self._buffer.impl();
                const target = self._pending_target orelse buf.target;
                if (self._pending_target) |t| buf.target = t;
                if (self._pending_usage) |u| buf.usage = u;
                if (self._pending_data) |d| {
                    gl.buffers.bind(target, buf.id);
                    const bytes: []const u8 = std.mem.sliceAsBytes(d.slice);
                    gl.buffers.bufferData(target, bytes.len, bytes.ptr, d.usage);
                    buf.size_bytes = bytes.len; buf.count = d.slice.len; buf.usage = d.usage;
                } else if (self._pending_data_bytes) |d| {
                    gl.buffers.bind(target, buf.id);
                    gl.buffers.bufferData(target, d.bytes.len, d.bytes.ptr, d.usage);
                    buf.size_bytes = d.bytes.len; buf.count = d.bytes.len / @sizeOf(data_); buf.usage = d.usage;
                } else if (self._pending_reserve) |r| {
                    gl.buffers.bind(target, buf.id);
                    gl.buffers.bufferData(target, r.size_bytes, null, r.usage);
                    buf.size_bytes = r.size_bytes; buf.count = r.size_bytes / @sizeOf(data_); buf.usage = r.usage;
                }
                if (self._pending_sub_data) |s| { gl.buffers.bind(target, buf.id); gl.buffers.bufferSubData(target, s.offset, s.bytes.len, s.bytes.ptr); }
                if (self._pending_sub_data_typed) |s| {
                    gl.buffers.bind(target, buf.id);
                    const bytes = std.mem.sliceAsBytes(s.slice);
                    const off = s.offset_elements * @sizeOf(data_);
                    gl.buffers.bufferSubData(target, off, bytes.len, bytes.ptr);
                }
                if (self._pending_copy) |c| gl.buffers.copySubData(c.read_target, target, c.read_offset, c.write_offset, c.size);
                if (self._pending_bind_base) |b| gl.buffers.bindBase(b.target, b.index, buf.id);
                if (self._pending_bind_range) |r| gl.buffers.bindRange(r.target, r.index, buf.id, @intCast(r.offset), @intCast(r.size));
                if (self._pending_map) |m| { gl.buffers.bind(target, buf.id); _ = gl.buffers.map(target, m.offset, m.length, m.access); buf.mapped = true; buf.access = m.access; }
                if (self._pending_flush) |f| gl.buffers.flushMappedRange(target, f.offset, f.length);
                if (self._pending_unmap) { const ok = gl.buffers.unmap(target); buf.mapped = !ok; if (ok) buf.access = null; }
                self.* = Editor.init(self._buffer);
            }

            pub fn mapNow(self: *Editor, offset: usize, length: usize, access: gl.buffers.MapAccess) ?*anyopaque {
                const buf = self._buffer.impl();
                const target = self._pending_target orelse buf.target;
                gl.buffers.bind(target, buf.id);
                const ptr = gl.buffers.map(target, offset, length, access);
                if (ptr != null) { buf.mapped = true; buf.access = access; }
                return ptr;
            }
            pub fn unmapNow(self: *Editor) bool {
                const buf = self._buffer.impl();
                const target = self._pending_target orelse buf.target;
                const ok = gl.buffers.unmap(target);
                buf.mapped = !ok; if (ok) buf.access = null;
                return ok;
            }
        };
    };
}
