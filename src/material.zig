/// Standard library import.
const std = @import("std");
/// Shader program factory imports.
const ShaderProgramFn = @import("shader_program.zig").ShaderProgram;
const VertexProgramFn = @import("shader_program.zig").VertexProgram;
/// Compile-time type metadata import.
const gpu_meta = @import("gpu_meta.zig");

/// Validates that `U` is a shader-owned uniform struct and returns its owner.
///
/// `U` must be the `Uniform` struct of a shader descriptor, i.e. it must
/// declare `pub const Owner` pointing back at that descriptor, and
/// `Owner.Uniform` must be exactly `U`. The owner must expose the minimal
/// descriptor API consumed by `Material`/`VertexMaterial` (`Uniform`,
/// `instance`, `edit`, `Editor` with `setUniform`/`apply`; `Vertex` is
/// optional and only needed for mesh compatibility checks).
/// Parameters:
/// - U: uniform struct type to validate (explicit factory type argument).
/// - param_name: factory parameter name for error messages.
///
/// Returns: the owner shader descriptor type.
fn checkShaderOwner(comptime U: type, comptime param_name: []const u8) type {
    if (@typeInfo(U) != .@"struct") @compileError("Material: '" ++ param_name ++ "' must be a shader Uniform struct type (e.g. MyVert.Uniform), got " ++ @typeName(U) ++ ". Pass the Uniform type explicitly.");
    if (!@hasDecl(U, "Owner")) @compileError("Material: '" ++ param_name ++ "' has type " ++ @typeName(U) ++ " without `pub const Owner`. Add `pub const Owner = <its shader>;` inside the Uniform struct (the generator emits it automatically; handwritten descriptors must add it by hand), so Material can find the ShaderProgram.");
    const Owner = U.Owner;
    if (@typeInfo(Owner) != .@"struct") @compileError("Material: '" ++ param_name ++ "' Owner must be the shader descriptor struct, got " ++ @typeName(Owner) ++ ".");
    if (Owner.Uniform != U) @compileError("Material: '" ++ param_name ++ "' type " ++ @typeName(U) ++ " does not belong to its Owner " ++ @typeName(Owner) ++ " (Owner.Uniform differs). Pass exactly Owner.Uniform.");
    if (!@hasDecl(Owner, "instance") or @typeInfo(@TypeOf(Owner.instance)) != .@"fn") @compileError("Material: shader " ++ @typeName(Owner) ++ " must expose `pub fn instance() u32`.");
    if (!@hasDecl(Owner, "edit") or @typeInfo(@TypeOf(Owner.edit)) != .@"fn") @compileError("Material: shader " ++ @typeName(Owner) ++ " must expose `pub fn edit(u32) Editor`.");
    if (!@hasDecl(Owner, "Editor")) @compileError("Material: shader " ++ @typeName(Owner) ++ " must expose `pub const Editor`.");
    if (!@hasDecl(Owner.Editor, "setUniform") or !@hasDecl(Owner.Editor, "apply")) @compileError("Material: shader " ++ @typeName(Owner) ++ ".Editor must expose `setUniform` and `apply`.");
    return Owner;
}

/// Resolves a uniform field id by name with a type check.
/// Shared by the vertex and fragment accessors of both material kinds.
/// Parameters:
/// - U: explicit uniform struct type.
/// - field_name: comptime field name to find.
/// - F: comptime expected field type.
///
/// Returns: field id, `FieldNotFound` or `FieldTypeMismatch`.
fn uniformFieldIdByName(comptime U: type, comptime field_name: []const u8, comptime F: type) gpu_meta.ResourceError!u32 {
    return gpu_meta.uniformFieldIdByName(comptime gpu_meta.uniformFields(U), field_name, gpu_meta.typeId(F));
}

/// Writes one uniform field by id.
/// Shared by the vertex and fragment setters of both material kinds.
/// Parameters:
/// - U: explicit uniform struct type.
/// - uniform: pointer to the cached uniform value.
/// - field_id: id from the matching `uniformFieldIdByName`.
/// - data: value whose type must match the field type.
///
/// Returns: `UnknownFieldId` or `FieldTypeMismatch`/`SizeMismatch` on failure.
fn writeUniformField(comptime U: type, uniform: *U, field_id: u32, data: anytype) gpu_meta.ResourceError!void {
    const fields = comptime gpu_meta.uniformFields(U);
    if (field_id >= fields.len) return error.UnknownFieldId;
    try gpu_meta.writeField(uniform, fields[field_id], gpu_meta.typeId(@TypeOf(data)), std.mem.asBytes(&data));
}

