const std = @import("std");
const builtin = @import("builtin");

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for zix source.
///
/// Note:
/// - Do not create in other place!
pub const ZIG_SEMVER = struct {
    const MINOR: usize = builtin.zig_version.major;
    const MAJOR: usize = builtin.zig_version.minor;
    const PATCH: usize = builtin.zig_version.patch;
};

// --------------------------------------------------------- //

/// Fail the build with a readable message when the compiler is neither Zig 0.16.x
/// nor 0.17.x, instead of a deep version-specific type error.
///
/// Note:
/// - The std.Build API around the build root moved between these two versions, so
///   dirExists below comptime-branches on the same check. Anything outside this
///   range needs its own port first (rnd/roadmap-0.5.x.md, "Zig version decision").
fn ensureSupportedZig() void {
    const zig = builtin.zig_version;
    if (zig.major == 0 and (zig.minor == 16 or zig.minor == 17)) return;

    @compileError(std.fmt.comptimePrint(
        "zix build requires Zig 0.16.x or 0.17.x, found {d}.{d}.{d}. " ++
            "Use zig-0.16 (or a 0.17 toolchain).",
        .{ zig.major, zig.minor, zig.patch },
    ));
}

/// Whether a directory exists under the build root. Gates the dev-only steps so
/// the package builds cleanly as a fetched dependency that ships only src/.
///
/// Note:
/// - The build-root handle moved between Zig versions: 0.16 exposes b.build_root
///   (a Cache.Directory), 0.17 exposes b.root (a Cache.Path) whose root_dir holds
///   the handle. The comptime branch picks the right field so the same
///   Io.Dir.access call serves both. It uses the build root, not cwd, so the check
///   stays correct when zix is a fetched dependency.
fn dirExists(b: *std.Build, sub_path: []const u8) bool {
    const root_handle = if (comptime builtin.zig_version.minor == 16)
        b.build_root.handle
    else
        b.root.root_dir.handle;

    root_handle.access(b.graph.io, sub_path, .{}) catch return false;

    return true;
}

// --------------------------------------------------------- //

pub fn build(b: *std.Build) void {
    ensureSupportedZig();

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
