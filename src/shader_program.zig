const std = @import("std");
const gl = @import("gl");

pub fn ShaderProgram(comptime vert_: type, comptime frag_: ?type) type {
    const has_frag = frag_ != null;
    const FragType = if (has_frag) frag_.? else void;

    const Impl = struct {
        id: u32 = 0,
        initialized: bool = false,
    };

    return opaque {
        const Self = @This();
        pub const Vert = vert_;
        pub const Frag = frag_;
        pub const HasFrag = has_frag;
        pub const FragT = FragType;

        inline fn impl(self: *Self) *Impl { return @ptrCast(@alignCast(self)); }
        inline fn implConst(self: *const Self) *const Impl { return @ptrCast(@alignCast(self)); }

        pub var vert_cache: if (@hasDecl(Vert, "IdCache")) Vert.IdCache else void = if (@hasDecl(Vert, "IdCache")) std.mem.zeroes(Vert.IdCache) else {};
        pub var frag_cache: if (has_frag) FragType.IdCache else void = if (has_frag) std.mem.zeroes(FragType.IdCache) else {};
        var _singleton: ?*Self = null;
        pub var id: u32 = 0;

        pub fn create(allocator: std.mem.Allocator) !*Self {
            const m = try allocator.create(Impl);
            m.* = .{};
            const prog_id = gl.programs.create();
            const vs = Vert.instance();
            gl.programs.attach(prog_id, vs);
            if (has_frag) {
                const fs = FragType.instance();
                gl.programs.attach(prog_id, fs);
            }
            gl.programs.link(prog_id);
            var ok: i32 = 0; gl.programs.getParameter(prog_id, .link_status, &ok);
            if (ok == 0) { var log: [512]u8 = undefined; _ = gl.programs.getInfoLog(prog_id, &log); }
            inline for (@typeInfo(Vert.Uniform).@"struct".fields) |field| {
                const loc = gl.uniforms.location(prog_id, @ptrCast(field.name));
                @field(vert_cache, field.name) = loc;
            }
            if (has_frag) {
                inline for (@typeInfo(FragType.Uniform).@"struct".fields) |field| {
                    const loc = gl.uniforms.location(prog_id, @ptrCast(field.name));
                    @field(frag_cache, field.name) = loc;
                }
            }
            m.id = prog_id; m.initialized = true;
            const self: *Self = @ptrCast(m);
            id = prog_id;
            _singleton = self;
            return self;
        }

        pub fn instance() *Self {
            if (_singleton) |s| if (s.implConst().initialized and s.implConst().id != 0) return s;
            return create(std.heap.page_allocator) catch @panic("ShaderProgram OOM");
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            const m = self.impl();
            if (m.id != 0) gl.programs.delete(m.id);
            m.id = 0; m.initialized = false; id = 0;
            if (_singleton == self) _singleton = null;
            allocator.destroy(m);
        }
        pub fn deinit(self: *Self) void { self.destroy(std.heap.page_allocator); }

        pub fn getId(self: *const Self) u32 { return self.implConst().id; }
        pub fn getVertCache(_: *const Self) if (@hasDecl(Vert, "IdCache")) Vert.IdCache else void { return vert_cache; }
        pub fn getFragCache(_: *const Self) if (has_frag) FragType.IdCache else void { if (has_frag) return frag_cache else return {}; }

        pub fn use(self: *const Self) void { gl.programs.use(self.implConst().id); }

        pub fn vertEdit(self: *const Self) Vert.Editor { return Vert.edit(self.implConst().id); }
        pub fn fragEdit(self: *const Self) if (has_frag) FragType.Editor else void {
            if (has_frag) return FragType.edit(self.implConst().id) else return {};
        }
        pub fn vertEditStatic() Vert.Editor { const s = instance(); return s.vertEdit(); }
        pub fn fragEditStatic() if (has_frag) FragType.Editor else void { if (has_frag) { const s = instance(); return s.fragEdit(); } else return {}; }
        pub fn useStatic() void { const s = instance(); s.use(); }
    };
}
