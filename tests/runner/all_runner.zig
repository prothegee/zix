// Test runner for all protocols and all dispatch models.
// Runs each protocol test sequentially. Exits 0 only when every test passes.
//
// Invoked by `zig build test-runner-all`.
// Server binary paths are passed as argv[1..60] by build.zig in this order:
//
// Basic dispatch-model servers (argv[1..23]):
//   http-async, http-pool, http-mixed, http-epoll,
//   http1-async, http1-pool, http1-mixed, http1-epoll, http1-uring,
//   grpc-async, grpc-pool, grpc-mixed, grpc-epoll,
//   tcp-async, tcp-pool, tcp-mixed, tcp-epoll,
//   fix-async, fix-pool, fix-mixed, fix-epoll,
//   http2-async, http2-pool, http2-mixed, http2-epoll, http2-uring,
//   udp, udp-raw, uds
//
// HTTP feature servers (argv[24..33]):
//   http-json, http-middleware, http-params, http-paths,
//   http-timeout-resp, http-xtra-headers, http-manual-concurrent,
//   http-static, http-sse, http-websocket
//
// HTTP1 feature servers (argv[34..44]):
//   http1-json, http1-middleware, http1-params, http1-paths,
//   http1-timeout-resp, http1-xtra-headers, http1-manual-concurrent,
//   http1-static, http1-sse, http1-websocket, http1-cache
//
// gRPC feature servers (argv[45..50]):
//   grpc-location-async, grpc-location-pool, grpc-location-mixed, grpc-location-epoll,
//   grpc-multi, grpc-timeout
//
// FIX trading (argv[51]):
//   fix-trading
//
// UDS HTTP pair (argv[52..53]):
//   uds-http-a (uds_server), uds-http-b (uds_http)
//
// Channel self-terminating (argv[54..56]):
//   channel-basic, channel-pipeline, channel-worker-pool
//
// Channel IPC pair (argv[57..58]):
//   channel-ipc-a, channel-ipc-b
//
// TLS servers (argv[59..60]):
//   tls-http1 (https/1.1), tls-http2 (h2)

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

// --------------------------------------------------------- //

const Packet = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

const MyUdpClient = zix.Udp.Client(Packet);

// --------------------------------------------------------- //

fn exitMissing(name: []const u8) noreturn {
    std.debug.print("FAIL: missing {s} server path\n", .{name});
    std.process.exit(1);
}

/// Running tally so the final count is derived from the actual number of report() calls, not a
/// hardcoded total.
const Tally = struct { total: usize = 0, failed: usize = 0 };

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

