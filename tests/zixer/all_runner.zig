//! Test runner for every zixer proxy demo.
//!
//! Invoked by `zig build zixer-test-runner-all`. The build passes the zixer
//! binary first, then one upstream binary path per row of the UPSTREAM table
//! below, in that exact order.
//!
//! One row is one demo: it starts its own daemon on its own throwaway root,
//! starts that demo's upstream processes, asks the daemon to bind its site,
//! drives a real client through the edge, then stops the site and tears
//! everything down again.
//!
//! Each row runs in a child copy of this binary, bounded in time (see
//! row_isolate.zig). Without that bound a single park costs the whole table:
//! the client blocks in a read that never returns, the step hits its CI wall
//! minutes later, and not one row after it is ever reported. With it, a park is
//! one FAIL line and the run carries on. A failed row also prints what its
//! daemon and upstreams wrote to stderr, which is the only account left of a
//! child the parent had to kill.
//!
//! Roots are throwaway copies of examples/proxies under tmp/ (see
//! root_setup.zig), one per row, so a run never disturbs a daemon a developer
//! already has on that directory and a killed row cannot hand its orphan to the
//! next one.
//!
//! Run one row by label:
//!     zig build zixer-test-runner-all
//!     ./zig-out/bin/zixer-test-runner-all --only http3 <zixer> <upstreams...>
//!
//! The check bodies live in sibling files, grouped by protocol family, plus one
//! per capability that is not a protocol:
//!   checks_http1.zig    plain proxy, sse, websocket, static, mixed, round robin
//!   checks_http2.zig    the h2 edge and the grpc relay
//!   checks_http3.zig    the QUIC edge
//!   checks_udp.zig      the flow forward and the webrtc media pair
//!   checks_tls.zig      TLS terminate and the webrtc signaling site
//!   checks_bounds.zig   the client budget and the connection limit
//!   checks_headers.zig  the two cfg header sections

const std = @import("std");

const common = @import("runner_common");

const child_stderr = @import("child_stderr.zig");
const gateway = @import("gateway.zig");
const root_setup = @import("root_setup.zig");
const row_isolate = @import("row_isolate.zig");
const upstreams = @import("upstreams.zig");

const checks_bounds = @import("checks_bounds.zig");
const checks_headers = @import("checks_headers.zig");
const checks_http1 = @import("checks_http1.zig");
const checks_http2 = @import("checks_http2.zig");
const checks_http3 = @import("checks_http3.zig");
const checks_tls = @import("checks_tls.zig");
const checks_udp = @import("checks_udp.zig");

// --------------------------------------------------------- //

/// Upstream binary slots, in the argv order zixer-build-test_runner.zig sends.
const UPSTREAM = struct {
    const HTTP1: usize = 0;
    const HTTP1_SSE: usize = 1;
    const HTTP1_WS: usize = 2;
    const HTTP2: usize = 3;
    const GRPC: usize = 4;
    const HTTP3: usize = 5;
    const UDP: usize = 6;
    const MIXED: usize = 7;
    const ROUND_ROBIN: usize = 8;
    const TLS: usize = 9;
    const BOUNDS: usize = 10;
    const HEADERS: usize = 11;
    const WEBRTC: usize = 12;

    const COUNT: usize = 13;
};

comptime {
    std.debug.assert(UPSTREAM.COUNT <= row_isolate.MAX_UPSTREAM_PATHS);
}

/// Edge ports, one per site config under examples/proxies/sites.
const EDGE = struct {
    const HTTP1: u16 = 9100;
    const HTTP1_SSE: u16 = 9102;
    const HTTP1_WS: u16 = 9104;
    const HTTP2: u16 = 9106;
    const GRPC: u16 = 9108;
    const HTTP3: u16 = 9110;
    const UDP: u16 = 9112;
    const STATIC: u16 = 9114;
    const MIXED: u16 = 9115;
    const ROUND_ROBIN: u16 = 9117;
    const TLS: u16 = 9120;
    const RTC_SIGNAL: u16 = 9122;
    const RTC_MEDIA: u16 = 9123;
    const BOUNDS: u16 = 9124;
    const HEADERS: u16 = 9128;
};

