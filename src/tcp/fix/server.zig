//! zix fix server: the public FixServer type and the dispatch_model switch. Each
//! dispatch model lives in its own file under dispatch/ (ADR-043).

const std = @import("std");
const core = @import("core.zig");
const FixServerConfig = @import("config.zig").FixServerConfig;
const FixServeOpts = core.FixServeOpts;
const common = @import("dispatch/common.zig");
const async_model = @import("dispatch/async.zig");
const pool_model = @import("dispatch/pool.zig");
const mixed_model = @import("dispatch/mixed.zig");
const epoll_model = @import("dispatch/epoll.zig");
const uring_model = @import("dispatch/uring.zig");

// --------------------------------------------------------- //

/// FIX 4.x session server. Dispatches connections via POOL, ASYNC, MIXED,
/// or EPOLL / URING (Linux-only: non-Linux falls back to POOL).
/// Session messages (Logon, Logout, Heartbeat, TestRequest) are handled internally.
/// Application messages are dispatched to registered routes.
///
/// Usage:
/// ```zig
/// var server = try FixServer.init(
///     &[_]FixRoute{
///         .{ .msg_type = "D", .handler = handleOrder },
///         .{ .msg_type = "F", .handler = handleCancel },
///     },
///     .{ .io = io, .ip = "0.0.0.0", .port = 9500, .comp_id = "SRV" },
/// );
/// defer server.deinit();
/// try server.run();
/// ```
pub const FixServer = struct {
    const Self = @This();

    routes: []const core.FixRoute,
    config: FixServerConfig,

    // --------------------------------------------------------- //

    /// Initialize.
    ///
    /// Param:
    /// routes - []const FixRoute (application message route table. pass &.{} for echo-only mode)
    /// config - FixServerConfig
    ///
    /// Return:
    /// - !Self
    /// - error.PortNotConfigured if config.port is 0
    pub fn init(routes: []const core.FixRoute, config: FixServerConfig) !Self {
        if (config.port == 0) return error.PortNotConfigured;

        return .{ .routes = routes, .config = config };
    }

    /// No-op, resources released inside run via defer.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Listen and serve FIX sessions using the server's comp_id.
    pub fn run(self: *Self) !void {
        const cfg = self.config;
        const conn_opts = FixServeOpts{
            .logger = cfg.logger,
            .default_heartbeat_secs = cfg.default_heartbeat_secs,
            .heartbeat_timeout_ms = cfg.heartbeat_timeout_ms,
            .conn_timeout_ms = cfg.conn_timeout_ms,
            .handler_timeout_ms = cfg.handler_timeout_ms,
            .routes = self.routes,
        };

        return switch (cfg.dispatch_model) {
            .ASYNC => async_model.runAsync(cfg, conn_opts),
            .POOL => pool_model.runPool(cfg, conn_opts),
            .MIXED => mixed_model.runMixed(cfg, conn_opts),
            .EPOLL => if (comptime @import("builtin").target.os.tag == .linux)
                epoll_model.runEpoll(cfg, conn_opts)
            else blk: {
                common.logSystem(cfg, "EPOLL is Linux-only. Falling back to POOL.", .{});

                break :blk pool_model.runPool(cfg, conn_opts);
            },
            // Native io_uring ring path (ADR-037 Phase 4 extension).
            .URING => if (comptime @import("builtin").target.os.tag == .linux)
                uring_model.runUring(cfg, conn_opts)
            else blk: {
                common.logSystem(cfg, "URING is Linux-only. Falling back to POOL.", .{});

                break :blk pool_model.runPool(cfg, conn_opts);
            },
        };
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix fix: FixServer.init, port zero returns PortNotConfigured" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        FixServer.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 0, .comp_id = "SERVER" }),
    );
}

test "zix fix: FixServer.init, valid config succeeds and deinit is safe" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try FixServer.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" });
    server.deinit();
}

test "zix fix: FixServer.init with EPOLL dispatch model succeeds" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try FixServer.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER", .dispatch_model = .EPOLL });
    server.deinit();
}

test "zix fix: FixServer EPOLL uses workers field for worker count, pool_size is ignored" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const server = try FixServer.init(&.{}, .{
        .io = io,
        .ip = "127.0.0.1",
        .port = 9500,
        .comp_id = "SERVER",
        .dispatch_model = .EPOLL,
        .workers = 4,
        .pool_size = 99,
    });
    try std.testing.expectEqual(@as(usize, 4), server.config.workers);
    try std.testing.expectEqual(@as(usize, 99), server.config.pool_size);
}
