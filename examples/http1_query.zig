const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9079;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const WORKERS: usize = 0; // ignored by .ASYNC

// The query content types /search knows how to answer. RFC 10008 section 3 puts
// this list on the wire as Accept-Query whenever a request names a type that is
// not in it, so a client learns what to send instead of guessing.
const ACCEPT_QUERY: []const u8 = "application/sql, application/graphql";

// --------------------------------------------------------- //

/// Whether /search can answer a question written in this media type.
///
/// Note:
/// - The engine parses and classifies QUERY, but which types a route accepts is
///   the route's own policy: the engine cannot know a route's schema
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
///   one is understood but declined, which is what separates 422 from 415
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

// --------------------------------------------------------- //

// curl usage: curl -X QUERY "http://localhost:9079/search" -H "Content-Type: application/sql" -d "SELECT name FROM users"
fn searchHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
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

    // Section 2 refuses a QUERY whose content type is missing, and section 2.1
    // forbids sniffing the body to recover it. An absent header ends here.
    const header_value = req.header("content-type") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"content-type is required\"}");
        return;
    };

    // typeFromHeader strips any parameters, so "application/sql; charset=utf-8"
    // resolves to the same type as the bare value.
    const content_type = zix.Http1.Content.typeFromHeader(header_value) orelse {
        try sendUnsupportedType(res);
        return;
    };

    if (!acceptsQueryType(content_type)) {
        try sendUnsupportedType(res);
        return;
    }

    const query = try req.body();
    if (query.len == 0) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"query content is empty\"}");
        return;
    }

    const rows = rowsMatching(content_type, query) orelse {
        res.setStatus(.UNPROCESSABLE_ENTITY);

        try res.sendJson("{\"ok\":false,\"message\":\"the query is understood but cannot be answered\"}");
        return;
    };

    var buf: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"message\":\"\",\"data\":{{\"type\":\"{s}\",\"rows\":{d}}}}}",
        .{ content_type.asString(), rows },
    );

    try res.sendJson(json);
}

// curl usage: curl -X GET "http://localhost:9079/status"
fn statusHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    // A plain GET route, so the same server can be reached without a QUERY
    // client. QUERY is safe and idempotent, so /search changes nothing either.
    try res.addHeader("Accept-Query", ACCEPT_QUERY);

    try res.sendJson("{\"ok\":true,\"message\":\"\",\"data\":{\"server\":\"zix\"}}");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/search", .handler = searchHandler },
    .{ .path = "/status", .handler = statusHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
