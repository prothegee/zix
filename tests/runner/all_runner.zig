// Test runner for all protocols.
//
// Invoked by `zig build test-runner-all`. The build pushes one server binary
// path per check as argv, in the exact order of the `checks` table below: that
// table is the single source of truth for order, labels, ports, and arity, so
// adding a server means adding one row here (and the matching path in the
// build) rather than editing three parallel lists.
//
// The checks run concurrently in bounded waves (see runWaves): each check is
// self-contained (own server process, unique port), so they no longer block one
// another. Results are collected by table index and reported in table order, so
// the output stays stable. A check that shares a filesystem resource with
// another (the two /tmp/zix.sock users) carries a `resource` tag, and the
// scheduler never runs two checks with the same tag at once.
//
// Every check body runs in a child copy of this binary rather than in the
// runner itself (see isolate.zig): the runner respawns itself with `--only
// <label>`, which gives a parked check an upper bound the parent can enforce.
// The child prints its own PASS or FAIL line and the parent forwards it, so
// running a check alone is just `test-runner-all --only <label> <server path>`.
//
// The check bodies live in sibling files grouped by concern:
//   wire.zig         low-level TLS record / header / h2-frame-scan helpers
//   checks_http.zig  arena + http1 engines, h2c, http3
//   checks_tls.zig   https/1.1, h2, gRPC, SSE, WebSocket over TLS 1.3
//   checks_rpc.zig   gRPC + FIX
//   checks_misc.zig  TCP, UDP, UDS, Channel

const std = @import("std");
const common = @import("common.zig");
const isolate = @import("isolate.zig");
const checks_http = @import("checks_http.zig");
const checks_tls = @import("checks_tls.zig");
const checks_rpc = @import("checks_rpc.zig");
const checks_misc = @import("checks_misc.zig");

// --------------------------------------------------------- //

/// Uniform check entry point: every wrapper in the `checks` table has this shape and pulls the server
/// path(s) it needs out of the per-check `paths` slice (length equals the row's `arity`).
const RunFn = *const fn (std.Io, []const []const u8) anyerror!void;

const Check = struct {
    label: []const u8,
    run: RunFn,
    /// Number of consecutive argv server paths this check consumes (uds-http and channel-ipc take 2).
    arity: u8 = 1,
    /// Shared filesystem path this check needs exclusively, or null. The scheduler never runs two
    /// checks with the same tag concurrently.
    resource: ?[]const u8 = null,
    /// CPU-heavy startup or handshake (TLS / QUIC). The scheduler caps how many of these run at once
    /// so a wave of them cannot starve each other into bind or handshake timeouts.
    heavy: bool = false,
};

const zix_sock = "tmp/zix.sock";
const zix_ipc_sock = "tmp/zix_ipc.sock";

