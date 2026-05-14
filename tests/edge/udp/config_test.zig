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
    const S = zix.Udp.Server(extern struct { id: u32 });
    try std.testing.expectError(
        error.PortNotConfigured,
        S.init(.{ .allocator = std.heap.smp_allocator, .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix edge: UdpServer.init, non-zero port with REQUIRED mode succeeds" {
    const S = zix.Udp.Server(extern struct { id: u32 });
    _ = try S.init(.{ .allocator = std.heap.smp_allocator, .ip = "127.0.0.1", .port = 9199 });
}
