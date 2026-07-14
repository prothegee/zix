const std = @import("std");
const builtin = @import("builtin");

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for the rediz build.
///
/// Note:
/// - Mirror of the check in src/lib.zig, kept local because build.zig cannot
///   import the module it builds.
pub const ZIG_SEMVER = struct {
    pub const MAJOR: usize = builtin.zig_version.major;
    pub const MINOR: usize = builtin.zig_version.minor;
    pub const PATCH: usize = builtin.zig_version.patch;
};

/// Examples built into zig-out/bin and verified by tests/runner.zig.
const example_names = [_][]const u8{
    "basic_connect",
    "url_connect",
    "strings_keyspace",
    "typed_json",
    "raw_command",
    "connection_pool",
    "pipeline_batch",
    "tls_connect",
    "error_handling",
};

// --------------------------------------------------------- //

/// Fail the build with a readable message when the compiler is neither Zig 0.16.x
/// nor 0.17.x, instead of a deep version-specific type error.
fn ensureSupportedZig() void {
    if (ZIG_SEMVER.MAJOR == 0 and (ZIG_SEMVER.MINOR == 16 or ZIG_SEMVER.MINOR == 17)) return;

    @compileError(std.fmt.comptimePrint(
        "rediz build requires Zig 0.16.x or 0.17.x, found {d}.{d}.{d}. " ++
            "Use zig-0.16 (or a 0.17 toolchain).",
        .{ ZIG_SEMVER.MAJOR, ZIG_SEMVER.MINOR, ZIG_SEMVER.PATCH },
    ));
}

/// Container start pipeline: build the image, replace any old container,
/// run detached. Rootless podman through the docker compat. The returned
/// step is the running container, callers hang their suite on it and hang a
/// teardown (addContainerTeardown) after the suite.
///
/// Note:
/// - test-integration and test-runner each get their OWN pipeline but share
///   the container name and ports: run them in separate invocations. On a
///   failed run the container stays up, the next run's pre-clean (or
///   `docker rm -f zix-rediz-r8`) removes it.
fn addContainerStart(b: *std.Build) *std.Build.Step.Run {
    const image_build = b.addSystemCommand(&.{
        "docker", "build", "-t", "zix-rediz-r8-img", "../../../containers/redis",
    });

    const pre_clean = b.addSystemCommand(&.{
        "sh", "-c", "docker rm -f zix-rediz-r8 >/dev/null 2>&1 || true",
    });
    pre_clean.step.dependOn(&image_build.step);

    const container_run = b.addSystemCommand(&.{
        "docker",           "run",
        "--rm",             "-d",
        "--name",           "zix-rediz-r8",
        "-p",               "127.0.0.1:63980:6379",
        "-p",               "127.0.0.1:63981:6390",
        "zix-rediz-r8-img",
    });
    container_run.step.dependOn(&pre_clean.step);

    return container_run;
}

fn addContainerTeardown(b: *std.Build) *std.Build.Step.Run {
    return b.addSystemCommand(&.{
        "sh", "-c", "docker rm -f zix-rediz-r8 >/dev/null 2>&1 || true",
    });
}

// --------------------------------------------------------- //

pub fn build(b: *std.Build) void {
    ensureSupportedZig();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rediz = b.addModule("rediz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --------------------------------------------------------- //

    // In-file tests live in the rediz module, scenario tests in tests/unit.zig.
    // Zig collects tests per module, so each needs its own addTest.
    const module_tests = b.addTest(.{ .root_module = rediz });
    const module_run = b.addRunArtifact(module_tests);

    const unit_module = b.createModule(.{
        .root_source_file = b.path("tests/unit.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_module.addImport("rediz", rediz);

    const unit_tests = b.addTest(.{ .root_module = unit_module });
    const unit_run = b.addRunArtifact(unit_tests);
    unit_run.step.dependOn(&module_run.step);

    const unit_step = b.step("test-unit", "Run rediz unit tests (no server needed)");
    unit_step.dependOn(&module_run.step);
    unit_step.dependOn(&unit_run.step);

    // --------------------------------------------------------- //

    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_module.addImport("rediz", rediz);

    const integration_tests = b.addTest(.{ .root_module = integration_module });
    const integration_run = b.addRunArtifact(integration_tests);
    // the suite talks to a fresh container every run: never cache-skip it
    integration_run.has_side_effects = true;
    integration_run.step.dependOn(&addContainerStart(b).step);

    const integration_teardown = addContainerTeardown(b);
    integration_teardown.step.dependOn(&integration_run.step);

    const integration_step = b.step("test-integration", "Run rediz integration tests (owns the Redis 8 container lifecycle)");
    integration_step.dependOn(&integration_teardown.step);

    // --------------------------------------------------------- //

    // Examples: `zig build examples` builds them all into zig-out/bin,
    // `zig build example-<name>` builds one (run it from zig-out/bin).
    const examples_step = b.step("examples", "Build every rediz example into zig-out/bin");

    var example_exes: [example_names.len]*std.Build.Step.Compile = undefined;
    inline for (example_names, 0..) |name, index| {
        const example_module = b.createModule(.{
            .root_source_file = b.path("examples/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        example_module.addImport("rediz", rediz);

        const example_exe = b.addExecutable(.{
            .name = "rediz-example-" ++ name,
            .root_module = example_module,
        });
        example_exes[index] = example_exe;

        const example_install = b.addInstallArtifact(example_exe, .{});
        examples_step.dependOn(&example_install.step);

        const single_step = b.step("example-" ++ name, "Build the " ++ name ++ " example into zig-out/bin");
        single_step.dependOn(&example_install.step);
    }

    // --------------------------------------------------------- //

    // Example runner: verifies every example against a fresh container.
    const runner_module = b.createModule(.{
        .root_source_file = b.path("tests/runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    runner_module.addImport("rediz", rediz);

    const runner_exe = b.addExecutable(.{
        .name = "rediz-runner",
        .root_module = runner_module,
    });

    const runner_run = b.addRunArtifact(runner_exe);
    runner_run.has_side_effects = true;
    for (example_exes) |example_exe| runner_run.addArtifactArg(example_exe);
    runner_run.step.dependOn(&addContainerStart(b).step);

    const runner_teardown = addContainerTeardown(b);
    runner_teardown.step.dependOn(&runner_run.step);

    const runner_step = b.step("test-runner", "Run every rediz example against the Redis 8 container (owns the lifecycle)");
    runner_step.dependOn(&runner_teardown.step);
}
