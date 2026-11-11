//! ZIX Http2 Config
//!
//! ### file: src/zix/tcp/http2/Config.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Server configuration for one Http2 (h2c) instance.
//!
//! ### note:
//!
//! n/a
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const DispatchModel = @import("../../shared/dispatch.zig").Model;
const Logger = @import("../../logger/Logger.zig");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
ip: []const u8,
port: u16,
/// .ASYNC is the portable blocking model. .EPOLL and .URING are the Linux
/// multiplexed loops, rejected off Linux.
dispatch_model: DispatchModel,
kernel_backlog: u31 = 1024,
/// Worker count for .EPOLL and .URING (0 = cpu count). .ASYNC ignores it.
workers: usize = 0,
/// Worker thread stack in bytes for .EPOLL, .URING, and the TLS handler
/// threads. Demand-paged, so RSS only grows with the depth a handler uses.
worker_stack_size_bytes: usize = 512 * 1024,
/// SO_BUSY_POLL spin window in microseconds (.EPOLL and .URING). 0 leaves it unset.
busy_poll_us: u32 = 0,
/// Steer a new connection to the listener on the CPU that received it
/// (.EPOLL and .URING). Opt-in.
reuseport_cbpf: bool = false,
/// Per-connection receive buffer floor in bytes (.EPOLL and .URING). The
/// reader is sized to the larger of this and one max frame.
max_recv_buf: usize = 32 * 1024,
/// Initial size in bytes of the per-connection TLS pending-write buffer. It
/// grows on demand.
tls_write_buf_initial_bytes: usize = 16 * 1024,
/// Advertised as SETTINGS_MAX_CONCURRENT_STREAMS.
max_streams: u32 = 128,
/// Advertised as SETTINGS_MAX_FRAME_SIZE, in bytes.
max_frame_size: u32 = 16384,
/// HPACK scratch buffer size per connection, in bytes.
max_header_scratch: usize = 4096,
/// Largest request body buffered per stream, in bytes (.EPOLL and .URING).
/// A larger body is rejected with 413, never cut.
max_body: usize = 16384,
/// Enable the per-worker response cache.
response_cache: bool = false,
/// Response cache slot count, rounded down to a power of two.
cache_max_entries: u32 = 256,
/// A response larger than this many bytes bypasses the cache.
cache_max_value_bytes: u32 = 16 * 1024,
/// Default cache freshness in milliseconds.
cache_ttl_ms: u32 = 1000,
/// Ceiling on per-worker cache memory in bytes. 0 disables the ceiling.
cache_max_total_bytes: usize = 0,
// TODO: tls: ?*Tls.Context = null,
// TODO: tls_port: u16 = 0,
logger: ?*Logger = null,
/// Per-handler budget in milliseconds. 0 disables it. Seeds the context
/// deadline at dispatch.
handler_timeout_ms: u32 = 0,
/// Root directory for static files. Empty disables static serving.
public_dir: []const u8 = "",
/// How long a resolved static file stays cached, in milliseconds. 0 never caches.
public_dir_cache_ttl_ms: u32 = 0,
/// Static file cache slot count.
public_dir_cache_max_entries: u32 = 256,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testConfig() Self {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 8082,
        .dispatch_model = .ASYNC,
    };
}

test "zix http2: Config, keeps the required fields" {
    const config = testConfig();

    try std.testing.expectEqualStrings("127.0.0.1", config.ip);
    try std.testing.expectEqual(@as(u16, 8082), config.port);
    try std.testing.expectEqual(DispatchModel.ASYNC, config.dispatch_model);
}

test "zix http2: Config, keeps an explicit dispatch model" {
    const config: Self = .{
        .io = std.testing.io,
        .ip = "0.0.0.0",
        .port = 1,
        .dispatch_model = .URING,
        .workers = 4,
    };

    try std.testing.expectEqual(DispatchModel.URING, config.dispatch_model);
    try std.testing.expectEqual(@as(usize, 4), config.workers);
}

test "zix http2: Config, worker defaults" {
    const config = testConfig();

    try std.testing.expectEqual(@as(usize, 0), config.workers);
    try std.testing.expectEqual(@as(u31, 1024), config.kernel_backlog);
    try std.testing.expectEqual(@as(usize, 512 * 1024), config.worker_stack_size_bytes);
    try std.testing.expectEqual(@as(u32, 0), config.busy_poll_us);
    try std.testing.expect(!config.reuseport_cbpf);
}

test "zix http2: Config, buffer defaults" {
    const config = testConfig();

    try std.testing.expectEqual(@as(usize, 32 * 1024), config.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 16 * 1024), config.tls_write_buf_initial_bytes);
    try std.testing.expectEqual(@as(usize, 4096), config.max_header_scratch);
}

test "zix http2: Config, stream and frame defaults" {
    const config = testConfig();

    try std.testing.expectEqual(@as(u32, 128), config.max_streams);
    try std.testing.expectEqual(@as(u32, 16384), config.max_frame_size);
    try std.testing.expectEqual(@as(usize, 16384), config.max_body);
}

test "zix http2: Config, response cache defaults off" {
    const config = testConfig();

    try std.testing.expect(!config.response_cache);
    try std.testing.expectEqual(@as(u32, 256), config.cache_max_entries);
    try std.testing.expectEqual(@as(u32, 16 * 1024), config.cache_max_value_bytes);
    try std.testing.expectEqual(@as(u32, 1000), config.cache_ttl_ms);
    try std.testing.expectEqual(@as(usize, 0), config.cache_max_total_bytes);
}

test "zix http2: Config, logger defaults to null" {
    const config = testConfig();

    try std.testing.expectEqual(@as(?*Logger, null), config.logger);
}

test "zix http2: Config, handler_timeout_ms defaults to zero" {
    const config = testConfig();

    try std.testing.expectEqual(@as(u32, 0), config.handler_timeout_ms);
}

test "zix http2: Config, static serving defaults off" {
    const config = testConfig();

    try std.testing.expectEqualStrings("", config.public_dir);
    try std.testing.expectEqual(@as(u32, 0), config.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 256), config.public_dir_cache_max_entries);
}

