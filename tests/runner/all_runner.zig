// Test runner for all protocols and all dispatch models.
//
// Invoked by `zig build test-runner-all`. The build pushes one server binary
// path per check as argv, in the exact order of the `checks` table below: that
// table is the single source of truth for order, labels, ports, and arity, so
// adding a server means adding one row here (and the matching path in the
// build) rather than editing three parallel lists.
//
// The checks run concurrently in bounded waves (see runWaves): each check is
// self-contained (own child process, unique port), so they no longer block one
// another. Results are collected by table index and reported in table order, so
// the output stays stable. A check that shares a filesystem resource with
// another (the two /tmp/zix.sock users) carries a `resource` tag, and the
// scheduler never runs two checks with the same tag at once.
//
// The check bodies live in sibling files grouped by concern:
//   wire.zig         low-level TLS record / header / h2-frame-scan helpers
//   checks_http.zig  arena + http1 engines, h2c, http3
//   checks_tls.zig   https/1.1, h2, gRPC, SSE, WebSocket over TLS 1.3
//   checks_rpc.zig   gRPC + FIX
//   checks_misc.zig  TCP, UDP, UDS, Channel

const std = @import("std");
const common = @import("common.zig");
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

const zix_sock = "/tmp/zix.sock";
const zix_ipc_sock = "/tmp/zix_ipc.sock";

