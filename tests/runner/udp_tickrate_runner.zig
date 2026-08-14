// Test runner for the tickrate pair (udp_server_tickrate + udp_client_tickrate,
// UDP port 9034). Spawns the server with explicit flags (--ip / --port engine-parsed,
// --tickrate example-parsed) and the client executable as a second process, then
// joins as another client and asserts on the snapshot stream:
// - the runner's own state returns more than once (per-tick re-broadcast, not a one-shot relay)
// - the client executable's state arrives (multi client, each instance its own process)
// - wrong-size datagrams (short and oversized) are dropped without entering the stream
//
// Invoked by `zig build test-runner-udp-tickrate`.
// argv[1]: server binary path, argv[2]: client binary path, argv[3]: label.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const SERVER_PORT: u16 = 9034;
const RUNNER_BIND_PORT: u16 = 9194;
const CLIENT_BIND_PORT: u16 = 9197;
const WAIT_MS: i64 = 600;
// Upper bound on receives while hunting the expected states. The bound only matters
// when a state never shows up: at tickrate 128 the stream is hundreds of datagrams
// per second, so a healthy run exits the hunt loop in well under a second.
const MAX_RECEIVES: usize = 2000;

// Must match the Packet definition in examples/udp_server_tickrate.zig exactly.
const Packet = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

const MyClient = zix.Udp.Client(Packet);

// --------------------------------------------------------- //

fn run(io: std.Io, server_path: []const u8, client_path: []const u8) !void {
    var server_child = try std.process.spawn(io, .{
        .argv = &.{ server_path, "--ip", "127.0.0.1", "--port", "9034", "--tickrate", "128" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer server_child.kill(io);

    // UDP has no connection handshake, give the server time to bind.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(WAIT_MS), .awake);

    // Wrong-size datagrams from a stranger socket: short and oversized, both must be
    // dropped. If either entered the registry, the snapshot stream below would carry
    // an odd-size datagram and receiveFeedback would fail with ZixUnexpectedPacketSize.
    {
        const stranger_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const stranger = try stranger_addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
        defer stranger.close(io);

        const server_addr = try std.Io.net.IpAddress.parse("127.0.0.1", SERVER_PORT);
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

    var runner_client = try MyClient.init(.{
        .ip = "127.0.0.1",
        .server_port = SERVER_PORT,
        .bind_ip = "127.0.0.1",
        .bind_port = RUNNER_BIND_PORT,
        .endianness = .LITTLE,
        .recv_timeout_ms = 3000,
    }, io, .{});
    defer runner_client.deinit();

    var runner_id: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&runner_id, "runner", .{}) catch {};
    var child_id: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&child_id, "client-{d}", .{CLIENT_BIND_PORT}) catch {};

    const pkt = Packet{
        .id = runner_id,
        .packet_type = 1,
        .register = 42,
        .position = .{ 0.25, 0.5, 0.75 },
    };
    try runner_client.send(pkt);

    // Hunt the snapshot stream. Any ack, nack, unknown sender, or odd-size datagram
    // (receiveFeedback error) fails the check.
    var own_seen: usize = 0;
    var child_seen: usize = 0;
    var receives: usize = 0;
    while (receives < MAX_RECEIVES and (own_seen < 2 or child_seen < 1)) : (receives += 1) {
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

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = common.argsIterator(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL udp-tickrate: missing server path\n", .{});
        std.process.exit(1);
    };
    const client_path = arg_iter.next() orelse {
        std.debug.print("FAIL udp-tickrate: missing client path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL udp-tickrate: missing label\n", .{});
        std.process.exit(1);
    };

    run(process.io, server_path, client_path) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}
