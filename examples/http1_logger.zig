//! ZIX example http1 logger
//!
//! ### file: examples/http1_logger.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example with the zix Logger attached (console and file output).
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

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9029;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel = .ASYNC;

const LOG_DIR:[]const u8 = "./logs";
const LOG_FILE:[]const u8 = "http1";

// --------------------------------------------------------- //

// The access line for this request is written by the engine.
// curl usage: curl -X GET "http://localhost:9029/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("Hello, World!");
}

// Adds one system line next to the automatic access line.
// curl usage: curl -X GET "http://localhost:9029/hello?name=Alice"
fn helloHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const name = req.queryParam("name") orelse "world";

    if (ctx.logger) |logger| {
        logger.system(.INFO, "example", "hello requested by {s}", .{name});
    }

    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "Hello, {s}!", .{name});

    res.setContentType(.TEXT_PLAIN);

    try res.send(text);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
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

    var server = zix.Http1.Server.init(Routes.dispatch, .{
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

