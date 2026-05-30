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
