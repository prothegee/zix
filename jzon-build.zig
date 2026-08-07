const std = @import("std");

/// Wire every jzon build step.
///
/// Note:
/// - jzon is part of the zix module (src/jzon, reached as zix.jzon), so its
///   in-file tests are collected by `zig build unit-test` along with the rest of
///   the library. What lives in its own jzon-build-*.zig files is the tiered
///   suites under tests/jzon, which import the zix module the same way every
///   other suite does.
/// - The package ships src/ and these build helpers but not tests/, so a fetched
///   dependency resolves this import and then wires nothing. That is a note on
///   the build log, never an error: everything past the unit tests reads real
///   files out of tests/jzon, and those files are not part of the package.
///
/// Param:
/// zix - *std.Build.Module (the engine module the suites import)
/// have_tests - bool (tests/ is present, so the test steps can be wired)
///
/// Return:
/// - void
pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zix: *std.Build.Module,
    have_tests: bool,
) void {
    if (!have_tests) {
        std.log.info(
            "jzon build: tests/ not found, skipping jzon-behaviour-test / jzon-edge-test / " ++
                "jzon-test-all (every one of them reads a file out of tests/jzon)",
            .{},
        );

        return;
    }

    @import("jzon-build-tests.zig").addSteps(b, target, optimize, zix);
}
