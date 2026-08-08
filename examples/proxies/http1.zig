//! http1.zig: the upstream behind the zixer http1 proxy demo. Port: 9101
//!
//! An ordinary cleartext http1 server. It knows nothing about being proxied:
//! it just reports the request head it received, which is how the headers
//! zixer adds on the upstream leg (Via, Forwarded) become visible.
//!
//! Site file: examples/proxies/sites/http1.cfg (edge port 9100)
//!
//! Run:
//! zig build zixer-example-http1
//! ./zig-out/bin/zixer-example-http1-<arch>-<os>-<optimize>
//!
//! Through the proxy:
//! curl http://127.0.0.1:9100/
//! curl -X POST --data-binary "ping" http://127.0.0.1:9100/echo
//!
//! Direct, to compare what changes:
//! curl http://127.0.0.1:9101/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9101;
// .ASYNC keeps the demo identical on every platform: the point here is the
// proxy hop, not the dispatch model of the backend.
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

const REPORT_MAX: usize = 1024;

// --------------------------------------------------------- //

/// Header value, or a dash when the request did not carry it.
fn headerOrDash(req: *zix.Http1.Request, name: []const u8) []const u8 {
    return req.header(name) orelse "-";
}

// GET / : report the request head as this backend received it.
// curl usage: curl -X GET "http://127.0.0.1:9100/"
fn homeHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var report_buf: [REPORT_MAX]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buf,
        \\upstream: proxies/http1 on {s}:{d}
        \\method: {s}
        \\path: {s}
        \\host: {s}
        \\via: {s}
        \\forwarded: {s}
        \\
    , .{
        IP,
        PORT,
        @tagName(req.method()),
        req.path(),
        headerOrDash(req, "host"),
        headerOrDash(req, "via"),
        headerOrDash(req, "forwarded"),
    }) catch "upstream: proxies/http1, report did not fit\n";

    res.setContentType(.TEXT_PLAIN);

    try res.send(report);
}

// POST /echo : send the request body straight back, so a body crossing the
// proxy can be compared byte for byte.
// curl usage: curl -X POST --data-binary "ping" "http://127.0.0.1:9100/echo"
fn echoHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const payload = try req.body();

    res.setContentType(.TEXT_PLAIN);

    try res.send(payload);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
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
