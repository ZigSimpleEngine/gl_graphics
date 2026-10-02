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
        const len = gl.programs.getInfoLog(prog_id, &log);
        std.debug.print("GLSL program link failed (id={}, vs={}, fs={?}):\n{s}\n", .{ prog_id, vs_id, fs_id, log[0..@min(len, log.len)] });
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
/// Variant cache: each unique `(vert_defines, frag_defines)` pair links its
/// own program on first `instance(allocator, ...)`; shaders themselves compile
/// per-stage variants via `Vert.instance(allocator, ...)` / `Frag.instance`.
/// Both descriptors must expose `Uniform`, `IdCache`, `Define`,
/// `instance(allocator, defines)`, `destroy(allocator)`, `edit` and `Editor`.
/// Parameters:
/// - vert: vertex shader descriptor type.
/// - frag: fragment shader descriptor type.
///
/// Returns: stateful shader program struct type (allocator for variants).
pub fn ShaderProgram(comptime vert: type, comptime frag: type) type {
    if (!@hasDecl(vert, "Define")) @compileError("ShaderProgram: vertex shader " ++ @typeName(vert) ++ " must expose `pub const Define` (regenerate descriptors).");
    if (!@hasDecl(frag, "Define")) @compileError("ShaderProgram: fragment shader " ++ @typeName(frag) ++ " must expose `pub const Define` (regenerate descriptors).");
    return struct {
        /// Vertex descriptor type.
        pub const Vert = vert;
        /// Fragment descriptor type.
        pub const Frag = frag;
        /// Always true: this program has a fragment stage.
        pub const HasFrag = true;
        /// Per-stage defines types.
        pub const VertDefines = vert.Define;
        /// Per-stage defines types.
        pub const FragDefines = frag.Define;
        /// Combined program key (material passes both fields).
        pub const ProgramDefines = struct {
            vert: VertDefines,
            frag: FragDefines,
        };
        /// Linked variant with per-variant uniform caches.
        pub const Variant = struct {
            prog_id: u32,
            vert_cache: Vert.IdCache,
            frag_cache: Frag.IdCache,
        };

        /// Variant cache (private state, allocator-owned).
        var variants: std.AutoHashMapUnmanaged(ProgramDefines, Variant) = .empty;

        /// Returns the program id for the given defines, linking on first call.
        /// Compiles per-stage shader variants as needed.
        ///
        /// Returns: OpenGL program identifier.
        pub fn instance(allocator: std.mem.Allocator, vert_defines: VertDefines, frag_defines: FragDefines) !u32 {
            const key: ProgramDefines = .{ .vert = vert_defines, .frag = frag_defines };
            if (variants.get(key)) |v| return v.prog_id;
            const vs_id = try Vert.instance(allocator, vert_defines);
            const fs_id = try Frag.instance(allocator, frag_defines);
            const prog_id = linkProgram(vs_id, fs_id);
            var vc: Vert.IdCache = std.mem.zeroes(Vert.IdCache);
            var fc: Frag.IdCache = std.mem.zeroes(Frag.IdCache);
            fillIdCache(prog_id, Vert.Uniform, &vc);
            fillIdCache(prog_id, Frag.Uniform, &fc);
            try variants.put(allocator, key, .{ .prog_id = prog_id, .vert_cache = vc, .frag_cache = fc });
            return prog_id;
        }

        /// Deletes all linked variants and resets state.
        ///
        /// Returns: void.
        pub fn destroy(allocator: std.mem.Allocator) void {
            if (gl.loader.loaded()) {
                var it = variants.iterator();
                while (it.next()) |e| gl.programs.delete(e.value_ptr.prog_id);
            }
            variants.deinit(allocator);
            variants = .empty;
        }

        /// Returns the cached variant (if linked).
        ///
        /// Returns: variant copy or null.
        pub fn getVariant(defines: ProgramDefines) ?Variant {
            return variants.get(defines);
        }

        /// Binds the program variant for rendering (links on first call).
        ///
        /// Returns: void.
        pub fn use(allocator: std.mem.Allocator, vert_defines: VertDefines, frag_defines: FragDefines) !void {
            gl.programs.use(try instance(allocator, vert_defines, frag_defines));
        }

        /// Wraps this program type as a type-erased `AnyProgram`.
        /// Preferred entry point over `AnyProgram.wrap(Prog)`: thin forward,
        /// same ownership rules (record never owns the variants).
        ///
        /// Returns: type-erased record.
        pub fn asAnyProgram() AnyProgram {
            return AnyProgram.wrap(@This());
        }

        /// Returns a vertex uniform editor bound to an explicit program id.
        ///
        /// Returns: vertex Editor.
        pub fn vertEdit(program: u32) Vert.Editor {
            return Vert.edit(program);
        }
        /// Returns a fragment uniform editor bound to an explicit program id.
        ///
        /// Returns: fragment Editor.
        pub fn fragEdit(program: u32) Frag.Editor {
            return Frag.edit(program);
        }
    };
}

