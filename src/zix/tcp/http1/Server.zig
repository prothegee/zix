//! ZIX Http1 Server
//!
//! ### file: src/zix/tcp/http1/Server.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Configured Http1 server: init, deinit, and model startup.
//! 
//! ### note:
//! 
//! n/a
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
const Config = @import("Config.zig");
const HandlerFn = @import("handler.zig").HandlerFn;
const StaticCacheRegistry = @import("../../utils/static/StaticCacheRegistry.zig");
const OS = @import("builtin").target.os.tag;
const dispatch_async = @import("dispatch/async.zig");
const dispatch_epoll = @import("dispatch/epoll.zig");
const dispatch_uring = @import("dispatch/uring.zig");
const log = @import("log.zig");
const tls_mux = @import("tls_mux.zig");
const tls_serve = @import("tls_serve.zig");

// --------------------------------------------------------- //
// Fields:

config: Config,
handler: HandlerFn,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn gateConfig(config: Config) void {
    if (config.ip.len == 0) {
        std.log.err("ZIX Http1 config.ip can't be empty", .{});
    }

    if (config.port == 0) {
        std.log.err("ZIX Http1 config.port can't be zero", .{});
    }
}

/// Fail fast when public_dir is set but cannot be entered, instead of a 404
/// for every file at runtime.
fn gatePublicDir(config: Config) Error!void {
    if (config.public_dir.len == 0) return;

    const opened = std.Io.Dir.cwd().openDir(config.io, config.public_dir, .{});
    const dir = opened catch |err| switch (err) {
        error.FileNotFound => return Error.ZixHttp1_Server_PublicDirNotFound,
        error.NotDir => return Error.ZixHttp1_Server_PublicDirNotADirectory,
        else => return Error.ZixHttp1_Server_PublicDirUnreadable,
    };

    dir.close(config.io);
}

/// Log one static cache warning through the configured logger.
fn warnStatic(config: Config, comptime message: []const u8) void {
    if (config.logger) |logger| {
        logger.system(.WARN, "http1", message, .{});

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
        error.ZixHttp1_Async_ResolveFailed
            => Error.ZixHttp1_Server_ResolveFailed,
        error.ZixHttp1_Async_ListenFailed
            => Error.ZixHttp1_Server_ListenFailed,
        error.ZixHttp1_Async_AcceptFailed
            => Error.ZixHttp1_Server_AcceptFailed,
    };
}

fn dispatchEpollError(err: dispatch_epoll.Error) Error {
    return switch (err) {
        error.ZixHttp1_Epoll_ResolveFailed
            => Error.ZixHttp1_Server_ResolveFailed,
        error.ZixHttp1_Epoll_ListenFailed
            => Error.ZixHttp1_Server_ListenFailed,
        error.ZixHttp1_Epoll_OutOfMemory,
        error.ZixHttp1_Epoll_SpawnFailed,
        error.ZixHttp1_Epoll_SetupFailed,
        error.ZixHttp1_Epoll_Unsupported,
            => Error.ZixHttp1_Server_EpollSetupFailed,
    };
}

fn dispatchUringError(err: dispatch_uring.Error) Error {
    return switch (err) {
        error.ZixHttp1_Uring_ResolveFailed
            => Error.ZixHttp1_Server_ResolveFailed,
        error.ZixHttp1_Uring_ListenFailed
            => Error.ZixHttp1_Server_ListenFailed,
        error.ZixHttp1_Uring_OutOfMemory,
        error.ZixHttp1_Uring_SpawnFailed,
        error.ZixHttp1_Uring_SetupFailed,
        error.ZixHttp1_Uring_WaitFailed,
        error.ZixHttp1_Uring_Unsupported,
            => Error.ZixHttp1_Server_UringSetupFailed,
    };
}

