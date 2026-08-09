//! headers.zig: the upstream behind the zixer headers proxy demo. Port: 9129
//!
//! An ordinary cleartext http1 server that reports the request head it
//! received, so the [request_headers] lines the site adds on the upstream leg
//! become visible. It also sets X-Frame-Options itself, which is how the
//! replace rule shows: the site sets that same name, so the client only ever
//! sees the site's value.
//!
//! Site file: examples/proxies/sites/headers.cfg (edge port 9128)
//!
//! Run:
//! zig build zixer-example-headers
//! ./zig-out/bin/zixer-example-headers-<arch>-<os>-<optimize>
//!
//! Through the proxy:
//! curl -D - http://127.0.0.1:9128/
//!
//! Direct, to compare what changes:
//! curl -D - http://127.0.0.1:9129/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9129;
// .ASYNC keeps the demo identical on every platform: the point here is which
// headers cross the hop, not the dispatch model of the backend.
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

/// The value this backend sets, which the site replaces with its own.
const ORIGIN_FRAME_OPTIONS: []const u8 = "SAMEORIGIN";

const REPORT_MAX: usize = 1024;

// --------------------------------------------------------- //

/// Header value, or a dash when the request did not carry it.
fn headerOrDash(req: *zix.Http1.Request, name: []const u8) []const u8 {
    return req.header(name) orelse "-";
}

// GET / : report the request headers the site added on the upstream leg, and
// answer with an X-Frame-Options the site is going to replace.
// curl usage: curl -D - "http://127.0.0.1:9128/"
fn homeHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var report_buf: [REPORT_MAX]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buf,
        \\upstream: proxies/headers on {s}:{d}
        \\x-real-ip: {s}
        \\x-forwarded-proto: {s}
        \\x-forwarded-host: {s}
        \\x-edge-tenant: {s}
        \\
    , .{
        IP,
        PORT,
        headerOrDash(req, "x-real-ip"),
        headerOrDash(req, "x-forwarded-proto"),
        headerOrDash(req, "x-forwarded-host"),
        headerOrDash(req, "x-edge-tenant"),
    }) catch "upstream: proxies/headers, report did not fit\n";

    res.setContentType(.TEXT_PLAIN);
    try res.addHeader("X-Frame-Options", ORIGIN_FRAME_OPTIONS);

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
