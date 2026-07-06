//! zix HTTP/3 server: the public Server type and the dispatch_model switch. Each
//! dispatch model lives in its own file under dispatch/ (ADR-043).
//!
//! What:
//! - Server.init(handler, config) binds a UDP socket and serves QUIC / HTTP-3 on the zix.Udp
//!   datagram substrate. The dispatch model selects the worker shape per the ADR-050 contract:
//!   `.ASYNC` runs a single-worker recv with internal CID demux. `.POOL` / `.MIXED` / `.EPOLL` /
//!   `.URING` run one SO_REUSEPORT worker per core, the kernel load-balancing connections by 4-tuple.
//!
//! Usage:
//! ```zig
//! fn handler(req: *const zix.Http3.Request, res: *zix.Http3.Response) void {
//!     res.send("hello over h3");
//! }
//! var server = zix.Http3.Server.init(handler, config); // config.tls must be a TLS 1.3 context
//! try server.run();
//! ```

const std = @import("std");

const Config = @import("config.zig");
const Http3ServerConfig = Config.Http3ServerConfig;
const core = @import("core.zig");

const common = @import("dispatch/common.zig");
const async_model = @import("dispatch/async.zig");
const pool_model = @import("dispatch/pool.zig");
const mixed_model = @import("dispatch/mixed.zig");
const epoll_model = @import("dispatch/epoll.zig");
const uring_model = @import("dispatch/uring.zig");

/// The application request handler (re-exported from core).
pub const HandlerFn = core.HandlerFn;
/// A decoded HTTP/3 request (re-exported from core).
pub const Request = core.Request;
/// The response the handler fills (re-exported from core).
pub const Response = core.Response;
/// The content coding a handler sets on its response body (re-exported from core).
pub const ContentEncoding = core.ContentEncoding;

// Internal generic implementation: use `Server.init(handler, config)` publicly.
fn Http3ServerImpl(comptime handler: HandlerFn) type {
    return struct {
        const Self = @This();

        config: Http3ServerConfig,

        /// Initialize the HTTP/3 server with the given config. Validation happens in run.
        ///
        /// Return:
        /// - Self
        pub fn init(config: Http3ServerConfig) Self {
            return .{ .config = config };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Bind and serve. Blocks until an error occurs. The dispatch model selects the worker shape.
        ///
        /// Return:
        /// - !void
        /// - error.PortNotConfigured if config.port is 0
        /// - error.TlsRequired if config.tls is null (QUIC has no cleartext mode)
        pub fn run(self: *const Self) !void {
            if (self.config.port == 0) return error.PortNotConfigured;
            if (self.config.tls == null) return error.TlsRequired;

            return switch (self.config.dispatch_model) {
                .ASYNC => async_model.runAsync(handler, self.config),
                .POOL => pool_model.runPool(handler, self.config),
                .MIXED => mixed_model.runMixed(handler, self.config),
                .EPOLL => epoll_model.runEpoll(handler, self.config),
                .URING => uring_model.runUring(handler, self.config),
            };
        }
    };
}

// --------------------------------------------------------------- //

/// http3 server - initialize with a comptime handler and a runtime config.
///
/// Note:
/// - handler must be comptime: it is baked into the server type, so there is no
///   dynamic registration after init. Pass a Router(routes).dispatch or a bare handler.
/// - QUIC has no cleartext mode: run() requires config.tls (a TLS 1.3 context).
///
/// Usage:
/// ```zig
/// const Routes = zix.Http3.Router(&[_]zix.Http3.Route{
///     .{ .path = "/", .handler = home },
/// });
///
/// var server = zix.Http3.Server.init(Routes.dispatch, .{
///     .io = io,
///     .allocator = allocator,
///     .ip = "0.0.0.0",
///     .port = 8443,
///     .tls = &tls,
///     .dispatch_model = .EPOLL,
/// });
/// defer server.deinit();
///
/// try server.run();
/// ```
pub const Server = struct {
    /// Param:
    /// handler - comptime HandlerFn (baked into the server type)
    /// config - Http3ServerConfig
    ///
    /// Return:
    /// - Http3ServerImpl(handler)
    pub fn init(comptime handler: HandlerFn, config: Http3ServerConfig) Http3ServerImpl(handler) {
        return Http3ServerImpl(handler).init(config);
    }
};

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn noopHandler(_: *const Request, _: *Response) void {}

test "zix test: Http3 run rejects port zero and missing TLS" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var no_port = Server.init(noopHandler, .{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
    });
    defer no_port.deinit();

    try std.testing.expectError(error.PortNotConfigured, no_port.run());

    var no_tls = Server.init(noopHandler, .{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9063,
        .dispatch_model = .ASYNC,
    });
    defer no_tls.deinit();

    try std.testing.expectError(error.TlsRequired, no_tls.run());
}

comptime {
    _ = common;
}
