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

/// Descriptor that generates Zig code for fragment shader assets.
pub const FragmentDescriptor = struct {
    /// Number of spaces to indent per depth level.
    spaces_per_depth: usize = 4,

    /// Tests whether a node is suitable for fragment shader generation.
    /// Parameters:
    /// - ptr: opaque descriptor pointer unused.
    /// - init: process init context unused.
    /// - data: descriptor data containing node to test.
    /// Returns: true when node is a .frag file.
    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, data: Descriptor.Data) anyerror!bool {
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
    /// Returns: allocated Zig source string.
    pub fn getCode(ptr: *anyopaque, init: std.process.Init, data: Descriptor.Data) anyerror![]u8 {
        const self: *FragmentDescriptor = @ptrCast(@alignCast(ptr));
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

        const embed_path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ data.path_to_root_node, path });
        defer gpa.free(embed_path);

        const raw_main = try common.readNodeFile(gpa, io, path) orelse try gpa.dupe(u8, "");
        defer gpa.free(raw_main);

        var include_contents = std.ArrayList([]u8).empty;
        defer {
            for (include_contents.items) |c| gpa.free(c);
            include_contents.deinit(gpa);
        }
        var visited = std.StringHashMap(void).init(gpa);
        defer visited.deinit();

        var include_queue = std.ArrayList([]u8).empty;
        defer {
            for (include_queue.items) |s| gpa.free(s);
            include_queue.deinit(gpa);
        }

        {
            var it = std.mem.splitScalar(u8, raw_main, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
                if (std.mem.startsWith(u8, trimmed, "#include")) {
                    var rest = std.mem.trim(u8, trimmed["#include".len..], &[_]u8{ ' ', '\t' });
                    if (rest.len >= 2 and (rest[0] == '"' or rest[0] == '<')) {
                        const endC: u8 = if (rest[0] == '"') '"' else '>';
                        if (std.mem.indexOfScalar(u8, rest[1..], endC)) |end| {
                            const inc = rest[1 .. 1 + end];
                            const resolved = try common.resolveIncludePath(gpa, path, inc);
                            try include_queue.append(gpa, resolved);
                        }
                    }
                }
            }
        }
        var idx: usize = 0;
        while (idx < include_queue.items.len) : (idx += 1) {
            const inc_path = include_queue.items[idx];
            if (visited.contains(inc_path)) continue;
            try visited.put(try gpa.dupe(u8, inc_path), {});
            const content = try common.readNodeFile(gpa, io, inc_path);
            if (content) |c| {
                try include_contents.append(gpa, c);
                var line_it = std.mem.splitScalar(u8, c, '\n');
                while (line_it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
                    if (std.mem.startsWith(u8, trimmed, "#include")) {
                        var rest = std.mem.trim(u8, trimmed["#include".len..], &[_]u8{ ' ', '\t' });
                        if (rest.len >= 2 and (rest[0] == '"' or rest[0] == '<')) {
                            const endC: u8 = if (rest[0] == '"') '"' else '>';
                            if (std.mem.indexOfScalar(u8, rest[1..], endC)) |end| {
                                const inc2 = rest[1 .. 1 + end];
                                const resolved2 = try common.resolveIncludePath(gpa, inc_path, inc2);
                                var already = false;
                                for (include_queue.items) |q| {
                                    if (std.mem.eql(u8, q, resolved2)) {
                                        already = true;
                                        break;
                                    }
                                }
                                if (!already) try include_queue.append(gpa, resolved2) else gpa.free(resolved2);
                            }
                        }
                    }
                }
            }
        }

        var combined = std.ArrayList(u8).empty;
        defer combined.deinit(gpa);
        for (include_contents.items) |c| {
            try combined.appendSlice(gpa, c);
            try combined.append(gpa, '\n');
        }
        {
            var line_it = std.mem.splitScalar(u8, raw_main, '\n');
            while (line_it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
                if (std.mem.startsWith(u8, trimmed, "#include")) continue;
                try combined.appendSlice(gpa, line);
                try combined.append(gpa, '\n');
            }
        }
        const combined_slice = try combined.toOwnedSlice(gpa);
        defer gpa.free(combined_slice);

        const no_comments = try common.stripComments(gpa, combined_slice);
        defer gpa.free(no_comments);

        const structs = try common.parseStructs(gpa, no_comments);
        defer common.freeStructs(gpa, structs);

        const uniforms = try common.parseUniforms(gpa, no_comments);
        defer common.freeUniforms(gpa, uniforms);

        var inner = std.ArrayList(u8).empty;
        defer inner.deinit(gpa);

        var struct_map = std.StringHashMap(void).init(gpa);
        defer struct_map.deinit();
        for (structs) |s| try struct_map.put(s.name, {});

        if (structs.len > 0) {
            for (structs) |s| {
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
                    } else try inner.appendSlice(gpa, zig_type);
                    try inner.appendSlice(gpa, ",\n");
                }
                try inner.appendSlice(gpa, "    };\n");
            }
            try inner.appendSlice(gpa, "\n");
        }

        for (uniforms) |u| if (u.kind == .block) {
            if (!struct_map.contains(u.glsl_type)) {
                try inner.appendSlice(gpa, "    pub const ");
                try inner.appendSlice(gpa, u.glsl_type);
                try inner.appendSlice(gpa, " = struct {\n");
                if (u.block_fields) |fields| for (fields) |f| {
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
                    } else try inner.appendSlice(gpa, zig_type);
                    try inner.appendSlice(gpa, ",\n");
                };
                try inner.appendSlice(gpa, "    };\n");
            }
        };
        if (structs.len > 0 or blk_has(uniforms)) try inner.appendSlice(gpa, "\n");

        if (uniforms.len == 0) {
            try inner.appendSlice(gpa, "    pub const Uniform = struct {};\n");
        } else {
            try inner.appendSlice(gpa, "    pub const Uniform = struct {\n");
            for (uniforms) |u| {
                const zig_type_raw: []u8 = blk: {
                    if (u.kind == .block) {
                        const inner_t = try common.mapGLSLTypeToZig(gpa, u.glsl_type);
                        defer gpa.free(inner_t);
                        break :blk try std.fmt.allocPrint(gpa, "@import(\"gl_graphics\").Buffer({s})", .{inner_t});
                    } else if (u.is_sampler) break :blk try gpa.dupe(u8, "*const @import(\"gl_graphics\").Texture")
                    else if (struct_map.contains(u.glsl_type)) break :blk try gpa.dupe(u8, u.glsl_type)
                    else break :blk try common.mapGLSLTypeToZig(gpa, u.glsl_type);
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
                    break :blk try std.fmt.allocPrint(gpa, "@import(\"gl_graphics\").Buffer({s})", .{inner_t});
                } else if (u.is_sampler) break :blk try gpa.dupe(u8, "*const @import(\"gl_graphics\").Texture")
                else if (struct_map.contains(u.glsl_type)) break :blk try gpa.dupe(u8, u.glsl_type)
                else break :blk try common.mapGLSLTypeToZig(gpa, u.glsl_type);
            };
            defer gpa.free(zig_param_type);
            const method_name = try std.fmt.allocPrint(gpa, "        pub fn set_{s}(self: *const Editor, value: {s}) *const Editor {{ @constCast(self)._pending.{s} = value; @constCast(self)._dirty.{s} = true; return @constCast(self); }}\n", .{ u.name, zig_param_type, u.name, u.name });
            defer gpa.free(method_name);
            try inner.appendSlice(gpa, method_name);
        }
        try inner.appendSlice(gpa, "\n");
        try inner.appendSlice(gpa, "        pub fn apply(self: *const Editor) void {\n");
        try inner.appendSlice(gpa, "            const mut = @constCast(self);\n");
        try inner.appendSlice(gpa, "            const gl = @import(\"gl_graphics\").gl;\n");
        try inner.appendSlice(gpa, "            inline for (@typeInfo(Uniform).@\"struct\".fields) |field| {\n");
        try inner.appendSlice(gpa, "                const name = field.name;\n");
        try inner.appendSlice(gpa, "                const is_dirty = if (self._set_all) true else @field(self._dirty, name);\n");
        try inner.appendSlice(gpa, "                const loc = gl.uniforms.location(self._program, @ptrCast(name));\n");
        try inner.appendSlice(gpa, "                if (is_dirty and loc != -1) {\n");
        try inner.appendSlice(gpa, "                const value = @field(self._pending, name);\n");
        try inner.appendSlice(gpa, "                const T = @TypeOf(value);\n");
        try inner.appendSlice(gpa, "                if (T == @import(\"gl_graphics\").Texture or T == *const @import(\"gl_graphics\").Texture or T == *@import(\"gl_graphics\").Texture) {\n");
        try inner.appendSlice(gpa, "                    const unit: u32 = 0;\n");
        try inner.appendSlice(gpa, "                    @import(\"gl_graphics\").gl.textures.activeTexture(@enumFromInt(@intFromEnum(@import(\"gl_graphics\").gl.textures.TextureUnit.texture0) + unit));\n");
        try inner.appendSlice(gpa, "                    @import(\"gl_graphics\").gl.textures.bind(.texture_2d, value.getId());\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1i(loc, @intCast(unit));\n");
        try inner.appendSlice(gpa, "                } else if (@typeInfo(T) == .@\"struct\" and @hasDecl(T, \"len\") and @hasDecl(T, \"value_type\")) {\n");
        try inner.appendSlice(gpa, "                    if (T.value_type == f32) {\n");
        try inner.appendSlice(gpa, "                        if (T.len == 1) gl.uniforms.uniform1f(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2f(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3f(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4f(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                    } else if (T.value_type == i32) {\n");
        try inner.appendSlice(gpa, "                        if (T.len == 1) gl.uniforms.uniform1i(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2i(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3i(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4i(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                    } else if (T.value_type == u32) {\n");
        try inner.appendSlice(gpa, "                        if (T.len == 1) gl.uniforms.uniform1ui(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2ui(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3ui(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4ui(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                    }\n");
        try inner.appendSlice(gpa, "                } else if (@typeInfo(T) == .@\"struct\" and @hasDecl(T, \"cols\") and @hasDecl(T, \"rows\")) {\n");
        try inner.appendSlice(gpa, "                    if (T.cols == 4 and T.rows == 4) { var data: [16]f32 = undefined; inline for (0..4) |c| { inline for (0..4) |r| { data[c * 4 + r] = value.data[c].v[r]; } } gl.uniforms.uniformMatrix4fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                    else if (T.cols == 3 and T.rows == 3) { var data: [9]f32 = undefined; inline for (0..3) |c| { inline for (0..3) |r| { data[c * 3 + r] = value.data[c].v[r]; } } gl.uniforms.uniformMatrix3fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                    else if (T.cols == 2 and T.rows == 2) { var data: [4]f32 = undefined; inline for (0..2) |c| { inline for (0..2) |r| { data[c * 2 + r] = value.data[c].v[r]; } } gl.uniforms.uniformMatrix2fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                    else if (T.cols == 3 and T.rows == 2) { var data: [6]f32 = undefined; inline for (0..3) |c| { inline for (0..2) |r| { data[c * 2 + r] = value.data[c].v[r]; } } gl.uniforms.uniformMatrix3x2fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                    else if (T.cols == 2 and T.rows == 3) { var data: [6]f32 = undefined; inline for (0..2) |c| { inline for (0..3) |r| { data[c * 3 + r] = value.data[c].v[r]; } } gl.uniforms.uniformMatrix2x3fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                } else if (T == f32) gl.uniforms.uniform1f(loc, value) else if (T == i32) gl.uniforms.uniform1i(loc, value) else if (T == u32) gl.uniforms.uniform1ui(loc, value) else if (T == bool) gl.uniforms.uniform1i(loc, if (value) 1 else 0) else {}\n");
        try inner.appendSlice(gpa, "                }\n");
        try inner.appendSlice(gpa, "            }\n");
        try inner.appendSlice(gpa, "            mut._set_all = false;\n");
        try inner.appendSlice(gpa, "            inline for (@typeInfo(@TypeOf(mut._dirty)).@\"struct\".fields) |f| @field(mut._dirty, f.name) = false;\n");
        try inner.appendSlice(gpa, "        }\n");
        try inner.appendSlice(gpa, "    };\n\n");

        try inner.appendSlice(gpa, "    pub fn instance() u32 {\n");
        try inner.appendSlice(gpa, "        if (_initialized and id != 0) return id;\n");
        try inner.appendSlice(gpa, "        const gl = @import(\"gl_graphics\").gl;\n");
        try inner.appendSlice(gpa, "        const src = @embedFile(\"");
        try inner.appendSlice(gpa, embed_path);
        try inner.appendSlice(gpa, "\");\n");
        try inner.appendSlice(gpa, "        const shader = gl.shaders.create(.fragment_shader);\n");
        try inner.appendSlice(gpa, "        gl.shaders.source(shader, src);\n");
        try inner.appendSlice(gpa, "        gl.shaders.compile(shader);\n");
        try inner.appendSlice(gpa, "        var ok: i32 = 0; gl.shaders.getParameter(shader, .compile_status, @ptrCast(&ok));\n");
        try inner.appendSlice(gpa, "        id = shader; _initialized = true; return id;\n");
        try inner.appendSlice(gpa, "    }\n\n");
        try inner.appendSlice(gpa, "    pub fn dispose() void { if (id != 0) { @import(\"gl_graphics\").gl.shaders.delete(id); id = 0; _initialized = false; } }\n\n");
        try inner.appendSlice(gpa, "    pub fn edit(program: u32) Editor { return Editor.init(program); }\n");

        const inner_slice = try inner.toOwnedSlice(gpa);
        defer gpa.free(inner_slice);

        return std.fmt.allocPrint(gpa, "{s}pub const {s} = struct {{\n{s}{s}{s}}};\n", .{ prefix orelse "", var_name, inner_slice, if (inner_slice.len > 0 and inner_slice[inner_slice.len - 1] == '\n') "" else "\n", prefix orelse "" });
    }

    /// Returns a Descriptor vtable for this fragment descriptor.
    /// Parameters:
    /// - self: pointer to descriptor instance.
    /// Returns: Descriptor with vtable.
    pub fn descriptor(self: *FragmentDescriptor) Descriptor {
        return .{ .ptr = self, .vtable = .{ .get_code = getCode, .is_suitable_data = isSuitableData } };
    }
};

/// Returns true when any uniform is a block type.
/// Parameters:
/// - uniforms: slice of uniform definitions.
/// Returns: true if any block uniform exists.
fn blk_has(uniforms: []common.UniformDef) bool {
    for (uniforms) |u| if (u.kind == .block) return true;
    return false;
}
