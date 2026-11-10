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
const async_cache = @import("../../../utils/cache/async.zig");
const conn = @import("../connection.zig");
const ConnArgs = @import("../ConnArgs.zig");
const log = @import("../log.zig");
const connEntry = conn.connEntry;

// --------------------------------------------------------- //
// Private:

/// Map the server Config onto the per-connection args of one accepted stream.
///
/// Param:
/// config - Config (server configuration)
/// handler - HandlerFn (top-level handler)
/// stream - std.Io.net.Stream (the accepted connection)
///
/// Return:
/// - ConnArgs
fn connArgs(config: Config, handler: HandlerFn, stream: std.Io.net.Stream) ConnArgs {
    return .{
        .io = config.io,
        .stream = stream,
        .handler = handler,
        .logger = config.logger,
        .handler_timeout_ms = config.handler_timeout_ms,
        .send_date_header = config.send_date_header,
        .large_body_recv_buf = config.large_body_recv_buf,
        .max_recv_buf = config.recvBufSize(),
        .max_request_body = config.max_request_body,
        .ws_recv_buf = config.wsRecvBufSize(),
        .max_response_headers = config.max_response_headers.value(),
        .public_dir = config.public_dir,
        .compress = config.compress,
        .compression_min_size = config.compression_min_size,
        .compression_max_out = config.compression_max_out,
        .cache_response = config.response_cache,
        .cache_ttl_ms = config.cache_ttl_ms,
        .cache_max_entries = config.cache_max_entries,
        .cache_max_value_bytes = config.cache_max_value_bytes,
    };
}

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

    // Frees the per-thread response caches, now or when the last open
    // connection ends.
    defer _ = async_cache.reclaim();

    std.log.info("TODO: connection registry & timeout", .{});

    std.log.info("TODO: connection timeout sweep, timer, & detach", .{});

    log.logSystem(
        config,
        .INFO,
        "listening on {s}:{d} (io.async)",
        .{ config.ip, config.port },
    );

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            else => return Error.ZixHttp1_Async_AcceptFailed,
        };
        _ = io.async(connEntry, .{connArgs(config, handler, stream)});
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const Context = @import("../Context.zig");

fn mockHandler(_: *Request, _: *Response, _: *Context) anyerror!void {}

fn testStream() !std.Io.net.Stream {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);

    return .{
        .socket = .{
            .handle = -1,
            .address = address,
        },
    };
}

fn testConfig() Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
    };
}

test "zix http1: async, connArgs carries the request knobs" {
    var config = testConfig();
    config.handler_timeout_ms = 250;
    config.send_date_header = false;
    config.large_body_recv_buf = 1 << 20;
    config.max_recv_buf = 2 * 1024 * 1024;
    config.max_request_body = 3 * 1024 * 1024;
    config.max_response_headers = .LARGE;
    config.ws_recv_buf = 32 * 1024;

    const args = connArgs(config, mockHandler, try testStream());

    try std.testing.expectEqual(@as(u32, 250), args.handler_timeout_ms);
    try std.testing.expect(!args.send_date_header);
    try std.testing.expectEqual(@as(usize, 1 << 20), args.large_body_recv_buf);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), args.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 3 * 1024 * 1024), args.max_request_body);
    try std.testing.expectEqual(@as(usize, 64), args.max_response_headers);
    try std.testing.expectEqual(@as(usize, 32 * 1024), args.ws_recv_buf);
}

test "zix http1: async, connArgs carries the compression knobs" {
    var config = testConfig();
    config.compress = true;
    config.compression_min_size = 512;
    config.compression_max_out = 1024;

    const args = connArgs(config, mockHandler, try testStream());

    try std.testing.expect(args.compress);
    try std.testing.expectEqual(@as(usize, 512), args.compression_min_size);
    try std.testing.expectEqual(@as(usize, 1024), args.compression_max_out);
}

test "zix http1: async, connArgs carries the cache knobs" {
    var config = testConfig();
    config.response_cache = true;
    config.cache_ttl_ms = 5000;
    config.cache_max_entries = 64;
    config.cache_max_value_bytes = 4096;

    const args = connArgs(config, mockHandler, try testStream());

    try std.testing.expect(args.cache_response);
    try std.testing.expectEqual(@as(u32, 5000), args.cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 64), args.cache_max_entries);
    try std.testing.expectEqual(@as(u32, 4096), args.cache_max_value_bytes);
}

test "zix http1: async, connArgs carries the public dir" {
    var config = testConfig();
    config.public_dir = "public";

    const args = connArgs(config, mockHandler, try testStream());

    try std.testing.expectEqualStrings("public", args.public_dir);
}

test "zix http1: async, connArgs falls back on a zero recv buffer" {
    var config = testConfig();
    config.max_recv_buf = 0;

    const args = connArgs(config, mockHandler, try testStream());

    try std.testing.expectEqual(config.recvBufSize(), args.max_recv_buf);
}

test "zix http1: async, connArgs keeps the default body limit" {
    const args = connArgs(testConfig(), mockHandler, try testStream());

    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), args.max_request_body);
}

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

