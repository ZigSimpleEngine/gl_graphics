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
            try inner.appendSlice(gpa, "    pub const Vertex = struct {};\n");
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

        try inner.appendSlice(gpa, "    pub const UniformUpload = struct {\n");
        try inner.appendSlice(gpa, "        const std = @import(\"std\");\n");
        try inner.appendSlice(gpa, "        pub fn flatten(program: u32, comptime prefix: []const u8, comptime T: type, value: T, gl: anytype) void {\n");
        try inner.appendSlice(gpa, "            inline for (@typeInfo(T).@\"struct\".fields) |f| {\n");
        try inner.appendSlice(gpa, "                const path: [:0]const u8 = if (prefix.len == 0) f.name else std.fmt.comptimePrint(\"{s}.{s}\", .{ prefix, f.name });\n");
        try inner.appendSlice(gpa, "                const loc = gl.uniforms.location(program, @ptrCast(path));\n");
        try inner.appendSlice(gpa, "                if (loc != -1) {\n");
        try inner.appendSlice(gpa, "                    const fv = @field(value, f.name);\n");
        try inner.appendSlice(gpa, "                    const FT = @TypeOf(fv);\n");
        try inner.appendSlice(gpa, "                    if (@typeInfo(FT) == .@\"struct\" and @hasDecl(FT, \"len\") and @hasDecl(FT, \"value_type\")) {\n");
        try inner.appendSlice(gpa, "                        if (FT.value_type == f32) {\n");
        try inner.appendSlice(gpa, "                            if (FT.len == 1) gl.uniforms.uniform1f(loc, fv.v[0]) else if (FT.len == 2) gl.uniforms.uniform2f(loc, fv.v[0], fv.v[1]) else if (FT.len == 3) gl.uniforms.uniform3f(loc, fv.v[0], fv.v[1], fv.v[2]) else if (FT.len == 4) gl.uniforms.uniform4f(loc, fv.v[0], fv.v[1], fv.v[2], fv.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                        } else if (FT.value_type == i32) {\n");
        try inner.appendSlice(gpa, "                            if (FT.len == 1) gl.uniforms.uniform1i(loc, fv.v[0]) else if (FT.len == 2) gl.uniforms.uniform2i(loc, fv.v[0], fv.v[1]) else if (FT.len == 3) gl.uniforms.uniform3i(loc, fv.v[0], fv.v[1], fv.v[2]) else if (FT.len == 4) gl.uniforms.uniform4i(loc, fv.v[0], fv.v[1], fv.v[2], fv.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                        } else if (FT.value_type == u32) {\n");
        try inner.appendSlice(gpa, "                            if (FT.len == 1) gl.uniforms.uniform1ui(loc, fv.v[0]) else if (FT.len == 2) gl.uniforms.uniform2ui(loc, fv.v[0], fv.v[1]) else if (FT.len == 3) gl.uniforms.uniform3ui(loc, fv.v[0], fv.v[1], fv.v[2]) else if (FT.len == 4) gl.uniforms.uniform4ui(loc, fv.v[0], fv.v[1], fv.v[2], fv.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                        }\n");
        try inner.appendSlice(gpa, "                    } else if (@typeInfo(FT) == .@\"struct\" and @hasDecl(FT, \"cols\") and @hasDecl(FT, \"rows\")) {\n");
        try inner.appendSlice(gpa, "                        if (FT.cols == 4 and FT.rows == 4) { var data: [16]f32 = undefined; inline for (0..4) |c| { inline for (0..4) |r| { data[c * 4 + r] = fv.data[c].v[r]; } } gl.uniforms.uniformMatrix4fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                        else if (FT.cols == 3 and FT.rows == 3) { var data: [9]f32 = undefined; inline for (0..3) |c| { inline for (0..3) |r| { data[c * 3 + r] = fv.data[c].v[r]; } } gl.uniforms.uniformMatrix3fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                        else if (FT.cols == 2 and FT.rows == 2) { var data: [4]f32 = undefined; inline for (0..2) |c| { inline for (0..2) |r| { data[c * 2 + r] = fv.data[c].v[r]; } } gl.uniforms.uniformMatrix2fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                        else if (FT.cols == 3 and FT.rows == 2) { var data: [6]f32 = undefined; inline for (0..3) |c| { inline for (0..2) |r| { data[c * 2 + r] = fv.data[c].v[r]; } } gl.uniforms.uniformMatrix3x2fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                        else if (FT.cols == 2 and FT.rows == 3) { var data: [6]f32 = undefined; inline for (0..2) |c| { inline for (0..3) |r| { data[c * 3 + r] = fv.data[c].v[r]; } } gl.uniforms.uniformMatrix2x3fv(loc, false, &data); }\n");
        try inner.appendSlice(gpa, "                    } else if (@typeInfo(FT) == .@\"struct\") {\n");
        try inner.appendSlice(gpa, "                        flatten(program, path, FT, fv, gl);\n");
        try inner.appendSlice(gpa, "                    } else if (FT == f32) {\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.uniform1f(loc, fv);\n");
        try inner.appendSlice(gpa, "                    } else if (FT == i32) {\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.uniform1i(loc, fv);\n");
        try inner.appendSlice(gpa, "                    } else if (FT == u32) {\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.uniform1ui(loc, fv);\n");
        try inner.appendSlice(gpa, "                    } else if (FT == bool) {\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.uniform1i(loc, if (fv) 1 else 0);\n");
        try inner.appendSlice(gpa, "                    } else {}\n");
        try inner.appendSlice(gpa, "                }\n");
        try inner.appendSlice(gpa, "            }\n");
        try inner.appendSlice(gpa, "        }\n");
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
        try inner.appendSlice(gpa, "            const gl = @import(\"gl_graphics\").gl;\n");
        try inner.appendSlice(gpa, "            const std = @import(\"std\");\n");
        try inner.appendSlice(gpa, "            inline for (@typeInfo(Uniform).@\"struct\".fields) |field| {\n");
        try inner.appendSlice(gpa, "                const name = field.name;\n");
        try inner.appendSlice(gpa, "                const is_dirty = if (self._set_all) true else @field(self._dirty, name);\n");
        try inner.appendSlice(gpa, "                const loc = gl.uniforms.location(self._program, @ptrCast(name));\n");
        try inner.appendSlice(gpa, "                if (is_dirty) {\n");
        try inner.appendSlice(gpa, "                const value = @field(self._pending, name);\n");
        try inner.appendSlice(gpa, "                const T = @TypeOf(value);\n");
        try inner.appendSlice(gpa, "                const DerefT = if (@typeInfo(T) == .pointer) std.meta.Child(T) else void;\n");
        try inner.appendSlice(gpa, "                // Dispatch upload based on type � handles math, Texture, Buffer\n");
        try inner.appendSlice(gpa, "                if (loc != -1 and T == @import(\"gl_graphics\").Texture or T == *const @import(\"gl_graphics\").Texture or T == *@import(\"gl_graphics\").Texture) {\n");
        try inner.appendSlice(gpa, "                    const unit: u32 = 0;\n");
        try inner.appendSlice(gpa, "                    @import(\"gl_graphics\").gl.textures.activeTexture(@enumFromInt(@intFromEnum(@import(\"gl_graphics\").gl.textures.TextureUnit.texture0) + unit));\n");
        try inner.appendSlice(gpa, "                    @import(\"gl_graphics\").gl.textures.bind(.texture_2d, value.getId());\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1i(loc, @intCast(unit));\n");
        try inner.appendSlice(gpa, "                } else if (@typeInfo(DerefT) == .@\"opaque\" and @hasDecl(DerefT, \"DataType\")) {\n");
        try inner.appendSlice(gpa, "                    // Uniform block buffer (UBO): bind the buffer to the block binding point.\n");
        try inner.appendSlice(gpa, "                    const block = @field(BufferBlocks, name);\n");
        try inner.appendSlice(gpa, "                    const bidx = gl.uniforms.blockIndex(self._program, block.name);\n");
        try inner.appendSlice(gpa, "                    if (bidx != 0xFFFFFFFF) {\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.blockBinding(self._program, bidx, block.point);\n");
        try inner.appendSlice(gpa, "                        gl.buffers.bindBase(.uniform_buffer, block.point, value.getId());\n");
        try inner.appendSlice(gpa, "                    }\n");
        try inner.appendSlice(gpa, "                } else if (loc != -1 and @typeInfo(T) == .@\"struct\" and @hasDecl(T, \"len\") and @hasDecl(T, \"value_type\")) {\n");
        try inner.appendSlice(gpa, "                    if (T.value_type == f32) {\n");
        try inner.appendSlice(gpa, "                        if (T.len == 1) gl.uniforms.uniform1f(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2f(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3f(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4f(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                    } else if (T.value_type == i32) {\n");
        try inner.appendSlice(gpa, "                        if (T.len == 1) gl.uniforms.uniform1i(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2i(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3i(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4i(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                    } else if (T.value_type == u32) {\n");
        try inner.appendSlice(gpa, "                        if (T.len == 1) gl.uniforms.uniform1ui(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2ui(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3ui(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4ui(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                    }\n");
        try inner.appendSlice(gpa, "                } else if (loc != -1 and @typeInfo(T) == .@\"struct\" and @hasDecl(T, \"cols\") and @hasDecl(T, \"rows\")) {\n");
        try inner.appendSlice(gpa, "                    if (T.cols == 4 and T.rows == 4) {\n");
        try inner.appendSlice(gpa, "                        var data: [16]f32 = undefined;\n");
        try inner.appendSlice(gpa, "                        inline for (0..4) |c| {\n");
        try inner.appendSlice(gpa, "                            inline for (0..4) |r| {\n");
        try inner.appendSlice(gpa, "                                data[c * 4 + r] = value.data[c].v[r];\n");
        try inner.appendSlice(gpa, "                            }\n");
        try inner.appendSlice(gpa, "                        }\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.uniformMatrix4fv(loc, false, &data);\n");
        try inner.appendSlice(gpa, "                    } else if (T.cols == 3 and T.rows == 3) {\n");
        try inner.appendSlice(gpa, "                        var data: [9]f32 = undefined;\n");
        try inner.appendSlice(gpa, "                        inline for (0..3) |c| {\n");
        try inner.appendSlice(gpa, "                            inline for (0..3) |r| {\n");
        try inner.appendSlice(gpa, "                                data[c * 3 + r] = value.data[c].v[r];\n");
        try inner.appendSlice(gpa, "                            }\n");
        try inner.appendSlice(gpa, "                        }\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.uniformMatrix3fv(loc, false, &data);\n");
        try inner.appendSlice(gpa, "                    } else if (T.cols == 2 and T.rows == 2) {\n");
        try inner.appendSlice(gpa, "                        var data: [4]f32 = undefined;\n");
        try inner.appendSlice(gpa, "                        inline for (0..2) |c| {\n");
        try inner.appendSlice(gpa, "                            inline for (0..2) |r| {\n");
        try inner.appendSlice(gpa, "                                data[c * 2 + r] = value.data[c].v[r];\n");
        try inner.appendSlice(gpa, "                            }\n");
        try inner.appendSlice(gpa, "                        }\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.uniformMatrix2fv(loc, false, &data);\n");
        try inner.appendSlice(gpa, "                    } else if (T.cols == 3 and T.rows == 2) {\n");
        try inner.appendSlice(gpa, "                        var data: [6]f32 = undefined;\n");
        try inner.appendSlice(gpa, "                        inline for (0..3) |c| {\n");
        try inner.appendSlice(gpa, "                            inline for (0..2) |r| {\n");
        try inner.appendSlice(gpa, "                                data[c * 2 + r] = value.data[c].v[r];\n");
        try inner.appendSlice(gpa, "                            }\n");
        try inner.appendSlice(gpa, "                        }\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.uniformMatrix3x2fv(loc, false, &data);\n");
        try inner.appendSlice(gpa, "                    } else if (T.cols == 2 and T.rows == 3) {\n");
        try inner.appendSlice(gpa, "                        var data: [6]f32 = undefined;\n");
        try inner.appendSlice(gpa, "                        inline for (0..2) |c| {\n");
        try inner.appendSlice(gpa, "                            inline for (0..3) |r| {\n");
        try inner.appendSlice(gpa, "                                data[c * 3 + r] = value.data[c].v[r];\n");
        try inner.appendSlice(gpa, "                            }\n");
        try inner.appendSlice(gpa, "                        }\n");
        try inner.appendSlice(gpa, "                        gl.uniforms.uniformMatrix2x3fv(loc, false, &data);\n");
        try inner.appendSlice(gpa, "                    }\n");
        try inner.appendSlice(gpa, "                } else if (loc != -1 and T == f32) {\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1f(loc, value);\n");
        try inner.appendSlice(gpa, "                } else if (loc != -1 and T == i32) {\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1i(loc, value);\n");
        try inner.appendSlice(gpa, "                } else if (loc != -1 and T == u32) {\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1ui(loc, value);\n");
        try inner.appendSlice(gpa, "                } else if (loc != -1 and T == bool) {\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1i(loc, if (value) 1 else 0);\n");
        try inner.appendSlice(gpa, "                } else if (@typeInfo(T) == .@\"struct\") {\n");
        try inner.appendSlice(gpa, "                    // Custom struct uniform: upload members with dotted GL names.\n");
        try inner.appendSlice(gpa, "                    UniformUpload.flatten(self._program, name, T, value, gl);\n");
        try inner.appendSlice(gpa, "                } else {}\n");
        try inner.appendSlice(gpa, "                }\n");
        try inner.appendSlice(gpa, "            }\n");
        try inner.appendSlice(gpa, "            mut._set_all = false;\n");
        try inner.appendSlice(gpa, "            inline for (@typeInfo(@TypeOf(mut._dirty)).@\"struct\".fields) |f| @field(mut._dirty, f.name) = false;\n");
        try inner.appendSlice(gpa, "        }\n");
        try inner.appendSlice(gpa, "    };\n\n");

        try inner.appendSlice(gpa, "    pub fn instance() u32 {\n");
        try inner.appendSlice(gpa, "        if (_initialized and id != 0) return id;\n");
        try inner.appendSlice(gpa, "        const gl = @import(\"gl_graphics\").gl;\n");
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
        try inner.appendSlice(gpa, "        const shader = gl.shaders.create(.vertex_shader);\n");
        try inner.appendSlice(gpa, "        gl.shaders.source(shader, src);\n");
        try inner.appendSlice(gpa, "        gl.shaders.compile(shader);\n");
        try inner.appendSlice(gpa, "        var ok: i32 = 0;\n");
        try inner.appendSlice(gpa, "        gl.shaders.getParameter(shader, .compile_status, @ptrCast(&ok));\n");
        try inner.appendSlice(gpa, "        if (ok == 0) {\n");
        try inner.appendSlice(gpa, "            var log: [512]u8 = undefined;\n");
        try inner.appendSlice(gpa, "            const len = gl.shaders.getInfoLog(shader, &log);\n");
        try inner.appendSlice(gpa, "            _ = len;\n");
        try inner.appendSlice(gpa, "        }\n");
        try inner.appendSlice(gpa, "        id = shader;\n");
        try inner.appendSlice(gpa, "        _initialized = true;\n");
        try inner.appendSlice(gpa, "        return id;\n");
        try inner.appendSlice(gpa, "    }\n\n");

        try inner.appendSlice(gpa, "    pub fn dispose() void {\n");
        try inner.appendSlice(gpa, "        if (id != 0) { @import(\"gl_graphics\").gl.shaders.delete(id); id = 0; _initialized = false; }\n");
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
    /// Returns: Descriptor with vtable.
    pub fn descriptor(self: *VertexDescriptor) Descriptor {
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
