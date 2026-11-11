//! ZIX Http2 upgrade
//!
//! ### file: src/zix/tcp/http2/upgrade.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Server side of the h2c upgrade: read the HTTP/1.1 request, answer 101.
//!
//! ### note:
//!
//! - Only the HTTP/1.1 half lives here. The caller reads the client preface,
//!   sends SETTINGS, and answers the upgrade request as stream 1.
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
const reader = @import("reader.zig");
const writer = @import("writer.zig");
const UpgradeHead = @import("UpgradeHead.zig");

// --------------------------------------------------------- //
// Private:

const Inner = Error || reader.Error || writer.Error;

/// One HTTP/1.1 header value by name (case-insensitive), leading spaces
/// trimmed. The request line is skipped.
///
/// Param:
/// head - []const u8 (request line and headers, ending in an empty line)
/// name - []const u8 (header name to look for)
///
/// Return:
/// - ?[]const u8 (the value, or null when absent)
fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    const first_crlf = std.mem.indexOf(u8, head, "\r\n") orelse return null;

    var pos = first_crlf + 2;
    while (pos < head.len) {
        const line_end = std.mem.indexOfPos(u8, head, pos, "\r\n") orelse break;
        const line = head[pos..line_end];
        if (line.len == 0) break;

        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                return std.mem.trimStart(u8, line[colon + 1 ..], " ");
            }
        }

        pos = line_end + 2;
    }

    return null;
}

/// Decode the HTTP2-Settings header into out.
///
/// Note:
/// - Best effort, as before: a value that does not decode or does not fit
///   leaves the peer on default settings.
///
/// Param:
/// value - []const u8 (the base64url header value, no padding)
/// out - []u8 (destination for the decoded settings payload)
///
/// Return:
/// - []const u8 (the decoded payload, empty on failure)
fn decodeSettings(value: []const u8, out: []u8) []const u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const trimmed = std.mem.trim(u8, value, " ");

    const len = decoder.calcSizeForSlice(trimmed) catch |err| switch (err) {
        error.InvalidCharacter,
        error.InvalidPadding,
        error.NoSpaceLeft,
        => return "",
    };
    if (len == 0 or len > out.len) return "";

    decoder.decode(out[0..len], trimmed) catch |err| switch (err) {
        error.InvalidCharacter,
        error.InvalidPadding,
        error.NoSpaceLeft,
        => return "",
    };

    return out[0..len];
}

/// Split the request line into method and target.
fn requestLine(head: []const u8) UpgradeHead {
    var result: UpgradeHead = .{
        .method = "GET",
        .path = "/",
    };

    const first_space = std.mem.indexOfScalar(u8, head, ' ') orelse return result;
    result.method = head[0..first_space];

    const after = head[first_space + 1 ..];
    if (std.mem.indexOfScalar(u8, after, ' ')) |second_space| {
        result.path = after[0..second_space];
    }

    return result;
}

/// Read until the end of the HTTP/1.1 head.
///
/// Return:
/// - usize (bytes up to and including the empty line)
fn readHead(fd: std.posix.fd_t, head_buf: []u8, filled_start: usize) Inner!usize {
    var filled = filled_start;

    while (std.mem.indexOf(u8, head_buf[0..filled], HEAD_END) == null) {
        if (filled >= head_buf.len) return Error.ZixHttp2_Upgrade_HeaderTooLarge;

        const got = try reader.readOnceFD(fd, head_buf[filled..]);
        if (got == 0) return Error.ZixHttp2_Upgrade_Closed;

        filled += got;
    }

    return std.mem.indexOf(u8, head_buf[0..filled], HEAD_END).? + HEAD_END.len;
}

/// Answer a request that is not an h2c upgrade with 400, best effort.
fn rejectBadRequest(fd: std.posix.fd_t) Error {
    writer.writeAllFD(fd, BAD_REQUEST) catch |err| switch (err) {
        // Best effort: the connection is being dropped either way.
        error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull,
        => {},
    };

    return Error.ZixHttp2_Upgrade_BadRequest;
}

