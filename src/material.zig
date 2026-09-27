/// Standard library import.
const std = @import("std");
/// Shader program factory import.
const ShaderProgramFn = @import("shader_program.zig").ShaderProgram;
/// Compile-time type metadata import.
const gpu_meta = @import("gpu_meta.zig");

/// Validates that `U` is a shader-owned uniform struct and returns its owner.
///
/// `U` must be the `Uniform` struct of a shader descriptor, i.e. it must
/// declare `pub const Owner` pointing back at that descriptor, and
/// `Owner.Uniform` must be exactly `U`. The owner must expose the minimal
/// descriptor API consumed by `Material`/`ShaderProgram` (`Uniform`,
/// `instance`, `edit`, `Editor` with `setUniform`/`apply`; `Vertex` is
/// optional and only needed for mesh compatibility checks).
/// Parameters:
/// - U: uniform struct type to validate.
/// - param_name: factory parameter name for error messages.
///
/// Returns: the owner shader descriptor type.
fn checkShaderOwner(comptime U: type, comptime param_name: []const u8) type {
    if (@typeInfo(U) != .@"struct") @compileError("Material: '" ++ param_name ++ "' must be a shader Uniform struct value (e.g. MyVert.Uniform{ ... }), got " ++ @typeName(U) ++ ". Pass a filled Uniform value; pass null only for 'frag_uniform'.");
    if (!@hasDecl(U, "Owner")) @compileError("Material: '" ++ param_name ++ "' has type " ++ @typeName(U) ++ " without `pub const Owner`. Add `pub const Owner = <its shader>;` inside the Uniform struct (the generator emits it automatically; handwritten descriptors must add it by hand), so Material can find the ShaderProgram.");
    const Owner = U.Owner;
    if (@typeInfo(Owner) != .@"struct") @compileError("Material: '" ++ param_name ++ "' Owner must be the shader descriptor struct, got " ++ @typeName(Owner) ++ ".");
    if (Owner.Uniform != U) @compileError("Material: '" ++ param_name ++ "' value of type " ++ @typeName(U) ++ " does not belong to its Owner " ++ @typeName(Owner) ++ " (Owner.Uniform differs). Pass a value of exactly Owner.Uniform.");
    if (!@hasDecl(Owner, "instance") or @typeInfo(@TypeOf(Owner.instance)) != .@"fn") @compileError("Material: shader " ++ @typeName(Owner) ++ " must expose `pub fn instance() u32`.");
    if (!@hasDecl(Owner, "edit") or @typeInfo(@TypeOf(Owner.edit)) != .@"fn") @compileError("Material: shader " ++ @typeName(Owner) ++ " must expose `pub fn edit(u32) Editor`.");
    if (!@hasDecl(Owner, "Editor")) @compileError("Material: shader " ++ @typeName(Owner) ++ " must expose `pub const Editor`.");
    if (!@hasDecl(Owner.Editor, "setUniform") or !@hasDecl(Owner.Editor, "apply")) @compileError("Material: shader " ++ @typeName(Owner) ++ ".Editor must expose `setUniform` and `apply`.");
    return Owner;
}

