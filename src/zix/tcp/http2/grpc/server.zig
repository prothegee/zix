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
const dispatch_async = @import("dispatch/async.zig");
const dispatch_epoll = @import("dispatch/epoll.zig");
const dispatch_uring = @import("dispatch/uring.zig");
const Config = @import("Config.zig");
const DispatchModel = @import("../../../shared/dispatch.zig").Model;
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
        pub fn run(self: *const Self) Error!void {
            try gatePort(self.config);
            try gateDispatchModel(self.config.dispatch_model);

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