fn acceptInner(
    fd: std.posix.fd_t,
    prefix: []const u8,
    head_buf: []u8,
    settings_buf: []u8,
) Inner!UpgradeHead {
    if (prefix.len > head_buf.len) return Error.ZixHttp2_Upgrade_HeaderTooLarge;

    @memcpy(head_buf[0..prefix.len], prefix);
    const head_len = try readHead(fd, head_buf, prefix.len);
    const head = head_buf[0..head_len];

    if (!isH2cUpgrade(head)) return rejectBadRequest(fd);

    const result = parseHead(head, settings_buf);

    try writer.writeAllFD(fd, SWITCHING_PROTOCOLS);

    return result;
}

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_Upgrade_HeaderTooLarge => Error.ZixHttp2_Upgrade_HeaderTooLarge,
        error.ZixHttp2_Upgrade_Closed => Error.ZixHttp2_Upgrade_Closed,
        error.ZixHttp2_Upgrade_ReadFailed => Error.ZixHttp2_Upgrade_ReadFailed,
        error.ZixHttp2_Upgrade_BadRequest => Error.ZixHttp2_Upgrade_BadRequest,
        error.ZixHttp2_Upgrade_BrokenPipe => Error.ZixHttp2_Upgrade_BrokenPipe,
        error.ZixHttp2_Upgrade_UnexpectedEOF => Error.ZixHttp2_Upgrade_UnexpectedEOF,
        error.ZixHttp2_Upgrade_Overflow => Error.ZixHttp2_Upgrade_Overflow,
        error.ZixHttp2_Upgrade_BufferFull => Error.ZixHttp2_Upgrade_BufferFull,
        error.ZixHttp2_Reader_Closed => Error.ZixHttp2_Upgrade_Closed,
        error.ZixHttp2_Reader_ReadFailed => Error.ZixHttp2_Upgrade_ReadFailed,
        error.ZixHttp2_Writer_BrokenPipe => Error.ZixHttp2_Upgrade_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF => Error.ZixHttp2_Upgrade_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow => Error.ZixHttp2_Upgrade_Overflow,
        error.ZixHttp2_Writer_BufferFull => Error.ZixHttp2_Upgrade_BufferFull,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 upgrade error
pub const Error = error {
    ZixHttp2_Upgrade_HeaderTooLarge,
    ZixHttp2_Upgrade_Closed,
    ZixHttp2_Upgrade_ReadFailed,
    ZixHttp2_Upgrade_BadRequest,
    ZixHttp2_Upgrade_BrokenPipe,
    ZixHttp2_Upgrade_UnexpectedEOF,
    ZixHttp2_Upgrade_Overflow,
    ZixHttp2_Upgrade_BufferFull,
};

/// End of an HTTP/1.1 head: the empty line after the last header.
pub const HEAD_END = "\r\n\r\n";

/// Reply to a request that is not an h2c upgrade.
pub const BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";

/// Reply that accepts an h2c upgrade.
pub const SWITCHING_PROTOCOLS =
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Connection: Upgrade\r\nUpgrade: h2c\r\n\r\n";

/// Whether an HTTP/1.1 head asks for an h2c upgrade.
///
/// Param:
/// head - []const u8 (request line and headers, ending in an empty line)
///
/// Return:
/// - bool (true when the Upgrade header is h2c, case-insensitive)
pub fn isH2cUpgrade(head: []const u8) bool {
    const upgrade_value = headerValue(head, "upgrade") orelse return false;

    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade_value, " "), "h2c");
}

/// Read the method, target, and HTTP2-Settings of an h2c upgrade head.
///
/// Note:
/// - No I/O. The caller already checked isH2cUpgrade.
///
/// Param:
/// head - []const u8 (request line and headers, ending in an empty line)
/// settings_buf - []u8 (holds the decoded HTTP2-Settings payload)
///
/// Return:
/// - UpgradeHead (borrows head and settings_buf)
pub fn parseHead(head: []const u8, settings_buf: []u8) UpgradeHead {
    var result = requestLine(head);
    if (headerValue(head, "http2-settings")) |value| {
        result.settings = decodeSettings(value, settings_buf);
    }

    return result;
}

/// Read an HTTP/1.1 request that asks for h2c and answer 101.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// prefix - []const u8 (bytes already read off fd, the head starts with them)
/// head_buf - []u8 (holds the HTTP/1.1 head, its length bounds the head)
/// settings_buf - []u8 (holds the decoded HTTP2-Settings payload)
///
/// Return:
/// - UpgradeHead (borrows head_buf and settings_buf)
/// - Error.ZixHttp2_Upgrade_BadRequest when the request is not an h2c
///   upgrade, after a 400 was sent
/// - Error.ZixHttp2_Upgrade_HeaderTooLarge when the head does not fit
/// - Error.ZixHttp2_Upgrade_Closed when the peer closed mid-head
pub fn accept(
    fd: std.posix.fd_t,
    prefix: []const u8,
    head_buf: []u8,
    settings_buf: []u8,
) Error!UpgradeHead {
    return acceptInner(fd, prefix, head_buf, settings_buf) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

const TEST_HEAD =
    "GET /items?page=2 HTTP/1.1\r\n" ++
    "Host: localhost\r\n" ++
    "Connection: Upgrade, HTTP2-Settings\r\n" ++
    "Upgrade: h2c\r\n" ++
    "HTTP2-Settings: AAMAAABkAAQAAP__\r\n\r\n";

fn testWriteAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;

    while (written < data.len) {
        const rc = std.posix.system.write(fd, data[written..].ptr, data.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => written += @intCast(rc),
            .INTR => continue,
            else => return error.ZixTest_WriteFailed,
        }
    }
}

