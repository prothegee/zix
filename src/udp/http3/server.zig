//! zix HTTP/3 server facade (the `Http3(handler)` type + `run()` dispatch switch).
//!
//! What:
//! - `Http3(handler)` binds a UDP socket and serves QUIC / HTTP-3 on the zix.Udp datagram substrate.
//!   The dispatch model selects the worker shape per the ADR-050 contract: `.ASYNC` / `.POOL` /
//!   `.MIXED` run a single-worker recv with internal CID demux, and `.EPOLL` / `.URING` run one
//!   SO_REUSEPORT worker per core, the kernel load-balancing connections by 4-tuple.
//!
//! Usage:
//! ```zig
//! fn handler(req: *const zix.Http3.Request, res: *zix.Http3.Response) void {
//!     res.send("hello over h3");
//! }
//! const Server = zix.Http3.Http3(handler);
//! var server = try Server.init(config); // config.tls must be a TLS 1.3 context
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

/// An HTTP/3 server bound to `handler`.
pub fn Http3(comptime handler: HandlerFn) type {
    return struct {
        const Self = @This();

        config: Http3ServerConfig,

        /// Initialize. The port must be non-zero and a TLS 1.3 context must be present (QUIC has no
        /// cleartext mode).
        pub fn init(config: Http3ServerConfig) !Self {
            if (config.port == 0) return error.PortNotConfigured;
            if (config.tls == null) return error.TlsRequired;

            return .{ .config = config };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Bind and serve. Blocks until an error occurs. The dispatch model selects the worker shape.
        pub fn run(self: *const Self) !void {
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
// --------------------------------------------------------------- //

fn noopHandler(_: *const Request, _: *Response) void {}

test "zix test: Http3 init rejects port zero and missing TLS" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const Server = Http3(noopHandler);

    try std.testing.expectError(error.PortNotConfigured, Server.init(.{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 0,
    }));

    try std.testing.expectError(error.TlsRequired, Server.init(.{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9063,
    }));
}

comptime {
    _ = common;
}
