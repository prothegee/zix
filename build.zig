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
        .{ "example-http_basic", "examples/http_basic.zig" },
        .{ "example-http_json", "examples/http_json.zig" },
        .{ "example-http_manual_concurrent", "examples/http_manual_concurrent.zig" },
        .{ "example-http_middleware", "examples/http_middleware.zig" },
        .{ "example-http_params", "examples/http_params.zig" },
        .{ "example-http_paths", "examples/http_paths.zig" },
        .{ "example-http_static", "examples/http_static.zig" },
        .{ "example-http_timeout_resp", "examples/http_timeout_resp.zig" },
        .{ "example-http_websocket", "examples/http_websocket.zig" },
        .{ "example-http_xtra_headers", "examples/http_xtra_headers.zig" },
        .{ "example-udp_server", "examples/udp_server.zig" },
        .{ "example-udp_client", "examples/udp_client.zig" },
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
