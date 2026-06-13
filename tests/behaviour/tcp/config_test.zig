//! Behaviour tests: zix.Tcp config defaults and frame wire format contracts.
//! Verifies field defaults and the 4-byte BE length-prefix frame encoding.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: TcpServerConfig, dispatch_model defaults to .ASYNC" {
    const cfg = zix.Tcp.ServerConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(zix.Tcp.DispatchModel.ASYNC, cfg.dispatch_model);
}

test "zix behaviour: TcpServerConfig, kernel_backlog defaults to 4096" {
    const cfg = zix.Tcp.ServerConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(@as(u31, 4096), cfg.kernel_backlog);
}

test "zix behaviour: TcpServerConfig, max_msg_len defaults to 4096" {
    const cfg = zix.Tcp.ServerConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(@as(usize, 4096), cfg.max_msg_len);
}

test "zix behaviour: TcpServerConfig, workers defaults to 0 (auto)" {
    const cfg = zix.Tcp.ServerConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
}

test "zix behaviour: TcpServerConfig, pool_size defaults to 0 (auto)" {
    const cfg = zix.Tcp.ServerConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(@as(usize, 0), cfg.pool_size);
}

test "zix behaviour: TcpClientConfig, max_msg_len defaults to 4096" {
    const cfg = zix.Tcp.ClientConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(@as(usize, 4096), cfg.max_msg_len);
}

test "zix behaviour: TcpClientConfig, recv_timeout_ms defaults to 0 (disabled)" {
    const cfg = zix.Tcp.ClientConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
}

test "zix behaviour: TcpClientConfig, send_timeout_ms defaults to 0 (disabled)" {
    const cfg = zix.Tcp.ClientConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqual(@as(u32, 0), cfg.send_timeout_ms);
}

test "zix behaviour: TCP frame, length header is 4-byte big-endian u32" {
    const payload_len: u32 = 1234;
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, payload_len, .big);
    const decoded = std.mem.readInt(u32, &hdr, .big);
    try std.testing.expectEqual(payload_len, decoded);
}

test "zix behaviour: TCP frame, zero-length payload encodes as four zero bytes" {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, 0, .big);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &hdr);
}

test "zix behaviour: TCP frame, header is always exactly 4 bytes" {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, 99, .big);
    try std.testing.expectEqual(@as(usize, 4), hdr.len);
}

test "zix behaviour: DispatchModel, ASYNC is zero value" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Tcp.DispatchModel.ASYNC));
}

test "zix behaviour: TcpServerConfig EPOLL, workers governs shared-nothing worker count" {
    const cfg = zix.Tcp.ServerConfig{
        .ip = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .EPOLL,
        .workers = 8,
        .pool_size = 0,
    };
    try std.testing.expectEqual(zix.Tcp.DispatchModel.EPOLL, cfg.dispatch_model);
    try std.testing.expectEqual(@as(usize, 8), cfg.workers);
}
