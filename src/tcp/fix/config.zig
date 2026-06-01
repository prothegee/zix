//! zix fix config

const std = @import("std");
const DispatchModel = @import("../config.zig").DispatchModel;
const Logger = @import("../../logger/logger.zig").Logger;

// --------------------------------------------------------- //

/// Configuration for a FIX 4.x session server instance.
/// Pass to Fix.Server.init(). Fields without defaults (io, ip, port, comp_id) are required.
/// No allocator field — the server uses stack allocation and smp_allocator internally.
pub const FixServerConfig = struct {
    /// Io backend for the server. Caller-provided. Must outlive the server.
    io: std.Io,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// Server SenderCompID (tag 49). Caller-provided. Must outlive the server.
    comp_id: []const u8,
    /// Connection dispatch model. Selects between POOL, ASYNC, and MIXED.
    /// Default: .ASYNC (single accept thread, io.async() per connection).
    dispatch_model: DispatchModel = .ASYNC,
    /// TCP listen backlog — maximum pending connections queued by the kernel before accept().
    kernel_backlog: u31 = 1024,
    /// Number of accept threads.
    /// 0 (default) = cpu_count accept threads.
    /// Ignored by .ASYNC (always 1 accept thread).
    workers: usize = 0,
    /// Number of pool threads. Only used by .POOL dispatch model.
    /// 0 (default) = max(10, cpu_count * 2).
    /// Ignored by .ASYNC and .MIXED.
    pool_size: usize = 0,
    /// Optional logger. When non-null, the server calls logger.system() for lifecycle events
    /// and logger.session() for each FIX message processed. Caller owns. Must outlive the server.
    logger: ?*Logger = null,
    /// Heartbeat timeout in milliseconds. 0 = disabled.
    /// When non-zero: after this interval with no incoming message, the server sends TestRequest (35=1).
    /// If no response arrives within another interval, the server sends Logout (35=5) and closes.
    /// Only takes effect after Logon completes. Before Logon, timeout closes silently.
    heartbeat_timeout_ms: u32 = 0,
    /// Idle connection timeout in milliseconds. 0 = disabled.
    /// When non-zero and heartbeat_timeout_ms is 0: the connection is closed if no message arrives
    /// within this interval (no TestRequest is sent before closing).
    connection_timeout_ms: u32 = 0,
    /// Server-wide default handler processing timeout in milliseconds. 0 = disabled.
    /// Applied to each routed message dispatch. Per-route Route.timeout_ms overrides this.
    handler_timeout_ms: u32 = 0,
};

/// Configuration for a FIX 4.x session client instance.
/// Pass to Fix.Client.connect(). All fields are required.
pub const FixClientConfig = struct {
    /// Server address.
    ip: []const u8,
    /// Server port. Must be non-zero.
    port: u16,
    /// This client's SenderCompID (tag 49).
    comp_id: []const u8,
    /// Server TargetCompID (tag 56).
    target_comp_id: []const u8,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix fix: FixServerConfig required fields" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = FixServerConfig{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9500), cfg.port);
    try std.testing.expectEqualStrings("SERVER", cfg.comp_id);
}

test "zix fix: FixServerConfig dispatch_model defaults to ASYNC" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = FixServerConfig{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" };
    try std.testing.expectEqual(DispatchModel.ASYNC, cfg.dispatch_model);
}

test "zix fix: FixServerConfig worker pool defaults to auto-size (zero)" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = FixServerConfig{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" };
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expectEqual(@as(usize, 0), cfg.pool_size);
}

test "zix fix: FixServerConfig kernel_backlog default" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = FixServerConfig{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" };
    try std.testing.expectEqual(@as(u31, 1024), cfg.kernel_backlog);
}

test "zix fix: FixServerConfig heartbeat_timeout_ms defaults to zero" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = FixServerConfig{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" };
    try std.testing.expectEqual(@as(u32, 0), cfg.heartbeat_timeout_ms);
}

test "zix fix: FixServerConfig connection_timeout_ms defaults to zero" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = FixServerConfig{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" };
    try std.testing.expectEqual(@as(u32, 0), cfg.connection_timeout_ms);
}

test "zix fix: FixServerConfig handler_timeout_ms defaults to zero" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = FixServerConfig{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" };
    try std.testing.expectEqual(@as(u32, 0), cfg.handler_timeout_ms);
}

test "zix fix: FixClientConfig fields" {
    const cfg = FixClientConfig{
        .ip = "127.0.0.1",
        .port = 9500,
        .comp_id = "CLIENT",
        .target_comp_id = "SERVER",
    };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9500), cfg.port);
    try std.testing.expectEqualStrings("CLIENT", cfg.comp_id);
    try std.testing.expectEqualStrings("SERVER", cfg.target_comp_id);
}
