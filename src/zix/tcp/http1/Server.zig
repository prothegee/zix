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
const Config = @import("Config.zig");
const HandlerFn = @import("handler.zig").HandlerFn;
const OS = @import("builtin").target.os.tag;
const dispatch_async = @import("dispatch/async.zig");
const dispatch_epoll = @import("dispatch/epoll.zig");

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
};

pub fn init(comptime handler: HandlerFn, config: Config) Self {
    gateConfig(config);

    return .{
        .config = config,
        .handler = handler,
    };
}

pub fn deinit(_: *Self) void {
    std.log.info("TODO: ZIX Http1 server deinit", .{});
    // If logger not null write the exit log first
}

pub fn run(self: *const Self) Error!void {
    std.log.info("TODO: ignoreSigpipe", .{});

    std.log.info("TODO: gateDispatchModel", .{});

    std.log.info("TODO: gatePublicDir", .{});

    std.log.info("TODO: gateTLS", .{});

    return switch (self.config.dispatch_model) {
        .ASYNC => {
            std.log.info("TODO: ZIX Http1 server run .ASYNC", .{});
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
            @panic("TODO: ZIX Http1 server run .URING");
        },
        else => Error.ZixHttp1_Server_DispatchModel_NotSupported,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Context = @import("Context.zig");

fn mockHandler(_: *Request, _: *Response, _: *Context) anyerror!void {}

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

