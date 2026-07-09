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
    /// Connection dispatch model. .ASYNC / .POOL / .MIXED are the cleartext blocking models, .EPOLL /
    /// .URING the Linux-only shared-nothing multiplexed loops (one SO_REUSEPORT listener plus epoll or
    /// io_uring per worker, .URING falls back to .EPOLL, off Linux both fold to .POOL). Required.
    dispatch_model: DispatchModel,
    /// TCP listen backlog.
    kernel_backlog: u31 = 1024,
    /// Accept thread count (0 = cpu_count). Ignored by .ASYNC (always 1 accept thread).
    workers: usize = 0,
    /// Pool thread count (0 = max(10, cpu_count * 2)). Only used by .POOL,
    /// ignored by .ASYNC and .MIXED.
    pool_size: usize = 0,
    /// Worker thread stack size in bytes for the .EPOLL, .URING, .POOL, and TLS handler threads.
    /// Thread stacks are demand-paged, so this costs little RSS until the depth is used.
    worker_stack_size_bytes: usize = 512 * 1024,
    /// SO_BUSY_POLL spin window in microseconds for accepted connections (.EPOLL / .URING): the
    /// kernel busy-spins this long before sleeping the worker, trading CPU for lower wake-up latency.
    /// Default 0 leaves it unset (set e.g. 50 to opt in). No-op when the kernel lacks SO_BUSY_POLL.
    busy_poll_us: u32 = 0,
    /// Attach SO_ATTACH_REUSEPORT_CBPF steering (.EPOLL / .URING): a new connection goes to listener
    /// index = receiving CPU mod workers instead of the 4-tuple hash, so it is served start-to-finish
    /// on the core that received it. Opt-in, default false. Silent no-op on a kernel pre-4.5.
    reuseport_cbpf: bool = false,
    /// Per-connection receive buffer in bytes (.EPOLL / .URING mux). Used as a floor: the reader is
    /// sized to the larger of this and one max frame, so a larger value cuts read() and compaction
    /// for big frames.
    max_recv_buf: usize = 32 * 1024,
    /// Initial capacity in bytes of the per-connection TLS pending-write buffer (it grows on demand).
    /// A larger initial avoids early reallocation under big responses on the TLS path.
    tls_write_buf_initial_bytes: usize = 16 * 1024,
    /// Maximum concurrent streams per connection, advertised as SETTINGS_MAX_CONCURRENT_STREAMS. The
    /// .EPOLL / .URING mux borrows each stream's slot from a per-worker pool, so this bounds
    /// concurrency without reserving the full count per connection.
    max_streams: u32 = 128,
    /// MAX_FRAME_SIZE setting sent to clients (bytes).
    max_frame_size: u32 = 16384,
    /// HPACK scratch buffer size per connection.
    max_header_scratch: usize = 4096,
    /// Maximum request body buffered per stream (bytes). A larger request body is truncated to this.
    max_body: usize = 16384,
    /// Enable the per-worker response cache (ADR-036). Default false. When off, the handler cache API
    /// (serveCached / sendCachedFD) degrades to a plain send. Active under .EPOLL and .URING.
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
    /// h2c (the default), the cleartext dispatch models untouched. alpn should include .H2 (browsers
    /// require it, RFC 7540 3.3). Caller owns the Context (Tls.Context.Config policy), must outlive.
    tls: ?*Tls.Context = null,
    /// Companion h2-over-TLS bind port for the dual-listener mode. 0 (default) keeps single-listener
    /// behavior (with tls set the server is TLS-only on port). Non-zero (requires tls) serves
    /// cleartext on port AND TLS on tls_port from one worker fleet. Ignored when tls is null.
    tls_port: u16 = 0,
    /// Optional logger. When non-null, the server calls logger.system() for lifecycle events
    /// (listening, fallback notices) instead of std.debug.print. The h2c handler owns its frame I/O,
    /// so per-request access logging is the handler's responsibility. Caller owns, must outlive.
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
    try std.testing.expectEqual(@as(u32, 128), cfg.max_streams);
    try std.testing.expectEqual(@as(u32, 16384), cfg.max_frame_size);
    try std.testing.expectEqual(@as(usize, 16384), cfg.max_body);
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
    try std.testing.expect(!cfg.reuseport_cbpf);
}
