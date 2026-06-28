//! zix udp raw-bytes datagram server (ADR-049).
//!
//! What:
//! - `Raw(handler)` serves variable-length datagrams up to `max_recv_buf`. The handler receives the
//!   datagram bytes, the peer address, and a `Sink` to reply through. Replies are coalesced and
//!   leave as one sendmmsg per received batch. This file is the thin server facade: init plus a
//!   `run()` switch over `dispatch_model`, mirroring `src/tcp/http1/server.zig`. The worker loops
//!   live in `dispatch/` and the handler / sink types in `core.zig`.
//!
//! Usage:
//! ```zig
//! fn handler(dg: []const u8, peer: *const std.Io.net.IpAddress, sink: *zix.Udp.Sink) void {
//!     sink.reply(dg); // echo back to the sender
//! }
//! const EchoServer = zix.Udp.Raw(handler);
//! var server = try EchoServer.init(config);
//! try server.run();
//! ```

const std = @import("std");

const Config = @import("config.zig");
const UdpServerConfig = Config.UdpServerConfig;
const core = @import("core.zig");

const async_model = @import("dispatch/async.zig");
const pool_model = @import("dispatch/pool.zig");
const mixed_model = @import("dispatch/mixed.zig");
const epoll_model = @import("dispatch/epoll.zig");
const uring_model = @import("dispatch/uring.zig");

// --------------------------------------------------------- //

/// The reply queue handed to a raw handler (re-exported from core).
pub const Sink = core.Sink;
/// A raw datagram handler (re-exported from core).
pub const HandlerFn = core.HandlerFn;

/// A raw-bytes UDP server bound to `handler`.
pub fn Raw(comptime handler: HandlerFn) type {
    return struct {
        const Self = @This();

        config: UdpServerConfig,

        /// Initialize in REQUIRED mode: port must be non-zero.
        pub fn init(config: UdpServerConfig) !Self {
            if (config.port == 0) return error.PortNotConfigured;

            return .{ .config = config };
        }

        /// Initialize in CONFIGURABLE mode: reads --port from CLI args, falls back to config.port.
        pub fn initArgs(config: UdpServerConfig, args: anytype) !Self {
            var cfg = config;
            var it = std.process.Args.Iterator.init(args);
            _ = it.skip();
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--port")) {
                    if (it.next()) |val| cfg.port = std.fmt.parseInt(u16, val, 10) catch cfg.port;
                }
            }

            if (cfg.port == 0) return error.PortNotConfigured;

            return .{ .config = cfg };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Bind and serve. Blocks until an error occurs. The dispatch model selects the worker
        /// shape: `.EPOLL` / `.URING` run per-core SO_REUSEPORT workers, the rest run a single worker.
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //

fn noopHandler(_: []const u8, _: *const std.Io.net.IpAddress, _: *Sink) void {}

test "zix test: Raw init, port zero returns PortNotConfigured" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const S = Raw(noopHandler);
    try std.testing.expectError(error.PortNotConfigured, S.init(.{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
    }));
}

test "zix test: Raw init, config preserved" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const S = Raw(noopHandler);
    var server = try S.init(.{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9070,
        .dispatch_model = .EPOLL,
        .reuse_address = true,
        .recv_batch = 16,
    });
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 9070), server.config.port);
    try std.testing.expectEqual(Config.DispatchModel.EPOLL, server.config.dispatch_model);
    try std.testing.expect(server.config.reuse_address);
    try std.testing.expectEqual(@as(usize, 16), server.config.recv_batch);
}
