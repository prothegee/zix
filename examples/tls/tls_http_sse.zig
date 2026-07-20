//! tls_http_sse.zig: Server-Sent Events over TLS on the zix.Http (arena) engine.
//!
//! Two endpoints:
//! GET /        - HTML page that opens an EventSource (open in browser over https)
//! GET /events  - SSE stream over TLS: a counter every second for 10 ticks then closes
//!
//! Streaming over TLS rides the thread-per-connection path (.ASYNC / .POOL / .MIXED), so this
//! example uses .ASYNC: each long-lived SSE connection owns its worker thread (ADR-054). The
//! .EPOLL / .URING multiplexed TLS path stays request / response only. res.sendStream() is unchanged:
//! it detaches the buffered capture and each event encrypts one TLS record straight to the socket.
//!
//! curl usage:
//! curl -N -k https://localhost:9072/events
//!
//! browser:
//! https://localhost:9072/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9072;
// Demo fixtures. For a real domain, point CERT / KEY at your certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// HSTS max-age in SECONDS (RFC 6797). 1 year, well above the common 180-day minimum.
const HSTS_MAX_AGE_S: u32 = 31536000;

// --------------------------------------------------------- //

// curl -N -k https://localhost:9072/events
//
// Streams "tick N" once per second for 10 ticks, each event encrypted as one TLS record. The
// handler returns after the loop, so the connection closes and the EventSource auto-reconnects.
fn eventsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
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

// browser: https://localhost:9072/
fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    res.setContentType(.TEXT_HTML);
    try res.send(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><meta charset="utf-8"><title>zix SSE over TLS</title></head>
        \\<body>
        \\<h2>zix Server-Sent Events over TLS</h2>
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

const Routes = [_]zix.Http.Route{
    .{ .path = "/events", .handler = eventsHandler },
    .{ .path = "/", .handler = homeHandler },
};

pub fn main(process: std.process.Init) !void {
    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
        .hsts_max_age_s = HSTS_MAX_AGE_S,
    });
    defer tls.deinit();

    var server = zix.Http.Server.init(&Routes, .{
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
