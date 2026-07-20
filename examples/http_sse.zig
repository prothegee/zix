//! http_sse.zig: Server-Sent Events example
//!
//! Two endpoints:
//! GET /        - HTML page that opens an EventSource (open in browser)
//! GET /events  - SSE stream: sends a counter every second for 10 ticks then closes
//!
//! Uses .ASYNC dispatch: single accept thread, each SSE connection dispatched via io.async().
//! .ASYNC is preferred for SSE: long-lived connections do not hold pool threads.
//!
//! curl usage:
//! curl -N http://localhost:9012/events
//!
//! browser:
//! http://localhost:9012/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9012;
const DISPATCH_MODEL: zix.Http.DispatchModel = .ASYNC;
const KERNEL_BACKLOG: usize = 1024;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const WORKERS: usize = 0; // ignored by .ASYNC
const POOL_SIZE: usize = 0; // ignored by .ASYNC

// --------------------------------------------------------- //

// curl -N http://localhost:9012/events
//
// Streams "tick N" once per second for 10 ticks.
// After the loop the handler returns, handleConnection closes the TCP connection
// and the browser EventSource auto-reconnects after the default 3-second retry.
pub fn eventsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    const sse = try res.sendStream();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "tick {d}", .{i}) catch break;
        sse.writeEvent(msg) catch break;
        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(1000), .awake) catch break;
    }
}

// browser: http://localhost:9012/
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
        \\<pre id="stream-val" style="font-family:monospace"></pre>
        \\<script>
        \\const el = document.getElementById('stream-val');
        \\const es = new EventSource('/events');
        \\es.onopen = () => { el.textContent = '[connected]'; };
        \\es.onmessage = e => { el.textContent = e.data; };
        \\es.onerror = () => { el.textContent = '[stream closed -- reconnecting]'; };
        \\</script>
        \\</body>
        \\</html>
    );
}

// --------------------------------------------------------- //

const Routes = [_]zix.Http.Route{
    .{ .path = "/events", .handler = eventsHandler },
    .{ .path = "/", .handler = homeHandler },
};

pub fn main(process: std.process.Init) !void {
    var server = zix.Http.Server.init(&Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
