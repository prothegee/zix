//! ZIX example http1 xtra headers
//!
//! ### file: examples/http1_xtra_headers.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that adds custom response headers with res.addHeader.
//!
//! ### note:
//!
//! max_response_headers caps the custom headers on one response (16 here).
//! addHeader rejects the header past the cap and any CR or LF in a name or value.
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

const builtin = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9026;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
const MAX_RESPONSE_HEADERS:zix.Http1.HeaderSize = .MINIMAL;

// --------------------------------------------------------- //

const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Add every header in order, stopping at the first one addHeader rejects.
fn addHeaders(res: *zix.Http1.Response, headers: []const Header) !void {
    for (headers) |header| try res.addHeader(header.name, header.value);
}

// GET /info
// Returns a JSON body with several custom headers attached.
// curl usage: curl -i "http://localhost:9026/info"
fn infoHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const headers = [_]Header{
        .{
            .name = "X-Server",
            .value = "zix",
        },
        .{
            .name = "X-Version",
            .value = "X.Y.Z",
        },
        .{
            .name = "Cache-Control",
            .value = "no-store",
        },
        .{
            .name = "Vary",
            .value = "Accept-Encoding",
        },
        .{
            .name = "X-Frame-Options",
            .value = "DENY",
        },
        .{
            .name = "X-Content-Type-Options",
            .value = "nosniff",
        },
    };

    try addHeaders(res, &headers);

    try res.sendJson("{\"status\":\"ok\",\"note\":\"6 headers added\"}");
}

// GET /cors
// A CORS preflight-style response with multiple headers.
// curl usage: curl -i "http://localhost:9026/cors"
fn corsHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const headers = [_]Header{
        .{
            .name = "Access-Control-Allow-Origin",
            .value = "*",
        },
        .{
            .name = "Access-Control-Allow-Methods",
            .value = "GET, POST, PUT, DELETE, OPTIONS",
        },
        .{
            .name = "Access-Control-Allow-Headers",
            .value = "Content-Type, Authorization, X-Request-ID",
        },
        .{
            .name = "Access-Control-Max-Age",
            .value = "86400",
        },
        .{
            .name = "Vary",
            .value = "Origin",
        },
    };

    try addHeaders(res, &headers);

    try res.sendJson("{\"status\":\"ok\",\"note\":\"5 CORS headers added\"}");
}

// GET /overflow
// Adds one header past the cap. The 16 accepted headers stay on the 500 answer.
// curl usage: curl -i "http://localhost:9026/overflow"
fn overflowHandler(
    _: *zix.Http1.Request,
    res: *zix.Http1.Response,
    _: *zix.Http1.Context,
) !void {
    const count = comptime MAX_RESPONSE_HEADERS.value() + 1;

    var name_store: [count][16]u8 = undefined;
    for (0..count) |index| {
        const name = try std.fmt.bufPrint(&name_store[index], "X-Header-{d}", .{index});

        res.addHeader(name, "1") catch |err| {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(
                &buf,
                "{{\"error\":\"{s}\",\"note\":\"cap is {d}\"}}",
                .{
                    @errorName(err),
                    MAX_RESPONSE_HEADERS.value(),
                },
            );

            res.setStatus(.INTERNAL_SERVER_ERROR);

            try res.sendJson(msg);
            return;
        };
    }

    try res.sendJson("{\"status\":\"ok\"}");
}

// GET /inject-guard
// Shows the CR/LF guard rejecting a crafted header value.
// curl usage: curl -i "http://localhost:9026/inject-guard"
fn injectGuardHandler(
    _: *zix.Http1.Request,
    res: *zix.Http1.Response,
    _: *zix.Http1.Context,
) !void {
    res.addHeader("X-Safe", "legit\r\nX-Injected: attack") catch |err| {
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(
            &buf,
            "{{\"error\":\"{s}\",\"note\":\"CR/LF in header value rejected\"}}",
            .{@errorName(err)},
        );

        res.setStatus(.BAD_REQUEST);

        try res.sendJson(msg);
        return;
    };

    try res.sendJson("{\"status\":\"ok\"}");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/info",
        .handler = infoHandler,
    },
    .{
        .path = "/cors",
        .handler = corsHandler,
    },
    .{
        .path = "/overflow",
        .handler = overflowHandler,
    },
    .{
        .path = "/inject-guard",
        .handler = injectGuardHandler,
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
        .max_response_headers = MAX_RESPONSE_HEADERS,
    });
    defer server.deinit();

    try server.run();
}

