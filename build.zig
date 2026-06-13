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

    // --------------------------------------------------------- //

    // Test runners. Each spawns a server example as a child process and exercises
    // the protocol through the zix client. Steps are independent of each other and
    // are not part of test-all.
    //
    // Basic dispatch-model runners:
    // zig build test-runner-http-async / pool / mixed / epoll
    // zig build test-runner-http1-async / pool / mixed / epoll
    // zig build test-runner-grpc-async / pool / mixed / epoll
    // zig build test-runner-tcp-async / pool / mixed / epoll
    // zig build test-runner-fix-async / pool / mixed / epoll
    // zig build test-runner-udp
    // zig build test-runner-uds
    //
    // HTTP feature runners:
    // zig build test-runner-http-json / middleware / params / paths / manual-concurrent
    // zig build test-runner-http-static / sse / websocket / timeout-resp / xtra-headers
    // zig build test-runner-http1-json / middleware / params / paths / manual-concurrent
    // zig build test-runner-http1-static / sse / websocket / timeout-resp / xtra-headers
    //
    // gRPC feature runners:
    // zig build test-runner-grpc-location-async / pool / mixed / epoll
    // zig build test-runner-grpc-multi
    // zig build test-runner-grpc-timeout
    //
    // FIX feature runner:
    // zig build test-runner-fix-trading
    //
    // UDS HTTP runner (two servers):
    // zig build test-runner-uds-http
    //
    // Channel runners:
    // zig build test-runner-channel-basic / pipeline / worker-pool
    // zig build test-runner-channel-ipc   (two processes)
    //
    // zig build test-runner-all

    // Helper: build a server exe for use by a runner (not installed to zig-out/bin/).
    // Named with "tr-" prefix to avoid step-name collisions with the examples loop.
    //
    // Columns: step-name, runner-src, server-exe-name, server-src, port, arg4, arg5, arg6.
    // argv[1] = server binary path (FileArg)
    // argv[2] = label (step-name stripped of "test-runner-" prefix)
    // argv[3] = port (row[4])
    // argv[4] = row[5] (route, filename, or ws-route for parameterized runners)
    // argv[5] = row[6] (origin or file content for parameterized runners)
    // argv[6] = row[7] (expected substring for http_get_runner)
    //
    // Runners that do not use the extra argv simply ignore them.
    const runner_table = .{
        // basic dispatch-model runners
        .{ "test-runner-http-async", "tests/runner/http_runner.zig", "tr-server-http-async", "examples/http_basic_1_async.zig", "9100", "", "", "" },
        .{ "test-runner-http-pool", "tests/runner/http_runner.zig", "tr-server-http-pool", "examples/http_basic_2_pool.zig", "9100", "", "", "" },
        .{ "test-runner-http-mixed", "tests/runner/http_runner.zig", "tr-server-http-mixed", "examples/http_basic_3_mixed.zig", "9100", "", "", "" },
        .{ "test-runner-http-epoll", "tests/runner/http_runner.zig", "tr-server-http-epoll", "examples/http_basic_4_epoll.zig", "9100", "", "", "" },
        .{ "test-runner-http1-async", "tests/runner/http1_runner.zig", "tr-server-http1-async", "examples/http1_basic_1_async.zig", "9100", "", "", "" },
        .{ "test-runner-http1-pool", "tests/runner/http1_runner.zig", "tr-server-http1-pool", "examples/http1_basic_2_pool.zig", "9100", "", "", "" },
        .{ "test-runner-http1-mixed", "tests/runner/http1_runner.zig", "tr-server-http1-mixed", "examples/http1_basic_3_mixed.zig", "9100", "", "", "" },
        .{ "test-runner-http1-epoll", "tests/runner/http1_runner.zig", "tr-server-http1-epoll", "examples/http1_basic_4_epoll.zig", "9100", "", "", "" },
        .{ "test-runner-grpc-async", "tests/runner/grpc_runner.zig", "tr-server-grpc-async", "examples/grpc_server_1_async.zig", "8083", "", "", "" },
        .{ "test-runner-grpc-pool", "tests/runner/grpc_runner.zig", "tr-server-grpc-pool", "examples/grpc_server_2_pool.zig", "8083", "", "", "" },
        .{ "test-runner-grpc-mixed", "tests/runner/grpc_runner.zig", "tr-server-grpc-mixed", "examples/grpc_server_3_mixed.zig", "8083", "", "", "" },
        .{ "test-runner-grpc-epoll", "tests/runner/grpc_runner.zig", "tr-server-grpc-epoll", "examples/grpc_server_4_epoll.zig", "8083", "", "", "" },
        .{ "test-runner-tcp-async", "tests/runner/tcp_runner.zig", "tr-server-tcp-async", "examples/tcp_server_1_async.zig", "9300", "", "", "" },
        .{ "test-runner-tcp-pool", "tests/runner/tcp_runner.zig", "tr-server-tcp-pool", "examples/tcp_server_2_pool.zig", "9301", "", "", "" },
        .{ "test-runner-tcp-mixed", "tests/runner/tcp_runner.zig", "tr-server-tcp-mixed", "examples/tcp_server_3_mixed.zig", "9302", "", "", "" },
        .{ "test-runner-tcp-epoll", "tests/runner/tcp_runner.zig", "tr-server-tcp-epoll", "examples/tcp_server_4_epoll.zig", "9303", "", "", "" },
        .{ "test-runner-fix-async", "tests/runner/fix_runner.zig", "tr-server-fix-async", "examples/fix_server_1_async.zig", "9500", "", "", "" },
        .{ "test-runner-fix-pool", "tests/runner/fix_runner.zig", "tr-server-fix-pool", "examples/fix_server_2_pool.zig", "9500", "", "", "" },
        .{ "test-runner-fix-mixed", "tests/runner/fix_runner.zig", "tr-server-fix-mixed", "examples/fix_server_3_mixed.zig", "9500", "", "", "" },
        .{ "test-runner-fix-epoll", "tests/runner/fix_runner.zig", "tr-server-fix-epoll", "examples/fix_server_4_epoll.zig", "9500", "", "", "" },
        .{ "test-runner-udp", "tests/runner/udp_runner.zig", "tr-server-udp", "examples/udp_server.zig", "9100", "", "", "" },
        .{ "test-runner-uds", "tests/runner/uds_runner.zig", "tr-server-uds", "examples/uds_server.zig", "0", "", "", "" },
        // http feature runners (http_get_runner: arg4=route, arg5=origin, arg6=expected)
        .{ "test-runner-http-json", "tests/runner/http_get_runner.zig", "tr-server-http-json", "examples/http_json.zig", "9001", "/status", "", "server" },
        .{ "test-runner-http-middleware", "tests/runner/http_get_runner.zig", "tr-server-http-middleware", "examples/http_middleware.zig", "9003", "/public", "http://127.0.0.1", "public" },
        .{ "test-runner-http-params", "tests/runner/http_get_runner.zig", "tr-server-http-params", "examples/http_params.zig", "9004", "/echo?foo=bar", "", "foo" },
        .{ "test-runner-http-paths", "tests/runner/http_get_runner.zig", "tr-server-http-paths", "examples/http_paths.zig", "9005", "/path", "", "" },
        .{ "test-runner-http-timeout-resp", "tests/runner/http_get_runner.zig", "tr-server-http-timeout-resp", "examples/http_timeout_resp.zig", "9007", "/ping", "", "pong" },
        .{ "test-runner-http-xtra-headers", "tests/runner/http_get_runner.zig", "tr-server-http-xtra-headers", "examples/http_xtra_headers.zig", "9009", "/info", "", "" },
        .{ "test-runner-http-manual-concurrent", "tests/runner/http_get_runner.zig", "tr-server-http-manual-concurrent", "examples/http_manual_concurrent.zig", "9002", "/", "", "hello" },
        // http static runners (arg4=filename, arg5=file content)
        .{ "test-runner-http-static", "tests/runner/http_static_runner.zig", "tr-server-http-static", "examples/http_static.zig", "9006", "http_text_file.txt", "this is http text file example.", "" },
        // http sse runners
        .{ "test-runner-http-sse", "tests/runner/sse_runner.zig", "tr-server-http-sse", "examples/http_sse.zig", "9010", "", "", "" },
        // http websocket runners (arg4=ws route)
        .{ "test-runner-http-websocket", "tests/runner/ws_runner.zig", "tr-server-http-websocket", "examples/http_websocket.zig", "9008", "/ws/lobby", "", "" },
        // http1 feature runners
        .{ "test-runner-http1-json", "tests/runner/http_get_runner.zig", "tr-server-http1-json", "examples/http1_json.zig", "9101", "/status", "", "server" },
        .{ "test-runner-http1-middleware", "tests/runner/http_get_runner.zig", "tr-server-http1-middleware", "examples/http1_middleware.zig", "9103", "/public", "http://127.0.0.1", "public" },
        .{ "test-runner-http1-params", "tests/runner/http_get_runner.zig", "tr-server-http1-params", "examples/http1_params.zig", "9104", "/echo?foo=bar", "", "foo" },
        .{ "test-runner-http1-paths", "tests/runner/http_get_runner.zig", "tr-server-http1-paths", "examples/http1_paths.zig", "9105", "/path", "", "" },
        .{ "test-runner-http1-timeout-resp", "tests/runner/http_get_runner.zig", "tr-server-http1-timeout-resp", "examples/http1_timeout_resp.zig", "9110", "/ping", "", "pong" },
        .{ "test-runner-http1-xtra-headers", "tests/runner/http_get_runner.zig", "tr-server-http1-xtra-headers", "examples/http1_xtra_headers.zig", "9109", "/info", "", "" },
        .{ "test-runner-http1-manual-concurrent", "tests/runner/http_get_runner.zig", "tr-server-http1-manual-concurrent", "examples/http1_manual_concurrent.zig", "9107", "/", "", "hello" },
        // http1 static runner
        .{ "test-runner-http1-static", "tests/runner/http_static_runner.zig", "tr-server-http1-static", "examples/http1_static.zig", "9106", "http1_text_file.txt", "this is http1 text file example.", "" },
        // http1 sse runner
        .{ "test-runner-http1-sse", "tests/runner/sse_runner.zig", "tr-server-http1-sse", "examples/http1_sse.zig", "9108", "", "", "" },
        // http1 websocket runner
        .{ "test-runner-http1-websocket", "tests/runner/ws_runner.zig", "tr-server-http1-websocket", "examples/http1_websocket.zig", "9111", "/ws", "", "" },
        // grpc location runners
        .{ "test-runner-grpc-location-async", "tests/runner/grpc_location_runner.zig", "tr-server-grpc-location-async", "examples/grpc_location_server_1_async.zig", "10101", "", "", "" },
        .{ "test-runner-grpc-location-pool", "tests/runner/grpc_location_runner.zig", "tr-server-grpc-location-pool", "examples/grpc_location_server_2_pool.zig", "10101", "", "", "" },
        .{ "test-runner-grpc-location-mixed", "tests/runner/grpc_location_runner.zig", "tr-server-grpc-location-mixed", "examples/grpc_location_server_3_mixed.zig", "10101", "", "", "" },
        .{ "test-runner-grpc-location-epoll", "tests/runner/grpc_location_runner.zig", "tr-server-grpc-location-epoll", "examples/grpc_location_server_4_epoll.zig", "10101", "", "", "" },
        // grpc multi and timeout runners
        .{ "test-runner-grpc-multi", "tests/runner/grpc_multi_runner.zig", "tr-server-grpc-multi", "examples/grpc_multi_server.zig", "10102", "", "", "" },
        .{ "test-runner-grpc-timeout", "tests/runner/grpc_timeout_runner.zig", "tr-server-grpc-timeout", "examples/grpc_timeout.zig", "8084", "", "", "" },
        // fix trading runner
        .{ "test-runner-fix-trading", "tests/runner/fix_trading_runner.zig", "tr-server-fix-trading", "examples/fix_server_trading.zig", "9500", "", "", "" },
        // channel self-terminating runners
        .{ "test-runner-channel-basic", "tests/runner/channel_selfterm_runner.zig", "tr-server-channel-basic", "examples/channel_basic.zig", "0", "", "", "" },
        .{ "test-runner-channel-pipeline", "tests/runner/channel_selfterm_runner.zig", "tr-server-channel-pipeline", "examples/channel_pipeline.zig", "0", "", "", "" },
        .{ "test-runner-channel-worker-pool", "tests/runner/channel_selfterm_runner.zig", "tr-server-channel-worker-pool", "examples/channel_worker_pool.zig", "0", "", "", "" },
    };

    inline for (runner_table) |row| {
        const server_mod = b.createModule(.{
            .root_source_file = b.path(row[3]),
            .target = target,
            .optimize = optimize,
        });
        server_mod.addImport("zix", zix);
        const server_exe = b.addExecutable(.{
            .name = row[2],
            .root_module = server_mod,
        });

        const runner_mod = b.createModule(.{
            .root_source_file = b.path(row[1]),
            .target = target,
            .optimize = optimize,
        });
        runner_mod.addImport("zix", zix);
        const runner_exe = b.addExecutable(.{
            .name = row[0],
            .root_module = runner_mod,
        });

        const run_runner = b.addRunArtifact(runner_exe);
        run_runner.addFileArg(server_exe.getEmittedBin()); // argv[1]: server path
        run_runner.addArg(row[0][comptime "test-runner-".len..]); // argv[2]: label
        run_runner.addArg(row[4]); // argv[3]: port
        run_runner.addArg(row[5]); // argv[4]: extra (route, filename, ws-route)
        run_runner.addArg(row[6]); // argv[5]: extra (origin, file content)
        run_runner.addArg(row[7]); // argv[6]: extra (expected substr)

        const runner_step = b.step(row[0], "Run " ++ row[0]);
        runner_step.dependOn(&run_runner.step);
    }

    // test-runner-uds-http: two server processes.
    // argv[1]=uds_server, argv[2]=uds_http, argv[3]=label.
    {
        const uds_srv_mod = b.createModule(.{
            .root_source_file = b.path("examples/uds_server.zig"),
            .target = target,
            .optimize = optimize,
        });
        uds_srv_mod.addImport("zix", zix);
        const uds_srv_exe = b.addExecutable(.{ .name = "tr-server-uds-http-a", .root_module = uds_srv_mod });

        const uds_http_mod = b.createModule(.{
            .root_source_file = b.path("examples/uds_http.zig"),
            .target = target,
            .optimize = optimize,
        });
        uds_http_mod.addImport("zix", zix);
        const uds_http_exe = b.addExecutable(.{ .name = "tr-server-uds-http-b", .root_module = uds_http_mod });

        const uds_http_runner_mod = b.createModule(.{
            .root_source_file = b.path("tests/runner/uds_http_runner.zig"),
            .target = target,
            .optimize = optimize,
        });
        uds_http_runner_mod.addImport("zix", zix);
        const uds_http_runner_exe = b.addExecutable(.{ .name = "test-runner-uds-http", .root_module = uds_http_runner_mod });

        const run_uds_http = b.addRunArtifact(uds_http_runner_exe);
        run_uds_http.addFileArg(uds_srv_exe.getEmittedBin()); // argv[1]: uds_server path
        run_uds_http.addFileArg(uds_http_exe.getEmittedBin()); // argv[2]: uds_http path
        run_uds_http.addArg("uds-http"); // argv[3]: label

        const uds_http_step = b.step("test-runner-uds-http", "Run test-runner-uds-http");
        uds_http_step.dependOn(&run_uds_http.step);
    }

    // test-runner-channel-ipc: two processes (ipc_a + ipc_b).
    // argv[1]=ipc_a, argv[2]=ipc_b, argv[3]=label.
    {
        const ipc_a_mod = b.createModule(.{
            .root_source_file = b.path("examples/channel_ipc_a.zig"),
            .target = target,
            .optimize = optimize,
        });
        ipc_a_mod.addImport("zix", zix);
        const ipc_a_exe = b.addExecutable(.{ .name = "tr-server-channel-ipc-a", .root_module = ipc_a_mod });

        const ipc_b_mod = b.createModule(.{
            .root_source_file = b.path("examples/channel_ipc_b.zig"),
            .target = target,
            .optimize = optimize,
        });
        ipc_b_mod.addImport("zix", zix);
        const ipc_b_exe = b.addExecutable(.{ .name = "tr-server-channel-ipc-b", .root_module = ipc_b_mod });

        const ipc_runner_mod = b.createModule(.{
            .root_source_file = b.path("tests/runner/channel_ipc_runner.zig"),
            .target = target,
            .optimize = optimize,
        });
        ipc_runner_mod.addImport("zix", zix);
        const ipc_runner_exe = b.addExecutable(.{ .name = "test-runner-channel-ipc", .root_module = ipc_runner_mod });

        const run_ipc = b.addRunArtifact(ipc_runner_exe);
        run_ipc.addFileArg(ipc_a_exe.getEmittedBin()); // argv[1]: ipc_a path
        run_ipc.addFileArg(ipc_b_exe.getEmittedBin()); // argv[2]: ipc_b path
        run_ipc.addArg("channel-ipc"); // argv[3]: label

        const ipc_step = b.step("test-runner-channel-ipc", "Run test-runner-channel-ipc");
        ipc_step.dependOn(&run_ipc.step);
    }

    // test-runner-all: one binary, all 56 server paths as argv.
    // Independent of the individual test-runner-* steps above.
    // argv order matches the path declarations in all_runner.zig.
    {
        const all_server_srcs = .{
            // basic dispatch-model servers (22)
            .{ "tr-all-server-http-async", "examples/http_basic_1_async.zig" },
            .{ "tr-all-server-http-pool", "examples/http_basic_2_pool.zig" },
            .{ "tr-all-server-http-mixed", "examples/http_basic_3_mixed.zig" },
            .{ "tr-all-server-http-epoll", "examples/http_basic_4_epoll.zig" },
            .{ "tr-all-server-http1-async", "examples/http1_basic_1_async.zig" },
            .{ "tr-all-server-http1-pool", "examples/http1_basic_2_pool.zig" },
            .{ "tr-all-server-http1-mixed", "examples/http1_basic_3_mixed.zig" },
            .{ "tr-all-server-http1-epoll", "examples/http1_basic_4_epoll.zig" },
            .{ "tr-all-server-grpc-async", "examples/grpc_server_1_async.zig" },
            .{ "tr-all-server-grpc-pool", "examples/grpc_server_2_pool.zig" },
            .{ "tr-all-server-grpc-mixed", "examples/grpc_server_3_mixed.zig" },
            .{ "tr-all-server-grpc-epoll", "examples/grpc_server_4_epoll.zig" },
            .{ "tr-all-server-tcp-async", "examples/tcp_server_1_async.zig" },
            .{ "tr-all-server-tcp-pool", "examples/tcp_server_2_pool.zig" },
            .{ "tr-all-server-tcp-mixed", "examples/tcp_server_3_mixed.zig" },
            .{ "tr-all-server-tcp-epoll", "examples/tcp_server_4_epoll.zig" },
            .{ "tr-all-server-fix-async", "examples/fix_server_1_async.zig" },
            .{ "tr-all-server-fix-pool", "examples/fix_server_2_pool.zig" },
            .{ "tr-all-server-fix-mixed", "examples/fix_server_3_mixed.zig" },
            .{ "tr-all-server-fix-epoll", "examples/fix_server_4_epoll.zig" },
            .{ "tr-all-server-udp", "examples/udp_server.zig" },
            .{ "tr-all-server-uds", "examples/uds_server.zig" },
            // http feature servers (10)
            .{ "tr-all-server-http-json", "examples/http_json.zig" },
            .{ "tr-all-server-http-middleware", "examples/http_middleware.zig" },
            .{ "tr-all-server-http-params", "examples/http_params.zig" },
            .{ "tr-all-server-http-paths", "examples/http_paths.zig" },
            .{ "tr-all-server-http-timeout-resp", "examples/http_timeout_resp.zig" },
            .{ "tr-all-server-http-xtra-headers", "examples/http_xtra_headers.zig" },
            .{ "tr-all-server-http-manual-concurrent", "examples/http_manual_concurrent.zig" },
            .{ "tr-all-server-http-static", "examples/http_static.zig" },
            .{ "tr-all-server-http-sse", "examples/http_sse.zig" },
            .{ "tr-all-server-http-websocket", "examples/http_websocket.zig" },
            // http1 feature servers (10)
            .{ "tr-all-server-http1-json", "examples/http1_json.zig" },
            .{ "tr-all-server-http1-middleware", "examples/http1_middleware.zig" },
            .{ "tr-all-server-http1-params", "examples/http1_params.zig" },
            .{ "tr-all-server-http1-paths", "examples/http1_paths.zig" },
            .{ "tr-all-server-http1-timeout-resp", "examples/http1_timeout_resp.zig" },
            .{ "tr-all-server-http1-xtra-headers", "examples/http1_xtra_headers.zig" },
            .{ "tr-all-server-http1-manual-concurrent", "examples/http1_manual_concurrent.zig" },
            .{ "tr-all-server-http1-static", "examples/http1_static.zig" },
            .{ "tr-all-server-http1-sse", "examples/http1_sse.zig" },
            .{ "tr-all-server-http1-websocket", "examples/http1_websocket.zig" },
            // grpc location + multi + timeout (6)
            .{ "tr-all-server-grpc-location-async", "examples/grpc_location_server_1_async.zig" },
            .{ "tr-all-server-grpc-location-pool", "examples/grpc_location_server_2_pool.zig" },
            .{ "tr-all-server-grpc-location-mixed", "examples/grpc_location_server_3_mixed.zig" },
            .{ "tr-all-server-grpc-location-epoll", "examples/grpc_location_server_4_epoll.zig" },
            .{ "tr-all-server-grpc-multi", "examples/grpc_multi_server.zig" },
            .{ "tr-all-server-grpc-timeout", "examples/grpc_timeout.zig" },
            // fix trading (1)
            .{ "tr-all-server-fix-trading", "examples/fix_server_trading.zig" },
            // uds-http pair (2 paths for one test)
            .{ "tr-all-server-uds-http-a", "examples/uds_server.zig" },
            .{ "tr-all-server-uds-http-b", "examples/uds_http.zig" },
            // channel self-terminating (3)
            .{ "tr-all-server-channel-basic", "examples/channel_basic.zig" },
            .{ "tr-all-server-channel-pipeline", "examples/channel_pipeline.zig" },
            .{ "tr-all-server-channel-worker-pool", "examples/channel_worker_pool.zig" },
            // channel ipc pair (2 paths for one test)
            .{ "tr-all-server-channel-ipc-a", "examples/channel_ipc_a.zig" },
            .{ "tr-all-server-channel-ipc-b", "examples/channel_ipc_b.zig" },
        };

        const all_runner_mod = b.createModule(.{
            .root_source_file = b.path("tests/runner/all_runner.zig"),
            .target = target,
            .optimize = optimize,
        });
        all_runner_mod.addImport("zix", zix);
        const all_runner_exe = b.addExecutable(.{
            .name = "test-runner-all",
            .root_module = all_runner_mod,
        });

        const run_all = b.addRunArtifact(all_runner_exe);
        inline for (all_server_srcs) |srv| {
            const srv_mod = b.createModule(.{
                .root_source_file = b.path(srv[1]),
                .target = target,
                .optimize = optimize,
            });
            srv_mod.addImport("zix", zix);
            const srv_exe = b.addExecutable(.{
                .name = srv[0],
                .root_module = srv_mod,
            });
            run_all.addFileArg(srv_exe.getEmittedBin());
        }

        const all_step = b.step("test-runner-all", "Run test-runner-all");
        all_step.dependOn(&run_all.step);
    }
}
