//! ZIX Http2 Grpc server
//!
//! ### file: src/zix/tcp/http2/grpc/server.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC h2c server: init, run, deinit, and the dispatch model switch.
//!
//! ### note:
//!
//! init takes the comptime Router type, not a bare handler: the engine reads
//! Route.is_server_streaming off route_slice before dispatch (inline or on a
//! task), which a handler pointer cannot carry.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const tlz = @import("tlz");
const dispatch_async = @import("dispatch/async.zig");
const dispatch_epoll = @import("dispatch/epoll.zig");
const dispatch_uring = @import("dispatch/uring.zig");
const log = @import("log.zig");
const tls_mux = @import("tls_mux.zig");
const tls_serve = @import("tls_serve.zig");
const Config = @import("Config.zig");
const DispatchModel = @import("../../../shared/dispatch.zig").Model;
const ignoreSigpipe = @import("../../../utils/ignore_sigpipe.zig").ignoreSigpipe;
const OS = @import("builtin").target.os.tag;

// --------------------------------------------------------- //
// Private:

fn gatePort(config: Config) Error!void {
    if (config.port == 0) return Error.ZixHttp2_GrpcServer_PortNotConfigured;
}

/// Reject a model this platform cannot run, before any listener is set up,
/// so a rejected config leaves nothing behind.
fn gateDispatchModel(model: DispatchModel) Error!void {
    switch (model) {
        .ASYNC => {},
        .EPOLL,
        .URING,
        => if (comptime OS != .linux) {
            return Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported;
        },
        // Not implemented yet. Listed one by one, so a new model in the enum
        // fails to compile here until it is given its own arm.
        .IOCP,
        .KQUEUE,
        => return Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
    }
}

fn dispatchError(err: dispatch_async.Error) Error {
    return switch (err) {
        error.ZixHttp2_GrpcAsync_ResolveFailed
            => Error.ZixHttp2_GrpcServer_ResolveFailed,
        error.ZixHttp2_GrpcAsync_ListenFailed
            => Error.ZixHttp2_GrpcServer_ListenFailed,
        error.ZixHttp2_GrpcAsync_AcceptFailed
            => Error.ZixHttp2_GrpcServer_AcceptFailed,
    };
}

fn dispatchEpollError(err: dispatch_epoll.Error) Error {
    return switch (err) {
        error.ZixHttp2_GrpcEpoll_ResolveFailed
            => Error.ZixHttp2_GrpcServer_ResolveFailed,
        error.ZixHttp2_GrpcEpoll_ListenFailed
            => Error.ZixHttp2_GrpcServer_ListenFailed,
        error.ZixHttp2_GrpcEpoll_OutOfMemory,
        error.ZixHttp2_GrpcEpoll_SpawnFailed,
        error.ZixHttp2_GrpcEpoll_SetupFailed,
        error.ZixHttp2_GrpcEpoll_Unsupported,
            => Error.ZixHttp2_GrpcServer_EpollSetupFailed,
    };
}

fn dispatchUringError(err: dispatch_uring.Error) Error {
    return switch (err) {
        error.ZixHttp2_GrpcUring_ResolveFailed
            => Error.ZixHttp2_GrpcServer_ResolveFailed,
        error.ZixHttp2_GrpcUring_ListenFailed
            => Error.ZixHttp2_GrpcServer_ListenFailed,
        error.ZixHttp2_GrpcUring_OutOfMemory,
        error.ZixHttp2_GrpcUring_SpawnFailed,
        error.ZixHttp2_GrpcUring_SetupFailed,
        error.ZixHttp2_GrpcUring_WaitFailed,
        error.ZixHttp2_GrpcUring_Unsupported,
            => Error.ZixHttp2_GrpcServer_UringSetupFailed,
    };
}

fn dispatchTlsServeError(err: tls_serve.Error) Error {
    return switch (err) {
        error.ZixHttp2_GrpcTlsServe_ResolveFailed
            => Error.ZixHttp2_GrpcServer_ResolveFailed,
        error.ZixHttp2_GrpcTlsServe_ListenFailed
            => Error.ZixHttp2_GrpcServer_ListenFailed,
        error.ZixHttp2_GrpcTlsServe_AcceptFailed
            => Error.ZixHttp2_GrpcServer_AcceptFailed,
    };
}

