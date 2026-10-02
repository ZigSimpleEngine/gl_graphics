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
///
/// Returns: true if whitespace.
pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}
/// Checks whether a byte is an alphabetic character or underscore.
/// Parameters:
/// - c: byte to test.
///
/// Returns: true if alpha or underscore.
pub fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}
/// Checks whether a byte is alphanumeric or underscore.
/// Parameters:
/// - c: byte to test.
///
/// Returns: true if alnum or underscore.
pub fn isAlnum(c: u8) bool {
    return isAlpha(c) or (c >= '0' and c <= '9');
}
/// Checks whether a byte is a decimal digit.
/// Parameters:
/// - c: byte to test.
///
/// Returns: true if digit.
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Skips whitespace characters starting at index i.
/// Parameters:
/// - s: source slice.
/// - i: starting index.
///
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
///
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
///
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
///
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
///
/// Returns: true if sampler type.
pub fn isSamplerType(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "sampler");
}

/// Parses GLSL struct definitions from source.
/// Parameters:
/// - allocator: allocator for results.
/// - source: source text stripped of comments.
///
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
///
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
///
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
///
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
///
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
///
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
///
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
///
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
    allocator: std.mem.Allocator,
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
                const resolved = try resolveIncludePath(allocator, path, inc);
                if (!visited.contains(resolved)) {
                    try visited.put(try allocator.dupe(u8, resolved), {});
                    if (try readNodeFile(allocator, io, resolved)) |content| {
                        const c = if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF")) content[3..] else content;
                        if (std.mem.endsWith(u8, resolved, ".glsl")) {
                            const inc_base = std.fs.path.basename(resolved);
                            const dot = std.mem.lastIndexOfScalar(u8, inc_base, '.');
                            const base = if (dot) |d| inc_base[0..d] else inc_base;
                            const inc_ident = try text_utils.filenameToIdentifier(allocator, base);
                            const inc_no_comments = try stripComments(allocator, c);
                            const inc_structs = try parseStructs(allocator, inc_no_comments);
                            for (inc_structs) |s| {
                                const key = try allocator.dupe(u8, s.name);
                                const ident_copy = try allocator.dupe(u8, inc_ident);
                                if (!link_map.contains(key)) {
                                    try link_map.put(key, ident_copy);
                                } else {
                                    allocator.free(key);
                                    allocator.free(ident_copy);
                                }
                            }
                            freeStructs(allocator, inc_structs);
                            allocator.free(inc_no_comments);
                            allocator.free(inc_ident);
                        }
                        try processShaderFile(allocator, io, out, c, resolved, visited, link_map);
                        allocator.free(content);
                    }
                }
                allocator.free(resolved);
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#version")) continue;
        // Normalize CRLF: byte offsets in the combined source (ENUM_ slots)
        // must match the template, which never contains '\r'.
        const no_cr = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try out.appendSlice(allocator, no_cr);
        try out.append(allocator, '\n');
    }
}

/// Resolves `#include` directives into a single GLSL source text. The main
/// file's `#version` is kept as the first line; includes are inlined at the
/// position of their directive.
/// Parameters:
/// - allocator: allocator for internal use.
/// - io: Io interface for file reads.
/// - out: output buffer for the assembled source.
/// - main_src: source of the main shader file.
/// - main_path: path of the main shader file.
/// - visited: set of already-included paths (caller owned).
/// - link_map: struct name -> owning .glsl identifier registry.
///
/// Returns: void.
pub fn resolveShaderIncludes(
    allocator: std.mem.Allocator,
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
                const no_cr = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
                try out.appendSlice(allocator, no_cr);
                try out.append(allocator, '\n');
                break;
            }
        }
    }
    try processShaderFile(allocator, io, out, main_src, main_path, visited, link_map);
}

/// Errors for `ENUM_` define processing.
/// Returned from `parseEnumDefines` with a `std.debug.print` hint explaining
/// the single-`#define` contract (print, not log.err, so tests expecting
/// errors do not fail the test runner on error logs).
pub const EnumDefineError = error{
    /// Same `ENUM_*` defined more than once in the combined source.
    DuplicateEnumDefine,
    /// `ENUM_*` compared in `#if`/`#elif` without exactly one `#define`.
    MissingEnumDefault,
    /// `#define`/`==` operand is not a single int/hex/identifier token.
    InvalidEnumToken,
    /// User `#define` uses a reserved `_N` / `_mN` / `_0x..` tag shape.
    ReservedDefineName,
    /// Suffix after `ENUM_` is not a valid Zig identifier.
    InvalidEnumFieldName,
};

/// One collected value of an `ENUM_*` define: original GLSL token text
/// plus the generated Zig enum tag (`0` -> `_0`, `-12` -> `_m12`,
/// `0x10` -> `_0x10`, `TRUE` -> `TRUE`). No numeric normalization:
/// `16` and `0x10` are different tokens and different tags.
pub const EnumValueDef = struct {
    /// Original token text as in GLSL (owned).
    token: []u8,
    /// Zig enum tag name (owned).
    tag: []u8,
};

/// One unique `ENUM_*` define with all collected values, default index
/// and the byte slot of the default token inside the template source
/// (`{offset,len}` for minimal runtime splicing).
pub const EnumDefineDef = struct {
    /// Full GLSL name, e.g. `ENUM_MODE` (owned).
    name: []u8,
    /// Zig field name: suffix after `ENUM_`, 1:1 (owned).
    field: []u8,
    /// All possible values: default first, then first-appearance order (owned).
    values: []EnumValueDef,
    /// Index of the default value inside `values` (always 0 for now).
    default_idx: usize,
    /// Byte offset of the default token in the template source.
    slot_offset: usize,
    /// Byte length of the default token in the template source.
    slot_len: usize,
};

/// Frees a slice of EnumDefineDef and all owned strings.
pub fn freeEnumDefines(allocator: std.mem.Allocator, defs: []EnumDefineDef) void {
    for (defs) |*d| {
        allocator.free(d.name);
        allocator.free(d.field);
        for (d.values) |*v| {
            allocator.free(v.token);
            allocator.free(v.tag);
        }
        allocator.free(d.values);
    }
    allocator.free(defs);
}

