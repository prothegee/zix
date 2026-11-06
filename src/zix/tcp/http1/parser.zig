//! ZIX Http1 parser
//!
//! ### file: src/zix/tcp/http1/parser.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Parses an HTTP/1 request head into a zero-copy ParsedHead.
//! 
//! ### note:
//! 
//! n/a
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
const ParseResult = @import("ParseResult.zig");
const Method = @import("../../utils/http/method.zig");
const HeaderSpan = @import("HeaderSpan.zig");
const ParsedHead = @import("ParsedHead.zig");

// --------------------------------------------------------- //
// Private:

/// Whether the request-line method token names a method this engine implements
///
/// Note:
/// - Method.codeFromString is the single table. Keeping a second copy here is
///   what let the two HTTP/1 engines disagree on method case, so the check
///   defers to the table it publishes
/// - The match is exact, per RFC 9110 section 9.1, so a normal request costs
///   one length switch and one compare, with no copy
/// - A keep-alive GET never reaches here at all: the EPOLL and URING loops
///   resolve it in parseGetFastPath before parseHeadAt is called
///
/// Param:
/// method - []const u8 (the raw token from the request line)
///
/// Return:
/// - bool
fn methodImplemented(method: []const u8) bool {
    return Method.codeFromString(method) != null;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixHttp1_Parser_IncompleteHeader,
    ZixHttp1_Parser_InvalidRequest,
    ZixHttp1_Parser_UnknownMethod,
};

/// Parse a complete HTTP/1.x request from buf where header_end (the index of
/// \r\n\r\n in buf) is already known. Avoids the redundant indexOf scan when
/// the caller has already located the terminator. buf may extend beyond
/// header_end + 4 (body bytes are ignored).
///
/// Note:
/// - Framing pass: a header line is tokenized only when its first letter is
///   c, t, e, or a (the letters that start a captured header: content-length,
///   connection, transfer-encoding, expect, accept-encoding). All other lines
///   skip with one indexOfPos plus one masked compare.
///
/// Return:
/// - !struct{ head: ParsedHead, body_offset: usize }
/// - Error.ZixHttp1_Parser_InvalidRequest on a malformed request line
/// - Error.ZixHttp1_Parser_UnknownMethod when the request line is well formed but names a
///   method this engine does not implement (the caller answers 501)
pub fn parseHeadAt(buf: []const u8, header_end: usize) Error!ParseResult {
    const body_offset = header_end + 4;

    const first_crlf = std.mem.indexOf(u8, buf[0..header_end], "\r\n") orelse header_end;
    const req_line = buf[0..first_crlf];

    const sp1 = std.mem.indexOfScalar(u8, req_line, ' ') orelse
        return Error.ZixHttp1_Parser_InvalidRequest;
    if (sp1 == 0) return Error.ZixHttp1_Parser_InvalidRequest;
    const method = req_line[0..sp1];

    const rest = req_line[sp1 + 1 ..];
    const sp2 = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse
        return Error.ZixHttp1_Parser_InvalidRequest;
    const target = rest[0..sp2];
    const version_str = rest[sp2 + 1 ..];

    const version_minor: u8 = if (std.mem.eql(u8, version_str, "HTTP/1.1"))
        1
    else if (std.mem.eql(u8, version_str, "HTTP/1.0"))
        0
    else
        return Error.ZixHttp1_Parser_InvalidRequest;

    // Checked after the version so a mangled request line still reads as
    // malformed (400) rather than as an unimplemented method (501).
    if (!methodImplemented(method)) return Error.ZixHttp1_Parser_UnknownMethod;

    var path = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |question_mark| {
        path = target[0..question_mark];
        query = target[question_mark + 1 ..];
    }

    const raw_headers: []const u8 = if (first_crlf >= header_end)
        buf[0..0]
    else
        buf[first_crlf + 2 .. header_end + 2];

    var keep_alive = (version_minor == 1);
    var content_length: u64 = 0;
    var chunked_request = false;
    var expect_continue = false;
    var accept_encoding: HeaderSpan = .{ .off = HeaderSpan.SPAN_ABSENT };

    var pos: usize = 0;
    while (pos < raw_headers.len) {
        const line_start = pos;
        const line_end = std.mem.indexOfPos(u8, raw_headers, pos, "\r\n") orelse raw_headers.len;
        const line = raw_headers[pos..line_end];
        pos = line_end + 2;
        if (line.len == 0) break;

        const first_lower = line[0] | 0x20;
        if (first_lower != 'c' and
            first_lower != 't' and
            first_lower != 'e' and
            first_lower != 'a')
                continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        var value_off: usize = colon + 1;
        while (value_off < line.len and line[value_off] == ' ') value_off += 1;
        const value = line[value_off..];

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch |err| switch (err) {
                else => 0,
            };
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) keep_alive = false;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) keep_alive = true;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            const chunked_pos = std.ascii.findIgnoreCase(value, "chunked");

            if (chunked_pos != null) chunked_request = true;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            if (std.ascii.eqlIgnoreCase(value, "100-continue")) expect_continue = true;
        } else if (std.ascii.eqlIgnoreCase(name, "accept-encoding")) {
            accept_encoding = .{
                .off = @intCast(line_start + value_off), .len = @intCast(value.len),
            };
        }
    }

    return .{ .head = .{
        .method = method,
        .path = path,
        .query = query,
        .raw_headers = raw_headers,
        .version_minor = version_minor,
        .keep_alive = keep_alive,
        .content_length = content_length,
        .chunked_request = chunked_request,
        .expect_continue = expect_continue,
        .accept_encoding = accept_encoding,
    }, .body_offset = body_offset };
}

