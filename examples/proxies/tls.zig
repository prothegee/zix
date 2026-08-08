//! tls.zig: the upstream behind the zixer TLS terminate demo. Port: 9121
//!
//! A cleartext http1 server with no certificate, no TLS config, and no idea
//! that its clients arrive over https. zixer terminates TLS at the edge and
//! speaks plain http1 to this backend.
//!
//! Site file: examples/proxies/sites/tls.cfg (edge port 9120)
//!
//! Run:
//! zig build zixer-example-tls
//! ./zig-out/bin/zixer-example-tls-<arch>-<os>-<optimize>
//!
//! Through the proxy (self-signed certificate, hence -k):
//! curl -k https://localhost:9120/
//!
//! Direct, to see the same backend answer without TLS:
//! curl http://127.0.0.1:9121/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9121;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

const REPORT_MAX: usize = 1024;

// --------------------------------------------------------- //

/// Header value, or a dash when the request did not carry it.
fn headerOrDash(req: *zix.Http1.Request, name: []const u8) []const u8 {
    return req.header(name) orelse "-";
}

// GET / : report the request head as this cleartext backend received it.
// curl usage: curl -k "https://localhost:9120/"
fn homeHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var report_buf: [REPORT_MAX]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buf,
        \\upstream: proxies/tls on {s}:{d}
        \\upstream leg: cleartext http/1.1, no certificate here
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
    }) catch "upstream: proxies/tls, report did not fit\n";

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