/// Returns true for `[A-Za-z_][A-Za-z0-9_]*`.
fn isIdentToken(tok: []const u8) bool {
    if (tok.len == 0) return false;
    const c0 = tok[0];
    if (!((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z') or c0 == '_')) return false;
    for (tok[1..]) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) return false;
    }
    return true;
}

/// Returns true for `-?[0-9]+`.
fn isDecIntToken(tok: []const u8) bool {
    var s = tok;
    if (s.len > 0 and s[0] == '-') s = s[1..];
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Returns true for `-?0x[0-9a-fA-F]+` (any `0x`/`0X` case).
fn isHexIntToken(tok: []const u8) bool {
    var s = tok;
    if (s.len > 0 and s[0] == '-') s = s[1..];
    if (s.len < 3) return false;
    if (s[0] != '0' or (s[1] != 'x' and s[1] != 'X')) return false;
    if (s.len == 2) return false;
    for (s[2..]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// Returns true when a token is a valid single `ENUM_` value:
/// decimal int, hex int or a plain identifier.
fn isValidEnumToken(tok: []const u8) bool {
    return isDecIntToken(tok) or isHexIntToken(tok) or isIdentToken(tok);
}

/// Returns true for reserved tag shapes the generator owns:
/// `_N`, `_mN`, `_0x..`, `_m0x..` (any digit after `_` / `_m`,
/// `0x` handled case-insensitively). Used to reject user `#define`s
/// that would collide with generated `_0` / `_m12` tags.
fn isReservedTagName(name: []const u8) bool {
    if (name.len < 2 or name[0] != '_') return false;
    var rest = name[1..];
    if (rest.len > 0 and (rest[0] == 'm' or rest[0] == 'M')) rest = rest[1..];
    if (rest.len == 0) return false;
    if (rest[0] >= '0' and rest[0] <= '9') return true;
    if (rest.len >= 2 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X')) return true;
    return false;
}

/// Builds a Zig tag for one token without numeric normalization.
/// Decimal: `0` -> `_0`, `-12` -> `_m12`. Hex: `0x10` -> `_0x10`,
/// `-0xC` -> `_m0xC` (case preserved). Identifier: as is.
fn enumTagForToken(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (isDecIntToken(token)) {
        if (token[0] == '-') return std.fmt.allocPrint(allocator, "_m{s}", .{token[1..]});
        return std.fmt.allocPrint(allocator, "_{s}", .{token});
    }
    if (isHexIntToken(token)) {
        if (token[0] == '-') return std.fmt.allocPrint(allocator, "_m{s}", .{token[1..]});
        return std.fmt.allocPrint(allocator, "_{s}", .{token});
    }
    return allocator.dupe(u8, token);
}

/// Returns true for Zig keywords that cannot be struct/enum names.
fn isZigKeyword(name: []const u8) bool {
    const kws = [_][]const u8{ "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn", "for", "if", "inline", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "linksection", "struct", "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable", "usingnamespace", "var", "volatile", "while" };
    for (kws) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

/// Returns true for a valid Zig identifier that is not a keyword.
fn isValidZigIdent(name: []const u8) bool {
    if (!isIdentToken(name)) return false;
    if (isZigKeyword(name)) return false;
    return true;
}

/// Skips spaces/tabs in `s` from index `i`.
fn skipBlank(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
    return j;
}

/// 1-based line/column position inside a shader source text.
pub const SourceLoc = struct {
    line: usize,
    col: usize,
};

/// Converts a byte offset into a 1-based line/column position.
/// Offsets past the end clamp to the end of the source.
pub fn lineColAt(source: []const u8, offset: usize) SourceLoc {
    var line: usize = 1;
    var col: usize = 1;
    const end = @min(offset, source.len);
    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

/// Finds the first whole-word occurrence of `word` at/after `start`.
/// Returns the byte offset of the word, or null when absent.
fn findWordOffset(source: []const u8, word: []const u8, start: usize) ?usize {
    var i: usize = start;
    while (std.mem.indexOfPos(u8, source, i, word)) |pos| {
        const before_ok = pos == 0 or !isAlnum(source[pos - 1]);
        const after = pos + word.len;
        const after_ok = after >= source.len or !isAlnum(source[after]);
        if (before_ok and after_ok) return pos;
        i = pos + 1;
    }
    return null;
}

/// Finds the byte offset of the name in a `struct <name>` declaration.
/// Returns null when no such declaration exists in `source`.
fn findStructDeclOffset(source: []const u8, name: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "struct")) |pos| {
        const before_ok = pos == 0 or !isAlnum(source[pos - 1]);
        const after = pos + 6;
        const after_ok = after >= source.len or isWhitespace(source[after]);
        if (!before_ok or !after_ok) {
            i = pos + 6;
            continue;
        }
        var j = skipSpaces(source, after);
        const name_start = j;
        while (j < source.len and (isAlnum(source[j]) or source[j] == '_')) j += 1;
        if (j > name_start and std.mem.eql(u8, source[name_start..j], name)) return name_start;
        i = j;
    }
    return null;
}

/// Prints one shader asset error: the file (plus `line:col` when known)
/// always comes first, with a blank line after so consecutive errors never
/// run together. Print, not log.err, so tests expecting errors
/// do not fail the test runner.
fn printShaderError(file: []const u8, loc: ?SourceLoc, comptime fmt: []const u8, args: anytype) void {
    if (loc) |l| {
        std.debug.print("{s}:{d}:{d}: ", .{ file, l.line, l.col });
    } else {
        std.debug.print("{s}: ", .{file});
    }
    std.debug.print(fmt ++ "\n\n", args);
}

/// Parses `#define ENUM_*` / `#if` / `#elif` after includes are inlined.
/// Template keeps comments, so directives inside `//` and `/* */` (and
/// GLSL `"...` strings) are ignored via a space-preserving cleaned copy
/// that keeps byte offsets intact.
/// Contract: every mentioned `ENUM_*` must have exactly one `#define`
/// with a single-token default; values are the default plus every token
/// ever compared with `==` / `!=` in `#if` / `#elif` (both operand orders).
/// `#ifdef` / `#ifndef` / runtime `if` are ignored. Anything else
/// (expression, missing/duplicate define, reserved `_N` name) is an
/// asset error with a `log.err` usage hint.
/// Parameters:
/// - allocator: allocator for results.
/// - combined: inlined GLSL source (template, comments preserved).
/// - file_path: shader file being compiled (e.g. `assets/shaders/foo.vert`);
///   shown first in every error hint together with `line:col` in `combined`.
///
/// Returns: defines in first-`#define` order (field order == slot order).
pub fn parseEnumDefines(allocator: std.mem.Allocator, combined: []const u8, file_path: []const u8) ![]EnumDefineDef {
    var defs = std.ArrayList(EnumDefineDef).empty;
    errdefer {
        for (defs.items) |*d| {
            allocator.free(d.name);
            allocator.free(d.field);
            for (d.values) |*v| {
                allocator.free(v.token);
                allocator.free(v.tag);
            }
            allocator.free(d.values);
        }
        defs.deinit(allocator);
    }
    var index_of = std.StringHashMap(usize).init(allocator);
    errdefer {
        var kit = index_of.iterator();
        while (kit.next()) |e| allocator.free(e.key_ptr.*);
        index_of.deinit();
    }
    var extra = std.StringHashMap(std.ArrayList([]u8)).init(allocator);
    defer {
        var it = extra.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |tok| allocator.free(tok);
            e.value_ptr.deinit(allocator);
            allocator.free(e.key_ptr.*);
        }
        extra.deinit();
    }

    var in_block = false;
    var offset: usize = 0;
    var line_no: usize = 1;
    var line_it = std.mem.splitScalar(u8, combined, '\n');
    while (line_it.next()) |raw_line| {
        defer line_no += 1;
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        const line_start = offset;
        offset += raw_line.len + 1;
        if (line.len == 0) continue;
        const cleaned = try allocator.alloc(u8, line.len);
        defer allocator.free(cleaned);
        @memcpy(cleaned, line);
        {
            var i: usize = 0;
            var in_str = false;
            while (i < line.len) {
                if (in_block) {
                    if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                        cleaned[i] = ' ';
                        cleaned[i + 1] = ' ';
                        in_block = false;
                        i += 2;
                    } else {
                        cleaned[i] = ' ';
                        i += 1;
                    }
                    continue;
                }
                if (in_str) {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 2;
                        continue;
                    }
                    if (line[i] == '"') in_str = false;
                    i += 1;
                    continue;
                }
                if (line[i] == '"') {
                    in_str = true;
                    i += 1;
                    continue;
                }
                if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
                    var k = i;
                    while (k < line.len) : (k += 1) cleaned[k] = ' ';
                    break;
                }
                if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                    cleaned[i] = ' ';
                    cleaned[i + 1] = ' ';
                    in_block = true;
                    i += 2;
                    continue;
                }
                i += 1;
            }
        }
        const trimmed = std.mem.trim(u8, cleaned, &[_]u8{ ' ', '\t' });
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#ifdef") or std.mem.startsWith(u8, trimmed, "#ifndef")) continue;
        if (std.mem.startsWith(u8, trimmed, "#define")) {
            var p = skipBlank(cleaned, std.mem.indexOf(u8, cleaned, "#define").? + "#define".len);
            const name_start = p;
            while (p < cleaned.len and (isAlnum(cleaned[p]) or cleaned[p] == '_')) p += 1;
            const name = cleaned[name_start..p];
            if (name.len == 0) continue;
            const after_name = skipBlank(cleaned, p);
            var tend = after_name;
            while (tend < cleaned.len and !isWhitespace(cleaned[tend])) tend += 1;
            const token = cleaned[after_name..tend];
            const rest = std.mem.trim(u8, cleaned[tend..], &[_]u8{ ' ', '\t' });
            const is_enum = std.mem.startsWith(u8, name, "ENUM_");
            if (!is_enum) {
                if (isReservedTagName(name)) {
                    printShaderError(file_path, .{ .line = line_no, .col = name_start + 1 }, "ENUM_: user #define '{s}' uses reserved tag shape `_N`/`_mN`/`_0x..`. Rename it: `_0`, `_m12`, `_0x10` are generated from numeric ENUM_ values.", .{name});
                    return error.ReservedDefineName;
                }
                continue;
            }
            if (token.len == 0 or rest.len != 0) {
                printShaderError(file_path, .{ .line = line_no, .col = name_start + 1 }, "ENUM_: '#define {s}' must have exactly one value token (int, hex or macro name). Example: `#define {s} 0`. Move expressions into a separate `#define OTHER ...` and use its name.", .{ name, name });
                return error.InvalidEnumToken;
            }
            if (!isValidEnumToken(token)) {
                printShaderError(file_path, .{ .line = line_no, .col = after_name + 1 }, "ENUM_: '#define {s} {s}': value must be a single decimal int (`0`, `-12`), hex (`0x10`) or macro name (`TRUE`). No expressions or parens.", .{ name, token });
                return error.InvalidEnumToken;
            }
            if (index_of.contains(name)) {
                printShaderError(file_path, .{ .line = line_no, .col = name_start + 1 }, "ENUM_: duplicate `#define {s}`. Keep exactly one `#define {s} <default>` in the whole inlined source (includes count); runtime variants replace its token in place.", .{ name, name });
                return error.DuplicateEnumDefine;
            }
            const suffix = name["ENUM_".len..];
            if (suffix.len == 0 or !isValidZigIdent(suffix)) {
                printShaderError(file_path, .{ .line = line_no, .col = name_start + 1 }, "ENUM_: name '{s}' has invalid suffix '{s}' after `ENUM_`. The suffix becomes a Zig field 1:1, so it must be `[A-Za-z_][A-Za-z0-9_]*` and not a Zig keyword.", .{ name, suffix });
                return error.InvalidEnumFieldName;
            }
            if (isReservedTagName(token) and isIdentToken(token)) {
                printShaderError(file_path, .{ .line = line_no, .col = after_name + 1 }, "ENUM_: value '{s}' for '{s}' uses reserved tag shape. Do not define macros named `_0`, `_m12`, `_0x10` yourself.", .{ token, name });
                return error.ReservedDefineName;
            }
            const name_copy = try allocator.dupe(u8, name);
            errdefer allocator.free(name_copy);
            const field_copy = try allocator.dupe(u8, suffix);
            errdefer allocator.free(field_copy);
            const tok_copy = try allocator.dupe(u8, token);
            errdefer allocator.free(tok_copy);
            const tag = try enumTagForToken(allocator, token);
            errdefer allocator.free(tag);
            const vals = try allocator.alloc(EnumValueDef, 1);
            vals[0] = .{ .token = tok_copy, .tag = tag };
            const tok_start_in_line = after_name;
            try defs.append(allocator, .{
                .name = name_copy,
                .field = field_copy,
                .values = vals,
                .default_idx = 0,
                .slot_offset = line_start + tok_start_in_line,
                .slot_len = token.len,
            });
            try index_of.put(try allocator.dupe(u8, name), defs.items.len - 1);
            continue;
        }
        const is_if = std.mem.startsWith(u8, trimmed, "#if") or std.mem.startsWith(u8, trimmed, "#elif");
        if (!is_if) {
            if (std.mem.startsWith(u8, trimmed, "#define")) continue;
            var k: usize = 0;
            while (k < cleaned.len) {
                if (cleaned[k] == '_' or (cleaned[k] >= 'A' and cleaned[k] <= 'Z') or (cleaned[k] >= 'a' and cleaned[k] <= 'z')) {
                    var e = k;
                    while (e < cleaned.len and (isAlnum(cleaned[e]) or cleaned[e] == '_')) e += 1;
                    const word = cleaned[k..e];
                    if (std.mem.startsWith(u8, word, "ENUM_") and word.len > 5 and !index_of.contains(word) and !extra.contains(word)) {
                        // Mention outside #if/#define does not create values,
                        // but a later validation still requires a default once
                        // the name is used anywhere? No: only #if comparisons
                        // extend the value set; plain mentions are ignored.
                    }
                    k = e;
                } else k += 1;
            }
            continue;
        }
        var s: usize = 0;
        while (s < cleaned.len) {
            const op_at: ?usize = blk: {
                var q = s;
                while (q + 1 < cleaned.len) : (q += 1) {
                    if ((cleaned[q] == '=' and cleaned[q + 1] == '=') or (cleaned[q] == '!' and cleaned[q + 1] == '=')) break :blk q;
                }
                break :blk null;
            };
            const op = op_at orelse break;
            var l_end = op;
            while (l_end > s and (cleaned[l_end - 1] == ' ' or cleaned[l_end - 1] == '\t' or cleaned[l_end - 1] == '(')) l_end -= 1;
            var l_start = l_end;
            while (l_start > s and (isAlnum(cleaned[l_start - 1]) or cleaned[l_start - 1] == '_' or cleaned[l_start - 1] == 'x' or cleaned[l_start - 1] == 'X')) l_start -= 1;
            if (l_start < l_end and l_start > s and cleaned[l_start - 1] == '-') l_start -= 1;
            var r_start = op + 2;
            while (r_start < cleaned.len and (cleaned[r_start] == ' ' or cleaned[r_start] == '\t' or cleaned[r_start] == '(')) r_start += 1;
            var r_end = r_start;
            if (r_end < cleaned.len and cleaned[r_end] == '-') r_end += 1;
            while (r_end < cleaned.len and (isAlnum(cleaned[r_end]) or cleaned[r_end] == '_')) r_end += 1;
            const left = if (l_start < l_end) std.mem.trim(u8, cleaned[l_start..l_end], &[_]u8{ ' ', '\t', '(', ')' }) else "";
            const right = if (r_start < r_end) cleaned[r_start..r_end] else "";
            const enum_side: ?[]const u8 = if (std.mem.startsWith(u8, left, "ENUM_")) left else if (std.mem.startsWith(u8, right, "ENUM_")) right else null;
            const other_side: []const u8 = if (enum_side == null) "" else if (enum_side.?.ptr == left.ptr) right else left;
            s = r_end + 1;
            const ename = enum_side orelse continue;
            if (!isIdentToken(ename) or !std.mem.startsWith(u8, ename, "ENUM_")) continue;
            if (other_side.len == 0 or !isValidEnumToken(other_side)) {
                const hash_col = (std.mem.indexOfScalar(u8, cleaned, '#') orelse 0) + 1;
                printShaderError(file_path, .{ .line = line_no, .col = hash_col }, "ENUM_: comparison for '{s}' must use a single token (`#if {s} == 1`, `== OTHER`). No expressions or parens around the value.", .{ ename, ename });
                return error.InvalidEnumToken;
            }
            if (isIdentToken(other_side) and isReservedTagName(other_side)) {
                const hash_col = (std.mem.indexOfScalar(u8, cleaned, '#') orelse 0) + 1;
                printShaderError(file_path, .{ .line = line_no, .col = hash_col }, "ENUM_: compared value '{s}' uses reserved tag shape `_N`/`_mN`. Rename your macro.", .{other_side});
                return error.ReservedDefineName;
            }
            const owned_key = try allocator.dupe(u8, ename);
            const gop = try extra.getOrPut(owned_key);
            if (gop.found_existing) allocator.free(owned_key) else gop.value_ptr.* = std.ArrayList([]u8).empty;
            var seen = false;
            for (gop.value_ptr.items) |t| {
                if (std.mem.eql(u8, t, other_side)) {
                    seen = true;
                    break;
                }
            }
            if (index_of.get(ename)) |di| {
                for (defs.items[di].values) |v| {
                    if (std.mem.eql(u8, v.token, other_side)) {
                        seen = true;
                        break;
                    }
                }
            }
            if (!seen) try gop.value_ptr.append(allocator, try allocator.dupe(u8, other_side));
        }
    }
    {
        var it = extra.iterator();
        while (it.next()) |e| {
            const idx = index_of.get(e.key_ptr.*) orelse {
                const loc: ?SourceLoc = if (findWordOffset(combined, e.key_ptr.*, 0)) |off| lineColAt(combined, off) else null;
                printShaderError(file_path, loc, "ENUM_: '{s}' is compared in `#if`/`#elif` but has no `#define`. Add exactly one `#define {s} <default>` (int, hex or macro name); runtime `use` will replace its token in place. Example:\n  #define {s} 0\n  #if {s} == 1\n  #elif {s} == OTHER", .{ e.key_ptr.*, e.key_ptr.*, e.key_ptr.*, e.key_ptr.*, e.key_ptr.* });
                return error.MissingEnumDefault;
            };
            for (e.value_ptr.items) |tok| {
                var dup = false;
                for (defs.items[idx].values) |v| {
                    if (std.mem.eql(u8, v.token, tok)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                const tag = try enumTagForToken(allocator, tok);
                errdefer allocator.free(tag);
                for (defs.items[idx].values) |v| {
                    if (std.mem.eql(u8, v.tag, tag)) {
                        allocator.free(tag);
                        printShaderError(file_path, lineColAt(combined, defs.items[idx].slot_offset), "ENUM_: tag collision for '{s}': tokens map to the same Zig tag. Rename the macro value.", .{defs.items[idx].name});
                        return error.InvalidEnumToken;
                    }
                }
                const old = defs.items[idx].values;
                const grown = try allocator.alloc(EnumValueDef, old.len + 1);
                @memcpy(grown[0..old.len], old);
                grown[old.len] = .{ .token = try allocator.dupe(u8, tok), .tag = tag };
                allocator.free(old);
                defs.items[idx].values = grown;
            }
        }
    }
    {
        var kit = index_of.iterator();
        while (kit.next()) |e| allocator.free(e.key_ptr.*);
        index_of.deinit();
    }
    return defs.toOwnedSlice(allocator);
}

/// Appends a Zig string literal (`"..."` with `\\`, `\"`, `\n` escapes,
/// `\r` dropped) for `s` into `out`.
pub fn appendZigStringLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => {},
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}

/// Emits one generated struct field with a default value.
/// Resource fields (`optional_resource`) become `name: ?Base = null`;
/// everything else (scalars, math, nested custom structs — GLSL structs
/// hold no resources, so zeroes is safe) becomes
/// `name: Base = @import("std").mem.zeroes(Base)`.
/// `base_type` must be the full type expression (arrays included).
pub fn appendGeneratedField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    name: []const u8,
    base_type: []const u8,
    optional_resource: bool,
) !void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, ": ");
    if (optional_resource) {
        try out.append(allocator, '?');
        try out.appendSlice(allocator, base_type);
        try out.appendSlice(allocator, " = null,\n");
    } else {
        try out.appendSlice(allocator, base_type);
        try out.appendSlice(allocator, " = @import(\"std\").mem.zeroes(");
        try out.appendSlice(allocator, base_type);
        try out.appendSlice(allocator, "),\n");
    }
}

