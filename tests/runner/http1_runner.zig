// Test runner for zix.Http1.Server (http1_basic_1_async, port 9100).
// Spawns the server, makes a GET / request, asserts 200 + "Hello, World!", kills server.
//
// Invoked by `zig build test-runner-http1`.
// The server binary path is passed as argv[1] by build.zig.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const PORT: u16 = 9100;
const WAIT_MS: u64 = 5000;
const EXPECTED_BODY: []const u8 = "Hello, World!";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    run(process) catch |err| {
        std.debug.print("FAIL http1: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("PASS http1\n", .{});
}

fn run(process: std.process.Init) !void {
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse return error.MissingServerPath;

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, PORT, WAIT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var resp = try client.get("http://127.0.0.1:9100/", .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (!std.mem.eql(u8, resp.body(), EXPECTED_BODY)) return error.UnexpectedBody;
}
