const std = @import("std");
const builtin = @import("builtin");

// --------------------------------------------------------- //

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for the uuidz build.
///
/// Note:
/// - Mirror of the check in src/lib.zig, kept local because build.zig cannot
///   import the module it builds.
pub const ZIG_SEMVER = struct {
    pub const MAJOR: usize = builtin.zig_version.major;
    pub const MINOR: usize = builtin.zig_version.minor;
    pub const PATCH: usize = builtin.zig_version.patch;
};

/// Examples built into zig-out/bin, one per question a caller asks uuidz.
const example_names = [_][]const u8{
    // "bench-uuid-v1",
};

// --------------------------------------------------------- //

/// Wrap a compiled test artifact in a Run step when the target can execute on
/// this host, otherwise return the compile step directly. Deterministic
/// compile-only coverage for a foreign target regardless of host binfmt_misc /
/// qemu registration making execution technically possible.
///
/// Note:
/// - name tags the step with its source path, so `--summary all` shows which
///   test file a pending or hung step belongs to.
fn testRunStep(b: *std.Build, exe: *std.Build.Step.Compile, foreign: bool, name: []const u8) *std.Build.Step {
    if (foreign) {
        exe.step.name = name;

        return &exe.step;
    }

    const run = b.addRunArtifact(exe);
    run.setName(name);

    return &run.step;
}

/// Compile every suite in `sources` into one step, each run chained after the
/// one before it.
///
/// Note:
/// - The chaining is not for ordering's sake. Zig 0.16 needs a suite's IPC
///   ".exit" to land before the next one starts, which running them back to back
///   guarantees.
///
/// Param:
/// uuidz - *std.Build.Module (the package under test, imported as "uuidz")
/// sources - []const []const u8 (the suite paths, in run order)
/// after - ?*std.Build.Step (a step every suite here runs behind, or null)
///
/// Return:
/// - ?*std.Build.Step (the last suite's step, or null when `sources` is empty)
fn addSuites(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    uuidz: *std.Build.Module,
    foreign: bool,
    step: *std.Build.Step,
    sources: []const []const u8,
    after: ?*std.Build.Step,
) ?*std.Build.Step {
    var previous = after;

    for (sources) |source| {
        const suite_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        });
        suite_module.addImport("uuidz", uuidz);

        const suite_tests = b.addTest(.{ .root_module = suite_module });
        const suite_step = testRunStep(b, suite_tests, foreign, source);
        if (previous) |prior| suite_step.dependOn(prior);

        previous = suite_step;
        step.dependOn(suite_step);
    }

    return previous;
}

// --------------------------------------------------------- //

/// Fail the build with a readable message when the compiler is neither Zig 0.16.x
/// nor 0.17.x, instead of a deep version-specific type error.
fn ensureSupportedZig() void {
    if (ZIG_SEMVER.MAJOR == 0 and (ZIG_SEMVER.MINOR == 16 or ZIG_SEMVER.MINOR == 17)) return;

    @compileError(std.fmt.comptimePrint(
        "uuidz build requires Zig 0.16.x or 0.17.x, found {d}.{d}.{d}. " ++
            "Use zig-0.16 (or a 0.17 toolchain).",
        .{ ZIG_SEMVER.MAJOR, ZIG_SEMVER.MINOR, ZIG_SEMVER.PATCH },
    ));
}

// --------------------------------------------------------- //

pub fn build(b: *std.Build) void {
    ensureSupportedZig();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Installed example binaries carry the target triplet and the optimize mode
    // so per-target and per-mode builds coexist in zig-out/bin. A foreign target
    // (cross build) compiles every suite and example but skips execution.
    const triplet = b.fmt("{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });

    // The optimize mode, lowercased, is the last part of every installed name.
    // No -Doptimize means Debug, so a plain build writes -debug. Spelled out
    // rather than lowercased at runtime so a new mode is a compile error here.
    const mode = switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe => "releasesafe",
        .ReleaseFast => "releasefast",
        .ReleaseSmall => "releasesmall",
    };

    const host = b.graph.host.result;
    const foreign_target = target.result.os.tag != host.os.tag or target.result.cpu.arch != host.cpu.arch;
    if (foreign_target) {
        std.log.info("uuidz: target {s} is foreign to this host, suites and examples compile but execution is skipped", .{triplet});
    }

    const uuidz = b.addModule("uuidz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --------------------------------------------------------- //

    // The in-file tests that sit beside the code they cover. Zig collects tests
    // per module, so the module needs its own addTest even though the tiered
    // suites below import it.
    const module_tests = b.addTest(.{ .root_module = uuidz });

    const unit_step = b.step("test-unit", "Run the uuidz in-file tests (src/)");
    unit_step.dependOn(testRunStep(b, module_tests, foreign_target, "src/lib.zig"));

    // --------------------------------------------------------- //

    const all_step = b.step("test-all", "Run every uuidz test: in-file unit tests");

    all_step.dependOn(unit_step);

    // --------------------------------------------------------- //

    // Examples: `zig build examples` builds them all into zig-out/bin,
    // `zig build example-<name>` builds one (run it from zig-out/bin).
    const examples_step = b.step("examples", "Build every uuidz example into zig-out/bin");

    inline for (example_names) |name| {
        const example_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        example_module.addImport("uuidz", uuidz);

        const example_exe = b.addExecutable(.{
            .name = b.fmt("uuidz-example-{s}-{s}-{s}", .{ name, triplet, mode }),
            .root_module = example_module,
        });

        const example_install = b.addInstallArtifact(example_exe, .{});
        examples_step.dependOn(&example_install.step);

        const single_step = b.step("example-" ++ name, "Build the " ++ name ++ " example into zig-out/bin");
        single_step.dependOn(&example_install.step);
    }
}