pub fn main(process: std.process.Init) void {
    var tally: Tally = .{};
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    // Basic dispatch-model servers.
    const http_async_path = arg_iter.next() orelse exitMissing("http-async");
    const http_pool_path = arg_iter.next() orelse exitMissing("http-pool");
    const http_mixed_path = arg_iter.next() orelse exitMissing("http-mixed");
    const http_epoll_path = arg_iter.next() orelse exitMissing("http-epoll");

    const http1_async_path = arg_iter.next() orelse exitMissing("http1-async");
    const http1_pool_path = arg_iter.next() orelse exitMissing("http1-pool");
    const http1_mixed_path = arg_iter.next() orelse exitMissing("http1-mixed");
    const http1_epoll_path = arg_iter.next() orelse exitMissing("http1-epoll");
    const http1_uring_path = arg_iter.next() orelse exitMissing("http1-uring");

    const grpc_async_path = arg_iter.next() orelse exitMissing("grpc-async");
    const grpc_pool_path = arg_iter.next() orelse exitMissing("grpc-pool");
    const grpc_mixed_path = arg_iter.next() orelse exitMissing("grpc-mixed");
    const grpc_epoll_path = arg_iter.next() orelse exitMissing("grpc-epoll");

    const tcp_async_path = arg_iter.next() orelse exitMissing("tcp-async");
    const tcp_pool_path = arg_iter.next() orelse exitMissing("tcp-pool");
    const tcp_mixed_path = arg_iter.next() orelse exitMissing("tcp-mixed");
    const tcp_epoll_path = arg_iter.next() orelse exitMissing("tcp-epoll");

    const fix_async_path = arg_iter.next() orelse exitMissing("fix-async");
    const fix_pool_path = arg_iter.next() orelse exitMissing("fix-pool");
    const fix_mixed_path = arg_iter.next() orelse exitMissing("fix-mixed");
    const fix_epoll_path = arg_iter.next() orelse exitMissing("fix-epoll");

    const http2_async_path = arg_iter.next() orelse exitMissing("http2-async");
    const http2_pool_path = arg_iter.next() orelse exitMissing("http2-pool");
    const http2_mixed_path = arg_iter.next() orelse exitMissing("http2-mixed");
    const http2_epoll_path = arg_iter.next() orelse exitMissing("http2-epoll");
    const http2_uring_path = arg_iter.next() orelse exitMissing("http2-uring");
    const udp_path = arg_iter.next() orelse exitMissing("udp");
    const udp_raw_path = arg_iter.next() orelse exitMissing("udp-raw");
    const uds_path = arg_iter.next() orelse exitMissing("uds");

    // HTTP feature servers.
    const http_json_path = arg_iter.next() orelse exitMissing("http-json");
    const http_middleware_path = arg_iter.next() orelse exitMissing("http-middleware");
    const http_params_path = arg_iter.next() orelse exitMissing("http-params");
    const http_paths_path = arg_iter.next() orelse exitMissing("http-paths");
    const http_timeout_resp_path = arg_iter.next() orelse exitMissing("http-timeout-resp");
    const http_xtra_headers_path = arg_iter.next() orelse exitMissing("http-xtra-headers");
    const http_manual_concurrent_path = arg_iter.next() orelse exitMissing("http-manual-concurrent");
    const http_static_path = arg_iter.next() orelse exitMissing("http-static");
    const http_sse_path = arg_iter.next() orelse exitMissing("http-sse");
    const http_websocket_path = arg_iter.next() orelse exitMissing("http-websocket");

    // HTTP1 feature servers.
    const http1_json_path = arg_iter.next() orelse exitMissing("http1-json");
    const http1_middleware_path = arg_iter.next() orelse exitMissing("http1-middleware");
    const http1_params_path = arg_iter.next() orelse exitMissing("http1-params");
    const http1_paths_path = arg_iter.next() orelse exitMissing("http1-paths");
    const http1_timeout_resp_path = arg_iter.next() orelse exitMissing("http1-timeout-resp");
    const http1_xtra_headers_path = arg_iter.next() orelse exitMissing("http1-xtra-headers");
    const http1_manual_concurrent_path = arg_iter.next() orelse exitMissing("http1-manual-concurrent");
    const http1_static_path = arg_iter.next() orelse exitMissing("http1-static");
    const http1_sse_path = arg_iter.next() orelse exitMissing("http1-sse");
    const http1_websocket_path = arg_iter.next() orelse exitMissing("http1-websocket");
    const http1_cache_path = arg_iter.next() orelse exitMissing("http1-cache");

    // gRPC feature servers.
    const grpc_location_async_path = arg_iter.next() orelse exitMissing("grpc-location-async");
    const grpc_location_pool_path = arg_iter.next() orelse exitMissing("grpc-location-pool");
    const grpc_location_mixed_path = arg_iter.next() orelse exitMissing("grpc-location-mixed");
    const grpc_location_epoll_path = arg_iter.next() orelse exitMissing("grpc-location-epoll");
    const grpc_multi_path = arg_iter.next() orelse exitMissing("grpc-multi");
    const grpc_timeout_path = arg_iter.next() orelse exitMissing("grpc-timeout");

    // FIX trading.
    const fix_trading_path = arg_iter.next() orelse exitMissing("fix-trading");

    // UDS HTTP pair.
    const uds_http_a_path = arg_iter.next() orelse exitMissing("uds-http-a");
    const uds_http_b_path = arg_iter.next() orelse exitMissing("uds-http-b");

    // Channel self-terminating.
    const channel_basic_path = arg_iter.next() orelse exitMissing("channel-basic");
    const channel_pipeline_path = arg_iter.next() orelse exitMissing("channel-pipeline");
    const channel_worker_pool_path = arg_iter.next() orelse exitMissing("channel-worker-pool");

    // Channel IPC pair.
    const channel_ipc_a_path = arg_iter.next() orelse exitMissing("channel-ipc-a");
    const channel_ipc_b_path = arg_iter.next() orelse exitMissing("channel-ipc-b");

    // tls (https/1.1 over TLS 1.3, the ed25519-cert variant, and h2 over TLS 1.3)
    const tls_http1_path = arg_iter.next() orelse exitMissing("tls-http1");
    const tls_http1_ed25519_path = arg_iter.next() orelse exitMissing("tls-http1-ed25519");
    const tls_http2_path = arg_iter.next() orelse exitMissing("tls-http2");

    // Basic dispatch-model tests.
    report("http-async", runHttp(io, http_async_path, 9000), &tally);
    report("http-pool", runHttp(io, http_pool_path, 9001), &tally);
    report("http-mixed", runHttp(io, http_mixed_path, 9002), &tally);
    report("http-epoll", runHttp(io, http_epoll_path, 9003), &tally);

    report("http1-async", runHttp1(io, http1_async_path, 9015), &tally);
    report("http1-pool", runHttp1(io, http1_pool_path, 9016), &tally);
    report("http1-mixed", runHttp1(io, http1_mixed_path, 9017), &tally);
    report("http1-epoll", runHttp1(io, http1_epoll_path, 9018), &tally);
    report("http1-uring", runHttp1(io, http1_uring_path, 9019), &tally);

    report("grpc-async", runGrpc(io, grpc_async_path, 9032), &tally);
    report("grpc-pool", runGrpc(io, grpc_pool_path, 9033), &tally);
    report("grpc-mixed", runGrpc(io, grpc_mixed_path, 9034), &tally);
    report("grpc-epoll", runGrpc(io, grpc_epoll_path, 9035), &tally);

    report("tcp-async", runTcp(io, tcp_async_path, 9043), &tally);
    report("tcp-pool", runTcp(io, tcp_pool_path, 9044), &tally);
    report("tcp-mixed", runTcp(io, tcp_mixed_path, 9045), &tally);
    report("tcp-epoll", runTcp(io, tcp_epoll_path, 9046), &tally);

    report("fix-async", runFix(io, fix_async_path, 9048), &tally);
    report("fix-pool", runFix(io, fix_pool_path, 9049), &tally);
    report("fix-mixed", runFix(io, fix_mixed_path, 9050), &tally);
    report("fix-epoll", runFix(io, fix_epoll_path, 9051), &tally);

    report("http2-async", runHttp2(io, http2_async_path, 9065), &tally);
    report("http2-pool", runHttp2(io, http2_pool_path, 9066), &tally);
    report("http2-mixed", runHttp2(io, http2_mixed_path, 9067), &tally);
    report("http2-epoll", runHttp2(io, http2_epoll_path, 9068), &tally);
    report("http2-uring", runHttp2(io, http2_uring_path, 9069), &tally);
    report("udp", runUdp(io, udp_path), &tally);
    report("udp-raw", runUdpRaw(io, udp_raw_path), &tally);
    report("uds", runUds(io, uds_path), &tally);

    // HTTP feature tests.
    report("http-json", runHttpGet(io, http_json_path, 9005, "/status", "", "server"), &tally);
    report("http-middleware", runHttpGet(io, http_middleware_path, 9006, "/public", "http://127.0.0.1", "public"), &tally);
    report("http-params", runHttpGet(io, http_params_path, 9007, "/echo?foo=bar", "", "foo"), &tally);
    report("http-paths", runHttpGet(io, http_paths_path, 9008, "/path", "", ""), &tally);
    report("http-timeout-resp", runHttpGet(io, http_timeout_resp_path, 9010, "/ping", "", "pong"), &tally);
    report("http-xtra-headers", runHttpGet(io, http_xtra_headers_path, 9011, "/info", "", ""), &tally);
    report("http-manual-concurrent", runHttpGet(io, http_manual_concurrent_path, 9014, "/", "", "hello"), &tally);
    report("http-static", runHttpStatic(io, http_static_path, 9009, "http_text_file.txt", "this is http text file example."), &tally);
    report("http-sse", runSse(io, http_sse_path, 9012), &tally);
    report("http-websocket", runWs(io, http_websocket_path, 9013, "/ws/lobby"), &tally);

    // HTTP1 feature tests.
    report("http1-json", runHttpGet(io, http1_json_path, 9020, "/status", "", "server"), &tally);
    report("http1-middleware", runHttpGet(io, http1_middleware_path, 9021, "/public", "http://127.0.0.1", "public"), &tally);
    report("http1-params", runHttpGet(io, http1_params_path, 9022, "/echo?foo=bar", "", "foo"), &tally);
    report("http1-paths", runHttpGet(io, http1_paths_path, 9023, "/path", "", ""), &tally);
    report("http1-timeout-resp", runHttpGet(io, http1_timeout_resp_path, 9025, "/ping", "", "pong"), &tally);
    report("http1-xtra-headers", runHttpGet(io, http1_xtra_headers_path, 9026, "/info", "", ""), &tally);
    report("http1-manual-concurrent", runHttpGet(io, http1_manual_concurrent_path, 9030, "/", "", "hello"), &tally);
    report("http1-static", runHttpStatic(io, http1_static_path, 9024, "http1_text_file.txt", "this is http1 text file example."), &tally);
    report("http1-sse", runSse(io, http1_sse_path, 9027), &tally);
    report("http1-websocket", runWs(io, http1_websocket_path, 9028, "/ws"), &tally);
    report("http1-cache", runHttpGet(io, http1_cache_path, 9031, "/cache?kb=1", "", "ok"), &tally);

    // gRPC feature tests.
    report("grpc-location-async", runGrpcLocation(io, grpc_location_async_path, 9038), &tally);
    report("grpc-location-pool", runGrpcLocation(io, grpc_location_pool_path, 9039), &tally);
    report("grpc-location-mixed", runGrpcLocation(io, grpc_location_mixed_path, 9040), &tally);
    report("grpc-location-epoll", runGrpcLocation(io, grpc_location_epoll_path, 9041), &tally);
    report("grpc-multi", runGrpcMulti(io, grpc_multi_path), &tally);
    report("grpc-timeout", runGrpcTimeout(io, grpc_timeout_path), &tally);

    // FIX trading test.
    report("fix-trading", runFixTrading(io, fix_trading_path), &tally);

    // UDS HTTP test.
    report("uds-http", runUdsHttp(io, uds_http_a_path, uds_http_b_path), &tally);

    // Channel self-terminating tests.
    report("channel-basic", runChannelSelfterm(io, channel_basic_path), &tally);
    report("channel-pipeline", runChannelSelfterm(io, channel_pipeline_path), &tally);
    report("channel-worker-pool", runChannelSelfterm(io, channel_worker_pool_path), &tally);

    // Channel IPC test.
    report("channel-ipc", runChannelIpc(io, channel_ipc_a_path, channel_ipc_b_path), &tally);

    // TLS tests (native clients, no curl): https/1.1 (std-backed), https/1.1 ed25519 (zix.Tls
    // client), h2 (zix.Tls client).
    report("tls-http1", runTls(io, tls_http1_path, 9060), &tally);
    report("tls-http1-ed25519", runTlsHttp1Ed25519(io, tls_http1_ed25519_path, 9062), &tally);
    report("tls-http2", runTlsHttp2(io, tls_http2_path, 9061), &tally);

    if (tally.failed > 0) {
        std.debug.print("{d}/{d} protocol(s) failed\n", .{ tally.failed, tally.total });
        std.process.exit(1);
    }

    std.debug.print("all {d} protocols passed\n", .{tally.total});
}

