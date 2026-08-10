//! RFC 10008 QUERY method wire checks, shared by all_runner.zig and
//! http_query_runner.zig.
//!
//! Walks the status map RFC 10008 section 2.1 defines against a running query
//! example, one raw request per case.
//!
//! A raw TCP socket is used rather than zix.Http.Client: the client wraps
//! std.http.Client, whose Method enum is a closed set that predates RFC 10008,
//! so it cannot put a QUERY on the wire over TCP at all.

const std = @import("std");
const common = @import("common.zig");
const wire = @import("wire.zig");

/// One request to send and what the answer must be.
const Case = struct {
    what: []const u8,
    method: []const u8,
    route: []const u8,
    content_type: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    body: []const u8 = "",
    want_status: u16,
    want_accept_query: bool = false,
    want_body_substr: ?[]const u8 = null,
};

const cases = [_]Case{
    .{
        .what = "a SQL question is answered",
        .method = "QUERY",
        .route = "/search",
        .content_type = "application/sql",
        .body = "SELECT name FROM users",
        .want_status = 200,
        .want_body_substr = "application/sql",
    },
    .{
        // The parameter must not change which type the route sees.
        .what = "a charset parameter is stripped before the type is matched",
        .method = "QUERY",
        .route = "/search",
        .content_type = "application/sql; charset=utf-8",
        .body = "SELECT name FROM users",
        .want_status = 200,
        .want_body_substr = "application/sql",
    },
    .{
        // Section 2: no content type means the content cannot be interpreted.
        .what = "a QUERY without a content type is refused",
        .method = "QUERY",
        .route = "/search",
        .body = "SELECT 1",
        .want_status = 400,
    },
    .{
        // Section 2.1: the body is never sniffed to recover a usable type.
        .what = "a content type the route does not accept draws 415 and Accept-Query",
        .method = "QUERY",
        .route = "/search",
        .content_type = "text/plain",
        .body = "SELECT 1",
        .want_status = 415,
        .want_accept_query = true,
    },
    .{
        // Understood and consistent, but this route cannot answer it.
        .what = "an accepted type the route cannot answer draws 422",
        .method = "QUERY",
        .route = "/search",
        .content_type = "application/graphql",
        .body = "{ user }",
        .want_status = 422,
    },
    .{
        .what = "an Accept the route cannot satisfy draws 406",
        .method = "QUERY",
        .route = "/search",
        .content_type = "application/sql",
        .accept = "text/html",
        .body = "SELECT 1",
        .want_status = 406,
    },
    .{
        .what = "a GET on the query route draws 405",
        .method = "GET",
        .route = "/search",
        .want_status = 405,
    },
    .{
        // RFC 9110 section 15.6.2, and it must not be mistaken for a bad request.
        .what = "an unimplemented method draws 501",
        .method = "BREW",
        .route = "/status",
        .want_status = 501,
    },
    .{
        // RFC 9110 section 9.1: method names are case-sensitive. Both HTTP/1
        // engines read one method table, so both answer this the same way.
        .what = "a lowercase query token is not the QUERY method",
        .method = "query",
        .route = "/search",
        .content_type = "application/sql",
        .body = "SELECT 1",
        .want_status = 501,
    },
    .{
        .what = "the GET route names what the query route accepts",
        .method = "GET",
        .route = "/status",
        .want_status = 200,
        .want_accept_query = true,
    },
};

// --------------------------------------------------------- //

/// Build one raw HTTP/1.1 request. Connection: close, so the server closes after
/// the body and the read side sees a clean end.
fn buildRequest(buf: []u8, case: Case) ![]const u8 {
    var len: usize = 0;

    len += (try std.fmt.bufPrint(buf[len..], "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n", .{ case.method, case.route })).len;
    if (case.content_type) |value| {
        len += (try std.fmt.bufPrint(buf[len..], "Content-Type: {s}\r\n", .{value})).len;
    }
    if (case.accept) |value| {
        len += (try std.fmt.bufPrint(buf[len..], "Accept: {s}\r\n", .{value})).len;
    }
    len += (try std.fmt.bufPrint(buf[len..], "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ case.body.len, case.body })).len;

    return buf[0..len];
}

/// Send one request on its own connection and read the whole answer.
fn exchange(io: std.Io, port: u16, case: Case, out: []u8) ![]const u8 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var req_buf: [1024]u8 = undefined;
    const req = try buildRequest(&req_buf, case);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(req);
    try writer.interface.flush();

    var read_buf: [2048]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var total: usize = 0;
    while (total < out.len) {
        const read = reader.interface.readSliceShort(out[total..]) catch break;
        if (read == 0) break;
        total += read;
    }

    return out[0..total];
}

/// The status line code, or an error when the answer is not an HTTP response.
fn statusOf(resp: []const u8) !u16 {
    const prefix = "HTTP/1.1 ";
    if (!std.mem.startsWith(u8, resp, prefix)) return error.NotAnHttpResponse;

    const rest = resp[prefix.len..];
    if (rest.len < 3) return error.TruncatedStatusLine;

    return std.fmt.parseInt(u16, rest[0..3], 10) catch error.BadStatusLine;
}

fn headOf(resp: []const u8) []const u8 {
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return resp;

    return resp[0..head_end];
}

fn bodyOf(resp: []const u8) []const u8 {
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return &.{};

    return resp[head_end + 4 ..];
}

/// Spawn a query example and walk every case against it.
///
/// Note:
/// - Works unchanged against both engines: the examples serve the same routes
///   on different ports, which is what proves the two answer alike
///
/// Param:
/// io - std.Io
/// server_path - []const u8 (the built example binary)
/// port - u16 (the port that example listens on)
///
/// Return:
/// - void
/// - An error naming the first case that answered wrong
pub fn runHttpQuery(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var resp_buf: [8192]u8 = undefined;

    for (cases) |case| {
        const resp = try exchange(io, port, case, &resp_buf);
        const status = try statusOf(resp);

        if (status != case.want_status) {
            std.debug.print("FAIL query case: {s}, got {d} want {d}\n", .{ case.what, status, case.want_status });
            return error.ZixUnexpectedStatus;
        }

        if (case.want_accept_query and wire.headerValue(headOf(resp), "accept-query") == null) {
            std.debug.print("FAIL query case: {s}, no Accept-Query header\n", .{case.what});
            return error.MissingAcceptQuery;
        }

        if (case.want_body_substr) |want| {
            if (!std.mem.containsAtLeast(u8, bodyOf(resp), 1, want)) {
                std.debug.print("FAIL query case: {s}, body does not name {s}\n", .{ case.what, want });
                return error.UnexpectedBody;
            }
        }
    }
}