/// Upstream ports the runner polls before handing a site to the daemon.
const BACKEND = struct {
    const HTTP1: u16 = 9101;
    const HTTP1_SSE: u16 = 9103;
    const HTTP1_WS: u16 = 9105;
    const HTTP2: u16 = 9107;
    const GRPC: u16 = 9109;
    const HTTP3: u16 = 9111;
    const MIXED: u16 = 9116;
    const ROUND_ROBIN_FIRST: u16 = 9118;
    const ROUND_ROBIN_SECOND: u16 = 9119;
    const TLS: u16 = 9121;
    const BOUNDS: u16 = 9125;
    const HEADERS: u16 = 9129;
};

/// One demo: its site config, the upstreams it needs, and the client that
/// proves it works.
const Check = struct {
    label: []const u8,
    site: []const u8,
    needs: []const upstreams.Spec,
    run: *const fn (std.Io) anyerror!void,
};

const checks = [_]Check{
    .{
        .label = "http1",
        .site = "http1.cfg",
        .needs = &.{.{ .binary = UPSTREAM.HTTP1, .tcp_port = BACKEND.HTTP1 }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_http1.runHttp1(io, EDGE.HTTP1);
            }
        }.call,
    },
    .{
        .label = "sse",
        .site = "http1_sse.cfg",
        .needs = &.{.{ .binary = UPSTREAM.HTTP1_SSE, .tcp_port = BACKEND.HTTP1_SSE }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_http1.runSse(io, EDGE.HTTP1_SSE);
            }
        }.call,
    },
    .{
        .label = "websocket",
        .site = "http1_ws.cfg",
        .needs = &.{.{ .binary = UPSTREAM.HTTP1_WS, .tcp_port = BACKEND.HTTP1_WS }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_http1.runWs(io, EDGE.HTTP1_WS);
            }
        }.call,
    },
    .{
        .label = "http2",
        .site = "http2.cfg",
        .needs = &.{.{ .binary = UPSTREAM.HTTP2, .tcp_port = BACKEND.HTTP2 }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_http2.runHttp2(io, EDGE.HTTP2);
            }
        }.call,
    },
    .{
        .label = "grpc",
        .site = "grpc.cfg",
        .needs = &.{.{ .binary = UPSTREAM.GRPC, .tcp_port = BACKEND.GRPC }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_http2.runGrpc(io, EDGE.GRPC);
            }
        }.call,
    },
    .{
        .label = "http3",
        .site = "http3.cfg",
        .needs = &.{.{ .binary = UPSTREAM.HTTP3, .tcp_port = BACKEND.HTTP3 }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_http3.runHttp3(io, EDGE.HTTP3);
            }
        }.call,
    },
    .{
        .label = "udp",
        .site = "udp.cfg",
        .needs = &.{.{ .binary = UPSTREAM.UDP }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_udp.runUdp(io, EDGE.UDP);
            }
        }.call,
    },
    .{
        .label = "static",
        .site = "static.cfg",
        .needs = &.{},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_http1.runStatic(io, EDGE.STATIC);
            }
        }.call,
    },
    .{
        .label = "mixed",
        .site = "mixed.cfg",
        .needs = &.{.{ .binary = UPSTREAM.MIXED, .tcp_port = BACKEND.MIXED }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_http1.runMixed(io, EDGE.MIXED);
            }
        }.call,
    },
    .{
        .label = "round-robin",
        .site = "round_robin.cfg",
        .needs = &.{
            .{ .binary = UPSTREAM.ROUND_ROBIN, .args = &.{ "--port", "9118" }, .tcp_port = BACKEND.ROUND_ROBIN_FIRST },
            .{ .binary = UPSTREAM.ROUND_ROBIN, .args = &.{ "--port", "9119" }, .tcp_port = BACKEND.ROUND_ROBIN_SECOND },
        },
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_http1.runRoundRobin(io, EDGE.ROUND_ROBIN, BACKEND.ROUND_ROBIN_FIRST, BACKEND.ROUND_ROBIN_SECOND);
            }
        }.call,
    },
    .{
        .label = "tls",
        .site = "tls.cfg",
        .needs = &.{.{ .binary = UPSTREAM.TLS, .tcp_port = BACKEND.TLS }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_tls.runTls(io, EDGE.TLS);
            }
        }.call,
    },
    .{
        .label = "bounds",
        .site = "bounds.cfg",
        .needs = &.{.{ .binary = UPSTREAM.BOUNDS, .tcp_port = BACKEND.BOUNDS }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_bounds.runBounds(io, EDGE.BOUNDS);
            }
        }.call,
    },
    .{
        .label = "headers",
        .site = "headers.cfg",
        .needs = &.{.{ .binary = UPSTREAM.HEADERS, .tcp_port = BACKEND.HEADERS }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_headers.runHeaders(io, EDGE.HEADERS);
            }
        }.call,
    },
    .{
        .label = "rtc-signal",
        .site = "rtc_signal.cfg",
        .needs = &.{.{ .binary = UPSTREAM.HTTP1_WS, .tcp_port = BACKEND.HTTP1_WS }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_tls.runRtcSignal(io, EDGE.RTC_SIGNAL);
            }
        }.call,
    },
    .{
        .label = "rtc-media",
        .site = "rtc_media.cfg",
        .needs = &.{.{ .binary = UPSTREAM.WEBRTC }},
        .run = &struct {
            fn call(io: std.Io) anyerror!void {
                return checks_udp.runRtcMedia(io, EDGE.RTC_MEDIA);
            }
        }.call,
    },
};

