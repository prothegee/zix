//! zix http2 server: the public Server type and the dispatch_model switch. Each
//! dispatch model lives in its own file under dispatch/ (ADR-043).

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const Http2ServerConfig = @import("config.zig").Http2ServerConfig;
const common = @import("dispatch/common.zig");
const async_model = @import("dispatch/async.zig");
const pool_model = @import("dispatch/pool.zig");
const mixed_model = @import("dispatch/mixed.zig");
const epoll_model = @import("dispatch/epoll.zig");
const uring_model = @import("dispatch/uring.zig");
const tls_serve = @import("tls_serve.zig");
const tls_mux = @import("tls_mux.zig");

const is_linux = builtin.target.os.tag == .linux;

pub const Route = core.Route;

// --------------------------------------------------------- //

/// HTTP/2 h2c server: initialize with a handler built via Router(routes).dispatch.
///
/// Usage:
/// ```zig
/// const router = zix.Http2.Router(&[_]zix.Http2.Route{
///     .{ .path = "/",     .handler = homeHandler },
///     .{ .path = "/echo", .handler = echoHandler },
/// });
/// var server = zix.Http2.Server.init(router.dispatch, .{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC });
/// defer server.deinit();
/// try server.run();
/// ```
pub const Http2Server = struct {
    const Self = @This();

    handler: core.HandlerFn,
    config: Http2ServerConfig,

    /// Initialize the HTTP/2 server with a handler and config. Validation happens in run.
    ///
    /// Return:
    /// - Self
    pub fn init(handler: core.HandlerFn, config: Http2ServerConfig) Self {
        return .{ .handler = handler, .config = config };
    }

    /// No-op: resources released inside run via defer.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Dual-listener TLS accept thread for the thread models: serves h2-over-TLS on
    /// config.port (already overridden to tls_port by the caller) while the cleartext model
    /// runs on the original port.
    fn serveTlsThread(handler: core.HandlerFn, config: Http2ServerConfig) void {
        tls_serve.runTls(handler, config) catch {};
    }

    /// Listen and serve.
    ///
    /// Return:
    /// - !void
    /// - error.PortNotConfigured if config.port is 0
    pub fn run(self: *Self) !void {
        if (self.config.port == 0) return error.PortNotConfigured;

        const cfg = self.config;
        const handler = self.handler;

        if (cfg.tls != null) {
            // Dual listener (tls_port): cleartext on port + TLS on tls_port from ONE worker
            // fleet, instead of a second server launch.
            if (cfg.tls_port != 0) {
                if (cfg.tls_port == cfg.port) return error.TlsPortConflict;

                if (is_linux and cfg.dispatch_model == .EPOLL)
                    return epoll_model.runEpoll(handler, cfg);
                if (is_linux and cfg.dispatch_model == .URING)
                    return uring_model.runUring(handler, cfg);

                // Thread models (.ASYNC / .POOL / .MIXED): one extra accept thread terminates
                // TLS on tls_port (thread-per-connection), the cleartext model runs below
                // unchanged.
                var tls_cfg = cfg;
                tls_cfg.port = cfg.tls_port;
                tls_cfg.tls_port = 0;

                const tls_thread = try std.Thread.spawn(.{}, serveTlsThread, .{ handler, tls_cfg });
                tls_thread.detach();
            } else {
                // Multiplexed TLS for the event-loop models (no thread-per-conn): one epoll worker per
                // core terminates TLS in place and serves the resumable mux, so high concurrency does
                // not spawn a thread per connection. ASYNC / POOL / MIXED keep the thread-per-conn
                // terminator, which also serves TLS 1.2.
                if (is_linux and (cfg.dispatch_model == .EPOLL or cfg.dispatch_model == .URING))
                    return tls_mux.runTlsMux(handler, cfg);

                return tls_serve.runTls(handler, cfg);
            }
        }

        return switch (cfg.dispatch_model) {
            .ASYNC => async_model.runAsync(handler, cfg),
            .POOL => pool_model.runPool(handler, cfg),
            .MIXED => mixed_model.runMixed(handler, cfg),
            // .EPOLL is the shared-nothing multiplexed h2 event loop (Linux-only).
            .EPOLL => if (is_linux) epoll_model.runEpoll(handler, cfg) else blk: {
                common.logSystem(cfg, "EPOLL is Linux-only. Falling back to POOL.", .{});

                break :blk pool_model.runPool(handler, cfg);
            },
            // .URING is the native io_uring shared-nothing loop (Linux-only). It probes the ring
            // at startup and falls back to .EPOLL when io_uring is unavailable.
            .URING => if (is_linux) uring_model.runUring(handler, cfg) else blk: {
                common.logSystem(cfg, "URING is Linux-only. Falling back to POOL.", .{});

                break :blk pool_model.runPool(handler, cfg);
            },
        };
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const empty_router = core.Router(&[_]Route{});

test "zix http2: Http2Server.run, port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = Http2Server.init(empty_router.dispatch, .{ .io = io, .ip = "127.0.0.1", .port = 0, .dispatch_model = .ASYNC });
    defer server.deinit();

    try std.testing.expectError(error.PortNotConfigured, server.run());
}

test "zix http2: Http2Server.init, valid config succeeds and deinit is safe" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = Http2Server.init(empty_router.dispatch, .{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC });
    server.deinit();
}
