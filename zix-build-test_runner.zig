const std = @import("std");

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zix: *std.Build.Module,
) void {
    // Each runner spawns a server as a child process and exercises the protocol via the
    // zix client. Steps are independent and not part of test-all (see zig build --help).
    //
    // Row: { step-name, runner-src, server-exe-name, server-src, port, arg4, arg5, arg6 }
    // argv[1]: server binary (FileArg). argv[2]: label. argv[3]: port.
    // argv[4]: route/filename/ws-route. argv[5]: origin/file-content. argv[6]: expected substr.
    // Unused argv are passed as empty string and ignored by the runner.
    const runner_table = .{
        // basic dispatch-model runners
        .{ "test-runner-http-async", "tests/runner/http_runner.zig", "tr-server-http-async", "examples/http_basic_1_async.zig", "9000", "", "", "" },
        .{ "test-runner-http-pool", "tests/runner/http_runner.zig", "tr-server-http-pool", "examples/http_basic_2_pool.zig", "9001", "", "", "" },
        .{ "test-runner-http-mixed", "tests/runner/http_runner.zig", "tr-server-http-mixed", "examples/http_basic_3_mixed.zig", "9002", "", "", "" },
        .{ "test-runner-http-epoll", "tests/runner/http_runner.zig", "tr-server-http-epoll", "examples/http_basic_4_epoll.zig", "9003", "", "", "" },
        .{ "test-runner-http-uring", "tests/runner/http_runner.zig", "tr-server-http-uring", "examples/http_basic_5_uring.zig", "9004", "", "", "" },
        .{ "test-runner-http1-async", "tests/runner/http1_runner.zig", "tr-server-http1-async", "examples/http1_basic_1_async.zig", "9015", "", "", "" },
        .{ "test-runner-http1-pool", "tests/runner/http1_runner.zig", "tr-server-http1-pool", "examples/http1_basic_2_pool.zig", "9016", "", "", "" },
        .{ "test-runner-http1-mixed", "tests/runner/http1_runner.zig", "tr-server-http1-mixed", "examples/http1_basic_3_mixed.zig", "9017", "", "", "" },
        .{ "test-runner-http1-epoll", "tests/runner/http1_runner.zig", "tr-server-http1-epoll", "examples/http1_basic_4_epoll.zig", "9018", "", "", "" },
        .{ "test-runner-http1-uring", "tests/runner/http1_runner.zig", "tr-server-http1-uring", "examples/http1_basic_5_uring.zig", "9019", "", "", "" },
        .{ "test-runner-http1-compression", "tests/runner/http1_compression_runner.zig", "tr-server-http1-compression", "examples/http1_compression.zig", "9058", "", "", "" },
        .{ "test-runner-http-compression", "tests/runner/http1_compression_runner.zig", "tr-server-http-compression", "examples/http_compression.zig", "9059", "", "", "" },
        .{ "test-runner-tls-http1", "tests/runner/tls_http1_basic_runner.zig", "tr-server-tls-http1", "examples/tls/tls_http1_basic.zig", "9060", "", "", "" },
        .{ "test-runner-tls-http1-ed25519", "tests/runner/tls_http1_ed25519_runner.zig", "tr-server-tls-http1-ed25519", "examples/tls/tls_http1_ed25519.zig", "9062", "", "", "" },
        .{ "test-runner-tls-http2", "tests/runner/tls_http2_basic_runner.zig", "tr-server-tls-http2", "examples/tls/tls_http2_basic.zig", "9061", "", "", "" },
        .{ "test-runner-tls-http2-client", "tests/runner/tls_http2_client_runner.zig", "tr-server-tls-http2-client", "examples/tls/tls_http2_basic.zig", "9061", "", "", "" },
        .{ "test-runner-grpc-async", "tests/runner/grpc_runner.zig", "tr-server-grpc-async", "examples/grpc_server_1_async.zig", "9032", "", "", "" },
        .{ "test-runner-grpc-pool", "tests/runner/grpc_runner.zig", "tr-server-grpc-pool", "examples/grpc_server_2_pool.zig", "9033", "", "", "" },
        .{ "test-runner-grpc-mixed", "tests/runner/grpc_runner.zig", "tr-server-grpc-mixed", "examples/grpc_server_3_mixed.zig", "9034", "", "", "" },
        .{ "test-runner-grpc-epoll", "tests/runner/grpc_runner.zig", "tr-server-grpc-epoll", "examples/grpc_server_4_epoll.zig", "9035", "", "", "" },
        .{ "test-runner-grpc-uring", "tests/runner/grpc_runner.zig", "tr-server-grpc-uring", "examples/grpc_server_5_uring.zig", "9036", "", "", "" },
        .{ "test-runner-grpc-stream-uring", "tests/runner/grpc_stream_runner.zig", "tr-server-grpc-stream-uring", "examples/grpc_server_5_uring.zig", "9036", "", "", "" },
        .{ "test-runner-tcp-async", "tests/runner/tcp_runner.zig", "tr-server-tcp-async", "examples/tcp_server_1_async.zig", "9043", "", "", "" },
        .{ "test-runner-tcp-pool", "tests/runner/tcp_runner.zig", "tr-server-tcp-pool", "examples/tcp_server_2_pool.zig", "9044", "", "", "" },
        .{ "test-runner-tcp-mixed", "tests/runner/tcp_runner.zig", "tr-server-tcp-mixed", "examples/tcp_server_3_mixed.zig", "9045", "", "", "" },
        .{ "test-runner-tcp-epoll", "tests/runner/tcp_runner.zig", "tr-server-tcp-epoll", "examples/tcp_server_4_epoll.zig", "9046", "", "", "" },
        .{ "test-runner-tcp-uring", "tests/runner/tcp_runner.zig", "tr-server-tcp-uring", "examples/tcp_server_5_uring.zig", "9047", "", "", "" },
        .{ "test-runner-fix-async", "tests/runner/fix_runner.zig", "tr-server-fix-async", "examples/fix_server_1_async.zig", "9048", "", "", "" },
        .{ "test-runner-fix-pool", "tests/runner/fix_runner.zig", "tr-server-fix-pool", "examples/fix_server_2_pool.zig", "9049", "", "", "" },
        .{ "test-runner-fix-mixed", "tests/runner/fix_runner.zig", "tr-server-fix-mixed", "examples/fix_server_3_mixed.zig", "9050", "", "", "" },
        .{ "test-runner-fix-epoll", "tests/runner/fix_runner.zig", "tr-server-fix-epoll", "examples/fix_server_4_epoll.zig", "9051", "", "", "" },
        .{ "test-runner-fix-uring", "tests/runner/fix_runner.zig", "tr-server-fix-uring", "examples/fix_server_5_uring.zig", "9052", "", "", "" },
        .{ "test-runner-udp", "tests/runner/udp_runner.zig", "tr-server-udp", "examples/udp_server.zig", "9054", "", "", "" },
        .{ "test-runner-udp-raw", "tests/runner/udp_raw_runner.zig", "tr-server-udp-raw", "examples/udp_raw_echo.zig", "9064", "", "", "" },
        .{ "test-runner-uds", "tests/runner/uds_runner.zig", "tr-server-uds", "examples/uds_server.zig", "0", "", "", "" },
        // http feature runners (http_get_runner: arg4=route, arg5=origin, arg6=expected)
        .{ "test-runner-http-json", "tests/runner/http_get_runner.zig", "tr-server-http-json", "examples/http_json.zig", "9005", "/status", "", "server" },
        .{ "test-runner-http-middleware", "tests/runner/http_get_runner.zig", "tr-server-http-middleware", "examples/http_middleware.zig", "9006", "/public", "http://127.0.0.1", "public" },
        .{ "test-runner-http-params", "tests/runner/http_get_runner.zig", "tr-server-http-params", "examples/http_params.zig", "9007", "/echo?foo=bar", "", "foo" },
        .{ "test-runner-http-paths", "tests/runner/http_get_runner.zig", "tr-server-http-paths", "examples/http_paths.zig", "9008", "/path", "", "" },
        .{ "test-runner-http-timeout-resp", "tests/runner/http_get_runner.zig", "tr-server-http-timeout-resp", "examples/http_timeout_resp.zig", "9010", "/ping", "", "pong" },
        .{ "test-runner-http-xtra-headers", "tests/runner/http_get_runner.zig", "tr-server-http-xtra-headers", "examples/http_xtra_headers.zig", "9011", "/info", "", "" },
        .{ "test-runner-http-manual-concurrent", "tests/runner/http_get_runner.zig", "tr-server-http-manual-concurrent", "examples/http_manual_concurrent.zig", "9014", "/", "", "hello" },
        // http static runner (arg4=filename, arg5=file content)
        .{ "test-runner-http-static", "tests/runner/http_static_runner.zig", "tr-server-http-static", "examples/http_static.zig", "9009", "http_text_file.txt", "this is http text file example.", "" },
        // http sse runner
        .{ "test-runner-http-sse", "tests/runner/sse_runner.zig", "tr-server-http-sse", "examples/http_sse.zig", "9012", "", "", "" },
        // http websocket runner (arg4=ws route)
        .{ "test-runner-http-websocket", "tests/runner/ws_runner.zig", "tr-server-http-websocket", "examples/http_websocket.zig", "9013", "/ws/lobby", "", "" },
        // http1 feature runners
        .{ "test-runner-http1-json", "tests/runner/http_get_runner.zig", "tr-server-http1-json", "examples/http1_json.zig", "9020", "/status", "", "server" },
        .{ "test-runner-http1-middleware", "tests/runner/http_get_runner.zig", "tr-server-http1-middleware", "examples/http1_middleware.zig", "9021", "/public", "http://127.0.0.1", "public" },
        .{ "test-runner-http1-params", "tests/runner/http_get_runner.zig", "tr-server-http1-params", "examples/http1_params.zig", "9022", "/echo?foo=bar", "", "foo" },
        .{ "test-runner-http1-paths", "tests/runner/http_get_runner.zig", "tr-server-http1-paths", "examples/http1_paths.zig", "9023", "/path", "", "" },
        .{ "test-runner-http1-timeout-resp", "tests/runner/http_get_runner.zig", "tr-server-http1-timeout-resp", "examples/http1_timeout_resp.zig", "9025", "/ping", "", "pong" },
        .{ "test-runner-http1-xtra-headers", "tests/runner/http_get_runner.zig", "tr-server-http1-xtra-headers", "examples/http1_xtra_headers.zig", "9026", "/info", "", "" },
        .{ "test-runner-http1-manual-concurrent", "tests/runner/http_get_runner.zig", "tr-server-http1-manual-concurrent", "examples/http1_manual_concurrent.zig", "9030", "/", "", "hello" },
        // http1 static runner
        .{ "test-runner-http1-static", "tests/runner/http_static_runner.zig", "tr-server-http1-static", "examples/http1_static.zig", "9024", "http1_text_file.txt", "this is http1 text file example.", "" },
        // http1 sse runner
        .{ "test-runner-http1-sse", "tests/runner/sse_runner.zig", "tr-server-http1-sse", "examples/http1_sse.zig", "9027", "", "", "" },
        // http1 websocket runner
        .{ "test-runner-http1-websocket", "tests/runner/ws_runner.zig", "tr-server-http1-websocket", "examples/http1_websocket.zig", "9028", "/ws", "", "" },
        // http1 websocket runner on the io_uring (.URING) dispatch model
        .{ "test-runner-http1-websocket-uring", "tests/runner/ws_runner.zig", "tr-server-http1-websocket-uring", "examples/http1_websocket_uring.zig", "9029", "/ws", "", "" },
        // http1 response-cache runner (unique port; small body so the GET is bounded)
        .{ "test-runner-http1-cache", "tests/runner/http_get_runner.zig", "tr-server-http1-cache", "examples/http1_cache.zig", "9031", "/cache?kb=1", "", "ok" },
        // http1 over-large request-body drain runners (EPOLL + URING only; the
        // other models truncate the body instead of draining it)
        .{ "test-runner-http1-drain-epoll", "tests/runner/http1_drain_runner.zig", "tr-server-http1-drain-epoll", "examples/http1_basic_4_epoll.zig", "9018", "", "", "" },
        .{ "test-runner-http1-drain-uring", "tests/runner/http1_drain_runner.zig", "tr-server-http1-drain-uring", "examples/http1_basic_5_uring.zig", "9019", "", "", "" },
        // grpc location runners
        .{ "test-runner-grpc-location-async", "tests/runner/grpc_location_runner.zig", "tr-server-grpc-location-async", "examples/grpc_location_server_1_async.zig", "9038", "", "", "" },
        .{ "test-runner-grpc-location-pool", "tests/runner/grpc_location_runner.zig", "tr-server-grpc-location-pool", "examples/grpc_location_server_2_pool.zig", "9039", "", "", "" },
        .{ "test-runner-grpc-location-mixed", "tests/runner/grpc_location_runner.zig", "tr-server-grpc-location-mixed", "examples/grpc_location_server_3_mixed.zig", "9040", "", "", "" },
        .{ "test-runner-grpc-location-epoll", "tests/runner/grpc_location_runner.zig", "tr-server-grpc-location-epoll", "examples/grpc_location_server_4_epoll.zig", "9041", "", "", "" },
        // grpc multi and timeout runners
        .{ "test-runner-grpc-multi", "tests/runner/grpc_multi_runner.zig", "tr-server-grpc-multi", "examples/grpc_multi_server.zig", "9042", "", "", "" },
        .{ "test-runner-grpc-timeout", "tests/runner/grpc_timeout_runner.zig", "tr-server-grpc-timeout", "examples/grpc_timeout.zig", "9037", "", "", "" },
        // fix trading runner
        .{ "test-runner-fix-trading", "tests/runner/fix_trading_runner.zig", "tr-server-fix-trading", "examples/fix_server_trading.zig", "9053", "", "", "" },
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

    // --------------------------------------------------------- //

    // test-runner-uds-http: two server processes.
    // argv[1]: uds_server path. argv[2]: uds_http path. argv[3]: label.
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

    // --------------------------------------------------------- //

    // test-runner-channel-ipc: two processes (ipc_a + ipc_b).
    // argv[1]: ipc_a path. argv[2]: ipc_b path. argv[3]: label.
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

    // --------------------------------------------------------- //

    // test-runner-all: one binary, all 58 server paths as argv.
    // Independent of the individual test-runner-* steps above.
    // argv order matches the path declarations in all_runner.zig.
    {
        const all_server_srcs = .{
            // basic dispatch-model servers (23)
            .{ "tr-all-server-http-async", "examples/http_basic_1_async.zig" },
            .{ "tr-all-server-http-pool", "examples/http_basic_2_pool.zig" },
            .{ "tr-all-server-http-mixed", "examples/http_basic_3_mixed.zig" },
            .{ "tr-all-server-http-epoll", "examples/http_basic_4_epoll.zig" },
            .{ "tr-all-server-http1-async", "examples/http1_basic_1_async.zig" },
            .{ "tr-all-server-http1-pool", "examples/http1_basic_2_pool.zig" },
            .{ "tr-all-server-http1-mixed", "examples/http1_basic_3_mixed.zig" },
            .{ "tr-all-server-http1-epoll", "examples/http1_basic_4_epoll.zig" },
            .{ "tr-all-server-http1-uring", "examples/http1_basic_5_uring.zig" },
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
            .{ "tr-all-server-udp-raw", "examples/udp_raw_echo.zig" },
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
            // http1 feature servers (11)
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
            .{ "tr-all-server-http1-cache", "examples/http1_cache.zig" },
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

            // tls (https/1.1 + ed25519 cert variant + h2, over TLS 1.3)
            .{ "tr-all-server-tls-http1", "examples/tls/tls_http1_basic.zig" },
            .{ "tr-all-server-tls-http1-ed25519", "examples/tls/tls_http1_ed25519.zig" },
            .{ "tr-all-server-tls-http2", "examples/tls/tls_http2_basic.zig" },
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
