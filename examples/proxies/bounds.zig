//! bounds.zig: the upstream behind the zixer bounds proxy demo. Port: 9125
//!
//! An ordinary cleartext http1 server. Nothing here knows about the bounds:
//! they all live on the edge, and this backend only exists so a bounded site
//! has something real to proxy to.
//!
//! Site file: examples/proxies/sites/bounds.cfg (edge port 9124)
//!
//! Run:
//! zig build zixer-example-bounds
//! ./zig-out/bin/zixer-example-bounds-<arch>-<os>-<optimize>
//!
//! Through the proxy:
//! curl http://127.0.0.1:9124/
//!
//! A request that never finishes its head, answered 408 once the budget runs
//! out:
//! printf 'GET / HTTP/1.1\r\nHost: 127.0.0.1:9124\r\n' | nc 127.0.0.1 9124
//!
//! Direct, to compare what changes:
//! curl http://127.0.0.1:9125/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9125;
// .ASYNC keeps the demo identical on every platform: the point here is what
// the edge bounds, not the dispatch model of the backend.
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

const REPORT_MAX: usize = 512;

// --------------------------------------------------------- //

// GET / : answer at once, so every wait the demo shows belongs to the edge
// rather than to this backend.
// curl usage: curl -X GET "http://127.0.0.1:9124/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var report_buf: [REPORT_MAX]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buf,
        \\upstream: proxies/bounds on {s}:{d}
        \\note: this backend answers immediately, every bound is the edge's
        \\
    , .{ IP, PORT }) catch "upstream: proxies/bounds, report did not fit\n";

    res.setContentType(.TEXT_PLAIN);

    try res.send(report);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
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
