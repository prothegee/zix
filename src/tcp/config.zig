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
    /// Single epoll event loop accepts connections and dispatches readable
    /// sockets to a worker pool. Each worker handles one request then re-arms
    /// the socket (EPOLLONESHOT), so idle keep-alive connections hold no thread.
    /// Best for very high connection counts and slow/idle clients. Linux-only.
    /// pool_size sets the worker count. Http, Grpc, Fix, and Tcp implement natively on Linux (Http2 falls back to .POOL).
    EPOLL = 3,
}; // for all Tcp

// --------------------------------------------------------- //

/// TCP stream server configuration.
/// Pass to TcpServer.init(). Fields without defaults (ip, port) are required.
pub const TcpServerConfig = struct {
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// Connection dispatch model. Default: .ASYNC (single accept thread, io.async() per connection).
    dispatch_model: DispatchModel = .ASYNC,
    /// TCP listen backlog: pending connections queued by the kernel before accept().
    kernel_backlog: u31 = 4096,
    /// Maximum payload bytes per frame. Frames exceeding this close the connection.
    max_msg_len: usize = 4096,
    /// Number of accept threads (0 = cpu_count). Ignored by .ASYNC.
    workers: usize = 0,
    /// Number of pool threads (0 = max(10, cpu_count * 2)). Only used by .POOL.
    pool_size: usize = 0,
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
    max_msg_len: usize = 4096,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: TcpServerConfig, default field values" {
    const cfg = TcpServerConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9300), cfg.port);
    try std.testing.expectEqual(DispatchModel.ASYNC, cfg.dispatch_model);
    try std.testing.expectEqual(@as(u31, 4096), cfg.kernel_backlog);
    try std.testing.expectEqual(@as(usize, 4096), cfg.max_msg_len);
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expectEqual(@as(usize, 0), cfg.pool_size);
}

test "zix test: TcpClientConfig, default field values" {
    const cfg = TcpClientConfig{ .ip = "127.0.0.1", .port = 9300 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9300), cfg.port);
    try std.testing.expectEqual(@as(usize, 4096), cfg.max_msg_len);
}
