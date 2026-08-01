//! Edge tests: zix.Http QUERY method boundary conditions (RFC 10008).
//!
//! Both HTTP/1 engines match the method token exactly, reading one shared
//! method table. That bound is pinned here alongside the Content-Type and
//! framing limits a query body runs into.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: Http matches the QUERY token exactly, as it does every method" {
    // RFC 9110 section 9.1 makes method names case-sensitive. A lowercase token
    // is not the QUERY method, so it reads as a method this engine does not
    // implement.
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http.Request.fromRaw("query /search HTTP/1.1\r\nHost: x\r\n\r\n", std.testing.allocator),
    );
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http.Request.fromRaw("QuErY /search HTTP/1.1\r\nHost: x\r\n\r\n", std.testing.allocator),
    );
}

test "zix edge: Http a five-byte token that is not QUERY is still refused" {
    // QUERY shares its length with PATCH and TRACE, so the length arm must not
    // become a catch-all for anything five bytes long.
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http.Request.fromRaw("QUERX /search HTTP/1.1\r\nHost: x\r\n\r\n", std.testing.allocator),
    );
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http.Request.fromRaw("BREWS /search HTTP/1.1\r\nHost: x\r\n\r\n", std.testing.allocator),
    );
}

test "zix edge: Http an unimplemented method answers 501, a broken line answers 400" {
    // The status a caller writes comes from the error, so the two failures stay
    // distinguishable all the way to the wire.
    try std.testing.expect(std.mem.startsWith(
        u8,
        zix.Http.parseErrorResponse(error.UnknownMethod),
        "HTTP/1.1 501 Not Implemented\r\n",
    ));
    try std.testing.expect(std.mem.startsWith(
        u8,
        zix.Http.parseErrorResponse(error.InvalidRequest),
        "HTTP/1.1 400 Bad Request\r\n",
    ));
}

test "zix edge: Http a QUERY with zero Content-Length frames as bodyless" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nContent-Length: 0\r\n\r\n",
        arena.allocator(),
    );

    try std.testing.expectEqual(@as(usize, 0), (try req.body()).len);
}

test "zix edge: Http a chunked QUERY body decodes to the same bytes as Content-Length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var chunked = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "8\r\nSELECT 1\r\n0\r\n\r\n",
        arena.allocator(),
    );

    var sized = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nContent-Length: 8\r\n\r\nSELECT 1",
        arena.allocator(),
    );
    sized.body_cache = "SELECT 1";

    try std.testing.expectEqualStrings(try sized.body(), try chunked.body());
}

test "zix edge: Http a QUERY keeps both its query string and its content" {
    const req = try zix.Http.Request.fromRaw(
        "QUERY /search?page=2 HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nContent-Length: 8\r\n\r\nSELECT 1",
        std.testing.allocator,
    );

    try std.testing.expectEqualStrings("/search", req.path());
    try std.testing.expectEqualStrings("page=2", req.query());
    try std.testing.expectEqualStrings("2", req.queryParam("page").?);
}

test "zix edge: Http the longest query content type is matched, not truncated" {
    // 33 bytes, the value that overran the table's lowercase buffer before the
    // bound was raised.
    const req = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 5\r\n\r\nq=abc",
        std.testing.allocator,
    );

    const declared = req.header("content-type").?;
    try std.testing.expectEqual(@as(usize, 33), declared.len);
    try std.testing.expectEqual(
        zix.Http.ContentType.APPLICATION_X_WWW_FORM_URLENCODED,
        zix.Http.Content.typeFromHeader(declared).?,
    );
}

test "zix edge: Http an absurd Content-Type reports no match instead of overrunning" {
    const prefix = "application/";
    var long_type: [prefix.len + 300]u8 = @splat('x');
    @memcpy(long_type[0..prefix.len], prefix);

    try std.testing.expect(zix.Http.Content.typeFromHeader(&long_type) == null);
    try std.testing.expect(zix.Http.Content.typeFromString(&long_type) == null);
}

test "zix edge: Http an empty Content-Type value reports no match" {
    try std.testing.expect(zix.Http.Content.typeFromHeader("") == null);
    try std.testing.expect(zix.Http.Content.typeFromHeader(";") == null);
    try std.testing.expect(zix.Http.Content.typeFromHeader("   ") == null);
}

test "zix edge: Http a multipart QUERY boundary parameter does not defeat the match" {
    const req = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=----zixBoundary9c3\r\nContent-Length: 4\r\n\r\n----",
        std.testing.allocator,
    );

    try std.testing.expectEqual(
        zix.Http.ContentType.MULTIPART_FORM_DATA,
        zix.Http.Content.typeFromHeader(req.header("content-type").?).?,
    );
}

test "zix edge: Http both engines answer the same for a parameterised query type" {
    // The two content tables are separate files. A type that resolves in one and
    // not the other would make a handler behave differently per engine.
    const declared = "application/jsonpath; charset=utf-8";

    try std.testing.expectEqualStrings(
        @tagName(zix.Http.Content.typeFromHeader(declared).?),
        @tagName(zix.Http1.Content.typeFromHeader(declared).?),
    );
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_JSONPATH, zix.Http.Content.typeFromHeader(declared).?);
}
