//! ZIX Http1 head
//!
//! ### file: src/zix/tcp/http1/head.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Status line and header bytes for one HTTP/1.1 response head.
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
const Status = @import("../../utils/http/status.zig");
const date = @import("date.zig");

const statusLine = Status.statusLine;
const statusPhrase = Status.stringFromEnum;

// --------------------------------------------------------- //
// Private:

/// Whether responses include the Date header. Set per worker from
/// config.send_date_header.
threadlocal var tl_send_date: bool = true;

fn appendStatusCode(buf: []u8, pos: usize, code: Status.Code) usize {
    const n: u16 = @intFromEnum(code);
    buf[pos]     = '0' + @as(u8, @intCast(n / 100));
    buf[pos + 1] = '0' + @as(u8, @intCast((n / 10) % 10));
    buf[pos + 2] = '0' + @as(u8, @intCast(n % 10));

    return pos + 3;
}

fn appendDec(buf: []u8, pos: usize, val: usize) usize {
    if (val == 0) {
        buf[pos] = '0';

        return pos + 1;
    }
    var tmp: [20]u8 = undefined;
    var tmp_len: usize = 0;
    var value = val;
    while (value > 0) {
        tmp[tmp_len] = '0' + @as(u8, @intCast(value % 10));
        tmp_len += 1;
        value /= 10;
    }

    var i: usize = 0;
    while (i < tmp_len) : (i += 1) {
        buf[pos + i] = tmp[tmp_len - 1 - i];
    }

    return pos + tmp_len;
}

fn appendBytes(buf: []u8, pos: usize, str: []const u8) usize {
    @memcpy(buf[pos..][0..str.len], str);

    return pos + str.len;
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 head error
pub const Error = error {
    ZixHttp1_Head_DateFormat,
};

/// Scratch buffer for building one HTTP status line plus its headers.
pub const HEADER_BUF_SIZE: usize = 256;

/// Set whether responses include the Date header. Called once per worker at
/// startup.
pub fn setDateHeader(enabled: bool) void {
    tl_send_date = enabled;
}

/// Build a simple response header into a fixed buffer and return the slice.
/// buf must be at least HEADER_BUF_SIZE bytes.
pub fn buildSimpleHeader(
    io: std.Io,
    buf: *[HEADER_BUF_SIZE]u8,
    status: Status.Code,
    content_type: []const u8,
    body_len: usize,
) Error![]u8 {
    const len = try buildSimpleHeaderInto(io, buf, status, content_type, body_len);

    return buf[0..len];
}

/// Write a simple response header into buf starting at offset 0 and return the
/// number of bytes written. buf must be at least 256 bytes.
///
/// The block ends with the final \r\n\r\n, so a caller inserting extra headers
/// (Response.addHeader) splices them in before the last two bytes.
pub fn buildSimpleHeaderInto(
    io: std.Io,
    buf: []u8,
    status: Status.Code,
    content_type: []const u8,
    body_len: usize,
) Error!usize {
    var pos: usize = 0;

    const line = statusLine(status);
    if (line.len > 0) {
        pos = appendBytes(buf, pos, line);
    } else {
        pos = appendBytes(buf, pos, "HTTP/1.1 ");
        pos = appendStatusCode(buf, pos, status);
        buf[pos] = ' ';
        pos += 1;
        pos = appendBytes(buf, pos, statusPhrase(status));
        pos = appendBytes(buf, pos, "\r\n");
    }

    if (content_type.len > 0) {
        pos = appendBytes(buf, pos, "Content-Type: ");
        pos = appendBytes(buf, pos, content_type);
        pos = appendBytes(buf, pos, "\r\n");
    }
    pos = appendBytes(buf, pos, "Content-Length: ");
    pos = appendDec(buf, pos, body_len);
    pos = appendBytes(buf, pos, "\r\n");
    if (tl_send_date) {
        pos = appendBytes(buf, pos, "Date: ");
        pos = appendBytes(buf, pos, date.cachedDate(io) catch |err| switch (err) {
            error.ZixHttp1_Date_NoSpaceLeft,
            error.ZixHttp1_Date_InvalidTimezone,
            => return Error.ZixHttp1_Head_DateFormat,
        });
        pos = appendBytes(buf, pos, "\r\n");
    }
    pos = appendBytes(buf, pos, "\r\n");

    return pos;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: head, builds a simple head" {
    setDateHeader(false);
    defer setDateHeader(true);

    var buf: [HEADER_BUF_SIZE]u8 = undefined;
    const written = try buildSimpleHeaderInto(std.testing.io, &buf, .OK, "text/plain", 5);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\n",
        buf[0..written],
    );
}

test "zix http1: head, builds without a content type" {
    setDateHeader(false);
    defer setDateHeader(true);

    var buf: [HEADER_BUF_SIZE]u8 = undefined;
    const written = try buildSimpleHeaderInto(std.testing.io, &buf, .NOT_FOUND, "", 0);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n",
        buf[0..written],
    );
}

test "zix http1: head, includes Date when enabled" {
    setDateHeader(true);
    defer setDateHeader(true);

    var buf: [HEADER_BUF_SIZE]u8 = undefined;
    const written = try buildSimpleHeaderInto(std.testing.io, &buf, .OK, "text/plain", 0);

    try std.testing.expect(std.mem.indexOf(u8, buf[0..written], "\r\nDate: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..written], " GMT\r\n\r\n"));
}