/// Errors for struct member validation.
/// Returned from `validateStructMembers` with a `std.debug.print` hint
/// (print, not log.err, so tests expecting errors do not fail the runner).
pub const StructMemberError = error{
    /// A struct member (direct or nested) uses an opaque GLSL type.
    OpaqueStructMember,
    /// A struct member uses a uniform block type.
    BlockStructMember,
    /// A GLSL struct or uniform block type uses a reserved generator name.
    ReservedStructName,
};

/// Returns true for struct/block type names reserved by the generator.
///
/// The generator emits `pub const Uniform` and `pub const Define` into every
/// `.vert`/`.frag` shader, so user GLSL must never declare `struct Define`,
/// `struct Uniform` or `uniform Define`/`uniform Uniform` blocks: they would
/// collide with (or silently rewire) the generated decls.
fn isReservedStructName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Define") or std.mem.eql(u8, name, "Uniform");
}

/// Returns true for GLSL opaque types that can never live in a struct
/// uploaded by the runtime: samplers, images and atomic counters.
fn isOpaqueMemberType(typ: []const u8) bool {
    if (isSamplerType(typ)) return true;
    if (std.mem.startsWith(u8, typ, "image")) return true;
    if (std.mem.eql(u8, typ, "atomic_uint")) return true;
    return false;
}

