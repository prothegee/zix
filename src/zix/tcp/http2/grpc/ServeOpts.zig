//! ZIX Http2 Grpc ServeOpts
//!
//! ### file: src/zix/tcp/http2/grpc/ServeOpts.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-connection serving knobs for one gRPC connection.
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
const frame = @import("../frame.zig");
const Logger = @import("../../../logger/Logger.zig");

// --------------------------------------------------------- //
// Fields:

/// Advertised as SETTINGS_MAX_CONCURRENT_STREAMS.
max_streams: usize = 128,
/// Advertised as SETTINGS_MAX_FRAME_SIZE, in bytes.
max_frame_size: u32 = frame.DEFAULT_MAX_FRAME_SIZE,
/// HPACK scratch per stream, in bytes.
max_header_scratch: usize = 4096,
/// Largest gRPC body buffered per stream, in bytes.
max_body: usize = 16384,
/// Read buffer floor per connection, in bytes. The reader is sized to the
/// larger of this and one max frame.
conn_read_buf_min: usize = 64 * 1024,
/// Initial TLS pending-write buffer per connection, in bytes.
tls_write_buf_initial: usize = 16 * 1024,
/// One logger.rpc line per call when set.
logger: ?*Logger = null,
/// Server handler budget in milliseconds. 0 disables it.
handler_timeout_ms: u32 = 0,
/// Pool that runs server-streaming calls. Null spawns one thread per call.
io: ?std.Io = null,
/// Gzip replies for a client that accepts gzip.
compress: bool = false,
/// Enable the per-worker unary response cache.
response_cache: bool = false,
/// Response cache slot count, rounded down to a power of two.
cache_max_entries: u32 = 256,
/// A reply message past this many bytes bypasses the cache.
cache_max_value_bytes: u32 = 16 * 1024,
/// Default cache freshness in milliseconds.
cache_ttl_ms: u32 = 1000,
/// Ceiling on per-worker cache memory in bytes. 0 disables the ceiling.
cache_max_total_bytes: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc: ServeOpts, stream and frame defaults" {
    const opts: Self = .{};

    try std.testing.expectEqual(@as(usize, 128), opts.max_streams);
    try std.testing.expectEqual(frame.DEFAULT_MAX_FRAME_SIZE, opts.max_frame_size);
    try std.testing.expectEqual(@as(usize, 4096), opts.max_header_scratch);
    try std.testing.expectEqual(@as(usize, 16384), opts.max_body);
}

test "zix http2 grpc: ServeOpts, buffer defaults" {
    const opts: Self = .{};

    try std.testing.expectEqual(@as(usize, 64 * 1024), opts.conn_read_buf_min);
    try std.testing.expectEqual(@as(usize, 16 * 1024), opts.tls_write_buf_initial);
}

test "zix http2 grpc: ServeOpts, handler defaults" {
    const opts: Self = .{};

    try std.testing.expect(opts.logger == null);
    try std.testing.expect(opts.io == null);
    try std.testing.expectEqual(@as(u32, 0), opts.handler_timeout_ms);
    try std.testing.expect(!opts.compress);
}

test "zix http2 grpc: ServeOpts, response cache defaults off" {
    const opts: Self = .{};

    try std.testing.expect(!opts.response_cache);
    try std.testing.expectEqual(@as(u32, 256), opts.cache_max_entries);
    try std.testing.expectEqual(@as(u32, 16 * 1024), opts.cache_max_value_bytes);
    try std.testing.expectEqual(@as(u32, 1000), opts.cache_ttl_ms);
    try std.testing.expectEqual(@as(usize, 0), opts.cache_max_total_bytes);
}

