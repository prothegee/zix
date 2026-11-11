//! ZIX Http2 Server
//!
//! ### file: src/zix/tcp/http2/Server.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Configured Http2 h2c server: init, deinit, and model startup.
//!
//! ### note:
//!
//! Only .ASYNC is wired. .EPOLL and .URING land with the Linux dispatch.
//! Until then they return DispatchModel_NotSupported after the config gates
//! pass.
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
const Config = @import("Config.zig");
const DispatchModel = @import("../../shared/dispatch.zig").Model;
const HandlerFn = @import("handler.zig").HandlerFn;
const dispatch_async = @import("dispatch/async.zig");
const StaticCacheRegistry = @import("../../utils/static/StaticCacheRegistry.zig");
const OS = @import("builtin").target.os.tag;

// --------------------------------------------------------- //
// Fields:

config: Config,
handler: HandlerFn,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn gatePort(config: Config) Error!void {
    if (config.port == 0) return Error.ZixHttp2_Server_PortNotConfigured;
}

/// Reject a model this platform cannot run, before any listener or static
/// cache is set up, so a rejected config leaves nothing behind.
fn gateDispatchModel(model: DispatchModel) Error!void {
    switch (model) {
        .ASYNC => {},
        .EPOLL,
        .URING,
        => if (comptime OS != .linux) return Error.ZixHttp2_Server_DispatchModel_NotSupported,
        // Not implemented yet. Listed one by one, so a new model in the enum
        // fails to compile here until it is given its own arm.
        .IOCP,
        .KQUEUE,
        => return Error.ZixHttp2_Server_DispatchModel_NotSupported,
    }
}

/// Fail fast when public_dir is set but cannot be entered, instead of a 404
/// for every file at runtime.
fn gatePublicDir(config: Config) Error!void {
    if (config.public_dir.len == 0) return;

    const opened = std.Io.Dir.cwd().openDir(config.io, config.public_dir, .{});
    const dir = opened catch |err| switch (err) {
        error.FileNotFound => return Error.ZixHttp2_Server_PublicDirNotFound,
        error.NotDir => return Error.ZixHttp2_Server_PublicDirNotADirectory,
        else => return Error.ZixHttp2_Server_PublicDirUnreadable,
    };

    dir.close(config.io);
}

/// Log one static cache warning through the configured logger.
fn warnStatic(config: Config, comptime message: []const u8) void {
    if (config.logger) |logger| {
        logger.system(.WARN, "http2", message, .{});

        return;
    }

    std.log.warn(message, .{});
}

/// Install the process static cache when public_dir and a TTL are set.
///
/// Note:
/// - A failed install is a warning, not an error: static files are still
///   served, each request re-opens its file.
///
/// Return:
/// - bool (true when this call built the table and owns its shutdown)
fn installStaticCache(config: Config) bool {
    if (config.public_dir.len == 0) return false;

    const installed = StaticCacheRegistry.shared.install(
        config.public_dir_cache_max_entries,
        config.public_dir_cache_ttl_ms,
    ) catch |err| switch (err) {
        error.ZixUtils_StaticCacheRegistry_OutOfMemory,
        error.ZixUtils_StaticCacheRegistry_MapFailed,
        => {
            warnStatic(config, "static cache not installed, each static request opens its file");

            return false;
        },
    };

    return switch (installed) {
        .INSTALLED => true,
        .MISMATCHED => {
            warnStatic(config, "static cache already installed with other settings, kept");

            return false;
        },
        .DISABLED,
        .ALREADY_INSTALLED,
        => false,
    };
}