fn dispatchTlsServeError(err: tls_serve.Error) Error {
    return switch (err) {
        error.ZixHttp1_TlsServe_ResolveFailed
            => Error.ZixHttp1_Server_ResolveFailed,
        error.ZixHttp1_TlsServe_ListenFailed
            => Error.ZixHttp1_Server_ListenFailed,
        error.ZixHttp1_TlsServe_AcceptFailed
            => Error.ZixHttp1_Server_AcceptFailed,
        error.ZixHttp1_TlsServe_EntropyUnavailable,
        error.ZixHttp1_TlsServe_Canceled,
        error.ZixHttp1_TlsServe_Closed,
        error.ZixHttp1_TlsServe_HeaderTooLarge,
        error.ZixHttp1_TlsServe_ReadFailed,
        error.ZixHttp1_TlsServe_SetBufFailed,
        error.ZixHttp1_TlsServe_BrokenPipe,
        error.ZixHttp1_TlsServe_HeadBuild,
        error.ZixHttp1_TlsServe_RecordTooLarge,
        error.ZixHttp1_TlsServe_UnexpectedRecord,
        error.ZixHttp1_TlsServe_PeerAlert,
        error.ZixHttp1_TlsServe_Tls12RequiresEcdsa,
        error.ZixHttp1_TlsServe_RecordSealFailed,
        error.ZixHttp1_TlsServe_InvalidRequest,
        error.ZixHttp1_TlsServe_UnknownMethod,
        error.ZixHttp1_TlsServe_ResponseTooLarge,
        error.ZixHttp1_TlsServe_StreamingNotSupported,
        error.ZixHttp1_TlsServe_WsFrameTooLarge,
        error.ZixHttp1_TlsServe_MissingKeyShare,
        error.ZixHttp1_TlsServe_BadKeyShare,
        error.ZixHttp1_TlsServe_UnsupportedCipher,
        error.ZixHttp1_TlsServe_UnsupportedGroup,
        error.ZixHttp1_TlsServe_NoCommonSignatureScheme,
        error.ZixHttp1_TlsServe_NoApplicationProtocol,
        error.ZixHttp1_TlsServe_HelloRetryRequestUnsupported,
        error.ZixHttp1_TlsServe_HelloRetryGroupMismatch,
        error.ZixHttp1_TlsServe_UnsupportedTlsVersion,
        error.ZixHttp1_TlsServe_MissingExtension,
        error.ZixHttp1_TlsServe_HandshakeFailure,
        error.ZixHttp1_TlsServe_IllegalParameter,
        error.ZixHttp1_TlsServe_DecodeError,
        error.ZixHttp1_TlsServe_SignFailed,
        error.ZixHttp1_TlsServe_InvalidKey,
        error.ZixHttp1_TlsServe_MessageTooLong,
        error.ZixHttp1_TlsServe_PeerClosed,
        error.ZixHttp1_TlsServe_UnexpectedMessage,
        error.ZixHttp1_TlsServe_UnexpectedHandshakeMessage,
        error.ZixHttp1_TlsServe_Decode,
        error.ZixHttp1_TlsServe_RecordOverflow,
        error.ZixHttp1_TlsServe_BadRecordMac,
        error.ZixHttp1_TlsServe_Truncated,
        error.ZixHttp1_TlsServe_ClientFinishedMismatch,
        error.ZixHttp1_TlsServe_ClientCertificateMissing,
        error.ZixHttp1_TlsServe_CertificateTooLarge,
        error.ZixHttp1_TlsServe_UnsupportedSignatureScheme,
        error.ZixHttp1_TlsServe_SignatureFailed,
        error.ZixHttp1_TlsServe_UnsupportedPeerKey,
        error.ZixHttp1_TlsServe_CertificateMalformed,
        error.ZixHttp1_TlsServe_CertificateHasUnrecognizedObjectId,
        error.ZixHttp1_TlsServe_ClientHelloInvalid,
        error.ZixHttp1_TlsServe_BadRecord,
        error.ZixHttp1_TlsServe_AuthenticationFailed,
            => Error.ZixHttp1_Server_TlsSetupFailed,
    };
}

fn dispatchTlsMuxError(err: tls_mux.Error) Error {
    return switch (err) {
        error.ZixHttp1_TlsMux_ResolveFailed
            => Error.ZixHttp1_Server_ResolveFailed,
        error.ZixHttp1_TlsMux_ListenFailed
            => Error.ZixHttp1_Server_ListenFailed,
        error.ZixHttp1_TlsMux_Unsupported,
        error.ZixHttp1_TlsMux_OutOfMemory,
        error.ZixHttp1_TlsMux_SpawnFailed,
        error.ZixHttp1_TlsMux_SetupFailed,
            => Error.ZixHttp1_Server_TlsSetupFailed,
    };
}

/// Thread body for the .ASYNC dual listener: https on tls_port while the
/// cleartext model serves port. A failure is logged, cleartext keeps serving.
fn serveTlsThread(config: Config, handler: HandlerFn, ctx: *const tlz.Context) void {
    tls_serve.runTls(config, handler, ctx) catch |err| {
        log.logSystem(
            config,
            .ERROR,
            "https listener on {s}:{d} stopped ({s}), cleartext still serving",
            .{ config.ip, config.port, @errorName(err) },
        );
    };
}

