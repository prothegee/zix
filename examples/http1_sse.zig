//! ZIX example http1 sse
//!
//! ### file: examples/http1_sse.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that streams Server-Sent Events.
//!
//! ### note:
//!
//! Uses .ASYNC, because an SSE handler keeps its connection open and must not
//! pin an event loop worker. The page is embedded, so the binary runs from any
//! directory.
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
const PORT:u16 = 9027;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF:usize = 16 * 1024;
const COMPRESSION_MAX_OUT:usize = 256 * 1024;
const TICK_MS:i64 = 1000;

// --------------------------------------------------------- //

/// Page that opens an EventSource on /events and prints each tick.
const PAGE: []const u8 =
    \\<!doctype html>
    \\<html>
    \\<head>
    \\<meta charset="utf-8">
    \\<title>zix http1 sse</title>
    \\</head>
    \\<body>
    \\<h1>zix http1 sse</h1>
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
// Opens the stream (no Content-Length) and sends "tick N" every second.
// The loop ends when a write fails, which means the client is gone.
// curl usage: curl -N "http://localhost:9027/events"
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
// browser: http://localhost:9027/
// curl usage: curl "http://localhost:9027/"
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
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .dispatch_model = DISPATCH_MODEL,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
    });
    defer server.deinit();

    try server.run();
}

