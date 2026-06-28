// Runner for tls_http_sse and tls_http1_sse examples (SSE over TLS, ADR-054).
// Spawns the https server, then asserts the SSE stream runs over TLS via common.tlsSseFirstEvent:
// a TLS 1.3 handshake with the native zix.Tls client, GET /events, decrypt the records, and confirm
// Content-Type: text/event-stream plus the first event. No curl, no openssl.
//
// Invoked by `zig build test-runner-tls-http-sse` or test-runner-tls-http1-sse.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.

const std = @import("std");
const common = @import("common.zig");

const WAIT_MS: u64 = 5000;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL tls-sse: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL tls-sse: missing label\n", .{});
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

    try common.tlsSseFirstEvent(port);
}
