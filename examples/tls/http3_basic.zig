// HTTP/3 (QUIC) over the zix.Udp datagram substrate. QUIC requires TLS 1.3, so a Tls.Context
// (cert + key) is mandatory: the server rejects a null context at init. Routes are a comptime table
// (zix.Http3.Router), the same shape as zix.Http1 / zix.Http2, dispatched on the decoded request
// path. ASYNC / POOL / MIXED run a single-worker recv with internal connection-id demux (ADR-049 /
// ADR-050). EPOLL / URING run one SO_REUSEPORT worker per core, the kernel load-balancing by 4-tuple.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9063;
// Demo fixtures. For a real domain, point CERT / KEY at your certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

fn home(_: *const zix.Http3.Request, res: *zix.Http3.Response) void {
    res.send("hello over http/3\n");
}

// Per-worker scratch for a computed body. Thread-local so the slice handed to `res.send` outlives the
// handler call (the engine copies it into the response right after the handler returns).
threadlocal var sum_buf: [32]u8 = undefined;

// /baseline2?a=1&b=1 -> sum the two query integers, the HttpArena baseline-h3 shape.
fn baseline(req: *const zix.Http3.Request, res: *zix.Http3.Response) void {
    const a = queryInt(req.path, "a") orelse 0;
    const b = queryInt(req.path, "b") orelse 0;

    const text = std.fmt.bufPrint(&sum_buf, "{d}", .{a + b}) catch "0";
    res.send(text);
}

// A large (256 KiB) response body, static for the process lifetime so the slice handed to `res.send`
// stays valid. It exercises the streamed multi-packet send path (one response fragmented across many
// 1-RTT packets within the congestion window), which the single-packet routes above do not, and is what
// the full-body correctness gate fetches (rnd/0.5.x/h3-fullbody-gate.sh, verify-http3-fullbody.md).
const big_body: [262144]u8 = @splat('Z');

// GET /big -> the 256 KiB body, to demonstrate and check large multi-packet responses over HTTP/3.
fn big(_: *const zix.Http3.Request, res: *zix.Http3.Response) void {
    res.send(&big_body);
}

// Repeat `unit` `times` over at comptime, the compressible body below.
fn repeatComptime(comptime unit: []const u8, comptime times: usize) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (0..times) |_| out = out ++ unit;

        return out;
    }
}

// A compressible body and its brotli-precompressed form, built once at startup (g_br_body). The
// /negotiated route serves the .br form with `Content-Encoding: br` when the client's Accept-Encoding
// offers br, otherwise the identity form: the content-negotiation shape a static file server uses. The
// codec runs once here, never on the send path, which just picks the smaller slice.
const negotiated_body: []const u8 = repeatComptime("zix HTTP/3 content negotiation demo line. ", 64);
var g_br_body: []const u8 = "";

fn negotiated(req: *const zix.Http3.Request, res: *zix.Http3.Response) void {
    if (g_br_body.len != 0 and std.mem.indexOf(u8, req.accept_encoding, "br") != null) {
        res.setContentEncoding(.br);
        res.send(g_br_body);
        return;
    }

    res.send(negotiated_body);
}

// Parse `?...&name=<int>&...` out of a request path. Returns null when absent or not an integer.
fn queryInt(path: []const u8, name: []const u8) ?i64 {
    const query_at = std.mem.indexOfScalar(u8, path, '?') orelse return null;

    var it = std.mem.splitScalar(u8, path[query_at + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) {
            return std.fmt.parseInt(i64, pair[eq + 1 ..], 10) catch null;
        }
    }

    return null;
}

// --------------------------------------------------------- //

// Try it (needs a curl built with HTTP/3, run from the repo root so the cert path resolves):
// - curl --http3-only -k https://127.0.0.1:9063/ -> "hello over http/3"
// - curl --http3-only -k "https://127.0.0.1:9063/baseline2?a=20&b=22" -> "42"
// - curl --http3-only -k https://127.0.0.1:9063/big -o /dev/null -w '%{size_download}\n' -> 262144
// - curl --http3-only -k --compressed -D- https://127.0.0.1:9063/negotiated -> content-encoding: br
const Routes = zix.Http3.Router(&[_]zix.Http3.Route{
    .{ .path = "/", .handler = home },
    .{ .path = "/baseline2", .handler = baseline },
    .{ .path = "/big", .handler = big },
    .{ .path = "/negotiated", .handler = negotiated },
});

pub fn main(process: std.process.Init) !void {
    // Precompress the negotiated body once (identity stays available for clients that do not accept br).
    g_br_body = zix.utils.compression.encode(std.heap.smp_allocator, .BR, negotiated_body, .DEFAULT) catch "";

    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
    });
    defer tls.deinit();

    const Server = zix.Http3.Http3(Routes.dispatch);
    var server = try Server.init(.{
        .io = process.io,
        .allocator = std.heap.smp_allocator,
        .ip = IP,
        .port = PORT,
        .dispatch_model = .ASYNC,
        .tls = &tls,
    });
    defer server.deinit();

    try server.run();
}
