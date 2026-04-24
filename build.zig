const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zix = b.addModule("zix", .{
        .root_source_file = b.path("src/zix.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zix_tests = b.addTest(.{ .root_module = zix });
    const zix_tests_run = b.addRunArtifact(zix_tests);

    // --------------------------------------------------------- //

    const test_step = b.step("test", "Run tests");

    // --------------------------------------------------------- //

    // Unit test
    test_step.dependOn(&zix_tests_run.step);

    // Integration test: postpone tbd

    // --------------------------------------------------------- //

    // Examples
    const examples = .{
        .{ "server_basic", "examples/server_basic.zig" },
        .{ "server_json", "examples/server_json.zig" },
        .{ "server_timeout_resp", "examples/server_timeout_resp.zig" },
        .{ "server_params", "examples/server_params.zig" },
        .{ "server_manual_concurrent", "examples/server_manual_concurrent.zig" },
        .{ "server_paths", "examples/server_paths.zig" },
    };

    inline for (examples) |pair| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(pair[1]),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("zix", zix);

        const exe = b.addExecutable(.{
            .name = pair[0],
            .root_module = exe_mod,
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        const run_step = b.step("example-" ++ pair[0], "Run " ++ pair[0]);
        run_step.dependOn(&run.step);
    }
}
