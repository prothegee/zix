const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9059;
// Compression is active under .EPOLL and .URING only (shared-nothing, one owner per
// worker). Under .ASYNC / .POOL / .MIXED sendNegotiated falls back to uncompressed.
const DISPATCH_MODEL: zix.Http.DispatchModel = .EPOLL;
const KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const COMPRESSION_MIN_SIZE: usize = 256;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // 0 = cpu_count epoll workers
const POOL_SIZE: usize = 0; // ignored by .EPOLL

// --------------------------------------------------------- //

// A body above COMPRESSION_MIN_SIZE and repetitive enough to compress well.
const BODY: []const u8 =
    \\zix response compression demo. This body is served through
    \\Response.sendNegotiated, which reads the request Accept-Encoding header and
    \\compresses with gzip or deflate when the client accepts a coding, the body
    \\clears the size floor, and the compressed result is smaller than the original.
    \\Repetitive text like this compresses well, so the wire payload shrinks while the
    \\handler stays a single sendNegotiated call. Without a matching Accept-Encoding
    \\the very same bytes are sent uncompressed.
;

// --------------------------------------------------------- //

// curl usage: curl --compressed -v "http://localhost:9059/data"
//   (or) curl -H "Accept-Encoding: gzip" -v "http://localhost:9059/data"
//   (or) curl -H "Accept-Encoding: deflate" -v "http://localhost:9059/data"
// sendNegotiated picks gzip or deflate per the client, or identity when neither is
// accepted, and sets Content-Encoding plus Vary: Accept-Encoding when it compresses.
pub fn dataHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = ctx;
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.send("method not allowed");
        return;
    }

    res.setContentType(.TEXT_PLAIN);
    try res.sendNegotiated(req, BODY);
}

// curl usage: curl -H "Accept-Encoding: gzip" -v "http://localhost:9059/ping"
// The body is under COMPRESSION_MIN_SIZE, so it is always sent uncompressed even
// when gzip is accepted.
pub fn pingHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = ctx;
    res.setContentType(.TEXT_PLAIN);
    try res.sendNegotiated(req, "pong");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Http.Route{
    .{ .path = "/data", .handler = dataHandler },
    .{ .path = "/ping", .handler = pingHandler },
};

pub fn main(process: std.process.Init) !void {
    var server = try zix.Http.Server.init(4096, &Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .compression = true,
        .compression_min_size = COMPRESSION_MIN_SIZE,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
