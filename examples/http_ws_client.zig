//! http_ws_client.zig: WebSocket client example (RFC 6455).
//!
//! Connects to the http_websocket example server, sends two text frames
//! and a ping, reads the pong and the broadcast echo, then closes.
//!
//! Run:
//! zig build example-http_websocket && ./zig-out/bin/example-http_websocket &
//! zig build example-http_ws_client && ./zig-out/bin/example-http_ws_client
//! kill %1

const std = @import("std");
const zix = @import("zix");

pub fn main(process: std.process.Init) !void {
    var wsc = zix.Http.WsClient.init(.{
        .io = process.io,
        .connect_timeout_ms = 5000,
    });

    var conn = try wsc.connect("ws://127.0.0.1:9008/ws/lobby");
    defer conn.deinit();
    std.debug.print("ws: connected to /ws/lobby\n", .{});

    try conn.send(.text, "hello from WsClient");
    std.debug.print("ws: sent text frame\n", .{});

    try conn.send(.ping, "");
    std.debug.print("ws: sent ping\n", .{});

    var buf: [4096]u8 = undefined;
    var done: usize = 0;

    while (done < 2) {
        const frame = try conn.recv(&buf) orelse break;

        switch (frame.opcode) {
            .text, .binary => {
                std.debug.print("ws: recv text: {s}\n", .{frame.payload});
                done += 1;
            },
            .pong => {
                std.debug.print("ws: recv pong\n", .{});
                done += 1;
            },
            .close => break,
            else => {},
        }
    }

    try conn.send(.close, &.{});
    std.debug.print("ws: closed\n", .{});
}