/// https/1.1 over TLS 1.3: spawn the server, GET / via the native zix.Http.Client (https,
/// trusting the fixture cert via tls_ca_path), assert 200 + body + the HSTS header. No curl.
fn runTls(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
        .tls_ca_path = "examples/tls/certs/ecdsa_p256_cert.pem",
    });
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{port});

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (std.mem.indexOf(u8, resp.body(), "hello over tls 1.3") == null) return error.UnexpectedBody;
    if (resp.header("Strict-Transport-Security") == null) return error.MissingHsts;
}

/// h2 over TLS 1.3: spawn the server, connect with the native zix.Tls client (ALPN h2), speak h2
/// over the encrypted ClientConnection (preface + SETTINGS + HEADERS GET /), assert :status 200.
fn runTlsHttp2(io: std.Io, server_path: []const u8, port: u16) !void {
    const Tls = zix.Tls;
    const Http2 = zix.Http2;
    const linux = std.os.linux;

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    var rnd: [64]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var ch_buf: [600]u8 = undefined;
    const started = try Tls.Client.start(.{ .client_random = rnd[0..32].*, .ephemeral_secret = rnd[32..64].*, .alpn = &.{.H2} }, &ch_buf);
    var state = started.state;
    try tlsWriteRecord(fd, 22, started.client_hello);

    var flight_buf: [8192]u8 = undefined;
    var flen: usize = 0;
    for (0..3) |_| flen += try tlsReadRecord(fd, flight_buf[flen..]);

    var fin_buf: [256]u8 = undefined;
    var finished = try Tls.Client.finish(&state, flight_buf[0..flen], &fin_buf);
    if (finished.alpn != Tls.Alpn.H2) return error.AlpnNotH2;
    try tlsWriteAll(fd, finished.client_finished);

    var req: [512]u8 = undefined;
    var n: usize = 0;
    @memcpy(req[0..Http2.PREFACE.len], Http2.PREFACE);
    n += Http2.PREFACE.len;
    var fh: [Http2.FRAME_HEADER_LEN]u8 = undefined;
    Http2.encodeFrameHeader(&fh, .{ .length = 0, .frame_type = Http2.FRAME_TYPE_SETTINGS, .flags = 0, .stream_id = 0 });
    @memcpy(req[n..][0..fh.len], &fh);
    n += fh.len;

    var hbuf: [256]u8 = undefined;
    var enc = Http2.HpackEncoder.init(&hbuf);
    try enc.writeHeader(":method", "GET");
    try enc.writeHeader(":path", "/");
    try enc.writeHeader(":scheme", "https");
    try enc.writeHeader(":authority", "localhost");
    const hblock = enc.encoded();
    Http2.encodeFrameHeader(&fh, .{ .length = @intCast(hblock.len), .frame_type = Http2.FRAME_TYPE_HEADERS, .flags = Http2.FLAG_END_HEADERS | Http2.FLAG_END_STREAM, .stream_id = 1 });
    @memcpy(req[n..][0..fh.len], &fh);
    n += fh.len;
    @memcpy(req[n..][0..hblock.len], hblock);
    n += hblock.len;

    var send_buf: [1024]u8 = undefined;
    try tlsWriteAll(fd, finished.connection.writeAppData(req[0..n], &send_buf));

    var acc: [16384]u8 = undefined;
    var acc_len: usize = 0;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var rec_buf: [17 * 1024]u8 = undefined;
        const rec_len = try tlsReadRecord(fd, &rec_buf);
        if (rec_buf[0] != 23) continue;

        var dec: [17 * 1024]u8 = undefined;
        const plain = try finished.connection.readAppData(rec_buf[0..rec_len], &dec);
        @memcpy(acc[acc_len..][0..plain.len], plain);
        acc_len += plain.len;

        var off: usize = 0;
        while (off + Http2.FRAME_HEADER_LEN <= acc_len) {
            const frame = Http2.parseFrameHeader(acc[off..][0..Http2.FRAME_HEADER_LEN]);
            const total = Http2.FRAME_HEADER_LEN + @as(usize, frame.length);
            if (off + total > acc_len) break;

            const payload = acc[off + Http2.FRAME_HEADER_LEN .. off + total];
            if (frame.frame_type == Http2.FRAME_TYPE_HEADERS) {
                var hdec = Http2.HpackDecoder.init();
                var hdrs: [Http2.MAX_HEADERS]Http2.Header = undefined;
                var scratch: [4096]u8 = undefined;
                const cnt = try hdec.decode(payload, &hdrs, &scratch);
                for (hdrs[0..cnt]) |h| {
                    if (std.mem.eql(u8, h.name, ":status") and std.mem.eql(u8, h.value, "200")) return;
                }
            }
            off += total;
        }
        if (off >= acc_len) {
            acc_len = 0;
        } else if (off > 0) {
            std.mem.copyForwards(u8, acc[0 .. acc_len - off], acc[off..acc_len]);
            acc_len -= off;
        }
    }

    return error.NoStatus200;
}