fn dispatchError(err: dispatch_async.Error) Error {
    return switch (err) {
        error.ZixHttp2_Async_ResolveFailed
            => Error.ZixHttp2_Server_ResolveFailed,
        error.ZixHttp2_Async_ListenFailed
            => Error.ZixHttp2_Server_ListenFailed,
        error.ZixHttp2_Async_AcceptFailed
            => Error.ZixHttp2_Server_AcceptFailed,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    /// config.port is 0
    ZixHttp2_Server_PortNotConfigured,
    /// config.dispatch_model cannot run on this platform or is not wired yet
    ZixHttp2_Server_DispatchModel_NotSupported,
    /// config.public_dir does not exist
    ZixHttp2_Server_PublicDirNotFound,
    /// config.public_dir is not a directory
    ZixHttp2_Server_PublicDirNotADirectory,
    /// config.public_dir cannot be opened (permission or other)
    ZixHttp2_Server_PublicDirUnreadable,
    /// E.Q.: error.ZixHttp2_Async_ResolveFailed
    ZixHttp2_Server_ResolveFailed,
    /// E.Q.: error.ZixHttp2_Async_ListenFailed
    ZixHttp2_Server_ListenFailed,
    /// E.Q.: error.ZixHttp2_Async_AcceptFailed
    ZixHttp2_Server_AcceptFailed,
};

/// Build the server. Validation happens in run.
///
/// Usage:
/// ```zig
/// const router = zix.Http2.Router(&[_]zix.Http2.Route{
///     .{
///         .path = "/",
///         .handler = home,
///     },
/// });
///
/// var server = zix.Http2.Server.init(router.dispatch, .{
///     .io = io,
///     .ip = "127.0.0.1",
///     .port = 9065,
///     .dispatch_model = .ASYNC,
/// });
/// defer server.deinit();
///
/// try server.run();
/// ```
///
/// Param:
/// handler - HandlerFn (the top-level handler, usually Router.dispatch)
/// config - Config (server settings)
///
/// Return:
/// - Self
pub fn init(comptime handler: HandlerFn, config: Config) Self {
    return .{
        .config = config,
        .handler = handler,
    };
}

pub fn deinit(self: *Self) void {
    if (self.config.logger) |logger| {
        logger.system(.INFO, "http2", "server stopped", .{});
    }
}

/// Listen and serve with the configured dispatch model.
///
/// Return:
/// - void
/// - Error.ZixHttp2_Server_PortNotConfigured when config.port is 0
/// - Error.ZixHttp2_Server_DispatchModel_NotSupported when the model cannot run
/// - Error.ZixHttp2_Server_PublicDir* when config.public_dir cannot be entered
/// - Error.ZixHttp2_Server_ResolveFailed, ListenFailed, or AcceptFailed from
///   the .ASYNC model
pub fn run(self: *const Self) Error!void {
    try gatePort(self.config);
    try gateDispatchModel(self.config.dispatch_model);
    try gatePublicDir(self.config);

    // Only the server that built the table closes it. A server that shares
    // it must not close files another server is still serving.
    const owns_static = installStaticCache(self.config);
    defer if (owns_static) StaticCacheRegistry.shared.shutdown(self.config.io);

    return switch (self.config.dispatch_model) {
        .ASYNC => {
            dispatch_async.run(self.config, self.handler) catch |err| switch (err) {
                else => return dispatchError(err),
            };
        },
        // .EPOLL and .URING land with the Linux dispatch. .IOCP and .KQUEUE
        // never pass gateDispatchModel.
        .EPOLL,
        .URING,
        .IOCP,
        .KQUEUE,
        => Error.ZixHttp2_Server_DispatchModel_NotSupported,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Context = @import("Context.zig");

fn mockHandler(_: *Request, _: *Response, _: *Context) anyerror!void {}

fn testServer(model: DispatchModel) Self {
    return Self.init(mockHandler, .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 9065,
        .dispatch_model = model,
    });
}

test "zix http2: Server, init stores its inputs" {
    const server = testServer(.ASYNC);

    try std.testing.expectEqualStrings("127.0.0.1", server.config.ip);
    try std.testing.expectEqual(@as(u16, 9065), server.config.port);
    try std.testing.expect(server.handler == mockHandler);
}

test "zix http2: Server, init keeps the dispatch model" {
    const server = testServer(.EPOLL);

    try std.testing.expectEqual(.EPOLL, server.config.dispatch_model);
}

test "zix http2: Server, deinit without a logger is safe" {
    var server = testServer(.ASYNC);

    server.deinit();
}

test "zix http2: Server, run with port 0 is PortNotConfigured" {
    var server = testServer(.ASYNC);
    server.config.port = 0;

    try std.testing.expectError(Error.ZixHttp2_Server_PortNotConfigured, server.run());
}

test "zix http2: Server, port 0 is checked before the dispatch model" {
    var server = testServer(.IOCP);
    server.config.port = 0;

    try std.testing.expectError(Error.ZixHttp2_Server_PortNotConfigured, server.run());
}

test "zix http2: Server, IOCP is not supported" {
    const server = testServer(.IOCP);

    try std.testing.expectError(Error.ZixHttp2_Server_DispatchModel_NotSupported, server.run());
}

test "zix http2: Server, KQUEUE is not supported" {
    const server = testServer(.KQUEUE);

    try std.testing.expectError(Error.ZixHttp2_Server_DispatchModel_NotSupported, server.run());
}

test "zix http2: Server, EPOLL outside Linux is not supported" {
    if (comptime OS == .linux) return;

    const server = testServer(.EPOLL);

    try std.testing.expectError(Error.ZixHttp2_Server_DispatchModel_NotSupported, server.run());
}

test "zix http2: Server, URING outside Linux is not supported" {
    if (comptime OS == .linux) return;

    const server = testServer(.URING);

    try std.testing.expectError(Error.ZixHttp2_Server_DispatchModel_NotSupported, server.run());
}

test "zix http2: Server, gateDispatchModel accepts ASYNC" {
    try gateDispatchModel(.ASYNC);
}

test "zix http2: Server, gateDispatchModel accepts EPOLL on Linux" {
    if (comptime OS != .linux) return;

    try gateDispatchModel(.EPOLL);
}

test "zix http2: Server, gateDispatchModel accepts URING on Linux" {
    if (comptime OS != .linux) return;

    try gateDispatchModel(.URING);
}

test "zix http2: Server, unsupported model is rejected before public_dir" {
    var server = testServer(.IOCP);
    server.config.public_dir = "no-such-public-dir-for-zix-tests";

    try std.testing.expectError(Error.ZixHttp2_Server_DispatchModel_NotSupported, server.run());
}

test "zix http2: Server, run with a missing public_dir is PublicDirNotFound" {
    var server = testServer(.ASYNC);
    server.config.public_dir = "no-such-public-dir-for-zix-tests";

    try std.testing.expectError(Error.ZixHttp2_Server_PublicDirNotFound, server.run());
}

test "zix http2: Server, gatePublicDir empty is accepted" {
    try gatePublicDir(testServer(.ASYNC).config);
}

test "zix http2: Server, gatePublicDir file is PublicDirNotADirectory" {
    var config = testServer(.ASYNC).config;
    config.public_dir = "build.zig";

    try std.testing.expectError(
        Error.ZixHttp2_Server_PublicDirNotADirectory,
        gatePublicDir(config),
    );
}

test "zix http2: Server, gatePublicDir existing directory is accepted" {
    var config = testServer(.ASYNC).config;
    config.public_dir = "src";

    try gatePublicDir(config);
}

test "zix http2: Server, installStaticCache without public_dir is false" {
    try std.testing.expect(!installStaticCache(testServer(.ASYNC).config));
}

test "zix http2: Server, installStaticCache ttl 0 is false" {
    var config = testServer(.ASYNC).config;
    config.public_dir = "src";

    try std.testing.expect(!installStaticCache(config));
    try std.testing.expect(StaticCacheRegistry.shared.instance() == null);
}

test "zix http2: Server, installStaticCache owns the table it builds" {
    var config = testServer(.ASYNC).config;
    config.public_dir = "src";
    config.public_dir_cache_ttl_ms = 1000;
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    try std.testing.expect(installStaticCache(config));
    try std.testing.expect(!installStaticCache(config));
}

test "zix http2: Server, dispatchError maps ResolveFailed" {
    try std.testing.expectEqual(
        Error.ZixHttp2_Server_ResolveFailed,
        dispatchError(error.ZixHttp2_Async_ResolveFailed),
    );
}

test "zix http2: Server, dispatchError maps ListenFailed" {
    try std.testing.expectEqual(
        Error.ZixHttp2_Server_ListenFailed,
        dispatchError(error.ZixHttp2_Async_ListenFailed),
    );
}

test "zix http2: Server, dispatchError maps AcceptFailed" {
    try std.testing.expectEqual(
        Error.ZixHttp2_Server_AcceptFailed,
        dispatchError(error.ZixHttp2_Async_AcceptFailed),
    );
}

test "zix http2: Server, ASYNC with an unresolvable ip is ResolveFailed" {
    var server = testServer(.ASYNC);
    server.config.ip = "not-an-ip";

    try std.testing.expectError(Error.ZixHttp2_Server_ResolveFailed, server.run());
}

