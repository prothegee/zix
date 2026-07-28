const std = @import("std");

/// Wrap a compiled test artifact in a Run step when the target can execute on this host,
/// otherwise return the compile step directly. Deterministic compile-only coverage for a
/// foreign target regardless of host binfmt_misc / qemu registration making execution
/// technically possible (e.g. aarch64-linux under a registered qemu-user interpreter).
///
/// Note:
/// - name tags the step with its source path, so `--summary all` shows which
///   test file a pending or hung step belongs to instead of a generic "run test".
fn testRunStep(b: *std.Build, exe: *std.Build.Step.Compile, foreign: bool, name: []const u8) *std.Build.Step {
    if (foreign) {
        exe.step.name = name;
        return &exe.step;
    }

    const run = b.addRunArtifact(exe);
    run.setName(name);
    return &run.step;
}

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zix: *std.Build.Module,
) void {
    // Foreign target (e.g. -Dtarget=x86_64-windows on a Linux host): every suite
    // still compiles for the target, and the run steps report skipped instead of
    // failing to spawn, so `zig build test-all -Dtarget=<t>` passes as a
    // compile-coverage pass. On the target's own machine the suites run for real.
    const host = b.graph.host.result;
    const foreign_target = target.result.os.tag != host.os.tag or target.result.cpu.arch != host.cpu.arch;
    if (foreign_target) {
        std.log.info("zix tests: target {s}-{s} is foreign to this host, suites compile but execution is skipped", .{
            @tagName(target.result.cpu.arch), @tagName(target.result.os.tag),
        });
    }

    const zix_tests = b.addTest(.{ .root_module = zix });
    const zix_tests_step = testRunStep(b, zix_tests, foreign_target, "unit-test");

    const test_step = b.step("unit-test", "Run unit tests");
    test_step.dependOn(zix_tests_step);

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
        "tests/integration/http/tls_dual_test.zig",
        // http1
        "tests/integration/http1/server_test.zig",
        "tests/integration/http1/router_test.zig",
        "tests/integration/http1/tls_dual_test.zig",
        // http2
        "tests/integration/http2/server_test.zig",
        "tests/integration/http2/tls_dual_test.zig",
        // websocket
        "tests/integration/websocket/websocket_test.zig",
        // fix
        "tests/integration/fix/server_test.zig",
        // grpc
        "tests/integration/grpc/server_test.zig",
        "tests/integration/grpc/tls_dual_test.zig",
        // udp
        "tests/integration/udp/packet_test.zig",
        "tests/integration/udp/config_test.zig",
        // uds
        "tests/integration/uds/config_test.zig",
        // channel
        "tests/integration/channel/channel_test.zig",
        // logger
        "tests/integration/logger/logger_test.zig",
        // tls
        "tests/integration/tls/rsa_test.zig",
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
        const t_step = testRunStep(b, t_exe, foreign_target, src);
        if (prev_integ) |p| t_step.dependOn(p);
        prev_integ = t_step;
        integration_test_step.dependOn(t_step);
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
        const t_step = testRunStep(b, t_exe, foreign_target, src);
        if (prev_behav) |p| t_step.dependOn(p);
        prev_behav = t_step;
        behaviour_test_step.dependOn(t_step);
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
        const t_step = testRunStep(b, t_exe, foreign_target, src);
        if (prev_edge) |p| t_step.dependOn(p);
        prev_edge = t_step;
        edge_test_step.dependOn(t_step);
    }

    // --------------------------------------------------------- //

    // Run tiers sequentially so zig 0.16 IPC sends ".exit" before the next tier starts.
    behaviour_test_step.dependOn(integration_test_step);
    edge_test_step.dependOn(behaviour_test_step);

    const all_test_step = b.step("test-all", "Run unit, integration, behaviour, and edge tests");
    all_test_step.dependOn(zix_tests_step);
    all_test_step.dependOn(integration_test_step);
    all_test_step.dependOn(behaviour_test_step);
    all_test_step.dependOn(edge_test_step);
}
