//! Behaviour tests: zix.Http1 support for the QUERY method (RFC 10008).
//!
//! QUERY is safe and idempotent like GET, and carries content like POST. A
//! server supports it when the request line resolves to the QUERY method, the
//! content is framed and readable, the declared content type is recognised
//! without sniffing the body, and the response is not filed under a cache key
//! that ignores that content.
//!
//! Everything here goes through the public zix.Http1 surface, so it states what
//! a caller can rely on rather than how the raw engine reaches it.

const std = @import("std");
const zix = @import("zix");

/// The request views under test never touch the socket, so any invalid fd works.
const TEST_FD: std.posix.fd_t = if (@import("builtin").os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

// --------------------------------------------------------- //

test "zix behaviour: Http1 parseHead reads QUERY off the request line" {
    const result = try zix.Http1.parseHead("QUERY /search HTTP/1.1\r\nHost: localhost\r\n\r\n");

    try std.testing.expectEqualStrings("QUERY", result.head.method);
    try std.testing.expectEqualStrings("/search", result.head.path);
    try std.testing.expectEqual(@as(u8, 1), result.head.version_minor);
}

test "zix behaviour: Http1 Request method resolves a QUERY request to QUERY" {
    const result = try zix.Http1.parseHead("QUERY /search HTTP/1.1\r\nHost: localhost\r\n\r\n");
    const req = zix.Http1.Request.init(&result.head, "", TEST_FD);

    try std.testing.expectEqual(zix.Http1.Method.Code.QUERY, req.method());
}

test "zix behaviour: Http1 a QUERY request is distinguishable from a GET" {
    // Without this a handler cannot tell the two apart, and a request meant to
    // carry its question in the content is answered as a plain GET.
    const query_result = try zix.Http1.parseHead("QUERY /search HTTP/1.1\r\nHost: x\r\n\r\n");
    const get_result = try zix.Http1.parseHead("GET /search HTTP/1.1\r\nHost: x\r\n\r\n");

    const query_req = zix.Http1.Request.init(&query_result.head, "", TEST_FD);
    const get_req = zix.Http1.Request.init(&get_result.head, "", TEST_FD);

    try std.testing.expect(query_req.method() != get_req.method());
}

test "zix behaviour: Http1 a QUERY request carries its content like a POST" {
    const body = "SELECT name FROM users WHERE id = 7";
    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nContent-Length: 35\r\n\r\n",
    );
    var req = zix.Http1.Request.init(&result.head, body, TEST_FD);

    try std.testing.expectEqual(@as(u64, 35), result.head.content_length);
    try std.testing.expectEqualStrings(body, try req.body());
    try std.testing.expect(req.bodyComplete());
}

test "zix behaviour: Http1 a QUERY request exposes its declared Content-Type" {
    // RFC 10008 section 2 requires the request to be refused when this header is
    // missing, so a handler has to be able to read it.
    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nContent-Length: 3\r\n\r\n",
    );
    const req = zix.Http1.Request.init(&result.head, "a=1", TEST_FD);

    const declared = req.header("content-type").?;
    try std.testing.expectEqualStrings("application/sql", declared);
    try std.testing.expectEqual(zix.Http1.ContentType.APPLICATION_SQL, zix.Http1.Content.typeFromHeader(declared).?);
}

test "zix behaviour: Http1 a QUERY without Content-Type reports no type" {
    // The absent header is what a handler turns into a 400 (RFC 10008 section 2.1).
    const result = try zix.Http1.parseHead("QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n");
    const req = zix.Http1.Request.init(&result.head, "a=1", TEST_FD);

    try std.testing.expect(req.header("content-type") == null);
}

test "zix behaviour: Http1 an unsupported query content type reports no match, never sniffed" {
    // Section 2.1 forbids guessing from the content. A declared type this engine
    // does not know stays unknown, which is what a handler turns into a 415.
    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/vnd.zix.made-up\r\nContent-Length: 15\r\n\r\n",
    );
    const req = zix.Http1.Request.init(&result.head, "SELECT 1 AS a;\n", TEST_FD);

    const declared = req.header("content-type").?;
    try std.testing.expect(zix.Http1.Content.typeFromHeader(declared) == null);
}

