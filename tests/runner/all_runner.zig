// Test runner for all protocols. Runs each protocol test sequentially.
// Exits 0 only when every protocol passes.
//
// Invoked by `zig build test-runner-all`.
// Server binary paths are passed as argv[1..7] by build.zig (order: http, http1,
// grpc, tcp, fix, udp, uds).

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

pub fn main(process: std.process.Init) void {
    var failed: usize = 0;
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    const http_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing http server path\n", .{});
        std.process.exit(1);
    };
    const http1_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing http1 server path\n", .{});
        std.process.exit(1);
    };
    const grpc_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing grpc server path\n", .{});
        std.process.exit(1);
    };
    const tcp_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing tcp server path\n", .{});
        std.process.exit(1);
    };
    const fix_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing fix server path\n", .{});
        std.process.exit(1);
    };
    const udp_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing udp server path\n", .{});
        std.process.exit(1);
    };
    const uds_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing uds server path\n", .{});
        std.process.exit(1);
    };

    if (runHttp(io, http_path)) {
        std.debug.print("PASS http\n", .{});
    } else |err| {
        std.debug.print("FAIL http: {}\n", .{err});
        failed += 1;
    }

    if (runHttp1(io, http1_path)) {
        std.debug.print("PASS http1\n", .{});
    } else |err| {
        std.debug.print("FAIL http1: {}\n", .{err});
        failed += 1;
    }

    if (runGrpc(io, grpc_path)) {
        std.debug.print("PASS grpc\n", .{});
    } else |err| {
        std.debug.print("FAIL grpc: {}\n", .{err});
        failed += 1;
    }

    if (runTcp(io, tcp_path)) {
        std.debug.print("PASS tcp\n", .{});
    } else |err| {
        std.debug.print("FAIL tcp: {}\n", .{err});
        failed += 1;
    }

    if (runFix(io, fix_path)) {
        std.debug.print("PASS fix\n", .{});
    } else |err| {
        std.debug.print("FAIL fix: {}\n", .{err});
        failed += 1;
    }

    if (runUdp(io, udp_path)) {
        std.debug.print("PASS udp\n", .{});
    } else |err| {
        std.debug.print("FAIL udp: {}\n", .{err});
        failed += 1;
    }

    if (runUds(io, uds_path)) {
        std.debug.print("PASS uds\n", .{});
    } else |err| {
        std.debug.print("FAIL uds: {}\n", .{err});
        failed += 1;
    }

    if (failed > 0) {
        std.debug.print("{d}/7 protocol(s) failed\n", .{failed});
        std.process.exit(1);
    }

    std.debug.print("all 7 protocols passed\n", .{});
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

fn runTcp(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, 9300, 5000);

    var client = try zix.Tcp.Client.connect(.{
        .ip = "127.0.0.1",
        .port = 9300,
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
