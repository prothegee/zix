//! http2.zig: the upstream behind the zixer http2 proxy demo. Port: 9107
//!
//! A cleartext http1 server. The client speaks h2 to zixer, zixer rebuilds the
//! request as http1 for this backend, so an http1-only service gains an h2
//! front without changing. curl reports HTTP/2 on its side, and the report
//! below shows the plain http1 head this backend received.
//!
//! Site file: examples/proxies/sites/http2.cfg (edge port 9106)
//!
//! Run:
//! zig build zixer-example-http2
//! ./zig-out/bin/zixer-example-http2-<arch>-<os>
//!
//! Through the proxy:
//! curl --http2-prior-knowledge http://127.0.0.1:9106/
//! curl --http2-prior-knowledge -X POST --data-binary "ping" http://127.0.0.1:9106/echo

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9107;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

const REPORT_MAX: usize = 1024;

// --------------------------------------------------------- //

/// Header value, or a dash when the request did not carry it.
fn headerOrDash(req: *zix.Http1.Request, name: []const u8) []const u8 {
    return req.header(name) orelse "-";
}

// GET / : report the request head as this http1 backend received it.
// curl usage: curl --http2-prior-knowledge "http://127.0.0.1:9106/"
fn homeHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var report_buf: [REPORT_MAX]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buf,
        \\upstream: proxies/http2 on {s}:{d}
        \\upstream protocol: http/1.1
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
    }) catch "upstream: proxies/http2, report did not fit\n";

    res.setContentType(.TEXT_PLAIN);

    try res.send(report);
}

// POST /echo : send the request body back, so an h2 DATA frame body can be
// compared byte for byte after the http1 rebuild.
// curl usage: curl --http2-prior-knowledge -X POST --data-binary "ping" "http://127.0.0.1:9106/echo"
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
