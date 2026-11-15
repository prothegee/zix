//! ZIX example tls http2 basic
//!
//! ### file: examples/tls/tls_http2_basic.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! HTTP/2 over TLS (h2) with an ECDSA P-256 certificate, one route.
//!
//! ### note:
//!
//! The TLS context must offer ALPN h2. .EPOLL and .URING terminate TLS 1.3 in
//! the event loop. .ASYNC also serves TLS 1.2 clients.
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
const PORT:u16 = 9061;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Http2.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
// Demo certificate (SAN localhost, 127.0.0.1). For a real domain, point CERT and
// KEY at the certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT:[]const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY:[]const u8 = "examples/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

// curl usage: curl -k --http2 "https://localhost:9061/"
fn homeHandler(_: *zix.Http2.Request, res: *zix.Http2.Response, _: *zix.Http2.Context) !void {
    try res.sendText("hello over h2 tls\n");
}

// --------------------------------------------------------- //

const Routes = zix.Http2.Router(&[_]zix.Http2.Route{
    .{
        .path = "/",
        .handler = homeHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    var tls = try zix.tlz.Context.init(std.heap.smp_allocator, init.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.H2},
    });
    defer tls.deinit();

    var server = zix.Http2.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        .workers = WORKERS,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}

