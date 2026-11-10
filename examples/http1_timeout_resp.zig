//! ZIX example http1 timeout resp
//!
//! ### file: examples/http1_timeout_resp.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that answers 408 when a handler runs past its budget.
//!
//! ### note:
//!
//! handler_timeout_ms arms a deadline before each handler call. Nothing is
//! interrupted: a handler checks zix.Http1.isExpired() or ctx.isExpired()
//! between steps and answers early.
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
const PORT:u16 = 9025;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
const HANDLER_TIMEOUT_MS:u32 = 5_000;

// --------------------------------------------------------- //

/// Sleep on the worker io to stand in for slow work.
fn simulateWork(ctx: *zix.Http1.Context, ms: i64) void {
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(ms), .awake) catch |err| switch (err) {
        // A canceled sleep only ends the simulated work early.
        else => {},
    };
}

// GET /slow
// Two steps of 3s each (6s total). With a 5s budget, step 2 trips the
// server-armed deadline through zix.Http1.isExpired().
// curl usage: curl http://localhost:9025/slow
fn slowHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    simulateWork(ctx, 3_000);
    if (zix.Http1.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);

        try res.sendJson("{\"error\":\"timeout\",\"step\":1}");
        return;
    }

    simulateWork(ctx, 3_000);
    if (zix.Http1.isExpired()) {
        res.setStatus(.REQUEST_TIMEOUT);

        try res.sendJson("{\"error\":\"timeout\",\"step\":2}");
        return;
    }

    try res.sendJson("{\"result\":\"ok\"}");
}

// GET /custom
// ctx.setTimeout gives this handler a shorter 2s window on the context
// deadline, independent of the server-wide 5s budget.
// curl usage: curl http://localhost:9025/custom
fn customTimeoutHandler(
    _: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    ctx.setTimeout(2_000);

    simulateWork(ctx, 1_500);
    if (ctx.timedOut()) {
        res.setStatus(.REQUEST_TIMEOUT);

        try res.sendJson("{\"error\":\"timeout\",\"handler\":\"custom\"}");
        return;
    }

    try res.sendJson("{\"result\":\"ok\",\"handler\":\"custom\"}");
}

// GET /ping
// Fast handler to confirm other requests are served normally.
// curl usage: curl http://localhost:9025/ping
fn pingHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    try res.sendJson("{\"result\":\"pong\"}");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/slow",
        .handler = slowHandler,
    },
    .{
        .path = "/custom",
        .handler = customTimeoutHandler,
    },
    .{
        .path = "/ping",
        .handler = pingHandler,
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
        .handler_timeout_ms = HANDLER_TIMEOUT_MS,
    });
    defer server.deinit();

    try server.run();
}

