//! Integration tests: Request.header() pre-populated index lookup.
//! These tests pre-populate header_index directly to exercise the cached lookup path.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix integration: header(), empty index returns null for all lookups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = try zix.Http.Request.fromRaw(
        "GET /api HTTP/1.1\r\nHost: localhost\r\n\r\n",
        arena.allocator(),
    );
    req.header_index = .empty;

    try std.testing.expect(req.header("Authorization") == null);
    try std.testing.expect(req.header("Content-Type") == null);
    try std.testing.expect(req.header("X-Missing") == null);
}

test "zix integration: header(), case-insensitive lookup via pre-populated index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    try map.put(al, "content-type", "application/json");
    try map.put(al, "authorization", "Bearer token123");
    try map.put(al, "x-request-id", "abc-42");

    var req = try zix.Http.Request.fromRaw(
        "GET /api/items HTTP/1.1\r\nHost: localhost\r\n\r\n",
        al,
    );
    req.header_index = map;

    try std.testing.expectEqualStrings("application/json", req.header("content-type").?);
    try std.testing.expectEqualStrings("application/json", req.header("Content-Type").?);
    try std.testing.expectEqualStrings("application/json", req.header("CONTENT-TYPE").?);
    try std.testing.expectEqualStrings("Bearer token123", req.header("Authorization").?);
    try std.testing.expectEqualStrings("abc-42", req.header("X-Request-Id").?);
    try std.testing.expect(req.header("Accept") == null);
}
