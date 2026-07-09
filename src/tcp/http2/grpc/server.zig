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
const tls_serve = @import("tls_serve.zig");
const tls_mux = @import("tls_mux.zig");

pub const Route = core.Route;

// --------------------------------------------------------- //

fn GrpcServerImpl(comptime routes: []const Route) type {
    return struct {
        const Self = @This();

        config: GrpcServerConfig,

        /// Initialize the gRPC server with the given config. Validation happens in run.
        ///
        /// Return:
        /// - Self
        pub fn init(config: GrpcServerConfig) Self {
            return .{ .config = config };
        }

        /// No-op: resources are released inside run via defer.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Dual-listener TLS accept thread for the thread models: serves gRPC-over-TLS on
        /// config.port (already overridden to tls_port by the caller) while the cleartext model
        /// runs on the original port.
        fn serveTlsThread(config: GrpcServerConfig) void {
            tls_serve.runTls(routes, config) catch {};
        }

        /// Listen and serve. Routes are baked in at compile time via Server.init.
        ///
        /// Return:
        /// - !void
        /// - error.PortNotConfigured if config.port is 0
        pub fn run(self: *Self) !void {
            if (self.config.port == 0) return error.PortNotConfigured;

            const cfg = self.config;

            if (cfg.tls != null) {
                const is_linux = @import("builtin").target.os.tag == .linux;

                // Dual listener (tls_port): cleartext on port + TLS on tls_port from ONE worker
                // fleet, instead of a second server launch.
                if (cfg.tls_port != 0) {
                    if (cfg.tls_port == cfg.port) return error.TlsPortConflict;

                    if (is_linux and cfg.dispatch_model == .EPOLL)
                        return epoll_model.runEpoll(routes, cfg);
                    if (is_linux and cfg.dispatch_model == .URING)
                        return uring_model.runUring(routes, cfg);

                    // Thread models (.ASYNC / .POOL / .MIXED): one extra accept thread terminates
                    // TLS on tls_port (thread-per-connection), the cleartext model runs below
                    // unchanged.
                    var tls_cfg = cfg;
                    tls_cfg.port = cfg.tls_port;
                    tls_cfg.tls_port = 0;

                    const tls_thread = try std.Thread.spawn(.{}, serveTlsThread, .{tls_cfg});
                    tls_thread.detach();
                } else {
                    // Multiplexed TLS for the event-loop models (no thread-per-conn): one epoll worker per
                    // core terminates TLS in place and serves the resumable grpc mux. ASYNC / POOL / MIXED
                    // keep the thread-per-conn terminator (which also serves TLS 1.2).
                    if (is_linux and (cfg.dispatch_model == .EPOLL or cfg.dispatch_model == .URING))
                        return tls_mux.runTlsMux(routes, cfg);

                    return tls_serve.runTls(routes, cfg);
                }
            }

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
/// var server = zix.Grpc.Server.init(
///     &[_]zix.Grpc.Route{
///         .{ .path = "/pkg.Svc/Method", .handler = myHandler },
///     },
///     .{ .io = io, .ip = "127.0.0.1", .port = 8083, .dispatch_model = .ASYNC },
/// );
/// defer server.deinit();
/// try server.run();
/// ```
pub const GrpcServer = struct {
    pub fn init(
        comptime routes: []const Route,
        config: GrpcServerConfig,
    ) GrpcServerImpl(routes) {
        return GrpcServerImpl(routes).init(config);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix grpc: GrpcServer.run port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = GrpcServer.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 0, .dispatch_model = .ASYNC });
    defer server.deinit();

    try std.testing.expectError(error.PortNotConfigured, server.run());
}

test "zix grpc: GrpcServer.init valid config succeeds and deinit is safe" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = GrpcServer.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 8083, .dispatch_model = .ASYNC });
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
