const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9021;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
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
        fn handle(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) anyerror!void {
            const origin = req.header("origin") orelse "";
            if (!isAllowedOrigin(origin)) {
                res.setStatus(.FORBIDDEN);

                try res.sendJson("{\"error\":\"forbidden origin\"}");
                return;
            }

            return next(req, res, ctx);
        }
    }.handle;
}

// Middleware: HTTP Basic authentication.
// Validates Authorization: Basic <base64(user:pass)> against AUTH_USER / AUTH_PASS.
// Returns 401 with WWW-Authenticate on missing or invalid credentials.
fn withBasicAuth(comptime next: zix.Http1.HandlerFn) zix.Http1.HandlerFn {
    return struct {
        fn handle(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) anyerror!void {
            const auth_header = req.header("authorization") orelse {
                // 401 carries WWW-Authenticate, which res.json cannot add, so the raw
                // response is hand-built and written verbatim through res.raw.
                var buf: [256]u8 = undefined;
                const unauthorized = std.fmt.bufPrint(
                    &buf,
                    "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"zix\"\r\nContent-Type: application/json\r\nContent-Length: 34\r\n\r\n{{\"error\":\"authorization required\"}}",
                    .{},
                ) catch return;

                try res.sendRaw(unauthorized);
                return;
            };

            const prefix = "Basic ";
            if (!std.mem.startsWith(u8, auth_header, prefix)) {
                res.setStatus(.BAD_REQUEST);

                try res.sendJson("{\"error\":\"basic auth required\"}");
                return;
            }

            const encoded = auth_header[prefix.len..];
            var decoded_buf: [256]u8 = undefined;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
                res.setStatus(.BAD_REQUEST);

                try res.sendJson("{\"error\":\"invalid base64 encoding\"}");
                return;
            };
            if (decoded_len > decoded_buf.len) {
                res.setStatus(.BAD_REQUEST);

                try res.sendJson("{\"error\":\"credentials too long\"}");
                return;
            }
            std.base64.standard.Decoder.decode(decoded_buf[0..decoded_len], encoded) catch {
                res.setStatus(.BAD_REQUEST);

                try res.sendJson("{\"error\":\"invalid base64 encoding\"}");
                return;
            };

            const decoded = decoded_buf[0..decoded_len];
            const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse {
                res.setStatus(.UNAUTHORIZED);

                try res.sendJson("{\"error\":\"malformed credentials\"}");
                return;
            };
            const user = decoded[0..colon];
            const pass = decoded[colon + 1 ..];

            if (!std.mem.eql(u8, user, AUTH_USER) or !std.mem.eql(u8, pass, AUTH_PASS)) {
                res.setStatus(.UNAUTHORIZED);

                try res.sendJson("{\"error\":\"invalid credentials\"}");
                return;
            }

            return next(req, res, ctx);
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
fn publicHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    try res.sendJson("{\"message\":\"public resource (origin verified)\"}");
}

// GET /private
// Protected by origin check then Basic auth (outer wrapper runs first).
//
// curl:
// curl -H "Origin: http://localhost" -u "admin:secret" "http://localhost:9021/private"  # 200
// curl -H "Origin: http://localhost" "http://localhost:9021/private"                    # 401
// curl "http://localhost:9021/private"                                                  # 403
fn privateHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    try res.sendJson("{\"message\":\"private resource (origin and credentials verified)\"}");
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
        .compression_max_out = COMPRESSION_MAX_OUT,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
