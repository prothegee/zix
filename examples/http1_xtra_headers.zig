const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9026;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

// zix.Http1.Response has no custom-header slots, so this example hand-builds the
// response with sendWithHeaders below and writes it through res.raw. The cap and
// the CR/LF injection guard are enforced by that helper, mirroring what
// zix.Http.Response.addHeader does.
const MAX_XTRA_HEADERS: usize = 16;

// --------------------------------------------------------- //

const Hdr = struct { name: []const u8, value: []const u8 };

fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        500 => "Internal Server Error",
        else => "OK",
    };
}

fn hasControlChar(str: []const u8) bool {
    return std.mem.indexOfScalar(u8, str, '\r') != null or std.mem.indexOfScalar(u8, str, '\n') != null;
}

// Build and send a response with arbitrary custom headers, written verbatim
// through res.raw so the wire bytes carry every custom header.
//
// Note:
// - error.TooManyHeaders when headers.len exceeds MAX_XTRA_HEADERS.
// - error.HeaderInjection when a name or value contains CR or LF.
fn sendWithHeaders(
    res: *zix.Http1.Response,
    status: u16,
    content_type: []const u8,
    headers: []const Hdr,
    body: []const u8,
) !void {
    if (headers.len > MAX_XTRA_HEADERS) return error.TooManyHeaders;

    for (headers) |header| {
        if (hasControlChar(header.name) or hasControlChar(header.value)) return error.HeaderInjection;
    }

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("HTTP/1.1 {d} {s}\r\n", .{ status, reason(status) });
    try writer.print("Content-Type: {s}\r\n", .{content_type});
    try writer.print("Content-Length: {d}\r\n", .{body.len});
    for (headers) |header| {
        try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    }
    try writer.writeAll("\r\n");
    try writer.writeAll(body);

    try res.sendRaw(writer.buffered());
}

// --------------------------------------------------------- //

// GET /info
// Returns a JSON body with several custom headers attached.
// curl usage: curl -i "http://localhost:9026/info"
fn infoHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const headers = [_]Hdr{
        .{ .name = "X-Server", .value = "zix" },
        .{ .name = "X-Version", .value = "X.Y.Z" },
        .{ .name = "Cache-Control", .value = "no-store" },
        .{ .name = "Vary", .value = "Accept-Encoding" },
        .{ .name = "X-Frame-Options", .value = "DENY" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    };

    return sendWithHeaders(res, 200, "application/json", &headers, "{\"status\":\"ok\",\"note\":\"6 headers added\"}");
}

// GET /cors
// A CORS preflight-style response with multiple headers.
// curl usage: curl -i "http://localhost:9026/cors"
fn corsHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const headers = [_]Hdr{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
        .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
        .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization, X-Request-ID" },
        .{ .name = "Access-Control-Max-Age", .value = "86400" },
        .{ .name = "Vary", .value = "Origin" },
    };

    return sendWithHeaders(res, 200, "application/json", &headers, "{\"status\":\"ok\",\"note\":\"5 CORS headers added\"}");
}

// GET /overflow
// Attempts to send MAX_XTRA_HEADERS + 1 headers, tripping the cap.
// curl usage: curl -i "http://localhost:9026/overflow"
fn overflowHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var name_store: [MAX_XTRA_HEADERS + 1][16]u8 = undefined;
    var headers: [MAX_XTRA_HEADERS + 1]Hdr = undefined;
    for (0..MAX_XTRA_HEADERS + 1) |index| {
        const name = std.fmt.bufPrint(&name_store[index], "X-Header-{d}", .{index}) catch return;
        headers[index] = .{ .name = name, .value = "1" };
    }

    sendWithHeaders(res, 200, "application/json", &headers, "{\"status\":\"ok\"}") catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\",\"note\":\"cap is 16\"}}", .{@errorName(err)}) catch return;
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson(msg);
        return;
    };
}

// GET /inject-guard
// Demonstrates the CR/LF injection guard rejecting a crafted header value.
// curl usage: curl -i "http://localhost:9026/inject-guard"
fn injectGuardHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const headers = [_]Hdr{
        .{ .name = "X-Safe", .value = "legit\r\nX-Injected: attack" },
    };

    sendWithHeaders(res, 200, "application/json", &headers, "{\"status\":\"ok\"}") catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\",\"note\":\"CR/LF in header value rejected\"}}", .{@errorName(err)}) catch return;
        res.setStatus(.BAD_REQUEST);

        try res.sendJson(msg);
        return;
    };
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/info", .handler = infoHandler },
    .{ .path = "/cors", .handler = corsHandler },
    .{ .path = "/overflow", .handler = overflowHandler },
    .{ .path = "/inject-guard", .handler = injectGuardHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
