//! Edge tests: zix.Tcp boundary conditions.
//! Verifies that port zero is rejected and DispatchModel backing values are stable.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: TcpServer.init, port zero returns PortNotConfigured" {
    const result = zix.Tcp.Server.init(.{ .ip = "127.0.0.1", .port = 0 });
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
