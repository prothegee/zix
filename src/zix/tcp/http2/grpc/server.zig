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
const Config = @import("Config.zig");
const DispatchModel = @import("../../../shared/dispatch.zig").Model;

// --------------------------------------------------------- //
// Private:

fn gatePort(config: Config) Error!void {
    if (config.port == 0) return Error.ZixHttp2_GrpcServer_PortNotConfigured;
}

/// Reject a model this server cannot run, before any listener is set up, so
/// a rejected config leaves nothing behind.
fn gateDispatchModel(model: DispatchModel) Error!void {
    switch (model) {
        .ASYNC => {},
        // Not wired yet: .EPOLL and .URING land with their dispatch files.
        // Listed one by one, so a new model in the enum fails to compile here
        // until it is given its own arm.
        .EPOLL,
        .URING,
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
        /// - Error.ZixHttp2_GrpcServer_ResolveFailed, ListenFailed, or
        ///   AcceptFailed from the .ASYNC model
        pub fn run(self: *const Self) Error!void {
            try gatePort(self.config);
            try gateDispatchModel(self.config.dispatch_model);

            dispatch_async.run(RouterType, self.config) catch |err| switch (err) {
                else => return dispatchError(err),
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

test "zix http2 grpc: server, EPOLL is not supported yet" {
    var server = testServer(9036, .EPOLL);
    defer server.deinit();

    try std.testing.expectError(
        Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
        server.run(),
    );
}

test "zix http2 grpc: server, URING is not supported yet" {
    var server = testServer(9036, .URING);
    defer server.deinit();

    try std.testing.expectError(
        Error.ZixHttp2_GrpcServer_DispatchModel_NotSupported,
        server.run(),
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