const checks = [_]Check{
    // Basic per-engine checks: one unified example each, on the dispatch model its target picks.
    .{ .label = "http", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp(io, paths[0], 9000);
        }
    }.f },
    .{ .label = "http1", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp1(io, paths[0], 9015);
        }
    }.f },
    .{ .label = "grpc", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpc(io, paths[0], 9032);
        }
    }.f },
    .{ .label = "tcp", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runTcp(io, paths[0], 9043);
        }
    }.f },
    .{ .label = "fix", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runFix(io, paths[0], 9048);
        }
    }.f },
    .{ .label = "http2", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp2(io, paths[0], 9065);
        }
    }.f },
    .{ .label = "udp", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runUdp(io, paths[0]);
        }
    }.f },
    .{ .label = "udp-raw", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runUdpRaw(io, paths[0]);
        }
    }.f },
    .{ .label = "uds", .resource = zix_sock, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runUds(io, paths[0]);
        }
    }.f },

    // HTTP feature checks.
    .{ .label = "http-json", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9005, "/status", "", "server");
        }
    }.f },
    .{ .label = "http-middleware", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9006, "/public", "http://127.0.0.1", "public");
        }
    }.f },
    .{ .label = "http-params", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9007, "/echo?foo=bar", "", "foo");
        }
    }.f },
    .{ .label = "http-paths", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9008, "/path", "", "");
        }
    }.f },
    .{ .label = "http-timeout-resp", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9010, "/ping", "", "pong");
        }
    }.f },
    .{ .label = "http-xtra-headers", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpHeader(io, paths[0], 9011, "/info", "X-Server", "zix");
        }
    }.f },
    .{ .label = "http-manual-concurrent", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9014, "/", "", "hello");
        }
    }.f },
    .{ .label = "http-static", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpStatic(io, paths[0], 9009, "http_text_file.txt", "this is http text file example.", null);
        }
    }.f },
    .{ .label = "http-sse", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runSse(io, paths[0], 9012);
        }
    }.f },
    .{ .label = "http-websocket", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runWs(io, paths[0], 9013, "/ws/lobby");
        }
    }.f },
    .{ .label = "http-compression", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpCompression(io, paths[0], 9059);
        }
    }.f },

    // HTTP1 feature checks.
    .{ .label = "http1-json", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9020, "/status", "", "server");
        }
    }.f },
    .{ .label = "http1-middleware", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9021, "/public", "http://127.0.0.1", "public");
        }
    }.f },
    .{ .label = "http1-params", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9022, "/echo?foo=bar", "", "foo");
        }
    }.f },
    .{ .label = "http1-paths", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9023, "/path", "", "");
        }
    }.f },
    .{ .label = "http1-timeout-resp", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9025, "/ping", "", "pong");
        }
    }.f },
    .{ .label = "http1-xtra-headers", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpHeader(io, paths[0], 9026, "/info", "X-Server", "zix");
        }
    }.f },
    .{ .label = "http1-manual-concurrent", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9030, "/", "", "hello");
        }
    }.f },
    .{ .label = "http1-static", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpStatic(io, paths[0], 9024, "http1_text_file.txt", "this is http1 text file example.", "/upload-multipart");
        }
    }.f },
    .{ .label = "http1-sse", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runSse(io, paths[0], 9027);
        }
    }.f },
    .{ .label = "http1-websocket", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runWs(io, paths[0], 9028, "/ws/lobby");
        }
    }.f },
    .{ .label = "http1-cache", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpGet(io, paths[0], 9031, "/cache?kb=1", "", "ok");
        }
    }.f },
    .{ .label = "http1-compression", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttpCompression(io, paths[0], 9058);
        }
    }.f },

    // gRPC feature checks.
    .{ .label = "grpc-location", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpcLocation(io, paths[0], 9038);
        }
    }.f },
    .{ .label = "grpc-multi", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpcMulti(io, paths[0]);
        }
    }.f },
    .{ .label = "grpc-timeout", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpcTimeout(io, paths[0]);
        }
    }.f },

    // FIX trading check.
    .{ .label = "fix-trading", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runFixTrading(io, paths[0]);
        }
    }.f },

    // UDS HTTP check (two server binaries: uds_server + uds_http).
    .{ .label = "uds-http", .arity = 2, .resource = zix_sock, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runUdsHttp(io, paths[0], paths[1]);
        }
    }.f },

    // Channel self-terminating checks.
    .{ .label = "channel-basic", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runChannelSelfterm(io, paths[0]);
        }
    }.f },
    .{ .label = "channel-pipeline", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runChannelSelfterm(io, paths[0]);
        }
    }.f },
    .{ .label = "channel-worker-pool", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runChannelSelfterm(io, paths[0]);
        }
    }.f },

    // Channel IPC check (two server binaries: ipc_a + ipc_b).
    .{ .label = "channel-ipc", .arity = 2, .resource = zix_ipc_sock, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runChannelIpc(io, paths[0], paths[1]);
        }
    }.f },

    // TLS checks (native clients, no curl): https/1.1, ed25519 variant, h2, gRPC over h2.
    .{ .label = "tls-http1", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTls(io, paths[0], 9060);
        }
    }.f },
    .{ .label = "tls-http1-ed25519", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTlsHttp1Ed25519(io, paths[0], 9062);
        }
    }.f },
    .{ .label = "tls-http2", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTlsHttp2(io, paths[0], 9061);
        }
    }.f },
    .{ .label = "tls-grpc", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTlsGrpc(io, paths[0], 9070);
        }
    }.f },

    // HTTP/3 check (QUIC over TLS 1.3, native hand-rolled client, no external tool).
    .{ .label = "http3-basic", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp3(io, paths[0], 9063);
        }
    }.f },

    // SSE over TLS (ADR-054): https streaming on the arena and http1 engines, native TLS client.
    .{ .label = "tls-http-sse", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTlsSse(io, paths[0], 9072);
        }
    }.f },
    .{ .label = "tls-http1-sse", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTlsSse(io, paths[0], 9073);
        }
    }.f },

    // WebSocket over TLS (ADR-055): wss echo on the http1 and arena engines, native TLS client.
    .{ .label = "tls-http1-ws", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTlsWs(io, paths[0], 9074);
        }
    }.f },
    .{ .label = "tls-http-ws", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTlsWs(io, paths[0], 9075);
        }
    }.f },

    // https/1.1 over TLS 1.3 on the arena engine (zix.Http). Appended last so the argv order of the
    // existing checks stays stable. Same native TLS GET as tls-http1, different engine.
    .{ .label = "tls-http", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTls(io, paths[0], 9071);
        }
    }.f },

    // Dual listener (config.tls_port, ADR-060): appended last so the argv order of the existing
    // checks stays stable. One server answers cleartext AND https from the same worker fleet.
    .{ .label = "tls-http1-dual", .heavy = true, .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_tls.runTlsHttp1Dual(io, paths[0], 9076, 9077);
        }
    }.f },
};

