//! Integration tests: zix.Http.Request pre-wired state.
//! Verifies pathParam() and body() when their backing state is populated
//! by the caller, as the server does before dispatch.

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

test "zix integration: pathParam() single param" {
    var inner = makeInner(.GET, "/users/alice");
    var req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = std.testing.allocator,
        .path_params = &.{.{ .name = "id", .value = "alice" }},
    };
    try std.testing.expectEqualStrings("alice", req.pathParam("id").?);
    try std.testing.expect(req.pathParam("missing") == null);
}

test "zix integration: pathParam() hyphenated param names" {
    var inner = makeInner(.GET, "/orgs/acme/branch/main");
    var req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = std.testing.allocator,
        .path_params = &.{
            .{ .name = "tenant-id", .value = "acme" },
            .{ .name = "tenant-branch", .value = "main" },
        },
    };
    try std.testing.expectEqualStrings("acme", req.pathParam("tenant-id").?);
    try std.testing.expectEqualStrings("main", req.pathParam("tenant-branch").?);
    try std.testing.expect(req.pathParam("missing") == null);
}

test "zix integration: body() returns body_cache without touching reader" {
    // reader is undefined, body_cache must short-circuit before any read attempt.
    var inner = makeInner(.POST, "/users");
    var req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = std.testing.allocator,
        .body_cache = "{\"name\":\"Alice\",\"age\":30}",
    };
    const b = try req.body();
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", b);
    // second call returns same pointer, no re-read
    const b2 = try req.body();
    try std.testing.expect(b.ptr == b2.ptr);
}
