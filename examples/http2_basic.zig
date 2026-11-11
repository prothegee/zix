//! ZIX example http2 basic
//!
//! ### file: examples/http2_basic.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Minimal Http2 (h2c, cleartext HTTP/2) server example with one route.
//!
//! ### note:
//!
//! h2c has no TLS, so a client must speak HTTP/2 from the first byte
//! (curl --http2-prior-knowledge) or ask for an h2c upgrade.
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
const PORT:u16 = 9065;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Http2.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

// --------------------------------------------------------- //

// curl usage: curl --http2-prior-knowledge "http://127.0.0.1:9065/"
// curl usage (h2c upgrade): curl --http2 "http://127.0.0.1:9065/"
fn homeHandler(_: *zix.Http2.Request, res: *zix.Http2.Response, _: *zix.Http2.Context) !void {
    try res.sendText("hello from zix h2c\n");
}

// --------------------------------------------------------- //

const Routes = zix.Http2.Router(&[_]zix.Http2.Route{
    .{
        .path = "/",
        .handler = homeHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Http2.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}

