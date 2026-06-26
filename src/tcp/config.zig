//! zix tcp config

const std = @import("std");
const Logger = @import("../logger/logger.zig").Logger;

// --------------------------------------------------------- //

/// Connection dispatch model. Controls how accepted connections are handed off to handlers.
/// Zero-value (.ASYNC = 0) is the default for zero-init structs.
pub const DispatchModel = enum(u8) {
    /// Single accept thread dispatches each connection via io.async().
    /// workers and pool_size are ignored.
    /// Best for low latency at moderate connection counts.
    ASYNC = 0,
    /// N accept threads push connections to a shared ConnQueue.
    /// M pool threads handle each connection synchronously.
    /// Best for throughput under high connection counts.
    POOL = 1,
    /// N accept threads each dispatch via io.async() directly, no ConnQueue.
    /// pool_size is ignored.
    /// Balanced throughput and latency.
    MIXED = 2,
    /// Shared-nothing epoll: each worker owns one SO_REUSEPORT listener and
    /// one epoll instance. The kernel load-balances accepted connections across
    /// workers with no shared queue. Each connection is dispatched via io.async.
    /// Best for very high connection counts. Linux-only.
    /// workers sets the worker count (0 = cpu_count). pool_size is ignored.
    /// Http, Grpc, Fix, and Tcp implement natively on Linux (Http2 falls back to .POOL).
    EPOLL = 3,
    /// Shared-nothing io_uring: each worker owns one SO_REUSEPORT listener and
    /// one completion ring (ADR-037). Same thread-per-core topology as .EPOLL,
    /// but completion-based instead of readiness-based, so most syscall
    /// transitions are batched away. Linux-only.
    /// workers sets the worker count (0 = cpu_count). pool_size is ignored.
    /// zix.Http1, zix.Http, zix.Grpc, and zix.Fix implement natively on Linux,
    /// as do the WebSocket pump and the zix.Tcp framed path. Http2 folds to
    /// .POOL, and the zix.Tcp per-connection handler folds to .EPOLL.
    URING = 4,
}; // for all Tcp

// --------------------------------------------------------- //

/// TCP stream server configuration.
/// Pass to Tcp.Server.init(). Fields without defaults (io, ip, port) are required.
pub const TcpServerConfig = struct {
    /// Io backend for the server. Caller-provided. Must outlive the server.
    io: std.Io,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// Connection dispatch model. Default: .ASYNC (single accept thread, io.async() per connection).
    dispatch_model: DispatchModel = .ASYNC,
    /// TCP listen backlog: pending connections queued by the kernel before accept().
    kernel_backlog: u31 = 4096,
    /// Maximum payload bytes per frame. Frames exceeding this close the connection.
    max_recv_buf: usize = 4096,
    /// Per-connection send buffer size in bytes for the .URING framed model. The send half
    /// of the per-connection footprint (max_recv_buf covers recv). No effect under the other
    /// dispatch models.
    uring_send_buf_size: usize = 64 * 1024,
    /// Number of accept threads (0 = cpu_count). Ignored by .ASYNC.
    workers: usize = 0,
    /// Number of pool threads (0 = max(10, cpu_count * 2)). Only used by .POOL.
    pool_size: usize = 0,
    /// Socket receive timeout per accepted connection in milliseconds (SO_RCVTIMEO). 0 = disabled.
    recv_timeout_ms: u32 = 0,
    /// Socket send timeout per accepted connection in milliseconds (SO_SNDTIMEO). 0 = disabled.
    send_timeout_ms: u32 = 0,
    /// Optional logger. When non-null, the server calls logger.system() for lifecycle events
    /// and logger.conn() after each connection closes. Caller owns. Must outlive the server.
    logger: ?*Logger = null,
};

// --------------------------------------------------------- //

/// TCP stream client configuration.
pub const TcpClientConfig = struct {
    /// Server address.
    ip: []const u8,
    /// Server port. Must be non-zero.
    port: u16,
    /// Maximum payload bytes per frame.
    max_recv_buf: usize = 4096,
    /// Socket receive timeout after connect in milliseconds (SO_RCVTIMEO). 0 = disabled.
    recv_timeout_ms: u32 = 0,
    /// Socket send timeout after connect in milliseconds (SO_SNDTIMEO). 0 = disabled.
    send_timeout_ms: u32 = 0,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: TcpServerConfig, default field values" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = TcpServerConfig{ .io = threaded.io(), .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9300), cfg.port);
    try std.testing.expectEqual(DispatchModel.ASYNC, cfg.dispatch_model);
    try std.testing.expectEqual(@as(u31, 4096), cfg.kernel_backlog);
    try std.testing.expectEqual(@as(usize, 4096), cfg.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 64 * 1024), cfg.uring_send_buf_size);
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expectEqual(@as(usize, 0), cfg.pool_size);
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), cfg.send_timeout_ms);
}

test "zix test: DispatchModel, URING variant value and ordering" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(DispatchModel.ASYNC));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(DispatchModel.EPOLL));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(DispatchModel.URING));
}

test "zix test: TcpClientConfig, default field values" {
    const cfg = TcpClientConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9300), cfg.port);
    try std.testing.expectEqual(@as(usize, 4096), cfg.max_recv_buf);
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), cfg.send_timeout_ms);
}