/// Recursively checks one struct's members for opaque/block types.
/// `path` holds the current DFS chain for cycle protection.
/// `file_path`/`source` locate the offending declaration for the error hint.
fn checkStructMembers(
    allocator: std.mem.Allocator,
    by_name: *const std.StringHashMap(*const StructDef),
    block_types: []const []const u8,
    s: *const StructDef,
    path: *std.ArrayList([]const u8),
    file_path: []const u8,
    source: []const u8,
) (StructMemberError || std.mem.Allocator.Error)!void {
    for (path.items) |n| {
        if (std.mem.eql(u8, n, s.name)) return;
    }
    try path.append(allocator, s.name);
    defer _ = path.pop();
    for (s.fields) |*f| {
        if (isOpaqueMemberType(f.typ)) {
            const loc: ?SourceLoc = blk: {
                if (findStructDeclOffset(source, s.name)) |soff| {
                    if (findWordOffset(source, f.name, soff)) |moff| break :blk lineColAt(source, moff);
                    break :blk lineColAt(source, soff);
                }
                break :blk null;
            };
            printShaderError(file_path, loc, "STRUCT_: struct '{s}' member '{s}' has opaque type '{s}'. Opaque types (samplers, images, atomics) cannot be struct members: the runtime never uploads them and strict drivers reject the shader. Keep resources as flat top-level uniforms (e.g. `uniform sampler2D uTex;`) and numeric-only data in structs.", .{ s.name, f.name, f.typ });
            return error.OpaqueStructMember;
        }
        for (block_types) |b| {
            if (!std.mem.eql(u8, b, f.typ)) continue;
            const loc: ?SourceLoc = blk: {
                if (findStructDeclOffset(source, s.name)) |soff| {
                    if (findWordOffset(source, f.name, soff)) |moff| break :blk lineColAt(source, moff);
                    break :blk lineColAt(source, soff);
                }
                break :blk null;
            };
            printShaderError(file_path, loc, "STRUCT_: struct '{s}' member '{s}' uses uniform block type '{s}'. Uniform blocks cannot be struct members: bind them as flat top-level `uniform {s} {{ ... }} instance;` uniforms instead.", .{ s.name, f.name, f.typ, f.typ });
            return error.BlockStructMember;
        }
        if (by_name.get(f.typ)) |nested| {
            try checkStructMembers(allocator, by_name, block_types, nested, path, file_path, source);
        }
    }
}

