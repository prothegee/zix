//! Edge tests: zix.Http1 QUERY method boundary conditions (RFC 10008).
//!
//! A QUERY request puts two peer-controlled values on paths that used to be
//! reached only by methods without content: the method token itself and the
//! Content-Type header. Both are bounded here, along with the framing cases a
//! query body runs into once it outgrows what a GET target could hold.

const std = @import("std");
const zix = @import("zix");

/// The request views under test never touch the socket, so any invalid fd works.
const TEST_FD: std.posix.fd_t = if (@import("builtin").os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

// --------------------------------------------------------- //

test "zix edge: Http1 a lowercase method token is refused, not folded" {
    // RFC 9110 section 9.1 makes method names case-sensitive. Both HTTP/1
    // engines now read one method table, so the same token gets the same
    // answer whichever engine serves it.
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http1.parseHead("query /search HTTP/1.1\r\nHost: x\r\n\r\n"),
    );
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http1.parseHead("QuErY /search HTTP/1.1\r\nHost: x\r\n\r\n"),
    );
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http1.parseHead("get /search HTTP/1.1\r\nHost: x\r\n\r\n"),
    );
}

test "zix edge: Http1 and Http answer a lowercase method the same way" {
    // The two engines used to disagree here: one folded the token, the other
    // matched exactly. This pins them together so the split cannot come back.
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http1.parseHead("query /search HTTP/1.1\r\nHost: x\r\n\r\n"),
    );
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http.Request.fromRaw("query /search HTTP/1.1\r\nHost: x\r\n\r\n", std.testing.allocator),
    );
}

test "zix edge: Http1 a method token past the known maximum is refused, not truncated" {
    // The token is peer-controlled. It must be bounded before the lowercase copy,
    // not copied and then measured.
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http1.parseHead("PROPPATCH /search HTTP/1.1\r\nHost: x\r\n\r\n"),
    );
    try std.testing.expect(zix.Http1.Method.codeFromString("PROPPATCH") == null);
}

test "zix edge: Http1 an unimplemented method answers 501, a broken line answers 400" {
    // Before RFC 10008 support, QUERY itself landed in the unknown bucket and the
    // engine answered as though it were a GET. Now the two failures stay apart all
    // the way to the status line.
    try std.testing.expectError(error.UnknownMethod, zix.Http1.parseHead("BREW /pot HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.InvalidRequest, zix.Http1.parseHead("GET\r\n\r\n"));

    try std.testing.expect(std.mem.startsWith(
        u8,
        zix.Http1.parseErrorResponse(error.UnknownMethod),
        "HTTP/1.1 501 Not Implemented\r\n",
    ));
    try std.testing.expect(std.mem.startsWith(
        u8,
        zix.Http1.parseErrorResponse(error.InvalidRequest),
        "HTTP/1.1 400 Bad Request\r\n",
    ));
}

test "zix edge: Http1 a malformed request line is not reported as an unknown method" {
    // A line that never tokenized says nothing about the method, so it must not
    // draw a 501.
    try std.testing.expectError(error.InvalidRequest, zix.Http1.parseHead("GET /x\r\n\r\n"));
    try std.testing.expectError(error.InvalidRequest, zix.Http1.parseHead("GET /x HTTP/9.9\r\n\r\n"));
}

test "zix edge: Http1 a QUERY with an empty method-adjacent target still parses" {
    const result = try zix.Http1.parseHead("QUERY / HTTP/1.1\r\nHost: x\r\n\r\n");

    try std.testing.expectEqualStrings("QUERY", result.head.method);
    try std.testing.expectEqualStrings("/", result.head.path);
}

test "zix edge: Http1 a QUERY with zero Content-Length frames as bodyless" {
    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nContent-Type: application/sql\r\nContent-Length: 0\r\n\r\n",
    );
    var req = zix.Http1.Request.init(&result.head, "", TEST_FD);

    try std.testing.expectEqual(@as(u64, 0), result.head.content_length);
    try std.testing.expectEqual(@as(usize, 0), (try req.body()).len);
    try std.testing.expect(req.bodyComplete());
}

test "zix edge: Http1 a QUERY with no Content-Length frames as bodyless" {
    // Nothing declared means nothing to read. A handler answers 400 because the
    // question is missing, not because framing failed.
    const result = try zix.Http1.parseHead("QUERY /search HTTP/1.1\r\nHost: x\r\n\r\n");

    try std.testing.expectEqual(@as(u64, 0), result.head.content_length);
    try std.testing.expect(!result.head.chunked_request);
}

test "zix edge: Http1 a chunked QUERY sets the chunked flag" {
    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nContent-Type: application/sql\r\nTransfer-Encoding: chunked\r\n\r\n",
    );

    try std.testing.expect(result.head.chunked_request);
}

