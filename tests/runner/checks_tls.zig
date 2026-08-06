//! TLS-terminated protocol checks for all_runner.zig.
//!
//! Each spawns its server, waits for the listening port, then drives a native
//! client over TLS 1.3 (no curl, no openssl): https/1.1, the ed25519-cert
//! variant, h2, gRPC-over-h2, plus SSE and WebSocket over TLS.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");
const wire = @import("wire.zig");

const Tls = zix.Tls;
const Http2 = zix.Http2;

// --------------------------------------------------------- //

/// https/1.1 over TLS 1.3: spawn the server, GET / via the native zix.Http.Client (https,
/// trusting the fixture cert via tls_ca_path), assert 200 + body + the HSTS header. No curl.
pub fn runTls(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .response_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .read_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .max_response_body = 4096,
        .tls_ca_path = "examples/certs/ecdsa_p256_cert.pem",
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

/// Dual listener (config.tls_port, ADR-060): spawn ONE server, then assert the same route answers
/// cleartext on `port` AND https on `tls_port`. No curl, both via the native zix.Http.Client.
pub fn runTlsHttp1Dual(io: std.Io, server_path: []const u8, port: u16, tls_port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);
    try common.waitForTcpPort(io, &server_child, tls_port, common.START_TIMEOUT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .response_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .read_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .max_response_body = 4096,
        .tls_ca_path = "examples/certs/ecdsa_p256_cert.pem",
    });
    defer client.deinit();

    var clear_url_buf: [64]u8 = undefined;
    const clear_url = try std.fmt.bufPrint(&clear_url_buf, "http://localhost:{d}/", .{port});

    var clear_resp = try client.get(clear_url, .{});
    defer clear_resp.deinit();
    if (clear_resp.status() != 200) return error.UnexpectedStatus;
    if (std.mem.indexOf(u8, clear_resp.body(), "dual listener") == null) return error.UnexpectedBody;

    var tls_url_buf: [64]u8 = undefined;
    const tls_url = try std.fmt.bufPrint(&tls_url_buf, "https://localhost:{d}/", .{tls_port});

    var tls_resp = try client.get(tls_url, .{});
    defer tls_resp.deinit();
    if (tls_resp.status() != 200) return error.UnexpectedStatus;
    if (std.mem.indexOf(u8, tls_resp.body(), "dual listener") == null) return error.UnexpectedBody;
}

/// h2 over TLS 1.3: spawn the server, connect with the native zix.Tls client (ALPN h2), speak h2
/// over the encrypted ClientConnection (preface + SETTINGS + HEADERS GET /), assert :status 200.
pub fn runTlsHttp2(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    var random_bytes: [64]u8 = undefined;
    io.random(&random_bytes);
    var ch_buf: [600]u8 = undefined;
    const started = try Tls.Client.start(.{ .client_random = random_bytes[0..32].*, .ephemeral_secret = random_bytes[32..64].*, .alpn = &.{.H2} }, &ch_buf);
    var state = started.state;
    try wire.tlsWriteRecord(fd, 22, started.client_hello);

    var flight_buf: [8192]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| flight_len += try wire.tlsReadRecord(fd, flight_buf[flight_len..]);

    var fin_buf: [256]u8 = undefined;
    var finished = try Tls.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);
    if (finished.alpn != Tls.Alpn.H2) return error.AlpnNotH2;
    try wire.tlsWriteAll(fd, finished.client_finished);

    var req: [512]u8 = undefined;
    var n: usize = 0;
    @memcpy(req[0..Http2.PREFACE.len], Http2.PREFACE);
    n += Http2.PREFACE.len;
    var frame_head: [Http2.FRAME_HEADER_LEN]u8 = undefined;
    Http2.encodeFrameHeader(&frame_head, .{ .length = 0, .frame_type = Http2.FRAME_TYPE_SETTINGS, .flags = 0, .stream_id = 0 });
    @memcpy(req[n..][0..frame_head.len], &frame_head);
    n += frame_head.len;

    var header_buf: [256]u8 = undefined;
    var hpack_encoder = Http2.HpackEncoder.init(&header_buf);
    try hpack_encoder.writeHeader(":method", "GET");
    try hpack_encoder.writeHeader(":path", "/");
    try hpack_encoder.writeHeader(":scheme", "https");
    try hpack_encoder.writeHeader(":authority", "localhost");
    const hblock = hpack_encoder.encoded();
    Http2.encodeFrameHeader(&frame_head, .{ .length = @intCast(hblock.len), .frame_type = Http2.FRAME_TYPE_HEADERS, .flags = Http2.FLAG_END_HEADERS | Http2.FLAG_END_STREAM, .stream_id = 1 });
    @memcpy(req[n..][0..frame_head.len], &frame_head);
    n += frame_head.len;
    @memcpy(req[n..][0..hblock.len], hblock);
    n += hblock.len;

    var send_buf: [1024]u8 = undefined;
    try wire.tlsWriteAll(fd, finished.connection.writeAppData(req[0..n], &send_buf));

    var scanner: wire.H2Scanner = .{};
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var rec_buf: [17 * 1024]u8 = undefined;
        const rec_len = try wire.tlsReadRecord(fd, &rec_buf);
        if (rec_buf[0] != 23) continue;

        var plain_buf: [17 * 1024]u8 = undefined;
        const plain = try finished.connection.readAppData(rec_buf[0..rec_len], &plain_buf);
        if (try scanner.push(plain)) return;
    }

    return error.NoStatus200;
}

