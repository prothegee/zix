//! zix http1 server configuration

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
    /// Max bytes to buffer per request header block and per HTTP connection
    /// in EPOLL mode.
    max_recv_buf: usize = 16 * 1024,
    /// Per-connection receive buffer size for WebSocket connections in EPOLL
    /// mode. 0 falls back to max_recv_buf. Set larger than max_recv_buf to
    /// give WS connections more room to accumulate pipelined frames without
    /// forcing a compact+re-read on every fill.
    ws_recv_buf: usize = 0,
    /// Enable response compression with Accept-Encoding negotiation (gzip and
    /// deflate, brotli later). Default false. Compression spends CPU to shrink the
    /// body, which only pays off over a real network: on a loopback benchmark it is
    /// a pure CPU add, so leaving it off keeps the URING perf gate untouched.
    ///
    /// Note:
    /// - Not yet read at runtime. The engine write-path wiring (negotiate, encode,
    ///   cache the compressed bytes) lands with the compression integration slice.
    compression: bool = false,
    /// Minimum response body size in bytes before compression is attempted. A body
    /// under this floor is sent uncompressed, since the header and CPU cost outweighs
    /// the saving. Mirrors utils.compression.min_size_default. Read once compression
    /// is wired into the engine.
    compression_min_size: usize = 256,
    /// Max output size in bytes for one compressed response, across ALL codings
    /// (gzip, deflate, and later brotli): the codec-agnostic successor to the former
    /// max_gzip_out. A response whose compressed form would exceed this is sent
    /// uncompressed instead.
    ///
    /// Note:
    /// - Currently informational. The live cap is the compile-time core.GZIP_OUT_SIZE
    ///   until the engine reads this field with the compression integration slice.
    compression_max_out: usize = 256 * 1024,
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
    /// https - opt-in. When tls_cert_path is non-null the server serves HTTP/1.1 over TLS 1.3
    /// (zix.Tls), otherwise cleartext, the default, leaving the EPOLL / URING hot path untouched.
    /// PEM path to the ECDSA P-256 (or Ed25519) end-entity certificate. null = cleartext.
    ///
    /// Note:
    /// - Not yet read at runtime. The https serve path (a gated serveConnTls driving the sans-I/O
    ///   zix.Tls.Connection over the fd) lands with the TLS integration slice.
    tls_cert_path: ?[]const u8 = null,
    /// PEM path to the private key matching tls_cert_path. Required when tls_cert_path is set.
    tls_key_path: ?[]const u8 = null,
    /// ALPN protocols offered over TLS, in server preference order. Empty = no ALPN (the client
    /// falls back to http/1.1). For the Http1 engine the only valid value is .HTTP_1_1.
    tls_alpn: []const Tls.Alpn = &.{},
    /// HSTS max-age in SECONDS (RFC 6797), the listener default for the Strict-Transport-Security
    /// header. 0 = no default. Seconds, not the zix _ms norm, since the spec is in seconds.
    /// Emitted by the handler (config default, handler may override per response), never
    /// auto-injected.
    hsts_max_age_s: u32 = 0,
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
