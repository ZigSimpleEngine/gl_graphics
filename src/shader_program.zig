/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");

/// Creates a shader program type for given vertex and optional fragment descriptors.
/// Manages program linkage, uniform location caching and singleton instance.
/// Parameters:
/// - vert_: vertex shader descriptor type.
/// - frag_: optional fragment shader descriptor type.
///
/// Returns: opaque shader program type.
pub fn ShaderProgram(comptime vert_: type, comptime frag_: ?type) type {
    const has_frag = frag_ != null;
    const FragType = if (has_frag) frag_.? else void;

    const Impl = struct {
        /// OpenGL program identifier.
        id: u32 = 0,
        /// Whether the program has been initialized and linked.
        initialized: bool = false,
    };

    return opaque {
        /// Self alias for internal referencing.
        const Self = @This();
        /// Vertex descriptor type.
        pub const Vert = vert_;
        /// Optional fragment descriptor type.
        pub const Frag = frag_;
        /// True when a fragment stage is configured.
        pub const HasFrag = has_frag;
        /// Resolved fragment type alias.
        pub const FragT = FragType;

        /// Returns mutable implementation pointer.
        /// Parameters:
        /// - self: program pointer.
        ///
        /// Returns: mutable Impl pointer.
        inline fn impl(self: *Self) *Impl {
            return @ptrCast(@alignCast(self));
        }
        /// Returns immutable implementation pointer.
        /// Parameters:
        /// - self: const program pointer.
        ///
        /// Returns: const Impl pointer.
        inline fn implConst(self: *const Self) *const Impl {
            return @ptrCast(@alignCast(self));
        }

        /// Cached vertex uniform locations.
        pub var vert_cache: if (@hasDecl(Vert, "IdCache")) Vert.IdCache else void = if (@hasDecl(Vert, "IdCache")) std.mem.zeroes(Vert.IdCache) else {};
        /// Cached fragment uniform locations.
        pub var frag_cache: if (has_frag) FragType.IdCache else void = if (has_frag) std.mem.zeroes(FragType.IdCache) else {};
        /// Singleton instance pointer if created.
        var _singleton: ?*Self = null;
        /// Global program identifier mirror.
        pub var id: u32 = 0;

        /// Creates and links a new shader program.
        /// Parameters:
        /// - allocator: allocator for Impl storage.
        ///
        /// Returns: pointer to created program or error.
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
            var ok: i32 = 0;
            gl.programs.getParameter(prog_id, .link_status, @ptrCast(&ok));
            if (ok == 0) {
                var log: [512]u8 = undefined;
                _ = gl.programs.getInfoLog(prog_id, &log);
            }
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
            m.id = prog_id;
            m.initialized = true;
            const self: *Self = @ptrCast(m);
            id = prog_id;
            _singleton = self;
            return self;
        }

        /// Returns the singleton instance, creating it if needed.
        /// Parameters:
        /// - allocator: allocator for creation when not yet initialized.
        ///
        /// Returns: pointer to program instance.
        pub fn instance(allocator: std.mem.Allocator) !*Self {
            if (_singleton) |s| if (s.implConst().initialized and s.implConst().id != 0) return s;
            return create(allocator);
        }

        /// Deletes the program and clears singleton state.
        /// Parameters:
        /// - self: program to destroy.
        /// - allocator: allocator used for creation.
        ///
        /// Returns: void.
        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            const m = self.impl();
            if (gl.loader.loaded() and m.id != 0) gl.programs.delete(m.id);
            m.id = 0;
            m.initialized = false;
            id = 0;
            if (_singleton == self) _singleton = null;
            allocator.destroy(m);
        }

        /// Returns the OpenGL program identifier.
        /// Parameters:
        /// - self: const program pointer.
        ///
        /// Returns: program id.
        pub fn getId(self: *const Self) u32 {
            return self.implConst().id;
        }
        /// Returns the cached vertex uniform locations.
        /// Parameters:
        /// - _: const program pointer unused, kept for API symmetry.
        ///
        /// Returns: copy of vertex IdCache.
        pub fn getVertCache(_: *const Self) if (@hasDecl(Vert, "IdCache")) Vert.IdCache else void {
            return vert_cache;
        }
        /// Returns the cached fragment uniform locations.
        /// Parameters:
        /// - _: const program pointer unused.
        ///
        /// Returns: copy of fragment IdCache or empty struct when no fragment stage.
        pub fn getFragCache(_: *const Self) if (has_frag) FragType.IdCache else void {
            if (has_frag) return frag_cache else return {};
        }

        /// Binds this program for rendering.
        /// Parameters:
        /// - self: const program pointer.
        ///
        /// Returns: void.
        pub fn use(self: *const Self) void {
            gl.programs.use(self.implConst().id);
        }

        /// Returns a vertex uniform editor for this program.
        /// Parameters:
        /// - self: const program pointer.
        ///
        /// Returns: vertex Editor bound to this program id.
        pub fn vertEdit(self: *const Self) Vert.Editor {
            return Vert.edit(self.implConst().id);
        }
        /// Returns a fragment uniform editor for this program.
        /// Parameters:
        /// - self: const program pointer.
        ///
        /// Returns: fragment Editor or void when no fragment stage.
        pub fn fragEdit(self: *const Self) if (has_frag) FragType.Editor else void {
            if (has_frag) return FragType.edit(self.implConst().id) else return {};
        }
        /// Returns a vertex editor via singleton instance.
        /// Parameters:
        /// - allocator: allocator for singleton retrieval or creation.
        ///
        /// Returns: vertex Editor or error.
        pub fn vertEditStatic(allocator: std.mem.Allocator) !Vert.Editor {
            const s = try instance(allocator);
            return s.vertEdit();
        }
        /// Returns a fragment editor via singleton instance.
        /// Parameters:
        /// - allocator: allocator for singleton retrieval or creation.
        ///
        /// Returns: fragment Editor or void or error.
        pub fn fragEditStatic(allocator: std.mem.Allocator) !if (has_frag) FragType.Editor else void {
            if (has_frag) {
                const s = try instance(allocator);
                return s.fragEdit();
            } else return {};
        }
        /// Binds the singleton program for rendering.
        /// Parameters:
        /// - allocator: allocator for singleton retrieval or creation.
        ///
        /// Returns: void or error.
        pub fn useStatic(allocator: std.mem.Allocator) !void {
            const s = try instance(allocator);
            s.use();
        }
    };
}