/// One unary gRPC call over TLS 1.3 (h2), exercising the multiplexed TLS path (tls_mux.zig): TLS
/// terminates in the epoll worker and the resumable gRPC h2 mux serves the call in place. Drives the
/// native zix.Tls client offering ALPN h2, then preface + SETTINGS + HEADERS (POST grpc route) + a
/// DATA frame with one length-prefixed message, and asserts the response HEADERS carry :status 200.
pub fn runTlsGrpc(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    var random_bytes: [64]u8 = undefined;
    io.random(&random_bytes);
    var ch_buf: [600]u8 = undefined;
    const started = try Tls.Client.start(.{ .client_random = random_bytes[0..32].*, .ephemeral_secret = random_bytes[32..64].*, .alpn = &.{.H2} }, &ch_buf);
    var state = started.state;
    try wire.tlsWriteRecord(fd, 22, started.client_hello);

    var flight_buf: [8192]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| flight_len += try wire.tlsReadRecord(fd, flight_buf[flight_len..]);

    var fin_buf: [256]u8 = undefined;
    var finished = try Tls.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);
    if (finished.alpn != Tls.Alpn.H2) return error.AlpnNotH2;
    try wire.tlsWriteAll(fd, finished.client_finished);

    // preface + empty SETTINGS + HEADERS (POST grpc route) + DATA (one length-prefixed message).
    var req: [512]u8 = undefined;
    var n: usize = 0;
    @memcpy(req[0..Http2.PREFACE.len], Http2.PREFACE);
    n += Http2.PREFACE.len;
    var frame_head: [Http2.FRAME_HEADER_LEN]u8 = undefined;
    Http2.encodeFrameHeader(&frame_head, .{ .length = 0, .frame_type = Http2.FRAME_TYPE_SETTINGS, .flags = 0, .stream_id = 0 });
    @memcpy(req[n..][0..frame_head.len], &frame_head);
    n += frame_head.len;

    var header_buf: [256]u8 = undefined;
    var hpack_encoder = Http2.HpackEncoder.init(&header_buf);
    try hpack_encoder.writeHeader(":method", "POST");
    try hpack_encoder.writeHeader(":path", "/helloworld.Greeter/SayHello");
    try hpack_encoder.writeHeader(":scheme", "https");
    try hpack_encoder.writeHeader(":authority", "localhost");
    try hpack_encoder.writeHeader("content-type", "application/grpc+proto");
    try hpack_encoder.writeHeader("te", "trailers");
    const hblock = hpack_encoder.encoded();
    Http2.encodeFrameHeader(&frame_head, .{ .length = @intCast(hblock.len), .frame_type = Http2.FRAME_TYPE_HEADERS, .flags = Http2.FLAG_END_HEADERS, .stream_id = 1 });
    @memcpy(req[n..][0..frame_head.len], &frame_head);
    n += frame_head.len;
    @memcpy(req[n..][0..hblock.len], hblock);
    n += hblock.len;

    const payload = "world";
    var msg: [5 + payload.len]u8 = undefined;
    msg[0] = 0;
    std.mem.writeInt(u32, msg[1..5], payload.len, .big);
    @memcpy(msg[5..], payload);
    Http2.encodeFrameHeader(&frame_head, .{ .length = @intCast(msg.len), .frame_type = Http2.FRAME_TYPE_DATA, .flags = Http2.FLAG_END_STREAM, .stream_id = 1 });
    @memcpy(req[n..][0..frame_head.len], &frame_head);
    n += frame_head.len;
    @memcpy(req[n..][0..msg.len], &msg);
    n += msg.len;

    var send_buf: [1024]u8 = undefined;
    try wire.tlsWriteAll(fd, finished.connection.writeAppData(req[0..n], &send_buf));

    var scanner: wire.H2Scanner = .{};
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var rec_buf: [17 * 1024]u8 = undefined;
        const rec_len = try wire.tlsReadRecord(fd, &rec_buf);
        if (rec_buf[0] != 23) continue;

        var plain_buf: [17 * 1024]u8 = undefined;
        const plain = try finished.connection.readAppData(rec_buf[0..rec_len], &plain_buf);
        if (try scanner.push(plain)) return;
    }

    return error.NoStatus200;
}

