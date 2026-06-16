//! Edge tests: zix.Tcp boundary conditions.
//! Verifies that port zero is rejected and DispatchModel backing values are stable.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: TcpServer.init, port zero returns PortNotConfigured" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const result = zix.Tcp.Server.init(zix.Tcp.echoHandler, .{ .io = threaded.io(), .ip = "127.0.0.1", .port = 0 });
    try std.testing.expectError(error.PortNotConfigured, result);
}

test "zix edge: DispatchModel, backing values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Tcp.DispatchModel.ASYNC));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Tcp.DispatchModel.POOL));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(zix.Tcp.DispatchModel.MIXED));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(zix.Tcp.DispatchModel.EPOLL));
}

test "zix edge: TCP frame, max u32 length encodes and decodes correctly" {
    const max_len: u32 = std.math.maxInt(u32);
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, max_len, .big);
    const decoded = std.mem.readInt(u32, &hdr, .big);
    try std.testing.expectEqual(max_len, decoded);
}

test "zix edge: TcpServer EPOLL with workers = 1, minimum explicit count initializes correctly" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    var server = try zix.Tcp.Server.init(zix.Tcp.echoHandler, .{
        .io = threaded.io(),
        .ip = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .EPOLL,
        .workers = 1,
    });
    server.deinit();
    try std.testing.expectEqual(@as(usize, 1), server.config.workers);
}

test "zix edge: TcpClientConfig, recv_timeout_ms = 0 disables timeout (default)" {
    const cfg = zix.Tcp.ClientConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
}

test "zix edge: TcpClientConfig, send_timeout_ms = 0 disables timeout (default)" {
    const cfg = zix.Tcp.ClientConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(@as(u32, 0), cfg.send_timeout_ms);
}

test "zix edge: TcpClientConfig, large recv_timeout_ms value is stored without overflow" {
    const cfg = zix.Tcp.ClientConfig{
        .ip = "127.0.0.1",
        .port = 9300,
        .recv_timeout_ms = std.math.maxInt(u32),
    };
    try std.testing.expectEqual(std.math.maxInt(u32), cfg.recv_timeout_ms);
}
