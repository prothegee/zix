//! ZIX example http2 logger
//!
//! ### file: examples/http2_logger.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http2 (h2c) server example with the zix Logger attached (console and file output).
//!
//! ### note:
//!
//! The logger does not create its directory, so main creates LOG_DIR first.
//! The logger must outlive the server: it is declared first, so its deinit runs last.
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
const PORT:u16 = 9034;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http2.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

const LOG_DIR:[]const u8 = "./logs";
const LOG_FILE:[]const u8 = "http2";

// --------------------------------------------------------- //

// The access line for this request is written by the engine.
// curl usage: curl --http2-prior-knowledge "http://127.0.0.1:9034/"
fn homeHandler(_: *zix.Http2.Request, res: *zix.Http2.Response, _: *zix.Http2.Context) !void {
    try res.sendText("Hello, World!");
}

// Adds one system line next to the automatic access line.
// curl usage: curl --http2-prior-knowledge "http://127.0.0.1:9034/hello"
fn helloHandler(
    req: *zix.Http2.Request,
    res: *zix.Http2.Response,
    ctx: *zix.Http2.Context,
) !void {
    if (ctx.logger) |logger| {
        logger.system(.INFO, "example", "hello requested on stream {d}", .{ctx.sid});
    }

    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "Hello from {s}!", .{req.path});

    try res.sendText(text);
}

// --------------------------------------------------------- //

const Routes = zix.Http2.Router(&[_]zix.Http2.Route{
    .{
        .path = "/",
        .handler = homeHandler,
    },
    .{
        .path = "/hello",
        .handler = helloHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    try std.Io.Dir.cwd().createDirPath(init.io, LOG_DIR);

    var logger = try zix.Logger.init(std.heap.smp_allocator, .{
        .console = .ALWAYS,
        .console_min_level = .INFO,
        .save_path = LOG_DIR,
        .save_file = LOG_FILE,
        .save_min_level = .INFO,
    });
    defer {
        logger.flush();
        logger.deinit();
    }

    var server = zix.Http2.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .dispatch_model = DISPATCH_MODEL,
        .logger = &logger,
    });
    defer server.deinit();

    try server.run();
}

