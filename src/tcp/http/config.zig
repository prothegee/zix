//! zix http server config

const std = @import("std");
const HeaderSize = @import("response.zig").HeaderSize;
const RequestHeaderSize = @import("parser.zig").RequestHeaderSize;
const Logger = @import("../../logger/logger.zig").Logger;
const Tls = @import("../../tls/Tls.zig");
pub const DispatchModel = @import("../config.zig").DispatchModel;

// --------------------------------------------------------- //

/// Configuration for an HTTP server instance.
/// Pass to Http.Server.init(). Fields without defaults (ip, port) are required.
pub const HttpServerConfig = struct {
    /// Io backend for the server. Caller-provided. Must outlive the server.
    io: std.Io,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// Connection dispatch model. Selects between .ASYNC, .POOL, .MIXED, .EPOLL,
    /// and .URING (.EPOLL and .URING are Linux-only and fall back to .POOL elsewhere).
    /// Required: the caller must set it explicitly (no default).
    dispatch_model: DispatchModel,
    /// TCP listen backlog: maximum pending connections queued by the kernel before accept().
    kernel_backlog: u31 = 1024 * 4,
    /// SO_BUSY_POLL spin window in microseconds for accepted connections (.EPOLL). The kernel
    /// busy-spins this long before sleeping the worker, trading CPU for lower tail latency. 0 leaves
    /// it unset. No-op when the kernel lacks SO_BUSY_POLL.
    busy_poll_us: u32 = 50,
    /// Read buffer size in bytes per request. Requests exceeding this are rejected with 431.
    max_recv_buf: usize = 1024 * 4,
    /// SO_RCVBUF (bytes) applied only while reading a large request body (uploads). Default 0 leaves
    /// the kernel default and its receive autotuning, which already sizes the upload window well on a
    /// box with a healthy net.core.rmem_max. An explicit value both caps the window AND disables
    /// autotuning, so a value below what autotuning would grow to actually slows uploads. Set it only
    /// to FORCE a window larger than autotuning, at the cost of per-connection memory while a large
    /// body is in flight. Small-request handlers never touch this path.
    large_body_rcvbuf: usize = 0,
    /// Max milliseconds Request.body() waits for the next segment of a multi-segment request body on
    /// the non-blocking .EPOLL / .URING fd before giving up (upload path). Bounds a stalled client so
    /// the worker is not blocked indefinitely. Default 30000 (30s) covers a slow upload. The hot GET
    /// path returns early (no body) and never waits here.
    body_read_timeout_ms: i32 = 30000,
    /// Per-connection send buffer size in bytes for the .URING dispatch model. The send
    /// half of the per-connection footprint (max_recv_buf covers recv). No effect under
    /// the other dispatch models.
    uring_send_buf_size: usize = 16 * 1024,
    /// Minimum warm idle-connection pool size for the .URING dispatch model. A closed connection is
    /// pooled (recv and send buffers intact) instead of freed, so a later accept reuses the
    /// allocation rather than making three heap allocations. The pool cap scales with this worker's
    /// live concurrency, with this value as the floor when the worker is idle. Mirrors zix.Http1.
    uring_idle_pool_floor: usize = 64,
    /// Enable response compression with Accept-Encoding negotiation (gzip, deflate, brotli). Default false.
    /// Compression spends CPU to shrink the body and only pays off over a real network, so leaving it off
    /// keeps the perf gate untouched. Active under .EPOLL and .URING. A handler opts in via resp.sendNegotiated.
    /// Same field set and names as Http1, for config consistency.
    compress: bool = false,
    /// Minimum response body size in bytes before compression is attempted. A body
    /// under this floor is sent uncompressed, since the header and CPU cost outweighs
    /// the saving. Mirrors utils.compression.min_size_default.
    compression_min_size: usize = 256,
    /// Max output size in bytes for one compressed response, across ALL codings
    /// (gzip, deflate, brotli). A response whose compressed form would exceed this is
    /// sent uncompressed instead.
    compression_max_out: usize = 256 * 1024,
    /// Initial arena capacity in bytes per connection. Grows automatically if exceeded.
    max_allocator_size: usize = 1024 * 4,
    /// Maximum request headers accepted per request. Requests exceeding this are rejected with 431.
    /// CUSTOM values above 64 are silently capped at the parser storage limit (64).
    /// See RequestHeaderSize for tier guidance.
    max_request_headers: RequestHeaderSize = .LARGE,
    /// Maximum custom response headers per request (default: .MINIMAL = 16).
    /// The backing buffer is arena-allocated per request to exactly this size.
    /// See docs/headers.md and zix.HeaderSize for tier guidance.
    max_response_headers: HeaderSize = .MINIMAL,
    /// Root directory for static file serving. Empty string disables static serving.
    public_dir: []const u8 = "",
    /// Upload subdirectory relative to public_dir. Receives multipart uploads.
    public_dir_upload: []const u8 = "u",
    /// Network-level connection guard (Layer D: ConnRegistry eviction).
    /// 0 = disabled. When non-zero, connections exceeding this lifetime are shut down
    /// by the background timer thread.
    /// Should be >= handler_timeout_ms to avoid cutting off an in-flight response.
    conn_timeout_ms: u32 = 0,
    /// Per-handler execution budget (Layer B: ctx.isExpired / ctx.timedOut).
    /// 0 = disabled. When non-zero, ctx.deadline is set before each handler dispatch.
    /// Handlers opt in by checking ctx.isExpired() between expensive steps.
    handler_timeout_ms: u32 = 0,
    /// Number of accept threads.
    /// 0 (default) = cpu_count accept threads.
    /// N           = exactly N accept threads.
    /// Ignored by .ASYNC (always 1 accept thread).
    workers: usize = 0,
    /// Number of pool threads. Only used by .POOL dispatch model.
    /// 0 (default) = max(10, cpu_count * 2), minimum 10, scales with core count.
    /// N           = exactly N pool threads.
    /// Ignored by .ASYNC and .MIXED.
    pool_size: usize = 0,
    /// Worker thread stack size in bytes for the .EPOLL, .URING, and .POOL handler threads.
    /// Thread stacks are demand-paged, so this costs little RSS until the depth is used.
    worker_stack_size_bytes: usize = 512 * 1024,
    /// Worker thread stack size in bytes when compression is enabled, applied as a floor under
    /// .EPOLL / .URING: the effective stack is max(worker_stack_size_bytes, this). std.compress.flate
    /// is built on the handler stack frame (about 230 KB), so a compressing handler needs more than
    /// the default. No effect when compression is off.
    worker_stack_compress_bytes: usize = 2 * 1024 * 1024,
    /// Enable the per-worker response cache (ADR-036). Default false. When off,
    /// the handler cache API (res.serveCached / res.sendCached) degrades to a
    /// plain send. Active under the .EPOLL and .URING dispatch models.
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
    /// Optional logger. When non-null, the server calls logger.access() after each
    /// response and injects a pointer into ctx.logger for handler use.
    /// Caller owns the Logger and must ensure it outlives the server.
    logger: ?*Logger = null,

    /// https - opt-in. When non-null the server serves HTTP/1.1 over TLS (zix.Tls) on a gated path,
    /// leaving the cleartext engine untouched. The .EPOLL / .URING models terminate TLS in the
    /// event-driven tls_mux worker, the thread models in tls_serve. The context (caller-owned,
    /// must outlive the server) carries the cert / key / alpn / version / curve / cipher / HSTS
    /// policy (Tls.Context.Config). Buffered responses only: SSE / streaming and WebSocket are not
    /// served over TLS yet (they bypass the buffered response sink).
    tls: ?*Tls.Context = null,
};

test "zix http: HttpServerConfig uring_send_buf_size default" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = HttpServerConfig{ .io = threaded.io(), .ip = "127.0.0.1", .port = 8080, .dispatch_model = .ASYNC };
    try std.testing.expectEqual(@as(usize, 16 * 1024), cfg.uring_send_buf_size);
    try std.testing.expectEqual(@as(usize, 64), cfg.uring_idle_pool_floor);
    try std.testing.expectEqual(@as(usize, 512 * 1024), cfg.worker_stack_size_bytes);
    try std.testing.expectEqual(@as(u32, 50), cfg.busy_poll_us);
    try std.testing.expectEqual(@as(i32, 30000), cfg.body_read_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), cfg.worker_stack_compress_bytes);
}