/// https/1.1 over TLS 1.3 with an Ed25519 server cert. The std-backed client cannot verify ed25519,
/// so drive the native zix.Tls client (offers + verifies ed25519), trust the fixture cert (chain +
/// hostname), GET / over the encrypted connection, assert 200 + body + the HSTS header. No curl.
pub fn runTlsHttp1Ed25519(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    var random_bytes: [64]u8 = undefined;
    io.random(&random_bytes);
    var ch_buf: [600]u8 = undefined;
    const started = try Tls.Client.start(.{ .client_random = random_bytes[0..32].*, .ephemeral_secret = random_bytes[32..64].* }, &ch_buf);
    var state = started.state;
    try wire.tlsWriteRecord(fd, 22, started.client_hello);

    var flight_buf: [8192]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| flight_len += try wire.tlsReadRecord(fd, flight_buf[flight_len..]);

    var fin_buf: [256]u8 = undefined;
    var finished = try Tls.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);

    // trust the Ed25519 server cert (chain + hostname) against the fixture anchor.
    var pem_buf: [8192]u8 = undefined;
    var pem_fixed_buf = std.heap.FixedBufferAllocator.init(&pem_buf);
    const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, "examples/certs/ed25519_cert.pem", pem_fixed_buf.allocator(), .limited(8192));
    var der_buf: [Tls.Client.max_server_cert_der]u8 = undefined;
    const anchor_der = try Tls.pemToDer(&der_buf, cert_pem);
    try finished.verifyServerCert(anchor_der, "localhost", common.realtimeSeconds(io));

    try wire.tlsWriteAll(fd, finished.client_finished);

    const req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var send_buf: [512]u8 = undefined;
    try wire.tlsWriteAll(fd, finished.connection.writeAppData(req, &send_buf));

    var recv_accum: [8192]u8 = undefined;
    var recv_len: usize = 0;
    var rounds: usize = 0;
    while (rounds < 32) : (rounds += 1) {
        var rec_buf: [17 * 1024]u8 = undefined;
        const rec_len = wire.tlsReadRecord(fd, &rec_buf) catch break;
        if (rec_buf[0] != 23) continue;

        var plain_buf: [17 * 1024]u8 = undefined;
        const plain = finished.connection.readAppData(rec_buf[0..rec_len], &plain_buf) catch break;
        if (recv_len + plain.len > recv_accum.len) break;
        @memcpy(recv_accum[recv_len..][0..plain.len], plain);
        recv_len += plain.len;

        if (std.mem.indexOf(u8, recv_accum[0..recv_len], "hello over tls 1.3 (ed25519)") != null) break;
    }

    const response = recv_accum[0..recv_len];
    if (std.mem.indexOf(u8, response, " 200 ") == null) return error.UnexpectedStatus;
    if (std.mem.indexOf(u8, response, "hello over tls 1.3 (ed25519)") == null) return error.UnexpectedBody;
    if (std.mem.indexOf(u8, response, "Strict-Transport-Security") == null) return error.MissingHsts;
}

/// SSE over TLS 1.3 (ADR-054): spawn the https streaming server, then confirm the SSE stream runs
/// over TLS (handshake, GET /events, decrypt records, Content-Type: text/event-stream + first event).
pub fn runTlsSse(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    try common.tlsSseFirstEvent(io, port);
}

/// WebSocket over TLS 1.3 (ADR-055): spawn the wss echo server, then confirm a frame echoes over TLS
/// (handshake, WS upgrade GET, encrypted 101, send a masked frame, decrypt the echoed frame).
pub fn runTlsWs(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    try common.tlsWsEcho(io, port);
}
