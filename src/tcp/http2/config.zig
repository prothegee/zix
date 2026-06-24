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
    /// Maximum concurrent streams per connection.
    max_streams: usize = 16,
    /// MAX_FRAME_SIZE setting sent to clients (bytes).
    max_frame_size: u32 = 16384,
    /// HPACK scratch buffer size per connection.
    max_header_scratch: usize = 4096,
    /// Maximum body buffer per stream (bytes).
    max_body: usize = 65536,
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
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 8082), cfg.port);
}

test "zix test: Http2ServerConfig dispatch_model defaults to ASYNC" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082 };
    try std.testing.expectEqual(DispatchModel.ASYNC, cfg.dispatch_model);
}

test "zix test: Http2ServerConfig worker and pool defaults to zero" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082 };
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expectEqual(@as(usize, 0), cfg.pool_size);
}

test "zix test: Http2ServerConfig stream and frame defaults" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082 };
    try std.testing.expectEqual(@as(usize, 16), cfg.max_streams);
    try std.testing.expectEqual(@as(u32, 16384), cfg.max_frame_size);
    try std.testing.expectEqual(@as(usize, 65536), cfg.max_body);
}

test "zix test: Http2ServerConfig logger defaults to null" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = Http2ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082 };
    try std.testing.expect(cfg.logger == null);
}
