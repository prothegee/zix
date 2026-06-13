// Runner for http_sse and http1_sse examples.
// Spawns the server, connects with SseClient, reads the first event, asserts its
// data is non-empty, then disconnects.
//
// Invoked by `zig build test-runner-http-sse` or test-runner-http1-sse.
// argv[1]: server binary path
// argv[2]: label
// argv[3]: port

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const WAIT_MS: u64 = 5000;
const SSE_ROUTE: []const u8 = "/events";

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
    std.debug.print("PASS {s}\n", .{label});
}

fn run(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, port, WAIT_MS);

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, SSE_ROUTE });

    var sse_client = zix.Http.SseClient.init(.{
        .io = io,
        .connect_timeout_ms = 3000,
    });
    var stream = try sse_client.open(url);
    defer stream.deinit();

    var buf: [4096]u8 = undefined;
    const event = try stream.next(&buf) orelse return error.NoSseEvent;

    if (event.data.len == 0) return error.EmptySseEvent;
}
