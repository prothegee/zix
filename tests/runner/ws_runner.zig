// Runner for http_websocket and http1_websocket examples.
// Spawns the server, connects via WsClient, sends a text frame, receives the echo,
// asserts the payload matches, then closes.
//
// Invoked by `zig build test-runner-http-websocket` or test-runner-http1-websocket.
// argv[1]: server binary path
// argv[2]: label
// argv[3]: port
// argv[4]: ws route (e.g. "/ws/lobby" or "/ws")

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const WAIT_MS: u64 = 5000;
const WS_PAYLOAD: []const u8 = "hello";

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
    const ws_route = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing ws route\n", .{label});
        std.process.exit(1);
    };

    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.debug.print("FAIL {s}: invalid port\n", .{label});
        std.process.exit(1);
    };

    run(process.io, server_path, port, ws_route) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    std.debug.print("PASS {s}\n", .{label});
}

fn run(io: std.Io, server_path: []const u8, port: u16, ws_route: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, port, WAIT_MS);

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}{s}", .{ port, ws_route });

    var wsc = zix.Http.WsClient.init(.{ .io = io, .connect_timeout_ms = 3000 });
    var conn = try wsc.connect(url);
    defer conn.deinit();

    try conn.send(.text, WS_PAYLOAD);

    var payload_buf: [256]u8 = undefined;
    const frame = try conn.recv(&payload_buf) orelse return error.NoWsFrame;

    if (!std.mem.containsAtLeast(u8, frame.payload, 1, WS_PAYLOAD)) return error.UnexpectedEcho;
}