fn testReadSome(fd: std.posix.fd_t, buf: []u8) ![]u8 {
    const got = try std.posix.read(fd, buf);

    return buf[0..got];
}

test "zix http2: upgrade, headerValue ignores case and trims" {
    const value = headerValue(TEST_HEAD, "UPGRADE").?;

    try std.testing.expectEqualStrings("h2c", value);
}

test "zix http2: upgrade, headerValue skips the request line" {
    try std.testing.expect(headerValue("GET / HTTP/1.1\r\n\r\n", "GET / HTTP/1.1") == null);
}

test "zix http2: upgrade, headerValue missing returns null" {
    try std.testing.expect(headerValue(TEST_HEAD, "x-missing") == null);
}

test "zix http2: upgrade, isH2cUpgrade accepts h2c in any case" {
    const head = "GET / HTTP/1.1\r\nUpgrade:  H2C \r\n\r\n";

    try std.testing.expect(isH2cUpgrade(head));
}

test "zix http2: upgrade, isH2cUpgrade refuses another protocol" {
    const head = "GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n";

    try std.testing.expect(!isH2cUpgrade(head));
}

test "zix http2: upgrade, isH2cUpgrade without the header is false" {
    try std.testing.expect(!isH2cUpgrade("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
}

test "zix http2: upgrade, decodeSettings reads two parameters" {
    var out: [64]u8 = undefined;
    const got = decodeSettings("AAMAAABkAAQAAP__", &out);

    try std.testing.expectEqual(@as(usize, 12), got.len);
    try std.testing.expectEqual(@as(u8, 0x03), got[1]);
    try std.testing.expectEqual(@as(u8, 0x64), got[5]);
}

test "zix http2: upgrade, decodeSettings malformed returns empty" {
    var out: [64]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), decodeSettings("!!!", &out).len);
}

test "zix http2: upgrade, decodeSettings too large returns empty" {
    var out: [4]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), decodeSettings("AAMAAABkAAQAAP__", &out).len);
}

test "zix http2: upgrade, requestLine splits method and target" {
    const head = requestLine(TEST_HEAD);

    try std.testing.expectEqualStrings("GET", head.method);
    try std.testing.expectEqualStrings("/items?page=2", head.path);
}

test "zix http2: upgrade, requestLine without spaces falls back" {
    const head = requestLine("garbage");

    try std.testing.expectEqualStrings("GET", head.method);
    try std.testing.expectEqualStrings("/", head.path);
}

test "zix http2: upgrade, parseHead reads method, target, and settings" {
    var settings_buf: [64]u8 = undefined;
    const head = parseHead(TEST_HEAD, &settings_buf);

    try std.testing.expectEqualStrings("GET", head.method);
    try std.testing.expectEqualStrings("/items?page=2", head.path);
    try std.testing.expect(head.settings.len > 0);
}

test "zix http2: upgrade, parseHead without HTTP2-Settings leaves settings empty" {
    var settings_buf: [64]u8 = undefined;
    const head = parseHead(
        "POST /form HTTP/1.1\r\nUpgrade: h2c\r\n\r\n",
        &settings_buf,
    );

    try std.testing.expectEqualStrings("POST", head.method);
    try std.testing.expectEqualStrings("/form", head.path);
    try std.testing.expectEqual(@as(usize, 0), head.settings.len);
}

test "zix http2: upgrade, accept answers 101" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try testWriteAll(fds[1], TEST_HEAD[3..]);

    var head_buf: [1024]u8 = undefined;
    var settings_buf: [64]u8 = undefined;
    const head = try accept(fds[0], TEST_HEAD[0..3], &head_buf, &settings_buf);

    try std.testing.expectEqualStrings("/items?page=2", head.path);
    try std.testing.expectEqual(@as(usize, 12), head.settings.len);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(SWITCHING_PROTOCOLS, try testReadSome(fds[1], &buf));
}

test "zix http2: upgrade, accept without h2c answers 400" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try testWriteAll(fds[1], "GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n");

    var head_buf: [1024]u8 = undefined;
    var settings_buf: [64]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_Upgrade_BadRequest,
        accept(fds[0], "", &head_buf, &settings_buf),
    );

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(BAD_REQUEST, try testReadSome(fds[1], &buf));
}

test "zix http2: upgrade, accept head too large" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try testWriteAll(fds[1], "GET / HTTP/1.1\r\nHost: localhost\r\n");

    var head_buf: [16]u8 = undefined;
    var settings_buf: [64]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_Upgrade_HeaderTooLarge,
        accept(fds[0], "", &head_buf, &settings_buf),
    );
}

test "zix http2: upgrade, accept peer closed mid-head" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    try testWriteAll(fds[1], "GET / HTTP/1.1\r\n");
    _ = std.posix.system.close(fds[1]);

    var head_buf: [1024]u8 = undefined;
    var settings_buf: [64]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_Upgrade_Closed,
        accept(fds[0], "", &head_buf, &settings_buf),
    );
}