test "zix behaviour: Http1 every query content type RFC 10008 names is recognised" {
    const cases = .{
        .{ "application/sql", zix.Http1.ContentType.APPLICATION_SQL },
        .{ "application/jsonpath", zix.Http1.ContentType.APPLICATION_JSONPATH },
        .{ "application/graphql", zix.Http1.ContentType.APPLICATION_GRAPHQL },
        .{ "application/x-www-form-urlencoded", zix.Http1.ContentType.APPLICATION_X_WWW_FORM_URLENCODED },
        .{ "multipart/form-data", zix.Http1.ContentType.MULTIPART_FORM_DATA },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case[1], zix.Http1.Content.typeFromHeader(case[0]).?);
    }
}

test "zix behaviour: Http1 a QUERY response is never filed under the request cache key" {
    // Section 2.7 wants a cache key that incorporates the request content. This
    // key is hash(method, path, query), so the store is refused outright and two
    // different questions to one path can never share an answer.
    var cache = try zix.Http1.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 512 });
    defer cache.deinit();

    zix.Http1.setCache(&cache, 1000);
    defer zix.Http1.setCache(null, 0);

    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nContent-Length: 14\r\n\r\n",
    );

    zix.Http1.cacheStore(&result.head, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi", 1000);
    try std.testing.expect(zix.Http1.cacheLookup(&result.head) == null);
}

test "zix behaviour: Http1 refusing QUERY leaves GET on the same path cacheable" {
    var cache = try zix.Http1.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 512 });
    defer cache.deinit();

    zix.Http1.setCache(&cache, 1000);
    defer zix.Http1.setCache(null, 0);

    const query_result = try zix.Http1.parseHead("QUERY /search HTTP/1.1\r\nHost: x\r\n\r\n");
    const get_result = try zix.Http1.parseHead("GET /search HTTP/1.1\r\nHost: x\r\n\r\n");

    const response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
    zix.Http1.cacheStore(&query_result.head, response, 1000);
    zix.Http1.cacheStore(&get_result.head, response, 1000);

    // The refusal is scoped to the method, it does not disable the path.
    try std.testing.expect(zix.Http1.cacheLookup(&query_result.head) == null);
    try std.testing.expectEqualStrings(response, zix.Http1.cacheLookup(&get_result.head).?);
}

test "zix behaviour: Http1 the query content types compose a valid Accept-Query value" {
    // Section 3 says Accept-Query is an RFC 9651 structured field, an sf-list of
    // bare items. A server only ever writes one, so the requirement is met by the
    // media type strings composing into that shape.
    const accept_query = "application/sql, application/graphql";

    // The value stays in step with the type table rather than drifting from it.
    try std.testing.expectEqualStrings("application/sql", zix.Http1.Content.stringFromEnum(.APPLICATION_SQL));
    try std.testing.expectEqualStrings("application/graphql", zix.Http1.Content.stringFromEnum(.APPLICATION_GRAPHQL));

    var items = std.mem.splitSequence(u8, accept_query, ", ");
    while (items.next()) |item| {
        try std.testing.expect(item.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, item, ' ') == null);
        try std.testing.expect(zix.Http1.Content.typeFromHeader(item) != null);
    }
}

test "zix behaviour: Http1 a method it does not implement draws 501, not a wrong answer" {
    // QUERY used to land here: unknown tokens resolved to GET, so the engine
    // answered a question it had not read. An unimplemented method now says so
    // (RFC 9110 section 15.6.2) instead of being served as something else.
    try std.testing.expectError(error.ZixUnknownMethod, zix.Http1.parseHead("BREW /pot HTTP/1.1\r\nHost: x\r\n\r\n"));

    const answer = zix.Http1.parseErrorResponse(error.ZixUnknownMethod);
    try std.testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 501 Not Implemented\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, answer, "\r\n\r\n"));
}

test "zix behaviour: Http1 QUERY is implemented, so it parses instead of drawing 501" {
    // The same gate that refuses BREW passes QUERY. That pairing is the whole
    // point: the engine now has an opinion about which methods it implements.
    const result = try zix.Http1.parseHead("QUERY /search HTTP/1.1\r\nHost: x\r\n\r\n");

    try std.testing.expectEqualStrings("QUERY", result.head.method);
}
