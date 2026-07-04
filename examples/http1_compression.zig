const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9058;
// Compression is active under .EPOLL and .URING only (shared-nothing, one owner per
// worker). Under .ASYNC / .POOL / .MIXED sendNegotiateCachedFD falls back to uncompressed.
const DISPATCH_MODEL: zix.Http1.DispatchModel = .EPOLL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MIN_SIZE: usize = 256;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0; // 0 = cpu_count epoll workers
const POOL_SIZE: usize = 0; // ignored by .EPOLL

// --------------------------------------------------------- //

// One paragraph of the demo body. brotli, gzip, and deflate all carry a fixed
// per-response header, so a body only shrinks once it clears that overhead. The
// paragraph is repeated below so every coding (brotli included) wins on the wire.
const PARAGRAPH: []const u8 =
    \\zix response compression demo. This body is served through
    \\zix.Http1.sendNegotiateCachedFD, which reads the request Accept-Encoding header
    \\and compresses with brotli, gzip, or deflate when the client accepts a
    \\coding, the body clears the size floor, and the compressed result is smaller
    \\than the original. Repetitive text like this compresses well, so the wire
    \\payload shrinks while the handler stays a single sendNegotiateCachedFD call.
    \\Without a matching Accept-Encoding the very same bytes are sent uncompressed.
;

// The repeated paragraphs make the body comfortably compressible for every coding.
const BODY: []const u8 = PARAGRAPH ++ "\n\n" ++ PARAGRAPH ++ "\n\n" ++ PARAGRAPH;

// --------------------------------------------------------- //

// curl usage: curl --compressed -v "http://localhost:9058/data"
//   (or) curl -H "Accept-Encoding: br" -v "http://localhost:9058/data"
//   (or) curl -H "Accept-Encoding: gzip" -v "http://localhost:9058/data"
//   (or) curl -H "Accept-Encoding: deflate" -v "http://localhost:9058/data"
// sendNegotiateCachedFD picks gzip, deflate, or brotli per the client (gzip leads at equal
// quality, brotli when the client asks for it), or identity when none is accepted, and
// sets Content-Encoding plus Vary: Accept-Encoding when it compresses.
fn dataHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.sendSimpleFD(fd, 405, "text/plain", "method not allowed") catch {};
        return;
    }

    zix.Http1.sendNegotiateCachedFD(fd, head, 200, "text/plain", BODY) catch {};
}

// curl usage: curl -H "Accept-Encoding: gzip" -v "http://localhost:9058/ping"
// The body is under COMPRESSION_MIN_SIZE, so it is always sent uncompressed even
// when gzip is accepted.
fn pingHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    zix.Http1.sendNegotiateCachedFD(fd, head, 200, "text/plain", "pong") catch {};
}

// Produce one specific coding explicitly through the codec facade (zix.utils.compression.encode), the
// lower-level alternative to sendNegotiateCachedFD. encode dispatches over every available coding
// (gzip, deflate, brotli), so the same helper serves all three: the route picks which.
//
// Note:
// - This forces the coding for demonstration and sets Content-Encoding to it regardless of the
//   request header. A real handler should negotiate from Accept-Encoding instead (see /data).
fn serveCoding(fd: std.posix.fd_t, encoding: zix.utils.compression.Encoding) void {
    const encoded = zix.utils.compression.encode(std.heap.smp_allocator, encoding, BODY, .DEFAULT) catch {
        zix.Http1.sendSimpleFD(fd, 500, "text/plain", "encode failed") catch {};
        return;
    };
    defer std.heap.smp_allocator.free(encoded);

    var hdr: [192]u8 = undefined;
    const header = std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: {s}\r\nVary: Accept-Encoding\r\nContent-Length: {d}\r\n\r\n",
        .{ encoding.contentEncoding().?, encoded.len },
    ) catch return;

    zix.Http1.writeAllFD(fd, header) catch return;
    zix.Http1.writeAllFD(fd, encoded) catch {};
}

// curl usage: curl -v "http://localhost:9058/gzip" | gunzip
fn gzipHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    serveCoding(fd, .GZIP);
}

// curl usage: curl -v "http://localhost:9058/deflate"
fn deflateHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    serveCoding(fd, .DEFLATE);
}

// curl usage: curl -v "http://localhost:9058/br" | brotli -d
fn brHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    serveCoding(fd, .BR);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/data", .handler = dataHandler },
    .{ .path = "/ping", .handler = pingHandler },
    .{ .path = "/gzip", .handler = gzipHandler },
    .{ .path = "/deflate", .handler = deflateHandler },
    .{ .path = "/br", .handler = brHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compress = true,
        .compression_min_size = COMPRESSION_MIN_SIZE,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
