/// Standard library import.
const std = @import("std");
/// Text utilities from assets_manager.
const text_utils = @import("assets_manager").text_utils;

/// Describes a single field inside a GLSL struct.
pub const FieldDef = struct {
    /// GLSL type name as allocated string.
    typ: []u8,
    /// Field name as allocated string.
    name: []u8,
    /// True when the field is an array type.
    is_array: bool = false,
    /// Optional fixed array length parsed from brackets.
    array_len: ?usize = null,
};

/// Describes a GLSL struct declaration.
pub const StructDef = struct {
    /// Struct name as allocated string.
    name: []u8,
    /// Fields belonging to the struct as allocated slice.
    fields: []FieldDef,
};

/// Classification of a uniform declaration.
pub const UniformKind = enum {
    /// Simple single uniform variable.
    simple,
    /// Uniform block with multiple fields.
    block,
};

/// Describes a parsed uniform variable or block.
pub const UniformDef = struct {
    /// Kind of uniform.
    kind: UniformKind,
    /// Original GLSL type name as allocated string.
    glsl_type: []u8,
    /// Uniform instance name as allocated string.
    name: []u8,
    /// Fields for block uniforms, null for simple uniforms.
    block_fields: ?[]FieldDef = null,
    /// True when the uniform is a sampler type.
    is_sampler: bool = false,
    /// True when the uniform represents a buffer or block.
    is_buffer: bool = false,
};

/// Checks whether a byte is whitespace.
/// Parameters:
/// - c: byte to test.
/// Returns: true if whitespace.
pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}
/// Checks whether a byte is an alphabetic character or underscore.
/// Parameters:
/// - c: byte to test.
/// Returns: true if alpha or underscore.
pub fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}
/// Checks whether a byte is alphanumeric or underscore.
/// Parameters:
/// - c: byte to test.
/// Returns: true if alnum or underscore.
pub fn isAlnum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}
/// Checks whether a byte is a decimal digit.
/// Parameters:
/// - c: byte to test.
/// Returns: true if digit.
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Skips whitespace characters starting at index i.
/// Parameters:
/// - s: source slice.
/// - i: starting index.
/// Returns: index of first non-whitespace or length.
pub fn skipSpaces(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and isWhitespace(s[j])) j += 1;
    return j;
}

