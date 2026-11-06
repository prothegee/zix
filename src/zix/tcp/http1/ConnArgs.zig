//! ZIX Http1 ConnArgs
//!
//! ### file: src/zix/tcp/http1/ConnArgs.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Everything one accepted connection needs to be served.
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
const HandlerFn = @import("handler.zig").HandlerFn;
const ConnRegistry = @import("ConnRegistry.zig");
const BUF_SIZE = @import("ServeOpts.zig").BUF_SIZE;
const Logger = @import("../../logger/Logger.zig");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
stream: std.Io.net.Stream,
handler: HandlerFn,
handler_timeout_ms: u32 = 0,
conn_timeout_ms: u32 = 0,
registry: ?*ConnRegistry = null,
send_date_header: bool = true,
large_body_recv_buf: usize = 0,
max_recv_buf: usize = BUF_SIZE,
max_request_body: usize = 0,
max_response_headers: usize = 16, // TODO: check max header config
public_dir: []const u8 = "",
logger: ?*Logger = null,
compress: bool = false,
compression_min_size: usize = 256,
compression_max_out: usize = 256 * 1024,
cache_response: bool = false,
cache_ttl_ms: u32 = 0,
cache_max_entries: u32 = 256,
cache_max_value_bytes: u32 = 16 * 1024,
cache_max_total_bytes: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Context = @import("Context.zig");

fn mockHandler(_: *Request, _: *Response, _: *Context) anyerror!void {}

test "zix http1: ConnArgs, applies defaults" {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const args: @This() = .{
        .io = std.testing.io,
        .stream = .{ .socket = .{ .handle = -1, .address = address } },
        .handler = mockHandler,
    };

    try std.testing.expectEqual(BUF_SIZE, args.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 16), args.max_response_headers);
    try std.testing.expect(args.send_date_header);
    try std.testing.expect(!args.compress);
    try std.testing.expect(!args.cache_response);
    try std.testing.expectEqual(@as(?*Logger, null), args.logger);
}

test "zix http1: ConnArgs, keeps explicit knobs" {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const args: @This() = .{
        .io = std.testing.io,
        .stream = .{ .socket = .{ .handle = -1, .address = address } },
        .handler = mockHandler,
        .max_recv_buf = 4096,
        .max_request_body = 1024,
        .send_date_header = false,
        .compress = true,
        .compression_min_size = 512,
    };

    try std.testing.expectEqual(@as(usize, 4096), args.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 1024), args.max_request_body);
    try std.testing.expect(!args.send_date_header);
    try std.testing.expect(args.compress);
    try std.testing.expectEqual(@as(usize, 512), args.compression_min_size);
}

