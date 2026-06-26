//! zix http1 server configuration

const std = @import("std");
const DispatchModel = @import("../config.zig").DispatchModel;
const Logger = @import("../../logger/logger.zig").Logger;
const Tls = @import("../../tls/Tls.zig");

/// HTTP/1 server configuration.
pub const Http1ServerConfig = struct {
    /// std.Io handle from process.io.
    io: @import("std").Io,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// Connection dispatch model. Default: .ASYNC.
    dispatch_model: DispatchModel = .ASYNC,
    /// TCP listen backlog.
    kernel_backlog: u31 = 1024,
    /// SO_BUSY_POLL spin window in microseconds for accepted connections (.EPOLL). The kernel
    /// busy-spins this long before sleeping the worker, trading CPU for lower tail latency. 0 leaves
    /// it unset. No-op when the kernel lacks SO_BUSY_POLL.
    busy_poll_us: u32 = 50,
    /// Max bytes to buffer per request header block and per HTTP connection
    /// in EPOLL mode.
    max_recv_buf: usize = 16 * 1024,
    /// Per-connection receive buffer size for WebSocket connections in EPOLL
    /// mode. 0 falls back to max_recv_buf. Set larger than max_recv_buf to
    /// give WS connections more room to accumulate pipelined frames without
    /// forcing a compact+re-read on every fill.
    ws_recv_buf: usize = 0,
    /// Per-connection send buffer size in bytes for the .URING dispatch model. The send
    /// half of the per-connection footprint (max_recv_buf covers recv). A response larger
    /// than this grows the buffer up to an internal ceiling so it still leaves as one
    /// on-ring send. No effect under the other dispatch models.
    uring_send_buf_size: usize = 16 * 1024,
    /// Warm idle-connection pool floor for the .URING dispatch model (A2): the minimum
    /// number of closed connections kept warm (buffers resident) per worker when otherwise
    /// idle, so a trickle of new connections skips the allocator. The effective warm cap is
    /// max(live_count, this). No effect under the other dispatch models.
    uring_idle_pool_floor: usize = 64,
    /// Enable response compression with Accept-Encoding negotiation (gzip, deflate,
    /// brotli). Default false. Compression spends CPU to shrink the body, which only
    /// pays off over a real network: on a loopback benchmark it is a pure CPU add, so
    /// leaving it off keeps the URING perf gate untouched.
    ///
    /// Note:
    /// - Active under the .EPOLL and .URING dispatch models (shared-nothing, one owner
    ///   per worker), installed into the write path from setCompression. A handler opts
    ///   in by calling writeNegotiated instead of writeSimple. Caching the compressed
    ///   bytes per (key, encoding) is a separate slice, still pending.
    compression: bool = false,
    /// Minimum response body size in bytes before compression is attempted. A body
    /// under this floor is sent uncompressed, since the header and CPU cost outweighs
    /// the saving. Mirrors utils.compression.min_size_default.
    compression_min_size: usize = 256,
    /// Max output size in bytes for one compressed response, across ALL codings
    /// (gzip, deflate, brotli): the codec-agnostic successor to the former max_gzip_out.
    /// A response whose compressed form would exceed this is sent uncompressed instead.
    compression_max_out: usize = 256 * 1024,
    /// No-op with the lazy engine. Kept for source compatibility.
    max_headers: u8 = 16,
    /// Accept thread count (0 = cpu_count). Ignored by .ASYNC.
    workers: usize = 0,
    /// Pool thread count (0 = max(10, cpu_count * 2)). Used by .POOL only.
    pool_size: usize = 0,
    /// Worker thread stack size in bytes for the .EPOLL, .URING, and .POOL handler threads.
    /// Thread stacks are demand-paged, so this costs little RSS until the depth is used.
    worker_stack_size_bytes: usize = 512 * 1024,
    /// Worker thread stack size in bytes when compression is enabled, applied as a floor under
    /// .EPOLL / .URING: the effective stack is max(worker_stack_size_bytes, this). std.compress.flate
    /// is built on the handler stack frame (about 230 KB), so a compressing handler needs more than
    /// the default. No effect when compression is off.
    worker_stack_compress_bytes: usize = 2 * 1024 * 1024,
    /// Per-handler execution budget in milliseconds. 0 = disabled.
    /// When non-zero, the server arms a thread-local deadline before each dispatch.
    /// Handlers opt in by calling zix.Http1.isExpired() between expensive steps and
    /// responding early. Handlers may shorten their own budget via zix.Http1.setTimeout().
    handler_timeout_ms: u32 = 0,
    /// Include the Date header in every response. Default true for RFC 7231 compliance.
    /// Set false to reduce response size by 37 bytes per response.
    send_date_header: bool = true,
    /// Enable the per-worker response cache (ADR-036). Default false. When off,
    /// the handler cache API (cacheLookup / cacheStore / writeWithCache) degrades
    /// to a no-op. Active under the .EPOLL and .URING dispatch models (both are
    /// shared-nothing, one owner thread per cache).
    response_cache: bool = false,
    /// Response cache slot count, rounded down to a power of two. Per-worker
    /// memory is cache_max_entries * cache_max_value_bytes, times the worker count.
    cache_max_entries: u32 = 256,
    /// Per-slot response cap. A response larger than this bypasses the cache.
    /// Caching pays off above a few KiB, so keep this lean.
    cache_max_value_bytes: u32 = 16 * 1024,
    /// Default freshness in milliseconds, exposed to handlers via cacheTtl().
    /// Handlers may pass their own TTL per store.
    cache_ttl_ms: u32 = 1000,
    /// Optional ceiling on per-worker cache memory. 0 disables the ceiling. When
    /// set, the effective entry count is reduced so entries * value_bytes fits.
    cache_max_total_bytes: usize = 0,
    /// https - opt-in. When non-null the server serves HTTP/1.1 over TLS (zix.Tls) on a gated path,
    /// otherwise cleartext, the default, leaving the EPOLL / URING hot path untouched. The context
    /// carries the cert / key / alpn / version / curve / cipher / HSTS policy (Tls.Context.Config).
    /// Caller owns the Context and must ensure it outlives the server.
    tls: ?*Tls.Context = null,
    /// Optional logger. When non-null, the server logs lifecycle lines (listening,
    /// fallback notices) through it instead of std.debug.print.
    ///
    /// Note:
    /// - The Http1 handler writes to the fd directly and returns void, so the server
    ///   cannot observe response status or bytes. Per-request access logging is the
    ///   handler's responsibility: call logger.access() inside the handler where the
    ///   final status and byte count are known.
    /// - Caller owns the Logger and must ensure it outlives the server.
    logger: ?*Logger = null,
};

test "zix http1: Http1ServerConfig URING knob defaults" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = Http1ServerConfig{ .io = threaded.io(), .ip = "127.0.0.1", .port = 9200 };
    try std.testing.expectEqual(@as(usize, 16 * 1024), cfg.uring_send_buf_size);
    try std.testing.expectEqual(@as(usize, 64), cfg.uring_idle_pool_floor);
}

test "zix http1: Http1ServerConfig worker stack defaults" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = Http1ServerConfig{ .io = threaded.io(), .ip = "127.0.0.1", .port = 9200 };
    try std.testing.expectEqual(@as(usize, 512 * 1024), cfg.worker_stack_size_bytes);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), cfg.worker_stack_compress_bytes);
    try std.testing.expectEqual(@as(u32, 50), cfg.busy_poll_us);
}
