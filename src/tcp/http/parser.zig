//! zix http parser
//!
//! Pure zero-copy HTTP/1.1 request parser.
//! No I/O, no allocation. All output fields are byte offsets into the caller's buffer.
//! parse() yields null when the buffer does not yet contain a complete header block.

const std = @import("std");
const Method = @import("method.zig");

pub const MAX_HEADERS: usize = 64;
pub const MAX_HEADERS_U8: u8 = MAX_HEADERS;

// --------------------------------------------------------- //

/// Request header cap tier. Controls how many headers the server accepts before rejecting with 431.
/// Mirrors HeaderSize for response headers. CUSTOM values above 64 are silently capped at 64.
pub const RequestHeaderSize = union(enum) {
    MINIMAL, // 16
    COMMON, // 32
    LARGE, // 64 (parser storage limit)
    CUSTOM: u8,

    pub fn value(self: RequestHeaderSize) u8 {
        return switch (self) {
            .MINIMAL => 16,
            .COMMON => 32,
            .LARGE => MAX_HEADERS,
            .CUSTOM => |n| @min(n, MAX_HEADERS),
        };
    }
};

/// One request header, encoded as byte offsets + lengths into the read buffer.
/// Zero-copy: no data is copied during parsing.
pub const HeaderEntry = struct {
    name_start: u16,
    name_len: u8,
    value_start: u16,
    value_len: u16,
};

/// Fully parsed HTTP/1.1 request head, encoded as offsets into the read buffer.
/// Pre-parses method, keep_alive, and content_length to avoid re-scanning on the hot path.
pub const ParsedHead = struct {
    method: Method.Code,
    path_start: u16,
    path_len: u16,
    query_start: u16, // 0 when no query string. Check query_len instead.
    query_len: u16,
    /// Raw header block: the header lines after the request line, up to but not
    /// including the terminating CRLF. Scanned on demand by getHeader. Lazy: no
    /// per-request header array is built, only the framing headers are pre-parsed.
    headers_start: u16,
    headers_len: u16,
    body_offset: u16, // byte index of first body byte (header_end + 4)
    keep_alive: bool, // false when Connection: close was sent, true otherwise (HTTP/1.1 default)
    content_length: u64,
    chunked: bool, // true when Transfer-Encoding: chunked
};

pub const ParseError = error{
    InvalidRequest,
    TooManyHeaders,
};

pub const DechunkError = error{
    InvalidChunkSize,
};

/// Find the start index of the end-of-headers marker "\r\n\r\n".
/// Scans for '\n' with a vectorized scalar search and verifies the three
/// preceding bytes, avoiding the per-window byte compare that a multi-byte
/// indexOf incurs (mem.eql at every position).
///
/// Param:
/// buf - []const u8 (bytes to search)
/// start - usize (byte index to begin scanning, clamped so a 3-byte look-back is valid)
///
/// Return:
/// - index of the first '\r' of "\r\n\r\n", or null when not present
pub fn findHeaderEnd(buf: []const u8, start: usize) ?usize {
    var i = @max(start, 3);
    while (std.mem.indexOfScalarPos(u8, buf, i, '\n')) |nl| {
        if (buf[nl - 1] == '\r' and buf[nl - 2] == '\n' and buf[nl - 3] == '\r') {
            return nl - 3;
        }
        i = nl + 1;
    }
    return null;
}

