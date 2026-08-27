const std = @import("std");
const text_utils = @import("assets_manager").text_utils;

// Shared helpers for GLSL parsing and code generation.

pub const FieldDef = struct {
    typ: []u8,
    name: []u8,
    is_array: bool = false,
    array_len: ?usize = null,
};

pub const StructDef = struct {
    name: []u8,
    fields: []FieldDef,
};

pub const UniformKind = enum { simple, block };

pub const UniformDef = struct {
    kind: UniformKind,
    glsl_type: []u8, // for simple: type like "mat4" or "sampler2D" or struct name; for block: block name
    name: []u8, // for simple: uniform variable name; for block: block instance name or block name if anon
    block_fields: ?[]FieldDef = null, // if block
    is_sampler: bool = false,
    is_buffer: bool = false, // true if block -> UBO
};

pub fn isWhitespace(c: u8) bool { return c == ' ' or c == '\t' or c == '\r' or c == '\n'; }
pub fn isAlpha(c: u8) bool { return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_'; }
pub fn isAlnum(c: u8) bool { return isAlpha(c) or (c >= '0' and c <= '9'); }
pub fn isDigit(c: u8) bool { return c >= '0' and c <= '9'; }

pub fn skipSpaces(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and isWhitespace(s[j])) j += 1;
    return j;
}

