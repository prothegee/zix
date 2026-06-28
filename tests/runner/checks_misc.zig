//! TCP, UDP, UDS, and Channel protocol checks for all_runner.zig.
//!
//! Each spawns its server (or server pair), waits for the port or socket, then
//! drives the native client. UDP has no accept handshake, so those checks give
//! the server a short fixed moment to bind instead of polling a port.

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

pub fn runTcp(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

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

pub fn runUdp(io: std.Io, server_path: []const u8) !void {
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

pub fn runUdpRaw(io: std.Io, server_path: []const u8) !void {
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

pub fn runUds(io: std.Io, server_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, "/tmp/zix.sock") catch {};

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForUdsSocket(io, "/tmp/zix.sock", common.START_TIMEOUT_MS);

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

pub fn runUdsHttp(io: std.Io, uds_server_path: []const u8, uds_http_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, "/tmp/zix.sock") catch {};

    var uds_child = try common.spawnServer(io, uds_server_path);
    defer uds_child.kill(io);

    try common.waitForUdsSocket(io, "/tmp/zix.sock", common.START_TIMEOUT_MS);

    var http_child = try common.spawnServer(io, uds_http_path);
    defer http_child.kill(io);

    try common.waitForTcpPort(io, &http_child, 9055, common.START_TIMEOUT_MS);

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

pub fn runChannelSelfterm(io: std.Io, binary_path: []const u8) !void {
    var child = try common.spawnServer(io, binary_path);
    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code != 0) return error.NonZeroExit;
        },
        .signal, .stopped, .unknown => return error.UnexpectedTermination,
    }
}

pub fn runChannelIpc(io: std.Io, ipc_a_path: []const u8, ipc_b_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, "/tmp/zix_ipc.sock") catch {};

    var child_a = try common.spawnServer(io, ipc_a_path);
    defer child_a.kill(io);

    try common.waitForUdsSocket(io, "/tmp/zix_ipc.sock", common.START_TIMEOUT_MS);

    var child_b = try common.spawnServer(io, ipc_b_path);
    defer child_b.kill(io);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1500), .awake);
}
