//! zix http2 .ASYNC dispatch model.

const std = @import("std");
const core = @import("../core.zig");
const Http2ServerConfig = @import("../config.zig").Http2ServerConfig;
const common = @import("common.zig");
const logSystem = common.logSystem;

// --------------------------------------------------------- //
// ASYNC model

pub fn runAsync(handler: core.HandlerFn, cfg: Http2ServerConfig) !void {
    const io = cfg.io;
    const opts = common.serveOpts(cfg);

    logSystem(cfg, "listening on {s}:{d} (async)", .{ cfg.ip, cfg.port });

    const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
    var listener = try addr.listen(io, .{
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
        .kernel_backlog = cfg.kernel_backlog,
    });
    defer listener.deinit(io);

    while (true) {
        const stream = listener.accept(io) catch |err| {
            if (err != error.ConnectionAborted) {
                logSystem(cfg, "accept error: {}", .{err});
                break;
            }
            continue;
        };
        _ = io.async(common.dispatchConn, .{common.ConnTask{
            .fd = stream.socket.handle,
            .opts = opts,
            .handler = handler,
            .io = io,
        }});
    }
}