/// Serve TLS only on config.port.
fn runTlsOnly(self: *const Self, ctx: *const tlz.Context) Error!void {
    return switch (self.config.dispatch_model) {
        .ASYNC => tls_serve.runTls(self.config, self.handler, ctx) catch |err| {
            return dispatchTlsServeError(err);
        },
        .EPOLL,
        .URING,
        => {
            if (comptime OS == .linux) {
                tls_mux.run(self.config, self.handler, ctx) catch |err| {
                    return dispatchTlsMuxError(err);
                };
            } else {
                return Error.ZixHttp1_Server_DispatchModel_NotSupported;
            }
        },
        .IOCP,
        .KQUEUE,
        => Error.ZixHttp1_Server_DispatchModel_NotSupported,
    };
}

/// Start the https side of the dual listener (config.tls_port).
///
/// Note:
/// - .ASYNC: one extra accept thread serves https on tls_port.
/// - .EPOLL and .URING host the TLS connections in the cleartext workers, so
///   their dispatch binds tls_port itself. Nothing starts here.
fn startTlsSide(self: *const Self, ctx: *const tlz.Context) Error!void {
    if (self.config.tls_port == self.config.port) return Error.ZixHttp1_Server_TlsPortConflict;

    switch (self.config.dispatch_model) {
        .ASYNC => {
            var tls_config = self.config;
            tls_config.port = self.config.tls_port;
            tls_config.tls_port = 0;

            const thread = std.Thread.spawn(
                .{},
                serveTlsThread,
                .{ tls_config, self.handler, ctx },
            ) catch |err| switch (err) {
                else => return Error.ZixHttp1_Server_TlsSetupFailed,
            };
            thread.detach();
        },
        .EPOLL,
        .URING,
        => {},
        .IOCP,
        .KQUEUE,
        => return Error.ZixHttp1_Server_DispatchModel_NotSupported,
    }
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixHttp1_Server_UnknownError,
    ZixHttp1_Server_DispatchModel_NotSupported,
    //
    /// E.Q.: error.Canceled
    ZixHttp1_Server_Canceled,
    /// E.Q.: error.SystemResources
    ZixHttp1_Server_SystemResources,
    /// E.Q.: error.AccessDenied
    ZixHttp1_Server_AccessDenied,
    /// E.Q.: error.Unexpected
    ZixHttp1_Server_Unexpected,
    /// E.Q.: error.ProcessFdQuotaExceeded
    ZixHttp1_Server_ProcessFdQuotaExceeded,
    /// E.Q.: error.SystemFdQuotaExceeded
    ZixHttp1_Server_SystemFdQuotaExceeded,
    /// E.Q.: error.NetworkDown
    ZixHttp1_Server_NetworkDown,
    /// E.Q.: error.AddressFamilyUnsupported
    ZixHttp1_Server_AddressFamilyUnsupported,
    /// E.Q.: error.NameTooLong
    ZixHttp1_Server_NameTooLong,
    /// E.Q.: error.AddressInUse
    ZixHttp1_Server_AddressInUse,
    /// E.Q.: error.AddressUnavailable
    ZixHttp1_Server_AddressUnavailable,
    /// E.Q.: error.ProtocolUnsupportedBySystem
    ZixHttp1_Server_ProtocolUnsupported_BySystem,
    /// E.Q.: error.ProtocolUnsupportedByAddressFamily
    ZixHttp1_Server_ProtocolUnsupported_ByAddressFamily,
    /// E.Q.: error.SocketModeUnsupported
    ZixHttp1_Server_SocketModeUnsupported,
    /// E.Q.: error.OptionUnsupported
    ZixHttp1_Server_OptionUnsupported,
    /// E.Q.: error.InterfaceNotFound
    ZixHttp1_Server_InterfaceNotFound,
    /// E.Q.: error.ParseFailed
    ZixHttp1_Server_ParseFailed,
    /// E.Q.: error.ZixHttp1_Async_ResolveFailed
    ZixHttp1_Server_ResolveFailed,
    /// E.Q.: error.ZixHttp1_Async_ListenFailed
    ZixHttp1_Server_ListenFailed,
    /// E.Q.: error.ZixHttp1_Async_AcceptFailed
    ZixHttp1_Server_AcceptFailed,
    /// E.Q.: error.ZixHttp1_Epoll_SetupFailed
    ZixHttp1_Server_EpollSetupFailed,
    /// E.Q.: error.ZixHttp1_Uring_SetupFailed
    ZixHttp1_Server_UringSetupFailed,
    /// config.public_dir does not exist
    ZixHttp1_Server_PublicDirNotFound,
    /// config.public_dir is not a directory
    ZixHttp1_Server_PublicDirNotADirectory,
    /// config.public_dir cannot be opened (permission or other)
    ZixHttp1_Server_PublicDirUnreadable,
    /// config.tls_port equals config.port
    ZixHttp1_Server_TlsPortConflict,
    /// E.Q.: error.ZixHttp1_TlsMux_SetupFailed
    ZixHttp1_Server_TlsSetupFailed,
};

