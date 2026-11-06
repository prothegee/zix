//! ZIX Http1 connection
//!
//! ### file: src/zix/tcp/http1/connection.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Accept-side entry: install worker state and hand the fd to serve.
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
const handler = @import("handler.zig");
const compress = @import("compress.zig");
const head = @import("head.zig");
const header = @import("header.zig");
const serve = @import("serve.zig");
const ConnArgs = @import("ConnArgs.zig");
const ConnEntry = @import("ConnEntry.zig");

// --------------------------------------------------------- //
// Public:

// /// This pool thread's response cache, sized from the connection's config.
// fn threadCache(args: ConnArgs) ?*async_cache.ResponseCache {
//     return async_cache.forThisThread(.{
//         .max_entries = async_cache.effectiveEntries(
//             args.cache_max_entries,
//             args.cache_max_value_bytes,
//             args.cache_max_total_bytes,
//         ),
//         .max_value_bytes = args.cache_max_value_bytes,
//     });
// }

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
    head.setDateHeader(args.send_date_header);
    // TODO: install the static-serve root from args.public_dir when the
    // static module is ported.
    header.setMaxResponseHeaders(args.max_response_headers);
    handler.setAccessLogger(args.logger);
    compress.setCompression(args.compress, args.compression_min_size, args.compression_max_out);

    std.log.info("TODO: args.response_cache", .{});
    // if (args.response_cache) {
    //     if (threadCache(args)) |cache| cache.setCache(cache, args.cache_ttl_ms) else
    //         cache.setCache(null, 0);
    // } else {
    //     cache.setCache(null, 0);
    // }

    defer args.stream.close(args.io);

    const fd = args.stream.socket.handle;

    var guard: ?ConnEntry = null;
    if (args.registry) |registry| {
        guard = ConnEntry{ .fd = fd, .deadline = connDeadline(args.io, args.conn_timeout_ms) };
        registry.register(&guard.?, args.io) catch |err| switch (err) {
            error.ZixHttp1_ConnRegistry_OutOfMemory => return,
            error.ZixHttp1_ConnRegistry_ShutdownFailed => return,
        };
    }
    defer if (args.registry) |registry| registry.deregister(&guard.?, args.io);

    serve.serveConn(
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: connection, deadline is in the future" {
    const io = std.testing.io;
    const now = std.Io.Clock.Timestamp.now(io, .real);
    const deadline = connDeadline(io, 1000);

    try std.testing.expect(deadline.compare(.gt, now));
}

test "zix http1: connection, zero timeout deadline is now" {
    const io = std.testing.io;
    const now = std.Io.Clock.Timestamp.now(io, .real);
    const deadline = connDeadline(io, 0);

    try std.testing.expect(deadline.compare(.gte, now));
}

