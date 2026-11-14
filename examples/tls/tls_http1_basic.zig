//! ZIX example tls http1 basic
//!
//! ### file: examples/tls/tls_http1_basic.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! https/1.1 over TLS with an ECDSA P-256 certificate, one route.
//!
//! ### note:
//!
//! .EPOLL and .URING terminate TLS 1.3 in the event loop. .ASYNC also serves
//! TLS 1.2 clients.
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
const PORT:u16 = 9060;
const WORKERS:usize = 1;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
// Demo certificate (SAN localhost, 127.0.0.1). For a real domain, point CERT and
// KEY at the certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT:[]const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY:[]const u8 = "examples/certs/ecdsa_p256_key.pem";
/// HSTS max-age in seconds (RFC 6797): one year.
const HSTS_MAX_AGE_S:u32 = 31536000;
const HSTS_VALUE:[]const u8 = std.fmt.comptimePrint(
    "max-age={d}; includeSubDomains",
    .{HSTS_MAX_AGE_S},
);

// --------------------------------------------------------- //

// curl usage: curl -k "https://localhost:9060/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);
    try res.addHeader("Strict-Transport-Security", HSTS_VALUE);

    try res.send("hello over tls\n");
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
        .hsts_max_age_s = HSTS_MAX_AGE_S,
    });
    defer tls.deinit();

    var server = zix.Http1.Server.init(Routes.dispatch, .{
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

