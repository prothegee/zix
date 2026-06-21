const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9021;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const MAX_GZIP_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

// Middleware is composed at comptime using wrapper functions.
// Each wrapper takes a 'next' handler (comptime-known) and returns a new HandlerFn.
// Compose left-to-right: withOriginCheck(withBasicAuth(handler)) runs origin first,
// then basic auth, then the actual handler.

// --------------------------------------------------------- //

const ALLOWED_ORIGINS = [_][]const u8{
    "http://localhost",
    "http://localhost:9021",
    "http://127.0.0.1",
    "http://127.0.0.1:9021",
};

const AUTH_USER = "admin";
const AUTH_PASS = "secret";

// --------------------------------------------------------- //

fn isAllowedOrigin(origin: []const u8) bool {
    for (ALLOWED_ORIGINS) |allowed| {
        if (std.mem.eql(u8, origin, allowed)) return true;
    }
    return false;
}

// Middleware: Origin check.
// Reads the Origin header and rejects requests whose origin is not in ALLOWED_ORIGINS.
// If no Origin header is present the request is rejected (403).
fn withOriginCheck(comptime next: zix.Http1.HandlerFn) zix.Http1.HandlerFn {
    return struct {
        fn handle(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
            const origin = zix.Http1.getHeader(head, "origin") orelse "";
            if (!isAllowedOrigin(origin)) {
                zix.Http1.writeJson(fd, 403, "{\"error\":\"forbidden origin\"}") catch {};
                return;
            }

            next(head, body, fd);
        }
    }.handle;
}

// Middleware: HTTP Basic authentication.
// Validates Authorization: Basic <base64(user:pass)> against AUTH_USER / AUTH_PASS.
// Returns 401 with WWW-Authenticate on missing or invalid credentials.
fn withBasicAuth(comptime next: zix.Http1.HandlerFn) zix.Http1.HandlerFn {
    return struct {
        fn handle(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
            const auth_header = zix.Http1.getHeader(head, "authorization") orelse {
                var buf: [256]u8 = undefined;
                const resp = std.fmt.bufPrint(
                    &buf,
                    "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"zix\"\r\nContent-Type: application/json\r\nContent-Length: 30\r\n\r\n{{\"error\":\"authorization required\"}}",
                    .{},
                ) catch return;
                zix.Http1.fdWriteAll(fd, resp) catch {};
                return;
            };

            const prefix = "Basic ";
            if (!std.mem.startsWith(u8, auth_header, prefix)) {
                zix.Http1.writeJson(fd, 400, "{\"error\":\"basic auth required\"}") catch {};
                return;
            }

            const encoded = auth_header[prefix.len..];
            var decoded_buf: [256]u8 = undefined;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
                zix.Http1.writeJson(fd, 400, "{\"error\":\"invalid base64 encoding\"}") catch {};
                return;
            };
            if (decoded_len > decoded_buf.len) {
                zix.Http1.writeJson(fd, 400, "{\"error\":\"credentials too long\"}") catch {};
                return;
            }
            std.base64.standard.Decoder.decode(decoded_buf[0..decoded_len], encoded) catch {
                zix.Http1.writeJson(fd, 400, "{\"error\":\"invalid base64 encoding\"}") catch {};
                return;
            };

            const decoded = decoded_buf[0..decoded_len];
            const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse {
                zix.Http1.writeJson(fd, 401, "{\"error\":\"malformed credentials\"}") catch {};
                return;
            };
            const user = decoded[0..colon];
            const pass = decoded[colon + 1 ..];

            if (!std.mem.eql(u8, user, AUTH_USER) or !std.mem.eql(u8, pass, AUTH_PASS)) {
                zix.Http1.writeJson(fd, 401, "{\"error\":\"invalid credentials\"}") catch {};
                return;
            }

            next(head, body, fd);
        }
    }.handle;
}

// --------------------------------------------------------- //

// GET /public
// Protected by origin check only.
//
// curl:
// curl -H "Origin: http://localhost" "http://localhost:9021/public"  # 200
// curl "http://localhost:9021/public"                                # 403
fn publicHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeJson(fd, 200, "{\"message\":\"public resource (origin verified)\"}") catch {};
}

// GET /private
// Protected by origin check then Basic auth (outer wrapper runs first).
//
// curl:
// curl -H "Origin: http://localhost" -u "admin:secret" "http://localhost:9021/private"  # 200
// curl -H "Origin: http://localhost" "http://localhost:9021/private"                    # 401
// curl "http://localhost:9021/private"                                                  # 403
fn privateHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeJson(fd, 200, "{\"message\":\"private resource (origin and credentials verified)\"}") catch {};
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/public", .handler = withOriginCheck(publicHandler) },
    .{ .path = "/private", .handler = withOriginCheck(withBasicAuth(privateHandler)) },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_gzip_out = MAX_GZIP_OUT,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
