//! Integration tests: zix.Http.Request pre-wired state.
//! Verifies pathParam() and body() when their backing state is populated
//! by the caller, as the server does before dispatch.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix integration: pathParam() single param" {
    var req = try zix.Http.Request.fromRaw(
        "GET /users/alice HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    req.path_params = &.{.{ .name = "id", .value = "alice" }};
    try std.testing.expectEqualStrings("alice", req.pathParam("id").?);
    try std.testing.expect(req.pathParam("missing") == null);
}

test "zix integration: pathParam() hyphenated param names" {
    var req = try zix.Http.Request.fromRaw(
        "GET /orgs/acme/branch/main HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    req.path_params = &.{
        .{ .name = "tenant-id", .value = "acme" },
        .{ .name = "tenant-branch", .value = "main" },
    };
    try std.testing.expectEqualStrings("acme", req.pathParam("tenant-id").?);
    try std.testing.expectEqualStrings("main", req.pathParam("tenant-branch").?);
    try std.testing.expect(req.pathParam("missing") == null);
}

test "zix integration: body(), chunked single chunk decoded correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try zix.Http.Request.fromRaw(
        "POST /upload HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n0\r\n\r\n",
        arena.allocator(),
    );
    const b = try req.body();
    try std.testing.expectEqualStrings("hello", b);
}

test "zix integration: body(), chunked multiple chunks assembled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try zix.Http.Request.fromRaw(
        "POST /data HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "3\r\nfoo\r\n4\r\nbarr\r\n0\r\n\r\n",
        arena.allocator(),
    );
    const b = try req.body();
    try std.testing.expectEqualStrings("foobarr", b);
}

test "zix integration: body(), chunked empty body returns empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try zix.Http.Request.fromRaw(
        "POST /empty HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "0\r\n\r\n",
        arena.allocator(),
    );
    const b = try req.body();
    try std.testing.expectEqualStrings("", b);
}

test "zix integration: body() returns body_cache without touching reader" {
    // body_cache must short-circuit before any read attempt (fd is undefined).
    var req = try zix.Http.Request.fromRaw(
        "POST /users HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    req.body_cache = "{\"name\":\"Alice\",\"age\":30}";
    const b = try req.body();
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", b);
    // second call returns same pointer, no re-read
    const b2 = try req.body();
    try std.testing.expect(b.ptr == b2.ptr);
}
