//! tls_http1_sse.zig: Server-Sent Events over TLS on the zix.Http1 engine.
//!
//! Two endpoints:
//! GET /        - HTML page that opens an EventSource (open in browser over https)
//! GET /events  - SSE stream over TLS: a counter every second until the client disconnects
//!
//! Streaming over TLS rides the thread-per-connection path (.ASYNC / .POOL / .MIXED), so this
//! example uses .ASYNC: each long-lived SSE connection owns its worker thread (ADR-054). The
//! handler calls beginStream() once: a no-op in cleartext, it is what detaches the buffered capture
//! so each event encrypts one TLS record straight to the socket. The same handler serves cleartext
//! (examples/http1_sse.zig) and TLS unchanged.
//!
//! curl usage:
//! curl -N -k https://localhost:9073/events
//!
//! browser:
//! https://localhost:9073/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9073;
// Demo fixtures. For a real domain, point CERT / KEY at your certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// HSTS max-age in SECONDS (RFC 6797). 1 year, well above the common 180-day minimum.
const HSTS_MAX_AGE_S: u32 = 31536000;

// The Http1 handler signature has no io param, so the SSE loop reaches the io backend through this
// global. Set once in main before the server starts.
var g_io: std.Io = undefined;

// --------------------------------------------------------- //

// curl -N -k https://localhost:9073/events
//
// Writes the SSE response headers, then emits "data: tick N" once per second, each event encrypted
// as one TLS record. The loop ends when a write fails, which is how a disconnected client is seen.
fn eventsHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;

    // beginStream() detaches the buffered capture so each event flushes immediately over TLS. An
    // SSE handler never returns, so a buffered response would never be encrypted and sent.
    zix.Http1.beginStream();
    const headers =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n\r\n";
    zix.Http1.writeAllFD(fd, headers) catch return;

    var i: u32 = 0;
    while (true) : (i += 1) {
        var buf: [64]u8 = undefined;
        const event = std.fmt.bufPrint(&buf, "data: tick {d}\n\n", .{i}) catch return;
        zix.Http1.writeAllFD(fd, event) catch return;

        std.Io.sleep(g_io, std.Io.Duration.fromMilliseconds(1000), .awake) catch return;
    }
}

// browser: https://localhost:9073/
fn homeHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.sendSimpleFD(fd, 200, "text/html",
        \\<!DOCTYPE html>
        \\<html>
        \\<head><meta charset="utf-8"><title>zix http1 SSE over TLS</title></head>
        \\<body>
        \\<h2>zix Http1 Server-Sent Events over TLS</h2>
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

    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
        .hsts_max_age_s = HSTS_MAX_AGE_S,
    });
    defer tls.deinit();

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .tls = &tls,
        // .ASYNC (thread per connection) is the streaming-over-TLS path: each SSE stream parks its
        // own thread instead of a fixed pool slot. .EPOLL / .URING would buffer (no streaming).
        .dispatch_model = .ASYNC,
    });
    defer server.deinit();

    try server.run();
}
