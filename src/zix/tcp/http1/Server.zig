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
//! n/a
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
const core = @import("core.zig");
const Config = @import("Config.zig");
const HandlerFn = core.HandlerFn;
const OS = @import("builtin").target.os.tag;
const dispatch_async = @import("dispatch/async.zig");

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

fn dispatchError(err: anyerror) Error {
    return switch (err) {
        error.Canceled
            => Error.ZixHttp1_Server_Canceled,
        error.SystemResources
            => Error.ZixHttp1_Server_SystemResources,
        error.AccessDenied
            => Error.ZixHttp1_Server_AccessDenied,
        error.Unexpected
            => Error.ZixHttp1_Server_Unexpected,
        error.ProcessFdQuotaExceeded
            => Error.ZixHttp1_Server_ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded
            => Error.ZixHttp1_Server_SystemFdQuotaExceeded,
        error.NetworkDown
            => Error.ZixHttp1_Server_NetworkDown,
        error.AddressFamilyUnsupported
            => Error.ZixHttp1_Server_AddressFamilyUnsupported,
        error.NameTooLong
            => Error.ZixHttp1_Server_NameTooLong,
        error.AddressInUse
            => Error.ZixHttp1_Server_AddressInUse,
        error.AddressUnavailable
            => Error.ZixHttp1_Server_AddressUnavailable,
        error.ProtocolUnsupportedBySystem
            => Error.ZixHttp1_Server_ProtocolUnsupported_BySystem,
        error.ProtocolUnsupportedByAddressFamily
            => Error.ZixHttp1_Server_ProtocolUnsupported_ByAddressFamily,
        error.SocketModeUnsupported
            => Error.ZixHttp1_Server_SocketModeUnsupported,
        error.OptionUnsupported
            => Error.ZixHttp1_Server_OptionUnsupported,
        error.InterfaceNotFound
            => Error.ZixHttp1_Server_InterfaceNotFound,
        error.ParseFailed
            => Error.ZixHttp1_Server_ParseFailed,
        else
            => Error.ZixHttp1_Server_UnknownError,
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
};

pub fn init(comptime handler: HandlerFn, config: Config) Self {
    core.initialize(config.io);

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
            dispatch_async.run(self.config, self.handler) catch |err| {
                return dispatchError(err);
            };
        },
        .EPOLL => {
            @panic("TODO: ZIX Http1 server run .EPOLL");
        },
        .URING => {
            @panic("TODO: ZIX Http1 server run .URING");
        },
        else => Error.ZixHttp1_Server_DispatchModel_NotSupported,
    };
}

