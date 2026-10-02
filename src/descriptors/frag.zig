/// Standard library import.
const std = @import("std");
/// EmbedDescriptor type from assets_manager.
const EmbedDescriptor = @import("assets_manager").descriptors.embed.abstract.EmbedDescriptor;
/// Node type for asset tree traversal.
const Node = @import("assets_manager").assets_tree.Node;
/// Text utilities for code generation.
const text_utils = @import("assets_manager").text_utils;
/// Common GLSL parsing utilities.
const common = @import("common.zig");

/// EmbedDescriptor that generates Zig code for fragment shader assets.
pub const FragmentDescriptor = struct {
    /// Number of spaces to indent per depth level.
    spaces_per_depth: usize = 4,

    /// Tests whether a node is suitable for fragment shader generation.
    /// Parameters:
    /// - ptr: opaque descriptor pointer unused.
    /// - init: process init context unused.
    /// - data: descriptor data containing node to test.
    ///
    /// Returns: true when node is a .frag file.
    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, data: EmbedDescriptor.Data) anyerror!bool {
        _ = ptr;
        _ = init;
        const node = data.node;
        if (node.kind != .file) return false;
        if (node.name) |name| return std.mem.endsWith(u8, name, ".frag");
        return false;
    }

    /// Generates Zig source code for a fragment shader asset.
    /// Parameters:
    /// - ptr: opaque descriptor pointer to self.
    /// - init: process init providing allocators and IO.
    /// - data: descriptor data with node, depth and path info.
    ///
    /// Returns: allocated Zig source string.
    pub fn getCode(ptr: *anyopaque, init: std.process.Init, data: EmbedDescriptor.Data) anyerror![]u8 {
        const self: *FragmentDescriptor = @ptrCast(@alignCast(ptr));
        const allocator = init.gpa;
        const io = init.io;
        const node = data.node;
        const depth = data.depth;

        const prefix = try text_utils.repeat(allocator, " ", depth * self.spaces_per_depth);
        defer if (prefix) |p| allocator.free(p);

        const path = try node.createPath(allocator);
        defer allocator.free(path);

        const identifier_raw = node.name orelse return error.MissingName;
        const var_name = try text_utils.filenameToIdentifier(allocator, identifier_raw);
        defer allocator.free(var_name);

        const raw_original = try common.readNodeFile(allocator, io, path) orelse try allocator.dupe(u8, "");
        defer allocator.free(raw_original);
        const raw_main = if (std.mem.startsWith(u8, raw_original, "\xEF\xBB\xBF")) raw_original[3..] else raw_original;

        // Maps a GLSL struct name to the top-level identifier (.glsl file base
        // name) that owns its single definition, e.g. "Light" -> "common".
        var link_map = std.StringHashMap([]u8).init(allocator);
        defer link_map.deinit();

        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();

        // Assemble the actual GLSL source: includes are inlined in place so
        // declaration order (e.g. precision hints before structs) is kept.
        var combined = std.ArrayList(u8).empty;
        defer combined.deinit(allocator);
        try common.resolveShaderIncludes(allocator, io, &combined, raw_main, path, &visited, &link_map);
        const combined_slice = try combined.toOwnedSlice(allocator);
        defer allocator.free(combined_slice);

        const no_comments = try common.stripComments(allocator, combined_slice);
        defer allocator.free(no_comments);

        const structs = try common.parseStructs(allocator, no_comments);
        defer common.freeStructs(allocator, structs);

        const uniforms = try common.parseUniforms(allocator, no_comments);
        defer common.freeUniforms(allocator, uniforms);

        var block_types = std.ArrayList([]const u8).empty;
        defer block_types.deinit(allocator);
        for (uniforms) |u| if (u.kind == .block) try block_types.append(allocator, u.glsl_type);
        try common.validateStructMembers(allocator, structs, block_types.items);

        const enum_defs = try common.parseEnumDefines(allocator, combined_slice);
        defer common.freeEnumDefines(allocator, enum_defs);

        var inner = std.ArrayList(u8).empty;
        defer inner.deinit(allocator);

        var struct_map = std.StringHashMap(void).init(allocator);
        defer struct_map.deinit();
        for (structs) |s| try struct_map.put(s.name, {});

        if (structs.len > 0) {
            for (structs) |s| {
                if (link_map.get(s.name)) |ident| {
                    // Link to the single definition generated from the .glsl
                    // include instead of duplicating it here.
                    try inner.appendSlice(allocator, "    pub const ");
                    try inner.appendSlice(allocator, s.name);
                    const link_line = try std.fmt.allocPrint(allocator, " = {s}.{s};\n", .{ ident, s.name });
                    defer allocator.free(link_line);
                    try inner.appendSlice(allocator, link_line);
                    continue;
                }
                try inner.appendSlice(allocator, "    pub const ");
                try inner.appendSlice(allocator, s.name);
                try inner.appendSlice(allocator, " = struct {\n");
                for (s.fields) |f| {
                    const zig_type = try common.mapGLSLTypeToZig(allocator, f.typ);
                    defer allocator.free(zig_type);
                    const full_type: []u8 = if (f.is_array) blk: {
                        if (f.array_len) |len| break :blk try std.fmt.allocPrint(allocator, "[{d}]{s}", .{ len, zig_type });
                        break :blk try std.fmt.allocPrint(allocator, "[]{s}", .{zig_type});
                    } else try allocator.dupe(u8, zig_type);
                    defer allocator.free(full_type);
                    try common.appendGeneratedField(allocator, &inner, "        ", f.name, full_type, false);
                }
                try inner.appendSlice(allocator, "    };\n");
            }
            try inner.appendSlice(allocator, "\n");
        }

        for (uniforms) |u| if (u.kind == .block) {
            if (!struct_map.contains(u.glsl_type)) {
                try inner.appendSlice(allocator, "    pub const ");
                try inner.appendSlice(allocator, u.glsl_type);
                try inner.appendSlice(allocator, " = struct {\n");
                if (u.block_fields) |fields| for (fields) |f| {
                    const zig_type = try common.mapGLSLTypeToZig(allocator, f.typ);
                    defer allocator.free(zig_type);
                    const full_type: []u8 = if (f.is_array) blk: {
                        if (f.array_len) |len| break :blk try std.fmt.allocPrint(allocator, "[{d}]{s}", .{ len, zig_type });
                        break :blk try std.fmt.allocPrint(allocator, "[]{s}", .{zig_type});
                    } else try allocator.dupe(u8, zig_type);
                    defer allocator.free(full_type);
                    try common.appendGeneratedField(allocator, &inner, "        ", f.name, full_type, false);
                };
                try inner.appendSlice(allocator, "    };\n");
            }
        };
        if (structs.len > 0 or blk_has(uniforms)) try inner.appendSlice(allocator, "\n");

        // Back-reference for `Material`: the Uniform struct is emitted as a
        // sibling top-level decl so `Owner` can forward-reference the shader
        // struct defined below (`Uniform.Owner.Uniform == Uniform`). A nested
        // self-reference is rejected by the compiler, hence the sibling.
        // `Owner` must not collide with a GLSL uniform name.
        for (uniforms) |u| {
            if (std.mem.eql(u8, u.name, "Owner")) return error.ReservedUniformName;
        }
        var uniform_outer = std.ArrayList(u8).empty;
        defer uniform_outer.deinit(allocator);
        const uniform_type_name = try std.fmt.allocPrint(allocator, "{s}_Uniform", .{var_name});
        defer allocator.free(uniform_type_name);
        try uniform_outer.appendSlice(allocator, "const ");
        try uniform_outer.appendSlice(allocator, uniform_type_name);
        try uniform_outer.appendSlice(allocator, " = struct {\n");
        const owner_line = try std.fmt.allocPrint(allocator, "    pub const Owner = {s};\n", .{var_name});
        defer allocator.free(owner_line);
        try uniform_outer.appendSlice(allocator, owner_line);
        for (uniforms) |u| {
            const is_resource = u.kind == .block or u.is_sampler;
            const zig_type_raw: []u8 = blk: {
                if (u.kind == .block) {
                    const inner_t = try common.mapGLSLTypeToZig(allocator, u.glsl_type);
                    defer allocator.free(inner_t);
                    break :blk try std.fmt.allocPrint(allocator, "*const @import(\"gl_graphics\").Buffer({s})", .{inner_t});
                } else if (u.is_sampler) break :blk try allocator.dupe(u8, "*const @import(\"gl_graphics\").Texture")
                else if (struct_map.contains(u.glsl_type)) break :blk try allocator.dupe(u8, u.glsl_type)
                else break :blk try common.mapGLSLTypeToZig(allocator, u.glsl_type);
            };
            defer allocator.free(zig_type_raw);
            try common.appendGeneratedField(allocator, &uniform_outer, "    ", u.name, zig_type_raw, is_resource);
        }
        try uniform_outer.appendSlice(allocator, "};\n");
        try inner.appendSlice(allocator, "    pub const Uniform = ");
        try inner.appendSlice(allocator, uniform_type_name);
        try inner.appendSlice(allocator, ";\n");
        try inner.appendSlice(allocator, "\n");

        if (uniforms.len == 0) {
            try inner.appendSlice(allocator, "    pub const IdCache = struct {};\n");
        } else {
            try inner.appendSlice(allocator, "    pub const IdCache = struct {\n");
            for (uniforms) |u| {
                try inner.appendSlice(allocator, "        ");
                try inner.appendSlice(allocator, u.name);
                try inner.appendSlice(allocator, ": i32,\n");
            }
            try inner.appendSlice(allocator, "    };\n");
        }
        try inner.appendSlice(allocator, "\n");
        try common.appendEnumDefinesCode(allocator, &inner, enum_defs, combined_slice);
        try inner.appendSlice(allocator, "    var variants: @import(\"std\").AutoHashMapUnmanaged(EnumDefines, u32) = .empty;\n\n");

        try inner.appendSlice(allocator, "    pub const BufferBlocks = struct {\n");
        var bind_point: usize = 0;
        for (uniforms) |u| {
            if (u.kind != .block) continue;
            try inner.appendSlice(allocator, "        pub const ");
            try inner.appendSlice(allocator, u.name);
            try inner.appendSlice(allocator, ": struct { name: [:0]const u8, point: u32 } = .{ .name = \"");
            try inner.appendSlice(allocator, u.glsl_type);
            try inner.appendSlice(allocator, "\", .point = ");
            const bp = try std.fmt.allocPrint(allocator, "{d}", .{bind_point});
            defer allocator.free(bp);
            try inner.appendSlice(allocator, bp);
            try inner.appendSlice(allocator, " };\n");
            bind_point += 1;
        }
        try inner.appendSlice(allocator, "    };\n\n");

        try inner.appendSlice(allocator, "    pub const Editor = struct {\n");
        try inner.appendSlice(allocator, "        _program: u32,\n");
        try inner.appendSlice(allocator, "        _pending: Uniform = .{},\n");
        if (uniforms.len == 0) {
            try inner.appendSlice(allocator, "        _dirty: struct {} = .{},\n");
        } else {
            try inner.appendSlice(allocator, "        _dirty: struct {\n");
            for (uniforms) |u| {
                try inner.appendSlice(allocator, "            ");
                try inner.appendSlice(allocator, u.name);
                try inner.appendSlice(allocator, ": bool = false,\n");
            }
            try inner.appendSlice(allocator, "        } = .{},\n");
        }
        try inner.appendSlice(allocator, "        _set_all: bool = false,\n\n");
        try inner.appendSlice(allocator, "        pub fn init(program: u32) Editor { return .{ ._program = program }; }\n");
        try inner.appendSlice(allocator, "        pub fn setUniform(self: *const Editor, uniform: Uniform) *const Editor { @constCast(self)._pending = uniform; @constCast(self)._set_all = true; return @constCast(self); }\n");
        for (uniforms) |u| {
            const zig_param_type: []u8 = blk: {
                if (u.kind == .block) {
                    const inner_t = try common.mapGLSLTypeToZig(allocator, u.glsl_type);
                    defer allocator.free(inner_t);
                    break :blk try std.fmt.allocPrint(allocator, "?*const @import(\"gl_graphics\").Buffer({s})", .{inner_t});
                } else if (u.is_sampler) break :blk try allocator.dupe(u8, "?*const @import(\"gl_graphics\").Texture")
                else if (struct_map.contains(u.glsl_type)) break :blk try allocator.dupe(u8, u.glsl_type)
                else break :blk try common.mapGLSLTypeToZig(allocator, u.glsl_type);
            };
            defer allocator.free(zig_param_type);
            const method_name = try std.fmt.allocPrint(allocator, "        pub fn set_{s}(self: *const Editor, value: {s}) *const Editor {{ @constCast(self)._pending.{s} = value; @constCast(self)._dirty.{s} = true; return @constCast(self); }}\n", .{ u.name, zig_param_type, u.name, u.name });
            defer allocator.free(method_name);
            try inner.appendSlice(allocator, method_name);
        }
        try inner.appendSlice(allocator, "\n");
        try inner.appendSlice(allocator, "        pub fn apply(self: *const Editor) void {\n");
        try inner.appendSlice(allocator, "            const mut = @constCast(self);\n");
        try inner.appendSlice(allocator, "            @import(\"gl_graphics\").applyUniforms(Uniform, BufferBlocks, mut._program, mut._pending, mut._set_all, &mut._dirty);\n");
        try inner.appendSlice(allocator, "        }\n");
        try inner.appendSlice(allocator, "    };\n\n");

        try inner.appendSlice(allocator, "    pub fn instance(allocator: @import(\"std\").mem.Allocator, defines: EnumDefines) !u32 {\n");
        try inner.appendSlice(allocator, "        if (variants.get(defines)) |sid| return sid;\n");
        if (enum_defs.len == 0) {
            try inner.appendSlice(allocator, "        const src = template_src;\n");
        } else {
            try inner.appendSlice(allocator, "        const texts = [_][]const u8{\n");
            for (enum_defs) |d| {
                const tline = try std.fmt.allocPrint(allocator, "            defines.{s}.text(),\n", .{d.field});
                defer allocator.free(tline);
                try inner.appendSlice(allocator, tline);
            }
            try inner.appendSlice(allocator, "        };\n");
            try inner.appendSlice(allocator, "        const src = try @import(\"gl_graphics\").buildVariantSrc(allocator, template_src, &define_slots, &texts);\n");
            try inner.appendSlice(allocator, "        defer allocator.free(src);\n");
        }
        try inner.appendSlice(allocator, "        const sid = @import(\"gl_graphics\").compileShaderSource(.fragment_shader, src);\n");
        try inner.appendSlice(allocator, "        try variants.put(allocator, defines, sid);\n");
        try inner.appendSlice(allocator, "        return sid;\n");
        try inner.appendSlice(allocator, "    }\n\n");
        try inner.appendSlice(allocator, "    pub fn destroy(allocator: @import(\"std\").mem.Allocator) void {\n");
        try inner.appendSlice(allocator, "        var it = variants.iterator();\n");
        try inner.appendSlice(allocator, "        while (it.next()) |e| @import(\"gl_graphics\").gl.shaders.delete(e.value_ptr.*);\n");
        try inner.appendSlice(allocator, "        variants.deinit(allocator);\n");
        try inner.appendSlice(allocator, "        variants = .empty;\n");
        try inner.appendSlice(allocator, "    }\n\n");
        try inner.appendSlice(allocator, "    pub fn edit(program: u32) Editor { return Editor.init(program); }\n");

        const inner_slice = try inner.toOwnedSlice(allocator);
        defer allocator.free(inner_slice);

        // Free include registry data (keys and identifiers owned by the maps).
        {
            var it = link_map.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            var vit = visited.iterator();
            while (vit.next()) |e| {
                allocator.free(e.key_ptr.*);
            }
        }

        const uniform_outer_slice = try uniform_outer.toOwnedSlice(allocator);
        defer allocator.free(uniform_outer_slice);

        return std.fmt.allocPrint(allocator, "{s}{s}\n{s}pub const {s} = struct {{\n{s}{s}{s}}};\n", .{ prefix orelse "", uniform_outer_slice, prefix orelse "", var_name, inner_slice, if (inner_slice.len > 0 and inner_slice[inner_slice.len - 1] == '\n') "" else "\n", prefix orelse "" });
    }

    /// Returns an EmbedDescriptor vtable for this fragment descriptor.
    /// Parameters:
    /// - self: pointer to descriptor instance.
    ///
    /// Returns: EmbedDescriptor with vtable.
    pub fn descriptor(self: *FragmentDescriptor) EmbedDescriptor {
        return .{ .ptr = self, .vtable = .{ .get_code = getCode, .is_suitable_data = isSuitableData } };
    }
};

/// Returns true when any uniform is a block type.
/// Parameters:
/// - uniforms: slice of uniform definitions.
///
/// Returns: true if any block uniform exists.
fn blk_has(uniforms: []common.UniformDef) bool {
    for (uniforms) |u| if (u.kind == .block) return true;
    return false;
}
