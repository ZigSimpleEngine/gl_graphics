/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");
/// Texture wrapper type.
const Texture = @import("texture.zig").Texture;

/// Returns true when `T` is a math vector type (`math.Vec`).
/// Parameters:
/// - T: type to test.
/// Returns: true for vector types.
fn isVecType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "len") and @hasDecl(T, "value_type");
}

/// Returns true when `T` is a math matrix type (`math.Mat`).
/// Parameters:
/// - T: type to test.
/// Returns: true for matrix types.
fn isMatType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "cols") and @hasDecl(T, "rows");
}

/// Uploads a single uniform value to `loc`, dispatching on the Zig type
/// (math vector/matrix, scalar or bool).
/// Parameters:
/// - loc: uniform location.
/// - T: value type.
/// - value: value to upload.
/// Returns: void.
pub fn uploadUniformValue(loc: i32, comptime T: type, value: T) void {
    if (comptime isVecType(T)) {
        if (T.value_type == f32) {
            if (T.len == 1) gl.uniforms.uniform1f(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2f(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3f(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4f(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}
        } else if (T.value_type == i32) {
            if (T.len == 1) gl.uniforms.uniform1i(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2i(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3i(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4i(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}
        } else if (T.value_type == u32) {
            if (T.len == 1) gl.uniforms.uniform1ui(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2ui(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3ui(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4ui(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}
        }
    } else if (comptime isMatType(T)) {
        if (T.cols == 4 and T.rows == 4) {
            var data: [16]f32 = undefined;
            inline for (0..4) |c| {
                inline for (0..4) |r| {
                    data[c * 4 + r] = value.data[c].v[r];
                }
            }
            gl.uniforms.uniformMatrix4fv(loc, false, &data);
        } else if (T.cols == 3 and T.rows == 3) {
            var data: [9]f32 = undefined;
            inline for (0..3) |c| {
                inline for (0..3) |r| {
                    data[c * 3 + r] = value.data[c].v[r];
                }
            }
            gl.uniforms.uniformMatrix3fv(loc, false, &data);
        } else if (T.cols == 2 and T.rows == 2) {
            var data: [4]f32 = undefined;
            inline for (0..2) |c| {
                inline for (0..2) |r| {
                    data[c * 2 + r] = value.data[c].v[r];
                }
            }
            gl.uniforms.uniformMatrix2fv(loc, false, &data);
        } else if (T.cols == 3 and T.rows == 2) {
            var data: [6]f32 = undefined;
            inline for (0..3) |c| {
                inline for (0..2) |r| {
                    data[c * 2 + r] = value.data[c].v[r];
                }
            }
            gl.uniforms.uniformMatrix3x2fv(loc, false, &data);
        } else if (T.cols == 2 and T.rows == 3) {
            var data: [6]f32 = undefined;
            inline for (0..2) |c| {
                inline for (0..3) |r| {
                    data[c * 3 + r] = value.data[c].v[r];
                }
            }
            gl.uniforms.uniformMatrix2x3fv(loc, false, &data);
        }
    } else if (T == f32) {
        gl.uniforms.uniform1f(loc, value);
    } else if (T == i32) {
        gl.uniforms.uniform1i(loc, value);
    } else if (T == u32) {
        gl.uniforms.uniform1ui(loc, value);
    } else if (T == bool) {
        gl.uniforms.uniform1i(loc, if (value) 1 else 0);
    } else {}
}

/// Recursively uploads the fields of a struct uniform using dotted GLSL
/// names ("prefix.field"). Non-struct leaves are uploaded directly.
/// Parameters:
/// - program: program to upload to.
/// - prefix: dotted name prefix (empty for top level).
/// - T: struct type to flatten.
/// - value: struct value to upload.
/// Returns: void.
pub fn flattenUniforms(program: u32, comptime prefix: []const u8, comptime T: type, value: T) void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const path: [:0]const u8 = if (prefix.len == 0) f.name else std.fmt.comptimePrint("{s}.{s}", .{ prefix, f.name });
        const loc = gl.uniforms.location(program, path);
        if (loc != -1) {
            const fv = @field(value, f.name);
            const FT = @TypeOf(fv);
            if (@typeInfo(FT) == .@"struct" and !isVecType(FT) and !isMatType(FT)) {
                flattenUniforms(program, path, FT, fv);
            } else {
                uploadUniformValue(loc, FT, fv);
            }
        }
    }
}

/// Applies pending editor uniforms that are marked dirty (or all of them
/// when `set_all` is true), then resets the dirty flags. Dispatches on the
/// uniform type: textures, uniform block buffers, math types, scalars and
/// nested structs.
/// Parameters:
/// - UniformT: editor uniform struct type.
/// - BlocksT: buffer block table (`name` -> `{ .name, .point }`).
/// - program: program to upload to.
/// - pending: pending uniform values.
/// - set_all: true to upload every uniform regardless of dirty flags.
/// - dirty: pointer to a struct mirroring `UniformT` field names with bools.
/// Returns: void.
pub fn applyUniforms(
    comptime UniformT: type,
    comptime BlocksT: type,
    program: u32,
    pending: UniformT,
    set_all: bool,
    dirty: anytype,
) void {
    inline for (@typeInfo(UniformT).@"struct".fields) |field| {
        const name = field.name;
        const is_dirty = if (set_all) true else @field(dirty, name);
        if (is_dirty) {
            const value = @field(pending, name);
            const T = @TypeOf(value);
            const DerefT = if (@typeInfo(T) == .pointer) std.meta.Child(T) else void;
            const loc = gl.uniforms.location(program, @ptrCast(name));
            if (loc != -1 and (T == Texture or T == *const Texture or T == *Texture)) {
                const unit: u32 = 0;
                gl.textures.activeTexture(@enumFromInt(@intFromEnum(gl.textures.TextureUnit.texture0) + unit));
                gl.textures.bind(.texture_2d, value.getId());
                gl.uniforms.uniform1i(loc, @intCast(unit));
            } else if (@typeInfo(DerefT) == .@"opaque" and @hasDecl(DerefT, "DataType")) {
                // Uniform block buffer (UBO): bind the buffer to the block binding point.
                const block = @field(BlocksT, name);
                const bidx = gl.uniforms.blockIndex(program, block.name);
                if (bidx != 0xFFFFFFFF) {
                    gl.uniforms.blockBinding(program, bidx, block.point);
                    gl.buffers.bindBase(.uniform_buffer, block.point, value.getId());
                }
            } else if (loc != -1 and comptime isVecType(T)) {
                uploadUniformValue(loc, T, value);
            } else if (loc != -1 and comptime isMatType(T)) {
                uploadUniformValue(loc, T, value);
            } else if (loc != -1 and (T == f32 or T == i32 or T == u32 or T == bool)) {
                uploadUniformValue(loc, T, value);
            } else if (@typeInfo(T) == .@"struct") {
                // Custom struct uniform: upload members with dotted GL names.
                flattenUniforms(program, name, T, value);
            } else {}
        }
    }
    const DirtyT = @typeInfo(@TypeOf(dirty)).pointer.child;
    inline for (@typeInfo(DirtyT).@"struct".fields) |f| @field(dirty, f.name) = false;
}

/// Creates a shader of the given kind, loads and compiles `src` into it.
/// Parameters:
/// - kind: shader stage type.
/// - src: GLSL source text.
/// Returns: created shader id.
pub fn compileShaderSource(kind: gl.shaders.ShaderType, src: []const u8) u32 {
    const shader = gl.shaders.create(kind);
    gl.shaders.source(shader, src);
    gl.shaders.compile(shader);
    var ok: i32 = 0;
    gl.shaders.getParameter(shader, .compile_status, @ptrCast(&ok));
    if (ok == 0) {
        var log: [512]u8 = undefined;
        const len = gl.shaders.getInfoLog(shader, &log);
        _ = len;
    }
    return shader;
}

/// Deletes a shader tracked by a generated wrapper and resets its state.
/// Parameters:
/// - id: pointer to the stored shader id.
/// - initialized: pointer to the stored initialization flag.
/// Returns: void.
pub fn disposeShader(id: *u32, initialized: *bool) void {
    if (id.* != 0) {
        gl.shaders.delete(id.*);
        id.* = 0;
        initialized.* = false;
    }
}

test "shader runtime decls analyze" {
    std.testing.refAllDecls(@This());
}