const checks = [_]Check{
    // Basic dispatch-model checks.
    .{ .label = "http-async", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp(io, paths[0], 9000);
        }
    }.f },
    .{ .label = "http-pool", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp(io, paths[0], 9001);
        }
    }.f },
    .{ .label = "http-mixed", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp(io, paths[0], 9002);
        }
    }.f },
    .{ .label = "http-epoll", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp(io, paths[0], 9003);
        }
    }.f },
    .{ .label = "http1-async", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp1(io, paths[0], 9015);
        }
    }.f },
    .{ .label = "http1-pool", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp1(io, paths[0], 9016);
        }
    }.f },
    .{ .label = "http1-mixed", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp1(io, paths[0], 9017);
        }
    }.f },
    .{ .label = "http1-epoll", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp1(io, paths[0], 9018);
        }
    }.f },
    .{ .label = "http1-uring", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp1(io, paths[0], 9019);
        }
    }.f },
    .{ .label = "grpc-async", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpc(io, paths[0], 9032);
        }
    }.f },
    .{ .label = "grpc-pool", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpc(io, paths[0], 9033);
        }
    }.f },
    .{ .label = "grpc-mixed", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpc(io, paths[0], 9034);
        }
    }.f },
    .{ .label = "grpc-epoll", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpc(io, paths[0], 9035);
        }
    }.f },
    .{ .label = "tcp-async", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runTcp(io, paths[0], 9043);
        }
    }.f },
    .{ .label = "tcp-pool", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runTcp(io, paths[0], 9044);
        }
    }.f },
    .{ .label = "tcp-mixed", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runTcp(io, paths[0], 9045);
        }
    }.f },
    .{ .label = "tcp-epoll", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_misc.runTcp(io, paths[0], 9046);
        }
    }.f },
    .{ .label = "fix-async", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runFix(io, paths[0], 9048);
        }
    }.f },
    .{ .label = "fix-pool", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runFix(io, paths[0], 9049);
        }
    }.f },
    .{ .label = "fix-mixed", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runFix(io, paths[0], 9050);
        }
    }.f },
    .{ .label = "fix-epoll", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runFix(io, paths[0], 9051);
        }
    }.f },
    .{ .label = "http2-async", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp2(io, paths[0], 9065);
        }
    }.f },
    .{ .label = "http2-pool", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp2(io, paths[0], 9066);
        }
    }.f },
    .{ .label = "http2-mixed", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp2(io, paths[0], 9067);
        }
    }.f },
    .{ .label = "http2-epoll", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp2(io, paths[0], 9068);
        }
    }.f },
    .{ .label = "http2-uring", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_http.runHttp2(io, paths[0], 9069);
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
            return checks_http.runWs(io, paths[0], 9028, "/ws");
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
    .{ .label = "grpc-location-async", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpcLocation(io, paths[0], 9038);
        }
    }.f },
    .{ .label = "grpc-location-pool", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpcLocation(io, paths[0], 9039);
        }
    }.f },
    .{ .label = "grpc-location-mixed", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpcLocation(io, paths[0], 9040);
        }
    }.f },
    .{ .label = "grpc-location-epoll", .run = &struct {
        fn f(io: std.Io, paths: []const []const u8) anyerror!void {
            return checks_rpc.runGrpcLocation(io, paths[0], 9041);
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
};

/// Total argv server paths the checks table consumes (sum of every row's arity).
const total_paths = blk: {
    var sum: usize = 0;
    for (checks) |c| sum += c.arity;
    break :blk sum;
};

// --------------------------------------------------------- //

/// Running tally so the final count is derived from the actual number of report() calls, not a
/// hardcoded total.
const Tally = struct { total: usize = 0, failed: usize = 0 };

fn exitMissing(name: []const u8) noreturn {
    std.debug.print("FAIL: missing {s} server path\n", .{name});
    std.process.exit(1);
}

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

// --------------------------------------------------------- //

/// Max attempts per check. A startup-contention failure (a fresh server's accept threads starved by
/// a concurrent startup burst, so the probe or first client connect is refused) is transient, so
/// respawning the whole check almost always clears it. Real assertion failures are never retried.
const MAX_ATTEMPTS = 3;

/// Whether an error is a transient startup-contention symptom worth retrying (versus a real failure).
/// These are all connection-establishment errors: under a startup burst a fresh server's accept path
/// is starved, so the probe or first client connect is refused, reset, or times out. A real check
/// failure is an assertion (UnexpectedStatus, UnexpectedBody, ...), which is never on this list.
fn isRetriable(err: anyerror) bool {
    return switch (err) {
        error.ServerStartTimeout,
        error.ConnectFailed,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.BrokenPipe,
        => true,
        else => false,
    };
}

/// One concurrent task: invoke a check's wrapper with the server path(s) it owns, retrying the whole
/// check on a transient startup error. The check is self-contained (it spawns its own server and
/// kills it on return, even on error), so each retry respawns from a clean slate. A short backoff
/// between attempts lets a momentary load spike clear instead of respawning straight back into it.
fn runCheck(io: std.Io, run: RunFn, paths: []const []const u8) anyerror!void {
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        if (run(io, paths)) {
            return;
        } else |err| {
            if (attempt >= MAX_ATTEMPTS or !isRetriable(err)) return err;

            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(750), .awake) catch {};
        }
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
/// count (a POOL server is ~3x CPU threads), so starting too many servers at once oversubscribes the
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

/// Run every check concurrently in waves whose width is scaled to the host, reporting each result as
/// its wave completes. Two limits shape a wave: a check whose `resource` tag is already in flight is
/// deferred so two checks that share a filesystem path never overlap, and at most `max_heavy` of the
/// CPU-heavy TLS / QUIC checks run at once so a wave cannot starve them into timeouts.
///
/// Output streams in stable table order: a wave is a contiguous block of checks, waves run in index
/// order, and within a wave the slots are awaited and reported in index order. report() runs only
/// here on the main thread (never on the concurrent check threads), so the prints never interleave.
fn runWaves(io: std.Io, all_paths: []const []const u8, tally: *Tally, cpu: usize) void {
    const wave_width = waveWidth(cpu);
    const max_heavy = maxHeavy(cpu);
    const Fut = std.Io.Future(anyerror!void);

    var check_idx: usize = 0;
    var path_cursor: usize = 0;
    while (check_idx < checks.len) {
        var futs: [WAVE_MAX]Fut = undefined;
        var slot_check: [WAVE_MAX]usize = undefined;
        var slot_res: [WAVE_MAX]?[]const u8 = undefined;
        var count: usize = 0;
        var heavy_count: usize = 0;

        while (check_idx < checks.len and count < wave_width) {
            const c = checks[check_idx];
            if (c.resource) |res| {
                if (resourceBusy(slot_res[0..count], res)) break;
            }
            if (c.heavy and heavy_count == max_heavy) break;

            const paths = all_paths[path_cursor..][0..c.arity];
            futs[count] = io.async(runCheck, .{ io, c.run, paths });
            slot_check[count] = check_idx;
            slot_res[count] = c.resource;

            if (c.heavy) heavy_count += 1;
            path_cursor += c.arity;
            count += 1;
            check_idx += 1;
        }

        for (0..count) |s| {
            const result = futs[s].await(io);
            report(checks[slot_check[s]].label, result, tally);
        }
    }
}

pub fn main(process: std.process.Init) void {
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    // Collect server paths in argv order, one slot per declared check path.
    var all_paths: [total_paths][]const u8 = undefined;
    var fill: usize = 0;
    for (checks) |c| {
        var k: usize = 0;
        while (k < c.arity) : (k += 1) {
            all_paths[fill] = arg_iter.next() orelse exitMissing(c.label);
            fill += 1;
        }
    }

    // Run all checks concurrently in bounded waves (width scaled to the host), streaming each wave's
    // results in table order as it completes.
    const cpu = std.Thread.getCpuCount() catch 4;

    var tally: Tally = .{};
    runWaves(io, &all_paths, &tally, cpu);

    if (tally.failed > 0) {
        std.debug.print("{d}/{d} protocol(s) failed\n", .{ tally.failed, tally.total });
        std.process.exit(1);
    }

    std.debug.print("all {d} protocols passed\n", .{tally.total});
}