test "zix edge: Http1 a QUERY may carry Expect 100-continue" {
    // A large query body is exactly the case where a client asks first.
    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nExpect: 100-continue\r\nContent-Type: application/sql\r\nContent-Length: 65536\r\n\r\n",
    );

    try std.testing.expect(result.head.expect_continue);
    try std.testing.expectEqual(@as(u64, 65536), result.head.content_length);
}

test "zix edge: Http1 a QUERY body past the receive buffer reports what arrived" {
    // The case a GET cannot express at all. The engine delivers a short slice and
    // the request still knows how much of the declared length is in hand.
    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nContent-Type: application/sql\r\nContent-Length: 65536\r\n\r\n",
    );
    var req = zix.Http1.Request.init(&result.head, "SELECT", TEST_FD);

    try std.testing.expectEqual(@as(u64, 65536), result.head.content_length);
    try std.testing.expectEqual(@as(u64, 6), req.bodyReceived());

    req.body_complete = false;
    try std.testing.expect(!req.bodyComplete());
}

test "zix edge: Http1 a QUERY keeps both its query string and its content" {
    // The target may still carry parameters. They do not replace the content and
    // the content does not erase them.
    const body = "SELECT 1";
    const result = try zix.Http1.parseHead(
        "QUERY /search?page=2 HTTP/1.1\r\nContent-Type: application/sql\r\nContent-Length: 8\r\n\r\n",
    );
    var req = zix.Http1.Request.init(&result.head, body, TEST_FD);

    try std.testing.expectEqualStrings("/search", req.path());
    try std.testing.expectEqualStrings("page=2", req.query());
    try std.testing.expectEqualStrings("2", req.queryParam("page").?);
    try std.testing.expectEqualStrings(body, try req.body());
}

test "zix edge: Http1 the longest query content type is matched, not truncated" {
    // 33 bytes. This is the value that overran the table's lowercase buffer before
    // the bound was raised, so it is the one worth pinning.
    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 5\r\n\r\n",
    );
    const req = zix.Http1.Request.init(&result.head, "q=abc", TEST_FD);

    const declared = req.header("content-type").?;
    try std.testing.expectEqual(@as(usize, 33), declared.len);
    try std.testing.expectEqual(
        zix.Http1.ContentType.APPLICATION_X_WWW_FORM_URLENCODED,
        zix.Http1.Content.typeFromHeader(declared).?,
    );
}

test "zix edge: Http1 an absurd Content-Type reports no match instead of overrunning" {
    const prefix = "application/";
    var long_type: [prefix.len + 300]u8 = @splat('x');
    @memcpy(long_type[0..prefix.len], prefix);

    try std.testing.expect(zix.Http1.Content.typeFromHeader(&long_type) == null);
    try std.testing.expect(zix.Http1.Content.typeFromString(&long_type) == null);
}

test "zix edge: Http1 an empty Content-Type value reports no match" {
    try std.testing.expect(zix.Http1.Content.typeFromHeader("") == null);
    try std.testing.expect(zix.Http1.Content.typeFromHeader(";") == null);
    try std.testing.expect(zix.Http1.Content.typeFromHeader("   ") == null);
}

test "zix edge: Http1 a multipart QUERY boundary parameter does not defeat the match" {
    const result = try zix.Http1.parseHead(
        "QUERY /search HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=----zixBoundary9c3\r\nContent-Length: 4\r\n\r\n",
    );
    const req = zix.Http1.Request.init(&result.head, "----", TEST_FD);

    try std.testing.expectEqual(
        zix.Http1.ContentType.MULTIPART_FORM_DATA,
        zix.Http1.Content.typeFromHeader(req.header("content-type").?).?,
    );
}

test "zix edge: Http1 a QUERY store is refused even when the response fits the cache" {
    // Refusing is not a size or capacity effect. A response well inside every
    // limit is still not stored.
    var cache = try zix.Http1.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 4096 });
    defer cache.deinit();

    zix.Http1.setCache(&cache, 1000);
    defer zix.Http1.setCache(null, 0);

    const result = try zix.Http1.parseHead("QUERY /search HTTP/1.1\r\nHost: x\r\n\r\n");

    zix.Http1.cacheStore(&result.head, "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx", 60000);
    try std.testing.expect(zix.Http1.cacheLookup(&result.head) == null);
}

test "zix edge: Http1 a QUERY encoded store is refused on the compressed path too" {
    // The per-encoding slots are a second way into the same key, so they carry
    // the same refusal.
    var cache = try zix.Http1.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 4096 });
    defer cache.deinit();

    zix.Http1.setCache(&cache, 1000);
    defer zix.Http1.setCache(null, 0);

    const result = try zix.Http1.parseHead("QUERY /search HTTP/1.1\r\nHost: x\r\n\r\n");

    zix.Http1.cacheStoreEncoded(&result.head, "gzip", "HTTP/1.1 200 OK\r\n\r\n", 60000);
    try std.testing.expect(zix.Http1.cacheLookupEncoded(&result.head, "gzip") == null);
}
