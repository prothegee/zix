const std = @import("std");

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zix: *std.Build.Module,
) void {
    const zix_tests = b.addTest(.{ .root_module = zix });
    const zix_tests_run = b.addRunArtifact(zix_tests);

    const test_step = b.step("unit-test", "Run unit tests");
    test_step.dependOn(&zix_tests_run.step);

    // --------------------------------------------------------- //

    const integration_test_step = b.step("integration-test", "Run integration tests");

    const integration_tests = .{
        // tcp
        "tests/integration/tcp/config_test.zig",
        // http
        "tests/integration/http/request_test.zig",
        "tests/integration/http/router_test.zig",
        "tests/integration/http/context_test.zig",
        "tests/integration/http/header_index_test.zig",
        "tests/integration/http/sse_test.zig",
        "tests/integration/http/client_test.zig",
        "tests/integration/http/ws_client_test.zig",
        "tests/integration/http/sse_client_test.zig",
        // http1
        "tests/integration/http1/server_test.zig",
        "tests/integration/http1/router_test.zig",
        // http2
        "tests/integration/http2/server_test.zig",
        // websocket
        "tests/integration/websocket/websocket_test.zig",
        // fix
        "tests/integration/fix/server_test.zig",
        // grpc
        "tests/integration/grpc/server_test.zig",
        // udp
        "tests/integration/udp/packet_test.zig",
        "tests/integration/udp/config_test.zig",
        // uds
        "tests/integration/uds/config_test.zig",
        // channel
        "tests/integration/channel/channel_test.zig",
        // logger
        "tests/integration/logger/logger_test.zig",
    };

    var prev_integ: ?*std.Build.Step = null;
    inline for (integration_tests) |src| {
        const t_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
        });
        t_mod.addImport("zix", zix);

        const t_exe = b.addTest(.{ .root_module = t_mod });
        const t_run = b.addRunArtifact(t_exe);
        if (prev_integ) |p| t_run.step.dependOn(p);
        prev_integ = &t_run.step;
        integration_test_step.dependOn(&t_run.step);
    }

    // --------------------------------------------------------- //

    const behaviour_test_step = b.step("behaviour-test", "Run behaviour tests");

    const behaviour_tests = .{
        // tcp
        "tests/behaviour/tcp/config_test.zig",
        // http
        "tests/behaviour/http/request_test.zig",
        "tests/behaviour/http/router_test.zig",
        "tests/behaviour/http/content_test.zig",
        "tests/behaviour/http/config_test.zig",
        "tests/behaviour/http/sse_test.zig",
        "tests/behaviour/http/client_test.zig",
        // http1
        "tests/behaviour/http1/config_test.zig",
        "tests/behaviour/http1/core_test.zig",
        // http2
        "tests/behaviour/http2/config_test.zig",
        // websocket
        "tests/behaviour/websocket/websocket_test.zig",
        // fix
        "tests/behaviour/fix/session_test.zig",
        // grpc
        "tests/behaviour/grpc/config_test.zig",
        // udp
        "tests/behaviour/udp/packet_test.zig",
        "tests/behaviour/udp/config_test.zig",
        // uds
        "tests/behaviour/uds/config_test.zig",
        // channel
        "tests/behaviour/channel/channel_test.zig",
        // logger
        "tests/behaviour/logger/logger_test.zig",
    };

    var prev_behav: ?*std.Build.Step = null;
    inline for (behaviour_tests) |src| {
        const t_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
        });
        t_mod.addImport("zix", zix);

        const t_exe = b.addTest(.{ .root_module = t_mod });
        const t_run = b.addRunArtifact(t_exe);
        if (prev_behav) |p| t_run.step.dependOn(p);
        prev_behav = &t_run.step;
        behaviour_test_step.dependOn(&t_run.step);
    }

    // --------------------------------------------------------- //

    const edge_test_step = b.step("edge-test", "Run edge tests");

    const edge_tests = .{
        // tcp
        "tests/edge/tcp/config_test.zig",
        // http
        "tests/edge/http/request_test.zig",
        "tests/edge/http/router_test.zig",
        "tests/edge/http/response_test.zig",
        "tests/edge/http/content_test.zig",
        "tests/edge/http/client_test.zig",
        "tests/edge/http/ws_client_test.zig",
        "tests/edge/http/sse_client_test.zig",
        // http1
        "tests/edge/http1/core_test.zig",
        // http2
        "tests/edge/http2/server_test.zig",
        // websocket
        "tests/edge/websocket/websocket_test.zig",
        // fix
        "tests/edge/fix/session_test.zig",
        // grpc
        "tests/edge/grpc/server_test.zig",
        // udp
        "tests/edge/udp/packet_test.zig",
        "tests/edge/udp/config_test.zig",
        // uds
        "tests/edge/uds/config_test.zig",
        // channel
        "tests/edge/channel/channel_test.zig",
        // logger
        "tests/edge/logger/logger_test.zig",
    };

    var prev_edge: ?*std.Build.Step = null;
    inline for (edge_tests) |src| {
        const t_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
        });
        t_mod.addImport("zix", zix);

        const t_exe = b.addTest(.{ .root_module = t_mod });
        const t_run = b.addRunArtifact(t_exe);
        if (prev_edge) |p| t_run.step.dependOn(p);
        prev_edge = &t_run.step;
        edge_test_step.dependOn(&t_run.step);
    }

    // --------------------------------------------------------- //

    // Run tiers sequentially so zig 0.16 IPC sends ".exit" before the next tier starts.
    behaviour_test_step.dependOn(integration_test_step);
    edge_test_step.dependOn(behaviour_test_step);

    const all_test_step = b.step("test-all", "Run unit, integration, behaviour, and edge tests");
    all_test_step.dependOn(&zix_tests_run.step);
    all_test_step.dependOn(integration_test_step);
    all_test_step.dependOn(behaviour_test_step);
    all_test_step.dependOn(edge_test_step);
}
