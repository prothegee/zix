//! Behaviour tests: zix.Http1.ServerConfig field defaults and DispatchModel contract.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: Http1 ServerConfig dispatch_model is required and stored as set" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(zix.Http1.DispatchModel.ASYNC, cfg.dispatch_model);
}

test "zix behaviour: Http1 ServerConfig workers defaults to zero (auto)" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
}

test "zix behaviour: Http1 ServerConfig kernel_backlog default is 1024" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(@as(u31, 1024), cfg.kernel_backlog);
}

test "zix behaviour: Http1 ServerConfig buffer size defaults" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(@as(usize, 6 * 1024), cfg.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 256 * 1024), cfg.compression_max_out);
}

test "zix behaviour: Http1 ServerConfig compression defaults" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(false, cfg.compress);
    try std.testing.expectEqual(@as(usize, 256), cfg.compression_min_size);
    try std.testing.expectEqual(@as(usize, 256 * 1024), cfg.compression_max_out);
}

test "zix behaviour: Http1 DispatchModel integer backing values (ASYNC=0 is zero-value)" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Http1.DispatchModel.ASYNC));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Http1.DispatchModel.EPOLL));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(zix.Http1.DispatchModel.URING));
}

test "zix behaviour: Http1 ServerConfig static cache is off by default" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .ASYNC,
    };

    // 0 means never cached, so an upgrade cannot change how an existing deployment serves files.
    try std.testing.expectEqual(@as(u32, 0), cfg.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 256), cfg.public_dir_cache_max_entries);
}

test "zix behaviour: Http1 ServerConfig static cache fields are stored as set" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .ASYNC,
        .public_dir = "./public",
        .public_dir_cache_ttl_ms = 5_000,
        .public_dir_cache_max_entries = 64,
    };

    try std.testing.expectEqual(@as(u32, 5_000), cfg.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 64), cfg.public_dir_cache_max_entries);
}

test "zix behaviour: Http1 static cache knobs are independent of the response cache knobs" {
    const cfg = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .ASYNC,
        .public_dir_cache_ttl_ms = 9_000,
    };

    // The response cache (ADR-036) keeps its own defaults: the two caches share no state.
    try std.testing.expectEqual(@as(u32, 9_000), cfg.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 1000), cfg.cache_ttl_ms);
    try std.testing.expectEqual(false, cfg.response_cache);
}