/// Parse an HTTP/1.1 request from buf.
/// On success the returned ParsedHead contains only offsets into buf, no data is copied.
///
/// Return:
/// - null when the buffer does not contain a complete header block (\r\n\r\n not found)
/// - ParseError on malformed input
pub fn parse(buf: []const u8, max_headers: u8) ParseError!?ParsedHead {
    // Scan for the end-of-headers marker. Search stops as soon as it is found.
    const header_end = findHeaderEnd(buf, 0) orelse return null;
    const head_buf = buf[0..header_end];

    // Parse request line: "METHOD TARGET HTTP/1.1"
    // When there are no additional headers, head_buf IS the request line (no \r\n inside it).
    // Scan for '\n' (vectorized) and step back over the '\r' to locate the CRLF.
    const first_nl = std.mem.indexOfScalar(u8, head_buf, '\n') orelse head_buf.len;
    const first_crlf = if (first_nl > 0 and head_buf[first_nl - 1] == '\r') first_nl - 1 else first_nl;
    const req_line = head_buf[0..first_crlf];

    const first_space = std.mem.indexOfScalar(u8, req_line, ' ') orelse return error.InvalidRequest;
    const method_code = parseMethod(req_line[0..first_space]) orelse return error.InvalidRequest;

    const after_method = req_line[first_space + 1 ..];
    const second_space = std.mem.indexOfScalar(u8, after_method, ' ') orelse return error.InvalidRequest;
    const target = after_method[0..second_space];

    // Absolute offsets of path and query into buf.
    const path_abs: u16 = @intCast(first_space + 1);
    var path_len: u16 = undefined;
    var query_start: u16 = 0;
    var query_len: u16 = 0;
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        path_len = @intCast(q);
        query_start = @intCast(first_space + 1 + q + 1);
        const qlen = target.len - q - 1;
        query_len = @intCast(qlen);
    } else {
        path_len = @intCast(target.len);
    }

    // Scan header lines once to pre-parse the framing headers and enforce the
    // header-count limit. Individual headers are NOT stored: getHeader rescans the
    // raw block on demand (lazy parseHead), which keeps ParsedHead small and skips
    // the per-request header-array fill on the hot path.
    const headers_start: usize = first_nl + 1;
    var header_count: u8 = 0;
    var keep_alive = true; // HTTP/1.1 default
    var content_length: u64 = 0;
    var chunked = false;

    var pos: usize = headers_start;
    while (pos < head_buf.len) {
        // Vectorized scan for the line's '\n', then step back over the '\r'.
        const nl = std.mem.indexOfScalarPos(u8, head_buf, pos, '\n') orelse head_buf.len;
        const line_end = if (nl > pos and head_buf[nl - 1] == '\r') nl - 1 else nl;
        const line = head_buf[pos..line_end];
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            pos = nl + 1;
            continue;
        };

        if (header_count >= max_headers) return error.TooManyHeaders;
        header_count += 1;

        // Skip colon + leading whitespace for value.
        var val_off = colon + 1;
        while (val_off < line.len and line[val_off] == ' ') val_off += 1;

        // Pre-parse the framing headers to avoid rescanning them on the hot path.
        const name = line[0..colon];
        const value = line[val_off..];
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch 0;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) keep_alive = false;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.eqlIgnoreCase(value, "chunked")) chunked = true;
        }

        pos = nl + 1;
    }

    return ParsedHead{
        .method = method_code,
        .path_start = path_abs,
        .path_len = path_len,
        .query_start = query_start,
        .query_len = query_len,
        .headers_start = @intCast(headers_start),
        .headers_len = @intCast(if (headers_start < head_buf.len) head_buf.len - headers_start else 0),
        .body_offset = @intCast(header_end + 4),
        .keep_alive = keep_alive,
        .content_length = content_length,
        .chunked = chunked,
    };
}

/// Look up a request header value by name (case-insensitive), scanning the raw
/// header block on demand. The lazy counterpart to the old per-request header
/// array: nothing is stored at parse time, the block is rescanned per lookup.
///
/// Param:
/// head - ParsedHead
/// buf - []const u8 (the read buffer the offsets point into)
/// name - []const u8 (header name, case-insensitive)
///
/// Return:
/// - the header value with leading optional whitespace trimmed, or null when absent
pub fn getHeader(head: ParsedHead, buf: []const u8, name: []const u8) ?[]const u8 {
    if (head.headers_len == 0) return null;

    const block = buf[head.headers_start..][0..head.headers_len];
    var pos: usize = 0;
    while (pos < block.len) {
        const nl = std.mem.indexOfScalarPos(u8, block, pos, '\n') orelse block.len;
        const line_end = if (nl > pos and block[nl - 1] == '\r') nl - 1 else nl;
        const line = block[pos..line_end];
        pos = nl + 1;
        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;

        var val_off = colon + 1;
        while (val_off < line.len and line[val_off] == ' ') val_off += 1;

        return line[val_off..];
    }

    return null;
}

