//! zix http1 server: the public Server type and the dispatch_model switch. Each
//! dispatch model lives in its own file under dispatch/ (ADR-043).

const std = @import("std");
const Config = @import("config.zig").Http1ServerConfig;
const core = @import("core.zig");
const HandlerFn = core.HandlerFn;
const common = @import("dispatch/common.zig");
const async_model = @import("dispatch/async.zig");
const pool_model = @import("dispatch/pool.zig");
const mixed_model = @import("dispatch/mixed.zig");
const epoll_model = @import("dispatch/epoll.zig");
const uring_model = @import("dispatch/uring.zig");
const tls_serve = @import("tls_serve.zig");
const tls_mux = @import("tls_mux.zig");

// --------------------------------------------------------- //

/// Server type specialized over a comptime handler and optional raw interceptor.
///
/// Note:
/// - handler and raw_fn are baked into the type, so run() takes no argument.
/// - raw_fn is null in the normal path: the if(comptime raw_fn != null) block
///   compiles away entirely, adding zero overhead to servers that don't use it.
fn Http1ServerImpl(comptime handler: HandlerFn, comptime raw_fn: ?core.RawFn) type {
    return struct {
        config: Config,

        const Self = @This();

        pub fn init(config: Config) Self {
            return .{ .config = config };
        }

        pub fn deinit(_: *Self) void {}

        /// Dual-listener TLS accept thread for the thread models: serves https on config.port
        /// (already overridden to tls_port by the caller) while the cleartext model runs on the
        /// original port.
        fn serveTlsThread(config: Config) void {
            tls_serve.runTls(handler, config) catch {};
        }

        pub fn run(self: *const Self) !void {
            // Static serving is opt-in: when public_dir is set, fail fast if the directory is absent
            // rather than 404-ing every file request at runtime. Mirrors zix.Http.Server.run.
            if (self.config.public_dir.len > 0) {
                const dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), self.config.io, self.config.public_dir, .{}) catch return error.PublicDirNotFound;
                dir.close(self.config.io);
            }

            if (self.config.tls != null) {
                const is_linux = comptime @import("builtin").target.os.tag == .linux;

                // Dual listener (tls_port): cleartext on port + TLS on tls_port from ONE worker
                // fleet, instead of a second server launch.
                if (self.config.tls_port != 0) {
                    if (self.config.tls_port == self.config.port) return error.TlsPortConflict;

                    if (is_linux and self.config.dispatch_model == .EPOLL)
                        return epoll_model.runEpoll(self.config, handler, raw_fn);
                    if (is_linux and self.config.dispatch_model == .URING)
                        return uring_model.runUring(self.config, handler, raw_fn);

                    // Thread models (.ASYNC / .POOL / .MIXED): one extra accept thread terminates
                    // TLS on tls_port (thread-per-connection, WebSocket + SSE included), the
                    // cleartext model runs below unchanged.
                    var tls_cfg = self.config;
                    tls_cfg.port = self.config.tls_port;
                    tls_cfg.tls_port = 0;

                    const tls_thread = try std.Thread.spawn(.{}, serveTlsThread, .{tls_cfg});
                    tls_thread.detach();
                } else {
                    // .EPOLL / .URING terminate TLS in an event-driven epoll-mux worker (keep-alive,
                    // thousands of connections per worker). The thread-per-connection blocking path
                    // (tls_serve) serves the remaining models.
                    if (is_linux and (self.config.dispatch_model == .EPOLL or self.config.dispatch_model == .URING))
                        return tls_mux.runTlsMux(handler, self.config);

                    return tls_serve.runTls(handler, self.config);
                }
            }

            return switch (self.config.dispatch_model) {
                .ASYNC => async_model.runAsync(self.config, handler),
                .POOL => pool_model.runPool(self.config, handler),
                .MIXED => mixed_model.runMixed(self.config, handler),
                .EPOLL => if (comptime @import("builtin").target.os.tag == .linux)
                    epoll_model.runEpoll(self.config, handler, raw_fn)
                else blk: {
                    common.logSystem(self.config, "EPOLL is Linux-only. Falling back to POOL.", .{});
                    break :blk pool_model.runPool(self.config, handler);
                },
                .URING => if (comptime @import("builtin").target.os.tag == .linux)
                    uring_model.runUring(self.config, handler, raw_fn)
                else blk: {
                    common.logSystem(self.config, "URING is Linux-only. Falling back to POOL.", .{});
                    break :blk pool_model.runPool(self.config, handler);
                },
            };
        }
    };
}

/// http1 server - initialize with a comptime handler and a runtime config.
///
/// Note:
/// - handler must be comptime: it is baked into the server type, so there is no
///   dynamic registration after init. Pass a Router(routes).dispatch, a bare
///   handler, or a middleware chain.
/// - For raw-bytes interception before parsing, use initRaw.
///
/// Usage:
/// ```zig
/// const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
///     .{ .path = "/", .handler = home },
/// });
///
/// var server = zix.Http1.Server.init(Routes.dispatch, .{
///     .ip = "0.0.0.0",
///     .port = 8080,
/// });
/// try server.run();
/// ```
pub const Server = struct {
    /// Param:
    /// handler - comptime HandlerFn (baked into the server type)
    /// config - Http1ServerConfig
    ///
    /// Return:
    /// - Http1ServerImpl(handler, null)
    pub fn init(comptime handler: HandlerFn, config: Config) Http1ServerImpl(handler, null) {
        return Http1ServerImpl(handler, null).init(config);
    }

    /// Like init, but also installs a raw-request interceptor for the EPOLL
    /// dispatch model. raw_fn is called before any header parsing on each
    /// request. Returning a non-null offset skips the full parse-and-dispatch
    /// path for that request. Only effective under EPOLL, other models ignore it.
    ///
    /// Param:
    /// handler - comptime HandlerFn
    /// raw_fn - comptime RawFn (called before parsing on every EPOLL request)
    /// config - Http1ServerConfig
    ///
    /// Return:
    /// - Http1ServerImpl(handler, raw_fn)
    pub fn initRaw(comptime handler: HandlerFn, comptime raw_fn: core.RawFn, config: Config) Http1ServerImpl(handler, raw_fn) {
        return Http1ServerImpl(handler, raw_fn).init(config);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

fn testNoopHandler(_: *const core.ParsedHead, _: []const u8, _: std.posix.fd_t) void {}

test "zix http1: Server.init valid config, deinit is safe" {
    var server = Server.init(testNoopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .ASYNC,
    });
    server.deinit();
}

test "zix http1: Server.init with POOL dispatch model" {
    var server = Server.init(testNoopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .POOL,
    });
    server.deinit();
}

test "zix http1: Server.init with EPOLL dispatch model" {
    var server = Server.init(testNoopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .EPOLL,
    });
    server.deinit();
}

test "zix http1: Server.init with URING dispatch model" {
    var server = Server.init(testNoopHandler, .{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9200,
        .dispatch_model = .URING,
    });
    server.deinit();
}
