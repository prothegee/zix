// Test runner for zix.Tcp.Server (tcp_server_*, port from argv[3]).
// Spawns the server, sends "ping", asserts fixed reply, kills server.
//
// Invoked by `zig build test-runner-tcp-<model>`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.
//
// Note:
// - Each TCP dispatch variant listens on a different port (9300-9303).
//   The port is passed as argv[3] by build.zig so one runner file covers all.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const WAIT_MS: u64 = 5000;
const MSG: []const u8 = "ping";
const EXPECTED_REPLY: []const u8 = "Hello from zix TCP Server";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL tcp: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL tcp: missing label\n", .{});
        std.process.exit(1);
    };
    const port_str = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing port\n", .{label});
        std.process.exit(1);
    };
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.debug.print("FAIL {s}: invalid port\n", .{label});
        std.process.exit(1);
    };

    run(process.io, server_path, port) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{label, err});
        std.process.exit(1);
    };
    std.debug.print("PASS {s}\n", .{label});
}

fn run(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, port, WAIT_MS);

    var client = try zix.Tcp.Client.connect(.{
        .ip = "127.0.0.1",
        .port = port,
        .recv_timeout_ms = 3000,
    }, io);
    defer client.deinit(io);

    try client.sendMsg(io, MSG);

    var recv_buf: [256]u8 = undefined;
    const reply = try client.recvMsg(io, &recv_buf);

    if (!std.mem.eql(u8, reply, EXPECTED_REPLY)) return error.UnexpectedReply;
}
