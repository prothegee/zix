const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9058;
// Compression is active under .EPOLL and .URING only (shared-nothing, one owner per
// worker). Under .ASYNC / .POOL / .MIXED writeNegotiated falls back to uncompressed.
const DISPATCH_MODEL: zix.Http1.DispatchModel = .EPOLL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MIN_SIZE: usize = 256;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0; // 0 = cpu_count epoll workers
const POOL_SIZE: usize = 0; // ignored by .EPOLL

// --------------------------------------------------------- //

// A body above COMPRESSION_MIN_SIZE and repetitive enough to compress well.
const BODY: []const u8 =
    \\zix response compression demo. This body is served through
    \\zix.Http1.writeNegotiated, which reads the request Accept-Encoding header
    \\and compresses with gzip or deflate when the client accepts a coding, the
    \\body clears the size floor, and the compressed result is smaller than the
    \\original. Repetitive text like this compresses well, so the wire payload
    \\shrinks while the handler stays a single writeNegotiated call. Without a
    \\matching Accept-Encoding the very same bytes are sent uncompressed.
;

// --------------------------------------------------------- //

// curl usage: curl --compressed -v "http://localhost:9058/data"
//   (or) curl -H "Accept-Encoding: gzip" -v "http://localhost:9058/data"
//   (or) curl -H "Accept-Encoding: deflate" -v "http://localhost:9058/data"
// writeNegotiated picks gzip or deflate per the client, or identity when neither
// is accepted, and sets Content-Encoding plus Vary: Accept-Encoding when it compresses.
fn dataHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeSimple(fd, 405, "text/plain", "method not allowed") catch {};
        return;
    }

    zix.Http1.writeNegotiated(fd, head, 200, "text/plain", BODY) catch {};
}

// curl usage: curl -H "Accept-Encoding: gzip" -v "http://localhost:9058/ping"
// The body is under COMPRESSION_MIN_SIZE, so it is always sent uncompressed even
// when gzip is accepted.
fn pingHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    zix.Http1.writeNegotiated(fd, head, 200, "text/plain", "pong") catch {};
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/data", .handler = dataHandler },
    .{ .path = "/ping", .handler = pingHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compression = true,
        .compression_min_size = COMPRESSION_MIN_SIZE,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