/// https/1.1 over TLS 1.3 with an Ed25519 server cert. The std-backed client cannot verify ed25519,
/// so drive the native zix.Tls client (offers + verifies ed25519), trust the fixture cert (chain +
/// hostname), GET / over the encrypted connection, assert 200 + body + the HSTS header. No curl.
fn runTlsHttp1Ed25519(io: std.Io, server_path: []const u8, port: u16) !void {
    const Tls = zix.Tls;
    const linux = std.os.linux;

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    var rnd: [64]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var ch_buf: [600]u8 = undefined;
    const started = try Tls.Client.start(.{ .client_random = rnd[0..32].*, .ephemeral_secret = rnd[32..64].* }, &ch_buf);
    var state = started.state;
    try tlsWriteRecord(fd, 22, started.client_hello);

    var flight_buf: [8192]u8 = undefined;
    var flen: usize = 0;
    for (0..3) |_| flen += try tlsReadRecord(fd, flight_buf[flen..]);

    var fin_buf: [256]u8 = undefined;
    var finished = try Tls.Client.finish(&state, flight_buf[0..flen], &fin_buf);

    // trust the Ed25519 server cert (chain + hostname) against the fixture anchor.
    var pem_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&pem_buf);
    const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, "examples/tls/certs/ed25519_cert.pem", fba.allocator(), .limited(8192));
    var der_buf: [Tls.Client.max_server_cert_der]u8 = undefined;
    const anchor_der = try Tls.pemToDer(&der_buf, cert_pem);
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    try finished.verifyServerCert(anchor_der, "localhost", ts.sec);

    try tlsWriteAll(fd, finished.client_finished);

    const req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var send_buf: [512]u8 = undefined;
    try tlsWriteAll(fd, finished.connection.writeAppData(req, &send_buf));

    var acc: [8192]u8 = undefined;
    var acc_len: usize = 0;
    var rounds: usize = 0;
    while (rounds < 32) : (rounds += 1) {
        var rec_buf: [17 * 1024]u8 = undefined;
        const rec_len = tlsReadRecord(fd, &rec_buf) catch break;
        if (rec_buf[0] != 23) continue;

        var dec: [17 * 1024]u8 = undefined;
        const plain = finished.connection.readAppData(rec_buf[0..rec_len], &dec) catch break;
        if (acc_len + plain.len > acc.len) break;
        @memcpy(acc[acc_len..][0..plain.len], plain);
        acc_len += plain.len;

        if (std.mem.indexOf(u8, acc[0..acc_len], "hello over tls 1.3 (ed25519)") != null) break;
    }

    const response = acc[0..acc_len];
    if (std.mem.indexOf(u8, response, " 200 ") == null) return error.UnexpectedStatus;
    if (std.mem.indexOf(u8, response, "hello over tls 1.3 (ed25519)") == null) return error.UnexpectedBody;
    if (std.mem.indexOf(u8, response, "Strict-Transport-Security") == null) return error.MissingHsts;
}

