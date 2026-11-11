//! ZIX Http2 ServeOpts
//!
//! ### file: src/zix/tcp/http2/ServeOpts.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-connection serving knobs passed to the HTTP/2 connection loop.
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
const frame = @import("frame.zig");
const Logger = @import("../../logger/Logger.zig");

// --------------------------------------------------------- //
// Fields:

/// Concurrent streams per connection, advertised as
/// SETTINGS_MAX_CONCURRENT_STREAMS.
max_streams: usize = 128,
/// SETTINGS_MAX_FRAME_SIZE this server advertises and accepts.
max_frame_size: u32 = frame.DEFAULT_MAX_FRAME_SIZE,
/// HPACK string scratch per connection.
max_header_scratch: usize = 4096,
/// Request body bytes buffered per stream. A larger body is shed with 413,
/// never truncated.
max_body: usize = 16384,
/// Where served streams are recorded. Null logs nothing.
logger: ?*Logger = null,
/// Per-connection read buffer floor in bytes.
conn_read_buf_min: usize = 32 * 1024,
/// Initial size of the per-connection TLS pending-write buffer.
tls_write_buf_initial: usize = 16 * 1024,
/// Enable the per-worker response cache. When off, serveCached and
/// sendCachedFD degrade to a plain send.
response_cache: bool = false,
/// Cache slot count, rounded down to a power of two.
cache_max_entries: u32 = 256,
/// Per-slot response cap in bytes. A larger response bypasses the cache.
cache_max_value_bytes: u32 = 16 * 1024,
/// Default freshness in milliseconds, read by handlers through cacheTtl.
cache_ttl_ms: u32 = 1000,
/// Ceiling on per-worker cache memory in bytes. 0 disables it.
cache_max_total_bytes: usize = 0,
/// Default handler deadline in milliseconds. 0 disables it.
handler_timeout_ms: u32 = 0,
/// Static file root carried onto Context. Empty disables static serving.
public_dir: []const u8 = "",

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2: ServeOpts, applies defaults" {
    const opts: Self = .{};

    try std.testing.expectEqual(@as(usize, 128), opts.max_streams);
    try std.testing.expectEqual(frame.DEFAULT_MAX_FRAME_SIZE, opts.max_frame_size);
    try std.testing.expectEqual(@as(usize, 16384), opts.max_body);
    try std.testing.expectEqual(@as(u32, 0), opts.handler_timeout_ms);
    try std.testing.expect(!opts.response_cache);
    try std.testing.expect(opts.logger == null);
    try std.testing.expectEqualStrings("", opts.public_dir);
}

test "zix http2: ServeOpts, accepts explicit limits" {
    const opts: Self = .{
        .max_streams = 4,
        .max_frame_size = 32 * 1024,
        .handler_timeout_ms = 250,
    };

    try std.testing.expectEqual(@as(usize, 4), opts.max_streams);
    try std.testing.expectEqual(@as(u32, 32 * 1024), opts.max_frame_size);
    try std.testing.expectEqual(@as(u32, 250), opts.handler_timeout_ms);
}