pub fn init(comptime handler: HandlerFn, config: Config) Self {
    gateConfig(config);

    return .{
        .config = config,
        .handler = handler,
    };
}

pub fn deinit(self: *Self) void {
    if (self.config.logger) |logger| {
        logger.system(.INFO, "http1", "server stopped", .{});
    }
}

pub fn run(self: *const Self) Error!void {
    std.log.info("TODO: ignoreSigpipe", .{});

    std.log.info("TODO: gateDispatchModel", .{});

    try gatePublicDir(self.config);

    // Only the server that built the table closes it. A server that shares
    // it must not close files another server is still serving.
    const owns_static = installStaticCache(self.config);
    defer if (owns_static) StaticCacheRegistry.shared.shutdown(self.config.io);

    if (self.config.tls) |ctx| {
        if (self.config.tls_port == 0) return self.runTlsOnly(ctx);

        try self.startTlsSide(ctx);
    }

    return switch (self.config.dispatch_model) {
        .ASYNC => {
            dispatch_async.run(self.config, self.handler) catch |err| switch (err) {
                else => return dispatchError(err),
            };
        },
        .EPOLL => {
            if (comptime OS == .linux) {
                dispatch_epoll.run(self.config, self.handler) catch |err| switch (err) {
                    else => return dispatchEpollError(err),
                };
            } else {
                return Error.ZixHttp1_Server_DispatchModel_NotSupported;
            }
        },
        .URING => {
            if (comptime OS == .linux) {
                dispatch_uring.run(self.config, self.handler) catch |err| switch (err) {
                    else => return dispatchUringError(err),
                };
            } else {
                return Error.ZixHttp1_Server_DispatchModel_NotSupported;
            }
        },
        // Not implemented yet. Listed one by one, so a new model in the enum
        // fails to compile here until it is given its own arm.
        .IOCP,
        .KQUEUE,
        => Error.ZixHttp1_Server_DispatchModel_NotSupported,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Context = @import("Context.zig");
const DispatchModel = @import("../../shared/dispatch.zig").Model;

fn mockHandler(_: *Request, _: *Response, _: *Context) anyerror!void {}

fn testServer(model: DispatchModel) Self {
    return Self.init(mockHandler, .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 8080,
        .dispatch_model = model,
        .response_cache = true,
    });
}

test "zix http1: Server, init stores its inputs" {
    const config: Config = .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 8080,
        .dispatch_model = .ASYNC,
    };
    const server = Self.init(mockHandler, config);

    try std.testing.expectEqualStrings("127.0.0.1", server.config.ip);
    try std.testing.expectEqual(@as(u16, 8080), server.config.port);
    try std.testing.expect(server.handler == mockHandler);
}

test "zix http1: Server, init keeps the dispatch model" {
    const config: Config = .{
        .io = std.testing.io,
        .ip = "0.0.0.0",
        .port = 9000,
        .dispatch_model = .EPOLL,
        .workers = 2,
    };
    const server = Self.init(mockHandler, config);

    try std.testing.expectEqual(.EPOLL, server.config.dispatch_model);
    try std.testing.expectEqual(@as(usize, 2), server.config.workers);
}

test "zix http1: Server, maps uring setup failures" {
    try std.testing.expectEqual(
        Error.ZixHttp1_Server_UringSetupFailed,
        dispatchUringError(error.ZixHttp1_Uring_SetupFailed),
    );
    try std.testing.expectEqual(
        Error.ZixHttp1_Server_UringSetupFailed,
        dispatchUringError(error.ZixHttp1_Uring_SpawnFailed),
    );
    try std.testing.expectEqual(
        Error.ZixHttp1_Server_ResolveFailed,
        dispatchUringError(error.ZixHttp1_Uring_ResolveFailed),
    );
    try std.testing.expectEqual(
        Error.ZixHttp1_Server_ListenFailed,
        dispatchUringError(error.ZixHttp1_Uring_ListenFailed),
    );
}