/// Total argv server paths the checks table consumes (sum of every row's arity).
const total_paths = blk: {
    var sum: usize = 0;
    for (checks) |c| sum += c.arity;
    break :blk sum;
};

/// Widest arity in the table, sizing the child's path buffer.
const max_arity = blk: {
    var widest: u8 = 1;
    for (checks) |c| widest = @max(widest, c.arity);
    break :blk widest;
};

/// The check that owns argv path `index`, for naming a missing path.
fn labelForPath(index: usize) []const u8 {
    var seen: usize = 0;
    for (checks) |c| {
        seen += c.arity;
        if (index < seen) return c.label;
    }

    return "unknown";
}

/// The table row carrying `label`, or null when no row does.
fn findCheck(label: []const u8) ?Check {
    for (checks) |c| {
        if (std.mem.eql(u8, c.label, label)) return c;
    }

    return null;
}

// --------------------------------------------------------- //

/// Running tally so the final count is derived from the actual number of report() calls, not a
/// hardcoded total.
const Tally = struct { total: usize = 0, failed: usize = 0 };

fn exitMissing(name: []const u8) noreturn {
    std.debug.print("FAIL: missing {s} server path\n", .{name});
    std.process.exit(1);
}

/// Print a check's own outcome. Only a child copy of the runner calls this, since only a child runs
/// a check body.
fn report(label: []const u8, result: anyerror!void, tally: *Tally) void {
    tally.total += 1;
    if (result) {
        common.printPass(label);
    } else |err| {
        _ = common.takeFallbackNote();
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        tally.failed += 1;
    }
}

/// Print what a check's child reported and fold the outcome into the tally. Only the parent calls
/// this, and it calls it as it awaits each slot, which is what keeps results in table order however
/// the checks themselves finished.
fn forwardResult(io: std.Io, result: isolate.Result, tally: *Tally) void {
    tally.total += 1;
    if (result.verdict != .PASSED) tally.failed += 1;

    isolate.forward(io, result.report);
}

