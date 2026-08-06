//! http3.zig: the upstream behind the zixer http3 proxy demo. Port: 9111
//!
//! A cleartext http1 server. QUIC terminates at zixer: the client speaks h3,
//! zixer rebuilds the request as http1 for this backend, and `via: 3 zixer` in
//! the report is the h3 edge naming itself on the upstream leg.
//!
//! Site file: examples/proxies/sites/http3.cfg (edge port 9110)
//!
//! Run:
//! zig build zixer-example-http3
//! ./zig-out/bin/zixer-example-http3-<arch>-<os>
//!
//! Through the proxy (curl must be built with HTTP/3):
//! curl -k --http3-only https://localhost:9110/
//! curl -k --http3-only -X POST --data-binary "ping" https://localhost:9110/echo
//! curl -k --http3-only -o /dev/null -w "%{size_download}\n" https://localhost:9110/big

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9111;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

const REPORT_MAX: usize = 1024;

/// Body size of /big. Far past one QUIC packet, so the reply only completes
/// once flow control has been replenished and losses recovered.
const BIG_BYTES: usize = 512 * 1024;
const BIG_FILL: u8 = 'z';

var big_body: [BIG_BYTES]u8 = undefined;

// --------------------------------------------------------- //

/// Header value, or a dash when the request did not carry it.
fn headerOrDash(req: *zix.Http1.Request, name: []const u8) []const u8 {
    return req.header(name) orelse "-";
}

// GET / : report the request head as this http1 backend received it.
// curl usage: curl -k --http3-only "https://localhost:9110/"
fn homeHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var report_buf: [REPORT_MAX]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buf,
        \\upstream: proxies/http3 on {s}:{d}
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
    }) catch "upstream: proxies/http3, report did not fit\n";

    res.setContentType(.TEXT_PLAIN);

    try res.send(report);
}

// POST /echo : send the request body back, so a body that crossed QUIC and was
// rebuilt as http1 can be compared byte for byte.
// curl usage: curl -k --http3-only -X POST --data-binary "ping" "https://localhost:9110/echo"
fn echoHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const payload = try req.body();

    res.setContentType(.TEXT_PLAIN);

    try res.send(payload);
}

// GET /big : 512 KiB of one byte, a reply that spans many QUIC packets.
// curl usage: curl -k --http3-only -o /dev/null -w "%{size_download}\n" "https://localhost:9110/big"
fn bigHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send(&big_body);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/big", .handler = bigHandler },
});

pub fn main(process: std.process.Init) !void {
    @memset(&big_body, BIG_FILL);

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