test "zix http1: Server, IOCP is not supported" {
    const server = testServer(.IOCP);

    try std.testing.expectError(Error.ZixHttp1_Server_DispatchModel_NotSupported, server.run());
}

test "zix http1: Server, KQUEUE is not supported" {
    const server = testServer(.KQUEUE);

    try std.testing.expectError(Error.ZixHttp1_Server_DispatchModel_NotSupported, server.run());
}

test "zix http1: Server, EPOLL outside Linux is not supported" {
    if (comptime OS == .linux) return;

    const server = testServer(.EPOLL);

    try std.testing.expectError(Error.ZixHttp1_Server_DispatchModel_NotSupported, server.run());
}

test "zix http1: Server, URING outside Linux is not supported" {
    if (comptime OS == .linux) return;

    const server = testServer(.URING);

    try std.testing.expectError(Error.ZixHttp1_Server_DispatchModel_NotSupported, server.run());
}

test "zix http1: Server, gatePublicDir empty is accepted" {
    try gatePublicDir(testServer(.ASYNC).config);
}

test "zix http1: Server, gatePublicDir missing directory is PublicDirNotFound" {
    var config = testServer(.ASYNC).config;
    config.public_dir = "no-such-public-dir-for-zix-tests";

    try std.testing.expectError(Error.ZixHttp1_Server_PublicDirNotFound, gatePublicDir(config));
}

test "zix http1: Server, gatePublicDir file is PublicDirNotADirectory" {
    var config = testServer(.ASYNC).config;
    config.public_dir = "build.zig";

    try std.testing.expectError(
        Error.ZixHttp1_Server_PublicDirNotADirectory,
        gatePublicDir(config),
    );
}

test "zix http1: Server, gatePublicDir existing directory is accepted" {
    var config = testServer(.ASYNC).config;
    config.public_dir = "src";

    try gatePublicDir(config);
}

test "zix http1: Server, installStaticCache without public_dir is false" {
    try std.testing.expect(!installStaticCache(testServer(.ASYNC).config));
}

test "zix http1: Server, installStaticCache ttl 0 is false" {
    var config = testServer(.ASYNC).config;
    config.public_dir = "src";

    try std.testing.expect(!installStaticCache(config));
    try std.testing.expect(StaticCacheRegistry.shared.instance() == null);
}

test "zix http1: Server, installStaticCache owns the table it builds" {
    var config = testServer(.ASYNC).config;
    config.public_dir = "src";
    config.public_dir_cache_ttl_ms = 1000;
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    try std.testing.expect(installStaticCache(config));
    try std.testing.expect(!installStaticCache(config));
}

test "zix http1: Server, tls_port equal to port is TlsPortConflict" {
    var ctx: tlz.Context = undefined;
    var server = testServer(.ASYNC);
    server.config.tls = &ctx;
    server.config.tls_port = server.config.port;

    try std.testing.expectError(Error.ZixHttp1_Server_TlsPortConflict, server.run());
}

test "zix http1: Server, TLS on IOCP is not supported" {
    var ctx: tlz.Context = undefined;
    var server = testServer(.IOCP);
    server.config.tls = &ctx;

    try std.testing.expectError(Error.ZixHttp1_Server_DispatchModel_NotSupported, server.run());
}

test "zix http1: Server, dual listener on KQUEUE is not supported" {
    var ctx: tlz.Context = undefined;
    var server = testServer(.KQUEUE);
    server.config.tls = &ctx;
    server.config.tls_port = 8443;

    try std.testing.expectError(Error.ZixHttp1_Server_DispatchModel_NotSupported, server.run());
}

test "zix http1: Server, maps a TLS bind failure" {
    try std.testing.expectEqual(
        Error.ZixHttp1_Server_ListenFailed,
        dispatchTlsServeError(error.ZixHttp1_TlsServe_ListenFailed),
    );
    try std.testing.expectEqual(
        Error.ZixHttp1_Server_ResolveFailed,
        dispatchTlsMuxError(error.ZixHttp1_TlsMux_ResolveFailed),
    );
}

test "zix http1: Server, maps TLS mux setup failures" {
    try std.testing.expectEqual(
        Error.ZixHttp1_Server_TlsSetupFailed,
        dispatchTlsMuxError(error.ZixHttp1_TlsMux_SpawnFailed),
    );
}

