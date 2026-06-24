// Test runner for zix.Udp.Raw (udp_raw_echo, UDP port 9064).
// Spawns the raw echo server, sends one datagram, asserts the exact bytes echo back, kills server.
//
// Invoked by `zig build test-runner-udp-raw`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port (unused).
//
// Note:
// - The raw echo server replies the datagram bytes verbatim to the sender, so we expect the same
//   payload back. A raw datagram client is used (no typed Packet struct).

const std = @import("std");
const common = @import("common.zig");

const SERVER_PORT: u16 = 9064;
const BIND_PORT: u16 = 9192;
const WAIT_MS: i64 = 600;
const PAYLOAD: []const u8 = "raw-echo-ping";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL udp-raw: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL udp-raw: missing label\n", .{});
        std.process.exit(1);
    };

    run(process.io, server_path) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}

fn run(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    // UDP has no connection handshake, give the server time to bind.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(WAIT_MS), .awake);

    const local = try std.Io.net.IpAddress.parse("127.0.0.1", BIND_PORT);
    const sock = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sock.close(io);

    const server = try std.Io.net.IpAddress.parse("127.0.0.1", SERVER_PORT);
    try sock.send(io, &server, PAYLOAD);

    const timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(3000),
        .clock = .awake,
    } };

    var buf: [64]u8 = undefined;
    const msg = try sock.receiveTimeout(io, &buf, timeout);
    if (!std.mem.eql(u8, msg.data, PAYLOAD)) return error.EchoMismatch;
}