// --------------------------------------------------------- //

/// Everything argv carried: this binary, the optional label filter, the gateway
/// binary, and the upstream binary paths in table order.
const Args = struct {
    self_exe: []const u8 = "",
    only: ?[]const u8 = null,
    zixer_path: []const u8 = "",
    paths: [UPSTREAM.COUNT][]const u8 = @splat(""),
    path_count: usize = 0,
};

/// Split argv into this binary, the filter, the gateway path, and the upstream
/// paths.
///
/// Note:
/// - argv[0] is kept rather than skipped: it is how a row respawns itself as a
///   child. zig build invokes the runner by its emitted path, which is what
///   std.process.spawn needs.
fn parseArgs(iter: *std.process.Args.Iterator) !Args {
    var args = Args{};
    args.self_exe = iter.next() orelse return error.MissingRunnerPath;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, row_isolate.ONLY_FLAG)) {
            args.only = iter.next() orelse return error.MissingOnlyValue;
            continue;
        }

        if (args.zixer_path.len == 0) {
            args.zixer_path = arg;
            continue;
        }

        if (args.path_count >= UPSTREAM.COUNT) return error.TooManyUpstreamPaths;

        args.paths[args.path_count] = arg;
        args.path_count += 1;
    }

    if (args.zixer_path.len == 0) return error.MissingZixerPath;
    if (args.path_count != UPSTREAM.COUNT) return error.MissingUpstreamPaths;

    return args;
}

/// The row one label names, or null when no row carries it.
fn findCheck(label: []const u8) ?Check {
    for (checks) |check| {
        if (std.mem.eql(u8, label, check.label)) return check;
    }

    return null;
}

/// Run one row against a live daemon: upstreams up, site bound, client driven,
/// everything torn down again whatever the outcome.
fn runCheck(io: std.Io, check: Check, live: *const gateway.Gateway, paths: []const []const u8) !void {
    var group = try upstreams.start(io, live.root, paths, check.needs);
    defer group.kill(io);

    try live.startSite(io, check.site);
    defer live.stopSite(io, check.site) catch {};

    try check.run(io);
}

// --------------------------------------------------------- //
// child mode: one row, one report line, one exit code

