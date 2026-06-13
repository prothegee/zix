// Test runner for all protocols and all dispatch models.
// Runs each protocol test sequentially. Exits 0 only when every test passes.
//
// Invoked by `zig build test-runner-all`.
// Server binary paths are passed as argv[1..56] by build.zig in this order:
//
// Basic dispatch-model servers (argv[1..22]):
//   http-async, http-pool, http-mixed, http-epoll,
//   http1-async, http1-pool, http1-mixed, http1-epoll,
//   grpc-async, grpc-pool, grpc-mixed, grpc-epoll,
//   tcp-async, tcp-pool, tcp-mixed, tcp-epoll,
//   fix-async, fix-pool, fix-mixed, fix-epoll,
//   udp, uds
//
// HTTP feature servers (argv[23..32]):
//   http-json, http-middleware, http-params, http-paths,
//   http-timeout-resp, http-xtra-headers, http-manual-concurrent,
//   http-static, http-sse, http-websocket
//
// HTTP1 feature servers (argv[33..42]):
//   http1-json, http1-middleware, http1-params, http1-paths,
//   http1-timeout-resp, http1-xtra-headers, http1-manual-concurrent,
//   http1-static, http1-sse, http1-websocket
//
// gRPC feature servers (argv[43..48]):
//   grpc-location-async, grpc-location-pool, grpc-location-mixed, grpc-location-epoll,
//   grpc-multi, grpc-timeout
//
// FIX trading (argv[49]):
//   fix-trading
//
// UDS HTTP pair (argv[50..51]):
//   uds-http-a (uds_server), uds-http-b (uds_http)
//
// Channel self-terminating (argv[52..54]):
//   channel-basic, channel-pipeline, channel-worker-pool
//
// Channel IPC pair (argv[55..56]):
//   channel-ipc-a, channel-ipc-b

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

