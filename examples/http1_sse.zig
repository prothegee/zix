//! http1_sse.zig: Server-Sent Events over zix.Http1
//!
//! Two endpoints:
//! GET /        - HTML page that opens an EventSource (open in browser)
//! GET /events  - SSE stream: sends a counter every second until the client disconnects
//!
//! Uses .ASYNC dispatch: each long-lived SSE connection is dispatched via io.async()
//! so it does not pin a pool thread.
//!
//! curl usage:
//! curl -N http://localhost:9027/events
//!
//! browser:
//! http://localhost:9027/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9027;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // ignored by .ASYNC

// --------------------------------------------------------- //

// GET /events
// Begins the SSE stream (no Content-Length, the body is an open stream), then
// emits "tick N" once per second. The loop ends when a write fails, which is
// how a disconnected client is detected. The sleep runs on ctx.io, the worker
// io the trio carries.
//
// curl usage: curl -N "http://localhost:9027/events"
fn eventsHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    // sendStream() detaches any buffered sink (each event flushes immediately, in cleartext and
    // over TLS, see examples/tls/tls_http1_sse.zig), writes the SSE header block, and returns the
    // event writer. An SSE handler never returns, so a buffered response would never flush.
    const stream = try res.sendStream();

    var i: u32 = 0;
    while (true) : (i += 1) {
        var buf: [64]u8 = undefined;
        const event = std.fmt.bufPrint(&buf, "tick {d}", .{i}) catch return;
        stream.writeEvent(event) catch return;

        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(1000), .awake) catch return;
    }
}

// browser: http://localhost:9027/
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_HTML);

    try res.send(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><meta charset="utf-8"><title>zix http1 SSE</title></head>
        \\<body>
        \\<h2>zix Http1 Server-Sent Events</h2>
        \\<pre id="stream-val" style="font-family:monospace"></pre>
        \\<script>
        \\const el = document.getElementById('stream-val');
        \\const es = new EventSource('/events');
        \\es.onopen = () => { el.textContent = '[connected]'; };
        \\es.onmessage = e => { el.textContent = e.data; };
        \\es.onerror = () => { el.textContent = '[stream closed, reconnecting]'; };
        \\</script>
        \\</body>
        \\</html>
    );
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/events", .handler = eventsHandler },
    .{ .path = "/", .handler = homeHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
