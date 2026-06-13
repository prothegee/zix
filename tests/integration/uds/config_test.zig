//! Integration tests: UDS Server.init, HandlerFn wiring, and client timeout.

const std = @import("std");
const zix = @import("zix");

test "zix integration: UdsServer.init, valid path succeeds and deinit is safe" {
    var server = try zix.Uds.Server.init(.{
        .path = "/tmp/zix_integration_test.sock",
        .allocator = std.testing.allocator,
    });
    server.deinit();
}

test "zix integration: UDS echoHandler, signature matches expected type" {
    const HandlerType = fn (std.Io.net.Stream, std.Io) void;
    const handler: HandlerType = zix.Uds.echoHandler;
    _ = handler;
}

test "zix integration: UdsClient, recv_timeout_ms fires when server sends no data" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const sock_path = "/tmp/zix_stall_uds_client_test.sock";
    std.Io.Dir.deleteFileAbsolute(io, sock_path) catch {};

    const unix_addr = try std.Io.net.UnixAddress.init(sock_path);
    var stall_listener = try unix_addr.listen(io, .{ .kernel_backlog = 2 });

    const StallAccept = struct {
        fn run(server: *std.Io.net.Server, srv_io: std.Io) void {
            _ = server.accept(srv_io) catch return;
        }
    };

    const stall_thread = try std.Thread.spawn(.{}, StallAccept.run, .{ &stall_listener, io });

    var client = try zix.Uds.Client.connect(.{
        .path = sock_path,
        .recv_timeout_ms = 200,
    }, io);

    var buf: [4096]u8 = undefined;
    const result = client.recvMsg(io, &buf);

    client.deinit(io);
    stall_listener.deinit(io);
    std.Io.Dir.deleteFileAbsolute(io, sock_path) catch {};
    stall_thread.join();

    if (result) |_| return error.ExpectedRecvTimeout else |_| {}
}
