//! zix http1 .ASYNC dispatch model.

const std = @import("std");
const Config = @import("../config.zig").Http1ServerConfig;
const core = @import("../core.zig");
const HandlerFn = core.HandlerFn;
const common = @import("common.zig");
const logSystem = common.logSystem;
const ConnArgs = common.ConnArgs;
const connEntry = common.connEntry;

// --------------------------------------------------------- //
// ASYNC model

pub fn runAsync(config: Config, handler: HandlerFn) !void {
    const io = config.io;
    const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
    var srv = try addr.listen(io, .{
        .mode = .stream,
        .kernel_backlog = config.kernel_backlog,
        .reuse_address = true,
    });
    defer srv.deinit(io);

    logSystem(config, "listening on {s}:{d} (io.async)", .{ config.ip, config.port });

    while (true) {
        const stream = srv.accept(io) catch continue;
        _ = io.async(connEntry, .{ConnArgs{ .stream = stream, .io = io, .handler = handler, .handler_timeout_ms = config.handler_timeout_ms, .send_date_header = config.send_date_header, .large_body_rcvbuf = config.large_body_rcvbuf, .public_dir = config.public_dir }});
    }
}
