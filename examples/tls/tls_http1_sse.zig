//! ZIX example tls http1 sse
//!
//! ### file: examples/tls/tls_http1_sse.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Server-Sent Events over TLS: a page at / and a tick stream at /events.
//!
//! ### note:
//!
//! .ASYNC: an SSE handler never returns, so it parks its own task instead of an
//! event loop worker. sendStream seals each event as TLS records.
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
const PORT:u16 = 9073;
const DISPATCH_MODEL:zix.Http1.DispatchModel = .ASYNC;
const TICK_MS:i64 = 1000;
// Demo certificate (SAN localhost, 127.0.0.1). For a real domain, point CERT and
// KEY at the certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT:[]const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY:[]const u8 = "examples/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

/// Page that opens an EventSource on /events and prints each tick.
const PAGE: []const u8 =
    \\<!doctype html>
    \\<html>
    \\<head>
    \\<meta charset="utf-8">
    \\<title>zix http1 sse over tls</title>
    \\</head>
    \\<body>
    \\<h1>zix http1 sse over tls</h1>
    \\<ul id="log"></ul>
    \\<script>
    \\const log = document.getElementById("log");
    \\const source = new EventSource("/events");
    \\source.onmessage = (event) => {
    \\  const item = document.createElement("li");
    \\  item.textContent = event.data;
    \\  log.prepend(item);
    \\};
    \\</script>
    \\</body>
    \\</html>
    \\
;

// GET /events
// Sends "tick N" every second. The loop ends when a write fails (client gone).
// curl usage: curl -k -N "https://localhost:9073/events"
fn eventsHandler(
    _: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const stream = try res.sendStream();

    var tick: u32 = 0;
    while (true) : (tick += 1) {
        var buf: [64]u8 = undefined;
        const event = try std.fmt.bufPrint(&buf, "tick {d}", .{tick});

        stream.writeEvent(event) catch |err| switch (err) {
            // A failed write means the client disconnected.
            else => return,
        };

        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(TICK_MS), .awake) catch |err|
            switch (err) {
                // A canceled sleep ends the stream.
                else => return,
            };
    }
}

// GET /
// browser: https://localhost:9073/
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_HTML);

    try res.send(PAGE);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/events",
        .handler = eventsHandler,
    },
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
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}

