//! HTTP/2 server configuration.

const std = @import("std");
const DispatchModel = @import("../config.zig").DispatchModel;
const Logger = @import("../../logger/logger.zig").Logger;
const Tls = @import("../../tls/Tls.zig");

// --------------------------------------------------------- //

/// Configuration for an HTTP/2 h2c server instance.
/// Pass to Http2.Server.init(). Fields without defaults (io, ip, port) are required.
pub const Http2ServerConfig = struct {
    /// Io backend for the server. Caller-provided. Must outlive the server.
    io: std.Io,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// Connection dispatch model. .ASYNC, .POOL, .MIXED are the cleartext blocking models. .EPOLL
    /// and .URING are the Linux-only shared-nothing multiplexed loops (one SO_REUSEPORT listener
    /// plus epoll or io_uring per worker), driving the resumable h2 state machine. .URING probes the
    /// ring at startup and falls back to .EPOLL when io_uring is unavailable. Off Linux both fold to
    /// .POOL. Ignored on the TLS path (the https terminator runs the blocking engine).
    /// Required: the caller must set it explicitly (no default).
    dispatch_model: DispatchModel,
    /// TCP listen backlog.
    kernel_backlog: u31 = 1024,
    /// Accept thread count.
    /// 0 (default) = cpu_count accept threads.
    /// Ignored by .ASYNC (always 1 accept thread).
    workers: usize = 0,
    /// Pool thread count. Only used by .POOL.
    /// 0 (default) = max(10, cpu_count * 2).
    /// Ignored by .ASYNC and .MIXED.
    pool_size: usize = 0,
    /// Worker thread stack size in bytes for the .EPOLL, .URING, .POOL, and TLS handler threads.
    /// Thread stacks are demand-paged, so this costs little RSS until the depth is used.
    worker_stack_size_bytes: usize = 512 * 1024,
    /// SO_BUSY_POLL spin window in microseconds for accepted connections (.EPOLL / .URING). The
    /// kernel busy-spins this long before sleeping the worker, trading CPU for lower wake-up latency
    /// on saturated benchmarks. Default 0 leaves it unset, so the engine's current CPU profile is
    /// unchanged. Mirrors zix.Http1's busy_poll_us: set to e.g. 50 to opt in. No-op when the kernel
    /// lacks SO_BUSY_POLL.
    busy_poll_us: u32 = 0,
    /// Maximum concurrent streams per connection.
    max_streams: usize = 16,
    /// MAX_FRAME_SIZE setting sent to clients (bytes).
    max_frame_size: u32 = 16384,
    /// HPACK scratch buffer size per connection.
    max_header_scratch: usize = 4096,
    /// Maximum body buffer per stream (bytes).
    max_body: usize = 65536,
    /// Per-connection receive buffer in bytes (.EPOLL / .URING mux). Used as a floor: the reader is
    /// sized to the larger of this and one max frame, so a larger value cuts read() and compaction
    /// for big frames.
    max_recv_buf: usize = 32 * 1024,
    /// Initial capacity in bytes of the per-connection TLS pending-write buffer (it grows on demand).
    /// A larger initial avoids early reallocation under big responses on the TLS path.
    tls_write_buf_initial_bytes: usize = 16 * 1024,
    /// Enable the per-worker response cache (ADR-036). Default false. When off, the handler cache API
    /// (serveCached / sendCached) degrades to a plain send. Active under .EPOLL and .URING.
    response_cache: bool = false,
    /// Response cache slot count, rounded down to a power of two. Per-worker memory is
    /// cache_max_entries * cache_max_value_bytes, times the worker count.
    cache_max_entries: u32 = 256,
    /// Per-slot response cap in bytes. A response larger than this bypasses the cache.
    cache_max_value_bytes: u32 = 16 * 1024,
    /// Default cache freshness in milliseconds, exposed to handlers via cacheTtl().
    cache_ttl_ms: u32 = 1000,
    /// Optional ceiling on per-worker cache memory in bytes. 0 disables the ceiling.
    cache_max_total_bytes: usize = 0,
    /// https - opt-in. When non-null the server serves HTTP/2 over TLS (zix.Tls, ALPN h2), otherwise
    /// h2c cleartext, the default. The TLS path is a gated blocking terminator in front of the
    /// existing h2c engine, so the cleartext dispatch models are untouched. The context carries the
    /// cert / key / alpn / version / curve / cipher / HSTS policy (Tls.Context.Config). For the
    /// Http2 engine alpn should include .H2 (browsers require ALPN h2 for HTTP/2 over TLS, RFC 7540
    /// 3.3). Caller owns the Context and must ensure it outlives the server.
    tls: ?*Tls.Context = null,
    /// Optional logger. When non-null, the server calls logger.system() for lifecycle
    /// events (listening, fallback notices) instead of std.debug.print. The h2c handler
    /// owns its frame I/O, so per-request access logging is the handler's responsibility.
    /// Caller owns the Logger and must ensure it outlives the server.
    logger: ?*Logger = null,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: Http2ServerConfig required fields" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 8082), cfg.port);
}

test "zix test: Http2ServerConfig dispatch_model is required and stored as set" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC };
    try std.testing.expectEqual(DispatchModel.ASYNC, cfg.dispatch_model);
}

test "zix test: Http2ServerConfig worker and pool defaults to zero" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC };
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expectEqual(@as(usize, 0), cfg.pool_size);
}

test "zix test: Http2ServerConfig stream and frame defaults" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC };
    try std.testing.expectEqual(@as(usize, 16), cfg.max_streams);
    try std.testing.expectEqual(@as(u32, 16384), cfg.max_frame_size);
    try std.testing.expectEqual(@as(usize, 65536), cfg.max_body);
}

test "zix test: Http2ServerConfig logger defaults to null" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC };
    try std.testing.expect(cfg.logger == null);
}

test "zix test: Http2ServerConfig worker_stack_size_bytes default" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC };
    try std.testing.expectEqual(@as(usize, 512 * 1024), cfg.worker_stack_size_bytes);
    try std.testing.expectEqual(@as(usize, 32 * 1024), cfg.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 16 * 1024), cfg.tls_write_buf_initial_bytes);
    try std.testing.expectEqual(@as(u32, 0), cfg.busy_poll_us);
}
