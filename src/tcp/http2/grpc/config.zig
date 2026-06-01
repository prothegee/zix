//! gRPC server and client configuration.

const std = @import("std");
const DispatchModel = @import("../../config.zig").DispatchModel;
const Logger = @import("../../../logger/logger.zig").Logger;

// --------------------------------------------------------- //

/// Configuration for a gRPC h2c server instance.
/// Pass to Grpc.Server.init(). Fields without defaults (io, ip, port) are required.
/// No allocator field — the server uses smp_allocator internally.
pub const GrpcServerConfig = struct {
    /// Io backend for the server. Caller-provided. Must outlive the server.
    io: std.Io,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// Connection dispatch model. Selects between POOL, ASYNC, and MIXED.
    /// Default: .ASYNC (single accept thread, io.async() per connection).
    dispatch_model: DispatchModel = .ASYNC,
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
    /// Maximum concurrent h2 streams per connection.
    max_streams: usize = 16,
    /// MAX_FRAME_SIZE setting sent to clients (bytes).
    max_frame_size: u32 = 16384,
    /// HPACK scratch buffer size per connection.
    max_header_scratch: usize = 4096,
    /// Maximum body buffer per stream (bytes).
    max_body: usize = 65536,
    /// Optional logger. When non-null, the server calls logger.system() for lifecycle events
    /// and logger.rpc() for each gRPC stream dispatched. Caller owns. Must outlive the server.
    logger: ?*Logger = null,
    /// Global handler timeout cap (milliseconds). 0 = disabled.
    /// When non-zero, each gRPC stream dispatch sets GrpcContext.deadline_ns to
    /// now + tighter_of(handler_timeout_ms, Route.timeout_ms, grpc-timeout header).
    /// Handlers opt in by checking ctx.isExpired() between expensive steps.
    handler_timeout_ms: u32 = 0,
};

/// Configuration for a gRPC h2c client connection.
/// Pass to Grpc.Client.connect().
pub const GrpcClientConfig = struct {
    /// Server address.
    ip: []const u8,
    /// Server port. Must be non-zero.
    port: u16,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix grpc: GrpcServerConfig required fields" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = GrpcServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8083 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 8083), cfg.port);
}

test "zix grpc: GrpcServerConfig dispatch_model defaults to ASYNC" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = GrpcServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8083 };
    try std.testing.expectEqual(DispatchModel.ASYNC, cfg.dispatch_model);
}

test "zix grpc: GrpcServerConfig worker and pool defaults to zero" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = GrpcServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8083 };
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expectEqual(@as(usize, 0), cfg.pool_size);
}

test "zix grpc: GrpcServerConfig stream and body defaults" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = GrpcServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8083 };
    try std.testing.expectEqual(@as(usize, 16), cfg.max_streams);
    try std.testing.expectEqual(@as(u32, 16384), cfg.max_frame_size);
    try std.testing.expectEqual(@as(usize, 65536), cfg.max_body);
}

test "zix grpc: GrpcServerConfig handler_timeout_ms defaults to zero" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = GrpcServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8083 };
    try std.testing.expectEqual(@as(u32, 0), cfg.handler_timeout_ms);
}

test "zix grpc: GrpcClientConfig fields" {
    const cfg = GrpcClientConfig{ .ip = "127.0.0.1", .port = 8083 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 8083), cfg.port);
}
