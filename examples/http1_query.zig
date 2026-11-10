//! ZIX example http1 query
//!
//! ### file: examples/http1_query.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that answers the QUERY method (RFC 10008) on /search.
//!
//! ### note:
//!
//! The engine parses QUERY, but which query content types a route accepts is
//! the route's own policy. An unknown type gets 415 with Accept-Query.
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
const PORT:u16 = 9079;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

// The query content types /search answers. RFC 10008 section 3 puts this list
// on the wire as Accept-Query when a request names a type not in it.
const ACCEPT_QUERY:[]const u8 = "application/sql, application/graphql";

// --------------------------------------------------------- //

/// Whether /search can answer a question written in this media type.
///
/// Param:
/// content_type - zix.Http1.ContentType (already stripped of its parameters)
///
/// Return:
/// - bool
fn acceptsQueryType(content_type: zix.Http1.ContentType) bool {
    return switch (content_type) {
        .APPLICATION_SQL, .APPLICATION_GRAPHQL => true,
        else => false,
    };
}

/// Whether the client's Accept header leaves room for a JSON answer.
///
/// Param:
/// accept - ?[]const u8 (the raw Accept header, absent means anything goes)
///
/// Return:
/// - bool
fn acceptsJson(accept: ?[]const u8) bool {
    const value = accept orelse return true;

    return std.mem.indexOf(u8, value, "application/json") != null or
        std.mem.indexOf(u8, value, "*/*") != null;
}

/// Answer a question, or report that this route cannot.
///
/// Note:
/// - Stands in for a real query engine. A SQL question is answered, a GraphQL
///   one is understood but declined, which is what separates 422 from 415.
///
/// Param:
/// content_type - zix.Http1.ContentType (the type the question is written in)
/// query - []const u8 (the request content, never inspected to guess its type)
///
/// Return:
/// - usize (how many rows the question matched)
/// - null when the type is understood but the question cannot be answered
fn rowsMatching(content_type: zix.Http1.ContentType, query: []const u8) ?usize {
    if (content_type != .APPLICATION_SQL) return null;

    return std.mem.count(u8, query, " ");
}

/// Refuse a media type this route does not accept, naming the ones it does.
fn sendUnsupportedType(res: *zix.Http1.Response) !void {
    res.setStatus(.UNSUPPORTED_MEDIA_TYPE);
    try res.addHeader("Accept-Query", ACCEPT_QUERY);

    try res.sendJson("{\"ok\":false,\"message\":\"unsupported query content type\"}");
}

// QUERY /search
// curl usage:
// curl -X QUERY "http://localhost:9079/search" \
//     -H "Content-Type: application/sql" -d "SELECT name FROM users"
fn searchHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    _: *zix.Http1.Context,
) !void {
    if (req.method() != .QUERY) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"ok\":false,\"message\":\"this route answers QUERY only\"}");
        return;
    }

    if (!acceptsJson(req.header("accept"))) {
        res.setStatus(.NOT_ACCEPTABLE);

        try res.sendJson("{\"ok\":false,\"message\":\"this route answers application/json\"}");
        return;
    }

    // Section 2 refuses a QUERY with no content type, and section 2.1 forbids
    // sniffing the body to recover it. An absent header ends here.
    const header_value = req.header("content-type") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"content-type is required\"}");
        return;
    };

    // typeFromHeader strips any parameters, so "application/sql; charset=utf-8"
    // resolves to the same type as the bare value.
    const content_type = zix.Http1.Content.typeFromHeader(header_value) orelse {
        return sendUnsupportedType(res);
    };

    if (!acceptsQueryType(content_type)) return sendUnsupportedType(res);

    const query = req.body();
    if (query.len == 0) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"query content is empty\"}");
        return;
    }

    const rows = rowsMatching(content_type, query) orelse {
        res.setStatus(.UNPROCESSABLE_ENTITY);

        try res.sendJson(
            "{\"ok\":false,\"message\":\"the query is understood but cannot be answered\"}",
        );
        return;
    };

    var buf: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"message\":\"\",\"data\":{{\"type\":\"{s}\",\"rows\":{d}}}}}",
        .{
            content_type.asString(),
            rows,
        },
    );

    try res.sendJson(json);
}

// GET /status
// A plain GET route, so the server can be reached without a QUERY client.
// curl usage: curl -X GET "http://localhost:9079/status"
fn statusHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    try res.addHeader("Accept-Query", ACCEPT_QUERY);

    try res.sendJson("{\"ok\":true,\"message\":\"\",\"data\":{\"server\":\"zix\"}}");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/search",
        .handler = searchHandler,
    },
    .{
        .path = "/status",
        .handler = statusHandler,
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

