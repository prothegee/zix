//! Behaviour tests: zix.Http1.ServerConfig field defaults and DispatchModel contract.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: Http1 ServerConfig dispatch_model defaults to ASYNC" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
    };
    try std.testing.expectEqual(zix.Http1.DispatchModel.ASYNC, cfg.dispatch_model);
}

test "zix behaviour: Http1 ServerConfig workers and pool_size default to zero (auto)" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
    };
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expectEqual(@as(usize, 0), cfg.pool_size);
}

test "zix behaviour: Http1 ServerConfig kernel_backlog default is 1024" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
    };
    try std.testing.expectEqual(@as(u31, 1024), cfg.kernel_backlog);
}

test "zix behaviour: Http1 ServerConfig buffer size defaults" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
    };
    try std.testing.expectEqual(@as(usize, 16 * 1024), cfg.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 256 * 1024), cfg.max_gzip_out);
}

test "zix behaviour: Http1 DispatchModel integer backing values (ASYNC=0 is zero-value)" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Http1.DispatchModel.ASYNC));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Http1.DispatchModel.POOL));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(zix.Http1.DispatchModel.MIXED));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(zix.Http1.DispatchModel.EPOLL));
}
