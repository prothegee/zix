// Test runner for all protocols and all dispatch models.
// Runs each protocol test sequentially. Exits 0 only when every test passes.
//
// Invoked by `zig build test-runner-all`.
// Server binary paths are passed as argv[1..22] by build.zig in this order:
//   http-async, http-pool, http-mixed, http-epoll,
//   http1-async, http1-pool, http1-mixed, http1-epoll,
//   grpc-async, grpc-pool, grpc-mixed, grpc-epoll,
//   tcp-async, tcp-pool, tcp-mixed, tcp-epoll,
//   fix-async, fix-pool, fix-mixed, fix-epoll,
//   udp, uds

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
        std.debug.print("FAIL {s}: {}\n", .{label, err});
        failed.* += 1;
    }
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var failed: usize = 0;
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    const http_async_path  = arg_iter.next() orelse exitMissing("http-async");
    const http_pool_path   = arg_iter.next() orelse exitMissing("http-pool");
    const http_mixed_path  = arg_iter.next() orelse exitMissing("http-mixed");
    const http_epoll_path  = arg_iter.next() orelse exitMissing("http-epoll");

    const http1_async_path  = arg_iter.next() orelse exitMissing("http1-async");
    const http1_pool_path   = arg_iter.next() orelse exitMissing("http1-pool");
    const http1_mixed_path  = arg_iter.next() orelse exitMissing("http1-mixed");
    const http1_epoll_path  = arg_iter.next() orelse exitMissing("http1-epoll");

    const grpc_async_path  = arg_iter.next() orelse exitMissing("grpc-async");
    const grpc_pool_path   = arg_iter.next() orelse exitMissing("grpc-pool");
    const grpc_mixed_path  = arg_iter.next() orelse exitMissing("grpc-mixed");
    const grpc_epoll_path  = arg_iter.next() orelse exitMissing("grpc-epoll");

    const tcp_async_path  = arg_iter.next() orelse exitMissing("tcp-async");
    const tcp_pool_path   = arg_iter.next() orelse exitMissing("tcp-pool");
    const tcp_mixed_path  = arg_iter.next() orelse exitMissing("tcp-mixed");
    const tcp_epoll_path  = arg_iter.next() orelse exitMissing("tcp-epoll");

    const fix_async_path  = arg_iter.next() orelse exitMissing("fix-async");
    const fix_pool_path   = arg_iter.next() orelse exitMissing("fix-pool");
    const fix_mixed_path  = arg_iter.next() orelse exitMissing("fix-mixed");
    const fix_epoll_path  = arg_iter.next() orelse exitMissing("fix-epoll");

    const udp_path = arg_iter.next() orelse exitMissing("udp");
    const uds_path = arg_iter.next() orelse exitMissing("uds");

    report("http-async",  runHttp(io, http_async_path),  &failed);
    report("http-pool",   runHttp(io, http_pool_path),   &failed);
    report("http-mixed",  runHttp(io, http_mixed_path),  &failed);
    report("http-epoll",  runHttp(io, http_epoll_path),  &failed);

    report("http1-async", runHttp1(io, http1_async_path), &failed);
    report("http1-pool",  runHttp1(io, http1_pool_path),  &failed);
    report("http1-mixed", runHttp1(io, http1_mixed_path), &failed);
    report("http1-epoll", runHttp1(io, http1_epoll_path), &failed);

    report("grpc-async",  runGrpc(io, grpc_async_path),  &failed);
    report("grpc-pool",   runGrpc(io, grpc_pool_path),   &failed);
    report("grpc-mixed",  runGrpc(io, grpc_mixed_path),  &failed);
    report("grpc-epoll",  runGrpc(io, grpc_epoll_path),  &failed);

    report("tcp-async",   runTcp(io, tcp_async_path, 9300), &failed);
    report("tcp-pool",    runTcp(io, tcp_pool_path,  9301), &failed);
    report("tcp-mixed",   runTcp(io, tcp_mixed_path, 9302), &failed);
    report("tcp-epoll",   runTcp(io, tcp_epoll_path, 9303), &failed);

    report("fix-async",   runFix(io, fix_async_path),    &failed);
    report("fix-pool",    runFix(io, fix_pool_path),     &failed);
    report("fix-mixed",   runFix(io, fix_mixed_path),    &failed);
    report("fix-epoll",   runFix(io, fix_epoll_path),    &failed);

    report("udp",         runUdp(io, udp_path),          &failed);
    report("uds",         runUds(io, uds_path),          &failed);

    if (failed > 0) {
        std.debug.print("{d}/22 protocol(s) failed\n", .{failed});
        std.process.exit(1);
    }

    std.debug.print("all 22 protocols passed\n", .{});
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
        .server_ip = "127.0.0.1",
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
