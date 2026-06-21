const std = @import("std");

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zix: *std.Build.Module,
) void {
    // Examples: not built by default. Third field is the group tag used to wire
    // per-category steps. `zig build examples` builds all, `zig build example-<group>`
    // builds one category, `zig build example-<name>` builds and runs a single one.
    const examples = .{
        .{ "example-tcp_server_1_async", "examples/tcp_server_1_async.zig", "tcp" },
        .{ "example-tcp_server_2_pool", "examples/tcp_server_2_pool.zig", "tcp" },
        .{ "example-tcp_server_3_mixed", "examples/tcp_server_3_mixed.zig", "tcp" },
        .{ "example-tcp_server_4_epoll", "examples/tcp_server_4_epoll.zig", "tcp" },
        .{ "example-tcp_server_5_uring", "examples/tcp_server_5_uring.zig", "tcp" },
        .{ "example-tcp_client", "examples/tcp_client.zig", "tcp" },
        .{ "example-http1_basic_1_async", "examples/http1_basic_1_async.zig", "http1" },
        .{ "example-http1_basic_2_pool", "examples/http1_basic_2_pool.zig", "http1" },
        .{ "example-http1_basic_3_mixed", "examples/http1_basic_3_mixed.zig", "http1" },
        .{ "example-http1_basic_4_epoll", "examples/http1_basic_4_epoll.zig", "http1" },
        .{ "example-http1_basic_5_uring", "examples/http1_basic_5_uring.zig", "http1" },
        .{ "example-http1_cache", "examples/http1_cache.zig", "http1" },
        .{ "example-http1_compression", "examples/http1_compression.zig", "http1" },
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
        .{ "example-http1_websocket_uring", "examples/http1_websocket_uring.zig", "http1" },
        .{ "example-http_basic_1_async", "examples/http_basic_1_async.zig", "http" },
        .{ "example-http_basic_2_pool", "examples/http_basic_2_pool.zig", "http" },
        .{ "example-http_basic_3_mixed", "examples/http_basic_3_mixed.zig", "http" },
        .{ "example-http_basic_4_epoll", "examples/http_basic_4_epoll.zig", "http" },
        .{ "example-http_basic_5_uring", "examples/http_basic_5_uring.zig", "http" },
        .{ "example-http_client", "examples/http_client.zig", "http" },
        .{ "example-http_compression", "examples/http_compression.zig", "http" },
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
        .{ "example-fix_server_5_uring", "examples/fix_server_5_uring.zig", "fix" },
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
        .{ "example-grpc_server_5_uring", "examples/grpc_server_5_uring.zig", "grpc" },
        .{ "example-grpc_timeout", "examples/grpc_timeout.zig", "grpc" },
        .{ "example-grpc_multi_server", "examples/grpc_multi_server.zig", "grpc" },
        .{ "example-grpc_multi_client", "examples/grpc_multi_client.zig", "grpc" },
    };

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

    // Bug reproduction programs: not built by default.
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
