const std = @import("std");
const builtin = @import("builtin");

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for zix source.
///
/// Note:
/// - Do not create in other place!
pub const ZIG_SEMVER = struct {
    pub const MAJOR: usize = builtin.zig_version.major;
    pub const MINOR: usize = builtin.zig_version.minor;
    pub const PATCH: usize = builtin.zig_version.patch;
};

// --------------------------------------------------------- //

/// Fail the build with a readable message when the compiler is neither Zig 0.16.x
/// nor 0.17.x, instead of a deep version-specific type error.
///
/// Note:
/// - The std.Build API around the build root moved between these two versions, so
///   dirExists below comptime-branches on the same check. Anything outside this
///   range needs its own port first (see the Zig version decision in the roadmap).
fn ensureSupportedZig() void {
    if (ZIG_SEMVER.MAJOR == 0 and (ZIG_SEMVER.MINOR == 16 or ZIG_SEMVER.MINOR == 17)) return;

    @compileError(std.fmt.comptimePrint(
        "zix build requires Zig 0.16.x or 0.17.x, found {d}.{d}.{d}. " ++
            "Use zig-0.16 (or a 0.17 toolchain).",
        .{ ZIG_SEMVER.MAJOR, ZIG_SEMVER.MINOR, ZIG_SEMVER.PATCH },
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
    const root_handle = if (comptime ZIG_SEMVER.MINOR == 16)
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

    // Brotli's static dictionary (RFC 7932 Appendix A) is generated at build time into the
    // cache by brotli_dictionary.gen.zig and bound to the @embedFile import in brotli.zig, so
    // no binary asset is tracked and no .gitignore exception is needed. Compiling the codec
    // depends on this run through the import, so any `zig build` target that builds zix
    // regenerates the dictionary first.
    const brotli_dict_gen = b.addExecutable(.{
        .name = "brotli_dictionary_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/compression/brotli_dictionary.gen.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const brotli_dict_run = b.addRunArtifact(brotli_dict_gen);
    const brotli_dict = brotli_dict_run.addOutputFileArg("brotli_dictionary.bin");
    zix.addAnonymousImport("brotli_dictionary.bin", .{ .root_source_file = brotli_dict });

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
