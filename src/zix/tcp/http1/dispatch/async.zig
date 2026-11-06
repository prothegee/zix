//! ZIX Http1 dispatch async model
//!
//! ### file: src/zix/tcp/http1/dispatch/async.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Async model: accept loop handing connections to pool threads.
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
const Config = @import("../Config.zig");
const HandlerFn = @import("../handler.zig").HandlerFn;
const conn = @import("../connection.zig");
const ConnArgs = @import("../ConnArgs.zig");
const connEntry = @import("common.zig").connEntry;

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 async dispatch error
pub const Error = error {
    ZixHttp1_Async_ResolveFailed,
    ZixHttp1_Async_ListenFailed,
    ZixHttp1_Async_AcceptFailed,
};

pub fn run(config: Config, handler: HandlerFn) Error!void {
    const io = config.io;
    const address = std.Io.net.IpAddress.resolve(
        io, config.ip, config.port,
    ) catch |err| switch (err) {
        else => return Error.ZixHttp1_Async_ResolveFailed,
    };
    var server = address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = config.kernel_backlog,
    }) catch |err| switch (err) {
        else => return Error.ZixHttp1_Async_ListenFailed,
    };
    defer server.deinit(io);

    std.log.info("TODO: async dispatch cache reclaim", .{});

    std.log.info("TODO: connection registry & timeout", .{});

    std.log.info("TODO: connection timeout sweep, timer, & detach", .{});

    std.log.info(
        \\TODO: log debug info for ip:port dispatch model.
        \\listening on {s}:{d} (io.async)
        ,
        .{ config.ip, config.port }
    );

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            else => return Error.ZixHttp1_Async_AcceptFailed,
        };
        _ = io.async(connEntry, .{ConnArgs{
            .io = io,
            .stream = stream,
            .handler = handler,
        }});
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const Context = @import("../Context.zig");

test "zix http1: async, run has the dispatch signature" {
    const info = @typeInfo(@TypeOf(run)).@"fn";

    try std.testing.expectEqual(@as(usize, 2), info.param_types.len);
    try std.testing.expect(info.param_types[0].? == Config);
    try std.testing.expect(info.param_types[1].? == HandlerFn);

    const ret = @typeInfo(info.return_type.?);
    try std.testing.expect(std.meta.activeTag(ret) == .error_union);
    try std.testing.expect(std.meta.activeTag(@typeInfo(ret.error_union.payload)) == .void);
}

test "zix http1: async, handler type is the shared contract" {
    const Expected = *const fn (*Request, *Response, *Context) anyerror!void;

    try std.testing.expect(HandlerFn == Expected);
}

