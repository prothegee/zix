const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9003;
const DISPATCH_MODEL: zix.Http.DispatchModel = .POOL;
const KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = auto (cpu_count accept threads)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) pool threads)

// Middleware is composed at comptime using wrapper functions.
// Each wrapper takes a 'next' handler (comptime-known) and returns a new HandlerFn.
// Compose left-to-right: withOriginCheck(withBasicAuth(handler)) runs origin first,
// then basic auth, then the actual handler.

// --------------------------------------------------------- //

// Allowed origins. Extend this list as needed.
const ALLOWED_ORIGINS = [_][]const u8{
    "http://localhost",
    "http://localhost:9003",
    "http://127.0.0.1",
    "http://127.0.0.1:9003",
};

// Basic auth credentials.
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
//
// Usage:
// server.registerHandler("/path", withOriginCheck(myHandler));
fn withOriginCheck(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
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
//
// Usage (standalone):
// server.registerHandler("/path", withBasicAuth(myHandler));
//
// Usage (composed, origin check runs first):
// server.registerHandler("/path", withOriginCheck(withBasicAuth(myHandler)));
fn withBasicAuth(comptime next: zix.Http.HandlerFn) zix.Http.HandlerFn {
    return struct {
        fn handle(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) anyerror!void {
            const auth_header = req.header("authorization") orelse {
                res.setStatus(.UNAUTHORIZED);
                try res.addHeader("WWW-Authenticate", "Basic realm=\"zix\"");
                try res.sendJson("{\"error\":\"authorization required\"}");
                return;
            };

            const prefix = "Basic ";
            if (!std.mem.startsWith(u8, auth_header, prefix)) {
                res.setStatus(.UNAUTHORIZED);
                try res.addHeader("WWW-Authenticate", "Basic realm=\"zix\"");
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

            // Split "user:pass" at the first ':'
            const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse {
                res.setStatus(.UNAUTHORIZED);
                try res.sendJson("{\"error\":\"malformed credentials\"}");
                return;
            };
            const user = decoded[0..colon];
            const pass = decoded[colon + 1 ..];

            if (!std.mem.eql(u8, user, AUTH_USER) or !std.mem.eql(u8, pass, AUTH_PASS)) {
                res.setStatus(.UNAUTHORIZED);
                try res.addHeader("WWW-Authenticate", "Basic realm=\"zix\"");
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
// curl -H "Origin: http://localhost" "http://localhost:9003/public"  # 200
// curl "http://localhost:9003/public"                                # 403
pub fn publicHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.sendJson("{\"message\":\"public resource, origin verified\"}");
}

// GET /private
// Protected by origin check then Basic auth (outer wrapper runs first).
//
// curl:
// curl -H "Origin: http://localhost" -u "admin:secret" "http://localhost:9003/private"  # 200
// curl -H "Origin: http://localhost" "http://localhost:9003/private"                    # 401
// curl "http://localhost:9003/private"                                                  # 403
pub fn privateHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.sendJson("{\"message\":\"private resource, origin and credentials verified\"}");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Http.Route{
    // /public: origin check only
    .{ .path = "/public", .handler = withOriginCheck(publicHandler) },
    // /private: origin check + basic auth (composed: left = outermost = runs first)
    .{ .path = "/private", .handler = withOriginCheck(withBasicAuth(privateHandler)) },
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
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
