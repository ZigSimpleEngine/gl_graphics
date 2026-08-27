const std = @import("std");
const Descriptor = @import("assets_manager").descriptors.Descriptor;
const Node = @import("assets_manager").assets_tree.Node;
const text_utils = @import("assets_manager").text_utils;
const common = @import("common.zig");

pub const VertexDescriptor = struct {
    spaces_per_depth: usize = 4,

    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, data: Descriptor.Data) anyerror!bool {
        _ = ptr; _ = init;
        const node = data.node;
        if (node.kind != .file) return false;
        if (node.name) |name| return std.mem.endsWith(u8, name, ".vert");
        return false;
    }

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

        // embed path for instance()
        const embed_path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ data.path_to_root_node, path });
        defer gpa.free(embed_path);

        // Read main file content
        const raw_main = try common.readNodeFile(gpa, io, path) orelse try gpa.dupe(u8, "");
        defer gpa.free(raw_main);

        // Collect includes recursively
        var include_contents = std.ArrayList([]u8).empty;
        defer {
            for (include_contents.items) |c| gpa.free(c);
            include_contents.deinit(gpa);
        }
        var visited = std.StringHashMap(void).init(gpa);
        defer visited.deinit();

        // Parse includes from raw_main (and nested)
        var include_queue = std.ArrayList([]u8).empty;
        defer {
            for (include_queue.items) |s| gpa.free(s);
            include_queue.deinit(gpa);
        }
        // First level includes from main
        {
            const lines = raw_main;
            var it = std.mem.splitScalar(u8, lines, '\n');
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
        // BFS resolve includes and collect their contents
        var idx: usize = 0;
        while (idx < include_queue.items.len) : (idx += 1) {
            const inc_path = include_queue.items[idx];
            if (visited.contains(inc_path)) continue;
            try visited.put(try gpa.dupe(u8, inc_path), {});
            const content = try common.readNodeFile(gpa, io, inc_path);
            if (content) |c| {
                try include_contents.append(gpa, c);
                // Also scan this content for nested includes
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
                                // check visited
                                var already = false;
                                for (include_queue.items) |q| {
                                    if (std.mem.eql(u8, q, resolved2)) { already = true; break; }
                                }
                                if (!already) {
                                    try include_queue.append(gpa, resolved2);
                                } else {
                                    gpa.free(resolved2);
                                }
                                continue;
                            }
                        }
                    }
                }
            } else {
                // could not read, ignore
            }
        }

        // Build combined source for struct parsing: concatenate all include contents + raw_main (with includes stripped)
        var combined = std.ArrayList(u8).empty;
        defer combined.deinit(gpa);
        for (include_contents.items) |c| {
            try combined.appendSlice(gpa, c);
            try combined.append(gpa, '\n');
        }
        // For raw_main, strip #include lines before appending (so they don't interfere)
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

        // For vertex inputs, we need source without layouts but also without include-structs? Use main-only source stripped?
        const main_no_comments = try common.stripComments(gpa, raw_main);
        defer gpa.free(main_no_comments);
        const stripped_for_ins = try common.stripLayouts(gpa, main_no_comments);
        defer gpa.free(stripped_for_ins);
        const ins = try common.parseIns(gpa, stripped_for_ins);
        defer common.freeFields(gpa, ins);

        const uniforms = try common.parseUniforms(gpa, no_comments);
        defer common.freeUniforms(gpa, uniforms);

        // Build code
        var inner = std.ArrayList(u8).empty;
        defer inner.deinit(gpa);

        // Helper to map uniform type already: we will need struct map for quick lookup
        var struct_map = std.StringHashMap(void).init(gpa);
        defer struct_map.deinit();
        for (structs) |s| try struct_map.put(s.name, {});

        // Emit structs from includes + main (as sibling consts)
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
                    } else {
                        try inner.appendSlice(gpa, zig_type);
                    }
                    try inner.appendSlice(gpa, ",\n");
                }
                try inner.appendSlice(gpa, "    };\n");
            }
            try inner.appendSlice(gpa, "\n");
        }

        // Also emit auxiliary structs for uniform blocks that are not already in structs map
        // Collect block structs to emit if not already defined
        for (uniforms) |u| {
            if (u.kind == .block) {
                const block_type = u.glsl_type;
                if (!struct_map.contains(block_type)) {
                    // Define block struct from its fields
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

        // Vertex
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

        // Uniform
        if (uniforms.len == 0) {
            try inner.appendSlice(gpa, "    pub const Uniform = struct {};\n");
        } else {
            try inner.appendSlice(gpa, "    pub const Uniform = struct {\n");
            for (uniforms) |u| {
                const zig_type_raw: []u8 = blk: {
                    if (u.kind == .block) {
                        // UBO -> Buffer(BlockType)
                        const inner_t = try common.mapGLSLTypeToZig(gpa, u.glsl_type);
                        defer gpa.free(inner_t);
                        // inner_t is e.g., "Matrices" or mapped; but for block we want struct name as is, not mapped math
                        // For block, glsl_type is block name, which is already struct name; map will return same name
                        // So we can do Buffer(BlockType)
                        break :blk try std.fmt.allocPrint(gpa, "@import(\"gl_graphics\").Buffer({s})", .{inner_t});
                    } else if (u.is_sampler) {
                        break :blk try gpa.dupe(u8, "@import(\"gl_graphics\").Texture");
                    } else {
                        // Check if uniform type is known struct -> keep as is, else map
                        if (struct_map.contains(u.glsl_type)) {
                            break :blk try gpa.dupe(u8, u.glsl_type);
                        } else {
                            break :blk try common.mapGLSLTypeToZig(gpa, u.glsl_type);
                        }
                    }
                };
                defer gpa.free(zig_type_raw);
                // Handle array uniforms: if uniform is array, wrap as [len]Type or []Type
                // Our UniformDef doesn't store array length; but parseUniforms currently doesn't capture array len.
                // So just emit as single.
                try inner.appendSlice(gpa, "        ");
                try inner.appendSlice(gpa, u.name);
                try inner.appendSlice(gpa, ": ");
                try inner.appendSlice(gpa, zig_type_raw);
                try inner.appendSlice(gpa, ",\n");
            }
            try inner.appendSlice(gpa, "    };\n");
        }
        try inner.appendSlice(gpa, "\n");

        // IdCache
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

        // id and id_cache vars
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

        // Editor
        try inner.appendSlice(gpa, "    pub const Editor = struct {\n");
        try inner.appendSlice(gpa, "        _program: u32,\n");
        try inner.appendSlice(gpa, "        _pending: Uniform = undefined,\n");
        // Dirty as struct of bools
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
            // Map zig type for param
            const zig_param_type: []u8 = blk: {
                if (u.kind == .block) {
                    const inner_t = try common.mapGLSLTypeToZig(gpa, u.glsl_type);
                    defer gpa.free(inner_t);
                    break :blk try std.fmt.allocPrint(gpa, "@import(\"gl_graphics\").Buffer({s})", .{inner_t});
                } else if (u.is_sampler) {
                    break :blk try gpa.dupe(u8, "@import(\"gl_graphics\").Texture");
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
        // For sampler we need texture unit management; generate per uniform handling with reflection?
        // We'll generate reflective loop with comptime.
        try inner.appendSlice(gpa, "            inline for (@typeInfo(Uniform).@\"struct\".fields) |field| {\n");
        try inner.appendSlice(gpa, "                const name = field.name;\n");
        try inner.appendSlice(gpa, "                const is_dirty = if (self._set_all) true else @field(self._dirty, name);\n");
        try inner.appendSlice(gpa, "                const loc = gl.uniforms.location(self._program, @ptrCast(name));\n");
        try inner.appendSlice(gpa, "                if (is_dirty and loc != -1) {\n");
        try inner.appendSlice(gpa, "                const value = @field(self._pending, name);\n");
        try inner.appendSlice(gpa, "                const T = @TypeOf(value);\n");
        // Dispatch with if chain — we need to handle common types generically via inline dispatch helper
        // For now we emit placeholder handling for f32/vec/mat/texture/buffer
        try inner.appendSlice(gpa, "                // Dispatch upload based on type — handles math, Texture, Buffer\n");
        try inner.appendSlice(gpa, "                if (T == @import(\"gl_graphics\").Texture) {\n");
        try inner.appendSlice(gpa, "                    const unit: u32 = 0; // TODO: assign texture unit tracking\n");
        try inner.appendSlice(gpa, "                    @import(\"gl_graphics\").gl.textures.activeTexture(@enumFromInt(@intFromEnum(@import(\"gl_graphics\").gl.textures.TextureUnit.texture0) + unit));\n");
        try inner.appendSlice(gpa, "                    @import(\"gl_graphics\").gl.textures.bind(.texture_2d, value.getId());\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1i(loc, @intCast(unit));\n");
        try inner.appendSlice(gpa, "                } else if (@typeInfo(T) == .@\"struct\" and @hasDecl(T, \"len\") and @hasDecl(T, \"value_type\")) {\n");
        try inner.appendSlice(gpa, "                    // Vec\n");
        try inner.appendSlice(gpa, "                    if (T.value_type == f32) {\n");
        try inner.appendSlice(gpa, "                        if (T.len == 1) gl.uniforms.uniform1f(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2f(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3f(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4f(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                    } else if (T.value_type == i32) {\n");
        try inner.appendSlice(gpa, "                        if (T.len == 1) gl.uniforms.uniform1i(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2i(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3i(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4i(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                    } else if (T.value_type == u32) {\n");
        try inner.appendSlice(gpa, "                        if (T.len == 1) gl.uniforms.uniform1ui(loc, value.v[0]) else if (T.len == 2) gl.uniforms.uniform2ui(loc, value.v[0], value.v[1]) else if (T.len == 3) gl.uniforms.uniform3ui(loc, value.v[0], value.v[1], value.v[2]) else if (T.len == 4) gl.uniforms.uniform4ui(loc, value.v[0], value.v[1], value.v[2], value.v[3]) else {}\n");
        try inner.appendSlice(gpa, "                    }\n");
        try inner.appendSlice(gpa, "                } else if (@typeInfo(T) == .@\"struct\" and @hasDecl(T, \"cols\") and @hasDecl(T, \"rows\")) {\n");
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
        try inner.appendSlice(gpa, "                    }\n");
        try inner.appendSlice(gpa, "                } else if (T == f32) {\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1f(loc, value);\n");
        try inner.appendSlice(gpa, "                } else if (T == i32) {\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1i(loc, value);\n");
        try inner.appendSlice(gpa, "                } else if (T == u32) {\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1ui(loc, value);\n");
        try inner.appendSlice(gpa, "                } else if (T == bool) {\n");
        try inner.appendSlice(gpa, "                    gl.uniforms.uniform1i(loc, if (value) 1 else 0);\n");
        try inner.appendSlice(gpa, "                } else {}\n");
        try inner.appendSlice(gpa, "                }\n");
        try inner.appendSlice(gpa, "            }\n");
        try inner.appendSlice(gpa, "            mut._set_all = false;\n");
        try inner.appendSlice(gpa, "            inline for (@typeInfo(@TypeOf(mut._dirty)).@\"struct\".fields) |f| @field(mut._dirty, f.name) = false;\n");
        try inner.appendSlice(gpa, "        }\n");
        try inner.appendSlice(gpa, "    };\n\n");

        // instance, dispose, edit
        try inner.appendSlice(gpa, "    pub fn instance() u32 {\n");
        try inner.appendSlice(gpa, "        if (_initialized and id != 0) return id;\n");
        try inner.appendSlice(gpa, "        const gl = @import(\"gl_graphics\").gl;\n");
        try inner.appendSlice(gpa, "        const src = @embedFile(\"");
        try inner.appendSlice(gpa, embed_path);
        try inner.appendSlice(gpa, "\");\n");
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

        const outer = try std.fmt.allocPrint(gpa,
            "{s}pub const {s} = struct {{\n{s}{s}{s}}};\n",
            .{ prefix orelse "", var_name, inner_slice, if (inner_slice.len > 0 and inner_slice[inner_slice.len - 1] == '\n') "" else "\n", prefix orelse "" });
        return outer;
    }

    pub fn descriptor(self: *VertexDescriptor) Descriptor {
        return .{ .ptr = self, .vtable = .{ .get_code = getCode, .is_suitable_data = isSuitableData } };
    }
};

fn blk_has(uniforms: []common.UniformDef) bool {
    for (uniforms) |u| if (u.kind == .block) return true;
    return false;
}