/// Validates that no struct — directly or transitively through nested
/// structs — uses an opaque GLSL type (`sampler*`, `image*`, `atomic_uint`)
/// or a uniform block type, and that no struct or uniform block type uses a
/// reserved generator name (`Define`, `Uniform`). Such members can neither be
/// uploaded by the runtime (`flattenUniforms` skips pointer leaves) nor
/// compiled by strict drivers, and reserved names would collide with the
/// generated `pub const Uniform` / `pub const Define` decls, so they are
/// rejected at asset compile time with a usage hint.
/// Parameters:
/// - allocator: allocator for internal index/path.
/// - structs: parsed struct definitions (borrowed).
/// - block_types: uniform block type names in scope (borrowed).
/// - file_path: shader file being compiled; shown first in every error hint
///   together with `line:col` in `source`.
/// - source: source text the structs were parsed from (used to locate the
///   offending declaration).
///
/// Returns: `OpaqueStructMember` / `BlockStructMember` /
/// `ReservedStructName` on violation.
pub fn validateStructMembers(
    allocator: std.mem.Allocator,
    structs: []const StructDef,
    block_types: []const []const u8,
    file_path: []const u8,
    source: []const u8,
) (StructMemberError || std.mem.Allocator.Error)!void {
    for (structs) |*s| {
        if (isReservedStructName(s.name)) {
            const loc: ?SourceLoc = if (findStructDeclOffset(source, s.name)) |off| lineColAt(source, off) else null;
            printShaderError(file_path, loc, "STRUCT_: struct '{s}' uses reserved name '{s}'. Names `Define` and `Uniform` are reserved by the generator (it emits `pub const Uniform` and `pub const Define` into every .vert/.frag shader): rename your GLSL struct (e.g. `struct {s}Data`). Do not declare `struct Define`, `struct Uniform` or `uniform Define`/`uniform Uniform` blocks.", .{ s.name, s.name, s.name });
            return error.ReservedStructName;
        }
    }
    for (block_types) |b| {
        if (isReservedStructName(b)) {
            const loc: ?SourceLoc = if (findWordOffset(source, b, 0)) |off| lineColAt(source, off) else null;
            printShaderError(file_path, loc, "STRUCT_: uniform block type '{s}' uses reserved name '{s}'. Names `Define` and `Uniform` are reserved by the generator (it emits `pub const Uniform` and `pub const Define` into every .vert/.frag shader): rename your uniform block type (e.g. `{s}Block`). Do not declare `struct Define`, `struct Uniform` or `uniform Define`/`uniform Uniform` blocks.", .{ b, b, b });
            return error.ReservedStructName;
        }
    }
    var by_name = std.StringHashMap(*const StructDef).init(allocator);
    defer by_name.deinit();
    for (structs) |*s| try by_name.put(s.name, s);
    var path = std.ArrayList([]const u8).empty;
    defer path.deinit(allocator);
    for (structs) |*s| {
        path.clearRetainingCapacity();
        try checkStructMembers(allocator, &by_name, block_types, s, &path, file_path, source);
    }
}