/// Parse a complete HTTP/1.x request from buf.
/// buf must contain the full header block ending with \r\n\r\n.
/// All slices in ParsedHead point into buf (zero copy).
///
/// Return:
/// - !struct{ head: ParsedHead, body_offset: usize }
/// - Error.ZixIncompleteHeader when \r\n\r\n has not arrived yet
/// - Error.ZixHttp1_Parser_InvalidRequest on a malformed request line
/// - Error.ZixHttp1_Parser_UnknownMethod when the method is not one this engine implements
pub fn parseHead(buf: []const u8) Error!ParseResult {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse
        return Error.ZixHttp1_Parser_IncompleteHeader;
    return parseHeadAt(buf, header_end);
}

/// One request header value by name (case-insensitive), or null.
///
/// Note:
/// - Scans the raw header block. The producing parse pass only captured the
///   framing headers, so every other name costs this linear walk.
///
/// Param:
/// head - *const ParsedHead (borrows the receive buffer)
/// name - []const u8 (the header name, matched case-insensitively)
///
/// Return:
/// - ?[]const u8 (the field value with leading spaces trimmed, or null)
pub fn getHeader(head: *const ParsedHead, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < head.raw_headers.len) {
        const line_end = std.mem.indexOfPos(
            u8, head.raw_headers, pos, "\r\n",
        ) orelse head.raw_headers.len;
        const line = head.raw_headers[pos..line_end];
        pos = line_end + 2;
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;

        var value_off: usize = colon + 1;
        while (value_off < line.len and line[value_off] == ' ') value_off += 1;

        return line[value_off..];
    }

    return null;
}

/// The Accept-Encoding value for this request. O(1) when the producing parse
/// pass captured (or ruled out) the header, one getHeader scan otherwise.
///
/// Param:
/// head - *const ParsedHead (borrows the receive buffer)
///
/// Return:
/// - ?[]const u8 (the raw field value, or null when the header is absent)
pub fn acceptEncoding(head: *const ParsedHead) ?[]const u8 {
    return switch (head.accept_encoding.off) {
        HeaderSpan.SPAN_UNSCANNED => getHeader(head, "accept-encoding"),
        HeaderSpan.SPAN_ABSENT => null,
        else => head.raw_headers[head.accept_encoding.off..][0..head.accept_encoding.len],
    };
}

/// Linear scan for a single query parameter by exact name.
/// Does not percent-decode keys or values.
///
/// Param:
/// head - *const ParsedHead (source of the query string)
/// name - []const u8 (the parameter name)
///
/// Return:
/// - ?[]const u8 (raw value slice, or null if not found)
pub fn queryParam(head: *const ParsedHead, name: []const u8) ?[]const u8 {
    if (head.query.len == 0) return null;

    var iter = std.mem.splitScalar(u8, head.query, '&');
    while (iter.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }

    return null;
}

/// Response to answer a failed request-line parse with.
///
/// Note:
/// - A method the engine does not implement is 501, not 400: the request line
///   was well formed and only the method is unsupported (RFC 9110 section
///   15.6.2). Answering 400 told a client the request was broken when it was
///   merely unhandled.
/// - Every other parse failure is a malformed request line, which stays 400.
/// - Reached only on the error path, so no request that parses pays for it.
///
/// Param:
/// err - Error (from parseHead or parseHeadAt)
///
/// Return:
/// - []const u8 (a complete response, ready to write)
pub fn parseErrorResponse(err: Error) []const u8 {
    return switch (err) {
        error.ZixHttp1_Parser_UnknownMethod =>
            "HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n",
        else => "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: parser, exposes request lookups" {
    const buf =
        "GET /path?q=1&name=zix HTTP/1.1\r\n" ++
        "Host: zix\r\n" ++
        "Accept-Encoding: gzip, br\r\n\r\n";
    const result = try parseHead(buf);
    const head = result.head;

    try std.testing.expectEqualStrings("zix", getHeader(&head, "host").?);
    try std.testing.expect(getHeader(&head, "missing") == null);
    try std.testing.expectEqualStrings("zix", queryParam(&head, "name").?);
    try std.testing.expect(queryParam(&head, "none") == null);
    try std.testing.expectEqualStrings("gzip, br", acceptEncoding(&head).?);
}

test "zix http1: parser, maps an error to a response" {
    try std.testing.expectEqualStrings(
        "HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n",
        parseErrorResponse(error.ZixHttp1_Parser_UnknownMethod),
    );
    try std.testing.expectEqualStrings(
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
        parseErrorResponse(error.ZixHttp1_Parser_InvalidRequest),
    );
}

test "zix http1: parser, rejects an incomplete head" {
    try std.testing.expectError(
        Error.ZixHttp1_Parser_IncompleteHeader,
        parseHead("GET / HTTP/1.1\r\n"),
    );
}

test "zix http1: parser, captures framing headers" {
    const buf =
        "POST /x HTTP/1.1\r\n" ++
        "Content-Length: 7\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Expect: 100-continue\r\n" ++
        "Connection: close\r\n\r\n";
    const result = try parseHead(buf);

    try std.testing.expectEqual(@as(u64, 7), result.head.content_length);
    try std.testing.expect(result.head.chunked_request);
    try std.testing.expect(result.head.expect_continue);
    try std.testing.expect(!result.head.keep_alive);
}

test "zix http1: parser, defaults HTTP/1.0 to close" {
    const result = try parseHead("GET / HTTP/1.0\r\n\r\n");

    try std.testing.expect(!result.head.keep_alive);
}

