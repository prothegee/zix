const std = @import("std");

pub fn build(b: *std.Build) void {
    const zon = @import("build.zig.zon");
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

    const zon_options = b.addOptions();

    // Options:
    // user_agent
    zon_options.addOption([]const u8, "user_agent", zon.user_agent);

    zix.addOptions("zon_options", zon_options);

    // --------------------------------------------------------- //

    const test_step = b.step("unit-test", "Run tests");

    // --------------------------------------------------------- //

    // Unit test
    test_step.dependOn(&zix_tests_run.step);

    // Integration tests
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
        // http2
        "tests/integration/http2/server_test.zig",
        // grpc
        "tests/integration/grpc/server_test.zig",
        // websocket
        "tests/integration/websocket/websocket_test.zig",
        // udp
        "tests/integration/udp/packet_test.zig",
        "tests/integration/udp/config_test.zig",
        // uds
        "tests/integration/uds/config_test.zig",
        // channel
        "tests/integration/channel/channel_test.zig",
        // logger
        "tests/integration/logger/logger_test.zig",
        // fix
        "tests/integration/fix/server_test.zig",
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

    // Behaviour tests
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
        // http2
        "tests/behaviour/http2/config_test.zig",
        // grpc
        "tests/behaviour/grpc/config_test.zig",
        // websocket
        "tests/behaviour/websocket/websocket_test.zig",
        // udp
        "tests/behaviour/udp/packet_test.zig",
        "tests/behaviour/udp/config_test.zig",
        // uds
        "tests/behaviour/uds/config_test.zig",
        // channel
        "tests/behaviour/channel/channel_test.zig",
        // logger
        "tests/behaviour/logger/logger_test.zig",
        // fix
        "tests/behaviour/fix/session_test.zig",
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

    // Edge tests
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
        // http2
        "tests/edge/http2/server_test.zig",
        // grpc
        "tests/edge/grpc/server_test.zig",
        // websocket
        "tests/edge/websocket/websocket_test.zig",
        // udp
        "tests/edge/udp/packet_test.zig",
        "tests/edge/udp/config_test.zig",
        // uds
        "tests/edge/uds/config_test.zig",
        // channel
        "tests/edge/channel/channel_test.zig",
        // logger
        "tests/edge/logger/logger_test.zig",
        // fix
        "tests/edge/fix/session_test.zig",
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

    // All tests — run tiers sequentially so zig build 0.16-dev IPC sends
    // ".exit" to each test binary before the next tier starts.
    behaviour_test_step.dependOn(integration_test_step);
    edge_test_step.dependOn(behaviour_test_step);

    const all_test_step = b.step("test-all", "Run unit, integration, behaviour, and edge tests");
    all_test_step.dependOn(&zix_tests_run.step);
    all_test_step.dependOn(integration_test_step);
    all_test_step.dependOn(behaviour_test_step);
    all_test_step.dependOn(edge_test_step);

    // --------------------------------------------------------- //

    // Examples
    const examples = .{
        .{ "example-tcp_server_1_async", "examples/tcp_server_1_async.zig" },
        .{ "example-tcp_server_2_pool", "examples/tcp_server_2_pool.zig" },
        .{ "example-tcp_server_3_mixed", "examples/tcp_server_3_mixed.zig" },
        .{ "example-tcp_server_4_epoll", "examples/tcp_server_4_epoll.zig" },
        .{ "example-tcp_client", "examples/tcp_client.zig" },
        .{ "example-http_basic_1_async", "examples/http_basic_1_async.zig" },
        .{ "example-http_basic_2_pool", "examples/http_basic_2_pool.zig" },
        .{ "example-http_basic_3_mixed", "examples/http_basic_3_mixed.zig" },
        .{ "example-http_basic_4_epoll", "examples/http_basic_4_epoll.zig" },
        .{ "example-http_client", "examples/http_client.zig" },
        .{ "example-http_json", "examples/http_json.zig" },
        .{ "example-http_manual_concurrent", "examples/http_manual_concurrent.zig" },
        .{ "example-http_middleware", "examples/http_middleware.zig" },
        .{ "example-http_params", "examples/http_params.zig" },
        .{ "example-http_paths", "examples/http_paths.zig" },
        .{ "example-http_static", "examples/http_static.zig" },
        .{ "example-http_timeout_resp", "examples/http_timeout_resp.zig" },
        .{ "example-http_sse", "examples/http_sse.zig" },
        .{ "example-http_websocket", "examples/http_websocket.zig" },
        .{ "example-http_xtra_headers", "examples/http_xtra_headers.zig" },
        .{ "example-fix_server_1_async", "examples/fix_server_1_async.zig" },
        .{ "example-fix_server_2_pool", "examples/fix_server_2_pool.zig" },
        .{ "example-fix_server_3_mixed", "examples/fix_server_3_mixed.zig" },
        .{ "example-fix_server_4_epoll", "examples/fix_server_4_epoll.zig" },
        .{ "example-fix_client", "examples/fix_client.zig" },
        .{ "example-fix_client_raw", "examples/fix_client_raw.zig" },
        .{ "example-fix_server_trading", "examples/fix_server_trading.zig" },
        .{ "example-fix_client_trading", "examples/fix_client_trading.zig" },
        .{ "example-udp_server", "examples/udp_server.zig" },
        .{ "example-udp_client", "examples/udp_client.zig" },
        .{ "example-uds_server", "examples/uds_server.zig" },
        .{ "example-uds_http", "examples/uds_http.zig" },
        .{ "example-channel_basic", "examples/channel_basic.zig" },
        .{ "example-channel_worker_pool", "examples/channel_worker_pool.zig" },
        .{ "example-channel_pipeline", "examples/channel_pipeline.zig" },
        .{ "example-channel_ipc_a", "examples/channel_ipc_a.zig" },
        .{ "example-channel_ipc_b", "examples/channel_ipc_b.zig" },
        .{ "example-grpc_server_1_async", "examples/grpc_server_1_async.zig" },
        .{ "example-grpc_server_2_pool", "examples/grpc_server_2_pool.zig" },
        .{ "example-grpc_server_3_mixed", "examples/grpc_server_3_mixed.zig" },
        .{ "example-grpc_client", "examples/grpc_client.zig" },
        .{ "example-grpc_location_server_1_async", "examples/grpc_location_server_1_async.zig" },
        .{ "example-grpc_location_server_2_pool", "examples/grpc_location_server_2_pool.zig" },
        .{ "example-grpc_location_server_3_mixed", "examples/grpc_location_server_3_mixed.zig" },
        .{ "example-grpc_location_server_4_epoll", "examples/grpc_location_server_4_epoll.zig" },
        .{ "example-grpc_location_client", "examples/grpc_location_client.zig" },
        .{ "example-grpc_server_4_epoll", "examples/grpc_server_4_epoll.zig" },
        .{ "example-grpc_timeout", "examples/grpc_timeout.zig" },
        .{ "example-grpc_multi_server", "examples/grpc_multi_server.zig" },
        .{ "example-grpc_multi_client", "examples/grpc_multi_client.zig" },
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
        const run_step = b.step(pair[0], "Run " ++ pair[0]);
        run_step.dependOn(&run.step);
    }

    // --------------------------------------------------------- //

    // Bug reproduction programs — not built by default.

    const bugs_0_2_x = .{
        .{ "bug-grpc_error_response_server", "rnd/bug-0.2.x/grpc_error_response_server.zig", "Bug 1: gRPC error response missing content-type" },
        .{ "bug-grpc_stream_concurrent_server", "rnd/bug-0.2.x/grpc_stream_concurrent_server.zig", "Bug 2: gRPC blocking dispatch under concurrent streams" },
    };

    // Reserved

    const bug_all_step = b.step("bug-all", "Build all bug reproduction programs");
    const bug_0_2_x_step = b.step("bug-0.2.x", "Build all 0.2.x bug reproduction programs");

    bug_all_step.dependOn(bug_0_2_x_step);

    inline for (bugs_0_2_x) |entry| {
        const bug_mod = b.createModule(.{
            .root_source_file = b.path(entry[1]),
            .target = target,
            .optimize = optimize,
        });
        bug_mod.addImport("zix", zix);

        const bug_exe = b.addExecutable(.{
            .name = entry[0],
            .root_module = bug_mod,
        });

        const bug_step = b.step(entry[0], entry[2]);
        bug_step.dependOn(&b.addInstallArtifact(bug_exe, .{}).step);
        bug_0_2_x_step.dependOn(bug_step);
    }
}
