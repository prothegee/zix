// Test runner for zix.Udp.Server (udp_server, UDP port 9100).
// Spawns the server, sends one packet, asserts broadcast echo received, kills server.
//
// Invoked by `zig build test-runner-udp`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port (unused).
//
// Note:
// - The udp_server example has broadcast=true, auto_ack=false, auto_echo=false.
//   The server adds the sender to its client list and then broadcasts to all clients
//   (including the sender), so we receive our own packet back as .packet.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const SERVER_PORT: u16 = 9100;
const BIND_PORT: u16 = 9191;
const WAIT_MS: i64 = 600;

// Must match the Packet definition in examples/udp_server.zig exactly.
const Packet = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

const MyClient = zix.Udp.Client(Packet);

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL udp: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL udp: missing label\n", .{});
        std.process.exit(1);
    };

    run(process.io, server_path) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    std.debug.print("PASS {s}\n", .{label});
}

fn run(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    // UDP has no connection handshake, give the server time to bind.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(WAIT_MS), .awake);

    var client = try MyClient.init(.{
        .server_ip = "127.0.0.1",
        .server_port = SERVER_PORT,
        .bind_ip = "127.0.0.1",
        .bind_port = BIND_PORT,
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
