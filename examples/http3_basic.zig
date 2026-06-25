// HTTP/3 (QUIC) over the zix.Udp datagram substrate. QUIC requires TLS 1.3, so a Tls.Context
// (cert + key) is mandatory: the server rejects a null context at init. Routes are a comptime table
// (zix.Http3.Router), the same shape as zix.Http1 / zix.Http2, dispatched on the decoded request
// path. The v1 engine runs a single-worker recv with internal connection-id demux (ADR-049 /
// ADR-050). EPOLL / URING fold to the v1 worker until per-core CID steering lands (ADR-049 phase 3).

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9063;
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

const Routes = zix.Http3.Router(&[_]zix.Http3.Route{
    .{ .path = "/", .handler = home },
    .{ .path = "/baseline2", .handler = baseline },
});

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

pub fn main(process: std.process.Init) !void {
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
