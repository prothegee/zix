//! ZIX example tls http1 ed25519
//!
//! ### file: examples/tls/tls_http1_ed25519.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! https/1.1 over TLS with an Ed25519 certificate.
//!
//! ### note:
//!
//! Ed25519 is TLS 1.3 only (the TLS 1.2 ServerKeyExchange here is ECDSA signed).
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
const PORT:u16 = 9062;
const WORKERS:usize = 1;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
// Demo certificate (SAN localhost, 127.0.0.1). For a real domain, point CERT and
// KEY at the certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT:[]const u8 = "examples/certs/ed25519_cert.pem";
const KEY:[]const u8 = "examples/certs/ed25519_key.pem";

// --------------------------------------------------------- //

// curl usage: curl -k --tlsv1.3 "https://localhost:9062/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("hello over tls 1.3 with an ed25519 certificate\n");
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
        .min_version = .TLS_1_3,
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

