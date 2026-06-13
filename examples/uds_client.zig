// Connect to a zix UDS server, send one request, print the reply, then exit.
//
// Default target: /tmp/zix.sock (uds_server).
// The server treats any frame content as a "get" request and replies
// with an incrementing counter value as a decimal string.
//
// Run the server first:
// zig build example-uds_server && ./zig-out/bin/example-uds_server
//
// Then this client in a second terminal:
// zig build example-uds_client && ./zig-out/bin/example-uds_client

const std = @import("std");
const zix = @import("zix");

const SOCK_PATH: []const u8 = "/tmp/zix.sock";
const MESSAGE: []const u8 = "get";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var client = zix.Uds.Client.connect(.{
        .path = SOCK_PATH,
    }, io) catch |err| {
        std.debug.print("error: cannot connect to {s}: {}\n", .{ SOCK_PATH, err });
        return;
    };
    defer client.deinit(io);

    client.sendMsg(io, MESSAGE) catch |err| {
        std.debug.print("error: send failed: {}\n", .{err});
        return;
    };
    std.debug.print("sent ({d} bytes): {s}\n", .{ MESSAGE.len, MESSAGE });

    var buf: [256]u8 = undefined;
    const reply = client.recvMsg(io, &buf) catch |err| {
        std.debug.print("error: recv failed: {}\n", .{err});
        return;
    };
    std.debug.print("recv ({d} bytes): {s}\n", .{ reply.len, reply });
}
