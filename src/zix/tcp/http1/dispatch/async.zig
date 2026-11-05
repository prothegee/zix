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
const Config = @import("../Config.zig");
const HandlerFn = @import("../core.zig").HandlerFn;
const conn = @import("../connection.zig");
const ConnArgs = @import("../ConnArgs.zig");
const connEntry = @import("common.zig").connEntry;

// --------------------------------------------------------- //
// Public:

pub fn run(config: Config, handler: HandlerFn) !void {
    const io = config.io;
    const address = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
    var server = try address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = config.kernel_backlog,
    });
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
        const stream = server.accept(io) catch continue;
        _ = io.async(connEntry, .{ConnArgs{
            .io = io,
            .stream = stream,
            .handler = handler,
        }});
    }
}

