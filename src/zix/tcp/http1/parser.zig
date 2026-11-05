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
//! n/a
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
    ZixHttp1_Parser_IncompleHeader,
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
pub fn parseHeadAt(buf: []const u8, header_end: usize) !ParseResult {
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
            content_length = std.fmt.parseInt(u64, value, 10) catch 0;
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
        return Error.ZixHttp1_Parser_IncompleHeader;
    return parseHeadAt(buf, header_end);
}

