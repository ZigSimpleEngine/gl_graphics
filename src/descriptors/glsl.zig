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

/// Descriptor that generates Zig structs from GLSL struct declarations.
pub const GlslDescriptor = struct {
    /// Number of spaces to indent per depth level.
    spaces_per_depth: usize = 4,

    /// Tests whether a node is suitable for generic GLSL generation.
    /// Parameters:
    /// - ptr: opaque descriptor pointer unused.
    /// - init: process init context unused.
    /// - data: descriptor data containing node to test.
    /// Returns: true when node is a .glsl file.
    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, data: Descriptor.Data) anyerror!bool {
        _ = ptr;
        _ = init;
        const node = data.node;
        if (node.kind != .file) return false;
        if (node.name) |name| {
            return std.mem.endsWith(u8, name, ".glsl");
        }
        return false;
    }

    /// Generates Zig source code for a generic GLSL file containing struct definitions.
    /// Parameters:
    /// - ptr: opaque descriptor pointer to self.
    /// - init: process init providing allocators and IO.
    /// - data: descriptor data with node, depth and path info.
    /// Returns: allocated Zig source string.
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
        const dot = std.mem.lastIndexOfScalar(u8, identifier_raw, '.');
        const baseName = if (dot) |d| identifier_raw[0..d] else identifier_raw;
        const var_name = try text_utils.filenameToIdentifier(gpa, baseName);
        defer gpa.free(var_name);

        const rawContent = try common.readNodeFile(gpa, io, path) orelse blk: {
            break :blk try gpa.dupe(u8, "");
        };
        defer gpa.free(rawContent);

        const no_comments = try common.stripComments(gpa, rawContent);
        defer gpa.free(no_comments);

        const structs = try common.parseStructs(gpa, no_comments);
        defer common.freeStructs(gpa, structs);

        var inner = std.ArrayList(u8).empty;
        defer inner.deinit(gpa);

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

    /// Returns a Descriptor vtable for this GLSL descriptor.
    /// Parameters:
    /// - self: pointer to descriptor instance.
    /// Returns: Descriptor with vtable.
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
