//! mixed.zig: the upstream behind the zixer mixed static plus proxy demo. Port: 9116
//!
//! Everything outside the site's public_prefix reaches this backend. Requests
//! under /assets never do: zixer opens those files itself and this server is
//! not involved.
//!
//! Site file: examples/proxies/sites/mixed.cfg (edge port 9115)
//!
//! Run:
//! zig build zixer-example-mixed
//! ./zig-out/bin/zixer-example-mixed-<arch>-<os>
//!
//! Through the proxy:
//! curl http://127.0.0.1:9115/assets/app.css      # zixer answers from public_dir
//! curl http://127.0.0.1:9115/                    # this backend answers
//! curl http://127.0.0.1:9115/api/health          # this backend answers

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9116;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

const REPORT_MAX: usize = 512;

// --------------------------------------------------------- //

// GET / : the application page, so it is obvious which plane answered.
// curl usage: curl "http://127.0.0.1:9115/"
fn homeHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var report_buf: [REPORT_MAX]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buf,
        \\upstream: proxies/mixed on {s}:{d}
        \\path: {s}
        \\note: static files live under /assets and never reach this backend
        \\
    , .{ IP, PORT, req.path() }) catch "upstream: proxies/mixed, report did not fit\n";

    res.setContentType(.TEXT_PLAIN);

    try res.send(report);
}

// GET /api/health : an ordinary backend endpoint outside the static prefix.
// curl usage: curl "http://127.0.0.1:9115/api/health"
fn healthHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    try res.sendJson("{\"status\":\"ok\",\"from\":\"proxies/mixed\"}");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/api/health", .handler = healthHandler },
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
