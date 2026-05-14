//! Integration tests: Request.header() pre-populated index lookup.
//! The index-build path requires a live server.receiveHead(), these tests
//! pre-populate header_index directly to exercise the cached lookup path.

const std = @import("std");
const zix = @import("zix");

fn makeInner(target_: []const u8) std.http.Server.Request {
    return .{
        .server = undefined,
        .head = .{
            .method = .GET,
            .target = target_,
            .version = .@"HTTP/1.1",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = .none,
            .transfer_compression = .identity,
            .keep_alive = true,
        },
        .head_buffer = undefined,
        .respond_err = null,
    };
}

// --------------------------------------------------------- //

test "zix integration: header(), empty index returns null for all lookups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var inner = makeInner("/api");
    var req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = arena.allocator(),
        .header_index = empty_map,
    };

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

    var inner = makeInner("/api/items");
    var req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = al,
        .header_index = map,
    };

    try std.testing.expectEqualStrings("application/json", req.header("content-type").?);
    try std.testing.expectEqualStrings("application/json", req.header("Content-Type").?);
    try std.testing.expectEqualStrings("application/json", req.header("CONTENT-TYPE").?);
    try std.testing.expectEqualStrings("Bearer token123", req.header("Authorization").?);
    try std.testing.expectEqualStrings("abc-42", req.header("X-Request-Id").?);
    try std.testing.expect(req.header("Accept") == null);
}