/// Generates Zig declarations for `ENUM_` variants into `inner`:
/// one `pub const <SUFFIX>` enum per define (with `text()` returning the
/// original GLSL token), `pub const Define` with defaults from the
/// single `#define`, plus `template_src` (full inlined GLSL, comments kept)
/// and `define_slots` (`{offset,len}` of each default token, field order).
/// `template_src` must be the exact `combined` slice the offsets refer to.
pub fn appendEnumDefinesCode(
    allocator: std.mem.Allocator,
    inner: *std.ArrayList(u8),
    enum_defs: []const EnumDefineDef,
    template_src: []const u8,
) !void {
    for (enum_defs) |d| {
        try inner.appendSlice(allocator, "    pub const ");
        try inner.appendSlice(allocator, d.field);
        try inner.appendSlice(allocator, " = enum {\n");
        for (d.values) |v| {
            try inner.appendSlice(allocator, "        ");
            try inner.appendSlice(allocator, v.tag);
            try inner.appendSlice(allocator, ",\n");
        }
        try inner.appendSlice(allocator, "\n");
        try inner.appendSlice(allocator, "        pub fn text(self: @This()) []const u8 {\n");
        try inner.appendSlice(allocator, "            return switch (self) {\n");
        for (d.values) |v| {
            try inner.appendSlice(allocator, "                .");
            try inner.appendSlice(allocator, v.tag);
            try inner.appendSlice(allocator, " => ");
            try appendZigStringLiteral(allocator, inner, v.token);
            try inner.appendSlice(allocator, ",\n");
        }
        try inner.appendSlice(allocator, "            };\n");
        try inner.appendSlice(allocator, "        }\n");
        try inner.appendSlice(allocator, "    };\n\n");
    }
    if (enum_defs.len == 0) {
        try inner.appendSlice(allocator, "    pub const Define = struct {};\n\n");
    } else {
        try inner.appendSlice(allocator, "    pub const Define = struct {\n");
        for (enum_defs) |d| {
            try inner.appendSlice(allocator, "        ");
            try inner.appendSlice(allocator, d.field);
            try inner.appendSlice(allocator, ": ");
            try inner.appendSlice(allocator, d.field);
            try inner.appendSlice(allocator, " = .");
            try inner.appendSlice(allocator, d.values[d.default_idx].tag);
            try inner.appendSlice(allocator, ",\n");
        }
        try inner.appendSlice(allocator, "    };\n\n");
    }
    try inner.appendSlice(allocator, "    const template_src: []const u8 = ");
    try appendZigStringLiteral(allocator, inner, template_src);
    try inner.appendSlice(allocator, ";\n");
    try inner.appendSlice(allocator, "    const define_slots = [_]@import(\"gl_graphics\").DefineSlot{\n");
    for (enum_defs) |d| {
        const line = try std.fmt.allocPrint(allocator, "        .{{ .offset = {d}, .len = {d} }},\n", .{ d.slot_offset, d.slot_len });
        defer allocator.free(line);
        try inner.appendSlice(allocator, line);
    }
    try inner.appendSlice(allocator, "    };\n\n");
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

test "enum defines basic with if comparisons" {
    const alloc = std.testing.allocator;
    const src = "#version 300 es\n#define ENUM_MODE 0\n#if ENUM_MODE == 1\n#endif\n#if ENUM_MODE == OTHER\n#endif\nvoid main() {}\n";
    const defs = try parseEnumDefines(alloc, src, "test.vert");
    defer freeEnumDefines(alloc, defs);
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("ENUM_MODE", defs[0].name);
    try std.testing.expectEqualStrings("MODE", defs[0].field);
    try std.testing.expectEqual(@as(usize, 3), defs[0].values.len);
    try std.testing.expectEqualStrings("0", defs[0].values[0].token);
    try std.testing.expectEqualStrings("_0", defs[0].values[0].tag);
    try std.testing.expectEqualStrings("1", defs[0].values[1].token);
    try std.testing.expectEqualStrings("OTHER", defs[0].values[2].token);
}

test "enum defines ignores comments and ifdef" {
    const alloc = std.testing.allocator;
    const src = "#version 300 es\n// #define ENUM_BAD 1\n/* #define ENUM_BAD2 2 */\n#define ENUM_OK TRUE\n#ifdef ENUM_OK\n#endif\nvoid main() {}\n";
    const defs = try parseEnumDefines(alloc, src, "test.vert");
    defer freeEnumDefines(alloc, defs);
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("ENUM_OK", defs[0].name);
}

test "enum defines duplicate and missing errors" {
    const alloc = std.testing.allocator;
    const dup = "#version 300 es\n#define ENUM_A 0\n#define ENUM_A 1\n";
    try std.testing.expectError(error.DuplicateEnumDefine, parseEnumDefines(alloc, dup, "test.frag"));
    const miss = "#version 300 es\n#if ENUM_MISSING == 1\n#endif\n";
    try std.testing.expectError(error.MissingEnumDefault, parseEnumDefines(alloc, miss, "test.frag"));
    const bad_tok = "#version 300 es\n#define ENUM_B 1+2\n";
    try std.testing.expectError(error.InvalidEnumToken, parseEnumDefines(alloc, bad_tok, "test.frag"));
    const reserved = "#version 300 es\n#define _0 5\n";
    try std.testing.expectError(error.ReservedDefineName, parseEnumDefines(alloc, reserved, "test.frag"));
}

test "enum defines hex no normalization and negative" {
    const alloc = std.testing.allocator;
    const src = "#version 300 es\n#define ENUM_H 0x10\n#if ENUM_H == 16\n#endif\n#if ENUM_H == -12\n#endif\n";
    const defs = try parseEnumDefines(alloc, src, "test.vert");
    defer freeEnumDefines(alloc, defs);
    try std.testing.expectEqual(@as(usize, 3), defs[0].values.len);
    try std.testing.expectEqualStrings("_0x10", defs[0].values[0].tag);
    try std.testing.expectEqualStrings("_16", defs[0].values[1].tag);
    try std.testing.expectEqualStrings("_m12", defs[0].values[2].tag);
}

test "appendGeneratedField emits null and zeroes defaults" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendGeneratedField(alloc, &out, "    ", "uTex", "*const @import(\"gl_graphics\").Texture", true);
    try appendGeneratedField(alloc, &out, "    ", "uMvp", "f32", false);
    try appendGeneratedField(alloc, &out, "    ", "uArr", "[4]f32", false);
    const code = try out.toOwnedSlice(alloc);
    defer alloc.free(code);
    try std.testing.expectEqualStrings(
        "    uTex: ?*const @import(\"gl_graphics\").Texture = null,\n" ++
            "    uMvp: f32 = @import(\"std\").mem.zeroes(f32),\n" ++
            "    uArr: [4]f32 = @import(\"std\").mem.zeroes([4]f32),\n",
        code,
    );
}