/// Decode HTTP/1.1 chunked transfer encoding.
/// raw: complete raw chunked body (including chunk framing).
/// out: destination buffer, must be at least raw.len bytes (decoded is always <= raw).
/// Stops at the terminal chunk (size 0) or when raw is exhausted.
/// Chunk extensions ("; name=value" on the size line) are ignored.
///
/// Return:
/// - number of decoded bytes written to out
pub fn dechunk(raw: []const u8, out: []u8) DechunkError!usize {
    var pos: usize = 0;
    var written: usize = 0;

    while (pos < raw.len) {
        const crlf = std.mem.indexOfPos(u8, raw, pos, "\r\n") orelse break;
        const size_line = raw[pos..crlf];

        const ext_pos = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const size_hex = std.mem.trim(u8, size_line[0..ext_pos], " \t");
        if (size_hex.len == 0) return error.InvalidChunkSize;

        const chunk_size = std.fmt.parseInt(usize, size_hex, 16) catch return error.InvalidChunkSize;
        if (chunk_size == 0) break;

        const data_start = crlf + 2;
        const data_end = data_start + chunk_size;
        if (data_end > raw.len) break;

        if (written + chunk_size <= out.len) {
            @memcpy(out[written..][0..chunk_size], raw[data_start..data_end]);
            written += chunk_size;
        }

        pos = data_end + 2;
    }

    return written;
}

fn parseMethod(s: []const u8) ?Method.Code {
    return switch (s.len) {
        3 => if (std.mem.eql(u8, s, "GET")) .GET else if (std.mem.eql(u8, s, "PUT")) .PUT else null,
        4 => if (std.mem.eql(u8, s, "HEAD")) .HEAD else if (std.mem.eql(u8, s, "POST")) .POST else null,
        5 => if (std.mem.eql(u8, s, "PATCH")) .PATCH else if (std.mem.eql(u8, s, "TRACE")) .TRACE else null,
        6 => if (std.mem.eql(u8, s, "DELETE")) .DELETE else null,
        7 => if (std.mem.eql(u8, s, "OPTIONS")) .OPTIONS else if (std.mem.eql(u8, s, "CONNECT")) .CONNECT else null,
        else => null,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: parser incomplete returns null" {
    try std.testing.expect(try parse("GET / HTTP/1.1\r\n", 64) == null);
    try std.testing.expect(try parse("GET / HTTP/1.1\r\nHost: x\r\n", 64) == null);
    try std.testing.expect(try parse("", 64) == null);
}

test "zix test: parser minimal GET" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const h = (try parse(raw, 64)).?;
    try std.testing.expectEqual(Method.Code.GET, h.method);
    try std.testing.expectEqualStrings("/", raw[h.path_start..][0..h.path_len]);
    try std.testing.expectEqual(@as(u16, 0), h.query_len);
    try std.testing.expectEqualStrings("localhost", getHeader(h, raw, "host").?);
    try std.testing.expect(h.keep_alive);
    try std.testing.expectEqual(@as(u64, 0), h.content_length);
}

test "zix test: parser path and query" {
    const raw = "GET /api/users/123?name=alice&flag HTTP/1.1\r\n\r\n";
    const h = (try parse(raw, 64)).?;
    try std.testing.expectEqualStrings("/api/users/123", raw[h.path_start..][0..h.path_len]);
    try std.testing.expectEqualStrings("name=alice&flag", raw[h.query_start..][0..h.query_len]);
}

