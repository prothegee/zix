// Test runner for zix.Tcp.Server (tcp_server_1_async, port 9300).
// Spawns the server, sends "ping", asserts echo "ping" back, kills server.
//
// Invoked by `zig build test-runner-tcp`.
// The server binary path is passed as argv[1] by build.zig.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const PORT: u16 = 9300;
const WAIT_MS: u64 = 5000;
const MSG: []const u8 = "ping";
const EXPECTED_REPLY: []const u8 = "Hello from zix TCP Server";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    run(process) catch |err| {
        std.debug.print("FAIL tcp: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("PASS tcp\n", .{});
}

fn run(process: std.process.Init) !void {
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse return error.MissingServerPath;

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, PORT, WAIT_MS);

    var client = try zix.Tcp.Client.connect(.{
        .ip = "127.0.0.1",
        .port = PORT,
        .recv_timeout_ms = 3000,
    }, io);
    defer client.deinit(io);

    try client.sendMsg(io, MSG);

    var recv_buf: [256]u8 = undefined;
    const reply = try client.recvMsg(io, &recv_buf);

    if (!std.mem.eql(u8, reply, EXPECTED_REPLY)) return error.UnexpectedReply;
}