/// Reads one uniform field by id.
/// Shared by the vertex and fragment getters of both material kinds.
/// Parameters:
/// - U: explicit uniform struct type.
/// - uniform: pointer to the cached uniform value.
/// - field_id: id from the matching `uniformFieldIdByName`.
/// - T: comptime expected field type.
///
/// Returns: field value copy, or `UnknownFieldId`/`FieldTypeMismatch` on failure.
fn readUniformField(comptime U: type, uniform: *U, field_id: u32, comptime T: type) gpu_meta.ResourceError!T {
    const fields = comptime gpu_meta.uniformFields(U);
    if (field_id >= fields.len) return error.UnknownFieldId;
    if (fields[field_id].type_id != gpu_meta.typeId(T)) return error.FieldTypeMismatch;
    var out: T = undefined;
    try gpu_meta.readField(uniform, fields[field_id], gpu_meta.typeId(T), std.mem.asBytes(&out));
    return out;
}

/// Uploads the vertex uniform through the program editor.
/// Shared by the `use` of both material kinds.
/// Parameters:
/// - Prog: concrete program type (`ShaderProgram` or `VertexProgram`).
/// - vert_uniform: cached vertex uniform value.
///
/// Returns: void.
fn uploadVertUniform(comptime Prog: type, vert_uniform: Prog.Vert.Uniform) void {
    var ve = Prog.vertEdit();
    _ = ve.setUniform(vert_uniform);
    ve.apply();
}

/// Uploads the fragment uniform through the program editor.
/// Used only by the full `Material` (concrete `ShaderProgram`).
/// Parameters:
/// - Prog: concrete `ShaderProgram` type.
/// - frag_uniform: cached fragment uniform value.
///
/// Returns: void.
fn uploadFragUniform(comptime Prog: type, frag_uniform: Prog.Frag.Uniform) void {
    var fe = Prog.fragEdit();
    _ = fe.setUniform(frag_uniform);
    fe.apply();
}