/// Creates a material type from filled shader uniform values.
///
/// The material is a plain struct with mutable fields: create instances
/// directly from the type (`var m: M = .{}`), no allocator, no create/destroy.
/// Each call with different comptime data produces a unique material type
/// (defaults differ); calls sharing the same shader descriptors reuse one
/// comptime-singleton `ShaderProgram` under the hood.
/// Parameters:
/// - vert_uniform: filled vertex `Uniform` value of a shader descriptor.
///   The value type must declare `pub const Owner` pointing at its shader
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
///   The owner must expose `Uniform`, `instance`, `edit`, `Editor`
///   with `setUniform`/`apply`. The value must be comptime-known plain
///   data; resource bindings (`*const Texture`, uniform-block buffers)
///   cannot be comptime defaults — pass `undefined` for them and assign
///   on the instance before `use()`.
/// - frag_uniform: filled fragment `Uniform` value with the same rules as
///   above, or literal `null` for a vertex-only program.
///
/// Returns: material struct type with `vertUniform`/`fragUniform` defaulted
/// to the passed values.
///
/// Example:
/// ```zig
/// const M = Material(.{ .uMvp = mvp, .uTex = undefined }, null);
/// var m: M = .{};
/// m.vertUniform.uTex = &tex;
/// m.use();
/// ```
pub fn Material(comptime vert_uniform: anytype, comptime frag_uniform: anytype) type {
    const VertUniform = @TypeOf(vert_uniform);
    const Vert = checkShaderOwner(VertUniform, "vert_uniform");
    const has_frag = @typeInfo(@TypeOf(frag_uniform)) != .null;
    const FragUniform = if (has_frag) @TypeOf(frag_uniform) else struct {};
    const Frag = if (has_frag) checkShaderOwner(FragUniform, "frag_uniform") else null;
    const Prog = ShaderProgramFn(Vert, Frag);

    return struct {
        /// Self alias for internal use.
        const Self = @This();
        /// Singleton shader program derived from the uniform owners.
        pub const ShaderProgram = Prog;
        /// True when a fragment stage is configured.
        pub const HasFrag = has_frag;
        /// Vertex uniform type alias.
        pub const VertUniformT = VertUniform;
        /// Fragment uniform type alias.
        pub const FragUniformT = FragUniform;

        /// Cached vertex uniform values (defaults from the factory call).
        vertUniform: VertUniform = vert_uniform,
        /// Cached fragment uniform values (defaults from the factory call).
        fragUniform: FragUniform = if (has_frag) frag_uniform else .{},

        /// Errors for name/id based uniform field access.
        pub const UniformFieldError = gpu_meta.ResourceError;

        /// Resolves a vertex uniform field id by name with a type check.
        /// `field_id` is the field index inside `VertUniform`.
        /// Parameters:
        /// - field_name: comptime field name to find.
        /// - F: comptime expected field type.
        ///
        /// Returns: field id, `FieldNotFound` or `FieldTypeMismatch`.
        pub fn getVertUniformFieldId(comptime field_name: []const u8, comptime F: type) UniformFieldError!u32 {
            return gpu_meta.uniformFieldIdByName(comptime gpu_meta.uniformFields(VertUniform), field_name, gpu_meta.typeId(F));
        }

        /// Writes one vertex uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getVertUniformFieldId`.
        /// - data: value whose type must match the field type.
        ///
        /// Returns: `UnknownFieldId` or `FieldTypeMismatch`/`SizeMismatch` on failure.
        pub fn setVertUniformData(self: *Self, field_id: u32, data: anytype) UniformFieldError!void {
            const fields = comptime gpu_meta.uniformFields(VertUniform);
            if (field_id >= fields.len) return error.UnknownFieldId;
            try gpu_meta.writeField(&self.vertUniform, fields[field_id], gpu_meta.typeId(@TypeOf(data)), std.mem.asBytes(&data));
        }

        /// Reads one vertex uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getVertUniformFieldId`.
        /// - T: comptime expected field type.
        ///
        /// Returns: field value copy, or `UnknownFieldId`/`FieldTypeMismatch` on failure.
        pub fn getVertUniformData(self: *Self, field_id: u32, comptime T: type) UniformFieldError!T {
            const fields = comptime gpu_meta.uniformFields(VertUniform);
            if (field_id >= fields.len) return error.UnknownFieldId;
            if (fields[field_id].type_id != gpu_meta.typeId(T)) return error.FieldTypeMismatch;
            var out: T = undefined;
            try gpu_meta.readField(&self.vertUniform, fields[field_id], gpu_meta.typeId(T), std.mem.asBytes(&out));
            return out;
        }

        /// Resolves a fragment uniform field id by name with a type check.
        /// `field_id` is the field index inside `FragUniform`.
        /// Parameters:
        /// - field_name: comptime field name to find.
        /// - F: comptime expected field type.
        ///
        /// Returns: field id, `FieldNotFound` or `FieldTypeMismatch`.
        pub fn getFragUniformFieldId(comptime field_name: []const u8, comptime F: type) UniformFieldError!u32 {
            return gpu_meta.uniformFieldIdByName(comptime gpu_meta.uniformFields(FragUniform), field_name, gpu_meta.typeId(F));
        }

        /// Writes one fragment uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getFragUniformFieldId`.
        /// - data: value whose type must match the field type.
        ///
        /// Returns: `UnknownFieldId` or `FieldTypeMismatch`/`SizeMismatch` on failure.
        pub fn setFragUniformData(self: *Self, field_id: u32, data: anytype) UniformFieldError!void {
            const fields = comptime gpu_meta.uniformFields(FragUniform);
            if (field_id >= fields.len) return error.UnknownFieldId;
            try gpu_meta.writeField(&self.fragUniform, fields[field_id], gpu_meta.typeId(@TypeOf(data)), std.mem.asBytes(&data));
        }

        /// Reads one fragment uniform field by id.
        /// Parameters:
        /// - self: material pointer.
        /// - field_id: id from `getFragUniformFieldId`.
        /// - T: comptime expected field type.
        ///
        /// Returns: field value copy, or `UnknownFieldId`/`FieldTypeMismatch` on failure.
        pub fn getFragUniformData(self: *Self, field_id: u32, comptime T: type) UniformFieldError!T {
            const fields = comptime gpu_meta.uniformFields(FragUniform);
            if (field_id >= fields.len) return error.UnknownFieldId;
            if (fields[field_id].type_id != gpu_meta.typeId(T)) return error.FieldTypeMismatch;
            var out: T = undefined;
            try gpu_meta.readField(&self.fragUniform, fields[field_id], gpu_meta.typeId(T), std.mem.asBytes(&out));
            return out;
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
            var ve = Prog.vertEdit();
            _ = ve.setUniform(self.vertUniform);
            ve.apply();
            if (has_frag) {
                var fe = Prog.fragEdit();
                _ = fe.setUniform(self.fragUniform);
                fe.apply();
            }
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

test "material from uniform values, defaults and uniqueness" {
    const M = Material(DummyVert.Uniform{ .uA = 1.0, .uB = 2 }, DummyFrag.Uniform{ .uC = 3 });
    var self: M = .{};
    // Factory values become instance defaults.
    try std.testing.expectEqual(@as(f32, 1.0), self.vertUniform.uA);
    try std.testing.expectEqual(@as(u32, 3), self.fragUniform.uC);
    // Instances are mutable directly.
    self.vertUniform.uA = 5.0;
    try std.testing.expectEqual(@as(f32, 5.0), self.vertUniform.uA);

    // Same shaders, different data -> unique material, shared program.
    const M2 = Material(DummyVert.Uniform{ .uA = 9.0, .uB = 2 }, DummyFrag.Uniform{ .uC = 3 });
    try std.testing.expect(M != M2);
    try std.testing.expect(M.ShaderProgram == M2.ShaderProgram);
    const other: M2 = .{};
    try std.testing.expectEqual(@as(f32, 9.0), other.vertUniform.uA);

    // Vertex-only material via null.
    const MV = Material(DummyVert.Uniform{ .uA = 0.5, .uB = -1 }, null);
    try std.testing.expect(!MV.HasFrag);
    const vonly: MV = .{};
    try std.testing.expectEqual(@as(f32, 0.5), vonly.vertUniform.uA);

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
