//! zix http2 server: the public Server type and the dispatch_model switch. Each
//! dispatch model lives in its own file under dispatch/ (ADR-043).

const std = @import("std");
const core = @import("core.zig");
const Http2ServerConfig = @import("config.zig").Http2ServerConfig;
const common = @import("dispatch/common.zig");
const async_model = @import("dispatch/async.zig");
const pool_model = @import("dispatch/pool.zig");
const mixed_model = @import("dispatch/mixed.zig");
const tls_serve = @import("tls_serve.zig");

pub const Route = core.Route;

// --------------------------------------------------------- //

fn Http2ServerImpl(comptime routes: []const Route) type {
    return struct {
        const Self = @This();

        config: Http2ServerConfig,

        /// Initialize the HTTP/2 server with the given config.
        ///
        /// Return:
        /// - !Self (error.PortNotConfigured if config.port is 0)
        pub fn init(config: Http2ServerConfig) !Self {
            if (config.port == 0) return error.PortNotConfigured;

            return .{ .config = config };
        }

        /// No-op: resources released inside run via defer.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Listen and serve. Routes are baked in at compile time via Server.init.
        ///
        /// Return:
        /// - !void
        pub fn run(self: *Self) !void {
            const cfg = self.config;

            if (cfg.tls != null) return tls_serve.runTls(routes, cfg);

            return switch (cfg.dispatch_model) {
                .ASYNC => async_model.runAsync(routes, cfg),
                .POOL => pool_model.runPool(routes, cfg),
                .MIXED => mixed_model.runMixed(routes, cfg),
                // .URING has no native ring path in zix.Http2, so it follows .EPOLL
                // and falls back to POOL (ADR-037 implements .URING in zix.Http1 first).
                .EPOLL, .URING => blk: {
                    common.logSystem(cfg, "EPOLL is HTTP-only. Falling back to POOL.", .{});

                    break :blk pool_model.runPool(routes, cfg);
                },
            };
        }
    };
}

// --------------------------------------------------------- //

/// HTTP/2 h2c server. Routes are baked in at compile time.
///
/// Usage:
/// ```zig
/// var server = try zix.Http2.Server.init(
///     &[_]zix.Http2.Route{
///         .{ .path = "/",     .handler = homeHandler },
///         .{ .path = "/echo", .handler = echoHandler },
///     },
///     .{ .io = io, .ip = "127.0.0.1", .port = 8082 },
/// );
/// defer server.deinit();
/// try server.run();
/// ```
pub const Http2Server = struct {
    pub fn init(
        comptime routes: []const Route,
        config: Http2ServerConfig,
    ) !Http2ServerImpl(routes) {
        return Http2ServerImpl(routes).init(config);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: Http2Server.init, port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        Http2Server.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix test: Http2Server.init, valid config succeeds and deinit is safe" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try Http2Server.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 8082 });
    server.deinit();
}