fn tlsWriteRecord(fd: std.posix.fd_t, content_type: u8, msg: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = content_type;
    header[1] = 0x03;
    header[2] = 0x03;
    std.mem.writeInt(u16, header[3..5], @intCast(msg.len), .big);
    try tlsWriteAll(fd, &header);
    try tlsWriteAll(fd, msg);
}

fn tlsReadRecord(fd: std.posix.fd_t, buf: []u8) !usize {
    try tlsReadAll(fd, buf[0..5]);
    const len = std.mem.readInt(u16, buf[3..5], .big);
    try tlsReadAll(fd, buf[5 .. 5 + len]);

    return 5 + len;
}

fn tlsReadAll(fd: std.posix.fd_t, buf: []u8) !void {
    var read: usize = 0;
    while (read < buf.len) {
        const rc = std.os.linux.read(fd, buf[read..].ptr, buf.len - read);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (rc == 0) return error.ConnectionClosed;
        read += rc;
    }
}

fn tlsWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.WriteFailed,
        }
        written += rc;
    }
}

// --------------------------------------------------------- //

fn runHttp(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (resp.body().len == 0) return error.EmptyBody;
}

fn runHttp1(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (!std.mem.eql(u8, resp.body(), "Hello, World!")) return error.UnexpectedBody;
}

