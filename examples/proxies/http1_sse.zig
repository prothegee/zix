//! http1_sse.zig: the upstream behind the zixer sse proxy demo. Port: 9103
//!
//! Emits one Server-Sent Event every 400 ms until the client goes away. The
//! gap is the point: through the proxy the events must arrive one by one, as
//! this backend sends them, not in a burst when the stream ends.
//!
//! Site file: examples/proxies/sites/http1_sse.cfg (edge port 9102)
//!
//! Run:
//! zig build zixer-example-http1_sse
//! ./zig-out/bin/zixer-example-http1_sse-<arch>-<os>-<optimize>
//!
//! Through the proxy:
//! curl -N http://127.0.0.1:9102/events

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9103;
// .ASYNC dispatches each long-lived stream through io.async(), so an open
// stream never pins an event loop worker.
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

/// Gap between events. Long enough to see them arrive separately by eye.
const TICK_MS: u64 = 400;

// --------------------------------------------------------- //

// GET /events : the event stream.
// curl usage: curl -N "http://127.0.0.1:9102/events"
fn eventsHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    // sendStream() detaches any buffered sink and writes the SSE head, so each
    // event flushes as it is written. An SSE handler never returns, and a
    // buffered response would never reach the client.
    const stream = try res.sendStream();

    var tick: u32 = 0;
    while (true) : (tick += 1) {
        var event_buf: [64]u8 = undefined;
        const event = std.fmt.bufPrint(&event_buf, "tick {d} from proxies/http1_sse", .{tick}) catch return;
        stream.writeEvent(event) catch return;

        std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(TICK_MS), .awake) catch return;
    }
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/events", .handler = eventsHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .max_recv_buf = MAX_RECV_BUF,
    });
    defer server.deinit();

    try server.run();
}
