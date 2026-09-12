/// Standard library import.
const std = @import("std");

/// Errors for name/id based field access on uniform structs and uploads.
pub const ResourceError = error{
    /// No field with the given name.
    FieldNotFound,
    /// Field exists but its type differs from the requested one.
    FieldTypeMismatch,
    /// No field with the given numeric id.
    UnknownFieldId,
    /// Byte slice length does not match the field/uniform size.
    SizeMismatch,
    /// Field kind cannot be handled without the concrete type
    /// (sampler, uniform block buffer, nested struct, array).
    UnsupportedUniformField,
};

/// Returns a runtime-unique identity for a type.
///
/// Implemented as a 64-bit hash of the fully qualified `@typeName`, so it is
/// a pure function: identical at comptime (descriptor baking) and at runtime
/// (`anytype` validation) without any global state. Two types share an id
/// only on hash collision or when their declarations are textually identical
/// (indistinguishable anonymous shapes) — both byte-copy safe for the
/// validated memcpy use case.
/// Parameters:
/// - `T`: type to identify.
///
/// Returns: id for `T` within this binary.
pub fn typeId(comptime T: type) usize {
    return @truncate(std.hash.Wyhash.hash(0, @typeName(T)));
}

/// Compile-time description of one struct field.
pub const FieldDesc = struct {
    /// Field name.
    name: []const u8,
    /// `@typeName` of the field type.
    type_name: []const u8,
    /// `@sizeOf` the field type.
    size: usize,
    /// `@alignOf` the field type.
    alignment: usize,
};

/// Compile-time description of a type, kept at runtime for comparisons.
pub const TypeDesc = struct {
    /// `@typeName` of the type.
    name: []const u8,
    /// `@sizeOf` the type.
    size: usize,
    /// `@alignOf` the type.
    alignment: usize,
    /// Field descriptors for structs, empty otherwise. Points at static memory.
    fields: []const FieldDesc,
};

/// Builds a `TypeDesc` for any type. Field slices point at static memory and
/// stay valid forever; no allocation happens. Call with `comptime` (all inputs
/// are comptime-known), mirroring `computeLayout` in `mesh.zig`.
/// Parameters:
/// - `T`: type to describe.
///
/// Returns: runtime-usable description of `T`.
pub fn describe(comptime T: type) TypeDesc {
    const ti = @typeInfo(T);
    if (ti != .@"struct") {
        return .{ .name = @typeName(T), .size = @sizeOf(T), .alignment = @alignOf(T), .fields = &.{} };
    }
    var acc: []const FieldDesc = &.{};
    inline for (ti.@"struct".fields) |f| {
        acc = acc ++ [_]FieldDesc{.{
            .name = f.name,
            .type_name = @typeName(f.type),
            .size = @sizeOf(f.type),
            .alignment = @alignOf(f.type),
        }};
    }
    return .{ .name = @typeName(T), .size = @sizeOf(T), .alignment = @alignOf(T), .fields = acc };
}

/// Finds a field index by name.
/// Parameters:
/// - fields: field descriptors to search.
/// - name: field name to find.
///
/// Returns: field index, or null when absent.
pub fn fieldIndexByName(fields: []const FieldDesc, name: []const u8) ?u32 {
    for (fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    }
    return null;
}