fn report(label: []const u8, result: anyerror!void, failed: *usize) void {
    if (result) {
        std.debug.print("PASS {s}\n", .{label});
    } else |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        failed.* += 1;
    }
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var failed: usize = 0;
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

    const udp_path = arg_iter.next() orelse exitMissing("udp");
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

    // Basic dispatch-model tests.
    report("http-async", runHttp(io, http_async_path), &failed);
    report("http-pool", runHttp(io, http_pool_path), &failed);
    report("http-mixed", runHttp(io, http_mixed_path), &failed);
    report("http-epoll", runHttp(io, http_epoll_path), &failed);

    report("http1-async", runHttp1(io, http1_async_path), &failed);
    report("http1-pool", runHttp1(io, http1_pool_path), &failed);
    report("http1-mixed", runHttp1(io, http1_mixed_path), &failed);
    report("http1-epoll", runHttp1(io, http1_epoll_path), &failed);

    report("grpc-async", runGrpc(io, grpc_async_path), &failed);
    report("grpc-pool", runGrpc(io, grpc_pool_path), &failed);
    report("grpc-mixed", runGrpc(io, grpc_mixed_path), &failed);
    report("grpc-epoll", runGrpc(io, grpc_epoll_path), &failed);

    report("tcp-async", runTcp(io, tcp_async_path, 9300), &failed);
    report("tcp-pool", runTcp(io, tcp_pool_path, 9301), &failed);
    report("tcp-mixed", runTcp(io, tcp_mixed_path, 9302), &failed);
    report("tcp-epoll", runTcp(io, tcp_epoll_path, 9303), &failed);

    report("fix-async", runFix(io, fix_async_path), &failed);
    report("fix-pool", runFix(io, fix_pool_path), &failed);
    report("fix-mixed", runFix(io, fix_mixed_path), &failed);
    report("fix-epoll", runFix(io, fix_epoll_path), &failed);

    report("udp", runUdp(io, udp_path), &failed);
    report("uds", runUds(io, uds_path), &failed);

    // HTTP feature tests.
    report("http-json", runHttpGet(io, http_json_path, 9001, "/status", "", "server"), &failed);
    report("http-middleware", runHttpGet(io, http_middleware_path, 9003, "/public", "http://127.0.0.1", "public"), &failed);
    report("http-params", runHttpGet(io, http_params_path, 9004, "/echo?foo=bar", "", "foo"), &failed);
    report("http-paths", runHttpGet(io, http_paths_path, 9005, "/path", "", ""), &failed);
    report("http-timeout-resp", runHttpGet(io, http_timeout_resp_path, 9007, "/ping", "", "pong"), &failed);
    report("http-xtra-headers", runHttpGet(io, http_xtra_headers_path, 9009, "/info", "", ""), &failed);
    report("http-manual-concurrent", runHttpGet(io, http_manual_concurrent_path, 9002, "/", "", "hello"), &failed);
    report("http-static", runHttpStatic(io, http_static_path, 9006, "http_text_file.txt", "this is http text file example."), &failed);
    report("http-sse", runSse(io, http_sse_path, 9010), &failed);
    report("http-websocket", runWs(io, http_websocket_path, 9008, "/ws/lobby"), &failed);

    // HTTP1 feature tests.
    report("http1-json", runHttpGet(io, http1_json_path, 9101, "/status", "", "server"), &failed);
    report("http1-middleware", runHttpGet(io, http1_middleware_path, 9103, "/public", "http://127.0.0.1", "public"), &failed);
    report("http1-params", runHttpGet(io, http1_params_path, 9104, "/echo?foo=bar", "", "foo"), &failed);
    report("http1-paths", runHttpGet(io, http1_paths_path, 9105, "/path", "", ""), &failed);
    report("http1-timeout-resp", runHttpGet(io, http1_timeout_resp_path, 9110, "/ping", "", "pong"), &failed);
    report("http1-xtra-headers", runHttpGet(io, http1_xtra_headers_path, 9109, "/info", "", ""), &failed);
    report("http1-manual-concurrent", runHttpGet(io, http1_manual_concurrent_path, 9107, "/", "", "hello"), &failed);
    report("http1-static", runHttpStatic(io, http1_static_path, 9106, "http1_text_file.txt", "this is http1 text file example."), &failed);
    report("http1-sse", runSse(io, http1_sse_path, 9108), &failed);
    report("http1-websocket", runWs(io, http1_websocket_path, 9111, "/ws"), &failed);

    // gRPC feature tests.
    report("grpc-location-async", runGrpcLocation(io, grpc_location_async_path, 10101), &failed);
    report("grpc-location-pool", runGrpcLocation(io, grpc_location_pool_path, 10101), &failed);
    report("grpc-location-mixed", runGrpcLocation(io, grpc_location_mixed_path, 10101), &failed);
    report("grpc-location-epoll", runGrpcLocation(io, grpc_location_epoll_path, 10101), &failed);
    report("grpc-multi", runGrpcMulti(io, grpc_multi_path), &failed);
    report("grpc-timeout", runGrpcTimeout(io, grpc_timeout_path), &failed);

    // FIX trading test.
    report("fix-trading", runFixTrading(io, fix_trading_path), &failed);

    // UDS HTTP test.
    report("uds-http", runUdsHttp(io, uds_http_a_path, uds_http_b_path), &failed);

    // Channel self-terminating tests.
    report("channel-basic", runChannelSelfterm(io, channel_basic_path), &failed);
    report("channel-pipeline", runChannelSelfterm(io, channel_pipeline_path), &failed);
    report("channel-worker-pool", runChannelSelfterm(io, channel_worker_pool_path), &failed);

    // Channel IPC test.
    report("channel-ipc", runChannelIpc(io, channel_ipc_a_path, channel_ipc_b_path), &failed);

    if (failed > 0) {
        std.debug.print("{d}/54 protocol(s) failed\n", .{failed});
        std.process.exit(1);
    }

    std.debug.print("all 54 protocols passed\n", .{});
}

// --------------------------------------------------------- //

fn runHttp(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, 9100, 5000);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var resp = try client.get("http://127.0.0.1:9100/", .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (resp.body().len == 0) return error.EmptyBody;
}

fn runHttp1(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, 9100, 5000);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var resp = try client.get("http://127.0.0.1:9100/", .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (!std.mem.eql(u8, resp.body(), "Hello, World!")) return error.UnexpectedBody;
}

fn runGrpc(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, 8083, 5000);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 8083 }, io);
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

    try common.waitForTcpPort(io, port, 5000);

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

fn runFix(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, 9500, 5000);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = 9500,
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
        .server_port = 9100,
        .bind_ip = "127.0.0.1",
        .bind_port = 9191,
        .port_mode = .REQUIRED,
        .endianness = .LITTLE,
        .recv_timeout_ms = 3000,
    }, io);
    defer client.deinit();

    var my_id: [16]u8 = [_]u8{0} ** 16;
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

    try common.waitForTcpPort(io, port, 5000);

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

    try common.waitForTcpPort(io, port, 5000);

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

    try common.waitForTcpPort(io, port, 5000);

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

    try common.waitForTcpPort(io, port, 5000);

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

    try common.waitForTcpPort(io, port, 5000);

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

    try common.waitForTcpPort(io, 10102, 5000);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 10102 }, io);
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

    try common.waitForTcpPort(io, 8084, 5000);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 8084 }, io);
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

    try common.waitForTcpPort(io, 9500, 5000);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = 9500,
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

    try common.waitForTcpPort(io, 9200, 5000);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var resp = try client.get("http://127.0.0.1:9200/data", .{});
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
