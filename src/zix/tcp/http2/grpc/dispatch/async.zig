//! ZIX Http2 Grpc dispatch async
//!
//! ### file: src/zix/tcp/http2/grpc/dispatch/async.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Async model: accept loop handing each gRPC h2c connection to a pool thread.
//!
//! ### note:
//!
//! The Router is a comptime type, so the accept loop and the connection
//! entry are built per Router.
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
const async_cache = @import("../../../../utils/cache/async.zig");
const cache = @import("../cache.zig");
const h2_cache = @import("../../cache.zig");
const log = @import("../log.zig");
const serve = @import("../serve.zig");
const CacheSize = @import("../../../../utils/cache/CacheSize.zig");
const Config = @import("../Config.zig");
const ServeOpts = @import("../ServeOpts.zig");

// --------------------------------------------------------- //
// Private:

/// Install this pool thread's response cache, or clear it when caching is off
/// or the cache could not be built.
///
/// Note:
/// - A held cache is kept from being freed until releaseCache() runs.
///
/// Param:
/// opts - ServeOpts (cache knobs of this connection)
///
/// Return:
/// - bool (true when the connection holds the cache and must call releaseCache)
fn installCache(opts: ServeOpts) bool {
    if (!opts.response_cache) {
        cache.setCache(null, 0);

        return false;
    }

    const size: CacheSize = .{
        .max_entries = h2_cache.effectiveCacheEntries(
            opts.cache_max_entries,
            opts.cache_max_value_bytes,
            opts.cache_max_total_bytes,
        ),
        .max_value_bytes = opts.cache_max_value_bytes,
    };

    if (async_cache.acquire(size)) |resp_cache| {
        cache.setCache(resp_cache, opts.cache_ttl_ms);
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

/// The pool-thread entry for one Router. io.async takes a plain function, so
/// the comptime Router is bound here instead of passed as an argument.
fn ConnEntry(comptime RouterType: type) type {
    return struct {
        /// Serve one accepted connection on a pool thread, then close it.
        ///
        /// Param:
        /// stream - std.Io.net.Stream (the accepted connection, closed on return)
        /// opts - ServeOpts (per-connection serve knobs)
        /// io - std.Io (the worker io)
        ///
        /// Return:
        /// - void
        fn serveOne(stream: std.Io.net.Stream, opts: ServeOpts, io: std.Io) void {
            const cache_held = installCache(opts);
            defer if (cache_held) releaseCache();

            defer stream.close(io);

            serve.serveConn(RouterType, stream.socket.handle, opts, io);
        }
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc async dispatch error
pub const Error = error {
    ZixHttp2_GrpcAsync_ResolveFailed,
    ZixHttp2_GrpcAsync_ListenFailed,
    ZixHttp2_GrpcAsync_AcceptFailed,
};

/// Listen and hand every accepted connection to io.async.
///
/// Note:
/// - A peer that drops before accept (ConnectionAborted) is skipped. Any
///   other accept failure ends the loop.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// config - Config (server configuration)
///
/// Return:
/// - void
/// - Error.ZixHttp2_GrpcAsync_ResolveFailed when config.ip does not resolve
/// - Error.ZixHttp2_GrpcAsync_ListenFailed when the address cannot be bound
/// - Error.ZixHttp2_GrpcAsync_AcceptFailed when accept fails for good
pub fn run(comptime RouterType: type, config: Config) Error!void {
    const io = config.io;
    const opts = config.serveOpts();
    const address = std.Io.net.IpAddress.resolve(
        io,
        config.ip,
        config.port,
    ) catch |err| switch (err) {
        else => return Error.ZixHttp2_GrpcAsync_ResolveFailed,
    };
    var server = address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = config.kernel_backlog,
    }) catch |err| switch (err) {
        else => return Error.ZixHttp2_GrpcAsync_ListenFailed,
    };
    defer server.deinit(io);

    // Frees the per-thread response caches, now or when the last open
    // connection ends.
    defer _ = async_cache.reclaim();

    log.logSystem(
        config,
        .INFO,
        "listening on {s}:{d} (io.async)",
        .{ config.ip, config.port },
    );

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return Error.ZixHttp2_GrpcAsync_AcceptFailed,
        };
        _ = io.async(ConnEntry(RouterType).serveOne, .{ stream, opts, io });
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const frame = @import("../../frame.zig");
const pair = @import("../../../../utils/socket/pair.zig");
const router = @import("../router.zig");
const writer = @import("../../writer.zig");
const Context = @import("../Context.zig");
const Header = @import("../../hpack/Header.zig");
const HpackDecoder = @import("../../hpack/HpackDecoder.zig");
const HpackEncoder = @import("../../hpack/HpackEncoder.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");

/// Handler calls seen by okHandler.
var ok_calls: usize = 0;

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    ok_calls += 1;

    try res.finish(.OK, "");
}

const TestRouter = router.Router(&[_]router.Route{
    .{
        .path = "/svc.Svc/Method",
        .handler = okHandler,
    },
});

fn testConfig() Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
    };
}

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

