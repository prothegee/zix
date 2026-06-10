//! Behaviour tests: zix.Http1 core parsing API contract.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: Http1 parseHead extracts method, path, and version" {
    const result = try zix.Http1.parseHead("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try std.testing.expectEqualStrings("GET", result.head.method);
    try std.testing.expectEqualStrings("/health", result.head.path);
    try std.testing.expectEqual(@as(u8, 1), result.head.version_minor);
}

test "zix behaviour: Http1 parseHead HTTP/1.1 defaults keep_alive to true" {
    const result = try zix.Http1.parseHead("GET / HTTP/1.1\r\n\r\n");
    try std.testing.expect(result.head.keep_alive);
}

test "zix behaviour: Http1 parseHead Connection: close disables keep_alive" {
    const result = try zix.Http1.parseHead("GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    try std.testing.expect(!result.head.keep_alive);
}

test "zix behaviour: Http1 getHeader returns value case-insensitively" {
    const result = try zix.Http1.parseHead("GET / HTTP/1.1\r\nX-Request-Id: abc123\r\n\r\n");
    try std.testing.expectEqualStrings("abc123", zix.Http1.getHeader(&result.head, "x-request-id").?);
    try std.testing.expectEqualStrings("abc123", zix.Http1.getHeader(&result.head, "X-REQUEST-ID").?);
}

test "zix behaviour: Http1 queryParam returns value for named param" {
    const result = try zix.Http1.parseHead("GET /path?token=xyz HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualStrings("xyz", zix.Http1.queryParam(&result.head, "token").?);
}
