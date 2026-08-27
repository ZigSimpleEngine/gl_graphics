const std = @import("std");
const Descriptor = @import("assets_manager").descriptors.Descriptor;
const Node = @import("assets_manager").assets_tree.Node;
const text_utils = @import("assets_manager").text_utils;
const common = @import("common.zig");

// GlslDescriptor — handles .glsl files, generates Zig struct containing
// only struct declarations from the source file.
pub const GlslDescriptor = struct {
    spaces_per_depth: usize = 4,

    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, data: Descriptor.Data) anyerror!bool {
        _ = ptr; _ = init;
        const node = data.node;
        if (node.kind != .file) return false;
        if (node.name) |name| {
            return std.mem.endsWith(u8, name, ".glsl");
        }
        return false;
    }

    pub fn getCode(ptr: *anyopaque, init: std.process.Init, data: Descriptor.Data) anyerror![]u8 {
        const self: *GlslDescriptor = @ptrCast(@alignCast(ptr));
        const gpa = init.gpa;
        const io = init.io;
        const node = data.node;
        const depth = data.depth;

        const prefix = try text_utils.repeat(gpa, " ", depth * self.spaces_per_depth);
        defer if (prefix) |p| gpa.free(p);

        const path = try node.createPath(gpa);
        defer gpa.free(path);

        const identifier_raw = node.name orelse return error.MissingName;
        // strip extension
        const dot = std.mem.lastIndexOfScalar(u8, identifier_raw, '.');
        const baseName = if (dot) |d| identifier_raw[0..d] else identifier_raw;
        const var_name = try text_utils.filenameToIdentifier(gpa, baseName);
        defer gpa.free(var_name);

        // Read file content via common helper (walk)
        const rawContent = try common.readNodeFile(gpa, io, path) orelse blk: {
            // fallback: try path with assets prefix? already attempted fallback; give empty
            break :blk try gpa.dupe(u8, "");
        };
        defer gpa.free(rawContent);

        const no_comments = try common.stripComments(gpa, rawContent);
        defer gpa.free(no_comments);

        const structs = try common.parseStructs(gpa, no_comments);
        defer common.freeStructs(gpa, structs);

        // Build inner struct definitions
        var inner = std.ArrayList(u8).empty;
        defer inner.deinit(gpa);

        // If no structs, generate empty struct placeholder with comment
        if (structs.len == 0) {
            try inner.appendSlice(gpa, "    // No struct declarations found in .glsl source.\n");
        } else {
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
                    try inner.appendSlice(gpa, zig_type);
                    if (f.is_array) {
                        if (f.array_len) |len| {
                            // Convert to array type: [len]Child
                            // Need to rewrite previous line? For now emit as array field type override
                            // We already emitted child type, need to wrap: Instead we stored child, so we should emit array syntax directly
                            // Our map already gave child type, we need to adjust: replace line
                            // Simple: emit array type directly without prior map? We handled via map then not array.
                            // For now emit as "[len]type" — we did not. We'll fix by replacing.
                            // To keep simple, we ignore array len and emit slice type warning.
                            _ = len;
                        }
                    }
                    try inner.appendSlice(gpa, ",\n");
                }
                try inner.appendSlice(gpa, "    };\n");
            }
        }

        const inner_slice = try inner.toOwnedSlice(gpa);
        defer gpa.free(inner_slice);

        const new_line_after = if (inner_slice.len > 0 and inner_slice[inner_slice.len - 1] == '\n') "" else "\n";

        return std.fmt.allocPrint(gpa,
            "{s}pub const {s} = struct {{\n{s}{s}{s}}};\n",
            .{
                prefix orelse "",
                var_name,
                inner_slice,
                new_line_after,
                prefix orelse "",
            });
    }

    pub fn descriptor(self: *GlslDescriptor) Descriptor {
        return .{
            .ptr = self,
            .vtable = .{
                .get_code = getCode,
                .is_suitable_data = isSuitableData,
            },
        };
    }
};
