/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");
/// Type-erased handle imports (for `asAnyProgram` forwarders).
const handles = @import("handles.zig");
const AnyProgram = handles.AnyProgram;

/// Links a program from compiled shader ids.
/// `fs_id` is a runtime optional `u32`, not an optional type parameter.
fn linkProgram(vs_id: u32, fs_id: ?u32) u32 {
    const prog_id = gl.programs.create();
    gl.programs.attach(prog_id, vs_id);
    if (fs_id) |fs| gl.programs.attach(prog_id, fs);
    gl.programs.link(prog_id);
    var ok: i32 = 0;
    gl.programs.getParameter(prog_id, .link_status, @ptrCast(&ok));
    if (ok == 0) {
        var log: [512]u8 = undefined;
        _ = gl.programs.getInfoLog(prog_id, &log);
    }
    return prog_id;
}

/// Caches live uniform locations into a descriptor `IdCache`.
/// The cache must expose one `i32` field per `Uniform` field name.
fn fillIdCache(prog_id: u32, comptime Uniform: type, cache_ptr: anytype) void {
    inline for (@typeInfo(Uniform).@"struct".fields) |field| {
        const loc = gl.uniforms.location(prog_id, @ptrCast(field.name));
        @field(cache_ptr.*, field.name) = loc;
    }
}

/// Creates a shader program type for given vertex and fragment descriptors.
/// Comptime singleton: each unique (vert, frag) pair gets its own private state,
/// no instances, no allocator, no pointers. Both descriptors are concrete
/// types (no optional type parameters); every descriptor must expose
/// `Uniform`, `IdCache`, `instance`, `edit` and `Editor`.
/// Parameters:
/// - vert: vertex shader descriptor type.
/// - frag: fragment shader descriptor type.
///
/// Returns: stateless shader program struct type.
pub fn ShaderProgram(comptime vert: type, comptime frag: type) type {
    return struct {
        /// Vertex descriptor type.
        pub const Vert = vert;
        /// Fragment descriptor type.
        pub const Frag = frag;
        /// Always true: this program has a fragment stage.
        pub const HasFrag = true;

        /// OpenGL program identifier (private singleton state).
        var id: u32 = 0;
        /// Whether the program has been linked (private singleton state).
        var initialized: bool = false;
        /// Cached vertex uniform locations (private singleton state).
        var vert_cache: Vert.IdCache = std.mem.zeroes(Vert.IdCache);
        /// Cached fragment uniform locations (private singleton state).
        var frag_cache: Frag.IdCache = std.mem.zeroes(Frag.IdCache);

        /// Returns the singleton program id, linking on first call.
        ///
        /// Returns: OpenGL program identifier.
        pub fn instance() u32 {
            if (initialized and id != 0) return id;
            const prog_id = linkProgram(Vert.instance(), Frag.instance());
            fillIdCache(prog_id, Vert.Uniform, &vert_cache);
            fillIdCache(prog_id, Frag.Uniform, &frag_cache);
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
        pub fn getVertCache() Vert.IdCache {
            return vert_cache;
        }
        /// Returns the cached fragment uniform locations.
        ///
        /// Returns: copy of fragment IdCache.
        pub fn getFragCache() Frag.IdCache {
            return frag_cache;
        }

        /// Binds the singleton program for rendering (links on first call).
        ///
        /// Returns: void.
        pub fn use() void {
            gl.programs.use(instance());
        }

        /// Wraps this program type as a type-erased `AnyProgram`.
        /// Preferred entry point over `AnyProgram.wrap(Prog)`: thin forward,
        /// same ownership rules (record never owns the singleton).
        ///
        /// Returns: type-erased record.
        pub fn asAnyProgram() AnyProgram {
            return AnyProgram.wrap(@This());
        }

        /// Returns a vertex uniform editor bound to the singleton program.
        ///
        /// Returns: vertex Editor.
        pub fn vertEdit() Vert.Editor {
            return Vert.edit(instance());
        }
        /// Returns a fragment uniform editor bound to the singleton program.
        ///
        /// Returns: fragment Editor.
        pub fn fragEdit() Frag.Editor {
            return Frag.edit(instance());
        }
    };
}

/// Creates a vertex-only shader program type for a given vertex descriptor.
/// Comptime singleton with the same rules as `ShaderProgram`, but without
/// any fragment stage: no `Frag` decl, no frag cache, no `fragEdit`.
/// The vertex descriptor must expose `Uniform`, `IdCache`, `instance`,
/// `edit` and `Editor`.
/// Parameters:
/// - vert: vertex shader descriptor type.
///
/// Returns: stateless vertex-only program struct type.
pub fn VertexProgram(comptime vert: type) type {
    return struct {
        /// Vertex descriptor type.
        pub const Vert = vert;
        /// Always false: this program has no fragment stage.
        pub const HasFrag = false;

        /// OpenGL program identifier (private singleton state).
        var id: u32 = 0;
        /// Whether the program has been linked (private singleton state).
        var initialized: bool = false;
        /// Cached vertex uniform locations (private singleton state).
        var vert_cache: Vert.IdCache = std.mem.zeroes(Vert.IdCache);

        /// Returns the singleton program id, linking on first call.
        ///
        /// Returns: OpenGL program identifier.
        pub fn instance() u32 {
            if (initialized and id != 0) return id;
            const prog_id = linkProgram(Vert.instance(), null);
            fillIdCache(prog_id, Vert.Uniform, &vert_cache);
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
        pub fn getVertCache() Vert.IdCache {
            return vert_cache;
        }

        /// Binds the singleton program for rendering (links on first call).
        ///
        /// Returns: void.
        pub fn use() void {
            gl.programs.use(instance());
        }

        /// Wraps this vertex-only program type as a type-erased `AnyProgram`.
        /// Preferred entry point over `AnyProgram.wrapVertex(Prog)`: thin forward,
        /// same ownership rules (record never owns the singleton).
        ///
        /// Returns: type-erased record.
        pub fn asAnyProgram() AnyProgram {
            return AnyProgram.wrapVertex(@This());
        }

        /// Returns a vertex uniform editor bound to the singleton program.
        ///
        /// Returns: vertex Editor.
        pub fn vertEdit() Vert.Editor {
            return Vert.edit(instance());
        }
    };
}
