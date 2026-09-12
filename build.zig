const std = @import("std");

const ThisBuild = @This();

pub const gl_descriptors = struct {
    pub const VertexDescriptor = @import("src/descriptors/vert.zig").VertexDescriptor;
    pub const FragmentDescriptor = @import("src/descriptors/frag.zig").FragmentDescriptor;
    pub const GlslDescriptor = @import("src/descriptors/glsl.zig").GlslDescriptor;
    pub const Common = @import("src/descriptors/common.zig");
};

pub const Options = struct {
    /// The target architecture for which the module will be built.
    target: ?std.Build.ResolvedTarget = null,
    /// The optimization mode used to compile the module.
    optimize: ?std.builtin.OptimizeMode = null,
    /// Shared `gl` module instance. See `dependency_math` for the pattern.
    dependency_gl: ?*std.Build.Module = null,
    /// Shared `math` module instance. When `null`, resolved via
    /// `b.dependency("math", ...)`. Pass an explicit module from the final
    /// project to guarantee a single `math` instance across `gl_graphics`,
    /// `core` and everything else — this avoids "repeated import" type
    /// conflicts (`math.Vec` from two instances are different types).
    dependency_math: ?*std.Build.Module = null,
    /// Shared `assets_manager` module instance. See `dependency_math`.
    dependency_assets_manager: ?*std.Build.Module = null,
    /// Shared `core` module instance. See `dependency_math`.
    /// NOTE: `core` itself imports `math`; after resolving, this helper
    /// re-points `core`'s `"math"` import at the shared `math` module so
    /// transitive types stay identical too.
    dependency_core: ?*std.Build.Module = null,

    pub fn initFromOptions(b: *std.Build) Options {
        return .{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            // `dependency_*` cannot come from `-D` flags; they stay null
            // here and are resolved via `b.dependency` in the helpers below.
        };
    }

    /// Create the `gl_graphics` module in the caller's build graph.
    ///
    /// ```zig
    /// const gl_mod = (@import("gl").Options{ .target = t, .optimize = o }).getModule(b);
    /// const math_mod = (@import("math").Options{ .target = t, .optimize = o }).getModule(b);
    /// const assets_mod = (@import("assets_manager").Options{ .target = t, .optimize = o }).getModule(b);
    /// const core_mod = (@import("core").Options{
    ///     .target = t, .optimize = o, .dependency_math = math_mod,
    /// }).getModule(b);
    /// const gfx_mod = (@import("gl_graphics").Options{
    ///     .target = t,
    ///     .optimize = o,
    ///     .dependency_gl = gl_mod,
    ///     .dependency_math = math_mod,
    ///     .dependency_assets_manager = assets_mod,
    ///     .dependency_core = core_mod,
    /// }).getModule(b);
    /// ```
    /// Any omitted `dependency_*` falls back to this package's own graph,
    /// so the call also works bare (`Options{}`) — deduplication then
    /// relies on Zig's global dependency cache (same target/optimize).
    pub fn getModule(self: Options, b: *std.Build) *std.Build.Module {
        const target = self.target orelse b.standardTargetOptions(.{});
        const optimize = self.optimize orelse b.standardOptimizeOption(.{});
        const self_dep = b.dependencyFromBuildZig(ThisBuild, .{
            .target = target,
            .optimize = optimize,
        });
        const child = self_dep.builder;
        const gl_mod = self.dependency_gl orelse child.dependency("gl", .{
            .target = target,
            .optimize = optimize,
        }).module("gl");
        const math_mod = self.dependency_math orelse child.dependency("math", .{
            .target = target,
            .optimize = optimize,
        }).module("math");
        const assets_mod = self.dependency_assets_manager orelse child.dependency("assets_manager", .{
            .target = target,
            .optimize = optimize,
        }).module("assets_manager");
        const core_mod = self.dependency_core orelse child.dependency("core", .{
            .target = target,
            .optimize = optimize,
        }).module("core");
        // Transitive wiring: force `core` to use the SAME `math` instance.
        // Without this, `core`'s internal `math` (from its own child build)
        // could differ from our shared one when callers mix explicit and
        // fallback modules. When everything falls back with the same
        // target/optimize this is a no-op (global cache already dedupes).
        core_mod.addImport("math", math_mod);

        const mod = b.createModule(.{
            .root_source_file = self_dep.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("gl", gl_mod);
        mod.addImport("math", math_mod);
        mod.addImport("assets_manager", assets_mod);
        mod.addImport("core", core_mod);
        return mod;
    }
};

/// Create the `gl_graphics` module in the *own* package graph.
/// Same wiring as `Options.getModule` but uses `b.path`/`b.dependency`.
fn createModuleOwn(b: *std.Build, options: Options) *std.Build.Module {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    const gl_mod = options.dependency_gl orelse b.dependency("gl", .{
        .target = target,
        .optimize = optimize,
    }).module("gl");
    const math_mod = options.dependency_math orelse b.dependency("math", .{
        .target = target,
        .optimize = optimize,
    }).module("math");
    const assets_mod = options.dependency_assets_manager orelse b.dependency("assets_manager", .{
        .target = target,
        .optimize = optimize,
    }).module("assets_manager");
    const core_mod = options.dependency_core orelse b.dependency("core", .{
        .target = target,
        .optimize = optimize,
    }).module("core");
    // See `Options.getModule`: keep transitive `math` identical.
    core_mod.addImport("math", math_mod);

    const mod = b.addModule("gl_graphics", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("gl", gl_mod);
    mod.addImport("math", math_mod);
    mod.addImport("assets_manager", assets_mod);
    mod.addImport("core", core_mod);
    return mod;
}

pub fn build(b: *std.Build) void {
    const options = Options.initFromOptions(b);
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});

    const mod = createModuleOwn(b, options);

    // Reuse the already-resolved shared instances for the exe so the
    // executable graph contains exactly one instance per dependency.
    const gl_mod = mod.import_table.get("gl").?;
    const math_mod = mod.import_table.get("math").?;
    const assets_mod = mod.import_table.get("assets_manager").?;
    const core_mod = mod.import_table.get("core").?;

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