/// Creates a vertex-only shader program type for a given vertex descriptor.
/// Same variant rules as `ShaderProgram`, but without any fragment stage.
/// Parameters:
/// - vert: vertex shader descriptor type.
///
/// Returns: stateful vertex-only program struct type.
pub fn VertexProgram(comptime vert: type) type {
    if (!@hasDecl(vert, "Define")) @compileError("VertexProgram: vertex shader " ++ @typeName(vert) ++ " must expose `pub const Define` (regenerate descriptors).");
    return struct {
        /// Vertex descriptor type.
        pub const Vert = vert;
        /// Always false: this program has no fragment stage.
        pub const HasFrag = false;
        /// Per-stage defines type (also the program key).
        pub const VertDefines = vert.Define;
        /// Combined program key (single stage).
        pub const ProgramDefines = VertDefines;
        /// Linked variant with per-variant uniform cache.
        pub const Variant = struct {
            prog_id: u32,
            vert_cache: Vert.IdCache,
        };

        /// Variant cache (private state, allocator-owned).
        var variants: std.AutoHashMapUnmanaged(ProgramDefines, Variant) = .empty;

        /// Returns the program id for the given defines, linking on first call.
        ///
        /// Returns: OpenGL program identifier.
        pub fn instance(allocator: std.mem.Allocator, vert_defines: VertDefines) !u32 {
            if (variants.get(vert_defines)) |v| return v.prog_id;
            const vs_id = try Vert.instance(allocator, vert_defines);
            const prog_id = linkProgram(vs_id, null);
            var vc: Vert.IdCache = std.mem.zeroes(Vert.IdCache);
            fillIdCache(prog_id, Vert.Uniform, &vc);
            try variants.put(allocator, vert_defines, .{ .prog_id = prog_id, .vert_cache = vc });
            return prog_id;
        }

        /// Deletes all linked variants and resets state.
        ///
        /// Returns: void.
        pub fn destroy(allocator: std.mem.Allocator) void {
            if (gl.loader.loaded()) {
                var it = variants.iterator();
                while (it.next()) |e| gl.programs.delete(e.value_ptr.prog_id);
            }
            variants.deinit(allocator);
            variants = .empty;
        }

        /// Returns the cached variant (if linked).
        ///
        /// Returns: variant copy or null.
        pub fn getVariant(defines: ProgramDefines) ?Variant {
            return variants.get(defines);
        }

        /// Binds the program variant for rendering (links on first call).
        ///
        /// Returns: void.
        pub fn use(allocator: std.mem.Allocator, vert_defines: VertDefines) !void {
            gl.programs.use(try instance(allocator, vert_defines));
        }

        /// Wraps this vertex-only program type as a type-erased `AnyProgram`.
        /// Preferred entry point over `AnyProgram.wrapVertex(Prog)`: thin forward,
        /// same ownership rules (record never owns the variants).
        ///
        /// Returns: type-erased record.
        pub fn asAnyProgram() AnyProgram {
            return AnyProgram.wrapVertex(@This());
        }

        /// Returns a vertex uniform editor bound to an explicit program id.
        ///
        /// Returns: vertex Editor.
        pub fn vertEdit(program: u32) Vert.Editor {
            return Vert.edit(program);
        }
    };
}
