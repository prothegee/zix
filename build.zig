const std = @import("std");

pub fn build(b: *std.Build) void {
    const zon = @import("build.zig.zon");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zix = b.addModule("zix", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --------------------------------------------------------- //

    const zon_options = b.addOptions();
    zon_options.addOption([]const u8, "user_agent", zon.user_agent);
    zix.addOptions("zon_options", zon_options);

    // --------------------------------------------------------- //

    // Dev-only steps (tests, examples, test-runners) are wired only when their
    // source directories are present. When zix is consumed as a fetched
    // dependency the package ships src/ plus these build helpers but not tests/
    // or examples/, so the helper imports still resolve (compile-time) while the
    // steps that reference the missing directories are skipped (run-time).
    const have_tests = dirExists(b, "tests");
    const have_examples = dirExists(b, "examples");

    if (have_tests) {
        @import("zix-build-tests.zig").addSteps(b, target, optimize, zix);
    } else {
        std.log.info("zix build: tests/ not found, skipping test steps (unit/integration/behaviour/edge)", .{});
    }

    if (have_examples) {
        @import("zix-build-examples.zig").addSteps(b, target, optimize, zix);
    } else {
        std.log.info("zix build: examples/ not found, skipping example steps", .{});
    }

    // The test-runners spawn example servers, so they need both directories.
    if (have_tests and have_examples) {
        @import("zix-build-test_runner.zig").addSteps(b, target, optimize, zix);
    } else {
        std.log.info("zix build: tests/ + examples/ required for test-runner steps, skipping", .{});
    }
}

/// Whether a directory exists under the build root. Gates the dev-only steps so
/// the package builds cleanly as a fetched dependency that ships only src/.
fn dirExists(b: *std.Build, sub_path: []const u8) bool {
    b.build_root.handle.access(b.graph.io, sub_path, .{}) catch return false;

    return true;
}
