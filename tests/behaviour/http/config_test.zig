//! Behaviour tests: zix.Http.ServerConfig defaults and zix.Http.HeaderSize tier values.
//! Verifies the field defaults callers rely on without starting a live server.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: ServerConfig, buffer size defaults" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9000,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(@as(u31, 1024), cfg.kernel_backlog);
    try std.testing.expectEqual(@as(usize, 6 * 1024), cfg.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 1024 * 4), cfg.max_allocator_size);
}

test "zix behaviour: ServerConfig, compression defaults match Http1" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9000,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(false, cfg.compress);
    try std.testing.expectEqual(@as(usize, 256), cfg.compression_min_size);
    try std.testing.expectEqual(@as(usize, 256 * 1024), cfg.compression_max_out);
}

test "zix behaviour: ServerConfig, timeout defaults are disabled (zero)" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9000,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(@as(u32, 0), cfg.conn_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), cfg.handler_timeout_ms);
}

test "zix behaviour: ServerConfig, static serving is disabled by default" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9000,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqualStrings("", cfg.public_dir);
    try std.testing.expectEqualStrings("u", cfg.public_dir_upload);
}

test "zix behaviour: ServerConfig, worker pool defaults to auto-size (zero)" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9000,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
}

test "zix behaviour: ServerConfig, dispatch_model is required and stored as set" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9000,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(zix.Tcp.DispatchModel.ASYNC, cfg.dispatch_model);
}

test "zix behaviour: DispatchModel, integer backing values (ASYNC=0 is zero-value)" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Tcp.DispatchModel.ASYNC));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Tcp.DispatchModel.EPOLL));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(zix.Tcp.DispatchModel.URING));
}

test "zix behaviour: ServerConfig, max_response_headers defaults to MINIMAL (16)" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9000,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(zix.Http.HeaderSize.MINIMAL, cfg.max_response_headers);
    try std.testing.expectEqual(@as(usize, 16), cfg.max_response_headers.value());
}

// --------------------------------------------------------- //

test "zix behaviour: HeaderSize, all tier values" {
    const minimal: zix.Http.HeaderSize = .MINIMAL;
    const common: zix.Http.HeaderSize = .COMMON;
    const large: zix.Http.HeaderSize = .LARGE;
    const extra_large: zix.Http.HeaderSize = .EXTRA_LARGE;
    try std.testing.expectEqual(@as(usize, 16), minimal.value());
    try std.testing.expectEqual(@as(usize, 32), common.value());
    try std.testing.expectEqual(@as(usize, 64), large.value());
    try std.testing.expectEqual(@as(usize, 128), extra_large.value());
}

test "zix behaviour: HeaderSize.CUSTOM, value() returns the given N" {
    const custom_7: zix.Http.HeaderSize = .{ .CUSTOM = 7 };
    const custom_100: zix.Http.HeaderSize = .{ .CUSTOM = 100 };
    try std.testing.expectEqual(@as(usize, 7), custom_7.value());
    try std.testing.expectEqual(@as(usize, 100), custom_100.value());
}

// --------------------------------------------------------- //

test "zix behaviour: Response, status defaults to OK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = zix.Http.Response.init(undefined, false, undefined, arena.allocator(), 32);
    const StatusCode = @TypeOf(res.status);
    try std.testing.expectEqual(StatusCode.OK, res.status);
}

test "zix behaviour: Http ServerConfig static cache is off by default" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .ASYNC,
    };

    try std.testing.expectEqual(@as(u32, 0), cfg.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 256), cfg.public_dir_cache_max_entries);
}

test "zix behaviour: Http ServerConfig static cache fields are stored as set" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .ASYNC,
        .public_dir = "./public",
        .public_dir_cache_ttl_ms = 2_500,
        .public_dir_cache_max_entries = 32,
    };

    try std.testing.expectEqual(@as(u32, 2_500), cfg.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 32), cfg.public_dir_cache_max_entries);
}