/// Strips line and block comments from GLSL source.
/// Preserves content outside comments and handles string literals correctly.
/// Parameters:
/// - allocator: allocator for output.
/// - source: source text to strip.
/// Returns: newly allocated stripped string.
pub fn stripComments(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < source.len) {
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '/') {
            i += 2;
            while (i < source.len and source[i] != '\n') i += 1;
        } else if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            i += 2;
        } else {
            try out.append(allocator, source[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Strips layout qualifiers by replacing them with spaces to preserve offsets.
/// Parameters:
/// - allocator: allocator for output.
/// - source: source text.
/// Returns: newly allocated string with layouts replaced by spaces.
pub fn stripLayouts(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < source.len) {
        if (i + 6 <= source.len and std.mem.eql(u8, source[i .. i + 6], "layout")) {
            var j = i + 6;
            j = skipSpaces(source, j);
            if (j < source.len and source[j] == '(') {
                var depth: usize = 0;
                var k = j;
                while (k < source.len) : (k += 1) {
                    if (source[k] == '(') depth += 1 else if (source[k] == ')') {
                        depth -= 1;
                        if (depth == 0) {
                            k += 1;
                            break;
                        }
                    }
                }
                const len = k - i;
                for (0..len) |_| try out.append(allocator, ' ');
                i = k;
                continue;
            }
        }
        try out.append(allocator, source[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Maps a GLSL type name to its Zig equivalent.
/// Parameters:
/// - allocator: allocator for result.
/// - glsl_type: GLSL type string.
/// Returns: newly allocated Zig type string.
pub fn mapGLSLTypeToZig(allocator: std.mem.Allocator, glsl_type: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, glsl_type, "sampler")) {
        return std.fmt.allocPrint(allocator, "*const @import(\"gl_graphics\").Texture", .{});
    }
    const builtin = std.StaticStringMap([]const u8).initComptime(.{
        .{ "float", "f32" },
        .{ "int", "i32" },
        .{ "uint", "u32" },
        .{ "bool", "bool" },
        .{ "vec2", "@import(\"gl_graphics\").math.Vec(2, f32)" },
        .{ "vec3", "@import(\"gl_graphics\").math.Vec(3, f32)" },
        .{ "vec4", "@import(\"gl_graphics\").math.Vec(4, f32)" },
        .{ "ivec2", "@import(\"gl_graphics\").math.Vec(2, i32)" },
        .{ "ivec3", "@import(\"gl_graphics\").math.Vec(3, i32)" },
        .{ "ivec4", "@import(\"gl_graphics\").math.Vec(4, i32)" },
        .{ "uvec2", "@import(\"gl_graphics\").math.Vec(2, u32)" },
        .{ "uvec3", "@import(\"gl_graphics\").math.Vec(3, u32)" },
        .{ "uvec4", "@import(\"gl_graphics\").math.Vec(4, u32)" },
        .{ "bvec2", "@import(\"gl_graphics\").math.Vec(2, bool)" },
        .{ "bvec3", "@import(\"gl_graphics\").math.Vec(3, bool)" },
        .{ "bvec4", "@import(\"gl_graphics\").math.Vec(4, bool)" },
        .{ "mat2", "@import(\"gl_graphics\").math.Mat(2, 2, f32)" },
        .{ "mat3", "@import(\"gl_graphics\").math.Mat(3, 3, f32)" },
        .{ "mat4", "@import(\"gl_graphics\").math.Mat(4, 4, f32)" },
        .{ "mat2x2", "@import(\"gl_graphics\").math.Mat(2, 2, f32)" },
        .{ "mat2x3", "@import(\"gl_graphics\").math.Mat(2, 3, f32)" },
        .{ "mat2x4", "@import(\"gl_graphics\").math.Mat(2, 4, f32)" },
        .{ "mat3x2", "@import(\"gl_graphics\").math.Mat(3, 2, f32)" },
        .{ "mat3x3", "@import(\"gl_graphics\").math.Mat(3, 3, f32)" },
        .{ "mat3x4", "@import(\"gl_graphics\").math.Mat(3, 4, f32)" },
        .{ "mat4x2", "@import(\"gl_graphics\").math.Mat(4, 2, f32)" },
        .{ "mat4x3", "@import(\"gl_graphics\").math.Mat(4, 3, f32)" },
        .{ "mat4x4", "@import(\"gl_graphics\").math.Mat(4, 4, f32)" },
    });
    if (builtin.get(glsl_type)) |zig_type| {
        return allocator.dupe(u8, zig_type);
    }
    return allocator.dupe(u8, glsl_type);
}

/// Returns true when the type name denotes a sampler.
/// Parameters:
/// - t: type name to test.
/// Returns: true if sampler type.
pub fn isSamplerType(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "sampler");
}

/// Parses GLSL struct definitions from source.
/// Parameters:
/// - allocator: allocator for results.
/// - source: source text stripped of comments.
/// Returns: slice of StructDef values.
pub fn parseStructs(allocator: std.mem.Allocator, source: []const u8) ![]StructDef {
    var list = std.ArrayList(StructDef).empty;
    errdefer {
        for (list.items) |*s| {
            allocator.free(s.name);
            for (s.fields) |f| {
                allocator.free(f.typ);
                allocator.free(f.name);
            }
            allocator.free(s.fields);
        }
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (i < source.len) {
        const pos = std.mem.indexOfPos(u8, source, i, "struct") orelse break;
        const before_ok = pos == 0 or !isAlnum(source[pos - 1]);
        const after = pos + 6;
        const after_ok = after >= source.len or isWhitespace(source[after]) or source[after] == '{' or source[after] == ' ';
        if (!before_ok or !after_ok) {
            i = pos + 6;
            continue;
        }
        var j = skipSpaces(source, after);
        const name_start = j;
        while (j < source.len and (isAlnum(source[j]) or source[j] == '_')) j += 1;
        if (j == name_start) {
            i = j;
            continue;
        }
        const struct_name = try allocator.dupe(u8, source[name_start..j]);
        j = skipSpaces(source, j);
        if (j >= source.len or source[j] != '{') {
            allocator.free(struct_name);
            i = j;
            continue;
        }
        const brace_open = j;
        var depth: usize = 0;
        var k = brace_open;
        var close: ?usize = null;
        while (k < source.len) : (k += 1) {
            if (source[k] == '{') depth += 1 else if (source[k] == '}') {
                depth -= 1;
                if (depth == 0) {
                    close = k;
                    break;
                }
            }
        }
        const brace_close = close orelse {
            allocator.free(struct_name);
            break;
        };
        const inner = source[brace_open + 1 .. brace_close];
        var fields = std.ArrayList(FieldDef).empty;
        var f_it = std.mem.splitScalar(u8, inner, ';');
        while (f_it.next()) |raw_field| {
            const trimmed = std.mem.trim(u8, raw_field, &[_]u8{ ' ', '\t', '\r', '\n' });
            if (trimmed.len == 0) continue;
            var tokens = std.ArrayList([]const u8).empty;
            defer tokens.deinit(allocator);
            var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
            while (tok_it.next()) |tok| try tokens.append(allocator, tok);
            if (tokens.items.len < 2) continue;
            var type_idx: usize = 0;
            if (tokens.items.len >= 3 and (std.mem.eql(u8, tokens.items[0], "highp") or std.mem.eql(u8, tokens.items[0], "mediump") or std.mem.eql(u8, tokens.items[0], "lowp"))) {
                type_idx = 1;
            }
            const typ_tok = tokens.items[type_idx];
            const name_tok_raw = tokens.items[type_idx + 1];
            var name_tok = name_tok_raw;
            var is_arr = false;
            var arr_len: ?usize = null;
            if (std.mem.indexOfScalar(u8, name_tok, '[')) |br| {
                is_arr = true;
                const name_only = name_tok[0..br];
                const arr_part = name_tok[br..];
                if (std.mem.indexOfScalar(u8, arr_part, ']')) |_| {
                    const inside = arr_part[1 .. arr_part.len - 1];
                    const trimmed_inside = std.mem.trim(u8, inside, &[_]u8{ ' ', '\t' });
                    if (trimmed_inside.len > 0) {
                        arr_len = std.fmt.parseInt(usize, trimmed_inside, 10) catch null;
                    }
                }
                name_tok = name_only;
            }
            const typ_copy = try allocator.dupe(u8, typ_tok);
            const name_copy = try allocator.dupe(u8, name_tok);
            try fields.append(allocator, .{ .typ = typ_copy, .name = name_copy, .is_array = is_arr, .array_len = arr_len });
        }
        const fields_slice = try fields.toOwnedSlice(allocator);
        try list.append(allocator, .{ .name = struct_name, .fields = fields_slice });
        i = brace_close + 1;
        const semi = std.mem.indexOfPos(u8, source, i, ";");
        if (semi) |s| i = s + 1 else i = brace_close + 1;
    }
    return list.toOwnedSlice(allocator);
}

/// Parses vertex input declarations from source.
/// Parameters:
/// - allocator: allocator for results.
/// - source: source text.
/// Returns: slice of FieldDef values representing inputs.
pub fn parseIns(allocator: std.mem.Allocator, source: []const u8) ![]FieldDef {
    var list = std.ArrayList(FieldDef).empty;
    errdefer {
        for (list.items) |f| {
            allocator.free(f.typ);
            allocator.free(f.name);
        }
        list.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, source, ';');
    while (it.next()) |stmt_raw| {
        var stmt = std.mem.trim(u8, stmt_raw, &[_]u8{ ' ', '\t', '\r', '\n' });
        if (stmt.len == 0) continue;
        var in_pos: ?usize = null;
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, stmt, search, "in ")) |pos| {
            const before_ok = pos == 0 or isWhitespace(stmt[pos - 1]) or stmt[pos - 1] == '\n' or stmt[pos - 1] == ';';
            const after = pos + 3;
            const after_ok = after < stmt.len and !isWhitespace(stmt[after]) and stmt[after] != ';';
            if (before_ok and after_ok) in_pos = pos;
            search = pos + 3;
        }
        if (in_pos == null and std.mem.startsWith(u8, stmt, "in ")) in_pos = 0;
        const pos = in_pos orelse continue;
        stmt = std.mem.trim(u8, stmt[pos + 3 ..], &[_]u8{ ' ', '\t' });
        var tokens = std.ArrayList([]const u8).empty;
        defer tokens.deinit(allocator);
        var tok_it = std.mem.tokenizeAny(u8, stmt, " \t");
        while (tok_it.next()) |tok| try tokens.append(allocator, tok);
        if (tokens.items.len < 2) continue;
        var type_idx: usize = 0;
        if (tokens.items.len >= 3 and (std.mem.eql(u8, tokens.items[0], "highp") or std.mem.eql(u8, tokens.items[0], "mediump") or std.mem.eql(u8, tokens.items[0], "lowp"))) type_idx = 1;
        const typ = tokens.items[type_idx];
        var name = tokens.items[type_idx + 1];
        if (std.mem.indexOfScalar(u8, name, '[')) |br| name = name[0..br];
        if (std.mem.indexOfScalar(u8, name, ';')) |semi| name = name[0..semi];
        const typ_c = try allocator.dupe(u8, typ);
        const name_c = try allocator.dupe(u8, name);
        try list.append(allocator, .{ .typ = typ_c, .name = name_c });
    }
    return list.toOwnedSlice(allocator);
}

/// Parses uniform declarations from source.
/// Parameters:
/// - allocator: allocator for results.
/// - source: source text.
/// Returns: slice of UniformDef values.
pub fn parseUniforms(allocator: std.mem.Allocator, source: []const u8) ![]UniformDef {
    var list = std.ArrayList(UniformDef).empty;
    errdefer {
        for (list.items) |*u| {
            allocator.free(u.glsl_type);
            allocator.free(u.name);
            if (u.block_fields) |fields| {
                for (fields) |f| {
                    allocator.free(f.typ);
                    allocator.free(f.name);
                }
                allocator.free(fields);
            }
        }
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (i < source.len) {
        const uni_pos = std.mem.indexOfPos(u8, source, i, "uniform") orelse break;
        const before_ok = uni_pos == 0 or !isAlnum(source[uni_pos - 1]);
        const after = uni_pos + 7;
        const after_ok = after >= source.len or isWhitespace(source[after]) or source[after] == '{' or source[after] == ' ' or source[after] == '\n' or source[after] == '\r';
        if (!before_ok or !after_ok) {
            i = uni_pos + 7;
            continue;
        }
        const j = skipSpaces(source, after);
        var tmp = j;
        var ident: ?[]const u8 = null;
        var ident_end = tmp;
        if (tmp < source.len and isAlpha(source[tmp])) {
            var k = tmp;
            while (k < source.len and (isAlnum(source[k]) or source[k] == '_')) k += 1;
            ident = source[tmp..k];
            ident_end = k;
            tmp = skipSpaces(source, k);
        }
        if (tmp < source.len and source[tmp] == '{') {
            const block_name = if (ident) |n| try allocator.dupe(u8, n) else try allocator.dupe(u8, "AnonymousBlock");
            const brace_open = tmp;
            var depth: usize = 0;
            var k = brace_open;
            var close: ?usize = null;
            while (k < source.len) : (k += 1) {
                if (source[k] == '{') depth += 1 else if (source[k] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        close = k;
                        break;
                    }
                }
            }
            const brace_close = close orelse {
                if (block_name.len != 0) allocator.free(block_name);
                break;
            };
            const inner = source[brace_open + 1 .. brace_close];
            var fields = std.ArrayList(FieldDef).empty;
            var f_it = std.mem.splitScalar(u8, inner, ';');
            while (f_it.next()) |raw| {
                const trimmed = std.mem.trim(u8, raw, &[_]u8{ ' ', '\t', '\r', '\n' });
                if (trimmed.len == 0) continue;
                var tokens = std.ArrayList([]const u8).empty;
                defer tokens.deinit(allocator);
                var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t");
                while (tok_it.next()) |tok| try tokens.append(allocator, tok);
                if (tokens.items.len < 2) continue;
                var type_idx: usize = 0;
                if (tokens.items.len >= 3 and (std.mem.eql(u8, tokens.items[0], "highp") or std.mem.eql(u8, tokens.items[0], "mediump") or std.mem.eql(u8, tokens.items[0], "lowp"))) type_idx = 1;
                const typ = tokens.items[type_idx];
                var name = tokens.items[type_idx + 1];
                var is_arr = false;
                var arr_len: ?usize = null;
                if (std.mem.indexOfScalar(u8, name, '[')) |br| {
                    is_arr = true;
                    const name_only = name[0..br];
                    const arr_part = name[br..];
                    if (std.mem.indexOfScalar(u8, arr_part, ']')) |_| {
                        const inside = arr_part[1 .. arr_part.len - 1];
                        const trimmed_inside = std.mem.trim(u8, inside, &[_]u8{ ' ', '\t' });
                        if (trimmed_inside.len > 0) arr_len = std.fmt.parseInt(usize, trimmed_inside, 10) catch null;
                    }
                    name = name_only;
                }
                const typ_c = try allocator.dupe(u8, typ);
                const name_c = try allocator.dupe(u8, name);
                try fields.append(allocator, .{ .typ = typ_c, .name = name_c, .is_array = is_arr, .array_len = arr_len });
            }
            const fields_slice = try fields.toOwnedSlice(allocator);
            var after_close = skipSpaces(source, brace_close + 1);
            var instance_name: ?[]u8 = null;
            if (after_close < source.len and isAlpha(source[after_close])) {
                var kk = after_close;
                while (kk < source.len and (isAlnum(source[kk]) or source[kk] == '_')) kk += 1;
                instance_name = try allocator.dupe(u8, source[after_close..kk]);
                after_close = kk;
            } else {
                const lower = try allocator.dupe(u8, block_name);
                for (lower) |*c| c.* = std.ascii.toLower(c.*);
                instance_name = lower;
            }
            const semi = std.mem.indexOfPos(u8, source, after_close, ";");
            i = (semi orelse brace_close) + 1;
            const block_fields = fields_slice;
            const type_copy = try allocator.dupe(u8, block_name);
            defer allocator.free(block_name);
            try list.append(allocator, .{
                .kind = .block,
                .glsl_type = type_copy,
                .name = instance_name.?,
                .block_fields = block_fields,
                .is_buffer = true,
            });
        } else {
            var type_str: []const u8 = "";
            var name_str: []const u8 = "";
            var type_end = j;
            if (ident) |t| {
                type_str = t;
                type_end = ident_end;
            } else {
                i = j;
                continue;
            }
            if (std.mem.eql(u8, type_str, "highp") or std.mem.eql(u8, type_str, "mediump") or std.mem.eql(u8, type_str, "lowp")) {
                const nxt = skipSpaces(source, type_end);
                var k = nxt;
                while (k < source.len and (isAlnum(source[k]) or source[k] == '_')) k += 1;
                type_str = source[nxt..k];
                type_end = k;
            }
            const after_type = skipSpaces(source, type_end);
            if (after_type >= source.len or !isAlpha(source[after_type])) {
                i = after_type;
                continue;
            }
            var k = after_type;
            while (k < source.len and (isAlnum(source[k]) or source[k] == '_')) k += 1;
            name_str = source[after_type..k];
            var after_name = skipSpaces(source, k);
            if (after_name < source.len and source[after_name] == '[') {
                var br = after_name;
                while (br < source.len and source[br] != ']') br += 1;
                if (br < source.len) br += 1;
                after_name = skipSpaces(source, br);
            }
            const semi = std.mem.indexOfPos(u8, source, after_name, ";") orelse {
                i = after_name;
                continue;
            };
            const typ_c = try allocator.dupe(u8, type_str);
            const name_c = try allocator.dupe(u8, name_str);
            const is_samp = isSamplerType(typ_c);
            try list.append(allocator, .{
                .kind = .simple,
                .glsl_type = typ_c,
                .name = name_c,
                .is_sampler = is_samp,
                .is_buffer = false,
            });
            i = semi + 1;
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Frees a slice of StructDef and its owned strings.
/// Parameters:
/// - allocator: allocator that was used.
/// - structs: slice to free.
/// Returns: void.
pub fn freeStructs(allocator: std.mem.Allocator, structs: []StructDef) void {
    for (structs) |*s| {
        allocator.free(s.name);
        for (s.fields) |f| {
            allocator.free(f.typ);
            allocator.free(f.name);
        }
        allocator.free(s.fields);
    }
    allocator.free(structs);
}

/// Frees a slice of UniformDef and its owned strings.
/// Parameters:
/// - allocator: allocator that was used.
/// - uniforms: slice to free.
/// Returns: void.
pub fn freeUniforms(allocator: std.mem.Allocator, uniforms: []UniformDef) void {
    for (uniforms) |*u| {
        allocator.free(u.glsl_type);
        allocator.free(u.name);
        if (u.block_fields) |fields| {
            for (fields) |f| {
                allocator.free(f.typ);
                allocator.free(f.name);
            }
            allocator.free(fields);
        }
    }
    allocator.free(uniforms);
}

/// Frees a slice of FieldDef and its owned strings.
/// Parameters:
/// - allocator: allocator that was used.
/// - fields: slice to free.
/// Returns: void.
pub fn freeFields(allocator: std.mem.Allocator, fields: []FieldDef) void {
    for (fields) |f| {
        allocator.free(f.typ);
        allocator.free(f.name);
    }
    allocator.free(fields);
}

/// Reads a node file by walking the asset tree.
/// Parameters:
/// - allocator: allocator for result.
/// - io: Io interface for file operations.
/// - nodePath: relative node path to locate.
/// Returns: optional file content or null if not found.
pub fn readNodeFile(allocator: std.mem.Allocator, io: std.Io, nodePath: []const u8) !?[]u8 {
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, ".", .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();
    var candidate: ?[]u8 = null;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const p = entry.path;
        const is_sep = p.len > nodePath.len and (p[p.len - nodePath.len - 1] == '/' or p[p.len - nodePath.len - 1] == '\\');
        if (std.mem.eql(u8, p, nodePath) or (p.len > nodePath.len and std.mem.endsWith(u8, p, nodePath) and is_sep)) {
            candidate = try allocator.dupe(u8, p);
            break;
        }
    }
    if (candidate) |path| {
        defer allocator.free(path);
        var file = cwd.openFile(io, path, .{}) catch return null;
        defer file.close(io);
        const stat = file.stat(io) catch return null;
        const size: usize = @intCast(stat.size);
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        var total: usize = 0;
        while (total < size) {
            const n = try file.readStreaming(io, &.{buf[total..]});
            if (n == 0) break;
            total += n;
        }
        return buf[0..total];
    }
    {
        var file = cwd.openFile(io, nodePath, .{}) catch return null;
        defer file.close(io);
        const stat = file.stat(io) catch return null;
        const size: usize = @intCast(stat.size);
        const buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        var total: usize = 0;
        while (total < size) {
            const n = try file.readStreaming(io, &.{buf[total..]});
            if (n == 0) break;
            total += n;
        }
        return buf[0..total];
    }
}

/// Resolves an include path relative to a base file path.
/// Parameters:
/// - allocator: allocator for result.
/// - baseFilePath: path of the including file.
/// - includeRaw: raw include string.
/// Returns: newly allocated resolved path.
pub fn resolveIncludePath(allocator: std.mem.Allocator, baseFilePath: []const u8, includeRaw: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(includeRaw)) return allocator.dupe(u8, includeRaw);
    const dir = std.fs.path.dirname(baseFilePath) orelse ".";
    // Relative include in the same directory: keep the bare name so that
    // `readNodeFile` can resolve it through its path suffix walker.
    if (std.mem.eql(u8, dir, ".")) return allocator.dupe(u8, includeRaw);
    return std.fs.path.join(allocator, &.{ dir, includeRaw });
}

/// Recursively processes a shader source, inlining `#include` contents at
/// their exact position (so declarations keep their original order), dropping
/// `#version`/`#include` directives and registering struct definitions
/// declared in `.glsl` files into `link_map` (struct name -> owning file
/// identifier, e.g. "Light" -> "common").
fn processShaderFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(u8),
    src: []const u8,
    path: []const u8,
    visited: *std.StringHashMap(void),
    link_map: *std.StringHashMap([]u8),
) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
        if (std.mem.startsWith(u8, trimmed, "#include")) {
            const inc = blk: {
                var rest = std.mem.trim(u8, trimmed["#include".len..], &[_]u8{ ' ', '\t' });
                if (rest.len >= 2 and (rest[0] == '"' or rest[0] == '<')) {
                    const endC: u8 = if (rest[0] == '"') '"' else '>';
                    if (std.mem.indexOfScalar(u8, rest[1..], endC)) |end| {
                        break :blk rest[1 .. 1 + end];
                    }
                }
                break :blk "";
            };
            if (inc.len > 0) {
                const resolved = try resolveIncludePath(gpa, path, inc);
                if (!visited.contains(resolved)) {
                    try visited.put(try gpa.dupe(u8, resolved), {});
                    if (try readNodeFile(gpa, io, resolved)) |content| {
                        const c = if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF")) content[3..] else content;
                        if (std.mem.endsWith(u8, resolved, ".glsl")) {
                            const inc_base = std.fs.path.basename(resolved);
                            const dot = std.mem.lastIndexOfScalar(u8, inc_base, '.');
                            const base = if (dot) |d| inc_base[0..d] else inc_base;
                            const inc_ident = try text_utils.filenameToIdentifier(gpa, base);
                            const inc_no_comments = try stripComments(gpa, c);
                            const inc_structs = try parseStructs(gpa, inc_no_comments);
                            for (inc_structs) |s| {
                                const key = try gpa.dupe(u8, s.name);
                                const ident_copy = try gpa.dupe(u8, inc_ident);
                                if (!link_map.contains(key)) {
                                    try link_map.put(key, ident_copy);
                                } else {
                                    gpa.free(key);
                                    gpa.free(ident_copy);
                                }
                            }
                            freeStructs(gpa, inc_structs);
                            gpa.free(inc_no_comments);
                            gpa.free(inc_ident);
                        }
                        try processShaderFile(gpa, io, out, c, resolved, visited, link_map);
                        gpa.free(content);
                    }
                }
                gpa.free(resolved);
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#version")) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
}

/// Resolves `#include` directives into a single GLSL source text. The main
/// file's `#version` is kept as the first line; includes are inlined at the
/// position of their directive.
/// Parameters:
/// - gpa: allocator for internal use.
/// - io: Io interface for file reads.
/// - out: output buffer for the assembled source.
/// - main_src: source of the main shader file.
/// - main_path: path of the main shader file.
/// - visited: set of already-included paths (caller owned).
/// - link_map: struct name -> owning .glsl identifier registry.
/// Returns: void.
pub fn resolveShaderIncludes(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(u8),
    main_src: []const u8,
    main_path: []const u8,
    visited: *std.StringHashMap(void),
    link_map: *std.StringHashMap([]u8),
) !void {
    {
        var it = std.mem.splitScalar(u8, main_src, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
            if (std.mem.startsWith(u8, trimmed, "#version")) {
                try out.appendSlice(gpa, line);
                try out.append(gpa, '\n');
                break;
            }
        }
    }
    try processShaderFile(gpa, io, out, main_src, main_path, visited, link_map);
}

test "parse structs" {
    const alloc = std.testing.allocator;
    const src =
        \\struct Light {
        \\    vec3 position;
        \\    float intensity;
        \\};
        \\struct Material { vec4 diffuse; Light light; };
    ;
    const structs = try parseStructs(alloc, src);
    defer freeStructs(alloc, structs);
    try std.testing.expectEqual(@as(usize, 2), structs.len);
    try std.testing.expectEqualStrings("Light", structs[0].name);
    try std.testing.expectEqual(@as(usize, 2), structs[0].fields.len);
    try std.testing.expectEqualStrings("vec3", structs[0].fields[0].typ);
    try std.testing.expectEqualStrings("position", structs[0].fields[0].name);
}

test "parse ins" {
    const alloc = std.testing.allocator;
    const src = "layout(location=0) in vec3 aPos; in vec2 aTexCoord; uniform mat4 uModel;";
    const no_comments = try stripComments(alloc, src);
    defer alloc.free(no_comments);
    const stripped = try stripLayouts(alloc, no_comments);
    defer alloc.free(stripped);
    const ins = try parseIns(alloc, stripped);
    defer freeFields(alloc, ins);
    try std.testing.expectEqual(@as(usize, 2), ins.len);
    try std.testing.expectEqualStrings("aPos", ins[0].name);
    try std.testing.expectEqualStrings("vec3", ins[0].typ);
}

test "parse ins with version" {
    const alloc = std.testing.allocator;
    const src = "#version 300 es\n\nin vec3 aPos; \n\nout vec3 vColor;\n\nvoid main() { gl_Position = vec4(aPos, 1.0); }";
    const no_comments = try stripComments(alloc, src);
    defer alloc.free(no_comments);
    const stripped = try stripLayouts(alloc, no_comments);
    defer alloc.free(stripped);
    const ins = try parseIns(alloc, stripped);
    defer freeFields(alloc, ins);
    try std.testing.expectEqual(@as(usize, 1), ins.len);
    try std.testing.expectEqualStrings("aPos", ins[0].name);
    try std.testing.expectEqualStrings("vec3", ins[0].typ);
}

test "parse uniforms simple" {
    const alloc = std.testing.allocator;
    const src = "uniform mat4 uModel; uniform sampler2D uTex; uniform Light uLight;";
    const uniforms = try parseUniforms(alloc, src);
    defer freeUniforms(alloc, uniforms);
    try std.testing.expectEqual(@as(usize, 3), uniforms.len);
    try std.testing.expectEqualStrings("uModel", uniforms[0].name);
    try std.testing.expectEqualStrings("mat4", uniforms[0].glsl_type);
    try std.testing.expect(uniforms[1].is_sampler);
}

test "map glsl to zig" {
    const alloc = std.testing.allocator;
    const t1 = try mapGLSLTypeToZig(alloc, "vec3");
    defer alloc.free(t1);
    try std.testing.expect(std.mem.indexOf(u8, t1, "Vec(3") != null);
    const t2 = try mapGLSLTypeToZig(alloc, "sampler2D");
    defer alloc.free(t2);
    try std.testing.expectEqualStrings("*const @import(\"gl_graphics\").Texture", t2);
}
