//! zix grpc server: the public Server type and the dispatch_model switch. Each
//! dispatch model lives in its own file under dispatch/ (ADR-043).

const std = @import("std");
const core = @import("core.zig");
const GrpcServerConfig = @import("config.zig").GrpcServerConfig;
const common = @import("dispatch/common.zig");
const async_model = @import("dispatch/async.zig");
const pool_model = @import("dispatch/pool.zig");
const mixed_model = @import("dispatch/mixed.zig");
const epoll_model = @import("dispatch/epoll.zig");
const uring_model = @import("dispatch/uring.zig");

pub const Route = core.Route;

// --------------------------------------------------------- //

fn GrpcServerImpl(comptime routes: []const Route) type {
    return struct {
        const Self = @This();

        config: GrpcServerConfig,

        /// Initialize the gRPC server with the given config.
        ///
        /// Return:
        /// - !Self (error.PortNotConfigured if config.port is 0)
        pub fn init(config: GrpcServerConfig) !Self {
            if (config.port == 0) return error.PortNotConfigured;

            return .{ .config = config };
        }

        /// No-op: resources are released inside run via defer.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Listen and serve. Routes are baked in at compile time via Server.init.
        ///
        /// Return:
        /// - !void
        pub fn run(self: *Self) !void {
            const cfg = self.config;

            return switch (cfg.dispatch_model) {
                .ASYNC => async_model.runAsync(routes, cfg),
                .POOL => pool_model.runPool(routes, cfg),
                .MIXED => mixed_model.runMixed(routes, cfg),
                .EPOLL => if (comptime @import("builtin").target.os.tag == .linux)
                    epoll_model.runEpoll(routes, cfg)
                else blk: {
                    common.logSystem(cfg, "EPOLL is Linux-only. Falling back to POOL.", .{});

                    break :blk pool_model.runPool(routes, cfg);
                },
                // Native io_uring ring path (ADR-037 Phase 4 step 3).
                .URING => if (comptime @import("builtin").target.os.tag == .linux)
                    uring_model.runUring(routes, cfg)
                else blk: {
                    common.logSystem(cfg, "URING is Linux-only. Falling back to POOL.", .{});

                    break :blk pool_model.runPool(routes, cfg);
                },
            };
        }
    };
}

// --------------------------------------------------------- //

/// gRPC h2c server. Routes are baked in at compile time.
///
/// Usage:
/// ```zig
/// var server = try zix.Grpc.Server.init(
///     &[_]zix.Grpc.Route{
///         .{ .path = "/pkg.Svc/Method", .handler = myHandler },
///     },
///     .{ .io = io, .ip = "127.0.0.1", .port = 8083 },
/// );
/// defer server.deinit();
/// try server.run();
/// ```
pub const GrpcServer = struct {
    pub fn init(
        comptime routes: []const Route,
        config: GrpcServerConfig,
    ) !GrpcServerImpl(routes) {
        return GrpcServerImpl(routes).init(config);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix grpc: GrpcServer.init port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        GrpcServer.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix grpc: GrpcServer.init valid config succeeds and deinit is safe" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try GrpcServer.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 8083 });
    server.deinit();
}

test "zix grpc: effectiveCacheEntries honors the memory ceiling" {
    const base = core.GrpcServeOpts{ .cache_max_entries = 1024, .cache_max_value_bytes = 16 * 1024 };

    // no ceiling: the configured entry count passes through unchanged
    try std.testing.expectEqual(@as(u32, 1024), common.effectiveCacheEntries(base));

    // ceiling caps the entry count so entries * value_bytes fits
    var capped = base;
    capped.cache_max_total_bytes = 256 * 1024;
    try std.testing.expectEqual(@as(u32, 16), common.effectiveCacheEntries(capped));

    // a tiny ceiling still yields at least one slot
    var tiny = base;
    tiny.cache_max_total_bytes = 1;
    try std.testing.expectEqual(@as(u32, 1), common.effectiveCacheEntries(tiny));
}
