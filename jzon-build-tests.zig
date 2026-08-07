const std = @import("std");

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
/// zix - *std.Build.Module (the engine module every suite imports)
/// sources - []const []const u8 (the suite paths, in run order)
/// after - ?*std.Build.Step (a step every suite here runs behind, or null)
///
/// Return:
/// - ?*std.Build.Step (the last suite's step, or null when `sources` is empty)
fn addSuites(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zix: *std.Build.Module,
    foreign: bool,
    step: *std.Build.Step,
    sources: []const []const u8,
    after: ?*std.Build.Step,
) ?*std.Build.Step {
    var previous = after;

    for (sources) |source| {
        const suite_mod = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        });
        suite_mod.addImport("zix", zix);

        const suite_tests = b.addTest(.{ .root_module = suite_mod });
        const suite_step = testRunStep(b, suite_tests, foreign, source);
        if (previous) |prior| suite_step.dependOn(prior);

        previous = suite_step;
        step.dependOn(suite_step);
    }

    return previous;
}

/// Wire `zig build jzon-behaviour-test`, `jzon-edge-test` and `jzon-test-all`.
///
/// Note:
/// - jzon's own in-file tests live in src/jzon, which the zix module reaches, so
///   they are collected by `zig build unit-test` and need no step here. What
///   this file wires is only the tiered suites under tests/jzon.
/// - A new src/jzon file with tests still needs a refAllDecls line in
///   src/lib.zig to be found by that unit-test step.
///
/// Param:
/// zix - *std.Build.Module (the engine module every suite imports)
///
/// Return:
/// - void
pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zix: *std.Build.Module,
) void {
    // Foreign target (e.g. -Dtarget=x86_64-windows on a Linux host): every suite
    // still compiles for the target and the run steps report skipped instead of
    // failing to spawn, so the step passes as a compile-coverage pass. On the
    // target's own machine the suites run for real.
    const host = b.graph.host.result;
    const foreign_target = target.result.os.tag != host.os.tag or target.result.cpu.arch != host.cpu.arch;
    if (foreign_target) {
        std.log.info("jzon tests: target {s}-{s} is foreign to this host, suites compile but execution is skipped", .{
            @tagName(target.result.cpu.arch), @tagName(target.result.os.tag),
        });
    }

    // --------------------------------------------------------- //

    const behaviour_step = b.step("jzon-behaviour-test", "Run the jzon behaviour tests");

    const behaviour_suites = [_][]const u8{
        "tests/jzon/behaviour/sink_test.zig",
        "tests/jzon/behaviour/cursor_test.zig",
        "tests/jzon/behaviour/escape_test.zig",
        "tests/jzon/behaviour/integer_test.zig",
    };
    const last_behaviour = addSuites(b, target, optimize, zix, foreign_target, behaviour_step, &behaviour_suites, null);

    // --------------------------------------------------------- //

    const edge_step = b.step("jzon-edge-test", "Run the jzon edge tests");

    const edge_suites = [_][]const u8{
        "tests/jzon/edge/sink_test.zig",
        "tests/jzon/edge/cursor_test.zig",
        "tests/jzon/edge/escape_test.zig",
        "tests/jzon/edge/integer_test.zig",
    };
    _ = addSuites(b, target, optimize, zix, foreign_target, edge_step, &edge_suites, last_behaviour);

    // The edge tier runs behind the behaviour tier, the order the zix suites
    // hold to.
    edge_step.dependOn(behaviour_step);

    // --------------------------------------------------------- //

    const all_step = b.step("jzon-test-all", "Run the jzon behaviour and edge tests");
    all_step.dependOn(behaviour_step);
    all_step.dependOn(edge_step);
}