/// Build this row's own root and daemon, run it, and print its one line.
///
/// Note:
/// - The root is left behind on purpose. The parent reads the daemon and
///   upstream stderr files out of it before removing it, and a row run by hand
///   leaves them there to read.
///
/// Return:
/// - row_isolate.Exit.PASSED or row_isolate.Exit.FAILED, the child's exit code
fn runOwnedRow(io: std.Io, args: Args, check: Check) u8 {
    var root_buf: [root_setup.MAX_ROOT]u8 = undefined;
    const root = root_setup.rootPath(check.label, &root_buf) catch {
        std.debug.print("FAIL zixer-{s} ({s}): label too long for a root path\n", .{ check.label, check.site });
        return row_isolate.Exit.FAILED;
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    root_setup.create(io, arena.allocator(), root) catch |err| {
        std.debug.print("FAIL zixer-{s} ({s}): root {s}\n", .{ check.label, check.site, @errorName(err) });
        return row_isolate.Exit.FAILED;
    };

    var live = gateway.start(io, args.zixer_path, root) catch |err| {
        std.debug.print("FAIL zixer-{s} ({s}): daemon {s}\n", .{ check.label, check.site, @errorName(err) });
        return row_isolate.Exit.FAILED;
    };
    defer live.shutdown(io);

    runCheck(io, check, &live, args.paths[0..args.path_count]) catch |err| {
        std.debug.print("FAIL zixer-{s} ({s}): {s}\n", .{ check.label, check.site, @errorName(err) });
        return row_isolate.Exit.FAILED;
    };

    std.debug.print("PASS zixer-{s} ({s})\n", .{ check.label, check.site });

    return row_isolate.Exit.PASSED;
}

/// Run the row one label names and exit with its verdict.
fn runOnly(io: std.Io, args: Args, label: []const u8) noreturn {
    const check = findCheck(label) orelse {
        std.debug.print("zixer runner: no check matched --only {s}\n", .{label});
        std.process.exit(2);
    };

    std.process.exit(runOwnedRow(io, args, check));
}

// --------------------------------------------------------- //
// parent mode: the whole table, one bounded child per row

/// Print whatever a failed row's children wrote to stderr. A child the parent
/// killed printed no report of its own, so this is the only account of it.
fn reportChildLogs(io: std.Io, check: Check, root: []const u8) void {
    var tail_buf: [child_stderr.TAIL_MAX]u8 = undefined;

    const daemon_tail = child_stderr.tail(io, root, child_stderr.DAEMON_NAME, &tail_buf);
    if (daemon_tail.len != 0) std.debug.print("  daemon stderr:\n{s}\n", .{daemon_tail});

    for (check.needs, 0..) |_, slot| {
        var name_buf: [child_stderr.MAX_NAME]u8 = undefined;
        const name = child_stderr.upstreamName(slot, &name_buf) catch continue;

        const upstream_tail = child_stderr.tail(io, root, name, &tail_buf);
        if (upstream_tail.len == 0) continue;

        std.debug.print("  {s}:\n{s}\n", .{ name, upstream_tail });
    }
}

/// Run one row as a bounded child, forward its report, and clean up its root.
fn runRowIsolated(io: std.Io, args: Args, check: Check, timeout_ms: u32) bool {
    var report_buf: [row_isolate.REPORT_MAX]u8 = undefined;
    const result = row_isolate.runRow(
        io,
        args.self_exe,
        check.label,
        args.zixer_path,
        args.paths[0..args.path_count],
        timeout_ms,
        &report_buf,
    );

    row_isolate.forward(io, result.report);

    var root_buf: [root_setup.MAX_ROOT]u8 = undefined;
    const root = root_setup.rootPath(check.label, &root_buf) catch return result.verdict == .PASSED;

    if (result.verdict != .PASSED) reportChildLogs(io, check, root);

    root_setup.destroy(io, root);

    return result.verdict == .PASSED;
}

/// Run the whole table, one bounded child per row, and report the tally.
fn runTable(io: std.Io, args: Args, timeout_ms: u32) u8 {
    var failed: usize = 0;

    for (checks) |check| {
        if (!runRowIsolated(io, args, check, timeout_ms)) failed += 1;
    }

    if (failed > 0) {
        std.debug.print("{d}/{d} example(s) failed\n", .{ failed, checks.len });

        return 1;
    }

    std.debug.print("zixer: all {d} examples passed\n", .{checks.len});

    return 0;
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    // common.argsIterator, not Iterator.init: the plain initializer is a
    // compile error on Windows, which needs the allocating variant.
    var iter = common.argsIterator(process.minimal.args);
    const args = parseArgs(&iter) catch |err| {
        std.debug.print("zixer runner: bad arguments ({s})\n", .{@errorName(err)});
        std.process.exit(2);
    };

    if (args.only) |label| runOnly(io, args, label);

    // The per-row kill bound is the native default unless the environment
    // widens it, which the qemu CI legs do.
    const timeout_ms = row_isolate.rowTimeoutMs(process.environ_map.get(row_isolate.ROW_TIMEOUT_ENV));

    std.process.exit(runTable(io, args, timeout_ms));
}