/// Checks two field lists for compatibility (same names with same types).
/// Order-insensitive: every field of `a` must exist in `b` with an equal
/// `type_name` and `size`, and vice versa.
/// Parameters:
/// - a: first field list.
/// - b: second field list.
///
/// Returns: true when the lists describe the same shape.
pub fn fieldsCompatible(a: []const FieldDesc, b: []const FieldDesc) bool {
    if (a.len != b.len) return false;
    for (a) |fa| {
        var ok = false;
        for (b) |fb| {
            if (std.mem.eql(u8, fa.name, fb.name) and std.mem.eql(u8, fa.type_name, fb.type_name) and fa.size == fb.size) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
    }
    return true;
}

/// Checks whether every field of `need` exists in `have` with an equal type.
/// Used for "does this mesh satisfy the shader vertex inputs" checks.
/// Parameters:
/// - need: required field list (e.g. shader inputs).
/// - have: provided field list (e.g. mesh vertex fields).
///
/// Returns: true when all required fields are present with matching types.
pub fn fieldsSatisfiedBy(need: []const FieldDesc, have: []const FieldDesc) bool {
    for (need) |fn_need| {
        var ok = false;
        for (have) |fh| {
            if (std.mem.eql(u8, fn_need.name, fh.name) and std.mem.eql(u8, fn_need.type_name, fh.type_name) and fn_need.size == fh.size) {
                ok = true;
                break;
            }
        }
        if (!ok) return false;
    }
    return true;
}

/// Classifies a uniform field type for direct GL upload.
///
/// Plain data kinds (`f32` … `mat2x3`) can be uploaded from raw bytes without
/// knowing the concrete Zig type. Everything else (samplers, uniform block
/// buffers, nested structs, arrays) is `other` and requires the typed path.
pub const UniformKind = enum {
    f32,
    i32,
    u32,
    boolean,
    vec1f,
    vec2f,
    vec3f,
    vec4f,
    vec1i,
    vec2i,
    vec3i,
    vec4i,
    vec1u,
    vec2u,
    vec3u,
    vec4u,
    mat2,
    mat3,
    mat4,
    mat3x2,
    mat2x3,
    other,
};

/// Classifies a uniform field type.
/// Parameters:
/// - `T`: field type to classify.
///
/// Returns: upload kind, or `other` for resource/aggregate types.
pub fn uniformKindOf(comptime T: type) UniformKind {
    if (T == f32) return .f32;
    if (T == i32) return .i32;
    if (T == u32) return .u32;
    if (T == bool) return .boolean;
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "len") and @hasDecl(T, "value_type")) {
        const len = T.len;
        if (T.value_type == f32) return switch (len) {
            1 => .vec1f,
            2 => .vec2f,
            3 => .vec3f,
            4 => .vec4f,
            else => .other,
        };
        if (T.value_type == i32) return switch (len) {
            1 => .vec1i,
            2 => .vec2i,
            3 => .vec3i,
            4 => .vec4i,
            else => .other,
        };
        if (T.value_type == u32) return switch (len) {
            1 => .vec1u,
            2 => .vec2u,
            3 => .vec3u,
            4 => .vec4u,
            else => .other,
        };
        return .other;
    }
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "cols") and @hasDecl(T, "rows") and @hasDecl(T, "value_type")) {
        if (T.value_type != f32) return .other;
        if (T.cols == 2 and T.rows == 2) return .mat2;
        if (T.cols == 3 and T.rows == 3) return .mat3;
        if (T.cols == 4 and T.rows == 4) return .mat4;
        if (T.cols == 3 and T.rows == 2) return .mat3x2;
        if (T.cols == 2 and T.rows == 3) return .mat2x3;
        return .other;
    }
    return .other;
}

/// Returns the exact byte size of a plain-data uniform kind.
/// Parameters:
/// - kind: uniform kind (must not be `other`).
///
/// Returns: byte size, or null for `other`.
pub fn uniformKindSize(kind: UniformKind) ?usize {
    return switch (kind) {
        .f32, .i32, .u32 => 4,
        .boolean => 1,
        .vec1f, .vec1i, .vec1u => 4,
        .vec2f, .vec2i, .vec2u => 8,
        .vec3f, .vec3i, .vec3u => 12,
        .vec4f, .vec4i, .vec4u => 16,
        .mat2 => 16,
        .mat3 => 36,
        .mat4 => 64,
        .mat3x2, .mat2x3 => 24,
        .other => null,
    };
}

/// Runtime description of one uniform struct field.
pub const UniformFieldDesc = struct {
    /// Field name (GLSL uniform name).
    name: []const u8,
    /// `typeId` of the field type.
    type_id: usize,
    /// `@sizeOf` the field type.
    size: usize,
    /// `@offsetOf` the field within the uniform struct.
    offset: usize,
    /// Upload classification.
    kind: UniformKind,
};

/// Builds uniform field descriptors for a uniform struct type.
/// Descriptors point at static memory; no allocation happens. Call with
/// `comptime` (all inputs are comptime-known).
/// Parameters:
/// - `U`: uniform struct type.
///
/// Returns: per-field descriptors in declaration order (`field_id` == index).
pub fn uniformFields(comptime U: type) []const UniformFieldDesc {
    if (@typeInfo(U) != .@"struct") @compileError("uniformFields expects a struct, got " ++ @typeName(U));
    var acc: []const UniformFieldDesc = &.{};
    inline for (@typeInfo(U).@"struct".fields) |f| {
        acc = acc ++ [_]UniformFieldDesc{.{
            .name = f.name,
            .type_id = typeId(f.type),
            .size = @sizeOf(f.type),
            .offset = @offsetOf(U, f.name),
            .kind = uniformKindOf(f.type),
        }};
    }
    return acc;
}