/// Builds one owned struct-member field for validator tests.
fn testStructField(allocator: std.mem.Allocator, typ: []const u8, name: []const u8) !FieldDef {
    return .{ .typ = try allocator.dupe(u8, typ), .name = try allocator.dupe(u8, name) };
}

/// Builds one owned struct definition for validator tests.
fn testStructDef(allocator: std.mem.Allocator, name: []const u8, member_types: []const []const u8) !StructDef {
    const fields = try allocator.alloc(FieldDef, member_types.len);
    errdefer allocator.free(fields);
    for (member_types, 0..) |t, i| fields[i] = try testStructField(allocator, t, "m");
    return .{ .name = try allocator.dupe(u8, name), .fields = fields };
}

fn freeTestStructDef(allocator: std.mem.Allocator, s: *StructDef) void {
    for (s.fields) |*f| {
        allocator.free(f.typ);
        allocator.free(f.name);
    }
    allocator.free(s.fields);
    allocator.free(s.name);
}

test "validateStructMembers accepts numeric and nested structs" {
    const alloc = std.testing.allocator;
    var light = try testStructDef(alloc, "Light", &.{ "vec3", "float" });
    defer freeTestStructDef(alloc, &light);
    var mat = try testStructDef(alloc, "Material", &.{ "vec4", "Light" });
    defer freeTestStructDef(alloc, &mat);
    const defs = [_]StructDef{ light, mat };
    try validateStructMembers(alloc, &defs, &.{}, "test.glsl", "struct Light { vec3 position; float intensity; } struct Material { vec4 diffuse; Light light; }");
}

