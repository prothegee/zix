//! Test runner for every zixer proxy demo.
//!
//! Invoked by `zig build zixer-test-runner-all`. The build passes the zixer
//! binary first, then one upstream binary path per row of the UPSTREAM table
//! below, in that exact order.
//!
//! One row is one demo: the runner starts that demo's upstream processes, asks
//! the daemon to bind its site, drives a real client through the edge, then
//! stops the site and kills the upstreams. Rows run one at a time, so a
//! failure names one demo and leaves nothing bound behind it.
//!
//! The daemon runs on a throwaway root under tmp/, copied from
//! examples/proxies (see root_setup.zig), so a run never disturbs a daemon a
//! developer already has on that directory.
//!
//! Run one row by label:
//!     zig build zixer-test-runner-all
//!     ./zig-out/bin/zixer-test-runner-all --only http3 <zixer> <upstreams...>
//!
//! The check bodies live in sibling files, grouped by protocol family:
//!   checks_http1.zig  plain proxy, sse, websocket, static, mixed, round robin
//!   checks_http2.zig  the h2 edge and the grpc relay
//!   checks_http3.zig  the QUIC edge
//!   checks_udp.zig    the flow forward and the webrtc media pair
//!   checks_tls.zig    TLS terminate and the webrtc signaling site

const std = @import("std");

const common = @import("runner_common");

const gateway = @import("gateway.zig");
const root_setup = @import("root_setup.zig");
const upstreams = @import("upstreams.zig");

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
    const WEBRTC: usize = 10;

    const COUNT: usize = 11;
};

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

/// Flag that narrows the run to one row.
const ONLY_FLAG: []const u8 = "--only";

// --------------------------------------------------------- //

/// Everything argv carried: the optional label filter, the gateway binary, and
/// the upstream binary paths in table order.
const Args = struct {
    only: ?[]const u8 = null,
    zixer_path: []const u8 = "",
    paths: [UPSTREAM.COUNT][]const u8 = @splat(""),
    path_count: usize = 0,
};

/// Split argv into the filter, the gateway path, and the upstream paths.
fn parseArgs(iter: *std.process.Args.Iterator) !Args {
    var args = Args{};
    _ = iter.next();

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, ONLY_FLAG)) {
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

/// Run one row: upstreams up, site bound, client driven, everything torn down
/// again whatever the outcome.
fn runCheck(io: std.Io, check: Check, live: *const gateway.Gateway, paths: []const []const u8) !void {
    var group = try upstreams.start(io, paths, check.needs);
    defer group.kill(io);

    try live.startSite(io, check.site);
    defer live.stopSite(io, check.site) catch {};

    try check.run(io);
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

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    try root_setup.create(io, arena.allocator());
    defer root_setup.destroy(io);

    var live = try gateway.start(io, args.zixer_path);
    defer live.shutdown(io);

    var ran: usize = 0;
    var failed: usize = 0;

    for (checks) |check| {
        if (args.only) |only| {
            if (!std.mem.eql(u8, only, check.label)) continue;
        }

        ran += 1;
        runCheck(io, check, &live, args.paths[0..args.path_count]) catch |err| {
            failed += 1;
            std.debug.print("FAIL zixer-{s} ({s}): {s}\n", .{ check.label, check.site, @errorName(err) });
            continue;
        };

        std.debug.print("PASS zixer-{s} ({s})\n", .{ check.label, check.site });
    }

    if (ran == 0) {
        std.debug.print("zixer runner: no check matched --only\n", .{});
        std.process.exit(2);
    }

    std.debug.print("zixer runner: {d} of {d} demos passed\n", .{ ran - failed, ran });

    if (failed != 0) std.process.exit(1);
}