/// Resolves a uniform field id by name with a type check.
/// Parameters:
/// - fields: uniform field descriptors.
/// - name: field name to find.
/// - want_type_id: `typeId` of the expected field type.
///
/// Returns: field id, `FieldNotFound` or `FieldTypeMismatch`.
pub fn uniformFieldIdByName(fields: []const UniformFieldDesc, name: []const u8, want_type_id: usize) ResourceError!u32 {
    for (fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) {
            if (f.type_id != want_type_id) return error.FieldTypeMismatch;
            return @intCast(i);
        }
    }
    return error.FieldNotFound;
}

/// Writes raw bytes into one field of a struct value by descriptor.
/// Parameters:
/// - base: pointer to the struct value.
/// - desc: field descriptor.
/// - want_type_id: expected field type id for validation.
/// - bytes: exactly `desc.size` bytes to write.
///
/// Returns: `FieldTypeMismatch` / `SizeMismatch` on validation failure.
pub fn writeField(base: *anyopaque, desc: UniformFieldDesc, want_type_id: usize, bytes: []const u8) ResourceError!void {
    if (desc.type_id != want_type_id) return error.FieldTypeMismatch;
    if (bytes.len != desc.size) return error.SizeMismatch;
    const dst: [*]u8 = @ptrFromInt(@intFromPtr(base) + desc.offset);
    @memcpy(dst[0..desc.size], bytes);
}

/// Reads raw bytes of one field of a struct value by descriptor.
/// Parameters:
/// - base: const pointer to the struct value.
/// - desc: field descriptor.
/// - want_type_id: expected field type id for validation.
/// - out: buffer receiving exactly `desc.size` bytes.
///
/// Returns: `FieldTypeMismatch` / `SizeMismatch` on validation failure.
pub fn readField(base: *const anyopaque, desc: UniformFieldDesc, want_type_id: usize, out: []u8) ResourceError!void {
    if (desc.type_id != want_type_id) return error.FieldTypeMismatch;
    if (out.len != desc.size) return error.SizeMismatch;
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(base) + desc.offset);
    @memcpy(out[0..desc.size], src[0..desc.size]);
}

test "describe struct and scalars" {
    const S = struct { a: f32, b: u16 };
    const d = comptime describe(S);
    try std.testing.expectEqualStrings(@typeName(S), d.name);
    try std.testing.expectEqual(@sizeOf(S), d.size);
    try std.testing.expectEqual(@as(usize, 2), d.fields.len);
    try std.testing.expectEqualStrings("a", d.fields[0].name);
    try std.testing.expect(fieldsCompatible(d.fields, d.fields));
    try std.testing.expect(fieldsSatisfiedBy(d.fields[0..1], d.fields));
    try std.testing.expect(!fieldsSatisfiedBy(d.fields, d.fields[0..1]));
    const n = comptime describe(u32);
    try std.testing.expectEqual(@as(usize, 0), n.fields.len);
}

test "typeId unique per type" {
    try std.testing.expect(typeId(u32) == typeId(u32));
    try std.testing.expect(typeId(u32) != typeId(i32));
    try std.testing.expect(typeId(struct { x: f32 }) != typeId(struct { x: f32, y: f32 }));
}

test "uniform fields lookup and byte rw" {
    const U = struct { alpha: f32, count: i32 };
    const fields = comptime uniformFields(U);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    const id = try uniformFieldIdByName(fields, "count", typeId(i32));
    try std.testing.expectEqual(@as(u32, 1), id);
    try std.testing.expectError(error.FieldNotFound, uniformFieldIdByName(fields, "missing", typeId(i32)));
    try std.testing.expectError(error.FieldTypeMismatch, uniformFieldIdByName(fields, "count", typeId(f32)));

    var u = U{ .alpha = 0.5, .count = 3 };
    const raw: [4]u8 = @bitCast(@as(i32, 42));
    try writeField(&u, fields[1], typeId(i32), &raw);
    try std.testing.expectEqual(@as(i32, 42), u.count);
    var out: [4]u8 = undefined;
    try readField(&u, fields[1], typeId(i32), &out);
    try std.testing.expectEqualSlices(u8, &raw, &out);
    try std.testing.expectError(error.SizeMismatch, writeField(&u, fields[1], typeId(i32), raw[0..2]));
    try std.testing.expectError(error.FieldTypeMismatch, writeField(&u, fields[1], typeId(f32), &raw));
}
