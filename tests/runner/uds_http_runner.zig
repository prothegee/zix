// Runner for uds_http example (requires two server processes).
// Spawns uds_server (Unix socket) then uds_http (TCP + UDS client), issues
// GET /data, checks the JSON response contains "count".
//
// Invoked by `zig build test-runner-uds-http`.
// argv[1]: uds_server binary path
// argv[2]: uds_http binary path
// argv[3]: label

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const UDS_SOCK_PATH: []const u8 = "/tmp/zix.sock";
const HTTP_PORT: u16 = 9200;
const WAIT_MS: u64 = 5000;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const uds_server_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing uds_server path\n", .{});
        std.process.exit(1);
    };
    const uds_http_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing uds_http path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL: missing label\n", .{});
        std.process.exit(1);
    };

    run(process.io, uds_server_path, uds_http_path) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    std.debug.print("PASS {s}\n", .{label});
}

fn run(io: std.Io, uds_server_path: []const u8, uds_http_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, UDS_SOCK_PATH) catch {};

    var uds_child = try common.spawnServer(io, uds_server_path);
    defer uds_child.kill(io);

    try common.waitForUdsSocket(io, UDS_SOCK_PATH, WAIT_MS);

    var http_child = try common.spawnServer(io, uds_http_path);
    defer http_child.kill(io);

    try common.waitForTcpPort(io, HTTP_PORT, WAIT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var resp = try client.get("http://127.0.0.1:9200/data", .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (!std.mem.containsAtLeast(u8, resp.body(), 1, "count")) return error.MissingCountField;
}
