// Test runner for zix.Grpc.Server server-streaming (Echo route, port 9036).
// Spawns the server, opens a stream, sends two messages, and asserts both echoes
// plus an OK status come back. Exercises the server-streaming path (multiple DATA
// frames coalesced into the reply), used to validate the .URING ring streaming
// path with zix's own gRPC client.
//
// Invoked by `zig build test-runner-grpc-stream-<model>`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const WAIT_MS: u64 = 5000;
const ECHO_PATH: []const u8 = "/helloworld.Greeter/Echo";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL grpc-stream: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL grpc-stream: missing label\n", .{});
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
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}

fn run(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, WAIT_MS);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = port }, io);
    defer client.deinit();

    const sid = try client.openStream(ECHO_PATH, "application/grpc+proto");
    try client.sendMessage(sid, "aaa");
    try client.sendMessage(sid, "bbb");
    try client.endStream(sid);

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;

    const r1 = try client.recvResponse(sid, &buf1);
    if (r1 != .data or !std.mem.eql(u8, r1.data, "aaa")) return error.UnexpectedEcho1;

    const r2 = try client.recvResponse(sid, &buf2);
    if (r2 != .data or !std.mem.eql(u8, r2.data, "bbb")) return error.UnexpectedEcho2;

    const fin = try client.recvResponse(sid, &buf1);
    if (fin != .status or fin.status != zix.Grpc.Status.OK) return error.NoOkStatus;
}
