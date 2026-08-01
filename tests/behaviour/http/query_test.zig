//! Behaviour tests: zix.Http support for the QUERY method (RFC 10008).
//!
//! QUERY is safe and idempotent like GET, and carries content like POST. This
//! engine parses the request line itself, and used to refuse any method outside
//! the nine RFC 9110 names before a handler ever ran. These tests hold it to the
//! same contract the raw engine answers, so a caller gets one behaviour from
//! both.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: Http accepts a QUERY request line" {
    // The request-line parser rejected QUERY outright before RFC 10008 support,
    // so the request never reached a route.
    const req = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );

    try std.testing.expectEqual(zix.Http.Method.Code.QUERY, req.method());
    try std.testing.expectEqualStrings("/search", req.path());
}

test "zix behaviour: Http a QUERY request is distinguishable from a GET" {
    const query_req = try zix.Http.Request.fromRaw("QUERY /search HTTP/1.1\r\nHost: x\r\n\r\n", std.testing.allocator);
    const get_req = try zix.Http.Request.fromRaw("GET /search HTTP/1.1\r\nHost: x\r\n\r\n", std.testing.allocator);

    try std.testing.expect(query_req.method() != get_req.method());
    try std.testing.expectEqual(zix.Http.Method.Code.GET, get_req.method());
}

test "zix behaviour: Http a QUERY request carries its content like a POST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "8\r\nSELECT 1\r\n0\r\n\r\n",
        arena.allocator(),
    );

    try std.testing.expectEqualStrings("SELECT 1", try req.body());
}

test "zix behaviour: Http a QUERY request exposes its declared Content-Type" {
    const req = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nContent-Length: 8\r\n\r\nSELECT 1",
        std.testing.allocator,
    );

    const declared = req.header("content-type").?;
    try std.testing.expectEqualStrings("application/sql", declared);
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_SQL, zix.Http.Content.typeFromHeader(declared).?);
}

test "zix behaviour: Http a QUERY without Content-Type reports no type" {
    // The absent header is what a handler turns into a 400 (RFC 10008 section 2.1).
    const req = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nSELECT 1",
        std.testing.allocator,
    );

    try std.testing.expect(req.header("content-type") == null);
}

test "zix behaviour: Http an unsupported query content type reports no match, never sniffed" {
    const req = try zix.Http.Request.fromRaw(
        "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/vnd.zix.made-up\r\nContent-Length: 8\r\n\r\nSELECT 1",
        std.testing.allocator,
    );

    try std.testing.expect(zix.Http.Content.typeFromHeader(req.header("content-type").?) == null);
}

test "zix behaviour: Http every query content type RFC 10008 names is recognised" {
    const cases = .{
        .{ "application/sql", zix.Http.ContentType.APPLICATION_SQL },
        .{ "application/jsonpath", zix.Http.ContentType.APPLICATION_JSONPATH },
        .{ "application/graphql", zix.Http.ContentType.APPLICATION_GRAPHQL },
        .{ "application/x-www-form-urlencoded", zix.Http.ContentType.APPLICATION_X_WWW_FORM_URLENCODED },
        .{ "multipart/form-data", zix.Http.ContentType.MULTIPART_FORM_DATA },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case[1], zix.Http.Content.typeFromHeader(case[0]).?);
    }
}

test "zix behaviour: Http and Http1 agree on what a QUERY request is" {
    // Two engines, one answer. A handler moved between them sees no difference.
    const raw = "QUERY /search HTTP/1.1\r\nHost: x\r\nContent-Type: application/sql\r\nContent-Length: 8\r\n\r\nSELECT 1";

    const http_req = try zix.Http.Request.fromRaw(raw, std.testing.allocator);
    const http1_result = try zix.Http1.parseHead(raw);

    try std.testing.expectEqualStrings("QUERY", @tagName(http_req.method()));
    try std.testing.expectEqualStrings("QUERY", http1_result.head.method);
    try std.testing.expectEqualStrings(http_req.path(), http1_result.head.path);
    try std.testing.expectEqual(
        zix.Http.Content.typeFromHeader("application/sql").?,
        zix.Http.ContentType.APPLICATION_SQL,
    );
    try std.testing.expectEqual(
        zix.Http1.Content.typeFromHeader("application/sql").?,
        zix.Http1.ContentType.APPLICATION_SQL,
    );
}

test "zix behaviour: Http a method it does not implement draws 501, not 400" {
    // The request line tokenized, so the request was not malformed. Answering 400
    // told a client to fix a request that had nothing wrong with it.
    try std.testing.expectError(
        error.UnknownMethod,
        zix.Http.Request.fromRaw("BREW /pot HTTP/1.1\r\nHost: x\r\n\r\n", std.testing.allocator),
    );

    const answer = zix.Http.parseErrorResponse(error.UnknownMethod);
    try std.testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 501 Not Implemented\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, answer, "\r\n\r\n"));
}

test "zix behaviour: Http and Http1 answer an unimplemented method identically" {
    try std.testing.expectEqualStrings(
        zix.Http.parseErrorResponse(error.UnknownMethod),
        zix.Http1.parseErrorResponse(error.UnknownMethod),
    );
    try std.testing.expectEqualStrings(
        zix.Http.parseErrorResponse(error.InvalidRequest),
        zix.Http1.parseErrorResponse(error.InvalidRequest),
    );
}