pub fn stripComments(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < source.len) {
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '/') {
            // line comment
            i += 2;
            while (i < source.len and source[i] != '\n') i += 1;
        } else if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            i += 2; // skip */
        } else {
            try out.append(allocator, source[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn stripLayouts(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < source.len) {
        if (i + 6 <= source.len and std.mem.eql(u8, source[i..i+6], "layout")) {
            var j = i + 6;
            j = skipSpaces(source, j);
            if (j < source.len and source[j] == '(') {
                var depth: usize = 0;
                var k = j;
                while (k < source.len) : (k += 1) {
                    if (source[k] == '(') depth += 1 else if (source[k] == ')') {
                        depth -= 1;
                        if (depth == 0) { k += 1; break; }
                    }
                }
                // replace layout(...) with spaces to keep offsets
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

// Map GLSL type name to Zig type string (inline @import)
pub fn mapGLSLTypeToZig(allocator: std.mem.Allocator, glsl_type: []const u8) ![]u8 {
    // sampler* => Texture
    if (std.mem.startsWith(u8, glsl_type, "sampler")) {
        return std.fmt.allocPrint(allocator, "@import(\"gl_graphics\").Texture", .{});
    }
    // Check struct vs builtin
    const builtin = std.StaticStringMap([]const u8).initComptime(.{
        .{ "float", "f32" },
        .{ "int", "i32" },
        .{ "uint", "u32" },
        .{ "bool", "bool" },
        .{ "vec2", "@import(\"math\").Vec(2, f32)" },
        .{ "vec3", "@import(\"math\").Vec(3, f32)" },
        .{ "vec4", "@import(\"math\").Vec(4, f32)" },
        .{ "ivec2", "@import(\"math\").Vec(2, i32)" },
        .{ "ivec3", "@import(\"math\").Vec(3, i32)" },
        .{ "ivec4", "@import(\"math\").Vec(4, i32)" },
        .{ "uvec2", "@import(\"math\").Vec(2, u32)" },
        .{ "uvec3", "@import(\"math\").Vec(3, u32)" },
        .{ "uvec4", "@import(\"math\").Vec(4, u32)" },
        .{ "bvec2", "@import(\"math\").Vec(2, bool)" },
        .{ "bvec3", "@import(\"math\").Vec(3, bool)" },
        .{ "bvec4", "@import(\"math\").Vec(4, bool)" },
        .{ "mat2", "@import(\"math\").Mat(2, 2, f32)" },
        .{ "mat3", "@import(\"math\").Mat(3, 3, f32)" },
        .{ "mat4", "@import(\"math\").Mat(4, 4, f32)" },
        .{ "mat2x2", "@import(\"math\").Mat(2, 2, f32)" },
        .{ "mat2x3", "@import(\"math\").Mat(2, 3, f32)" },
        .{ "mat2x4", "@import(\"math\").Mat(2, 4, f32)" },
        .{ "mat3x2", "@import(\"math\").Mat(3, 2, f32)" },
        .{ "mat3x3", "@import(\"math\").Mat(3, 3, f32)" },
        .{ "mat3x4", "@import(\"math\").Mat(3, 4, f32)" },
        .{ "mat4x2", "@import(\"math\").Mat(4, 2, f32)" },
        .{ "mat4x3", "@import(\"math\").Mat(4, 3, f32)" },
        .{ "mat4x4", "@import(\"math\").Mat(4, 4, f32)" },
    });
    if (builtin.get(glsl_type)) |zig_type| {
        return allocator.dupe(u8, zig_type);
    }
    // Assume user struct name — return as is (will be resolved via included structs)
    // Keep original identifier
    return allocator.dupe(u8, glsl_type);
}

pub fn isSamplerType(t: []const u8) bool { return std.mem.startsWith(u8, t, "sampler"); }

pub fn parseStructs(allocator: std.mem.Allocator, source: []const u8) ![]StructDef {
    var list = std.ArrayList(StructDef).empty;
    errdefer {
        for (list.items) |*s| {
            allocator.free(s.name);
            for (s.fields) |f| { allocator.free(f.typ); allocator.free(f.name); }
            allocator.free(s.fields);
        }
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (i < source.len) {
        const pos = std.mem.indexOfPos(u8, source, i, "struct") orelse break;
        // Ensure word boundary
        const before_ok = pos == 0 or !isAlnum(source[pos - 1]);
        const after = pos + 6;
        const after_ok = after >= source.len or isWhitespace(source[after]) or source[after] == '{' or source[after] == ' ';
        if (!before_ok or !after_ok) { i = pos + 6; continue; }
        var j = skipSpaces(source, after);
        // parse struct name
        const name_start = j;
        while (j < source.len and (isAlnum(source[j]) or source[j] == '_')) j += 1;
        if (j == name_start) { i = j; continue; }
        const struct_name = try allocator.dupe(u8, source[name_start..j]);
        j = skipSpaces(source, j);
        if (j >= source.len or source[j] != '{') { allocator.free(struct_name); i = j; continue; }
        const brace_open = j;
        // find matching }
        var depth: usize = 0;
        var k = brace_open;
        var close: ?usize = null;
        while (k < source.len) : (k += 1) {
            if (source[k] == '{') depth += 1 else if (source[k] == '}') {
                depth -= 1;
                if (depth == 0) { close = k; break; }
            }
        }
        const brace_close = close orelse {
            allocator.free(struct_name);
            break;
        };
        const inner = source[brace_open + 1 .. brace_close];
        // parse fields inside inner split by ';'
        var fields = std.ArrayList(FieldDef).empty;
        var f_it = std.mem.splitScalar(u8, inner, ';');
        while (f_it.next()) |raw_field| {
            const trimmed = std.mem.trim(u8, raw_field, &[_]u8{ ' ', '\t', '\r', '\n' });
            if (trimmed.len == 0) continue;
            // field is like "vec3 position" or "highp vec3 pos" or "Light light[2]"
            // split into tokens
            var tokens = std.ArrayList([]const u8).empty;
            defer tokens.deinit(allocator);
            var tok_it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
            while (tok_it.next()) |tok| try tokens.append(allocator, tok);
            if (tokens.items.len < 2) continue;
            // ignore precision qualifiers? If first token is highp/mediump/lowp, skip
            var type_idx: usize = 0;
            if (tokens.items.len >= 3 and (std.mem.eql(u8, tokens.items[0], "highp") or std.mem.eql(u8, tokens.items[0], "mediump") or std.mem.eql(u8, tokens.items[0], "lowp"))) {
                type_idx = 1;
            }
            const typ_tok = tokens.items[type_idx];
            const name_tok_raw = tokens.items[type_idx + 1];
            // name may contain array suffix: "positions[4]"
            var name_tok = name_tok_raw;
            var is_arr = false;
            var arr_len: ?usize = null;
            if (std.mem.indexOfScalar(u8, name_tok, '[')) |br| {
                is_arr = true;
                const name_only = name_tok[0..br];
                const arr_part = name_tok[br..];
                // parse length inside [ ]
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
        // skip until ';' after struct
        const semi = std.mem.indexOfPos(u8, source, i, ";");
        if (semi) |s| i = s + 1 else i = brace_close + 1;
    }
    return list.toOwnedSlice(allocator);
}

pub fn parseIns(allocator: std.mem.Allocator, source: []const u8) ![]FieldDef {
    // source should have layouts stripped and comments removed
    var list = std.ArrayList(FieldDef).empty;
    errdefer {
        for (list.items) |f| { allocator.free(f.typ); allocator.free(f.name); }
        list.deinit(allocator);
    }
    // Split by ';' statements
    var it = std.mem.splitScalar(u8, source, ';');
    while (it.next()) |stmt_raw| {
        var stmt = std.mem.trim(u8, stmt_raw, &[_]u8{ ' ', '\t', '\r', '\n' });
        if (stmt.len == 0) continue;
        // Check for " in " pattern — attribute
        // Handle possible "layout(...)" already stripped, so stmt now like "in vec3 aPos"
        if (std.mem.startsWith(u8, stmt, "in ")) {
            stmt = std.mem.trim(u8, stmt[3..], &[_]u8{ ' ', '\t' });
            // now type + name
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
    }
    return list.toOwnedSlice(allocator);
}

pub fn parseUniforms(allocator: std.mem.Allocator, source: []const u8) ![]UniformDef {
    var list = std.ArrayList(UniformDef).empty;
    errdefer {
        for (list.items) |*u| {
            allocator.free(u.glsl_type);
            allocator.free(u.name);
            if (u.block_fields) |fields| {
                for (fields) |f| { allocator.free(f.typ); allocator.free(f.name); }
                allocator.free(fields);
            }
        }
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (i < source.len) {
        const uni_pos = std.mem.indexOfPos(u8, source, i, "uniform") orelse break;
        // word boundary check
        const before_ok = uni_pos == 0 or !isAlnum(source[uni_pos - 1]);
        const after = uni_pos + 7;
        const after_ok = after >= source.len or isWhitespace(source[after]) or source[after] == '{' or source[after] == ' ' or source[after] == '\n' or source[after] == '\r';
        if (!before_ok or !after_ok) { i = uni_pos + 7; continue; }
        const j = skipSpaces(source, after);
        // Peek for block case: need to handle optional identifier then '{'
        // Look ahead to see if next non-space after identifier is '{'
        var tmp = j;
        // parse optional identifier
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
            // uniform block
            const block_name = if (ident) |n| try allocator.dupe(u8, n) else try allocator.dupe(u8, "AnonymousBlock");
            const brace_open = tmp;
            var depth: usize = 0;
            var k = brace_open;
            var close: ?usize = null;
            while (k < source.len) : (k += 1) {
                if (source[k] == '{') depth += 1 else if (source[k] == '}') {
                    depth -= 1;
                    if (depth == 0) { close = k; break; }
                }
            }
            const brace_close = close orelse {
                if (block_name.len != 0) allocator.free(block_name);
                break;
            };
            const inner = source[brace_open + 1 .. brace_close];
            // parse inner fields split by ';'
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
                if (std.mem.indexOfScalar(u8, name, '[')) |br| name = name[0..br];
                const typ_c = try allocator.dupe(u8, typ);
                const name_c = try allocator.dupe(u8, name);
                try fields.append(allocator, .{ .typ = typ_c, .name = name_c });
            }
            const fields_slice = try fields.toOwnedSlice(allocator);
            // After block, there may be instance name before ';'  e.g., "} instanceName;" or just "};"
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
            // Expect ';'
            const semi = std.mem.indexOfPos(u8, source, after_close, ";");
            i = (semi orelse brace_close) + 1;
            const block_fields = fields_slice;
            // For uniform block, glsl_type is block name, name is instance name
            const type_copy = try allocator.dupe(u8, block_name);
            defer allocator.free(block_name);
            try list.append(allocator, .{
                .kind = .block,
                .glsl_type = type_copy,
                .name = instance_name.?,
                .block_fields = block_fields,
                .is_buffer = true,
            });
            // block_name freed via defer; need to not free again
            // type_copy is duplication, so fine
        } else {
            // simple uniform: "uniform <type> <name>;"
            // ident we parsed is actually the type, not block name, need to reinterpret
            // j points to type start, ident is type candidate
            // Actually we consumed identifier as block_name but for simple case it's type
            // So reset: type = ident, name is next identifier
            var type_str: []const u8 = "";
            var name_str: []const u8 = "";
            var type_end = j;
            if (ident) |t| {
                type_str = t;
                type_end = ident_end;
            } else {
                // No type parsed? skip
                i = j;
                continue;
            }
            // Handle precision qualifier if type_str is highp/mediump/lowp then actual type is next token
            if (std.mem.eql(u8, type_str, "highp") or std.mem.eql(u8, type_str, "mediump") or std.mem.eql(u8, type_str, "lowp")) {
                const nxt = skipSpaces(source, type_end);
                var k = nxt;
                while (k < source.len and (isAlnum(source[k]) or source[k] == '_')) k += 1;
                type_str = source[nxt..k];
                type_end = k;
            }
            const after_type = skipSpaces(source, type_end);
            // parse name
            if (after_type >= source.len or !isAlpha(source[after_type])) { i = after_type; continue; }
            var k = after_type;
            while (k < source.len and (isAlnum(source[k]) or source[k] == '_')) k += 1;
            name_str = source[after_type..k];
            // check for array
            var after_name = skipSpaces(source, k);
            if (after_name < source.len and source[after_name] == '[') {
                // skip array part
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

pub fn freeStructs(allocator: std.mem.Allocator, structs: []StructDef) void {
    for (structs) |*s| {
        allocator.free(s.name);
        for (s.fields) |f| { allocator.free(f.typ); allocator.free(f.name); }
        allocator.free(s.fields);
    }
    allocator.free(structs);
}

pub fn freeUniforms(allocator: std.mem.Allocator, uniforms: []UniformDef) void {
    for (uniforms) |*u| {
        allocator.free(u.glsl_type);
        allocator.free(u.name);
        if (u.block_fields) |fields| {
            for (fields) |f| { allocator.free(f.typ); allocator.free(f.name); }
            allocator.free(fields);
        }
    }
    allocator.free(uniforms);
}

pub fn freeFields(allocator: std.mem.Allocator, fields: []FieldDef) void {
    for (fields) |f| { allocator.free(f.typ); allocator.free(f.name); }
    allocator.free(fields);
}

// ------------------------------------------------------------
// File locating helpers for descriptors (robust to assets_dir)
// ------------------------------------------------------------
pub fn readNodeFile(allocator: std.mem.Allocator, io: std.Io, nodePath: []const u8) !?[]u8 {
    // Try to locate file whose path suffix matches nodePath.
    // Walk cwd recursively searching for matching suffix.
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, ".", .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();
    var candidate: ?[]u8 = null;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const p = entry.path;
        // Check suffix equals nodePath or ends with "/" + nodePath
        if (std.mem.eql(u8, p, nodePath) or (p.len > nodePath.len and std.mem.endsWith(u8, p, nodePath) and p[p.len - nodePath.len - 1] == '/')) {
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
    // Fallback: try direct open of nodePath
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

pub fn resolveIncludePath(allocator: std.mem.Allocator, baseFilePath: []const u8, includeRaw: []const u8) ![]u8 {
    // baseFilePath is full path of including file (e.g., assets/shaders/main.vert)
    // includeRaw is like "common.glsl" or "../common.glsl"
    if (std.fs.path.isAbsolute(includeRaw)) return allocator.dupe(u8, includeRaw);
    const dir = std.fs.path.dirname(baseFilePath) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, includeRaw });
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
    const src = "layout(location=0) in vec3 aPos; in vec2 aTexCoord; // comment\n uniform mat4 uModel;";
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
    try std.testing.expectEqualStrings("@import(\"gl_graphics\").Texture", t2);
}
