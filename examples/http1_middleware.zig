//! ZIX example http1 middleware
//!
//! ### file: examples/http1_middleware.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that wraps route handlers with an origin check and
//! HTTP Basic authentication.
//!
//! ### note:
//!
//! Middleware is composed at comptime. Each wrapper takes the next HandlerFn and
//! returns a new one. withOriginCheck(withBasicAuth(handler)) runs the origin
//! check first, then basic auth, then the handler.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9021;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel = .ASYNC;

const ALLOWED_ORIGINS = [_][]const u8{
    "http://localhost",
    "http://localhost:9021",
    "http://127.0.0.1",
    "http://127.0.0.1:9021",
};

const AUTH_USER:[]const u8 = "admin";
const AUTH_PASS:[]const u8 = "secret";

// --------------------------------------------------------- //

fn isAllowedOrigin(origin: []const u8) bool {
    for (ALLOWED_ORIGINS) |allowed| {
        if (std.mem.eql(u8, origin, allowed)) return true;
    }

    return false;
}

fn sendError(res: *zix.Http1.Response, status: zix.Http1.Status.Code, body: []const u8) !void {
    res.setStatus(status);

    try res.sendJson(body);
}

/// Middleware: origin check.
///
/// Note:
/// - A request with no Origin header, or one not in ALLOWED_ORIGINS, gets 403.
///
/// Param:
/// next - zix.Http1.HandlerFn (the handler to run when the origin is allowed)
///
/// Return:
/// - zix.Http1.HandlerFn
fn withOriginCheck(comptime next: zix.Http1.HandlerFn) zix.Http1.HandlerFn {
    return struct {
        fn handle(
            req: *zix.Http1.Request,
            res: *zix.Http1.Response,
            ctx: *zix.Http1.Context,
        ) anyerror!void {
            const origin = req.header("origin") orelse "";
            if (!isAllowedOrigin(origin)) {
                return sendError(res, .FORBIDDEN, "{\"error\":\"forbidden origin\"}");
            }

            return next(req, res, ctx);
        }
    }.handle;
}

/// Middleware: HTTP Basic authentication.
///
/// Note:
/// - Checks `Authorization: Basic <base64(user:pass)>` against AUTH_USER and
///   AUTH_PASS.
/// - A missing header gets 401 with a WWW-Authenticate challenge.
///
/// Param:
/// next - zix.Http1.HandlerFn (the handler to run when the credentials match)
///
/// Return:
/// - zix.Http1.HandlerFn
fn withBasicAuth(comptime next: zix.Http1.HandlerFn) zix.Http1.HandlerFn {
    return struct {
        fn handle(
            req: *zix.Http1.Request,
            res: *zix.Http1.Response,
            ctx: *zix.Http1.Context,
        ) anyerror!void {
            const auth_header = req.header("authorization") orelse {
                try res.addHeader("WWW-Authenticate", "Basic realm=\"zix\"");

                return sendError(
                    res,
                    .UNAUTHORIZED,
                    "{\"error\":\"authorization required\"}",
                );
            };

            const prefix = "Basic ";
            if (!std.mem.startsWith(u8, auth_header, prefix)) {
                return sendError(res, .BAD_REQUEST, "{\"error\":\"basic auth required\"}");
            }

            const encoded = auth_header[prefix.len..];
            var decoded_buf: [256]u8 = undefined;

            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
                return sendError(
                    res,
                    .BAD_REQUEST,
                    "{\"error\":\"invalid base64 encoding\"}",
                );
            };
            if (decoded_len > decoded_buf.len) {
                return sendError(res, .BAD_REQUEST, "{\"error\":\"credentials too long\"}");
            }

            std.base64.standard.Decoder.decode(decoded_buf[0..decoded_len], encoded) catch {
                return sendError(
                    res,
                    .BAD_REQUEST,
                    "{\"error\":\"invalid base64 encoding\"}",
                );
            };

            const decoded = decoded_buf[0..decoded_len];
            const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse {
                return sendError(
                    res,
                    .UNAUTHORIZED,
                    "{\"error\":\"malformed credentials\"}",
                );
            };

            const user = decoded[0..colon];
            const pass = decoded[colon + 1 ..];
            if (!std.mem.eql(u8, user, AUTH_USER) or !std.mem.eql(u8, pass, AUTH_PASS)) {
                return sendError(res, .UNAUTHORIZED, "{\"error\":\"invalid credentials\"}");
            }

            return next(req, res, ctx);
        }
    }.handle;
}

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
    .{
        .path = "/public",
        .handler = withOriginCheck(publicHandler),
    },
    .{
        .path = "/private",
        .handler = withOriginCheck(withBasicAuth(privateHandler)),
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}

