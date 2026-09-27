/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");

/// Creates a shader program type for given vertex and optional fragment descriptors.
/// Comptime singleton: each unique (vert, frag) pair gets its own private state,
/// no instances, no allocator, no pointers.
/// Parameters:
/// - vert_: vertex shader descriptor type.
/// - frag_: optional fragment shader descriptor type.
///
/// Returns: stateless shader program struct type.
pub fn ShaderProgram(comptime vert_: type, comptime frag_: ?type) type {
    const has_frag = frag_ != null;
    const FragType = if (has_frag) frag_.? else void;

    return struct {
        /// Vertex descriptor type.
        pub const Vert = vert_;
        /// Optional fragment descriptor type.
        pub const Frag = frag_;
        /// True when a fragment stage is configured.
        pub const HasFrag = has_frag;
        /// Resolved fragment type alias.
        pub const FragT = FragType;

        /// OpenGL program identifier (private singleton state).
        var id: u32 = 0;
        /// Whether the program has been linked (private singleton state).
        var initialized: bool = false;
        /// Cached vertex uniform locations (private singleton state).
        var vert_cache: if (@hasDecl(Vert, "IdCache")) Vert.IdCache else void = if (@hasDecl(Vert, "IdCache")) std.mem.zeroes(Vert.IdCache) else {};
        /// Cached fragment uniform locations (private singleton state).
        var frag_cache: if (has_frag) FragType.IdCache else void = if (has_frag) std.mem.zeroes(FragType.IdCache) else {};

        /// Returns the singleton program id, linking on first call.
        ///
        /// Returns: OpenGL program identifier.
        pub fn instance() u32 {
            if (initialized and id != 0) return id;
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
            id = prog_id;
            initialized = true;
            return id;
        }

        /// Deletes the program and resets singleton state.
        ///
        /// Returns: void.
        pub fn destroy() void {
            if (gl.loader.loaded() and id != 0) gl.programs.delete(id);
            id = 0;
            initialized = false;
        }

        /// Returns the cached OpenGL program identifier without linking.
        ///
        /// Returns: program id (0 when not yet created).
        pub fn getId() u32 {
            return id;
        }
        /// Returns whether the program has been linked.
        ///
        /// Returns: true after a successful `instance()` call.
        pub fn isInitialized() bool {
            return initialized and id != 0;
        }
        /// Returns the cached vertex uniform locations.
        ///
        /// Returns: copy of vertex IdCache.
        pub fn getVertCache() if (@hasDecl(Vert, "IdCache")) Vert.IdCache else void {
            return vert_cache;
        }
        /// Returns the cached fragment uniform locations.
        ///
        /// Returns: copy of fragment IdCache or empty struct when no fragment stage.
        pub fn getFragCache() if (has_frag) FragType.IdCache else void {
            if (has_frag) return frag_cache else return {};
        }

        /// Binds the singleton program for rendering (links on first call).
        ///
        /// Returns: void.
        pub fn use() void {
            gl.programs.use(instance());
        }

        /// Returns a vertex uniform editor bound to the singleton program.
        ///
        /// Returns: vertex Editor.
        pub fn vertEdit() Vert.Editor {
            return Vert.edit(instance());
        }
        /// Returns a fragment uniform editor bound to the singleton program.
        ///
        /// Returns: fragment Editor or void when no fragment stage.
        pub fn fragEdit() if (has_frag) FragType.Editor else void {
            if (has_frag) return FragType.edit(instance()) else return {};
        }
    };
}
