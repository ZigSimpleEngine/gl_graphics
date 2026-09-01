/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");

/// Creates a material type bound to a specific shader program.
/// The material stores vertex and fragment uniforms and applies them via editors.
/// Parameters:
/// - shader_program_: shader program type providing Vert and optional Frag descriptors.
/// Returns: opaque material type specialized for the program.
pub fn Material(comptime shader_program_: type) type {
    const has_frag = shader_program_.HasFrag;
    const FragUniform = if (has_frag) shader_program_.FragT.Uniform else struct {};
    const VertUniform = shader_program_.Vert.Uniform;

    return opaque {
        /// Self alias for internal use.
        const Self = @This();
        /// Shader program type this material is bound to.
        pub const ShaderProgram = shader_program_;
        /// Vertex uniform type alias.
        pub const VertUniformT = VertUniform;
        /// Fragment uniform type alias.
        pub const FragUniformT = FragUniform;

        /// Internal storage for material state.
        const Impl = struct {
            /// Cached vertex uniform values.
            vertUniform: VertUniform = undefined,
            /// Cached fragment uniform values.
            fragUniform: FragUniform = undefined,
            /// Optional callback invoked on use to fill uniforms dynamically.
            fill_fn: ?*const fn (*Self) void = null,
            /// Associated shader program instance.
            program: ?*ShaderProgram = null,
            /// Allocator used for program instance retrieval.
            allocator: std.mem.Allocator = undefined,
        };

        /// Returns mutable implementation pointer.
        /// Parameters:
        /// - self: material pointer.
        /// Returns: mutable Impl pointer.
        inline fn impl(self: *Self) *Impl {
            return @ptrCast(@alignCast(self));
        }
        /// Returns immutable implementation pointer.
        /// Parameters:
        /// - self: const material pointer.
        /// Returns: const Impl pointer.
        inline fn implConst(self: *const Self) *const Impl {
            return @ptrCast(@alignCast(self));
        }

        /// Creates a new material instance.
        /// Parameters:
        /// - allocator: allocator for storage and program instance.
        /// - fill_fn: optional function to populate uniforms before use.
        /// Returns: pointer to created material or error.
        pub fn create(allocator: std.mem.Allocator, fill_fn: ?*const fn (*Self) void) !*Self {
            const m = try allocator.create(Impl);
            const prog = try ShaderProgram.instance(allocator);
            m.* = .{ .fill_fn = fill_fn, .program = prog, .allocator = allocator };
            return @ptrCast(m);
        }
        /// Destroys the material and frees its storage.
        /// Parameters:
        /// - self: material to destroy.
        /// - allocator: allocator used for creation.
        /// Returns: void.
        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self.impl());
        }

        /// Returns a copy of the cached vertex uniform.
        /// Parameters:
        /// - self: const material pointer.
        /// Returns: vertex uniform value.
        pub fn getVertUniform(self: *const Self) VertUniform {
            return self.implConst().vertUniform;
        }
        /// Returns a copy of the cached fragment uniform.
        /// Parameters:
        /// - self: const material pointer.
        /// Returns: fragment uniform value.
        pub fn getFragUniform(self: *const Self) FragUniform {
            return self.implConst().fragUniform;
        }
        /// Sets the cached vertex uniform.
        /// Parameters:
        /// - self: material pointer.
        /// - u: new vertex uniform value.
        /// Returns: void.
        pub fn setVertUniform(self: *Self, u: VertUniform) void {
            self.impl().vertUniform = u;
        }
        /// Sets the cached fragment uniform.
        /// Parameters:
        /// - self: material pointer.
        /// - u: new fragment uniform value.
        /// Returns: void.
        pub fn setFragUniform(self: *Self, u: FragUniform) void {
            self.impl().fragUniform = u;
        }
        /// Sets the fill callback invoked on use.
        /// Parameters:
        /// - self: material pointer.
        /// - f: optional fill function.
        /// Returns: void.
        pub fn setFillFn(self: *Self, f: ?*const fn (*Self) void) void {
            self.impl().fill_fn = f;
        }
        /// Returns the associated shader program if present.
        /// Parameters:
        /// - self: const material pointer.
        /// Returns: optional program pointer.
        pub fn getProgram(self: *const Self) ?*ShaderProgram {
            return self.implConst().program;
        }

        /// Binds the program and uploads uniforms via editors.
        /// Parameters:
        /// - self: material pointer.
        /// Returns: void.
        pub fn use(self: *Self) void {
            const m = self.impl();
            if (m.program == null or m.program.?.getId() == 0)
                m.program = ShaderProgram.instance(m.allocator) catch null;
            const prog = m.program orelse return;
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