fn dispatchTlsMuxError(err: tls_mux.Error) Error {
    return switch (err) {
        error.ZixHttp2_GrpcTlsMux_ResolveFailed
            => Error.ZixHttp2_GrpcServer_ResolveFailed,
        error.ZixHttp2_GrpcTlsMux_ListenFailed
            => Error.ZixHttp2_GrpcServer_ListenFailed,
        error.ZixHttp2_GrpcTlsMux_Unsupported,
        error.ZixHttp2_GrpcTlsMux_OutOfMemory,
        error.ZixHttp2_GrpcTlsMux_SpawnFailed,
        error.ZixHttp2_GrpcTlsMux_SetupFailed,
            => Error.ZixHttp2_GrpcServer_TlsSetupFailed,
    };
}

/// The .ASYNC dual listener thread for one Router. std.Thread.spawn takes a
/// plain function, so the comptime Router is bound here.
fn TlsThread(comptime RouterType: type) type {
    return struct {
        /// gRPC over TLS on tls_port while the cleartext model serves port. A
        /// failure is logged, cleartext keeps serving.
        fn run(config: Config, ctx: *const tlz.Context) void {
            tls_serve.runTls(RouterType, config, ctx) catch |err| {
                log.logSystem(
                    config,
                    .ERROR,
                    "grpc TLS listener on {s}:{d} stopped ({s}), cleartext still serving",
                    .{ config.ip, config.port, @errorName(err) },
                );
            };
        }
    };
}

/// Serve gRPC over TLS only, on config.port.
///
/// Note:
/// - .ASYNC runs one task per connection and also serves TLS 1.2.
/// - .EPOLL and .URING run the multiplexed TLS workers (TLS 1.3).
fn runTlsOnly(comptime RouterType: type, config: Config, ctx: *const tlz.Context) Error!void {
    return switch (config.dispatch_model) {
        .ASYNC => tls_serve.runTls(RouterType, config, ctx) catch |err| {
            return dispatchTlsServeError(err);
        },
        .EPOLL,
        .URING,
        => tls_mux.run(RouterType, config, ctx) catch |err| {
            return dispatchTlsMuxError(err);
        },
        // Never pass gateDispatchModel.
        .IOCP,
        .KQUEUE,
        => Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
    };
}

/// Start the TLS side of the dual listener (config.tls_port).
///
/// Note:
/// - .ASYNC: one extra accept thread serves gRPC over TLS on tls_port.
/// - .EPOLL and .URING host the TLS connections in the cleartext workers, so
///   their dispatch binds tls_port itself. Nothing starts here.
fn startTlsSide(comptime RouterType: type, config: Config, ctx: *const tlz.Context) Error!void {
    if (config.tls_port == config.port) return Error.ZixHttp2_GrpcServer_TlsPortConflict;

    switch (config.dispatch_model) {
        .ASYNC => {
            var tls_config = config;
            tls_config.port = config.tls_port;
            tls_config.tls_port = 0;

            const thread = std.Thread.spawn(
                .{},
                TlsThread(RouterType).run,
                .{ tls_config, ctx },
            ) catch |err| switch (err) {
                else => return Error.ZixHttp2_GrpcServer_TlsSetupFailed,
            };
            thread.detach();
        },
        .EPOLL,
        .URING,
        => {},
        // Never pass gateDispatchModel.
        .IOCP,
        .KQUEUE,
        => return Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
    }
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    /// config.port is 0
    ZixHttp2_GrpcServer_PortNotConfigured,
    /// config.dispatch_model cannot run on this platform or is not wired yet
    ZixHttp2_GrpcServer_DispatchModel_NotSupported,
    /// E.Q.: error.ZixHttp2_GrpcAsync_ResolveFailed
    ZixHttp2_GrpcServer_ResolveFailed,
    /// E.Q.: error.ZixHttp2_GrpcAsync_ListenFailed
    ZixHttp2_GrpcServer_ListenFailed,
    /// E.Q.: error.ZixHttp2_GrpcAsync_AcceptFailed
    ZixHttp2_GrpcServer_AcceptFailed,
    /// E.Q.: error.ZixHttp2_GrpcEpoll_SetupFailed
    ZixHttp2_GrpcServer_EpollSetupFailed,
    /// E.Q.: error.ZixHttp2_GrpcUring_SetupFailed
    ZixHttp2_GrpcServer_UringSetupFailed,
    /// config.tls_port equals config.port
    ZixHttp2_GrpcServer_TlsPortConflict,
    /// E.Q.: error.ZixHttp2_GrpcTlsMux_SetupFailed
    ZixHttp2_GrpcServer_TlsSetupFailed,
};

