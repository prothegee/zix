// Test runner for zix.Uds.Server (uds_server, /tmp/zix.sock).
// Spawns the server, sends "get", asserts a counter string is received, kills server.
//
// Invoked by `zig build test-runner-uds`.
// The server binary path is passed as argv[1] by build.zig.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const SOCK_PATH: []const u8 = "/tmp/zix.sock";
const WAIT_MS: u64 = 5000;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    run(process) catch |err| {
        std.debug.print("FAIL uds: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("PASS uds\n", .{});
}

fn run(process: std.process.Init) !void {
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse return error.MissingServerPath;

    // Remove stale socket from a previous run before spawning.
    std.Io.Dir.deleteFileAbsolute(io, SOCK_PATH) catch {};

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForUdsSocket(io, SOCK_PATH, WAIT_MS);

    var client = try zix.Uds.Client.connect(.{
        .path = SOCK_PATH,
        .recv_timeout_ms = 3000,
    }, io);
    defer client.deinit(io);

    try client.sendMsg(io, "get");

    var recv_buf: [64]u8 = undefined;
    const reply = try client.recvMsg(io, &recv_buf);

    if (reply.len == 0) return error.EmptyReply;
}
