//! Unit tests: parseHead, percentDecode, parseRange, readChunkedBody — no live I/O.
//! Run: zig test rnd/http1_unit_test.zig

const std = @import("std");
const core = @import("http1_poc_core.zig");

// ------------------------------------------------------------------ //
// parseHead                                                           //
// ------------------------------------------------------------------ //

test "unit: parseHead extracts method, path, version from GET request" {
    const raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expectEqualStrings("GET", r.head.method);
    try std.testing.expectEqualStrings("/hello", r.head.path);
    try std.testing.expectEqual(1, r.head.version_minor);
}

test "unit: parseHead extracts query string separately from path" {
    const raw = "GET /search?q=zig&lang=en HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expectEqualStrings("/search", r.head.path);
    try std.testing.expectEqualStrings("q=zig&lang=en", r.head.query);
}

test "unit: parseHead sets version_minor 0 for HTTP/1.0" {
    const raw = "GET / HTTP/1.0\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expectEqual(0, r.head.version_minor);
}

test "unit: parseHead keep_alive true by default for HTTP/1.1" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expect(r.head.keep_alive);
}

test "unit: parseHead keep_alive false for HTTP/1.0 without Connection: keep-alive" {
    const raw = "GET / HTTP/1.0\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expect(!r.head.keep_alive);
}

test "unit: parseHead keep_alive false when Connection: close present" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expect(!r.head.keep_alive);
}

test "unit: parseHead parses Content-Length header" {
    const raw = "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 42\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expectEqual(42, r.head.content_length);
}

test "unit: parseHead sets chunked_request when Transfer-Encoding: chunked" {
    const raw = "POST /data HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expect(r.head.chunked_request);
}

test "unit: parseHead sets expect_continue on Expect: 100-continue" {
    const raw = "POST /big HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000\r\nExpect: 100-continue\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expect(r.head.expect_continue);
}

test "unit: parseHead returns error.InvalidRequest for malformed request line" {
    const raw = "BADREQUEST\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, core.parseHead(raw));
}

test "unit: getHeader finds header case-insensitively" {
    const raw = "GET / HTTP/1.1\r\nContent-Type: text/plain\r\nX-Custom: hello\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expectEqualStrings("text/plain", core.getHeader(&r.head, "content-type").?);
    try std.testing.expectEqualStrings("hello", core.getHeader(&r.head, "x-custom").?);
}

test "unit: getHeader returns null for absent header" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expect(core.getHeader(&r.head, "authorization") == null);
}

// ------------------------------------------------------------------ //
// percentDecode                                                       //
// ------------------------------------------------------------------ //

test "unit: percentDecode decodes %20 as space" {
    var buf = "hello%20world".*;
    const out = core.percentDecode(&buf);
    try std.testing.expectEqualStrings("hello world", out);
}

test "unit: percentDecode leaves plain ASCII unchanged" {
    var buf = "/api/v1/users".*;
    const out = core.percentDecode(&buf);
    try std.testing.expectEqualStrings("/api/v1/users", out);
}

test "unit: percentDecode decodes multiple sequences" {
    var buf = "%2Fpath%2Fto%2Ffile".*;
    const out = core.percentDecode(&buf);
    try std.testing.expectEqualStrings("/path/to/file", out);
}

// ------------------------------------------------------------------ //
// parseRange                                                          //
// ------------------------------------------------------------------ //

test "unit: parseRange parses closed range" {
    const r = core.parseRange("bytes=0-9", 100).?;
    try std.testing.expectEqual(0, r.start);
    try std.testing.expectEqual(9, r.end);
}

test "unit: parseRange parses open-ended range" {
    const r = core.parseRange("bytes=90-", 100).?;
    try std.testing.expectEqual(90, r.start);
    try std.testing.expectEqual(99, r.end);
}

test "unit: parseRange clamps end to total-1 when end exceeds resource size" {
    const r = core.parseRange("bytes=0-999", 36).?;
    try std.testing.expectEqual(0, r.start);
    try std.testing.expectEqual(35, r.end);
}

test "unit: parseRange returns null for start beyond total" {
    try std.testing.expect(core.parseRange("bytes=100-200", 36) == null);
}

test "unit: parseRange returns null for invalid prefix" {
    try std.testing.expect(core.parseRange("items=0-9", 100) == null);
}

test "unit: parseRange returns null for start greater than end" {
    try std.testing.expect(core.parseRange("bytes=9-0", 100) == null);
}

// ------------------------------------------------------------------ //
// readChunkedBody                                                      //
// ------------------------------------------------------------------ //

fn makePipe() ![2]std.posix.fd_t {
    return try std.Io.Threaded.pipe2(.{});
}

test "unit: readChunkedBody decodes single chunk" {
    const fds = try makePipe();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);
    const data = "5\r\nhello\r\n0\r\n\r\n";
    _ = std.posix.system.write(fds[1], data.ptr, data.len);
    _ = std.posix.system.close(fds[1]);
    var out: [64]u8 = undefined;
    const n = try core.readChunkedBody(fds[0], &.{}, &out);
    try std.testing.expectEqual(5, n);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

test "unit: readChunkedBody decodes multiple chunks" {
    const fds = try makePipe();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);
    const data = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    _ = std.posix.system.write(fds[1], data.ptr, data.len);
    _ = std.posix.system.close(fds[1]);
    var out: [64]u8 = undefined;
    const n = try core.readChunkedBody(fds[0], &.{}, &out);
    try std.testing.expectEqual(11, n);
    try std.testing.expectEqualStrings("hello world", out[0..n]);
}

test "unit: readChunkedBody ignores chunk extension after semicolon" {
    const fds = try makePipe();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);
    const data = "5;name=value\r\nhello\r\n0\r\n\r\n";
    _ = std.posix.system.write(fds[1], data.ptr, data.len);
    _ = std.posix.system.close(fds[1]);
    var out: [64]u8 = undefined;
    const n = try core.readChunkedBody(fds[0], &.{}, &out);
    try std.testing.expectEqual(5, n);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}

test "unit: readChunkedBody uses peeked bytes before reading from fd" {
    const fds = try makePipe();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);
    const peeked = "5\r\nhel"; // chunk-size line + partial data already buffered
    const rest = "lo\r\n0\r\n\r\n"; // remainder on wire
    _ = std.posix.system.write(fds[1], rest.ptr, rest.len);
    _ = std.posix.system.close(fds[1]);
    var out: [64]u8 = undefined;
    const n = try core.readChunkedBody(fds[0], peeked, &out);
    try std.testing.expectEqual(5, n);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}
