//! Integration tests: zix.Http.Request
//! Covers gaps not in the unit tests in src/tcp/http/request.zig:
//!   - pathParam() with path_params populated
//!   - body() with body_cache pre-set (no reader needed)
//!   - queryParam() empty-value edge case ("?k=" → "" not null)
//!   - queryParams() empty-value edge case ("?k=" → .value = null)

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

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
    var inner = makeInner(.GET, "/path/user/alice");
    var req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = std.testing.allocator,
        .path_params = &.{.{ .name = "id", .value = "alice" }},
    };

    try std.testing.expectEqualStrings("alice", req.pathParam("id").?);
    try std.testing.expect(req.pathParam("missing") == null);
}

test "zix integration: pathParam() hyphenated names (http_paths example)" {
    var inner = makeInner(.GET, "/path/acme/main");
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
    // reader is undefined — if body() reads from it the test will crash.
    // body_cache short-circuits the reader path.
    var inner = makeInner(.POST, "/user");
    var req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = std.testing.allocator,
        .body_cache = "{\"name\":\"Alice\",\"age\":30}",
    };

    const b = try req.body();
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", b);

    // second call must return the same slice (no re-read)
    const b2 = try req.body();
    try std.testing.expect(b.ptr == b2.ptr);
}

test "zix integration: queryParam() — empty value returns empty string not null" {
    // "?k=" has a key 'k' with an empty value.
    // queryParam() returns the raw substring after '=', which is "".
    // This differs from queryParams() which normalises empty values to null.
    var inner = makeInner(.GET, "/path?k=");
    const req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = std.testing.allocator,
    };

    const v = req.queryParam("k");
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("", v.?);
}

test "zix integration: queryParams() — empty value yields null in QueryParam.value" {
    // queryParams() normalises: if val.len == 0 the value field is null, not "".
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var inner = makeInner(.GET, "/path?k=");
    const req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = arena.allocator(),
    };

    const params = try req.queryParams(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("k", params[0].key);
    try std.testing.expect(params[0].value == null);
}
