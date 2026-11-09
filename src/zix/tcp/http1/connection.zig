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
const async_cache = @import("../../utils/cache/async.zig");
const cache = @import("cache.zig");
const handler = @import("handler.zig");
const compress = @import("compress.zig");
const head = @import("head.zig");
const header = @import("header.zig");
const serve = @import("serve.zig");
const Config = @import("Config.zig");
const ConnArgs = @import("ConnArgs.zig");
const ConnEntry = @import("ConnEntry.zig");

// --------------------------------------------------------- //
// Private:

/// Install this pool thread's response cache, or clear it when caching is off
/// or the cache could not be built.
///
/// Note:
/// - Only the cache size fields of the Config are read, so the address fields
///   are left empty.
/// - A held cache is kept from being freed until releaseCache() runs.
///
/// Param:
/// args - ConnArgs (cache knobs of this connection)
///
/// Return:
/// - bool (true when the connection holds the cache and must call releaseCache)
fn installCache(args: ConnArgs) bool {
    if (!args.cache_response) {
        cache.setCache(null, 0);

        return false;
    }

    const config: Config = .{
        .io = args.io,
        .ip = "",
        .port = 0,
        .dispatch_model = .ASYNC,
        .cache_max_entries = args.cache_max_entries,
        .cache_max_value_bytes = args.cache_max_value_bytes,
    };

    if (async_cache.acquire(config)) |resp_cache| {
        cache.setCache(resp_cache, args.cache_ttl_ms);
    } else {
        cache.setCache(null, 0);
    }

    return true;
}

/// Clear this thread's cache pointer and end the connection's hold.
fn releaseCache() void {
    cache.setCache(null, 0);
    async_cache.release();
}

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
    head.setDateHeader(args.send_date_header);
    // TODO: install the static-serve root from args.public_dir when the
    // static module is ported.
    header.setMaxResponseHeaders(args.max_response_headers);
    handler.setAccessLogger(args.logger);
    compress.setCompression(args.compress, args.compression_min_size, args.compression_max_out);

    const cache_held = installCache(args);
    defer if (cache_held) releaseCache();

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

const ServeOpts = @import("ServeOpts.zig");
const pair = @import("../../utils/socket/pair.zig");

fn probeHandler(
    _: *@import("Request.zig"),
    _: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {}

fn testArgs(cache_on: bool) ConnArgs {
    return .{
        .io = std.testing.io,
        .stream = undefined,
        .handler = probeHandler,
        .cache_response = cache_on,
        .cache_ttl_ms = 2500,
        .cache_max_entries = 8,
        .cache_max_value_bytes = 1024,
    };
}

/// Runs installCache on its own thread, so the threadlocal cache slots die
/// with that thread instead of leaking into later tests.
const InstallProbe = struct {
    installed: bool = false,
    ttl_ms: u32 = 0,

    fn run(self: *InstallProbe, cache_on: bool) void {
        const cache_held = installCache(testArgs(cache_on));

        self.installed = cache.tl_cache != null;
        self.ttl_ms = cache.cacheTtl();

        if (cache_held) releaseCache();
    }
};

/// Slow-path count of cachedHandler. A cache hit returns before it counts.
var cached_miss_count: usize = 0;

/// Exact wire bytes cachedHandler answers with, on a miss and on a hit.
const CACHED_RESPONSE =
    "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\n" ++
    "Content-Length: 6\r\n\r\ncached";

fn cachedHandler(
    req: *@import("Request.zig"),
    res: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {
    if (try res.sendFromCache(req)) return;

    cached_miss_count += 1;
    res.setContentType(.TEXT_PLAIN);

    try res.sendCached(req, "cached", 60_000);
}

/// Serves one connection the way connEntry does on a .ASYNC pool thread:
/// install the thread cache, then hand the fd to serve. Runs on its own
/// thread so the threadlocal slots die with it.
const ServeProbe = struct {
    fn run(fd: std.posix.fd_t) void {
        head.setDateHeader(false);

        const cache_held = installCache(testArgs(true));
        defer if (cache_held) releaseCache();

        serve.serveConn(
            fd,
            cachedHandler,
            .{
                .max_recv_buf = ServeOpts.BUF_SIZE,
            },
            std.testing.io,
        );
    }
};

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

test "zix http1: connection, installCache sets the thread cache when on" {
    var probe: InstallProbe = .{};

    const thread = try std.Thread.spawn(.{}, InstallProbe.run, .{ &probe, true });
    thread.join();

    try std.testing.expect(probe.installed);
    try std.testing.expectEqual(@as(u32, 2500), probe.ttl_ms);
    try std.testing.expectEqual(@as(usize, 1), async_cache.reclaim());
}

test "zix http1: connection, installCache clears the thread cache when off" {
    var probe: InstallProbe = .{};

    const thread = try std.Thread.spawn(.{}, InstallProbe.run, .{ &probe, false });
    thread.join();

    try std.testing.expect(!probe.installed);
    try std.testing.expectEqual(@as(usize, 0), async_cache.reclaim());
}

test "zix http1: connection, serves a miss then a hit from the response cache" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    cached_miss_count = 0;

    const request =
        "GET /cached HTTP/1.1\r\nConnection: keep-alive\r\n\r\n" ++
        "GET /cached HTTP/1.1\r\nConnection: close\r\n\r\n";
    try std.testing.expectEqual(
        @as(usize, request.len),
        std.posix.system.write(fds[0], request.ptr, request.len),
    );

    const thread = try std.Thread.spawn(.{}, ServeProbe.run, .{fds[1]});
    thread.join();
    _ = std.posix.system.close(fds[1]);

    var out: [1024]u8 = undefined;
    var len: usize = 0;
    while (len < out.len) {
        const count = try std.posix.read(fds[0], out[len..]);
        if (count == 0) break;

        len += count;
    }

    try std.testing.expectEqual(@as(usize, 1), async_cache.reclaim());
    try std.testing.expectEqual(@as(usize, 1), cached_miss_count);
    try std.testing.expectEqual(CACHED_RESPONSE.len * 2, len);
    try std.testing.expectEqualStrings(CACHED_RESPONSE, out[0..CACHED_RESPONSE.len]);
    try std.testing.expectEqualStrings(CACHED_RESPONSE, out[CACHED_RESPONSE.len..len]);
}

