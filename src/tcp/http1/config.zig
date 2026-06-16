//! zix http1 server configuration

const DispatchModel = @import("../config.zig").DispatchModel;
const Logger = @import("../../logger/logger.zig").Logger;

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
    /// Max bytes to buffer per request header block and per HTTP connection
    /// in EPOLL mode.
    max_recv_buf: usize = 16 * 1024,
    /// Per-connection receive buffer size for WebSocket connections in EPOLL
    /// mode. 0 falls back to max_recv_buf. Set larger than max_recv_buf to
    /// give WS connections more room to accumulate pipelined frames without
    /// forcing a compact+re-read on every fill.
    ws_recv_buf: usize = 0,
    /// Max output size for gzip-compressed responses.
    max_gzip_out: usize = 256 * 1024,
    /// No-op with the lazy engine. Kept for source compatibility.
    max_headers: u8 = 16,
    /// Accept thread count (0 = cpu_count). Ignored by .ASYNC.
    workers: usize = 0,
    /// Pool thread count (0 = max(10, cpu_count * 2)). Used by .POOL only.
    pool_size: usize = 0,
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
