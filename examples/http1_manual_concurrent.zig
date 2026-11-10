//! ZIX example http1 manual concurrent
//!
//! ### file: examples/http1_manual_concurrent.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that builds its own std.Io.Threaded to cap concurrency.
//!
//! ### note:
//!
//! main does not take std.process.Init, because the io is created here by hand.
//! .ASYNC runs each accepted connection through io.async(), so the cap is the io
//! async_limit (concurrent_limit only caps io.concurrent()). When the pool is
//! full, io.async() runs the connection inline on the accept loop, so up to
//! CONCURRENT_LIMIT + 1 connections run at once. .EPOLL and .URING ignore this
//! io limit: their worker count comes from WORKERS.
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
const PORT:u16 = 9030;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
const MAX_RECV_BUF:usize = 16 * 1024;
const COMPRESSION_MAX_OUT:usize = 256 * 1024;

/// Thread pool cap for io.async() (0 means unlimited).
const CONCURRENT_LIMIT:usize = 4;

// --------------------------------------------------------- //

// GET /
// curl usage: curl -X GET "http://localhost:9030/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("hello from zix http1 (manual concurrent)");
}

// GET /info
// Returns the limit set on the io.
// curl usage: curl -X GET "http://localhost:9030/info"
fn infoHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{{\"concurrent_limit\":{d}}}", .{CONCURRENT_LIMIT});

    try res.sendJson(msg);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/",
        .handler = homeHandler,
    },
    .{
        .path = "/info",
        .handler = infoHandler,
    },
});

pub fn main() !void {
    const limit: std.Io.Limit = if (CONCURRENT_LIMIT == 0)
        .unlimited
    else
        std.Io.Limit.limited(CONCURRENT_LIMIT);

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .async_limit = limit,
    });
    defer threaded.deinit();

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = threaded.io(),
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .dispatch_model = DISPATCH_MODEL,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
    });
    defer server.deinit();

    try server.run();
}

