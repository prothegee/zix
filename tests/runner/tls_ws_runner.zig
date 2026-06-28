// Runner for tls_http1_ws and tls_http_ws examples (WebSocket over TLS, ADR-055).
// Spawns the wss server, then asserts a WebSocket echoes over TLS via common.tlsWsEcho: a TLS 1.3
// handshake with the native zix.Tls client, the WS upgrade GET, confirm the encrypted 101, send one
// masked text frame, decrypt the echoed frame. No curl, no websocat.
//
// Invoked by `zig build test-runner-tls-http1-ws` or test-runner-tls-http-ws.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.

const std = @import("std");
const common = @import("common.zig");

const WAIT_MS: u64 = 5000;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL tls-ws: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL tls-ws: missing label\n", .{});
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

    try common.tlsWsEcho(port);
}
