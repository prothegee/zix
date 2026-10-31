//! ZIX example http1 basic
//!
//! ### file: /home/pr/repo/zix/examples/http1_basic.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! n/a
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
const zix = @import("zix");

const builtint = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9015;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtint.os.tag == .linux) .URING else .ASYNC;

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9015/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("Hello, World!");
}

// curl usage: curl -X GET "http://localhost:9015/echo"
fn echoHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    try res.sendJson("{\"status\":\"ok\"}");
}

// curl usage: curl -X GET "http://localhost:9015/about"
fn aboutHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("zix http1 basic server example");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/about", .handler = aboutHandler },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = "",
        .port = PORT,
        .workers = WORKERS,
        // Checked:
        // - [ ] ASYNC
        // - [ ] EPOLL
        // - [ ] URING
        .dispatch_model = .ASYNC,
    });
    defer server.deinit();

    try server.run();
}