/// Creates a material type from explicit uniform types and default values.
///
/// The material is a plain struct with mutable fields: create instances
/// directly from the type (`var m: M = .{}`), no allocator, no create/destroy.
/// Each call with different comptime data produces a unique material type
/// (defaults differ); calls sharing the same shader descriptors reuse one
/// comptime-singleton `ShaderProgram` under the hood.
/// All types are explicit parameters instead of `@TypeOf(value)`,
/// so the resulting struct fields have directly named types.
/// Parameters:
/// - vert_uniform: vertex `Uniform` type of a shader descriptor.
///   The type must declare `pub const Owner` pointing at its shader
///   (the `.vert` generator emits the Uniform as a sibling `X_Uniform`
///   struct with the back-reference; handwritten shaders follow the same
///   shape because a nested self-reference is rejected by the compiler):
///   ```zig
///   const MyVertUniform = struct {
///       pub const Owner = MyVert;
///       uMvp: Mat,
///   };
///   const MyVert = struct {
///       pub const Uniform = MyVertUniform;
///       // ...
///   };
///   ```
///   The owner must expose `Uniform`, `IdCache`, `instance`, `edit`,
///   `Editor` with `setUniform`/`apply`.
/// - vert_uniform_value: default vertex uniform value of type `vert_uniform`.
///   Must be comptime-known plain data; resource bindings
///   (`*const Texture`, uniform-block buffers) cannot be comptime
///   defaults — pass `undefined` for them and assign on the instance
///   before `use()`.
/// - frag_uniform: fragment `Uniform` type with the same rules as above.
/// - frag_uniform_value: default fragment uniform value of type `frag_uniform`.
///
/// Returns: material struct type with `vertUniform`/`fragUniform` defaulted
/// to the passed values.
///
/// Example:
/// ```zig
/// const M = Material(MyVert.Uniform, .{ .uMvp = mvp, .uTex = undefined }, MyFrag.Uniform, .{ .uColor = white });
/// var m: M = .{};
/// m.vertUniform.uTex = &tex;
/// m.use();
/// ```
pub fn Material(
    comptime vert_uniform: type,
    comptime vert_uniform_value: vert_uniform,
    comptime frag_uniform: type,
    comptime frag_uniform_value: frag_uniform,
) type {
    const Vert = checkShaderOwner(vert_uniform, "vert_uniform");
    const Frag = checkShaderOwner(frag_uniform, "frag_uniform");
    const Prog = ShaderProgramFn(Vert, Frag);

    return struct {
        /// Self alias for internal use.
        const Self = @This();
        /// Singleton shader program derived from the uniform owners.
        pub const ShaderProgram = Prog;
        /// Always true: this material has a fragment stage.
        pub const HasFrag = true;
        /// Vertex uniform type alias (explicit `vert_uniform` parameter).
        pub const VertUniformT = vert_uniform;
        /// Fragment uniform type alias (explicit `frag_uniform` parameter).
        pub const FragUniformT = frag_uniform;

        /// Cached vertex uniform values (defaults from `vert_uniform_value`).
        vertUniform: vert_uniform = vert_uniform_value,
        /// Cached fragment uniform values (defaults from `frag_uniform_value`).
        fragUniform: frag_uniform = frag_uniform_value,

        /// Errors for name/id based uniform field access.
        pub const UniformFieldError = gpu_meta.ResourceError;

        /// Resolves a vertex uniform field id by name with a type check.
        /// `field_id` is the field index inside `vert_uniform`.
        /// Parameters:
        /// - field_name: comptime field name to find.
        /// - F: comptime expected field type.
        ///
        /// Returns: field id, `FieldNotFound` or `FieldTypeMismatch`.
        pub fn getVertUniformFieldId(comptime field_name: []const u8, comptime F: type) UniformFieldError!u32 {
            return uniformFieldIdByName(vert_uniform, field_name, F);
        }

        /// Writes one vertex uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getVertUniformFieldId`.
        /// - data: value whose type must match the field type.
        ///
        /// Returns: `UnknownFieldId` or `FieldTypeMismatch`/`SizeMismatch` on failure.
        pub fn setVertUniformData(self: *Self, field_id: u32, data: anytype) UniformFieldError!void {
            try writeUniformField(vert_uniform, &self.vertUniform, field_id, data);
        }

        /// Reads one vertex uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getVertUniformFieldId`.
        /// - T: comptime expected field type.
        ///
        /// Returns: field value copy, or `UnknownFieldId`/`FieldTypeMismatch` on failure.
        pub fn getVertUniformData(self: *Self, field_id: u32, comptime T: type) UniformFieldError!T {
            return readUniformField(vert_uniform, &self.vertUniform, field_id, T);
        }

        /// Resolves a fragment uniform field id by name with a type check.
        /// `field_id` is the field index inside `frag_uniform`.
        /// Parameters:
        /// - field_name: comptime field name to find.
        /// - F: comptime expected field type.
        ///
        /// Returns: field id, `FieldNotFound` or `FieldTypeMismatch`.
        pub fn getFragUniformFieldId(comptime field_name: []const u8, comptime F: type) UniformFieldError!u32 {
            return uniformFieldIdByName(frag_uniform, field_name, F);
        }

        /// Writes one fragment uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getFragUniformFieldId`.
        /// - data: value whose type must match the field type.
        ///
        /// Returns: `UnknownFieldId` or `FieldTypeMismatch`/`SizeMismatch` on failure.
        pub fn setFragUniformData(self: *Self, field_id: u32, data: anytype) UniformFieldError!void {
            try writeUniformField(frag_uniform, &self.fragUniform, field_id, data);
        }

        /// Reads one fragment uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getFragUniformFieldId`.
        /// - T: comptime expected field type.
        ///
        /// Returns: field value copy, or `UnknownFieldId`/`FieldTypeMismatch` on failure.
        pub fn getFragUniformData(self: *Self, field_id: u32, comptime T: type) UniformFieldError!T {
            return readUniformField(frag_uniform, &self.fragUniform, field_id, T);
        }

        /// Binds the program and uploads uniforms via editors.
        /// Dynamic per-frame uniform updates are the caller's job: write the
        /// `vertUniform` / `fragUniform` fields (or field setters)
        /// before calling `use`, e.g. from an explicit ECS system.
        /// Parameters:
        /// - self: material pointer.
        ///
        /// Returns: void.
        pub fn use(self: *Self) void {
            Prog.use();
            uploadVertUniform(Prog, self.vertUniform);
            uploadFragUniform(Prog, self.fragUniform);
        }
    };
}