/// Write one complete frame the way a client would.
fn writeFrameTo(
    fd: std.posix.fd_t,
    frame_type: u8,
    flags: u8,
    sid: u31,
    payload: []const u8,
) !void {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&buf, .{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = sid,
    });

    try writer.writeAllDirectFD(fd, &buf);
    if (payload.len > 0) try writer.writeAllDirectFD(fd, payload);
}

/// Read until EOF and count the grpc-status 0 trailers on stream 1.
fn countStatusOk(fd: std.posix.fd_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const got = std.posix.read(fd, buf[total..]) catch break;
        if (got == 0) break;

        total += got;
    }

    var decoder = HpackDecoder.init();
    var count: usize = 0;
    var pos: usize = 0;

    while (pos + frame.FRAME_HEADER_LEN <= total) {
        const header = frame.parseFrameHeader(buf[pos..][0..frame.FRAME_HEADER_LEN]);
        pos += frame.FRAME_HEADER_LEN;
        if (pos + header.length > total) break;

        const payload = buf[pos..][0..header.length];
        pos += header.length;

        if (header.frame_type != frame.FRAME_TYPE_HEADERS) continue;
        if (header.stream_id != 1) continue;

        var headers: [frame.MAX_HEADERS]Header = undefined;
        var scratch: [256]u8 = undefined;
        const decoded = decoder.decode(payload, &headers, &scratch) catch continue;

        for (headers[0..decoded]) |entry| {
            const is_ok =
                std.mem.eql(u8, entry.name, "grpc-status") and
                std.mem.eql(u8, entry.value, "0");
            if (is_ok) count += 1;
        }
    }

    return count;
}

/// Runs installCache on its own thread, so the threadlocal cache slots die
/// with that thread instead of leaking into later tests.
const InstallProbe = struct {
    installed: bool = false,
    held: bool = false,
    ttl_ms: u32 = 0,

    fn run(self: *InstallProbe, opts: ServeOpts) void {
        self.held = installCache(opts);
        self.installed = cache.tl_cache != null;
        self.ttl_ms = cache.cacheTtl();

        if (self.held) releaseCache();
    }
};

test "zix http2 grpc: async, installCache off clears the cache" {
    var probe: InstallProbe = .{};
    const thread = try std.Thread.spawn(.{}, InstallProbe.run, .{ &probe, ServeOpts{} });
    thread.join();

    try std.testing.expect(!probe.held);
    try std.testing.expect(!probe.installed);
    try std.testing.expectEqual(@as(u32, 0), probe.ttl_ms);
}

test "zix http2 grpc: async, installCache on installs the cache" {
    const opts: ServeOpts = .{
        .response_cache = true,
        .cache_max_entries = 8,
        .cache_max_value_bytes = 1024,
        .cache_ttl_ms = 2500,
    };

    var probe: InstallProbe = .{};
    const thread = try std.Thread.spawn(.{}, InstallProbe.run, .{ &probe, opts });
    thread.join();
    _ = async_cache.reclaim();

    try std.testing.expect(probe.held);
    try std.testing.expect(probe.installed);
    try std.testing.expectEqual(@as(u32, 2500), probe.ttl_ms);
}

test "zix http2 grpc: async, ConnEntry serves one connection end to end" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var block: [128]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "POST");
    try encoder.writeHeader(":path", "/svc.Svc/Method");

    const empty_message = [_]u8{ 0, 0, 0, 0, 0 };
    const block_flags = frame.FLAG_END_HEADERS;

    try writer.writeAllDirectFD(fds[0], frame.PREFACE);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_SETTINGS, 0, 0, "");
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, block_flags, 1, encoder.encoded());
    try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &empty_message);
    _ = std.os.linux.shutdown(fds[0], std.os.linux.SHUT.WR);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const stream: std.Io.net.Stream = .{
        .socket = .{
            .handle = fds[1],
            .address = address,
        },
    };

    ok_calls = 0;
    ConnEntry(TestRouter).serveOne(stream, .{}, std.testing.io);

    var buf: [8192]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 1), countStatusOk(fds[0], &buf));
    try std.testing.expectEqual(@as(usize, 1), ok_calls);
}

test "zix http2 grpc: async, run with an unresolvable ip is ResolveFailed" {
    var config = testConfig();
    config.ip = "not-an-ip";

    try std.testing.expectError(Error.ZixHttp2_GrpcAsync_ResolveFailed, run(TestRouter, config));
}

