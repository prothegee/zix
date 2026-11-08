//! ZIX Http1 Config
//!
//! ### file: src/zix/tcp/http1/Config.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Server configuration for one Http1 instance.
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
const HeaderSize = @import("header.zig").Size;
const BUF_SIZE = @import("ServeOpts.zig").BUF_SIZE;

// --------------------------------------------------------- //
// Fields:

io: std.Io,
ip: []const u8,
port: u16,
// TODO: tls: ?Tls = null,
// TODO: tls_port: u16,
// TODO: tls_redirect: bool = false,
logger: ?*Logger = null,
dispatch_model: DispatchModel,
workers: usize = 0,
worker_stack_size_bytes: usize = 1 * 1024,
// worker_stack_compress_bytes: usize = 2 * 1024 * 1024,
compress_worker_stack_size_bytes: usize = 2 * 1024 * 1024,
kernel_backlog: u31 = 1 * 1024,
/// Per-handler budget in milliseconds. 0 disables it. Handlers check it with
/// ctx.timedOut() between expensive steps.
handler_timeout_ms: u32 = 0,
/// Per-connection receive buffer in bytes. It bounds the header block, and a
/// body that fits in it is handed to the handler whole. 0 falls back to the
/// engine minimum (ServeOpts.BUF_SIZE).
max_recv_buf: usize = 4 * 1024,
/// Largest request body in bytes the server accepts. A larger declared
/// Content-Length gets 413 and the connection closes. 0 removes the check.
max_request_body: usize = 2 * 1024 * 1024,
/// SO_RCVBUF in bytes, set only when a body larger than max_recv_buf is
/// drained. 0 keeps the kernel default and its autotuning.
large_body_recv_buf: usize = 0,
/// Add the Date header to every response.
send_date_header: bool = true,
/// Cap on custom headers a handler may add per response (Response.addHeader).
max_response_headers: HeaderSize = .MINIMAL,
/// Enable response compression with Accept-Encoding negotiation.
compress: bool = false,
/// Bodies smaller than this many bytes are sent uncompressed.
compression_min_size: usize = 256,
/// A compressed body larger than this many bytes is sent uncompressed instead.
compression_max_out: usize = 256 * 1024,
/// Enable the per-worker response cache.
response_cache: bool = false,
/// Default cache freshness in milliseconds.
cache_ttl_ms: u32 = 1000,
/// Response cache slot count, rounded down to a power of two.
cache_max_entries: u32 = 256,
/// A response larger than this many bytes bypasses the cache.
cache_max_value_bytes: u32 = 16 * 1024,
/// Root directory for static files. Empty disables static serving.
public_dir: []const u8 = "",
/// Upload subdirectory under public_dir. The upload handler owns the write.
public_dir_upload: []const u8 = "u",
/// How long a resolved static file stays cached, in milliseconds. 0 never caches.
public_dir_cache_ttl_ms: u32 = 0,
/// Static file cache slot count.
public_dir_cache_max_entries: u32 = 256,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// The per-connection receive buffer size every dispatch model allocates.
///
/// Return:
/// - usize (max_recv_buf, or BUF_SIZE when max_recv_buf is 0)
pub fn recvBufSize(self: Self) usize {
    return if (self.max_recv_buf == 0) BUF_SIZE else self.max_recv_buf;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testConfig() Self {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 8080,
        .dispatch_model = .ASYNC,
    };
}

test "zix http1: Config, applies defaults" {
    const config = testConfig();

    try std.testing.expectEqual(@as(usize, 0), config.workers);
    try std.testing.expectEqual(@as(usize, 1024), config.worker_stack_size_bytes);
    try std.testing.expectEqual(@as(u31, 1024), config.kernel_backlog);
    try std.testing.expectEqual(@as(?*Logger, null), config.logger);
    try std.testing.expectEqual(
        @as(usize, 2 * 1024 * 1024),
        config.compress_worker_stack_size_bytes,
    );
}

test "zix http1: Config, keeps an explicit dispatch model" {
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

test "zix http1: Config, request knobs use their defaults" {
    const config = testConfig();

    try std.testing.expectEqual(@as(u32, 0), config.handler_timeout_ms);
    try std.testing.expectEqual(@as(usize, 4 * 1024), config.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 0), config.large_body_recv_buf);
    try std.testing.expect(config.send_date_header);
    try std.testing.expectEqual(HeaderSize.MINIMAL, config.max_response_headers);
}

test "zix http1: Config, max_request_body defaults to 2 MiB" {
    const config = testConfig();

    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), config.max_request_body);
}

test "zix http1: Config, compression defaults off" {
    const config = testConfig();

    try std.testing.expect(!config.compress);
    try std.testing.expectEqual(@as(usize, 256), config.compression_min_size);
    try std.testing.expectEqual(@as(usize, 256 * 1024), config.compression_max_out);
}

test "zix http1: Config, response cache defaults off" {
    const config = testConfig();

    try std.testing.expect(!config.response_cache);
    try std.testing.expectEqual(@as(u32, 1000), config.cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 256), config.cache_max_entries);
    try std.testing.expectEqual(@as(u32, 16 * 1024), config.cache_max_value_bytes);
}

test "zix http1: Config, static serving defaults off" {
    const config = testConfig();

    try std.testing.expectEqualStrings("", config.public_dir);
    try std.testing.expectEqualStrings("u", config.public_dir_upload);
    try std.testing.expectEqual(@as(u32, 0), config.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 256), config.public_dir_cache_max_entries);
}

test "zix http1: Config, keeps an explicit header cap" {
    var config = testConfig();
    config.max_response_headers = .{ .CUSTOM = 40 };

    try std.testing.expectEqual(@as(usize, 40), config.max_response_headers.value());
}

test "zix http1: Config, recvBufSize returns max_recv_buf" {
    var config = testConfig();
    config.max_recv_buf = 2 * 1024 * 1024;

    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), config.recvBufSize());
}

test "zix http1: Config, recvBufSize falls back on zero" {
    var config = testConfig();
    config.max_recv_buf = 0;

    try std.testing.expectEqual(BUF_SIZE, config.recvBufSize());
}