// --------------------------------------------------------- //

/// Max attempts per check. A startup-contention failure (a fresh server's accept threads starved by
/// a concurrent startup burst, so the probe or first client connect is refused) is transient, so
/// respawning the whole check almost always clears it. Real assertion failures are never retried.
const MAX_ATTEMPTS = 3;

/// One concurrent task: run a check in its own child process, retrying the whole check on a transient
/// startup error. The check is self-contained (the child spawns its own server and kills it on return,
/// even on error), so each retry respawns from a clean slate. A short backoff between attempts lets a
/// momentary load spike clear instead of respawning straight back into it.
///
/// Note:
/// - A TIMED_OUT check is never retried. The parent killed that child, so it ran no defers and left
///   its server running on the check's port. A second attempt would talk to the orphan rather than a
///   fresh server, which is worse than reporting the failure.
fn runIsolatedCheck(
    io: std.Io,
    self_exe: []const u8,
    label: []const u8,
    paths: []const []const u8,
    report_buf: []u8,
) isolate.Result {
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        const result = isolate.runIsolated(io, self_exe, label, paths, report_buf);
        if (result.verdict != .RETRIABLE or attempt >= MAX_ATTEMPTS) return result;

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(750), .awake) catch {};
    }
}

/// Child mode: run exactly one check, print its result line, and exit with the code the parent reads.
/// One attempt only, since retries belong to the parent.
fn runOneCheck(io: std.Io, arg_iter: *std.process.Args.Iterator) noreturn {
    const label = arg_iter.next() orelse exitMissing(isolate.ONLY_FLAG);
    const check = findCheck(label) orelse {
        std.debug.print("FAIL: no check named {s}\n", .{label});
        std.process.exit(isolate.Exit.FAILED);
    };

    var paths: [max_arity][]const u8 = undefined;
    for (0..check.arity) |i| paths[i] = arg_iter.next() orelse exitMissing(label);

    var tally: Tally = .{};
    const result = check.run(io, paths[0..check.arity]);
    report(label, result, &tally);

    if (result) {
        std.process.exit(isolate.Exit.PASSED);
    } else |err| {
        std.process.exit(if (isolate.isRetriable(err)) isolate.Exit.RETRIABLE else isolate.Exit.FAILED);
    }
}

/// Whether any in-flight slot in the current wave already holds this shared resource.
fn resourceBusy(active: []const ?[]const u8, res: []const u8) bool {
    for (active) |held| {
        if (held) |h| {
            if (std.mem.eql(u8, h, res)) return true;
        }
    }

    return false;
}

/// Hard ceiling on wave width, sizing the per-wave slot arrays. The live width is chosen at runtime
/// from the CPU count (see waveWidth) and is always <= this.
const WAVE_MAX = 16;

/// Live wave width scaled to the host. Each engine server spawns a worker pool sized to the CPU
/// count (a multiplexed server is one worker per CPU), so starting too many servers at once oversubscribes the
/// cores, starves a fresh server's accept threads, and the runner's connect probe then gets refused
/// (a flaky "ServerStartTimeout"). Conservative on purpose: a small box can only bring up a few of
/// these heavyweight servers at a time, a large box scales out. The per-check retry (see runCheck) is
/// the safety net for the occasional starved server, so this need not be tuned all the way to zero.
fn waveWidth(cpu: usize) usize {
    return std.math.clamp(cpu / 4, 2, WAVE_MAX);
}

/// Live cap on concurrent CPU-heavy TLS / QUIC checks (crypto handshakes plus a worker pool), tighter
/// than waveWidth. On a small box this serializes them so each gets the cores it needs to hand shake.
fn maxHeavy(cpu: usize) usize {
    return std.math.clamp(cpu / 12, 1, 3);
}

// --------------------------------------------------------- //