fn runGrpc(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = port }, io);
    defer client.deinit();

    var resp_buf: [256]u8 = undefined;
    const resp = try client.unary(
        "/helloworld.Greeter/SayHello",
        "application/grpc+proto",
        "runner",
        &resp_buf,
    );

    if (!std.mem.startsWith(u8, resp, "Hello,")) return error.UnexpectedResponse;
}

fn runTcp(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var client = try zix.Tcp.Client.connect(.{
        .ip = "127.0.0.1",
        .port = port,
        .recv_timeout_ms = 3000,
    }, io);
    defer client.deinit(io);

    try client.sendMsg(io, "ping");

    var recv_buf: [256]u8 = undefined;
    const reply = try client.recvMsg(io, &recv_buf);

    if (!std.mem.eql(u8, reply, "Hello from zix TCP Server")) return error.UnexpectedReply;
}

fn runFix(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = port,
        .comp_id = "RUNNER",
        .target_comp_id = "ZIX",
    }, io);
    defer client.deinit(io);

    try client.logon(io, 30);

    const order_fields = [_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = "RUN001" },
        .{ .tag = .Symbol, .value = "TEST" },
        .{ .tag = .Side, .value = "1" },
        .{ .tag = .OrderQty, .value = "1" },
        .{ .tag = .OrdType, .value = "2" },
        .{ .tag = .Price, .value = "1.00" },
    };
    try client.sendMessage(io, zix.Fix.MsgType.NewOrderSingle, &order_fields);

    const raw = try client.recvMessage(io);
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    const field_count = try zix.Fix.parseFields(raw, &fields);
    const symbol = zix.Fix.getField(fields[0..field_count], .Symbol) orelse return error.MissingSymbolField;

    if (!std.mem.eql(u8, symbol, "TEST")) return error.UnexpectedSymbol;

    try client.logout(io);
}

fn runUdp(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(600), .awake);

    var client = try MyUdpClient.init(.{
        .ip = "127.0.0.1",
        .server_port = 9054,
        .bind_ip = "127.0.0.1",
        .bind_port = 9191,
        .port_mode = .REQUIRED,
        .endianness = .LITTLE,
        .recv_timeout_ms = 3000,
    }, io);
    defer client.deinit();

    var my_id: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&my_id, "runner", .{}) catch {};

    const pkt = Packet{
        .id = my_id,
        .packet_type = 1,
        .register = 42,
        .position = .{ 0.0, 0.0, 0.0 },
    };
    try client.send(pkt);

    const feedback = try client.receiveFeedback();
    switch (feedback) {
        .packet => |received| {
            if (received.packet_type != pkt.packet_type) return error.UnexpectedPacketType;
        },
        .ack => {},
        .nack => return error.UnexpectedNack,
    }
}

fn runUdpRaw(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    // UDP has no connection handshake, give the server time to bind.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(600), .awake);

    const local = try std.Io.net.IpAddress.parse("127.0.0.1", 9193);
    const sock = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sock.close(io);

    const server = try std.Io.net.IpAddress.parse("127.0.0.1", 9064);
    try sock.send(io, &server, "raw-echo-ping");

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(3000),
        .clock = .awake,
    } };

    var buf: [64]u8 = undefined;
    const msg = try sock.receiveTimeout(io, &buf, timeout);
    if (!std.mem.eql(u8, msg.data, "raw-echo-ping")) return error.EchoMismatch;
}