test "zix test: parser header offsets" {
    const raw = "POST /data HTTP/1.1\r\nContent-Length: 5\r\nX-Foo: bar\r\n\r\nhello";
    const h = (try parse(raw, 64)).?;
    try std.testing.expectEqual(Method.Code.POST, h.method);
    try std.testing.expectEqual(@as(u64, 5), h.content_length);
    // Headers are scanned on demand from the raw block (case-insensitive).
    try std.testing.expectEqualStrings("5", getHeader(h, raw, "content-length").?);
    try std.testing.expectEqualStrings("bar", getHeader(h, raw, "X-Foo").?);
    try std.testing.expect(getHeader(h, raw, "missing") == null);
    // Body offset points right after \r\n\r\n
    try std.testing.expectEqualStrings("hello", raw[h.body_offset..]);
}

test "zix test: parser keep_alive false on Connection: close" {
    const raw = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n";
    const h = (try parse(raw, 64)).?;
    try std.testing.expect(!h.keep_alive);
}

test "zix test: parser all methods" {
    const cases = [_]struct { raw: []const u8, code: Method.Code }{
        .{ .raw = "GET / HTTP/1.1\r\n\r\n", .code = .GET },
        .{ .raw = "HEAD / HTTP/1.1\r\n\r\n", .code = .HEAD },
        .{ .raw = "POST / HTTP/1.1\r\n\r\n", .code = .POST },
        .{ .raw = "PUT / HTTP/1.1\r\n\r\n", .code = .PUT },
        .{ .raw = "DELETE / HTTP/1.1\r\n\r\n", .code = .DELETE },
        .{ .raw = "PATCH / HTTP/1.1\r\n\r\n", .code = .PATCH },
        .{ .raw = "OPTIONS / HTTP/1.1\r\n\r\n", .code = .OPTIONS },
    };
    for (cases) |c| {
        const h = (try parse(c.raw, 64)).?;
        try std.testing.expectEqual(c.code, h.method);
    }
}

test "zix test: parser invalid method" {
    const raw = "BREW / HTTP/1.1\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, parse(raw, 64));
}

test "zix test: parser chunked flag set when Transfer-Encoding: chunked" {
    const raw = "POST /upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    const h = (try parse(raw, 64)).?;
    try std.testing.expect(h.chunked);
}

test "zix test: parser chunked flag false when Transfer-Encoding absent" {
    const raw = "POST /upload HTTP/1.1\r\nContent-Length: 5\r\n\r\n";
    const h = (try parse(raw, 64)).?;
    try std.testing.expect(!h.chunked);
}

test "zix test: dechunk single chunk" {
    const raw = "5\r\nhello\r\n0\r\n\r\n";
    var out: [64]u8 = undefined;
    const n = try dechunk(raw, &out);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

test "zix test: dechunk multiple chunks" {
    const raw = "3\r\nfoo\r\n4\r\nbarr\r\n0\r\n\r\n";
    var out: [64]u8 = undefined;
    const n = try dechunk(raw, &out);
    try std.testing.expectEqualStrings("foobarr", out[0..n]);
}

test "zix test: dechunk terminal only returns empty" {
    const raw = "0\r\n\r\n";
    var out: [64]u8 = undefined;
    const n = try dechunk(raw, &out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "zix test: dechunk chunk extension ignored" {
    const raw = "5;name=value\r\nhello\r\n0\r\n\r\n";
    var out: [64]u8 = undefined;
    const n = try dechunk(raw, &out);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

test "zix test: dechunk invalid hex returns error" {
    const raw = "zz\r\nhello\r\n0\r\n\r\n";
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidChunkSize, dechunk(raw, &out));
}

test "zix test: dechunk uppercase hex accepted" {
    const raw = "A\r\n0123456789\r\n0\r\n\r\n";
    var out: [64]u8 = undefined;
    const n = try dechunk(raw, &out);
    try std.testing.expectEqualStrings("0123456789", out[0..n]);
}