/// Run every check concurrently in waves whose width is scaled to the host, reporting each result as
/// its wave completes. Two limits shape a wave: a check whose `resource` tag is already in flight is
/// deferred so two checks that share a filesystem path never overlap, and at most `max_heavy` of the
/// CPU-heavy TLS / QUIC checks run at once so a wave cannot starve them into timeouts.
///
/// Output streams in stable table order: a wave is a contiguous block of checks, waves run in index
/// order, and within a wave the slots are awaited and reported in index order. report() runs only
/// here on the main thread (never on the concurrent check threads), so the prints never interleave.
fn runWaves(io: std.Io, self_exe: []const u8, all_paths: []const []const u8, tally: *Tally, cpu: usize) void {
    const wave_width = waveWidth(cpu);
    const max_heavy = maxHeavy(cpu);
    const Fut = std.Io.Future(isolate.Result);

    var check_idx: usize = 0;
    var path_cursor: usize = 0;
    while (check_idx < checks.len) {
        var futs: [WAVE_MAX]Fut = undefined;
        var slot_check: [WAVE_MAX]usize = undefined;
        var slot_res: [WAVE_MAX]?[]const u8 = undefined;
        // One report buffer per slot: the child writes its line here while the wave is in flight, and
        // the parent reads it back when it awaits that slot.
        var slot_report: [WAVE_MAX][isolate.REPORT_MAX]u8 = undefined;
        var count: usize = 0;
        var heavy_count: usize = 0;

        while (check_idx < checks.len and count < wave_width) {
            const c = checks[check_idx];
            if (common.skipDispatchOffPlatform(c.label)) {
                tally.total += 1;
                path_cursor += c.arity;
                check_idx += 1;
                continue;
            }
            if (c.resource) |res| {
                if (resourceBusy(slot_res[0..count], res)) break;
            }
            if (c.heavy and heavy_count == max_heavy) break;

            const paths = all_paths[path_cursor..][0..c.arity];
            futs[count] = io.async(runIsolatedCheck, .{ io, self_exe, c.label, paths, slot_report[count][0..] });
            slot_check[count] = check_idx;
            slot_res[count] = c.resource;

            if (c.heavy) heavy_count += 1;
            path_cursor += c.arity;
            count += 1;
            check_idx += 1;
        }

        for (0..count) |s| {
            const result = futs[s].await(io);
            forwardResult(io, result, tally);
        }
    }
}

pub fn main(process: std.process.Init) void {
    const io = process.io;

    var arg_iter = common.argsIterator(process.minimal.args);

    // argv[0] is how a check gets respawned as a child, so it is kept rather than skipped. zig build
    // invokes the runner by its emitted path, which is what std.process.spawn needs.
    const self_exe = arg_iter.next() orelse exitMissing("runner path");
    const first = arg_iter.next() orelse exitMissing(labelForPath(0));

    // Child mode: this copy runs one check and exits, it never schedules a wave.
    if (std.mem.eql(u8, first, isolate.ONLY_FLAG)) runOneCheck(io, &arg_iter);

    // Collect server paths in argv order, one slot per declared check path.
    var all_paths: [total_paths][]const u8 = undefined;
    all_paths[0] = first;
    var fill: usize = 1;
    while (fill < total_paths) : (fill += 1) {
        all_paths[fill] = arg_iter.next() orelse exitMissing(labelForPath(fill));
    }

    // Run all checks concurrently in bounded waves (width scaled to the host), streaming each wave's
    // results in table order as it completes.
    const cpu = std.Thread.getCpuCount() catch 4;

    var tally: Tally = .{};

    runWaves(io, self_exe, &all_paths, &tally, cpu);

    if (tally.failed > 0) {
        std.debug.print("{d}/{d} protocol(s) failed\n", .{ tally.failed, tally.total });
        std.process.exit(1);
    }

    std.debug.print("all {d} protocols passed\n", .{tally.total});
}
