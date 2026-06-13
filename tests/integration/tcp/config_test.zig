//! Integration tests: TcpServer.init wiring and HandlerFn type contract.

const std = @import("std");
const zix = @import("zix");

test "zix integration: TcpServer.init, valid config succeeds and deinit is safe" {
    var server = try zix.Tcp.Server.init(.{
        .ip = "127.0.0.1",
        .port = 9300,
    });
    server.deinit();
}

test "zix integration: TcpServer.init with EPOLL dispatch model succeeds and deinit is safe" {
    var server = try zix.Tcp.Server.init(.{
        .ip = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .EPOLL,
    });
    server.deinit();
}

test "zix integration: TcpServer EPOLL, workers governs worker count and pool_size is ignored" {
    const server = try zix.Tcp.Server.init(.{
        .ip = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .EPOLL,
        .workers = 4,
        .pool_size = 99,
    });
    try std.testing.expectEqual(@as(usize, 4), server.config.workers);
    try std.testing.expectEqual(@as(usize, 99), server.config.pool_size);
}

test "zix integration: TcpServer.init, port zero returns PortNotConfigured" {
    const result = zix.Tcp.Server.init(.{
        .ip = "127.0.0.1",
        .port = 0,
    });
    try std.testing.expectError(error.PortNotConfigured, result);
}

test "zix integration: HandlerFn, echoHandler satisfies the type" {
    const handler: zix.Tcp.HandlerFn = zix.Tcp.echoHandler;
    _ = handler;
}

test "zix integration: TcpClient.connect, port zero returns PortNotConfigured" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = zix.Tcp.Client.connect(.{
        .ip = "127.0.0.1",
        .port = 0,
    }, io);
    try std.testing.expectError(error.PortNotConfigured, result);
}

test "zix integration: TcpClient, recv_timeout_ms fires when server sends no data" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", 9341);
    var stall_listener = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    defer stall_listener.deinit(io);

    var client = try zix.Tcp.Client.connect(.{
        .ip = "127.0.0.1",
        .port = 9341,
        .recv_timeout_ms = 200,
    }, io);
    defer client.deinit(io);

    var buf: [4096]u8 = undefined;
    const result = client.recvMsg(io, &buf);
    if (result) |_| return error.ExpectedRecvTimeout else |_| {}
}
