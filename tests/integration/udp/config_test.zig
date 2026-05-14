//! Integration tests: zix.Udp.Server(T).init wiring and error enforcement.
//! Verifies that init accepts a valid config and rejects port zero.

const std = @import("std");
const zix = @import("zix");

const Pkt = extern struct { id: u32, value: f32 };

test "zix integration: UdpServer.init, valid config succeeds" {
    const S = zix.Udp.Server(Pkt);
    const server = try S.init(.{
        .allocator = std.heap.smp_allocator,
        .ip = "127.0.0.1",
        .port = 9200,
    });
    _ = server;
}

test "zix integration: UdpServer.init, port zero returns error.PortNotConfigured" {
    const S = zix.Udp.Server(Pkt);
    try std.testing.expectError(
        error.PortNotConfigured,
        S.init(.{ .allocator = std.heap.smp_allocator, .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix integration: UdpClient.init, zero bind_port returns error.PortNotConfigured" {
    const C = zix.Udp.Client(Pkt);
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        C.init(.{ .server_ip = "127.0.0.1", .server_port = 9200, .bind_port = 0 }, io),
    );
}
