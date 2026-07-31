//! Edge tests: zix.Http1 request-body framing boundary conditions.
//!
//! Content-Length is what every dispatch model uses to decide whether a body is
//! delivered whole, waited for, or drained off the socket, so a value the parser
//! rejects changes which path a request takes.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: Http1 absent Content-Length frames the request as bodyless" {
    const result = try zix.Http1.parseHead("POST /upload HTTP/1.1\r\nHost: t\r\n\r\n");

    try std.testing.expectEqual(@as(u64, 0), result.head.content_length);
    try std.testing.expect(!result.head.chunked_request);
}

test "zix edge: Http1 zero Content-Length frames the request as bodyless" {
    const result = try zix.Http1.parseHead("POST /upload HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    try std.testing.expectEqual(@as(u64, 0), result.head.content_length);
}

test "zix edge: Http1 non-numeric Content-Length falls back to zero" {
    const result = try zix.Http1.parseHead("POST /upload HTTP/1.1\r\nContent-Length: abc\r\n\r\n");

    try std.testing.expectEqual(@as(u64, 0), result.head.content_length);
}

test "zix edge: Http1 Content-Length with a trailing space falls back to zero" {
    const result = try zix.Http1.parseHead("POST /upload HTTP/1.1\r\nContent-Length: 5 \r\n\r\n");

    try std.testing.expectEqual(@as(u64, 0), result.head.content_length);
}

test "zix edge: Http1 Content-Length past u64 falls back to zero" {
    const result = try zix.Http1.parseHead("POST /upload HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n");

    try std.testing.expectEqual(@as(u64, 0), result.head.content_length);
}

test "zix edge: Http1 Content-Length is read case-insensitively" {
    const result = try zix.Http1.parseHead("POST /upload HTTP/1.1\r\ncOnTeNt-LeNgTh: 20971520\r\n\r\n");

    try std.testing.expectEqual(@as(u64, 20971520), result.head.content_length);
}

test "zix edge: Http1 chunked request sets the chunked flag beside Content-Length" {
    const result = try zix.Http1.parseHead("POST /upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 7\r\n\r\n");

    try std.testing.expect(result.head.chunked_request);
    try std.testing.expectEqual(@as(u64, 7), result.head.content_length);
}

test "zix edge: Http1 Expect 100-continue is flagged for a body-carrying request" {
    const result = try zix.Http1.parseHead("POST /upload HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 9\r\n\r\n");

    try std.testing.expect(result.head.expect_continue);
    try std.testing.expectEqual(@as(u64, 9), result.head.content_length);
}

test "zix edge: Http1 Request bodyReceived is zero for a bodyless request" {
    const result = try zix.Http1.parseHead("GET /ping HTTP/1.1\r\nHost: t\r\n\r\n");
    var req = zix.Http1.Request.init(&result.head, &.{}, -1);

    try std.testing.expectEqual(@as(u64, 0), req.bodyReceived());
    try std.testing.expectEqual(@as(usize, 0), (try req.body()).len);
}

test "zix edge: Http1 Request bodyReceived tracks the delivered slice by default" {
    const result = try zix.Http1.parseHead("POST /upload HTTP/1.1\r\nContent-Length: 4\r\n\r\n");
    var req = zix.Http1.Request.init(&result.head, "abcd", -1);

    try std.testing.expectEqual(@as(u64, 4), req.bodyReceived());
    try std.testing.expectEqualStrings("abcd", try req.body());
}
