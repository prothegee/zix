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
        // http1
        "tests/integration/http1/server_test.zig",
        "tests/integration/http1/router_test.zig",
        // http
        "tests/integration/http/request_test.zig",
        "tests/integration/http/router_test.zig",
        "tests/integration/http/context_test.zig",
        "tests/integration/http/header_index_test.zig",
        "tests/integration/http/sse_test.zig",
        "tests/integration/http/client_test.zig",
        "tests/integration/http/ws_client_test.zig",
        "tests/integration/http/sse_client_test.zig",
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
        // http1
        "tests/behaviour/http1/config_test.zig",
        "tests/behaviour/http1/core_test.zig",
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
        // http1
        "tests/edge/http1/core_test.zig",
        // http
        "tests/edge/http/request_test.zig",
        "tests/edge/http/router_test.zig",
        "tests/edge/http/response_test.zig",
        "tests/edge/http/content_test.zig",
        "tests/edge/http/client_test.zig",
        "tests/edge/http/ws_client_test.zig",
        "tests/edge/http/sse_client_test.zig",
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

    // All tests: run tiers sequentially so zig build 0.16 IPC sends
    // ".exit" to each test binary before the next tier starts.
    behaviour_test_step.dependOn(integration_test_step);
    edge_test_step.dependOn(behaviour_test_step);

    const all_test_step = b.step("test-all", "Run unit, integration, behaviour, and edge tests");
    all_test_step.dependOn(&zix_tests_run.step);
    all_test_step.dependOn(integration_test_step);
    all_test_step.dependOn(behaviour_test_step);
    all_test_step.dependOn(edge_test_step);

    // --------------------------------------------------------- //

    // Examples. Third field is the group tag, used to wire the per-category
    // build steps (example-tcp, example-http1, example-http, ...).
    const examples = .{
        .{ "example-tcp_server_1_async", "examples/tcp_server_1_async.zig", "tcp" },
        .{ "example-tcp_server_2_pool", "examples/tcp_server_2_pool.zig", "tcp" },
        .{ "example-tcp_server_3_mixed", "examples/tcp_server_3_mixed.zig", "tcp" },
        .{ "example-tcp_server_4_epoll", "examples/tcp_server_4_epoll.zig", "tcp" },
        .{ "example-tcp_client", "examples/tcp_client.zig", "tcp" },
        .{ "example-http1_basic_1_async", "examples/http1_basic_1_async.zig", "http1" },
        .{ "example-http1_basic_2_pool", "examples/http1_basic_2_pool.zig", "http1" },
        .{ "example-http1_basic_3_mixed", "examples/http1_basic_3_mixed.zig", "http1" },
        .{ "example-http1_basic_4_epoll", "examples/http1_basic_4_epoll.zig", "http1" },
        .{ "example-http1_json", "examples/http1_json.zig", "http1" },
        .{ "example-http1_middleware", "examples/http1_middleware.zig", "http1" },
        .{ "example-http1_params", "examples/http1_params.zig", "http1" },
        .{ "example-http1_paths", "examples/http1_paths.zig", "http1" },
        .{ "example-http1_static", "examples/http1_static.zig", "http1" },
        .{ "example-http1_manual_concurrent", "examples/http1_manual_concurrent.zig", "http1" },
        .{ "example-http1_sse", "examples/http1_sse.zig", "http1" },
        .{ "example-http1_xtra_headers", "examples/http1_xtra_headers.zig", "http1" },
        .{ "example-http1_client", "examples/http1_client.zig", "http1" },
        .{ "example-http1_timeout_resp", "examples/http1_timeout_resp.zig", "http1" },
        .{ "example-http1_websocket", "examples/http1_websocket.zig", "http1" },
        .{ "example-http_basic_1_async", "examples/http_basic_1_async.zig", "http" },
        .{ "example-http_basic_2_pool", "examples/http_basic_2_pool.zig", "http" },
        .{ "example-http_basic_3_mixed", "examples/http_basic_3_mixed.zig", "http" },
        .{ "example-http_basic_4_epoll", "examples/http_basic_4_epoll.zig", "http" },
        .{ "example-http_client", "examples/http_client.zig", "http" },
        .{ "example-http_json", "examples/http_json.zig", "http" },
        .{ "example-http_manual_concurrent", "examples/http_manual_concurrent.zig", "http" },
        .{ "example-http_middleware", "examples/http_middleware.zig", "http" },
        .{ "example-http_params", "examples/http_params.zig", "http" },
        .{ "example-http_paths", "examples/http_paths.zig", "http" },
        .{ "example-http_static", "examples/http_static.zig", "http" },
        .{ "example-http_timeout_resp", "examples/http_timeout_resp.zig", "http" },
        .{ "example-http_sse", "examples/http_sse.zig", "http" },
        .{ "example-http_sse_client", "examples/http_sse_client.zig", "http" },
        .{ "example-http_websocket", "examples/http_websocket.zig", "http" },
        .{ "example-http_ws_client", "examples/http_ws_client.zig", "http" },
        .{ "example-http_uds_client", "examples/http_uds_client.zig", "http" },
        .{ "example-http_xtra_headers", "examples/http_xtra_headers.zig", "http" },
        .{ "example-fix_server_1_async", "examples/fix_server_1_async.zig", "fix" },
        .{ "example-fix_server_2_pool", "examples/fix_server_2_pool.zig", "fix" },
        .{ "example-fix_server_3_mixed", "examples/fix_server_3_mixed.zig", "fix" },
        .{ "example-fix_server_4_epoll", "examples/fix_server_4_epoll.zig", "fix" },
        .{ "example-fix_client", "examples/fix_client.zig", "fix" },
        .{ "example-fix_client_raw", "examples/fix_client_raw.zig", "fix" },
        .{ "example-fix_server_trading", "examples/fix_server_trading.zig", "fix" },
        .{ "example-fix_client_trading", "examples/fix_client_trading.zig", "fix" },
        .{ "example-udp_server", "examples/udp_server.zig", "udp" },
        .{ "example-udp_client", "examples/udp_client.zig", "udp" },
        .{ "example-uds_server", "examples/uds_server.zig", "uds" },
        .{ "example-uds_client", "examples/uds_client.zig", "uds" },
        .{ "example-uds_http", "examples/uds_http.zig", "uds" },
        .{ "example-channel_basic", "examples/channel_basic.zig", "channel" },
        .{ "example-channel_worker_pool", "examples/channel_worker_pool.zig", "channel" },
        .{ "example-channel_pipeline", "examples/channel_pipeline.zig", "channel" },
        .{ "example-channel_ipc_a", "examples/channel_ipc_a.zig", "channel" },
        .{ "example-channel_ipc_b", "examples/channel_ipc_b.zig", "channel" },
        .{ "example-grpc_server_1_async", "examples/grpc_server_1_async.zig", "grpc" },
        .{ "example-grpc_server_2_pool", "examples/grpc_server_2_pool.zig", "grpc" },
        .{ "example-grpc_server_3_mixed", "examples/grpc_server_3_mixed.zig", "grpc" },
        .{ "example-grpc_client", "examples/grpc_client.zig", "grpc" },
        .{ "example-grpc_location_server_1_async", "examples/grpc_location_server_1_async.zig", "grpc" },
        .{ "example-grpc_location_server_2_pool", "examples/grpc_location_server_2_pool.zig", "grpc" },
        .{ "example-grpc_location_server_3_mixed", "examples/grpc_location_server_3_mixed.zig", "grpc" },
        .{ "example-grpc_location_server_4_epoll", "examples/grpc_location_server_4_epoll.zig", "grpc" },
        .{ "example-grpc_location_client", "examples/grpc_location_client.zig", "grpc" },
        .{ "example-grpc_server_4_epoll", "examples/grpc_server_4_epoll.zig", "grpc" },
        .{ "example-grpc_timeout", "examples/grpc_timeout.zig", "grpc" },
        .{ "example-grpc_multi_server", "examples/grpc_multi_server.zig", "grpc" },
        .{ "example-grpc_multi_client", "examples/grpc_multi_client.zig", "grpc" },
    };

    // Examples are not built by default. `zig build examples` builds them all,
    // `zig build example-<group>` builds one category, `zig build example-<name>`
    // builds and runs a single one.
    const examples_step = b.step("examples", "Build all examples");

    const group_tcp = b.step("example-tcp", "Build all tcp examples");
    const group_http1 = b.step("example-http1", "Build all http1 examples");
    const group_http = b.step("example-http", "Build all http examples");
    const group_fix = b.step("example-fix", "Build all fix examples");
    const group_grpc = b.step("example-grpc", "Build all grpc examples");
    const group_channel = b.step("example-channel", "Build all channel examples");
    const group_udp = b.step("example-udp", "Build all udp examples");
    const group_uds = b.step("example-uds", "Build all uds examples");

    examples_step.dependOn(group_tcp);
    examples_step.dependOn(group_http1);
    examples_step.dependOn(group_http);
    examples_step.dependOn(group_fix);
    examples_step.dependOn(group_grpc);
    examples_step.dependOn(group_channel);
    examples_step.dependOn(group_udp);
    examples_step.dependOn(group_uds);

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

        const group = if (comptime std.mem.eql(u8, pair[2], "tcp"))
            group_tcp
        else if (comptime std.mem.eql(u8, pair[2], "http1"))
            group_http1
        else if (comptime std.mem.eql(u8, pair[2], "http"))
            group_http
        else if (comptime std.mem.eql(u8, pair[2], "fix"))
            group_fix
        else if (comptime std.mem.eql(u8, pair[2], "grpc"))
            group_grpc
        else if (comptime std.mem.eql(u8, pair[2], "channel"))
            group_channel
        else if (comptime std.mem.eql(u8, pair[2], "udp"))
            group_udp
        else if (comptime std.mem.eql(u8, pair[2], "uds"))
            group_uds
        else
            @compileError("unknown example group tag: " ++ pair[2]);

        group.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run = b.addRunArtifact(exe);
        const run_step = b.step(pair[0], "Run " ++ pair[0]);
        run_step.dependOn(&run.step);
    }

    // --------------------------------------------------------- //

    // Bug reproduction programs - not built by default.

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
