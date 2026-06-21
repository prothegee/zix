// Runner for grpc_multi_server example.
// Spawns the server, tests both /helloworld.Greeter/SayHello and
// /location.Location/SendLocationAndSave routes.
//
// Invoked by `zig build test-runner-grpc-multi`.
// argv[1]: server binary path
// argv[2]: label

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const PORT: u16 = 9042;
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

    var hello_req_buf: [64]u8 = undefined;
    var hello_req_pos: usize = 0;
    hello_req_pos += zix.Grpc.encodeString(1, "runner", hello_req_buf[hello_req_pos..]);

    var hello_buf: [256]u8 = undefined;
    const hello_raw = try client.unary(
        "/helloworld.Greeter/SayHello",
        "application/grpc+proto",
        hello_req_buf[0..hello_req_pos],
        &hello_buf,
    );

    var hello_reader = zix.Grpc.MessageReader.init(hello_raw);
    var hello_found = false;
    while (hello_reader.next() catch null) |field| {
        if (field.field_number == 1) {
            if (!std.mem.startsWith(u8, field.payload, "Hello,")) return error.UnexpectedHelloResponse;
            hello_found = true;
        }
    }
    if (!hello_found) return error.MissingHelloField;

    var loc_req_buf: [128]u8 = undefined;
    var pos: usize = 0;
    pos += zix.Grpc.encodeDouble(1, 106.8, loc_req_buf[pos..]);
    pos += zix.Grpc.encodeDouble(2, -6.2, loc_req_buf[pos..]);
    pos += zix.Grpc.encodeString(3, "runner", loc_req_buf[pos..]);

    var loc_resp_buf: [256]u8 = undefined;
    const loc_resp = try client.unary(
        "/location.Location/SendLocationAndSave",
        "application/grpc+proto",
        loc_req_buf[0..pos],
        &loc_resp_buf,
    );

    if (loc_resp.len == 0) return error.EmptyLocationResponse;
}
