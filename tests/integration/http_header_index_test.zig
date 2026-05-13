//! Integration tests: Request.header() lazy index lookup path.
//!
//! The index-build path (iterateHeaders) requires a real server.receiveHead()
//! and cannot be exercised in unit/integration tests without a live server.
//! These tests cover the lookup path by pre-populating header_index directly,
//! verifying case-insensitive resolution and missing-key behavior.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

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

test "zix integration: header() -- empty index returns null for all names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Pre-set an empty index so header() uses the cached path without calling
    // iterateHeaders() (which requires a live server).
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

// --------------------------------------------------------- //

test "zix integration: header() -- case-insensitive lookup via pre-populated index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    // Build a lowercase-keyed map matching how header() would build it.
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

    // Exact lowercase match.
    try std.testing.expectEqualStrings("application/json", req.header("content-type").?);

    // Caller uses mixed/upper case -- must still resolve via lowercased key.
    try std.testing.expectEqualStrings("application/json", req.header("Content-Type").?);
    try std.testing.expectEqualStrings("application/json", req.header("CONTENT-TYPE").?);

    try std.testing.expectEqualStrings("Bearer token123", req.header("Authorization").?);
    try std.testing.expectEqualStrings("Bearer token123", req.header("authorization").?);

    try std.testing.expectEqualStrings("abc-42", req.header("X-Request-Id").?);
    try std.testing.expectEqualStrings("abc-42", req.header("x-request-id").?);

    // Absent header returns null.
    try std.testing.expect(req.header("Accept") == null);
    try std.testing.expect(req.header("X-Missing") == null);
}
