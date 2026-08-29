const std = @import("std");

pub const gl_descriptors = struct {
    pub const VertexDescriptor = @import("src/descriptors/vert.zig").VertexDescriptor;
    pub const FragmentDescriptor = @import("src/descriptors/frag.zig").FragmentDescriptor;
    pub const GlslDescriptor = @import("src/descriptors/glsl.zig").GlslDescriptor;
    pub const Common = @import("src/descriptors/common.zig");
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("gl_graphics", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const gl_dep = b.dependency("gl", .{ .target = target });
    const gl_mod = gl_dep.module("gl");
    const math_dep = b.dependency("math", .{ .target = target });
    const math_mod = math_dep.module("math");
    const assets_dep = b.dependency("assets_manager", .{});
    const assets_mod = assets_dep.module("assets_manager");
    const core_dep = b.dependency("core", .{ .target = target });
    const core_mod = core_dep.module("core");
    mod.addImport("gl", gl_mod);
    mod.addImport("math", math_mod);
    mod.addImport("assets_manager", assets_mod);
    mod.addImport("core", core_mod);

    const exe = b.addExecutable(.{
        .name = "gl_graphics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gl_graphics", .module = mod },
                .{ .name = "gl", .module = gl_mod },
                .{ .name = "math", .module = math_mod },
                .{ .name = "assets_manager", .module = assets_mod },
                .{ .name = "core", .module = core_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

}
