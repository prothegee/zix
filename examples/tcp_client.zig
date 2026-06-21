// Connect to a zix TCP server, send one message, print the reply, then exit.
//
// Default target: 127.0.0.1:9043 (tcp_server_1_async).
// Override at runtime:
// zig build example-tcp_client -- --ip 127.0.0.1 --port 9044

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9043;
const MESSAGE: []const u8 = "Hello from zix TCP Client";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var client = zix.Tcp.Client.connectArgs(.{
        .ip = IP,
        .port = PORT,
    }, io, process.minimal.args) catch |err| {
        std.debug.print("error: cannot connect to {s}:{d}: {}\n", .{ IP, PORT, err });
        return;
    };
    defer client.deinit(io);

    client.sendMsg(io, MESSAGE) catch |err| {
        std.debug.print("error: send failed: {}\n", .{err});
        return;
    };
    std.debug.print("sent ({d} bytes): {s}\n", .{ MESSAGE.len, MESSAGE });

    var buf: [4096]u8 = undefined;
    const reply = client.recvMsg(io, &buf) catch |err| {
        std.debug.print("error: recv failed: {}\n", .{err});
        return;
    };
    std.debug.print("recv ({d} bytes): {s}\n", .{ reply.len, reply });
}
