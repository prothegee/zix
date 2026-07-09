// Test runner for zix.Http3 (http3_basic, QUIC over UDP port 9063).
// Spawns the HTTP/3 server, drives one native QUIC round trip via the hand-rolled http3_client,
// asserts the routed handler summed the query (/baseline2?a=20&b=22 -> 42), kills the server.
//
// Invoked by `zig build test-runner-http3`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.
//
// Note:
// - The client is hand-rolled from zix.Http3 primitives (no external tool), the same way the HTTP/2
//   runner hand-rolls a client from zix.Http2 primitives. QUIC binds a UDP socket with no TCP accept
//   to poll, so the server is given a short fixed moment to bind before the client connects.

const std = @import("std");
const common = @import("common.zig");
const http3_client = @import("http3_client.zig");

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9063;
const WAIT_MS: i64 = 1200;

// --------------------------------------------------------- //

fn run(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(WAIT_MS), .awake);

    var body_buf: [256]u8 = undefined;
    const body = try http3_client.fetch(io, SERVER_IP, SERVER_PORT, "/baseline2?a=20&b=22", &body_buf);

    if (!std.mem.eql(u8, body, "42")) return error.UnexpectedBody;

    // Multiplexing: two requests on ONE connection, on streams 0 and 4, must both be answered
    // with their own summed result (a=20&b=22 -> 42, a=1&b=2 -> 3).
    var body0_buf: [256]u8 = undefined;
    var body1_buf: [256]u8 = undefined;
    const both = try http3_client.fetchTwo(io, SERVER_IP, SERVER_PORT, "/baseline2?a=20&b=22", "/baseline2?a=1&b=2", &body0_buf, &body1_buf);

    if (!std.mem.eql(u8, both[0], "42")) return error.UnexpectedBody;
    if (!std.mem.eql(u8, both[1], "3")) return error.UnexpectedBody;
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL http3: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL http3: missing label\n", .{});
        std.process.exit(1);
    };

    run(process.io, server_path) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };

    common.printPass(label);
}