fn runHttp2(io: std.Io, server_path: []const u8, port: u16) !void {
    const Http2 = zix.Http2;

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    // Prior-knowledge h2c: preface, empty SETTINGS, then HEADERS GET / on stream 1.
    var req: [512]u8 = undefined;
    var n: usize = 0;
    @memcpy(req[0..Http2.PREFACE.len], Http2.PREFACE);
    n += Http2.PREFACE.len;

    var fh: [Http2.FRAME_HEADER_LEN]u8 = undefined;
    Http2.encodeFrameHeader(&fh, .{ .length = 0, .frame_type = Http2.FRAME_TYPE_SETTINGS, .flags = 0, .stream_id = 0 });
    @memcpy(req[n..][0..fh.len], &fh);
    n += fh.len;

    var hbuf: [256]u8 = undefined;
    var enc = Http2.HpackEncoder.init(&hbuf);
    try enc.writeHeader(":method", "GET");
    try enc.writeHeader(":path", "/");
    try enc.writeHeader(":scheme", "http");
    try enc.writeHeader(":authority", "localhost");
    const hblock = enc.encoded();
    Http2.encodeFrameHeader(&fh, .{ .length = @intCast(hblock.len), .frame_type = Http2.FRAME_TYPE_HEADERS, .flags = Http2.FLAG_END_HEADERS | Http2.FLAG_END_STREAM, .stream_id = 1 });
    @memcpy(req[n..][0..fh.len], &fh);
    n += fh.len;
    @memcpy(req[n..][0..hblock.len], hblock);
    n += hblock.len;

    try tlsWriteAll(fd, req[0..n]);

    var acc: [16384]u8 = undefined;
    var acc_len: usize = 0;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const rc = std.os.linux.read(fd, acc[acc_len..].ptr, acc.len - acc_len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (rc == 0) return error.ConnectionClosed;
        acc_len += rc;

        var off: usize = 0;
        while (off + Http2.FRAME_HEADER_LEN <= acc_len) {
            const frame = Http2.parseFrameHeader(acc[off..][0..Http2.FRAME_HEADER_LEN]);
            const total = Http2.FRAME_HEADER_LEN + @as(usize, frame.length);
            if (off + total > acc_len) break;

            const payload = acc[off + Http2.FRAME_HEADER_LEN .. off + total];
            if (frame.frame_type == Http2.FRAME_TYPE_HEADERS) {
                var hdec = Http2.HpackDecoder.init();
                var hdrs: [Http2.MAX_HEADERS]Http2.Header = undefined;
                var scratch: [4096]u8 = undefined;
                const cnt = try hdec.decode(payload, &hdrs, &scratch);
                for (hdrs[0..cnt]) |h| {
                    if (std.mem.eql(u8, h.name, ":status") and std.mem.eql(u8, h.value, "200")) return;
                }
            }
            off += total;
        }
        if (off >= acc_len) {
            acc_len = 0;
        } else if (off > 0) {
            std.mem.copyForwards(u8, acc[0 .. acc_len - off], acc[off..acc_len]);
            acc_len -= off;
        }
    }

    return error.NoStatus200;
}

fn runUds(io: std.Io, server_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, "/tmp/zix.sock") catch {};

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForUdsSocket(io, "/tmp/zix.sock", 5000);

    var client = try zix.Uds.Client.connect(.{
        .path = "/tmp/zix.sock",
        .recv_timeout_ms = 3000,
    }, io);
    defer client.deinit(io);

    try client.sendMsg(io, "get");

    var recv_buf: [64]u8 = undefined;
    const reply = try client.recvMsg(io, &recv_buf);

    if (reply.len == 0) return error.EmptyReply;
}

// --------------------------------------------------------- //

fn runHttpGet(
    io: std.Io,
    server_path: []const u8,
    port: u16,
    route: []const u8,
    origin: []const u8,
    expected_substr: []const u8,
) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 16384,
    });
    defer client.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, route });

    const origin_header = std.http.Header{ .name = "Origin", .value = origin };
    const headers: []const std.http.Header = if (origin.len > 0) &[_]std.http.Header{origin_header} else &.{};

    var resp = try client.get(url, .{ .headers = headers });
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;

    if (expected_substr.len > 0) {
        if (!std.mem.containsAtLeast(u8, resp.body(), 1, expected_substr)) return error.MissingExpectedSubstring;
    }
}

fn runHttpStatic(
    io: std.Io,
    server_path: []const u8,
    port: u16,
    filename: []const u8,
    file_content: []const u8,
) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var file_path_buf: [256]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_path_buf, "public/secret/{s}", .{filename});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = file_content });

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "http://127.0.0.1:{d}/secret/{s}?sec=abc123",
        .{ port, filename },
    );

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
}

fn runSse(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/events", .{port});

    var sse_client = zix.Http.SseClient.init(.{ .io = io, .connect_timeout_ms = 3000 });
    var stream = try sse_client.open(url);
    defer stream.deinit();

    var buf: [4096]u8 = undefined;
    const event = try stream.next(&buf) orelse return error.NoSseEvent;

    if (event.data.len == 0) return error.EmptySseEvent;
}

fn runWs(io: std.Io, server_path: []const u8, port: u16, ws_route: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}{s}", .{ port, ws_route });

    var wsc = zix.Http.WsClient.init(.{ .io = io, .connect_timeout_ms = 3000 });
    var conn = try wsc.connect(url);
    defer conn.deinit();

    try conn.send(.text, "hello");

    var payload_buf: [256]u8 = undefined;
    const frame = try conn.recv(&payload_buf) orelse return error.NoWsFrame;

    if (!std.mem.containsAtLeast(u8, frame.payload, 1, "hello")) return error.UnexpectedEcho;
}

// --------------------------------------------------------- //

