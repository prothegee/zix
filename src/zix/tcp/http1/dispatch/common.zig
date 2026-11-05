//! ZIX Http1 dispatch common
//!
//! ### file: src/zix/tcp/http1/dispatch/common.zig
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
const core = @import("../core.zig");
const ConnArgs = @import("../ConnArgs.zig");
const ConnEntry = @import("../ConnEntry.zig");

// --------------------------------------------------------- //
// Private:

// /// This pool thread's response cache, sized from the connection's config.
// fn threadCache(args: ConnArgs) ?*async_cache.ResponseCache {
//     return async_cache.forThisThread(.{
//         .max_entries = async_cache.effectiveEntries(args.cache_max_entries, args.cache_max_value_bytes, args.cache_max_total_bytes),
//         .max_value_bytes = args.cache_max_value_bytes,
//     });
// }

// --------------------------------------------------------- //
// Public:

/// The wall-clock deadline for a connection accepted now.
pub fn connDeadline(io: std.Io, timeout_ms: u32) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(
        io,
        std.Io.Clock.Duration{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .real 
        },
    );
}

pub fn connEntry(args: ConnArgs) void {
    core.setDateHeader(args.send_date_header);
    core.setStatic(args.public_dir, args.io);
    core.setMaxResponseHeaders(args.max_response_headers);
    std.log.info("TODO: core.setAccessLogger", .{});
    core.setCompression(args.compress, args.compression_min_size, args.compression_max_out);

    std.log.info("TODO: args.response_cache", .{});
    // if (args.response_cache) {
    //     if (threadCache(args)) |cache| core.setCache(cache, args.cache_ttl_ms) else
    //         core.setCache(null, 0);
    // } else {
    //     core.setCache(null, 0);
    // }

    defer args.stream.close(args.io);

    const fd = args.stream.socket.handle;

    var guard: ?ConnEntry = null;
    if (args.registry) |registry| {
        guard = ConnEntry{ .fd = fd, .deadline = connDeadline(args.io, args.conn_timeout_ms) };
        registry.register(&guard.?, args.io);
    }
    defer if (args.registry) |registry| registry.deregister(&guard.?, args.io);

    core.serveConn(
        fd,
        args.handler,
        .{
            .handler_timeout_ms = args.handler_timeout_ms,
            .large_body_recv_buf = args.large_body_recv_buf,
            .max_recv_buf = args.max_recv_buf,
            .max_request_body = args.max_request_body,
        },
        args.io,
    );
}

