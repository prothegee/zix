//! ZIX example http1 compression
//!
//! ### file: examples/http1_compression.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that compresses responses with gzip, deflate, or br.
//!
//! ### note:
//!
//! /data and /ping negotiate from Accept-Encoding through res.sendNegotiated.
//! /gzip, /deflate, and /br force one coding for demonstration only.
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
const zix = @import("zix");

const builtin = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9058;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
const MAX_RECV_BUF:usize = 16 * 1024;
const COMPRESSION_MIN_SIZE:usize = 256;
const COMPRESSION_MAX_OUT:usize = 256 * 1024;

// --------------------------------------------------------- //

/// One paragraph of the demo body.
const PARAGRAPH: []const u8 =
    \\zix response compression demo. This body is served through
    \\res.sendNegotiated, which reads the request Accept-Encoding header and
    \\compresses with brotli, gzip, or deflate when the client accepts a coding,
    \\the body clears the size floor, and the compressed result is smaller than
    \\the original. Repetitive text like this compresses well, so the payload
    \\shrinks while the handler stays a single sendNegotiated call. Without a
    \\matching Accept-Encoding the same bytes are sent uncompressed.
;

/// Every coding adds a fixed header, so the paragraph repeats to stay smaller.
const BODY: []const u8 = PARAGRAPH ++ "\n\n" ++ PARAGRAPH ++ "\n\n" ++ PARAGRAPH;

/// Send BODY in one forced coding, ignoring Accept-Encoding.
fn serveCoding(
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
    encoding: zix.utils.compression.Encoding,
) !void {
    const encoded = zix.utils.compression.encode(ctx.allocator, encoding, BODY, .DEFAULT) catch
        |err| switch (err) {
            else => {
                res.setStatus(.INTERNAL_SERVER_ERROR);
                res.setContentType(.TEXT_PLAIN);

                return res.send("encode failed");
            },
        };
    defer ctx.allocator.free(encoded);

    res.setContentType(.TEXT_PLAIN);
    try res.addHeader("Content-Encoding", encoding.contentEncoding().?);
    try res.addHeader("Vary", "Accept-Encoding");

    try res.send(encoded);
}

// GET /data
// Picks br, gzip, or deflate from Accept-Encoding, or identity when none fits.
// curl usage: curl --compressed -v "http://localhost:9058/data"
// curl usage: curl -H "Accept-Encoding: br" -v "http://localhost:9058/data"
// curl usage: curl -H "Accept-Encoding: gzip" -v "http://localhost:9058/data"
// curl usage: curl -H "Accept-Encoding: deflate" -v "http://localhost:9058/data"
fn dataHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.send("method not allowed");
        return;
    }

    try res.sendNegotiated(req, BODY);
}

// GET /ping
// The body is under COMPRESSION_MIN_SIZE, so it is always sent uncompressed.
// curl usage: curl -H "Accept-Encoding: gzip" -v "http://localhost:9058/ping"
fn pingHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.sendNegotiated(req, "pong");
}

// GET /gzip
// curl usage: curl -s "http://localhost:9058/gzip" | gunzip
fn gzipHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    try serveCoding(res, ctx, .GZIP);
}

// GET /deflate
// curl usage: curl -s "http://localhost:9058/deflate" | zlib-flate -uncompress
fn deflateHandler(
    _: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    try serveCoding(res, ctx, .DEFLATE);
}

// GET /br
// curl usage: curl -s "http://localhost:9058/br" | brotli -d
fn brHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    try serveCoding(res, ctx, .BR);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/data",
        .handler = dataHandler,
    },
    .{
        .path = "/ping",
        .handler = pingHandler,
    },
    .{
        .path = "/gzip",
        .handler = gzipHandler,
    },
    .{
        .path = "/deflate",
        .handler = deflateHandler,
    },
    .{
        .path = "/br",
        .handler = brHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .dispatch_model = DISPATCH_MODEL,
        .max_recv_buf = MAX_RECV_BUF,
        .compress = true,
        .compression_min_size = COMPRESSION_MIN_SIZE,
        .compression_max_out = COMPRESSION_MAX_OUT,
    });
    defer server.deinit();

    try server.run();
}