fn runGrpcLocation(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = port }, io);
    defer client.deinit();

    var req_buf: [128]u8 = undefined;
    var pos: usize = 0;
    pos += zix.Grpc.encodeDouble(1, 106.8, req_buf[pos..]);
    pos += zix.Grpc.encodeDouble(2, -6.2, req_buf[pos..]);
    pos += zix.Grpc.encodeString(3, "runner", req_buf[pos..]);

    var resp_buf: [256]u8 = undefined;
    const resp = try client.unary(
        "/location.Location/SendLocationAndSave",
        "application/grpc+proto",
        req_buf[0..pos],
        &resp_buf,
    );

    if (resp.len == 0) return error.EmptyResponse;
}

fn runGrpcMulti(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, 9042, 5000);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 9042 }, io);
    defer client.deinit();

    var hello_req_buf: [64]u8 = undefined;
    var hello_req_pos: usize = 0;
    hello_req_pos += zix.Grpc.encodeString(1, "runner", hello_req_buf[hello_req_pos..]);

    var hello_buf: [256]u8 = undefined;
    const hello_raw = try client.unary(
        "/helloworld.Greeter/SayHello",
        "application/grpc+proto",
        hello_req_buf[0..hello_req_pos],
        &hello_buf,
    );

    var hello_reader = zix.Grpc.MessageReader.init(hello_raw);
    var hello_found = false;
    while (hello_reader.next() catch null) |field| {
        if (field.field_number == 1) {
            if (!std.mem.startsWith(u8, field.payload, "Hello,")) return error.UnexpectedHelloResponse;
            hello_found = true;
        }
    }
    if (!hello_found) return error.MissingHelloField;

    var loc_req_buf: [128]u8 = undefined;
    var pos: usize = 0;
    pos += zix.Grpc.encodeDouble(1, 106.8, loc_req_buf[pos..]);
    pos += zix.Grpc.encodeDouble(2, -6.2, loc_req_buf[pos..]);
    pos += zix.Grpc.encodeString(3, "runner", loc_req_buf[pos..]);

    var loc_resp_buf: [256]u8 = undefined;
    const loc_resp = try client.unary(
        "/location.Location/SendLocationAndSave",
        "application/grpc+proto",
        loc_req_buf[0..pos],
        &loc_resp_buf,
    );

    if (loc_resp.len == 0) return error.EmptyLocationResponse;
}

fn runGrpcTimeout(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, 9037, 5000);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 9037 }, io);
    defer client.deinit();

    var resp_buf: [256]u8 = undefined;
    const resp = try client.unary(
        "/helloworld.Greeter/SayHello",
        "application/grpc+proto",
        "runner",
        &resp_buf,
    );

    if (!std.mem.startsWith(u8, resp, "Hello,")) return error.UnexpectedResponse;
}

// --------------------------------------------------------- //

fn runFixTrading(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, 9053, 5000);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = 9053,
        .comp_id = "RUNNER",
        .target_comp_id = "ZIX",
    }, io);
    defer client.deinit(io);

    try client.logon(io, 30);

    const order_fields = [_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = "TR001" },
        .{ .tag = .Symbol, .value = "ZIXTEST" },
        .{ .tag = .Side, .value = "1" },
        .{ .tag = .OrderQty, .value = "100" },
        .{ .tag = .OrdType, .value = "2" },
        .{ .tag = .Price, .value = "42.00" },
    };
    try client.sendMessage(io, zix.Fix.MsgType.NewOrderSingle, &order_fields);

    const raw = try client.recvMessage(io);
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    const field_count = try zix.Fix.parseFields(raw, &fields);
    const msg_type = zix.Fix.getField(fields[0..field_count], .MsgType) orelse return error.MissingMsgType;

    if (!std.mem.eql(u8, msg_type, "8")) return error.UnexpectedMsgType;

    try client.logout(io);
}

// --------------------------------------------------------- //

fn runUdsHttp(io: std.Io, uds_server_path: []const u8, uds_http_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, "/tmp/zix.sock") catch {};

    var uds_child = try common.spawnServer(io, uds_server_path);
    defer uds_child.kill(io);

    try common.waitForUdsSocket(io, "/tmp/zix.sock", 5000);

    var http_child = try common.spawnServer(io, uds_http_path);
    defer http_child.kill(io);

    try common.waitForTcpPort(io, &http_child, 9055, 5000);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var resp = try client.get("http://127.0.0.1:9055/data", .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (!std.mem.containsAtLeast(u8, resp.body(), 1, "count")) return error.MissingCountField;
}

// --------------------------------------------------------- //

fn runChannelSelfterm(io: std.Io, binary_path: []const u8) !void {
    var child = try common.spawnServer(io, binary_path);
    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code != 0) return error.NonZeroExit;
        },
        .signal, .stopped, .unknown => return error.UnexpectedTermination,
    }
}

fn runChannelIpc(io: std.Io, ipc_a_path: []const u8, ipc_b_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, "/tmp/zix_ipc.sock") catch {};

    var child_a = try common.spawnServer(io, ipc_a_path);
    defer child_a.kill(io);

    try common.waitForUdsSocket(io, "/tmp/zix_ipc.sock", 5000);

    var child_b = try common.spawnServer(io, ipc_b_path);
    defer child_b.kill(io);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1500), .awake);
}
