//! JZON build root
//!
//! ### file: src/jzon/build.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Build steps for the jzon package: the module, the test steps, and the examples.
//!
//! ### note:
//!
//! The root `build.zig` builds the same module for `zix.jzon`. Keep the module name and
//! the `jzon_options` fields the same in both files.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Private:

const ALLOWED_ZIG = struct {
    pub const MAJOR: usize = 0;
    pub const MINOR: usize = 17;
};

/// Example names, one per file under `examples/`.
const EXAMPLES = [_][]const u8{
    "serialize",
    "deserialize",
    "strings",
    "unknown_keys",
    "bench_serialize",
    "bench_deserialize",
    "zon_file",
};

/// Behaviour tier suites, one per file under `tests/behaviour/`.
const BEHAVIOUR_SUITES = [_][]const u8{
    "tests/behaviour/sink_test.zig",
    "tests/behaviour/cursor_test.zig",
    "tests/behaviour/cursor_vector_test.zig",
    "tests/behaviour/escape_test.zig",
    "tests/behaviour/escape_vector_test.zig",
    "tests/behaviour/integer_test.zig",
    "tests/behaviour/float_test.zig",
    "tests/behaviour/reflect_test.zig",
    "tests/behaviour/fields_test.zig",
    "tests/behaviour/scan_shape_test.zig",
    "tests/behaviour/skip_test.zig",
    "tests/behaviour/string_value_test.zig",
    "tests/behaviour/std_emitter_test.zig",
    "tests/behaviour/generated_emitter_test.zig",
    "tests/behaviour/serialize_test.zig",
    "tests/behaviour/std_parser_test.zig",
    "tests/behaviour/scanner_parser_test.zig",
    "tests/behaviour/generated_parser_test.zig",
    "tests/behaviour/deserialize_test.zig",
    "tests/behaviour/round_trip_test.zig",
    "tests/behaviour/strategy_pairs_test.zig",
    "tests/behaviour/zon_deserialize_test.zig",
    "tests/behaviour/zon_serialize_test.zig",
    "tests/behaviour/zon_round_trip_test.zig",
};

fn ensureSupportedZig() void {
    const zig = builtin.zig_version;

    if (zig.major == ALLOWED_ZIG.MAJOR and zig.minor == ALLOWED_ZIG.MINOR) return;

    @compileError(std.fmt.comptimePrint(
        "jzon build requires Zig {d}.{d}.\n" ++
            "Found {d}.{d}.{d}.",
        .{
            ALLOWED_ZIG.MAJOR,
            ALLOWED_ZIG.MINOR,
            zig.major,
            zig.minor,
            zig.patch,
        },
    ));
}

/// Add one test run per suite file to `step`.
///
/// Param:
/// b - *std.Build (the build graph)
/// target - std.Build.ResolvedTarget (the target every suite compiles for)
/// optimize - std.builtin.OptimizeMode (the optimize mode every suite compiles with)
/// jzon - *std.Build.Module (the package under test, imported as "jzon")
/// step - *std.Build.Step (the tier step that runs every suite)
/// sources - []const []const u8 (the suite paths)
///
/// Return:
/// - void
fn addSuites(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    jzon: *std.Build.Module,
    step: *std.Build.Step,
    sources: []const []const u8,
) void {
    for (sources) |source| {
        const suite_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(source),
        });
        suite_module.addImport("jzon", jzon);

        const suite_tests = b.addTest(.{
            .root_module = suite_module,
        });
        const suite_run = b.addRunArtifact(suite_tests);

        step.dependOn(&suite_run.step);
    }
}

/// Add one install step per example, plus the `examples` step that builds them all.
///
/// Param:
/// b - *std.Build (the build graph)
/// target - std.Build.ResolvedTarget (the target every example compiles for)
/// optimize - std.builtin.OptimizeMode (the optimize mode every example compiles with)
/// jzon - *std.Build.Module (the package, imported as "jzon")
///
/// Return:
/// - void
fn addExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    jzon: *std.Build.Module,
) void {
    const triplet = b.fmt("{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
    });

    const mode = switch (optimize) {
        .debug => "debug",
        .safe => "safe",
        .fast => "fast",
        .small => "small",
    };

    const all_step = b.step("examples", "JZON: Build all examples.");

    for (EXAMPLES) |name| {
        const example_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
        });
        example_module.addImport("jzon", jzon);

        const example_exe = b.addExecutable(.{
            .name = b.fmt("jzon-example-{s}-{s}-{s}", .{
                name,
                triplet,
                mode,
            }),
            .root_module = example_module,
        });
        const example_install = b.addInstallArtifact(example_exe, .{});

        const single_step = b.step(
            b.fmt("example-{s}", .{name}),
            b.fmt("JZON: Build the {s} example.", .{name}),
        );
        single_step.dependOn(&example_install.step);
        all_step.dependOn(&example_install.step);
    }
}

// --------------------------------------------------------- //
// Public:

pub fn build(b: *std.Build) void {
    ensureSupportedZig();

    const zon = @import("build.zig.zon");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const jzon_options = b.addOptions();
    jzon_options.addOption(usize, "version_major", zon.semver.major);
    jzon_options.addOption(usize, "version_minor", zon.semver.minor);
    jzon_options.addOption(usize, "version_patch", zon.semver.patch);

    const jzon = b.addModule("jzon", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/lib.zig"),
    });
    jzon.addOptions("jzon_options", jzon_options);

    // Unit and edge: the in-file tests under src/, collected through src/test.zig
    const unit_edge_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/test.zig"),
    });
    unit_edge_mod.addOptions("jzon_options", jzon_options);

    const unit_edge_tests = b.addTest(.{
        .root_module = unit_edge_mod,
    });
    const unit_edge_run = b.addRunArtifact(unit_edge_tests);

    const unit_edge_step = b.step("unit_edge-test", "JZON: Run unit & edge tests.");
    unit_edge_step.dependOn(&unit_edge_run.step);

    // Behaviour: one test binary per suite file
    const behaviour_step = b.step("behaviour-test", "JZON: Run behaviour tests.");
    addSuites(b, target, optimize, jzon, behaviour_step, &BEHAVIOUR_SUITES);

    const all_step = b.step("all-test", "JZON: Run unit, edge, and behaviour tests.");
    all_step.dependOn(unit_edge_step);
    all_step.dependOn(behaviour_step);

    // Examples
    addExamples(b, target, optimize, jzon);
}

