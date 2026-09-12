/// Standard library import.
const std = @import("std");
/// Descriptor type from assets_manager.
const Descriptor = @import("assets_manager").descriptors.Descriptor;
/// Node type for asset tree traversal.
const Node = @import("assets_manager").assets_tree.Node;
/// Text utilities for code generation.
const text_utils = @import("assets_manager").text_utils;
/// Common GLSL parsing utilities.
const common = @import("common.zig");

/// Descriptor that generates Zig code for vertex shader assets.
pub const VertexDescriptor = struct {
    /// Number of spaces to indent per depth level.
    spaces_per_depth: usize = 4,

    /// Tests whether a node is suitable for vertex shader generation.
    /// Parameters:
    /// - ptr: opaque descriptor pointer unused.
    /// - init: process init context unused.
    /// - data: descriptor data containing node to test.
    ///
    /// Returns: true when node is a .vert file.
    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, data: Descriptor.Data) anyerror!bool {
        _ = ptr;
        _ = init;
        const node = data.node;
        if (node.kind != .file) return false;
        if (node.name) |name| return std.mem.endsWith(u8, name, ".vert");
        return false;
    }

    /// Generates Zig source code for a vertex shader asset.
    /// Parameters:
    /// - ptr: opaque descriptor pointer to self.
    /// - init: process init providing allocators and IO.
    /// - data: descriptor data with node, depth and path info.
    ///
    /// Returns: allocated Zig source string.
    pub fn getCode(ptr: *anyopaque, init: std.process.Init, data: Descriptor.Data) anyerror![]u8 {
        const self: *VertexDescriptor = @ptrCast(@alignCast(ptr));
        const gpa = init.gpa;
        const io = init.io;
        const node = data.node;
        const depth = data.depth;

        const prefix = try text_utils.repeat(gpa, " ", depth * self.spaces_per_depth);
        defer if (prefix) |p| gpa.free(p);

        const path = try node.createPath(gpa);
        defer gpa.free(path);

        const identifier_raw = node.name orelse return error.MissingName;
        const var_name = try text_utils.filenameToIdentifier(gpa, identifier_raw);
        defer gpa.free(var_name);

        const raw_original = try common.readNodeFile(gpa, io, path) orelse try gpa.dupe(u8, "");
        defer gpa.free(raw_original);
        const raw_main = if (std.mem.startsWith(u8, raw_original, "\xEF\xBB\xBF")) raw_original[3..] else raw_original;

        // Maps a GLSL struct name to the top-level identifier (.glsl file base
        // name) that owns its single definition, e.g. "Light" -> "common".
        var link_map = std.StringHashMap([]u8).init(gpa);
        defer link_map.deinit();

        var visited = std.StringHashMap(void).init(gpa);
        defer visited.deinit();

        // Assemble the actual GLSL source: includes are inlined in place so
        // declaration order (e.g. precision hints before structs) is kept.
        var combined = std.ArrayList(u8).empty;
        defer combined.deinit(gpa);
        try common.resolveShaderIncludes(gpa, io, &combined, raw_main, path, &visited, &link_map);
        const combined_slice = try combined.toOwnedSlice(gpa);
        defer gpa.free(combined_slice);

        const no_comments = try common.stripComments(gpa, combined_slice);
        defer gpa.free(no_comments);

        const structs = try common.parseStructs(gpa, no_comments);
        defer common.freeStructs(gpa, structs);

        const main_no_comments = try common.stripComments(gpa, raw_main);
        defer gpa.free(main_no_comments);
        const stripped_for_ins = try common.stripLayouts(gpa, main_no_comments);
        defer gpa.free(stripped_for_ins);
        const ins = try common.parseIns(gpa, stripped_for_ins);
        defer common.freeFields(gpa, ins);

        const uniforms = try common.parseUniforms(gpa, no_comments);
        defer common.freeUniforms(gpa, uniforms);

        var inner = std.ArrayList(u8).empty;
        defer inner.deinit(gpa);

        var struct_map = std.StringHashMap(void).init(gpa);
        defer struct_map.deinit();
        for (structs) |s| try struct_map.put(s.name, {});

        if (structs.len > 0) {
            for (structs) |s| {
                if (link_map.get(s.name)) |ident| {
                    // Link to the single definition generated from the .glsl
                    // include instead of duplicating it here.
                    try inner.appendSlice(gpa, "    pub const ");
                    try inner.appendSlice(gpa, s.name);
                    const link_line = try std.fmt.allocPrint(gpa, " = {s}.{s};\n", .{ ident, s.name });
                    defer gpa.free(link_line);
                    try inner.appendSlice(gpa, link_line);
                    continue;
                }
                try inner.appendSlice(gpa, "    pub const ");
                try inner.appendSlice(gpa, s.name);
                try inner.appendSlice(gpa, " = struct {\n");
                for (s.fields) |f| {
                    const zig_type = try common.mapGLSLTypeToZig(gpa, f.typ);
                    defer gpa.free(zig_type);
                    try inner.appendSlice(gpa, "        ");
                    try inner.appendSlice(gpa, f.name);
                    try inner.appendSlice(gpa, ": ");
                    if (f.is_array) {
                        if (f.array_len) |len| {
                            const tmp = try std.fmt.allocPrint(gpa, "[{d}]{s}", .{ len, zig_type });
                            defer gpa.free(tmp);
                            try inner.appendSlice(gpa, tmp);
                        } else {
                            const tmp = try std.fmt.allocPrint(gpa, "[]{s}", .{zig_type});
                            defer gpa.free(tmp);
                            try inner.appendSlice(gpa, tmp);
                        }
                    } else {
                        try inner.appendSlice(gpa, zig_type);
                    }
                    try inner.appendSlice(gpa, ",\n");
                }
                try inner.appendSlice(gpa, "    };\n");
            }
            try inner.appendSlice(gpa, "\n");
        }

        for (uniforms) |u| {
            if (u.kind == .block) {
                const block_type = u.glsl_type;
                if (!struct_map.contains(block_type)) {
                    try inner.appendSlice(gpa, "    pub const ");
                    try inner.appendSlice(gpa, block_type);
                    try inner.appendSlice(gpa, " = struct {\n");
                    if (u.block_fields) |fields| {
                        for (fields) |f| {
                            const zig_type = try common.mapGLSLTypeToZig(gpa, f.typ);
                            defer gpa.free(zig_type);
                            try inner.appendSlice(gpa, "        ");
                            try inner.appendSlice(gpa, f.name);
                            try inner.appendSlice(gpa, ": ");
                            if (f.is_array) {
                                if (f.array_len) |len| {
                                    const tmp = try std.fmt.allocPrint(gpa, "[{d}]{s}", .{ len, zig_type });
                                    defer gpa.free(tmp);
                                    try inner.appendSlice(gpa, tmp);
                                } else {
                                    const tmp = try std.fmt.allocPrint(gpa, "[]{s}", .{zig_type});
                                    defer gpa.free(tmp);
                                    try inner.appendSlice(gpa, tmp);
                                }
                            } else {
                                try inner.appendSlice(gpa, zig_type);
                            }
                            try inner.appendSlice(gpa, ",\n");
                        }
                    }
                    try inner.appendSlice(gpa, "    };\n");
                }
            }
        }
        if (structs.len > 0 or blk_has(uniforms)) try inner.appendSlice(gpa, "\n");

        if (ins.len == 0) {
            try inner.appendSlice(gpa, "    pub const Vertex = struct {\n");
            try inner.appendSlice(gpa, "        pub const SOA = struct {};\n");
            try inner.appendSlice(gpa, "    };\n");
        } else {
            try inner.appendSlice(gpa, "    pub const Vertex = struct {\n");
            for (ins) |f| {
                const zig_type = try common.mapGLSLTypeToZig(gpa, f.typ);
                defer gpa.free(zig_type);
                try inner.appendSlice(gpa, "        ");
                try inner.appendSlice(gpa, f.name);
                try inner.appendSlice(gpa, ": ");
                try inner.appendSlice(gpa, zig_type);
                try inner.appendSlice(gpa, ",\n");
            }
            // SOA struct of arrays: same fields but as slices
            try inner.appendSlice(gpa, "\n");
            try inner.appendSlice(gpa, "        pub const SOA = struct {\n");
            for (ins) |f| {
                const zig_type = try common.mapGLSLTypeToZig(gpa, f.typ);
                defer gpa.free(zig_type);
                try inner.appendSlice(gpa, "            ");
                try inner.appendSlice(gpa, f.name);
                try inner.appendSlice(gpa, ": []const ");
                try inner.appendSlice(gpa, zig_type);
                try inner.appendSlice(gpa, ",\n");
            }
            try inner.appendSlice(gpa, "        };\n");
            try inner.appendSlice(gpa, "    };\n");
        }
        try inner.appendSlice(gpa, "\n");

        if (uniforms.len == 0) {
            try inner.appendSlice(gpa, "    pub const Uniform = struct {};\n");
        } else {
            try inner.appendSlice(gpa, "    pub const Uniform = struct {\n");
            for (uniforms) |u| {
                const zig_type_raw: []u8 = blk: {
                    if (u.kind == .block) {
                        const inner_t = try common.mapGLSLTypeToZig(gpa, u.glsl_type);
                        defer gpa.free(inner_t);
                        break :blk try std.fmt.allocPrint(gpa, "*const @import(\"gl_graphics\").Buffer({s})", .{inner_t});
                    } else if (u.is_sampler) {
                        break :blk try gpa.dupe(u8, "*const @import(\"gl_graphics\").Texture");
                    } else {
                        if (struct_map.contains(u.glsl_type)) {
                            break :blk try gpa.dupe(u8, u.glsl_type);
                        } else {
                            break :blk try common.mapGLSLTypeToZig(gpa, u.glsl_type);
                        }
                    }
                };
                defer gpa.free(zig_type_raw);
                try inner.appendSlice(gpa, "        ");
                try inner.appendSlice(gpa, u.name);
                try inner.appendSlice(gpa, ": ");
                try inner.appendSlice(gpa, zig_type_raw);
                try inner.appendSlice(gpa, ",\n");
            }
            try inner.appendSlice(gpa, "    };\n");
        }
        try inner.appendSlice(gpa, "\n");

        if (uniforms.len == 0) {
            try inner.appendSlice(gpa, "    pub const IdCache = struct {};\n");
        } else {
            try inner.appendSlice(gpa, "    pub const IdCache = struct {\n");
            for (uniforms) |u| {
                try inner.appendSlice(gpa, "        ");
                try inner.appendSlice(gpa, u.name);
                try inner.appendSlice(gpa, ": i32,\n");
            }
            try inner.appendSlice(gpa, "    };\n");
        }
        try inner.appendSlice(gpa, "\n");

        try inner.appendSlice(gpa, "    pub var id: u32 = 0;\n");
        if (uniforms.len == 0) {
            try inner.appendSlice(gpa, "    pub var id_cache: IdCache = .{};\n");
        } else {
            try inner.appendSlice(gpa, "    pub var id_cache: IdCache = .{\n");
            for (uniforms) |u| {
                try inner.appendSlice(gpa, "        .");
                try inner.appendSlice(gpa, u.name);
                try inner.appendSlice(gpa, " = -1,\n");
            }
            try inner.appendSlice(gpa, "    };\n");
        }
        try inner.appendSlice(gpa, "    var _initialized: bool = false;\n\n");

        try inner.appendSlice(gpa, "    pub const BufferBlocks = struct {\n");
        var bind_point: usize = 0;
        for (uniforms) |u| {
            if (u.kind != .block) continue;
            try inner.appendSlice(gpa, "        pub const ");
            try inner.appendSlice(gpa, u.name);
            try inner.appendSlice(gpa, ": struct { name: [:0]const u8, point: u32 } = .{ .name = \"");
            try inner.appendSlice(gpa, u.glsl_type);
            try inner.appendSlice(gpa, "\", .point = ");
            const bp = try std.fmt.allocPrint(gpa, "{d}", .{bind_point});
            defer gpa.free(bp);
            try inner.appendSlice(gpa, bp);
            try inner.appendSlice(gpa, " };\n");
            bind_point += 1;
        }
        try inner.appendSlice(gpa, "    };\n\n");

        try inner.appendSlice(gpa, "    pub const Editor = struct {\n");
        try inner.appendSlice(gpa, "        _program: u32,\n");
        try inner.appendSlice(gpa, "        _pending: Uniform = undefined,\n");
        if (uniforms.len == 0) {
            try inner.appendSlice(gpa, "        _dirty: struct {} = .{},\n");
        } else {
            try inner.appendSlice(gpa, "        _dirty: struct {\n");
            for (uniforms) |u| {
                try inner.appendSlice(gpa, "            ");
                try inner.appendSlice(gpa, u.name);
                try inner.appendSlice(gpa, ": bool = false,\n");
            }
            try inner.appendSlice(gpa, "        } = .{},\n");
        }
        try inner.appendSlice(gpa, "        _set_all: bool = false,\n\n");
        try inner.appendSlice(gpa, "        pub fn init(program: u32) Editor { return .{ ._program = program }; }\n");
        try inner.appendSlice(gpa, "        pub fn setUniform(self: *const Editor, uniform: Uniform) *const Editor { @constCast(self)._pending = uniform; @constCast(self)._set_all = true; return @constCast(self); }\n");
        for (uniforms) |u| {
            const zig_param_type: []u8 = blk: {
                if (u.kind == .block) {
                    const inner_t = try common.mapGLSLTypeToZig(gpa, u.glsl_type);
                    defer gpa.free(inner_t);
                    break :blk try std.fmt.allocPrint(gpa, "*const @import(\"gl_graphics\").Buffer({s})", .{inner_t});
                } else if (u.is_sampler) {
                    break :blk try gpa.dupe(u8, "*const @import(\"gl_graphics\").Texture");
                } else {
                    if (struct_map.contains(u.glsl_type)) {
                        break :blk try gpa.dupe(u8, u.glsl_type);
                    } else {
                        break :blk try common.mapGLSLTypeToZig(gpa, u.glsl_type);
                    }
                }
            };
            defer gpa.free(zig_param_type);
            const method_name = try std.fmt.allocPrint(gpa, "        pub fn set_{s}(self: *const Editor, value: {s}) *const Editor {{ @constCast(self)._pending.{s} = value; @constCast(self)._dirty.{s} = true; return @constCast(self); }}\n", .{ u.name, zig_param_type, u.name, u.name });
            defer gpa.free(method_name);
            try inner.appendSlice(gpa, method_name);
        }
        try inner.appendSlice(gpa, "\n");
        try inner.appendSlice(gpa, "        pub fn apply(self: *const Editor) void {\n");
        try inner.appendSlice(gpa, "            const mut = @constCast(self);\n");
        try inner.appendSlice(gpa, "            @import(\"gl_graphics\").applyUniforms(Uniform, BufferBlocks, mut._program, mut._pending, mut._set_all, &mut._dirty);\n");
        try inner.appendSlice(gpa, "        }\n");
        try inner.appendSlice(gpa, "    };\n\n");

        try inner.appendSlice(gpa, "    pub fn instance() u32 {\n");
        try inner.appendSlice(gpa, "        if (_initialized and id != 0) return id;\n");
        // Inline GLSL with `#include` resolved at generation time.
        try inner.appendSlice(gpa, "        const src = ");
        var src_literal = std.ArrayList(u8).empty;
        defer src_literal.deinit(gpa);
        try src_literal.append(gpa, '"');
        for (combined_slice) |ch| {
            switch (ch) {
                '\\' => try src_literal.appendSlice(gpa, "\\\\"),
                '"' => try src_literal.appendSlice(gpa, "\\\""),
                '\n' => try src_literal.appendSlice(gpa, "\\n"),
                '\r' => {},
                else => try src_literal.append(gpa, ch),
            }
        }
        try src_literal.append(gpa, '"');
        try inner.appendSlice(gpa, src_literal.items);
        try inner.appendSlice(gpa, ";\n");
        try inner.appendSlice(gpa, "        id = @import(\"gl_graphics\").compileShaderSource(.vertex_shader, src);\n");
        try inner.appendSlice(gpa, "        _initialized = true;\n");
        try inner.appendSlice(gpa, "        return id;\n");
        try inner.appendSlice(gpa, "    }\n\n");

        try inner.appendSlice(gpa, "    pub fn dispose() void {\n");
        try inner.appendSlice(gpa, "        @import(\"gl_graphics\").disposeShader(&id, &_initialized);\n");
        try inner.appendSlice(gpa, "    }\n\n");

        try inner.appendSlice(gpa, "    pub fn edit(program: u32) Editor { return Editor.init(program); }\n");

        const inner_slice = try inner.toOwnedSlice(gpa);
        defer gpa.free(inner_slice);

        // Free include registry data (keys and identifiers owned by the maps).
        {
            var it = link_map.iterator();
            while (it.next()) |e| {
                gpa.free(e.key_ptr.*);
                gpa.free(e.value_ptr.*);
            }
            var vit = visited.iterator();
            while (vit.next()) |e| {
                gpa.free(e.key_ptr.*);
            }
        }

        const outer = try std.fmt.allocPrint(gpa,
            "{s}pub const {s} = struct {{\n{s}{s}{s}}};\n",
            .{ prefix orelse "", var_name, inner_slice, if (inner_slice.len > 0 and inner_slice[inner_slice.len - 1] == '\n') "" else "\n", prefix orelse "" });
        return outer;
    }

    /// Returns a Descriptor vtable for this vertex descriptor.
    /// Parameters:
    /// - self: pointer to descriptor instance.
    ///
    /// Returns: Descriptor with vtable.
    pub fn descriptor(self: *VertexDescriptor) Descriptor {
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