/// The server type for one Router.
///
/// Param:
/// RouterType - type (from zix.Grpc.Router, carrying route_slice and dispatch)
///
/// Return:
/// - type (holds the config, run serves it)
pub fn GrpcServer(comptime RouterType: type) type {
    return struct {
        config: Config,

        const Self = @This();

        /// No-op: run releases what it set up before it returns.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Listen and serve with the configured dispatch model.
        ///
        /// Return:
        /// - void
        /// - Error.ZixHttp2_GrpcServer_PortNotConfigured when config.port is 0
        /// - Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported when the
        ///   model cannot run
        /// - Error.ZixHttp2_GrpcServer_ResolveFailed or ListenFailed from any model
        /// - Error.ZixHttp2_GrpcServer_AcceptFailed from the .ASYNC model
        /// - Error.ZixHttp2_GrpcServer_EpollSetupFailed or UringSetupFailed
        ///   when a Linux model could not start its workers
        /// - Error.ZixHttp2_GrpcServer_TlsPortConflict when tls_port equals port
        /// - Error.ZixHttp2_GrpcServer_TlsSetupFailed when the TLS side could
        ///   not start
        pub fn run(self: *const Self) Error!void {
            ignoreSigpipe();

            try gatePort(self.config);
            try gateDispatchModel(self.config.dispatch_model);

            if (self.config.tls) |ctx| {
                if (self.config.tls_port == 0) return runTlsOnly(RouterType, self.config, ctx);

                try startTlsSide(RouterType, self.config, ctx);
            }

            return switch (self.config.dispatch_model) {
                .ASYNC => {
                    dispatch_async.run(RouterType, self.config) catch |err| switch (err) {
                        else => return dispatchError(err),
                    };
                },
                .EPOLL => {
                    dispatch_epoll.run(RouterType, self.config) catch |err| switch (err) {
                        else => return dispatchEpollError(err),
                    };
                },
                .URING => {
                    dispatch_uring.run(RouterType, self.config) catch |err| switch (err) {
                        else => return dispatchUringError(err),
                    };
                },
                // Never pass gateDispatchModel.
                .IOCP,
                .KQUEUE,
                => Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
            };
        }
    };
}

/// Build the server. Validation happens in run.
///
/// Usage:
/// ```zig
/// const router = zix.Grpc.Router(&[_]zix.Grpc.Route{
///     .{
///         .path = "/helloworld.Greeter/SayHello",
///         .handler = sayHello,
///     },
/// });
///
/// var server = zix.Grpc.Server.init(router, .{
///     .io = io,
///     .ip = "127.0.0.1",
///     .port = 9036,
///     .dispatch_model = .ASYNC,
/// });
/// defer server.deinit();
///
/// try server.run();
/// ```
///
/// Param:
/// RouterType - type (from zix.Grpc.Router)
/// config - Config (server settings)
///
/// Return:
/// - GrpcServer(RouterType)
pub fn init(comptime RouterType: type, config: Config) GrpcServer(RouterType) {
    return .{
        .config = config,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const router = @import("router.zig");

const EmptyRouter = router.Router(&[_]router.Route{});

fn testServer(port: u16, model: DispatchModel) GrpcServer(EmptyRouter) {
    return init(EmptyRouter, .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = port,
        .dispatch_model = model,
    });
}

fn testServerAt(ip: []const u8, model: DispatchModel) GrpcServer(EmptyRouter) {
    return init(EmptyRouter, .{
        .io = std.testing.io,
        .ip = ip,
        .port = 9036,
        .dispatch_model = model,
    });
}

test "zix http2 grpc: server, init keeps the config" {
    var server = testServer(9036, .ASYNC);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 9036), server.config.port);
    try std.testing.expectEqual(DispatchModel.ASYNC, server.config.dispatch_model);
}

test "zix http2 grpc: server, run with port 0 is PortNotConfigured" {
    var server = testServer(0, .ASYNC);
    defer server.deinit();

    try std.testing.expectError(Error.ZixHttp2_GrpcServer_PortNotConfigured, server.run());
}

test "zix http2 grpc: server, EPOLL off Linux is not supported" {
    if (comptime OS == .linux) return error.SkipZigTest;

    var server = testServer(9036, .EPOLL);
    defer server.deinit();

    try std.testing.expectError(
        Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
        server.run(),
    );
}

test "zix http2 grpc: server, URING off Linux is not supported" {
    if (comptime OS == .linux) return error.SkipZigTest;

    var server = testServer(9036, .URING);
    defer server.deinit();

    try std.testing.expectError(
        Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
        server.run(),
    );
}

test "zix http2 grpc: server, EPOLL on Linux maps an unresolvable ip to ResolveFailed" {
    if (comptime OS != .linux) return error.SkipZigTest;

    var server = testServerAt("not-an-ip", .EPOLL);
    defer server.deinit();

    try std.testing.expectError(Error.ZixHttp2_GrpcServer_ResolveFailed, server.run());
}

