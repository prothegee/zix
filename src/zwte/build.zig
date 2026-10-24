const std = @import("std");
const builtin = @import("builtin");

// --------------------------------------------------------- //

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for the zwte build.
///
/// Note:
/// - Mirror of the check in src/lib.zig, kept local because build.zig cannot
///   import the module it builds.
pub const ZIG_SEMVER = struct {
    pub const MAJOR: usize = builtin.zig_version.major;
    pub const MINOR: usize = builtin.zig_version.minor;
    pub const PATCH: usize = builtin.zig_version.patch;
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

/// Fail the build with a readable message when the compiler is neither Zig 0.16.x
/// nor 0.17.x, instead of a deep version-specific type error.
fn ensureSupportedZig() void {
    if (ZIG_SEMVER.MAJOR == 0 and (ZIG_SEMVER.MINOR == 16 or ZIG_SEMVER.MINOR == 17)) return;

    @compileError(std.fmt.comptimePrint(
        "zwte build requires Zig 0.16.x or 0.17.x, found {d}.{d}.{d}. " ++
            "Use zig-0.16 (or a 0.17 toolchain).",
        .{ ZIG_SEMVER.MAJOR, ZIG_SEMVER.MINOR, ZIG_SEMVER.PATCH },
    ));
}

// --------------------------------------------------------- //

pub fn build(b: *std.Build) void {
    ensureSupportedZig();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const host = b.graph.host.result;
    const foreign_target = target.result.os.tag != host.os.tag or target.result.cpu.arch != host.cpu.arch;

    const zwte = b.addModule("zwte", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --------------------------------------------------------- //

    // The in-file tests that sit beside the code they cover. Zig collects tests
    // per module, so the module needs its own addTest.
    const module_tests = b.addTest(.{ .root_module = zwte });

    const unit_step = b.step("test-unit", "Run the zwte in-file tests (src/)");
    unit_step.dependOn(testRunStep(b, module_tests, foreign_target, "src/lib.zig"));

    // --------------------------------------------------------- //

    const all_step = b.step("test-all", "Run every zwte test: in-file unit tests");

    all_step.dependOn(unit_step);
}
