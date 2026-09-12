/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");
/// Compile-time type metadata import.
const gpu_meta = @import("gpu_meta.zig");

/// Creates a material type bound to a specific shader program.
/// The material stores vertex and fragment uniforms and applies them via editors.
/// Parameters:
/// - shader_program_: shader program type providing Vert and optional Frag descriptors.
///
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
            /// Associated shader program instance.
            program: ?*ShaderProgram = null,
            /// Allocator used for program instance retrieval.
            allocator: std.mem.Allocator = undefined,
        };

        /// Returns mutable implementation pointer.
        /// Parameters:
        /// - self: material pointer.
        ///
        /// Returns: mutable Impl pointer.
        inline fn impl(self: *Self) *Impl {
            return @ptrCast(@alignCast(self));
        }
        /// Returns immutable implementation pointer.
        /// Parameters:
        /// - self: const material pointer.
        ///
        /// Returns: const Impl pointer.
        inline fn implConst(self: *const Self) *const Impl {
            return @ptrCast(@alignCast(self));
        }

        /// Creates a new material instance.
        /// Parameters:
        /// - allocator: allocator for storage and program instance.
        ///
        /// Returns: pointer to created material or error.
        pub fn create(allocator: std.mem.Allocator) !*Self {
            const m = try allocator.create(Impl);
            const prog = try ShaderProgram.instance(allocator);
            m.* = .{ .program = prog, .allocator = allocator };
            return @ptrCast(m);
        }
        /// Destroys the material and frees its storage.
        /// Parameters:
        /// - self: material to destroy.
        /// - allocator: allocator used for creation.
        ///
        /// Returns: void.
        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            allocator.destroy(self.impl());
        }

        /// Returns a copy of the cached vertex uniform.
        /// Parameters:
        /// - self: const material pointer.
        ///
        /// Returns: vertex uniform value.
        pub fn getVertUniform(self: *const Self) VertUniform {
            return self.implConst().vertUniform;
        }
        /// Returns a copy of the cached fragment uniform.
        /// Parameters:
        /// - self: const material pointer.
        ///
        /// Returns: fragment uniform value.
        pub fn getFragUniform(self: *const Self) FragUniform {
            return self.implConst().fragUniform;
        }
        /// Sets the cached vertex uniform.
        /// Parameters:
        /// - self: material pointer.
        /// - u: new vertex uniform value.
        ///
        /// Returns: void.
        pub fn setVertUniform(self: *Self, u: VertUniform) void {
            self.impl().vertUniform = u;
        }
        /// Sets the cached fragment uniform.
        /// Parameters:
        /// - self: material pointer.
        /// - u: new fragment uniform value.
        ///
        /// Returns: void.
        pub fn setFragUniform(self: *Self, u: FragUniform) void {
            self.impl().fragUniform = u;
        }

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
            try gpu_meta.writeField(&self.impl().vertUniform, fields[field_id], gpu_meta.typeId(@TypeOf(data)), std.mem.asBytes(&data));
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
            try gpu_meta.readField(&self.implConst().vertUniform, fields[field_id], gpu_meta.typeId(T), std.mem.asBytes(&out));
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
            try gpu_meta.writeField(&self.impl().fragUniform, fields[field_id], gpu_meta.typeId(@TypeOf(data)), std.mem.asBytes(&data));
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
            try gpu_meta.readField(&self.implConst().fragUniform, fields[field_id], gpu_meta.typeId(T), std.mem.asBytes(&out));
            return out;
        }

        /// Returns the associated shader program if present.
        /// Parameters:
        /// - self: const material pointer.
        ///
        /// Returns: optional program pointer.
        pub fn getProgram(self: *const Self) ?*ShaderProgram {
            return self.implConst().program;
        }

        /// Binds the program and uploads uniforms via editors.
        /// Dynamic per-frame uniform updates are the caller's job: write the
        /// cached uniforms (setVertUniform / setFragUniform / field setters)
        /// before calling `use`, e.g. from an explicit ECS system.
        /// Parameters:
        /// - self: material pointer.
        ///
        /// Returns: void.
        pub fn use(self: *Self) void {
            const m = self.impl();
            if (m.program == null or m.program.?.getId() == 0)
                m.program = ShaderProgram.instance(m.allocator) catch null;
            const prog = m.program orelse return;
            prog.use();
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

test "material uniform field access by name and id" {
    const DummyVert = struct {
        pub const Uniform = struct { uA: f32, uB: i32 };
    };
    const DummyFrag = struct {
        pub const Uniform = struct { uC: u32 };
    };
    const DummyProg = struct {
        pub const HasFrag = true;
        pub const Vert = DummyVert;
        pub const FragT = DummyFrag;
    };
    const M = Material(DummyProg);
    const alloc = std.testing.allocator;
    const storage = try alloc.create(M.Impl);
    defer alloc.destroy(storage);
    storage.* = .{
        .vertUniform = .{ .uA = 1.0, .uB = 2 },
        .fragUniform = .{ .uC = 3 },
        .program = null,
        .allocator = alloc,
    };
    const self: *M = @ptrCast(storage);

    const id_a = try M.getVertUniformFieldId("uA", f32);
    try std.testing.expectEqual(@as(f32, 1.0), try self.getVertUniformData(id_a, f32));
    try self.setVertUniformData(id_a, @as(f32, 2.5));
    try std.testing.expectEqual(@as(f32, 2.5), self.getVertUniform().uA);

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