test "zix http2 grpc: server, URING on Linux maps an unresolvable ip to ResolveFailed" {
    if (comptime OS != .linux) return error.SkipZigTest;

    var server = testServerAt("not-an-ip", .URING);
    defer server.deinit();

    try std.testing.expectError(Error.ZixHttp2_GrpcServer_ResolveFailed, server.run());
}

test "zix http2 grpc: server, dispatchEpollError maps SetupFailed" {
    try std.testing.expectEqual(
        Error.ZixHttp2_GrpcServer_EpollSetupFailed,
        dispatchEpollError(dispatch_epoll.Error.ZixHttp2_GrpcEpoll_SetupFailed),
    );
}

test "zix http2 grpc: server, dispatchUringError maps WaitFailed" {
    try std.testing.expectEqual(
        Error.ZixHttp2_GrpcServer_UringSetupFailed,
        dispatchUringError(dispatch_uring.Error.ZixHttp2_GrpcUring_WaitFailed),
    );
}

test "zix http2 grpc: server, dispatchUringError maps ListenFailed" {
    try std.testing.expectEqual(
        Error.ZixHttp2_GrpcServer_ListenFailed,
        dispatchUringError(dispatch_uring.Error.ZixHttp2_GrpcUring_ListenFailed),
    );
}

test "zix http2 grpc: server, IOCP is not supported" {
    var server = testServer(9036, .IOCP);
    defer server.deinit();

    try std.testing.expectError(
        Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
        server.run(),
    );
}

test "zix http2 grpc: server, port is checked before the model" {
    var server = testServer(0, .KQUEUE);
    defer server.deinit();

    try std.testing.expectError(Error.ZixHttp2_GrpcServer_PortNotConfigured, server.run());
}

test "zix http2 grpc: server, an unresolvable ip is ResolveFailed" {
    var server = init(EmptyRouter, .{
        .io = std.testing.io,
        .ip = "not-an-ip",
        .port = 9036,
        .dispatch_model = .ASYNC,
    });
    defer server.deinit();

    try std.testing.expectError(Error.ZixHttp2_GrpcServer_ResolveFailed, server.run());
}

test "zix http2 grpc: server, tls_port equal to port is TlsPortConflict" {
    var ctx: tlz.Context = undefined;
    var server = testServer(9036, .ASYNC);
    defer server.deinit();
    server.config.tls = &ctx;
    server.config.tls_port = 9036;

    try std.testing.expectError(Error.ZixHttp2_GrpcServer_TlsPortConflict, server.run());
}

test "zix http2 grpc: server, TLS on IOCP is not supported" {
    var ctx: tlz.Context = undefined;
    var server = testServer(9036, .IOCP);
    defer server.deinit();
    server.config.tls = &ctx;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
        server.run(),
    );
}

test "zix http2 grpc: server, dual listener on KQUEUE is not supported" {
    var ctx: tlz.Context = undefined;
    var server = testServer(9036, .KQUEUE);
    defer server.deinit();
    server.config.tls = &ctx;
    server.config.tls_port = 9443;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
        server.run(),
    );
}

test "zix http2 grpc: server, TLS with an unresolvable ip is ResolveFailed" {
    var ctx: tlz.Context = undefined;
    var server = testServerAt("not-an-ip", .ASYNC);
    defer server.deinit();
    server.config.tls = &ctx;

    try std.testing.expectError(Error.ZixHttp2_GrpcServer_ResolveFailed, server.run());
}

test "zix http2 grpc: server, TLS mux with an unresolvable ip is ResolveFailed" {
    if (comptime OS != .linux) return error.SkipZigTest;

    var ctx: tlz.Context = undefined;
    var server = testServerAt("not-an-ip", .EPOLL);
    defer server.deinit();
    server.config.tls = &ctx;

    try std.testing.expectError(Error.ZixHttp2_GrpcServer_ResolveFailed, server.run());
}

test "zix http2 grpc: server, dispatchTlsServeError maps ListenFailed" {
    try std.testing.expectEqual(
        Error.ZixHttp2_GrpcServer_ListenFailed,
        dispatchTlsServeError(tls_serve.Error.ZixHttp2_GrpcTlsServe_ListenFailed),
    );
}

test "zix http2 grpc: server, dispatchTlsMuxError maps SpawnFailed" {
    try std.testing.expectEqual(
        Error.ZixHttp2_GrpcServer_TlsSetupFailed,
        dispatchTlsMuxError(tls_mux.Error.ZixHttp2_GrpcTlsMux_SpawnFailed),
    );
}

