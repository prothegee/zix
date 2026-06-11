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
//! curl -N http://localhost:9108/events
//!
//! browser:
//! http://localhost:9108/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9108;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const MAX_GZIP_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0; // ignored by .ASYNC

// The Http1 handler signature has no io param, so the SSE loop reaches the io
// backend through this global. Set once in main before the server starts.
var g_io: std.Io = undefined;

// --------------------------------------------------------- //

// GET /events
// Writes the SSE response headers directly (no Content-Length, the body is an
// open stream), then emits "data: tick N" once per second. The loop ends when
// a write fails, which is how a disconnected client is detected.
//
// curl usage: curl -N "http://localhost:9108/events"
fn eventsHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n\r\n";
    zix.Http1.fdWriteAll(fd, headers) catch return;

    var i: u32 = 0;
    while (true) : (i += 1) {
        var buf: [64]u8 = undefined;
        const event = std.fmt.bufPrint(&buf, "data: tick {d}\n\n", .{i}) catch return;
        zix.Http1.fdWriteAll(fd, event) catch return;

        std.Io.sleep(g_io, std.Io.Duration.fromMilliseconds(1000), .awake) catch return;
    }
}

// browser: http://localhost:9108/
fn homeHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeSimple(fd, 200, "text/html",
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
    ) catch {};
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/events", .handler = eventsHandler },
    .{ .path = "/", .handler = homeHandler },
});

pub fn main(process: std.process.Init) !void {
    g_io = process.io;

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_gzip_out = MAX_GZIP_OUT,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
