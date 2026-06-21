// Runner for grpc_location_server_* examples.
// Spawns the server, sends a SendLocationAndSave RPC, asserts a non-empty response.
//
// Invoked by `zig build test-runner-grpc-location-<model>`.
// argv[1]: server binary path
// argv[2]: label
// argv[3]: port

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

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

    var req_buf: [128]u8 = undefined;
    var pos: usize = 0;
    pos += zix.Grpc.encodeDouble(1, 106.8, req_buf[pos..]);
    pos += zix.Grpc.encodeDouble(2, -6.2, req_buf[pos..]);
    pos += zix.Grpc.encodeString(3, "runner", req_buf[pos..]);

    var resp_buf: [256]u8 = undefined;
    const resp = try client.unary(
        "/location.Location/SendLocationAndSave",
        "application/grpc+proto",
        req_buf[0..pos],
        &resp_buf,
    );

    if (resp.len == 0) return error.EmptyResponse;
}
