//! http_sse.zig — Server-Sent Events example
//!
//! Two endpoints:
//!   GET /        — HTML page that opens an EventSource (open in browser)
//!   GET /events  — SSE stream: sends a counter every second for 10 ticks then closes
//!
//! Uses workers = 1 (Model 1): each accepted connection is dispatched as a concurrent
//! task via io.concurrent().  Model 2's blocking thread pool would be exhausted by
//! long-lived SSE connections, one thread per open stream.
//!
//! curl usage:
//!   curl -N http://localhost:9010/events
//!
//! browser:
//!   http://localhost:9010/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9010;
const MAX_KERNEL_BACKLOG: usize = 1024;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;

// --------------------------------------------------------- //

// curl -N http://localhost:9010/events
//
// Streams "tick N" once per second for 10 ticks.
// After the loop the handler returns — handleConnection closes the TCP connection
// and the browser EventSource auto-reconnects after the default 3-second retry.
pub fn eventsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    const sse = try res.stream();
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "tick {d}", .{i}) catch break;
        sse.writeEvent(msg) catch break;
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(1000), .awake) catch break;
    }
}

// browser: http://localhost:9010/
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    res.setContentType(.TEXT_HTML);
    try res.send(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><meta charset="utf-8"><title>zix SSE</title></head>
        \\<body>
        \\<h2>zix Server-Sent Events</h2>
        \\<div id="log" style="font-family:monospace;line-height:1.6"></div>
        \\<script>
        \\const log = document.getElementById('log');
        \\function append(text) { log.innerHTML += '<div>' + text + '</div>'; }
        \\const es = new EventSource('/events');
        \\es.onopen = () => append('[connected]');
        \\es.onmessage = e => append(e.data);
        \\es.onerror = () => append('[stream closed — reconnecting…]');
        \\</script>
        \\</body>
        \\</html>
    );
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(4096, .{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = IP,
        .port = PORT,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = 1, // Model 1 — io.concurrent() per connection; avoids pool exhaustion
    });
    defer server.deinit();

    server.registerHandler("/events", eventsHandler);
    server.registerHandler("/", homeHandler);

    try server.run();
}
