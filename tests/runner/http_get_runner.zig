// Parameterized GET runner for HTTP and HTTP1 examples.
// Spawns the server, issues one GET request, checks status 200 and optional body
// substring, then kills the server.
//
// Invoked by `zig build test-runner-<name>`.
// argv[1]: server binary path
// argv[2]: label
// argv[3]: port
// argv[4]: route (e.g. "/status" or "/echo?foo=bar")
// argv[5]: origin header value (empty string = no Origin header)
// argv[6]: expected body substring (empty string = skip body check)

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
    const route = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing route\n", .{label});
        std.process.exit(1);
    };
    const origin = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing origin arg\n", .{label});
        std.process.exit(1);
    };
    const expected_substr = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing expected_substr arg\n", .{label});
        std.process.exit(1);
    };

    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.debug.print("FAIL {s}: invalid port\n", .{label});
        std.process.exit(1);
    };

    run(process.io, server_path, port, route, origin, expected_substr) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    std.debug.print("PASS {s}\n", .{label});
}

fn run(
    io: std.Io,
    server_path: []const u8,
    port: u16,
    route: []const u8,
    origin: []const u8,
    expected_substr: []const u8,
) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, port, WAIT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 16384,
    });
    defer client.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, route });

    const origin_header = std.http.Header{ .name = "Origin", .value = origin };
    const headers: []const std.http.Header = if (origin.len > 0) &[_]std.http.Header{origin_header} else &.{};

    var resp = try client.get(url, .{ .headers = headers });
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;

    if (expected_substr.len > 0) {
        if (!std.mem.containsAtLeast(u8, resp.body(), 1, expected_substr)) return error.MissingExpectedSubstring;
    }
}
