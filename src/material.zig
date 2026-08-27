const std = @import("std");
const gl = @import("gl");

pub fn Material(comptime shader_program_: type) type {
    const has_frag = shader_program_.HasFrag;
    const FragUniform = if (has_frag) shader_program_.FragT.Uniform else struct {};
    const VertUniform = shader_program_.Vert.Uniform;

    return opaque {
        const Self = @This();
        pub const ShaderProgram = shader_program_;
        pub const VertUniformT = VertUniform;
        pub const FragUniformT = FragUniform;

        const Impl = struct {
            vertUniform: VertUniform = std.mem.zeroes(VertUniform),
            fragUniform: FragUniform = std.mem.zeroes(FragUniform),
            fill_fn: ?*const fn (*Self) void = null,
            program: ?*ShaderProgram = null,
        };

        inline fn impl(self: *Self) *Impl { return @ptrCast(@alignCast(self)); }
        inline fn implConst(self: *const Self) *const Impl { return @ptrCast(@alignCast(self)); }

        pub fn create(allocator: std.mem.Allocator, fill_fn: ?*const fn (*Self) void) !*Self {
            const m = try allocator.create(Impl);
            m.* = .{ .fill_fn = fill_fn, .program = ShaderProgram.instance() };
            return @ptrCast(m);
        }
        pub fn init(fill_fn: ?*const fn (*Self) void) *Self { return create(std.heap.page_allocator, fill_fn) catch @panic("Material OOM"); }
        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void { allocator.destroy(self.impl()); }
        pub fn deinit(self: *Self) void { self.destroy(std.heap.page_allocator); }

        pub fn getVertUniform(self: *const Self) VertUniform { return self.implConst().vertUniform; }
        pub fn getFragUniform(self: *const Self) FragUniform { return self.implConst().fragUniform; }
        pub fn setVertUniform(self: *Self, u: VertUniform) void { self.impl().vertUniform = u; }
        pub fn setFragUniform(self: *Self, u: FragUniform) void { self.impl().fragUniform = u; }
        pub fn setFillFn(self: *Self, f: ?*const fn (*Self) void) void { self.impl().fill_fn = f; }
        pub fn getProgram(self: *const Self) ?*ShaderProgram { return self.implConst().program; }

        pub fn use(self: *Self) void {
            const m = self.impl();
            if (m.program == null or m.program.?.getId() == 0) m.program = ShaderProgram.instance();
            const prog = m.program.?;
            prog.use();
            if (m.fill_fn) |f| f(self);
            var ve = prog.vertEdit();
            _ = ve.setUniform(m.vertUniform);
            ve.apply();
            if (has_frag) {
                var fe = prog.fragEdit();
                _ = fe.setUniform(m.fragUniform);
                fe.apply();
            }
        }
    };
}
