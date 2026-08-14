//! TCP, UDP, UDS, and Channel protocol checks for all_runner.zig.
//!
//! Each spawns its server (or server pair), waits for the port or socket, then
//! drives the native client. UDP has no accept handshake, so those checks give
//! the server a short fixed moment to bind instead of polling a port.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");
const socket_poll = zix.utils.socket_poll;

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
        .endianness = .LITTLE,
        .recv_timeout_ms = 3000,
    }, io, .{});
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

    // Readiness first, then a plain receive: a timed std.Io receive needs the Io to run the receive
    // and a timer concurrently, which the Windows backend cannot do for a socket.
    if (!try socket_poll.waitReady(sock.handle, socket_poll.READABLE, 3000)) return error.EchoTimeout;

    var buf: [64]u8 = undefined;
    const msg = try sock.receive(io, &buf);
    if (!std.mem.eql(u8, msg.data, "raw-echo-ping")) return error.EchoMismatch;
}

// Tickrate pair check (udp_server_tickrate + udp_client_tickrate, UDP port 9034).
// Spawns the server with explicit flags (--ip / --port engine-parsed, --tickrate
// example-parsed) and the client executable as a second process, joins as another
// client, and asserts on the snapshot stream: the own state returns more than once
// (per-tick re-broadcast), the client executable's state arrives (multi client),
// and wrong-size datagrams are dropped without entering the stream.
pub fn runUdpTickrate(io: std.Io, server_path: []const u8, client_path: []const u8) !void {
    var server_child = try std.process.spawn(io, .{
        .argv = &.{ server_path, "--ip", "127.0.0.1", "--port", "9034", "--tickrate", "128" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer server_child.kill(io);

    // UDP has no connection handshake, give the server time to bind.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(600), .awake);

    // Wrong-size datagrams from a stranger socket: short and oversized, both must be
    // dropped. If either entered the registry, the snapshot stream below would carry
    // an odd-size datagram and receiveFeedback would fail with ZixUnexpectedPacketSize.
    {
        const stranger_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const stranger = try stranger_addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
        defer stranger.close(io);

        const server_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 9034);
        var oversized: [100]u8 = @splat('x');
        try stranger.send(io, &server_addr, "bad");
        try stranger.send(io, &server_addr, &oversized);
    }

    var client_child = try std.process.spawn(io, .{
        .argv = &.{ client_path, "--bind-port", "9197", "--server-ip", "127.0.0.1", "--server-port", "9034" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer client_child.kill(io);

    var runner_client = try MyUdpClient.init(.{
        .ip = "127.0.0.1",
        .server_port = 9034,
        .bind_ip = "127.0.0.1",
        .bind_port = 9194,
        .endianness = .LITTLE,
        .recv_timeout_ms = 3000,
    }, io, .{});
    defer runner_client.deinit();

    var runner_id: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&runner_id, "runner", .{}) catch {};
    // The bind port the spawned client ends up on. On Windows CLI flags are skipped
    // (std.process.Args.Iterator is POSIX-only in Zig 0.16), so the --bind-port 9197
    // passed above is ignored and the client keeps its default 9035.
    const child_bind_port: u16 = if (@import("builtin").target.os.tag == .windows) 9035 else 9197;
    var child_id: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&child_id, "client-{d}", .{child_bind_port}) catch {};

    const pkt = Packet{
        .id = runner_id,
        .packet_type = 1,
        .register = 42,
        .position = .{ 0.25, 0.5, 0.75 },
    };
    try runner_client.send(pkt);

    // Hunt the snapshot stream. Any ack, nack, unknown sender, or odd-size datagram
    // (receiveFeedback error) fails the check. The bound only matters when a state
    // never shows up: a healthy run exits in well under a second.
    var own_seen: usize = 0;
    var child_seen: usize = 0;
    var receives: usize = 0;
    while (receives < 2000 and (own_seen < 2 or child_seen < 1)) : (receives += 1) {
        const feedback = try runner_client.receiveFeedback();
        switch (feedback) {
            .packet => |received| {
                if (std.mem.eql(u8, &received.id, &runner_id)) {
                    if (received.register != pkt.register) return error.StateCorrupted;
                    own_seen += 1;
                } else if (std.mem.eql(u8, &received.id, &child_id)) {
                    child_seen += 1;
                } else {
                    return error.UnexpectedClientId;
                }
            },
            .ack => return error.UnexpectedAck,
            .nack => return error.UnexpectedNack,
        }
    }

    if (own_seen < 2) return error.SnapshotRebroadcastMissing;
    if (child_seen < 1) return error.ClientStateMissing;
}

pub fn runUds(io: std.Io, server_path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, "tmp/zix.sock") catch {};

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForUdsSocket(io, "tmp/zix.sock", common.START_TIMEOUT_MS);

    // The same absolute path the server derived. Connecting by relative path is refused on
    // Windows, so both sides go through the shared resolver.
    var path_buf: [600]u8 = undefined;
    const sock_path = try zix.utils.socket_path.resolve(io, "tmp", "zix.sock", &path_buf);

    var client = try zix.Uds.Client.connect(.{
        .path = sock_path,
        .recv_timeout_ms = 3000,
    }, io);
    defer client.deinit(io);

    try client.sendMsg(io, "get");

    var recv_buf: [64]u8 = undefined;
    const reply = try client.recvMsg(io, &recv_buf);

    if (reply.len == 0) return error.EmptyReply;
}

pub fn runUdsHttp(io: std.Io, uds_server_path: []const u8, uds_http_path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, "tmp/zix.sock") catch {};

    var uds_child = try common.spawnServer(io, uds_server_path);
    defer uds_child.kill(io);

    try common.waitForUdsSocket(io, "tmp/zix.sock", common.START_TIMEOUT_MS);

    var http_child = try common.spawnServer(io, uds_http_path);
    defer http_child.kill(io);

    try common.waitForTcpPort(io, &http_child, 9055, common.START_TIMEOUT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .response_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .read_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var resp = try client.get("http://127.0.0.1:9055/data", .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.ZixUnexpectedStatus;
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
    std.Io.Dir.cwd().deleteFile(io, "tmp/zix_ipc.sock") catch {};

    var child_a = try common.spawnServer(io, ipc_a_path);
    defer child_a.kill(io);

    try common.waitForUdsSocket(io, "tmp/zix_ipc.sock", common.START_TIMEOUT_MS);

    var child_b = try common.spawnServer(io, ipc_b_path);
    defer child_b.kill(io);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1500), .awake);
}