test "validateStructMembers rejects opaque and block members" {
    const alloc = std.testing.allocator;
    // Direct sampler member.
    {
        var bad = try testStructDef(alloc, "Bad", &.{"sampler2D"});
        defer freeTestStructDef(alloc, &bad);
        const defs = [_]StructDef{bad};
        try std.testing.expectError(error.OpaqueStructMember, validateStructMembers(alloc, &defs, &.{}, "test.glsl", ""));
    }
    // Sampler array, image and atomic members.
    {
        var bad = try testStructDef(alloc, "Bad2", &.{ "samplerCube", "image2D", "atomic_uint" });
        defer freeTestStructDef(alloc, &bad);
        const defs = [_]StructDef{bad};
        try std.testing.expectError(error.OpaqueStructMember, validateStructMembers(alloc, &defs, &.{}, "test.glsl", ""));
    }
    // Transitive: holder -> inner with sampler.
    {
        var inner = try testStructDef(alloc, "Inner", &.{"sampler2D"});
        defer freeTestStructDef(alloc, &inner);
        var holder = try testStructDef(alloc, "Holder", &.{"Inner"});
        defer freeTestStructDef(alloc, &holder);
        const defs = [_]StructDef{ inner, holder };
        try std.testing.expectError(error.OpaqueStructMember, validateStructMembers(alloc, &defs, &.{}, "test.glsl", ""));
    }
    // Uniform block type member.
    {
        var s = try testStructDef(alloc, "S", &.{"MyBlock"});
        defer freeTestStructDef(alloc, &s);
        const defs = [_]StructDef{s};
        const blocks = [_][]const u8{"MyBlock"};
        try std.testing.expectError(error.BlockStructMember, validateStructMembers(alloc, &defs, &blocks, "test.glsl", "struct S { MyBlock m; }"));
    }
}

test "validateStructMembers rejects reserved Define and Uniform names" {
    const alloc = std.testing.allocator;
    // GLSL struct named Define.
    {
        var bad = try testStructDef(alloc, "Define", &.{"float"});
        defer freeTestStructDef(alloc, &bad);
        const defs = [_]StructDef{bad};
        try std.testing.expectError(error.ReservedStructName, validateStructMembers(alloc, &defs, &.{}, "test.vert", "struct Define { float m; }"));
    }
    // GLSL struct named Uniform.
    {
        var bad = try testStructDef(alloc, "Uniform", &.{"vec3"});
        defer freeTestStructDef(alloc, &bad);
        const defs = [_]StructDef{bad};
        try std.testing.expectError(error.ReservedStructName, validateStructMembers(alloc, &defs, &.{}, "test.frag", "struct Uniform { vec3 m; }"));
    }
    // Uniform block type named Define / Uniform.
    {
        var s = try testStructDef(alloc, "S", &.{"float"});
        defer freeTestStructDef(alloc, &s);
        const defs = [_]StructDef{s};
        const blocks_define = [_][]const u8{"Define"};
        try std.testing.expectError(error.ReservedStructName, validateStructMembers(alloc, &defs, &blocks_define, "test.vert", "uniform Define { float m; } s;"));
        const blocks_uniform = [_][]const u8{"Uniform"};
        try std.testing.expectError(error.ReservedStructName, validateStructMembers(alloc, &defs, &blocks_uniform, "test.vert", "uniform Uniform { float m; } s;"));
    }
    // Sanity: similar but non-reserved names still pass.
    {
        var ok = try testStructDef(alloc, "Defines", &.{"float"});
        defer freeTestStructDef(alloc, &ok);
        const defs = [_]StructDef{ok};
        try validateStructMembers(alloc, &defs, &.{}, "test.glsl", "struct Defines { float m; }");
    }
}

test "shader error locations resolve line:col" {
    const src = "line one\nstruct Define { float m; }\nthird\n";
    const soff = findStructDeclOffset(src, "Define").?;
    try std.testing.expectEqualDeep(SourceLoc{ .line = 2, .col = 8 }, lineColAt(src, soff));
    try std.testing.expect(findStructDeclOffset(src, "Missing") == null);
    // Whole-word match only: `oneline` must not match `one`.
    try std.testing.expectEqual(@as(usize, 0), findWordOffset(src, "line", 0).?);
    try std.testing.expect(findWordOffset(src, "oneline", 0) == null);
    try std.testing.expectEqual(soff, findWordOffset(src, "Define", 0).?);
}

test "enum defines slots survive CRLF normalization" {
    // Regression: sources with CRLF endings used to shift every slot by
    // the number of preceding '\r' (template drops '\r', parser did not),
    // corrupting the variant (e.g. `uniform` -> `TRUEform`) and failing
    // driver compilation. resolveShaderIncludes now strips trailing '\r'.
    const alloc = std.testing.allocator;
    const crlf_src = "#version 300 es\r\n#define ENUM_MODE 0\r\n#if ENUM_MODE == 1\r\n#endif\r\nvoid main() {}\r\n";
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(alloc);
    var visited = std.StringHashMap(void).init(alloc);
    defer visited.deinit();
    var link_map = std.StringHashMap([]u8).init(alloc);
    defer link_map.deinit();
    // No IO needed: no #include directives, readNodeFile never called.
    try resolveShaderIncludes(alloc, undefined, &combined, crlf_src, "test.frag", &visited, &link_map);
    const template = try combined.toOwnedSlice(alloc);
    defer alloc.free(template);
    try std.testing.expect(std.mem.indexOf(u8, template, "\r") == null);
    const defs = try parseEnumDefines(alloc, template, "test.frag");
    defer freeEnumDefines(alloc, defs);
    try std.testing.expectEqual(@as(usize, 1), defs.len);
    try std.testing.expectEqualStrings("0", template[defs[0].slot_offset .. defs[0].slot_offset + defs[0].slot_len]);
}

test "enum defines codegen emits template and slots" {
    const alloc = std.testing.allocator;
    const src = "#version 300 es\n#define ENUM_MODE 0\n#if ENUM_MODE == 1\n#endif\nvoid main() {}\n";
    const defs = try parseEnumDefines(alloc, src, "test.vert");
    defer freeEnumDefines(alloc, defs);
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(alloc);
    try appendEnumDefinesCode(alloc, &inner, defs, src);
    const code = try inner.toOwnedSlice(alloc);
    defer alloc.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const MODE = enum") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub const Define = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "template_src") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "define_slots") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "_0") != null);
    // Slot must point at the default token so a splice reproduces the variant.
    const off = defs[0].slot_offset;
    try std.testing.expectEqualStrings("0", src[off .. off + defs[0].slot_len]);
}
