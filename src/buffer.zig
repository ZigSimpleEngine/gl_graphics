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
        const Self = @This();
        inline fn impl(self: *Self) *Impl { return @ptrCast(@alignCast(self)); }
        inline fn implConst(self: *const Self) *const Impl { return @ptrCast(@alignCast(self)); }

        pub const DataType = data_;

        pub fn create(allocator: std.mem.Allocator) !*@This() {
            const m = try allocator.create(Impl);
            m.* = .{};
            var id: u32 = 0;
            gl.buffers.gen(1, @ptrCast(&id));
            m.id = id;
            return @ptrCast(m);
        }
        pub fn init(allocator: std.mem.Allocator) !*@This() { return create(allocator); }
        pub fn destroy(self: *@This(), allocator: std.mem.Allocator) void {
            const m = self.impl();
            if (m.id != 0) gl.buffers.delete(1, @ptrCast(&m.id));
            allocator.destroy(m);
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void { self.destroy(allocator); }

        pub fn isValid(self: *const @This()) bool { const m = self.implConst(); return m.id != 0 and gl.buffers.isBuffer(m.id); }

        pub fn getId(self: *const @This()) u32 { return self.implConst().id; }
        pub fn getTarget(self: *const @This()) gl.buffers.BufferTarget { return self.implConst().target; }
        pub fn getUsage(self: *const @This()) gl.buffers.BufferUsage { return self.implConst().usage; }
        pub fn getSizeBytes(self: *const @This()) usize { return self.implConst().size_bytes; }
        pub fn getCount(self: *const @This()) usize { return self.implConst().count; }
        pub fn getDataType(_: *const @This()) type { return data_; }
        pub fn getIsMapped(self: *const @This()) bool { return self.implConst().mapped; }

        pub fn querySize(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_size, @ptrCast(&v)); return v; }
        pub fn queryUsage(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_usage, @ptrCast(&v)); return v; }
        pub fn queryMapped(self: *const @This()) bool { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_mapped, @ptrCast(&v)); return v != 0; }
        pub fn queryMapLength(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_map_length, @ptrCast(&v)); return v; }
        pub fn queryMapOffset(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_map_offset, @ptrCast(&v)); return v; }
        pub fn queryAccessFlags(self: *const @This()) i32 { const m = self.implConst(); gl.buffers.bind(m.target, m.id); var v: i32 = 0; gl.buffers.getParameter(m.target, .buffer_access_flags, @ptrCast(&v)); return v; }

        pub fn bind(self: *const @This()) void { const m = self.implConst(); gl.buffers.bind(m.target, m.id); }
        pub fn bindTo(self: *const @This(), target: gl.buffers.BufferTarget) void { gl.buffers.bind(target, self.implConst().id); }
        pub fn use(self: *const @This()) void { self.bind(); }

        pub fn edit(self: *Self) Editor { return Editor.init(self); }

        pub const Editor = struct {
            _buffer: *Self,
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

            pub fn init(buffer: *Self) Editor { return .{ ._buffer = buffer }; }

            pub fn setTarget(self: *const Editor, target: gl.buffers.BufferTarget) *const Editor { @constCast(self)._pending_target = target; return @constCast(self); }
            pub fn setUsage(self: *const Editor, usage: gl.buffers.BufferUsage) *const Editor { @constCast(self)._pending_usage = usage; return @constCast(self); }
            pub fn setData(self: *const Editor, data: []const data_, usage: gl.buffers.BufferUsage) *const Editor { @constCast(self)._pending_data = .{ .slice = data, .usage = usage }; return @constCast(self); }
            pub fn setDataBytes(self: *const Editor, bytes: []const u8, usage: gl.buffers.BufferUsage) *const Editor { @constCast(self)._pending_data_bytes = .{ .bytes = bytes, .usage = usage }; return @constCast(self); }
            pub fn reserve(self: *const Editor, size_bytes: usize, usage: gl.buffers.BufferUsage) *const Editor { @constCast(self)._pending_reserve = .{ .size_bytes = size_bytes, .usage = usage }; return @constCast(self); }
            pub fn setSubData(self: *const Editor, offset: usize, bytes: []const u8) *const Editor { @constCast(self)._pending_sub_data = .{ .offset = offset, .bytes = bytes }; return @constCast(self); }
            pub fn setSubDataTyped(self: *const Editor, offset_elements: usize, slice: []const data_) *const Editor { @constCast(self)._pending_sub_data_typed = .{ .offset_elements = offset_elements, .slice = slice }; return @constCast(self); }
            pub fn setCopySubData(self: *const Editor, read_target: gl.buffers.BufferTarget, read_offset: usize, write_offset: usize, size: usize) *const Editor { @constCast(self)._pending_copy = .{ .read_target = read_target, .read_offset = read_offset, .write_offset = write_offset, .size = size }; return @constCast(self); }
            pub fn setBindBase(self: *const Editor, target: gl.buffers.BufferTarget, index: u32) *const Editor { @constCast(self)._pending_bind_base = .{ .target = target, .index = index }; return @constCast(self); }
            pub fn setBindRange(self: *const Editor, target: gl.buffers.BufferTarget, index: u32, offset: usize, size: usize) *const Editor { @constCast(self)._pending_bind_range = .{ .target = target, .index = index, .offset = offset, .size = size }; return @constCast(self); }
            pub fn setMap(self: *const Editor, offset: usize, length: usize, access: gl.buffers.MapAccess) *const Editor { @constCast(self)._pending_map = .{ .offset = offset, .length = length, .access = access }; return @constCast(self); }
            pub fn setUnmap(self: *const Editor) *const Editor { @constCast(self)._pending_unmap = true; return @constCast(self); }
            pub fn setFlushMappedRange(self: *const Editor, offset: usize, length: usize) *const Editor { @constCast(self)._pending_flush = .{ .offset = offset, .length = length }; return @constCast(self); }
            pub fn setDataSimple(self: *const Editor, data: []const data_) *const Editor {
                const u = @constCast(self)._pending_usage orelse @constCast(self)._buffer.implConst().usage;
                return self.setData(data, u);
            }

            pub fn apply(self: *const Editor) void {
            const loaded = gl.loader.loaded();
                const buf = @constCast(self)._buffer.impl();
                const target = @constCast(self)._pending_target orelse buf.target;
                if (@constCast(self)._pending_target) |t| buf.target = t;
                if (@constCast(self)._pending_usage) |u| buf.usage = u;
                if (@constCast(self)._pending_data) |d| {
                    if (loaded) gl.buffers.bind(target, buf.id);
                    const bytes: []const u8 = std.mem.sliceAsBytes(d.slice);
                    if (loaded) gl.buffers.bufferData(target, bytes.len, bytes.ptr, d.usage);
                    buf.size_bytes = bytes.len; buf.count = d.slice.len; buf.usage = d.usage;
                } else if (@constCast(self)._pending_data_bytes) |d| {
                    if (loaded) gl.buffers.bind(target, buf.id);
                    if (loaded) gl.buffers.bufferData(target, d.bytes.len, d.bytes.ptr, d.usage);
                    buf.size_bytes = d.bytes.len; buf.count = d.bytes.len / @sizeOf(data_); buf.usage = d.usage;
                } else if (@constCast(self)._pending_reserve) |r| {
                    if (loaded) gl.buffers.bind(target, buf.id);
                    if (loaded) gl.buffers.bufferData(target, r.size_bytes, null, r.usage);
                    buf.size_bytes = r.size_bytes; buf.count = r.size_bytes / @sizeOf(data_); buf.usage = r.usage;
                }
                if (@constCast(self)._pending_sub_data) |s| { if (loaded) gl.buffers.bind(target, buf.id); if (loaded) gl.buffers.bufferSubData(target, s.offset, s.bytes.len, s.bytes.ptr); }
                if (@constCast(self)._pending_sub_data_typed) |s| {
                    if (loaded) gl.buffers.bind(target, buf.id);
                    const bytes = std.mem.sliceAsBytes(s.slice);
                    const off = s.offset_elements * @sizeOf(data_);
                    if (loaded) gl.buffers.bufferSubData(target, off, bytes.len, bytes.ptr);
                }
                if (@constCast(self)._pending_copy) |c| if (loaded) gl.buffers.copySubData(c.read_target, target, c.read_offset, c.write_offset, c.size);
                if (@constCast(self)._pending_bind_base) |b| if (loaded) gl.buffers.bindBase(b.target, b.index, buf.id);
                if (@constCast(self)._pending_bind_range) |r| if (loaded) gl.buffers.bindRange(r.target, r.index, buf.id, @intCast(r.offset), @intCast(r.size));
                if (@constCast(self)._pending_map) |m| { if (loaded) gl.buffers.bind(target, buf.id); if (loaded) _ = gl.buffers.map(target, m.offset, m.length, m.access); buf.mapped = true; buf.access = m.access; }
                if (@constCast(self)._pending_flush) |f| if (loaded) gl.buffers.flushMappedRange(target, f.offset, f.length);
                if (@constCast(self)._pending_unmap) {
                    var ok: bool = false;
                    if (loaded) ok = gl.buffers.unmap(target);
                    buf.mapped = !ok;
                    if (ok) buf.access = null;
                }
                @constCast(self).* = Editor.init(@constCast(self)._buffer);
            }

            pub fn mapNow(self: *const Editor, offset: usize, length: usize, access: gl.buffers.MapAccess) ?*anyopaque {
                const buf = @constCast(self)._buffer.impl();
                const target = @constCast(self)._pending_target orelse buf.target;
                if (gl.loader.loaded()) gl.buffers.bind(target, buf.id);
                const ptr = if (gl.loader.loaded()) gl.buffers.map(target, offset, length, access) else null;
                if (ptr != null) { buf.mapped = true; buf.access = access; }
                return ptr;
            }
            pub fn unmapNow(self: *const Editor) bool {
                const buf = @constCast(self)._buffer.impl();
                const target = @constCast(self)._pending_target orelse buf.target;
                var ok: bool = false;
                if (gl.loader.loaded()) ok = gl.buffers.unmap(target) != 0;
                buf.mapped = !ok; if (ok) buf.access = null;
                return ok;
            }
        };
    };
}
