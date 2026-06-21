// Runner for grpc_timeout example.
// Spawns the server, sends a fast SayHello (no sleep, won't hit the 3s timeout),
// asserts the response starts with "Hello,".
//
// Invoked by `zig build test-runner-grpc-timeout`.
// argv[1]: server binary path
// argv[2]: label

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const PORT: u16 = 9037;
const WAIT_MS: u64 = 5000;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL: missing label\n", .{});
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

    try common.waitForTcpPort(io, &server_child, PORT, WAIT_MS);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = PORT }, io);
    defer client.deinit();

    var resp_buf: [256]u8 = undefined;
    const resp = try client.unary(
        "/helloworld.Greeter/SayHello",
        "application/grpc+proto",
        "runner",
        &resp_buf,
    );

    if (!std.mem.startsWith(u8, resp, "Hello,")) return error.UnexpectedResponse;
}
