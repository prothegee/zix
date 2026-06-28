//! Behaviour tests: zix.Udp.ServerConfig and ClientConfig default field values.
//! Verifies the defaults callers rely on without starting a live server.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: UdpServerConfig, conn_timeout_ms defaults to 5000" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = zix.Udp.ServerConfig{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9100,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(@as(i64, 5000), cfg.conn_timeout_ms);
}

test "zix behaviour: UdpServerConfig, poll_timeout_ms defaults to 2000" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = zix.Udp.ServerConfig{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9100,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(@as(i64, 2000), cfg.poll_timeout_ms);
}

test "zix behaviour: UdpServerConfig, auto_ack defaults to false" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = zix.Udp.ServerConfig{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9100,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expect(!cfg.auto_ack);
}

test "zix behaviour: UdpServerConfig, broadcast defaults to false" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = zix.Udp.ServerConfig{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9100,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expect(!cfg.broadcast);
}

test "zix behaviour: UdpServerConfig, endianness defaults to LITTLE" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = zix.Udp.ServerConfig{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9100,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(zix.Udp.Endianness.LITTLE, cfg.endianness);
}

test "zix behaviour: UdpServerConfig, port_mode defaults to REQUIRED" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = zix.Udp.ServerConfig{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9100,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(zix.Udp.PortMode.REQUIRED, cfg.port_mode);
}

test "zix behaviour: UdpClientConfig, send_once defaults to false" {
    const cfg = zix.Udp.ClientConfig{
        .ip = "127.0.0.1",
        .server_port = 9100,
        .bind_port = 9101,
    };
    try std.testing.expect(!cfg.send_once);
}

test "zix behaviour: UdpClientConfig, send_every defaults to 99" {
    const cfg = zix.Udp.ClientConfig{
        .ip = "127.0.0.1",
        .server_port = 9100,
        .bind_port = 9101,
    };
    try std.testing.expectEqual(@as(u64, 99), cfg.send_every);
}

test "zix behaviour: UdpClientConfig, endianness defaults to LITTLE" {
    const cfg = zix.Udp.ClientConfig{
        .ip = "127.0.0.1",
        .server_port = 9100,
        .bind_port = 9101,
    };
    try std.testing.expectEqual(zix.Udp.Endianness.LITTLE, cfg.endianness);
}

test "zix behaviour: UdpClientConfig, recv_timeout_ms defaults to 0 (disabled)" {
    const cfg = zix.Udp.ClientConfig{
        .ip = "127.0.0.1",
        .server_port = 9100,
        .bind_port = 9101,
    };
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
}
