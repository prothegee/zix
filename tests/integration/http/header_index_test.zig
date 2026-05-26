//! Integration tests: Request.header() linear scan lookup.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix integration: header(), absent names return null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = try zix.Http.Request.fromRaw(
        "GET /api HTTP/1.1\r\nHost: localhost\r\n\r\n",
        arena.allocator(),
    );

    try std.testing.expect(req.header("Authorization") == null);
    try std.testing.expect(req.header("Content-Type") == null);
    try std.testing.expect(req.header("X-Missing") == null);
}

test "zix integration: header(), case-insensitive match via parsed headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = try zix.Http.Request.fromRaw(
        "GET /api/items HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nAuthorization: Bearer token123\r\nX-Request-Id: abc-42\r\n\r\n",
        arena.allocator(),
    );

    try std.testing.expectEqualStrings("application/json", req.header("content-type").?);
    try std.testing.expectEqualStrings("application/json", req.header("Content-Type").?);
    try std.testing.expectEqualStrings("application/json", req.header("CONTENT-TYPE").?);
    try std.testing.expectEqualStrings("Bearer token123", req.header("Authorization").?);
    try std.testing.expectEqualStrings("abc-42", req.header("X-Request-Id").?);
    try std.testing.expect(req.header("Accept") == null);
}