/// Creates a vertex-only material type from an explicit uniform type and default.
///
/// Same rules as `Material` (plain struct, no allocator, comptime-singleton
/// program), but bound to a `VertexProgram`: no fragment stage, no
/// `fragUniform` field, no `FragUniformT` alias, no fragment accessors.
/// See `Material` for the `Owner` shape requirements.
/// Parameters:
/// - vert_uniform: vertex `Uniform` type of a shader descriptor.
/// - vert_uniform_value: default vertex uniform value of type `vert_uniform`
///   (same comptime-data rules as in `Material`).
///
/// Returns: material struct type with `vertUniform` defaulted to the passed value.
///
/// Example:
/// ```zig
/// const M = VertexMaterial(MyVert.Uniform, .{ .uMvp = mvp });
/// var m: M = .{};
/// m.use();
/// ```
pub fn VertexMaterial(comptime vert_uniform: type, comptime vert_uniform_value: vert_uniform) type {
    const Vert = checkShaderOwner(vert_uniform, "vert_uniform");
    const Prog = VertexProgramFn(Vert);

    return struct {
        /// Self alias for internal use.
        const Self = @This();
        /// Singleton vertex program derived from the uniform owner.
        pub const ShaderProgram = Prog;
        /// Always false: this material has no fragment stage.
        pub const HasFrag = false;
        /// Vertex uniform type alias (explicit `vert_uniform` parameter).
        pub const VertUniformT = vert_uniform;

        /// Cached vertex uniform values (defaults from `vert_uniform_value`).
        vertUniform: vert_uniform = vert_uniform_value,

        /// Errors for name/id based uniform field access.
        pub const UniformFieldError = gpu_meta.ResourceError;

        /// Resolves a vertex uniform field id by name with a type check.
        /// `field_id` is the field index inside `vert_uniform`.
        /// Parameters:
        /// - field_name: comptime field name to find.
        /// - F: comptime expected field type.
        ///
        /// Returns: field id, `FieldNotFound` or `FieldTypeMismatch`.
        pub fn getVertUniformFieldId(comptime field_name: []const u8, comptime F: type) UniformFieldError!u32 {
            return uniformFieldIdByName(vert_uniform, field_name, F);
        }

        /// Writes one vertex uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getVertUniformFieldId`.
        /// - data: value whose type must match the field type.
        ///
        /// Returns: `UnknownFieldId` or `FieldTypeMismatch`/`SizeMismatch` on failure.
        pub fn setVertUniformData(self: *Self, field_id: u32, data: anytype) UniformFieldError!void {
            try writeUniformField(vert_uniform, &self.vertUniform, field_id, data);
        }

        /// Reads one vertex uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getVertUniformFieldId`.
        /// - T: comptime expected field type.
        ///
        /// Returns: field value copy, or `UnknownFieldId`/`FieldTypeMismatch` on failure.
        pub fn getVertUniformData(self: *Self, field_id: u32, comptime T: type) UniformFieldError!T {
            return readUniformField(vert_uniform, &self.vertUniform, field_id, T);
        }

        /// Binds the program and uploads the vertex uniform via editor.
        /// Dynamic per-frame updates are the caller's job: write the
        /// `vertUniform` field (or field setters) before calling `use`.
        /// Parameters:
        /// - self: material pointer.
        ///
        /// Returns: void.
        pub fn use(self: *Self) void {
            Prog.use();
            uploadVertUniform(Prog, self.vertUniform);
        }
    };
}

