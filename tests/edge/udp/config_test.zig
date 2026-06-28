//! Edge tests: zix.Udp config boundary conditions.
//! Verifies PortMode enum stability and that Server.init rejects port zero.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: PortMode, CONFIGURABLE has backing value 0" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Udp.PortMode.CONFIGURABLE));
}

test "zix edge: PortMode, REQUIRED has backing value 1" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Udp.PortMode.REQUIRED));
}

test "zix edge: UdpServer.init, port zero with REQUIRED mode returns error.PortNotConfigured" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const S = zix.Udp.Server(extern struct { id: u32 });
    try std.testing.expectError(
        error.PortNotConfigured,
        S.init(.{ .io = threaded.io(), .allocator = std.heap.smp_allocator, .ip = "127.0.0.1", .port = 0, .dispatch_model = .ASYNC }),
    );
}

test "zix edge: UdpServer.init, non-zero port with REQUIRED mode succeeds" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const S = zix.Udp.Server(extern struct { id: u32 });
    _ = try S.init(.{ .io = threaded.io(), .allocator = std.heap.smp_allocator, .ip = "127.0.0.1", .port = 9199, .dispatch_model = .ASYNC });
}

test "zix edge: UdpClientConfig, recv_timeout_ms = 0 disables timeout (default)" {
    const cfg = zix.Udp.ClientConfig{
        .ip = "127.0.0.1",
        .server_port = 9200,
        .bind_port = 9141,
    };
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
}

test "zix edge: UdpClientConfig, large recv_timeout_ms value is stored without overflow" {
    const cfg = zix.Udp.ClientConfig{
        .ip = "127.0.0.1",
        .server_port = 9200,
        .bind_port = 9141,
        .recv_timeout_ms = std.math.maxInt(u32),
    };
    try std.testing.expectEqual(std.math.maxInt(u32), cfg.recv_timeout_ms);
}
