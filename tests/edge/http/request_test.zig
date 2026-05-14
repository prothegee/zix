//! Edge tests: zix.Http.Request query parsing boundary conditions.
//! Verifies behaviour at the boundaries: empty value, missing key, no query string.

const std = @import("std");
const zix = @import("zix");

fn makeInner(method_: std.http.Method, target_: []const u8) std.http.Server.Request {
    return .{
        .server = undefined,
        .head = .{
            .method = method_,
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

test "zix edge: queryParam, key present with empty value returns empty string" {
    // "?k=" means the key exists but maps to the empty string, must not return null
    var inner = makeInner(.GET, "/search?k=");
    const req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = std.testing.allocator };
    const v = req.queryParam("k");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("", v.?);
}

test "zix edge: queryParam, key absent returns null" {
    var inner = makeInner(.GET, "/search?other=value");
    const req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = std.testing.allocator };
    try std.testing.expect(req.queryParam("missing") == null);
}

test "zix edge: queryParam, no query string at all returns null" {
    var inner = makeInner(.GET, "/search");
    const req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = std.testing.allocator };
    try std.testing.expect(req.queryParam("k") == null);
}
