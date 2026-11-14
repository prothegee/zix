//! ZIX example tls http1 dual
//!
//! ### file: examples/tls/tls_http1_dual.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One server serves cleartext http/1.1 on PORT and https/1.1 on TLS_PORT.
//!
//! ### note:
//!
//! .EPOLL and .URING host both sides in the same workers. .ASYNC serves the
//! https side from one extra accept thread.
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
const PORT:u16 = 9076;
const TLS_PORT:u16 = 9077;
const WORKERS:usize = 1;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
// Demo certificate (SAN localhost, 127.0.0.1). For a real domain, point CERT and
// KEY at the certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT:[]const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY:[]const u8 = "examples/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

// curl usage: curl "http://localhost:9076/"
// curl usage: curl -k "https://localhost:9077/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("hello from the dual listener\n");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/",
        .handler = homeHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    var tls = try zix.tlz.Context.init(std.heap.smp_allocator, init.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
    });
    defer tls.deinit();

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        .tls_port = TLS_PORT,
        .workers = WORKERS,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}