// File-scope doubles: `Owner` forward-references require container scope
// (function-local forward refs are rejected), mirroring generated shaders.
const DummyVertUniform = struct {
    pub const Owner = DummyVert;
    uA: f32,
    uB: i32,
};
const DummyVert = struct {
    pub const Uniform = DummyVertUniform;
    pub const IdCache = struct { uA: i32, uB: i32 };
    pub const Editor = struct {
        pub fn setUniform(self: *@This(), u: Uniform) *@This() {
            _ = u;
            return self;
        }
        pub fn apply(self: *@This()) void {
            _ = self;
        }
    };
    pub fn instance() u32 {
        return 0;
    }
    pub fn edit(_: u32) Editor {
        return .{};
    }
};
const DummyFragUniform = struct {
    pub const Owner = DummyFrag;
    uC: u32,
};
const DummyFrag = struct {
    pub const Uniform = DummyFragUniform;
    pub const IdCache = struct { uC: i32 };
    pub const Editor = struct {
        pub fn setUniform(self: *@This(), u: Uniform) *@This() {
            _ = u;
            return self;
        }
        pub fn apply(self: *@This()) void {
            _ = self;
        }
    };
    pub fn instance() u32 {
        return 0;
    }
    pub fn edit(_: u32) Editor {
        return .{};
    }
};

test "material from uniform types, defaults and uniqueness" {
    const M = Material(DummyVert.Uniform, .{ .uA = 1.0, .uB = 2 }, DummyFrag.Uniform, .{ .uC = 3 });
    var self: M = .{};
    // Factory values become instance defaults.
    try std.testing.expectEqual(@as(f32, 1.0), self.vertUniform.uA);
    try std.testing.expectEqual(@as(u32, 3), self.fragUniform.uC);
    try std.testing.expect(M.HasFrag);
    // Instances are mutable directly.
    self.vertUniform.uA = 5.0;
    try std.testing.expectEqual(@as(f32, 5.0), self.vertUniform.uA);

    // Same shaders, different data -> unique material, shared program.
    const M2 = Material(DummyVert.Uniform, .{ .uA = 9.0, .uB = 2 }, DummyFrag.Uniform, .{ .uC = 3 });
    try std.testing.expect(M != M2);
    try std.testing.expect(M.ShaderProgram == M2.ShaderProgram);
    const other: M2 = .{};
    try std.testing.expectEqual(@as(f32, 9.0), other.vertUniform.uA);

    const id_a = try M.getVertUniformFieldId("uA", f32);
    try std.testing.expectEqual(@as(f32, 5.0), try self.getVertUniformData(id_a, f32));
    try self.setVertUniformData(id_a, @as(f32, 2.5));
    try std.testing.expectEqual(@as(f32, 2.5), self.vertUniform.uA);

    const id_b = try M.getVertUniformFieldId("uB", i32);
    try self.setVertUniformData(id_b, @as(i32, -4));
    try std.testing.expectEqual(@as(i32, -4), try self.getVertUniformData(id_b, i32));

    const id_c = try M.getFragUniformFieldId("uC", u32);
    try self.setFragUniformData(id_c, @as(u32, 9));
    try std.testing.expectEqual(@as(u32, 9), try self.getFragUniformData(id_c, u32));

    try std.testing.expectError(error.FieldNotFound, M.getVertUniformFieldId("nope", f32));
    try std.testing.expectError(error.FieldTypeMismatch, M.getVertUniformFieldId("uA", i32));
    try std.testing.expectError(error.UnknownFieldId, self.getVertUniformData(99, f32));
    try std.testing.expectError(error.FieldTypeMismatch, self.getVertUniformData(id_a, i32));
    try std.testing.expectError(error.UnknownFieldId, self.setFragUniformData(7, @as(u32, 1)));
}

test "vertex material from uniform type and default" {
    const MV = VertexMaterial(DummyVert.Uniform, .{ .uA = 0.5, .uB = -1 });
    try std.testing.expect(!MV.HasFrag);
    try std.testing.expect(!@hasDecl(MV, "FragUniformT"));
    const vonly: MV = .{};
    try std.testing.expectEqual(@as(f32, 0.5), vonly.vertUniform.uA);

    var self: MV = .{};
    const id_a = try MV.getVertUniformFieldId("uA", f32);
    try std.testing.expectEqual(@as(f32, 0.5), try self.getVertUniformData(id_a, f32));
    try self.setVertUniformData(id_a, @as(f32, 2.5));
    try std.testing.expectEqual(@as(f32, 2.5), self.vertUniform.uA);

    try std.testing.expectError(error.FieldNotFound, MV.getVertUniformFieldId("nope", f32));
    try std.testing.expectError(error.UnknownFieldId, self.getVertUniformData(99, f32));
}
