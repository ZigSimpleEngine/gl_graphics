const std = @import("std");
const gl = @import("gl");

// Generic material tying a ShaderProgram's uniform data.
// `shader_program_` is expected to be type returned by ShaderProgram(...).
pub fn Material(comptime shader_program_: type) type {
    const has_frag = shader_program_.HasFrag;
    return struct {
        const Self = @This();
        pub const ShaderProgram = shader_program_;
        pub const VertUniform = ShaderProgram.Vert.Uniform;
        pub const FragUniform = if (has_frag) ShaderProgram.FragType.Uniform else struct {};

        // Public uniform storage — user edits directly
        vertUniform: VertUniform = std.mem.zeroes(VertUniform),
        fragUniform: FragUniform = std.mem.zeroes(FragUniform),

        // Optional callback invoked on use() before uploading uniforms
        _fill_fn: ?*const fn (*Self) void = null,
        _program: ShaderProgram = std.mem.zeroes(ShaderProgram),

        pub fn init(fill_uniform_fn: ?*const fn (*Self) void) Self {
            var self = Self{
                ._fill_fn = fill_uniform_fn,
            };
            // Ensure shader program singleton exists (linking)
            self._program = ShaderProgram.instance();
            return self;
        }

        pub fn getVertUniform(self: *const Self) *const VertUniform { return &self.vertUniform; }
        pub fn getFragUniform(self: *const Self) *const FragUniform { return &self.fragUniform; }
        pub fn setVertUniform(self: *Self, u: VertUniform) void { self.vertUniform = u; }
        pub fn setFragUniform(self: *Self, u: FragUniform) void { self.fragUniform = u; }

        pub fn setFillFn(self: *Self, f: ?*const fn (*Self) void) void { self._fill_fn = f; }

        pub fn use(self: *Self) void {
            if (self._program.getId() == 0) self._program = ShaderProgram.instance();
            var prog = self._program;
            if (prog.getId() == 0) prog = ShaderProgram.instance();

            prog.use();

            if (self._fill_fn) |f| f(self);

            var ve = prog.vertEdit();
            _ = ve.setUniform(self.vertUniform);
            ve.apply();

            if (comptime has_frag) {
                var fe = prog.fragEdit();
                _ = fe.setUniform(self.fragUniform);
                fe.apply();
            }
        }

        pub fn getProgram(self: *const Self) ShaderProgram { return self._program; }
    };
}
