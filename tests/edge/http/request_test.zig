//! Edge tests: zix.Http.Request query parsing boundary conditions.
//! Verifies behaviour at the boundaries: empty value, missing key, no query string.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: queryParam, key present with empty value returns empty string" {
    // "?k=" means the key exists but maps to the empty string, must not return null
    const req = try zix.Http.Request.fromRaw(
        "GET /search?k= HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    const v = req.queryParam("k");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("", v.?);
}

test "zix edge: queryParam, key absent returns null" {
    const req = try zix.Http.Request.fromRaw(
        "GET /search?other=value HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    try std.testing.expect(req.queryParam("missing") == null);
}

test "zix edge: queryParam, no query string at all returns null" {
    const req = try zix.Http.Request.fromRaw(
        "GET /search HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    try std.testing.expect(req.queryParam("k") == null);
}

test "zix edge: body(), chunked invalid hex returns empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try zix.Http.Request.fromRaw(
        "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "zz\r\nbaddata\r\n0\r\n\r\n",
        arena.allocator(),
    );
    const b = try req.body();
    try std.testing.expectEqualStrings("", b);
}

test "zix edge: body(), chunked missing terminal chunk returns partial data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try zix.Http.Request.fromRaw(
        "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n",
        arena.allocator(),
    );
    const b = try req.body();
    try std.testing.expectEqualStrings("hello", b);
}

test "zix edge: body(), chunked single-byte chunks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try zix.Http.Request.fromRaw(
        "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "1\r\na\r\n1\r\nb\r\n1\r\nc\r\n0\r\n\r\n",
        arena.allocator(),
    );
    const b = try req.body();
    try std.testing.expectEqualStrings("abc", b);
}
